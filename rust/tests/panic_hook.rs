// Хук паніки (ADR-0021 п. 5): невиловлена паніка не цитує даних у stderr — хук вклеює stderr у контекст сесії.
//
// Тест запускає сам себе дочірнім процесом (змінна KIT_PANIC_CHILD): дитина ставить хук kit і панікує з
// маркером у payload, батько перевіряє stderr. Без `install_panic_hook` маркер із'являється — тест червоніє.

use std::process::Command;

const MARKER: &str = "СЕКРЕТ-маркер-паніки";
const CHILD_ENV: &str = "KIT_PANIC_CHILD";

#[test]
fn panic_child() {
    if std::env::var_os(CHILD_ENV).is_none() {
        return;
    }
    kit::install_panic_hook();
    panic!("{MARKER}");
}

#[test]
fn panic_does_not_echo_payload() {
    let exe = std::env::current_exe().unwrap();
    let out = Command::new(exe)
        .args(["--exact", "panic_child", "--nocapture", "--test-threads=1"])
        .env(CHILD_ENV, "1")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        !out.status.success(),
        "дитина мала впасти: {stdout}{stderr}"
    );
    assert!(
        !stderr.contains(MARKER) && !stdout.contains(MARKER),
        "payload паніки витік:\n{stdout}{stderr}"
    );
    assert!(
        stderr.contains(kit::PANIC_TEXT),
        "немає сталого тексту:\n{stderr}"
    );
}
