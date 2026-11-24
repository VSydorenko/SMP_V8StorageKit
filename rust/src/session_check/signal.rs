// Сигнал одного джерела `truth: storage` (`kit session-check`): з узгодженого git-знімка, читання сховища й відбитка
// будується текст рядка, причина `NewInStorageReason`, крок для `next:` і прапорці для кодів виходу. Нічого не друкує
// й не пише. Поведінка перенесена з PowerShell-версії (видалена в B4; історія git).
//
// Причини (`NewInStorageReason`): `remote-only` (дзеркала немає локально, є `origin/<гілка>`), `imprint-ahead`
// (відбиток актуальний, його версія більша за дзеркало), `partial-read` (обхід сховища дістав помилку читання —
// стан прочитано не повністю, код 3), `unclear` (шлях доступний, але не схожий на сховище), `no-mirror`, `newer`,
// `packed-newer`, `server` (серверне сховище не перевіряється, код 0). Причина `partial-read` має перевагу над
// евристиками: час під помилкою читання занижений.
//
// Поля JSON — порядок оголошення (рішення 15 плану B4), як у PowerShell: Key, Branch, MirrorExists, LastMirrorDate,
// StorageWrite, NewInStorage, NewInStorageReason, UnmergedCommits, Accessible, GitProblem, Text, OriginGap.
// `Accessible` — каталог сховища відповів на цій машині; серверне сховище й недоступне — `false`.

use super::activity::{Activity, StorageReading, Unavailable};
use super::imprint::{Imprint, is_current, read_imprint};
use super::snapshot::{SourceGit, snapshot};
use super::ticks::{TICKS_PER_SECOND, format_iso, format_utc};
use crate::config::mask_storage_path;
use crate::storage_branch::{OriginGap, ref_sha, restore_mirror_step};
use serde::Serialize;
use std::path::Path;

/// Допуск порівняння часу сховища з датою коміту дзеркала: `sync` стемпить дати комітів цілими секундами, а час
/// запису має частку секунди — без допуску вічний хибний сигнал. Навмисно малий: великий не дав би сигналу ніколи.
const MIRROR_TOLERANCE_TICKS: i64 = 5 * TICKS_PER_SECOND;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reason {
    RemoteOnly,
    ImprintAhead,
    PartialRead,
    Unclear,
    NoMirror,
    Newer,
    PackedNewer,
    Server,
}

impl Reason {
    fn as_str(self) -> &'static str {
        match self {
            Reason::RemoteOnly => "remote-only",
            Reason::ImprintAhead => "imprint-ahead",
            Reason::PartialRead => "partial-read",
            Reason::Unclear => "unclear",
            Reason::NoMirror => "no-mirror",
            Reason::Newer => "newer",
            Reason::PackedNewer => "packed-newer",
            Reason::Server => "server",
        }
    }
}

/// Відставання від `origin` у JSON: `OriginGap` сигналу (`HasRemote`, `Ahead`, `Behind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct GapJson {
    pub has_remote: bool,
    pub ahead: u64,
    pub behind: u64,
}

impl From<OriginGap> for GapJson {
    fn from(g: OriginGap) -> Self {
        GapJson {
            has_remote: g.has_remote,
            ahead: g.ahead,
            behind: g.behind,
        }
    }
}

/// Сигнал джерела — те, що друкує `-AsJson`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct Signal {
    pub key: String,
    pub branch: String,
    pub mirror_exists: bool,
    pub last_mirror_date: Option<String>,
    pub storage_write: Option<String>,
    pub new_in_storage: bool,
    pub new_in_storage_reason: Option<&'static str>,
    pub unmerged_commits: u64,
    pub accessible: bool,
    pub git_problem: Option<String>,
    pub text: String,
    pub origin_gap: Option<GapJson>,
}

/// Сигнал плюс те, що не йде в JSON: крок для `next:` і прапорець `partial-read` (код 3 навіть тоді, коли причину
/// сигналу витіснила інша — `remote-only`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Computed {
    pub signal: Signal,
    pub step: Option<String>,
    pub partial: bool,
}

/// Вхід обчислення сигналу одного джерела.
pub struct SourceInput<'a> {
    pub repo_root: &'a Path,
    pub key: &'a str,
    pub branch: &'a str,
    /// Шлях сховища як у конфігурації (з паролем у userinfo, якщо він там є): у текст іде лише замаскований.
    pub storage_path: &'a str,
    pub main_branch: &'a str,
}

fn unavailable_text(reason: Unavailable, masked_path: &str) -> String {
    match reason {
        Unavailable::Missing => format!(
            "сховище недоступне на цій машині (каталог недоступний: {masked_path}) — перевизначте шлях у v8storagekit.local.yaml (storages:)"
        ),
        Unavailable::Denied => format!(
            "сховище недоступне на цій машині (немає доступу до каталогу: {masked_path}) — перевірте права доступу або перевизначте шлях у v8storagekit.local.yaml (storages:)"
        ),
        Unavailable::NoAnswer => format!(
            "сховище недоступне на цій машині (каталог не відповів: {masked_path}) — можливо, тимчасовий збій мережі чи диска; повторіть пізніше, шлях перевизначайте лише коли він хибний (v8storagekit.local.yaml, storages:)"
        ),
    }
}

fn git_problem_signal(
    input: &SourceInput<'_>,
    reading: &StorageReading,
    problem: &str,
) -> Computed {
    let mirror_exists = ref_sha(input.repo_root, &format!("refs/heads/{}", input.branch))
        .ok()
        .flatten()
        .is_some();
    let activity = activity_of(reading);
    Computed {
        signal: Signal {
            key: input.key.to_string(),
            branch: input.branch.to_string(),
            mirror_exists,
            last_mirror_date: None,
            storage_write: activity.and_then(|a| a.latest_object_write).map(format_iso),
            new_in_storage: false,
            new_in_storage_reason: None,
            unmerged_commits: 0,
            accessible: matches!(reading, StorageReading::Read(_)),
            git_problem: Some(problem.to_string()),
            text: format!(
                "- {}: стан git не прочитано ({problem}) — сигнал недоступний; розбір: kit check.",
                input.key
            ),
            origin_gap: None,
        },
        step: Some("kit check".to_string()),
        partial: false,
    }
}

fn activity_of(reading: &StorageReading) -> Option<&Activity> {
    match reading {
        StorageReading::Read(a) => Some(a),
        _ => None,
    }
}

fn newer_than_mirror(write: Option<i64>, mirror: Option<i64>) -> bool {
    matches!((write, mirror), (Some(w), Some(m)) if w > m + MIRROR_TOLERANCE_TICKS)
}

/// Сигнал джерела з готового читання сховища. Збій git — `GitProblem` цього джерела (код 1), не виняток.
pub fn compute(input: &SourceInput<'_>, reading: &StorageReading) -> Computed {
    let shot = match snapshot(input.repo_root, input.branch, input.main_branch) {
        Ok(shot) => shot,
        Err(problem) => return git_problem_signal(input, reading, &problem.0),
    };
    let key = input.key;
    let branch = input.branch;
    let main = input.main_branch;
    let activity = activity_of(reading);
    let mirror = shot.mirror_sha.is_some();
    let partial = activity.and_then(|a| a.partial);

    let imprint: Option<Imprint> = match (mirror, shot.last_version) {
        (true, Some(version)) => read_imprint(input.repo_root, key)
            .filter(|i| is_current(i, key, input.storage_path, version, reading)),
        _ => None,
    };
    let imprint_ahead = matches!((&imprint, shot.last_version),
        (Some(i), Some(v)) if u64::try_from(i.version).is_ok_and(|n| n > v));

    let reason = pick_reason(&shot, reading, activity, imprint.is_some(), imprint_ahead);
    let new_in_storage = match reason {
        None | Some(Reason::Server) => false,
        Some(Reason::PartialRead) => !mirror,
        Some(_) => true,
    };

    let mut parts: Vec<String> = Vec::new();
    let mut step: Option<String> = None;
    let sync_apply = format!("kit sync -Source {key} -Apply");

    if let (Some(i), Some(version)) = (&imprint, shot.last_version) {
        if imprint_ahead {
            parts.push(format!(
                "за відбитком сховище було на версії {} станом на {} UTC, дзеркало на версії {version} — оновити: {sync_apply}",
                i.version,
                format_utc(i.read_at_ticks)
            ));
            step = Some(sync_apply.clone());
        } else {
            let merged_all = if shot.unmerged == 0 {
                format!(", {main} містить усе")
            } else {
                String::new()
            };
            parts.push(format!(
                "дзеркало синхронне зі сховищем на версії {}{merged_all} (відбиток прочитано {} UTC)",
                i.version,
                format_utc(i.read_at_ticks)
            ));
        }
    } else {
        match reading {
            StorageReading::Unavailable(u) => parts.push(unavailable_text(
                *u,
                &mask_storage_path(input.storage_path),
            )),
            StorageReading::Server => parts.push(format!(
                "серверне сховище: нові версії session-check не перевіряє — перевірити вручну: kit sync -Source {key} (прев'ю показує нові версії)"
            )),
            StorageReading::Read(a) => {
                if let Some(class) = a.partial {
                    parts.push(format!(
                        "стан сховища прочитано не повністю ({}) — нові версії не виключено",
                        class.label()
                    ));
                } else if let Some(not_storage) = a.not_storage {
                    // Мовчати тут — хибний all-clear на завідомо неправильному шляху, гірший за будь-який шум.
                    parts.push(format!(
                        "шлях сховища доступний, але не схожий на сховище 1С ({}) — перевірте storages: {key} у v8storagekit.local.yaml (чи сам шлях у v8storagekit.yaml)",
                        not_storage.text()
                    ));
                }
            }
        }

        if shot.remote_only {
            // Дзеркало лише на origin (#101): `sync -Apply` почав би реплей з нуля в другу історію.
            let restore = restore_mirror_step(branch);
            parts.push(format!(
                "локальної гілки {branch} немає, але є origin/{branch} — відновіть дзеркало: {restore}"
            ));
            step = Some(restore);
        } else if !mirror {
            parts.push(format!(
                "дзеркала storage/{key} ще немає — перший реплей: {sync_apply}"
            ));
            step = Some(sync_apply.clone());
        } else if reason == Some(Reason::Newer) {
            let (write, mirror_at) = (
                activity.and_then(|a| a.latest_object_write),
                shot.last_mirror_ticks,
            );
            if let (Some(write), Some(mirror_at)) = (write, mirror_at) {
                parts.push(format!(
                    "у сховищі ймовірно нові версії (запис {} UTC після дзеркала {} UTC) — оновити? {sync_apply}",
                    format_utc(write),
                    format_utc(mirror_at)
                ));
            }
            step = Some(sync_apply.clone());
        } else if reason == Some(Reason::PackedNewer) {
            // Дешева перевірка чесно каже «не знаю»; дія — `kit sync` БЕЗ -Apply: прочитає звіт і залишить точний
            // відбиток на майбутнє.
            if let Some(mirror_at) = shot.last_mirror_ticks {
                parts.push(format!(
                    "усі об'єкти запаковані після останнього дзеркала ({} UTC) — чи є нові версії, дешева перевірка сказати не може; точну відповідь дає kit sync -Source {key} без -Apply",
                    format_utc(mirror_at)
                ));
            }
            step = Some(format!("kit sync -Source {key}"));
        }
    }
    // Незлиті коміти — НЕЗАЛЕЖНО від доступності сховища.
    if shot.unmerged > 0 {
        let n = shot.unmerged;
        if shot.main_missing {
            if shot.main_unborn {
                parts.push(format!(
                    "на {branch} є {n} коміт(и), а головної гілки '{main}' ще немає — зробіть перший коміт у '{main}', потім kit sync -Source {key} -Apply -MergeMain"
                ));
                step.get_or_insert_with(|| format!("kit sync -Source {key} -Apply -MergeMain"));
            } else {
                parts.push(format!(
                    "на {branch} є {n} коміт(и), а гілки '{main}' з маніфесту немає — перевірте mainBranch: (описка?)"
                ));
            }
        } else {
            parts.push(format!(
                "на {branch} є {n} коміт(и), не злиті в {main} — звірочний коміт: kit verify -Apply"
            ));
            step.get_or_insert_with(|| "kit verify -Apply".to_string());
        }
    }
    if parts.is_empty() {
        parts.push(format!(
            "дзеркало синхронне зі сховищем, {main} містить усе"
        ));
    }

    let origin_gap = mirror.then_some(GapJson::from(shot.origin_gap));
    Computed {
        signal: Signal {
            key: key.to_string(),
            branch: branch.to_string(),
            mirror_exists: mirror,
            last_mirror_date: shot.last_mirror_ticks.map(format_iso),
            storage_write: activity.and_then(|a| a.latest_object_write).map(format_iso),
            new_in_storage,
            new_in_storage_reason: reason.map(Reason::as_str),
            unmerged_commits: shot.unmerged,
            accessible: activity.is_some(),
            git_problem: None,
            text: format!("- {key}: {}.", parts.join("; ")),
            origin_gap,
        },
        step,
        partial: partial.is_some(),
    }
}

/// Причина сигналу за пріоритетом: `remote-only` (дія не залежить від сховища) → відбиток → стан читання сховища
/// (серверне, `partial-read`, не схоже на сховище, дзеркала немає, евристики часу).
fn pick_reason(
    shot: &SourceGit,
    reading: &StorageReading,
    activity: Option<&Activity>,
    imprint_current: bool,
    imprint_ahead: bool,
) -> Option<Reason> {
    if shot.remote_only {
        return Some(Reason::RemoteOnly);
    }
    if imprint_current {
        return imprint_ahead.then_some(Reason::ImprintAhead);
    }
    if matches!(reading, StorageReading::Server) {
        return Some(Reason::Server);
    }
    let a = activity?;
    if a.partial.is_some() {
        return Some(Reason::PartialRead);
    }
    if !a.is_storage {
        return Some(Reason::Unclear);
    }
    if shot.mirror_sha.is_none() {
        return Some(Reason::NoMirror);
    }
    if newer_than_mirror(a.latest_object_write, shot.last_mirror_ticks) {
        return Some(Reason::Newer);
    }
    if newer_than_mirror(a.latest_pack_write, shot.last_mirror_ticks) {
        return Some(Reason::PackedNewer);
    }
    None
}
