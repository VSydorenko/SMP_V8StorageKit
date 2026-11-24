// Читання гілок через ядро `git`: «так», «ні» і «git відповів збоєм» розрізняються (рішення 5 плану B3) —
// збій не стає «гілки немає».

use super::gitq::query;
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

pub(super) fn branch_state(root: &Path, branch: &str) -> Result<BranchState, String> {
    let full = format!("refs/heads/{branch}");
    if query(root, &["rev-parse", "--verify", "--quiet", &full], &[0, 1])?.code == 0 {
        return Ok(BranchState::Exists);
    }
    let head = query(root, &["symbolic-ref", "-q", "HEAD"], &[0, 1])?;
    let target = String::from_utf8_lossy(&head.stdout);
    if head.code == 0 && target.trim() == full {
        Ok(BranchState::Unborn)
    } else {
        Ok(BranchState::Missing)
    }
}
