// Тести ядра git (ADR-0014; «байти порівняння й хешування») на справжньому git і
// синтетичному репозиторії: кирилиця й пробіл у шляху, бінарний блоб 262 байти з невалідним UTF-8,
// CRLF з BOM (вимір байтів).

use kit::git::{self, GitError};
use std::path::PathBuf;

const CYR_PATH: &str = "кирилиця/файл з пробілом.txt";
const BLOB_PATH: &str = "дані/блоб.bin";
const CRLF_BOM: &[u8] = b"\xEF\xBB\xBF\xD1\x80\xD1\x8F\xD0\xB4\xD0\xBE\xD0\xBA 1\r\n\xD1\x80\xD1\x8F\xD0\xB4\xD0\xBE\xD0\xBA 2\r\n";

/// 262 байти: усі значення 0..=255 і шість, що не є валідним UTF-8 у жодному контексті.
fn binary_blob() -> Vec<u8> {
    let mut b: Vec<u8> = (0..=255u8).collect();
    b.extend_from_slice(&[0xFF, 0xFE, 0xC3, 0x28, 0x80, 0x00]);
    assert_eq!(b.len(), 262);
    b
}

/// Тимчасова тека тесту; прибирається після тесту.
struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("kit-git-{name}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Репозиторій з одним комітом. `core.quotepath=true` і `core.autocrlf=false` — локально: перше
/// доводить, що `-c` ядра перекриває конфігурацію (і не залежить від глобальної на машині), друге —
/// що в git лежать саме ці байти.
fn fixture(name: &str) -> (TempDir, PathBuf) {
    let tmp = TempDir::new(name);
    let repo = tmp.0.join("репо з пробілом");
    std::fs::create_dir_all(&repo).unwrap();
    let ok = |args: &[&str], stdin: Option<&[u8]>| git::run(&repo, args, stdin, false).unwrap();
    ok(&["init", "-q"], None);
    ok(&["config", "core.quotepath", "true"], None);
    ok(&["config", "core.autocrlf", "false"], None);
    for (rel, bytes) in [(CYR_PATH, CRLF_BOM.to_vec()), (BLOB_PATH, binary_blob())] {
        let file = repo.join(rel);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, bytes).unwrap();
    }
    ok(&["add", "-A"], None);
    // Повідомлення коміту — через stdin ядра.
    ok(
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-F",
            "-",
        ],
        Some("коміт".as_bytes()),
    );
    (tmp, repo)
}

fn utf8(bytes: &[u8]) -> &str {
    std::str::from_utf8(bytes).expect("вивід git — UTF-8")
}

#[test]
fn cyrillic_paths_without_octal_escapes() {
    let (_tmp, repo) = fixture("octal");
    // Без -z: саме тут core.quotepath=true дав би "\320\272…" у лапках.
    let plain = git::run(&repo, &["ls-files"], None, false).unwrap();
    assert_eq!(
        utf8(&plain.stdout).lines().collect::<Vec<_>>(),
        vec![BLOB_PATH, CYR_PATH]
    );
    let z = git::run(&repo, &["ls-files", "-z"], None, false).unwrap();
    assert_eq!(z.stdout, format!("{BLOB_PATH}\0{CYR_PATH}\0").into_bytes());
}

#[test]
fn nul_records_keep_cyrillic() {
    let (_tmp, repo) = fixture("nul");
    let ls = git::run(&repo, &["ls-tree", "-r", "-z", "HEAD"], None, false).unwrap();
    let paths: Vec<&str> = ls
        .stdout
        .split(|b| *b == 0)
        .filter(|r| !r.is_empty())
        .map(|r| {
            utf8(r)
                .split_once('\t')
                .expect("запис ls-tree: <meta>\\t<шлях>")
                .1
        })
        .collect();
    assert_eq!(paths, vec![BLOB_PATH, CYR_PATH]);
}

#[test]
fn export_tree_is_byte_exact() {
    let (tmp, repo) = fixture("export");
    let dest = tmp.0.join("вивантаження");
    assert_eq!(git::export_tree(&repo, "HEAD", "", &dest).unwrap(), 2);
    assert_eq!(std::fs::read(dest.join(BLOB_PATH)).unwrap(), binary_blob());
    // BOM і CRLF — як у git: декодування як тексту зняло б BOM.
    assert_eq!(std::fs::read(dest.join(CYR_PATH)).unwrap(), CRLF_BOM);
}

#[test]
fn failure_contract() {
    let (_tmp, repo) = fixture("fail");
    let args = ["rev-parse", "--verify", "немає-такої-гілки"];
    // З дозволом — код і stderr як є.
    let allowed = git::run(&repo, &args, None, true).unwrap();
    assert_ne!(allowed.code, 0);
    assert!(
        !allowed.stderr.is_empty(),
        "git мав надрукувати причину в stderr"
    );
    // Без дозволу — помилка з дослівним stderr того самого виклику, не порожній результат.
    match git::run(&repo, &args, None, false) {
        Err(GitError::Failed { code, stderr, .. }) => {
            assert_eq!(code, Some(allowed.code));
            assert_eq!(stderr, allowed.stderr);
        }
        other => panic!("очікувалась GitError::Failed, отримано {other:?}"),
    }
}

#[test]
fn failure_stderr_is_byte_exact() {
    let (_tmp, repo) = fixture("fail-bytes");
    // Псевдонім-оболонка git друкує в stderr байти, що не є UTF-8: помилка несе їх дослівно.
    let args = [
        "-c",
        "alias.bad=!printf '\\377\\376збій' >&2; exit 3",
        "bad",
    ];
    match git::run(&repo, &args, None, false) {
        Err(GitError::Failed { code, stderr, .. }) => {
            assert_eq!(code, Some(3));
            assert_eq!(stderr, b"\xFF\xFE\xD0\xB7\xD0\xB1\xD1\x96\xD0\xB9".to_vec());
        }
        other => panic!("очікувалась GitError::Failed, отримано {other:?}"),
    }
}

/// `GIT_NO_LAZY_FETCH=1` ядра (ADR-0021 п. 3): у partial clone запит, якому бракує об'єкта, не
/// ходить до promisor-віддаленого, а одразу завершується помилкою. Контроль, що тест уміє впасти: той самий запит
/// голим git без змінної намагається fetch (stderr «could not fetch … from promisor remote»).
#[test]
fn partial_clone_missing_object_fails_fast_without_lazy_fetch() {
    let tmp = TempDir::new("lazy-fetch");
    let src = tmp.0.join("src");
    std::fs::create_dir_all(&src).unwrap();
    let ok = |dir: &std::path::Path, args: &[&str]| git::run(dir, args, None, false).unwrap();
    ok(&src, &["init", "-q"]);
    std::fs::write(src.join("a.txt"), "вміст блоба\n").unwrap();
    ok(&src, &["add", "a.txt"]);
    ok(
        &src,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "i",
        ],
    );
    let blob = utf8(&ok(&src, &["rev-parse", "HEAD:a.txt"]).stdout)
        .trim()
        .to_string();
    let bare = tmp.0.join("bare.git");
    let bare_s = bare.to_str().unwrap();
    ok(&tmp.0, &["clone", "-q", "--bare", "src", bare_s]);
    ok(&bare, &["config", "uploadpack.allowFilter", "true"]);
    let url = format!("file:///{}", bare_s.replace('\\', "/"));
    let part = tmp.0.join("part");
    ok(
        &tmp.0,
        &[
            "clone",
            "-q",
            "--filter=blob:none",
            "--no-checkout",
            &url,
            part.to_str().unwrap(),
        ],
    );
    // promisor-віддалений — на неіснуючий шлях: будь-яка спроба fetch видна в stderr.
    let gone = tmp.0.join("нема.git");
    ok(
        &part,
        &["remote", "set-url", "origin", gone.to_str().unwrap()],
    );
    let args = ["cat-file", "-p", blob.as_str()];

    // Контроль: без змінної git справді пробує lazy fetch.
    let raw = std::process::Command::new("git")
        .arg("-C")
        .arg(&part)
        .args(args)
        .env_remove("GIT_NO_LAZY_FETCH")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    let raw_err = String::from_utf8_lossy(&raw.stderr);
    assert!(!raw.status.success());
    assert!(
        raw_err.contains("promisor remote"),
        "контроль: без GIT_NO_LAZY_FETCH git мав спробувати fetch: {raw_err}"
    );

    // Ядро: помилка без спроби fetch.
    let started = std::time::Instant::now();
    match git::run(&part, &args, None, false) {
        Err(GitError::Failed { stderr, .. }) => {
            let text = String::from_utf8_lossy(&stderr);
            assert!(!text.contains("promisor"), "ядро пробувало fetch: {text}");
            assert!(!text.contains("fetch"), "ядро пробувало fetch: {text}");
        }
        other => panic!("очікувалась GitError::Failed, отримано {other:?}"),
    }
    assert!(started.elapsed() < std::time::Duration::from_secs(5));
}
