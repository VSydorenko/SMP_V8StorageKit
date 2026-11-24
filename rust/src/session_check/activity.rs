// Активність сховища (`Get-KitStorageActivity`, tools/lib/StorageBranch.psm1): коли у сховище останнім разом
// писали об'єкти (максимальний час запису під `data/objects` і `data/pack`), перелік pack-файлів для звірки з
// відбитком і розпізнавання «це взагалі сховище 1С» без платформи. `1cv8ddb.1CD` — лише ознака «це сховище», не
// індикатор часу (його оновлює кожне підключення Конфігуратора).
//
// Множина файлів — як `Get-ChildItem -Recurse -File` без `-Force`: приховані й системні файли й
// теки пропускаються, теки-посилання не обходяться. Це паритет порівнюваних байтів, поки відбиток пише PowerShell
// `sync`; фаза 3 переглядає правило разом із записом відбитка.
//
// Помилка читання запису посеред обходу — не мовчанка (PowerShell із `-ErrorAction SilentlyContinue` занижував час
// і давав хибне «синхронне»): вона запам'ятовується класом ОС без шляху (`partial`). Запис, що зник між переліком
// і читанням (код ОС 2 чи 3), — не помилка читання: файла вже немає; інше `NotFound` (15, 53, 67) — обрив.
//
// Читання кожного джерела — у власному потоці зі стелею (`ceiling`): недоступний мережевий шлях висить у ОС без
// таймауту. Усі джерела стартують разом (`start_reading`), результат збирається в порядку джерел; на стелі —
// «недоступне на цій машині» (ADR-0021 п. 2), не `partial-read`. Серверна адреса файлово не читається.

use super::ticks::from_system_time;
use crate::ceiling;
use crate::config::is_server_storage_path;
use std::fs;
use std::io;
use std::path::Path;
use std::time::Duration;

/// Стеля читання одного сховища (як проба каталогу в `check`).
pub const READ_CEILING: Duration = Duration::from_secs(5);

/// Чому каталог сховища недоступний (причини розрізняються).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unavailable {
    /// Каталогу немає (чи шлях — не каталог).
    Missing,
    /// Каталог є, доступу немає.
    Denied,
    /// Ресурс не відповів: збій мережі чи не вклався в стелю.
    NoAnswer,
}

impl Unavailable {
    /// Причина для тексту сигналу.
    pub fn text(self) -> &'static str {
        match self {
            Unavailable::Missing => "немає",
            Unavailable::Denied => "немає доступу",
            Unavailable::NoAnswer => "не відповіло",
        }
    }
}

/// Клас помилки читання запису посеред обходу: вид помилки ОС, без шляху (шлях може бути секретним, а клас
/// достатній, щоб людина знала, що робити).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadErrorClass {
    AccessDenied,
    Interrupted,
    Other,
}

impl ReadErrorClass {
    /// Текст класу для сигналу `partial-read`.
    pub fn label(self) -> &'static str {
        match self {
            ReadErrorClass::AccessDenied => "немає доступу",
            ReadErrorClass::Interrupted => "обрив",
            ReadErrorClass::Other => "інше",
        }
    }

    fn of(e: &io::Error) -> Self {
        use io::ErrorKind as K;
        if e.kind() == K::PermissionDenied {
            return ReadErrorClass::AccessDenied;
        }
        // `NotFound`, що не є «запису немає» (15, 53, 67, без коду ОС): диск чи мережа зникли — обрив.
        if e.kind() == K::NotFound {
            return ReadErrorClass::Interrupted;
        }
        // 53/67 — мережевий шлях чи ім'я не знайдено, 59 — неочікувана мережева помилка, 64 — мережеве ім'я більше
        // недоступне, 121 — таймаут семафора, 1231/1236 — мережа недосяжна / з'єднання перервано.
        let network_code = matches!(
            e.raw_os_error(),
            Some(53 | 59 | 64 | 67 | 121 | 1231 | 1236)
        );
        let interrupted_kind = matches!(
            e.kind(),
            K::ConnectionReset
                | K::ConnectionAborted
                | K::NotConnected
                | K::BrokenPipe
                | K::TimedOut
                | K::Interrupted
                | K::HostUnreachable
                | K::NetworkUnreachable
                | K::NetworkDown
                | K::UnexpectedEof
        );
        if network_code || interrupted_kind {
            ReadErrorClass::Interrupted
        } else {
            ReadErrorClass::Other
        }
    }
}

/// Чому каталог, що відповів, не схожий на сховище.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotStorage {
    /// Немає `1cv8ddb.1CD` — шлях переплутано.
    NoDatabase,
    /// Обидві теки — `data/objects` і `data/pack` — порожні чи відсутні: жодної версії.
    NoVersions,
}

impl NotStorage {
    /// Текст причини (як `Reason` у PowerShell).
    pub fn text(self) -> &'static str {
        match self {
            NotStorage::NoDatabase => "у каталозі немає 1cv8ddb.1CD — не схоже на сховище 1С",
            NotStorage::NoVersions => {
                "у сховищі немає жодного файла ні в data/objects, ні в data/pack (жодної версії)"
            }
        }
    }
}

/// Файл `data/pack`: ім'я, розмір (`i64`) і час запису (тики UTC) — рівно те, що звіряється з відбитком.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackFile {
    pub name: String,
    pub length: i64,
    pub last_write_ticks: i64,
}

/// Результат читання каталогу, що відповів. Якщо `partial` задано, решті полів довіряти не можна: обхід
/// натрапив на помилку, час міг бути занижений.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Activity {
    pub is_storage: bool,
    /// Заповнено, лише коли `is_storage == false`.
    pub not_storage: Option<NotStorage>,
    pub latest_object_write: Option<i64>,
    pub latest_pack_write: Option<i64>,
    /// Відсортовані за іменем без регістру, потім за точним.
    pub pack_files: Vec<PackFile>,
    pub partial: Option<ReadErrorClass>,
}

impl Activity {
    /// Обхід прочитав сховище повністю: схоже на сховище 1С і без помилки читання. Лише така активність дозволяє
    /// довіряти відбитку.
    pub fn read_complete(&self) -> bool {
        self.is_storage && self.partial.is_none()
    }
}

/// Що дало читання сховища джерела.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StorageReading {
    /// Серверна адреса (`tcp://`, `http(s)://`): файлово не читається.
    Server,
    /// Каталог недоступний на цій машині.
    Unavailable(Unavailable),
    /// Каталог відповів.
    Read(Activity),
}

/// Запису справді немає: `ERROR_FILE_NOT_FOUND` (2) чи `ERROR_PATH_NOT_FOUND` (3). Rust на Windows зводить до
/// `ErrorKind::NotFound` ще й `ERROR_INVALID_DRIVE` (15), `ERROR_BAD_NETPATH` (53), `ERROR_BAD_NET_NAME` (67) — це
/// не «немає», а недоступність, тож вид помилки для цього розрізнення не годиться. Єдина функція на три місця:
/// перевірка кореня, `unavailable_of`, помилка посеред обходу.
fn entry_absent(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::NotFound && matches!(e.raw_os_error(), Some(2 | 3))
}

/// Помилка читання запису: «зник між переліком і читанням» мовчить, решта — `partial` (перша перемагає).
fn note_read_error(slot: &mut Option<ReadErrorClass>, e: &io::Error) {
    if entry_absent(e) {
        return;
    }
    slot.get_or_insert(ReadErrorClass::of(e));
}

fn unavailable_of(e: &io::Error) -> Unavailable {
    if e.kind() == io::ErrorKind::NotFound && !entry_absent(e) {
        return Unavailable::NoAnswer;
    }
    match e.kind() {
        io::ErrorKind::NotFound => Unavailable::Missing,
        io::ErrorKind::PermissionDenied => Unavailable::Denied,
        _ => Unavailable::NoAnswer,
    }
}

#[cfg(windows)]
fn hidden_or_system(meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const HIDDEN: u32 = 0x2;
    const SYSTEM: u32 = 0x4;
    meta.file_attributes() & (HIDDEN | SYSTEM) != 0
}

#[cfg(not(windows))]
fn hidden_or_system(_: &fs::Metadata) -> bool {
    false
}

/// Тека-посилання (junction чи symlink на теку): не обходиться.
#[cfg(windows)]
fn directory_link(meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const DIRECTORY: u32 = 0x10;
    const REPARSE_POINT: u32 = 0x400;
    let attrs = meta.file_attributes();
    attrs & DIRECTORY != 0 && attrs & REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn directory_link(meta: &fs::Metadata) -> bool {
    meta.file_type().is_symlink()
}

struct Found {
    name: String,
    length: i64,
    ticks: i64,
}

#[derive(Default)]
struct Walk {
    files: Vec<Found>,
    error: Option<ReadErrorClass>,
}

impl Walk {
    fn note(&mut self, e: &io::Error) {
        note_read_error(&mut self.error, e);
    }

    fn visit(&mut self, dir: &Path) {
        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(e) => return self.note(&e),
        };
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(e) => {
                    self.note(&e);
                    continue;
                }
            };
            let meta = match entry.metadata() {
                Ok(meta) => meta,
                Err(e) => {
                    self.note(&e);
                    continue;
                }
            };
            if hidden_or_system(&meta) {
                continue;
            }
            if directory_link(&meta) {
                continue;
            }
            if meta.is_dir() {
                self.visit(&entry.path());
                continue;
            }
            let modified = match meta.modified() {
                Ok(t) => from_system_time(t),
                Err(e) => {
                    self.note(&e);
                    continue;
                }
            };
            self.files.push(Found {
                name: entry.file_name().to_string_lossy().into_owned(),
                length: i64::try_from(meta.len()).unwrap_or(i64::MAX),
                ticks: modified,
            });
        }
    }
}

fn walk_dir(dir: &Path, error: &mut Option<ReadErrorClass>) -> Vec<Found> {
    // Каталог верхнього рівня, якого немає, — не помилка: `Test-Path` у PowerShell так само пропускає.
    match fs::metadata(dir) {
        Ok(m) if m.is_dir() => {}
        Ok(_) => return Vec::new(),
        Err(e) => {
            note_read_error(error, &e);
            return Vec::new();
        }
    }
    let mut walk = Walk::default();
    walk.visit(dir);
    if let Some(class) = walk.error {
        error.get_or_insert(class);
    }
    walk.files
}

/// Синхронне читання сховища за шляхом (без стелі). Серверна адреса — `Server`.
pub fn read_storage(storage_path: &str) -> StorageReading {
    if is_server_storage_path(storage_path) {
        return StorageReading::Server;
    }
    let root = Path::new(storage_path);
    match fs::metadata(root) {
        Ok(m) if m.is_dir() => {}
        Ok(_) => return StorageReading::Unavailable(Unavailable::Missing),
        Err(e) => return StorageReading::Unavailable(unavailable_of(&e)),
    }

    let mut result = Activity {
        is_storage: false,
        not_storage: None,
        latest_object_write: None,
        latest_pack_write: None,
        pack_files: Vec::new(),
        partial: None,
    };
    match fs::metadata(root.join("1cv8ddb.1CD")) {
        Ok(m) if m.is_file() => {}
        Ok(_) => {
            result.not_storage = Some(NotStorage::NoDatabase);
            return StorageReading::Read(result);
        }
        Err(e) => {
            note_read_error(&mut result.partial, &e);
            result.not_storage = Some(NotStorage::NoDatabase);
            return StorageReading::Read(result);
        }
    }

    let objects = walk_dir(&root.join("data").join("objects"), &mut result.partial);
    let packs = walk_dir(&root.join("data").join("pack"), &mut result.partial);
    result.latest_object_write = objects.iter().map(|f| f.ticks).max();
    result.latest_pack_write = packs.iter().map(|f| f.ticks).max();
    if objects.is_empty() && packs.is_empty() {
        result.not_storage = Some(NotStorage::NoVersions);
    } else {
        result.is_storage = true;
    }
    let mut pack_files: Vec<PackFile> = packs
        .into_iter()
        .map(|f| PackFile {
            name: f.name,
            length: f.length,
            last_write_ticks: f.ticks,
        })
        .collect();
    pack_files.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.name.cmp(&b.name))
    });
    result.pack_files = pack_files;
    StorageReading::Read(result)
}

/// Читання, що вже стартувало: стеля рахується від старту, а не від `wait`.
pub enum PendingReading {
    Ready(StorageReading),
    Running(ceiling::Pending<StorageReading>),
}

impl PendingReading {
    /// Результат; не вклалось у стелю — «недоступне: не відповіло» (ADR-0021 п. 2).
    pub fn wait(self) -> StorageReading {
        match self {
            PendingReading::Ready(r) => r,
            PendingReading::Running(p) => p
                .wait()
                .unwrap_or(StorageReading::Unavailable(Unavailable::NoAnswer)),
        }
    }
}

/// Стартує читання сховища у власному потоці зі стелею `READ_CEILING`.
pub fn start_reading(storage_path: &str) -> PendingReading {
    start_reading_with(storage_path, READ_CEILING, read_storage)
}

/// `start_reading` зі швом: стеля й функція читання задаються викликачем (тест підставляє повільне читання
/// замість справжнього SMB). Серверна адреса потоку не стартує.
pub fn start_reading_with<F>(storage_path: &str, ceiling: Duration, reader: F) -> PendingReading
where
    F: FnOnce(&str) -> StorageReading + Send + 'static,
{
    if is_server_storage_path(storage_path) {
        return PendingReading::Ready(StorageReading::Server);
    }
    let owned = storage_path.to_string();
    PendingReading::Running(ceiling::start(ceiling, move || reader(&owned)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(code: i32) -> io::Error {
        io::Error::from_raw_os_error(code)
    }

    #[test]
    fn only_codes_2_and_3_mean_the_entry_is_absent() {
        for code in [2, 3] {
            assert!(entry_absent(&os(code)), "{code}");
            assert_eq!(unavailable_of(&os(code)), Unavailable::Missing, "{code}");
        }
        for code in [15, 53, 67] {
            // Контроль допущення: std справді зводить їх до NotFound, інакше тест нічого не доводить.
            assert_eq!(os(code).kind(), io::ErrorKind::NotFound, "{code}");
            assert!(!entry_absent(&os(code)), "{code}");
            assert_eq!(unavailable_of(&os(code)), Unavailable::NoAnswer, "{code}");
        }
        let bare = io::Error::from(io::ErrorKind::NotFound);
        assert!(!entry_absent(&bare));
        assert_eq!(unavailable_of(&bare), Unavailable::NoAnswer);
    }

    #[test]
    fn walk_error_vanished_entry_is_silent_other_not_found_is_partial_interrupted() {
        let mut walk = Walk::default();
        walk.note(&os(2));
        walk.note(&os(3));
        assert_eq!(walk.error, None);
        for code in [15, 53, 67] {
            let mut walk = Walk::default();
            walk.note(&os(code));
            assert_eq!(walk.error, Some(ReadErrorClass::Interrupted), "{code}");
        }
        let mut slot = None;
        note_read_error(&mut slot, &io::Error::from(io::ErrorKind::NotFound));
        assert_eq!(slot, Some(ReadErrorClass::Interrupted));
    }

    #[test]
    fn walk_does_not_follow_a_directory_junction_in_objects() {
        use std::process::Command;
        let base = std::env::temp_dir().join(format!("kit-junction-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let objects = base.join("objects");
        let outside = base.join("outside");
        fs::create_dir_all(&objects).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("f.bin"), "x").unwrap();
        let made = Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(objects.join("link"))
            .arg(&outside)
            .output()
            .unwrap();
        if !made.status.success() {
            let _ = fs::remove_dir_all(&base);
            panic!(
                "mklink /J не спрацював: {}",
                String::from_utf8_lossy(&made.stdout)
            );
        }
        let mut error = None;
        let files = walk_dir(&objects, &mut error);
        // Знімаємо junction до видалення, щоб не зачепити цільову теку.
        let _ = fs::remove_dir(objects.join("link"));
        let _ = fs::remove_dir_all(&base);
        assert!(files.is_empty(), "junction обійдено");
        assert_eq!(error, None);
    }
}
