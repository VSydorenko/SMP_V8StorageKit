// Тести модуля `unica` (ADR-0019): семантика реєстру (регістр імені, одиночний запис і масив, BOM), вибір запису
// (рішення 4 плану B2) і таблиці вердиктів з тими самими рядками й текстами, що в Pester
// (tools/tests/Environment.Tests.ps1, Runner.Tests.ps1). Лише фальшиві реєстри й фальшивий раннер.

use kit::unica::{self, Level};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

const FAKE: &str = env!("CARGO_BIN_EXE_fake-runner");

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("kit-unica-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    fn dir(&self, name: &str) -> PathBuf {
        let d = self.0.join(name);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn registry(&self, body: &str) -> PathBuf {
        let p = self.0.join("installed_plugins.json");
        std::fs::write(&p, body).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn plugins(v: Value) -> String {
    json!({"version": 2, "plugins": v}).to_string()
}

fn rec(scope: &str, project: Option<&Path>, version: &str, install: &Path) -> Value {
    let mut r = json!({"scope": scope, "version": version, "installPath": install});
    if let Some(p) = project {
        r["projectPath"] = json!(p);
    }
    r
}

// ---- Семантика реєстру ----

#[test]
fn registry_unavailable_states_name_the_cause() {
    let tmp = TempDir::new("states");
    let missing = tmp.0.join("ніякого-реєстру.json");
    let i = unica::installation(&missing, None);
    assert!(!i.installed);
    assert_eq!(
        i.reason,
        format!("Реєстр плагінів не знайдено: {}", missing.display())
    );

    let broken = tmp.registry("{ \"plugins\": { ");
    let i = unica::installation(&broken, None);
    assert!(
        i.reason.starts_with(&format!(
            "Реєстр плагінів не читається як JSON ({}): ",
            broken.display()
        )),
        "{}",
        i.reason
    );

    let no_section = tmp.registry("{ \"version\": 2 }");
    assert_eq!(
        unica::installation(&no_section, None).reason,
        format!("У реєстрі {} немає розділу 'plugins'", no_section.display())
    );

    let empty = tmp.registry(&plugins(json!({"unica@unica": []})));
    assert_eq!(
        unica::installation(&empty, None).reason,
        "Плагін 'unica' є в реєстрі, але без жодного запису про встановлення"
    );

    let lookalike = tmp.registry(&plugins(
        json!({"unica-extras@somewhere": [rec("user", None, "1.0.0", &tmp.0)]}),
    ));
    let i = unica::installation(&lookalike, None);
    assert!(!i.installed);
    assert_eq!(
        i.reason,
        format!(
            "Плагін 'unica' не значиться в реєстрі {}",
            lookalike.display()
        )
    );
}

#[test]
fn name_is_case_insensitive_and_value_may_be_object_or_array() {
    let tmp = TempDir::new("shape");
    let install = tmp.dir("unica-0.16.0");
    for body in [
        plugins(json!({"Unica@Unica": [rec("user", None, "0.16.0", &install)]})),
        plugins(json!({"unica@unica": rec("user", None, "0.16.0", &install)})),
    ] {
        let i = unica::installation(&tmp.registry(&body), None);
        assert!(i.installed && i.path_exists, "{}", i.reason);
        assert_eq!(i.version, "0.16.0");
        assert_eq!(i.install_path, install.to_string_lossy());
        assert!(i.reason.is_empty());
    }
}

#[test]
fn utf8_bom_is_stripped() {
    let tmp = TempDir::new("bom");
    let install = tmp.dir("u");
    let body = format!(
        "\u{feff}{}",
        plugins(json!({"unica@unica": [rec("user", None, "0.16.0", &install)]}))
    );
    assert!(unica::installation(&tmp.registry(&body), None).installed);
}

#[test]
fn registry_and_disk_may_disagree() {
    let tmp = TempDir::new("disk");
    let gone = tmp.0.join("видалена-тека");
    let i = unica::installation(
        &tmp.registry(&plugins(
            json!({"unica@unica": [rec("user", None, "0.12.3", &gone)]}),
        )),
        None,
    );
    assert!(i.installed && !i.path_exists);
    assert_eq!(
        i.reason,
        format!(
            "Реєстр вказує на теку, якої немає на диску: {}",
            gone.display()
        )
    );
    let i = unica::installation(
        &tmp.registry(&plugins(
            json!({"unica@unica": [{"scope": "user", "version": "0.12.3"}]}),
        )),
        None,
    );
    assert!(i.installed && !i.path_exists);
    assert_eq!(i.reason, "Запис про 'unica' є, але без installPath");
}

// ---- Вибір запису (рішення 4) ----

#[test]
fn foreign_project_entry_first_is_not_chosen() {
    let tmp = TempDir::new("foreign");
    let (foreign, mine, repo) = (
        tmp.dir("foreign-install"),
        tmp.dir("user-install"),
        tmp.dir("repo"),
    );
    // Ключ чужого проєкту стоїть першим і в алфавіті ключів.
    let reg = tmp.registry(&plugins(json!({
        "unica@a": [rec("project", Some(&tmp.0.join("чужий-репо")), "0.15.0", &foreign)],
        "unica@z": [rec("user", None, "0.16.0", &mine)],
    })));
    let i = unica::installation(&reg, Some(&repo));
    assert!(i.installed, "{}", i.reason);
    assert_eq!(i.install_path, mine.to_string_lossy());
    assert_eq!(i.version, "0.16.0");
    // Без репозиторію — теж лише user.
    assert_eq!(
        unica::installation(&reg, None).install_path,
        mine.to_string_lossy()
    );
}

#[test]
fn only_foreign_project_entry_means_not_installed() {
    let tmp = TempDir::new("onlyforeign");
    let foreign = tmp.dir("f");
    let reg = tmp.registry(&plugins(
        json!({"unica@unica": [rec("project", Some(&tmp.0.join("чужий")), "0.16.0", &foreign)]}),
    ));
    let i = unica::installation(&reg, Some(&tmp.dir("repo")));
    assert!(!i.installed && i.candidates.is_empty());
}

/// Канонізований корінь (`\\?\C:\…`) збігається з `projectPath` без префікса; контроль — чужий корінь з префіксом.
#[test]
fn extended_length_prefix_on_repo_root_is_ignored() {
    let tmp = TempDir::new("verbatim");
    let install = tmp.dir("install");
    let project = PathBuf::from(r"C:\x\repo");
    let reg = tmp.registry(&plugins(
        json!({"unica@unica": [rec("project", Some(&project), "0.16.1", &install)]}),
    ));
    let i = unica::installation(&reg, Some(Path::new(r"\\?\C:\x\repo")));
    assert!(i.installed, "{}", i.reason);
    let i = unica::installation(&reg, Some(Path::new(r"\\?\C:\x\other")));
    assert!(!i.installed);
    // UNC: `\\?\UNC\srv\share\repo` ≡ `\\srv\share\repo`.
    let unc = PathBuf::from(r"\\srv\share\repo");
    let reg = tmp.registry(&plugins(
        json!({"unica@unica": [rec("project", Some(&unc), "0.16.1", &install)]}),
    ));
    assert!(unica::installation(&reg, Some(Path::new(r"\\?\UNC\srv\share\repo"))).installed);
}

#[test]
fn own_project_entry_and_ancestor_project_path_are_candidates() {
    let tmp = TempDir::new("own");
    let install = tmp.dir("install");
    let repo = tmp.dir("work").join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    for project in [repo.clone(), tmp.0.join("work")] {
        let reg = tmp.registry(&plugins(
            json!({"unica@unica": [rec("project", Some(&project), "0.16.1", &install)]}),
        ));
        let i = unica::installation(&reg, Some(&repo));
        assert!(i.installed, "{}", i.reason);
        assert_eq!(i.version, "0.16.1");
    }
    // Спільний префікс рядка, але не предок: wor не охоплює work/repo.
    let sibling = tmp.0.join("wor");
    let reg = tmp.registry(&plugins(
        json!({"unica@unica": [rec("local", Some(&sibling), "0.16.1", &install)]}),
    ));
    assert!(!unica::installation(&reg, Some(&repo)).installed);
}

#[test]
fn user_plus_own_project_is_an_error_naming_both_and_the_uninstall_step() {
    let tmp = TempDir::new("both");
    let (a, b, repo) = (tmp.dir("a"), tmp.dir("b"), tmp.dir("repo"));
    let reg = tmp.registry(&plugins(json!({"unica@unica": [rec("user", None, "0.16.0", &a), rec("project", Some(&repo), "0.16.2", &b)]})));
    let i = unica::installation(&reg, Some(&repo));
    assert!(!i.installed);
    assert_eq!(i.candidates.len(), 2);
    for needle in [
        "unica@unica (scope user, projectPath -, версія 0.16.0)",
        "scope project",
        "0.16.2",
        "claude plugin uninstall unica@unica --scope user",
        "claude plugin uninstall unica@unica --scope project",
    ] {
        assert!(i.reason.contains(needle), "немає {needle:?} у {}", i.reason);
    }
    let v = unica::unica_verdict(&i);
    assert_eq!(v.level, Level::Error);
    assert_eq!(v.message, i.reason);
    // Раннер за двозначного вибору — теж error, без запуску.
    let rv = unica::runner_verdict(None, &reg, Some(&repo));
    assert_eq!(rv.level, Level::Error);
    assert!(
        rv.message
            .starts_with("Раннер Уніки недоступний: Раннер не знайдено: У реєстрі"),
        "{}",
        rv.message
    );
}

#[test]
fn two_user_entries_are_an_error_and_one_user_entry_is_chosen() {
    let tmp = TempDir::new("twouser");
    let (a, b) = (tmp.dir("a"), tmp.dir("b"));
    let two = tmp.registry(&plugins(json!({"unica@x": [rec("user", None, "0.16.0", &a)], "unica@y": [rec("user", None, "0.16.0", &b)]})));
    let i = unica::installation(&two, None);
    assert!(!i.installed);
    assert_eq!(i.candidates.len(), 2);
    assert!(
        i.reason
            .contains("claude plugin uninstall unica@x --scope user")
            && i.reason
                .contains("claude plugin uninstall unica@y --scope user")
    );
    // Контроль: один user-запис обирається.
    let one = tmp.registry(&plugins(
        json!({"unica@x": [rec("user", None, "0.16.0", &a)]}),
    ));
    let i = unica::installation(&one, None);
    assert!(i.installed && i.candidates.len() == 1);
}

// ---- Таблиці вердиктів ----

fn verdict_for(version: &str) -> unica::Verdict {
    unica::unica_verdict(&unica::Installation {
        installed: true,
        path_exists: true,
        version: version.into(),
        install_path: "C:\\u".into(),
        ..Default::default()
    })
}

#[test]
fn unica_verdict_table() {
    for (v, level) in [
        ("0.15.2", Level::Error),
        ("0.13.0", Level::Error),
        ("0.16.0", Level::Ok),
        ("0.16.9", Level::Ok),
        ("0.17.0", Level::Warn),
        ("1.0.0", Level::Warn),
        ("dev", Level::Warn),
    ] {
        assert_eq!(verdict_for(v).level, level, "{v}");
    }
    assert_eq!(verdict_for("0.16.0").message, "Плагін unica 0.16.0.");
    assert_eq!(
        verdict_for("0.15.2").message,
        "Плагін unica 0.15.2 старіший за 0.16: kit говорить лише мовою Уніки 0.16 (v8-runner 0.18), старого словника в скілах і шаблонах більше немає. \
         Оновіть Уніку — claude plugin marketplace update unica; claude plugin update unica@unica — і почніть нову сесію (оновлення перемикає всі репозиторії машини)."
    );
    assert_eq!(
        verdict_for("0.17.0").message,
        "Плагін unica 0.17.0 новіший за перевірену 0.16.x: перед роботою звірте контракт за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit)."
    );
    assert_eq!(
        verdict_for("dev").message,
        "Версію плагіна unica 'dev' не розібрано — kit перевірено на Уніці 0.16.x."
    );
    let none = unica::unica_verdict(&unica::Installation {
        reason: "немає в реєстрі".into(),
        ..Default::default()
    });
    assert_eq!(none.level, Level::Error);
    assert_eq!(
        none.message,
        "Плагін unica не знайдено (немає в реєстрі): sync, verify і provision беруть раннер із його встановлення й без нього не працюють \
         (kit dump працює й без Уніки — він бере платформу напряму). \
         Встановіть: claude plugin marketplace add IngvarConsulting/unica-marketplace; claude plugin install unica@unica."
    );
}

fn runner_with_version(tmp: &TempDir, name: &str, line: &str) -> PathBuf {
    let dir = tmp.dir(name);
    let exe = dir.join("v8-runner.exe");
    std::fs::copy(FAKE, &exe).unwrap();
    std::fs::write(dir.join("version.txt"), line).unwrap();
    exe
}

#[test]
fn runner_verdict_table() {
    let tmp = TempDir::new("rv");
    let none = tmp.0.join("не-реєстр.json");
    for (line, level) in [
        ("0.18.1", Level::Ok),
        ("0.18.9-fork.3", Level::Ok),
        ("0.19.0", Level::Warn),
        ("0.17.4", Level::Warn),
    ] {
        let exe = runner_with_version(&tmp, &format!("r{line}"), line);
        let v = unica::runner_verdict(Some(&exe), &none, None);
        assert_eq!(v.level, level, "{line}");
        assert_eq!(v.version, line);
    }
    let exe = runner_with_version(&tmp, "ok", "0.18.1");
    assert_eq!(
        unica::runner_verdict(Some(&exe), &none, None).message,
        "Раннер v8-runner 0.18.1."
    );
    let exe = runner_with_version(&tmp, "warn", "0.19.0");
    assert_eq!(
        unica::runner_verdict(Some(&exe), &none, None).message,
        "Раннер v8-runner 0.19.0 — kit перевірено на 0.18.x: перед роботою звірте контракт за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit)."
    );
    // Файла раннера немає — error із шляхом і нагадуванням про kit dump.
    let v = unica::runner_verdict(
        Some(&tmp.0.join("немає").join("v8-runner.exe")),
        &none,
        None,
    );
    assert_eq!(v.level, Level::Error);
    assert!(
        v.message.starts_with("Раннер Уніки недоступний: Раннер не знайдено: ")
            && v.message.contains("немає")
            && v.message.ends_with("sync, verify і provision без раннера не працюють (kit dump працює й без нього — він бере платформу напряму)."),
        "{}",
        v.message
    );
    // Без явного шляху раннер береться з реєстру: реєстр без плагіна — error.
    let reg = tmp.registry(r#"{"version":2,"plugins":{}}"#);
    assert_eq!(unica::runner_verdict(None, &reg, None).level, Level::Error);
}

#[test]
fn installed_runner_is_built_from_install_path_only() {
    let tmp = TempDir::new("installed");
    let install = tmp.dir("unica");
    let reg = tmp.registry(&plugins(
        json!({"unica@unica": [rec("user", None, "0.16.0", &install)]}),
    ));
    let err = kit::runner::installed_runner(&reg, None).unwrap_err();
    let expected = install
        .join("bin")
        .join("win-x64")
        .join("v8-runner-windows-x86_64")
        .join("v8-runner.exe");
    assert_eq!(
        err,
        format!(
            "Раннер не знайдено: у встановленій Уніці ({}) немає файла {}",
            install.display(),
            expected.display()
        )
    );
    std::fs::create_dir_all(expected.parent().unwrap()).unwrap();
    std::fs::copy(FAKE, &expected).unwrap();
    assert_eq!(kit::runner::installed_runner(&reg, None).unwrap(), expected);
    // Реєстр без Уніки.
    let empty = tmp.registry(r#"{"version":2,"plugins":{}}"#);
    assert!(
        kit::runner::installed_runner(&empty, None)
            .unwrap_err()
            .starts_with("Раннер не знайдено: Unica не встановлена. Плагін 'unica' не значиться")
    );
}
