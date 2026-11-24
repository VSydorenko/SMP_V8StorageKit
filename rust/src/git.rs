// Ядро git (ADR-0014) — ЄДИНЕ місце, де Rust-код kit запускає git; поза цим модулем
// запуск git ловить запобіжник rust/tests/git_guard.rs.
//
// Кожен запуск: `git -C <repo> -c core.quotepath=false <аргументи>`, `GIT_TERMINAL_PROMPT=0`, решта
// оточення успадкована. Вивід — байти, без декодування: текстове декодування псує бінарні блоби
// (262 байти → 524) і знімало б BOM на початку потоку (виміряно). Контракт збою явний: ненульовий
// код без дозволу — помилка з дослівним stderr git; з дозволом — `Output` з кодом. Режиму «тихо
// порожньо» немає.
//
// Два входи: `run` збирає весь вивід; `start` — потоковий процес (stdin/stdout каналами) для
// байтового обміну `cat-file --batch`, де збирання всього stdout тримало б у пам'яті все джерело.

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Component, Path};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::thread::JoinHandle;

/// Зібраний результат git: код і сирі байти потоків.
#[derive(Debug)]
pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug)]
pub enum GitError {
    /// git не запустився.
    Spawn { args: String, source: io::Error },
    /// Ненульовий код без дозволу; `stderr` — дослівно байти, які надрукував git (декодуються лише в `Display`).
    Failed {
        args: String,
        code: Option<i32>,
        stderr: Vec<u8>,
    },
    /// Збій вводу-виводу поза git (канал, файл призначення).
    Io { context: String, source: io::Error },
    /// git відповів не за протоколом (рядок `ls-tree`, заголовок `cat-file`) або вхід недопустимий.
    Protocol(String),
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GitError::Spawn { args, source } => write!(f, "git {args} не запустився: {source}"),
            GitError::Failed { args, code, stderr } => {
                let code = code.map_or_else(|| "без коду".to_string(), |c| c.to_string());
                write!(
                    f,
                    "git {args} завершився з кодом {code}: {}",
                    String::from_utf8_lossy(stderr).trim_end()
                )
            }
            GitError::Io { context, source } => write!(f, "{context}: {source}"),
            GitError::Protocol(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for GitError {}

fn describe<S: AsRef<OsStr>>(args: &[S]) -> String {
    args.iter()
        .map(|a| a.as_ref().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

fn command<S: AsRef<OsStr>>(repo: &Path, args: &[S]) -> Command {
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(repo)
        .arg("-c")
        .arg("core.quotepath=false");
    cmd.args(args);
    cmd.env("GIT_TERMINAL_PROMPT", "0");
    cmd
}

/// Зібраний вхід: запускає git, віддає `stdin` (якщо є) і чекає завершення. Ненульовий код без
/// `allow_fail` — `GitError::Failed` з дослівним stderr.
pub fn run<S: AsRef<OsStr>>(
    repo: &Path,
    args: &[S],
    stdin: Option<&[u8]>,
    allow_fail: bool,
) -> Result<Output, GitError> {
    let mut cmd = command(repo, args);
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|source| GitError::Spawn {
        args: describe(args),
        source,
    })?;
    // stdin пише окремий потік: git може писати stdout, не дочитавши вхід, і обидва канали заповнились би.
    let writer = match (stdin, child.stdin.take()) {
        (Some(bytes), Some(mut pipe)) => {
            let bytes = bytes.to_vec();
            Some(std::thread::spawn(move || pipe.write_all(&bytes)))
        }
        _ => None,
    };
    let out = child.wait_with_output().map_err(|source| GitError::Io {
        context: format!("git {}", describe(args)),
        source,
    })?;
    if let Some(w) = writer {
        // Обірваний канал означає, що git вийшов, не дочитавши: про це скаже його код і stderr.
        match w.join() {
            Ok(Err(e)) if e.kind() != io::ErrorKind::BrokenPipe => {
                return Err(GitError::Io {
                    context: format!("stdin git {}", describe(args)),
                    source: e,
                });
            }
            _ => {}
        }
    }
    let code = out.status.code();
    if code != Some(0) && !allow_fail {
        return Err(GitError::Failed {
            args: describe(args),
            code,
            stderr: out.stderr,
        });
    }
    Ok(Output {
        code: code.unwrap_or(-1),
        stdout: out.stdout,
        stderr: out.stderr,
    })
}

/// Потоковий процес git: stdin і stdout — канали для обміну запит-відповідь, stderr збирає
/// окремий потік (обсяг невідомий — непрочитаний канал зупинив би git).
pub struct Stream {
    args: String,
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: Option<ChildStdout>,
    stderr: Option<JoinHandle<Vec<u8>>>,
}

/// Потоковий вхід: запускає git і віддає канали.
pub fn start<S: AsRef<OsStr>>(repo: &Path, args: &[S]) -> Result<Stream, GitError> {
    let mut cmd = command(repo, args);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|source| GitError::Spawn {
        args: describe(args),
        source,
    })?;
    let stderr = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            buf
        })
    });
    Ok(Stream {
        args: describe(args),
        stdin: child.stdin.take(),
        stdout: child.stdout.take(),
        child,
        stderr,
    })
}

impl Stream {
    /// Канали процесу: (stdin, stdout).
    pub fn pipes(&mut self) -> (&mut ChildStdin, &mut ChildStdout) {
        (
            self.stdin.as_mut().expect("stdin відкритий до finish"),
            self.stdout.as_mut().expect("stdout відкритий до finish"),
        )
    }

    /// Закриває канали (git, що ще пише відповідь, отримує обірваний канал і виходить — без зависання
    /// на непрочитаному stdout), чекає завершення. Контракт збою — як у `run`; повертає код.
    pub fn finish(mut self, allow_fail: bool) -> Result<i32, GitError> {
        self.stdin.take();
        self.stdout.take();
        let status = self.child.wait().map_err(|source| GitError::Io {
            context: format!("git {}", self.args),
            source,
        })?;
        let stderr = self
            .stderr
            .take()
            .and_then(|h| h.join().ok())
            .unwrap_or_default();
        let code = status.code();
        if code != Some(0) && !allow_fail {
            return Err(GitError::Failed {
                args: std::mem::take(&mut self.args),
                code,
                stderr,
            });
        }
        Ok(code.unwrap_or(-1))
    }
}

impl Drop for Stream {
    /// Незавершений потік (вихід з помилкою посеред обміну): закрити канали й не лишити процес.
    fn drop(&mut self) {
        if self.stdin.take().is_some() | self.stdout.take().is_some() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

/// Дерево `<rev>:<repo_path>` у теку `dest` — байт у байт із блобів git (git archive і checkout
/// застосовують eol-конверсію з .gitattributes, а потрібне те, що ЛЕЖИТЬ у git). Один процес
/// `cat-file --batch`, запит-відповідь по блобу. Повертає кількість записаних файлів.
///
/// Тек не видаляє (#34): `dest` має не існувати або бути порожньою текою.
pub fn export_tree(
    repo: &Path,
    rev: &str,
    repo_path: &str,
    dest: &Path,
) -> Result<usize, GitError> {
    let io_err = |context: String| move |source| GitError::Io { context, source };
    if dest.exists() {
        let mut entries =
            std::fs::read_dir(dest).map_err(io_err(format!("тека {}", dest.display())))?;
        if entries.next().is_some() {
            return Err(GitError::Protocol(format!(
                "тека вивантаження {} не порожня",
                dest.display()
            )));
        }
    }
    std::fs::create_dir_all(dest).map_err(io_err(format!("тека {}", dest.display())))?;

    let prefix = repo_path
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    let mut ls_args: Vec<OsString> = vec![
        "ls-tree".into(),
        "-r".into(),
        "-z".into(),
        rev.into(),
        "--".into(),
    ];
    if !prefix.is_empty() {
        ls_args.push(prefix.clone().into());
    }
    let ls = run(repo, &ls_args, None, false)?;

    let mut blobs = Vec::new();
    for record in ls.stdout.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let bad = || {
            GitError::Protocol(format!(
                "нерозпізнаний запис git ls-tree: {:?}",
                String::from_utf8_lossy(record)
            ))
        };
        let tab = record.iter().position(|b| *b == b'\t').ok_or_else(bad)?;
        let meta = std::str::from_utf8(&record[..tab]).map_err(|_| bad())?;
        let path = std::str::from_utf8(&record[tab + 1..]).map_err(|_| {
            GitError::Protocol(format!(
                "шлях git ls-tree — не UTF-8: {:?}",
                String::from_utf8_lossy(record)
            ))
        })?;
        let mut parts = meta.split(' ');
        let (Some(_mode), Some(kind), Some(oid), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(bad());
        };
        if kind != "blob" {
            continue;
        }
        let rel = if prefix.is_empty() {
            path
        } else {
            path.strip_prefix(prefix.as_str())
                .and_then(|r| r.strip_prefix('/'))
                .ok_or_else(bad)?
        };
        let rel_path = Path::new(rel);
        if rel.is_empty()
            || !rel_path
                .components()
                .all(|c| matches!(c, Component::Normal(_)))
        {
            return Err(GitError::Protocol(format!(
                "шлях git ls-tree поза текою вивантаження: {path:?}"
            )));
        }
        blobs.push((oid.to_string(), dest.join(rel_path)));
    }
    if blobs.is_empty() {
        return Ok(0);
    }

    let mut stream = start(repo, &["cat-file", "--batch"])?;
    let (stdin, stdout) = stream.pipes();
    let mut reader = BufReader::new(stdout);
    let mut header = Vec::new();
    for (oid, file) in &blobs {
        stdin
            .write_all(format!("{oid}\n").as_bytes())
            .and_then(|_| stdin.flush())
            .map_err(io_err(format!("git cat-file --batch: запит {oid}")))?;
        header.clear();
        reader
            .read_until(b'\n', &mut header)
            .map_err(io_err(format!("git cat-file --batch: відповідь {oid}")))?;
        let line = String::from_utf8_lossy(&header);
        let size = line
            .trim_end_matches('\n')
            .strip_prefix(oid.as_str())
            .and_then(|r| r.strip_prefix(" blob "))
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(|| {
                GitError::Protocol(format!(
                    "git cat-file --batch: неочікуваний заголовок {line:?} для {}",
                    file.display()
                ))
            })?;
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)
                .map_err(io_err(format!("тека {}", parent.display())))?;
        }
        let mut out =
            std::fs::File::create(file).map_err(io_err(format!("файл {}", file.display())))?;
        let copied = io::copy(&mut (&mut reader).take(size), &mut out)
            .map_err(io_err(format!("файл {}", file.display())))?;
        let mut lf = [0u8; 1];
        if copied != size || reader.read_exact(&mut lf).is_err() || lf[0] != b'\n' {
            return Err(GitError::Protocol(format!(
                "git cat-file --batch: обірвана відповідь для {}",
                file.display()
            )));
        }
    }
    drop(reader);
    stream.finish(false)?;
    Ok(blobs.len())
}
