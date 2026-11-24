// Рядок підключення до інформаційної бази — як `ConvertFrom-V8Connection`, `Get-V8CredentialsRecipe` і
// `Assert-V8SecretQuoteFree` (tools/lib/V8.psm1): ті самі правила й ті самі тексти.
//
// Відома відмінність від PowerShell (ADR-0014 п. 7, рішення 9 плану B1, рішення архітектора 2026-11-23).
// PowerShell друкує в тексті помилки ім'я ключа з сирого рядка, яким би воно не було (`Srvr=a;Ref=pa;ss=word` →
// «невідомий ключ 'ss'»): у ключі може опинитись секрет (пропущена `;` між елементами). Rust друкує ім'я лише
// з відомого переліку (`srvr`, `ref`, `file`, `usr`, `pwd`); інакше — без імені: «Рядок підключення містить
// невідомий ключ (ім'я не друкується). Дозволені ключі: Srvr, Ref, File.» Те саме для «'=' у значенні», «непарних
// лапок» і «порожнього значення» на невідомому ключі. Порядок перевірок — контракт: частини зліва направо, перша
// помилка зупиняє; `usr`/`pwd` відмовляють раніше за «невідомий ключ». Текст помилки ніколи не містить значень.

use super::{ConfigError, Secret};
use std::fmt;

/// Розібране підключення.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Connection {
    Server { server: String, reference: String },
    File { file: String },
}

/// Помилка розбору: текст без рядка підключення й значень його елементів. `credentials` — причина в ключах
/// `Usr`/`Pwd` (рецепт залежить від походження рядка, його дописує викликач — `credentials_recipe`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionError {
    message: String,
    credentials: bool,
}

impl ConnectionError {
    fn plain(message: impl Into<String>) -> Self {
        ConnectionError {
            message: message.into(),
            credentials: false,
        }
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn is_credentials(&self) -> bool {
        self.credentials
    }
}

impl fmt::Display for ConnectionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ConnectionError {}

/// Чий це рядок — для рецепта на `Usr`/`Pwd`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialsKind {
    Agent,
    Overlay,
}

const KNOWN_KEYS: [&str; 5] = ["srvr", "ref", "file", "usr", "pwd"];

/// `[^=]+=.*` без `(?s)`: ключ непорожній, значення не має `\n` (`.` .NET його не знаходить).
fn split_pair(piece: &str) -> Option<(&str, &str)> {
    let (key, val) = piece.split_once('=')?;
    if key.is_empty() || val.contains('\n') {
        return None;
    }
    Some((key, val))
}

/// Як `ключа 'X'` для відомого імені й без імені для невідомого.
fn key_label(key: &str, lkey: &str) -> String {
    if KNOWN_KEYS.contains(&lkey) {
        format!("ключа '{key}'")
    } else {
        "невідомого ключа (ім'я не друкується)".to_string()
    }
}

pub fn parse(raw: &super::RawConnection) -> Result<Connection, ConnectionError> {
    parse_str(raw.expose())
}

pub(crate) fn parse_str(connection: &str) -> Result<Connection, ConnectionError> {
    if connection.trim().is_empty() {
        return Err(ConnectionError::plain(
            "Рядок підключення до інформаційної бази порожній.",
        ));
    }
    let value = connection.trim();
    if !value.contains('=') {
        return Err(ConnectionError::plain(
            "Рядок підключення — голий шлях без ключа. Голий шлях більше не приймається: вкажіть File=<шлях>.",
        ));
    }

    let mut fields: Vec<(String, String)> = Vec::new();
    for part in value.split(';') {
        let piece = part.trim();
        if piece.is_empty() {
            continue;
        }
        let Some((key, val)) = split_pair(piece) else {
            return Err(ConnectionError::plain(
                "Рядок підключення містить елемент без '='.",
            ));
        };
        let key = key.trim();
        let mut val = val.trim().to_string();
        if key.contains('"') {
            return Err(ConnectionError::plain(
                "Рядок підключення містить лапки в імені ключа.",
            ));
        }
        let lkey = key.to_lowercase();
        if lkey == "usr" || lkey == "pwd" {
            return Err(ConnectionError {
                message: format!(
                    "Рядок підключення містить ключ '{key}' (логін чи пароль): логін і пароль не задаються в рядку підключення, у ньому лишаються лише Srvr=/Ref= або File=."
                ),
                credentials: true,
            });
        }
        if val.chars().count() >= 2 && val.starts_with('"') && val.ends_with('"') {
            val = val
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .unwrap_or("")
                .trim()
                .to_string();
        }
        let label = key_label(key, &lkey);
        if val.contains('"') {
            return Err(ConnectionError::plain(format!(
                "Рядок підключення містить непарні лапки у значенні {label}: лапки допускаються лише парою навколо всього значення (Srvr=\"SRV\";Ref=\"BASE\";). Шлях у File= не може містити ';' ні в лапках, ні без них."
            )));
        }
        if val.contains('=') {
            return Err(ConnectionError::plain(format!(
                "Рядок підключення містить '=' у значенні {label} — найімовірніше, пропущено ';' між елементами. Шлях у File= не може містити '=' (як і ';')."
            )));
        }
        if val.trim().is_empty() {
            return Err(ConnectionError::plain(format!(
                "Рядок підключення містить порожнє значення для {label}."
            )));
        }
        if !["srvr", "ref", "file"].contains(&lkey.as_str()) {
            return Err(ConnectionError::plain(
                "Рядок підключення містить невідомий ключ (ім'я не друкується). Дозволені ключі: Srvr, Ref, File.",
            ));
        }
        if fields.iter().any(|(k, _)| *k == lkey) {
            return Err(ConnectionError::plain(format!(
                "Рядок підключення містить ключ '{key}' двічі."
            )));
        }
        fields.push((lkey, val));
    }

    let field = |name: &str| {
        fields
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
    };
    let (srvr, reference, file) = (field("srvr"), field("ref"), field("file"));

    if srvr.is_some() && file.is_some() {
        return Err(ConnectionError::plain(
            "Рядок підключення містить одночасно Srvr= і File= — це два різні способи описати базу, разом вони суперечливі.",
        ));
    }
    if srvr.is_some() || reference.is_some() {
        return match (srvr, reference) {
            (Some(server), Some(reference)) => Ok(Connection::Server { server, reference }),
            (srvr, _) => {
                let missing = if srvr.is_some() { "Ref=" } else { "Srvr=" };
                Err(ConnectionError::plain(format!(
                    "Рядок підключення — серверна база потребує і Srvr=, і Ref= разом; бракує {missing}."
                )))
            }
        };
    }
    if let Some(file) = file {
        return Ok(Connection::File { file });
    }
    Err(ConnectionError::plain(
        "Рядок підключення не описує базу: очікується Srvr=<сервер>;Ref=<база>; або File=<шлях>.",
    ))
}

/// Рецепт для помилки з `Usr`/`Pwd` залежно від походження рядка; порожній, якщо причина інша.
pub fn credentials_recipe(error: &ConnectionError, kind: CredentialsKind) -> String {
    if !error.credentials {
        return String::new();
    }
    match kind {
        CredentialsKind::Agent => "Логін і пароль бази агента задаються ключами user і password в infobases.origin у v8project.local.yaml.".to_string(),
        CredentialsKind::Overlay => {
            "Логін дев-бази задається ключем user у її записі в infobases: накладки v8storagekit.local.yaml; пароль дев-бази kit не підтримує.".to_string()
        }
    }
}

/// Єдина перевірка пароля на подвійну лапку — і для пароля бази агента, і для пароля сховища. Помилка називає
/// лише `origin` (звідки пароль) і причину; значення в текст не потрапляє.
pub fn assert_secret_quote_free(value: &Secret, origin: &str) -> Result<(), ConfigError> {
    if value.expose().contains('"') {
        return Err(ConfigError::new(format!(
            "{origin} містить подвійну лапку — платформа не приймає її в /P \"…\" (і в /ConfigurationRepositoryP), а маска виводу (Hide-V8Secrets) обірвалась би на ній і показала б решту пароля. Змініть цей пароль."
        )));
    }
    Ok(())
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

    fn err(s: &str) -> ConnectionError {
        parse_str(s).unwrap_err()
    }

    #[test]
    fn parses_server_and_file_forms() {
        assert_eq!(
            parse_str(" Ref=\"B\" ; SRVR = s ;").unwrap(),
            Connection::Server {
                server: "s".into(),
                reference: "B".into()
            }
        );
        assert_eq!(
            parse_str("File=D:\\Bases\\X").unwrap(),
            Connection::File {
                file: "D:\\Bases\\X".into()
            }
        );
        assert!(err("C:\\x").message().contains("голий шлях"));
        assert!(err("Srvr=a").message().ends_with("бракує Ref=."));
        assert!(err("Srvr=a;Ref=b;File=c").message().contains("одночасно"));
        assert!(
            err("File=a;file=b")
                .message()
                .ends_with("ключ 'file' двічі.")
        );
    }

    // Відома відмінність (рішення 9): невідомий ключ — без імені, відомий — з іменем; порядок перевірок — контракт.
    #[test]
    fn unknown_key_is_never_printed_and_order_is_contract() {
        let marker = "СЕКРЕТ-маркер";
        let unknown = [
            format!("Srvr=a;Ref=pa;{marker}=word"),
            format!("Srvr=a;Ref=pa;{marker}=w=ord"),
            format!("Srvr=a;Ref=pa;{marker}=\"w\"o\""),
            format!("Srvr=a;Ref=pa;{marker}="),
            format!("Srvr=a;Ref=pa;{marker}=ʼ\u{2060}word"),
        ];
        for s in &unknown {
            let e = err(s);
            assert!(!e.message().contains(marker), "{e}");
            assert!(!format!("{e:?}").contains(marker));
        }
        assert_eq!(
            err("Srvr=a;Ref=pa;ss=word").message(),
            "Рядок підключення містить невідомий ключ (ім'я не друкується). Дозволені ключі: Srvr, Ref, File."
        );
        // usr/pwd відмовляють раніше за невідомий ключ, що стоїть правіше; відомий ключ друкується.
        let e = err("Srvr=a;Pwd=x;zz=1");
        assert!(
            e.is_credentials() && e.message().contains("ключ 'Pwd'") && !e.message().contains('x'),
            "{e}"
        );
        assert!(
            err("Srvr=a;zz=1;Pwd=x")
                .message()
                .contains("невідомий ключ")
        );
        assert!(err("File=a=b").message().contains("значенні ключа 'File'"));
        // Значення відомого ключа не цитується; багатобайтові символи біля роздільників не панікують.
        let e = err(&format!("File=\"{marker};ʼ\"=ʼ;Srvr=a"));
        assert!(!e.message().contains(marker), "{e}");
    }

    #[test]
    fn recipes_and_secret_quote_check() {
        let e = err("File=a;Usr=u");
        assert!(credentials_recipe(&e, CredentialsKind::Agent).contains("infobases.origin"));
        assert!(credentials_recipe(&e, CredentialsKind::Overlay).contains("накладки"));
        assert_eq!(
            credentials_recipe(&err("File=a;x=1"), CredentialsKind::Agent),
            ""
        );

        let marker = "п\"ароль-МАРКЕР";
        let e = assert_secret_quote_free(&Secret::new(marker), "пароль бази агента").unwrap_err();
        assert!(
            e.message()
                .starts_with("пароль бази агента містить подвійну лапку")
                && !e.message().contains("МАРКЕР")
        );
        assert!(assert_secret_quote_free(&Secret::new("ok"), "x").is_ok());
    }
}
