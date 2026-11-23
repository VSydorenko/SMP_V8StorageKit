// Запобіжник «запуск git лише в модулі git» (ADR-0014): поза модулем `git` Rust-код kit git не запускає.
//
// Обсяг — rust/src/** (рекурсивно) і rust/build.rs; тести rust/tests/ поза обсягом, як tools/tests/ у
// PowerShell. Модуль `git` — src/git.rs і src/git/**.
//
// Джерело розбирається на лексеми без коментарів; рядкові літерали розбираються РАНІШЕ за коментарі,
// тож `"/*"` чи `"//"` у рядку не ховає код за ним. Правило поза модулем `git`:
//  (а) рядковий літерал `git`, `git.exe`, `…/git`, `…\git(.exe)` (без регістру);
//  (б) літерал зі словом `git` у будь-якому місці рядка оболонки (`cd x && git status`) всередині
//      аргументів `.arg(`, `.args(` чи `Command::new(`;
//  (в) `Command::new` з нелітеральним аргументом (або без виклику — як значення функції) — лише з
//      явного переліку дозволених місць ALLOWED_DYNAMIC;
//  Правило (а) має явний перелік ALLOWED_LITERAL: слово `git`, що не є програмою (словник значень). Кожен запис
//  мусить відповідати рівно одному літералу, застарілий запис — червоне, як в ALLOWED_DYNAMIC.
//  (г) псевдонім типу `Command` (`Command as X`, `type X = …Command;`).
// Позитивний двійник: у модулі `git` правило влучення ДАЄ — інакше сканер сліпий.

use std::path::{Path, PathBuf};

/// Дозволені динамічні `Command::new`: (файл відносно rust/, текст аргументу, навіщо). Кожен запис
/// мусить відповідати рівно одному місцю в коді — застарілий запис теж червоне.
const ALLOWED_DYNAMIC: &[(&str, &str, &str)] = &[
    ("src/main.rs", "&pwsh", "передача команди PowerShell-диспетчеру"),
    ("src/proc.rs", "&taskkill", "убити дерево процесів на стелі часу: хук старту (session-check) і gh"),
    ("src/gh.rs", "&exe", "gh для session-board: програма знайдена в PATH"),
];

/// Дозволені літерали правила (а): (файл відносно rust/, літерал, навіщо). Кожен запис — рівно одне місце.
const ALLOWED_LITERAL: &[(&str, &str, &str)] =
    &[("src/config/mod.rs", "git", "значення truth: git у словнику маніфесту, не програма")];

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Lit(String),
    Punct(char),
}

/// Лексеми з номером рядка. Коментарі (`//`, вкладені `/* */`) пропущено; рядки (`"…"`, `b"…"`,
/// `r#"…"#`, `br"…"`, `c"…"`) — значенням; символьні літерали й часи життя — пропущено.
fn lex(src: &str) -> Vec<(Tok, usize)> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let (mut i, mut line) = (0usize, 1usize);
    let count_lines = |from: usize, to: usize| c[from..to].iter().filter(|ch| **ch == '\n').count();
    while i < c.len() {
        let ch = c[i];
        if ch == '\n' {
            line += 1;
            i += 1;
        } else if ch.is_whitespace() {
            i += 1;
        } else if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            let start = i;
            let mut depth = 0;
            while i < c.len() {
                if c[i] == '/' && c.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if c[i] == '*' && c.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    i += 1;
                }
            }
            line += count_lines(start, i);
        } else if ch == '"' {
            let (start, at) = (i, line);
            let mut v = String::new();
            i += 1;
            while i < c.len() && c[i] != '"' {
                if c[i] == '\\' && i + 1 < c.len() {
                    match c[i + 1] {
                        // `\` + перенос: перенос і пробіли після нього не входять у значення.
                        '\n' | '\r' => {
                            i += 1;
                            while i < c.len() && c[i].is_whitespace() {
                                i += 1;
                            }
                        }
                        // `\xHH`: рівно дві шістнадцяткові цифри.
                        'x' => {
                            let hex: String = c[(i + 2).min(c.len())..(i + 4).min(c.len())].iter().collect();
                            v.extend(u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32));
                            i += 4;
                        }
                        // `\u{…}`: до шести цифр, підкреслення дозволені.
                        'u' if c.get(i + 2) == Some(&'{') => {
                            let close = c[i..].iter().position(|ch| *ch == '}').map_or(c.len(), |p| i + p);
                            let hex: String = c[i + 3..close].iter().filter(|ch| **ch != '_').collect();
                            v.extend(u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32));
                            i = close + 1;
                        }
                        other => {
                            v.push(match other {
                                'n' => '\n',
                                't' => '\t',
                                'r' => '\r',
                                '0' => '\0',
                                other => other,
                            });
                            i += 2;
                        }
                    }
                } else {
                    v.push(c[i]);
                    i += 1;
                }
            }
            i += 1;
            line += count_lines(start, i.min(c.len()));
            out.push((Tok::Lit(v), at));
        } else if ch == '\'' {
            // 'x', '\n', '\u{..}' — символ; інакше — час життя ('a).
            if c.get(i + 1) == Some(&'\\') {
                i += 3; // лапка, зворотна риска й екранований символ (зокрема '\'')
                while i < c.len() && c[i] != '\'' {
                    i += 1;
                }
                i += 1;
            } else if c.get(i + 2) == Some(&'\'') {
                i += 3;
            } else {
                i += 1;
            }
        } else if ch.is_alphanumeric() || ch == '_' {
            let start = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '_') {
                i += 1;
            }
            let word: String = c[start..i].iter().collect();
            let raw = matches!(word.as_str(), "r" | "br" | "cr");
            let plain = matches!(word.as_str(), "b" | "c");
            if raw && matches!(c.get(i), Some('"') | Some('#')) {
                let mut hashes = 0;
                let mut j = i;
                while c.get(j) == Some(&'#') {
                    hashes += 1;
                    j += 1;
                }
                if c.get(j) == Some(&'"') {
                    let (from, at) = (j + 1, line);
                    let mut k = from;
                    loop {
                        if k >= c.len() {
                            break;
                        }
                        if c[k] == '"' && (1..=hashes).all(|h| c.get(k + h) == Some(&'#')) {
                            break;
                        }
                        k += 1;
                    }
                    out.push((Tok::Lit(c[from..k.min(c.len())].iter().collect()), at));
                    i = (k + 1 + hashes).min(c.len());
                    line += count_lines(start, i);
                    continue;
                }
            }
            if plain && c.get(i) == Some(&'"') {
                continue; // префікс b"…"/c"…": далі — звичайний рядок
            }
            out.push((Tok::Ident(word), line));
        } else {
            out.push((Tok::Punct(ch), line));
            i += 1;
        }
    }
    out
}

#[derive(Debug, PartialEq)]
struct Hit {
    rule: &'static str,
    line: usize,
    detail: String,
}

fn is_git_name(v: &str) -> bool {
    let v = v.to_lowercase();
    ["git", "git.exe"].contains(&v.as_str())
        || ["/git", "\\git", "/git.exe", "\\git.exe"].iter().any(|s| v.ends_with(s))
}

/// Рядок оболонки, де `git` — окреме слово команди в будь-якому місці: `git status`, `cd x && git status`,
/// `& git status`, `(git status)`. Межі слова — пробіли й роздільники оболонки; `.git`, `--no-git`,
/// `gitignore` словом `git` не є.
fn is_git_command_line(v: &str) -> bool {
    v.split(|c: char| c.is_whitespace() || ";&|()'\"`".contains(c)).any(is_git_name)
}

fn ident(t: Option<&(Tok, usize)>, name: &str) -> bool {
    matches!(t, Some((Tok::Ident(s), _)) if s == name)
}

fn punct(t: Option<&(Tok, usize)>, ch: char) -> bool {
    matches!(t, Some((Tok::Punct(p), _)) if *p == ch)
}

/// `Command :: new` на позиції i.
fn is_command_new(toks: &[(Tok, usize)], i: usize) -> bool {
    ident(toks.get(i), "Command") && punct(toks.get(i + 1), ':') && punct(toks.get(i + 2), ':') && ident(toks.get(i + 3), "new")
}

/// Літерал на позиції `at` лежить в аргументах `.arg(`/`.args(`/`Command::new(` — на будь-якому рівні
/// вкладеності в межах інструкції.
fn inside_launch_args(toks: &[(Tok, usize)], at: usize) -> bool {
    let mut depth = 0i32;
    let mut i = at;
    while i > 0 {
        i -= 1;
        match &toks[i].0 {
            Tok::Punct(')') | Tok::Punct(']') | Tok::Punct('}') => depth += 1,
            Tok::Punct('{') if depth == 0 => return false,
            Tok::Punct(';') if depth == 0 => return false,
            Tok::Punct('(') | Tok::Punct('[') | Tok::Punct('{') if depth > 0 => depth -= 1,
            Tok::Punct('(') => {
                let method = i >= 2 && punct(toks.get(i - 2), '.') && (ident(toks.get(i - 1), "arg") || ident(toks.get(i - 1), "args"));
                let ctor = i >= 4 && is_command_new(toks, i - 4);
                if method || ctor {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

fn text(toks: &[(Tok, usize)]) -> String {
    toks.iter()
        .map(|(t, _)| match t {
            Tok::Ident(s) => s.clone(),
            Tok::Lit(s) => format!("{s:?}"),
            Tok::Punct(p) => p.to_string(),
        })
        .collect()
}

/// Влучення правила в одному джерелі. Динамічні `Command::new` повертаються окремо — їх звіряють з
/// переліком дозволених місць.
fn scan_source(src: &str) -> (Vec<Hit>, Vec<(usize, String)>) {
    let toks = lex(src);
    let mut hits = Vec::new();
    let mut dynamic = Vec::new();
    for (i, (t, line)) in toks.iter().enumerate() {
        match t {
            Tok::Lit(v) if is_git_name(v) => hits.push(Hit { rule: "а", line: *line, detail: format!("{v:?}") }),
            Tok::Lit(v) if is_git_command_line(v) && inside_launch_args(&toks, i) => {
                hits.push(Hit { rule: "б", line: *line, detail: format!("{v:?}") })
            }
            Tok::Ident(s) if s == "Command" => {
                if ident(toks.get(i + 1), "as") {
                    hits.push(Hit { rule: "г", line: *line, detail: "Command as …".into() });
                }
                if punct(toks.get(i + 1), ';') {
                    let start = toks[..i].iter().rposition(|(t, _)| matches!(t, Tok::Punct(';') | Tok::Punct('{') | Tok::Punct('}'))).map_or(0, |p| p + 1);
                    if toks[start..i].iter().any(|(t, _)| matches!(t, Tok::Ident(s) if s == "type")) {
                        hits.push(Hit { rule: "г", line: *line, detail: format!("type … = {};", text(&toks[start..=i])) });
                    }
                }
                if is_command_new(&toks, i) {
                    if !punct(toks.get(i + 4), '(') {
                        dynamic.push((*line, "<Command::new як значення>".to_string()));
                        continue;
                    }
                    let open = i + 4;
                    let mut depth = 0;
                    let mut close = open;
                    for (k, (t, _)) in toks.iter().enumerate().skip(open) {
                        match t {
                            Tok::Punct('(') => depth += 1,
                            Tok::Punct(')') => {
                                depth -= 1;
                                if depth == 0 {
                                    close = k;
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                    let arg = &toks[open + 1..close.max(open + 1)];
                    if !(arg.len() == 1 && matches!(arg[0].0, Tok::Lit(_))) {
                        dynamic.push((*line, text(arg)));
                    }
                }
            }
            _ => {}
        }
    }
    (hits, dynamic)
}

fn in_git_module(rel: &str) -> bool {
    rel == "src/git.rs" || rel.starts_with("src/git/")
}

/// Файли обсягу: rust/src/**/*.rs і rust/build.rs, відносні шляхи з `/`.
fn scope_files(root: &Path) -> Vec<(String, PathBuf)> {
    fn walk(dir: &Path, rel: &str, out: &mut Vec<(String, PathBuf)>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let name = e.file_name().to_string_lossy().into_owned();
            let child = format!("{rel}/{name}");
            if e.file_type().unwrap().is_dir() {
                walk(&e.path(), &child, out);
            } else if name.ends_with(".rs") {
                out.push((child, e.path()));
            }
        }
    }
    let mut out = vec![("build.rs".to_string(), root.join("build.rs"))];
    walk(&root.join("src"), "src", &mut out);
    out
}

/// Незалежний лічильник файлів `*.rs` обсягу (контроль сліпоти): інший обхід — стек, не рекурсія.
fn count_rs(root: &Path) -> usize {
    let mut n = usize::from(root.join("build.rs").is_file());
    let mut stack = vec![root.join("src")];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "rs") {
                n += 1;
            }
        }
    }
    n
}

struct Report {
    scanned: usize,
    violations: Vec<String>,
    git_module_hits: usize,
}

fn scan_crate(root: &Path, allowed: &[(&str, &str, &str)], allowed_literal: &[(&str, &str, &str)]) -> Report {
    let files = scope_files(root);
    let mut unused: Vec<(&str, &str)> = allowed.iter().map(|(f, a, _)| (*f, *a)).collect();
    let mut unused_lit: Vec<(&str, &str)> = allowed_literal.iter().map(|(f, a, _)| (*f, *a)).collect();
    let mut violations = Vec::new();
    let mut git_module_hits = 0;
    for (rel, path) in &files {
        let src = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{rel}: {e}"));
        let (hits, dynamic) = scan_source(&src);
        if in_git_module(rel) {
            git_module_hits += hits.len();
            continue;
        }
        for h in hits {
            if h.rule == "а" {
                let pos = unused_lit.iter().position(|(f, lit)| *f == rel && format!("{lit:?}") == h.detail);
                if let Some(p) = pos {
                    unused_lit.remove(p);
                    continue;
                }
            }
            violations.push(format!("{rel}:{} правило ({}) {}", h.line, h.rule, h.detail));
        }
        for (line, arg) in dynamic {
            match unused.iter().position(|(f, a)| *f == rel && *a == arg) {
                Some(p) => {
                    unused.remove(p);
                }
                None => violations.push(format!("{rel}:{line} правило (в) Command::new({arg}) поза переліком дозволених")),
            }
        }
    }
    for (f, a) in unused {
        violations.push(format!("застарілий запис переліку дозволених: {f} Command::new({a})"));
    }
    for (f, lit) in unused_lit {
        violations.push(format!("застарілий запис переліку дозволених літералів: {f} {lit:?}"));
    }
    Report { scanned: files.len(), violations, git_module_hits }
}

#[test]
fn git_is_launched_only_in_git_module() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let r = scan_crate(root, ALLOWED_DYNAMIC, ALLOWED_LITERAL);
    assert!(r.scanned > 0, "сканер не бачить жодного файлу");
    assert_eq!(r.scanned, count_rs(root), "відскановано не всі файли *.rs обсягу");
    assert!(r.git_module_hits > 0, "у модулі git немає жодного влучення — сканер сліпий");
    assert!(r.violations.is_empty(), "запуск git поза модулем git:\n{}", r.violations.join("\n"));
}

/// Мутації R1–R14 правила і три з аудиту: кожна дає влучення (для (в) — динамічний запуск поза
/// переліком).
#[test]
fn launch_forms_are_caught() {
    let cases: &[(&str, &str)] = &[
        ("R1 літерал", r#"fn f() { Command::new("git").arg("status"); }"#),
        ("R2 git.exe", r#"fn f() { Command::new("git.exe").status(); }"#),
        ("R3 повний шлях", r#"fn f() { Command::new(r"C:\Program Files\Git\cmd\git.exe").status(); }"#),
        ("R4 змінна", r#"fn f() { let g = "git"; Command::new(g).status(); }"#),
        ("R5 const", r#"const GIT: &str = "git"; fn f() { Command::new(GIT).status(); }"#),
        ("R6 повний шлях типу", r#"fn f() { std::process::Command::new("git").status(); }"#),
        ("R7 cmd /c", r#"fn f() { Command::new("cmd").args(["/c", "git status"]).status(); }"#),
        ("R8 pwsh -c", r#"fn f() { Command::new("pwsh").arg("-c").arg("git status --short").status(); }"#),
        ("R12 git посеред рядка cmd", r#"fn f() { Command::new("cmd").args(["/c", "cd x && git status"]).status(); }"#),
        ("R13 git після & у pwsh", r#"fn f() { Command::new("pwsh").args(["-Command", "& git status"]).status(); }"#),
        ("R14 git.exe у дужках", r#"fn f() { Command::new("pwsh").arg("-c").arg("(git.exe rev-parse HEAD)").status(); }"#),
        ("R9 конкатенація", r#"fn f() { Command::new(format!("{}{}", "gi", "t")).status(); }"#),
        ("R10 ім'я з оточення", r#"fn f() { Command::new(std::env::var("KIT_GIT").unwrap()).status(); }"#),
        ("R11 сирий рядок", r##"fn f() { Command::new(r#"git"#).status(); }"##),
        ("A1 псевдонім зі змінною", r#"use std::process::Command as Proc; fn f(v: &str) { Proc::new(v).status(); }"#),
        ("A1 псевдонім type", r#"type Proc = std::process::Command; fn f(v: &str) { Proc::new(v).status(); }"#),
        ("A3 /* у рядку", "fn f() { let s = \"/*\"; Command::new(\"git\").status(); let t = \"*/\"; }"),
        ("A4 екранування \\x", r#"fn f() { Command::new("\x67it").status(); }"#),
        ("A4 екранування \\u", r#"fn f() { Command::new("\u{67}\u{0069}t").status(); }"#),
        ("A4 перенос рядка після \\", "fn f() { Command::new(\"g\\\n      it\").status(); }"),
    ];
    for (name, src) in cases {
        let (hits, dynamic) = scan_source(src);
        assert!(!hits.is_empty() || !dynamic.is_empty(), "{name}: не спіймано\n{src}");
    }
}

/// Не-запуски: повідомлення з `git {}`, коментарі, виклик ядра, `.git`, дозволений `gh` — без влучень.
#[test]
fn non_launches_are_not_hits() {
    let src = r#"
        // Command::new("git").status();
        /* Command::new("git") /* вкладений */ "git" */
        fn f(repo: &Path) {
            eprintln!("git {} завершився з помилкою", 1);
            let dot = repo.join(".git");
            let _ = kit::git::run(repo, &["status"], None, false);
            let c = '"';
            Command::new("taskkill").args(["/T", "/F"]).status();
            Command::new("taskkill").args(["/c", "echo .git --no-git gitignore"]).status();
        }
    "#;
    assert_eq!(scan_source(src), (vec![], vec![]));
    // Динамічний запуск із дозволеного місця — не порушення; той самий в іншому файлі — порушення.
    let (_, dynamic) = scan_source("fn f(gh: &Path) { Command::new(&gh).status(); }");
    assert_eq!(dynamic, vec![(1, "&gh".to_string())]);
}

/// A2: файл у підтеці src/**/ сканується; запуск у ньому — порушення, перелік дозволених не застарілий
/// лише тоді, коли місце справді є.
#[test]
fn nested_file_is_scanned() {
    let tmp = std::env::temp_dir().join(format!("kit-guard-{}-{}", std::process::id(), line!()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("src/a/b")).unwrap();
    std::fs::write(tmp.join("build.rs"), "fn main() {}").unwrap();
    std::fs::write(tmp.join("src/git.rs"), r#"fn g() { Command::new("git"); }"#).unwrap();
    std::fs::write(tmp.join("src/a/b/deep.rs"), r#"fn f() { Command::new("git").status(); }"#).unwrap();
    let r = scan_crate(&tmp, &[("src/main.rs", "&pwsh", "")], &[]);
    let _ = std::fs::remove_dir_all(&tmp);
    assert_eq!(r.scanned, 3);
    assert_eq!(r.git_module_hits, 1);
    assert_eq!(
        r.violations,
        vec![
            "src/a/b/deep.rs:1 правило (а) \"git\"".to_string(),
            "застарілий запис переліку дозволених: src/main.rs Command::new(&pwsh)".to_string(),
        ]
    );
}

/// Перелік дозволених літералів: запис гасить рівно одне влучення правила (а) у своєму файлі; застарілий запис
/// і той самий літерал в іншому файлі поза модулем git — червоне (контроль, що сканер не осліп).
#[test]
fn allowed_literal_is_exact_and_stale_entries_fail() {
    let tmp = std::env::temp_dir().join(format!("kit-guard-{}-{}", std::process::id(), line!()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("src")).unwrap();
    std::fs::write(tmp.join("build.rs"), "fn main() {}").unwrap();
    std::fs::write(tmp.join("src/git.rs"), r#"fn g() { Command::new("git"); }"#).unwrap();
    std::fs::write(tmp.join("src/words.rs"), r#"const A: &str = "git";"#).unwrap();
    std::fs::write(tmp.join("src/other.rs"), r#"const B: &str = "git";"#).unwrap();
    let allowed = [("src/words.rs", "git", "слово словника")];
    let r = scan_crate(&tmp, &[], &allowed);
    assert_eq!(r.violations, vec!["src/other.rs:1 правило (а) \"git\"".to_string()], "дозволений запис гасить лише своє місце");
    // Застарілий запис: у файлі літерала немає.
    let stale = [("src/words.rs", "git", ""), ("src/other.rs", "git", ""), ("src/nowhere.rs", "git", "")];
    let r = scan_crate(&tmp, &[], &stale);
    let _ = std::fs::remove_dir_all(&tmp);
    assert_eq!(r.violations, vec!["застарілий запис переліку дозволених літералів: src/nowhere.rs \"git\"".to_string()]);
}
