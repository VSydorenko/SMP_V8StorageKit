// Розбір сирих аргументів команди в стилі PowerShell — та сама форма, що `ConvertFrom-KitArguments`
// (tools/lib/KitCli.psm1): позиційні + `-Ім'я значення` / `-Ім'я:значення` / `-Прапорець[:true|false]`.
//
// Імена нечутливі до регістру; у `named` лежать імена зі специфікації. `-Help` (і `--help`, `-h`)
// приймається завжди. Невідоме ім'я, форма `--name` замість `-Name`, параметр без значення —
// помилка виклику (код 2). Значенням стає наступний токен, якщо він не є іменем зі специфікації:
// так `-Note "-x"` працює, а `-Note -Model sonnet` (забули текст) — помилка. Токен на кшталт `-5`
// (цифра після мінуса) — позиційний, не ім'я.

use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Str,
    List,
    Switch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Str(String),
    List(Vec<String>),
    Switch(bool),
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Parsed {
    pub positional: Vec<String>,
    pub named: BTreeMap<String, Value>,
    pub help: bool,
}

/// Помилка виклику (код 2): текст причини без префікса `<команда>: ERROR`.
#[derive(Debug, PartialEq, Eq)]
pub struct UsageError(pub String);

/// `-Ім'я` або `-Ім'я:значення` → (ім'я, вбудоване значення). Ім'я — латинська літера, далі
/// літери й цифри (як `^-([A-Za-z][A-Za-z0-9]*)(?::(.*))?$` у PowerShell). .NET `$` збігається й
/// перед ОДНИМ кінцевим `\n`, тож `-Model:abc\n` там — `Model=abc`: цей `\n` відкидаємо так само.
fn split_name(t: &str) -> Option<(&str, Option<&str>)> {
    let t = t.strip_suffix('\n').unwrap_or(t);
    let rest = t.strip_prefix('-')?;
    let end = rest.find(|c: char| !c.is_ascii_alphanumeric()).unwrap_or(rest.len());
    let name = &rest[..end];
    if !name.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return None;
    }
    let tail = &rest[end..];
    if tail.is_empty() {
        return Some((name, None));
    }
    // `.` у .NET-регексі не бере перенос рядка: значення з ним — не форма `-Ім'я:значення`.
    let inline = tail.strip_prefix(':')?;
    if inline.contains('\n') {
        return None;
    }
    Some((name, Some(inline)))
}

/// `--some-name` → `SomeName` (підказка правильної форми).
fn camel(dashed: &str) -> String {
    dashed
        .split('-')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let mut c = p.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

pub fn parse(args: &[String], spec: &[(&str, Kind)]) -> Result<Parsed, UsageError> {
    let lookup = |raw: &str| spec.iter().find(|(n, _)| n.eq_ignore_ascii_case(raw)).copied();
    let is_name = |t: &str| match split_name(t) {
        Some((raw, _)) => lookup(raw).is_some() || raw.eq_ignore_ascii_case("Help"),
        None => false,
    };
    let mut out = Parsed::default();
    let mut i = 0;
    while i < args.len() {
        let t = args[i].as_str();
        i += 1;
        // PowerShell `-eq` порівнює рядки без регістру.
        if t.eq_ignore_ascii_case("--help") || t.eq_ignore_ascii_case("-h") {
            out.help = true;
            continue;
        }
        if let Some(rest) = t.strip_prefix("--") {
            let name: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '-').collect();
            if name.starts_with(|c: char| c.is_ascii_alphabetic()) {
                return Err(UsageError(format!(
                    "форма '{t}' не підтримується: параметри пишуться як -Ім'я ({})",
                    camel(&name)
                )));
            }
        }
        let Some((raw, inline)) = split_name(t) else {
            out.positional.push(t.to_string());
            continue;
        };
        if raw.eq_ignore_ascii_case("Help") {
            out.help = true;
            continue;
        }
        let Some((name, kind)) = lookup(raw) else {
            let mut known: Vec<&str> = spec.iter().map(|(n, _)| *n).collect();
            known.sort_by_key(|n| n.to_lowercase());
            let tail = if known.is_empty() {
                " (команда не має іменованих параметрів)".to_string()
            } else {
                format!(" (відомі: {})", known.iter().map(|n| format!("-{n}")).collect::<Vec<_>>().join(", "))
            };
            return Err(UsageError(format!("невідомий параметр -{raw}{tail}")));
        };
        if kind == Kind::Switch {
            let v = match inline {
                None => true,
                Some(v) if v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("$true") => true,
                Some(v) if v.eq_ignore_ascii_case("false") || v.eq_ignore_ascii_case("$false") => false,
                Some(_) => {
                    return Err(UsageError(format!("-{name}: прапорець без значення (або -{name}:true|false)")));
                }
            };
            out.named.insert(name.to_string(), Value::Switch(v));
            continue;
        }
        let value = match inline {
            Some(v) => v.to_string(),
            None => {
                if i >= args.len() || is_name(&args[i]) {
                    return Err(UsageError(format!("-{name} потребує значення")));
                }
                i += 1;
                args[i - 1].clone()
            }
        };
        if kind == Kind::List {
            match out.named.entry(name.to_string()).or_insert_with(|| Value::List(Vec::new())) {
                Value::List(l) => l.push(value),
                _ => unreachable!("ім'я зі специфікації List має лише значення List"),
            }
        } else {
            out.named.insert(name.to_string(), Value::Str(value));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPEC: &[(&str, Kind)] = &[("Model", Kind::Str), ("Path", Kind::List), ("Apply", Kind::Switch)];

    fn p(args: &[&str]) -> Result<Parsed, UsageError> {
        parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>(), SPEC)
    }

    fn err(args: &[&str]) -> String {
        p(args).expect_err("очікувалась помилка виклику").0
    }

    #[test]
    fn forms() {
        let r = p(&["refs", "-model", "sonnet", "-Path:a b", "-Path", "-x", "-5", "-Apply:false"]).unwrap();
        assert_eq!(r.positional, vec!["refs", "-5"]);
        assert_eq!(r.named["Model"], Value::Str("sonnet".into()));
        // `-Path -x`: наступний токен — не ім'я зі специфікації, тож значення.
        assert_eq!(r.named["Path"], Value::List(vec!["a b".into(), "-x".into()]));
        assert_eq!(r.named["Apply"], Value::Switch(false));
        assert!(!r.help);

        assert_eq!(p(&["-Apply"]).unwrap().named["Apply"], Value::Switch(true));
        assert_eq!(p(&["-Apply:$TRUE"]).unwrap().named["Apply"], Value::Switch(true));
        assert_eq!(p(&["-Model:"]).unwrap().named["Model"], Value::Str(String::new()));
        for h in ["-Help", "-help", "-HELP", "--help", "--HELP", "--Help", "-h", "-H"] {
            assert!(p(&[h]).unwrap().help, "{h}");
        }
        // .NET `$` — і перед одним кінцевим `\n`; два `\n` чи `\n` посередині — уже не ім'я.
        assert_eq!(p(&["-Model:abc\n"]).unwrap().named["Model"], Value::Str("abc".into()));
        assert_eq!(p(&["-Apply\n"]).unwrap().named["Apply"], Value::Switch(true));
        assert_eq!(p(&["-Model:a\nb"]).unwrap().positional, vec!["-Model:a\nb"]);
        assert_eq!(p(&["-Apply\n\n"]).unwrap().positional, vec!["-Apply\n\n"]);
    }

    #[test]
    fn usage_errors() {
        assert_eq!(err(&["--dry-run"]), "форма '--dry-run' не підтримується: параметри пишуться як -Ім'я (DryRun)");
        assert_eq!(err(&["-Nope"]), "невідомий параметр -Nope (відомі: -Apply, -Model, -Path)");
        assert_eq!(
            parse(&["-X".to_string()], &[]).unwrap_err().0,
            "невідомий параметр -X (команда не має іменованих параметрів)"
        );
        assert_eq!(err(&["-Model"]), "-Model потребує значення");
        assert_eq!(err(&["-Model", "-Apply"]), "-Model потребує значення");
        assert_eq!(err(&["-Model", "-Help"]), "-Model потребує значення");
        assert_eq!(err(&["-Apply:yes"]), "-Apply: прапорець без значення (або -Apply:true|false)");
    }
}
