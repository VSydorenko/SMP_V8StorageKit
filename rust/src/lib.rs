// Бібліотечна частина крейта kit: модулі, які перевіряють інтеграційні тести rust/tests/ (тест бінарного
// крейта не може імпортувати його модулі). Перенесені команди беруть їх звідси.

// Аудит репозиторію-споживача `kit check` (блок B3).
pub mod check;

// Розбір сирих аргументів команди — та сама форма, що `ConvertFrom-KitArguments` (tools/lib/KitCli.psm1).
pub mod cli;
pub mod config;
pub mod gh;
pub mod git;
pub mod proc;
pub mod profile;
pub mod runner;
pub mod session_board;
pub mod unica;

/// Хук паніки всього `kit.exe` (спека §6, ADR-0014): невиловлена паніка друкує сталий текст без payload і місця.
/// Повідомлення паніки цитує дані (зріз рядка не на межі символу друкує сам рядок), а хук вклеює stderr у
/// контекст сесії. З `panic = "abort"` процес після хука завершується. Запис у stderr не панікує: помилку
/// запису проковтнуто.
pub const PANIC_TEXT: &str = "kit: ERROR внутрішня помилка";

pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|_| {
        use std::io::Write;
        let _ = writeln!(std::io::stderr(), "{PANIC_TEXT}");
    }));
}
