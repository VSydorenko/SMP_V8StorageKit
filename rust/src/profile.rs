// Профіль процесу (ADR-0003; tools/lib/KitProfile.psm1): шари від нижнього до верхнього — машинний
// (`$XDG_CONFIG_HOME/v8storagekit/profile.json`, типово `~/.config/…`), проєктний
// (`.agents/kit.profile.json`) і локальний (`.agents/kit.profile.local.json`). Об'єкти зливаються,
// масиви й скаляри замінюються цілком. Імена полів нечутливі до регістру, як у хештаблиці PowerShell.
// Поля, якого немає, команда не вгадує: умовчання вона дає сама.
//
// Тут же — дві дрібні функції JSON «як у PowerShell», спільні з хуком старту (session_start.rs).

use crate::git;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

/// Профіль не прочитано: код виходу й текст без префікса `<команда>: ERROR`.
#[derive(Debug, PartialEq, Eq)]
pub struct ProfileError {
    pub code: i32,
    pub message: String,
}

/// Злитий профіль checkout-а.
#[derive(Debug)]
pub struct Profile {
    data: Value,
}

impl Profile {
    /// Значення за шляхом `a.b.c`; None, коли проміжне поле — не об'єкт або ключа немає.
    pub fn value(&self, path: &str) -> Option<&Value> {
        let mut cur = &self.data;
        for key in path.split('.') {
            cur = cur.as_object()?.get(&key.to_lowercase())?;
        }
        Some(cur)
    }

    /// Профіль checkout-а `cwd`: корінь — `git rev-parse --show-toplevel`; не git — «не перевірено» (код 3).
    pub fn load(cwd: &Path) -> Result<Profile, ProfileError> {
        let root = checkout_root(cwd)?;
        let machine = machine_profile_path();
        let layers = [machine, root.join(".agents").join("kit.profile.json"), root.join(".agents").join("kit.profile.local.json")];
        let mut data = Value::Object(Map::new());
        for path in &layers {
            if path.exists() {
                data = merge(data, read_layer(path)?);
            }
        }
        // Спершу шари, потім простір імен v8storagekit (ADR-0020).
        Ok(Profile { data: apply_namespace(data) })
    }
}

/// Простір імен `v8storagekit` (ADR-0020): у репозиторії, де профіль ділять v8storagekit і agent-kit, наявна
/// секція першого рівня `v8storagekit.<секція>` заміняє верхню `<секцію>` ЦІЛКОМ, без злиття (інакше
/// `v8storagekit.tests` без `levels` пропустив би рівні тестів іншої зони). `v8storagekit.version` — не
/// секція, а версія проєкту (`project_version`). Ключі вже в нижньому регістрі (`lower_keys`).
pub fn apply_namespace(data: Value) -> Value {
    let Value::Object(mut top) = data else { return data };
    if let Some(Value::Object(ns)) = top.get("v8storagekit").cloned() {
        for (k, v) in ns {
            if k != "version" {
                top.insert(k, v);
            }
        }
    }
    Value::Object(top)
}

/// Версія проєкту для v8storagekit (ADR-0020).
#[derive(Debug, PartialEq, Eq)]
pub enum ProjectVersion {
    /// Версію не задано: поля немає (або лише чужий `kit.version` < 1.0.0 — agent-kit). Хук рахує від 0.1.0.
    Unset,
    Set(String),
    /// `v8storagekit.version` є, але не x.y.z.
    Bad,
}

/// Версія проєкту з ОДНОГО JSON-об'єкта профілю (ключі будь-якого регістру): `v8storagekit.version`; немає — тимчасово
/// `kit.version`, лише коли він ≥ 1.0.0 (agent-kit на лінії 0.x, v8storagekit — 1.x). Невалідний `kit.version` — чужий,
/// мовчки ігнорується.
fn get_ci<'a>(obj: &'a Value, name: &str) -> Option<&'a Value> {
    obj.as_object()?.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v)
}

pub fn project_version(json: &Value) -> ProjectVersion {
    let field = |sec: &str| get_ci(json, sec).and_then(|s| get_ci(s, "version"));
    match field("v8storagekit") {
        Some(Value::Null) | None => {}
        Some(v) => {
            let s = ps_string(v);
            return if is_version(&s) { ProjectVersion::Set(s) } else { ProjectVersion::Bad };
        }
    }
    if let Some(v) = field("kit") {
        let s = ps_string(v);
        if let Some((major, _, _)) = parse_version(&s).filter(|_| is_version(&s))
            && major >= 1
        {
            return ProjectVersion::Set(s);
        }
    }
    ProjectVersion::Unset
}

pub fn is_version(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// Версія x.y.z як кортеж; переповнення — None (у PowerShell [version] кидав виняток).
pub fn parse_version(s: &str) -> Option<(i32, i32, i32)> {
    let mut it = s.split('.').map(|p| p.parse::<i32>().ok());
    match (it.next()??, it.next()??, it.next()??, it.next()) {
        (a, b, c, None) => Some((a, b, c)),
        _ => None,
    }
}

fn checkout_root(cwd: &Path) -> Result<PathBuf, ProfileError> {
    let not_git = || ProfileError { code: 3, message: format!("не git-репозиторій: {}", cwd.display()) };
    if !cwd.exists() {
        return Err(not_git());
    }
    let out = git::run(cwd, &["rev-parse", "--show-toplevel"], None, true).map_err(|_| not_git())?;
    if out.code != 0 {
        return Err(not_git());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let first = text.lines().next().unwrap_or("").trim();
    if first.is_empty() {
        return Err(not_git());
    }
    Ok(PathBuf::from(first.replace('/', "\\")))
}

fn machine_profile_path() -> PathBuf {
    let base = match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(x) => PathBuf::from(x),
        None => {
            let home = std::env::var_os("USERPROFILE").filter(|v| !v.is_empty()).or_else(|| std::env::var_os("HOME")).unwrap_or_default();
            PathBuf::from(home).join(".config")
        }
    };
    base.join("v8storagekit").join("profile.json")
}

/// Шар профілю: UTF-8 (BOM знімається), коментарі `//` і `/* */` дозволені, порожній файл — порожній шар.
fn read_layer(path: &Path) -> Result<Value, ProfileError> {
    let shown = path.display();
    let bytes = std::fs::read(path).map_err(|e| ProfileError { code: 3, message: format!("не читається {shown}: {e}") })?;
    let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    let text = strip_json_comments(&String::from_utf8_lossy(body));
    if text.trim().is_empty() {
        return Ok(Value::Object(Map::new()));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| ProfileError { code: 3, message: format!("не читається {shown}: {e}") })?;
    match value {
        Value::Object(_) => Ok(lower_keys(value)),
        // PowerShell тут падав на прив'язці параметра [hashtable]: це збій, а не «не перевірено».
        _ => Err(ProfileError { code: 1, message: format!("не читається {shown}: очікувався JSON-об'єкт") }),
    }
}

fn lower_keys(v: Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(m.into_iter().map(|(k, v)| (k.to_lowercase(), lower_keys(v))).collect()),
        other => other,
    }
}

/// Верхній шар доповнює нижній: об'єкти зливаються, масиви й скаляри замінюються цілком.
fn merge(base: Value, over: Value) -> Value {
    match (base, over) {
        (Value::Object(mut b), Value::Object(o)) => {
            for (k, v) in o {
                let merged = match b.remove(&k) {
                    Some(old @ Value::Object(_)) if v.is_object() => merge(old, v),
                    _ => v,
                };
                b.insert(k, merged);
            }
            Value::Object(b)
        }
        (_, over) => over,
    }
}

/// Значення JSON так, як його дає `[string]` PowerShell після ConvertFrom-Json. Об'єкт — текст `@{…}`,
/// що ніколи не є версією.
pub fn ps_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Null => String::new(),
        serde_json::Value::Bool(b) => if *b { "True" } else { "False" }.to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Array(items) => items.iter().map(ps_string).collect::<Vec<_>>().join(" "),
        serde_json::Value::Object(_) => "@{}".to_string(),
    }
}

/// JSON без коментарів `//` (до кінця рядка) і `/* */` поза рядковими літералами; коментар стає пробілом.
pub fn strip_json_comments(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut in_string = false;
    while i < c.len() {
        let ch = c[i];
        if in_string {
            out.push(ch);
            if ch == '\\' && i + 1 < c.len() {
                out.push(c[i + 1]);
                i += 2;
                continue;
            }
            if ch == '"' {
                in_string = false;
            }
            i += 1;
        } else if ch == '"' {
            in_string = true;
            out.push(ch);
            i += 1;
        } else if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
            out.push(' ');
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            i += 2;
            while i < c.len() && !(c[i] == '*' && c.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i += 2;
            out.push(' ');
        } else {
            out.push(ch);
            i += 1;
        }
    }
    out
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layers_merge_objects_and_replace_the_rest() {
        let low = lower_keys(serde_json::json!({ "PR": { "Base": "main", "x": 1 }, "list": [1, 2] }));
        let high = lower_keys(serde_json::json!({ "pr": { "base": "develop" }, "list": [3] }));
        let merged = merge(low, high);
        let profile = Profile { data: merged };
        assert_eq!(profile.value("pr.base"), Some(&Value::String("develop".into())));
        assert_eq!(profile.value("pr.x"), Some(&Value::from(1)));
        assert_eq!(profile.value("list"), Some(&serde_json::json!([3])));
        assert_eq!(profile.value("pr.base.deeper"), None);
    }

    #[test]
    fn namespace_section_replaces_whole_top_section() {
        // v8storagekit.tests без levels: рівні Linux верхнього tests НЕ просочуються (заміна, не злиття).
        let data = lower_keys(serde_json::json!({
            "tests": { "default": "gateway", "levels": { "gateway": { "command": ["npx", "vitest"] } } },
            "pr": { "base": "main", "afterMerge": [{ "paths": ["**"], "run": ["linux-cmd"] }] },
            "V8StorageKit": { "tests": { "default": "yaxunit" }, "version": "1.6.14" }
        }));
        let p = Profile { data: apply_namespace(data) };
        assert_eq!(p.value("tests.default"), Some(&Value::String("yaxunit".into())));
        assert_eq!(p.value("tests.levels"), None);
        assert_eq!(p.value("pr.base"), Some(&Value::String("main".into())), "секція без перекриття лишається");
        assert_eq!(p.value("version"), None, "version простору імен — не секція");
        // Контроль: без простору імен — верхні секції як були.
        let plain = Profile { data: apply_namespace(lower_keys(serde_json::json!({ "tests": { "levels": { "a": {} } } }))) };
        assert!(plain.value("tests.levels").is_some());
    }

    #[test]
    fn project_version_namespace_then_foreign_kit_version_only_from_1_0() {
        let v = |j: serde_json::Value| project_version(&j);
        assert_eq!(v(serde_json::json!({ "v8storagekit": { "version": "1.6.14" }, "kit": { "version": "0.11.5" } })), ProjectVersion::Set("1.6.14".into()));
        assert_eq!(v(serde_json::json!({ "kit": { "version": "1.6.12" } })), ProjectVersion::Set("1.6.12".into()));
        assert_eq!(v(serde_json::json!({ "kit": { "version": "0.4.2" } })), ProjectVersion::Unset, "версія agent-kit — не наша");
        assert_eq!(v(serde_json::json!({ "kit": { "version": "x" } })), ProjectVersion::Unset, "невалідний чужий — мовчки");
        assert_eq!(v(serde_json::json!({ "V8StorageKit": { "Version": "nope" } })), ProjectVersion::Bad);
        assert_eq!(v(serde_json::json!({})), ProjectVersion::Unset);
    }
}
