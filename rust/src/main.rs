// kit.exe — один вхід команд kit (ADR-0014): `kit <команда> [аргументи]`.
//
// Перенесені на Rust команди kit виконує сам; решту передає PowerShell-диспетчеру
// `<корінь плагіна>/tools/kit.ps1`. Токени йдуть НЕ аргументами `pwsh -File` (PowerShell сам
// розщеплює `-Ім'я:значення` і перетворює `-X:false` на `-X` + `False`), а JSON-масивом рядків у
// змінній оточення KIT_ARGV; диспетчер читає її й прибирає зі свого оточення. stdin, stdout і stderr
// успадковані, код диспетчера — код kit.exe.
//
// Коди (ADR-0014): 0 — так; 1 — зупинка; 2 — помилка виклику; 3 — не перевірено; 4 — виконано, є наступний
// крок. Помилка — перший рядок stderr `<команда>: ERROR …`.
//
// Перенесені команди: `session-board` (ADR-0014), `check` (блок B3: аудит репозиторію без PowerShell),
// `session-check` (блок B4: сигнал сховищ без PowerShell). Модулі `check.psm1` і `session-check.psm1` лишаються
// до видалення в задачі 4 блоку B4; хук старту сесії поки кличе PowerShell-диспетчер напряму (задача 3).
//
// Приховані підкоманди (не в довідці й не в переліку команд процесу): `source-fingerprint` — запобіжник
// «бінарник = джерело» (ADR-0014); `session-start` — хук SessionStart плагіна (`hooks/hooks.json`, ADR-0014);
// `subagent-start` — хук SubagentStart плагіна: специфіка 1С агентам процесу в репозиторіях 1С;
// `config-preflight` — префлайт конфігурації як JSON із маскою секретів (блок B1, живе, доки живе PowerShell-копія);
// `runner-exec <шлях раннера> <робоча тека> <аргумент>…` — запуск раннера Уніки для PowerShell до фази 3
// (ADR-0019): аргументи раннера дослівно, без розбору `cli::parse`, потоки успадковані, код — код раннера;
// `tool-verdicts [-InstalledPluginsPath p] [-RunnerPath p]` — вердикти версій Уніки й раннера одним JSON
// для `check-environment.ps1`.

mod fingerprint;
mod session_start;
mod subagent_start;

use kit::{check, cli, config, runner, session_board, session_check, unica};
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};

/// Відбиток джерел `rust/`, вбудований build.rs під час збірки (ADR-0014).
const EMBEDDED_FINGERPRINT: &str = env!("KIT_SOURCE_FINGERPRINT");

/// Прихована підкоманда запобіжника «бінарник = джерело»: не в довідці, не команда для людини.
const FINGERPRINT_COMMAND: &str = "source-fingerprint";

/// Імена команд — без регістру, як у диспетчері PowerShell (`-notcontains`): інакше `kit.exe Check` пішов би в
/// `pwsh` і виконав би старий PowerShell-`check` (з сирим шляхом сховища у виводі).
fn is_command(given: &str, name: &str) -> bool {
    given.eq_ignore_ascii_case(name)
}

fn fail(command: &str, message: &str, code: i32) -> ! {
    eprintln!("{command}: ERROR {message}");
    exit(code)
}

/// Корінь плагіна — батьківська тека теки бінарника (bin/kit.exe → корінь).
fn plugin_root() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("шлях kit.exe не визначено: {e}"))?;
    exe.parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| format!("у шляху {} немає теки над bin/", exe.display()))
}

fn print_help(root: Option<&Path>) {
    println!("usage: kit <команда> [аргументи]");
    let mut names: Vec<String> = root
        .and_then(|r| std::fs::read_dir(r.join("tools").join("commands")).ok())
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            e.file_name()
                .to_str()
                .and_then(|n| n.strip_suffix(".psm1"))
                .map(str::to_string)
        })
        .collect();
    // Команди, перенесені на Rust, модуля .psm1 не мають.
    names.push("session-board".to_string());
    // `check` і `session-check` поки мають і модулі .psm1 (їх видаляє задача 4 блоку B4) — без дубля в переліку.
    for ported in ["check", SESSION_CHECK_COMMAND] {
        if !names.iter().any(|n| n == ported) {
            names.push(ported.to_string());
        }
    }
    names.sort();
    if !names.is_empty() {
        println!("команди: {}", names.join(", "));
    }
    println!("довідка команди: kit <команда> -Help");
}

/// `kit source-fingerprint [<тека крейта>]`: вбудований відбиток і, якщо тека задана, обчислений з неї
/// з кількістю файлів. Запобіжник «бінарник = джерело» у Pester порівнює ці два рядки.
fn source_fingerprint(args: &[String]) -> i32 {
    println!("embedded {EMBEDDED_FINGERPRINT}");
    match args {
        [] => 0,
        [dir] => match fingerprint::source_fingerprint(Path::new(dir)) {
            Ok((hash, files)) => {
                println!("computed {hash:016x} {files}");
                0
            }
            Err(e) => fail(
                FINGERPRINT_COMMAND,
                &format!("відбиток {dir} не обчислено: {e}"),
                1,
            ),
        },
        _ => fail(FINGERPRINT_COMMAND, "очікувалась одна тека крейта", 2),
    }
}

/// Процес PowerShell-диспетчера з токенами в KIT_ARGV, ще не запущений: його запускає передача
/// команди (`dispatch`) і хук старту (`session_start`) — одне місце запуску `pwsh`.
pub(crate) fn dispatcher(root: &Path, tokens: &[String]) -> Result<Command, String> {
    let script = root.join("tools").join("kit.ps1");
    if !script.is_file() {
        return Err(format!("диспетчер {} не знайдено", script.display()));
    }
    let Some(pwsh) = kit::proc::find_program("pwsh") else {
        return Err("pwsh (PowerShell 7+) не знайдено в PATH".to_string());
    };
    let argv =
        serde_json::to_string(tokens).map_err(|e| format!("KIT_ARGV не серіалізовано: {e}"))?;
    let mut cmd = Command::new(&pwsh);
    cmd.arg("-NoProfile")
        .arg("-File")
        .arg(&script)
        .env("KIT_ARGV", argv);
    Ok(cmd)
}

/// Передача команди PowerShell-диспетчеру через KIT_ARGV (ADR-0014); код диспетчера — код kit.exe.
fn dispatch(root: &Path, tokens: &[String]) -> i32 {
    let mut cmd = dispatcher(root, tokens).unwrap_or_else(|e| fail("kit", &e, 1));
    match cmd.status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => fail(
            "kit",
            &format!(
                "{} не запустився: {e}",
                Path::new(cmd.get_program()).display()
            ),
            1,
        ),
    }
}

/// `kit config-preflight -RepoRoot <тека> [-Mode Strict|Lenient|Check] [-Workspace w] [-Source s] [-Truth t ...]`:
/// друкує JSON результату `config::preflight` (код 0, зупинка — поле `stop`); помилка виклику — код 2.
fn config_preflight(args: &[String]) -> i32 {
    const NAME: &str = "config-preflight";
    let spec = [
        ("RepoRoot", cli::Kind::Str),
        ("Mode", cli::Kind::Str),
        ("Workspace", cli::Kind::Str),
        ("Source", cli::Kind::Str),
        ("Truth", cli::Kind::List),
    ];
    let parsed = cli::parse(args, &spec).unwrap_or_else(|cli::UsageError(m)| fail(NAME, &m, 2));
    if !parsed.positional.is_empty() {
        fail(NAME, "позиційні аргументи не підтримуються", 2);
    }
    let text = |n: &str| match parsed.named.get(n) {
        Some(cli::Value::Str(s)) => Some(s.clone()),
        _ => None,
    };
    let Some(root) = text("RepoRoot") else {
        fail(NAME, "потрібен -RepoRoot", 2);
    };
    let mode = match text("Mode") {
        None => config::Mode::Strict,
        Some(m) => config::Mode::parse(&m)
            .unwrap_or_else(|| fail(NAME, "-Mode: Strict, Lenient або Check", 2)),
    };
    let truth = match parsed.named.get("Truth") {
        Some(cli::Value::List(l)) => l.clone(),
        _ => Vec::new(),
    };
    let report = config::preflight::report_json(
        Path::new(&root),
        mode,
        text("Workspace").as_deref(),
        text("Source").as_deref(),
        &truth,
    );
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{report}").and_then(|_| stdout.flush());
    0
}

/// Прихована підкоманда запуску раннера: два позиційні токени, далі аргументи раннера дослівно (вони можуть
/// бути `--config`, `--json-message`, `--version`, які `cli::parse` відхилив би). Код — код раннера; власна
/// помилка (раннера немає, не запустився) — `runner-exec: ERROR …` і код 1.
const RUNNER_EXEC_COMMAND: &str = "runner-exec";

fn runner_exec(args: &[OsString]) -> i32 {
    let [runner_path, cwd, rest @ ..] = args else {
        fail(
            RUNNER_EXEC_COMMAND,
            "очікувалось: <шлях раннера> <робоча тека> [аргумент…]",
            2,
        );
    };
    match runner::exec_inherit(Path::new(runner_path), Path::new(cwd), rest) {
        Ok(code) => code,
        Err(e) => fail(RUNNER_EXEC_COMMAND, &e.to_string(), 1),
    }
}

const VERDICTS_COMMAND: &str = "tool-verdicts";

/// `kit tool-verdicts [-InstalledPluginsPath p] [-RunnerPath p] [-RepoRoot p]`: один JSON з установленою Унікою й
/// вердиктами Уніки та раннера (без `-RepoRoot` — лише записи `scope: user`). Код 0, коли JSON
/// надруковано, зокрема на вердикті `error`.
fn tool_verdicts(args: &[String]) -> i32 {
    let spec = [
        ("InstalledPluginsPath", cli::Kind::Str),
        ("RunnerPath", cli::Kind::Str),
        ("RepoRoot", cli::Kind::Str),
    ];
    let parsed =
        cli::parse(args, &spec).unwrap_or_else(|cli::UsageError(m)| fail(VERDICTS_COMMAND, &m, 2));
    if parsed.help {
        println!(
            "usage: kit tool-verdicts [-InstalledPluginsPath <реєстр>] [-RunnerPath <раннер>] [-RepoRoot <корінь репозиторію>]"
        );
        return 0;
    }
    if !parsed.positional.is_empty() {
        fail(VERDICTS_COMMAND, "позиційних аргументів немає", 2);
    }
    let named = |n: &str| match parsed.named.get(n) {
        Some(cli::Value::Str(s)) if !s.is_empty() => Some(s.clone()),
        _ => None,
    };
    let registry = named("InstalledPluginsPath")
        .map(PathBuf::from)
        .or_else(unica::default_registry)
        .unwrap_or_else(|| {
            fail(
                VERDICTS_COMMAND,
                "домашню теку не визначено: вкажіть -InstalledPluginsPath",
                2,
            )
        });
    let repo_root = named("RepoRoot").map(PathBuf::from);
    let installation = unica::installation(&registry, repo_root.as_deref());
    let unica_verdict = unica::unica_verdict(&installation);
    let runner_path = named("RunnerPath").map(PathBuf::from);
    let runner_verdict =
        unica::runner_verdict(runner_path.as_deref(), &registry, repo_root.as_deref());
    let json = serde_json::json!({
        "unica": {
            "Installed": installation.installed,
            "Version": installation.version,
            "InstallPath": installation.install_path,
            "PathExists": installation.path_exists,
            "Reason": installation.reason,
            "Level": unica_verdict.level.as_str(),
            "Message": unica_verdict.message,
        },
        "runner": {
            "Level": runner_verdict.level.as_str(),
            "Message": runner_verdict.message,
            "Version": runner_verdict.version,
        },
    });
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{json}").and_then(|_| stdout.flush());
    0
}

const CHECK_COMMAND: &str = "check";

/// `kit check [-RepoRoot p] [-Workspace w] [-Source s] [-InstalledPluginsPath p] [-RunnerPath p] [-Quiet]`
/// (блок B3): префлайт `Mode::Check` → `check::run` → друк. Коди: 0/1/3 — звіт; 2 — помилка виклику;
/// зупинка префлайту (корінь не існує чи не git) — `check: ERROR …`, код 1, як у диспетчері.
fn check_command(args: &[String]) -> i32 {
    let spec = [
        ("RepoRoot", cli::Kind::Str),
        ("Workspace", cli::Kind::Str),
        ("Source", cli::Kind::Str),
        ("InstalledPluginsPath", cli::Kind::Str),
        ("RunnerPath", cli::Kind::Str),
        ("Quiet", cli::Kind::Switch),
    ];
    let parsed =
        cli::parse(args, &spec).unwrap_or_else(|cli::UsageError(m)| fail(CHECK_COMMAND, &m, 2));
    if parsed.help {
        println!(
            "usage: kit check [-InstalledPluginsPath <значення>] [-Quiet] [-RepoRoot <значення>] [-RunnerPath <значення>] [-Source <значення>] [-Workspace <значення>]"
        );
        return 0;
    }
    if let Some(first) = parsed.positional.first() {
        fail(
            CHECK_COMMAND,
            &format!(
                "позиційний токен '{first}': команди сховища приймають лише -Ім'я значення і -Прапорець (pwsh -File розщеплює -Ім'я:значення на два токени — пиши -Ім'я значення)"
            ),
            2,
        );
    }
    let text = |n: &str| match parsed.named.get(n) {
        Some(cli::Value::Str(s)) => Some(s.clone()),
        _ => None,
    };
    let quiet = matches!(parsed.named.get("Quiet"), Some(cli::Value::Switch(true)));
    let registry = text("InstalledPluginsPath")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(unica::default_registry)
        .unwrap_or_else(|| {
            fail(
                CHECK_COMMAND,
                "домашню теку не визначено: вкажіть -InstalledPluginsPath",
                2,
            )
        });
    let repo_root = match text("RepoRoot") {
        Some(r) => PathBuf::from(r),
        None => std::env::current_dir()
            .unwrap_or_else(|e| fail(CHECK_COMMAND, &format!("поточна тека не визначена: {e}"), 1)),
    };
    let ctx = config::preflight(&repo_root, config::Mode::Check)
        .unwrap_or_else(|stop| fail(CHECK_COMMAND, &stop.message, 1));
    let opts = check::Options {
        workspace: text("Workspace"),
        source: text("Source"),
        registry,
        runner: text("RunnerPath")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from),
    };
    let report =
        check::run(&ctx, &opts).unwrap_or_else(|check::UsageError(m)| fail(CHECK_COMMAND, &m, 2));
    if !quiet {
        check::print(&report, Path::new(&ctx.repo_root));
        let _ = std::io::stdout().flush();
    }
    report.code
}

const SESSION_CHECK_COMMAND: &str = "session-check";

/// `kit session-check [-RepoRoot p] [-Workspace w] [-Source s] [-AsJson] [-InstalledPluginsPath p] [-RunnerPath p]`
/// (блок B4): префлайт `Mode::Lenient` → `check::run` → сигнали джерел `truth: storage`. Коди — шапка модуля
/// `session_check::command`; виклик (рішення 18): невідомий параметр (зокрема `-Apply`) — 2, `-Help` — 0, корінь не
/// існує чи не git — `session-check: ERROR …`, код 1.
fn session_check_command(args: &[String]) -> i32 {
    const NAME: &str = SESSION_CHECK_COMMAND;
    let spec = [
        ("RepoRoot", cli::Kind::Str),
        ("Workspace", cli::Kind::Str),
        ("Source", cli::Kind::Str),
        ("AsJson", cli::Kind::Switch),
        ("InstalledPluginsPath", cli::Kind::Str),
        ("RunnerPath", cli::Kind::Str),
    ];
    let parsed = cli::parse(args, &spec).unwrap_or_else(|cli::UsageError(m)| fail(NAME, &m, 2));
    if parsed.help {
        println!(
            "usage: kit session-check [-AsJson] [-InstalledPluginsPath <значення>] [-RepoRoot <значення>] [-RunnerPath <значення>] [-Source <значення>] [-Workspace <значення>]"
        );
        return 0;
    }
    if let Some(first) = parsed.positional.first() {
        fail(
            NAME,
            &format!(
                "позиційний токен '{first}': команди сховища приймають лише -Ім'я значення і -Прапорець (pwsh -File розщеплює -Ім'я:значення на два токени — пиши -Ім'я значення)"
            ),
            2,
        );
    }
    let text = |n: &str| match parsed.named.get(n) {
        Some(cli::Value::Str(s)) => Some(s.clone()),
        _ => None,
    };
    let as_json = matches!(parsed.named.get("AsJson"), Some(cli::Value::Switch(true)));
    let registry = text("InstalledPluginsPath")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(unica::default_registry)
        .unwrap_or_else(|| {
            fail(
                NAME,
                "домашню теку не визначено: вкажіть -InstalledPluginsPath",
                2,
            )
        });
    let repo_root = match text("RepoRoot") {
        Some(r) => PathBuf::from(r),
        None => std::env::current_dir()
            .unwrap_or_else(|e| fail(NAME, &format!("поточна тека не визначена: {e}"), 1)),
    };
    let ctx = config::preflight(&repo_root, config::Mode::Lenient)
        .unwrap_or_else(|stop| fail(NAME, &stop.message, 1));
    let opts = session_check::command::Options {
        check: check::Options {
            workspace: text("Workspace"),
            source: text("Source"),
            registry,
            runner: text("RunnerPath")
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
        },
        as_json,
    };
    let mut stdout = std::io::stdout().lock();
    session_check::command::run(&ctx, &opts, &mut stdout)
        .unwrap_or_else(|check::UsageError(m)| fail(NAME, &m, 2))
}

fn main() {
    kit::install_panic_hook();
    let raw: Vec<OsString> = std::env::args_os().skip(1).collect();
    if raw
        .first()
        .and_then(|a| a.to_str())
        .is_some_and(|a| is_command(a, RUNNER_EXEC_COMMAND))
    {
        exit(runner_exec(&raw[1..]));
    }
    let mut tokens = Vec::new();
    for a in raw {
        match a.into_string() {
            Ok(s) => tokens.push(s),
            Err(raw) => fail(
                "kit",
                &format!("аргумент {raw:?} — не коректний Unicode"),
                2,
            ),
        }
    }
    let Some(command) = tokens.first().cloned() else {
        fail(
            "kit",
            "команду не вказано; usage: kit <команда> [аргументи] (kit -Help)",
            2,
        );
    };
    if is_command(&command, FINGERPRINT_COMMAND) {
        exit(source_fingerprint(&tokens[1..]));
    }
    if is_command(&command, VERDICTS_COMMAND) {
        exit(tool_verdicts(&tokens[1..]));
    }
    if is_command(&command, session_start::COMMAND) {
        // Хук старту сесії (ADR-0014): код 0 завжди, вивід — одним записом або жодного.
        let out = plugin_root()
            .ok()
            .and_then(|root| session_start::run(&root));
        if let Some(text) = out {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout
                .write_all(text.as_bytes())
                .and_then(|_| stdout.flush());
        }
        exit(0);
    }
    if is_command(&command, subagent_start::COMMAND) {
        // Хук SubagentStart: код 0 завжди, вивід — одним записом або жодного (блокувати хук не може).
        let out = plugin_root()
            .ok()
            .and_then(|root| subagent_start::run_stdin(&root));
        if let Some(text) = out {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout
                .write_all(text.as_bytes())
                .and_then(|_| stdout.flush());
        }
        exit(0);
    }
    if is_command(&command, "config-preflight") {
        exit(config_preflight(&tokens[1..]));
    }
    if is_command(&command, CHECK_COMMAND) {
        exit(check_command(&tokens[1..]));
    }
    if is_command(&command, SESSION_CHECK_COMMAND) {
        exit(session_check_command(&tokens[1..]));
    }
    if is_command(&command, "session-board") {
        // Перенесена команда (ADR-0014): вивід і код — як у PowerShell-версії, байти без перетворень.
        let cwd = std::env::current_dir().unwrap_or_else(|e| {
            fail(
                "session-board",
                &format!("поточна тека не визначена: {e}"),
                1,
            )
        });
        let o = session_board::run(&tokens[1..], &cwd);
        let mut stdout = std::io::stdout().lock();
        let _ = stdout
            .write_all(o.stdout.as_bytes())
            .and_then(|_| stdout.flush());
        let mut stderr = std::io::stderr().lock();
        let _ = stderr
            .write_all(o.stderr.as_bytes())
            .and_then(|_| stderr.flush());
        exit(o.code);
    }
    let root = plugin_root();
    // Параметр замість команди: довідка чи помилка виклику — та сама форма розбору, що в команд.
    if command.starts_with('-') {
        match cli::parse(&tokens[..1], &[]) {
            Ok(p) if p.help => {
                print_help(root.as_deref().ok());
                exit(0);
            }
            Ok(_) => {}
            Err(cli::UsageError(msg)) => fail(
                "kit",
                &format!("{msg}; usage: kit <команда> [аргументи]"),
                2,
            ),
        }
    }
    let root = root.unwrap_or_else(|e| fail("kit", &e, 1));
    exit(dispatch(&root, &tokens));
}
