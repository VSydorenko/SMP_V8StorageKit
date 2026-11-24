// Хуки захисту `storage/*` і старий проєктний хук старту сесії (еталон — `Test-KitGitHooks`,
// `Test-KitLegacySessionHook`, tools/lib/Hooks.psm1). Модуль бібліотечний, без друку; git — лише через ядро `git`
// (запити від кореня зі стелею, збій ≠ «немає»). PowerShell-копії лишаються (їх кличуть `install-hooks`, `sync`).
//
// Відмінності від PowerShell (рішення 5, 8, 12 плану B3):
//  - `core.hooksPath` нормалізується відносно кореня: `./.githooks` і абсолютний шлях до тієї самої теки — не
//    помилка;
//  - збій git чи читання файла — «не перевірено» цієї перевірки, а не втрата звіту; абсолютний `core.hooksPath`,
//    що не відповів за стелю, — warn «недоступний з цієї машини» (відповідь, не збій);
//  - відсутній шаблон плагіна — «не перевірено: шаблон <ім'я> не знайдено в плагіні», а не тиша;
//  - шаблони шукаються від `current_exe` (корінь плагіна), не від поточної теки;
//  - `hook-shim`: «не JSON» і «неочікувана структура» — різні тексти; текст розбору JSON не друкується (лише
//    рядок і колонка: текст `serde_json` може цитувати дані файла).

use crate::case_guard::fold;
use crate::ceiling::Pending;
use crate::config::Level;
use crate::git::query;
use serde_json::Value;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const HOOKS_DIR: &str = ".githooks";
pub const HOOK_NAMES: [&str; 2] = ["pre-commit", "pre-merge-commit"];
const SESSION_HOOK: &str = ".claude/hooks/session-start.ps1";
const SETTINGS: &str = ".claude/settings.json";
/// Стеля розв'язання абсолютного `core.hooksPath` (мережевий шлях може не відповісти).
const PATH_CEILING: Duration = Duration::from_secs(5);

/// Результат одного пункту аудиту: знахідка рівня `level` або «не перевірено» (перевірку треба було виконати, а
/// вона не вдалася).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Finding { level: Level, message: String },
    Unchecked { what: String, reason: String },
}

fn finding(level: Level, message: String) -> Outcome {
    Outcome::Finding { level, message }
}

fn unchecked(what: impl Into<String>, reason: impl Into<String>) -> Outcome {
    Outcome::Unchecked {
        what: what.into(),
        reason: reason.into(),
    }
}

/// Тека шаблонів плагіна: від `current_exe` угору до першого предка, де лежить `templates/githooks` (у поставці —
/// `<корінь плагіна>/bin/kit.exe`; у `cargo test` — дерево розробки). Від поточної теки не залежить.
pub fn plugin_templates_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    exe.ancestors()
        .skip(1)
        .map(|a| a.join("templates").join("githooks"))
        .find(|d| d.is_dir())
}

/// Розв'язання `core.hooksPath`: відповідь уже відома (збіг рядків — без мережі) або проба, що йде в потоці.
pub enum Resolution {
    Known(bool),
    Probe {
        pending: Pending<(io::Result<PathBuf>, io::Result<PathBuf>)>,
        secs: u64,
    },
}

impl Resolution {
    /// `Err(секунди)` — абсолютний шлях не відповів за стелю: це відповідь («недоступний з цієї машини»), а не збій
    /// власного читання kit.
    fn finish(self) -> Result<bool, u64> {
        match self {
            Resolution::Known(v) => Ok(v),
            Resolution::Probe { pending, secs } => match pending.wait() {
                None => Err(secs),
                Some((Ok(a), Ok(b))) => {
                    Ok(fold(&a.to_string_lossy()) == fold(&b.to_string_lossy()))
                }
                // Не розв'язується (шляху немає) — не та сама тека.
                Some(_) => Ok(false),
            },
        }
    }
}

/// Початок розв'язання `core.hooksPath` за коренем: `./.githooks`, `.githooks/`, абсолютний шлях до тієї самої
/// теки — та сама тека. Порівняння без регістру (NTFS). Спершу — порівняння рядків (збіг не потребує мережі);
/// інакше `canonicalize` ходить у мережу, тож стартує в потоці зі стелею.
fn begin_hooks_path(
    root: &Path,
    configured: &str,
    ceiling: Duration,
    canon: fn(&Path) -> io::Result<PathBuf>,
) -> Resolution {
    let unified = configured.replace('\\', "/");
    let mut rel = unified.trim_end_matches('/');
    while let Some(rest) = rel.strip_prefix("./") {
        rel = rest.trim_start_matches('/');
    }
    if rel == HOOKS_DIR {
        return Resolution::Known(true);
    }
    if !Path::new(configured).is_absolute() {
        return Resolution::Known(false);
    }
    let want = root.join(HOOKS_DIR);
    let want_text = want.to_string_lossy().replace('\\', "/");
    if fold(unified.trim_end_matches('/')) == fold(want_text.trim_end_matches('/')) {
        return Resolution::Known(true);
    }
    let configured_path = PathBuf::from(configured);
    Resolution::Probe {
        pending: crate::ceiling::start(ceiling, move || (canon(&configured_path), canon(&want))),
        secs: ceiling.as_secs().max(1),
    }
}

/// Те саме одним викликом (початок + очікування).
#[cfg(test)]
fn hooks_path_is_default(
    root: &Path,
    configured: &str,
    ceiling: Duration,
    canon: fn(&Path) -> io::Result<PathBuf>,
) -> Result<bool, u64> {
    begin_hooks_path(root, configured, ceiling, canon).finish()
}

/// `core.hooksPath` із git. `rev-parse --git-dir` розрізняє «значення не задано» й «git не бачить репозиторій»
/// (напр. `core.repositoryformatversion=99`: `config --get` тоді дає код 1, як для незаданого ключа).
fn read_hooks_path(root: &Path) -> Result<String, String> {
    query(root, &["rev-parse", "--git-dir"], &[0])?;
    let o = query(root, &["config", "--get", "core.hooksPath"], &[0, 1])?;
    Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Налаштований `core.hooksPath` і розв'язання, що вже йде.
pub struct HooksPrefetch {
    configured: String,
    resolution: Resolution,
}

fn begin_prefetch(
    root: &Path,
    canon: fn(&Path) -> io::Result<PathBuf>,
) -> Result<HooksPrefetch, String> {
    let configured = read_hooks_path(root)?;
    let resolution = begin_hooks_path(root, &configured, PATH_CEILING, canon);
    Ok(HooksPrefetch {
        configured,
        resolution,
    })
}

/// Стартує розв'язання `core.hooksPath` заздалегідь, щоб мережеві проби `check` ішли паралельно. `None` — git не
/// відповів: `audit_with` сам повідомить причину.
pub fn prefetch_hooks_path(
    root: &Path,
    canon: fn(&Path) -> io::Result<PathBuf>,
) -> Option<HooksPrefetch> {
    begin_prefetch(root, canon).ok()
}

/// Вміст без BOM і з `\n` замість `\r\n`: CR — окрема біда, і про неї каже `.gitattributes`.
fn normalized(bytes: &[u8]) -> Vec<u8> {
    let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let mut out = Vec::with_capacity(body.len());
    let mut i = 0;
    while let Some(b) = body.get(i) {
        if *b == b'\r' && body.get(i.saturating_add(1)) == Some(&b'\n') {
            i = i.saturating_add(1);
            continue;
        }
        out.push(*b);
        i = i.saturating_add(1);
    }
    out
}

fn is_file(path: &Path) -> io::Result<bool> {
    match fs::metadata(path) {
        Ok(m) => Ok(m.is_file()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// Аудит хуків (`Test-KitGitHooks`): `core.hooksPath` увімкнено, обидва файли є, вміст = шаблон плагіна, біт
/// виконання в git. `templates` — тека шаблонів (`None` — не знайдено).
pub fn audit(root: &Path, templates: Option<&Path>) -> Vec<Outcome> {
    audit_with(root, templates, None, |p| fs::canonicalize(p))
}

/// `audit` із розв'язанням `core.hooksPath`, що вже стартувало (`prefetch_hooks_path`).
pub fn audit_with(
    root: &Path,
    templates: Option<&Path>,
    prefetch: Option<HooksPrefetch>,
    canon: fn(&Path) -> io::Result<PathBuf>,
) -> Vec<Outcome> {
    let mut out = Vec::new();
    match prefetch.map_or_else(|| begin_prefetch(root, canon), Ok) {
        Ok(p) => match p.resolution.finish() {
            Ok(true) => {}
            Err(secs) => out.push(finding(
                Level::Warn,
                format!(
                    "каталог хуків не відповів за {secs} с — хуки з цієї машини, ймовірно, не спрацюють: core.hooksPath '{}'. Якщо це мережевий шлях без зв'язку — повторіть із мережею або вкажіть локальну теку: git config core.hooksPath {HOOKS_DIR}.",
                    p.configured
                ),
            )),
            Ok(false) => out.push(finding(
                Level::Error,
                format!(
                    "core.hooksPath не вказує на {HOOKS_DIR} (зараз: '{}') — хуки захисту storage/* не працюють. Увімкнути: git config core.hooksPath {HOOKS_DIR} (скіл onboarding робить це сам).",
                    p.configured
                ),
            )),
        },
        Err(reason) => out.push(unchecked("core.hooksPath", reason)),
    }

    let head = crate::git::ref_exists(root, "HEAD");
    for name in HOOK_NAMES {
        let rel = format!("{HOOKS_DIR}/{name}");
        let installed = root.join(HOOKS_DIR).join(name);
        match is_file(&installed) {
            Ok(true) => {}
            Ok(false) => {
                // Не лише ЧОГО бракує, а й ДЕ взяти файл і другий крок (core.hooksPath).
                out.push(finding(
                    Level::Error,
                    format!(
                        "Хука {rel} немає — гілки storage/* не захищені від ручного коміту. Скопіюйте його з templates/githooks/ у теці плагіна (знайти теку: claude plugin list, або /plugin у сесії Claude Code) у {rel} і виконайте: git config core.hooksPath {HOOKS_DIR}. Або одним кроком: kit install-hooks -RepoRoot . -Apply."
                    ),
                ));
                continue;
            }
            Err(e) => {
                out.push(unchecked(format!("хук {rel}"), e.to_string()));
                continue;
            }
        }
        content(&mut out, &rel, name, &installed, templates);
        mode(&mut out, root, &rel, &head);
    }
    out
}

fn content(
    out: &mut Vec<Outcome>,
    rel: &str,
    name: &str,
    installed: &Path,
    templates: Option<&Path>,
) {
    let template = templates.map(|t| t.join(name));
    let template = match template.as_deref().map(|t| (t, is_file(t))) {
        Some((t, Ok(true))) => t.to_path_buf(),
        Some((_, Ok(false))) | None => {
            return out.push(unchecked(
                format!("вміст хука {rel}"),
                format!("шаблон {name} не знайдено в плагіні"),
            ));
        }
        Some((_, Err(e))) => {
            return out.push(unchecked(
                format!("вміст хука {rel}"),
                format!("шаблон {name} не прочитано: {e}"),
            ));
        }
    };
    match (fs::read(installed), fs::read(&template)) {
        (Ok(a), Ok(b)) => {
            if normalized(&a) != normalized(&b) {
                out.push(finding(
                    Level::Warn,
                    format!(
                        "Хук {rel} відрізняється від шаблону плагіна ({}). Оновіть копію з templates/githooks плагіна, якщо це не свідома локальна правка.",
                        template.display()
                    ),
                ));
            }
        }
        (Err(e), _) | (_, Err(e)) => {
            out.push(unchecked(format!("вміст хука {rel}"), e.to_string()))
        }
    }
}

/// Біт виконання — окрема знахідка від вмісту. На POSIX git не запускає хук без нього й мовчки; питаємо саме git, а
/// не файлову систему: на Windows `core.filemode = false`, і те, що бачить ФС, не має стосунку до режиму, який
/// git запише в дерево майбутнього клону.
fn mode(out: &mut Vec<Outcome>, root: &Path, rel: &str, head: &Result<bool, String>) {
    let spec = format!(":(literal){rel}");
    let staged = match query(root, &["ls-files", "-s", "--", &spec], &[0]) {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(reason) => {
            return out.push(unchecked(format!("режим хука {rel} в індексі"), reason));
        }
    };
    let line = staged.lines().next().unwrap_or_default().trim().to_string();
    let mode: String = line.chars().take(6).collect();
    let has_mode = mode.len() == 6
        && mode.chars().all(|c| c.is_ascii_digit())
        && line.chars().nth(6).is_some_and(char::is_whitespace);
    if !has_mode {
        // Хук є на диску, але не застейджений і не закомічений: наступний клон його не отримає. «Застейджено, але не
        // закомічено» сюди НЕ потрапляє: `ls-files -s` бачить індекс.
        return out.push(finding(
            Level::Warn,
            format!(
                "Хук {rel} лежить на диску, але не закомічений у git — наступний клон його не отримає, і гілки storage/* лишаться без захисту. Закомітьте: git add {rel} і git commit. Або одним кроком (стейджить із бітом виконання самостійно): kit install-hooks -RepoRoot . -Apply."
            ),
        ));
    }
    if mode == "100644" {
        out.push(finding(
            Level::Warn,
            format!(
                "Хук {rel} закомічено без біта виконання (режим 100644) — у клоні на Linux/macOS git тихо проігнорує хук, і storage/* лишиться незахищеним. Полагодити: git update-index --chmod=+x {rel} і закомітити."
            ),
        ));
    }
    // `git commit --only <шляхи>` НЕ бере індекс — перечитує файл із диска, і на Windows (core.filemode=false) пише
    // 100644, хоч в індексі лишається 100755. Індекс тоді бреше про те, що отримає клон, — питаємо сам коміт.
    if mode == "100755" {
        match head {
            Ok(false) => {}
            Err(reason) => out.push(unchecked(
                format!("наявність HEAD для хука {rel}"),
                reason.clone(),
            )),
            Ok(true) => match query(root, &["ls-tree", "HEAD", "--", rel], &[0]) {
                Ok(o) => {
                    if String::from_utf8_lossy(&o.stdout).starts_with("100644") {
                        out.push(finding(
                            Level::Warn,
                            format!(
                                "Хук {rel} у коміті HEAD без біта виконання (100644), хоч в індексі 100755 — так буває після git commit --only (перечитує файл з диска). Клон на Linux/macOS тихо проігнорує хук. Полагодити: закомітьте індекс командою git commit без --only і без шляхів (індекс уже правильний)."
                            ),
                        ));
                    }
                }
                Err(reason) => out.push(unchecked(format!("режим хука {rel} у HEAD"), reason)),
            },
        }
    }
}

/// Старий проєктний хук старту сесії (до 1.6.0): розділ `hooks.SessionStart` з командою на `session-start.ps1` у
/// `.claude/settings.json` і/або файл-шим `.claude/hooks/session-start.ps1` (`Test-KitLegacySessionHook`). Хук
/// тепер у плагіні; старий лишався б другим екземпляром («Стан сховищ» двічі). Одна знахідка називає все
/// знайдене. Нічого не знайдено — тиша.
pub fn legacy_session_hook(root: &Path) -> Vec<Outcome> {
    let mut out = Vec::new();
    let mut found: Vec<String> = Vec::new();
    let settings = root.join(SETTINGS);
    match is_file(&settings) {
        Ok(false) => {}
        Err(e) => out.push(unchecked(
            format!("{SETTINGS}: чи є в ньому старий хук старту сесії"),
            format!("файл не прочитано: {e}"),
        )),
        Ok(true) => match fs::read(&settings) {
            Err(e) => out.push(unchecked(
                format!("{SETTINGS}: чи є в ньому старий хук старту сесії"),
                format!("файл не прочитано: {e}"),
            )),
            Ok(bytes) => {
                let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
                match serde_json::from_slice::<Value>(body) {
                    Err(e) => out.push(unchecked(
                        format!("{SETTINGS}: чи є в ньому старий хук старту сесії"),
                        format!(
                            "файл не JSON (рядок {}, колонка {}) — виправте його; доки він битий, kit не може перевірити, чи немає в ньому старого хука старту сесії",
                            e.line(),
                            e.column()
                        ),
                    )),
                    Ok(json) => match has_legacy_command(&json) {
                        Ok(true) => found.push(format!(
                            "{SETTINGS} (hooks.SessionStart з командою на session-start.ps1)"
                        )),
                        Ok(false) => {}
                        Err(shape) => out.push(unchecked(
                            format!("{SETTINGS}: чи є в ньому старий хук старту сесії"),
                            format!("неочікувана структура файла: {shape}"),
                        )),
                    },
                }
            }
        },
    }
    match is_file(&root.join(SESSION_HOOK)) {
        Ok(true) => found.push(SESSION_HOOK.to_string()),
        Ok(false) => {}
        Err(e) => out.push(unchecked(
            format!("{SESSION_HOOK}: чи є файл-шим"),
            e.to_string(),
        )),
    }
    if !found.is_empty() {
        out.push(finding(
            Level::Warn,
            format!(
                "Старий проєктний хук старту сесії: {}. Тепер цей хук поставляє сам плагін — «Стан сховищ» з'явиться двічі. Прибрати обидва: розділ hooks.SessionStart з командою на session-start.ps1 у {SETTINGS} і файл {SESSION_HOOK} (git rm).",
                found.join("; ")
            ),
        ));
    }
    out
}

/// `Ok(true)` — у `hooks.SessionStart[*].hooks[*].command` є `session-start.ps1` (без регістру); `Err` — назва
/// невідповідної структури (без цитування даних).
fn has_legacy_command(json: &Value) -> Result<bool, &'static str> {
    let Value::Object(root) = json else {
        return Err("корінь — не об'єкт");
    };
    let Some(hooks) = root.get("hooks").filter(|v| !v.is_null()) else {
        return Ok(false);
    };
    let Value::Object(hooks) = hooks else {
        return Err("hooks — не об'єкт");
    };
    let Some(start) = hooks.get("SessionStart").filter(|v| !v.is_null()) else {
        return Ok(false);
    };
    let Value::Array(entries) = start else {
        return Err("hooks.SessionStart — не масив");
    };
    let mut found = false;
    for entry in entries {
        let Value::Object(entry) = entry else {
            return Err("запис hooks.SessionStart — не об'єкт");
        };
        let Some(list) = entry.get("hooks").filter(|v| !v.is_null()) else {
            continue;
        };
        let Value::Array(list) = list else {
            return Err("hooks у записі hooks.SessionStart — не масив");
        };
        for hook in list {
            let Value::Object(hook) = hook else {
                return Err("хук у записі hooks.SessionStart — не об'єкт");
            };
            match hook.get("command") {
                None | Some(Value::Null) => {}
                Some(Value::String(c)) => {
                    if c.to_lowercase().contains("session-start.ps1") {
                        found = true;
                    }
                }
                Some(_) => return Err("command хука — не рядок"),
            }
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::hooks_path_is_default;
    use std::io;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    fn hang(_: &Path) -> io::Result<PathBuf> {
        std::thread::sleep(Duration::from_secs(3));
        Ok(PathBuf::new())
    }

    fn same(p: &Path) -> io::Result<PathBuf> {
        Ok(p.to_path_buf())
    }

    // Стеля розв'язання абсолютного `core.hooksPath`: недоступний мережевий шлях не вішає `check`; збіг рядків
    // мережі не потребує, а розв'язання, що вклалось, дає відповідь.
    #[test]
    fn absolute_hooks_path_resolution_has_a_ceiling_and_string_match_skips_it() {
        let root = Path::new("C:\\repo");
        let started = Instant::now();
        let r = hooks_path_is_default(root, r"\\srv\share\h", Duration::from_millis(100), hang);
        assert_eq!(r, Err(1));
        assert!(started.elapsed() < Duration::from_secs(2));
        // Збіг рядків — без звернення до розв'язувача (той висів би).
        let r = hooks_path_is_default(root, "C:/repo/.githooks/", Duration::from_millis(100), hang);
        assert_eq!(r, Ok(true));
        // Розв'язувач вклався: різні теки — «ні».
        let r = hooks_path_is_default(root, "C:\\other", Duration::from_secs(5), same);
        assert_eq!(r, Ok(false));
    }
}
