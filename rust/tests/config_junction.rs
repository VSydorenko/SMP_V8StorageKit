// Інваріант спеки §6: перетин бази агента з базою людини й пам'яттю раннера не пропускається через junction
// (принцип 3: kit ніколи не пише в базу людини). Тест на СПРАВЖНЬОМУ junction (`mklink /J` через `cmd`: тести
// rust/tests/ поза обсягом запобіжника git_guard) і з контролем, що лексичне порівняння дає інший результат —
// тест, що проходить і на лексиці, нічого б не доводив.

use kit::config::RawConnection;
use kit::config::agent_base::{
    canonical_path, canonical_paths_overlap, paths_overlap, resolve_agent_base,
};
use kit::config::overlay::{Overlay, OverlayInfobase};
use kit::config::v8project::read_v8project;
use std::path::{Path, PathBuf};
use std::process::Command;

fn junction(link: &Path, target: &Path) {
    let out = Command::new("cmd")
        .arg("/C")
        .arg("mklink")
        .arg("/J")
        .arg(link)
        .arg(target)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "mklink /J не вдалося: {}",
        String::from_utf8_lossy(&out.stdout)
    );
}

fn tmp(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("kit-junction-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn lexical(p: &Path) -> String {
    std::path::absolute(p)
        .unwrap()
        .to_string_lossy()
        .into_owned()
}

#[test]
fn canonical_form_follows_junction_and_lexical_form_does_not() {
    let d = tmp("canon");
    std::fs::create_dir_all(d.join("real").join("deep")).unwrap();
    junction(&d.join("link"), &d.join("real"));

    let via_link = d.join("link").join("deep").join("ib");
    let canon = canonical_path(&via_link.to_string_lossy()).unwrap();
    assert!(
        canon.to_lowercase().ends_with("\\real\\deep\\ib"),
        "{canon}"
    );
    // Префікс пристрою на вході — відмова (рішення архітектора 2026-11-23), а не мовчазне зняття.
    let verbatim = format!("\\\\?\\{}", via_link.display());
    assert!(canonical_path(&verbatim).is_err());

    let real = d.join("real");
    assert!(paths_overlap(&via_link.to_string_lossy(), &real.to_string_lossy()).unwrap());
    // Контроль: на лексичних формах (GetFullPath) шляхи не перетинаються — саме так перетин пропустили б.
    assert!(!canonical_paths_overlap(
        &lexical(&via_link),
        &lexical(&real)
    ));
}

// Фікстура (1) плану §6: база агента воркспейсу через junction лягає в теку дев-бази людини.
#[test]
fn agent_base_behind_junction_is_refused_against_human_dev_base() {
    let d = tmp("human");
    let human_dir = d.join("human");
    std::fs::create_dir_all(&human_dir).unwrap();
    let ws = d.join("ws");
    std::fs::create_dir_all(&ws).unwrap();
    std::fs::write(
        ws.join("v8project.yaml"),
        "source-set: [{ name: a, type: EXTENSION, path: src }]\n",
    )
    .unwrap();
    std::fs::write(
        ws.join("v8project.local.yaml"),
        "infobases: { origin: { connection: 'File=build/ib' } }\n",
    )
    .unwrap();
    junction(&ws.join("build"), &human_dir);
    let project = read_v8project(&ws.join("v8project.yaml")).unwrap();
    let overlay = |dir: &Path| Overlay {
        path: d.join("v8storagekit.local.yaml"),
        infobases: vec![OverlayInfobase {
            name: "human".into(),
            connection: RawConnection::new(format!("File={}", dir.display())),
            user: String::new(),
        }],
        storages: vec![],
        workspaces: vec![],
    };

    let e = resolve_agent_base(Some(&overlay(&human_dir)), "ws", &project).unwrap_err();
    assert!(
        e.message()
            .contains("збігається з дев-базою людини 'human'"),
        "{e}"
    );
    // Контроль: лексично база агента (ws\build\ib) і дев-база не перетинаються.
    assert!(!canonical_paths_overlap(
        &lexical(&ws.join("build").join("ib")),
        &lexical(&human_dir)
    ));
    // Інша дев-база, поза junction, — перетину немає.
    let other = d.join("other");
    std::fs::create_dir_all(&other).unwrap();
    assert!(
        resolve_agent_base(Some(&overlay(&other)), "ws", &project)
            .unwrap()
            .is_some()
    );
}
