// Перевірки маніфесту й воркспейсів: `manifest` (зведення), `agent-base-required`, `main-branch`, `unique-keys`,
// `undeclared-source`. Фільтр джерел за `truth` — лише через `config::Truth`.

use super::{Collector, Options, guards, hooks, local, selected_sources, sources};
use crate::config::agent_base::InfobaseKind;
use crate::config::manifest::Manifest;
use crate::config::{Context, Level, Truth, Workspace, yaml::eq_ci};
use crate::storage_branch::{BranchState, branch_state};
use std::path::Path;

pub(super) fn check(c: &mut Collector, ctx: &Context, manifest: &Manifest, opts: &Options) {
    summary(c, ctx, manifest, opts);
    agent_base_required(c, ctx, opts);
    main_branch(c, ctx, manifest);
    unique_keys(c, ctx);
    // Далі в PowerShell-порядку: накладка, джерела, воркспейси, хуки.
    let root = Path::new(&ctx.repo_root);
    guards::overlay_ignored(c, root);
    local::overlay_connection(c, ctx);
    for src in selected_sources(ctx, opts) {
        sources::check_source(c, ctx, src);
    }
    // Воркспейси, задекларовані в маніфесті (рішення 6): страж `local-ignored` не залежить від того, чи
    // воркспейс розв'язався; решта перевірок воркспейсу — лише для розв'язаних (помилка префлайту вже error).
    for declared in &manifest.workspaces {
        if opts
            .workspace
            .as_deref()
            .is_some_and(|w| !w.is_empty() && !eq_ci(&declared.path, w))
        {
            continue;
        }
        let resolved = ctx
            .workspaces
            .iter()
            .find(|w| eq_ci(&w.path, &declared.path));
        if let Some(ws) = resolved {
            undeclared_sources(c, manifest, ws);
            local::build_artifacts(c, ctx, ws);
        }
        guards::local_ignored(c, root, &declared.path);
        if let Some(ws) = resolved {
            local::local_audit(c, ctx, ws);
        }
    }
    hooks::check(c, root);
}

/// `manifest`: зведення за МАНІФЕСТОМ, а не за розв'язаним контекстом: воркспейс із помилкою конфігу до
/// `ctx.workspaces` не потрапляє, і «воркспейсів 0, джерел 0» читалось би як «маніфест порожній».
fn summary(c: &mut Collector, ctx: &Context, manifest: &Manifest, opts: &Options) {
    let workspace = opts.workspace.as_deref().filter(|w| !w.is_empty());
    let source = opts.source.as_deref().filter(|s| !s.is_empty());
    let declared: Vec<_> = manifest
        .workspaces
        .iter()
        .filter(|w| workspace.is_none_or(|n| eq_ci(&w.path, n)))
        .collect();
    let sources: Vec<_> = declared
        .iter()
        .flat_map(|w| w.sources.iter())
        .filter(|s| source.is_none_or(|n| eq_ci(&s.key, n)))
        .collect();
    // Групи за truth без регістру, ім'я — перше входження; порядок — ординальний за нижнім регістром.
    let mut groups: Vec<(String, usize)> = Vec::new();
    for s in &sources {
        match groups.iter_mut().find(|(n, _)| eq_ci(n, &s.truth_text)) {
            Some((_, count)) => *count = count.saturating_add(1),
            None => groups.push((s.truth_text.clone(), 1)),
        }
    }
    groups.sort_by_key(|a| a.0.to_lowercase());
    let by_truth = groups
        .iter()
        .map(|(n, k)| format!("{n}: {k}"))
        .collect::<Vec<_>>()
        .join(", ");
    let unresolved = if declared.len() > ctx.workspaces.len() {
        format!(
            " (розв'язано {} — решту див. у помилках конфігу нижче)",
            ctx.workspaces.len()
        )
    } else {
        String::new()
    };
    c.add(
        Level::Info,
        "manifest",
        format!(
            "Маніфест: {} {}, головна гілка {}, воркспейсів {}, джерел у перевірці {} ({by_truth}){unresolved}.",
            manifest.kind.as_str(),
            manifest.label,
            manifest.main_branch,
            declared.len(),
            sources.len(),
        ),
    );
}

/// `agent-base-required`: дамп версії сховища виконується в базі агента, тож для кожного воркспейсу з
/// `truth: storage` база — передумова. Одна знахідка на воркспейс (рішення 11), а не на джерело. warn, не
/// error: репозиторій несуперечливий — просто ще не готовий до sync на ЦІЙ машині. Помилка бази агента
/// (збіг з дев-базою людини, нерозбірне підключення) — error: звіряти `v8project.local.yaml` у `local-audit`
/// недостатньо, підключення законно буває й у закоміченому `v8project.yaml`.
fn agent_base_required(c: &mut Collector, ctx: &Context, opts: &Options) {
    let storage: Vec<_> = selected_sources(ctx, opts)
        .into_iter()
        .filter(|s| s.truth == Truth::Storage)
        .collect();
    let mut done: Vec<&str> = Vec::new();
    for src in &storage {
        let path = src.workspace.as_str();
        if done.contains(&path) {
            continue;
        }
        done.push(path);
        let Some(ws) = ctx.workspaces.iter().find(|w| w.path == path) else {
            continue;
        };
        let keys: Vec<&str> = storage
            .iter()
            .filter(|s| s.workspace == path)
            .map(|s| s.key.as_str())
            .collect();
        let what = if let [one] = keys.as_slice() {
            format!("Джерело '{one}' (truth: storage) вивантажується")
        } else {
            let list = keys
                .iter()
                .map(|k| format!("'{k}'"))
                .collect::<Vec<_>>()
                .join(", ");
            format!("Джерела {list} (truth: storage) вивантажуються")
        };
        match crate::config::agent_base(ctx, ws) {
            Err(e) => c.add(Level::Error, "agent-base-required", format!("{path}: {e}")),
            Ok(None) => c.add(
                Level::Warn,
                "agent-base-required",
                format!(
                    "{what} в контексті базової конфігурації. {}",
                    crate::config::agent_base_missing_message(path)
                ),
            ),
            Ok(Some(ab)) if ab.kind == InfobaseKind::File && !ab.exists => c.add(
                Level::Warn,
                "agent-base-required",
                format!(
                    "{what} в контексті базової конфігурації, а бази агента воркспейсу '{path}' ще немає на диску: v8storagekit:infobase-agent."
                ),
            ),
            Ok(Some(_)) => {}
        }
    }
}

/// `main-branch`: `mainBranch` маніфесту мусить існувати — sync зливає `storage/*` саме в неї. Два рівні:
/// `HEAD` уже на цій гілці, лише ref ще немає (свіжий репозиторій) — законний стан, info; `HEAD` деінде —
/// найімовірніше описка, warn. Збій git — «не перевірено», а не «гілки немає».
fn main_branch(c: &mut Collector, ctx: &Context, manifest: &Manifest) {
    let name = manifest.main_branch.as_str();
    match branch_state(Path::new(&ctx.repo_root), name) {
        Ok(BranchState::Exists) => {}
        Ok(BranchState::Unborn) => c.add(
            Level::Info,
            "main-branch",
            format!(
                "Свіжий репозиторій: головної гілки '{name}' (mainBranch: у v8storagekit.yaml) ще немає — її створить перший коміт до першого kit sync."
            ),
        ),
        Ok(BranchState::Missing) => c.add(
            Level::Warn,
            "main-branch",
            format!(
                "Головної гілки '{name}' (mainBranch: у v8storagekit.yaml) немає в репозиторії, а HEAD указує на іншу гілку — перевірте mainBranch: (описка?), або виправте маніфест, якщо головну гілку перейменовано."
            ),
        ),
        Err(reason) => c.unchecked(
            "main-branch",
            &format!("наявність головної гілки '{name}'"),
            &reason,
        ),
    }
}

/// `unique-keys`: ключі `truth: storage` унікальні в межах репозиторію (гілка `storage/<ключ>` одна).
/// Порівняння без регістру (refs на NTFS — рішення 10); не залежить від `-Workspace`/`-Source`.
fn unique_keys(c: &mut Collector, ctx: &Context) {
    let mut groups: Vec<(String, Vec<&str>)> = Vec::new();
    for src in ctx
        .workspaces
        .iter()
        .flat_map(|w| w.sources.iter())
        .filter(|s| s.truth == Truth::Storage)
    {
        match groups.iter_mut().find(|(k, _)| eq_ci(k, &src.key)) {
            Some((_, list)) => list.push(src.workspace.as_str()),
            None => groups.push((src.key.clone(), vec![src.workspace.as_str()])),
        }
    }
    for (key, list) in groups.iter().filter(|(_, l)| l.len() > 1) {
        c.add(
            Level::Error,
            "unique-keys",
            format!(
                "Ключ '{key}' з truth: storage повторюється у воркспейсах {} — гілка storage/{key} була б спільною. Перейменуйте source-set в одному з них.",
                list.join(", ")
            ),
        );
    }
}

/// `undeclared-source`: зворотний напрямок «v8project.yaml → маніфест». Source-set без запису в маніфесті sync
/// ніколи не дзеркалить. warn, не error: чи це незаявлене джерело, вирішує людина. Звіряється з КЛЮЧАМИ
/// маніфесту, не з розв'язаними джерелами: «оголошене» те, що написала людина.
fn undeclared_sources(c: &mut Collector, manifest: &Manifest, ws: &Workspace) {
    let declared: Vec<&str> = manifest
        .workspaces
        .iter()
        .find(|w| eq_ci(&w.path, &ws.path))
        .map(|w| w.sources.iter().map(|s| s.key.as_str()).collect())
        .unwrap_or_default();
    for set in &ws.project.source_sets {
        if declared.iter().any(|k| eq_ci(k, &set.name)) {
            continue;
        }
        c.add(
            Level::Warn,
            "undeclared-source",
            format!(
                "{ws_path}: source-set '{name}' ({ty}) оголошено у {ws_path}/v8project.yaml, але його немає в маніфесті — kit про це джерело не знає, і sync його не дзеркалить. Заявіть його в v8storagekit.yaml з truth (зразок: templates/v8storagekit.yaml.example) або приберіть source-set. Для truth: git/storage знадобиться рядок '{set_path}/** -text' у .gitattributes, для truth: vendor — '{set_path}/**' у .gitignore.",
                ws_path = ws.path,
                name = set.name,
                ty = set.type_name,
                set_path = set.path,
            ),
        );
    }
}
