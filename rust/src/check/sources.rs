// Перевірки одного джерела (`<воркспейс>/<ключ>`) у порядку PowerShell: `gitattributes`, `case-collision`,
// `gitignore` (дерево), далі `gitignore` vendor (правила й факт), `dump-from`. Задача 3 плану B3 вставляє свої
// перевірки (поставка, `storage-path`, `storage-branch`, `config-name`) у `check_source` на місця, позначені
// коментарями «[задача 3]».

use super::Collector;
use super::gitq::{has_head, head_paths, ignored, slashed, text_unset};
use crate::case_guard::case_collisions;
use crate::config::{Context, Level, Source, Truth};
use std::path::Path;

pub(super) fn check_source(c: &mut Collector, ctx: &Context, src: &Source) {
    let root = Path::new(&ctx.repo_root);
    let tag = format!("{}/{}", src.workspace, src.key);

    // Усі дерева платформи, що потрапляють у git, — під -text. truth: vendor гітігноровано за визначенням,
    // тож для нього інваріант інший (нижче).
    if src.truth != Truth::Vendor {
        gitattributes(c, root, &tag, src);
        case_collision(c, root, &tag, src);
        tree_not_ignored(c, root, &tag, src);
    }

    // [задача 3] поставка вендора основної конфігурації: gitignore/supply для CONFIGURATION без vendor.

    if src.truth == Truth::Vendor {
        vendor_tree(c, root, &tag, src);
    }
    // [задача 3] truth: storage — storage-path, storage-branch.

    if matches!(src.truth, Truth::Dump | Truth::Vendor) {
        dump_from(c, ctx, &tag, src);
    }
    // [задача 3] config-name для EXTENSION без vendor.
}

/// `gitattributes` (рішення 14): питаємо САМ git про один файл `<шлях>/Configuration.xml` — правила `-text`
/// прив'язані до шляху, а `git status` при хибній політиці чистий завжди.
fn gitattributes(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", slashed(&src.repo_path));
    match text_unset(root, &probe) {
        Ok(true) => {}
        Ok(false) => c.add(
            Level::Error,
            "gitattributes",
            format!(
                "{tag}: дерево '{p}' не виведено з-під конверсії кінців рядків — додайте в .gitattributes рядок '{p}/** -text' (docs/text-policy.md).",
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked(
            "gitattributes",
            &format!("{tag}: політика кінців рядків дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// `case-collision` (рішення 13): групи регістру в HEAD під шляхом джерела. Немає `HEAD` — не застосовується.
fn case_collision(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let what = format!("{tag}: регістр шляхів у HEAD");
    let paths = match has_head(root) {
        Ok(false) => return,
        Ok(true) => head_paths(root, &slashed(&src.repo_path)),
        Err(reason) => Err(reason),
    };
    let paths = match paths {
        Ok(p) => p,
        Err(reason) => return c.unchecked("case-collision", &what, &reason),
    };
    let groups = case_collisions(&paths);
    if groups.is_empty() {
        return;
    }
    let shown: Vec<String> = groups.iter().take(5).map(|g| g.join(" | ")).collect();
    let more = if groups.len() > 5 {
        format!("; …і ще {}", groups.len().saturating_sub(5))
    } else {
        String::new()
    };
    c.add(
        Level::Error,
        "case-collision",
        format!(
            "{tag}: у HEAD {} груп(и) шляхів, що різняться лише регістром: {}{more}. Зніміть фантом з індексу (git rm --cached -- <шлях>) і закомітьте без --only; розбір — docs/storage-and-git.md, «Перейменування регістром».",
            groups.len(),
            shown.join("; ")
        ),
    );
}

/// Дерево, яке МАЄ бути в git, не повинно ловитись правилом `.gitignore`: помилково широке правило викидає
/// вихідники з git мовчки. `--no-index` обов'язковий — інакше відстежений `Configuration.xml` ніколи не
/// показався б ігнорованим.
fn tree_not_ignored(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", src.repo_path);
    match ignored(root, &probe) {
        Ok(false) => {}
        Ok(true) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: дерево '{}' гітігноровано, хоч має потрапляти в git (truth: {}) — перевірте правила .gitignore.",
                src.repo_path,
                src.truth.as_str()
            ),
        ),
        Err(reason) => c.unchecked(
            "gitignore",
            &format!("{tag}: гітігнорування дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// vendor — два РІЗНІ питання: ПРАВИЛА (дерево ігнорується) і ФАКТ (дерево не в індексі). Страж (рішення 2):
/// збій git — error «не перевірено».
fn vendor_tree(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", src.repo_path);
    let rules = ignored(root, &probe).and_then(|ok| {
        // Файл дерева в іншому регістрі може лишитися поза правилом.
        if ok && !c.unignored(root, &src.repo_path)?.is_empty() {
            return Ok(false);
        }
        Ok(ok)
    });
    match rules {
        Ok(true) => {}
        Ok(false) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: '{p}' не гітігноровано (truth: vendor) — чужа конфігурація потрапила б у git. Додайте в .gitignore рядок '{p}/**' (перевірка: git check-ignore).",
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked_error(
            "gitignore",
            &format!("{tag}: гітігнорування дерева '{}'", src.repo_path),
            &reason,
        ),
    }
    // Правило може бути на місці, а файли вже закомічені (`git add -f`): check-ignore --no-index індекс
    // свідомо ігнорує, тож питаємо індекс напряму.
    match c.tracked(root, &src.repo_path) {
        Ok(files) if files.is_empty() => {}
        Ok(files) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: дерево '{p}' (truth: vendor) відстежується git — у ньому {} файл(ів), хоч чужа конфігурація не має потрапляти в репозиторій. Приберіть з індексу: git rm -r --cached -- '{p}'.",
                files.len(),
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked_error(
            "gitignore",
            &format!("{tag}: відстеження дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// `dump-from`: джерело `dump`/`vendor` береться з дев-бази накладки. Накладки немає — warn; накладка є, але не
/// розібрана (рішення 7), — мовчимо: помилка `overlay` уже error, а казати «накладки немає» було б неправдою.
fn dump_from(c: &mut Collector, ctx: &Context, tag: &str, src: &Source) {
    let from = src.dump_from.as_deref().unwrap_or_default();
    match (&ctx.overlay, &ctx.overlay_path) {
        (Some(overlay), path) => {
            if overlay.infobase(from).is_none() {
                c.add(
                    Level::Warn,
                    "dump-from",
                    format!(
                        "{tag}: дев-бази '{from}' немає в infobases: накладки {}.",
                        path.as_deref().unwrap_or_default()
                    ),
                );
            }
        }
        (None, None) => c.add(
            Level::Warn,
            "dump-from",
            format!(
                "{tag}: dump.from '{from}', але накладки v8storagekit.local.yaml на цій машині немає — dump тут не запрацює, поки її не створити (зразок: templates/v8storagekit.local.yaml.example)."
            ),
        ),
        (None, Some(_)) => {}
    }
}
