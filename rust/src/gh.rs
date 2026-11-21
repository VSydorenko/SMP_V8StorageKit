// Межа виклику `gh` (tools/lib/GhRun.psm1, `Invoke-KitGh`): програма — з PATH (PATHEXT, як шукає
// оболонка), оточення успадковане, `GH_PROMPT_DISABLED=1` (gh не питає людину), stdin закритий,
// stdout і stderr читаються потоками ДО очікування завершення. Стеля часу вбиває все дерево процесів gh
// (gh породжує git, браузер, pager).
//
// Класи збою — ті самі, що в PowerShell: gh відсутній або не залогінений — `Unavailable`; ненульовий
// код чи таймаут — `Failed` (текст `gh <два перші аргументи>: <перший рядок stderr>`).

use crate::proc;
use serde_json::Value;
use std::fmt;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Стеля часу виклику, с (як `-TimeoutSec` за умовчанням в `Invoke-KitGh`).
pub const TIMEOUT_SEC: u64 = 120;

#[derive(Debug, PartialEq, Eq)]
pub enum GhError {
    /// gh відсутній у PATH або не залогінений.
    Unavailable(String),
    /// Ненульовий код або таймаут.
    Failed(String),
    /// Відповідь не JSON: у PowerShell виняток ConvertFrom-Json не ловився (код 1, а не 3).
    BadJson(String),
}

impl fmt::Display for GhError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GhError::Unavailable(m) | GhError::Failed(m) | GhError::BadJson(m) => f.write_str(m),
        }
    }
}

fn first_line(text: &str) -> &str {
    text.trim().split('\n').next().unwrap_or("").trim_end_matches('\r')
}

/// stderr, за яким gh «не залогінений» (`(?i)auth login|not logged`).
fn is_auth_problem(stderr: &str) -> bool {
    let low = stderr.to_lowercase();
    low.contains("auth login") || low.contains("not logged")
}

/// `gh <args>` у теці `cwd`; stdout без країв. З `Some(json)` ... див. `run_json`.
pub fn run(args: &[&str], cwd: &Path, timeout: Duration) -> Result<String, GhError> {
    let Some(exe) = proc::find_program("gh") else {
        return Err(GhError::Unavailable("gh CLI не знайдено в PATH".to_string()));
    };
    let label = format!("gh {}", args.iter().take(2).copied().collect::<Vec<_>>().join(" "));
    let mut child = Command::new(&exe)
        .args(args)
        .current_dir(cwd)
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| GhError::Unavailable(format!("gh CLI не знайдено в PATH ({e})")))?;
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut p) = pipe {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        })
    };
    let out_thread = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let err_thread = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if Instant::now() >= deadline => {
                proc::kill_tree(&mut child);
                return Err(GhError::Failed(format!("{label}: немає відповіді за {} с", timeout.as_secs())));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => {
                proc::kill_tree(&mut child);
                return Err(GhError::Failed(format!("{label}: {e}")));
            }
        }
    };
    let stdout = String::from_utf8_lossy(&out_thread.join().unwrap_or_default()).into_owned();
    let stderr = String::from_utf8_lossy(&err_thread.join().unwrap_or_default()).into_owned();
    let code = status.code().unwrap_or(-1);
    if code != 0 {
        let first = first_line(&stderr);
        if is_auth_problem(&stderr) {
            return Err(GhError::Unavailable(format!("gh не залогінений (gh auth login): {first}")));
        }
        let first = if first.is_empty() { format!("код виходу {code}") } else { first.to_string() };
        return Err(GhError::Failed(format!("{label}: {first}")));
    }
    Ok(stdout.trim().to_string())
}

/// `gh <args> --json …` як елементи відповіді: порожній stdout — порожній список, масив — його елементи,
/// інший JSON — один елемент (так `@(…)` розгортає результат у PowerShell).
pub fn run_json(args: &[&str], cwd: &Path) -> Result<Vec<Value>, GhError> {
    let text = run(args, cwd, Duration::from_secs(TIMEOUT_SEC))?;
    if text.is_empty() {
        return Ok(Vec::new());
    }
    match serde_json::from_str::<Value>(&text) {
        // Вкладений масив розгортається ще раз: у PowerShell його розгортали і ConvertFrom-Json, і `return`.
        Ok(Value::Array(items)) => Ok(items
            .into_iter()
            .flat_map(|v| match v {
                Value::Array(inner) => inner,
                other => vec![other],
            })
            .collect()),
        Ok(other) => Ok(vec![other]),
        Err(e) => Err(GhError::BadJson(format!("Conversion from JSON failed with error: {e}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stderr_classes() {
        assert_eq!(first_line("\n boom \r\nsecond\r\n"), "boom ");
        assert!(is_auth_problem("To get started, please run:  gh auth login"));
        assert!(is_auth_problem("You are NOT LOGGED into any hosts"));
        assert!(!is_auth_problem("HTTP 404"));
    }
}
