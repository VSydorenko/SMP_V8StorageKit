// Контракт прихованої підкоманди `kit config-preflight`: коди виходу, форма JSON, маска секретів у справжньому
// бінарнику. Пароль у виводі — лише ознака; контроль: тест упав би, якби бінарник друкував пароль.

use std::path::PathBuf;
use std::process::Command;

fn kit(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_kit"))
        .arg("config-preflight")
        .args(args)
        .output()
        .unwrap()
}

fn repo(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("kit-cfgcli-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join(".git")).unwrap();
    std::fs::create_dir_all(d.join("ws")).unwrap();
    std::fs::write(
        d.join("v8storagekit.yaml"),
        "version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources:\n      cf: { truth: storage, storage: { path: 'C:\\st' } }\n",
    )
    .unwrap();
    std::fs::write(
        d.join("ws").join("v8project.yaml"),
        "providers: { push: designer, pull: designer, download: designer }\nsource-set:\n  - { name: cf, type: CONFIGURATION, path: cf }\n",
    )
    .unwrap();
    d
}

#[test]
fn usage_errors_exit_2_and_stop_is_json_with_code_0() {
    let out = kit(&[]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("config-preflight: ERROR"));
    assert_eq!(
        kit(&["-RepoRoot", "x", "-Mode", "Bogus"]).status.code(),
        Some(2)
    );
    // Корінь не існує: код 0, зупинка в JSON.
    let missing = std::env::temp_dir().join(format!("kit-cfgcli-none-{}", std::process::id()));
    let out = kit(&["-RepoRoot", &missing.to_string_lossy(), "-Mode", "Strict"]);
    assert_eq!(out.status.code(), Some(0));
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(
        v["stop"]["check"].is_null() && v["stop"]["message"].as_str().unwrap().contains("не існує")
    );
}

#[test]
fn json_shape_and_secrets_mask() {
    let d = repo("mask");
    let marker = "МАРКЕР-пароль-9";
    std::fs::write(
        d.join("v8storagekit.local.yaml"),
        format!("storages:\n  cf: {{ password: {marker} }}\n"),
    )
    .unwrap();
    std::fs::write(
        d.join("ws").join("v8project.local.yaml"),
        format!("infobases:\n  origin:\n    connection: 'File=build/ib'\n    password: {marker}\n    dbms: {{ password: {marker} }}\n"),
    )
    .unwrap();
    let out = kit(&[
        "-RepoRoot",
        &d.to_string_lossy(),
        "-Mode",
        "Lenient",
        "-Truth",
        "storage",
        "-Truth",
        "git",
    ]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(!text.contains(marker), "{text}");
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert!(v["stop"].is_null() && v["context"]["ok"] == true, "{text}");
    assert_eq!(v["selected"][0]["storagePasswordSet"], true);
    let base = &v["context"]["workspaces"][0]["agentBase"]["base"];
    assert_eq!(
        (&base["passwordSet"], &base["dbmsSet"]),
        (&true.into(), &true.into())
    );
    assert!(base.get("password").is_none() && base["connection"]["parses"] == true);
    // Значення -Truth поза словником нічого не вибирає.
    let out = kit(&["-RepoRoot", &d.to_string_lossy(), "-Truth", "bogus"]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["selected"].as_array().unwrap().len(), 0);
}

// Інваріант: будь-який вивід шляху сховища йде через маску userinfo. Маркер у паролі адреси не потрапляє ні в
// stdout, ні в stderr; позитивний двійник — `***@host` у виводі є (шлях дійшов до друку).
#[test]
fn storage_path_userinfo_is_masked_in_stdout_and_stderr() {
    let d = repo("userinfo");
    let (m1, m2) = ("МАРКЕР-адреса-1", "МАРКЕР-накладка-2");
    std::fs::write(
        d.join("v8storagekit.yaml"),
        format!("version: 1\nproduct: P\nworkspaces:\n  - path: ws\n    sources:\n      cf: {{ truth: storage, storage: {{ path: 'tcp://user:{m1}@host/x' }} }}\n"),
    )
    .unwrap();
    let args = |extra: &[&'static str]| {
        let mut a = vec!["-RepoRoot".to_string(), d.to_string_lossy().into_owned()];
        a.extend(extra.iter().map(|s| s.to_string()));
        a
    };
    let run = |a: Vec<String>| {
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        kit(&refs)
    };
    let out = run(args(&["-Mode", "Lenient", "-Truth", "storage"]));
    let (stdout, stderr) = (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    );
    assert!(
        !stdout.contains(m1) && !stderr.contains(m1),
        "{stdout}{stderr}"
    );
    assert!(stdout.contains("tcp://***@host/x"), "{stdout}");

    // Шлях із накладки — теж через маску (і в `selected`, і в самій накладці).
    std::fs::write(
        d.join("v8storagekit.local.yaml"),
        format!("storages:\n  cf: {{ path: 'http://u:{m2}@srv/r' }}\n"),
    )
    .unwrap();
    let out = run(args(&["-Mode", "Lenient", "-Truth", "storage"]));
    let (stdout, stderr) = (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    );
    assert!(
        !stdout.contains(m1)
            && !stderr.contains(m1)
            && !stdout.contains(m2)
            && !stderr.contains(m2),
        "{stdout}{stderr}"
    );
    assert!(stdout.matches("http://***@srv/r").count() >= 2, "{stdout}");
}
