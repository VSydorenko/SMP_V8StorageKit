// Тести модуля `check` (блок B3, задача 1): коди 0/1/2/3, машина (`unica-version`, `runner-version`, стеля
// `version`), зведення маніфесту, `agent-base-required`, `main-branch`, `unique-keys`, `undeclared-source`.
// Лише синтетичні репозиторії (справжній git у тимчасовій теці), фальшивий реєстр і фальшивий раннер.

use kit::check::{self, Options, Report};
use kit::config::{self, Finding, Level, Mode};
use kit::runner;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const FAKE: &str = env!("CARGO_BIN_EXE_fake-runner");

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("kit-check-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Репозиторій із першим комітом на гілці `branch` (`None` — без коміту: свіжий).
fn init_repo(dir: &Path, branch: &str, commit: bool) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", branch]);
    if commit {
        git(
            dir,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "i",
            ],
        );
    }
}

/// Воркспейс: тека з `v8project.yaml`, де source-set — ключі `sets` (тип CONFIGURATION).
fn write_workspace(root: &Path, ws: &str, sets: &[&str]) {
    let dir = root.join(ws);
    std::fs::create_dir_all(&dir).unwrap();
    let list: Vec<String> = sets
        .iter()
        .map(|k| format!("  - {{ name: {k}, type: CONFIGURATION, path: {k} }}\n"))
        .collect();
    std::fs::write(
        dir.join("v8project.yaml"),
        format!(
            "providers: {{ push: designer, pull: designer, download: designer }}\nsource-set:\n{}",
            list.concat()
        ),
    )
    .unwrap();
}

/// Маніфест: воркспейси з джерелами `(ключ, truth)`; для `storage` — каталог сховища.
fn write_manifest(root: &Path, main_branch: Option<&str>, workspaces: &[(&str, &[(&str, &str)])]) {
    let mut text = String::from("version: 1\nproduct: P\n");
    if let Some(b) = main_branch {
        text.push_str(&format!("mainBranch: {b}\n"));
    }
    text.push_str("workspaces:\n");
    for (path, sources) in workspaces {
        text.push_str(&format!("  - path: {path}\n    sources:\n"));
        for (key, truth) in *sources {
            match *truth {
                "storage" => text.push_str(&format!(
                    "      {key}: {{ truth: storage, storage: {{ path: 'C:\\st' }} }}\n"
                )),
                "git" => text.push_str(&format!(
                    "      {key}: {{ truth: git }}
"
                )),
                other => text.push_str(&format!(
                    "      {key}: {{ truth: {other}, dump: {{ from: dev }} }}\n"
                )),
            }
        }
    }
    std::fs::write(root.join("v8storagekit.yaml"), text).unwrap();
    write_guard_files(root, workspaces);
}

/// `.gitignore` и `.gitattributes` здорового репозитория: накладка и `v8project.local.yaml` под ігнором, vendor —
/// ігнорується, решта дерев — під `-text`. Файли не комітяться: правила читаються з робочого дерева.
fn write_guard_files(root: &Path, workspaces: &[(&str, &[(&str, &str)])]) {
    let mut ignore = String::from(
        "v8storagekit.local.yaml
v8project.local.yaml
",
    );
    let mut attrs = String::new();
    for (path, sources) in workspaces {
        for (key, truth) in *sources {
            if *truth == "vendor" {
                ignore.push_str(&format!(
                    "{path}/{key}/**
"
                ));
            } else {
                attrs.push_str(&format!(
                    "{path}/{key}/** -text
"
                ));
            }
        }
    }
    std::fs::write(root.join(".gitignore"), ignore).unwrap();
    std::fs::write(root.join(".gitattributes"), attrs).unwrap();
}

/// Фальшива Уніка: тека встановлення з фальшивим раннером (версія `runner_version`) і реєстр на неї.
/// Повертає (реєстр, шлях раннера).
fn install_unica(
    tmp: &TempDir,
    scope: &str,
    project: Option<&Path>,
    unica_version: &str,
    runner_version: &str,
) -> (PathBuf, PathBuf) {
    let install = tmp.0.join(format!("unica-{scope}-{unica_version}"));
    let dir = install
        .join("bin")
        .join("win-x64")
        .join("v8-runner-windows-x86_64");
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("v8-runner.exe");
    std::fs::copy(FAKE, &exe).unwrap();
    std::fs::write(dir.join("version.txt"), runner_version).unwrap();
    let mut rec = json!({"scope": scope, "version": unica_version, "installPath": install});
    if let Some(p) = project {
        rec["projectPath"] = json!(p);
    }
    let registry = tmp.0.join("installed_plugins.json");
    std::fs::write(
        &registry,
        json!({"version": 2, "plugins": {"unica@unica": [rec]}}).to_string(),
    )
    .unwrap();
    (registry, exe)
}

fn opts(registry: &Path) -> Options {
    Options {
        workspace: None,
        source: None,
        registry: registry.to_path_buf(),
        runner: None,
    }
}

fn run_check(root: &Path, o: &Options) -> Result<Report, check::UsageError> {
    let ctx = config::preflight(root, Mode::Check).unwrap();
    check::run(&ctx, o)
}

fn by<'a>(r: &'a Report, id: &str) -> Vec<&'a Finding> {
    r.findings.iter().filter(|f| f.check == id).collect()
}

/// Здоровий репозиторій: гілка `main` із комітом, один воркспейс, Уніка 0.16 з раннером 0.18.
struct Healthy {
    tmp: TempDir,
    root: PathBuf,
    registry: PathBuf,
}

/// Комітить файл у дерево джерела, потім видаляє з диска кореневий об'єкт-дерево `HEAD`: ref і індекс цілі, а
/// `ls-tree HEAD` падає — точковий збій git лише в перевірках, що читають дерево коміту.
fn break_head_tree(root: &Path) {
    let file = root.join("ws").join("cf").join("Configuration.xml");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, "<x/>").unwrap();
    git(root, &["add", "--", "ws/cf/Configuration.xml"]);
    git(
        root,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "f",
        ],
    );
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "HEAD^{tree}"])
        .output()
        .unwrap();
    let sha = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let object = root
        .join(".git")
        .join("objects")
        .join(&sha[..2])
        .join(&sha[2..]);
    let mut perms = std::fs::metadata(&object).unwrap().permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    // Windows-ціль: лише знімається атрибут «лише читання»
    perms.set_readonly(false);
    std::fs::set_permissions(&object, perms).unwrap();
    std::fs::remove_file(&object).unwrap();
}

/// Хуки плагіна в `.githooks` як у здорового репозиторію: копії шаблонів, закомічені з бітом виконання, і
/// `core.hooksPath`. Шаблони — з дерева розробки (так їх бачить і сам `check` від `current_exe`).
fn install_hooks(root: &Path) {
    let templates = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("templates")
        .join("githooks");
    let dir = root.join(".githooks");
    std::fs::create_dir_all(&dir).unwrap();
    for name in ["pre-commit", "pre-merge-commit"] {
        std::fs::copy(templates.join(name), dir.join(name)).unwrap();
        let rel = format!(".githooks/{name}");
        git(root, &["add", "--", &rel]);
        git(root, &["update-index", "--chmod=+x", "--", &rel]);
    }
    git(
        root,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "hooks",
        ],
    );
    git(root, &["config", "core.hooksPath", ".githooks"]);
}

fn healthy(tag: &str) -> Healthy {
    let tmp = TempDir::new(tag);
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    install_hooks(&root);
    write_workspace(&root, "ws", &["cf"]);
    write_manifest(&root, None, &[("ws", &[("cf", "storage")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    Healthy {
        tmp,
        root,
        registry,
    }
}

// ---- Коди ----

#[test]
fn exit_codes_0_1_3_follow_errors_and_unchecked() {
    // 0: немає error і немає «не перевірено» (agent-base-required — лише warn).
    let h = healthy("codes");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    assert_eq!(r.code, 0, "{:?}", r.findings);
    assert!(r.not_checked.is_empty());
    assert_eq!(by(&r, "agent-base-required").len(), 1);

    // 1: є error (Уніки немає — runner-version).
    let missing = h.tmp.0.join("нема.json");
    let r = run_check(&h.root, &opts(&missing)).unwrap();
    assert_eq!(r.code, 1);
    assert_eq!(by(&r, "runner-version")[0].level, Level::Error);

    // 3: немає error, але git відповів збоєм у неохоронній перевірці — «не перевірено», а не «колізій немає».
    break_head_tree(&h.root);
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let cc = by(&r, "case-collision");
    assert_eq!(cc.len(), 1, "{:?}", r.findings);
    assert_eq!(cc[0].level, Level::Warn);
    assert!(
        cc[0]
            .message
            .starts_with("не перевірено: ws/cf: регістр шляхів у HEAD — git ls-tree "),
        "{}",
        cc[0].message
    );
    // Той самий збій (немає кореневого дерева HEAD) бачить і перевірка режиму хуків у HEAD: по одній на хук.
    assert_eq!(r.not_checked.len(), 3, "{:?}", r.findings);
    assert_eq!(by(&r, "hooks").len(), 2, "{:?}", r.findings);
    assert!(
        by(&r, "hooks")
            .iter()
            .all(|f| f.level == Level::Warn && f.message.starts_with("не перевірено: "))
    );
    assert_eq!(r.code, 3, "{:?}", r.findings);

    // error сильніший за «не перевірено»: код 1.
    let r = run_check(&h.root, &opts(&missing)).unwrap();
    assert_eq!(r.code, 1);
    assert!(!r.not_checked.is_empty());
}

#[test]
fn names_outside_the_manifest_are_usage_errors_code_2() {
    let h = healthy("names");
    let mut o = opts(&h.registry);
    o.workspace = Some("Nope".into());
    let e = run_check(&h.root, &o).unwrap_err();
    assert_eq!(e.to_string(), "Воркспейсу 'Nope' немає в маніфесті. Є: ws.");

    o.workspace = None;
    o.source = Some("zzz".into());
    let e = run_check(&h.root, &o).unwrap_err();
    assert_eq!(e.to_string(), "Джерела 'zzz' немає у маніфесті. Є: cf.");

    // Ім'я без регістру збігається.
    o.workspace = Some("WS".into());
    o.source = Some("CF".into());
    assert!(run_check(&h.root, &o).is_ok());
}

#[test]
fn ambiguous_key_without_workspace_is_usage_error() {
    let tmp = TempDir::new("ambig");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "a", &["cf"]);
    write_workspace(&root, "b", &["cf"]);
    write_manifest(
        &root,
        None,
        &[("a", &[("cf", "storage")]), ("b", &[("cf", "storage")])],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let mut o = opts(&registry);
    o.source = Some("cf".into());
    let e = run_check(&root, &o).unwrap_err();
    assert_eq!(
        e.to_string(),
        "Ключ 'cf' є у кількох воркспейсах: a, b — уточніть -Workspace."
    );
    // З уточненням — звичайний звіт.
    o.workspace = Some("a".into());
    assert!(run_check(&root, &o).is_ok());
}

#[test]
fn name_in_manifest_but_unresolved_is_a_report_not_usage_error() {
    // Воркспейс b є в маніфесті, але теки немає: помилка префлайту, код 1, а не код 2; решта звіту друкується.
    let tmp = TempDir::new("unres");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "a", &["cf"]);
    write_manifest(
        &root,
        None,
        &[("a", &[("cf", "storage")]), ("b", &[("ext", "storage")])],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let mut o = opts(&registry);
    o.workspace = Some("b".into());
    o.source = Some("ext".into());
    let r = run_check(&root, &o).unwrap();
    assert_eq!(r.code, 1, "{:?}", r.findings);
    // Зведення рахує за маніфестом, розв'язаних менше — про це сказано (як у PowerShell, -Workspace не звужує
    // порівняння з числом розв'язаних).
    o.workspace = None;
    let r = run_check(&root, &o).unwrap();
    assert!(r.findings.iter().any(|f| f.level == Level::Error));
    let m = by(&r, "manifest");
    assert_eq!(m.len(), 1);
    assert!(
        m[0].message.contains("воркспейсів 2, джерел у перевірці 1")
            && m[0]
                .message
                .contains("(розв'язано 1 — решту див. у помилках конфігу нижче)"),
        "{}",
        m[0].message
    );
}

#[test]
fn unread_manifest_gives_error_report_code_1_not_usage_error() {
    let tmp = TempDir::new("nomanifest");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    std::fs::write(root.join("v8storagekit.yaml"), "version: [\n").unwrap();
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let mut o = opts(&registry);
    o.workspace = Some("whatever".into());
    let r = run_check(&root, &o).unwrap();
    assert_eq!(r.code, 1);
    assert!(
        r.findings
            .iter()
            .any(|f| f.level == Level::Error && f.check == "manifest"),
        "{:?}",
        r.findings
    );
}

// ---- Машина ----

#[test]
fn machine_checks_report_unica_and_runner_verdicts() {
    let h = healthy("machine");
    // Уніка 0.16.0 + раннер 0.18.1: знахідок машини немає.
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    assert!(by(&r, "unica-version").is_empty() && by(&r, "runner-version").is_empty());

    // Уніка новіша — warn; старіша — error; раннер іншого мінору — warn.
    let (reg, _) = install_unica(&h.tmp, "user", None, "0.17.2", "0.19.0");
    let r = run_check(&h.root, &opts(&reg)).unwrap();
    assert_eq!(by(&r, "unica-version")[0].level, Level::Warn);
    assert_eq!(by(&r, "runner-version")[0].level, Level::Warn);
    let (reg, _) = install_unica(&h.tmp, "user", None, "0.15.0", "0.18.1");
    let r = run_check(&h.root, &opts(&reg)).unwrap();
    assert_eq!(by(&r, "unica-version")[0].level, Level::Error);
    assert_eq!(r.code, 1);
}

#[test]
fn missing_unica_is_reported_only_by_runner_version() {
    let h = healthy("nounica");
    let r = run_check(&h.root, &opts(&h.tmp.0.join("нема.json"))).unwrap();
    assert!(by(&r, "unica-version").is_empty());
    let rv = by(&r, "runner-version");
    assert_eq!(rv.len(), 1);
    assert_eq!(rv[0].level, Level::Error);
    assert!(rv[0].message.starts_with("Раннер Уніки недоступний: "));
}

#[test]
fn project_scope_unica_is_seen_through_the_repo_root() {
    // Уніка лише зі scope project, чий projectPath — корінь репозиторію: бачиться (виправлений дефект B2);
    // з чужим projectPath — не бачиться.
    let h = healthy("scope");
    let (reg, _) = install_unica(&h.tmp, "project", Some(&h.root), "0.16.0", "0.18.1");
    let r = run_check(&h.root, &opts(&reg)).unwrap();
    assert!(by(&r, "runner-version").is_empty(), "{:?}", r.findings);
    assert!(by(&r, "unica-version").is_empty());

    let other = h.tmp.0.join("інший");
    let (reg, _) = install_unica(&h.tmp, "project", Some(&other), "0.16.0", "0.18.1");
    let r = run_check(&h.root, &opts(&reg)).unwrap();
    assert_eq!(by(&r, "runner-version")[0].level, Level::Error);
}

#[test]
fn ambiguous_unica_is_error_in_both_checks_with_candidates() {
    let h = healthy("ambig-unica");
    let reg = h.tmp.0.join("two.json");
    let (i1, i2) = (h.tmp.0.join("u1"), h.tmp.0.join("u2"));
    std::fs::write(
        &reg,
        json!({"plugins": {"unica@unica": [
            {"scope": "user", "version": "0.16.0", "installPath": i1},
            {"scope": "project", "version": "0.16.1", "installPath": i2, "projectPath": h.root},
        ]}})
        .to_string(),
    )
    .unwrap();
    let r = run_check(&h.root, &opts(&reg)).unwrap();
    for id in ["unica-version", "runner-version"] {
        let f = by(&r, id);
        assert_eq!(f.len(), 1, "{id}: {:?}", r.findings);
        assert_eq!(f[0].level, Level::Error);
        assert!(f[0].message.contains("scope user") && f[0].message.contains("scope project"));
    }
    assert_eq!(r.code, 1);
}

#[test]
fn explicit_runner_overrides_the_registry() {
    let h = healthy("explicit");
    let (_, exe) = install_unica(&h.tmp, "user", None, "0.16.0", "0.18.1");
    let mut o = opts(&h.tmp.0.join("нема.json"));
    o.runner = Some(exe);
    let r = run_check(&h.root, &o).unwrap();
    assert!(by(&r, "runner-version").is_empty(), "{:?}", r.findings);
}

/// Рішення 4: завислий `--version` не вішає check. Контроль, що тест уміє впасти: той самий фальшивий раннер без
/// стелі спав би 60 с (перевіряється тут же прямим `exec` зі стелею 1 с: без стелі в `version` тест червоний).
#[test]
fn hanging_runner_version_is_cut_by_the_ceiling() {
    let tmp = TempDir::new("hang");
    let exe = tmp.0.join("v8-runner.exe");
    std::fs::copy(FAKE, &exe).unwrap();
    std::fs::write(tmp.0.join("version-sleep.txt"), "60").unwrap();

    // Контроль харнеса: фальшивий раннер справді спить на --version.
    let probe = runner::exec(
        &exe,
        Path::new("."),
        &[std::ffi::OsStr::new("--version")],
        Some(Duration::from_secs(1)),
    );
    assert!(
        matches!(probe, Err(runner::RunError::Timeout { .. })),
        "{probe:?}"
    );

    let started = Instant::now();
    let err = runner::version(&exe).unwrap_err();
    assert!(
        started.elapsed() < Duration::from_secs(6),
        "version не вклався в стелю: {:?}",
        started.elapsed()
    );
    assert!(
        err.starts_with("раннер не відповів на --version за 5 с"),
        "{err}"
    );

    // У check це error runner-version з префіксом вердикту, не «не перевірено».
    let h = healthy("hang-check");
    let mut o = opts(&h.tmp.0.join("нема.json"));
    o.runner = Some(exe);
    let r = run_check(&h.root, &o).unwrap();
    let rv = by(&r, "runner-version");
    assert_eq!(rv.len(), 1);
    assert_eq!(rv[0].level, Level::Error);
    assert!(
        rv[0]
            .message
            .starts_with("Раннер Уніки недоступний: раннер не відповів на --version за 5 с"),
        "{}",
        rv[0].message
    );
    assert!(r.not_checked.is_empty());
}

// ---- Маніфест і воркспейси ----

#[test]
fn manifest_summary_counts_declared_sources_by_truth() {
    let tmp = TempDir::new("summary");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["a", "b", "c"]);
    write_manifest(
        &root,
        None,
        &[("ws", &[("a", "storage"), ("b", "storage"), ("c", "vendor")])],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    let m = by(&r, "manifest");
    assert_eq!(m.len(), 1);
    assert_eq!(m[0].level, Level::Info);
    assert!(
        m[0].message.starts_with("Маніфест: product P, головна гілка main, воркспейсів 1, джерел у перевірці 3 (storage: 2, vendor: 1)."),
        "{}",
        m[0].message
    );
    // -Source звужує зведення.
    let mut o = opts(&registry);
    o.source = Some("c".into());
    let r = run_check(&root, &o).unwrap();
    assert!(
        by(&r, "manifest")[0]
            .message
            .contains("джерел у перевірці 1 (vendor: 1)"),
        "{}",
        by(&r, "manifest")[0].message
    );
}

#[test]
fn agent_base_required_is_one_finding_per_workspace() {
    let tmp = TempDir::new("agentbase");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["a", "b"]);
    write_workspace(&root, "ws2", &["c"]);
    write_manifest(
        &root,
        None,
        &[
            ("ws", &[("a", "storage"), ("b", "storage")]),
            ("ws2", &[("c", "storage")]),
        ],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "agent-base-required");
    assert_eq!(f.len(), 2, "{:?}", r.findings);
    assert!(f[0].message.starts_with(
        "Джерела 'a', 'b' (truth: storage) вивантажуються в контексті базової конфігурації. "
    ));
    assert!(
        f[0].message
            .contains("База агента воркспейсу 'ws' не налаштована")
    );
    assert!(
        f[1].message
            .starts_with("Джерело 'c' (truth: storage) вивантажується ")
    );
    assert!(f.iter().all(|x| x.level == Level::Warn));

    // База агента задана, а теки на диску немає — інший текст, теж одна знахідка.
    std::fs::write(
        root.join("ws").join("v8project.local.yaml"),
        "infobases:\n  origin:\n    connection: 'File=build/ib'\n",
    )
    .unwrap();
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "agent-base-required");
    assert_eq!(f.len(), 2);
    assert!(
        f[0].message.ends_with(
            "а бази агента воркспейсу 'ws' ще немає на диску: v8storagekit:infobase-agent."
        ),
        "{}",
        f[0].message
    );

    // Воркспейс без truth: storage — знахідки немає.
    let tmp = TempDir::new("agentbase-none");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["a"]);
    write_manifest(&root, None, &[("ws", &[("a", "vendor")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(by(&r, "agent-base-required").is_empty());
}

#[test]
fn main_branch_exists_unborn_or_misspelled() {
    let tmp = TempDir::new("branch");
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let setup = |name: &str, git_branch: &str, commit: bool, manifest_branch: Option<&str>| {
        let root = tmp.0.join(name);
        init_repo(&root, git_branch, commit);
        if commit {
            install_hooks(&root);
        }
        write_workspace(&root, "ws", &["a"]);
        write_manifest(&root, manifest_branch, &[("ws", &[("a", "vendor")])]);
        root
    };
    // Гілка є — тиша.
    let r = run_check(&setup("ok", "main", true, None), &opts(&registry)).unwrap();
    assert!(by(&r, "main-branch").is_empty());
    // Свіжий репозиторій: HEAD на main, ref немає — info.
    let r = run_check(&setup("fresh", "main", false, None), &opts(&registry)).unwrap();
    let f = by(&r, "main-branch");
    assert_eq!((f.len(), f[0].level), (1, Level::Info));
    assert!(
        f[0].message
            .starts_with("Свіжий репозиторій: головної гілки 'main'")
    );
    // HEAD деінде (описка в mainBranch) — warn, код 0.
    let r = run_check(&setup("typo", "work", true, Some("mian")), &opts(&registry)).unwrap();
    let f = by(&r, "main-branch");
    assert_eq!((f.len(), f[0].level), (1, Level::Warn));
    assert!(f[0].message.starts_with("Головної гілки 'mian'"));
    assert_eq!(r.code, 0);
}

#[test]
fn unique_keys_is_case_insensitive_and_ignores_the_selection() {
    let tmp = TempDir::new("unique");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "a", &["Cf"]);
    write_workspace(&root, "b", &["cf"]);
    write_workspace(&root, "c", &["x"]);
    write_manifest(
        &root,
        None,
        &[
            ("a", &[("Cf", "storage")]),
            ("b", &[("cf", "storage")]),
            ("c", &[("x", "storage")]),
        ],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let mut o = opts(&registry);
    // Звужений огляд воркспейсом c усе одно бачить дубль (перевірка по всьому репозиторію).
    o.workspace = Some("c".into());
    let r = run_check(&root, &o).unwrap();
    let f = by(&r, "unique-keys");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert_eq!(
        f[0].message,
        "Ключ 'Cf' з truth: storage повторюється у воркспейсах a, b — гілка storage/Cf була б спільною. Перейменуйте source-set в одному з них."
    );
    assert_eq!(r.code, 1);
}

#[test]
fn undeclared_source_set_is_a_warning_per_set() {
    let tmp = TempDir::new("undeclared");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    install_hooks(&root);
    write_workspace(&root, "ws", &["a", "Stray"]);
    write_manifest(&root, None, &[("ws", &[("A", "vendor")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "undeclared-source");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.starts_with(
            "ws: source-set 'Stray' (CONFIGURATION) оголошено у ws/v8project.yaml, але його немає в маніфесті"
        ),
        "{}",
        f[0].message
    );
    assert!(f[0].message.contains("рядок 'Stray/** -text'"));
    assert_eq!(r.code, 0);
}

/// Зламаний `.git` вкладеного репозиторію всередині зовнішнього: git не мусить піднятись до зовнішнього й
/// відповісти на його рефи — `main-branch` «не перевірено», код 3. Контроль: без `GIT_CEILING_DIRECTORIES`
/// (`git::run`) той самий запит дає відповідь зовнішнього репозиторію.
#[test]
fn broken_nested_git_dir_does_not_fall_through_to_the_outer_repository() {
    let tmp = TempDir::new("nested");
    init_repo(&tmp.0, "main", true); // зовнішній, із гілкою main
    let root = tmp.0.join("inner");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["a"]);
    write_manifest(&root, None, &[("ws", &[("a", "vendor")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    std::fs::write(
        root.join(".git").join("HEAD"),
        "сміття, не ref
",
    )
    .unwrap();

    // Контроль: звичайний запит git піднімається до зовнішнього репозиторію й бачить `main`.
    let out = kit::git::run(
        &root,
        &["rev-parse", "--verify", "--quiet", "refs/heads/main"],
        None,
        true,
    )
    .unwrap();
    assert_eq!(
        out.code, 0,
        "контроль: без стелі відповідає зовнішній репозиторій"
    );

    let r = run_check(&root, &opts(&registry)).unwrap();
    let mb = by(&r, "main-branch");
    assert_eq!(mb.len(), 1, "{:?}", r.findings);
    assert!(
        mb[0].message.starts_with("не перевірено: "),
        "{}",
        mb[0].message
    );
    // Стражі секрету на тому ж збої — error «не перевірено» (fail-closed), тож код 1, а не 3.
    assert_eq!(r.code, 1, "{:?}", r.findings);
}

// ---- Задача 2: git-стражі й локальні файли ----

fn commit(root: &Path, message: &str) {
    // Без хуків репозиторію: тест кладе в коміт фантом регістру, який pre-commit плагіна відхилив би.
    git(
        root,
        &[
            "-c",
            "core.hooksPath=.без-хуків",
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            message,
        ],
    );
}

fn write_file(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn messages(r: &Report, id: &str) -> Vec<String> {
    by(r, id).iter().map(|f| f.message.clone()).collect()
}

#[test]
fn healthy_repository_has_no_guard_findings_and_overlay_guard_sees_rule_and_fact() {
    let h = healthy("guards");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    for id in [
        "overlay-ignored",
        "local-ignored",
        "gitattributes",
        "gitignore",
        "case-collision",
        "build-artifacts",
        "local-audit",
        "overlay-connection",
    ] {
        assert!(by(&r, id).is_empty(), "{id}: {:?}", r.findings);
    }

    // ПРАВИЛА: накладку не гітігноровано.
    write_file(&h.root, ".gitignore", "v8project.local.yaml\n");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "overlay-ignored");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert!(
        f[0].message.contains("не гітігноровано"),
        "{}",
        f[0].message
    );
    assert_eq!(r.code, 1);

    // ФАКТ: правило є, а файл закомічено силою.
    write_file(
        &h.root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\n",
    );
    write_file(&h.root, "v8storagekit.local.yaml", "infobases: {}\n");
    git(&h.root, &["add", "-f", "--", "v8storagekit.local.yaml"]);
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "overlay-ignored");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(f[0].message.contains("вже закомічено"), "{}", f[0].message);
}

#[test]
fn overlay_guard_runs_when_the_manifest_is_unread_and_local_guard_for_unresolved_workspace() {
    // Рішення 6: страж не залежить від розв'язаного контексту.
    let h = healthy("guards-ctx");
    write_file(&h.root, ".gitignore", "");
    write_file(&h.root, "v8storagekit.yaml", "це: [не маніфест\n");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    assert!(
        r.findings
            .iter()
            .any(|f| f.check == "manifest" && f.level == Level::Error),
        "{:?}",
        r.findings
    );
    let f = by(&r, "overlay-ignored");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);

    // Воркспейс задекларовано, але не розв'язався (немає v8project.yaml): `local-ignored` усе одно питає.
    let h = healthy("guards-unresolved");
    std::fs::remove_file(h.root.join("ws").join("v8project.yaml")).unwrap();
    write_file(&h.root, ".gitignore", "v8storagekit.local.yaml\n");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "local-ignored");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .starts_with("ws/v8project.local.yaml не гітігноровано"),
        "{}",
        f[0].message
    );
    // Решти перевірок воркспейсу для нього немає: помилка префлайту вже error.
    assert!(by(&r, "local-audit").is_empty());
    assert!(by(&r, "build-artifacts").is_empty());
}

#[test]
fn local_ignored_rules_and_fact() {
    let h = healthy("local-ignored");
    write_file(&h.root, ".gitignore", "v8storagekit.local.yaml\n");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    assert_eq!(by(&r, "local-ignored").len(), 1, "{:?}", r.findings);

    write_file(
        &h.root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\n",
    );
    write_file(&h.root, "ws/v8project.local.yaml", "infobases: {}\n");
    git(&h.root, &["add", "-f", "--", "ws/v8project.local.yaml"]);
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "local-ignored");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(f[0].message.contains("вже закомічено"), "{}", f[0].message);
}

#[test]
fn text_policy_tree_ignore_and_vendor_rules_and_fact() {
    let tmp = TempDir::new("trees");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["cf", "vd"]);
    write_manifest(&root, None, &[("ws", &[("cf", "git"), ("vd", "vendor")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(
        by(&r, "gitattributes").is_empty() && by(&r, "gitignore").is_empty(),
        "{:?}",
        r.findings
    );

    // Дерево без -text, дерево git під ігнором, vendor без правила: три різні знахідки.
    write_file(&root, ".gitattributes", "");
    write_file(
        &root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\nws/cf/**\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    let attrs = messages(&r, "gitattributes");
    assert_eq!(attrs.len(), 1, "{:?}", r.findings);
    assert!(attrs[0].contains("'ws/cf/** -text'"), "{}", attrs[0]);
    let ign = messages(&r, "gitignore");
    assert_eq!(ign.len(), 2, "{:?}", r.findings);
    assert!(
        ign[0].contains("гітігноровано, хоч має потрапляти в git (truth: git)"),
        "{}",
        ign[0]
    );
    assert!(
        ign[1].contains("не гітігноровано (truth: vendor)"),
        "{}",
        ign[1]
    );

    // vendor: правило є, а дерево закомічено силою — ФАКТ.
    write_file(
        &root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\nws/vd/**\n",
    );
    write_file(&root, "ws/vd/Configuration.xml", "<x/>");
    git(&root, &["add", "-f", "--", "ws/vd/Configuration.xml"]);
    let r = run_check(&root, &opts(&registry)).unwrap();
    let ign = messages(&r, "gitignore");
    assert_eq!(ign.len(), 1, "{:?}", r.findings);
    assert!(
        ign[0].contains("відстежується git — у ньому 1 файл(ів)"),
        "{}",
        ign[0]
    );
}

#[test]
fn case_collision_groups_in_head_and_no_head_is_not_applicable() {
    let h = healthy("case");
    // Дві різні за регістром (кирилиця) назви в HEAD: на NTFS це один файл. У дерево вони потрапляють через індекс.
    for (i, name) in ["ws/cf/Файл.xml", "ws/cf/файл.xml"].iter().enumerate() {
        write_file(&h.root, "blob.txt", &format!("v{i}"));
        let out = Command::new("git")
            .arg("-C")
            .arg(&h.root)
            .args(["hash-object", "-w", "blob.txt"])
            .output()
            .unwrap();
        let sha = String::from_utf8(out.stdout).unwrap().trim().to_string();
        git(
            &h.root,
            &[
                "update-index",
                "--add",
                "--cacheinfo",
                &format!("100644,{sha},{name}"),
            ],
        );
    }
    commit(&h.root, "two");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "case-collision");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert!(
        f[0].message.contains("1 груп(и)")
            && f[0].message.contains("ws/cf/Файл.xml | ws/cf/файл.xml"),
        "{}",
        f[0].message
    );

    // Свіжий репозиторій без HEAD — «не застосовується»: ні знахідки, ні «не перевірено».
    let tmp = TempDir::new("case-fresh");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", false);
    write_workspace(&root, "ws", &["cf"]);
    write_manifest(&root, None, &[("ws", &[("cf", "storage")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(
        by(&r, "case-collision").is_empty() && r.not_checked.is_empty(),
        "{:?}",
        r.findings
    );
}

#[test]
fn build_artifacts_outside_the_work_path_are_a_warning() {
    let h = healthy("artifacts");
    for rel in ["ws/out/a.EPF", "ws/b.cfe", "ws/build/ok.cf", "ws/readme.md"] {
        write_file(&h.root, rel, "x");
        git(&h.root, &["add", "-f", "--", rel]);
    }
    commit(&h.root, "files");
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let f = by(&r, "build-artifacts");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.contains("2 файл(ів): ws/b.cfe, ws/out/a.EPF"),
        "{}",
        f[0].message
    );
    assert!(r.not_checked.is_empty());
    assert_eq!(r.code, 0);
}

#[test]
fn dump_from_overlay_connection_and_broken_overlay() {
    let tmp = TempDir::new("overlay");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["cf"]);
    write_manifest(&root, None, &[("ws", &[("cf", "dump")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");

    // Накладки немає.
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = messages(&r, "dump-from");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].contains("накладки v8storagekit.local.yaml на цій машині немає"),
        "{}",
        f[0]
    );

    // Накладка є, але потрібної бази в ній немає; один рядок підключення не розбирається, один відносний.
    write_file(
        &root,
        "v8storagekit.local.yaml",
        "infobases:\n  other: { connection: 'File=C:\\\\h\\\\a' }\n  bad: { connection: 'Srvr=a;' }\n  rel: { connection: 'File=build\\\\ib' }\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = messages(&r, "dump-from");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].contains("дев-бази 'dev' немає в infobases: накладки"),
        "{}",
        f[0]
    );
    let oc = messages(&r, "overlay-connection");
    assert_eq!(oc.len(), 2, "{:?}", r.findings);
    assert!(oc[0].starts_with("Дев-база 'bad' у "), "{}", oc[0]);
    assert!(
        oc[1].starts_with("Дев-база 'rel' у ") && oc[1].contains("відносний File="),
        "{}",
        oc[1]
    );
    assert!(
        by(&r, "overlay-connection")
            .iter()
            .all(|f| f.level == Level::Warn)
    );

    // Накладка зламана (рішення 7): «накладки немає» не кажемо, звірку позначаємо «не перевірено».
    write_file(
        &root,
        "v8storagekit.local.yaml",
        "infobases:\n  dev: { connection: '' }\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(by(&r, "dump-from").is_empty(), "{:?}", r.findings);
    let oc = by(&r, "overlay-connection");
    assert_eq!(oc.len(), 1, "{:?}", r.findings);
    assert_eq!(
        oc[0].message,
        "не перевірено: підключення дев-баз накладки — накладку не розібрано"
    );
    assert_eq!(r.not_checked.len(), 1);
    assert_eq!(r.code, 1, "error накладки сильніший: {:?}", r.findings);
}

#[test]
fn local_audit_names_every_overlapping_dev_base_and_the_legacy_key() {
    let tmp = TempDir::new("audit");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["cf"]);
    write_manifest(&root, None, &[("ws", &[("cf", "dump")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    write_file(
        &root,
        "v8storagekit.local.yaml",
        "infobases:\n  dev: { connection: 'File=C:\\\\hum\\\\a' }\n  far: { connection: 'File=D:\\\\far' }\n  parent: { connection: 'File=C:\\\\hum' }\n",
    );
    write_file(
        &root,
        "ws/v8project.local.yaml",
        "infobases:\n  origin:\n    connection: 'File=C:\\\\hum\\\\a\\\\'\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = messages(&r, "local-audit");
    assert_eq!(f.len(), 2, "всі збіги, не перший: {:?}", r.findings);
    assert!(f[0].contains("дев-базою 'dev'"), "{}", f[0]);
    assert!(f[1].contains("дев-базою 'parent'"), "{}", f[1]);
    assert_eq!(r.code, 1);

    // Обгортка `config::dev_base_overlaps(ctx, ws)` дає той самий перелік (усі збіги, порядок накладки).
    let ctx = config::preflight(&root, Mode::Check).unwrap();
    let hits = config::dev_base_overlaps(&ctx, &ctx.workspaces[0]);
    let names: Vec<String> = hits.into_iter().map(|h| h.unwrap().name).collect();
    assert_eq!(names, ["dev", "parent"]);

    // Контроль: база агента окремо — аудит мовчить.
    write_file(
        &root,
        "ws/v8project.local.yaml",
        "infobases:\n  origin:\n    connection: 'File=C:\\\\agent\\\\ib'\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(by(&r, "local-audit").is_empty(), "{:?}", r.findings);

    // Стара конвенція devInfobase: kit її не читає — warn, а не тиша.
    write_file(
        &root,
        "ws/v8project.local.yaml",
        "devInfobase: File=C:\\x\n",
    );
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "local-audit");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.contains("ключ devInfobase:"),
        "{}",
        f[0].message
    );
}

#[test]
fn global_git_failure_gives_guard_errors_code_1() {
    // `core.repositoryformatversion=99`: кожна команда git відповідає 128 — страж файла з паролем fail-closed.
    let tmp = TempDir::new("global");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["cf", "vd"]);
    write_manifest(
        &root,
        None,
        &[("ws", &[("cf", "storage"), ("vd", "vendor")])],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    git(&root, &["config", "core.repositoryformatversion", "99"]);
    let r = run_check(&root, &opts(&registry)).unwrap();
    for id in ["overlay-ignored", "local-ignored", "gitignore"] {
        // `gitignore`: страж лише для vendor (`ws/vd`); дерево storage-джерела неохоронне, warn.
        let mut f = by(&r, id);
        f.retain(|x| id != "gitignore" || x.message.contains("ws/vd:"));
        assert!(!f.is_empty(), "{id}: {:?}", r.findings);
        assert!(
            f.iter()
                .all(|x| x.level == Level::Error && x.message.starts_with("не перевірено: ")),
            "{id}: {f:?}"
        );
        // «Не перевірено» — властивість знахідки: вона й у переліку.
        for x in f {
            assert!(r.not_checked.contains(x), "{id}: {x:?}");
        }
    }
    assert_eq!(r.code, 1, "{:?}", r.findings);
    // Неохоронні перевірки на тому ж збої — «не перевірено» warn.
    let ba = by(&r, "build-artifacts");
    assert_eq!(ba[0].level, Level::Warn);
    assert!(ba[0].message.starts_with("не перевірено: "));
    // `git config --get core.hooksPath` на нерозпізнаному репозиторії дає код 1, як для незаданого ключа: це не
    // «значення не задано» — `hooks` каже «не перевірено», а не error «не вказує на .githooks (зараз: '')».
    let hooks = by(&r, "hooks");
    assert!(
        hooks
            .iter()
            .any(|x| x.level == Level::Warn
                && x.message.starts_with("не перевірено: core.hooksPath")),
        "{hooks:?}"
    );
    assert!(
        hooks
            .iter()
            .all(|x| !x.message.contains("не вказує на .githooks")),
        "{hooks:?}"
    );
    // Інваріант: not_checked ⊆ findings, той самий рівень.
    for x in &r.not_checked {
        assert!(r.findings.contains(x), "{x:?}");
    }
}

#[test]
fn tracked_secret_file_in_another_case_is_still_committed() {
    // Pathspec git звіряє регістр, а правило `.gitignore` за `core.ignorecase` — ні: файл з паролем в індексі під
    // іншим регістром не мусить пройти повз страж.
    let h = healthy("case-fact");
    write_file(
        &h.root,
        "V8StorageKit.local.yaml",
        "infobases: {}
",
    );
    write_file(
        &h.root,
        "ws/V8Project.local.yaml",
        "infobases: {}
",
    );
    git(
        &h.root,
        &[
            "add",
            "-f",
            "--",
            "V8StorageKit.local.yaml",
            "ws/V8Project.local.yaml",
        ],
    );
    let r = run_check(&h.root, &opts(&h.registry)).unwrap();
    let o = by(&r, "overlay-ignored");
    assert_eq!(o.len(), 1, "{:?}", r.findings);
    assert!(o[0].message.contains("вже закомічено"), "{}", o[0].message);
    let l = by(&r, "local-ignored");
    assert_eq!(l.len(), 1, "{:?}", r.findings);
    assert!(l[0].message.contains("вже закомічено"), "{}", l[0].message);
    assert_eq!(r.code, 1);
}

#[test]
fn unignored_file_in_another_case_is_caught_when_rule_ignores_the_canonical_name() {
    // `core.ignorecase=false`: правило ігнорує канонічне ім'я, а файли на диску в іншому регістрі лишаються
    // неігнорованими й потрапили б у перший же `git add -A`.
    let tmp = TempDir::new("unignored");
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["cf", "vd"]);
    write_manifest(
        &root,
        None,
        &[("ws", &[("cf", "storage"), ("vd", "vendor")])],
    );
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    git(&root, &["config", "core.ignorecase", "false"]);
    let r = run_check(&root, &opts(&registry)).unwrap();
    assert!(
        by(&r, "overlay-ignored").is_empty()
            && by(&r, "local-ignored").is_empty()
            && by(&r, "gitignore").is_empty(),
        "контроль: без файлів в іншому регістрі знахідок немає: {:?}",
        r.findings
    );

    write_file(&root, "V8StorageKit.local.yaml", "infobases: {}\n");
    write_file(&root, "ws/V8Project.local.yaml", "infobases: {}\n");
    write_file(&root, "ws/VD/Configuration.xml", "<x/>");
    let r = run_check(&root, &opts(&registry)).unwrap();
    for (id, text) in [
        ("overlay-ignored", "не гітігноровано"),
        ("local-ignored", "не гітігноровано"),
        ("gitignore", "не гітігноровано (truth: vendor)"),
    ] {
        let f = by(&r, id);
        assert_eq!(f.len(), 1, "{id}: {:?}", r.findings);
        assert_eq!(f[0].level, Level::Error);
        assert!(f[0].message.contains(text), "{id}: {}", f[0].message);
    }
    assert_eq!(r.code, 1);
}

/// Воркспейс `ws` з одним source-set `vd` (vendor), шлях якого в `v8project.yaml` — `source_path`.
fn vendor_with_source_path(tag: &str, source_path: &str) -> (TempDir, PathBuf, PathBuf) {
    let tmp = TempDir::new(tag);
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    write_workspace(&root, "ws", &["vd"]);
    write_file(
        &root,
        "ws/v8project.yaml",
        &format!(
            "providers: {{ push: designer, pull: designer, download: designer }}\nsource-set:\n  - {{ name: vd, type: CONFIGURATION, path: '{source_path}' }}\n"
        ),
    );
    write_manifest(&root, None, &[("ws", &[("vd", "vendor")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    (tmp, root, registry)
}

#[test]
fn source_path_with_dot_segments_is_normalized_before_matching_the_index() {
    let (_tmp, root, registry) = vendor_with_source_path("dotpath", "./vd");
    write_file(&root, "ws/vd/Configuration.xml", "<x/>");
    git(&root, &["add", "-f", "--", "ws/vd/Configuration.xml"]);
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "gitignore");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .contains("відстежується git — у ньому 1 файл(ів)"),
        "{}",
        f[0].message
    );
    assert_eq!(r.code, 1);
}

#[test]
fn source_path_escaping_the_repository_is_an_unchecked_guard_error() {
    let (_tmp, root, registry) = vendor_with_source_path("escape", "../../out");
    let r = run_check(&root, &opts(&registry)).unwrap();
    let f = by(&r, "gitignore");
    assert!(!f.is_empty(), "{:?}", r.findings);
    assert!(
        f.iter()
            .all(|x| x.level == Level::Error && x.message.starts_with("не перевірено: ")),
        "{f:?}"
    );
    assert!(f.iter().all(|x| r.not_checked.contains(x)));
    assert!(
        f.iter().any(|x| x.message.contains("виходить за корінь")),
        "{f:?}"
    );
    assert_eq!(r.code, 1);
}

// ---- Задача 3: поставка, сховище, `storage/*`, `config-name`, хуки ----

fn git_stdin(dir: &Path, args: &[&str], stdin: &str) -> String {
    use std::io::Write;
    use std::process::Stdio;
    let mut child = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// Дерево з файлами `files` (усі з однаковим вмістом) без індексу й робочого дерева.
fn make_tree(root: &Path, files: &[&str]) -> String {
    fn build(root: &Path, blob: &str, files: &[&str]) -> String {
        let mut entries = Vec::new();
        let mut dirs: std::collections::BTreeMap<String, Vec<String>> = Default::default();
        for f in files {
            match f.split_once('/') {
                None => entries.push(format!("100644 blob {blob}\t{f}\n")),
                Some((d, rest)) => dirs
                    .entry(d.to_string())
                    .or_default()
                    .push(rest.to_string()),
            }
        }
        for (d, rest) in dirs {
            let refs: Vec<&str> = rest.iter().map(String::as_str).collect();
            let t = build(root, blob, &refs);
            entries.push(format!("040000 tree {t}\t{d}\n"));
        }
        git_stdin(root, &["mktree"], &entries.concat())
    }
    let blob = git_stdin(root, &["hash-object", "-w", "--stdin"], "x");
    build(root, &blob, files)
}

fn commit_tree(root: &Path, tree: &str, parents: &[&str], trailers: &str) -> String {
    let mut args = vec!["commit-tree", tree];
    for p in parents {
        args.extend(["-p", p]);
    }
    args.extend(["-m", "s", "-m", trailers]);
    git_stdin(root, &args, "")
}

fn set_ref(root: &Path, branch: &str, sha: &str) {
    git(root, &["update-ref", &format!("refs/heads/{branch}"), sha]);
}

/// Видаляє незапакований об'єкт: ref і решта цілі, а читання самого об'єкта падає.
fn remove_object(root: &Path, sha: &str) {
    let object = root
        .join(".git")
        .join("objects")
        .join(&sha[..2])
        .join(&sha[2..]);
    let mut perms = std::fs::metadata(&object).unwrap().permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    perms.set_readonly(false);
    std::fs::set_permissions(&object, perms).unwrap();
    std::fs::remove_file(&object).unwrap();
}

/// Файл, відкритий монопольно (без спільного доступу): метадані читаються, вміст — ні.
fn lock_file(path: &Path) -> std::fs::File {
    use std::os::windows::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(path)
        .unwrap()
}

fn run_h(h: &Healthy) -> Report {
    run_check(&h.root, &opts(&h.registry)).unwrap()
}

fn all_texts(r: &Report) -> String {
    r.findings
        .iter()
        .map(|f| f.message.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

// supply

const SUPPLY: &str = "ws/cf/Ext/ParentConfigurations";

/// `.bin` описує поставку (понад 16 байт); `rule` — рядок ігнору теки поставки в `.gitignore`.
fn supply_fixture(h: &Healthy, rule: bool) {
    write_file(
        &h.root,
        "ws/cf/Ext/ParentConfigurations.bin",
        &"b".repeat(40),
    );
    if rule {
        let mut ignore = std::fs::read_to_string(h.root.join(".gitignore")).unwrap();
        ignore.push_str("**/Ext/ParentConfigurations/\n");
        write_file(&h.root, ".gitignore", &ignore);
    }
}

#[test]
fn supply_state_missing_stale_current_and_unknown() {
    let h = healthy("supply");
    // Без `.bin` і з порожнім `.bin` (16 байт) поставки немає — мовчання.
    assert!(by(&run_h(&h), "supply").is_empty());
    write_file(
        &h.root,
        "ws/cf/Ext/ParentConfigurations.bin",
        &"b".repeat(16),
    );
    assert!(by(&run_h(&h), "supply").is_empty());

    supply_fixture(&h, true);
    // Немає ні .cf, ні позначки: «відсутня», рецепт для гілки main — kit verify.
    let r = run_h(&h);
    let f = by(&r, "supply");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.starts_with("ws/cf: поставка вендора відсутня"),
        "{}",
        f[0].message
    );
    assert!(
        f[0].message.contains("на гілці main") && f[0].message.contains("kit verify -Source cf"),
        "{}",
        f[0].message
    );
    assert_eq!(r.code, 0, "{:?}", r.findings);

    // На гілці задачі рецепт каже «спершу поставка на головній гілці».
    git(&h.root, &["checkout", "-q", "-b", "task"]);
    let r = run_h(&h);
    assert!(
        by(&r, "supply")[0]
            .message
            .contains("спершу поставка на головній гілці main"),
        "{:?}",
        r.findings
    );
    git(&h.root, &["checkout", "-q", "main"]);

    // .cf є, позначка не збігається — «застаріла».
    write_file(&h.root, &format!("{SUPPLY}/a.cf"), "cf");
    write_file(&h.root, &format!("{SUPPLY}/.kit-bin-sha1"), "0000");
    let r = run_h(&h);
    assert!(
        by(&r, "supply")[0]
            .message
            .contains("поставка вендора застаріла"),
        "{:?}",
        r.findings
    );

    // Позначка = SHA-1 .bin — без знахідок.
    let sha = kit::supply::bin_sha1(&h.root.join("ws").join("cf")).unwrap();
    write_file(&h.root, &format!("{SUPPLY}/.kit-bin-sha1"), &sha);
    let r = run_h(&h);
    assert!(by(&r, "supply").is_empty(), "{:?}", r.findings);
    assert_eq!(r.code, 0);

    // `.bin` не читається (монопольно відкритий): стан unknown у тексті «не перевірено» — код 3.
    let _lock = lock_file(&h.root.join("ws/cf/Ext/ParentConfigurations.bin"));
    let r = run_h(&h);
    let f = by(&r, "supply");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message
            .starts_with("не перевірено: ws/cf: поставка вендора — ")
            && f[0].message.contains("стан поставки вендора не обчислено"),
        "{}",
        f[0].message
    );
    assert!(r.not_checked.contains(f[0]));
    assert_eq!(r.code, 3, "{:?}", r.findings);
}

#[test]
fn supply_git_rules_cf_not_ignored_bin_ignored_and_tracked() {
    let h = healthy("supply-git");
    supply_fixture(&h, false);
    // Правила: тека поставки не під ігнором.
    let r = run_h(&h);
    let f = by(&r, "gitignore");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert!(
        f[0].message
            .contains("тека поставки вендора 'ws/cf/Ext/ParentConfigurations/' не гітігнорована"),
        "{}",
        f[0].message
    );
    assert_eq!(r.code, 1);

    // Ігнор лише `*.cf` без позначки — друга проба ловить.
    write_file(
        &h.root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\n*.cf\n",
    );
    let r = run_h(&h);
    assert_eq!(by(&r, "gitignore").len(), 1, "{:?}", r.findings);

    // `.bin` під ігнором — error.
    write_file(
        &h.root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\n**/Ext/ParentConfigurations/\n*.bin\n",
    );
    let r = run_h(&h);
    let f = by(&r, "gitignore");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message.contains("ознаки підтримки"),
        "{}",
        f[0].message
    );

    // .cf закомічено силою — відстежується.
    write_file(
        &h.root,
        ".gitignore",
        "v8storagekit.local.yaml\nv8project.local.yaml\n**/Ext/ParentConfigurations/\n",
    );
    write_file(&h.root, &format!("{SUPPLY}/a.cf"), "cf");
    git(&h.root, &["add", "-f", "--", &format!("{SUPPLY}/a.cf")]);
    let r = run_h(&h);
    let f = by(&r, "gitignore");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .contains("поставка вендора відстежується git (1 файл(ів)")
            && f[0]
                .message
                .contains("git rm -r --cached -- 'ws/cf/Ext/ParentConfigurations'"),
        "{}",
        f[0].message
    );
}

// storage-path

fn set_storage_path(h: &Healthy, path: &str) {
    write_file(
        &h.root,
        "v8storagekit.yaml",
        &format!(
            "version: 1
product: P
workspaces:
  - path: ws
    sources:
      cf: {{ truth: storage, storage: {{ path: '{path}' }} }}
"
        ),
    );
}

#[test]
fn storage_path_directory_server_address_and_userinfo_mask() {
    let h = healthy("storage-path");
    // Існуючий каталог — тиша.
    set_storage_path(&h, &h.tmp.0.to_string_lossy());
    assert!(by(&run_h(&h), "storage-path").is_empty());

    // Немає каталогу — warn (як зараз).
    set_storage_path(&h, "C:\\нема-такого-каталогу-kit");
    let r = run_h(&h);
    let f = by(&r, "storage-path");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.contains("каталог сховища недоступний на цій машині: 'C:\\нема-такого-каталогу-kit', як записано в v8storagekit.yaml"),
        "{}",
        f[0].message
    );

    // Серверна адреса — info, файлово не пробується; userinfo не друкується нікуди.
    const MARKER: &str = "МАРКЕР-pw-7731";
    set_storage_path(&h, &format!("tcp://user:{MARKER}@srv/repo"));
    let r = run_h(&h);
    let f = by(&r, "storage-path");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Info);
    assert!(
        f[0].message
            .contains("серверне сховище — доступність check не перевіряє")
            && f[0].message.contains("tcp://***@srv/repo"),
        "{}",
        f[0].message
    );
    assert!(!all_texts(&r).contains(MARKER), "{:?}", r.findings);
    assert_eq!(r.code, 0);

    // Перевизначення накладкою: у тексті обидва шляхи, обидва без userinfo.
    write_file(
        &h.root,
        "v8storagekit.local.yaml",
        "storages:\n  cf: { path: 'C:\\нема-такого-каталогу-kit' }\n",
    );
    let r = run_h(&h);
    let f = by(&r, "storage-path");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message.contains("перевизначено в v8storagekit.local.yaml на 'C:\\нема-такого-каталогу-kit'; у самому v8storagekit.yaml записано: 'tcp://***@srv/repo'"),
        "{}",
        f[0].message
    );
    assert!(!all_texts(&r).contains(MARKER), "{:?}", r.findings);

    // Контроль маски: функція справді прибирає облікові дані й не чіпає адресу без них.
    assert_eq!(
        config::mask_storage_path(&format!("https://u:{MARKER}/x@h/r")),
        "https://***@h/r"
    );
    assert_eq!(
        config::mask_storage_path("tcp://srv/repo"),
        "tcp://srv/repo"
    );
    assert_eq!(config::mask_storage_path("C:\\a@b"), "C:\\a@b");
    assert!(
        config::is_server_storage_path("HTTPS://h") && !config::is_server_storage_path("C:\\h")
    );
}

// storage-branch

#[test]
fn storage_branch_absent_good_and_every_invariant_violation() {
    let h = healthy("storage-branch");
    // Гілки немає — info.
    let r = run_h(&h);
    let f = by(&r, "storage-branch");
    assert_eq!((f.len(), f[0].level), (1, Level::Info), "{:?}", r.findings);
    assert!(f[0].message.contains("гілки storage/cf ще немає"));

    // Здорова гілка: Source = ключ (без регістру), версії зростають, дерево лише під шляхом джерела.
    let good = make_tree(&h.root, &["ws/cf/Configuration.xml"]);
    let c1 = commit_tree(
        &h.root,
        &good,
        &[],
        "Storage-Source: cf\nStorage-Version: 1",
    );
    let c2 = commit_tree(
        &h.root,
        &good,
        &[&c1],
        "Storage-Source: CF\nStorage-Version: 2",
    );
    set_ref(&h.root, "storage/cf", &c2);
    let r = run_h(&h);
    assert!(by(&r, "storage-branch").is_empty(), "{:?}", r.findings);
    assert_eq!(r.code, 0, "{:?}", r.findings);

    // Кожне порушення — своя знахідка error.
    let bad_tree = make_tree(
        &h.root,
        &[
            "ws/cf/A.xml",
            "ws/cf/a.xml",
            "stray/x",
            "ws/cf/Configuration.xml",
        ],
    );
    let b1 = commit_tree(&h.root, &good, &[], "просто текст");
    let b2 = commit_tree(
        &h.root,
        &good,
        &[&b1],
        "Storage-Source: інше\nStorage-Version: 5",
    );
    let b3 = commit_tree(
        &h.root,
        &good,
        &[&b2],
        "Storage-Source: cf\nStorage-Version: 5",
    );
    let b4 = commit_tree(
        &h.root,
        &bad_tree,
        &[&b3, &b1],
        "Storage-Source: cf\nStorage-Version: 6",
    );
    set_ref(&h.root, "storage/cf", &b4);
    let r = run_h(&h);
    let msgs = messages(&r, "storage-branch");
    let joined = msgs.join("\n");
    for needle in [
        "без трейлера Storage-Source:",
        "без числового трейлера Storage-Version:",
        "має Storage-Source: 'інше', а гілка належить джерелу 'cf'",
        "версії не зростають строго — після 5 іде 5",
        "має 2 батьків — merge-коміт",
        "у дереві 1 файл(ів) поза шляхом джерела 'ws/cf': stray/x",
        "у вершині 1 груп(и) шляхів, що різняться лише регістром",
        "ws/cf/A.xml | ws/cf/a.xml",
    ] {
        assert!(joined.contains(needle), "{needle}: {joined}");
    }
    assert!(
        by(&r, "storage-branch")
            .iter()
            .all(|f| f.level == Level::Error)
    );
    assert_eq!(r.code, 1);
}

#[test]
fn storage_branch_git_failure_is_unchecked_not_absent() {
    let h = healthy("storage-branch-fail");
    let tree = make_tree(&h.root, &["ws/cf/Configuration.xml"]);
    let c1 = commit_tree(
        &h.root,
        &tree,
        &[],
        "Storage-Source: cf\nStorage-Version: 1",
    );
    set_ref(&h.root, "storage/cf", &c1);
    remove_object(&h.root, &tree);
    let r = run_h(&h);
    let f = by(&r, "storage-branch");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message
            .starts_with("не перевірено: ws/cf: інваріанти гілки storage/cf — git ls-tree")
            && f[0].message.contains("not a tree object"),
        "{}",
        f[0].message
    );
    assert!(r.not_checked.contains(f[0]));
    assert_eq!(r.code, 3, "{:?}", r.findings);
}

// config-name

fn extension_repo(tag: &str) -> Healthy {
    let tmp = TempDir::new(tag);
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
    install_hooks(&root);
    write_file(
        &root,
        "ws/v8project.yaml",
        "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: Ext, type: EXTENSION, path: ext }\n",
    );
    write_manifest(&root, None, &[("ws", &[("Ext", "git")])]);
    let (registry, _) = install_unica(&tmp, "user", None, "0.16.0", "0.18.1");
    Healthy {
        tmp,
        root,
        registry,
    }
}

#[test]
fn config_name_absent_match_mismatch_missing_name_and_unreadable() {
    let h = extension_repo("config-name");
    let cfg = "ws/ext/Configuration.xml";
    // Файла ще немає — info.
    let r = run_h(&h);
    let f = by(&r, "config-name");
    assert_eq!((f.len(), f[0].level), (1, Level::Info), "{:?}", r.findings);
    assert!(f[0].message.contains("ws/ext/Configuration.xml ще немає"));

    // <Name> збігається з ключем без регістру — тиша.
    write_file(
        &h.root,
        cfg,
        "<MetaDataObject><Name>EXT</Name></MetaDataObject>",
    );
    assert!(by(&run_h(&h), "config-name").is_empty());

    // Не збігається — error.
    write_file(&h.root, cfg, "<x><name>Інше</name></x>");
    let r = run_h(&h);
    let f = by(&r, "config-name");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert!(
        f[0].message.contains(
            "<Name>Інше</Name> у ws/ext/Configuration.xml не збігається з ключем джерела 'Ext'"
        ),
        "{}",
        f[0].message
    );

    // Немає <Name> — warn.
    write_file(&h.root, cfg, "<x/>");
    let r = run_h(&h);
    let f = by(&r, "config-name");
    assert_eq!((f.len(), f[0].level), (1, Level::Warn), "{:?}", r.findings);
    assert!(f[0].message.contains("не знайдено <Name>"));
    assert!(r.not_checked.is_empty());

    // Файл не читається — «не перевірено» (код 3), а не втрата звіту.
    write_file(&h.root, cfg, "<Name>Ext</Name>");
    let _lock = lock_file(&h.root.join(cfg));
    let r = run_h(&h);
    let f = by(&r, "config-name");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .starts_with("не перевірено: ws/Ext: ws/ext/Configuration.xml — ")
    );
    assert!(r.not_checked.contains(f[0]));
    assert_eq!(r.code, 3, "{:?}", r.findings);
}

// hooks

fn hook_findings(r: &Report) -> Vec<&Finding> {
    by(r, "hooks")
}

#[test]
fn hooks_path_missing_files_content_mode_and_not_committed() {
    let h = healthy("hooks");
    assert!(hook_findings(&run_h(&h)).is_empty(), "healthy");

    // `./.githooks` і абсолютний шлях до тієї самої теки — не помилка.
    git(&h.root, &["config", "core.hooksPath", "./.githooks/"]);
    assert!(hook_findings(&run_h(&h)).is_empty());
    let abs = h.root.join(".githooks").to_string_lossy().into_owned();
    git(&h.root, &["config", "core.hooksPath", &abs]);
    assert!(hook_findings(&run_h(&h)).is_empty());

    // Інша тека — error, у тексті — що зараз.
    git(&h.root, &["config", "core.hooksPath", "elsewhere"]);
    let r = run_h(&h);
    let f = hook_findings(&r);
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Error);
    assert!(
        f[0].message.contains("зараз: 'elsewhere'"),
        "{}",
        f[0].message
    );
    git(&h.root, &["config", "--unset", "core.hooksPath"]);
    assert!(hook_findings(&run_h(&h))[0].message.contains("зараз: ''"));
    git(&h.root, &["config", "core.hooksPath", ".githooks"]);

    // Вміст відрізняється — warn; відмінність лише в CRLF — ні.
    let hook = h.root.join(".githooks/pre-commit");
    let original = std::fs::read_to_string(&hook).unwrap();
    std::fs::write(&hook, original.replace('\n', "\r\n")).unwrap();
    assert!(hook_findings(&run_h(&h)).is_empty(), "CRLF");
    std::fs::write(&hook, format!("{original}echo local\n")).unwrap();
    let r = run_h(&h);
    let f = hook_findings(&r);
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(f[0].message.contains("відрізняється від шаблону плагіна"));
    std::fs::write(&hook, &original).unwrap();

    // Режим 100644 в індексі й коміті — warn.
    git(
        &h.root,
        &[
            "update-index",
            "--chmod=-x",
            "--",
            ".githooks/pre-merge-commit",
        ],
    );
    let r = run_h(&h);
    let f = hook_findings(&r);
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .contains("закомічено без біта виконання (режим 100644)")
    );

    // Індекс 100755, а HEAD 100644 (стан після `commit --only` на Windows): спершу коміт без біта, далі біт в індексі.
    commit(&h.root, "без біта");
    git(
        &h.root,
        &[
            "update-index",
            "--chmod=+x",
            "--",
            ".githooks/pre-merge-commit",
        ],
    );
    let r = run_h(&h);
    let f = hook_findings(&r);
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .contains("у коміті HEAD без біта виконання (100644), хоч в індексі 100755")
    );

    // Файла хука немає — error; хук на диску, але не в git — warn.
    std::fs::remove_file(h.root.join(".githooks/pre-commit")).unwrap();
    git(
        &h.root,
        &["rm", "-q", "--cached", "--", ".githooks/pre-merge-commit"],
    );
    let r = run_h(&h);
    let texts: Vec<_> = hook_findings(&r)
        .iter()
        .map(|f| f.message.clone())
        .collect();
    assert!(
        texts
            .iter()
            .any(|t| t.starts_with("Хука .githooks/pre-commit немає")),
        "{texts:?}"
    );
    assert!(
        texts.iter().any(|t| t
            .contains("Хук .githooks/pre-merge-commit лежить на диску, але не закомічений у git")),
        "{texts:?}"
    );
}

#[test]
fn hooks_missing_plugin_template_and_git_failure_are_unchecked() {
    let h = healthy("hooks-unchecked");
    // Шаблонів немає в плагіні — «не перевірено», а не тиша.
    let empty = h.tmp.0.join("порожньо");
    std::fs::create_dir_all(&empty).unwrap();
    let out = kit::hooks::audit(&h.root, Some(&empty));
    assert_eq!(out.len(), 2, "{out:?}");
    for o in &out {
        match o {
            kit::hooks::Outcome::Unchecked { reason, .. } => {
                assert!(reason.contains("не знайдено в плагіні"), "{reason}");
            }
            other => panic!("{other:?}"),
        }
    }
    let out = kit::hooks::audit(&h.root, None);
    assert_eq!(out.len(), 2, "{out:?}");

    // Індекс зіпсовано: `ls-files -s` падає — «не перевірено» на кожен хук, а не «закомічено».
    std::fs::write(h.root.join(".git").join("index"), b"garbage").unwrap();
    let r = run_h(&h);
    let f = hook_findings(&r);
    assert_eq!(f.len(), 2, "{:?}", r.findings);
    assert!(
        f.iter()
            .all(|x| x.level == Level::Warn && x.message.starts_with("не перевірено: режим хука")),
        "{f:?}"
    );
    assert!(f.iter().all(|x| r.not_checked.contains(x)));
}

#[test]
fn hooks_and_hook_shim_run_when_the_manifest_is_unread() {
    // Рішення 6: страж не залежить від розв'язаного контексту.
    let h = healthy("hooks-ctx");
    write_file(&h.root, "v8storagekit.yaml", "це: [не маніфест\n");
    git(&h.root, &["config", "--unset", "core.hooksPath"]);
    write_file(&h.root, ".claude/hooks/session-start.ps1", "x");
    let r = run_h(&h);
    assert_eq!(hook_findings(&r).len(), 1, "{:?}", r.findings);
    assert_eq!(by(&r, "hook-shim").len(), 1, "{:?}", r.findings);
    assert_eq!(r.code, 1);
}

// hook-shim

#[test]
fn hook_shim_legacy_settings_shim_file_not_json_structure_and_unreadable() {
    let h = healthy("hook-shim");
    assert!(by(&run_h(&h), "hook-shim").is_empty());

    // Старий хук у settings.json і файл-шим — одна знахідка називає обидва.
    write_file(
        &h.root,
        ".claude/settings.json",
        r#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"pwsh -File .claude/hooks/SESSION-START.PS1"}]}]}}"#,
    );
    write_file(&h.root, ".claude/hooks/session-start.ps1", "x");
    let r = run_h(&h);
    let f = by(&r, "hook-shim");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert_eq!(f[0].level, Level::Warn);
    assert!(
        f[0].message.contains(".claude/settings.json (hooks.SessionStart з командою на session-start.ps1); .claude/hooks/session-start.ps1"),
        "{}",
        f[0].message
    );
    assert!(r.not_checked.is_empty());

    // Чужий хук SessionStart без session-start.ps1 — тиша.
    std::fs::remove_file(h.root.join(".claude/hooks/session-start.ps1")).unwrap();
    write_file(
        &h.root,
        ".claude/settings.json",
        r#"{"hooks":{"SessionStart":[{"hooks":[{"command":"echo"}]}]},"permissions":{}}"#,
    );
    assert!(by(&run_h(&h), "hook-shim").is_empty());

    // Не JSON: «не перевірено», текст не цитує вміст файла.
    const MARKER: &str = "МАРКЕР-секрет-4417";
    write_file(
        &h.root,
        ".claude/settings.json",
        &format!("{{\"k\": \"{MARKER}\" ,,}}"),
    );
    let r = run_h(&h);
    let f = by(&r, "hook-shim");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message.contains("файл не JSON (рядок 1, колонка "),
        "{}",
        f[0].message
    );
    assert!(!all_texts(&r).contains(MARKER));
    assert!(r.not_checked.contains(f[0]));
    assert_eq!(r.code, 3, "{:?}", r.findings);
    let not_json = f[0].message.clone();

    // Валідний JSON неочікуваної структури — інший текст.
    write_file(
        &h.root,
        ".claude/settings.json",
        r#"{"hooks":{"SessionStart":"x"}}"#,
    );
    let r = run_h(&h);
    let f = by(&r, "hook-shim");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message
            .contains("неочікувана структура файла: hooks.SessionStart — не масив")
    );
    assert_ne!(f[0].message, not_json);
    assert!(r.not_checked.contains(f[0]));

    // IO-збій читання — «не перевірено» (код 3), текст — помилка ОС.
    write_file(&h.root, ".claude/settings.json", "{}");
    let _lock = lock_file(&h.root.join(".claude/settings.json"));
    let r = run_h(&h);
    let f = by(&r, "hook-shim");
    assert_eq!(f.len(), 1, "{:?}", r.findings);
    assert!(
        f[0].message.contains("файл не прочитано: "),
        "{}",
        f[0].message
    );
    assert_eq!(r.code, 3, "{:?}", r.findings);
}

#[test]
fn supply_state_is_one_line_when_the_bin_is_unreadable() {
    // Рішення 8: збій читання `.bin` — один рядок «не перевірено» про поставку, а не два.
    let h = healthy("supply-once");
    supply_fixture(&h, true);
    write_file(&h.root, &format!("{SUPPLY}/a.cf"), "cf");
    write_file(&h.root, &format!("{SUPPLY}/.kit-bin-sha1"), "0000");
    let _lock = lock_file(&h.root.join("ws/cf/Ext/ParentConfigurations.bin"));
    let r = run_h(&h);
    let lines: Vec<_> = r
        .findings
        .iter()
        .filter(|f| f.message.contains("поставк"))
        .collect();
    assert_eq!(lines.len(), 1, "{:?}", r.findings);
}
