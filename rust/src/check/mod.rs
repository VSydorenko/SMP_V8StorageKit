// `kit check` (фаза 2, блок B3): повний аудит репозиторію-споживача без PowerShell. Нічого не змінює: читає
// файли, git (лише ядро `git`), раннер (лише модуль `runner`) і реєстр плагінів (`unica`).
//
// `run` повертає звіт — знахідки в порядку виконання, перелік «не перевірено» і код; `print` друкує звіт окремо
// (`-Quiet` = без друку). Знахідки ідуть у порядку PowerShell-версії `Invoke-KitCheck`
// (tools/commands/check.psm1): машина → маніфест → воркспейси.
//
// Коди (рішення 2 плану B3): 0 — немає error і немає «не перевірено»; 1 — є error; 3 — немає error, але є
// «не перевірено»; 2 — помилка виклику (`UsageError`, ім'я поза маніфестом). «Не перевірено» — ознака знахідки
// (`not_checked`) з текстом «не перевірено: <що> — <причина>» і ідентифікатором перевірки: перевірку треба було
// виконати, а вона не вдалася. Рівень звичайної знахідки — warn; для стражів секрету — error (код 1). «Не застосовується» (немає джерел потрібного `truth`, немає `HEAD`) — не код 3.
//
// Відомі відмінності від PowerShell (ADR-0014 п. 7; кожна — рішення плану B3): 2 (код 3), 3 (код 2 на імені поза
// маніфестом), 4 (стеля `runner::version`), 5 (збій git ≠ «немає»), 9 (scope Уніки), 10 (`unique-keys` без
// регістру), 11 (одна `agent-base-required` на воркспейс).

mod gitq;
mod guards;
mod hooks;
mod local;
mod machine;
mod sources;
mod workspaces;

use crate::config::{Context, Finding, Level, Source, manifest::Manifest, yaml::eq_ci};
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Перевірки стану машини, а не репозиторію: сигнали `session-check` їх не блокують (рішення 16).
pub const MACHINE_STATE_CHECKS: &[&str] = &["runner-version", "unica-version"];

/// Параметри виклику.
#[derive(Debug, Clone)]
pub struct Options {
    pub workspace: Option<String>,
    pub source: Option<String>,
    /// Реєстр плагінів машини, де шукається Уніка.
    pub registry: PathBuf,
    /// Явний шлях раннера; `None` — з установленої Уніки (того самого реєстру).
    pub runner: Option<PathBuf>,
}

/// Помилка виклику (код 2): ім'я воркспейсу чи джерела поза маніфестом, неоднозначний ключ.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageError(pub String);

impl fmt::Display for UsageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for UsageError {}

/// Результат `check`: знахідки в порядку виконання, повні знахідки «не перевірено» (їх належність до списку — ознака; код рахується з нього) і код виходу.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub findings: Vec<Finding>,
    pub not_checked: Vec<Finding>,
    pub code: i32,
}

/// Стеля проби мережевого ресурсу (каталог сховища, `core.hooksPath`; рішення 4): кожна проба має свою.
pub(crate) const PROBE_CEILING: Duration = Duration::from_secs(5);

enum Probe {
    Pending(crate::ceiling::Pending<bool>),
    Done(Option<bool>),
}

/// Проби каталогів: стартують усі заздалегідь і йдуть паралельно (кожна зі стелею від свого старту), а знахідки
/// збираються в порядку перевірок. Проба на стелі лишає потік, заблокований на ОС; вихід процесу його не чекає.
#[derive(Default)]
pub(crate) struct DirProbes {
    map: HashMap<String, Probe>,
}

impl DirProbes {
    /// Стартує пробу шляху, якщо її ще немає.
    pub fn start<F>(&mut self, path: &str, ceiling: Duration, probe: F)
    where
        F: FnOnce(&str) -> bool + Send + 'static,
    {
        if !self.map.contains_key(path) {
            let owned = path.to_string();
            let pending = crate::ceiling::start(ceiling, move || probe(&owned));
            self.map.insert(path.to_string(), Probe::Pending(pending));
        }
    }

    /// Результат проби (стартує її, якщо заздалегідь не стартувала): `None` — не вклалась у стелю.
    pub fn wait<F>(&mut self, path: &str, ceiling: Duration, probe: F) -> Option<bool>
    where
        F: FnOnce(&str) -> bool + Send + 'static,
    {
        self.start(path, ceiling, probe);
        match self.map.remove(path) {
            Some(Probe::Pending(p)) => {
                let r = p.wait();
                self.map.insert(path.to_string(), Probe::Done(r));
                r
            }
            Some(Probe::Done(r)) => {
                self.map.insert(path.to_string(), Probe::Done(r));
                r
            }
            None => None,
        }
    }
}

/// Збирач знахідок: єдине місце, де народжується «не перевірено».
pub(crate) struct Collector {
    pub findings: Vec<Finding>,
    pub not_checked: Vec<Finding>,
    /// Індекс і неігноровані файли читаються один раз за прогін.
    index: Option<Result<Vec<String>, String>>,
    unignored: Option<Result<Vec<String>, String>>,
    /// Усі шляхи `HEAD` (без pathspec: він чутливий до регістру), теж один раз за прогін.
    head: Option<Result<Vec<String>, String>>,
    /// Мережеві проби, що стартували заздалегідь (паралельно).
    pub probes: DirProbes,
    pub hooks_prefetch: Option<crate::hooks::HooksPrefetch>,
    pub probes_seam: Probes,
}

impl Collector {
    /// Відстежувані файли під шляхом (файл чи тека), регістр складається як у NTFS.
    pub fn tracked(&mut self, root: &Path, path: &str) -> Result<Vec<String>, String> {
        let list = self
            .index
            .get_or_insert_with(|| gitq::index_files(root))
            .as_ref()
            .map_err(Clone::clone)?;
        gitq::under_ci(list, path)
    }

    /// Неігноровані файли на диску під шляхом: правило, що «ігнорує» канонічне ім'я, може не ловити файл в іншому
    /// регістрі.
    pub fn unignored(&mut self, root: &Path, path: &str) -> Result<Vec<String>, String> {
        let list = self
            .unignored
            .get_or_insert_with(|| gitq::unignored_files(root))
            .as_ref()
            .map_err(Clone::clone)?;
        gitq::under_ci(list, path)
    }

    /// Файли `HEAD` під шляхом без регістру (файл чи тека).
    pub fn head_under(&mut self, root: &Path, path: &str) -> Result<Vec<String>, String> {
        let list = self
            .head
            .get_or_insert_with(|| gitq::head_paths(root))
            .as_ref()
            .map_err(Clone::clone)?;
        gitq::under_ci(list, path)
    }

    pub fn add(&mut self, level: Level, check: &str, message: impl Into<String>) {
        self.findings.push(Finding {
            level,
            check: check.to_string(),
            message: message.into(),
        });
    }

    /// Те саме для СТРАЖІВ секрету (рішення 2): fail-closed, рівень error — код 1, а не 3. «Не перевірено» —
    /// властивість знахідки: вона й у `not_checked` (інваріант `not_checked ⊆ findings`).
    pub fn unchecked_error(&mut self, check: &str, what: &str, reason: &str) {
        let finding = Finding {
            level: Level::Error,
            check: check.to_string(),
            message: format!("не перевірено: {what} — {reason}"),
        };
        self.not_checked.push(finding.clone());
        self.findings.push(finding);
    }

    /// «не перевірено: <що> — <причина>»: warn з ідентифікатором перевірки й окремий запис для коду 3.
    pub fn unchecked(&mut self, check: &str, what: &str, reason: &str) {
        let finding = Finding {
            level: Level::Warn,
            check: check.to_string(),
            message: format!("не перевірено: {what} — {reason}"),
        };
        self.not_checked.push(finding.clone());
        self.findings.push(finding);
    }
}

/// Порядок імен у переліку «Є: …»: ординально в нижньому регістрі, при рівності — вихідні рядки; без дублів
/// без регістру (як `Select-KitSources` у `config`).
fn sorted_unique(mut items: Vec<String>) -> Vec<String> {
    items.sort_by(|a, b| {
        a.to_lowercase()
            .cmp(&b.to_lowercase())
            .then_with(|| a.cmp(b))
    });
    items.dedup_by(|a, b| eq_ci(a, b));
    items
}

/// Рішення 3: імена `-Workspace`/`-Source` звіряються з самим маніфестом, а не з розв'язаним контекстом
/// (воркспейс із помилкою конфігу в нього не потрапляє). Тексти — ті самі, що в `select_sources`.
fn validate_names(manifest: &Manifest, opts: &Options) -> Result<(), UsageError> {
    let workspace = opts.workspace.as_deref().filter(|w| !w.is_empty());
    let mut workspaces: Vec<_> = manifest.workspaces.iter().collect();
    if let Some(w) = workspace {
        let selected: Vec<_> = workspaces
            .iter()
            .copied()
            .filter(|x| eq_ci(&x.path, w))
            .collect();
        if selected.is_empty() {
            let names: Vec<&str> = workspaces.iter().map(|x| x.path.as_str()).collect();
            return Err(UsageError(format!(
                "Воркспейсу '{w}' немає в маніфесті. Є: {}.",
                names.join(", ")
            )));
        }
        workspaces = selected;
    }
    if let Some(s) = opts.source.as_deref().filter(|s| !s.is_empty()) {
        let matched: Vec<&str> = workspaces
            .iter()
            .flat_map(|w| {
                w.sources
                    .iter()
                    .filter(|x| eq_ci(&x.key, s))
                    .map(|_| w.path.as_str())
            })
            .collect();
        if matched.is_empty() {
            let scope = workspace
                .map(|w| format!("у воркспейсі '{w}'"))
                .unwrap_or_else(|| "у маніфесті".to_string());
            let keys = sorted_unique(
                workspaces
                    .iter()
                    .flat_map(|w| w.sources.iter().map(|x| x.key.clone()))
                    .collect(),
            );
            return Err(UsageError(format!(
                "Джерела '{s}' немає {scope}. Є: {}.",
                keys.join(", ")
            )));
        }
        if matched.len() > 1 {
            return Err(UsageError(format!(
                "Ключ '{s}' є у кількох воркспейсах: {} — уточніть -Workspace.",
                matched.join(", ")
            )));
        }
    }
    Ok(())
}

/// Джерела за `-Workspace`/`-Source` серед розв'язаних (після звірки імен з маніфестом). Воркспейс чи
/// джерело, що не розв'язалось, дає порожній вибір: їхня помилка вже є знахідкою префлайту.
fn selected_sources<'a>(ctx: &'a Context, opts: &Options) -> Vec<&'a Source> {
    crate::config::select_sources(ctx, opts.workspace.as_deref(), opts.source.as_deref(), &[])
        .unwrap_or_default()
}

/// Шов мережевих проб: як перевіряється каталог сховища і як розв'язується абсолютний `core.hooksPath`. У
/// виробництві — файлова система; тест підставляє повільні проби й міряє, що `run` стартує їх заздалегідь.
#[doc(hidden)]
#[derive(Clone, Copy)]
pub struct Probes {
    pub dir_exists: fn(&str) -> bool,
    pub canonicalize: fn(&Path) -> std::io::Result<PathBuf>,
}

impl Default for Probes {
    fn default() -> Self {
        Probes {
            dir_exists: sources::dir_exists,
            canonicalize: |p| std::fs::canonicalize(p),
        }
    }
}

/// Виконує всі перевірки. `Err` — лише помилка виклику (код 2).
pub fn run(ctx: &Context, opts: &Options) -> Result<Report, UsageError> {
    run_with(ctx, opts, Probes::default())
}

/// `run` із швом мережевих проб (лише для тестів).
#[doc(hidden)]
pub fn run_with(ctx: &Context, opts: &Options, seam: Probes) -> Result<Report, UsageError> {
    if let Some(manifest) = &ctx.manifest {
        validate_names(manifest, opts)?;
    }
    let mut c = Collector {
        findings: ctx.findings.clone(),
        not_checked: Vec::new(),
        index: None,
        unignored: None,
        head: None,
        probes: DirProbes::default(),
        hooks_prefetch: None,
        probes_seam: seam,
    };
    let root = Path::new(&ctx.repo_root);
    // Усі мережеві проби стартують разом; звіт збирається в порядку перевірок, а не завершення проб.
    c.hooks_prefetch = crate::hooks::prefetch_hooks_path(root, seam.canonicalize);
    sources::prefetch_storage_probes(&mut c, ctx, opts);

    machine::check(&mut c, opts, root);
    if let Some(manifest) = &ctx.manifest {
        workspaces::check(&mut c, ctx, manifest, opts);
    } else {
        // Рішення 6: страж файла з паролем не мовчить, коли конфіг зламаний.
        guards::overlay_ignored(&mut c, root);
        hooks::check(&mut c, root);
    }

    let has_error = c.findings.iter().any(|f| f.level == Level::Error);
    let code = if has_error {
        1
    } else if !c.not_checked.is_empty() {
        3
    } else {
        0
    };
    Ok(Report {
        findings: c.findings,
        not_checked: c.not_checked,
        code,
    })
}

/// Текстовий вивід: шапка, знахідки з маркерами `[-]/[!]/[i]`, підсумок.
pub fn print(report: &Report, root: &Path) {
    println!("kit check — {}", root.display());
    for f in &report.findings {
        let mark = match f.level {
            Level::Error => "[-]",
            Level::Warn => "[!]",
            Level::Info => "[i]",
        };
        println!("{mark} {}", f.message);
    }
    println!();
    let count = |l: Level| report.findings.iter().filter(|f| f.level == l).count();
    let (errors, warns) = (count(Level::Error), count(Level::Warn));
    let unchecked = if report.not_checked.is_empty() {
        String::new()
    } else {
        format!(", з них не перевірено: {}", report.not_checked.len())
    };
    if errors == 0 {
        println!("Помилок немає. Попереджень: {warns}{unchecked}.");
    } else {
        println!("Помилок: {errors}, попереджень: {warns}{unchecked}.");
    }
}
