// Чисті функції хука старту сесії (рішення 16 плану B4): токени дочірнього `kit.exe session-check`, стеля часу зі
// змінної оточення й текст розділу «Стан сховищ» з коду, stdout і stderr дочірнього процесу. Запуск, тимчасові
// файли й убивство дерева живуть у самому хуку (`src/session_start.rs` бінарника); тут — лише відображення, які
// перевіряють unit-тести.
//
// Межа довіри: контекст сесії бачить агент, тож у нього йде лише stdout дочірнього процесу — текст, який формує
// сам `session-check` (секрети замасковано там). stderr (паніка, `GIT_TRACE`, попередження git) у контекст не
// потрапляє за жодного контрактного коду; лише за неочікуваного коду, обрізаний до 2 КБ.

/// Стеля часу `session-check` за умовчанням, с.
pub const DEFAULT_TIMEOUT_SEC: u64 = 15;

/// Найбільша стеля, с: `timeout` хука SessionStart у `hooks/hooks.json` (60 с) мінус 5 с на старт процесу й
/// друк. Claude Code убиває хук на своєму `timeout` — і тоді контексту немає взагалі, навіть «не вклався».
/// Звірку з `hooks.json` тримає Pester `SessionStartHook.Tests.ps1`: змінене одне без другого — червоне.
pub const MAX_TIMEOUT_SEC: u64 = 55;

/// Найбільший обсяг stderr у тексті неочікуваного коду, байт UTF-8.
pub const STDERR_LIMIT: usize = 2048;

/// Токени дочірнього процесу — закритий перелік: без `-Apply`, `-RunnerPath`, `-InstalledPluginsPath`.
pub fn child_tokens(repo: &str) -> Vec<String> {
    vec![
        "session-check".to_string(),
        "-RepoRoot".to_string(),
        repo.to_string(),
    ]
}

/// Стеля з значення `V8KIT_SESSION_CHECK_TIMEOUT` (рішення 11, 17): ціле `1..=55` — як є; більше — 55;
/// нечисло, порожньо, `≤ 0`, змінної немає (`None`) — 15.
pub fn timeout_sec(value: Option<&str>) -> u64 {
    let Some(v) = value.map(str::trim) else {
        return DEFAULT_TIMEOUT_SEC;
    };
    let digits = v.strip_prefix('+').unwrap_or(v);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        // Порожньо, нечисло, від'ємне.
        return DEFAULT_TIMEOUT_SEC;
    }
    match digits.parse::<u64>() {
        Ok(0) => DEFAULT_TIMEOUT_SEC,
        Ok(n) => n.min(MAX_TIMEOUT_SEC),
        // Лише цифри, але понад u64 — число, більше за межу.
        Err(_) => MAX_TIMEOUT_SEC,
    }
}

/// Найдовший префікс `s` не довший за `limit` байт, що закінчується на межі символу UTF-8.
fn truncate_utf8(s: &str, limit: usize) -> &str {
    if s.len() <= limit {
        return s;
    }
    let mut end = limit;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Текст розділу «Стан сховищ» (рішення 10). `code` — код виходу `session-check`, `None` — убито на стелі
/// `timeout` с. У контекст іде лише `stdout`; `stderr` — лише за неочікуваного коду, обрізаний до 2 КБ.
pub fn status_text(code: Option<i32>, stdout: &str, stderr: &str, timeout: u64) -> String {
    let out = stdout.trim();
    let Some(code) = code else {
        let mut status = format!(
            "УВАГА: kit session-check не вклався в {timeout} с — стан сховищ НЕВІДОМИЙ, не «без змін». Найчастіша причина — повільний доступ до сховища (SMB); перевірити вручну: kit session-check -RepoRoot ."
        );
        // Те, що kit устиг надрукувати, не пропадає; позначка «частково» обов'язкова.
        if !out.is_empty() {
            status.push_str(&format!(
                "\n\nЧастково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):\n{out}"
            ));
        }
        return status;
    };
    match code {
        0 | 1 | 4 if !out.is_empty() => out.to_string(),
        3 if !out.is_empty() => format!(
            "УВАГА: kit session-check завершився кодом 3 — стан сховищ ЧАСТКОВО НЕВІДОМИЙ: частину не перевірено, тож відсутність сигналу не означає «без змін».\n\n{out}"
        ),
        // Справжній session-check завжди друкує хоч рядок: порожнеча — збій, а не «нових версій немає».
        0 | 1 | 3 | 4 => format!(
            "УВАГА: kit session-check завершився кодом {code} без жодного виводу — стан сховищ НЕВІДОМИЙ, не «без змін». Перевірити вручну: kit session-check -RepoRoot ."
        ),
        _ => {
            let err = stderr.trim();
            let cut = truncate_utf8(err, STDERR_LIMIT);
            let mut raw = [out, cut]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            if cut.len() < err.len() {
                raw.push_str("\n… (stderr обрізано до 2 КБ)");
            }
            format!(
                "УВАГА: kit session-check завершився неочікуваним кодом {code} (очікувалось 0, 1, 3 або 4) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:\n{raw}"
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MARK: &str = "STDERR-MARKER-7f3a";

    #[test]
    fn child_tokens_are_exactly_session_check_and_repo_root() {
        assert_eq!(
            child_tokens(r"C:\р\repo"),
            vec![
                "session-check".to_string(),
                "-RepoRoot".to_string(),
                r"C:\р\repo".to_string()
            ]
        );
    }

    #[test]
    fn timeout_within_bounds_is_taken_as_is() {
        assert_eq!(timeout_sec(Some("1")), 1);
        assert_eq!(timeout_sec(Some(" 30 ")), 30);
        assert_eq!(timeout_sec(Some("55")), 55);
    }

    #[test]
    fn timeout_above_the_bound_is_cut_to_55() {
        assert_eq!(timeout_sec(Some("56")), 55);
        assert_eq!(timeout_sec(Some("600")), 55);
        assert_eq!(timeout_sec(Some("99999999999999999999999")), 55);
    }

    #[test]
    fn timeout_not_a_number_empty_nonpositive_or_absent_is_15() {
        for v in ["abc", "1.5", "", "  ", "0", "-5", "5s"] {
            assert_eq!(timeout_sec(Some(v)), 15, "{v:?}");
        }
        assert_eq!(timeout_sec(None), 15);
    }

    #[test]
    fn code_0_1_4_with_output_is_stdout_as_is_and_stderr_never_enters() {
        for code in [0, 1, 4] {
            let t = status_text(Some(code), "рядок сигналу\nnext: kit sync\n", MARK, 15);
            assert_eq!(t, "рядок сигналу\nnext: kit sync", "код {code}");
        }
    }

    #[test]
    fn code_3_with_output_is_partially_unknown_plus_stdout_without_stderr() {
        let t = status_text(Some(3), "- Alpha: прочитано не повністю\n", MARK, 15);
        assert!(t.contains("стан сховищ ЧАСТКОВО НЕВІДОМИЙ"), "{t}");
        assert!(t.ends_with("\n\n- Alpha: прочитано не повністю"), "{t}");
        assert!(!t.contains(MARK), "{t}");
    }

    #[test]
    fn contract_codes_without_output_are_unknown_with_the_code() {
        for code in [0, 1, 3, 4] {
            let t = status_text(Some(code), " \n", MARK, 15);
            assert!(t.contains("стан сховищ НЕВІДОМИЙ"), "{t}");
            assert!(
                t.contains(&format!("кодом {code} без жодного виводу")),
                "{t}"
            );
            assert!(!t.contains("неочікуваним"), "{t}");
            assert!(!t.contains("ЧАСТКОВО"), "{t}");
            assert!(!t.contains(MARK), "код {code}: {t}");
        }
    }

    #[test]
    fn unexpected_code_names_0_1_3_4_and_carries_stderr() {
        let t = status_text(Some(2), "", MARK, 15);
        assert!(
            t.contains("неочікуваним кодом 2 (очікувалось 0, 1, 3 або 4)"),
            "{t}"
        );
        assert!(t.contains("НЕВІДОМИЙ"), "{t}");
        assert!(t.ends_with(MARK), "{t}");
        let t = status_text(Some(-1), "вивід", "", 15);
        assert!(t.ends_with("Зупинка:\nвивід"), "{t}");
    }

    #[test]
    fn unexpected_code_cuts_stderr_to_2_kb_on_a_char_boundary() {
        // 'ї' — 2 байти: 1025 символів = 2050 байт, межа 2048 падає між символами лише за непарного зсуву.
        let err = format!("x{}", "ї".repeat(1100));
        let t = status_text(Some(7), "", &err, 15);
        let body = t.split_once("Зупинка:\n").unwrap().1;
        let (kept, note) = body.split_once("\n… ").unwrap();
        assert!(kept.len() <= STDERR_LIMIT, "{}", kept.len());
        assert_eq!(kept.len(), 2047, "межа символу: x + 1023 × 2 байти");
        assert!(note.contains("обрізано до 2 КБ"), "{note}");
        // Короткий stderr — без позначки.
        assert!(!status_text(Some(7), "", "коротко", 15).contains("обрізано"));
    }

    #[test]
    fn ceiling_says_not_within_and_partial_only_for_printed_stdout() {
        let t = status_text(None, "", MARK, 3);
        assert!(t.contains("не вклався в 3 с"), "{t}");
        assert!(t.contains("НЕВІДОМИЙ"), "{t}");
        assert!(!t.contains("Частково"), "{t}");
        assert!(!t.contains(MARK), "{t}");
        let t = status_text(None, "[!] хуків немає: kit install-hooks\n", MARK, 3);
        assert!(
            t.ends_with("Частково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):\n[!] хуків немає: kit install-hooks"),
            "{t}"
        );
        assert!(!t.contains(MARK), "{t}");
    }
}
