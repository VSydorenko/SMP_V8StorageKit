// Хук старту сесії `kit.exe session-start` чорною скринькою (блок B4, задача 3): стеля часу дочірнього
// `session-check` і вбивство дерева процесів. Повільну дитину й онука дає фальшивий раннер (`fake-runner`):
// `session-check` питає його `--version` через реєстр Уніки домашньої теки (`unica::default_registry` читає
// `USERPROFILE` процесу хука). Файл `version-sleep.txt` — сон `--version` (менший за стелю раннера 5 с),
// `version-grandchild.txt` — онук (режим hold, 10 с), що успадковує канали раннера; його pid — `grandchild-pid.txt`.
//
// Тут, а не в Pester: `fake-runner` збирає лише `cargo test` (у bin/ його немає), а `kit.exe` — та сама збірка
// тих самих джерел; запуск — копія `kit.exe` у `<плагін>/bin/`, як у поставці.

use serde_json::json;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const KIT: &str = env!("CARGO_BIN_EXE_kit");
const FAKE: &str = env!("CARGO_BIN_EXE_fake-runner");

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("kit-hook-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Плагін з `bin/kit.exe`, дім із реєстром Уніки на фальшивий раннер і репозиторій з маніфестом.
struct Setup {
    tmp: TempDir,
    exe: PathBuf,
    home: PathBuf,
    runner_dir: PathBuf,
    repo: PathBuf,
}

fn setup(tag: &str) -> Setup {
    let tmp = TempDir::new(tag);
    let bin = tmp.0.join("plugin").join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let exe = bin.join("kit.exe");
    std::fs::copy(KIT, &exe).unwrap();

    let install = tmp.0.join("unica");
    let runner_dir = install
        .join("bin")
        .join("win-x64")
        .join("v8-runner-windows-x86_64");
    std::fs::create_dir_all(&runner_dir).unwrap();
    std::fs::copy(FAKE, runner_dir.join("v8-runner.exe")).unwrap();
    std::fs::write(runner_dir.join("version.txt"), "0.18.1").unwrap();

    let home = tmp.0.join("home");
    let plugins = home.join(".claude").join("plugins");
    std::fs::create_dir_all(&plugins).unwrap();
    let rec = json!({"scope": "user", "version": "0.16.0", "installPath": install});
    std::fs::write(
        plugins.join("installed_plugins.json"),
        json!({"version": 2, "plugins": {"unica@unica": [rec]}}).to_string(),
    )
    .unwrap();

    let repo = tmp.0.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let st = Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["init", "-q", "-b", "main"])
        .status()
        .unwrap();
    assert!(st.success());
    std::fs::write(
        repo.join("v8storagekit.yaml"),
        "version: 1\nproduct: P\nworkspaces: []\n",
    )
    .unwrap();
    Setup {
        tmp,
        exe,
        home,
        runner_dir,
        repo,
    }
}

struct HookRun {
    context: String,
    seconds: f64,
}

/// Хук до кінця читання його stdout і stderr (EOF), як читає Claude Code: нащадок, що успадкував канал stdout
/// хука, тримав би читання до власного кінця.
fn run_hook(s: &Setup, timeout: Option<&str>) -> HookRun {
    let mut cmd = Command::new(&s.exe);
    cmd.arg("session-start")
        .current_dir(&s.tmp.0)
        .env("CLAUDE_PROJECT_DIR", &s.repo)
        .env("USERPROFILE", &s.home)
        .env("HOME", &s.home)
        .env_remove("V8KIT_SESSION_CHECK_TIMEOUT")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(t) = timeout {
        cmd.env("V8KIT_SESSION_CHECK_TIMEOUT", t);
    }
    let started = Instant::now();
    let mut child = cmd.spawn().unwrap();
    let mut err_pipe = child.stderr.take().unwrap();
    let err_reader = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = err_pipe.read_to_end(&mut v);
        v
    });
    let mut out = Vec::new();
    child.stdout.take().unwrap().read_to_end(&mut out).unwrap();
    let err = err_reader.join().unwrap();
    let seconds = started.elapsed().as_secs_f64();
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    assert!(err.is_empty(), "{}", String::from_utf8_lossy(&err));
    let json: serde_json::Value = serde_json::from_slice(&out).expect("вивід хука — валідний JSON");
    assert_eq!(json["hookSpecificOutput"]["hookEventName"], "SessionStart");
    let context = json["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap()
        .to_string();
    HookRun { context, seconds }
}

fn grandchild_pid(s: &Setup) -> Option<u32> {
    std::fs::read_to_string(s.runner_dir.join("grandchild-pid.txt"))
        .ok()
        .and_then(|t| t.trim().parse().ok())
}

fn alive(pid: u32) -> bool {
    let out = Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).contains(&format!("\"{pid}\""))
}

/// Чекає, поки процес зникне, не довше `wait`; повертає, чи він ще живий.
fn alive_after(pid: u32, wait: Duration) -> bool {
    let until = Instant::now() + wait;
    while alive(pid) {
        if Instant::now() >= until {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

fn kill(pid: u32) {
    let _ = Command::new("taskkill")
        .args(["/F", "/PID", &pid.to_string()])
        .output();
}

/// Повільний session-check (раннер спить 4 с на `--version`) і стеля 1 с: рядок «не вклався», а не очікування.
/// «Частково» немає: до кінця `check` session-check нічого не друкує, тож частини, що встигла, немає.
#[test]
fn slow_session_check_gives_not_within_the_ceiling_not_a_hang() {
    let s = setup("slow");
    std::fs::write(s.runner_dir.join("version-sleep.txt"), "4").unwrap();
    let r = run_hook(&s, Some("1"));
    assert!(r.seconds < 3.5, "хук чекав {} с при стелі 1 с", r.seconds);
    assert!(r.context.contains("не вклався в 1 с"), "{}", r.context);
    assert!(r.context.contains("стан сховищ НЕВІДОМИЙ"), "{}", r.context);
    assert!(!r.context.contains("Частково"), "{}", r.context);
}

/// На стелі хук убиває дерево: онук раннера, що успадкував його канали, не переживає хука.
#[test]
fn ceiling_kills_the_tree_including_the_grandchild() {
    let s = setup("tree");
    std::fs::write(s.runner_dir.join("version-sleep.txt"), "4").unwrap();
    std::fs::write(s.runner_dir.join("version-grandchild.txt"), "").unwrap();
    let r = run_hook(&s, Some("2"));
    let pid = grandchild_pid(&s);
    let still = pid.map(|p| alive_after(p, Duration::from_secs(3)));
    if let (Some(p), Some(true)) = (pid, still) {
        kill(p);
    }
    assert!(r.seconds < 7.0, "хук чекав {} с при стелі 2 с", r.seconds);
    assert!(r.context.contains("не вклався в 2 с"), "{}", r.context);
    assert!(
        pid.is_some(),
        "контроль: онук справді стартував до стелі, інакше перевірка нижче порожня"
    );
    assert_eq!(still, Some(false), "kill_tree мав убити й онука");
}

/// Нащадок, що пережив нормальний вихід session-check, не тримає читання виводу хука: власні дескриптори хука
/// неуспадковувані. Онук (hold, 10 с) тримає канали раннера; session-check чекає їх до стелі раннера (5 с) і
/// завершується сам, стелі хука немає. Якби канал stdout хука успадкувався вниз, EOF настав би лише з кінцем
/// онука (~10 с).
#[test]
fn descendant_surviving_a_normal_exit_does_not_hold_the_hook_output() {
    let s = setup("orphan");
    std::fs::write(s.runner_dir.join("version-sleep.txt"), "0").unwrap();
    std::fs::write(s.runner_dir.join("version-grandchild.txt"), "").unwrap();
    let r = run_hook(&s, None);
    let pid = grandchild_pid(&s);
    let still = pid.map(alive);
    if let Some(p) = pid {
        kill(p);
    }
    assert!(pid.is_some(), "контроль: онук стартував");
    assert!(
        !r.context.contains("не вклався"),
        "session-check мав завершитись сам: {}",
        r.context
    );
    assert!(
        r.seconds < 9.0,
        "читання виводу хука чекало онука: {} с",
        r.seconds
    );
    assert_eq!(
        still,
        Some(true),
        "контроль: онук пережив кінець читання — інакше швидкий EOF нічого не доводить"
    );
}
