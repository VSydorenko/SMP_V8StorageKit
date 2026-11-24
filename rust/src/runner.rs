// Раннер Уніки (v8-runner) як інструмент kit (ADR-0019): ЄДИНЕ місце, де Rust-код kit будує шлях раннера й
// запускає його процес; поза цим модулем запуск раннера ловить запобіжник rust/tests/git_guard.rs.
//
// Шлях раннера — лише з `install_path` установленої Уніки (`installed_runner`) або з явного параметра;
// з маніфесту, накладки й оточення — ніколи. Динамічний `Command::new` у модулі один — приватна функція
// `runner_command`; `exec`, `exec_inherit` і `run` ідуть через неї. Код виходу раннера, `ok` і `error`
// конверта kit не перетлумачує, вивід не маскує. Тексти помилок — ті самі, що в `Runner.psm1`.

use crate::{proc, unica};
use serde_json::Value;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Сирий результат запуску: код і дослівний вивід (UTF-8 із заміною непридатних байтів).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Помилка конверта раннера (`error` відповіді): поля дослівно, без перетлумачення.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeError {
    pub code: Option<String>,
    pub kind: Option<String>,
    pub message: Option<String>,
}

/// Конверт відповіді раннера (`--json-message`): поля без перетлумачення, `raw` — вся відповідь.
#[derive(Debug, Clone, PartialEq)]
pub struct Envelope {
    pub exit_code: i32,
    pub ok: bool,
    pub command: Option<String>,
    pub data: Value,
    pub warnings: Vec<Value>,
    pub error: Option<EnvelopeError>,
    pub raw: Value,
}

#[derive(Debug)]
pub enum RunError {
    /// Файла раннера немає.
    NotFound(String),
    /// Раннер не запустився.
    Spawn { runner: String, message: String },
    /// Стеля часу: процес убито; вивід — те, що встигло прийти.
    Timeout {
        runner: String,
        seconds: u64,
        stdout: String,
        stderr: String,
    },
    /// Відповідь не JSON.
    NotJson {
        args: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    /// JSON без поля `ok` (чи `ok` не логічне).
    NoOk {
        args: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
}

impl fmt::Display for RunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RunError::NotFound(path) => write!(f, "Раннер не знайдено: {path}"),
            RunError::Spawn { runner, message } => {
                write!(f, "Раннер {runner} не запустився: {message}")
            }
            RunError::Timeout {
                runner,
                seconds,
                stdout,
                stderr,
            } => write!(
                f,
                "Раннер {runner}: стеля часу {seconds} с, процес убито; вивід, що встиг прийти: {} {}",
                stdout.trim(),
                stderr.trim()
            ),
            RunError::NotJson {
                args,
                exit_code,
                stdout,
                stderr,
            } => write!(
                f,
                "Раннер на '{args}' відповів не JSON-ом: код виходу {exit_code}, вивід: {} {}",
                stdout.trim(),
                stderr.trim()
            ),
            RunError::NoOk { args, stdout, .. } => write!(
                f,
                "Відповідь раннера на '{args}' без поля ok: {}",
                stdout.trim()
            ),
        }
    }
}

impl std::error::Error for RunError {}

/// Єдине місце, де будується процес раннера: перевірка наявності й програма. Шлях без теки (голе ім'я)
/// `Command::new` на Windows шукав би в PATH, теці `kit.exe` і системних теках, а `is_file()` дивився б у
/// поточну теку: перевірявся б один файл, запускався інший. Тож шлях стає абсолютним до перевірки, і
/// запускається саме той файл, що перевірений. Помилка `NotFound` несе шлях, як його передав викликач.
fn runner_command<I, S>(runner: &Path, cwd: &Path, args: I) -> Result<Command, RunError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let absolute = std::path::absolute(runner).unwrap_or_else(|_| runner.to_path_buf());
    if !absolute.is_file() {
        return Err(RunError::NotFound(runner.display().to_string()));
    }
    let mut cmd = Command::new(absolute);
    cmd.args(args).current_dir(cwd);
    Ok(cmd)
}

/// Шлях раннера в установленій Уніці (`Get-KitRunnerPath`): єдине місце, що будує його з `install_path`.
pub fn installed_runner(registry: &Path, repo_root: Option<&Path>) -> Result<PathBuf, String> {
    let u = unica::installation(registry, repo_root);
    if u.candidates.len() > 1 {
        return Err(format!("Раннер не знайдено: {}", u.reason));
    }
    if !u.installed {
        return Err(format!(
            "Раннер не знайдено: Unica не встановлена. {}",
            u.reason
        ));
    }
    if !u.path_exists {
        return Err(format!("Раннер не знайдено: {}", u.reason));
    }
    let runner = Path::new(&u.install_path)
        .join("bin")
        .join("win-x64")
        .join("v8-runner-windows-x86_64")
        .join("v8-runner.exe");
    if !runner.is_file() {
        return Err(format!(
            "Раннер не знайдено: у встановленій Уніці ({}) немає файла {}",
            u.install_path,
            runner.display()
        ));
    }
    Ok(runner)
}

/// Читання каналу потоком із накопиченням у спільний буфер: вивід, що вже прийшов, доступний і тоді, коли
/// канал не закрився (онук тримає його після виходу процесу).
struct Drain {
    buf: Arc<Mutex<Vec<u8>>>,
    handle: std::thread::JoinHandle<()>,
}

fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> Drain {
    let buf = Arc::new(Mutex::new(Vec::new()));
    let shared = Arc::clone(&buf);
    let handle = std::thread::spawn(move || {
        let Some(mut p) = pipe else { return };
        let mut chunk = [0u8; 8192];
        while let Ok(n) = p.read(&mut chunk) {
            if n == 0 {
                break;
            }
            shared
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .extend_from_slice(&chunk[..n]);
        }
    });
    Drain { buf, handle }
}

impl Drain {
    /// Чекає EOF каналу не довше `until` (без межі — до EOF) і віддає накопичене.
    fn finish(self, until: Option<Instant>) -> String {
        while !self.handle.is_finished() && until.is_none_or(|u| Instant::now() < u) {
            std::thread::sleep(Duration::from_millis(5));
        }
        let bytes = self.buf.lock().unwrap_or_else(|e| e.into_inner()).clone();
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

/// Скільки чекати EOF каналів після вбивства дерева за стелею.
const KILL_GRACE: Duration = Duration::from_secs(1);

fn describe(args: &[&OsStr]) -> String {
    args.iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Сирий запуск без `--config`: stdin закритий, stdout і stderr читаються потоками до очікування (без
/// дедлоку на великому виводі). Стеля часу — `proc::kill_tree` і `RunError::Timeout`.
pub fn exec(
    runner: &Path,
    cwd: &Path,
    args: &[&OsStr],
    timeout: Option<Duration>,
) -> Result<RawOutput, RunError> {
    let mut cmd = runner_command(runner, cwd, args)?;
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| RunError::Spawn {
        runner: runner.display().to_string(),
        message: e.to_string(),
    })?;
    let out = drain(child.stdout.take());
    let err = drain(child.stderr.take());
    let deadline = timeout.map(|t| Instant::now() + t);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Ok(s),
            Ok(None) if deadline.is_some_and(|d| Instant::now() >= d) => break Err(None),
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => break Err(Some(e)),
        }
    };
    match status {
        // Очікування каналів після виходу обмежене рештою стелі: онук, що успадкував канали, не тримає виклик.
        Ok(s) => Ok(RawOutput {
            exit_code: s.code().unwrap_or(-1),
            stdout: out.finish(deadline),
            stderr: err.finish(deadline),
        }),
        Err(cause) => {
            proc::kill_tree(&mut child);
            let until = Some(Instant::now() + KILL_GRACE);
            let (stdout, stderr) = (out.finish(until), err.finish(until));
            match cause {
                None => Err(RunError::Timeout {
                    runner: runner.display().to_string(),
                    seconds: timeout.map_or(0, |t| t.as_secs()),
                    stdout,
                    stderr,
                }),
                Some(e) => Err(RunError::Spawn {
                    runner: runner.display().to_string(),
                    message: e.to_string(),
                }),
            }
        }
    }
}

/// Запуск з успадкованими stdin, stdout і stderr (`kit runner-exec`): байти йдуть без перетворень, код —
/// код раннера.
pub fn exec_inherit(runner: &Path, cwd: &Path, args: &[OsString]) -> Result<i32, RunError> {
    let mut cmd = runner_command(runner, cwd, args)?;
    cmd.stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    let status = cmd.status().map_err(|e| RunError::Spawn {
        runner: runner.display().to_string(),
        message: e.to_string(),
    })?;
    Ok(status.code().unwrap_or(1))
}

/// Запуск з `--config <workspace_dir>/v8project.yaml`, аргументами й `--json-message`; робоча тека —
/// `workspace_dir`. Успіх — поле `ok` конверта, а не код виходу (`Invoke-KitRunner`).
pub fn run(
    runner: &Path,
    workspace_dir: &Path,
    args: &[&OsStr],
    timeout: Option<Duration>,
) -> Result<Envelope, RunError> {
    let config = workspace_dir.join("v8project.yaml").into_os_string();
    let mut all: Vec<&OsStr> = vec![OsStr::new("--config"), &config];
    all.extend_from_slice(args);
    all.push(OsStr::new("--json-message"));
    let raw = exec(runner, workspace_dir, &all, timeout)?;
    let shown = describe(args);
    let RawOutput {
        exit_code,
        stdout,
        stderr,
    } = raw;
    let text = stdout.strip_prefix('\u{feff}').unwrap_or(&stdout).trim();
    let Ok(json) = serde_json::from_str::<Value>(text) else {
        return Err(RunError::NotJson {
            args: shown,
            exit_code,
            stdout,
            stderr,
        });
    };
    let Some(ok) = json.get("ok").and_then(Value::as_bool) else {
        return Err(RunError::NoOk {
            args: shown,
            exit_code,
            stdout,
            stderr,
        });
    };
    let field = |v: &Value, name: &str| match v.get(name) {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Null) | None => None,
        Some(other) => Some(other.to_string()),
    };
    Ok(Envelope {
        exit_code,
        ok,
        command: field(&json, "command"),
        data: json.get("data").cloned().unwrap_or(Value::Null),
        warnings: match json.get("warnings") {
            Some(Value::Array(a)) => a.clone(),
            _ => Vec::new(),
        },
        error: match json.get("error") {
            Some(e @ Value::Object(_)) => Some(EnvelopeError {
                code: field(e, "code"),
                kind: field(e, "kind"),
                message: field(e, "message"),
            }),
            _ => None,
        },
        raw: json,
    })
}

/// Версія з виводу `--version`: рядок `v8-runner <версія>` (`(?m)^v8-runner\s+(?<v>\d+(?:\.\d+)+\S*)\s*$`).
fn parse_version(stdout: &str) -> Option<String> {
    stdout.split('\n').find_map(|line| {
        let rest = line.strip_prefix("v8-runner")?;
        let token = rest.trim_start();
        if token.len() == rest.len() {
            return None; // \s+ — хоча б один пробіл
        }
        let token = token.trim_end();
        let digits = |s: &str| s.bytes().take_while(u8::is_ascii_digit).count();
        let first = digits(token);
        let ok = first > 0
            && !token.contains(char::is_whitespace)
            && token[first..]
                .strip_prefix('.')
                .is_some_and(|t| digits(t) > 0);
        ok.then(|| token.to_string())
    })
}

/// Стеля `--version`: виміряно 13-33 мс (2026-11-24); запас понад сто разів і вкладається в стелю хука 15 с.
const VERSION_TIMEOUT: Duration = Duration::from_secs(5);

/// Версія раннера з `--version` (`Get-KitRunnerVersion`): з `v8-runner 0.18.1` береться `0.18.1`.
pub fn version(runner: &Path) -> Result<String, String> {
    let o = exec(
        runner,
        Path::new("."),
        &[OsStr::new("--version")],
        Some(VERSION_TIMEOUT),
    )
    .map_err(|e| match e {
        // Раннер є, але не відповідає: текст іде в вердикт `runner-version` (error), не в «не перевірено».
        RunError::Timeout { seconds, .. } => format!(
            "раннер не відповів на --version за {seconds} с, процес убито: {}",
            runner.display()
        ),
        other => other.to_string(),
    })?;
    parse_version(&o.stdout).ok_or_else(|| {
        format!(
            "Раннер {} на --version відповів не рядком 'v8-runner <версія>': код виходу {}, вивід: {} {}",
            runner.display(),
            o.exit_code,
            o.stdout.trim(),
            o.stderr.trim()
        )
    })
}
