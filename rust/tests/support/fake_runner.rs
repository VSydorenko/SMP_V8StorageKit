// Фальшивий раннер і argv-луна для тестів модуля `runner` (rust/tests/runner_core.rs). Справжній PE, а не
// `.cmd`: для пакетних файлів `std::process::Command` лапкує за правилами cmd.exe, і тест лапкування
// виміряв би не те. argv розбирається через `std::env::args_os` свідомо: справжній раннер — Rust-бінарник,
// тож розбирає так само. Ціль у `bin/` не потрапляє: `tools/build-kit-exe.ps1` збирає лише `--bin kit`.
//
// Режим — перший аргумент, що не є `--config <шлях>` і не `--json-message`; `--version` — як раннер:
// `v8-runner <версія>`, версія з `version.txt` поруч із exe (інакше 0.18.1).
//  echo      — друкує `{"argv":[аргументи після режиму]}`, без конверта;
//  envelope  — конверт ok:true з data.argv (усі аргументи після імені програми) і data.cwd;
//  fail      — конверт ok:false з error, код виходу 2;
//  notjson   — не JSON; noook — JSON без ok;
//  big       — по 2 МіБ у stdout і stderr (дедлок на непрочитаному каналі), код 0;
//  sleep     — спить 60 с;
//  partial   — друкує рядок у stdout і stderr, потім спить 60 с (вивід, що встиг прийти);
//  code7     — код виходу 7.

use std::io::Write;

fn json_array(items: &[String]) -> String {
    serde_json::to_string(items).unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
    if args.first().map(String::as_str) == Some("--version") {
        let exe = std::env::current_exe().unwrap();
        let version = std::fs::read_to_string(exe.with_file_name("version.txt")).unwrap_or_else(|_| "0.18.1".to_string());
        println!("v8-runner {}", version.trim());
        return;
    }
    let mut i = 0;
    let mut mode_at = None;
    while i < args.len() {
        match args[i].as_str() {
            "--config" => i += 2,
            "--json-message" => i += 1,
            _ => {
                mode_at = Some(i);
                break;
            }
        }
    }
    let Some(at) = mode_at else { std::process::exit(64) };
    let rest = &args[at + 1..];
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    match args[at].as_str() {
        "echo" => writeln!(out, "{{\"argv\":{}}}", json_array(rest)).unwrap(),
        "envelope" => {
            let cwd = std::env::current_dir().unwrap().display().to_string();
            let v = serde_json::json!({"ok": true, "command": "envelope", "data": {"argv": args, "cwd": cwd}, "warnings": ["w1"]});
            writeln!(out, "{v}").unwrap();
        }
        "fail" => {
            let v = serde_json::json!({"ok": false, "command": "fail", "data": {"message": "boom"},
                "error": {"code": "E42", "kind": "config", "message": "no infobase is selected"}});
            writeln!(out, "{v}").unwrap();
            drop(out);
            std::process::exit(2);
        }
        "notjson" => writeln!(out, "это не json").unwrap(),
        "noook" => writeln!(out, "{{\"data\":1}}").unwrap(),
        "big" => {
            let chunk = vec![b'x'; 1024];
            let mut err = std::io::stderr().lock();
            for _ in 0..2048 {
                out.write_all(&chunk).unwrap();
                err.write_all(&chunk).unwrap();
            }
        }
        "sleep" => std::thread::sleep(std::time::Duration::from_secs(60)),
        "partial" => {
            writeln!(out, "pre-out").unwrap();
            out.flush().unwrap();
            eprintln!("pre-err");
            std::thread::sleep(std::time::Duration::from_secs(60));
        }
        "code7" => {
            drop(out);
            std::process::exit(7);
        }
        _ => std::process::exit(64),
    }
}
