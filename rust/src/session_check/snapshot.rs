// Узгоджений знімок git-стану одного джерела `truth: storage` (ADR-0021 п. 3): SHA вершини дзеркала, головної
// гілки й `origin/<гілка>` читаються ОДИН раз, а дата коміту, трейлер версії й лічильники — від цих SHA, тож
// паралельний `sync` не змішає три стани в одному сигналі. Без мережі й без запису.
//
// Збій git (код поза «є/немає», нерозбірна дата коміту, нерозбірне число) — `GitProblem` цього джерела з
// дослівним stderr git, а не «гілки немає»: «немає» радило б `kit sync -Apply`, що будує другу історію.

use super::ticks;
use crate::git::query;
use crate::storage_branch::{
    BranchState, OriginGap, branch_state, origin_gap_between, ref_sha, storage_version_at,
};
use std::fmt;
use std::path::Path;

/// Збій git на джерелі: текст — дослівно, як його дав git.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitProblem(pub String);

impl fmt::Display for GitProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GitProblem {}

impl From<String> for GitProblem {
    fn from(message: String) -> Self {
        GitProblem(message)
    }
}

/// Знімок git-стану джерела.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceGit {
    /// `refs/heads/<гілка дзеркала>`.
    pub mirror_sha: Option<String>,
    /// `refs/heads/<головна гілка>`.
    pub main_sha: Option<String>,
    /// `refs/remotes/origin/<гілка дзеркала>`.
    pub origin_sha: Option<String>,
    /// Дзеркала немає локально, а `origin/<гілка>` є (#101).
    pub remote_only: bool,
    /// Дата автора вершини дзеркала, тики UTC (`%aI`); дзеркала немає — `None`.
    pub last_mirror_ticks: Option<i64>,
    /// `Storage-Version` вершини дзеркала; дзеркала немає — `None`.
    pub last_version: Option<u64>,
    /// Коміти дзеркала, не злиті в головну (`main..mirror`); головної немає — усі коміти дзеркала.
    pub unmerged: u64,
    /// Дзеркало є, головної гілки немає.
    pub main_missing: bool,
    /// Головної гілки немає, але `HEAD` указує на неї (свіжий репозиторій до першого коміту).
    pub main_unborn: bool,
    /// Відставання від origin; `OriginGap::NONE`, коли дзеркала чи `origin/<гілка>` немає.
    pub origin_gap: OriginGap,
}

fn count(root: &Path, range: &[&str]) -> Result<u64, GitProblem> {
    let mut args = vec!["rev-list", "--count"];
    args.extend_from_slice(range);
    let out = query(root, &args, &[0])?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.is_empty() || !text.chars().all(|c| c.is_ascii_digit()) {
        return Err(GitProblem(format!(
            "git {}: нерозбірна відповідь «{text}»",
            args.join(" ")
        )));
    }
    text.parse::<u64>().map_err(|_| {
        GitProblem(format!(
            "git {}: число поза діапазоном «{text}»",
            args.join(" ")
        ))
    })
}

fn author_date(root: &Path, sha: &str) -> Result<i64, GitProblem> {
    let out = query(root, &["log", "-1", "--format=%aI", sha], &[0])?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    ticks::parse_iso(&text).ok_or_else(|| {
        GitProblem(format!(
            "git log -1 --format=%aI {sha}: нерозбірна дата коміту «{text}»"
        ))
    })
}

/// Знімок джерела: `branch` — гілка дзеркала (`storage/<ключ>`), `main` — головна гілка маніфесту.
pub fn snapshot(root: &Path, branch: &str, main: &str) -> Result<SourceGit, GitProblem> {
    let mirror_sha = ref_sha(root, &format!("refs/heads/{branch}"))?;
    let main_sha = ref_sha(root, &format!("refs/heads/{main}"))?;
    let origin_sha = ref_sha(root, &format!("refs/remotes/origin/{branch}"))?;
    let remote_only = mirror_sha.is_none() && origin_sha.is_some();

    let mut shot = SourceGit {
        mirror_sha: mirror_sha.clone(),
        main_sha: main_sha.clone(),
        origin_sha: origin_sha.clone(),
        remote_only,
        last_mirror_ticks: None,
        last_version: None,
        unmerged: 0,
        main_missing: false,
        main_unborn: false,
        origin_gap: OriginGap::NONE,
    };
    let Some(mirror) = mirror_sha else {
        return Ok(shot);
    };

    shot.last_mirror_ticks = Some(author_date(root, &mirror)?);
    shot.last_version = Some(storage_version_at(root, &mirror)?);
    if let Some(origin) = &origin_sha {
        shot.origin_gap = origin_gap_between(root, &mirror, origin)?;
    }
    match &main_sha {
        Some(main_sha) => {
            shot.unmerged = count(root, &[&format!("{main_sha}..{mirror}")])?;
        }
        None => {
            shot.main_missing = true;
            shot.main_unborn = branch_state(root, main)? == BranchState::Unborn;
            shot.unmerged = count(root, &[&mirror])?;
        }
    }
    Ok(shot)
}
