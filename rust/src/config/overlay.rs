// Накладка `v8storagekit.local.yaml` — як `Read-KitLocalOverlay` (tools/lib/Manifest.psm1): гітігнорована
// накладка цієї машини з дев-базами, перевизначеннями сховищ і шаблоном `.dt` бази агента. Файла немає чи він
// порожній — законно: порожні таблиці. Запису накладки в B1 немає.
//
// Секрети — типом: пароль сховища — `Secret`, рядок підключення — `RawConnection` (без `Display`, `Debug`
// друкує лише ознаку «задано»). Ключі й значення, що не пройшли перевірку, у помилки не потрапляють (спека §6).

use super::manifest::{
    assert_entry_has_value, assert_keys, assert_map_keys, assert_storage_path_form, is_blank,
};
use super::yaml::{
    Emptiness, assert_scalar, contains, eq_ci, get, get_string, ps_string, read_yaml,
};
use super::{ConfigError, RawConnection, Secret};
use serde_yaml::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayInfobase {
    pub name: String,
    pub connection: RawConnection,
    pub user: String,
}

/// Запис `storages.<ключ джерела>`: шлях, користувач і пароль — кожне лише коли задано непорожнім.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayStorage {
    pub key: String,
    pub path: Option<String>,
    pub user: Option<String>,
    pub password: Option<Secret>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayWorkspace {
    pub path: String,
    pub agent_base_template: Option<String>,
}

/// Прочитана накладка; записи — у порядку файла, пошук за ім'ям — без регістру (хештаблиці PowerShell).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Overlay {
    pub path: PathBuf,
    pub infobases: Vec<OverlayInfobase>,
    pub storages: Vec<OverlayStorage>,
    pub workspaces: Vec<OverlayWorkspace>,
}

impl Overlay {
    pub fn infobase(&self, name: &str) -> Option<&OverlayInfobase> {
        self.infobases.iter().find(|i| eq_ci(&i.name, name))
    }

    pub fn storage(&self, key: &str) -> Option<&OverlayStorage> {
        self.storages.iter().find(|s| eq_ci(&s.key, key))
    }

    pub fn workspace(&self, path: &str) -> Option<&OverlayWorkspace> {
        self.workspaces.iter().find(|w| eq_ci(&w.path, path))
    }
}

pub fn read_overlay(path: &Path) -> Result<Overlay, ConfigError> {
    let mut result = Overlay {
        path: path.to_path_buf(),
        infobases: Vec::new(),
        storages: Vec::new(),
        workspaces: Vec::new(),
    };
    if !path.is_file() {
        return Ok(result);
    }
    let o = read_yaml(path, Emptiness::Allowed)?;
    let where_ = format!("Накладка {}", path.display());
    assert_keys(&o, &["infobases", "storages", "workspaces"], &[], &where_)?;

    if let Some(section) = get(&o, "infobases") {
        let Value::Mapping(map) = section else {
            return Err(ConfigError::new(format!(
                "{where_} — infobases: має бути мапою «ім'я → {{ connection, user }}»."
            )));
        };
        for (idx, (name, ib)) in map.iter().enumerate() {
            let name = ps_string(name);
            assert_entry_has_value(ib, idx.saturating_add(1), &format!("{where_}, infobases"))?;
            let ib = assert_map_keys(
                ib,
                &["connection", "user"],
                &["connection"],
                &format!("{where_}, infobases.{name}"),
            )?;
            let ib_where = format!("{where_}, infobases.{name}");
            assert_scalar(ib, "connection", &ib_where, "connection")?;
            assert_scalar(ib, "user", &ib_where, "user")?;
            let conn = get_string(ib, "connection");
            if is_blank(&conn) {
                return Err(ConfigError::new(format!(
                    "{where_} — infobases.{name}.connection порожній."
                )));
            }
            let user = if contains(ib, "user") {
                get_string(ib, "user")
            } else {
                String::new()
            };
            result.infobases.push(OverlayInfobase {
                name,
                connection: RawConnection::new(conn),
                user,
            });
        }
    }

    if let Some(section) = get(&o, "storages") {
        let Value::Mapping(map) = section else {
            return Err(ConfigError::new(format!(
                "{where_} — storages: має бути мапою «ключ джерела → шлях або {{ path, user, password }}»."
            )));
        };
        for (idx, (key, v)) in map.iter().enumerate() {
            let key = ps_string(key);
            assert_entry_has_value(v, idx.saturating_add(1), &format!("{where_}, storages"))?;
            let mut entry = OverlayStorage {
                key: key.clone(),
                path: None,
                user: None,
                password: None,
            };
            if let Value::Mapping(vm) = v {
                assert_keys(
                    vm,
                    &["path", "user", "password"],
                    &[],
                    &format!("{where_}, storages.{key}"),
                )?;
                if vm.is_empty() {
                    return Err(ConfigError::new(format!(
                        "{where_} — storages.{key} порожній: вкажіть path, user або password."
                    )));
                }
                for k in ["path", "user", "password"] {
                    assert_scalar(vm, k, &format!("{where_}, storages.{key}"), k)?;
                    let text = get_string(vm, k);
                    if is_blank(&text) {
                        continue;
                    }
                    match k {
                        "path" => {
                            assert_storage_path_form(
                                &text,
                                &format!("{where_}, storages.{key}.path"),
                            )?;
                            entry.path = Some(text);
                        }
                        "user" => entry.user = Some(text),
                        _ => entry.password = Some(Secret::new(text)),
                    }
                }
            } else {
                if matches!(v, Value::Sequence(_)) {
                    return Err(ConfigError::new(format!(
                        "{where_}, storages.{key} — має бути шляхом (скалярне значення) чи мапою {{ path, user, password }}, а не списком (значення не друкується)."
                    )));
                }
                let p = ps_string(v);
                if is_blank(&p) {
                    return Err(ConfigError::new(format!(
                        "{where_} — storages.{key} порожній."
                    )));
                }
                assert_storage_path_form(&p, &format!("{where_}, storages.{key}"))?;
                entry.path = Some(p);
            }
            result.storages.push(entry);
        }
    }

    if let Some(section) = get(&o, "workspaces") {
        let Value::Mapping(map) = section else {
            return Err(ConfigError::new(format!(
                "{where_} — workspaces: має бути мапою «тека воркспейсу → {{ agentBase }}»."
            )));
        };
        for (idx, (ws_path, ws)) in map.iter().enumerate() {
            let ws_path = ps_string(ws_path);
            assert_entry_has_value(ws, idx.saturating_add(1), &format!("{where_}, workspaces"))?;
            let ws = assert_map_keys(
                ws,
                &["agentBase"],
                &[],
                &format!("{where_}, workspaces.{ws_path}"),
            )?;
            let mut template = None;
            if let Some(base) = get(ws, "agentBase") {
                let base = assert_map_keys(
                    base,
                    &["template"],
                    &[],
                    &format!("{where_}, workspaces.{ws_path}.agentBase"),
                )?;
                if contains(base, "template") {
                    assert_scalar(
                        base,
                        "template",
                        &format!("{where_}, workspaces.{ws_path}.agentBase"),
                        "template",
                    )?;
                    let t = get_string(base, "template");
                    // Порожній шаблон — помилка конфігу, а не «шаблону немає»; значення в текст не потрапляє.
                    if is_blank(&t) {
                        return Err(ConfigError::new(format!(
                            "{where_} — workspaces.{ws_path}.agentBase.template порожній: вкажіть правильний шлях до .dt; рішення прибрати шаблон — за людиною."
                        )));
                    }
                    template = Some(t);
                }
            }
            result.workspaces.push(OverlayWorkspace {
                path: ws_path,
                agent_base_template: template,
            });
        }
    }

    Ok(result)
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

    fn read(tag: &str, text: &str) -> Result<Overlay, ConfigError> {
        let d = std::env::temp_dir().join(format!("kit-overlay-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("v8storagekit.local.yaml");
        std::fs::write(&p, text).unwrap();
        read_overlay(&p)
    }

    #[test]
    fn reads_overlay_and_missing_or_empty_file_is_empty() {
        let o = read(
            "ok",
            "infobases:\n  devUNF: { connection: 'File=C:\\b;', user: u }\nstorages:\n  cfg: { path: 'tcp://h/r', password: 12345 }\n  ext: 'C:\\x'\nworkspaces:\n  main: { agentBase: { template: 'C:\\t.dt' } }\n",
        )
        .unwrap();
        assert_eq!(o.infobase("DEVunf").unwrap().user, "u");
        let st = o.storage("cfg").unwrap();
        assert_eq!(st.path.as_deref(), Some("tcp://h/r"));
        assert_eq!(st.password.as_ref().unwrap().expose(), "12345");
        assert_eq!(o.storage("ext").unwrap().path.as_deref(), Some("C:\\x"));
        assert_eq!(
            o.workspace("main").unwrap().agent_base_template.as_deref(),
            Some("C:\\t.dt")
        );

        let none = read_overlay(Path::new("Z:/немає/накладки.yaml")).unwrap();
        assert!(
            none.infobases.is_empty() && none.storages.is_empty() && none.workspaces.is_empty()
        );
        assert!(read("empty", "# нічого\n").unwrap().infobases.is_empty());
    }

    // Інваріант §6: пароль і сирий рядок підключення не потрапляють у Debug накладки; відхилений ключ чи
    // значення (невідомий ключ, запис без значення, рядок замість мапи, неправильна форма шляху) — у помилку.
    #[test]
    fn secrets_and_rejected_input_stay_out_of_output() {
        let marker = "СЕКРЕТ-маркер";
        let ok = read("secret", &format!("infobases:\n  d: {{ connection: 'Srvr=a;Ref={marker};' }}\nstorages:\n  c: {{ path: 'C:\\s', password: '{marker}' }}\n")).unwrap();
        assert!(
            !format!("{ok:?}").contains(marker),
            "Debug накладки видав секрет"
        );

        let cases = [
            (
                "unknown-key",
                format!("storages:\n  c: {{ path: 'C:\\s', {marker}: 1 }}\n"),
            ),
            (
                "no-value",
                format!("storages: {{ c: {{ path: 'C:\\s' }}, {marker} }}\n"),
            ),
            ("string-for-map", format!("infobases:\n  d: {marker}\n")),
            ("bad-path", format!("storages:\n  c: {marker}\n")),
            (
                "bad-path-map",
                format!("storages:\n  c: {{ path: '{marker}' }}\n"),
            ),
            ("top-unknown", format!("{marker}: 1\n")),
        ];
        for (tag, text) in cases {
            let e = read(tag, &text).unwrap_err();
            assert!(
                !e.message().contains(marker) && !format!("{e:?}").contains(marker),
                "{tag}: {e}"
            );
        }
        let e = read("no-value-text", "storages: { c: { path: 'C:\\s' }, X }\n").unwrap_err();
        assert!(e.message().ends_with("storages — запис №2 без значення (ім'я не друкується). Перевірте пробіл після ':' і форму 'ключ: значення'."), "{e}");
    }
}
