// Відбиток «стан сховища, побачений останнім sync» — `build/session-check/<ключ>.json` (схема 1, tools/lib/
// StorageImprint.psm1). Кеш, не стан: істина про залите — трейлер `Storage-Version` вершини `storage/<ключ>`.
// Тут лише ЧИТАННЯ й звірка (запис — PowerShell `sync`, фаза 3): інваріант «session-check нічого не мутує» тримає
// законність убивства процесу на стелі. Відбиток, що не читається чи має чужу схему, — «відбитка немає».
//
// Байти, які порівнюються з диском, — значеннями точно як PowerShell: час — цілі 100-нс тики UTC, розміри — `i64`,
// без допуску (обидві сторони зняті одним годинником файлової системи сховища).
//
// Відбиток актуальний лише тоді, коли виконано ВСЕ (ADR-0021 п. 6): він прив'язаний до цього джерела (ключ і шлях
// сховища, без регістру, нормалізовані роздільники); його версія не менша за версію дзеркала; обхід цього
// прогону справді прочитав сховище (доступне, схоже на сховище 1С, без `partial-read`; серверне — ніколи); час
// найновішого об'єкта й pack-файли (множина за іменем без регістру) збігаються з диском.

use super::activity::{Activity, PackFile, StorageReading};
use super::ticks;
use crate::config::is_server_storage_path;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

const SCHEMA: i64 = 1;

/// Прочитаний відбиток.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Imprint {
    pub key: String,
    pub storage_path: String,
    /// Версія сховища зі звіту `sync` на момент читання.
    pub version: i64,
    /// Коли `sync` читав звіт (тики UTC).
    pub read_at_ticks: i64,
    pub latest_object_write: Option<i64>,
    pub pack_files: Vec<PackFile>,
}

/// Файл відбитка джерела; `None` — ключ шляхоподібний (виходить за `build/session-check`).
fn imprint_path(repo_root: &Path, key: &str) -> Option<std::path::PathBuf> {
    if key.is_empty() || key == ".." || key == "." || key.contains(['/', '\\']) {
        return None;
    }
    Some(
        repo_root
            .join("build")
            .join("session-check")
            .join(format!("{key}.json")),
    )
}

fn parse_pack(value: &Value) -> Option<PackFile> {
    Some(PackFile {
        name: value.get("name")?.as_str()?.to_string(),
        length: value.get("length")?.as_i64()?,
        last_write_ticks: ticks::parse_iso(value.get("lastWriteUtc")?.as_str()?)?,
    })
}

/// Відбиток джерела або `None`: файла немає, JSON битий, схема чужа, поле несумісного типу чи дата зіпсована —
/// усе це «відбитка немає», і жодне не зупиняє команду.
pub fn read_imprint(repo_root: &Path, key: &str) -> Option<Imprint> {
    let path = imprint_path(repo_root, key)?;
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8(bytes).ok()?;
    let doc: Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
    if doc.get("schema")?.as_i64()? != SCHEMA {
        return None;
    }
    let latest = match doc.get("latestObjectWriteUtc")? {
        Value::Null => None,
        v => Some(ticks::parse_iso(v.as_str()?)?),
    };
    let pack_files = match doc.get("packFiles")? {
        Value::Null => Vec::new(),
        v => v
            .as_array()?
            .iter()
            .map(parse_pack)
            .collect::<Option<Vec<_>>>()?,
    };
    Some(Imprint {
        key: doc.get("key")?.as_str()?.to_string(),
        storage_path: doc.get("storagePath")?.as_str()?.to_string(),
        version: doc.get("version")?.as_i64()?,
        read_at_ticks: ticks::parse_iso(doc.get("readAtUtc")?.as_str()?)?,
        latest_object_write: latest,
        pack_files,
    })
}

fn normalized_path(p: &str) -> String {
    p.replace('\\', "/").trim_end_matches('/').to_lowercase()
}

/// Відбиток належить цьому джерелу: ключ і шлях сховища збігаються (без регістру, роздільники нормалізовано).
pub fn is_bound_to(imprint: &Imprint, key: &str, storage_path: &str) -> bool {
    imprint.key.to_lowercase() == key.to_lowercase()
        && normalized_path(&imprint.storage_path) == normalized_path(storage_path)
}

/// Диск дорівнює відбитку: час найновішого об'єкта й pack-файли — множиною за іменем без регістру (дубль імені з
/// різних підтек — не рівно), розмір і час кожного точно.
pub fn matches_disk(imprint: &Imprint, activity: &Activity) -> bool {
    if imprint.latest_object_write != activity.latest_object_write {
        return false;
    }
    fn by_name(files: &[PackFile]) -> Option<HashMap<String, &PackFile>> {
        let mut map = HashMap::new();
        for f in files {
            if map.insert(f.name.to_lowercase(), f).is_some() {
                return None;
            }
        }
        Some(map)
    }
    let (Some(saved), Some(disk)) = (by_name(&imprint.pack_files), by_name(&activity.pack_files))
    else {
        return false;
    };
    saved.len() == disk.len()
        && saved.iter().all(|(name, s)| {
            disk.get(name)
                .is_some_and(|d| d.length == s.length && d.last_write_ticks == s.last_write_ticks)
        })
}

/// Відбиток актуальний — диск не змінювався з моменту, коли `sync` читав звіт, тож `imprint.version` — факт.
/// `mirror_version` — `Storage-Version` вершини дзеркала: відбиток із меншою версією — «відбитка немає».
pub fn is_current(
    imprint: &Imprint,
    key: &str,
    storage_path: &str,
    mirror_version: u64,
    reading: &StorageReading,
) -> bool {
    let StorageReading::Read(activity) = reading else {
        return false;
    };
    if is_server_storage_path(storage_path) || !activity.read_complete() {
        return false;
    }
    match u64::try_from(imprint.version) {
        Ok(v) if v >= mirror_version => {}
        _ => return false,
    }
    is_bound_to(imprint, key, storage_path) && matches_disk(imprint, activity)
}
