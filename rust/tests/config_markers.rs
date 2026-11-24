// Маркерні тести інваріантів безпеки (ADR-0021 п. 5): секрети й ключі/значення YAML, що не пройшли перевірку,
// не з'являються ні в `Display`/`Debug` помилок і знахідок модуля `config`, ні в stdout/stderr підкоманди
// `kit config-preflight`. Маркер — ASCII без спецсимволів JSON (інакше JSON друкує \uXXXX і пошук підрядка сліпий),
// плюс варіант з `"` (шукається алфавітна частина; так маркер доходить до `Assert-V8SecretQuoteFree`) і з
// багатобайтовими символами біля роздільників (`;`, `=`, лапка).
//
// Самої присутності маркера у файлі мало: префлайт міг зупинитись раніше. Тому кожен випадок має позитивного двійника:
// той самий вхід дає очікувану знахідку чи помилку СВОГО класу, а пароль — ознаку «задано» в JSON, тобто маркер
// пройшов шлях, що його вивів би. Двійник перевіряється і на JSON модуля, і на JSON підкоманди.

use kit::config::{Mode, agent_base, agent_base_collisions, preflight};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

const TOKEN: &str = "ZQMRK7";

/// Значення маркера у файлі: проста форма, форма з `"` перед алфавітною частиною і багатобайтові символи по краях.
const VARIANTS: [(&str, &str, bool); 3] = [
    ("plain", "ZQMRK7", false),
    ("quote", "a\"ZQMRK7", true),
    ("multibyte", "ʼZQMRK7ʼ", false),
];

#[derive(Clone, Copy)]
enum File {
    Manifest,
    Overlay,
    Local,
}

enum Expect {
    /// Знахідка з перевіркою `check`, текст якої містить `part`.
    Finding(&'static str, &'static str),
    /// Помилка бази агента чи перетинів містить `part`.
    BaseError(&'static str),
    /// Значення за JSON-вказівником.
    Is(&'static str, Value),
    /// Два значення за JSON-вказівниками (друге доводить, що вхід пройшов розбір).
    IsBoth(&'static str, Value, &'static str, Value),
}

struct Case {
    name: &'static str,
    file: File,
    /// Текст файла; `{M}` замінюється значенням маркера (завжди в одинарних лапках YAML).
    text: &'static str,
    expect: Expect,
    /// `Some(true)` — лише варіант із `"`, `Some(false)` — усі, крім нього.
    quote_only: Option<bool>,
}

fn case(name: &'static str, file: File, text: &'static str, expect: Expect) -> Case {
    Case {
        name,
        file,
        text,
        expect,
        quote_only: None,
    }
}

fn cases() -> Vec<Case> {
    use File::{Local, Manifest, Overlay};
    let on = |c: Case, q: bool| Case {
        quote_only: Some(q),
        ..c
    };
    let json_true = Value::Bool(true);
    vec![
        // --- накладка: рядок замість мапи ---
        case(
            "overlay infobases: рядок",
            Overlay,
            "infobases: '{M}'\n",
            Expect::Finding("overlay", "infobases: має бути мапою"),
        ),
        case(
            "overlay storages: рядок",
            Overlay,
            "storages: '{M}'\n",
            Expect::Finding("overlay", "storages: має бути мапою"),
        ),
        case(
            "overlay workspaces: рядок",
            Overlay,
            "workspaces: '{M}'\n",
            Expect::Finding("overlay", "workspaces: має бути мапою"),
        ),
        case(
            "overlay запис бази рядком",
            Overlay,
            "infobases:\n  dev: '{M}'\n",
            Expect::Finding("overlay", "має бути мапою"),
        ),
        case(
            "overlay агентська база не мапа",
            Overlay,
            "workspaces:\n  ws: { agentBase: '{M}' }\n",
            Expect::Finding("overlay", "має бути мапою"),
        ),
        // --- маніфест: запис `sources` без значення (ключ без `:`) — ім'я не друкується, лише номер запису ---
        case(
            "manifest запис sources без значення",
            Manifest,
            "version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources: { cf: { truth: git }, '{M}' }\n",
            Expect::Finding("manifest", "запис №2 без значення"),
        ),
        // --- дубль ключа (розбір YAML) ---
        case(
            "overlay дубль ключа",
            Overlay,
            "'{M}': 1\n'{M}': 2\n",
            Expect::Finding("overlay", "не розбирається як YAML"),
        ),
        case(
            "local дубль ключа",
            Local,
            "infobases:\n  origin: { connection: 'File=build/ib' }\n'{M}': 1\n'{M}': 2\n",
            Expect::Finding("workspace", "не розбирається як YAML"),
        ),
        // --- невідомий ключ ---
        case(
            "overlay невідомий ключ угорі",
            Overlay,
            "'{M}': 1\n",
            Expect::Finding("overlay", "невідомий ключ"),
        ),
        case(
            "overlay невідомий ключ запису бази",
            Overlay,
            "infobases:\n  dev: { connection: 'File=C:\\h', '{M}': 1 }\n",
            Expect::Finding("overlay", "невідомий ключ"),
        ),
        case(
            "overlay невідомий ключ запису сховища",
            Overlay,
            "storages:\n  cf: { '{M}': 1 }\n",
            Expect::Finding("overlay", "невідомий ключ"),
        ),
        case(
            "overlay невідомий ключ воркспейсу",
            Overlay,
            "workspaces:\n  ws: { '{M}': 1 }\n",
            Expect::Finding("overlay", "невідомий ключ"),
        ),
        case(
            "overlay невідомий ключ agentBase",
            Overlay,
            "workspaces:\n  ws: { agentBase: { '{M}': 1 } }\n",
            Expect::Finding("overlay", "невідомий ключ"),
        ),
        // --- запис без значення ---
        case(
            "overlay запис бази без значення",
            Overlay,
            "infobases:\n  '{M}':\n",
            Expect::Finding("overlay", "без значення"),
        ),
        case(
            "overlay запис сховища без значення",
            Overlay,
            "storages:\n  '{M}':\n",
            Expect::Finding("overlay", "без значення"),
        ),
        case(
            "overlay запис воркспейсу без значення",
            Overlay,
            "workspaces:\n  '{M}':\n",
            Expect::Finding("overlay", "без значення"),
        ),
        // --- неправильна форма шляху сховища ---
        case(
            "overlay шлях сховища рядком",
            Overlay,
            "storages:\n  cf: '{M}'\n",
            Expect::Finding("overlay", "шлях сховища має форму"),
        ),
        case(
            "overlay шлях сховища у мапі",
            Overlay,
            "storages:\n  cf: { path: '{M}' }\n",
            Expect::Finding("overlay", "шлях сховища має форму"),
        ),
        // --- неправильний рядок підключення (база людини в накладці проти бази агента) ---
        case(
            "overlay підключення: невідомий ключ після дозволених",
            Overlay,
            "infobases:\n  dev: { connection: 'Srvr=a;Ref=b;{M}=x' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "overlay підключення: Usr",
            Overlay,
            "infobases:\n  dev: { connection: 'Srvr=a;Ref=b;Usr={M}' }\n",
            Expect::BaseError("логін чи пароль"),
        ),
        case(
            "overlay підключення: Pwd",
            Overlay,
            "infobases:\n  dev: { connection: 'Srvr=a;Ref=b;Pwd={M}' }\n",
            Expect::BaseError("логін чи пароль"),
        ),
        case(
            "overlay підключення: значення File без ';'",
            Overlay,
            "infobases:\n  dev: { connection: 'File=C:\\x,Pwd={M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "overlay підключення: голий шлях",
            Overlay,
            "infobases:\n  dev: { connection: '{M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "overlay підключення: ключ і значення з маркером",
            Overlay,
            "infobases:\n  dev: { connection: 'Srvr=a;Ref=b;{M}={M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        // --- пароль сховища ---
        on(
            case(
                "overlay пароль сховища",
                Overlay,
                "storages:\n  cf: { password: '{M}' }\n",
                Expect::Is(
                    "/context/workspaces/0/sources/0/storagePasswordSet",
                    json_true.clone(),
                ),
            ),
            false,
        ),
        on(
            case(
                "overlay пароль сховища з \"",
                Overlay,
                "storages:\n  cf: { password: '{M}' }\n",
                Expect::Finding("overlay", "подвійну лапку"),
            ),
            true,
        ),
        // --- v8project.local.yaml ---
        case(
            "local infobases: рядок",
            Local,
            "infobases: '{M}'\n",
            Expect::Finding("workspace", "infobases має бути мапою"),
        ),
        case(
            "local ключ infobases, відмінний від origin",
            Local,
            "infobases:\n  '{M}': { connection: 'File=x' }\n",
            Expect::Finding("workspace", "відмінний від origin"),
        ),
        case(
            "local origin рядком",
            Local,
            "infobases:\n  origin: '{M}'\n",
            Expect::Finding("workspace", "без connection"),
        ),
        case(
            "local корінь — список",
            Local,
            "- '{M}'\n",
            Expect::Finding("workspace", "не читається"),
        ),
        case(
            "local стара форма infobase",
            Local,
            "infobase: { connection: 'File=x', password: '{M}' }\n",
            Expect::Finding("workspace", "стара форма"),
        ),
        case(
            "local невідомий ключ origin (мовчки приймається)",
            Local,
            "infobases:\n  origin: { connection: 'File=build/ib', '{M}': 1 }\n",
            Expect::Is(
                "/context/workspaces/0/agentBase/base/connection/parses",
                json_true.clone(),
            ),
        ),
        case(
            "local підключення: невідомий ключ після дозволених",
            Local,
            "infobases:\n  origin: { connection: 'Srvr=a;Ref=b;{M}=x' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "local підключення: Usr",
            Local,
            "infobases:\n  origin: { connection: 'Srvr=a;Ref=b;Usr={M}' }\n",
            Expect::BaseError("логін чи пароль"),
        ),
        case(
            "local підключення: Pwd",
            Local,
            "infobases:\n  origin: { connection: 'File=a;Pwd={M}' }\n",
            Expect::BaseError("логін чи пароль"),
        ),
        case(
            "local підключення: значення File без ';'",
            Local,
            "infobases:\n  origin: { connection: 'File=C:\\x,Pwd={M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "local підключення: голий шлях",
            Local,
            "infobases:\n  origin: { connection: '{M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        case(
            "local підключення: ключ і значення з маркером",
            Local,
            "infobases:\n  origin: { connection: 'Srvr=a;Ref=b;{M}={M}' }\n",
            Expect::BaseError("Рядок підключення"),
        ),
        // --- пароль бази агента, ключ і значення в dbms ---
        on(
            case(
                "local пароль бази агента",
                Local,
                "infobases:\n  origin: { connection: 'File=build/ib', password: '{M}' }\n",
                Expect::Is(
                    "/context/workspaces/0/agentBase/base/passwordSet",
                    json_true.clone(),
                ),
            ),
            false,
        ),
        on(
            case(
                "local пароль бази агента з \"",
                Local,
                "infobases:\n  origin: { connection: 'File=build/ib', password: '{M}' }\n",
                Expect::Finding("workspace", "подвійну лапку"),
            ),
            true,
        ),
        case(
            "local dbms: ключ і значення",
            Local,
            "infobases:\n  origin: { connection: 'File=build/ib', dbms: { '{M}': '{M}' } }\n",
            Expect::Is(
                "/context/workspaces/0/agentBase/base/dbmsSet",
                json_true.clone(),
            ),
        ),
        case(
            "local dbms: рядком",
            Local,
            "infobases:\n  origin: { connection: 'File=build/ib', dbms: '{M}' }\n",
            Expect::IsBoth(
                "/context/workspaces/0/agentBase/base/dbmsSet",
                Value::Bool(false),
                "/context/workspaces/0/agentBase/base/connection/parses",
                Value::Bool(true),
            ),
        ),
    ]
}

fn tmp(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("kit-markers-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join(".git")).unwrap();
    std::fs::create_dir_all(d.join("ws")).unwrap();
    std::fs::write(
        d.join("v8storagekit.yaml"),
        "version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources:\n      cf: { truth: storage, storage: { path: 'C:\\st' } }\n      ext: { truth: git }\n",
    )
    .unwrap();
    std::fs::write(
        d.join("ws").join("v8project.yaml"),
        "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: cf, type: CONFIGURATION, path: cf }\n  - { name: ext, type: EXTENSION, path: ext }\n",
    )
    .unwrap();
    std::fs::write(
        d.join("ws").join("v8project.local.yaml"),
        "infobases:\n  origin: { connection: 'File=build/ib' }\n",
    )
    .unwrap();
    d
}

fn write_case(dir: &Path, c: &Case, value: &str) -> String {
    let text = c.text.replace("{M}", value);
    let path = match c.file {
        File::Manifest => dir.join("v8storagekit.yaml"),
        File::Overlay => dir.join("v8storagekit.local.yaml"),
        File::Local => dir.join("ws").join("v8project.local.yaml"),
    };
    std::fs::write(path, &text).unwrap();
    text
}

/// Усе, що модуль `config` може показати людині для цього репозиторію: `Display`/`Debug` помилок і знахідок,
/// `Debug` контексту (з типами секретів), бази агента й перетинів, JSON підкоманди — у всіх режимах.
fn module_channels(dir: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for mode in [Mode::Strict, Mode::Lenient, Mode::Check] {
        match preflight(dir, mode) {
            Ok(ctx) => {
                out.push((format!("{mode:?} контекст Debug"), format!("{ctx:?}")));
                for f in &ctx.findings {
                    out.push((format!("{mode:?} знахідка Debug"), format!("{f:?}")));
                    out.push((format!("{mode:?} знахідка текст"), f.message.clone()));
                }
                for w in &ctx.workspaces {
                    let base = agent_base(&ctx, w);
                    out.push((format!("{mode:?} база агента"), format!("{base:?}")));
                    if let Err(e) = &base {
                        out.push((format!("{mode:?} база агента Display"), e.to_string()));
                    }
                    out.push((
                        format!("{mode:?} перетини"),
                        format!("{:?}", agent_base_collisions(&ctx, w)),
                    ));
                }
            }
            Err(stop) => {
                out.push((format!("{mode:?} зупинка Debug"), format!("{stop:?}")));
                out.push((format!("{mode:?} зупинка текст"), stop.message.clone()));
            }
        }
        out.push((
            format!("{mode:?} report_json"),
            kit::config::preflight::report_json(dir, mode, None, None, &[]).to_string(),
        ));
    }
    out
}

fn cli(dir: &Path, mode: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_kit"))
        .args(["config-preflight", "-RepoRoot"])
        .arg(dir)
        .args(["-Mode", mode])
        .output()
        .unwrap()
}

/// Двійник: очікувана знахідка чи помилка власного класу, ознака «задано» — у JSON.
fn expectation_holds(v: &Value, expect: &Expect) -> bool {
    match expect {
        Expect::Finding(check, part) => v["findings"].as_array().is_some_and(|f| {
            f.iter().any(|x| {
                x["check"] == *check && x["message"].as_str().is_some_and(|m| m.contains(part))
            })
        }),
        Expect::BaseError(part) => {
            let ws = &v["context"]["workspaces"][0];
            [&ws["agentBase"]["error"], &ws["collisions"]["error"]]
                .iter()
                .any(|e| e.as_str().is_some_and(|m| m.contains(part)))
        }
        Expect::Is(pointer, want) => v.pointer(pointer) == Some(want),
        Expect::IsBoth(p1, w1, p2, w2) => v.pointer(p1) == Some(w1) && v.pointer(p2) == Some(w2),
    }
}

#[test]
fn markers_never_reach_module_or_subcommand_output() {
    let mut total = 0;
    for (idx, c) in cases().iter().enumerate() {
        for (label, value, is_quote) in VARIANTS {
            if c.quote_only.is_some_and(|q| q != is_quote) {
                continue;
            }
            total += 1;
            let dir = tmp(&format!("{idx}{label}"));
            let text = write_case(&dir, c, value);
            let ctx_name = format!("«{}» [{label}]", c.name);
            // Маркер справді у файлі.
            assert!(text.contains(TOKEN), "{ctx_name}: маркера немає у файлі");

            // Двійник на JSON модуля.
            let module_json =
                kit::config::preflight::report_json(&dir, Mode::Lenient, None, None, &[]);
            assert!(
                expectation_holds(&module_json, &c.expect),
                "{ctx_name}: двійник не знайшов свого класу в JSON модуля:\n{module_json}"
            );

            // Канали модуля: Display і Debug помилок і знахідок.
            for (channel, text) in module_channels(&dir) {
                assert!(
                    !text.contains(TOKEN),
                    "{ctx_name}: маркер у каналі «{channel}»:\n{text}"
                );
            }

            // Канали підкоманди: stdout і stderr у всіх режимах; двійник на JSON підкоманди.
            for mode in ["Strict", "Lenient", "Check"] {
                let out = cli(&dir, mode);
                let (stdout, stderr) = (
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr),
                );
                assert_eq!(
                    out.status.code(),
                    Some(0),
                    "{ctx_name} [{mode}]: код виходу, stderr: {stderr}"
                );
                assert!(
                    !stdout.contains(TOKEN),
                    "{ctx_name} [{mode}]: маркер у stdout:\n{stdout}"
                );
                assert!(
                    !stderr.contains(TOKEN),
                    "{ctx_name} [{mode}]: маркер у stderr:\n{stderr}"
                );
                if mode == "Lenient" {
                    let v: Value = serde_json::from_str(&stdout).unwrap();
                    assert!(
                        expectation_holds(&v, &c.expect),
                        "{ctx_name}: двійник не знайшов свого класу в JSON підкоманди:\n{stdout}"
                    );
                }
            }
        }
    }
    // Нижня межа: випадки справді виконано (порожній перелік не дає «зеленого нічого»).
    assert!(total >= 100, "виконано лише {total} маркерних випадків");
}

// Контроль, що вміє впасти: якби підкоманда друкувала пароль, пошук маркера його знайшов би.
#[test]
fn control_marker_search_can_fail() {
    let dir = tmp("control");
    // Не секрет: ім'я користувача сховища друкується, тож маркер у ньому ОБОВ'ЯЗКОВО з'являється в JSON.
    std::fs::write(
        dir.join("v8storagekit.local.yaml"),
        format!("storages:\n  cf: {{ user: '{TOKEN}' }}\n"),
    )
    .unwrap();
    let out = cli(&dir, "Lenient");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains(TOKEN),
        "пошук маркера сліпий: друкований користувач не знайдений"
    );
    let report =
        kit::config::preflight::report_json(&dir, Mode::Lenient, None, None, &[]).to_string();
    assert!(report.contains(TOKEN));
}
