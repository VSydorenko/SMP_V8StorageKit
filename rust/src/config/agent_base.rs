// База агента воркспейсу й перетини баз — як `AgentBase.psm1` і `Resolve-KitAgentInfobasePath`,
// `Get-KitRunnerMemoryPath` (tools/lib): ті самі правила й тексти.
//
// Принцип 3: kit ніколи не пише в базу людини. Перетини баз, пам'яті раннера й шаблонів `.dt` рахуються лише
// через КАНОНІЧНУ форму шляху (`canonical_path`, як `Get-KitCanonicalPath`): зняти `\\?\`, `\\?\UNC\`, `\??\`,
// розкрити junction/symlink по компонентах (`fs::read_link`, ліміт стрибків 40), нечитаний атрибут чи ціль —
// відмова (fail-closed). `fs::canonicalize` не вживається: вона вимагає наявного шляху й повертає `\\?\`-форму.
// Лексичний `[IO.Path]::GetFullPath` (`v8project::full_path`) для порівняння баз НЕ годиться: build за junction
// веде в теку, де лежить база людини, а лексично шляхи різні (інваріант §6).
//
// Одне правило на вхід, без часткового зведення (рішення архітектора 2026-11-23; відома відмінність від
// PowerShell, ADR-0014 п. 7): `File=` з префіксом пристрою (`\\.\`, `\\?\`, `\??\`, зокрема `GLOBALROOT` і
// `Volume{`) чи на адмінський ресурс UNC (`\\<хост>\<X>$\…`) — відмова до будь-якої дії, текст шлях не цитує.
// Те саме для цілі посилання, що після зняття `\\?\`/`\\?\UNC\`/`\??\` не є абсолютним шляхом диска чи UNC.
// Відносна ціль без префікса розв'язується від теки самого посилання, не від поточної теки процесу.
//
// Межа, яку прийнято: звичайний ресурс `\\<локальний хост>\<ресурс>`, що веде в локальну теку, лексично не
// відрізнити від віддаленого; надійно розрізняє лише ідентичність тому й файлу — це рівень спеки, не B1.
//
// Єдиний предикат перетину — `canonical_paths_overlap`: його кличуть і гілка файлових баз
// (`infobases_overlap`), і `paths_overlap` (захищені шляхи, пам'ять раннера).
//
// Вхід — не `Context`/`Workspace` префлайту (їх створює задача 3), а їхні складові: накладка, шлях і
// `V8Project` воркспейсу; задача 3 обгортає їх у `agent_base(&Context, &Workspace)`.

use super::connection::{Connection, CredentialsKind, credentials_recipe, parse_str};
use super::overlay::Overlay;
use super::v8project::{AgentInfobase, V8Project, full_path, join_ps, resolve_agent_infobase};
use super::yaml::eq_ci;
use super::{ConfigError, RawConnection, Secret, SecretTree};
use crate::case_guard::fold_char;
use std::os::windows::fs::MetadataExt;
use std::path::Path;

const REPARSE_POINT: u32 = 0x400;
const MAX_HOPS: usize = 40;
const SEPARATORS: [char; 2] = ['\\', '/'];

const ERR_ATTRIBUTES: &str =
    "не вдалося перевірити компонент шляху бази на посилання — kit не може довести, що бази різні.";
const ERR_LINK_TARGET: &str =
    "не вдалося прочитати ціль посилання в шляху бази — kit не може довести, що бази різні.";
const ERR_LINK_CHAIN: &str =
    "ланцюг посилань у шляху бази задовгий (або зациклений) — kit не може довести, що бази різні.";

// ---------------------------------------------------------------------------------------------------------
// Канонічна форма шляху

/// Зняти `\\?\UNC\` (→ `\\`), `\\?\` і `\??\`.
fn strip_verbatim(p: &str) -> String {
    let head: String = p.chars().take(8).collect::<String>().to_uppercase();
    if head == "\\\\?\\UNC\\" {
        format!("\\\\{}", p.chars().skip(8).collect::<String>())
    } else if p.starts_with("\\\\?\\") || p.starts_with("\\??\\") {
        p.chars().skip(4).collect()
    } else {
        p.to_string()
    }
}

/// `[IO.Path]::IsPathRooted`: починається з роздільника чи `X:`.
fn is_path_rooted(p: &str) -> bool {
    let mut chars = p.chars();
    match (chars.next(), chars.next()) {
        (Some(a), _) if SEPARATORS.contains(&a) => true,
        (Some(a), Some(':')) => a.is_ascii_alphabetic(),
        _ => false,
    }
}

/// `[IO.Path]::GetPathRoot` для вже нормалізованого (`\`) шляху: `X:\` чи `\\сервер\ресурс`.
fn path_root(full: &str) -> String {
    let chars: Vec<char> = full.chars().collect();
    if chars.first() == Some(&'\\') && chars.get(1) == Some(&'\\') {
        let rest: String = chars.iter().skip(2).collect();
        let mut parts = rest.split('\\');
        let server = parts.next().unwrap_or("");
        return match parts.next() {
            Some(share) if !share.is_empty() => format!("\\\\{server}\\{share}"),
            _ => format!("\\\\{server}"),
        };
    }
    if chars.get(1) == Some(&':') && chars.get(2).is_some_and(|c| SEPARATORS.contains(c)) {
        return chars.iter().take(3).collect();
    }
    if chars.first().is_some_and(|c| SEPARATORS.contains(c)) {
        return "\\".to_string();
    }
    String::new()
}

const ERR_DEVICE_PATH: &str = "kit не може довести, що база агента не збігається з базою людини; вкажіть звичайний шлях X:\\… чи \\\\сервер\\ресурс\\….";

/// Вхідний шлях має бути звичайним: диск (`X:\…`), відносний чи UNC `\\сервер\ресурс\…`. Префікси пристроїв
/// (`\\.\`, `\\?\`, `\??\`) і адмінський ресурс (`\\<хост>\<X>$\…`) — відмова без цитування шляху.
pub fn assert_plain_path(path: &str) -> Result<(), ConfigError> {
    let p = path.trim().replace('/', "\\");
    if ["\\\\.\\", "\\\\?\\", "\\??\\"]
        .iter()
        .any(|prefix| p.starts_with(prefix))
    {
        return Err(ConfigError::new(ERR_DEVICE_PATH));
    }
    if let Some(rest) = p.strip_prefix("\\\\") {
        // Порожні частини пропускаються: `\\localhost\\C$` після нормалізації — той самий адмінський ресурс.
        let mut parts = rest.split('\\').filter(|s| !s.is_empty());
        let _host = parts.next();
        let admin = parts.next().is_some_and(|share| {
            let mut c = share.chars();
            matches!((c.next(), c.next(), c.next()), (Some(l), Some('$'), None) if l.is_ascii_alphabetic())
        });
        if admin {
            return Err(ConfigError::new(ERR_DEVICE_PATH));
        }
    }
    Ok(())
}

/// Ціль посилання → абсолютний шлях. `None` — порожня ціль (посилання без цілі, як `LinkTarget = $null`).
/// Ціль з префіксом `\\?\`/`\??\`, що після зняття не є диском чи UNC (`Volume{…}`, `GLOBALROOT`), — відмова;
/// відносна ціль без префікса — від теки `current` (теки посилання), не від поточної теки процесу.
fn resolve_link_target(raw: &str, current: &str) -> Result<Option<String>, ConfigError> {
    if raw.is_empty() {
        return Ok(None);
    }
    let prefixed = raw.starts_with("\\\\?\\") || raw.starts_with("\\??\\");
    let target = strip_verbatim(raw);
    if target.is_empty() {
        return Ok(None);
    }
    let drive = {
        let mut c = target.chars();
        matches!((c.next(), c.next(), c.next()), (Some(l), Some(':'), Some(s)) if l.is_ascii_alphabetic() && SEPARATORS.contains(&s))
    };
    let joined = if drive || target.starts_with("\\\\") {
        target
    } else if prefixed || is_path_rooted(&target) {
        // Префікс без диска (`Volume{…}`, `GLOBALROOT`), корінь без диска (`\x`) чи диск без кореня (`C:x`):
        // склеїти з диском чи текою процесу не можна — відмова.
        return Err(ConfigError::new(ERR_DEVICE_PATH));
    } else {
        format!("{current}\\{target}")
    };
    assert_plain_path(&joined)?;
    let normalized = full_path(&joined)?;
    // І по нормалізованому шляху: `GetFullPathNameW` зводить підряд роздільники.
    assert_plain_path(&normalized)?;
    Ok(Some(normalized))
}

/// Компонент відсутній лише за кодами Windows 2 і 3 (як .NET FileNotFound/DirectoryNotFound). Усе інше —
/// мережеві помилки (67 BAD_NET_NAME), шлях через файл (267), доступ — fail-closed: `ErrorKind::NotFound` для цього
/// надто широкий.
fn is_absent(e: &std::io::Error) -> bool {
    matches!(e.raw_os_error(), Some(2) | Some(3))
}

/// Канонічний абсолютний шлях для порівняння баз і тек: без префікса `\\?\`, з розкритими посиланнями по наявних
/// компонентах. Ненаявний компонент зупиняє розкриття (глибше нічого немає). Помилка читання атрибута чи цілі
/// наявного компонента — відмова (fail-closed); текст помилки не містить шляху.
pub fn canonical_path(path: &str) -> Result<String, ConfigError> {
    assert_plain_path(path)?;
    let mut full = full_path(path.trim())?;
    assert_plain_path(&full)?;
    for _ in 0..MAX_HOPS {
        let root = path_root(&full);
        let rest = full.strip_prefix(root.as_str()).unwrap_or("");
        let segments: Vec<&str> = rest.split(SEPARATORS).filter(|s| !s.is_empty()).collect();
        let mut current = root.trim_end_matches(SEPARATORS).to_string();
        let mut restart: Option<String> = None;
        for (i, segment) in segments.iter().enumerate() {
            let next = format!("{current}\\{segment}");
            let meta = match std::fs::symlink_metadata(&next) {
                Ok(m) => m,
                Err(e) if is_absent(&e) => {
                    // Глибше нічого немає: решту дописуємо як є.
                    let tail: Vec<&str> =
                        segments.iter().skip(i.saturating_add(1)).copied().collect();
                    return Ok(std::iter::once(next.as_str())
                        .chain(tail)
                        .collect::<Vec<_>>()
                        .join("\\"));
                }
                Err(_) => return Err(ConfigError::new(ERR_ATTRIBUTES)),
            };
            // Посиланням kit вважає лише symlink і junction (їхню ціль дає `read_link`); інша точка повторного
            // розбору (OneDrive, том) цілі не має — звичайний компонент, як `LinkTarget = $null` у PowerShell.
            if meta.file_attributes() & REPARSE_POINT != 0 && meta.file_type().is_symlink() {
                let target =
                    std::fs::read_link(&next).map_err(|_| ConfigError::new(ERR_LINK_TARGET))?;
                let target = resolve_link_target(&target.to_string_lossy(), &current)?;
                if let Some(target) = target {
                    let tail: Vec<&str> =
                        segments.iter().skip(i.saturating_add(1)).copied().collect();
                    let tail = if tail.is_empty() {
                        String::new()
                    } else {
                        format!("\\{}", tail.join("\\"))
                    };
                    let next_full =
                        full_path(&format!("{}{tail}", target.trim_end_matches(SEPARATORS)))?;
                    assert_plain_path(&next_full)?;
                    restart = Some(next_full);
                    break;
                }
            }
            current = next;
        }
        match restart {
            None => return Ok(current),
            Some(r) => full = r,
        }
    }
    Err(ConfigError::new(ERR_LINK_CHAIN))
}

fn starts_with_ci(a: &str, b: &str) -> bool {
    let mut ai = a.chars().map(fold_char);
    b.chars().map(fold_char).all(|bc| ai.next() == Some(bc))
}

/// Єдиний предикат перетину для вже канонізованих шляхів: рівні, один під іншим чи над ним. Порівняння з
/// роздільником (`build\ib2` не лежить під `build\ib`), без регістру.
pub fn canonical_paths_overlap(left: &str, right: &str) -> bool {
    let a = format!("{}\\", left.trim_end_matches(SEPARATORS));
    let b = format!("{}\\", right.trim_end_matches(SEPARATORS));
    starts_with_ci(&a, &b) || starts_with_ci(&b, &a)
}

/// Чи перетинаються два шляхи після канонізації.
pub fn paths_overlap(left: &str, right: &str) -> Result<bool, ConfigError> {
    Ok(canonical_paths_overlap(
        &canonical_path(left)?,
        &canonical_path(right)?,
    ))
}

/// Шлях і всі його предки у ВЛАСНОМУ написанні (так псевдонім шляху видно файловій системі, але не канонізації
/// тексту), від глибокого до кореня; ланцюг обривається, а не кидає. Батько — як `Split-Path -Parent`.
pub fn path_ancestry(path: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = path.trim_end_matches(SEPARATORS).to_string();
    for _ in 0..64 {
        if cur.is_empty() {
            break;
        }
        out.push(cur.clone());
        match parent_of(&cur) {
            Some(parent) if parent != cur => cur = parent,
            _ => break,
        }
    }
    out
}

/// `Split-Path -Parent`: без останнього сегмента, роздільники нормалізуються до `\`; у кореня батька немає.
fn parent_of(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches(SEPARATORS);
    if trimmed.is_empty() {
        return None;
    }
    let chars: Vec<char> = trimmed.chars().collect();
    let pos = chars.iter().rposition(|c| SEPARATORS.contains(c))?;
    let head: String = chars.get(..pos)?.iter().collect();
    let parent = head.trim_end_matches(SEPARATORS).replace('/', "\\");
    if parent.is_empty() {
        return Some("\\".to_string());
    }
    // `C:` + роздільник — корінь диска: роздільник лишається.
    if parent.ends_with(':') {
        return Some(format!("{parent}\\"));
    }
    Some(parent)
}

// ---------------------------------------------------------------------------------------------------------
// Підключення бази агента

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InfobaseKind {
    File,
    Server,
}

/// Підключення бази агента → вид, абсолютний шлях (для файлової), ключ платформи.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentInfobasePath {
    pub kind: InfobaseKind,
    pub path: Option<String>,
    pub ib_switch: String,
}

/// Розбір через `connection::parse_str`; відносний `File=` розв'язується від теки конфіга (як Уніка).
pub fn resolve_agent_infobase_path(
    project: &V8Project,
    connection: &RawConnection,
) -> Result<AgentInfobasePath, ConfigError> {
    let parsed = match parse_str(connection.expose()) {
        Ok(p) => p,
        Err(e) => {
            let leaf = project
                .directory
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let recipe = credentials_recipe(&e, CredentialsKind::Agent);
            let tail = if recipe.is_empty() {
                String::new()
            } else {
                format!(" {recipe}")
            };
            return Err(ConfigError::new(format!(
                "infobases.origin.connection воркспейсу '{leaf}' (v8project.local.yaml або v8project.yaml): {}{tail}",
                e.message()
            )));
        }
    };
    match parsed {
        Connection::Server { server, reference } => Ok(AgentInfobasePath {
            kind: InfobaseKind::Server,
            path: None,
            ib_switch: format!("/S \"{server}\\{reference}\""),
        }),
        Connection::File { file } => {
            let joined = if is_path_rooted(&file) {
                file
            } else {
                join_ps(&project.directory.to_string_lossy(), &file)
            };
            let path = full_path(&joined)?;
            Ok(AgentInfobasePath {
                kind: InfobaseKind::File,
                ib_switch: format!("/F \"{path}\""),
                path: Some(path),
            })
        }
    }
}

/// `<тека v8project.yaml>/.local/infobases/<база>` — єдине місце, де kit знає, де раннер веде пам'ять бази.
pub fn runner_memory_path(project: &V8Project, infobase: &str) -> String {
    let dir = project.directory.to_string_lossy();
    join_ps(&join_ps(&join_ps(&dir, ".local"), "infobases"), infobase)
}

// ---------------------------------------------------------------------------------------------------------
// Перетин двох підключень

pub enum Canonical {
    Parsed {
        kind: InfobaseKind,
        identity: String,
        path: Option<String>,
    },
    Unparsed {
        reason: String,
        credentials: Option<super::connection::ConnectionError>,
    },
}

/// Розбір одного підключення на канонічну форму. Відносний `File=` тут завжди нерозбірний: бази відліку немає.
pub fn canonical_form(connection: &str) -> Canonical {
    let parsed = match parse_str(connection) {
        Ok(p) => p,
        Err(e) => {
            return Canonical::Unparsed {
                reason: e.message().to_string(),
                credentials: Some(e),
            };
        }
    };
    match parsed {
        Connection::Server { server, reference } => Canonical::Parsed {
            kind: InfobaseKind::Server,
            identity: format!(
                "server:{}/{}",
                server.to_lowercase(),
                reference.to_lowercase()
            ),
            path: None,
        },
        Connection::File { file } => {
            if !is_path_rooted(&file) {
                return Canonical::Unparsed {
                    reason: "відносний File= — kit звіряє лише абсолютні File=.".to_string(),
                    credentials: None,
                };
            }
            match canonical_path(&file) {
                Ok(full) => Canonical::Parsed {
                    kind: InfobaseKind::File,
                    identity: format!("file:{}", full.to_lowercase()),
                    path: Some(full),
                },
                Err(e) => Canonical::Unparsed {
                    reason: e.message().to_string(),
                    credentials: None,
                },
            }
        }
    }
}

/// Звідки підключення — для тексту відмови, без значень рядка.
pub struct Origins<'a> {
    pub left: &'a str,
    pub right: &'a str,
    pub left_kind: CredentialsKind,
    pub right_kind: CredentialsKind,
}

/// Чи ПЕРЕТИНАЮТЬСЯ два підключення: та сама база або одна лежить усередині/над іншою. Fail-closed: коли хоч одне
/// підключення не розбирається однозначно, — помилка, а не `false`.
pub fn infobases_overlap(
    left: &str,
    right: &str,
    origins: &Origins<'_>,
) -> Result<bool, ConfigError> {
    let l = canonical_form(left);
    let r = canonical_form(right);
    let (bad, bad_origin, bad_kind) = match (&l, &r) {
        (Canonical::Unparsed { .. }, _) => (Some(&l), origins.left, origins.left_kind),
        (_, Canonical::Unparsed { .. }) => (Some(&r), origins.right, origins.right_kind),
        _ => (None, "", CredentialsKind::Agent),
    };
    if let Some(Canonical::Unparsed {
        reason,
        credentials,
    }) = bad
    {
        let mut reason = reason.clone();
        if let Some(e) = credentials {
            let recipe = credentials_recipe(e, bad_kind);
            if !recipe.is_empty() {
                reason = format!("{reason} {recipe}");
            }
        }
        return Err(ConfigError::new(format!(
            "Kit не може однозначно розібрати й звірити два підключення до бази: нерозбірне — {bad_origin}. {reason} Очікується File=<абсолютний шлях> або Srvr=<сервер>;Ref=<база>;. Доки kit не впевнений, що бази РІЗНІ, він зупиняється, а не продовжує мовчки (принцип 3)."
        )));
    }
    match (l, r) {
        (
            Canonical::Parsed {
                kind: lk,
                identity: li,
                path: lp,
            },
            Canonical::Parsed {
                kind: rk,
                identity: ri,
                path: rp,
            },
        ) => {
            if lk != rk {
                return Ok(false);
            }
            if lk == InfobaseKind::File {
                return Ok(match (lp, rp) {
                    (Some(a), Some(b)) => canonical_paths_overlap(&a, &b),
                    _ => false,
                });
            }
            Ok(li == ri)
        }
        _ => Ok(false),
    }
}

// ---------------------------------------------------------------------------------------------------------
// Захищені шляхи

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectedKind {
    DevBase,
    OtherBase,
    OtherMemory,
    Template,
}

impl ProtectedKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProtectedKind::DevBase => "devbase",
            ProtectedKind::OtherBase => "otherbase",
            ProtectedKind::OtherMemory => "othermemory",
            ProtectedKind::Template => "template",
        }
    }
}

pub const ALL_PROTECTED_KINDS: [ProtectedKind; 4] = [
    ProtectedKind::DevBase,
    ProtectedKind::OtherBase,
    ProtectedKind::OtherMemory,
    ProtectedKind::Template,
];

/// Воркспейс, як його бачить аудит баз: шлях у маніфесті й його `v8project`.
#[derive(Debug, Clone, Copy)]
pub struct WorkspaceRef<'a> {
    pub path: &'a str,
    pub project: &'a V8Project,
}

/// Елемент переліку захищених шляхів. `label` — текст для повідомлення без значень конфігу; `path` — абсолютний
/// шлях файлової бази чи файла (немає для серверної); `connection` — підключення серверної бази.
#[derive(Debug, Clone, PartialEq)]
pub struct ProtectedItem {
    pub kind: ProtectedKind,
    pub other: Option<String>,
    pub label: String,
    pub path: Option<String>,
    pub connection: Option<RawConnection>,
    pub candidates: Vec<String>,
}

fn item(
    kind: ProtectedKind,
    other: Option<&str>,
    label: String,
    path: Option<String>,
    connection: Option<RawConnection>,
) -> ProtectedItem {
    let candidates = path.as_deref().map(path_ancestry).unwrap_or_default();
    ProtectedItem {
        kind,
        other: other.map(str::to_string),
        label,
        path,
        connection,
        candidates,
    }
}

/// ЄДИНИЙ перелік шляхів, яких provision не має права зачепити: дев-бази накладки, бази агента й пам'ять
/// раннера ІНШИХ воркспейсів, шаблони `.dt` (параметр і `agentBase.template` накладки кожного воркспейсу).
pub fn protected_paths(
    overlay: Option<&Overlay>,
    workspaces: &[WorkspaceRef<'_>],
    current: &str,
    template: Option<&str>,
    kinds: &[ProtectedKind],
) -> Result<Vec<ProtectedItem>, ConfigError> {
    let mut items = Vec::new();
    if kinds.contains(&ProtectedKind::DevBase) {
        for human in overlay.map(|o| o.infobases.as_slice()).unwrap_or_default() {
            let label = format!("дев-база '{}'", human.name);
            let parsed = parse_str(human.connection.expose()).map_err(|_| {
                ConfigError::new(format!(
                    "Не вдалося розібрати підключення ({label}) для перевірки захищених шляхів — kit не може довести, що бази різні."
                ))
            })?;
            let Connection::File { file } = parsed else {
                items.push(item(
                    ProtectedKind::DevBase,
                    None,
                    label,
                    None,
                    Some(human.connection.clone()),
                ));
                continue;
            };
            assert_plain_path(&file)?;
            let p = file;
            if !is_path_rooted(&p) {
                continue;
            }
            items.push(item(ProtectedKind::DevBase, None, label, Some(p), None));
        }
    }
    if kinds.contains(&ProtectedKind::OtherBase) || kinds.contains(&ProtectedKind::OtherMemory) {
        for other in workspaces.iter().filter(|w| !eq_ci(w.path, current)) {
            let Some(ib) = resolve_agent_infobase(other.project)? else {
                continue;
            };
            if kinds.contains(&ProtectedKind::OtherBase) {
                let resolved = resolve_agent_infobase_path(other.project, &ib.connection)?;
                let label = format!("база агента воркспейсу '{}'", other.path);
                match resolved.kind {
                    InfobaseKind::File => items.push(item(
                        ProtectedKind::OtherBase,
                        Some(other.path),
                        label,
                        resolved.path,
                        None,
                    )),
                    InfobaseKind::Server => items.push(item(
                        ProtectedKind::OtherBase,
                        Some(other.path),
                        label,
                        None,
                        Some(ib.connection.clone()),
                    )),
                }
            }
            if kinds.contains(&ProtectedKind::OtherMemory) {
                // Уся тека .local/infobases (батьківська для бази origin): чужа база під будь-якою пам'яттю
                // раннера чужого воркспейсу — перетин.
                let mem = parent_of(&runner_memory_path(other.project, "origin"));
                let label = format!(
                    "пам'ять раннера воркспейсу '{}' (.local/infobases)",
                    other.path
                );
                items.push(item(
                    ProtectedKind::OtherMemory,
                    Some(other.path),
                    label,
                    mem,
                    None,
                ));
            }
        }
    }
    if kinds.contains(&ProtectedKind::Template) {
        let mut templates: Vec<(String, String)> = Vec::new();
        if let Some(t) = template.filter(|t| !t.is_empty()) {
            templates.push((t.to_string(), "параметр -Template".to_string()));
        }
        for ow in overlay.map(|o| o.workspaces.as_slice()).unwrap_or_default() {
            if let Some(t) = ow.agent_base_template.as_deref().filter(|t| !t.is_empty()) {
                templates.push((
                    t.to_string(),
                    format!("workspaces.{}.agentBase.template у накладці", ow.path),
                ));
            }
        }
        let mut seen: Vec<String> = Vec::new();
        for (t, origin) in templates {
            let full = full_path(&t).map_err(|_| {
                ConfigError::new(format!(
                    "Шлях шаблону бази (.dt) не розбирається ({origin}) — kit не може довести, що шаблон лежить поза текою видалення. Рішення за людиною: коректний шлях шаблону."
                ))
            })?;
            if seen.iter().any(|s| eq_ci(s, &full)) {
                continue;
            }
            seen.push(full.clone());
            items.push(item(
                ProtectedKind::Template,
                None,
                "шаблон бази (.dt)".to_string(),
                Some(full),
                None,
            ));
        }
    }
    Ok(items)
}

/// Те, що охороняється: тека бази чи пам'ять раннера.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub name: &'static str,
    pub path: Option<String>,
    pub connection: Option<RawConnection>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProtectedHit {
    pub element: ProtectedItem,
    pub target: &'static str,
}

/// Перетин елементів переліку захищених шляхів з кожною ціллю: подвійний цикл «перелік × цілі», без вибору пар.
/// Файли — `paths_overlap` (канонізація), серверні — `infobases_overlap`. Нерозбірне — помилка без значень шляху.
pub fn find_protected_collisions(
    protected: &[ProtectedItem],
    targets: &[Target],
) -> Result<Vec<ProtectedHit>, ConfigError> {
    let mut hits = Vec::new();
    for el in protected {
        for t in targets {
            let overlap = if let Some(el_path) = &el.path {
                match &t.path {
                    Some(t_path) => paths_overlap(el_path, t_path).map_err(|e| {
                        ConfigError::new(format!(
                            "Kit не може звірити захищений шлях ({}) з текою бази агента чи пам'яті раннера: {}",
                            el.label,
                            e.message()
                        ))
                    })?,
                    None => false,
                }
            } else if let (Some(t_conn), Some(el_conn)) = (&t.connection, &el.connection) {
                infobases_overlap(
                    el_conn.expose(),
                    t_conn.expose(),
                    &Origins {
                        left: &el.label,
                        right: "база агента цього воркспейсу (infobases.origin)",
                        left_kind: CredentialsKind::Agent,
                        right_kind: CredentialsKind::Overlay,
                    },
                )?
            } else {
                false
            };
            if overlap {
                hits.push(ProtectedHit {
                    element: el.clone(),
                    target: t.name,
                });
            }
        }
    }
    Ok(hits)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CollisionKind {
    Base,
    MemoryMine,
    MemoryTheirs,
    MemoryBoth,
}

impl CollisionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            CollisionKind::Base => "base",
            CollisionKind::MemoryMine => "memory-mine",
            CollisionKind::MemoryTheirs => "memory-theirs",
            CollisionKind::MemoryBoth => "memory-both",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentBaseCollision {
    pub other: Option<String>,
    pub kind: CollisionKind,
    /// Збіг серверних баз за сервером і Ref (не «тека»).
    pub server: bool,
}

/// Перетини бази агента воркспейсу з базами агента й пам'яттю раннера ІНШИХ воркспейсів маніфесту.
pub fn agent_base_collisions(
    overlay: Option<&Overlay>,
    workspaces: &[WorkspaceRef<'_>],
    current: &WorkspaceRef<'_>,
) -> Result<Vec<AgentBaseCollision>, ConfigError> {
    let Some(mine) = resolve_agent_infobase(current.project)? else {
        return Ok(Vec::new());
    };
    let resolved = resolve_agent_infobase_path(current.project, &mine.connection)?;
    let is_file = resolved.kind == InfobaseKind::File;
    let targets = [
        Target {
            name: "base",
            path: if is_file { resolved.path.clone() } else { None },
            connection: if is_file {
                None
            } else {
                Some(mine.connection.clone())
            },
        },
        Target {
            name: "memory",
            path: Some(runner_memory_path(current.project, "origin")),
            connection: None,
        },
    ];
    let protected = protected_paths(
        overlay,
        workspaces,
        current.path,
        None,
        &[ProtectedKind::OtherBase, ProtectedKind::OtherMemory],
    )?;
    let mut found = Vec::new();
    for h in find_protected_collisions(&protected, &targets)? {
        let kind = if h.element.kind == ProtectedKind::OtherMemory && h.target == "memory" {
            CollisionKind::MemoryBoth
        } else if h.element.kind == ProtectedKind::OtherMemory {
            CollisionKind::MemoryTheirs
        } else if h.target == "base" {
            CollisionKind::Base
        } else {
            CollisionKind::MemoryMine
        };
        found.push(AgentBaseCollision {
            other: h.element.other.clone(),
            kind,
            server: h.element.path.is_none() && kind == CollisionKind::Base,
        });
    }
    Ok(found)
}

// ---------------------------------------------------------------------------------------------------------
// База агента воркспейсу

#[derive(Debug, Clone, PartialEq)]
pub struct AgentBase {
    pub workspace: String,
    pub connection: RawConnection,
    pub user: String,
    pub password: Secret,
    pub dbms: Option<SecretTree>,
    pub origin: String,
    pub kind: InfobaseKind,
    pub path: Option<String>,
    pub ib_switch: String,
    pub exists: bool,
}

/// Дев-база накладки, з якою перетинається база агента.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevBaseOverlap {
    pub name: String,
}

/// ВСІ перетини підключення бази агента воркспейсу з дев-базами накладки, у порядку накладки: `Ok` — база
/// перетинається, `Err` — звірити не вдалося (fail-closed: підключення нерозбірне). Бази, що не перетинаються
/// і розібрані, у переліку немає. Єдине правило перетину для `resolve_agent_base` (перший елемент) і для
/// `local-audit` (усі). Відносний `File=` розв'язується від теки конфіга, як в `resolve_agent_infobase_path`.
pub fn dev_base_overlaps(
    overlay: Option<&Overlay>,
    workspace_path: &str,
    project: &V8Project,
    connection: &RawConnection,
) -> Vec<Result<DevBaseOverlap, ConfigError>> {
    let Some(overlay) = overlay else {
        return Vec::new();
    };
    let resolved = match resolve_agent_infobase_path(project, connection) {
        Ok(r) => r,
        Err(e) => return vec![Err(e)],
    };
    let agent_conn = match (&resolved.kind, &resolved.path) {
        (InfobaseKind::File, Some(p)) => format!("File={p}"),
        _ => connection.expose().to_string(),
    };
    let left_origin = format!(
        "база агента воркспейсу '{workspace_path}' (infobases.origin у v8project.local.yaml)"
    );
    let mut found = Vec::new();
    for human in &overlay.infobases {
        let right_origin = format!("дев-база '{}' у v8storagekit.local.yaml", human.name);
        match infobases_overlap(
            &agent_conn,
            human.connection.expose(),
            &Origins {
                left: &left_origin,
                right: &right_origin,
                left_kind: CredentialsKind::Agent,
                right_kind: CredentialsKind::Overlay,
            },
        ) {
            Ok(false) => {}
            Ok(true) => found.push(Ok(DevBaseOverlap {
                name: human.name.clone(),
            })),
            Err(e) => found.push(Err(e)),
        }
    }
    found
}

/// База агента воркспейсу плюс аудит: це не база людини. Збіг з дев-базою накладки чи нерозбірне підключення —
/// помилка до будь-якої дії. `None` — бази не налаштовано на цій машині.
pub fn resolve_agent_base(
    overlay: Option<&Overlay>,
    workspace_path: &str,
    project: &V8Project,
) -> Result<Option<AgentBase>, ConfigError> {
    let Some(ib) = resolve_agent_infobase(project)? else {
        return Ok(None);
    };
    let resolved = resolve_agent_infobase_path(project, &ib.connection)?;

    if let Some(first) = dev_base_overlaps(overlay, workspace_path, project, &ib.connection)
        .into_iter()
        .next()
    {
        return Err(match first {
            Err(e) => e,
            Ok(human) => ConfigError::new(format!(
                "База агента воркспейсу '{workspace_path}' ({}) збігається з дев-базою людини '{}' із накладки kit або перетинається з нею (та сама тека, вкладена чи батьківська). Kit ніколи не пише в базу людини (принцип 3): приберіть infobases.origin з v8project.local.yaml або дайте агентові окрему базу.",
                ib.origin, human.name
            )),
        });
    }

    let exists = match (&resolved.kind, &resolved.path) {
        (InfobaseKind::File, Some(p)) => Path::new(&join_ps(p, "1Cv8.1CD")).is_file(),
        _ => true,
    };
    let AgentInfobase {
        connection,
        origin,
        user,
        password,
        dbms,
    } = ib;
    Ok(Some(AgentBase {
        workspace: workspace_path.to_string(),
        connection,
        user,
        password,
        dbms,
        origin,
        kind: resolved.kind,
        path: resolved.path,
        ib_switch: resolved.ib_switch,
        exists,
    }))
}

/// Чи потребує воркспейс бази агента — за ТИПАМИ наборів, не за наявністю бази.
pub fn workspace_needs_agent_base(project: &V8Project) -> bool {
    project
        .source_sets
        .iter()
        .any(|s| eq_ci(&s.type_name, "CONFIGURATION") || eq_ci(&s.type_name, "EXTENSION"))
}

/// Єдиний текст «бази агента воркспейсу не налаштовано» — для зупинок і знахідок check.
pub fn agent_base_missing_message(workspace_path: &str) -> String {
    format!(
        "База агента воркспейсу '{workspace_path}' не налаштована: у {workspace_path}/v8project.local.yaml немає infobases.origin (файл гітігнорований — на свіжому клоні його ще немає). Налаштувати й розгорнути базу — скіл v8storagekit:infobase-agent, тоді повторіть команду."
    )
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod tests {
    use super::*;
    use crate::config::v8project::read_v8project;

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("kit-agb-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn workspace(dir: &Path, local: &str, source_type: &str) -> V8Project {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(
            dir.join("v8project.yaml"),
            format!("source-set: [{{ name: a, type: {source_type}, path: src }}]\n"),
        )
        .unwrap();
        std::fs::write(dir.join("v8project.local.yaml"), local).unwrap();
        read_v8project(&dir.join("v8project.yaml")).unwrap()
    }

    fn origins<'a>() -> Origins<'a> {
        Origins {
            left: "ліве",
            right: "праве",
            left_kind: CredentialsKind::Agent,
            right_kind: CredentialsKind::Overlay,
        }
    }

    #[test]
    fn overlap_predicate_is_separator_aware_and_case_insensitive() {
        assert!(canonical_paths_overlap("D:\\Bases\\X", "d:\\bases\\x\\"));
        assert!(canonical_paths_overlap("D:\\Bases\\X\\ib", "D:\\Bases\\X"));
        assert!(!canonical_paths_overlap("D:\\Bases\\ib2", "D:\\Bases\\ib"));
        // Канонічна форма не вимагає наявності шляху; зняття префіксів — лише для цілей посилань.
        assert_eq!(
            canonical_path("Z:\\немає\\x").unwrap().to_lowercase(),
            "z:\\немає\\x"
        );
        assert_eq!(strip_verbatim("\\\\?\\UNC\\srv\\sh\\x"), "\\\\srv\\sh\\x");
        assert_eq!(strip_verbatim("\\??\\C:\\x"), "C:\\x");
    }

    // Раунд 1, знахідка 2: «відсутній» — лише коди 2 і 3; мережева помилка (67) і шлях через файл (267) —
    // fail-closed, а не тихий перехід на лексичне порівняння.
    #[test]
    fn only_file_and_path_not_found_stop_link_resolution() {
        let e = canonical_path("\\\\localhost\\nosuchshare_zz_kit\\x").unwrap_err();
        assert!(
            e.message()
                .starts_with("не вдалося перевірити компонент шляху бази"),
            "{e}"
        );
        let d = tmp("absent");
        std::fs::write(d.join("file.txt"), "x").unwrap();
        // Шлях через звичайний файл Windows відхиляє кодом 3, як .NET (DirectoryNotFoundException): «відсутній»,
        // а не помилка (виміряно: код 267 для цього входу не виникає).
        let through_file = d.join("file.txt").join("sub");
        assert!(
            canonical_path(&through_file.to_string_lossy())
                .unwrap()
                .to_lowercase()
                .ends_with("file.txt\\sub")
        );
        // Контроль: ненаявний хвіст під наявною текою — не помилка.
        assert!(
            canonical_path(&d.join("немає").join("x").to_string_lossy())
                .unwrap()
                .to_lowercase()
                .ends_with("немає\\x")
        );
    }

    // Раунд 1, доповнення архітектора: пристрої, GLOBALROOT, Volume{…}, адмінські ресурси — відмова без цитування
    // шляху; звичайний `C:\…` і `\\сервер\ресурс\…` проходять.
    #[test]
    fn device_prefixes_and_admin_shares_are_refused_everywhere() {
        let marker = "МАРКЕР-шлях";
        for bad in [
            format!("\\\\.\\C:\\{marker}"),
            format!("\\\\localhost\\C$\\{marker}"),
            format!("\\\\?\\GLOBALROOT\\Device\\{marker}"),
            format!("\\\\?\\C:\\{marker}"),
            format!("\\??\\C:\\{marker}"),
            format!("//./C:/{marker}"),
            format!("\\\\localhost\\\\C$\\{marker}"),
            format!("//localhost//C$/{marker}"),
            format!("\\\\h\\/C$\\{marker}"),
            format!(" \\\\localhost\\\\C$\\{marker}"),
            format!("\\\\127.0.0.1\\\\\\C$\\{marker}"),
            format!("\\\\?\\UNC\\localhost\\C$\\{marker}"),
        ] {
            let e = assert_plain_path(&bad).unwrap_err();
            assert!(
                e.message().contains("не збігається з базою людини")
                    && !e.message().contains(marker),
                "{e}"
            );
            assert!(canonical_path(&bad).is_err());
            // Дев-база накладки: відмова в переліку захищених шляхів.
            let overlay = Overlay {
                path: "o.yaml".into(),
                infobases: vec![crate::config::overlay::OverlayInfobase {
                    name: "dev".into(),
                    connection: RawConnection::new(format!("File={bad}")),
                    user: String::new(),
                }],
                storages: vec![],
                workspaces: vec![],
            };
            let e = protected_paths(Some(&overlay), &[], "ws", None, &[ProtectedKind::DevBase])
                .unwrap_err();
            assert!(!e.message().contains(marker), "{e}");
            // База агента проти дев-бази: нерозбірне — відмова, значення не цитується.
            let e =
                infobases_overlap(&format!("File={bad}"), "File=Z:\\b", &origins()).unwrap_err();
            assert!(!e.message().contains(marker), "{e}");
        }
        for ok in [
            "C:\\x\\ib",
            "\\\\server\\share\\ib",
            "build\\ib",
            "\\\\server\\ADMIN\\x",
        ] {
            assert!(assert_plain_path(ok).is_ok(), "{ok}");
        }
    }

    // Ціль посилання: Volume{…}/GLOBALROOT — відмова; відносна ціль — від теки посилання, не від теки процесу.
    #[test]
    fn link_target_is_checked_and_relative_target_uses_link_dir() {
        for bad in [
            "\\\\?\\Volume{00000000-0000-0000-0000-000000000000}\\",
            "\\??\\Volume{1}\\x",
            "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1\\x",
        ] {
            let e = resolve_link_target(bad, "C:\\a\\b").unwrap_err();
            assert!(
                e.message().contains("не збігається з базою людини")
                    && !e.message().contains("Volume"),
                "{e}"
            );
        }
        assert_eq!(
            resolve_link_target("\\??\\C:\\real\\x", "C:\\a")
                .unwrap()
                .as_deref(),
            Some("C:\\real\\x")
        );
        assert_eq!(
            resolve_link_target("\\\\?\\UNC\\srv\\sh\\x", "C:\\a")
                .unwrap()
                .as_deref(),
            Some("\\\\srv\\sh\\x")
        );
        assert_eq!(
            resolve_link_target("..\\x", "C:\\a\\b").unwrap().as_deref(),
            Some("C:\\a\\x")
        );
        // Корінь без диска й диск без кореня — відмова, а не підстановка диска чи теки процесу.
        for bad in ["\\x", "C:x", "/x"] {
            assert!(resolve_link_target(bad, "D:\\a").is_err(), "{bad}");
        }
        // Адмінський ресурс у цілі — відмова (у т. ч. після зняття `\\?\UNC\`).
        assert!(resolve_link_target("\\\\?\\UNC\\localhost\\C$\\x", "D:\\a").is_err());
        assert!(resolve_link_target("\\\\localhost\\\\C$\\x", "D:\\a").is_err());
        assert_eq!(resolve_link_target("", "C:\\a").unwrap(), None);
    }

    #[test]
    fn infobase_overlap_contract_and_fail_closed() {
        assert!(infobases_overlap("Srvr=S;Ref=R;", "ref=r;SRVR=\"s\";", &origins()).unwrap());
        assert!(!infobases_overlap("Srvr=S;Ref=R;", "File=D:\\x", &origins()).unwrap());
        assert!(infobases_overlap("File=Z:\\b\\", "File=Z:\\b\\ib", &origins()).unwrap());
        // Нерозбірне — помилка за походженням, без значень; рецепт на Usr/Pwd — за видом підключення.
        let e = infobases_overlap("File=build/ib", "File=Z:\\b", &origins()).unwrap_err();
        assert!(
            e.message().contains("нерозбірне — ліве. відносний File=")
                && !e.message().contains("build/ib"),
            "{e}"
        );
        let e = infobases_overlap("File=Z:\\b", "File=Z:\\b;Pwd=СЕКРЕТ", &origins()).unwrap_err();
        assert!(
            e.message().contains("нерозбірне — праве.")
                && e.message().contains("накладки")
                && !e.message().contains("СЕКРЕТ"),
            "{e}"
        );
    }

    #[test]
    fn ancestry_and_memory_path() {
        assert_eq!(path_ancestry("C:\\a\\b\\"), ["C:\\a\\b", "C:\\a", "C:\\"]);
        assert_eq!(
            path_ancestry("\\\\localhost\\C$\\x"),
            [
                "\\\\localhost\\C$\\x",
                "\\\\localhost\\C$",
                "\\\\localhost",
                "\\"
            ]
        );
        let d = tmp("mem");
        let p = workspace(&d.join("ws"), "", "CONFIGURATION");
        assert!(runner_memory_path(&p, "origin").ends_with("ws\\.local\\infobases\\origin"));
        assert!(workspace_needs_agent_base(&p));
        assert!(!workspace_needs_agent_base(&workspace(
            &d.join("w2"),
            "",
            "external_data_processors"
        )));
        assert!(
            agent_base_missing_message("main")
                .contains("'main' не налаштована: у main/v8project.local.yaml")
        );
    }

    #[test]
    fn agent_base_resolves_relative_file_and_refuses_human_base() {
        let d = tmp("base");
        let ws = d.join("ws");
        let project = workspace(
            &ws,
            "infobases:\n  origin:\n    connection: 'File=build/ib'\n    password: МАРКЕР-пароль\n",
            "EXTENSION",
        );
        let human = |conn: &str| Overlay {
            path: d.join("o.yaml"),
            infobases: vec![crate::config::overlay::OverlayInfobase {
                name: "dev".into(),
                connection: RawConnection::new(conn),
                user: String::new(),
            }],
            storages: vec![],
            workspaces: vec![],
        };
        let b = resolve_agent_base(Some(&human("File=Z:\\інша")), "ws", &project)
            .unwrap()
            .unwrap();
        assert!(
            b.path
                .as_deref()
                .unwrap()
                .to_lowercase()
                .ends_with("ws\\build\\ib")
                && !b.exists
        );
        assert!(b.ib_switch.starts_with("/F \"") && b.password.expose() == "МАРКЕР-пароль");
        assert!(
            !format!("{b:?}").contains("МАРКЕР"),
            "Debug бази агента видав пароль: {b:?}"
        );
        // Дев-база над текою бази агента — збіг; нерозбірна дев-база — відмова (fail-closed).
        let e = resolve_agent_base(
            Some(&human(&format!("File={}", ws.display()))),
            "ws",
            &project,
        )
        .unwrap_err();
        assert!(
            e.message().contains("збігається з дев-базою людини 'dev'"),
            "{e}"
        );
        assert!(resolve_agent_base(Some(&human("File=rel")), "ws", &project).is_err());
        assert!(
            resolve_agent_base(None, "ws", &workspace(&d.join("w3"), "", "EXTENSION"))
                .unwrap()
                .is_none()
        );
    }
}
