// Бібліотечна частина крейта kit: модулі, які перевіряють інтеграційні тести rust/tests/ (тест бінарного
// крейта не може імпортувати його модулі). Перенесені команди беруть їх звідси.

// Розбір сирих аргументів команди — та сама форма, що `ConvertFrom-KitArguments` (tools/lib/KitCli.psm1).
pub mod cli;
pub mod gh;
pub mod git;
pub mod proc;
pub mod profile;
pub mod session_board;
