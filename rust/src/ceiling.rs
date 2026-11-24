// Стеля часу для блокуючих викликів ОС (недоступний мережевий диск, UNC-хост, що не відповідає): виклик іде з
// окремого потоку, і `check` чекає не довше за стелю. Потік, що не вклався, не зупиняється — висить, поки ОС не
// відповість, але звіт від нього не залежить. Модуль нічого не запускає й не читає оточення.

use std::sync::mpsc;
use std::time::{Duration, Instant};

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

/// Проба, що вже стартувала в окремому потоці: стеля рахується від старту, а не від `wait`. Так кілька проб
/// стартують разом, а звіт збирається в порядку перевірок: `wait` чекає лише те, що лишилось до стелі цієї проби.
pub struct Pending<T> {
    rx: mpsc::Receiver<T>,
    deadline: Instant,
}

/// Стартує `f` у потоці зі стелею `ceiling` від цього моменту.
pub fn start<T, F>(ceiling: Duration, f: F) -> Pending<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    Pending {
        rx,
        deadline: Instant::now() + ceiling,
    }
}

impl<T> Pending<T> {
    /// Результат, якщо проба вклалась у стелю; `None` — ні (потік лишається, процес його не чекає).
    pub fn wait(self) -> Option<T> {
        self.rx
            .recv_timeout(self.deadline.saturating_duration_since(Instant::now()))
            .ok()
    }
}
