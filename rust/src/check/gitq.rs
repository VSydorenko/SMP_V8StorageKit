// Запити git для перевірок `check` (рішення 5 плану B3): кожен розрізняє «так», «ні» і «git відповів збоєм»
// (код поза контрактом команди, git не запустився). Збій — `Err` з дослівним stderr git, а не «немає». Усе —
// через `git::run_at_root`: від кореня, зі стелею `GIT_CEILING_DIRECTORIES`, тож зламана тека `.git` дає збій,
// а не відповідь зовнішнього репозиторію. Факт відстеження й неігновані файли беруться списком без pathspec
// (git звіряє pathspec з урахуванням регістру) і фільтруються в Rust за нормалізованим шляхом без регістру
// (`under_ci`): `[`, `*`, `?` у шляху — літерали; `.`, `..`, `//` згортаються, вихід за корінь — помилка.
// `check-ignore`, `check-attr` і `ls-tree` приймають шлях як є.

use crate::case_guard::fold;
use std::path::Path;

pub(super) use crate::storage_branch::query;

/// Шлях у формі git: роздільники `/`, без кінцевої скісної риски.
pub(super) fn slashed(path: &str) -> String {
    path.replace('\\', "/").trim_end_matches('/').to_string()
}

/// Чи ігнорує `.gitignore` шлях — за ПРАВИЛАМИ (`--no-index`), не за індексом: без нього check-ignore звіряється
/// з індексом і ніколи не покаже вже відстежений файл ігнорованим.
pub(super) fn ignored(root: &Path, path: &str) -> Result<bool, String> {
    Ok(query(
        root,
        &["check-ignore", "--no-index", "-q", "--", path],
        &[0, 1],
    )?
    .code
        == 0)
}

/// Усі відстежувані індексом шляхи (ФАКТ, а не правила). Без pathspec: git звіряє pathspec з урахуванням регістру
/// навіть за `core.ignorecase=true`, а файл з паролем в індексі може лежати в іншому регістрі.
pub(super) fn index_files(root: &Path) -> Result<Vec<String>, String> {
    Ok(nul_split(&query(root, &["ls-files", "-z"], &[0])?.stdout))
}

/// Файли на диску, що не відстежуються й не ігноруються (`--others --exclude-standard`).
pub(super) fn unignored_files(root: &Path) -> Result<Vec<String>, String> {
    let out = query(
        root,
        &["ls-files", "-z", "--others", "--exclude-standard"],
        &[0],
    )?;
    Ok(nul_split(&out.stdout))
}

/// Шлях без сегментів `.` і порожніх, з розгорнутими `..`. `..` понад корінь репозиторію — помилка (fail-closed:
/// шлях поза репозиторієм перевірити неможливо, а мовчання читалося б як «нічого не відстежується»).
fn normalized(path: &str) -> Result<String, String> {
    let mut parts: Vec<&str> = Vec::new();
    let unified = path.replace('\\', "/");
    for seg in unified.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(format!("шлях '{path}' виходить за корінь репозиторію"));
                }
            }
            s => parts.push(s),
        }
    }
    Ok(parts.join("/"))
}

/// Записи списку, що збігаються з шляхом (сам файл чи вміст теки) за юнікодним `OrdinalIgnoreCase`, як у NTFS.
pub(super) fn under_ci(list: &[String], path: &str) -> Result<Vec<String>, String> {
    let want = fold(&normalized(path)?);
    Ok(list
        .iter()
        .filter(|e| {
            let f = fold(e);
            f == want
                || f.strip_prefix(&want)
                    .is_some_and(|rest| rest.starts_with('/'))
        })
        .cloned()
        .collect())
}

/// Чи є в репозиторії `HEAD` (немає — свіжий репозиторій до першого коміту).
pub(super) fn has_head(root: &Path) -> Result<bool, String> {
    Ok(query(root, &["rev-parse", "-q", "--verify", "HEAD"], &[0, 1])?.code == 0)
}

/// Повні шляхи файлів `HEAD` під шляхом, сирі UTF-8 (`-z`: без квотування).
pub(super) fn head_paths(root: &Path, path: &str) -> Result<Vec<String>, String> {
    let out = query(
        root,
        &["ls-tree", "-r", "-z", "--name-only", "HEAD", "--", path],
        &[0],
    )?;
    Ok(nul_split(&out.stdout))
}

/// Чи діє `-text` (`text: unset`) на файл, який git питається самим — з урахуванням порядку й перекриття правил.
pub(super) fn text_unset(root: &Path, probe: &str) -> Result<bool, String> {
    let out = query(root, &["check-attr", "text", "--", probe], &[0])?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.trim_end();
    Ok(line
        .strip_suffix("unset")
        .map(str::trim_end)
        .and_then(|l| l.strip_suffix("text:"))
        .map(str::trim_end)
        .is_some_and(|l| l.ends_with(':')))
}

fn nul_split(bytes: &[u8]) -> Vec<String> {
    bytes
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect()
}
