// Форма помилки розбору YAML і межі довіри §6 (задача 4, B1).
//
// 1. Класи, де PowerShell вклеює текст YamlDotNet (YAML не розбирається, дубль ключа, кілька документів), Rust
//    називає лише файл і місце (рядок, колонка) — текст `serde_yaml` цитує ключі й значення з файла.
// 2. «Мільярд сміхів» (вкладені якорі й посилання) і надмірна вкладеність завершуються помилкою з іменем файла за
//    стелю часу, а не зависанням чи панікою процесу. Червоніє, якщо обмеження `serde_yaml` обійти (власним
//    розгортанням якорів).

use kit::config::manifest::read_manifest;
use kit::config::overlay::read_overlay;
use kit::config::yaml::{Emptiness, read_yaml};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const MARKER: &str = "ZQMRK7";

fn tmp(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("kit-yamlform-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join(".git")).unwrap();
    std::fs::create_dir_all(d.join("ws")).unwrap();
    d
}

/// Рівно «Файл <шлях> не розбирається як YAML (рядок N, колонка M).» (чи «містить кілька YAML-документів (…)»).
fn assert_place_only(message: &str, path: &Path, what: &str) {
    let shown = path.display().to_string();
    let rest = message
        .strip_prefix(&format!("Файл {shown} не розбирається як YAML (рядок "))
        .or_else(|| {
            message.strip_prefix(&format!(
                "Файл {shown} містить кілька YAML-документів (другий починається в рядку "
            ))
        })
        .unwrap_or_else(|| panic!("{what}: форма повідомлення: {message}"));
    let digits_and_tail: Vec<&str> = rest.split(", колонка ").collect();
    assert_eq!(digits_and_tail.len(), 2, "{what}: {message}");
    assert!(
        digits_and_tail[0].chars().all(|c| c.is_ascii_digit()) && !digits_and_tail[0].is_empty(),
        "{what}: рядок: {message}"
    );
    assert!(
        !message.contains(MARKER),
        "{what}: маркер у повідомленні: {message}"
    );
    for parser_word in [
        "did not find",
        "duplicate",
        "mapping values",
        "unknown anchor",
        "invalid",
        "expected",
        "while parsing",
    ] {
        assert!(
            !message.to_lowercase().contains(parser_word),
            "{what}: текст парсера «{parser_word}» у {message}"
        );
    }
}

#[test]
fn yaml_errors_name_file_and_place_only() {
    let inputs = [
        (
            "незакрита послідовність",
            format!("key: [{MARKER}\nother: 1\n"),
        ),
        ("незакрита лапка", format!("key: '{MARKER}\n")),
        ("дубль ключа", format!("{MARKER}: 1\n{MARKER}: 2\n")),
        ("табуляція в відступі", format!("a:\n\t{MARKER}: 1\n")),
        ("невідомий якір", format!("a: *{MARKER}\n")),
        (
            "значення мапи без двокрапки",
            format!("a: 1\n  {MARKER} b: 2\n  - x\n"),
        ),
        ("кілька документів", format!("a: 1\n---\n{MARKER}: 2\n")),
    ];
    let d = tmp("form");
    for (what, text) in inputs {
        let p = d.join("f.yaml");
        std::fs::write(&p, &text).unwrap();
        // Той самий розбір для маніфесту, накладки й загального читача.
        let e = read_yaml(&p, Emptiness::Required).unwrap_err();
        assert_place_only(e.message(), &p, what);
        let e = read_manifest(&p, false).unwrap_err();
        assert_place_only(e.message(), &p, what);
        let e = read_overlay(&p).unwrap_err();
        assert_place_only(e.message(), &p, what);
    }
}

/// Корінь з `depth` рівнів вкладених якорів: кожен рівень повторює попередній 9 разів (9^depth вузлів після розгортання).
fn laughs(depth: usize) -> String {
    let mut text = String::from(
        "lol0: &a0 [\"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\"]\n",
    );
    for i in 1..depth {
        let prev = format!("*a{}", i - 1);
        let items = vec![prev; 9].join(", ");
        text.push_str(&format!("lol{i}: &a{i} [{items}]\n"));
    }
    text
}

/// Запускає підкоманду, чекає не довше `ceiling`; повертає (код, stdout, stderr) або `None` на зависанні.
fn run_with_ceiling(
    dir: &Path,
    mode: &str,
    ceiling: Duration,
) -> Option<(Option<i32>, String, String)> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_kit"))
        .args(["config-preflight", "-RepoRoot"])
        .arg(dir)
        .args(["-Mode", mode])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let start = Instant::now();
    loop {
        if child.try_wait().unwrap().is_some() {
            let out = child.wait_with_output().unwrap();
            return Some((
                out.status.code(),
                String::from_utf8_lossy(&out.stdout).into_owned(),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            ));
        }
        if start.elapsed() > ceiling {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn valid_manifest() -> &'static str {
    "version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources:\n      ext: { truth: git }\n"
}

#[test]
fn nested_anchors_end_with_error_not_hang() {
    let bomb = laughs(9);
    // Контроль: невелика глибина тих самих вкладених якорів розбирається (фікстура синтаксично правильна), тож
    // помилка нижче — саме від обмеження розгортання, а не від форми файла.
    let small = tmp("anchors-small");
    std::fs::write(small.join("f.yaml"), laughs(3)).unwrap();
    assert!(read_yaml(&small.join("f.yaml"), Emptiness::Required).is_ok());
    let ceiling = Duration::from_secs(60);

    // Три файли, які kit читає: маніфест, накладка, v8project.local.yaml.
    for (what, relative) in [
        ("маніфест", "v8storagekit.yaml"),
        ("накладка", "v8storagekit.local.yaml"),
        ("local", "ws/v8project.local.yaml"),
    ] {
        let d = tmp(&format!("anchors-{}", relative.replace(['/', '.'], "_")));
        std::fs::write(d.join("v8storagekit.yaml"), valid_manifest()).unwrap();
        std::fs::write(
            d.join("ws").join("v8project.yaml"),
            "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: ext, type: EXTENSION, path: e }\n",
        )
        .unwrap();
        let target = d.join(relative);
        let text = if relative == "v8storagekit.yaml" {
            format!("{}{bomb}", valid_manifest())
        } else {
            bomb.clone()
        };
        std::fs::write(&target, text).unwrap();

        let started = Instant::now();
        // Strict: перша помилка — зупинка; Lenient: знахідка. В обох — ім'я файла й не зависання.
        for mode in ["Strict", "Lenient"] {
            let (code, stdout, stderr) = run_with_ceiling(&d, mode, ceiling)
                .unwrap_or_else(|| panic!("{what} [{mode}]: зависання понад {ceiling:?}"));
            assert_eq!(
                code,
                Some(0),
                "{what} [{mode}]: код процесу (паніка дала б не 0): {stderr}"
            );
            assert!(
                !stderr.contains(kit::PANIC_TEXT),
                "{what} [{mode}]: паніка: {stderr}"
            );
            let name = relative.rsplit('/').next().unwrap();
            assert!(
                stdout.contains(name) && stdout.contains("не розбирається як YAML"),
                "{what} [{mode}]: помилка з іменем файла очікувалась:\n{stdout}"
            );
            assert!(
                !stdout.contains("lol"),
                "{what} [{mode}]: вміст файла в помилці:\n{stdout}"
            );
        }
        assert!(
            started.elapsed() < ceiling,
            "{what}: розбір не вклався в стелю часу"
        );
    }
}

#[test]
// Глибина понад ліміт рекурсії `serde_yaml` (128) завершується помилкою, а не падінням. Час розбору ЗРОСТАЄ квадратично
// з глибиною (libyaml сканує весь потік до першої події; 80 000 рівнів — десятки секунд у debug) — це межа залежності,
// у Concerns задачі 4; тут глибина, що вкладається в секунди.
fn deep_nesting_ends_with_error_not_crash() {
    let d = tmp("deep");
    std::fs::write(
        d.join("v8storagekit.yaml"),
        format!(
            "{}x: {}{}\n",
            valid_manifest(),
            "[".repeat(5_000),
            "]".repeat(5_000)
        ),
    )
    .unwrap();
    let (code, stdout, stderr) = run_with_ceiling(&d, "Strict", Duration::from_secs(60))
        .expect("зависання на глибокій вкладеності");
    assert_eq!(code, Some(0), "код процесу: {stderr}");
    assert!(
        stdout.contains("v8storagekit.yaml") && stdout.contains("не розбирається як YAML"),
        "{stdout}"
    );
}

// Злиття ключів мап без регістру лінійне: 40 000 ключів у `storages:` розбираються за секунди. Квадратична версія
// (лінійний пошук по вже прочитаних ключах) на цьому вході тримається десятки секунд — стеля щедра, щоб не залежати
// від машини, але такої версії не пропускає.
#[test]
fn many_keys_are_merged_in_linear_time() {
    let d = tmp("many-keys");
    let p = d.join("v8storagekit.local.yaml");
    let mut text = String::from("storages:\n");
    for i in 0..40_000 {
        text.push_str(&format!("  k{i}: 'C:\\st'\n"));
    }
    std::fs::write(&p, &text).unwrap();
    let started = Instant::now();
    let overlay = read_overlay(&p).unwrap();
    let elapsed = started.elapsed();
    assert_eq!(overlay.storages.len(), 40_000);
    assert!(
        elapsed < Duration::from_secs(30),
        "40 000 ключів: {elapsed:?} — злиття ключів стало нелінійним"
    );
}
