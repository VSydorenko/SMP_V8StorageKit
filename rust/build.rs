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

fn main() {
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
