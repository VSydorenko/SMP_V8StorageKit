// Стеля часу для блокуючих викликів ОС (недоступний мережевий диск, UNC-хост, що не відповідає): виклик іде з
// окремого потоку, і `check` чекає не довше за стелю. Потік, що не вклався, не зупиняється — висить, поки ОС не
// відповість, але звіт від нього не залежить. Модуль нічого не запускає й не читає оточення.

use std::sync::mpsc;
use std::time::Duration;

/// Результат `f`, якщо він вклався в `ceiling`; `None` — не вклався.
pub fn run<T, F>(ceiling: Duration, f: F) -> Option<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx.recv_timeout(ceiling).ok()
}
