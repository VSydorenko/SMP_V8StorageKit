// Стражі секретів: файли з рядками підключення й паролями не мусять потрапити в git. Два РІЗНІ питання на файл —
// ПРАВИЛА (`check-ignore --no-index`) і ФАКТ (`ls-files`): правило може бути на місці, а файл уже закомічено
// (`git add -f` чи до появи правила). Страж fail-closed (ADR-0021 п. 2): збій git — error «не перевірено», а не
// мовчання про файл із паролем. Не залежать від розв'язаного контексту: виконуються й коли маніфест
// не прочитано чи воркспейс випав через помилку конфігу.

use super::Collector;
use super::gitq::ignored;
use std::path::Path;

pub(super) fn overlay_ignored(c: &mut Collector, root: &Path) {
    const FILE: &str = "v8storagekit.local.yaml";
    let rules = ignored(root, FILE).and_then(|ok| {
        // Правило «ігнорує» канонічне ім'я, а файл на диску може лежати в іншому регістрі й бути неігнорованим.
        if ok && !c.unignored(root, FILE)?.is_empty() {
            return Ok(false);
        }
        Ok(ok)
    });
    match rules {
        Ok(true) => {}
        Ok(false) => c.add(
            crate::config::Level::Error,
            "overlay-ignored",
            "v8storagekit.local.yaml не гітігноровано в корені репозиторію — це накладка з рядками підключення й користувачами сховищ, і перший же git add -A застейджить її в публічний репозиторій. Додайте рядок 'v8storagekit.local.yaml' у .gitignore (зразок: templates/gitignore).",
        ),
        Err(reason) => c.unchecked_error(
            "overlay-ignored",
            "гітігнорування v8storagekit.local.yaml",
            &reason,
        ),
    }
    match c.tracked(root, FILE) {
        Ok(files) if files.is_empty() => {}
        Ok(_) => c.add(
            crate::config::Level::Error,
            "overlay-ignored",
            "v8storagekit.local.yaml вже закомічено в git — у ньому рядки підключення й користувачі сховищ, а репозиторій публічний. Приберіть з індексу: git rm --cached -- v8storagekit.local.yaml. Це не прибирає файл із ІСТОРІЇ попередніх комітів — лише зупиняє подальше витікання.",
        ),
        Err(reason) => c.unchecked_error(
            "overlay-ignored",
            "відстеження v8storagekit.local.yaml",
            &reason,
        ),
    }
}

/// `<воркспейс>/v8project.local.yaml` — файл Уніки з підключенням до бази; живе в КОЖНОМУ воркспейсі.
pub(super) fn local_ignored(c: &mut Collector, root: &Path, ws_path: &str) {
    use crate::config::Level;
    let rel = format!("{ws_path}/v8project.local.yaml");
    let rules = ignored(root, &rel).and_then(|ok| {
        if ok && !c.unignored(root, &rel)?.is_empty() {
            return Ok(false);
        }
        Ok(ok)
    });
    match rules {
        Ok(true) => {}
        Ok(false) => c.add(
            Level::Error,
            "local-ignored",
            format!("{rel} не гітігноровано — це файл Уніки з підключенням до бази, і перший же git add -A застейджить його в публічний репозиторій. Додайте рядок 'v8project.local.yaml' у .gitignore (зразок: templates/gitignore)."),
        ),
        Err(reason) => c.unchecked_error(
            "local-ignored",
            &format!("гітігнорування {rel}"),
            &reason,
        ),
    }
    match c.tracked(root, &rel) {
        Ok(files) if files.is_empty() => {}
        Ok(_) => c.add(
            Level::Error,
            "local-ignored",
            format!("{rel} вже закомічено в git — це файл Уніки з підключенням до бази. Приберіть з індексу: git rm --cached -- {rel}. Це не прибирає файл із ІСТОРІЇ попередніх комітів — лише зупиняє подальше витікання."),
        ),
        Err(reason) => c.unchecked_error(
            "local-ignored",
            &format!("відстеження {rel}"),
            &reason,
        ),
    }
}
