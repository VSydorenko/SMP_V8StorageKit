// Гілки `storage/*`: спільний бібліотечний модуль (без друку; git — лише через ядро `git`). `check` бере звідси
// «гілка існує / ненароджена / немає» й аудит інваріантів дзеркала; `sync`, `verify`, `session-check` (B4, фаза 3)
// додають сюди решту (`remote_only`, `restore_mirror_step`, `last_storage_version`). Еталон —
// tools/lib/StorageBranch.psm1.
//
// Кожен запит розрізняє «так», «ні» і «git відповів збоєм» (рішення 5 плану B3): збій — `Err` з дослівним
// stderr git, а не «гілки немає». Рефи — повними іменами `refs/heads/<гілка>`; запити йдуть від кореня
// репозиторію зі стелею `GIT_CEILING_DIRECTORIES` (`git::run_at_root`).

use crate::case_guard::case_collisions;
use crate::git;
use std::path::Path;

/// Код з переліку `ok` — відповідь команди; будь-який інший чи збій запуску — помилка з дослівним stderr git.
pub(crate) fn query(root: &Path, args: &[&str], ok: &[i32]) -> Result<git::Output, String> {
    let out = git::run_at_root(root, args, None, true).map_err(|e| e.to_string())?;
    if ok.contains(&out.code) {
        return Ok(out);
    }
    Err(format!(
        "git {} завершився з кодом {}: {}",
        args.join(" "),
        out.code,
        String::from_utf8_lossy(&out.stderr).trim_end()
    ))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchState {
    /// `refs/heads/<гілка>` є.
    Exists,
    /// Ref ще немає, але `HEAD` указує саме на неї: свіжий репозиторій до першого коміту.
    Unborn,
    /// Гілки немає, `HEAD` указує деінде (чи від'єднаний).
    Missing,
}

/// Чи є локальна гілка (`Test-KitBranchExists`).
pub fn branch_exists(root: &Path, branch: &str) -> Result<bool, String> {
    let full = format!("refs/heads/{branch}");
    Ok(query(root, &["rev-parse", "--verify", "--quiet", &full], &[0, 1])?.code == 0)
}

/// Гілка є / ненароджена (`HEAD` на ній, ref немає) / немає (`Test-KitBranchUnborn`).
pub fn branch_state(root: &Path, branch: &str) -> Result<BranchState, String> {
    if branch_exists(root, branch)? {
        return Ok(BranchState::Exists);
    }
    let head = query(root, &["symbolic-ref", "-q", "HEAD"], &[0, 1])?;
    let target = String::from_utf8_lossy(&head.stdout);
    if head.code == 0 && target.trim() == format!("refs/heads/{branch}") {
        Ok(BranchState::Unborn)
    } else {
        Ok(BranchState::Missing)
    }
}

/// Результат аудиту інваріантів: знахідки (усі error) і збій git, якщо аудит довелось урвати. Знахідки, зібрані до
/// збою, не губляться.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Invariants {
    pub errors: Vec<String>,
    pub failure: Option<String>,
}

#[derive(Debug)]
struct Commit {
    sha: String,
    parents: usize,
    trailers: Vec<(String, String)>,
}

impl Commit {
    /// Трейлер без регістру ключа; повтор — перемагає останній (як присвоєння в упорядкованому словнику).
    fn trailer(&self, key: &str) -> Option<&str> {
        self.trailers
            .iter()
            .rev()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.as_str())
    }
}

/// `^[A-Za-z][A-Za-z0-9-]*:\s*.*$` — рядок трейлера.
fn parse_trailer(line: &str) -> Option<(String, String)> {
    let (key, value) = line.split_once(':')?;
    let mut chars = key.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }
    Some((key.to_string(), value.trim().to_string()))
}

/// Коміти від кореня до вершини одним викликом `git log` (запис на коміт — `\x1e`, поля — `\x1f`).
fn branch_commits(root: &Path, reference: &str) -> Result<Vec<Commit>, String> {
    let out = query(
        root,
        &[
            "log",
            "--reverse",
            "--format=%x1e%H%x1f%P%x1f%(trailers:only,unfold)",
            reference,
        ],
        &[0],
    )?;
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(text
        .split('\u{1e}')
        .filter(|r| !r.trim().is_empty())
        .map(|record| {
            let mut parts = record.splitn(3, '\u{1f}');
            let sha = parts.next().unwrap_or_default().trim().to_string();
            let parents = parts.next().map_or(0, |p| p.split_whitespace().count());
            let trailers = parts
                .next()
                .map(|t| t.lines().filter_map(parse_trailer).collect())
                .unwrap_or_default();
            Commit {
                sha,
                parents,
                trailers,
            }
        })
        .collect())
}

/// Повні шляхи файлів вершини гілки (сирі, UTF-8, `-z`).
fn tree_paths(root: &Path, reference: &str) -> Result<Vec<String>, String> {
    let out = query(
        root,
        &["ls-tree", "-r", "-z", "--name-only", reference],
        &[0],
    )?;
    Ok(out
        .stdout
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect())
}

/// Інваріанти гілки дзеркала (`Test-KitStorageBranchInvariants`): кожен коміт має числовий `Storage-Version` і
/// `Storage-Source` = ключ джерела; версії строго зростають; батьків не більше одного; дерево лише під шляхом
/// джерела; без груп шляхів, що різняться регістром. Гілки немає — порожній результат.
pub fn invariants(root: &Path, branch: &str, source_key: &str, repo_path: &str) -> Invariants {
    let mut result = Invariants::default();
    let reference = format!("refs/heads/{branch}");
    match branch_exists(root, branch) {
        Ok(true) => {}
        Ok(false) => return result,
        Err(e) => {
            result.failure = Some(e);
            return result;
        }
    }
    let commits = match branch_commits(root, &reference) {
        Ok(c) => c,
        Err(e) => {
            result.failure = Some(e);
            return result;
        }
    };
    let mut prev: Option<u64> = None;
    for commit in &commits {
        let label: String = commit.sha.chars().take(7).collect();
        if commit.parents > 1 {
            result.errors.push(format!(
                "{branch}: коміт {label} має {} батьків — merge-коміт на гілці сховища. Гілки storage/* лише дописує sync; зливають ЇХ у main/F, а не навпаки.",
                commit.parents
            ));
        }
        match commit.trailer("Storage-Source") {
            None => result.errors.push(format!(
                "{branch}: коміт {label} без трейлера Storage-Source:."
            )),
            Some(v) if !crate::config::yaml::eq_ci(v, source_key) => {
                result.errors.push(format!(
                    "{branch}: коміт {label} має Storage-Source: '{v}', а гілка належить джерелу '{source_key}'."
                ));
            }
            Some(_) => {}
        }
        let version = commit.trailer("Storage-Version").and_then(|v| {
            (!v.is_empty() && v.chars().all(|c| c.is_ascii_digit()))
                .then(|| v.parse::<u64>().ok())
                .flatten()
        });
        let Some(v) = version else {
            result.errors.push(format!(
                "{branch}: коміт {label} без числового трейлера Storage-Version:."
            ));
            continue;
        };
        if let Some(p) = prev.filter(|p| v <= *p) {
            result.errors.push(format!(
                "{branch}: версії не зростають строго — після {p} іде {v} (коміт {label})."
            ));
        }
        prev = Some(v);
    }

    let tree = match tree_paths(root, &reference) {
        Ok(t) => t,
        Err(e) => {
            result.failure = Some(e);
            return result;
        }
    };
    let prefix = format!("{}/", repo_path.replace('\\', "/").trim_end_matches('/'));
    let stray: Vec<&String> = tree.iter().filter(|p| !p.starts_with(&prefix)).collect();
    if !stray.is_empty() {
        // Один запис на весь перелік, а не на кожен файл: сотні однакових знахідок затоплюють вивід check.
        let shown: Vec<&str> = stray.iter().take(5).map(|s| s.as_str()).collect();
        let more = stray.len().saturating_sub(shown.len());
        let tail = if more > 0 {
            format!(", …і ще {more}")
        } else {
            String::new()
        };
        result.errors.push(format!(
            "{branch}: у дереві {} файл(ів) поза шляхом джерела '{repo_path}': {}{tail}.",
            stray.len(),
            shown.join(", ")
        ));
    }

    let groups = case_collisions(&tree);
    if !groups.is_empty() {
        let shown: Vec<String> = groups.iter().take(5).map(|g| g.join(" | ")).collect();
        let more = groups.len().saturating_sub(shown.len());
        let tail = if more > 0 {
            format!("; …і ще {more}")
        } else {
            String::new()
        };
        result.errors.push(format!(
            "{branch}: у вершині {} груп(и) шляхів, що різняться лише регістром (на Windows — один файл; злиття в робочу гілку впаде): {}{tail}. Розбір: docs/storage-and-git.md, «Перейменування регістром».",
            groups.len(),
            shown.join("; ")
        ));
    }
    result
}
