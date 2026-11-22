// Спільні для команд kit операції над зовнішніми процесами: пошук програми й убивство дерева процесів.
// Одне місце на все, щоб `pwsh` (передача диспетчеру, хук) і `gh` (session-board) шукались однаково, а
// стеля часу вбивала нащадків так само (ADR-0014; запобіжник git знає тут `&taskkill`).

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

/// Пошук програми так, як її шукає оболонка Windows: теки `PATH` по черзі, у кожній — розширення з
/// `PATHEXT`. Одна функція для всіх зовнішніх програм; швів через змінні оточення немає.
pub fn find_program(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Убиває дерево процесів дочірнього (`taskkill /T /F`; session-check запускає git і раннер, gh — git і
/// браузер), потім — сам процес на випадок, коли taskkill не спрацював, і чекає його завершення.
pub fn kill_tree(child: &mut Child) {
    let system_root = std::env::var_os("SystemRoot").map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
    let taskkill = system_root.join("System32").join("taskkill.exe");
    let _ = Command::new(&taskkill)
        .args(["/T", "/F", "/PID", &child.id().to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = child.kill();
    let _ = child.wait();
}
