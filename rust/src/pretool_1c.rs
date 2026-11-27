// Хук PreToolUse плагіна — прихована підкоманда `kit.exe pretool-1c` (`hooks/hooks.json`, matcher
// `Grep|Glob|Read|Bash`). У репозиторії 1С, коли інструмент збирається читати чи шукати у вихідниках 1С
// (`.bsl`, теки `Ext/`) замість Уніки, додає в контекст підказку з еквівалентами Уніки.
//
// Лише підказка: у виводі нема `permissionDecision`, тож хук нічого не забороняє й не питає. Будь-який
// збій, не-1С репозиторій, нерозпізнаний вхід — тиша й код 0. Процесів не запускає, pwsh не кличе.
// Ознака репозиторію 1С — та сама, що в SubagentStart (`subagent_start::is_1c_repo`).
//
// Ознаки цілі навмисно прості: розширення `.bsl` і сегмент `Ext/` (XML модулів і форм). Теки
// source-set-ів із `v8project.yaml` не беруться — хибне спрацювання тут лише зайвий рядок контексту.
//
// Текст підказки — константа в коді, а не файл у `hooks/`: хуку не потрібен корінь плагіна, і текст
// не може зникнути чи не прочитатись разом із файлом; контракт тексту — точні імена інструментів Уніки.

use crate::subagent_start::is_1c_repo;
use std::io::Read;
use std::path::PathBuf;

/// Ім'я прихованої підкоманди.
pub const COMMAND: &str = "pretool-1c";

/// Стеля читання stdin.
const STDIN_LIMIT: u64 = 1 << 20;

/// Інструменти командного рядка, якими читають чи шукають текст.
const READ_TOOLS: [&str; 6] = ["grep", "rg", "findstr", "select-string", "cat", "sed"];

const HINT: &str = "Це код 1С: читай і шукай його через Уніку, а не текстовими інструментами. \
Пошук — `unica_search` з `query` і `scope`; тіло методу — `unica_view` з `at` \
\"<набір>:CommonModule.<Ім'я>.Method.<Метод>\"; шлях ↔ адреса — `unica_resolve`. \
Текстове читання доречне лише для байтових перевірок (CRLF, BOM, `git diff`) або коли Уніка \
відповіла помилкою чи `uninitialized`; тоді назви причину у звіті.";

/// Вивід хука для stdin процесу або None — тиша.
pub fn run_stdin() -> Option<String> {
    let mut input = String::new();
    std::io::stdin()
        .take(STDIN_LIMIT)
        .read_to_string(&mut input)
        .ok()?;
    run(&input)
}

/// Вивід хука для вхідного JSON або None — тиша.
pub fn run(input: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(input).ok()?;
    let tool = v.get("tool_name")?.as_str()?;
    let args = v.get("tool_input")?;
    let field = |k: &str| args.get(k).and_then(|x| x.as_str()).unwrap_or("");
    let hit = match tool {
        "Read" => targets_1c_file(field("file_path")),
        "Grep" => targets_1c_file(field("path")) || targets_1c_file(field("glob")),
        "Glob" => targets_1c_file(field("pattern")) || targets_1c_file(field("path")),
        "Bash" => bash_reads_1c(field("command")),
        _ => false,
    };
    if !hit {
        return None;
    }
    let cwd = PathBuf::from(v.get("cwd")?.as_str()?);
    if !cwd.is_absolute() || !cwd.is_dir() || !is_1c_repo(&cwd) {
        return None;
    }
    let ctx = serde_json::to_string(HINT).ok()?;
    Some(format!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"additionalContext\":{ctx}}}}}\n"
    ))
}

/// Рядок (шлях чи глоб) указує на `.bsl` або на `Ext/` у шляху.
fn targets_1c_file(s: &str) -> bool {
    let n = s.replace('\\', "/").to_lowercase();
    n.contains(".bsl") || n.contains("/ext/") || n.starts_with("ext/")
}

/// Команда читає чи шукає у вихідниках 1С. Байтові перевірки через `git` (`diff`, `show`,
/// `ls-files --eol`) — легальні; `git grep` — ні, це той самий текстовий пошук.
fn bash_reads_1c(cmd: &str) -> bool {
    let c = cmd.trim().to_lowercase();
    if c.starts_with("git ") && !c.starts_with("git grep") {
        return false;
    }
    if !targets_1c_file(&c) {
        return false;
    }
    c.split(|ch: char| !(ch.is_alphanumeric() || ch == '-' || ch == '_'))
        .any(|w| READ_TOOLS.contains(&w))
}

#[cfg(test)]
mod tests {
    use super::run;
    use std::path::Path;

    fn input(tool: &str, args: serde_json::Value, cwd: &Path) -> String {
        serde_json::json!({
            "tool_name": tool,
            "tool_input": args,
            "cwd": cwd.to_string_lossy(),
        })
        .to_string()
    }

    fn repo(tag: &str, manifest: bool) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("kit-pretool-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::create_dir(d.join(".git")).unwrap();
        if manifest {
            std::fs::write(d.join("v8storagekit.yaml"), "version: 1\n").unwrap();
        }
        d
    }

    #[test]
    fn hints_on_1c_sources_in_1c_repo_without_permission_decision() {
        let d = repo("hint", true);
        let cases = [
            (
                "Read",
                serde_json::json!({"file_path": "C:\\r\\cf\\src\\CommonModules\\A\\Ext\\Module.bsl"}),
            ),
            (
                "Read",
                serde_json::json!({"file_path": "/r/cf/src/Catalogs/A/Forms/F/Ext/Form.xml"}),
            ),
            (
                "Grep",
                serde_json::json!({"pattern": "Процедура", "glob": "*.bsl"}),
            ),
            ("Glob", serde_json::json!({"pattern": "**/*.bsl"})),
            (
                "Bash",
                serde_json::json!({"command": "grep -rn Foo cf/src --include=*.bsl"}),
            ),
            (
                "Bash",
                serde_json::json!({"command": "git grep Foo -- '*.bsl'"}),
            ),
        ];
        for (tool, args) in cases {
            let out = run(&input(tool, args.clone(), d.as_path()))
                .unwrap_or_else(|| panic!("{tool} {args}"));
            let j: serde_json::Value = serde_json::from_str(&out).unwrap();
            let o = &j["hookSpecificOutput"];
            assert_eq!(o["hookEventName"], "PreToolUse");
            assert!(
                o["additionalContext"]
                    .as_str()
                    .unwrap()
                    .contains("unica_search")
            );
            assert!(!out.contains("permissionDecision"), "{out}");
        }
    }

    #[test]
    fn silent_outside_1c_repo_for_git_byte_checks_and_on_bad_input() {
        let d = repo("silent", true);
        let plain = repo("plain", false);
        let read = serde_json::json!({"file_path": "a/b.bsl"});
        // Контроль: той самий вхід у не-1С репозиторії мовчить, у 1С — ні.
        assert!(run(&input("Read", read.clone(), plain.as_path())).is_none());
        assert!(run(&input("Read", read, d.as_path())).is_some());
        for cmd in [
            "git diff -- a/Ext/Module.bsl",
            "git show HEAD:a/Module.bsl",
            "git ls-files --eol a/Module.bsl",
            "ls a/Module.bsl",
        ] {
            assert!(
                run(&input(
                    "Bash",
                    serde_json::json!({"command": cmd}),
                    d.as_path()
                ))
                .is_none(),
                "{cmd}"
            );
        }
        assert!(
            run(&input(
                "Read",
                serde_json::json!({"file_path": "README.md"}),
                d.as_path()
            ))
            .is_none()
        );
        for bad in ["", "not json", "{}", "{\"tool_name\":\"Read\"}"] {
            assert!(run(bad).is_none(), "{bad}");
        }
    }
}
