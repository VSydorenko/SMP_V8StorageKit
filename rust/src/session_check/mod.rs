// `kit session-check` : команда (`command`: друк у міру готовності, коди), сигнал джерела (`signal`),
// читання сховища (`activity`), читання й звірка відбитка (`imprint`), узгоджений git-стан джерела (`snapshot`) і
// час у тиках (`ticks`). Друкує лише `command`; ніщо в модулі нічого не пише на диск.

pub mod activity;
pub mod command;
pub mod imprint;
pub mod signal;
pub mod snapshot;
pub mod ticks;
