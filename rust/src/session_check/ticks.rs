// Час у цілих 100-нс тиках UTC від 0001-01-01 — та сама міра, що `DateTime.Ticks` у PowerShell. Байти, які kit
// порівнює (відбиток проти диска), мусять збігатися значеннями точно, без допуску: тому час тут — `i64`, а не
// `SystemTime` (його тики залежать від платформи) і не рядок.

use std::time::{SystemTime, UNIX_EPOCH};

pub const TICKS_PER_SECOND: i64 = 10_000_000;
const UNIX_EPOCH_TICKS: i64 = 621_355_968_000_000_000;
const SECONDS_PER_DAY: i64 = 86_400;

/// Тики UTC для часу файлової системи. Windows віддає 100-нс крок, тож округлення немає; для часу до 1970 —
/// від'ємна відстань від епохи.
pub fn from_system_time(t: SystemTime) -> i64 {
    let (secs, nanos, sign) = match t.duration_since(UNIX_EPOCH) {
        Ok(d) => (d.as_secs(), d.subsec_nanos(), 1_i64),
        Err(e) => (e.duration().as_secs(), e.duration().subsec_nanos(), -1_i64),
    };
    let secs = i64::try_from(secs).unwrap_or(i64::MAX / TICKS_PER_SECOND / 2);
    let fraction = i64::from(nanos / 100);
    UNIX_EPOCH_TICKS + sign * (secs * TICKS_PER_SECOND + fraction)
}

/// Дні від 1970-01-01 для григоріанської дати (алгоритм Говарда Гіннанта).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// `yyyy-MM-dd HH:mm:ss` UTC фіксованим форматом (без культури).
pub fn format_utc(ticks: i64) -> String {
    let unix_secs = (ticks - UNIX_EPOCH_TICKS).div_euclid(TICKS_PER_SECOND);
    let days = unix_secs.div_euclid(SECONDS_PER_DAY);
    let rest = unix_secs.rem_euclid(SECONDS_PER_DAY);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// Те, що дає PowerShell `ConvertTo-Json` для `DateTime` у UTC: `yyyy-MM-ddTHH:mm:ssZ`, а коли частка секунди
/// ненульова, — ще й рівно 7 цифр дробу (`.fffffff`) перед `Z`.
pub fn format_iso(ticks: i64) -> String {
    let fraction = (ticks - UNIX_EPOCH_TICKS).rem_euclid(TICKS_PER_SECOND);
    let base = format_utc(ticks).replacen(' ', "T", 1);
    if fraction == 0 {
        format!("{base}Z")
    } else {
        format!("{base}.{fraction:07}Z")
    }
}

fn digits(b: &[u8], from: usize, n: usize) -> Option<i64> {
    let part = b.get(from..from.checked_add(n)?)?;
    if !part.iter().all(u8::is_ascii_digit) {
        return None;
    }
    part.iter()
        .try_fold(0_i64, |acc, d| Some(acc * 10 + i64::from(d - b'0')))
}

/// ISO 8601: `yyyy-MM-ddTHH:mm:ss[.f…](Z|±HH:MM)` — форма `git log %aI` і формат `o` відбитка (`…ffffffZ`). Без
/// суфікса зони час вважається UTC (так порівнює PowerShell: `DateTime` порівнюється за тиками, не за `Kind`).
/// Нерозбірне — `None`.
pub fn parse_iso(text: &str) -> Option<i64> {
    let b = text.trim().as_bytes();
    let (year, month, day) = (digits(b, 0, 4)?, digits(b, 5, 2)?, digits(b, 8, 2)?);
    if *b.get(4)? != b'-' || *b.get(7)? != b'-' || !matches!(b.get(10)?, b'T' | b't' | b' ') {
        return None;
    }
    let (hour, minute, second) = (digits(b, 11, 2)?, digits(b, 14, 2)?, digits(b, 17, 2)?);
    if *b.get(13)? != b':' || *b.get(16)? != b':' {
        return None;
    }
    if !(1..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let mut at = 19;
    let mut fraction = 0_i64;
    if b.get(at) == Some(&b'.') {
        at += 1;
        let start = at;
        while b.get(at).is_some_and(u8::is_ascii_digit) {
            at += 1;
        }
        if at == start {
            return None;
        }
        // Тик — 7 знаків; решта (git дає секунди, `o` — рівно 7) відкидається.
        let kept = b.get(start..at.min(start + 7))?;
        fraction = kept
            .iter()
            .try_fold(0_i64, |acc, d| Some(acc * 10 + i64::from(d - b'0')))?;
        for _ in kept.len()..7 {
            fraction *= 10;
        }
    }
    let offset = match b.get(at) {
        None => 0,
        Some(b'Z' | b'z') if at + 1 == b.len() => 0,
        Some(sign @ (b'+' | b'-')) => {
            let (h, m) = (digits(b, at + 1, 2)?, digits(b, at + 4, 2)?);
            if *b.get(at + 3)? != b':' || at + 6 != b.len() || h > 23 || m > 59 {
                return None;
            }
            let seconds = h * 3600 + m * 60;
            if *sign == b'+' { seconds } else { -seconds }
        }
        Some(_) => return None,
    };
    let days = days_from_civil(year, month, day);
    let unix_secs = days * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second - offset;
    Some(UNIX_EPOCH_TICKS + unix_secs * TICKS_PER_SECOND + fraction)
}
