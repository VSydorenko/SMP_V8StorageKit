// `kit session-check` (фаза 2, блок B4). Бібліотечна частина: читання сховища (`activity`), читання й звірка відбитка
// (`imprint`), узгоджений git-стан джерела (`snapshot`) і час у тиках (`ticks`). Нічого не пише й не друкує.

pub mod activity;
pub mod imprint;
pub mod snapshot;
pub mod ticks;
