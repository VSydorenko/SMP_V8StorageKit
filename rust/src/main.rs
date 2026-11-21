// kit.exe — один вхід команд kit (спека #51 D1, D1а, D2, D3): `kit <команда> [аргументи]`.
//
// Перенесені на Rust команди kit виконує сам; решту передає PowerShell-диспетчеру
// `<корінь плагіна>/tools/kit.ps1`. Токени йдуть НЕ аргументами `pwsh -File` (PowerShell сам
// розщеплює `-Ім'я:значення` і перетворює `-X:false` на `-X` + `False`), а JSON-масивом рядків у
// змінній оточення KIT_ARGV; диспетчер читає її й прибирає зі свого оточення. stdin, stdout і stderr
// успадковані, код диспетчера — код kit.exe.
//
// Коди (D3): 0 — так; 1 — зупинка; 2 — помилка виклику; 3 — не перевірено; 4 — виконано, є наступний
// крок. Помилка — перший рядок stderr `<команда>: ERROR …`.
//
// Приховані підкоманди (не в довідці й не в переліку команд процесу): `source-fingerprint` — запобіжник
// «бінарник = джерело» (D7); `session-start` — хук SessionStart плагіна (`hooks/hooks.json`, D6, план Р5).

mod cli;
mod fingerprint;
mod session_start;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};

/// Відбиток джерел `rust/`, вбудований build.rs під час збірки (D7).
const EMBEDDED_FINGERPRINT: &str = env!("KIT_SOURCE_FINGERPRINT");

/// Прихована підкоманда запобіжника «бінарник = джерело»: не в довідці, не команда для людини.
const FINGERPRINT_COMMAND: &str = "source-fingerprint";

fn fail(command: &str, message: &str, code: i32) -> ! {
    eprintln!("{command}: ERROR {message}");
    exit(code)
}

/// Корінь плагіна — батьківська тека теки бінарника (bin/kit.exe → корінь), план Р3.
fn plugin_root() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("шлях kit.exe не визначено: {e}"))?;
    exe.parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| format!("у шляху {} немає теки над bin/", exe.display()))
}

/// Пошук програми так, як її шукає оболонка Windows: теки `PATH` по черзі, у кожній — розширення з
/// `PATHEXT`. Одна функція для всіх зовнішніх програм; швів через змінні оточення немає (план Р3).
fn find_program(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn print_help(root: Option<&Path>) {
    println!("usage: kit <команда> [аргументи]");
    let mut names: Vec<String> = root
        .and_then(|r| std::fs::read_dir(r.join("tools").join("commands")).ok())
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".psm1")).map(str::to_string))
        .collect();
    names.sort();
    if !names.is_empty() {
        println!("команди: {}", names.join(", "));
    }
    println!("довідка команди: kit <команда> -Help");
}

/// `kit source-fingerprint [<тека крейта>]`: вбудований відбиток і, якщо тека задана, обчислений з неї
/// з кількістю файлів. Запобіжник D7 у Pester порівнює ці два рядки.
fn source_fingerprint(args: &[String]) -> i32 {
    println!("embedded {EMBEDDED_FINGERPRINT}");
    match args {
        [] => 0,
        [dir] => match fingerprint::source_fingerprint(Path::new(dir)) {
            Ok((hash, files)) => {
                println!("computed {hash:016x} {files}");
                0
            }
            Err(e) => fail(FINGERPRINT_COMMAND, &format!("відбиток {dir} не обчислено: {e}"), 1),
        },
        _ => fail(FINGERPRINT_COMMAND, "очікувалась одна тека крейта", 2),
    }
}

/// Процес PowerShell-диспетчера з токенами в KIT_ARGV (D1а), ще не запущений: його запускає передача
/// команди (`dispatch`) і хук старту (`session_start`) — одне місце запуску `pwsh`.
pub(crate) fn dispatcher(root: &Path, tokens: &[String]) -> Result<Command, String> {
    let script = root.join("tools").join("kit.ps1");
    if !script.is_file() {
        return Err(format!("диспетчер {} не знайдено", script.display()));
    }
    let Some(pwsh) = find_program("pwsh") else {
        return Err("pwsh (PowerShell 7+) не знайдено в PATH".to_string());
    };
    let argv = serde_json::to_string(tokens).map_err(|e| format!("KIT_ARGV не серіалізовано: {e}"))?;
    let mut cmd = Command::new(&pwsh);
    cmd.arg("-NoProfile").arg("-File").arg(&script).env("KIT_ARGV", argv);
    Ok(cmd)
}

/// Передача команди PowerShell-диспетчеру через KIT_ARGV (D1а); код диспетчера — код kit.exe.
fn dispatch(root: &Path, tokens: &[String]) -> i32 {
    let mut cmd = dispatcher(root, tokens).unwrap_or_else(|e| fail("kit", &e, 1));
    match cmd.status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => fail("kit", &format!("{} не запустився: {e}", Path::new(cmd.get_program()).display()), 1),
    }
}

fn main() {
    let mut tokens = Vec::new();
    for a in std::env::args_os().skip(1) {
        match a.into_string() {
            Ok(s) => tokens.push(s),
            Err(raw) => fail("kit", &format!("аргумент {raw:?} — не коректний Unicode"), 2),
        }
    }
    let Some(command) = tokens.first().cloned() else {
        fail("kit", "команду не вказано; usage: kit <команда> [аргументи] (kit -Help)", 2);
    };
    if command == FINGERPRINT_COMMAND {
        exit(source_fingerprint(&tokens[1..]));
    }
    if command == session_start::COMMAND {
        // Хук старту сесії (D6, план Р5): код 0 завжди, вивід — одним записом або жодного.
        let out = plugin_root().ok().and_then(|root| session_start::run(&root));
        if let Some(text) = out {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(text.as_bytes()).and_then(|_| stdout.flush());
        }
        exit(0);
    }
    let root = plugin_root();
    // Параметр замість команди: довідка чи помилка виклику — та сама форма розбору, що в команд.
    if command.starts_with('-') {
        match cli::parse(&tokens[..1], &[]) {
            Ok(p) if p.help => {
                print_help(root.as_deref().ok());
                exit(0);
            }
            Ok(_) => {}
            Err(cli::UsageError(msg)) => fail("kit", &format!("{msg}; usage: kit <команда> [аргументи]"), 2),
        }
    }
    let root = root.unwrap_or_else(|e| fail("kit", &e, 1));
    exit(dispatch(&root, &tokens));
}
