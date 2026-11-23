// Відбиток джерел крейта (ADR-0014) — одна реалізація на два місця: build.rs підключає
// цей файл через `include!` і вбудовує відбиток у бінарник, крейт — модулем `fingerprint` і обчислює
// той самий відбиток для заданої теки (прихована підкоманда `kit source-fingerprint`). Тому тут лише
// елементи рівня модуля, без внутрішніх атрибутів і doc-коментарів `//!`.
//
// Вхід — УСІ файли під коренем крейта, крім теки `target/` у корені: не білий список, тож зміна
// `.cargo/config.toml` чи ресурсу `include_str!` теж змінює відбиток. Файли — у порядку відносних
// шляхів з `/` (байтове порівняння); кінці рядків CRLF → LF, бо з `core.autocrlf=true` клон має
// CRLF там, де індекс — LF. Алгоритм — FNV-1a 64: мета — помітити застарілий bin/kit.exe, а не
// протидіяти підробці, тож криптографічний хеш (і залежність) не потрібен.

pub type FingerprintInputs = (Vec<(String, std::path::PathBuf)>, Vec<std::path::PathBuf>);

/// Вхід відбитка: файли (відносний шлях з `/`, повний шлях) у порядку хешування і теки, які обійдено
/// (включно з коренем). build.rs стежить саме за цим переліком (rerun-if-changed).
pub fn fingerprint_inputs(root: &std::path::Path) -> std::io::Result<FingerprintInputs> {
    let mut files = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    fingerprint_collect(root, "", &mut files, &mut dirs)?;
    files.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    Ok((files, dirs))
}

/// (відбиток, кількість файлів) для кореня крейта `root`.
pub fn source_fingerprint(root: &std::path::Path) -> std::io::Result<(u64, usize)> {
    let (files, _) = fingerprint_inputs(root)?;
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for b in bytes {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    for (rel, path) in &files {
        let raw = std::fs::read(path)?;
        let mut text = Vec::with_capacity(raw.len());
        for (i, b) in raw.iter().enumerate() {
            if *b == b'\r' && raw.get(i + 1) == Some(&b'\n') {
                continue;
            }
            text.push(*b);
        }
        // Ім'я, NUL, довжина вмісту — межі записів однозначні, навіть коли вміст містить NUL.
        feed(rel.as_bytes());
        feed(&[0]);
        feed(&(text.len() as u64).to_le_bytes());
        feed(&text);
    }
    Ok((h, files.len()))
}

fn fingerprint_collect(
    dir: &std::path::Path,
    rel: &str,
    out: &mut Vec<(String, std::path::PathBuf)>,
    dirs: &mut Vec<std::path::PathBuf>,
) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if rel.is_empty() && name == "target" {
            continue;
        }
        let child = if rel.is_empty() { name } else { format!("{rel}/{name}") };
        let kind = entry.file_type()?;
        if kind.is_dir() {
            dirs.push(entry.path());
            fingerprint_collect(&entry.path(), &child, out, dirs)?;
        } else if kind.is_file() {
            out.push((child, entry.path()));
        }
    }
    Ok(())
}
