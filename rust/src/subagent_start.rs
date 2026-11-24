// Хук SubagentStart плагіна — прихована підкоманда `kit.exe subagent-start` (`hooks/hooks.json`,
// matcher `^v8storagekit:`). Агенти процесу — одна загальна множина; специфіку 1С їм у репозиторіях 1С
// підмішує цей хук: вміст `<корінь плагіна>/hooks/domain-1c/<ім'я агента>.md` іде в additionalContext
// субагента. Контракт узгоджено з напрямом «специфіка 1С» 2026-11-22.
//
// Вхід — JSON у stdin (поля `agent_type`, `cwd`). Вивід — один JSON SubagentStart або нічого.
// Хук інформаційний (SubagentStart блокувати не може): будь-який збій — тиша й код 0. pwsh не запускає,
// процесів не запускає взагалі.
//
// Репозиторій 1С: `v8storagekit.yaml` у `cwd` чи його предку, АБО `v8project.yaml` у корені git чи в
// прямій підтеці кореня (вимір 2026-11-22: у репозиторіях SMP_* воркспейс Уніки — рівно на рівень нижче
// кореня). Профіль процесу ознакою 1С не є: його має й сам kit.
//
// Ім'я агента — вхід ззовні: після префікса `v8storagekit:` дозволено лише `[a-z0-9-]+`, інакше тиша —
// шлях до файлу з довільного тексту не будується.

use std::io::Read;
use std::path::{Path, PathBuf};

/// Ім'я прихованої підкоманди.
pub const COMMAND: &str = "subagent-start";

/// Префікс агентів плагіна в `agent_type`.
const AGENT_PREFIX: &str = "v8storagekit:";

/// Стеля читання stdin: вхід хука — кілька сотень байтів.
const STDIN_LIMIT: u64 = 1 << 20;

/// Тека текстів 1С відносно кореня плагіна.
const DOMAIN_DIR: [&str; 2] = ["hooks", "domain-1c"];

/// Вивід хука (JSON SubagentStart з переносом рядка) для stdin процесу або None — тиша.
pub fn run_stdin(plugin: &Path) -> Option<String> {
    let mut input = String::new();
    std::io::stdin()
        .take(STDIN_LIMIT)
        .read_to_string(&mut input)
        .ok()?;
    run(plugin, &input)
}

/// Вивід хука для вхідного JSON або None — тиша.
pub fn run(plugin: &Path, input: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(input).ok()?;
    let name = agent_name(v.get("agent_type")?.as_str()?)?;
    let cwd = PathBuf::from(v.get("cwd")?.as_str()?);
    if !cwd.is_absolute() || !cwd.is_dir() || !is_1c_repo(&cwd) {
        return None;
    }
    let mut file = plugin.to_path_buf();
    for part in DOMAIN_DIR {
        file.push(part);
    }
    file.push(format!("{name}.md"));
    let bytes = std::fs::read(&file).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text).trim();
    if text.is_empty() {
        return None;
    }
    let ctx = serde_json::to_string(text).ok()?;
    Some(format!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"SubagentStart\",\"additionalContext\":{ctx}}}}}\n"
    ))
}

/// Ім'я агента плагіна без префікса — лише `[a-z0-9-]+`; інакше None.
fn agent_name(agent_type: &str) -> Option<&str> {
    let name = agent_type.strip_prefix(AGENT_PREFIX)?;
    let ok = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    ok.then_some(name)
}

/// Чи `cwd` — у репозиторії 1С (див. шапку файлу).
fn is_1c_repo(cwd: &Path) -> bool {
    if cwd
        .ancestors()
        .any(|d| d.join("v8storagekit.yaml").is_file())
    {
        return true;
    }
    let Some(root) = cwd.ancestors().find(|d| d.join(".git").exists()) else {
        return false;
    };
    if root.join("v8project.yaml").is_file() {
        return true;
    }
    let Ok(entries) = std::fs::read_dir(root) else {
        return false;
    };
    entries.flatten().any(|e| {
        e.file_type().is_ok_and(|t| t.is_dir()) && e.path().join("v8project.yaml").is_file()
    })
}

#[cfg(test)]
mod tests {
    use super::agent_name;

    #[test]
    fn agent_name_accepts_only_plugin_agents_with_safe_names() {
        assert_eq!(agent_name("v8storagekit:implementer"), Some("implementer"));
        assert_eq!(
            agent_name("v8storagekit:code-review-verifier"),
            Some("code-review-verifier")
        );
        for bad in [
            "implementer",
            "Explore",
            "other:implementer",
            "v8storagekit:",
            "v8storagekit:../x",
            "v8storagekit:a/b",
            "v8storagekit:a\\b",
            "v8storagekit:Implementer",
            "v8storagekit:a.md",
            "v8storagekit:a b",
        ] {
            assert_eq!(agent_name(bad), None, "{bad}");
        }
    }
}
