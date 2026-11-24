// Конфігурація kit: маніфест `v8storagekit.yaml`, його накладка `v8storagekit.local.yaml`
// і, далі, `v8project.yaml`, рядок підключення, база агента й префлайт. Еталон поведінки — PowerShell
// (`tools/lib/Yaml.psm1`, `Manifest.psm1`): ті самі правила й ті самі тексти помилок.
//
// Файли читаються деревом `serde_yaml::Value` і перевіряються вручну, без `#[derive(Deserialize)]`: так
// тексти помилок збігаються з PowerShell, а ключі й значення з файла не потрапляють у помилки `serde`.
// Помилка розбору YAML називає лише файл і місце (рядок, колонка) — текст `serde_yaml` цитує дані.
//
// Інваріант безпеки (ADR-0021 п. 5): розбір не панікує на жодному вході. Паніка в `kit.exe` друкує текст у stderr,
// а хук вклеює stderr у контекст сесії, тож лінти нижче забороняють усе, що панікує на даних із файлів.
// Те, що лінти не бачать (`str::split_at`, `String::insert/remove/drain/split_off`, `Vec::remove/insert/swap`,
// `assert!`), у цьому модулі на даних із файлів не вживається. Модуль не запускає зовнішніх процесів.
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::string_slice,
    clippy::panic,
    clippy::unreachable,
    clippy::todo,
    clippy::unimplemented,
    clippy::arithmetic_side_effects
)]

pub mod agent_base;
pub mod connection;
pub mod manifest;
pub mod overlay;
pub mod preflight;
pub mod v8project;
pub mod yaml;

pub use manifest::{is_server_storage_path, mask_storage_path};
pub use preflight::{
    Context, Finding, Level, Mode, PreflightStop, Source, Workspace, agent_base,
    agent_base_collisions, agent_base_missing_message, dev_base_overlaps,
    local_has_dev_infobase_line, preflight, select_sources, workspace_needs_agent_base,
};

use std::fmt;

/// Помилка конфігурації: текст призначений людині й не містить секретів — ключі й значення, що не пройшли
/// перевірку, у нього не потрапляють (ADR-0021 п. 5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(String);

impl ConfigError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        ConfigError(message.into())
    }

    pub fn message(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

/// Пароль. Без `Display`, `Debug` друкує лише ознаку «задано»; сирий текст дає тільки `expose` — його кличе
/// код, що передає значення далі (фаза 3), не форматування.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Self {
        Secret(value.into())
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Чи пароль порожній (порожній рядок — «не задано»); довжина й вид скаляра назовні не віддаються.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(задано)")
    }
}

/// Піддерево `infobases.origin.dbms` (облікові дані СУБД): ключі й значення — секрет, тому дерево непрозоре.
/// Без `Display`, `Debug` друкує лише ознаку «задано»; сирий вміст дає тільки `expose`.
#[derive(Clone, PartialEq)]
pub struct SecretTree(serde_yaml::Mapping);

impl SecretTree {
    pub fn new(tree: serde_yaml::Mapping) -> Self {
        SecretTree(tree)
    }

    pub fn expose(&self) -> &serde_yaml::Mapping {
        &self.0
    }
}

impl fmt::Debug for SecretTree {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecretTree(задано)")
    }
}

/// Сирий рядок підключення до інформаційної бази: може нести облікові дані (`Usr=`, `Pwd=`), тому той самий
/// режим, що в `Secret`.
#[derive(Clone, PartialEq, Eq)]
pub struct RawConnection(String);

impl RawConnection {
    pub fn new(value: impl Into<String>) -> Self {
        RawConnection(value.into())
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for RawConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RawConnection(задано)")
    }
}

/// Значення `truth: git`. Єдиний у модулі літерал `"git"` — слово словника, не програма: запобіжник
/// tests/git_guard.rs має для нього запис ALLOWED_LITERAL.
const TRUTH_GIT: &str = "git";

/// Словник `truth` — єдине місце, де він оголошений (як `$script:TruthValues`).
pub const TRUTH_VALUES: [&str; 4] = ["storage", "dump", "vendor", TRUTH_GIT];

/// Джерело істини джерела конфігурації. Порівняння з рядком — без регістру, як `-notcontains`/`switch`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Truth {
    Storage,
    Dump,
    Vendor,
    Git,
}

impl Truth {
    pub fn parse(text: &str) -> Option<Truth> {
        let lower = text.to_lowercase();
        match lower.as_str() {
            "storage" => Some(Truth::Storage),
            "dump" => Some(Truth::Dump),
            "vendor" => Some(Truth::Vendor),
            TRUTH_GIT => Some(Truth::Git),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Truth::Storage => "storage",
            Truth::Dump => "dump",
            Truth::Vendor => "vendor",
            Truth::Git => TRUTH_GIT,
        }
    }
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

    // Інваріант (ADR-0021 п. 5): пароль і сирий рядок підключення не друкуються ні `Debug`, ні (відсутнім) `Display`.
    #[test]
    fn secrets_debug_prints_only_the_flag() {
        let marker = "МАРКЕР-пароль;=\"ʼ";
        let secret = format!("{:?}", Secret::new(marker));
        let conn = format!("{:?}", RawConnection::new(marker));
        assert!(
            !secret.contains(marker) && secret.contains("задано"),
            "{secret}"
        );
        assert!(!conn.contains(marker) && conn.contains("задано"), "{conn}");
    }

    #[test]
    fn truth_is_case_insensitive_and_closed() {
        assert_eq!(Truth::parse("Storage"), Some(Truth::Storage));
        assert_eq!(Truth::parse("VENDOR"), Some(Truth::Vendor));
        assert_eq!(Truth::parse("storage "), None);
        assert_eq!(TRUTH_VALUES.len(), 4);
    }
}
