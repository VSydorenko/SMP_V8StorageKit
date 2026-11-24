// Тести бібліотеки `session_check` (блок B4, задача 1): читання сховища (обхід, `partial-read`, стеля, паралельність),
// відбиток (читання схеми 1, звірка без допуску), знімок git-стану й `GitProblem`. Лише синтетичні сховища й
// репозиторії у тимчасових теках; мережі й справжнього SMB немає (стеля — через шов `start_reading_with`).

use kit::session_check::activity::{
    Activity, NotStorage, ReadErrorClass, StorageReading, Unavailable, read_storage,
    start_reading_with,
};
use kit::session_check::imprint::{self, Imprint};
use kit::session_check::snapshot::snapshot;
use kit::session_check::ticks;
use kit::storage_branch;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("kit-sc-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const UNIX_EPOCH_TICKS: i64 = 621_355_968_000_000_000;

/// Тики для `секунди + нс` від епохи Unix — незалежно від коду крейта.
fn ticks_of(secs: u64, nanos: u32) -> i64 {
    UNIX_EPOCH_TICKS + (secs as i64) * 10_000_000 + i64::from(nanos / 100)
}

fn system_time(ticks_value: i64) -> SystemTime {
    let since = ticks_value - UNIX_EPOCH_TICKS;
    UNIX_EPOCH
        + Duration::new(
            (since / 10_000_000) as u64,
            (since % 10_000_000) as u32 * 100,
        )
}

/// Файл із заданим часом запису (у тиках).
fn write_file(path: &Path, content: &str, mtime_ticks: i64) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    f.set_modified(system_time(mtime_ticks)).unwrap();
}

fn set_hidden(path: &Path) {
    let status = Command::new("attrib").arg("+H").arg(path).status().unwrap();
    assert!(status.success(), "attrib +H {path:?}");
}

const T0: i64 = 1_700_000_000;

fn base_time() -> i64 {
    ticks_of(T0 as u64, 123_456_700)
}

fn activity_of(reading: StorageReading) -> Activity {
    match reading {
        StorageReading::Read(a) => a,
        other => panic!("очікувалось Read, є {other:?}"),
    }
}

/// Сховище: `1cv8ddb.1CD`, три об'єкти (час T, T+10 с, T+20 с) і два pack-файли в двох теках.
fn make_storage(root: &Path) {
    write_file(&root.join("1cv8ddb.1CD"), "db", base_time());
    write_file(&root.join("data/objects/a/o1.bin"), "1", base_time());
    write_file(
        &root.join("data/objects/a/b/o2.bin"),
        "22",
        base_time() + 100_000_000,
    );
    write_file(
        &root.join("data/objects/c/o3.bin"),
        "333",
        base_time() + 200_000_000,
    );
    write_file(&root.join("data/pack/p1.pack"), "pppp", base_time() + 5);
    write_file(
        &root.join("data/pack/sub/p2.pack"),
        "qq",
        base_time() + 300_000_000,
    );
}

#[test]
fn walk_reads_every_file_except_hidden_and_keeps_100ns_ticks() {
    let tmp = TempDir::new("walk");
    make_storage(&tmp.0);
    // Приховані файл і тека: PowerShell `Get-ChildItem -Recurse -File` без `-Force` їх не бачить; вони новіші за все,
    // тож якщо обхід їх підхопить, час і перелік pack зсунуться.
    let hidden_file = tmp.0.join("data/objects/hidden.bin");
    write_file(&hidden_file, "h", base_time() + 900_000_000);
    set_hidden(&hidden_file);
    let hidden_dir = tmp.0.join("data/pack/hid");
    write_file(
        &hidden_dir.join("inside.pack"),
        "x",
        base_time() + 900_000_000,
    );
    set_hidden(&hidden_dir);

    let a = activity_of(read_storage(tmp.0.to_str().unwrap()));
    assert!(a.read_complete());
    assert_eq!(a.partial, None);
    assert_eq!(a.latest_object_write, Some(base_time() + 200_000_000));
    assert_eq!(a.latest_pack_write, Some(base_time() + 300_000_000));
    let packs: Vec<(&str, i64, i64)> = a
        .pack_files
        .iter()
        .map(|p| (p.name.as_str(), p.length, p.last_write_ticks))
        .collect();
    assert_eq!(
        packs,
        vec![
            ("p1.pack", 4, base_time() + 5),
            ("p2.pack", 2, base_time() + 300_000_000)
        ]
    );
    // Значення часу — рівно ті тики, що задано: 100-нс крок не втрачається.
    assert_eq!(base_time() % 10_000_000, 1_234_567);
}

#[test]
fn directory_states_and_server_address() {
    let tmp = TempDir::new("states");
    // Немає каталогу, шлях — файл, сервер.
    assert_eq!(
        read_storage(tmp.0.join("nope").to_str().unwrap()),
        StorageReading::Unavailable(Unavailable::Missing)
    );
    let file = tmp.0.join("f.txt");
    std::fs::write(&file, "x").unwrap();
    assert_eq!(
        read_storage(file.to_str().unwrap()),
        StorageReading::Unavailable(Unavailable::Missing)
    );
    assert_eq!(
        read_storage("tcp://user:pw@host/repo"),
        StorageReading::Server
    );
    // Каталог без 1CD; з 1CD, але без жодного файла версії.
    let plain = tmp.0.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let a = activity_of(read_storage(plain.to_str().unwrap()));
    assert!(!a.is_storage);
    assert_eq!(a.not_storage, Some(NotStorage::NoDatabase));
    let empty = tmp.0.join("empty");
    write_file(&empty.join("1cv8ddb.1CD"), "db", base_time());
    std::fs::create_dir_all(empty.join("data/objects")).unwrap();
    let a = activity_of(read_storage(empty.to_str().unwrap()));
    assert!(!a.is_storage);
    assert_eq!(a.not_storage, Some(NotStorage::NoVersions));
    // Усе запаковано: порожня data/objects при наявних pack — сховище.
    let packed = tmp.0.join("packed");
    write_file(&packed.join("1cv8ddb.1CD"), "db", base_time());
    write_file(&packed.join("data/pack/p.pack"), "p", base_time());
    let a = activity_of(read_storage(packed.to_str().unwrap()));
    assert!(a.is_storage);
    assert_eq!(a.latest_object_write, None);
}

/// Забороняє читання підтеки на час життя; знімається завжди — і при паніці тесту.
struct DenyRead {
    dir: PathBuf,
    who: String,
}

impl DenyRead {
    fn new(dir: &Path) -> Self {
        let who = format!(
            "{}\\{}",
            std::env::var("USERDOMAIN").unwrap_or_else(|_| ".".into()),
            std::env::var("USERNAME").unwrap()
        );
        let status = Command::new("icacls")
            .arg(dir)
            .arg("/deny")
            .arg(format!("{who}:(OI)(CI)R"))
            .output()
            .unwrap();
        assert!(
            status.status.success(),
            "icacls /deny: {}",
            String::from_utf8_lossy(&status.stdout)
        );
        DenyRead {
            dir: dir.to_path_buf(),
            who,
        }
    }
}

impl Drop for DenyRead {
    fn drop(&mut self) {
        let _ = Command::new("icacls")
            .arg(&self.dir)
            .arg("/remove:d")
            .arg(&self.who)
            .output();
    }
}

#[test]
fn error_in_the_middle_of_the_walk_is_partial_read_without_a_path() {
    let tmp = TempDir::new("partial");
    make_storage(&tmp.0);
    let locked = tmp.0.join("data/objects/a/b");
    // Контроль: до заборони обхід повний.
    let before = activity_of(read_storage(tmp.0.to_str().unwrap()));
    assert!(before.read_complete());
    // Змінна часу: `deny` оголошено ПІСЛЯ `tmp`, тож знімається першим.
    let _deny = DenyRead::new(&locked);
    let a = activity_of(read_storage(tmp.0.to_str().unwrap()));
    assert_eq!(a.partial, Some(ReadErrorClass::AccessDenied));
    assert!(!a.read_complete());
    assert_eq!(a.partial.unwrap().label(), "немає доступу");
}

#[test]
fn slow_read_past_the_ceiling_is_unavailable_not_partial() {
    let slow = |_: &str| {
        std::thread::sleep(Duration::from_secs(3));
        StorageReading::Server
    };
    let started = Instant::now();
    let reading = start_reading_with("C:\\slow", Duration::from_millis(300), slow).wait();
    assert_eq!(reading, StorageReading::Unavailable(Unavailable::NoAnswer));
    assert!(started.elapsed() < Duration::from_secs(2));
    // Контроль: швидке читання в межах стелі віддає свій результат.
    let fast = |_: &str| StorageReading::Unavailable(Unavailable::Denied);
    assert_eq!(
        start_reading_with("C:\\fast", Duration::from_millis(300), fast).wait(),
        StorageReading::Unavailable(Unavailable::Denied)
    );
    // Серверна адреса потоку не стартує: шов не викликається.
    let boom = |_: &str| -> StorageReading { panic!("не мало викликатись") };
    assert_eq!(
        start_reading_with("https://h/r", Duration::from_millis(300), boom).wait(),
        StorageReading::Server
    );
}

#[test]
fn several_hanging_sources_cost_one_ceiling_not_a_sum() {
    let ceiling = Duration::from_millis(600);
    let started = Instant::now();
    let pending: Vec<_> = (0..4)
        .map(|i| {
            start_reading_with(&format!("C:\\s{i}"), ceiling, |_| {
                std::thread::sleep(Duration::from_secs(4));
                StorageReading::Server
            })
        })
        .collect();
    let readings: Vec<_> = pending.into_iter().map(|p| p.wait()).collect();
    let elapsed = started.elapsed();
    assert!(
        readings
            .iter()
            .all(|r| *r == StorageReading::Unavailable(Unavailable::NoAnswer))
    );
    assert!(elapsed >= Duration::from_millis(550), "{elapsed:?}");
    // Послідовно було б 4 × 600 мс = 2,4 с.
    assert!(elapsed < Duration::from_millis(1500), "{elapsed:?}");
}

fn o_format(t: i64) -> String {
    let secs = ticks::format_utc(t).replace(' ', "T");
    format!("{secs}.{:07}Z", t.rem_euclid(10_000_000))
}

/// Відбиток точно як пише `Write-KitStorageImprint` (схема 1).
fn write_imprint(repo: &Path, key: &str, storage_path: &str, version: i64, a: &Activity) {
    let packs: Vec<_> = a
        .pack_files
        .iter()
        .map(|p| json!({"name": p.name, "length": p.length, "lastWriteUtc": o_format(p.last_write_ticks)}))
        .collect();
    let doc = json!({
        "schema": 1, "key": key, "storagePath": storage_path, "version": version,
        "readAtUtc": o_format(base_time() + 1_000_000_000),
        "latestObjectWriteUtc": a.latest_object_write.map(o_format),
        "packFiles": packs,
    });
    let path = repo.join("build/session-check").join(format!("{key}.json"));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
}

fn current(repo: &Path, key: &str, path: &str, mirror: u64, reading: &StorageReading) -> bool {
    match imprint::read_imprint(repo, key) {
        Some(i) => imprint::is_current(&i, key, path, mirror, reading),
        None => false,
    }
}

#[test]
fn imprint_is_current_only_on_an_untouched_disk() {
    let tmp = TempDir::new("imprint");
    let storage = tmp.0.join("st");
    let repo = tmp.0.join("repo");
    make_storage(&storage);
    let path = storage.to_str().unwrap().to_string();
    let reading = read_storage(&path);
    let a = activity_of(reading.clone());
    write_imprint(&repo, "k", &path, 7, &a);

    // Актуальний; регістр і роздільники шляху не важливі, версія дзеркала не вища.
    assert!(current(&repo, "k", &path, 7, &reading));
    let loose = format!("{}/", path.replace('\\', "/").to_uppercase());
    assert!(current(&repo, "k", &loose, 5, &reading));
    // Версія відбитка менша за версію дзеркала — відбитка немає.
    assert!(!current(&repo, "k", &path, 8, &reading));
    // Чужий шлях і чужий ключ.
    assert!(!current(&repo, "k", "C:\\other", 7, &reading));
    assert!(!current(&repo, "z", &path, 7, &reading));

    // Зсув часу одного pack-файла на 1 тик (100 нс) — не актуальний: допуску немає.
    write_file(
        &storage.join("data/pack/p1.pack"),
        "pppp",
        base_time() + 5 + 1,
    );
    let shifted = read_storage(&path);
    assert!(!current(&repo, "k", &path, 7, &shifted));
    // Повернули час — знову актуальний (контроль, що зсув був причиною).
    write_file(&storage.join("data/pack/p1.pack"), "pppp", base_time() + 5);
    assert!(current(&repo, "k", &path, 7, &read_storage(&path)));

    // Той самий час, інша довжина .pack — не актуальний.
    write_file(
        &storage.join("data/pack/p1.pack"),
        "pppp-longer",
        base_time() + 5,
    );
    assert!(!current(&repo, "k", &path, 7, &read_storage(&path)));
    write_file(&storage.join("data/pack/p1.pack"), "pppp", base_time() + 5);
    assert!(current(&repo, "k", &path, 7, &read_storage(&path)));

    // Новий .pack.
    write_file(&storage.join("data/pack/p3.pack"), "n", base_time());
    assert!(!current(&repo, "k", &path, 7, &read_storage(&path)));
    std::fs::remove_file(storage.join("data/pack/p3.pack")).unwrap();

    // Час найновішого об'єкта.
    write_file(
        &storage.join("data/objects/c/o3.bin"),
        "333",
        base_time() + 200_000_001,
    );
    assert!(!current(&repo, "k", &path, 7, &read_storage(&path)));
}

#[test]
fn duplicate_pack_names_and_unread_storage_are_never_current() {
    let tmp = TempDir::new("imprint-dup");
    let storage = tmp.0.join("st");
    let repo = tmp.0.join("repo");
    make_storage(&storage);
    let path = storage.to_str().unwrap().to_string();

    // Імена без регістру: відбиток із великими літерами збігається з диском.
    let a = activity_of(read_storage(&path));
    let mut upper = a.clone();
    for p in &mut upper.pack_files {
        p.name = p.name.to_uppercase();
    }
    write_imprint(&repo, "k", &path, 1, &upper);
    assert!(current(&repo, "k", &path, 1, &StorageReading::Read(a)));

    // Дубль імені з різних підтек (інший регістр) — не актуальний, навіть якщо відбиток зняли з такого ж диска.
    write_file(
        &storage.join("data/pack/sub/P1.PACK"),
        "pppp",
        base_time() + 5,
    );
    let dup = read_storage(&path);
    write_imprint(&repo, "k", &path, 1, &activity_of(dup.clone()));
    assert!(!current(&repo, "k", &path, 1, &dup));
    std::fs::remove_file(storage.join("data/pack/sub/P1.PACK")).unwrap();

    // tcp:// — ніколи: відбиток із порожнім станом диска, що збігається з порожнім читанням, не дає «синхронне».
    let server = "tcp://srv/repo";
    let empty = Activity {
        is_storage: true,
        not_storage: None,
        latest_object_write: None,
        latest_pack_write: None,
        pack_files: Vec::new(),
        partial: None,
    };
    write_imprint(&repo, "s", server, 3, &empty);
    assert!(!current(&repo, "s", server, 3, &read_storage(server)));
    // Навіть із підставленою «повною» активністю адреса сервера не дає актуального.
    assert!(!current(
        &repo,
        "s",
        server,
        3,
        &StorageReading::Read(empty.clone())
    ));

    // Обхід, що не прочитав сховище: partial, не схоже на сховище, недоступне.
    write_imprint(&repo, "k", &path, 1, &activity_of(read_storage(&path)));
    let mut partial = activity_of(read_storage(&path));
    partial.partial = Some(ReadErrorClass::Other);
    assert!(!current(
        &repo,
        "k",
        &path,
        1,
        &StorageReading::Read(partial)
    ));
    let mut unclear = activity_of(read_storage(&path));
    unclear.is_storage = false;
    assert!(!current(
        &repo,
        "k",
        &path,
        1,
        &StorageReading::Read(unclear)
    ));
    assert!(!current(
        &repo,
        "k",
        &path,
        1,
        &StorageReading::Unavailable(Unavailable::NoAnswer)
    ));
}

#[test]
fn unreadable_imprints_are_absent_and_dates_parse_exactly() {
    let tmp = TempDir::new("imprint-bad");
    let dir = tmp.0.join("build/session-check");
    std::fs::create_dir_all(&dir).unwrap();
    assert!(imprint::read_imprint(&tmp.0, "none").is_none());
    std::fs::write(dir.join("broken.json"), "{ not json").unwrap();
    assert!(imprint::read_imprint(&tmp.0, "broken").is_none());
    std::fs::write(
        dir.join("old.json"),
        r#"{"schema":2,"key":"old","storagePath":"p","version":1,"readAtUtc":"2026-11-24T10:20:30.1234567Z","latestObjectWriteUtc":null,"packFiles":[]}"#,
    )
    .unwrap();
    assert!(imprint::read_imprint(&tmp.0, "old").is_none());
    std::fs::write(
        dir.join("baddate.json"),
        r#"{"schema":1,"key":"baddate","storagePath":"p","version":1,"readAtUtc":"yesterday","latestObjectWriteUtc":null,"packFiles":[]}"#,
    )
    .unwrap();
    assert!(imprint::read_imprint(&tmp.0, "baddate").is_none());
    // Ключ, що виходить за теку відбитків, не читається.
    assert!(imprint::read_imprint(&tmp.0, "..\\x").is_none());
    // Правильний файл читається, дата — рівно тими тиками, що дає .NET (значення зняті з PowerShell).
    std::fs::write(
        dir.join("ok.json"),
        r#"{"schema":1,"key":"ok","storagePath":"p","version":4,"readAtUtc":"2026-11-24T10:20:30.1234567Z","latestObjectWriteUtc":null,"packFiles":[]}"#,
    )
    .unwrap();
    let ok: Imprint = imprint::read_imprint(&tmp.0, "ok").unwrap();
    assert_eq!(ok.read_at_ticks, 639_311_124_301_234_567);
    assert_eq!(ok.version, 4);
    assert_eq!(
        ticks::parse_iso("2026-05-01T10:00:00+02:00"),
        Some(639_132_192_000_000_000)
    );
    assert_eq!(
        ticks::parse_iso("1999-12-31T23:59:59-05:30"),
        Some(630_823_013_990_000_000)
    );
    assert_eq!(
        ticks::parse_iso("2026-11-24T10:20:30Z"),
        Some(639_311_124_300_000_000)
    );
    assert_eq!(ticks::parse_iso("2026-11-24 10:20"), None);
    assert_eq!(
        ticks::format_utc(639_311_124_301_234_567),
        "2026-11-24 10:20:30"
    );
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn git_out(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success());
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn mirror_commit(dir: &Path, version: u32, date: &str) {
    git(
        dir,
        &[
            "commit",
            "-q",
            "--allow-empty",
            "--date",
            date,
            "-m",
            &format!("v{version}"),
            "-m",
            &format!("Storage-Source: k\nStorage-Version: {version}"),
        ],
    );
}

/// Репозиторій: `main` з першим комітом і гілка `storage/k` від нього з версіями 1..=n.
fn repo_with_mirror(dir: &Path, versions: u32) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", "main"]);
    git(dir, &["commit", "-q", "--allow-empty", "-m", "init"]);
    git(dir, &["checkout", "-q", "-b", "storage/k"]);
    for v in 1..=versions {
        mirror_commit(dir, v, "2026-05-01T10:00:00+02:00");
    }
    git(dir, &["checkout", "-q", "main"]);
}

#[test]
fn snapshot_reads_the_mirror_main_and_origin_once() {
    let tmp = TempDir::new("snap");
    repo_with_mirror(&tmp.0, 3);
    let tip = git_out(&tmp.0, &["rev-parse", "storage/k"]);
    let main = git_out(&tmp.0, &["rev-parse", "main"]);

    let s = snapshot(&tmp.0, "storage/k", "main").unwrap();
    assert_eq!(s.mirror_sha.as_deref(), Some(tip.as_str()));
    assert_eq!(s.main_sha.as_deref(), Some(main.as_str()));
    assert_eq!(s.origin_sha, None);
    assert_eq!(s.last_version, Some(3));
    // Дата автора вершини: 10:00+02:00 = 08:00 UTC.
    assert_eq!(
        s.last_mirror_ticks,
        ticks::parse_iso("2026-05-01T08:00:00Z")
    );
    assert_eq!(s.unmerged, 3);
    assert!(!s.main_missing && !s.remote_only);
    assert!(!s.origin_gap.has_remote);

    // origin/<гілка> на два коміти позаду локальної: ahead 2, behind 0.
    git(
        &tmp.0,
        &["update-ref", "refs/remotes/origin/storage/k", "storage/k~2"],
    );
    let s = snapshot(&tmp.0, "storage/k", "main").unwrap();
    assert!(s.origin_gap.has_remote);
    assert_eq!((s.origin_gap.ahead, s.origin_gap.behind), (2, 0));
    let gap = storage_branch::origin_gap(&tmp.0, "storage/k").unwrap();
    assert_eq!(gap, s.origin_gap);

    // Допоміжні функції модуля `storage_branch`.
    assert_eq!(
        storage_branch::last_storage_version(&tmp.0, "storage/k").unwrap(),
        Some(3)
    );
    assert_eq!(
        storage_branch::last_storage_version(&tmp.0, "storage/none").unwrap(),
        None
    );
    assert!(!storage_branch::remote_only(&tmp.0, "storage/k").unwrap());
    assert_eq!(
        storage_branch::restore_mirror_step("storage/k"),
        "git branch --track storage/k origin/storage/k"
    );
}

#[test]
fn remote_only_mirror_and_unborn_main() {
    let tmp = TempDir::new("snap-states");
    repo_with_mirror(&tmp.0, 2);
    // Локальну гілку прибрано, на origin вона є.
    git(
        &tmp.0,
        &["update-ref", "refs/remotes/origin/storage/k", "storage/k"],
    );
    git(&tmp.0, &["branch", "-q", "-D", "storage/k"]);
    let s = snapshot(&tmp.0, "storage/k", "main").unwrap();
    assert!(s.remote_only);
    assert_eq!(s.mirror_sha, None);
    assert_eq!(s.unmerged, 0);
    assert!(storage_branch::remote_only(&tmp.0, "storage/k").unwrap());

    // Свіжий репозиторій: HEAD на ненародженій main, дзеркало є.
    let fresh = TempDir::new("snap-unborn");
    std::fs::create_dir_all(&fresh.0).unwrap();
    git(&fresh.0, &["init", "-q", "-b", "storage/k"]);
    mirror_commit(&fresh.0, 1, "2026-05-01T10:00:00+02:00");
    git(&fresh.0, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let s = snapshot(&fresh.0, "storage/k", "main").unwrap();
    assert!(s.main_missing && s.main_unborn);
    assert_eq!(s.unmerged, 1);
}

#[test]
fn git_failure_is_a_git_problem_with_verbatim_stderr() {
    let tmp = TempDir::new("snap-broken");
    repo_with_mirror(&tmp.0, 1);
    // Контроль: до поломки знімок читається.
    assert!(snapshot(&tmp.0, "storage/k", "main").is_ok());
    git(&tmp.0, &["config", "core.repositoryformatversion", "99"]);
    let problem = snapshot(&tmp.0, "storage/k", "main").unwrap_err();
    assert!(
        problem
            .0
            .contains("Expected git repo version <= 1, found 99"),
        "{problem}"
    );
    assert!(
        !problem.0.to_lowercase().contains("немає гілки"),
        "{problem}"
    );
    // Те саме для `remote_only`: збій git — Err, а не «ні».
    assert!(storage_branch::remote_only(&tmp.0, "storage/k").is_err());
}

#[test]
fn mirror_tip_without_a_numeric_version_is_a_git_problem() {
    let tmp = TempDir::new("snap-trailer");
    std::fs::create_dir_all(&tmp.0).unwrap();
    git(&tmp.0, &["init", "-q", "-b", "main"]);
    git(&tmp.0, &["commit", "-q", "--allow-empty", "-m", "init"]);
    git(&tmp.0, &["branch", "storage/k"]);
    let problem = snapshot(&tmp.0, "storage/k", "main").unwrap_err();
    assert!(problem.0.contains("Storage-Version"), "{problem}");
}

#[test]
fn missing_commit_object_of_the_mirror_is_a_git_problem_not_a_missing_ref() {
    // `rev-parse --verify --quiet <ref>^{commit}` на відсутньому об'єкті мовчить із кодом 1 — зламане дзеркало
    // виглядало б як «гілки немає» (порада `kit sync -Apply` будує другу історію). Знімок мусить дати GitProblem.
    let tmp = TempDir::new("snap-missing-object");
    repo_with_mirror(&tmp.0, 1);
    let tip = git_out(&tmp.0, &["rev-parse", "storage/k"]);
    assert!(snapshot(&tmp.0, "storage/k", "main").is_ok());
    let object = tmp
        .0
        .join(".git")
        .join("objects")
        .join(&tip[..2])
        .join(&tip[2..]);
    // Файли об'єктів git лише для читання (Windows не дає їх видалити); тека — тимчасова, прав на Unix не торкаємось.
    #[allow(clippy::permissions_set_readonly_false)]
    fn make_writable(path: &Path) {
        let mut perm = std::fs::metadata(path).unwrap().permissions();
        perm.set_readonly(false);
        std::fs::set_permissions(path, perm).unwrap();
    }
    make_writable(&object);
    std::fs::remove_file(&object).unwrap();
    let problem = snapshot(&tmp.0, "storage/k", "main").unwrap_err();
    assert!(problem.0.contains("bad object"), "{problem}");
}

#[test]
fn json_dates_follow_powershell_convertto_json() {
    // 2026-01-10T08:00:00Z без дробу; з дробом — рівно 7 цифр, включно з нулями наприкінці.
    let base = ticks::parse_iso("2026-01-10T08:00:00Z").unwrap();
    assert_eq!(ticks::format_iso(base), "2026-01-10T08:00:00Z");
    assert_eq!(
        ticks::format_iso(base + 1_234_567),
        "2026-01-10T08:00:00.1234567Z"
    );
    assert_eq!(
        ticks::format_iso(base + 1_200_000),
        "2026-01-10T08:00:00.1200000Z"
    );
    assert_eq!(ticks::format_iso(base + 1), "2026-01-10T08:00:00.0000001Z");
}
