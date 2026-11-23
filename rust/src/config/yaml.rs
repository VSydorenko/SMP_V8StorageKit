// Читання YAML-файла в впорядковану мапу — як `Read-KitYaml` (tools/lib/Yaml.psm1): `ConvertFrom-Yaml -Ordered`.
//
// Контракт: файл не знайдено, не розбирається, порожній обов'язковий, корінь не мапа — помилка з іменем файла;
// порожній дозволений — порожня мапа. Помилка розбору називає лише місце (рядок, колонка): текст `serde_yaml`
// цитує ключі й значення з файла (спека §6).
//
// Дерево — `serde_yaml::Value`, нормалізоване під PowerShell: ключі мап — завжди рядки, мапа тримає порядок
// файла, ключі, що відрізняються лише регістром, зливаються (PowerShell тримає дерево в `OrderedDictionary`
// без регістру: перший запис задає ім'я й місце, останній — значення). Пошук за ключем — без регістру.
//
// Відомі розбіжності із YamlDotNet, неусувні з `Value` (скаляр там уже розібраний, початкового тексту немає):
// `1.10` → `1.1`, `0x1f`/`0o7` → десяткове число. Вимір PowerShell 2026-11-23: `0x1f`, `0o7`, `1_000`, `.inf` —
// рядки з початковим текстом; `1.0`, `1e3` — цілі `1`, `1000`.

use super::ConfigError;
use serde_yaml::{Mapping, Number, Value};
use std::collections::HashMap;
use std::path::Path;

/// Що робити з порожнім файлом (`-AllowEmpty` у PowerShell).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Emptiness {
    Required,
    Allowed,
}

/// Читає файл у мапу. Не панікує на жодному вході.
pub fn read_yaml(path: &Path, emptiness: Emptiness) -> Result<Mapping, ConfigError> {
    let shown = path.display();
    if !path.is_file() {
        return Err(ConfigError::new(format!("Файл не знайдено: {shown}")));
    }
    let bytes = std::fs::read(path).map_err(|e| ConfigError::new(format!("Файл {shown} не прочитано: {}", e.kind())))?;
    // `Get-Content -Encoding UTF8`: BOM відкидається, некоректні байти — символ заміни.
    let text = String::from_utf8_lossy(&bytes);
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);

    let root = if text.trim().is_empty() {
        None
    } else {
        match parse_first_document(text) {
            Ok(v) => v,
            Err(place) => {
                let at = match place {
                    Some((line, column)) => format!(" (рядок {line}, колонка {column})"),
                    None => String::new(),
                };
                return Err(ConfigError::new(format!("Файл {shown} не розбирається як YAML{at}.")));
            }
        }
    };

    match root {
        None | Some(Value::Null) => match emptiness {
            Emptiness::Allowed => Ok(Mapping::new()),
            Emptiness::Required => Err(ConfigError::new(format!(
                "Файл {shown} порожній — очікувався YAML-документ із мапою на верхньому рівні."
            ))),
        },
        Some(Value::Mapping(m)) => Ok(m),
        Some(other) => Err(ConfigError::new(format!(
            "Файл {shown} на верхньому рівні має бути мапою (ключ: значення), а не {}.",
            ps_type_name(&other)
        ))),
    }
}

/// Документ файла. `Err` — місце помилки, якщо його відомо. Потік з кількома документами `serde_yaml` не
/// читає, тож він (на відміну від PowerShell, що бере перший) — помилка розбору: fail-closed.
fn parse_first_document(text: &str) -> Result<Option<Value>, Option<(usize, usize)>> {
    let value: Value = serde_yaml::from_str(text).map_err(|e| e.location().map(|l| (l.line(), l.column())))?;
    normalize(value).map(Some).ok_or(None)
}

/// Ключі мап → рядки, ключі без урахування регістру зливаються, теги знімаються. `None` — ключ не скаляр
/// (у PowerShell такий вузол не має `.Value`, і розбір падає).
fn normalize(value: Value) -> Option<Value> {
    match value {
        Value::Tagged(t) => normalize(t.value),
        Value::Sequence(items) => items.into_iter().map(normalize).collect::<Option<Vec<_>>>().map(Value::Sequence),
        Value::Mapping(map) => {
            let mut out = Mapping::new();
            let mut spelled: HashMap<String, String> = HashMap::new();
            for (k, v) in map {
                let key = key_text(&k)?;
                let v = normalize(v)?;
                let folded = key.to_lowercase();
                let name = spelled.entry(folded).or_insert_with(|| key.clone()).clone();
                out.insert(Value::String(name), v);
            }
            Some(Value::Mapping(out))
        }
        scalar => Some(scalar),
    }
}

fn key_text(k: &Value) -> Option<String> {
    match k {
        Value::String(s) => Some(s.clone()),
        Value::Bool(b) => Some(if *b { "true" } else { "false" }.to_string()),
        Value::Null => Some("~".to_string()),
        Value::Number(n) => Some(number_text(n).0),
        Value::Tagged(t) => key_text(&t.value),
        Value::Sequence(_) | Value::Mapping(_) => None,
    }
}

/// Порівняння імен без регістру (як `-eq`/`-notcontains`/`Contains` у PowerShell).
pub fn eq_ci(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

/// Значення за ключем без регістру.
pub fn get<'a>(map: &'a Mapping, key: &str) -> Option<&'a Value> {
    map.iter().find(|(k, _)| k.as_str().is_some_and(|k| eq_ci(k, key))).map(|(_, v)| v)
}

pub fn contains(map: &Mapping, key: &str) -> bool {
    get(map, key).is_some()
}

/// Ключі мапи в порядку файла (після нормалізації всі — рядки).
pub fn keys(map: &Mapping) -> Vec<String> {
    map.iter().filter_map(|(k, _)| k.as_str().map(str::to_string)).collect()
}

/// `[string]$map[$key]`; ключа немає — порожній рядок (`$null`).
pub fn get_string(map: &Mapping, key: &str) -> String {
    get(map, key).map(ps_string).unwrap_or_default()
}

const LIST_TYPE: &str = "System.Collections.Generic.List`1[System.Object]";
const MAP_TYPE: &str = "System.Collections.Specialized.OrderedDictionary";

/// Значення → рядок за правилами PowerShell `[string]` (рішення 7 плану): ціле без крапки, `True`/`False`,
/// `null` → порожньо, список — елементи через пробіл, мапа й вкладений список — ім'я типу .NET.
pub fn ps_string(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(b) => if *b { "True" } else { "False" }.to_string(),
        Value::Number(n) => number_text(n).0,
        Value::String(s) => s.clone(),
        Value::Tagged(t) => ps_string(&t.value),
        Value::Mapping(_) => MAP_TYPE.to_string(),
        Value::Sequence(items) => items
            .iter()
            .map(|i| match i {
                Value::Sequence(_) => LIST_TYPE.to_string(),
                other => ps_string(other),
            })
            .collect::<Vec<_>>()
            .join(" "),
    }
}

/// Коротке ім'я типу .NET значення, як `$x.GetType().Name` (вимір 2026-11-23: список → `List`1`, рядок →
/// `String`, ціле → `Int32`, булеве → `Boolean`).
pub fn ps_type_name(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::Bool(_) => "Boolean".to_string(),
        Value::String(_) => "String".to_string(),
        Value::Number(n) => number_text(n).1.to_string(),
        Value::Tagged(t) => ps_type_name(&t.value),
        Value::Sequence(_) => "List`1".to_string(),
        Value::Mapping(_) => "OrderedDictionary".to_string(),
    }
}

/// (текст, ім'я типу .NET) числа за правилами powershell-yaml: ціле — `Int32`/`Int64`/`BigInteger`; дріб з
/// нульовою дробовою частиною — теж ціле (`1.0` → `1`); інакше `Decimal`, поза його діапазоном `Double`.
fn number_text(n: &Number) -> (String, &'static str) {
    if let Some(i) = n.as_i64() {
        return integer_text(i.to_string());
    }
    if let Some(u) = n.as_u64() {
        return integer_text(u.to_string());
    }
    let f = n.as_f64().unwrap_or(0.0);
    if f.is_nan() {
        return (".nan".to_string(), "String");
    }
    if f.is_infinite() {
        return (if f < 0.0 { "-.inf" } else { ".inf" }.to_string(), "String");
    }
    if f.fract() == 0.0 {
        let digits = format!("{f:.0}");
        return integer_text(if digits == "-0" { "0".to_string() } else { digits });
    }
    (format!("{f}"), if f.abs() < 7.9e28 { "Decimal" } else { "Double" })
}

fn integer_text(digits: String) -> (String, &'static str) {
    let kind = if digits.parse::<i32>().is_ok() {
        "Int32"
    } else if digits.parse::<i64>().is_ok() {
        "Int64"
    } else {
        "BigInteger"
    };
    (digits, kind)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn file(dir: &Path, name: &str, text: &str) -> std::path::PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, text).unwrap();
        p
    }

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("kit-yaml-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn contract_of_read_yaml() {
        let d = tmp("contract");
        // Порядок ключів збережено, регістр зливається (перше ім'я, останнє значення), BOM відкинуто.
        let ok = file(&d, "ok.yaml", "\u{feff}b: 1\nA: 2\na: 3\n");
        let m = read_yaml(&ok, Emptiness::Required).unwrap();
        assert_eq!(keys(&m), ["b", "A"]);
        assert_eq!(get_string(&m, "a"), "3");

        // Порожній: обов'язковий — помилка з іменем файла, дозволений — порожня мапа.
        let empty = file(&d, "empty.yaml", "# лише коментар\n");
        let e = read_yaml(&empty, Emptiness::Required).unwrap_err();
        assert!(e.message().contains("empty.yaml") && e.message().contains("порожній"), "{e}");
        assert!(read_yaml(&empty, Emptiness::Allowed).unwrap().is_empty());

        // Корінь не мапа — з іменем типу .NET.
        let list = file(&d, "list.yaml", "- a\n- b\n");
        assert!(read_yaml(&list, Emptiness::Required).unwrap_err().message().ends_with("а не List`1."));
        let int = file(&d, "int.yaml", "5\n");
        assert!(read_yaml(&int, Emptiness::Required).unwrap_err().message().ends_with("а не Int32."));

        // Немає файла.
        assert!(read_yaml(&d.join("none.yaml"), Emptiness::Required).unwrap_err().message().starts_with("Файл не знайдено: "));
    }

    // Інваріант §6: помилка розбору називає файл і місце, не цитує даних; дубль ключа не друкує ключ.
    #[test]
    fn parse_error_gives_place_without_data() {
        let d = tmp("place");
        let marker = "СЕКРЕТ-маркер";
        for (name, text) in [("bad.yaml", format!("a: [{marker}\nb: ]]\n")), ("dup.yaml", format!("{marker}: 1\n{marker}: 2\n"))] {
            let p = file(&d, name, &text);
            let e = read_yaml(&p, Emptiness::Required).unwrap_err();
            assert!(e.message().contains(name) && e.message().contains("не розбирається як YAML"), "{e}");
            assert!(!e.message().contains(marker) && !format!("{e:?}").contains(marker), "{e}");
        }
    }

    // Інваріант §6: «мільярд сміхів» завершується помилкою за стелю часу, а не зависанням чи панікою.
    #[test]
    fn billion_laughs_terminates_with_error() {
        let d = tmp("laughs");
        let mut text = String::from("a0: &a0 [\"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\", \"lol\"]\n");
        for i in 1..10 {
            let prev = i - 1;
            let refs = vec![format!("*a{prev}"); 9].join(", ");
            text.push_str(&format!("a{i}: &a{i} [{refs}]\n"));
        }
        let p = file(&d, "laughs.yaml", &text);
        let started = Instant::now();
        let r = read_yaml(&p, Emptiness::Required);
        assert!(started.elapsed() < Duration::from_secs(20), "розбір завис");
        let e = r.unwrap_err();
        assert!(e.message().contains("laughs.yaml") && e.message().contains("не розбирається як YAML"), "{e}");
    }

    #[test]
    fn powershell_string_conversion() {
        let v: Value = serde_yaml::from_str("[1, true, ~, 1.0, 2.5, [x], {k: v}, abc]").unwrap();
        assert_eq!(ps_string(&v), format!("1 True  1 2.5 {LIST_TYPE} {MAP_TYPE} abc"));
        let m: Value = serde_yaml::from_str("{k: v}").unwrap();
        assert_eq!(ps_string(&m), MAP_TYPE);
    }
}
