// `v8project.yaml` і `v8project.local.yaml` Уніки — як `Read-V8Project`, `Read-V8ProjectLocalInfobase`,
// `Resolve-V8AgentInfobase` і `Get-V8ProjectConfigProblems` (tools/lib/V8Project.psm1): ті самі правила й тексти.
//
// Kit читає лише те, від чого залежить: source-set-и (name/type/path), `workPath`, `providers` (як дерево) і
// `infobases.origin` у локальному файлі. Секрети — типом: пароль — `Secret`, рядок підключення — `RawConnection`,
// піддерево `dbms` — непрозорий `SecretTree` (спека §6). Усі рядкові поля переводяться тією самою `ps_string`,
// що й решта конфігурації (рішення 7 плану), — пароль не має окремого шляху.

use super::manifest::is_blank;
use super::yaml::{Emptiness, assert_scalar, contains, eq_ci, get, get_string, keys, read_yaml, read_yaml_or_none};
use super::{ConfigError, RawConnection, Secret, SecretTree};
use serde_yaml::{Mapping, Value};
use std::path::{Path, PathBuf};

/// Типи source-set, які kit уміє співставити з маніфестом.
pub const KNOWN_SOURCE_SET_TYPES: [&str; 3] = ["CONFIGURATION", "EXTENSION", "EXTERNAL_DATA_PROCESSORS"];

pub const LOCAL_FILE_NAME: &str = "v8project.local.yaml";
pub const PROJECT_FILE_NAME: &str = "v8project.yaml";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceSet {
    pub name: String,
    pub type_name: String,
    /// Шлях відносно теки конфіга: `/` замість `\`, без кінцевого `/`.
    pub path: String,
    pub full_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq)]
pub struct V8Project {
    pub path: PathBuf,
    pub directory: PathBuf,
    pub work_path: String,
    pub providers: Option<Mapping>,
    pub source_sets: Vec<SourceSet>,
}

/// `infobases.origin` з `v8project.local.yaml`.
#[derive(Debug, Clone, PartialEq)]
pub struct LocalInfobase {
    pub connection: RawConnection,
    pub user: String,
    pub password: Secret,
    pub dbms: Option<SecretTree>,
}

/// База агента так, як її бачить Уніка: `infobases.origin` у `v8project.local.yaml`, і лише там.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentInfobase {
    pub connection: RawConnection,
    /// Файл-джерело (`<тека>\v8project.local.yaml`).
    pub origin: String,
    pub user: String,
    pub password: Secret,
    pub dbms: Option<SecretTree>,
}

/// `[IO.Path]::GetFullPath` — лексично (без розкриття посилань).
pub(crate) fn full_path(path: &str) -> Result<String, ConfigError> {
    std::path::absolute(path)
        .map(|p| p.to_string_lossy().into_owned())
        .map_err(|_| ConfigError::new("Шлях не розбирається."))
}

/// `Join-Path`: розділювач рівно один між частинами.
pub(crate) fn join_ps(dir: &str, rel: &str) -> String {
    format!("{}\\{}", dir.trim_end_matches(['\\', '/']), rel.trim_start_matches(['\\', '/']))
}

fn project_dir(full: &str) -> String {
    Path::new(full).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}

pub fn read_v8project(path: &Path) -> Result<V8Project, ConfigError> {
    let shown = path.display().to_string();
    let data = read_yaml(path, Emptiness::Required)?;
    let full = full_path(&path.to_string_lossy())?;
    let dir = project_dir(&full);

    let Some(raw_sets) = get(&data, "source-set") else {
        return Err(ConfigError::new(format!(
            "У {shown} немає розділу source-set: — без нього Unica не бачить воркспейсу, а kit не має чого звірити з маніфестом."
        )));
    };
    let items = match raw_sets {
        Value::Sequence(items) if !items.is_empty() => items,
        _ => return Err(ConfigError::new(format!("Розділ source-set: у {shown} має бути непорожнім списком."))),
    };

    let mut sets: Vec<SourceSet> = Vec::new();
    for item in items {
        let Value::Mapping(item) = item else {
            return Err(ConfigError::new(format!("Елемент source-set у {shown} не є мапою з ключами name/type/path.")));
        };
        for key in ["name", "type", "path"] {
            assert_scalar(item, key, &format!("У source-set файлу {shown}"), key)?;
            if !contains(item, key) || is_blank(&get_string(item, key)) {
                return Err(ConfigError::new(format!("У source-set файлу {shown} бракує ключа '{key}'.")));
            }
        }
        let name = get_string(item, "name");
        let type_name = get_string(item, "type");
        let rel = get_string(item, "path");

        if !KNOWN_SOURCE_SET_TYPES.iter().any(|k| eq_ci(k, &type_name)) {
            return Err(ConfigError::new(format!(
                "source-set '{name}' у {shown} має невідомий type '{type_name}'. Kit знає: {}.",
                KNOWN_SOURCE_SET_TYPES.join(", ")
            )));
        }
        if sets.iter().any(|s| eq_ci(&s.name, &name)) {
            return Err(ConfigError::new(format!("source-set '{name}' оголошено в {shown} двічі.")));
        }
        let full_set = full_path(&join_ps(&dir, &rel))?;
        sets.push(SourceSet {
            name,
            type_name,
            path: rel.replace('\\', "/").trim_end_matches('/').to_string(),
            full_path: PathBuf::from(full_set),
        });
    }

    assert_scalar(&data, "workPath", &format!("У {shown}"), "workPath")?;
    let work_path = match get(&data, "workPath") {
        Some(_) if !is_blank(&get_string(&data, "workPath")) => get_string(&data, "workPath"),
        _ => "build".to_string(),
    };
    let providers = match get(&data, "providers") {
        Some(Value::Mapping(m)) => Some(m.clone()),
        _ => None,
    };
    Ok(V8Project { path: PathBuf::from(full), directory: PathBuf::from(dir), work_path, providers, source_sets: sets })
}

/// `infobases.origin` з `v8project.local.yaml`; `None` — бази не налаштовано на цій машині (файла немає, немає
/// `origin`, він не мапа чи без `connection`).
pub fn read_local_infobase(path: &Path) -> Result<Option<LocalInfobase>, ConfigError> {
    if !path.is_file() {
        return Ok(None);
    }
    let data = read_yaml(path, Emptiness::Allowed)?;
    let Some(Value::Mapping(ibs)) = get(&data, "infobases") else {
        return Ok(None);
    };
    let Some(Value::Mapping(origin)) = get(ibs, "origin") else {
        return Ok(None);
    };
    let local_where = format!("У {}", path.display());
    for field in ["connection", "user", "password"] {
        assert_scalar(origin, field, &local_where, &format!("infobases.origin.{field}"))?;
    }
    let connection = get_string(origin, "connection");
    if is_blank(&connection) {
        return Ok(None);
    }
    let dbms = match get(origin, "dbms") {
        Some(Value::Mapping(m)) => Some(SecretTree::new(m.clone())),
        _ => None,
    };
    Ok(Some(LocalInfobase {
        connection: RawConnection::new(connection),
        user: get_string(origin, "user"),
        password: Secret::new(get_string(origin, "password")),
        dbms,
    }))
}

pub fn resolve_agent_infobase(project: &V8Project) -> Result<Option<AgentInfobase>, ConfigError> {
    let local = join_ps(&project.directory.to_string_lossy(), LOCAL_FILE_NAME);
    Ok(read_local_infobase(Path::new(&local))?.map(|o| AgentInfobase {
        connection: o.connection,
        origin: local,
        user: o.user,
        password: o.password,
        dbms: o.dbms,
    }))
}

/// Знахідки конфігу воркспейсу, з яким kit не працює (чи працює не тим виконавцем), — кожна з рецептом.
/// Політика на обох файлах: `v8project.yaml` (закомічений) і `v8project.local.yaml`.
pub fn config_problems(directory: &Path) -> Result<Vec<String>, ConfigError> {
    let dir = directory.to_string_lossy().into_owned();
    let local_path = join_ps(&dir, LOCAL_FILE_NAME);
    let files = [(join_ps(&dir, PROJECT_FILE_NAME), true), (local_path.clone(), false)];
    let mut problems = Vec::new();
    for (p, committed) in files {
        if !Path::new(&p).is_file() {
            continue;
        }
        // `$null` (порожній чи суто коментований файл) PowerShell пропускає: `if ($null -eq $data) { continue }`.
        let Some(data) = read_yaml_or_none(Path::new(&p))? else {
            continue;
        };

        if contains(&data, "infobase") {
            problems.push(format!(
                "{p}: стара форма 'infobase:' — kit читає базу агента лише з infobases.origin у {local_path} (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: {{ origin: {{ connection: …, user: …, password: … }} }} у {local_path} і приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.6.0»)."
            ));
        }
        if let Some(infobases) = get(&data, "infobases") {
            if committed {
                problems.push(format!(
                    "{p}: infobases у закоміченому v8project.yaml — база агента машинна й може нести пароль. Перенесіть блок у {local_path} (гітігнорований)."
                ));
            } else if let Value::Mapping(map) = infobases {
                for name in keys(map) {
                    if !eq_ci(&name, "origin") {
                        problems.push(format!(
                            "{p}: infobases містить ключ, відмінний від origin (ім'я не друкується: у ключі може опинитись пароль; перевірте пробіл після ':' і форму 'ключ: значення') — Уніка обслуговує лише origin, і kit читає лише origin; інша назва означала б, що аудит перевіряє не ту базу. Перейменуйте на origin або приберіть."
                        ));
                    }
                }
                if let Some(origin) = get(map, "origin") {
                    let described = matches!(origin, Value::Mapping(o) if contains(o, "connection") && !is_blank(&get_string(o, "connection")));
                    if !described {
                        problems.push(format!(
                            "{p}: infobases.origin без connection — база агента оголошена, але не описана. Допишіть connection: 'File=build/ib' (файлова) або 'Srvr=…;Ref=…;' (серверна) — скіл v8storagekit:infobase-agent."
                        ));
                    }
                }
            } else {
                problems.push(format!(
                    "{p}: infobases має бути мапою з ключем origin (infobases: {{ origin: {{ connection: … }} }}) — інакше база агента тихо зникає. Виправте або приберіть infobases."
                ));
            }
        }
        if committed {
            let Some(Value::Mapping(providers)) = get(&data, "providers") else {
                problems.push(format!(
                    "{p}: немає providers — запис і завантаження бази агента мусить робити один виконавець (дефект раннера #459). Додайте: providers: {{ push: designer, pull: designer, download: designer }}."
                ));
                continue;
            };
            for op in ["push", "pull", "download"] {
                let scalar = !matches!(get(providers, op), Some(Value::Sequence(_) | Value::Mapping(_)));
                let v = if contains(providers, op) && scalar { get_string(providers, op) } else { String::new() };
                if !eq_ci(&v, "designer") {
                    let shown = if !scalar {
                        "не скаляр".to_string()
                    } else if v.is_empty() {
                        "відсутній".to_string()
                    } else {
                        format!("'{v}'")
                    };
                    problems.push(format!(
                        "{p}: providers.{op} — {shown}, потрібно designer (агентський режим раннера на Windows не заміряний, #429)."
                    ));
                }
            }
        }
    }
    Ok(problems)
}

/// Ознака: у `v8project.local.yaml` є рядок, що починається з `devInfobase:` (сирий текст, не YAML) — як
/// `-match '(?m)^\s*devInfobase\s*:'` у `check.psm1` (без регістру, пробіли довкола ключа дозволені).
pub fn local_has_dev_infobase_line(directory: &Path) -> bool {
    let local = join_ps(&directory.to_string_lossy(), LOCAL_FILE_NAME);
    let Ok(bytes) = std::fs::read(&local) else {
        return false;
    };
    let lossy = String::from_utf8_lossy(&bytes);
    // `Get-Content -Encoding UTF8`: BOM відкидається.
    let text = lossy.strip_prefix('\u{feff}').unwrap_or(&lossy).to_string();
    let lines: Vec<&str> = text.split('\n').collect();
    for (i, line) in lines.iter().enumerate() {
        let head = line.trim_start();
        let key: String = head.chars().take(11).collect::<String>().to_lowercase();
        if key != "devinfobase" {
            continue;
        }
        let tail: String = head.chars().skip(11).collect();
        if tail.trim().is_empty() {
            // `\s*` перед `:` може перейти на наступні рядки.
            let next = lines.iter().skip(i.saturating_add(1)).find(|l| !l.trim().is_empty());
            if next.is_some_and(|l| l.trim_start().starts_with(':')) {
                return true;
            }
        } else if tail.trim_start().starts_with(':') {
            return true;
        }
    }
    false
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("kit-v8p-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    const PROVIDERS: &str = "providers: { push: designer, pull: Designer, download: designer }\n";

    // `$null` (порожній чи суто коментований файл) PowerShell пропускає, а явна порожня мапа `{}` — перевіряє (знахідка
    // про providers): паритет із `Get-V8ProjectConfigProblems` (задача 4).
    #[test]
    fn config_problems_skips_null_file_but_checks_empty_map() {
        let d = tmp("nullfile");
        let p = d.join("v8project.yaml");
        std::fs::write(&p, "# лише коментар
").unwrap();
        assert!(config_problems(&d).unwrap().is_empty());
        std::fs::write(&p, "{}
").unwrap();
        assert!(config_problems(&d).unwrap()[0].contains("немає providers"));
    }

    #[test]
    fn reads_project_and_rejects_bad_shapes() {
        let d = tmp("read");
        let p = d.join("v8project.yaml");
        std::fs::write(&p, format!("{PROVIDERS}workPath: out\nsource-set:\n  - {{ name: cf, type: configuration, path: 'cf\\src\\' }}\n  - {{ name: epf, type: EXTERNAL_DATA_PROCESSORS, path: epf }}\n")).unwrap();
        let v = read_v8project(&p).unwrap();
        assert_eq!(v.work_path, "out");
        assert_eq!(v.source_sets[0].path, "cf/src");
        assert!(v.source_sets[0].full_path.ends_with("cf\\src") || v.source_sets[0].full_path.ends_with("cf\\src\\"));
        assert!(v.providers.is_some());

        for (text, expect) in [
            ("a: 1\n", "немає розділу source-set"),
            ("source-set: []\n", "має бути непорожнім списком"),
            ("source-set: [x]\n", "не є мапою"),
            ("source-set: [{ name: a, type: cf }]\n", "бракує ключа 'path'"),
            ("source-set: [{ name: a, type: BAD, path: p }]\n", "невідомий type 'BAD'"),
            ("source-set: [{ name: a, type: EXTENSION, path: p }, { name: A, type: EXTENSION, path: q }]\n", "оголошено в"),
        ] {
            std::fs::write(&p, text).unwrap();
            let e = read_v8project(&p).unwrap_err();
            assert!(e.message().contains(expect), "{text}: {e}");
        }
    }

    // Інваріант §6: пароль і піддерево dbms не потрапляють у Debug; пароль іде через `ps_string` (число → текст).
    #[test]
    fn local_infobase_keeps_secrets_opaque() {
        let d = tmp("local");
        let marker = "СЕКРЕТ-маркер";
        let p = d.join(LOCAL_FILE_NAME);
        std::fs::write(&p, format!("infobases:\n  origin:\n    connection: 'File=build/ib'\n    user: u\n    password: 0123\n    dbms: {{ {marker}: {marker} }}\n")).unwrap();
        let o = read_local_infobase(&p).unwrap().unwrap();
        assert_eq!(o.password.expose(), "0123");
        assert!(o.dbms.is_some());
        assert!(!format!("{o:?}").contains(marker) && !format!("{o:?}").contains("0123") && !format!("{o:?}").contains("build/ib"));

        for text in ["", "infobases: 1\n", "infobases: { other: {} }\n", "infobases: { origin: x }\n", "infobases: { origin: { connection: ' ' } }\n"] {
            std::fs::write(&p, text).unwrap();
            assert!(read_local_infobase(&p).unwrap().is_none(), "{text}");
        }
        assert!(read_local_infobase(&d.join("немає.yaml")).unwrap().is_none());
    }

    #[test]
    fn policy_covers_both_files() {
        let d = tmp("policy");
        let committed = d.join(PROJECT_FILE_NAME);
        std::fs::write(&committed, "infobase: x\ninfobases: { origin: { connection: c } }\nsource-set: []\nproviders: { push: designer, pull: x }\n").unwrap();
        std::fs::write(d.join(LOCAL_FILE_NAME), "infobase: y\ninfobases: { СЕКРЕТ: 1, origin: { user: u } }\n").unwrap();
        let problems = config_problems(&d).unwrap();
        let all = problems.join("\n");
        assert!(all.contains("стара форма 'infobase:'") && all.contains("infobases у закоміченому"), "{all}");
        assert!(all.contains("providers.pull — 'x'") && all.contains("providers.download — відсутній"), "{all}");
        assert!(all.contains("ключ, відмінний від origin") && all.contains("infobases.origin без connection"), "{all}");
        assert!(!all.contains("СЕКРЕТ"), "ім'я ключа надрукували: {all}");
        assert_eq!(problems.len(), 7);
        // Файла немає — знахідок немає; чистий конфіг — теж.
        std::fs::write(&committed, format!("{PROVIDERS}source-set: []\n")).unwrap();
        std::fs::remove_file(d.join(LOCAL_FILE_NAME)).unwrap();
        assert!(config_problems(&d).unwrap().is_empty());
    }

    #[test]
    fn dev_infobase_line_is_raw_text_match() {
        let d = tmp("devib");
        let p = d.join(LOCAL_FILE_NAME);
        for (text, expect) in [("devInfobase: x\n", true), ("a: 1\n  DEVINFOBASE : x\n", true), ("a: 1\n# devInfobase: x\n", false), ("xdevInfobase: 1\n", false), ("\u{feff}devInfobase: x\n", true)] {
            std::fs::write(&p, text).unwrap();
            assert_eq!(local_has_dev_infobase_line(&d), expect, "{text:?}");
        }
        assert!(!local_has_dev_infobase_line(&d.join("немає")));
    }
}
