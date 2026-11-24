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

fn healthy(tag: &str) -> Healthy {
    let tmp = TempDir::new(tag);
    let root = tmp.0.join("repo");
    init_repo(&root, "main", true);
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
    assert_eq!(r.not_checked.len(), 1, "{:?}", r.findings);
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
