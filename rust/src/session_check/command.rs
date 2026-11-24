// `kit session-check`: дешевий сигнал для старту сесії — без платформи, без ліцензії, без мережі, без запису.
// Спершу повний `check` тим самим контекстом (`check::run`, нічого не друкуючи): error поза
// `check::MACHINE_STATE_CHECKS` — код 1 і сигнали не обчислюються (на `storage/*` з чужим комітом дата дзеркала
// нічого не означає); знахідки стану машини (Уніка, її раннер) сигналів не блокують і друкуються поряд із ними.
// Далі для кожного джерела `truth: storage` — сигнал (`signal::compute`): усі читання сховищ стартують разом
// (`start_reading`, кожне зі стелею 5 с), а рядок джерела друкується, щойно його читання готове, у порядку
// маніфесту ; `next:` — останнім.
//
// Коди (ADR-0021 п. 2, пріоритет 1 > 3 > 4 > 0): 1 — блокувальна помилка `check` чи `GitProblem` джерела;
// 3 — `partial-read` джерела або `check` дав «не перевірено» (стан не зелений); 4 — є крок (`NewInStorage` чи
// незлиті коміти); 0 — інакше. Серверне сховище (`server`) і сховище, що не відповіло, — стан машини, код 0.

use super::activity::{PendingReading, start_reading};
use super::signal::{Computed, SourceInput, compute};
use crate::check::{self, MACHINE_STATE_CHECKS};
use crate::config::{Context, Level, Truth, select_sources};
use std::io::Write;

/// Параметри виклику.
#[derive(Debug, Clone)]
pub struct Options {
    pub check: check::Options,
    pub as_json: bool,
}

fn header(ctx: &Context) -> String {
    match (&ctx.kind, &ctx.label) {
        (Some(kind), Some(label)) => format!("session-check — {} {label}", kind.as_str()),
        // Маніфесту не прочитано: без порожнього хвоста «—».
        _ => "session-check".to_string(),
    }
}

fn put(out: &mut dyn Write, line: &str) {
    // Помилка запису (закритий канал) нічого не змінює: код виходу від виводу не залежить.
    let _ = writeln!(out, "{line}").and_then(|()| out.flush());
}

/// Виконує команду: друкує в `out`, повертає код виходу. `Err` — лише помилка виклику (код 2).
pub fn run(ctx: &Context, opts: &Options, out: &mut dyn Write) -> Result<i32, check::UsageError> {
    let report = check::run(ctx, &opts.check)?;
    let is_machine = |f: &crate::config::Finding| MACHINE_STATE_CHECKS.contains(&f.check.as_str());
    let errors: Vec<_> = report
        .findings
        .iter()
        .filter(|f| f.level == Level::Error)
        .collect();
    let blocking = errors.iter().any(|f| !is_machine(f));
    // «Не перевірено» друкується завжди; решта warn — крім `storage-path`: недоступний каталог описує
    // сигнал джерела з порадою про накладку.
    let unchecked = |f: &crate::config::Finding| report.not_checked.contains(f);
    let warns: Vec<_> = report
        .findings
        .iter()
        .filter(|f| f.level == Level::Warn && (f.check != "storage-path" || unchecked(f)))
        .collect();

    if blocking {
        if opts.as_json {
            put(out, "[]");
        } else {
            put(out, &header(ctx));
            for e in &errors {
                put(out, &format!("[-] {}", e.message));
            }
            for w in &warns {
                if unchecked(w) {
                    put(out, &format!("[!] {}", w.message));
                }
            }
            put(
                out,
                "Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.",
            );
            put(out, "next: kit check");
        }
        return Ok(1);
    }

    let sources = select_sources(
        ctx,
        opts.check.workspace.as_deref(),
        opts.check.source.as_deref(),
        &[Truth::Storage],
    )
    .map_err(check::UsageError)?;
    // Усі читання стартують разом, до першого очікування: стеля кожного рахується від його старту.
    let pending: Vec<PendingReading> = sources
        .iter()
        .map(|s| start_reading(s.storage_path.as_deref().unwrap_or("")))
        .collect();

    if !opts.as_json {
        put(out, &header(ctx));
        for e in errors.iter().filter(|f| is_machine(f)) {
            put(out, &format!("[-] {}", e.message));
        }
        for i in report
            .findings
            .iter()
            .filter(|f| f.level == Level::Info && f.check == "main-branch")
        {
            put(out, &format!("[i] {}", i.message));
        }
        for w in &warns {
            put(out, &format!("[!] {}", w.message));
        }
        if sources.is_empty() {
            put(out, "- джерел truth: storage у маніфесті немає.");
        }
    }

    let root = std::path::Path::new(&ctx.repo_root);
    let mut computed: Vec<Computed> = Vec::new();
    for (src, reading) in sources.iter().zip(pending) {
        let reading = reading.wait();
        let branch = src
            .branch
            .clone()
            .unwrap_or_else(|| format!("storage/{}", src.key));
        let input = SourceInput {
            repo_root: root,
            key: &src.key,
            branch: &branch,
            storage_path: src.storage_path.as_deref().unwrap_or(""),
            main_branch: &ctx.main_branch,
        };
        let c = compute(&input, &reading);
        if !opts.as_json {
            put(out, &c.signal.text);
            // Відставання від origin — окремим рядком лише в людському виводі; у JSON це поле `OriginGap`.
            if let Some(gap) = c.signal.origin_gap.filter(|g| g.has_remote && g.behind > 0) {
                put(
                    out,
                    &format!(
                        "- {}: локальна гілка {} позаду origin на {} комітів — git fetch",
                        c.signal.key, c.signal.branch, gap.behind
                    ),
                );
            }
        }
        computed.push(c);
    }

    if opts.as_json {
        let signals: Vec<_> = computed.iter().map(|c| &c.signal).collect();
        // Серіалізація власної структури без ключів-мап не падає; запасний `[]` лише для повноти.
        let text = serde_json::to_string_pretty(&signals).unwrap_or_else(|_| "[]".to_string());
        put(out, &text);
    } else if let Some(step) = computed.iter().find_map(|c| c.step.as_deref()) {
        put(out, &format!("next: {step}"));
    }

    let code = if computed.iter().any(|c| c.signal.git_problem.is_some()) {
        1
    } else if computed.iter().any(|c| c.partial) || !report.not_checked.is_empty() {
        3
    } else if computed
        .iter()
        .any(|c| c.signal.new_in_storage || c.signal.unmerged_commits > 0)
    {
        4
    } else {
        0
    };
    Ok(code)
}
