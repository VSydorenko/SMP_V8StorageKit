// Тести модуля `runner` (ADR-0019): запуск на справжньому PE-фальшивому раннері (tests/support/fake_runner.rs,
// ціль cargo `fake-runner`) — лапкування аргументів, конверт без перетлумачення, вивід без дедлоку, стеля
// часу, підкоманди `runner-exec` і `tool-verdicts`. Справжній раннер і справжній реєстр машини не
// використовуються: лише явні параметри.

use kit::runner::{self, RunError};
use serde_json::Value;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const FAKE: &str = env!("CARGO_BIN_EXE_fake-runner");
const KIT: &str = env!("CARGO_BIN_EXE_kit");

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("kit-runner-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn exec(args: &[&str]) -> Result<runner::RawOutput, RunError> {
    let a: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
    runner::exec(Path::new(FAKE), Path::new("."), &a, None)
}

/// Токени тесту лапкування: пробіл, лапка, кінцевий `\`, `\` перед лапкою, порожній аргумент, кирилиця.
const TOKENS: &[&str] = &[
    "a b",
    "q\"uote",
    "end\\",
    "back\\\"slash",
    "",
    "кирилиця з пробілом",
    "C:\\Program Files\\x\\",
    "--json-message",
    "--config",
];

fn echoed(out: &runner::RawOutput) -> Vec<String> {
    let v: Value = serde_json::from_str(out.stdout.trim()).unwrap_or_else(|e| panic!("не JSON: {e}: {:?}", out.stdout));
    v["argv"].as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect()
}

#[test]
fn arguments_reach_the_runner_verbatim() {
    let mut args = vec!["echo"];
    args.extend_from_slice(TOKENS);
    let out = exec(&args).unwrap();
    assert_eq!(out.exit_code, 0);
    assert_eq!(echoed(&out), TOKENS.iter().map(|s| s.to_string()).collect::<Vec<_>>());
}

#[test]
fn run_builds_config_and_json_message_and_keeps_the_envelope_as_is() {
    let tmp = TempDir::new("env");
    let ws = tmp.0.join("робочий каталог з пробілом");
    std::fs::create_dir_all(&ws).unwrap();
    let a: Vec<&OsStr> = ["envelope", "x y"].iter().map(OsStr::new).collect();
    let env = runner::run(Path::new(FAKE), &ws, &a, None).unwrap();
    assert!(env.ok);
    assert_eq!(env.exit_code, 0);
    assert_eq!(env.command.as_deref(), Some("envelope"));
    assert_eq!(env.warnings, vec![Value::String("w1".into())]);
    assert!(env.error.is_none());
    let argv: Vec<String> = env.data["argv"].as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect();
    assert_eq!(
        argv,
        vec!["--config".to_string(), ws.join("v8project.yaml").display().to_string(), "envelope".into(), "x y".into(), "--json-message".into()]
    );
    // Робоча тека — workspace_dir.
    let cwd = PathBuf::from(env.data["cwd"].as_str().unwrap());
    assert_eq!(cwd.canonicalize().unwrap(), ws.canonicalize().unwrap());
    assert_eq!(env.raw["data"]["argv"], env.data["argv"]);
}

#[test]
fn run_does_not_reinterpret_ok_false_or_the_exit_code() {
    let a: Vec<&OsStr> = vec![OsStr::new("fail")];
    let env = runner::run(Path::new(FAKE), Path::new("."), &a, None).unwrap();
    assert!(!env.ok);
    assert_eq!(env.exit_code, 2);
    let e = env.error.unwrap();
    assert_eq!(
        (e.code.as_deref(), e.kind.as_deref(), e.message.as_deref()),
        (Some("E42"), Some("config"), Some("no infobase is selected"))
    );
    assert_eq!(env.data["message"], "boom");
}

#[test]
fn run_errors_carry_code_and_verbatim_output() {
    let notjson = runner::run(Path::new(FAKE), Path::new("."), &[OsStr::new("notjson")], None).unwrap_err();
    match &notjson {
        RunError::NotJson { exit_code, stdout, .. } => {
            assert_eq!(*exit_code, 0);
            assert!(stdout.contains("это не json"));
        }
        other => panic!("{other:?}"),
    }
    assert!(notjson.to_string().starts_with("Раннер на 'notjson' відповів не JSON-ом: код виходу 0, вивід: это не json"));
    let noook = runner::run(Path::new(FAKE), Path::new("."), &[OsStr::new("noook")], None).unwrap_err();
    assert!(matches!(noook, RunError::NoOk { .. }));
    assert_eq!(noook.to_string(), "Відповідь раннера на 'noook' без поля ok: {\"data\":1}");
}

#[test]
fn large_output_on_both_streams_does_not_deadlock() {
    let out = exec(&["big"]).unwrap();
    assert_eq!((out.stdout.len(), out.stderr.len()), (2 * 1024 * 1024, 2 * 1024 * 1024));
}

#[test]
fn exit_code_is_returned_raw() {
    assert_eq!(exec(&["code7"]).unwrap().exit_code, 7);
}

#[test]
fn ceiling_kills_the_process_and_keeps_what_arrived() {
    let a: Vec<&OsStr> = vec![OsStr::new("partial")];
    let started = std::time::Instant::now();
    let err = runner::exec(Path::new(FAKE), Path::new("."), &a, Some(Duration::from_millis(1500))).unwrap_err();
    assert!(started.elapsed() < Duration::from_secs(30), "процес не вбито");
    match err {
        RunError::Timeout { stdout, stderr, .. } => {
            assert!(stdout.contains("pre-out"), "{stdout:?}");
            assert!(stderr.contains("pre-err"), "{stderr:?}");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn missing_runner_is_not_found() {
    let err = runner::exec(Path::new("C:\\немає\\v8-runner.exe"), Path::new("."), &[], None).unwrap_err();
    assert_eq!(err.to_string(), "Раннер не знайдено: C:\\немає\\v8-runner.exe");
}

#[test]
fn version_is_parsed_from_the_version_line() {
    let tmp = TempDir::new("ver");
    for (line, expect) in [("0.18.1", Some("0.18.1")), ("0.18.9-fork.3", Some("0.18.9-fork.3")), ("dev", None)] {
        let exe = tmp.0.join("v8-runner.exe");
        std::fs::copy(FAKE, &exe).unwrap();
        std::fs::write(tmp.0.join("version.txt"), line).unwrap();
        let got = runner::version(&exe);
        match expect {
            Some(v) => assert_eq!(got.unwrap(), v),
            None => assert!(
                got.unwrap_err().contains("відповів не рядком 'v8-runner <версія>': код виходу 0, вивід: v8-runner dev"),
                "{line}"
            ),
        }
    }
}

/// runner-exec: аргументи (зокрема `--config`, `--version`) доходять дослівно, код — код раннера, потоки
/// успадковані.
#[test]
fn runner_exec_passes_arguments_and_exit_code_through() {
    let out = Command::new(KIT).args(["runner-exec", FAKE, ".", "echo"]).args(TOKENS).output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    let got: Vec<&str> = v["argv"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
    assert_eq!(got, TOKENS);
    let out = Command::new(KIT).args(["runner-exec", FAKE, ".", "code7"]).output().unwrap();
    assert_eq!(out.status.code(), Some(7));
    // Власна помилка — `runner-exec: ERROR …` у stderr і код 1.
    let out = Command::new(KIT).args(["runner-exec", "C:\\немає\\v8-runner.exe", "."]).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("runner-exec: ERROR Раннер не знайдено"));
}

/// tool-verdicts: один JSON; код 0 і на вердикті error.
#[test]
fn tool_verdicts_prints_one_json() {
    let tmp = TempDir::new("verdicts");
    let install = tmp.0.join("unica");
    std::fs::create_dir_all(&install).unwrap();
    let registry = tmp.0.join("installed_plugins.json");
    let body = serde_json::json!({"version": 2, "plugins": {"unica@unica": [{"scope": "user", "version": "0.16.0", "installPath": install}]}});
    std::fs::write(&registry, body.to_string()).unwrap();
    let runner_dir = tmp.0.join("r");
    std::fs::create_dir_all(&runner_dir).unwrap();
    let exe = runner_dir.join("v8-runner.exe");
    std::fs::copy(FAKE, &exe).unwrap();
    let out = Command::new(KIT)
        .arg("tool-verdicts")
        .arg("-InstalledPluginsPath")
        .arg(&registry)
        .arg("-RunnerPath")
        .arg(&exe)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["unica"]["Level"], "ok");
    assert_eq!(v["unica"]["Message"], "Плагін unica 0.16.0.");
    assert_eq!(v["unica"]["Installed"], true);
    assert_eq!(v["runner"]["Level"], "ok");
    assert_eq!(v["runner"]["Message"], "Раннер v8-runner 0.18.1.");
    assert_eq!(v["runner"]["Version"], "0.18.1");
    // Раннера немає — error, але код 0 і JSON.
    let out = Command::new(KIT)
        .arg("tool-verdicts")
        .arg("-InstalledPluginsPath")
        .arg(&registry)
        .arg("-RunnerPath")
        .arg(tmp.0.join("немає.exe"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["runner"]["Level"], "error");
    // Помилка виклику — код 2.
    let out = Command::new(KIT).args(["tool-verdicts", "--nope"]).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}
