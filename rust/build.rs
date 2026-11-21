// Вбудовує відбиток джерел крейта в бінарник (спека #51 D7, план Р6). Реалізація одна — src/fingerprint.rs,
// її ж крейт підключає модулем.
//
// rerun-if-changed — на кожен файл і кожну теку входу відбитка (той самий перелік, що хешується), крім
// самого кореня крейта: теку cargo сканує рекурсивно, а в корені лежить target/, тож стеження за коренем
// перезбирало б крейт на кожному `cargo build`. Без директив cargo стежить лише за файлами пакета й не
// бачить змін у rust/.cargo/. Сліпа пляма, що лишається: НОВИЙ запис у корені крейта (файл чи тека, зокрема
// перша поява .cargo/) build.rs не перезапускає — застарілий вбудований відбиток тоді ловить тест
// «робоче дерево» (tools/tests/KitExe.Tests.ps1), а синхронізує `touch build.rs`.
include!("src/fingerprint.rs");

/// Ціль поставки bin/kit.exe (спека #51 D0, план Р7). `targets` у rust-toolchain.toml лише встановлює
/// ціль; задати її файлом `.cargo/config.toml` не можна — з явною ціллю cargo не застосовує `rustflags`
/// цілі з машинного конфігу до build-скриптів. Тож збірка з іншою ціллю зупиняється тут.
const KIT_TARGET: &str = "x86_64-pc-windows-msvc";

fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target != KIT_TARGET {
        panic!("kit збирається лише для цілі {KIT_TARGET} (план #51 Р7), а ціль збірки — '{target}': встановіть тулчейн MSVC (rust-toolchain.toml) і збирайте без --target");
    }
    let dir = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let (inputs, dirs) = fingerprint_inputs(&dir).expect("вхід відбитка джерел крейта");
    for (_, path) in &inputs {
        println!("cargo:rerun-if-changed={}", path.display());
    }
    for d in dirs.iter().filter(|d| **d != dir) {
        println!("cargo:rerun-if-changed={}", d.display());
    }
    let (hash, files) = source_fingerprint(&dir).expect("відбиток джерел крейта");
    println!("cargo:rustc-env=KIT_SOURCE_FINGERPRINT={hash:016x}");
    println!("cargo:rustc-env=KIT_SOURCE_FILES={files}");
}
