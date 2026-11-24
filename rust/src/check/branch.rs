// Читання гілок через ядро `git`: «так», «ні» і «git відповів збоєм» розрізняються (рішення 5 плану B3) —
// збій не стає «гілки немає».

use crate::git;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BranchState {
    /// `refs/heads/<гілка>` є.
    Exists,
    /// Ref ще немає, але `HEAD` указує саме на неї: свіжий репозиторій до першого коміту.
    Unborn,
    /// Гілки немає, `HEAD` указує деінде (чи від'єднаний).
    Missing,
}

/// Код 0 чи 1 — відповідь команди; будь-який інший код чи збій запуску — помилка з дослівним stderr git.
fn query(root: &Path, args: &[&str]) -> Result<git::Output, String> {
    let out = git::run_at_root(root, args, None, true).map_err(|e| e.to_string())?;
    if out.code == 0 || out.code == 1 {
        return Ok(out);
    }
    Err(format!(
        "git {} завершився з кодом {}: {}",
        args.join(" "),
        out.code,
        String::from_utf8_lossy(&out.stderr).trim_end()
    ))
}

pub(super) fn branch_state(root: &Path, branch: &str) -> Result<BranchState, String> {
    let full = format!("refs/heads/{branch}");
    if query(root, &["rev-parse", "--verify", "--quiet", &full])?.code == 0 {
        return Ok(BranchState::Exists);
    }
    let head = query(root, &["symbolic-ref", "-q", "HEAD"])?;
    let target = String::from_utf8_lossy(&head.stdout);
    if head.code == 0 && target.trim() == full {
        Ok(BranchState::Unborn)
    } else {
        Ok(BranchState::Missing)
    }
}
