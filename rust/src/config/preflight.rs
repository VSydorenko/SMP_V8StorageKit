// Префлайт kit у трьох режимах, вибір джерел і база агента воркспейсу як API фази 2 — як `Resolve-V8RepoRoot`,
// `Invoke-KitPreflight`, `Select-KitSources` (tools/lib). Порядок знахідок, тексти й режими — ті самі.
//
// Режими: `Strict` повертає першу знахідку error зупинкою (`Err`), `Lenient` і `Check` збирають знахідки в
// `Context` (`Check` додатково пропускає `kitVersion` маніфесту окремою знахідкою `kit-version`). Корінь, якого
// немає чи який не git-репозиторій, зупиняє в усіх режимах — `Err` з порожнім `check`.
//
// `config-preflight` (прихована підкоманда, `report_json`) друкує результат цього API з маскою секретів
// (спека §6): пароль — лише ознака «задано», піддерево `dbms` — лише ознака, рядок підключення — розібрана
// форма чи «не розбирається», сирим текстом — ніколи. Секрети тут — типи `Secret`/`SecretTree`/`RawConnection`
// без `Display`; текст дістається лише розібраною формою (`connection::parse`) чи ознакою.
//
// Відомі відмінності від PowerShell (ADR-0014 п. 7): немає нових поверх задач 1–2. Невиміряне наближення:
// впорядкування знахідки `DT-INF` і переліку ключів у помилці `Select-KitSources` (`Sort-Object` у культурі
// людини) відтворено таблицею розділових знаків ICU й нечутливістю до регістру — паритет на корпусі це покаже.

use super::agent_base::{
    AgentBase, AgentBaseCollision, InfobaseKind, WorkspaceRef,
    agent_base_collisions as collisions_of, agent_base_missing_message as missing_of,
    resolve_agent_base, workspace_needs_agent_base as needs_of,
};
use super::connection::{self, Connection, assert_secret_quote_free};
use super::manifest::{Manifest, ProductKind, read_manifest};
use super::overlay::{Overlay, read_overlay};
use super::v8project::{
    self, V8Project, config_problems, join_ps, read_local_infobase, read_v8project,
};
use super::yaml::eq_ci;
use super::{RawConnection, Secret, Truth};
use serde_json::{Value, json};
use std::cmp::Ordering;
use std::os::windows::fs::MetadataExt;
use std::path::Path;

const MANIFEST_FILE_NAME: &str = "v8storagekit.yaml";
const OVERLAY_FILE_NAME: &str = "v8storagekit.local.yaml";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Strict,
    Lenient,
    Check,
}

impl Mode {
    /// `ValidateSet('Strict', 'Lenient', 'Check')` — без регістру.
    pub fn parse(text: &str) -> Option<Mode> {
        match text.to_lowercase().as_str() {
            "strict" => Some(Mode::Strict),
            "lenient" => Some(Mode::Lenient),
            "check" => Some(Mode::Check),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Error,
    Warn,
    Info,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Error => "error",
            Level::Warn => "warn",
            Level::Info => "info",
        }
    }
}

/// Один рядок звіту check/preflight (`New-KitFinding`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub level: Level,
    pub check: String,
    pub message: String,
}

/// Зупинка префлайту. `check` порожній для кореня (не існує чи не git-репозиторій).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreflightStop {
    pub check: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct Source {
    pub key: String,
    pub truth: Truth,
    /// `truth` у написанні файла.
    pub truth_text: String,
    pub type_name: String,
    pub workspace: String,
    pub path: String,
    pub repo_path: String,
    pub full_path: String,
    pub storage_path: Option<String>,
    pub storage_user: Option<String>,
    pub storage_password: Secret,
    pub dump_from: Option<String>,
    /// `storage/<ключ>` лише для `truth: storage`.
    pub branch: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Workspace {
    pub path: String,
    pub full_path: String,
    pub project: V8Project,
    pub sources: Vec<Source>,
}

#[derive(Debug, Clone)]
pub struct Context {
    pub repo_root: String,
    pub manifest_path: String,
    pub overlay_path: Option<String>,
    /// `None`, коли маніфест не прочитано (як `$null` у PowerShell).
    pub manifest: Option<Manifest>,
    pub overlay: Option<Overlay>,
    pub kind: Option<ProductKind>,
    pub label: Option<String>,
    pub main_branch: String,
    pub workspaces: Vec<Workspace>,
    pub findings: Vec<Finding>,
    pub ok: bool,
}

fn stop(check: Option<&str>, message: impl Into<String>) -> PreflightStop {
    PreflightStop {
        check: check.map(str::to_string),
        message: message.into(),
    }
}

/// `Resolve-V8RepoRoot`: корінь існує й має `.git` (тека чи файл worktree).
fn resolve_root(path: &str) -> Result<String, PreflightStop> {
    if !Path::new(path).exists() {
        return Err(stop(
            None,
            format!("Шлях '{path}' не існує — -RepoRoot має вказувати на корінь git-репозиторію."),
        ));
    }
    let resolved = v8project::full_path(path).map_err(|e| stop(None, e.message()))?;
    if !Path::new(&join_ps(&resolved, ".git")).exists() {
        return Err(stop(
            None,
            format!(
                "'{resolved}' не є коренем git-репозиторію (немає .git). Запустіть із кореня репо-споживача або передайте -RepoRoot явно."
            ),
        ));
    }
    Ok(resolved)
}

/// Порядок `Sort-Object` для рядків: нечутливо до регістру, розділові знаки раніше цифр, цифри раніше літер
/// (таблиця ICU), при рівності — малі літери раніше великих.
fn ps_compare(a: &str, b: &str) -> Ordering {
    const PUNCT: &str = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$";
    let primary = |c: char| -> (u8, u32) {
        let lower = c.to_lowercase().next().unwrap_or(c);
        if let Some(i) = PUNCT.chars().position(|p| p == lower) {
            return (0, u32::try_from(i).unwrap_or(0));
        }
        if lower.is_numeric() {
            (1, u32::from(lower))
        } else if lower.is_alphabetic() {
            (2, u32::from(lower))
        } else {
            (0, u32::from(lower).saturating_add(1000))
        }
    };
    a.chars()
        .map(primary)
        .cmp(b.chars().map(primary))
        .then_with(|| {
            a.chars()
                .map(char::is_uppercase)
                .cmp(b.chars().map(char::is_uppercase))
        })
}

fn sort_unique(mut items: Vec<String>) -> Vec<String> {
    items.sort_by(|a, b| ps_compare(a, b));
    items.dedup_by(|a, b| eq_ci(a, b));
    items
}

/// Підтеки кореня, видимі `Get-ChildItem -Directory` (без прихованих і системних; нечитана тека — порожньо).
fn visible_dirs(dir: &Path) -> Vec<String> {
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for entry in read.flatten() {
        let hidden = entry
            .path()
            .symlink_metadata()
            .map(|m| m.file_attributes() & 0x6 != 0)
            .unwrap_or(false);
        if hidden || !entry.path().is_dir() {
            continue;
        }
        if let Some(name) = entry.file_name().to_str() {
            names.push(name.to_string());
        }
    }
    names
}

/// Ознака EDT — `DT-INF/` у корені й на двох рівнях підтек; глибина обмежена навмисно (префлайт іде на кожній команді).
fn dt_inf_found(root: &str) -> Vec<String> {
    let mut found = Vec::new();
    let root_path = Path::new(root);
    if root_path.join("DT-INF").is_dir() {
        found.push("DT-INF/ (у корені)".to_string());
    }
    let level1 = visible_dirs(root_path);
    for d1 in &level1 {
        if root_path.join(d1).join("DT-INF").is_dir() {
            found.push(format!("{d1}/DT-INF"));
        }
    }
    for d1 in &level1 {
        for d2 in visible_dirs(&root_path.join(d1)) {
            if root_path.join(d1).join(&d2).join("DT-INF").is_dir() {
                found.push(format!("{d1}/{d2}/DT-INF"));
            }
        }
    }
    found.sort_by(|a, b| ps_compare(a, b));
    found
}

/// Знахідка `$fail`: у суворому режимі — зупинка, в інших — знахідка error й `ok = false`.
struct Run {
    strict: bool,
    findings: Vec<Finding>,
    ok: bool,
}

impl Run {
    fn fail(&mut self, check: &str, message: impl Into<String>) -> Result<(), PreflightStop> {
        let message = message.into();
        if self.strict {
            return Err(stop(Some(check), message));
        }
        self.findings.push(Finding {
            level: Level::Error,
            check: check.to_string(),
            message,
        });
        self.ok = false;
        Ok(())
    }
}

/// `Invoke-KitPreflight`: маніфест, накладка, воркспейси, відповідність ключів джерел source-set-ам.
pub fn preflight(repo_root: &Path, mode: Mode) -> Result<Context, PreflightStop> {
    let mut run = Run {
        strict: mode == Mode::Strict,
        findings: Vec::new(),
        ok: true,
    };
    let root = resolve_root(&repo_root.to_string_lossy())?;
    let manifest_path = join_ps(&root, MANIFEST_FILE_NAME);
    let mut ctx = Context {
        repo_root: root.clone(),
        manifest_path: manifest_path.clone(),
        overlay_path: None,
        manifest: None,
        overlay: None,
        kind: None,
        label: None,
        main_branch: super::manifest::DEFAULT_MAIN_BRANCH.to_string(),
        workspaces: Vec::new(),
        findings: Vec::new(),
        ok: true,
    };

    let finish = |mut ctx: Context, run: Run| {
        ctx.findings = run.findings;
        ctx.ok = run.ok;
        ctx
    };

    if !Path::new(&manifest_path).is_file() {
        let found = dt_inf_found(&root);
        if !found.is_empty() {
            run.fail(
                "manifest",
                format!(
                    "Вихідники у форматі EDT kit не підтримує ({}): перетворіть їх операцією `convert` раннера Уніки або вивантажте сховище наново.",
                    found.join(", ")
                ),
            )?;
            return Ok(finish(ctx, run));
        }
        run.fail(
            "manifest",
            format!(
                "Маніфест {MANIFEST_FILE_NAME} не знайдено в {root}. Репозиторій не підключено до kit — скопіюйте templates/v8storagekit.yaml.example з теки плагіна (знайти теку: claude plugin list, або /plugin у сесії Claude Code) у корінь репозиторію як {MANIFEST_FILE_NAME}, заповніть і запустіть kit check ще раз. Далі — скіл v8storagekit:onboarding."
            ),
        )?;
        return Ok(finish(ctx, run));
    }
    let manifest = match read_manifest(Path::new(&manifest_path), mode == Mode::Check) {
        Ok(m) => m,
        Err(e) => {
            run.fail("manifest", e.message())?;
            return Ok(finish(ctx, run));
        }
    };
    if manifest.has_kit_version {
        run.fail(
            "kit-version",
            "У маніфесті є поле kitVersion — його прибрано: видаліть рядок kitVersion: з v8storagekit.yaml; версію проєкту тримає .agents/kit.profile.json (v8storagekit.version).",
        )?;
    }
    ctx.kind = Some(manifest.kind);
    ctx.label = Some(manifest.label.clone());
    ctx.main_branch = manifest.main_branch.clone();

    let overlay_path = join_ps(&root, OVERLAY_FILE_NAME);
    if Path::new(&overlay_path).is_file() {
        ctx.overlay_path = Some(overlay_path.clone());
        match read_overlay(Path::new(&overlay_path)) {
            Ok(o) => ctx.overlay = Some(o),
            Err(e) => run.fail("overlay", e.message())?,
        }
    }

    let mut workspaces = Vec::new();
    for ws in &manifest.workspaces {
        let ws_full = join_ps(&root, &ws.path);
        if !Path::new(&ws_full).is_dir() {
            run.fail(
                "workspace",
                format!("Воркспейс '{}' з маніфесту не знайдено в {root}.", ws.path),
            )?;
            continue;
        }
        let project_path = join_ps(&ws_full, v8project::PROJECT_FILE_NAME);
        if !Path::new(&project_path).is_file() {
            run.fail(
                "workspace",
                format!(
                    "У воркспейсі '{}' немає v8project.yaml — структуру джерел описує саме він.",
                    ws.path
                ),
            )?;
            continue;
        }
        let problems = match config_problems(Path::new(&ws_full)) {
            Ok(p) => p,
            Err(e) => {
                run.fail(
                    "workspace",
                    format!(
                        "Конфіг Уніки воркспейсу '{}' не читається: {}",
                        ws.path,
                        e.message()
                    ),
                )?;
                continue;
            }
        };
        for problem in &problems {
            run.fail("workspace", problem.clone())?;
        }
        if !problems.is_empty() {
            continue;
        }
        let project = match read_v8project(Path::new(&project_path)) {
            Ok(p) => p,
            Err(e) => {
                run.fail("workspace", e.message())?;
                continue;
            }
        };

        // `"` у паролі бази агента — відмова тут, а не лише при запуску платформи.
        let local = join_ps(&ws_full, v8project::LOCAL_FILE_NAME);
        let agent_check = read_local_infobase(Path::new(&local)).and_then(|ib| match ib {
            Some(ib) => assert_secret_quote_free(
                &ib.password,
                &format!(
                    "Пароль бази агента ({}/v8project.local.yaml, infobases.origin.password)",
                    ws.path
                ),
            ),
            None => Ok(()),
        });
        if let Err(e) = agent_check {
            run.fail("workspace", e.message())?;
            continue;
        }

        let mut sources = Vec::new();
        for src in &ws.sources {
            let Some(set) = project
                .source_sets
                .iter()
                .find(|s| eq_ci(&s.name, &src.key))
            else {
                let names: Vec<&str> = project
                    .source_sets
                    .iter()
                    .map(|s| s.name.as_str())
                    .collect();
                run.fail(
                    "source",
                    format!(
                        "Ключ sources воркспейсу '{0}' (ім'я не друкується) не відповідає жодному name: source-set у {0}/v8project.yaml (є: {1}).",
                        ws.path,
                        names.join(", ")
                    ),
                )?;
                continue;
            };
            let mut storage_path = src.storage_path.clone();
            let mut storage_user = src.storage_user.clone();
            let mut storage_password = Secret::new("");
            let ov = if src.truth == Truth::Storage {
                ctx.overlay.as_ref().and_then(|o| o.storage(&src.key))
            } else {
                None
            };
            if let Some(ov) = ov {
                if let Some(p) = ov.path.as_ref().filter(|p| !p.is_empty()) {
                    storage_path = Some(p.clone());
                }
                if let Some(u) = ov.user.as_ref().filter(|u| !u.is_empty()) {
                    storage_user = Some(u.clone());
                }
                if let Some(pw) = ov.password.as_ref().filter(|p| !p.is_empty()) {
                    // `"` у паролі сховища — відмова ДО першого запуску платформи.
                    let origin = format!(
                        "Пароль сховища (накладка {OVERLAY_FILE_NAME}, storages.{}.password)",
                        src.key
                    );
                    if let Err(e) = assert_secret_quote_free(pw, &origin) {
                        run.fail("overlay", e.message())?;
                        continue;
                    }
                    storage_password = pw.clone();
                }
            }
            sources.push(Source {
                key: src.key.clone(),
                truth: src.truth,
                truth_text: src.truth_text.clone(),
                type_name: set.type_name.clone(),
                workspace: ws.path.clone(),
                path: set.path.clone(),
                repo_path: format!("{}/{}", ws.path, set.path),
                full_path: set.full_path.to_string_lossy().into_owned(),
                storage_path,
                storage_user,
                storage_password,
                dump_from: src.dump_from.clone(),
                branch: (src.truth == Truth::Storage).then(|| format!("storage/{}", src.key)),
            });
        }
        workspaces.push(Workspace {
            path: ws.path.clone(),
            full_path: ws_full,
            project,
            sources,
        });
    }
    ctx.workspaces = workspaces;
    ctx.manifest = Some(manifest);
    Ok(finish(ctx, run))
}

/// `Select-KitSources`: джерела за `-Workspace` / `-Source` / `-Truth`. Порожній рядок — «не задано», як у PowerShell.
pub fn select_sources<'a>(
    ctx: &'a Context,
    workspace: Option<&str>,
    source: Option<&str>,
    truth: &[Truth],
) -> Result<Vec<&'a Source>, String> {
    let mut workspaces: Vec<&Workspace> = ctx.workspaces.iter().collect();
    let workspace = workspace.filter(|w| !w.is_empty());
    if let Some(w) = workspace {
        let selected: Vec<&Workspace> = workspaces
            .iter()
            .copied()
            .filter(|x| eq_ci(&x.path, w))
            .collect();
        if selected.is_empty() {
            let names: Vec<&str> = workspaces.iter().map(|x| x.path.as_str()).collect();
            return Err(format!(
                "Воркспейсу '{w}' немає в маніфесті. Є: {}.",
                names.join(", ")
            ));
        }
        workspaces = selected;
    }
    let mut sources: Vec<&Source> = workspaces.iter().flat_map(|w| w.sources.iter()).collect();
    if let Some(s) = source.filter(|s| !s.is_empty()) {
        let matched: Vec<&Source> = sources
            .iter()
            .copied()
            .filter(|x| eq_ci(&x.key, s))
            .collect();
        if matched.is_empty() {
            let scope = workspace
                .map(|w| format!("у воркспейсі '{w}'"))
                .unwrap_or_else(|| "у маніфесті".to_string());
            let keys = sort_unique(sources.iter().map(|x| x.key.clone()).collect());
            return Err(format!(
                "Джерела '{s}' немає {scope}. Є: {}.",
                keys.join(", ")
            ));
        }
        if matched.len() > 1 {
            let names: Vec<&str> = matched.iter().map(|x| x.workspace.as_str()).collect();
            return Err(format!(
                "Ключ '{s}' є у кількох воркспейсах: {} — уточніть -Workspace.",
                names.join(", ")
            ));
        }
        sources = matched;
    }
    if !truth.is_empty() {
        sources.retain(|x| truth.contains(&x.truth));
    }
    Ok(sources)
}

/// `Select-KitSources` для тексту `-Truth`: значення поза словником нічого не вибирають (`-contains`), а не
/// вимикають фільтр.
pub fn select_sources_by_text<'a>(
    ctx: &'a Context,
    workspace: Option<&str>,
    source: Option<&str>,
    truth: &[String],
) -> Result<Vec<&'a Source>, String> {
    let parsed: Vec<Truth> = truth.iter().filter_map(|t| Truth::parse(t)).collect();
    let mut selected = select_sources(ctx, workspace, source, &parsed)?;
    if !truth.is_empty() && parsed.is_empty() {
        selected.clear();
    }
    Ok(selected)
}

/// `Resolve-KitAgentBase`: база агента воркспейсу плюс аудит «це не база людини». `None` — бази не налаштовано.
pub fn agent_base(ctx: &Context, workspace: &Workspace) -> Result<Option<AgentBase>, String> {
    resolve_agent_base(ctx.overlay.as_ref(), &workspace.path, &workspace.project)
        .map_err(|e| e.message().to_string())
}

/// `Find-KitAgentBaseCollisions`: перетини бази агента з базами й пам'яттю раннера ІНШИХ воркспейсів.
pub fn agent_base_collisions(
    ctx: &Context,
    workspace: &Workspace,
) -> Result<Vec<AgentBaseCollision>, String> {
    let all: Vec<WorkspaceRef<'_>> = ctx
        .workspaces
        .iter()
        .map(|w| WorkspaceRef {
            path: &w.path,
            project: &w.project,
        })
        .collect();
    let current = WorkspaceRef {
        path: &workspace.path,
        project: &workspace.project,
    };
    collisions_of(ctx.overlay.as_ref(), &all, &current).map_err(|e| e.message().to_string())
}

/// `Test-KitWorkspaceNeedsAgentBase`.
pub fn workspace_needs_agent_base(workspace: &Workspace) -> bool {
    needs_of(&workspace.project)
}

/// `New-KitAgentBaseMissingMessage`.
pub fn agent_base_missing_message(ws: &str) -> String {
    missing_of(ws)
}

/// Ознака: у `v8project.local.yaml` воркспейсу є рядок, що починається з `devInfobase:` (сирий текст, не YAML).
pub fn local_has_dev_infobase_line(workspace: &Workspace) -> bool {
    v8project::local_has_dev_infobase_line(Path::new(&workspace.full_path))
}

// ---------------------------------------------------------------------------------------------------------
// JSON прихованої підкоманди `config-preflight` — з маскою секретів.

fn mask_connection(raw: &RawConnection) -> Value {
    match connection::parse(raw) {
        Ok(Connection::File { file }) => json!({ "parses": true, "kind": "file", "file": file }),
        Ok(Connection::Server { server, reference }) => {
            json!({ "parses": true, "kind": "server", "server": server, "ref": reference })
        }
        Err(e) => json!({ "parses": false, "credentials": e.is_credentials() }),
    }
}

fn mask_agent_base(b: &AgentBase) -> Value {
    json!({
        "workspace": b.workspace,
        "connection": mask_connection(&b.connection),
        "user": b.user,
        "passwordSet": !b.password.is_empty(),
        "dbmsSet": b.dbms.is_some(),
        "origin": b.origin,
        "kind": match b.kind { InfobaseKind::File => "file", InfobaseKind::Server => "server" },
        "path": b.path,
        "ibSwitch": b.ib_switch,
        "exists": b.exists,
    })
}

fn mask_source(s: &Source) -> Value {
    json!({
        "key": s.key,
        "truth": s.truth_text,
        "type": s.type_name,
        "workspace": s.workspace,
        "path": s.path,
        "repoPath": s.repo_path,
        "fullPath": s.full_path,
        "storagePath": s.storage_path,
        "storageUser": s.storage_user,
        "storagePasswordSet": !s.storage_password.is_empty(),
        "dumpFrom": s.dump_from,
        "branch": s.branch,
    })
}

fn mask_overlay(o: &Overlay) -> Value {
    json!({
        "path": o.path.to_string_lossy(),
        "infobases": o.infobases.iter().map(|i| json!({ "name": i.name, "connection": mask_connection(&i.connection), "user": i.user })).collect::<Vec<_>>(),
        "storages": o.storages.iter().map(|s| json!({ "key": s.key, "path": s.path, "user": s.user, "passwordSet": s.password.as_ref().is_some_and(|p| !p.is_empty()) })).collect::<Vec<_>>(),
        "workspaces": o.workspaces.iter().map(|w| json!({ "path": w.path, "agentBaseTemplate": w.agent_base_template })).collect::<Vec<_>>(),
    })
}

fn mask_workspace(ctx: &Context, ws: &Workspace) -> Value {
    let base = match agent_base(ctx, ws) {
        Ok(b) => json!({ "base": b.as_ref().map(mask_agent_base), "error": null }),
        Err(e) => json!({ "base": null, "error": e }),
    };
    let collisions = match agent_base_collisions(ctx, ws) {
        Ok(list) => json!({
            "items": list.iter().map(|c| json!({ "other": c.other, "kind": c.kind.as_str(), "server": c.server })).collect::<Vec<_>>(),
            "error": null,
        }),
        Err(e) => json!({ "items": [], "error": e }),
    };
    json!({
        "path": ws.path,
        "fullPath": ws.full_path,
        "project": {
            "path": ws.project.path.to_string_lossy(),
            "directory": ws.project.directory.to_string_lossy(),
            "workPath": ws.project.work_path,
            "providersSet": ws.project.providers.is_some(),
            "sourceSets": ws.project.source_sets.iter().map(|s| json!({
                "name": s.name, "type": s.type_name, "path": s.path, "fullPath": s.full_path.to_string_lossy(),
            })).collect::<Vec<_>>(),
        },
        "sources": ws.sources.iter().map(mask_source).collect::<Vec<_>>(),
        "needsAgentBase": workspace_needs_agent_base(ws),
        "agentBaseMissingMessage": agent_base_missing_message(&ws.path),
        "localHasDevInfobaseLine": local_has_dev_infobase_line(ws),
        "agentBase": base,
        "collisions": collisions,
    })
}

/// Результат `config-preflight`: зупинка (`stop`) або контекст, знахідки, вибрані джерела, база агента й перетини
/// кожного воркспейсу. Секрети замасковано (див. шапку).
pub fn report_json(
    repo_root: &Path,
    mode: Mode,
    workspace: Option<&str>,
    source: Option<&str>,
    truth: &[String],
) -> Value {
    let ctx = match preflight(repo_root, mode) {
        Ok(c) => c,
        Err(s) => return json!({ "stop": { "check": s.check, "message": s.message } }),
    };
    let (selected, select_error) = match select_sources_by_text(&ctx, workspace, source, truth) {
        Ok(list) => (
            list.iter().map(|s| mask_source(s)).collect::<Vec<_>>(),
            Value::Null,
        ),
        Err(e) => (Vec::new(), Value::String(e)),
    };
    json!({
        "stop": null,
        "context": {
            "repoRoot": ctx.repo_root,
            "manifestPath": ctx.manifest_path,
            "overlayPath": ctx.overlay_path,
            "manifest": ctx.manifest.as_ref().map(|m| json!({
                "version": m.version,
                "kind": m.kind.as_str(),
                "label": m.label,
                "mainBranch": m.main_branch,
                "hasKitVersion": m.has_kit_version,
                "workspaces": m.workspaces.iter().map(|w| w.path.clone()).collect::<Vec<_>>(),
            })),
            "overlay": ctx.overlay.as_ref().map(mask_overlay),
            "kind": ctx.kind.map(ProductKind::as_str),
            "label": ctx.label,
            "mainBranch": ctx.main_branch,
            "ok": ctx.ok,
            "workspaces": ctx.workspaces.iter().map(|w| mask_workspace(&ctx, w)).collect::<Vec<_>>(),
        },
        "findings": ctx.findings.iter().map(|f| json!({ "level": f.level.as_str(), "check": f.check, "message": f.message })).collect::<Vec<_>>(),
        "selected": selected,
        "selectError": select_error,
    })
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("kit-pre-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join(".git")).unwrap();
        d
    }

    const MANIFEST: &str = "version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources:\n      cf: { truth: storage, storage: { path: 'C:\\st' } }\n      ext: { truth: git }\n";
    const PROJECT: &str = "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: cf, type: CONFIGURATION, path: cf }\n  - { name: ext, type: EXTENSION, path: ext }\n";

    fn repo(tag: &str, manifest: &str, project: Option<&str>) -> std::path::PathBuf {
        let d = tmp(tag);
        std::fs::write(d.join(MANIFEST_FILE_NAME), manifest).unwrap();
        if let Some(p) = project {
            std::fs::create_dir_all(d.join("ws")).unwrap();
            std::fs::write(d.join("ws").join("v8project.yaml"), p).unwrap();
        }
        d
    }

    #[test]
    fn root_stops_in_every_mode_and_strict_stops_on_first_error() {
        for mode in [Mode::Strict, Mode::Lenient, Mode::Check] {
            let missing =
                std::env::temp_dir().join(format!("kit-pre-no-such-{}", std::process::id()));
            let e = preflight(&missing, mode).unwrap_err();
            assert!(e.check.is_none() && e.message.contains("не існує"), "{e:?}");
            let plain = std::env::temp_dir();
            let no_git = tmp("nogit");
            std::fs::remove_dir_all(no_git.join(".git")).unwrap();
            let e = preflight(&no_git, mode).unwrap_err();
            assert!(
                e.check.is_none() && e.message.contains("не є коренем git-репозиторію"),
                "{e:?} {plain:?}"
            );
        }
        // Маніфесту немає: Strict — зупинка з check, Lenient — знахідка й ok = false.
        let d = tmp("nomanifest");
        let e = preflight(&d, Mode::Strict).unwrap_err();
        assert_eq!(e.check.as_deref(), Some("manifest"));
        let c = preflight(&d, Mode::Lenient).unwrap();
        assert!(
            !c.ok
                && c.manifest.is_none()
                && c.findings.len() == 1
                && c.findings[0].check == "manifest"
        );
    }

    #[test]
    fn dt_inf_is_found_on_two_levels_but_not_three() {
        let d = tmp("dtinf");
        std::fs::create_dir_all(d.join("b").join("DT-INF")).unwrap();
        std::fs::create_dir_all(d.join("a").join("x").join("DT-INF")).unwrap();
        std::fs::create_dir_all(d.join("c").join("y").join("z").join("DT-INF")).unwrap();
        let c = preflight(&d, Mode::Lenient).unwrap();
        let m = &c.findings[0].message;
        assert!(m.contains("(a/x/DT-INF, b/DT-INF)"), "{m}");
        assert!(
            !m.contains("DT-INF/ (у корені)") && !m.contains("z/DT-INF"),
            "{m}"
        );
    }

    #[test]
    fn kit_version_is_a_manifest_stop_unless_check() {
        let d = repo(
            "kitver",
            &format!("kitVersion: 1\n{MANIFEST}"),
            Some(PROJECT),
        );
        std::fs::create_dir_all(d.join("ws").join("cf")).unwrap();
        let strict = preflight(&d, Mode::Strict).unwrap_err();
        assert_eq!(strict.check.as_deref(), Some("manifest"));
        let lenient = preflight(&d, Mode::Lenient).unwrap();
        assert!(
            !lenient.ok && lenient.manifest.is_none() && lenient.findings[0].check == "manifest"
        );
        let check = preflight(&d, Mode::Check).unwrap();
        assert_eq!(check.findings[0].check, "kit-version");
        assert!(!check.ok && check.manifest.is_some() && check.workspaces.len() == 1);
    }

    #[test]
    fn builds_sources_and_selects_them() {
        let d = repo("ok", MANIFEST, Some(PROJECT));
        let c = preflight(&d, Mode::Strict).unwrap();
        assert!(c.ok && c.findings.is_empty());
        let s = &c.workspaces[0].sources;
        assert_eq!(s[0].branch.as_deref(), Some("storage/cf"));
        assert_eq!(s[1].branch, None);
        assert_eq!(s[0].repo_path, "ws/cf");
        assert_eq!(select_sources(&c, None, Some("EXT"), &[]).unwrap().len(), 1);
        assert_eq!(
            select_sources(&c, Some("ws"), None, &[Truth::Git]).unwrap()[0].key,
            "ext"
        );
        assert!(
            select_sources(&c, None, Some("nope"), &[])
                .unwrap_err()
                .contains("Є: cf, ext.")
        );
        assert!(
            select_sources(&c, Some("zz"), None, &[])
                .unwrap_err()
                .contains("Воркспейсу 'zz'")
        );
        // Значення -Truth поза словником нічого не вибирає (а не вимикає фільтр).
        assert!(
            select_sources_by_text(&c, None, None, &["bogus".into()])
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            select_sources_by_text(&c, None, None, &[]).unwrap().len(),
            2
        );
    }

    #[test]
    fn lenient_collects_workspace_and_source_findings_in_order() {
        let d = repo(
            "findings",
            MANIFEST,
            Some(
                "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: cf, type: CONFIGURATION, path: cf }\n",
            ),
        );
        let c = preflight(&d, Mode::Lenient).unwrap();
        assert!(!c.ok);
        assert_eq!(c.findings.len(), 1);
        assert_eq!(c.findings[0].check, "source");
        assert_eq!(c.workspaces[0].sources.len(), 1);
        let strict = preflight(&d, Mode::Strict).unwrap_err();
        assert_eq!(strict.check.as_deref(), Some("source"));
    }

    // Інваріант §6: у JSON підкоманди пароль, дбмс і рядок підключення сирим текстом не з'являються.
    #[test]
    fn json_masks_passwords_dbms_and_raw_connections() {
        let d = repo("mask", MANIFEST, Some(PROJECT));
        let marker = "МАРКЕР7";
        std::fs::write(
            d.join("ws").join("v8project.local.yaml"),
            format!("infobases:\n  origin:\n    connection: 'Srvr=s;Ref=b;Usr={marker}'\n    password: {marker}\n    dbms: {{ user: {marker}, password: {marker} }}\n"),
        )
        .unwrap();
        std::fs::write(
            d.join("v8storagekit.local.yaml"),
            format!("infobases:\n  dev: {{ connection: 'File=C:\\h;Pwd={marker}' }}\nstorages:\n  cf: {{ password: {marker} }}\n"),
        )
        .unwrap();
        let text = report_json(&d, Mode::Lenient, None, None, &[]).to_string();
        assert!(!text.contains(marker), "{text}");
        assert!(text.contains("\"storagePasswordSet\":true"), "{text}");
        assert!(text.contains("\"parses\":false"), "{text}");
    }

    // Контроль, що вміє впасти: без маски (`expose`) той самий маркер у виводі був би видно — тест маски не порожній.
    #[test]
    fn mask_control_would_detect_a_leak() {
        let leaky = format!("{{\"password\":\"{}\"}}", Secret::new("МАРКЕР7").expose());
        assert!(leaky.contains("МАРКЕР7"));
    }
}
