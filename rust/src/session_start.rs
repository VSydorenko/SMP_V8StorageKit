// Хук SessionStart плагіна (ADR-0014): прихована підкоманда `kit.exe session-start`,
// її кличе `hooks/hooks.json`. «Стан сховищ» і вказівка на скіл storage-rules на старті сесії в
// репозиторії під kit; блок правил спілкування власника (hooks/communication-rules.md) і рядок
// оновлення проєкту. Нічого не змінює: рішення — людині, дія — скіл v8storagekit:storage-sync.
//
// ХУК СПРАЦЬОВУЄ В КОЖНІЙ СЕСІЇ МАШИНИ, зокрема в проєктах не про 1С. Критерій — маніфест АБО профіль
// процесу з заданою версією v8storagekit (v8storagekit.version; тимчасово kit.version ≥ 1.0.0, ADR-0020;
// профіль спільного agent-kit без версії хука не вмикає): v8storagekit.yaml шукається в теці проєкту сесії (CLAUDE_PROJECT_DIR) і в її предках; профіль —
// <корінь git>/.agents/kit.profile.json (корінь git — перша тека вгору від проєкту з .git, текою чи
// файлом; git не запускається). Ні маніфесту, ні профілю (або змінної немає) — нічого не друкується, код
// 0, і `pwsh` не запускається: PowerShell потрібен лише `session-check`, тобто лише з маніфестом.
// - маніфест у самій теці проєкту — контекст «Стан сховищ» і наприкінці блок правил;
// - маніфест лише в предку — те саме з -RepoRoot <предок> плюс попередження: Уніка бачитиме лише теку
//   сесії, а воркспейси лежать у корені репозиторію;
// - лише профіль з версією — контекст із самого блоку правил і рядка оновлення; session-check не запускається.
//   Профіль, що не читається (не JSON або v8storagekit.version не x.y.z), без маніфесту дає тишу, а з маніфестом —
//   звичайний контекст без рядка оновлення.
//
// Гарантія «код 0 і жодного часткового виводу» — структурна: увесь вивід збирається в пам'яті й
// друкується одним записом наприкінці (main.rs), код виходу підкоманди — 0 завжди. Збій, не врахований
// нижче, дає None — тишу. Код не панікує: у release `panic = "abort"`, тож розпакування без перевірки
// тут заборонене.
//
// session-check — фаза 2 (#53): хук кличе його передачею PowerShell-диспетчеру (main.rs,
// `dispatcher`) зі стелею часу. Вивід дочірнього процесу — у тимчасові файли, не в канали: онук, що
// успадкував дескриптор, не блокує читання. Власні стандартні потоки kit.exe перед запуском стають
// неуспадковуваними: інакше нащадок, що пережив session-check, тримав би читання виводу хука в Claude
// Code до власного кінця. На стелі хук убиває ДЕРЕВО процесів (`taskkill /T /F`):
// session-check сам запускає git і раннер. Убивати дозволено рівно тому, що session-check нічого не
// мутує; -Apply хук не передає ніколи — список токенів закритий.
//
// Матчери (hooks.json): startup|clear|compact — сесія без раніше доданого контексту. resume і fork
// успадковують транскрипт, у якому «Стан сховищ» уже є.
//
// Перенесено з hooks/session-start.ps1 (PowerShell-хук до переносу на Rust); той, у свою чергу, — з agent-kit 0.9.1
// hooks/session-rules.mjs (modified): блок правил і рядок оновлення.

use kit::profile::{is_version, parse_version, strip_json_comments};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

/// Ім'я прихованої підкоманди.
pub const COMMAND: &str = "session-start";

/// Стеля часу session-check за умовчанням, с; змінна V8KIT_SESSION_CHECK_TIMEOUT — 1–600.
const DEFAULT_TIMEOUT_SEC: u64 = 15;

/// Вивід хука (JSON SessionStart з переносом рядка) або None — тиша.
pub fn run(plugin: &Path) -> Option<String> {
    let project = std::env::var_os("CLAUDE_PROJECT_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .and_then(|p| std::path::absolute(p).ok())
        .map(trim_separators);
    let (repo, git_root) = match &project {
        Some(p) => {
            let repo = if plugin.join("tools").join("kit.ps1").is_file() {
                find_up(p, |d| d.join("v8storagekit.yaml").is_file())
            } else {
                None
            };
            (repo, find_up(p, |d| d.join(".git").exists()))
        }
        None => (None, None),
    };

    let profile = git_root.as_deref().map_or(Profile::None, read_profile);

    // Блок правил і рядок оновлення; збій тут не скасовує решти.
    let mut rules_block = String::new();
    if repo.is_some() || profile.marks_repo() {
        let rules = rules_text(plugin).unwrap_or_default();
        let hint = match (&profile, &git_root) {
            (Profile::Ok(version, _), Some(root)) => {
                upgrade_hint(plugin, root, version).unwrap_or_default()
            }
            _ => String::new(),
        };
        rules_block = [rules, hint]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
    }

    match (repo, project) {
        (Some(repo), Some(project)) => {
            let context = match storage_context(plugin, &repo, &project, &rules_block) {
                Ok(c) => c,
                Err(e) => format!(
                    "<v8storagekit>\nХук v8storagekit не зміг зібрати стан: {e}\n</v8storagekit>"
                ),
            };
            Some(hook_json(&context))
        }
        _ if profile.marks_repo() && !rules_block.is_empty() => Some(hook_json(&format!(
            "<v8storagekit>\n{rules_block}\n</v8storagekit>"
        ))),
        _ => None,
    }
}

/// JSON хука; ключі — у тому порядку, що й у PowerShell-хука до переносу на Rust.
fn hook_json(context: &str) -> String {
    let ctx = serde_json::to_string(context).unwrap_or_else(|_| "\"\"".to_string());
    format!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"SessionStart\",\"additionalContext\":{ctx}}}}}\n"
    )
}

/// Шлях без кінцевих роздільників (крім кореня диска): тека проєкту однакова з `/` наприкінці й без.
fn trim_separators(p: PathBuf) -> PathBuf {
    let mut p = p;
    while p.parent().is_some() {
        let s = p.as_os_str().to_string_lossy();
        if !(s.ends_with('\\') || s.ends_with('/')) {
            break;
        }
        match p.to_str() {
            Some(t) => p = PathBuf::from(&t[..t.len() - 1]),
            None => break,
        }
    }
    p
}

/// Тека `start` і її предки — до першої, що задовольняє `hit`.
fn find_up(start: &Path, hit: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    start.ancestors().find(|d| hit(d)).map(Path::to_path_buf)
}

/// Текст файлу: UTF-8 без BOM; невалідні байти — замінником (як Get-Content -Encoding UTF8).
fn read_text(path: &Path) -> std::io::Result<String> {
    let bytes = std::fs::read(path)?;
    let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    Ok(String::from_utf8_lossy(body).into_owned())
}

/// Профіль процесу: None — файла немає; Ok — читається; Bad — не JSON
/// або v8storagekit.version не x.y.z (ADR-0020; чужий kit.version не Bad).
enum Profile {
    None,
    /// Версія проєкту (типово 0.1.0) і ознака, що вона задана в профілі (`ProjectVersion::Set`).
    Ok(String, bool),
    Bad,
}

impl Profile {
    /// Профіль — ознака репозиторію v8storagekit лише коли в ньому задано версію (ADR-0020): профіль
    /// agent-kit без v8storagekit.version (і без kit.version ≥ 1.0.0) хука не вмикає.
    fn marks_repo(&self) -> bool {
        matches!(self, Profile::Ok(_, true))
    }
}

fn read_profile(git_root: &Path) -> Profile {
    let file = git_root.join(".agents").join("kit.profile.json");
    if !file.is_file() {
        return Profile::None;
    }
    let Ok(text) = read_text(&file) else {
        return Profile::Bad;
    };
    // Як ConvertFrom-Json PowerShell-хука («як було»): порожній файл — профіль без полів,
    // коментарі `//` і `/* */` поза рядками дозволені. Решту його поблажливостей (одинарні лапки, ключі
    // без лапок, кома в кінці) kit сам не пише — тут вони дають Bad.
    let text = strip_json_comments(&text);
    if text.trim().is_empty() {
        return Profile::Ok("0.1.0".to_string(), false);
    }
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Profile::Bad;
    };
    // Версія — за єдиним правилом profile::project_version (ADR-0020): v8storagekit.version, тимчасово kit.version ≥ 1.0.0.
    match kit::profile::project_version(&json) {
        kit::profile::ProjectVersion::Unset => Profile::Ok("0.1.0".to_string(), false),
        kit::profile::ProjectVersion::Set(s) => Profile::Ok(s, true),
        kit::profile::ProjectVersion::Bad => Profile::Bad,
    }
}

/// Правила спілкування без провідного HTML-коментаря, обрізані. Файла немає — None.
fn rules_text(plugin: &Path) -> Option<String> {
    let text = read_text(&plugin.join("hooks").join("communication-rules.md")).ok()?;
    let lead = text.trim_start();
    let body = match lead
        .strip_prefix("<!--")
        .and_then(|rest| rest.find("-->").map(|p| &rest[p + 3..]))
    {
        Some(after) => after,
        None => text.as_str(),
    };
    Some(body.trim().to_string())
}

/// Проєкт відстав від плагіна — один рядок із числом кроків чеклістів журналу. Нема що казати — None.
fn upgrade_hint(plugin: &Path, git_root: &Path, project_version: &str) -> Option<String> {
    let meta: serde_json::Value =
        serde_json::from_str(&read_text(&plugin.join(".claude-plugin").join("plugin.json")).ok()?)
            .ok()?;
    let plugin_version = meta
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    if !is_version(&plugin_version) {
        return None;
    }
    // Корінь git проєкту — сам цей плагін: оновлювати нічого. Імена порівнюються без регістру, як -eq.
    let root_json = git_root.join(".claude-plugin").join("plugin.json");
    if root_json.is_file() {
        let root_meta = read_text(&root_json)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok());
        if let Some(root_meta) = root_meta {
            let name = |v: &serde_json::Value| {
                v.get("name")
                    .and_then(|n| n.as_str())
                    .map(str::to_lowercase)
            };
            if name(&root_meta) == name(&meta) {
                return None;
            }
        }
    }
    let changelog = read_text(&plugin.join("CHANGELOG.md")).ok()?;
    let from = parse_version(project_version)?;
    let to = parse_version(&plugin_version)?;
    if from >= to {
        return None;
    }
    let mut steps = 0;
    let mut in_range = false;
    let mut in_checklist = false;
    for line in changelog.lines() {
        if let Some(v) = version_heading(line) {
            let v = parse_version(v)?;
            in_range = v > from && v <= to;
            in_checklist = false;
        } else if is_heading(line) {
            in_checklist = in_range && checklist_heading(line);
        } else if in_checklist && is_checklist_item(line) {
            steps += 1;
        }
    }
    Some(format!(
        "v8storagekit: проєкт на {project_version}, плагін {plugin_version}; кроків оновлення: {steps} — власник запускає онбординг процесу."
    ))
}

/// `^##\s+(\d+\.\d+\.\d+)\b` — версія з заголовка запису журналу.
fn version_heading(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("##")?;
    let ver = rest.trim_start();
    if ver.len() == rest.len() {
        return None;
    }
    let mut end = 0;
    for part in 0..3 {
        let digits = ver[end..].bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        end += digits;
        if part < 2 {
            if ver[end..].starts_with('.') {
                end += 1;
            } else {
                return None;
            }
        }
    }
    match ver[end..].chars().next() {
        Some(c) if c.is_alphanumeric() || c == '_' => None,
        _ => Some(&ver[..end]),
    }
}

/// `^#{1,3}\s` — заголовок першого–третього рівня.
fn is_heading(line: &str) -> bool {
    let hashes = line.bytes().take_while(|b| *b == b'#').count();
    (1..=3).contains(&hashes)
        && line[hashes..]
            .chars()
            .next()
            .is_some_and(char::is_whitespace)
}

/// `^###\s+Чекліст оновлення проєкту`.
fn checklist_heading(line: &str) -> bool {
    line.strip_prefix("###")
        .filter(|rest| rest.starts_with(char::is_whitespace))
        .is_some_and(|rest| rest.trim_start().starts_with("Чекліст оновлення проєкту"))
}

/// `^- \[[ xX]\] `.
fn is_checklist_item(line: &str) -> bool {
    ["- [ ] ", "- [x] ", "- [X] "]
        .iter()
        .any(|p| line.starts_with(p))
}

/// Контекст «Стан сховищ»: session-check зі стелею часу, попередження про предка, вказівка на скіл,
/// правила. Err — хук не зміг зібрати стан (текст іде в контекст).
fn storage_context(
    plugin: &Path,
    repo: &Path,
    project: &Path,
    rules_block: &str,
) -> Result<String, String> {
    let status = session_check_status(plugin, repo)?;
    let warning = if repo != project {
        format!(
            "УВАГА: сесію відкрито в {}, а корінь репозиторію kit — {}. Уніка бачитиме лише цей воркспейс, а не весь репозиторій; відкрийте сесію в корені репозиторію.\n\n",
            project.display(),
            repo.display()
        )
    } else {
        String::new()
    };
    // Порядок: попередження → стан → вказівка на скіл → правила спілкування. Вступ скіла НЕ вклеюється:
    // Claude Code велику частину виводу хука показує агентові лише прев'ю, тож стан стоїть першим.
    let pointer = "Репозиторій під kit. Правила контуру — скіл `v8storagekit:storage-rules`: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем.";
    let tail = if rules_block.is_empty() {
        String::new()
    } else {
        format!("\n\n{rules_block}")
    };
    Ok(format!(
        "<v8storagekit>\n{warning}## Стан сховищ (kit session-check)\n\n{status}\n\n{pointer}{tail}\n</v8storagekit>"
    ))
}

/// Стеля з V8KIT_SESSION_CHECK_TIMEOUT (ціле 1–600), інакше 15 с. Стеля — через змінну, а не накладку:
/// хук за конструкцією не читає YAML.
fn timeout_sec() -> u64 {
    std::env::var("V8KIT_SESSION_CHECK_TIMEOUT")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|v| (1..=600).contains(v))
        .map_or(DEFAULT_TIMEOUT_SEC, |v| v as u64)
}

/// Тимчасовий файл виводу; прибирається на виході з області.
struct TempFile {
    path: PathBuf,
    file: Option<File>,
}

impl TempFile {
    fn new(tag: &str) -> Result<Self, String> {
        let dir = std::env::temp_dir();
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        for n in 0..100u32 {
            let path = dir.join(format!(
                "kit-session-check-{}-{stamp}-{n}.{tag}",
                std::process::id()
            ));
            match File::options().write(true).create_new(true).open(&path) {
                Ok(file) => {
                    return Ok(TempFile {
                        path,
                        file: Some(file),
                    });
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    return Err(format!(
                        "тимчасовий файл {} не створено: {e}",
                        path.display()
                    ));
                }
            }
        }
        Err(format!("тимчасовий файл у {} не створено", dir.display()))
    }

    fn stdio(&self) -> Result<Stdio, String> {
        match &self.file {
            Some(f) => f
                .try_clone()
                .map(Stdio::from)
                .map_err(|e| format!("тимчасовий файл {}: {e}", self.path.display())),
            None => Err(format!("тимчасовий файл {} закрито", self.path.display())),
        }
    }

    /// Вміст як текст UTF-8 (BOM знято); файл не читається — порожньо.
    fn text(&self) -> String {
        read_text(&self.path).unwrap_or_default()
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        self.file.take();
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Текст розділу «Стан сховищ». Коди session-check: 0 — як є (порожньо — штатна тиша); 1 і 4 — як є, коли
/// вивід непорожній, а без виводу — «НЕВІДОМИЙ»; будь-який інший — «неочікуваний код»: порожній текст
/// читався б як «нових версій немає».
fn session_check_status(plugin: &Path, repo: &Path) -> Result<String, String> {
    let timeout = timeout_sec();
    let repo_arg = repo
        .to_str()
        .ok_or_else(|| format!("шлях {} — не коректний Unicode", repo.display()))?;
    let tokens = [
        "session-check".to_string(),
        "-RepoRoot".to_string(),
        repo_arg.to_string(),
    ];
    let out = TempFile::new("out")?;
    let err = TempFile::new("err")?;
    let mut cmd = crate::dispatcher(plugin, &tokens)?;
    cmd.stdin(Stdio::null())
        .stdout(out.stdio()?)
        .stderr(err.stdio()?);
    std_handles_not_inheritable();
    let mut child = cmd.spawn().map_err(|e| {
        format!(
            "{} не запустився: {e}",
            Path::new(cmd.get_program()).display()
        )
    })?;
    // Дескриптори-копії в `cmd` закриваються: файли тримає лише дочірній процес.
    drop(cmd);

    let deadline = Instant::now() + Duration::from_secs(timeout);
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status.code().unwrap_or(-1)),
            Ok(None) if Instant::now() >= deadline => break None,
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                kit::proc::kill_tree(&mut child);
                return Err(format!("очікування session-check: {e}"));
            }
        }
    };

    let Some(code) = code else {
        kit::proc::kill_tree(&mut child);
        let mut status = format!(
            "УВАГА: kit session-check не вклався в {timeout} с — стан сховищ НЕВІДОМИЙ, не «без змін». Найчастіша причина — повільний доступ до сховища (SMB); перевірити вручну: kit session-check -RepoRoot ."
        );
        // Те, що kit устиг надрукувати, не пропадає; позначка «частково» обов'язкова.
        let partial = out.text().trim().to_string();
        if !partial.is_empty() {
            status.push_str(&format!("\n\nЧастково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):\n{partial}"));
        }
        return Ok(status);
    };

    let raw = format!("{}{}", out.text(), err.text()).trim().to_string();
    Ok(match code {
        0 => raw,
        1 | 4 if !raw.is_empty() => raw,
        1 | 4 => format!(
            "УВАГА: kit session-check завершився кодом {code} без жодного виводу — стан сховищ НЕВІДОМИЙ, не «без змін». Перевірити вручну: kit session-check -RepoRoot ."
        ),
        _ => format!(
            "УВАГА: kit session-check завершився неочікуваним кодом {code} (очікувалось 0, 1 або 4) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:\n{raw}"
        ),
    })
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn SetHandleInformation(handle: *mut std::ffi::c_void, mask: u32, flags: u32) -> i32;
}

const HANDLE_FLAG_INHERIT: u32 = 0x1;

/// Власні stdin, stdout і stderr kit.exe — неуспадковувані. Rust std на Windows запускає дочірній процес з
/// `bInheritHandles=TRUE` без переліку дескрипторів, тож pwsh і його нащадки дістали б і канал stdout хука,
/// який kit.exe отримав від батька успадковуваним. Нащадок, що пережив session-check (або осиротів, і
/// `taskkill /T` його не бачить), тримав би тоді читання виводу хука в Claude Code до власного кінця.
/// Дескрипторам дочірнього це не шкодить: `Stdio::from(File)` і `Stdio::null()` std дублює як
/// успадковувані окремо. Збій — без наслідків для виводу: це запобіжник, не умова роботи.
fn std_handles_not_inheritable() {
    use std::os::windows::io::AsRawHandle;
    let handles = [
        std::io::stdin().as_raw_handle(),
        std::io::stdout().as_raw_handle(),
        std::io::stderr().as_raw_handle(),
    ];
    for h in handles {
        if !h.is_null() {
            // SAFETY: дескриптор власного стандартного потоку процесу; змінюється лише прапорець успадкування.
            unsafe {
                SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
            }
        }
    }
}
