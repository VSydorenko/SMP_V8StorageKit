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
//  мусить відповідати рівно одному літералу, застарілий запис — червоне, як в ALLOWED_DYNAMIC. Літерал в аргументах
//  запуску (`.arg(`, `.args(`, `Command::new(`) перелік не гасить ніколи.
//  (г) псевдонім типу `Command` (`Command as X`, `type X = …Command;`).
//  Межа: сканер ловить літерал і відомі форми запуску; обчислений рядок в аргументах (константа, виклик функції,
//  `concat!`, змінна оболонки) — поза межею лексичного сканера, його тримає рев'ю коду.
// Позитивний двійник: у модулі `git` правило влучення ДАЄ — інакше сканер сліпий.
//
// Друге правило тієї ж схеми — «раннер Уніки запускає лише модуль `runner`» (ADR-0019).
// Модуль `runner` — src/runner.rs і src/runner/**. Правило раннера діє ВСЮДИ, зокрема в модулі git:
//  (д) рядковий літерал, останній сегмент шляху якого (після `/` чи `\`) дорівнює без регістру `v8-runner` чи
//      `v8-runner.exe`;
//  (е) літерал зі словом `v8-runner` (так само, як (д), по словах) усередині `.arg(`, `.args(`, `Command::new(`.
// Вердикти (`"Раннер v8-runner {v}."`) і сегмент `v8-runner-windows-x86_64` влучень не дають. Позитивний двійник:
// у модулі `runner` (д)/(е) влучення ДАЮТЬ (власний лічильник), а правила git (а), (б), (г) там діють, як скрізь.
// Динамічний `Command::new` у модулі `runner` — рівно один, у приватній функції-будівнику `runner_command`
// (без запису в ALLOWED_DYNAMIC): `exec`, `exec_inherit` і `run` ідуть через неї.
//
// Окрема перевірка оточення: у src/unica* і src/runner* немає читання змінних оточення, крім одного
// дозволеного місця — домашньої теки в `unica::default_registry` (ALLOWED_ENV; шлях раннера не береться з оточення).

use std::path::{Path, PathBuf};

/// Приватна функція модуля `runner`, що будує `Command` раннера: єдине дозволене там динамічне `Command::new`.
const RUNNER_BUILDER: &str = "runner_command";

/// Дозволені читання оточення в модулях `unica`/`runner`: (файл відносно rust/, функція). Застарілий запис —
/// червоне.
const ALLOWED_ENV: &[(&str, &str)] = &[("src/unica.rs", "default_registry")];

/// Дозволені динамічні `Command::new`: (файл відносно rust/, текст аргументу, навіщо). Кожен запис
/// мусить відповідати рівно одному місцю в коді — застарілий запис теж червоне.
const ALLOWED_DYNAMIC: &[(&str, &str, &str)] = &[
    (
        "src/main.rs",
        "&pwsh",
        "передача команди PowerShell-диспетчеру",
    ),
    (
        "src/proc.rs",
        "&taskkill",
        "убити дерево процесів на стелі часу: хук старту (session-check) і gh",
    ),
    (
        "src/gh.rs",
        "&exe",
        "gh для session-board: програма знайдена в PATH",
    ),
    (
        "src/session_start.rs",
        "std::env::current_exe().map_err(|e|format!(\"шлях kit.exe не визначено: {e}\"))?,",
        "хук старту сесії: дочірній session-check — сам kit.exe (current_exe), не з PATH",
    ),
];

/// Дозволені літерали правила (а): (файл відносно rust/, літерал, навіщо). Кожен запис — рівно одне місце.
const ALLOWED_LITERAL: &[(&str, &str, &str)] = &[(
    "src/config/mod.rs",
    "git",
    "значення truth: git у словнику маніфесту, не програма",
)];

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
                            let hex: String = c[(i + 2).min(c.len())..(i + 4).min(c.len())]
                                .iter()
                                .collect();
                            v.extend(u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32));
                            i += 4;
                        }
                        // `\u{…}`: до шести цифр, підкреслення дозволені.
                        'u' if c.get(i + 2) == Some(&'{') => {
                            let close = c[i..]
                                .iter()
                                .position(|ch| *ch == '}')
                                .map_or(c.len(), |p| i + p);
                            let hex: String =
                                c[i + 3..close].iter().filter(|ch| **ch != '_').collect();
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
    /// Літерал стоїть в аргументах запуску (`.arg(`, `.args(`, `Command::new(`): перелік його не гасить.
    in_launch_args: bool,
}

fn is_git_name(v: &str) -> bool {
    let v = v.to_lowercase();
    ["git", "git.exe"].contains(&v.as_str())
        || ["/git", "\\git", "/git.exe", "\\git.exe"]
            .iter()
            .any(|s| v.ends_with(s))
}

/// Ім'я раннера: останній сегмент шляху (після `/` чи `\`) — `v8-runner` або `v8-runner.exe`, без регістру.
fn is_runner_name(v: &str) -> bool {
    let last = v.rsplit(['/', '\\']).next().unwrap_or("").to_lowercase();
    last == "v8-runner" || last == "v8-runner.exe"
}

/// Рядок оболонки, де раннер — окреме слово (межі — як у `is_git_command_line`).
fn is_runner_command_line(v: &str) -> bool {
    v.split(|c: char| c.is_whitespace() || ";&|()'\"`".contains(c))
        .any(is_runner_name)
}

/// Рядок оболонки, де `git` — окреме слово команди в будь-якому місці: `git status`, `cd x && git status`,
/// `& git status`, `(git status)`. Межі слова — пробіли й роздільники оболонки; `.git`, `--no-git`,
/// `gitignore` словом `git` не є.
fn is_git_command_line(v: &str) -> bool {
    v.split(|c: char| c.is_whitespace() || ";&|()'\"`".contains(c))
        .any(is_git_name)
}

fn ident(t: Option<&(Tok, usize)>, name: &str) -> bool {
    matches!(t, Some((Tok::Ident(s), _)) if s == name)
}

fn punct(t: Option<&(Tok, usize)>, ch: char) -> bool {
    matches!(t, Some((Tok::Punct(p), _)) if *p == ch)
}

/// `Command :: new` на позиції i.
fn is_command_new(toks: &[(Tok, usize)], i: usize) -> bool {
    ident(toks.get(i), "Command")
        && punct(toks.get(i + 1), ':')
        && punct(toks.get(i + 2), ':')
        && ident(toks.get(i + 3), "new")
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
                let method = i >= 2
                    && punct(toks.get(i - 2), '.')
                    && (ident(toks.get(i - 1), "arg") || ident(toks.get(i - 1), "args"));
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

/// Динамічний `Command::new`: рядок, текст аргументу й ім'я найближчої функції `fn` угорі.
#[derive(Debug, PartialEq)]
struct Dyn {
    line: usize,
    arg: String,
    func: String,
}

/// Ім'я функції, у тілі якої лежить лексема `i` (найближче `fn <ім'я>` угорі; вкладені `fn` не розрізняються).
fn enclosing_fn(toks: &[(Tok, usize)], i: usize) -> String {
    toks[..i]
        .iter()
        .rposition(|(t, _)| matches!(t, Tok::Ident(s) if s == "fn"))
        .and_then(|p| match toks.get(p + 1) {
            Some((Tok::Ident(name), _)) => Some(name.clone()),
            _ => None,
        })
        .unwrap_or_default()
}

/// Влучення правила в одному джерелі. Динамічні `Command::new` повертаються окремо — їх звіряють з
/// переліком дозволених місць.
fn scan_source(src: &str) -> (Vec<Hit>, Vec<(usize, String)>) {
    let (hits, dynamic) = scan_full(src);
    (hits, dynamic.into_iter().map(|d| (d.line, d.arg)).collect())
}

fn scan_full(src: &str) -> (Vec<Hit>, Vec<Dyn>) {
    let toks = lex(src);
    let mut hits = Vec::new();
    let mut dynamic = Vec::new();
    for (i, (t, line)) in toks.iter().enumerate() {
        if let Tok::Lit(v) = t {
            if is_runner_name(v) {
                hits.push(Hit {
                    rule: "д",
                    line: *line,
                    detail: format!("{v:?}"),
                    in_launch_args: false,
                });
            } else if is_runner_command_line(v) && inside_launch_args(&toks, i) {
                hits.push(Hit {
                    rule: "е",
                    line: *line,
                    detail: format!("{v:?}"),
                    in_launch_args: false,
                });
            }
        }
        match t {
            Tok::Lit(v) if is_git_name(v) => hits.push(Hit {
                rule: "а",
                line: *line,
                detail: format!("{v:?}"),
                in_launch_args: inside_launch_args(&toks, i),
            }),
            Tok::Lit(v) if is_git_command_line(v) && inside_launch_args(&toks, i) => {
                hits.push(Hit {
                    rule: "б",
                    line: *line,
                    detail: format!("{v:?}"),
                    in_launch_args: true,
                })
            }
            Tok::Ident(s) if s == "Command" => {
                if ident(toks.get(i + 1), "as") {
                    hits.push(Hit {
                        rule: "г",
                        line: *line,
                        detail: "Command as …".into(),
                        in_launch_args: false,
                    });
                }
                if punct(toks.get(i + 1), ';') {
                    let start = toks[..i]
                        .iter()
                        .rposition(|(t, _)| {
                            matches!(t, Tok::Punct(';') | Tok::Punct('{') | Tok::Punct('}'))
                        })
                        .map_or(0, |p| p + 1);
                    if toks[start..i]
                        .iter()
                        .any(|(t, _)| matches!(t, Tok::Ident(s) if s == "type"))
                    {
                        hits.push(Hit {
                            rule: "г",
                            line: *line,
                            detail: format!("type … = {};", text(&toks[start..=i])),
                            in_launch_args: false,
                        });
                    }
                }
                if is_command_new(&toks, i) {
                    if !punct(toks.get(i + 4), '(') {
                        dynamic.push(Dyn {
                            line: *line,
                            arg: "<Command::new як значення>".to_string(),
                            func: enclosing_fn(&toks, i),
                        });
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
                        dynamic.push(Dyn {
                            line: *line,
                            arg: text(arg),
                            func: enclosing_fn(&toks, i),
                        });
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

fn in_runner_module(rel: &str) -> bool {
    rel == "src/runner.rs" || rel.starts_with("src/runner/")
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
    /// Влучення правила раннера (д)/(е) у модулі `runner` — позитивний двійник.
    runner_module_hits: usize,
    /// Динамічні `Command::new` у функції-будівнику модуля `runner`.
    runner_builders: usize,
}

fn scan_crate(
    root: &Path,
    allowed: &[(&str, &str, &str)],
    allowed_literal: &[(&str, &str, &str)],
) -> Report {
    let files = scope_files(root);
    let mut unused: Vec<(&str, &str)> = allowed.iter().map(|(f, a, _)| (*f, *a)).collect();
    let mut unused_lit: Vec<(&str, &str)> =
        allowed_literal.iter().map(|(f, a, _)| (*f, *a)).collect();
    let mut violations = Vec::new();
    let (mut git_module_hits, mut runner_module_hits, mut runner_builders) = (0, 0, 0);
    for (rel, path) in &files {
        let src = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{rel}: {e}"));
        let (hits, dynamic) = scan_full(&src);
        let (in_git, in_runner) = (in_git_module(rel), in_runner_module(rel));
        for h in hits {
            let runner_rule = matches!(h.rule, "д" | "е");
            if in_git && !runner_rule {
                git_module_hits += 1;
            } else if in_runner && runner_rule {
                runner_module_hits += 1;
            } else {
                if h.rule == "а" && !h.in_launch_args {
                    let pos = unused_lit
                        .iter()
                        .position(|(f, lit)| *f == rel && format!("{lit:?}") == h.detail);
                    if let Some(p) = pos {
                        unused_lit.remove(p);
                        continue;
                    }
                }
                violations.push(format!(
                    "{rel}:{} правило ({}) {}",
                    h.line, h.rule, h.detail
                ));
            }
        }
        if in_git {
            continue;
        }
        for d in dynamic {
            if in_runner {
                if d.func == RUNNER_BUILDER && runner_builders == 0 {
                    runner_builders += 1;
                } else {
                    violations.push(format!(
                        "{rel}:{} правило (в) Command::new({}) у модулі runner: дозволене одне, у функції {RUNNER_BUILDER} (тут: {})",
                        d.line, d.arg, d.func
                    ));
                }
                continue;
            }
            match unused.iter().position(|(f, a)| *f == rel && *a == d.arg) {
                Some(p) => {
                    unused.remove(p);
                }
                None => violations.push(format!(
                    "{rel}:{} правило (в) Command::new({}) поза переліком дозволених",
                    d.line, d.arg
                )),
            }
        }
    }
    for (f, a) in unused {
        violations.push(format!(
            "застарілий запис переліку дозволених: {f} Command::new({a})"
        ));
    }
    for (f, lit) in unused_lit {
        violations.push(format!(
            "застарілий запис переліку дозволених літералів: {f} {lit:?}"
        ));
    }
    Report {
        scanned: files.len(),
        violations,
        git_module_hits,
        runner_module_hits,
        runner_builders,
    }
}

/// Читання оточення в модулях `unica`/`runner`: (рядок, функція). Ознаки: `env::{var,var_os,vars,vars_os}`,
/// `env::{…}` і `env as …` (обхід імпортом), голі `var_os`/`vars`/`vars_os`, `::var`. Макрос `env!` — час
/// збірки, не оточення виконання.
fn scan_env(src: &str) -> Vec<(usize, String)> {
    let toks = lex(src);
    let mut out = Vec::new();
    for (i, (t, line)) in toks.iter().enumerate() {
        let Tok::Ident(s) = t else { continue };
        let after_path = i >= 2 && punct(toks.get(i - 1), ':') && punct(toks.get(i - 2), ':');
        let hit = match s.as_str() {
            "var_os" | "vars" | "vars_os" => true,
            "var" => after_path,
            "env" => {
                (punct(toks.get(i + 1), ':')
                    && punct(toks.get(i + 2), ':')
                    && punct(toks.get(i + 3), '{'))
                    || ident(toks.get(i + 1), "as")
            }
            _ => false,
        };
        if hit {
            out.push((*line, enclosing_fn(&toks, i)));
        }
    }
    out
}

fn in_env_scope(rel: &str) -> bool {
    rel.starts_with("src/unica") || rel.starts_with("src/runner")
}

/// Порушення перевірки оточення: читання поза ALLOWED_ENV і застарілі дозволи.
fn env_violations(root: &Path, allowed: &[(&str, &str)]) -> Vec<String> {
    let mut unused: Vec<(&str, &str)> = allowed.to_vec();
    let mut out = Vec::new();
    for (rel, path) in scope_files(root)
        .iter()
        .filter(|(rel, _)| in_env_scope(rel))
    {
        let src = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{rel}: {e}"));
        for (line, func) in scan_env(&src) {
            match unused.iter().position(|(f, g)| f == rel && *g == func) {
                Some(p) => {
                    unused.remove(p);
                }
                None => out.push(format!("{rel}:{line} читання оточення у функції {func:?}")),
            }
        }
    }
    for (f, g) in unused {
        out.push(format!("застарілий дозвіл оточення: {f} {g}"));
    }
    out
}

#[test]
fn git_is_launched_only_in_git_module() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let r = scan_crate(root, ALLOWED_DYNAMIC, ALLOWED_LITERAL);
    assert!(r.scanned > 0, "сканер не бачить жодного файлу");
    assert_eq!(
        r.scanned,
        count_rs(root),
        "відскановано не всі файли *.rs обсягу"
    );
    assert!(
        r.git_module_hits > 0,
        "у модулі git немає жодного влучення — сканер сліпий"
    );
    assert!(
        r.runner_module_hits > 0,
        "у модулі runner немає жодного влучення правила раннера — сканер сліпий"
    );
    assert_eq!(
        r.runner_builders, 1,
        "у модулі runner має бути рівно одна функція-будівник {RUNNER_BUILDER}"
    );
    assert!(
        r.violations.is_empty(),
        "запуск git чи раннера поза своїм модулем:\n{}",
        r.violations.join("\n")
    );
}

#[test]
fn unica_and_runner_do_not_read_the_environment() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let v = env_violations(root, ALLOWED_ENV);
    assert!(
        v.is_empty(),
        "читання оточення в модулях unica/runner:\n{}",
        v.join("\n")
    );
}

/// Мутації R1–R14 правила і три з аудиту: кожна дає влучення (для (в) — динамічний запуск поза
/// переліком).
#[test]
fn launch_forms_are_caught() {
    let cases: &[(&str, &str)] = &[
        (
            "R1 літерал",
            r#"fn f() { Command::new("git").arg("status"); }"#,
        ),
        (
            "R2 git.exe",
            r#"fn f() { Command::new("git.exe").status(); }"#,
        ),
        (
            "R3 повний шлях",
            r#"fn f() { Command::new(r"C:\Program Files\Git\cmd\git.exe").status(); }"#,
        ),
        (
            "R4 змінна",
            r#"fn f() { let g = "git"; Command::new(g).status(); }"#,
        ),
        (
            "R5 const",
            r#"const GIT: &str = "git"; fn f() { Command::new(GIT).status(); }"#,
        ),
        (
            "R6 повний шлях типу",
            r#"fn f() { std::process::Command::new("git").status(); }"#,
        ),
        (
            "R7 cmd /c",
            r#"fn f() { Command::new("cmd").args(["/c", "git status"]).status(); }"#,
        ),
        (
            "R8 pwsh -c",
            r#"fn f() { Command::new("pwsh").arg("-c").arg("git status --short").status(); }"#,
        ),
        (
            "R12 git посеред рядка cmd",
            r#"fn f() { Command::new("cmd").args(["/c", "cd x && git status"]).status(); }"#,
        ),
        (
            "R13 git після & у pwsh",
            r#"fn f() { Command::new("pwsh").args(["-Command", "& git status"]).status(); }"#,
        ),
        (
            "R14 git.exe у дужках",
            r#"fn f() { Command::new("pwsh").arg("-c").arg("(git.exe rev-parse HEAD)").status(); }"#,
        ),
        (
            "R9 конкатенація",
            r#"fn f() { Command::new(format!("{}{}", "gi", "t")).status(); }"#,
        ),
        (
            "R10 ім'я з оточення",
            r#"fn f() { Command::new(std::env::var("KIT_GIT").unwrap()).status(); }"#,
        ),
        (
            "R11 сирий рядок",
            r##"fn f() { Command::new(r#"git"#).status(); }"##,
        ),
        (
            "A1 псевдонім зі змінною",
            r#"use std::process::Command as Proc; fn f(v: &str) { Proc::new(v).status(); }"#,
        ),
        (
            "A1 псевдонім type",
            r#"type Proc = std::process::Command; fn f(v: &str) { Proc::new(v).status(); }"#,
        ),
        (
            "A3 /* у рядку",
            "fn f() { let s = \"/*\"; Command::new(\"git\").status(); let t = \"*/\"; }",
        ),
        (
            "A4 екранування \\x",
            r#"fn f() { Command::new("\x67it").status(); }"#,
        ),
        (
            "A4 екранування \\u",
            r#"fn f() { Command::new("\u{67}\u{0069}t").status(); }"#,
        ),
        (
            "A4 перенос рядка після \\",
            "fn f() { Command::new(\"g\\\n      it\").status(); }",
        ),
    ];
    for (name, src) in cases {
        let (hits, dynamic) = scan_source(src);
        assert!(
            !hits.is_empty() || !dynamic.is_empty(),
            "{name}: не спіймано\n{src}"
        );
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
    std::fs::write(
        tmp.join("src/a/b/deep.rs"),
        r#"fn f() { Command::new("git").status(); }"#,
    )
    .unwrap();
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
    assert_eq!(
        r.violations,
        vec!["src/other.rs:1 правило (а) \"git\"".to_string()],
        "дозволений запис гасить лише своє місце"
    );
    // Застарілий запис: у файлі літерала немає.
    let stale = [
        ("src/words.rs", "git", ""),
        ("src/other.rs", "git", ""),
        ("src/nowhere.rs", "git", ""),
    ];
    let r = scan_crate(&tmp, &[], &stale);
    assert_eq!(
        r.violations,
        vec!["застарілий запис переліку дозволених літералів: src/nowhere.rs \"git\"".to_string()]
    );
    // Дозволений файл із запуском замість оголошення — червоне: перелік не гасить літерал в аргументах запуску.
    std::fs::write(
        tmp.join("src/words.rs"),
        r#"pub fn probe() { let _ = std::process::Command::new("git").arg("status").status(); }"#,
    )
    .unwrap();
    std::fs::write(tmp.join("src/other.rs"), "").unwrap();
    let r = scan_crate(&tmp, &[], &allowed);
    assert!(
        r.violations
            .iter()
            .any(|v| v.starts_with("src/words.rs:1 правило (а)")),
        "запуск у дозволеному файлі пройшов: {:?}",
        r.violations
    );
    // Той самий файл лише з оголошенням — зелене.
    std::fs::write(
        tmp.join("src/words.rs"),
        r#"const TRUTH_GIT: &str = "git";"#,
    )
    .unwrap();
    let r = scan_crate(&tmp, &[], &allowed);
    let _ = std::fs::remove_dir_all(&tmp);
    assert!(
        r.violations.is_empty(),
        "оголошення має проходити: {:?}",
        r.violations
    );
}

/// Тимчасовий крейт із заданими файлами `src/…` (шляхи з `/`) і порожнім build.rs.
fn synthetic(name: &str, files: &[(&str, &str)]) -> Report {
    let tmp = std::env::temp_dir().join(format!(
        "kit-guard-{name}-{}-{}",
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("src")).unwrap();
    std::fs::write(tmp.join("build.rs"), "fn main() {}").unwrap();
    for (rel, src) in files {
        let p = tmp.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, src).unwrap();
    }
    let r = scan_crate(&tmp, &[], &[]);
    let _ = std::fs::remove_dir_all(&tmp);
    r
}

const BUILDER: &str = "fn runner_command(r: &Path) -> Command { Command::new(r) }";

/// Позитивний двійник і межі модуля `runner`: влучення раннера там рахуються, будівник один, правила git діють.
#[test]
fn runner_module_rules() {
    // Двійник: літерал раннера й будівник в модулі — без порушень, влучення пораховано.
    let ok = format!(r#"{BUILDER} fn p() -> &'static str {{ "v8-runner.exe" }}"#);
    let r = synthetic("rm-ok", &[("src/runner.rs", &ok)]);
    assert!(r.violations.is_empty(), "{:?}", r.violations);
    assert_eq!((r.runner_module_hits, r.runner_builders), (1, 1));

    // Контроль: git у модулі runner — червоне.
    let bad = format!(r#"{BUILDER} fn g() {{ Command::new("git").status(); }}"#);
    let r = synthetic("rm-git", &[("src/runner.rs", &bad)]);
    assert_eq!(r.violations.len(), 1, "{:?}", r.violations);
    assert!(r.violations[0].contains("правило (а)"));

    // Контроль: другий динамічний Command::new поза будівником — червоне; другий усередині будівника теж.
    for (name, src) in [
        (
            "rm-dyn",
            format!("{BUILDER} fn other(r: &Path) {{ Command::new(r).status(); }}"),
        ),
        (
            "rm-dyn2",
            "fn runner_command(r: &Path) { Command::new(r); Command::new(r); }".to_string(),
        ),
        (
            "rm-dyn-out",
            "fn other(r: &Path) { Command::new(r); }".to_string(),
        ),
    ] {
        let r = synthetic(name, &[("src/runner.rs", &src)]);
        assert_eq!(r.violations.len(), 1, "{name}: {:?}", r.violations);
        assert!(r.violations[0].contains("правило (в)"), "{name}");
    }
}

/// Контроль «правило раннера діє поза модулем runner, зокрема в модулі git»: кожна форма — червоне.
#[test]
fn runner_launch_forms_are_caught_outside_the_module() {
    let cases: &[(&str, &str)] = &[
        (
            "літерал",
            r#"fn f() { Command::new("v8-runner.exe").status(); }"#,
        ),
        (
            "повний шлях без регістру",
            r#"fn f() { let p = r"C:\U\V8-Runner.EXE"; }"#,
        ),
        (
            "const",
            r#"const R: &str = "v8-runner"; fn f() { Command::new(R).status(); }"#,
        ),
        (
            "format",
            r#"fn f(d: &str) { let p = format!("{d}\\v8-runner.exe"); }"#,
        ),
        (
            "cmd /c",
            r#"fn f() { Command::new("cmd").args(["/c", "v8-runner --version"]).status(); }"#,
        ),
        (
            "& у pwsh",
            r#"fn f() { Command::new("pwsh").arg("-c").arg("cd x && v8-runner.exe y").status(); }"#,
        ),
        (
            "псевдонім",
            r#"use std::process::Command as P; fn f() { P::new("v8-runner").status(); }"#,
        ),
    ];
    for (rel, host) in [
        ("src/other.rs", "інший модуль"),
        ("src/git.rs", "модуль git"),
    ] {
        for (name, src) in cases {
            let r = synthetic("rf", &[(rel, src)]);
            assert!(
                r.violations
                    .iter()
                    .any(|v| v.contains("правило (д)") || v.contains("правило (е)")),
                "{host}: {name}: {:?}",
                r.violations
            );
        }
    }
    // У модулі git правила git лишаються дозволеними (двійник схеми): git там не порушення.
    let r = synthetic(
        "rf-git",
        &[("src/git.rs", r#"fn g() { Command::new("git"); }"#)],
    );
    assert!(r.violations.is_empty(), "{:?}", r.violations);
}

/// Нехибні: вердикти, сегмент каталогу Уніки, версія в тексті поза `.arg(`.
#[test]
fn runner_texts_are_not_hits() {
    let src = r#"
        fn f(v: &str, d: &Path) {
            let m = format!("Раннер v8-runner {v}.");
            let n = "Раннер v8-runner 0.18.x — kit перевірено";
            let p = d.join("v8-runner-windows-x86_64");
            eprintln!("v8-runner 0.18.1 готовий");
        }
    "#;
    assert_eq!(scan_source(src), (vec![], vec![]));
}

/// Контроль перевірки оточення: кожна форма читання — червоне; макрос `env!` — ні; дозвіл без читання —
/// застарілий.
#[test]
fn environment_reads_are_caught() {
    for (name, src) in [
        ("env::var", r#"fn f() { let _ = std::env::var("X"); }"#),
        ("var_os", r#"fn f() { let _ = std::env::var_os("X"); }"#),
        ("vars", r#"fn f() { for _ in std::env::vars() {} }"#),
        ("vars_os", r#"fn f() { for _ in std::env::vars_os() {} }"#),
        (
            "use var",
            r#"use std::env::var; fn f() { let _ = var("X"); }"#,
        ),
        (
            "use {var}",
            r#"use std::env::{var}; fn f() { let _ = var("X"); }"#,
        ),
        (
            "use env as",
            r#"use std::env as e; fn f() { let _ = e::var("X"); }"#,
        ),
    ] {
        assert!(!scan_env(src).is_empty(), "{name}: не спіймано");
    }
    assert!(scan_env(r#"fn f() { let _ = env!("CARGO_MANIFEST_DIR"); }"#).is_empty());

    let tmp = std::env::temp_dir().join(format!("kit-guard-env-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(tmp.join("src")).unwrap();
    std::fs::write(tmp.join("build.rs"), "fn main() {}").unwrap();
    // Контроль: env::var("X") у модулі runner — червоне; поза обсягом (other.rs) — ні; дозволене місце — ні.
    std::fs::write(
        tmp.join("src/runner.rs"),
        r#"fn f() { let _ = std::env::var("X"); }"#,
    )
    .unwrap();
    std::fs::write(
        tmp.join("src/other.rs"),
        r#"fn f() { let _ = std::env::var("X"); }"#,
    )
    .unwrap();
    std::fs::write(
        tmp.join("src/unica.rs"),
        r#"fn default_registry() { let _ = std::env::var_os("USERPROFILE"); }"#,
    )
    .unwrap();
    let v = env_violations(&tmp, ALLOWED_ENV);
    assert_eq!(v.len(), 1, "{v:?}");
    assert!(v[0].starts_with("src/runner.rs:1"));
    // Дозвіл без читання — застарілий.
    std::fs::write(tmp.join("src/unica.rs"), "fn default_registry() {}").unwrap();
    std::fs::write(tmp.join("src/runner.rs"), "fn f() {}").unwrap();
    let v = env_violations(&tmp, ALLOWED_ENV);
    let _ = std::fs::remove_dir_all(&tmp);
    assert_eq!(
        v,
        vec!["застарілий дозвіл оточення: src/unica.rs default_registry".to_string()]
    );
}
