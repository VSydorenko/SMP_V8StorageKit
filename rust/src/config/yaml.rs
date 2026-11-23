// Читання YAML-файла в впорядковану мапу — як `Read-KitYaml` (tools/lib/Yaml.psm1): `ConvertFrom-Yaml -Ordered`.
//
// Контракт: файл не знайдено, не розбирається, порожній обов'язковий, корінь не мапа — помилка з іменем файла;
// порожній дозволений — порожня мапа. Помилка розбору називає лише місце (рядок, колонка): текст `serde_yaml`
// цитує ключі й значення з файла (спека §6).
//
// Кілька документів (`---`) у файлі — відмова з іменем файла й місцем другого `---` (рядок, колонка). PowerShell
// мовчки бере перший документ і відкидає решту; це дефект, він не відтворюється (ADR-0014 п. 7, відома відмінність).
//
// Текст скалярів (рішення архітектора 2026-11-23). Поле, яке kit читає як рядок, дає ВИХІДНИЙ текст файла: `1.10`,
// `0123`, `0x1f`, `1e3`, `1_000`, `yes`, `true` лишаються такими, як написано (ключі мап — так само). Тиха зміна
// значення (`1.10` → `1.1`, `0123` → `123`) — дефект: з ключа джерела `0123` вийшла б гілка `storage/123`.
// Тому файл розбирається двічі: типовим `Value` (форма й ознака `null`), потім деревом, у якому кожен скаляр
// прочитано як рядок (`deserialize_string` у `serde_yaml` віддає вихідний текст); `null`/`~`/порожнє лишається
// `Null` (порожній рядок, як у PowerShell). Вимір `serde_yaml` 0.9.34 — у звіті задачі 1.
// Відмінність від PowerShell: там значення `0123`, `1.0`, `1e3` стають числом (`123`, `1`, `1000`) — Rust дає текст.
//
// Дерево нормалізоване під PowerShell: ключі мап — рядки, мапа тримає порядок файла, ключі, що відрізняються лише
// регістром, зливаються (PowerShell тримає дерево в `OrderedDictionary` без регістру: перший запис задає місце,
// ім'я й значення — останній; вимір 2026-11-24: `A: 1` і `a: 2` дають ключ `a`, задача 4). Пошук за ключем — без регістру. Тег (`!x`) у значенні — помилка розбору.

use super::ConfigError;
use serde::Deserialize;
use serde::de::{DeserializeSeed, Deserializer, Error as _, IgnoredAny, MapAccess, SeqAccess, Visitor};
use serde_yaml::{Mapping, Number, Value};
use std::fmt;
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
    match read_yaml_or_none(path)? {
        Some(map) => Ok(map),
        None => match emptiness {
            Emptiness::Allowed => Ok(Mapping::new()),
            Emptiness::Required => Err(ConfigError::new(format!(
                "Файл {shown} порожній — очікувався YAML-документ із мапою на верхньому рівні."
            ))),
        },
    }
}

/// Те саме, але порожній або суто коментований файл — `None` (`$null` з `-AllowEmpty`), на відміну від явної
/// порожньої мапи `{}`: `Get-V8ProjectConfigProblems` пропускає перший і перевіряє другу.
pub fn read_yaml_or_none(path: &Path) -> Result<Option<Mapping>, ConfigError> {
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
        match parse_document(text) {
            Ok(v) => v,
            Err(fail) => {
                let msg = match fail {
                    ParseFail::Syntax(Some((line, column))) => format!("Файл {shown} не розбирається як YAML (рядок {line}, колонка {column})."),
                    ParseFail::Syntax(None) => format!("Файл {shown} не розбирається як YAML."),
                    ParseFail::MultiDocument(line, column) => format!(
                        "Файл {shown} містить кілька YAML-документів (другий починається в рядку {line}, колонка {column}); kit читає один документ."
                    ),
                };
                return Err(ConfigError::new(msg));
            }
        }
    };

    match root {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Mapping(typed)) => match text_tree(text, &typed) {
            Some(Value::Mapping(m)) => Ok(Some(m)),
            _ => Err(ConfigError::new(format!("Файл {shown} не розбирається як YAML."))),
        },
        Some(other) => Err(ConfigError::new(format!(
            "Файл {shown} на верхньому рівні має бути мапою (ключ: значення), а не {}.",
            ps_type_name(&other)
        ))),
    }
}

enum ParseFail {
    Syntax(Option<(usize, usize)>),
    MultiDocument(usize, usize),
}

/// Відхиляє будь-що: потрібен лише для місця, де `serde_yaml` бачить початок документа.
struct Reject;

impl<'de> Visitor<'de> for Reject {
    type Value = ();

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("нічого")
    }
    fn visit_map<A: MapAccess<'de>>(self, _: A) -> Result<(), A::Error> {
        Err(A::Error::custom("документ"))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, _: A) -> Result<(), A::Error> {
        Err(A::Error::custom("документ"))
    }
    fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<(), E> {
        Err(E::custom("документ"))
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<(), E> {
        Err(E::custom("документ"))
    }
    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<(), E> {
        Err(E::custom("документ"))
    }
    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<(), E> {
        Err(E::custom("документ"))
    }
    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<(), E> {
        Err(E::custom("документ"))
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<(), E> {
        Err(E::custom("документ"))
    }
}

fn place(e: &serde_yaml::Error) -> Option<(usize, usize)> {
    e.location().map(|l| (l.line(), l.column()))
}

/// Типовий `Value` першого документа. Другий документ — `MultiDocument` з місцем його `---`: `serde_yaml` дає
/// початок вмісту документа, а `---` лежить на тому ж чи одному з попередніх рядків.
fn parse_document(text: &str) -> Result<Option<Value>, ParseFail> {
    let mut docs = serde_yaml::Deserializer::from_str(text);
    let Some(first) = docs.next() else {
        return Ok(None);
    };
    let value = Value::deserialize(first).map_err(|e| ParseFail::Syntax(place(&e)))?;
    if let Some(second) = docs.next() {
        return Err(match second.deserialize_any(Reject).err().as_ref().and_then(place) {
            Some((line, _)) => ParseFail::MultiDocument(marker_line(text, line), 1),
            None => ParseFail::Syntax(None),
        });
    }
    Ok(Some(value))
}

/// Рядок останнього `---` не нижче за рядок вмісту документа (1-based); немає — сам рядок вмісту.
fn marker_line(text: &str, content_line: usize) -> usize {
    text.lines()
        .enumerate()
        .map(|(i, l)| (i.saturating_add(1), l))
        .take_while(|(n, _)| *n <= content_line)
        .filter(|(_, l)| l.starts_with("---"))
        .map(|(n, _)| n)
        .fold(content_line, |_, n| n)
}

/// Дерево першого документа, де кожен скаляр прочитано як рядок; форму (мапа, список, `null`) задає типове дерево.
fn text_tree(text: &str, typed: &Mapping) -> Option<Value> {
    let first = serde_yaml::Deserializer::from_str(text).next()?;
    let shape = Value::Mapping(typed.clone());
    let tree = TextSeed(&shape).deserialize(first).ok()?;
    normalize(tree)
}

struct TextSeed<'a>(&'a Value);

impl<'de> DeserializeSeed<'de> for TextSeed<'_> {
    type Value = Value;

    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        match self.0 {
            Value::Mapping(shape) => d.deserialize_map(MapShape(shape)),
            Value::Sequence(shape) => d.deserialize_seq(SeqShape(shape)),
            Value::Null => d.deserialize_any(IgnoredAny).map(|_| Value::Null),
            Value::Tagged(_) => Err(D::Error::custom("тег")),
            Value::Bool(_) | Value::Number(_) | Value::String(_) => String::deserialize(d).map(Value::String),
        }
    }
}

struct MapShape<'a>(&'a Mapping);

impl<'de> Visitor<'de> for MapShape<'_> {
    type Value = Value;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("мапа")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut out = Mapping::new();
        for (key_shape, value_shape) in self.0 {
            if matches!(key_shape, Value::Sequence(_) | Value::Mapping(_) | Value::Tagged(_)) {
                return Err(A::Error::custom("ключ не скаляр"));
            }
            let Some(key) = a.next_key::<String>()? else { break };
            let value = a.next_value_seed(TextSeed(value_shape))?;
            out.insert(Value::String(key), value);
        }
        Ok(Value::Mapping(out))
    }
}

struct SeqShape<'a>(&'a [Value]);

impl<'de> Visitor<'de> for SeqShape<'_> {
    type Value = Value;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("список")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut out = Vec::new();
        for shape in self.0 {
            match a.next_element_seed(TextSeed(shape))? {
                Some(v) => out.push(v),
                None => break,
            }
        }
        Ok(Value::Sequence(out))
    }
}

/// Ключі мап → рядки, ключі без урахування регістру зливаються, теги знімаються. `None` — ключ не скаляр
/// (у PowerShell такий вузол не має `.Value`, і розбір падає).
fn normalize(value: Value) -> Option<Value> {
    match value {
        Value::Tagged(t) => normalize(t.value),
        Value::Sequence(items) => items.into_iter().map(normalize).collect::<Option<Vec<_>>>().map(Value::Sequence),
        Value::Mapping(map) => {
            // `OrderedDictionary` у PowerShell: ключ без регістру — одне місце (де вперше з'явився), а ім'я й значення
            // — з останнього запису (вимір 2026-11-24: `Alpha_SMB:` і `ALPHA_SMB:` дають ключ `ALPHA_SMB`).
            let mut entries: Vec<(String, Value)> = Vec::new();
            for (k, v) in map {
                let key = key_text(&k)?;
                let v = normalize(v)?;
                let folded = key.to_lowercase();
                match entries.iter_mut().find(|(name, _)| name.to_lowercase() == folded) {
                    Some(slot) => *slot = (key, v),
                    None => entries.push((key, v)),
                }
            }
            let mut out = Mapping::new();
            for (name, v) in entries {
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
        // Порядок ключів збережено, регістр зливається (місце першого запису, ім'я й значення останнього), BOM відкинуто.
        let ok = file(&d, "ok.yaml", "\u{feff}b: 1\nA: 2\na: 3\n");
        let m = read_yaml(&ok, Emptiness::Required).unwrap();
        assert_eq!(keys(&m), ["b", "a"]);
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
        let d = tmp("psstring");
        let p = file(&d, "v.yaml", "l: [1.10, true, ~, 0123, [x], {k: v}, abc]\nm: {k: v}\n");
        let m = read_yaml(&p, Emptiness::Required).unwrap();
        assert_eq!(get_string(&m, "l"), format!("1.10 true  0123 {LIST_TYPE} {MAP_TYPE} abc"));
        assert_eq!(get_string(&m, "m"), MAP_TYPE);
    }

    // Рішення архітектора: рядкове поле дає вихідний текст скаляра, ніколи `1.1` замість `1.10` чи `123` замість
    // `0123`; ключі — так само; `null`/`~`/порожнє — порожній рядок.
    #[test]
    fn scalars_keep_source_text() {
        let d = tmp("scalars");
        let cases = ["1.10", "0x1f", "0o7", "0123", "1e3", "1_000", "yes", "true", "1.0", "-0", ".inf"];
        let mut text = String::new();
        for (i, c) in cases.iter().enumerate() {
            text.push_str(&format!("v{i}: {c}\n{c}: k{i}\n"));
        }
        text.push_str("n1: ~\nn2: null\nn3:\n");
        let m = read_yaml(&file(&d, "s.yaml", &text), Emptiness::Required).unwrap();
        for (i, c) in cases.iter().enumerate() {
            assert_eq!(get_string(&m, &format!("v{i}")), *c);
            assert_eq!(get_string(&m, c), format!("k{i}"), "ключ {c}");
        }
        assert!(["n1", "n2", "n3"].iter().all(|k| contains(&m, k) && get_string(&m, k).is_empty()));
    }

    // Кілька документів — відмова з іменем файла й місцем другого `---`, без тексту парсера й даних.
    #[test]
    fn several_documents_are_refused_with_place() {
        let d = tmp("multi");
        let marker = "СЕКРЕТ-маркер";
        let p = file(&d, "multi.yaml", &format!("a: 1\n\n# коментар\n---\nb: {marker}\n"));
        let e = read_yaml(&p, Emptiness::Required).unwrap_err();
        assert!(e.message().contains("multi.yaml") && e.message().contains("кілька YAML-документів"), "{e}");
        assert!(e.message().contains("рядку 4, колонка 1"), "{e}");
        assert!(!e.message().contains(marker), "{e}");
        // Порожній другий документ теж відхиляється.
        let e = read_yaml(&file(&d, "m2.yaml", "a: 1\n---\n"), Emptiness::Required).unwrap_err();
        assert!(e.message().contains("рядку 2, колонка 1"), "{e}");
    }
}
