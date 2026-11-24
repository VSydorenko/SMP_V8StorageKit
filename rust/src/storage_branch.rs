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

use crate::git::query;

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
    git::ref_exists(root, &full)
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

// --- Перенесене для `session-check` (B4, рішення 23 плану). PowerShell-копії лишаються: їх кличуть `sync`/`adopt`.
// Усі запити розрізняють «так», «ні» і «git відповів збоєм» (збій — `Err` з дослівним stderr).

/// SHA, на який указує повне ім'я рефа (`refs/heads/…`, `refs/remotes/…`): `Some` — є, `None` — немає,
/// `Err` — збій git. Код 1 з повідомленням у stderr (`warning: ignoring broken ref …`) — збій, а не «немає».
pub fn ref_sha(root: &Path, full_name: &str) -> Result<Option<String>, String> {
    // Без `^{commit}`: з ним `--quiet` ковтає відсутній об'єкт коміту (код 1 без stderr) і зламаний ref виглядав би як
    // «гілки немає». Відсутній об'єкт покаже перший запит від SHA (`log`, `rev-list`) — збоєм git джерела.
    let spec = full_name;
    let out = query(root, &["rev-parse", "--verify", "--quiet", spec], &[0, 1])?;
    if out.code == 1 {
        if out.stderr.iter().all(u8::is_ascii_whitespace) {
            return Ok(None);
        }
        return Err(format!(
            "git rev-parse --verify --quiet {spec} завершився з кодом 1: {}",
            String::from_utf8_lossy(&out.stderr).trim_end()
        ));
    }
    let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if sha.len() < 40 || !sha.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!(
            "git rev-parse --verify --quiet {spec}: нерозбірна відповідь «{sha}»"
        ));
    }
    Ok(Some(sha))
}

/// Дзеркало є лише на `origin` (`Test-KitRemoteOnlyMirror`, #101): локальної `refs/heads/<гілка>` немає, а
/// `refs/remotes/origin/<гілка>` є. Без мережі, лише наявні рефи.
pub fn remote_only(root: &Path, branch: &str) -> Result<bool, String> {
    if ref_sha(root, &format!("refs/heads/{branch}"))?.is_some() {
        return Ok(false);
    }
    Ok(ref_sha(root, &format!("refs/remotes/origin/{branch}"))?.is_some())
}

/// Крок відновлення локального дзеркала з origin (`Get-KitRestoreMirrorStep`) — той самий текст, що в `sync`/`adopt`.
pub fn restore_mirror_step(branch: &str) -> String {
    format!("git branch --track {branch} origin/{branch}")
}

/// Номер `Storage-Version` з вершини `rev` (SHA чи реф). Трейлера немає чи він не число — `Err`: гілку писав не
/// `sync`, вгадувати стан не можна.
pub fn storage_version_at(root: &Path, rev: &str) -> Result<u64, String> {
    let out = query(
        root,
        &[
            "log",
            "-1",
            "--format=%(trailers:key=Storage-Version,valueonly)",
            rev,
        ],
        &[0],
    )?;
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_digit()) {
        return Err(format!(
            "Вершина {rev} не має числового трейлера Storage-Version: — гілку писав не sync. Розбір: kit check."
        ));
    }
    value
        .parse::<u64>()
        .map_err(|_| format!("Storage-Version на вершині {rev} поза діапазоном: {value}"))
}

/// «Остання залита версія» джерела (`Get-KitStorageBranchLastVersion`): трейлер вершини `refs/heads/<гілка>`;
/// гілки немає — `None`.
pub fn last_storage_version(root: &Path, branch: &str) -> Result<Option<u64>, String> {
    match ref_sha(root, &format!("refs/heads/{branch}"))? {
        Some(sha) => storage_version_at(root, &sha).map(Some),
        None => Ok(None),
    }
}

/// Розходження локальної гілки з `origin/<гілка>` без мережі (`Get-KitOriginGap`). `has_remote = false` —
/// `origin/<гілка>` немає (легальний стан: репозиторій без origin, гілку не пушено); це не збій git.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OriginGap {
    pub has_remote: bool,
    pub ahead: u64,
    pub behind: u64,
}

impl OriginGap {
    pub const NONE: OriginGap = OriginGap {
        has_remote: false,
        ahead: 0,
        behind: 0,
    };
}

/// `rev-list --left-right --count local...origin` від двох SHA: ліворуч — лише локальні (ahead), праворуч —
/// лише на origin (behind). Нерозбірна відповідь — `Err`.
pub fn origin_gap_between(
    root: &Path,
    local_sha: &str,
    origin_sha: &str,
) -> Result<OriginGap, String> {
    let range = format!("{local_sha}...{origin_sha}");
    let out = query(root, &["rev-list", "--left-right", "--count", &range], &[0])?;
    let text = String::from_utf8_lossy(&out.stdout);
    let parts: Vec<&str> = text.split_whitespace().collect();
    let parsed = match parts.as_slice() {
        [a, b] => a.parse::<u64>().ok().zip(b.parse::<u64>().ok()),
        _ => None,
    };
    match parsed {
        Some((ahead, behind)) => Ok(OriginGap {
            has_remote: true,
            ahead,
            behind,
        }),
        None => Err(format!(
            "git rev-list --left-right --count {range}: нерозбірна відповідь «{}»",
            text.trim()
        )),
    }
}

/// Розходження гілки з origin за іменем: рефи читаються тут (для викликачів без знімка).
pub fn origin_gap(root: &Path, branch: &str) -> Result<OriginGap, String> {
    let Some(origin) = ref_sha(root, &format!("refs/remotes/origin/{branch}"))? else {
        return Ok(OriginGap::NONE);
    };
    let Some(local) = ref_sha(root, &format!("refs/heads/{branch}"))? else {
        return Ok(OriginGap::NONE);
    };
    origin_gap_between(root, &local, &origin)
}
