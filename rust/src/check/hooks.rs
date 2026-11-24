// Перевірки `hooks` і `hook-shim`: не залежать від розв'язаного контексту (рішення 6) — виконуються й коли маніфест
// не прочитано чи воркспейс випав через помилку конфігу. Логіка — у бібліотечному модулі `crate::hooks`.

use super::Collector;
use crate::hooks::{self, Outcome};
use std::path::Path;

fn push(c: &mut Collector, check: &str, outcomes: Vec<Outcome>) {
    for outcome in outcomes {
        match outcome {
            Outcome::Finding { level, message } => c.add(level, check, message),
            Outcome::Unchecked { what, reason } => c.unchecked(check, &what, &reason),
        }
    }
}

pub(super) fn check(c: &mut Collector, root: &Path) {
    let templates = hooks::plugin_templates_dir();
    let prefetch = c.hooks_prefetch.take();
    push(
        c,
        "hooks",
        hooks::audit_with(root, templates.as_deref(), prefetch),
    );
    push(c, "hook-shim", hooks::legacy_session_hook(root));
}
