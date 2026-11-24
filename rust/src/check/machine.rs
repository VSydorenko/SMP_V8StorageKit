// Перевірки машини: `unica-version` і `runner-version`. Уніка й раннер — через `unica` і `runner`; корінь
// репозиторію передається в `unica::installation`, тож записи `scope: project`/`local` бачаться.
// Вердикт «ok» знахідки не дає. Відсутня Уніка — лише `runner-version` (раннера без неї не знайти, і його текст
// уже називає причину); неоднозначна — error в обох перевірках, з переліком кандидатів.

use super::{Collector, Options};
use crate::config::Level;
use crate::unica::{self, Level as VerdictLevel};
use std::path::Path;

fn level(v: VerdictLevel) -> Option<Level> {
    match v {
        VerdictLevel::Ok => None,
        VerdictLevel::Warn => Some(Level::Warn),
        VerdictLevel::Error => Some(Level::Error),
    }
}

pub(super) fn check(c: &mut Collector, opts: &Options, root: &Path) {
    let inst = unica::installation(&opts.registry, Some(root));
    if inst.candidates.len() > 1 || (inst.installed && inst.path_exists) {
        let verdict = unica::unica_verdict(&inst);
        if let Some(l) = level(verdict.level) {
            c.add(l, "unica-version", verdict.message);
        }
    }
    let verdict = unica::runner_verdict(opts.runner.as_deref(), &opts.registry, Some(root));
    if let Some(l) = level(verdict.level) {
        c.add(l, "runner-version", verdict.message);
    }
}
