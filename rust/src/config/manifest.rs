// Маніфест `v8storagekit.yaml` — як `Read-KitManifest` (tools/lib/Manifest.psm1): ті самі правила й ті самі
// тексти. Звірка ключів `sources` з `name:` source-set-ів — робота префлайту, не цього модуля.
//
// Ім'я невідомого ключа й запис без значення не друкуються ніколи (спека §6): у flow-мапі запис без `:`
// стає ключем цілком, і секрет опиняється в ньому. Друкуємо шлях до мапи, дозволені ключі й підказку.

use super::yaml::{
    Emptiness, assert_scalar, contains, eq_ci, get, get_string, keys, ps_string, read_yaml,
};
use super::{ConfigError, TRUTH_VALUES, Truth};
use serde_yaml::{Mapping, Value};
use std::path::{Path, PathBuf};

pub const DEFAULT_STORAGE_USER: &str = "gitbot";
pub const DEFAULT_MAIN_BRANCH: &str = "main";

const HINT: &str = "Перевірте пробіл після ':' і форму 'ключ: значення'.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProductKind {
    Product,
    Client,
}

impl ProductKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProductKind::Product => "product",
            ProductKind::Client => "client",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestSource {
    pub key: String,
    pub truth: Truth,
    /// `truth` у написанні файла (регістр зберігається, як `Truth = $truth` у PowerShell).
    pub truth_text: String,
    pub storage_path: Option<String>,
    pub storage_user: Option<String>,
    pub dump_from: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestWorkspace {
    pub path: String,
    pub sources: Vec<ManifestSource>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub path: PathBuf,
    pub version: u32,
    pub kind: ProductKind,
    pub label: String,
    pub main_branch: String,
    pub workspaces: Vec<ManifestWorkspace>,
    /// У файлі був старий ключ `kitVersion` (дозволений лише в режимі `check`).
    pub has_kit_version: bool,
}

/// `Assert-KitMapKeys` для значення, що мусить бути мапою.
pub(crate) fn assert_map_keys<'a>(
    value: &'a Value,
    allowed: &[&str],
    required: &[&str],
    where_: &str,
) -> Result<&'a Mapping, ConfigError> {
    let Value::Mapping(map) = value else {
        return Err(ConfigError::new(format!(
            "{where_} має бути мапою (ключ: значення)."
        )));
    };
    assert_keys(map, allowed, required, where_)?;
    Ok(map)
}

/// Мапа має рівно дозволені ключі й усі обов'язкові (ключі — без регістру).
pub(crate) fn assert_keys(
    map: &Mapping,
    allowed: &[&str],
    required: &[&str],
    where_: &str,
) -> Result<(), ConfigError> {
    for r in required {
        if !contains(map, r) {
            return Err(ConfigError::new(format!(
                "{where_} — бракує обов'язкового ключа '{r}'."
            )));
        }
    }
    for k in keys(map) {
        if !allowed.iter().any(|a| eq_ci(a, &k)) {
            return Err(ConfigError::new(format!(
                "{where_} — містить невідомий ключ (ім'я не друкується). Дозволені: {}. {HINT}",
                allowed.join(", ")
            )));
        }
    }
    Ok(())
}

/// Запис мапи накладки має значення; запис без значення називається номером, а не іменем.
pub(crate) fn assert_entry_has_value(
    value: &Value,
    index: usize,
    where_: &str,
) -> Result<(), ConfigError> {
    if value.is_null() {
        return Err(ConfigError::new(format!(
            "{where_} — запис №{index} без значення (ім'я не друкується). {HINT}"
        )));
    }
    Ok(())
}

/// Шлях сховища має форму шляху сховища: `X:\…`, `\\…`, `tcp://…`, `http://…`, `https://…`. Правило-властивість:
/// пароль, що потрапив у поле шляху через друкарську помилку, формі не відповідає й відхиляється без друку.
pub(crate) fn assert_storage_path_form(path: &str, where_: &str) -> Result<(), ConfigError> {
    let lower = path.to_lowercase();
    let mut chars = path.chars();
    let drive = matches!((chars.next(), chars.next(), chars.next()), (Some(a), Some(':'), Some('\\')) if a.is_ascii_alphabetic());
    let ok = drive
        || path.starts_with("\\\\")
        || ["tcp://", "http://", "https://"]
            .iter()
            .any(|p| lower.starts_with(p));
    if ok {
        return Ok(());
    }
    Err(ConfigError::new(format!(
        "{where_} — шлях сховища має форму абсолютного шляху з диском (X:\\…), UNC (\\\\сервер\\…) або адреси tcp://…, http://…, https://… (значення не друкується). {HINT}"
    )))
}

pub(crate) fn is_blank(s: &str) -> bool {
    s.trim().is_empty()
}

/// Читає й валідує маніфест. `allow_kit_version` — режим `check`: `kitVersion` не зупиняє, а лише виставляє
/// `has_kit_version`; решта маніфесту розбирається як завжди.
pub fn read_manifest(path: &Path, allow_kit_version: bool) -> Result<Manifest, ConfigError> {
    let mut m = read_yaml(path, Emptiness::Required)?;
    let where_ = format!("Маніфест {}", path.display());

    let mut has_kit_version = false;
    if contains(&m, "kitVersion") {
        if !allow_kit_version {
            return Err(ConfigError::new(format!(
                "{where_} — поле kitVersion прибрано: версію проєкту тримає .agents/kit.profile.json (v8storagekit.version); видаліть рядок і запустіть /v8storagekit:onboarding."
            )));
        }
        has_kit_version = true;
        // `-cne`: з регістром — ключ `KitVersion` лишається й далі відхиляється як невідомий.
        let mut rest = Mapping::new();
        for (k, v) in &m {
            if k.as_str() != Some("kitVersion") {
                rest.insert(k.clone(), v.clone());
            }
        }
        m = rest;
    }
    assert_keys(
        &m,
        &["version", "product", "client", "mainBranch", "workspaces"],
        &["version", "workspaces"],
        &where_,
    )?;

    assert_scalar(&m, "version", &where_, "version")?;
    let version = get_string(&m, "version");
    if version != "1" {
        return Err(ConfigError::new(format!(
            "{where_} — version: {version} не підтримується; kit знає лише version: 1."
        )));
    }

    let has_product = contains(&m, "product");
    let has_client = contains(&m, "client");
    if has_product == has_client {
        let state = if has_product {
            "вказано обидва"
        } else {
            "не вказано жодного"
        };
        return Err(ConfigError::new(format!(
            "{where_} — має бути рівно один із ключів product: або client: ({state})."
        )));
    }
    let label_key = if has_product { "product" } else { "client" };
    assert_scalar(&m, label_key, &where_, label_key)?;
    let label = get_string(&m, label_key);
    if is_blank(&label) {
        return Err(ConfigError::new(format!(
            "{where_} — значення product:/client: порожнє."
        )));
    }

    let mut main_branch = DEFAULT_MAIN_BRANCH.to_string();
    if contains(&m, "mainBranch") {
        assert_scalar(&m, "mainBranch", &where_, "mainBranch")?;
        main_branch = get_string(&m, "mainBranch");
        if is_blank(&main_branch)
            || main_branch.chars().any(char::is_whitespace)
            || main_branch.starts_with("storage/")
        {
            return Err(ConfigError::new(format!(
                "{where_} — mainBranch: '{main_branch}' не схоже на ім'я гілки або лежить у просторі storage/, зарезервованому для дзеркал сховищ."
            )));
        }
    }

    let Some(Value::Sequence(ws_raw)) = get(&m, "workspaces") else {
        return Err(ConfigError::new(format!(
            "{where_} — workspaces: має бути непорожнім списком."
        )));
    };
    if ws_raw.is_empty() {
        return Err(ConfigError::new(format!(
            "{where_} — workspaces: має бути непорожнім списком."
        )));
    }

    let mut workspaces = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for ws in ws_raw {
        let ws_map = assert_map_keys(
            ws,
            &["path", "sources"],
            &["path", "sources"],
            &format!("{where_}, елемент workspaces"),
        )?;
        assert_scalar(
            ws_map,
            "path",
            &format!("{where_}, елемент workspaces"),
            "path",
        )?;
        let ws_path = get_string(ws_map, "path").trim().to_string();
        if ws_path.is_empty() || ws_path.contains(['\\', '/']) || ws_path == "." || ws_path == ".."
        {
            return Err(ConfigError::new(format!(
                "{where_} — workspaces[].path '{ws_path}' має бути ім'ям теки безпосередньо в корені репозиторію (без роздільників)."
            )));
        }
        if seen.iter().any(|s| eq_ci(s, &ws_path)) {
            return Err(ConfigError::new(format!(
                "{where_} — воркспейс '{ws_path}' оголошено двічі."
            )));
        }
        seen.push(ws_path.clone());

        let sources_err = || {
            ConfigError::new(format!(
                "{where_}, воркспейс '{ws_path}' — sources: має бути непорожньою мапою «ключ джерела → опис»."
            ))
        };
        let Some(Value::Mapping(src_raw)) = get(ws_map, "sources") else {
            return Err(sources_err());
        };
        if src_raw.is_empty() {
            return Err(sources_err());
        }

        let mut sources = Vec::new();
        for (idx, (key_value, src)) in src_raw.iter().enumerate() {
            // Спершу значення, потім ім'я: запис без значення — це ключ без `:`, і секрет міг опинитись у ньому.
            assert_entry_has_value(
                src,
                idx.saturating_add(1),
                &format!("{where_}, воркспейс '{ws_path}', sources"),
            )?;
            let key = ps_string(key_value);
            let swhere = format!("{where_}, воркспейс '{ws_path}', джерело '{key}'");
            let src_map = assert_map_keys(src, &["truth", "storage", "dump"], &["truth"], &swhere)?;
            sources.push(read_source(src_map, key, &swhere)?);
        }
        workspaces.push(ManifestWorkspace {
            path: ws_path,
            sources,
        });
    }

    Ok(Manifest {
        path: std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf()),
        version: 1,
        kind: if has_product {
            ProductKind::Product
        } else {
            ProductKind::Client
        },
        label,
        main_branch,
        workspaces,
        has_kit_version,
    })
}

fn read_source(src: &Mapping, key: String, swhere: &str) -> Result<ManifestSource, ConfigError> {
    assert_scalar(src, "truth", swhere, "truth")?;
    let truth_text = get_string(src, "truth");
    let Some(truth) = Truth::parse(&truth_text) else {
        return Err(ConfigError::new(format!(
            "{swhere} — truth: '{truth_text}' невідомий. Дозволені: {}.",
            TRUTH_VALUES.join(", ")
        )));
    };
    let (mut storage_path, mut storage_user, mut dump_from) = (None, None, None);
    match truth {
        Truth::Storage => {
            let Some(storage) = get(src, "storage") else {
                return Err(ConfigError::new(format!(
                    "{swhere} — truth: storage потребує блоку storage: {{ path: … }}."
                )));
            };
            if contains(src, "dump") {
                return Err(ConfigError::new(format!(
                    "{swhere} — truth: storage не поєднується з dump:."
                )));
            }
            let st = assert_map_keys(
                storage,
                &["path", "user"],
                &["path"],
                &format!("{swhere}, storage"),
            )?;
            assert_scalar(st, "path", &format!("{swhere}, storage"), "path")?;
            assert_scalar(st, "user", &format!("{swhere}, storage"), "user")?;
            let path = get_string(st, "path");
            if is_blank(&path) {
                return Err(ConfigError::new(format!(
                    "{swhere} — storage.path порожній."
                )));
            }
            assert_storage_path_form(&path, &format!("{swhere}, storage.path"))?;
            let user = get_string(st, "user");
            storage_user = Some(if contains(st, "user") && !is_blank(&user) {
                user
            } else {
                DEFAULT_STORAGE_USER.to_string()
            });
            storage_path = Some(path);
        }
        Truth::Dump | Truth::Vendor => {
            let Some(dump) = get(src, "dump") else {
                return Err(ConfigError::new(format!(
                    "{swhere} — truth: {truth_text} потребує блоку dump: {{ from: <ключ у infobases: накладки> }}."
                )));
            };
            if contains(src, "storage") {
                return Err(ConfigError::new(format!(
                    "{swhere} — truth: {truth_text} не поєднується зі storage:."
                )));
            }
            let d = assert_map_keys(dump, &["from"], &["from"], &format!("{swhere}, dump"))?;
            assert_scalar(d, "from", &format!("{swhere}, dump"), "from")?;
            let from = get_string(d, "from");
            if is_blank(&from) {
                return Err(ConfigError::new(format!("{swhere} — dump.from порожній.")));
            }
            dump_from = Some(from);
        }
        Truth::Git => {
            if contains(src, "storage") || contains(src, "dump") {
                return Err(ConfigError::new(format!(
                    "{swhere} — truth: git означає, що зовнішнього джерела немає: ні storage:, ні dump: тут не буває."
                )));
            }
        }
    }
    Ok(ManifestSource {
        key,
        truth,
        truth_text,
        storage_path,
        storage_user,
        dump_from,
    })
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

    fn read(tag: &str, text: &str, allow: bool) -> Result<Manifest, ConfigError> {
        let d = std::env::temp_dir().join(format!("kit-manifest-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("v8storagekit.yaml");
        std::fs::write(&p, text).unwrap();
        read_manifest(&p, allow)
    }

    const GOOD: &str = "version: 1\nproduct: УНФ\nworkspaces:\n  - path: main\n    sources:\n      cfg: { truth: storage, storage: { path: 'C:\\st' } }\n      ext: { truth: Vendor, dump: { from: devUNF } }\n      git1: { truth: git }\n";

    #[test]
    fn reads_valid_manifest_in_file_order() {
        let m = read("good", GOOD, false).unwrap();
        assert_eq!(
            (
                m.kind,
                m.label.as_str(),
                m.main_branch.as_str(),
                m.has_kit_version
            ),
            (ProductKind::Product, "УНФ", "main", false)
        );
        let s = &m.workspaces[0].sources;
        assert_eq!(
            s.iter().map(|x| x.key.as_str()).collect::<Vec<_>>(),
            ["cfg", "ext", "git1"]
        );
        assert_eq!(
            (s[0].storage_user.as_deref(), s[0].storage_path.as_deref()),
            (Some("gitbot"), Some("C:\\st"))
        );
        assert_eq!(
            (
                s[1].truth,
                s[1].truth_text.as_str(),
                s[1].dump_from.as_deref()
            ),
            (Truth::Vendor, "Vendor", Some("devUNF"))
        );
    }

    // kitVersion: у суворому режимі — помилка з рецептом, у check — ознака в типі, решта розбирається.
    #[test]
    fn kit_version_depends_on_mode() {
        let text = format!("kitVersion: 1.2.3\n{GOOD}");
        let e = read("kv-strict", &text, false).unwrap_err();
        assert!(
            e.message().contains("поле kitVersion прибрано")
                && e.message().contains("/v8storagekit:onboarding"),
            "{e}"
        );
        assert!(read("kv-check", &text, true).unwrap().has_kit_version);
    }

    // Інваріант §6: невідомий ключ, запис без значення й шлях не тієї форми не друкуються; тексти — як у PowerShell.
    #[test]
    fn rejected_input_is_not_echoed_and_texts_match_powershell() {
        let marker = "СЕКРЕТ-маркер";
        let unknown = format!(
            "version: 1\nproduct: p\n{marker}: x\nworkspaces: [{{path: a, sources: {{k: {{truth: git}}}}}}]\n"
        );
        let e = read("unknown", &unknown, false).unwrap_err();
        assert!(!e.message().contains(marker), "{e}");
        assert!(e.message().ends_with(
            "— містить невідомий ключ (ім'я не друкується). Дозволені: version, product, client, mainBranch, workspaces. Перевірте пробіл після ':' і форму 'ключ: значення'."
        ), "{e}");

        let bad_path = format!(
            "version: 1\nproduct: p\nworkspaces: [{{path: a, sources: {{k: {{truth: storage, storage: {{path: '{marker}'}}}}}}}}]\n"
        );
        let e = read("badpath", &bad_path, false).unwrap_err();
        assert!(
            !e.message().contains(marker) && e.message().contains("шлях сховища має форму"),
            "{e}"
        );

        // Запис `sources` без значення: ім'я не друкується (номер запису); двійник — той самий запис зі значенням
        // друкується в тексті про значення (ім'я там уже перевірене розбором).
        let no_value = format!(
            "version: 1\nproduct: p\nworkspaces: [{{path: a, sources: {{k: {{truth: git}}, {marker}}}}}]\n"
        );
        let e = read("novalue", &no_value, false).unwrap_err();
        assert!(
            !e.message().contains(marker) && e.message().contains("запис №2 без значення"),
            "{e}"
        );
        let with_value = format!(
            "version: 1\nproduct: p\nworkspaces: [{{path: a, sources: {{k: {{truth: git}}, {marker}: git}}}}]\n"
        );
        assert!(
            read("withvalue", &with_value, false)
                .unwrap_err()
                .message()
                .contains(&format!("джерело '{marker}' має бути мапою"))
        );

        let both = "version: 1\nproduct: p\nclient: c\nworkspaces: []\n";
        assert!(
            read("both", both, false)
                .unwrap_err()
                .message()
                .ends_with("рівно один із ключів product: або client: (вказано обидва).")
        );
        let ver = "version: 2\nproduct: p\nworkspaces: []\n";
        assert!(
            read("ver", ver, false)
                .unwrap_err()
                .message()
                .ends_with("version: 2 не підтримується; kit знає лише version: 1.")
        );
    }
}
