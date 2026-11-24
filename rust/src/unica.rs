// Плагін Уніка в оточенні kit (ADR-0019, ADR-0021 п. 7): реєстр плагінів Claude Code, установлена
// Уніка (лише `install_path` і версія) і вердикти версій. Модуль нічого не запускає: шлях раннера з
// `install_path` будує й запускає лише модуль `runner`.
//
// Реєстр — `<домашня тека>/.claude/plugins/installed_plugins.json` або явний параметр; шлях ніколи не
// береться з маніфесту, накладки чи оточення (єдине читання оточення — домашня тека в `default_registry`;
// запобіжник rust/tests/git_guard.rs). Тексти причин і вердиктів — ті самі, що в
// `Get-UnicaInstallation` і `Get-KitUnicaVersionVerdict` (tools/lib/Environment.psm1); відомі відмінності:
//  - вибір запису (ADR-0019, ADR-0021 п. 7): PowerShell брав перший ключ `unica@…` і перший запис,
//    ігноруючи `scope` і `projectPath`; тут кандидати — записи `scope: user` і записи `project`/`local`,
//    чий `projectPath` — корінь репозиторію чи його предок; кілька кандидатів — помилка без вибору;
//  - текст розбору зіпсованого JSON — не .NET-ний (префікс до двокрапки той самий; ADR-0014 п. 7).

use serde_json::Value;
use std::fmt;
use std::path::{Path, PathBuf};

/// Протестований мінор Уніки: kit говорить мовою Уніки 0.16 (`$script:UnicaTestedMinor`).
const TESTED_MINOR: (u64, u64) = (0, 16);

/// Ім'я плагіна до `@` у ключі реєстру.
const PLUGIN_NAME: &str = "unica";

/// Рівень вердикту.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Ok,
    Warn,
    Error,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Ok => "ok",
            Level::Warn => "warn",
            Level::Error => "error",
        }
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Вердикт: рівень, текст і версія (порожня, коли її не визначено).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub level: Level,
    pub message: String,
    pub version: String,
}

/// Запис реєстру, що претендує на роль установленої Уніки.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub key: String,
    pub scope: String,
    pub project_path: Option<String>,
    pub version: String,
    pub install_path: String,
}

impl Candidate {
    fn describe(&self) -> String {
        format!(
            "{} (scope {}, projectPath {}, версія {})",
            self.key,
            self.scope,
            self.project_path.as_deref().unwrap_or("-"),
            if self.version.is_empty() {
                "-"
            } else {
                &self.version
            }
        )
    }
}

/// Установлена Уніка за реєстром (`Get-UnicaInstallation`). `installed` — запис знайдено й обрано;
/// `path_exists` — тека на диску є. Кілька кандидатів: `installed == false`, `candidates` — усі, `reason` —
/// текст помилки з кроком прибирання зайвого встановлення.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Installation {
    pub installed: bool,
    pub version: String,
    pub install_path: String,
    pub path_exists: bool,
    pub reason: String,
    pub candidates: Vec<Candidate>,
}

/// Реєстр поточного користувача: `<домашня тека>/.claude/plugins/installed_plugins.json`. Домашня тека — та
/// сама, що `$HOME` у `pwsh` на Windows (виміряно: `USERPROFILE`, не `HOME`).
pub fn default_registry() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE")?;
    if home.is_empty() {
        return None;
    }
    Some(
        PathBuf::from(home)
            .join(".claude")
            .join("plugins")
            .join("installed_plugins.json"),
    )
}

/// Шлях для порівняння: розділювачі `/`, без кінцевих, без регістру (Windows).
fn norm_path(p: &str) -> String {
    // Префікс розширеного шляху (`fs::canonicalize` на Windows) знімається: `\\?\UNC\` → `\\`, `\\?\` → ``.
    let p = if let Some(rest) = p.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else {
        p.strip_prefix(r"\\?\").unwrap_or(p).to_string()
    };
    p.replace('\\', "/").trim_end_matches('/').to_lowercase()
}

/// `project_path` — корінь репозиторію чи його предок.
fn covers(project_path: &str, repo_root: &Path) -> bool {
    let (pp, root) = (
        norm_path(project_path),
        norm_path(&repo_root.to_string_lossy()),
    );
    !pp.is_empty() && (root == pp || root.starts_with(&format!("{pp}/")))
}

fn str_field(v: &Value, name: &str) -> Option<String> {
    match v.get(name)? {
        Value::String(s) => Some(s.clone()),
        Value::Null => None,
        other => Some(other.to_string()),
    }
}

fn not_installed(reason: String) -> Installation {
    Installation {
        reason,
        ..Installation::default()
    }
}

/// Читає реєстр і вибирає запис Уніки. Не падає: причина — текстом у `reason`. `repo_root == None` —
/// лише записи `scope: user`.
pub fn installation(registry: &Path, repo_root: Option<&Path>) -> Installation {
    let shown = registry.display();
    if !registry.exists() {
        return not_installed(format!("Реєстр плагінів не знайдено: {shown}"));
    }
    let bytes = match std::fs::read(registry) {
        Ok(b) => b,
        Err(e) => {
            return not_installed(format!(
                "Реєстр плагінів не читається як JSON ({shown}): {e}"
            ));
        }
    };
    let raw = String::from_utf8_lossy(&bytes);
    let raw = raw.strip_prefix('\u{feff}').unwrap_or(&raw);
    let json: Value = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => {
            return not_installed(format!(
                "Реєстр плагінів не читається як JSON ({shown}): {e}"
            ));
        }
    };
    let Some(plugins) = json.get("plugins").and_then(Value::as_object) else {
        return not_installed(format!("У реєстрі {shown} немає розділу 'plugins'"));
    };

    let keys: Vec<(&String, &Value)> = plugins
        .iter()
        .filter(|(k, _)| k.split('@').next().unwrap_or("").to_lowercase() == PLUGIN_NAME)
        .collect();
    if keys.is_empty() {
        return not_installed(format!(
            "Плагін '{PLUGIN_NAME}' не значиться в реєстрі {shown}"
        ));
    }

    // Значення ключа — масив записів або один об'єкт.
    let mut records: Vec<(&String, &Value)> = Vec::new();
    for (key, value) in &keys {
        match value {
            Value::Array(items) => records.extend(items.iter().map(|i| (*key, i))),
            Value::Null => {}
            single => records.push((key, single)),
        }
    }
    if records.is_empty() {
        return not_installed(format!(
            "Плагін '{PLUGIN_NAME}' є в реєстрі, але без жодного запису про встановлення"
        ));
    }

    let mut candidates = Vec::new();
    for (key, rec) in records {
        if !rec.is_object() {
            continue;
        }
        let scope = str_field(rec, "scope").unwrap_or_default();
        let project_path = str_field(rec, "projectPath");
        let qualifies = scope.eq_ignore_ascii_case("user")
            || (["project", "local"]
                .iter()
                .any(|s| scope.eq_ignore_ascii_case(s))
                && matches!((repo_root, &project_path), (Some(root), Some(pp)) if covers(pp, root)));
        if qualifies {
            candidates.push(Candidate {
                key: key.clone(),
                scope,
                project_path,
                version: str_field(rec, "version").unwrap_or_default(),
                install_path: str_field(rec, "installPath").unwrap_or_default(),
            });
        }
    }

    match candidates.len() {
        0 => not_installed(format!(
            "Плагін '{PLUGIN_NAME}' не значиться в реєстрі {shown}"
        )),
        1 => {
            let c = candidates[0].clone();
            let mut r = Installation {
                installed: true,
                version: c.version.clone(),
                install_path: c.install_path.clone(),
                candidates,
                ..Installation::default()
            };
            if c.install_path.trim().is_empty() {
                r.reason = format!("Запис про '{PLUGIN_NAME}' є, але без installPath");
                return r;
            }
            r.path_exists = Path::new(&c.install_path).exists();
            if !r.path_exists {
                r.reason = format!(
                    "Реєстр вказує на теку, якої немає на диску: {}",
                    c.install_path
                );
            }
            r
        }
        _ => {
            let list = candidates
                .iter()
                .map(Candidate::describe)
                .collect::<Vec<_>>()
                .join("; ");
            let steps = candidates
                .iter()
                .map(|c| format!("claude plugin uninstall {} --scope {}", c.key, c.scope))
                .collect::<Vec<_>>()
                .join("; ");
            Installation {
                reason: format!(
                    "У реєстрі {shown} кілька записів плагіна '{PLUGIN_NAME}', чинних для цього репозиторію: {list}. \
                     kit не вибирає між ними (який вантажиться — Claude Code не документує); залиште один, \
                     прибравши зайве встановлення: {steps}"
                ),
                candidates,
                ..Installation::default()
            }
        }
    }
}

/// `^(\d+)\.(\d+)(\.\d+)?` на початку рядка версії → (мажор, мінор).
fn parse_major_minor(raw: &str) -> Option<(u64, u64)> {
    let digits = |s: &str| -> usize { s.bytes().take_while(u8::is_ascii_digit).count() };
    let a = digits(raw);
    if a == 0 || raw.as_bytes().get(a) != Some(&b'.') {
        return None;
    }
    let rest = &raw[a + 1..];
    let b = digits(rest);
    if b == 0 {
        return None;
    }
    Some((raw[..a].parse().ok()?, rest[..b].parse().ok()?))
}

/// Висновок про версію встановленої Уніки (`Get-KitUnicaVersionVerdict`): ok | warn (новіша чи
/// нерозбірна) | error (немає, не та тека, старіша за 0.16, кілька кандидатів).
pub fn unica_verdict(inst: &Installation) -> Verdict {
    let v = |level, message: String, version: &str| Verdict {
        level,
        message,
        version: version.to_string(),
    };
    if inst.candidates.len() > 1 {
        return v(Level::Error, inst.reason.clone(), "");
    }
    if !inst.installed || !inst.path_exists {
        return v(
            Level::Error,
            format!(
                "Плагін unica не знайдено ({}): sync, verify і provision беруть раннер із його встановлення \
                 й без нього не працюють (kit dump працює й без Уніки — він бере платформу напряму). \
                 Встановіть: claude plugin marketplace add IngvarConsulting/unica-marketplace; claude plugin install unica@unica.",
                inst.reason
            ),
            "",
        );
    }
    let raw = &inst.version;
    let Some(minor) = parse_major_minor(raw) else {
        return v(
            Level::Warn,
            format!("Версію плагіна unica '{raw}' не розібрано — kit перевірено на Уніці 0.16.x."),
            raw,
        );
    };
    if minor < TESTED_MINOR {
        return v(
            Level::Error,
            format!(
                "Плагін unica {raw} старіший за 0.16: kit говорить лише мовою Уніки 0.16 (v8-runner 0.18), \
                 старого словника в скілах і шаблонах більше немає. Оновіть Уніку — claude plugin marketplace update unica; \
                 claude plugin update unica@unica — і почніть нову сесію (оновлення перемикає всі репозиторії машини)."
            ),
            raw,
        );
    }
    if minor > TESTED_MINOR {
        return v(
            Level::Warn,
            format!(
                "Плагін unica {raw} новіший за перевірену 0.16.x: перед роботою звірте контракт \
                 за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit)."
            ),
            raw,
        );
    }
    v(Level::Ok, format!("Плагін unica {raw}."), raw)
}

/// Протестований мінор раннера: Уніка 0.16 несе v8-runner 0.18.x.
const RUNNER_TESTED_MINOR: (u64, u64) = (0, 18);

/// Висновок про раннер (`Get-KitRunnerVerdict`): ok | warn (мінор не 0.18 чи версію не розібрано) | error
/// (раннера немає чи він не відповідає; кілька кандидатів Уніки). Шлях — явний `runner` або раннер
/// установленої Уніки з того самого реєстру.
pub fn runner_verdict(runner: Option<&Path>, registry: &Path, repo_root: Option<&Path>) -> Verdict {
    let notice = "sync, verify і provision без раннера не працюють (kit dump працює й без нього — він бере платформу напряму).";
    let found = match runner {
        Some(p) if !p.as_os_str().is_empty() => Ok(p.to_path_buf()),
        _ => crate::runner::installed_runner(registry, repo_root),
    };
    let version = found.and_then(|p| crate::runner::version(&p));
    let version = match version {
        Ok(v) => v,
        Err(e) => {
            return Verdict {
                level: Level::Error,
                version: String::new(),
                message: format!("Раннер Уніки недоступний: {e} {notice}"),
            };
        }
    };
    let Some(minor) = parse_major_minor(&version) else {
        return Verdict {
            level: Level::Warn,
            message: format!(
                "Версію раннера '{version}' не розібрано — kit перевірено на v8-runner 0.18.x."
            ),
            version,
        };
    };
    if minor != RUNNER_TESTED_MINOR {
        return Verdict {
            level: Level::Warn,
            message: format!(
                "Раннер v8-runner {version} — kit перевірено на 0.18.x: перед роботою звірте контракт \
                 за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit)."
            ),
            version,
        };
    }
    Verdict {
        level: Level::Ok,
        message: format!("Раннер v8-runner {version}."),
        version,
    }
}
