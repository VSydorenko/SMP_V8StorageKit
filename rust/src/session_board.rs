// `kit session-board` (спека #51 D8; перенесено з tools/commands/session-board.psm1, який походив з
// agent-kit 0.9.1 bin/session-board + lib/session-board.mjs): статус паралельних сесій одним екраном.
// Джерела — git і gh, не список агентів.
//
// Вивід збігається з PowerShell-версією побайтно (еталон — task-5-golden плану): рядки таблиці
// з'єднані `\n`, кожен записаний рядок завершується `\r\n` (Console.WriteLine на Windows), помилки
// stderr — теж `\r\n`. Відомі відмінності: (1) detached worktree з `-All` дає рядок `(detached)`, а не
// падіння; (2) корінь файлу сесій, що не є JSON-об'єктом, — відмова із зрозумілим текстом (PowerShell
// пропускав його через `-is [pscustomobject]`, який істинний для будь-якого значення); (3) тексти системних
// винятків PowerShell (розбір JSON) замінено текстами serde_json.
//
// Режим робочої копії — з профілю (`workspace.mode`): `worktree` — рядки є worktree; `shared` — одна
// копія, рядки є гілки (з файлу сесій або всі локальні, крім базової і `storage/*`).

use crate::cli::{self, Kind, Value as Arg};
use crate::gh::{self, GhError};
use crate::git;
use crate::profile::{Profile, ps_string, strip_json_comments};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

const COMMAND: &str = "session-board";

const USAGE: &str = "session-board [-Sessions <file>] [-Fetch] [-All]

One-screen table of parallel sessions: session, role, branch, HEAD, age of the last commit,
uncommitted files, ahead/behind origin/<base>, PR, next step.

Profile workspace.mode (default \"shared\"):
  worktree  rows are the repo's worktrees (git worktree list), with the full path column;
            sessions of the file without a worktree are listed too
  shared    one working copy: rows are branches (from -Sessions, otherwise local branches except
            the base and storage/*); the tree column is filled only for the checked-out branch

  -Sessions <file>  JSON { \"<session>\": \"<branch>\" | { \"branch\", \"role\" } } kept by the architect
  -Fetch            git fetch origin first (otherwise ahead/behind uses the local origin/<base>)
  -All              worktree mode: also show detached worktrees (scratch copies)

Base branch: profile pr.base, default \"main\".
A merged PR counts for a branch only when the branch has no new work after it.
Exit: 0 table complete; 3 PR not checked (gh missing or failed) or bad profile field \u{2014} the table
is still printed without PRs.";

/// Результат команди: байти потоків (текст) і код виходу.
#[derive(Debug, Default)]
pub struct Outcome {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

struct Fail {
    code: i32,
    message: String,
}

fn fail(code: i32, message: impl Into<String>) -> Fail {
    Fail { code, message: message.into() }
}

fn write_line(buf: &mut String, text: &str) {
    buf.push_str(text);
    buf.push_str("\r\n");
}

pub fn run(args: &[String], cwd: &Path) -> Outcome {
    let mut out = Outcome::default();
    match execute(args, cwd, &mut out.stdout) {
        Ok(code) => out.code = code,
        Err(f) => {
            // `Write-KitError`: перший рядок — `<команда>: ERROR <причина>`; помилка виклику — вказівка на -Help.
            let mut lines = f.message.split('\n').map(|l| l.trim_end_matches('\r'));
            write_line(&mut out.stderr, &format!("{COMMAND}: ERROR {}", lines.next().unwrap_or("")));
            if f.code == 2 {
                write_line(&mut out.stderr, &format!("usage: {COMMAND} -Help"));
            } else {
                let hint = lines.collect::<Vec<_>>().join("\n");
                if !hint.trim().is_empty() {
                    write_line(&mut out.stderr, hint.trim_matches('\n'));
                }
            }
            out.code = f.code;
        }
    }
    out
}

// ---------- git ----------

/// stdout git у теці або None, коли git відмовив: `\r\n` → `\n`, краї обрізано.
fn sb_git(cwd: &Path, args: &[&str]) -> Option<String> {
    let out = git::run(cwd, args, None, true).ok()?;
    if out.code != 0 {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n").trim().to_string())
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Worktree {
    path: String,
    head: String,
    branch: Option<String>,
    detached: bool,
    prunable: bool,
}

/// `git worktree list --porcelain` → список worktree.
fn parse_worktrees(text: &str) -> Vec<Worktree> {
    let mut out: Vec<Worktree> = Vec::new();
    for line in text.split('\n').map(|l| l.trim_end_matches('\r')) {
        if let Some(p) = line.strip_prefix("worktree ") {
            out.push(Worktree { path: p.to_string(), ..Default::default() });
        } else if let Some(cur) = out.last_mut() {
            if let Some(h) = line.strip_prefix("HEAD ") {
                cur.head = h.to_string();
            } else if let Some(b) = line.strip_prefix("branch ") {
                let short = if b.len() >= 11 && b[..11].eq_ignore_ascii_case("refs/heads/") { &b[11..] } else { b };
                cur.branch = Some(short.to_string());
            } else if line == "detached" {
                cur.detached = true;
            } else if line.starts_with("prunable") {
                cur.prunable = true;
            }
        }
    }
    out
}

// ---------- чисті функції таблиці ----------

fn format_age(seconds: Option<i64>) -> String {
    let Some(s) = seconds else { return "?".to_string() };
    if s < 3600 {
        return format!("{}m", ((s as f64 / 60.0).round() as i64).max(0));
    }
    if s < 86400 {
        return format!("{}h", (s as f64 / 3600.0).round() as i64);
    }
    format!("{}d", (s as f64 / 86400.0).round() as i64)
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// Рядки → вирівняна таблиця; ширина колонки — за найдовшим значенням (у одиницях UTF-16, як `.Length`).
fn format_table(headers: &[String], rows: &[Vec<String>]) -> String {
    let widths: Vec<usize> = (0..headers.len())
        .map(|i| rows.iter().map(|r| utf16_len(&r[i])).chain([utf16_len(&headers[i])]).max().unwrap_or(0))
        .collect();
    let line = |cells: &[String]| {
        let padded: Vec<String> =
            cells.iter().enumerate().map(|(i, c)| format!("{c}{}", " ".repeat(widths[i].saturating_sub(utf16_len(c))))).collect();
        padded.join("  ").trim_end().to_string()
    };
    let mut lines = vec![line(headers)];
    lines.extend(rows.iter().map(|r| line(r)));
    lines.join("\n")
}

/// Істинність значення JSON так, як її бачить `if (...)` PowerShell.
fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(_) => true,
    }
}

fn number_text(v: &Value) -> String {
    match v {
        Value::Number(n) => match n.as_f64() {
            Some(f) if f.fract() == 0.0 && n.as_i64().is_none() && n.as_u64().is_none() => format!("{}", f as i64),
            _ => n.to_string(),
        },
        other => ps_string(other),
    }
}

// ---------- файл сесій ----------

struct Session {
    name: String,
    branch: String,
    role: String,
}

/// Ключі верхнього рівня JSON-об'єкта у порядку файлу (serde_json без `preserve_order` порядок губить).
fn top_level_keys(text: &str) -> Vec<String> {
    let c: Vec<char> = text.chars().collect();
    let (mut keys, mut depth, mut expect_key, mut i) = (Vec::new(), 0i32, false, 0usize);
    while i < c.len() {
        match c[i] {
            '{' | '[' => {
                depth += 1;
                expect_key = depth == 1 && c[i] == '{';
            }
            '}' | ']' => depth -= 1,
            ',' if depth == 1 => expect_key = true,
            '"' => {
                let start = i;
                i += 1;
                while i < c.len() && c[i] != '"' {
                    if c[i] == '\\' {
                        i += 1;
                    }
                    i += 1;
                }
                if depth == 1 && expect_key {
                    let lit: String = c[start..(i + 1).min(c.len())].iter().collect();
                    if let Ok(k) = serde_json::from_str::<String>(&lit) {
                        if !keys.contains(&k) {
                            keys.push(k);
                        }
                    }
                    expect_key = false;
                }
            }
            _ => {}
        }
        i += 1;
    }
    keys
}

fn read_sessions(file: &str) -> Result<Vec<Session>, Fail> {
    let path = Path::new(file);
    if !path.is_file() {
        return Err(fail(2, format!("файл сесій не знайдено: {file}")));
    }
    let bytes = std::fs::read(path).map_err(|e| fail(1, format!("файл сесій не прочитано: {e}")))?;
    let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    let text = strip_json_comments(&String::from_utf8_lossy(body));
    let shape = "sessions file must be a JSON object { \"<session>\": \"<branch>\" | { \"branch\", \"role\" } }";
    let root: Value =
        serde_json::from_str(&text).map_err(|e| fail(1, format!("файл сесій не розібрано як JSON: {e}")))?;
    let Value::Object(map) = &root else { return Err(fail(1, shape)) };
    let mut list = Vec::new();
    for name in top_level_keys(&text) {
        let Some(v) = map.get(&name) else { continue };
        let (mut branch, mut role) = (None, String::new());
        match v {
            Value::String(s) => branch = Some(s.clone()),
            Value::Object(o) => {
                if let Some(Value::String(b)) = o.get("branch") {
                    branch = Some(b.clone());
                }
                if let Some(r) = o.get("role").filter(|r| !r.is_null()) {
                    role = ps_string(r);
                }
            }
            _ => {}
        }
        let Some(branch) = branch else { return Err(fail(1, format!("session \"{name}\": branch missing"))) };
        list.push(Session { name, branch, role });
    }
    Ok(list)
}

// ---------- стан гілки / worktree ----------

#[derive(Default)]
struct State {
    age_sec: Option<i64>,
    ahead: Option<i64>,
    behind: Option<i64>,
}

fn now_unix() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// Вік і ahead/behind проти origin/<base> для ref у теці.
fn get_state(cwd: &Path, reference: &str, base: &str) -> State {
    let mut s = State::default();
    if let Some(ct) = sb_git(cwd, &["log", "-1", "--format=%ct", reference]).filter(|t| all_digits(t)) {
        s.age_sec = ct.parse::<i64>().ok().map(|c| now_unix() - c);
    }
    let range = format!("origin/{base}...{reference}");
    if let Some(counts) = sb_git(cwd, &["rev-list", "--left-right", "--count", &range]) {
        let parts: Vec<&str> = counts.split_whitespace().collect();
        if let [b, a] = parts[..] {
            if all_digits(b) && all_digits(a) {
                s.behind = b.parse().ok();
                s.ahead = a.parse().ok();
            }
        }
    }
    s
}

fn get_tree(cwd: &Path) -> String {
    match sb_git(cwd, &["status", "--porcelain"]) {
        None => "-".to_string(),
        Some(st) if st.is_empty() => "clean".to_string(),
        Some(st) => format!("{} changed", st.split('\n').count()),
    }
}

// ---------- PR ----------

struct Pr {
    number: Value,
    oid: String,
    draft: bool,
}

#[derive(Default)]
struct PrEntry {
    open: Option<Pr>,
    merged: Option<Pr>,
}

fn to_pr(v: &Value) -> Option<(String, Pr)> {
    let name = v.get("headRefName")?.as_str()?.to_string();
    Some((
        name,
        Pr {
            number: v.get("number").cloned().unwrap_or(Value::Null),
            oid: v.get("headRefOid").and_then(Value::as_str).unwrap_or("").to_string(),
            draft: v.get("isDraft").is_some_and(truthy),
        },
    ))
}

/// branch (без регістру) → PR; відкритий важливіший за старий злитий з тією ж назвою гілки.
fn get_pr_map(cwd: &Path) -> Result<HashMap<String, PrEntry>, GhError> {
    let open = gh::run_json(&["pr", "list", "--state", "open", "--limit", "100", "--json", "number,headRefName,headRefOid,isDraft"], cwd)?;
    let merged = gh::run_json(&["pr", "list", "--state", "merged", "--limit", "50", "--json", "number,headRefName,headRefOid"], cwd)?;
    let mut map: HashMap<String, PrEntry> = HashMap::new();
    for (name, pr) in merged.iter().filter_map(to_pr) {
        map.entry(name.to_lowercase()).or_insert(PrEntry { open: None, merged: Some(pr) });
    }
    for (name, pr) in open.iter().filter_map(to_pr) {
        map.insert(name.to_lowercase(), PrEntry { open: Some(pr), merged: None });
    }
    Ok(map)
}

// ---------- рядки ----------

#[derive(Default)]
struct Row {
    branch: Option<String>,
    path: Option<String>,
    head: String,
    detached: bool,
    prunable: bool,
    tree: String,
    state: State,
}

fn new_row(branch: Option<String>) -> Row {
    Row { branch, tree: "-".to_string(), ..Default::default() }
}

struct NextInput<'a> {
    merged: Option<&'a str>,
    pr: bool,
    unpushed: bool,
    behind: Option<i64>,
    path: Option<&'a str>,
    prunable: bool,
}

/// Перша підказка, яка вимагає дії архітектора; порожньо — нічого робити.
fn next_step(r: &NextInput, base: &str, worktree: bool) -> String {
    if let Some(m) = r.merged {
        return match (worktree, r.path) {
            (true, Some(p)) if !p.is_empty() => format!("merged #{m}: pr-gate cleanup {p}"),
            _ => format!("merged #{m}"),
        };
    }
    if worktree {
        if r.path.is_none_or(str::is_empty) {
            return "no worktree".to_string();
        }
        if r.prunable {
            return "prunable: git worktree prune".to_string();
        }
    }
    if r.pr {
        if r.unpushed {
            return "local HEAD not pushed".to_string();
        }
        if let Some(b) = r.behind.filter(|b| *b > 0) {
            return format!("behind {base} {b}: merge origin/{base}");
        }
    }
    String::new()
}

fn same(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

fn execute(args: &[String], cwd: &Path, stdout: &mut String) -> Result<i32, Fail> {
    let spec = [("Sessions", Kind::Str), ("Fetch", Kind::Switch), ("All", Kind::Switch)];
    let a = cli::parse(args, &spec).map_err(|e| fail(2, e.0))?;
    if a.help {
        write_line(stdout, &USAGE.replace('\n', "\r\n"));
        return Ok(0);
    }
    if let Some(p) = a.positional.first() {
        return Err(fail(2, format!("зайвий позиційний аргумент '{p}'")));
    }

    let profile = Profile::load(cwd).map_err(|e| fail(e.code, e.message))?;
    let base = profile.value("pr.base").map_or_else(|| "main".to_string(), ps_string);
    let mode = profile.value("workspace.mode").map_or_else(|| "shared".to_string(), ps_string).to_lowercase();
    if mode != "shared" && mode != "worktree" {
        return Err(fail(3, format!("поле профілю \"workspace.mode\": \"{mode}\" — допустимо shared або worktree")));
    }
    let worktree_mode = mode == "worktree";

    if sb_git(cwd, &["rev-parse", "--git-dir"]).is_none() {
        return Err(fail(1, format!("{} не є git-репозиторієм", cwd.display())));
    }
    let sessions = match a.named.get("Sessions") {
        Some(Arg::Str(f)) => read_sessions(f)?,
        _ => Vec::new(),
    };
    let mut session_of: HashMap<String, usize> = HashMap::new();
    for (i, s) in sessions.iter().enumerate() {
        session_of.insert(s.branch.to_lowercase(), i);
    }
    // Наявність параметра, а не його значення: `-Fetch:false` у PowerShell-версії теж діяв.
    if a.named.contains_key("Fetch") {
        let _ = sb_git(cwd, &["fetch", "-q", "origin"]);
    }
    let show_all = a.named.contains_key("All");

    let mut rows: Vec<Row> = Vec::new();
    if worktree_mode {
        let text = sb_git(cwd, &["worktree", "list", "--porcelain"]).unwrap_or_default();
        for w in parse_worktrees(&text) {
            if !show_all && w.branch.is_none() {
                continue;
            }
            let mut r = new_row(w.branch.clone());
            r.path = Some(w.path.clone());
            r.head = w.head.clone();
            r.detached = w.detached;
            r.prunable = w.prunable;
            if !w.prunable {
                let wp = Path::new(&w.path);
                r.tree = get_tree(wp);
                r.state = get_state(wp, "HEAD", &base);
            }
            rows.push(r);
        }
        // Сесії з файлу, для яких worktree вже немає: показати, чим закінчились.
        for s in &sessions {
            if !rows.iter().any(|r| r.branch.as_deref().is_some_and(|b| same(b, &s.branch))) {
                rows.push(new_row(Some(s.branch.clone())));
            }
        }
    } else {
        let branches: Vec<String> = if sessions.is_empty() {
            let all = sb_git(cwd, &["for-each-ref", "--format=%(refname:short)", "refs/heads"]).unwrap_or_default();
            all.split('\n')
                .map(|l| l.trim_end_matches('\r'))
                .filter(|b| !b.is_empty() && !same(b, &base) && !b.starts_with("storage/"))
                .map(str::to_string)
                .collect()
        } else {
            sessions.iter().map(|s| s.branch.clone()).collect()
        };
        let current = sb_git(cwd, &["symbolic-ref", "--short", "-q", "HEAD"]);
        for b in branches {
            let mut r = new_row(Some(b.clone()));
            let head = sb_git(cwd, &["rev-parse", "--verify", "-q", &format!("refs/heads/{b}")]).unwrap_or_default();
            if !head.is_empty() {
                r.head = head;
                r.state = get_state(cwd, &format!("refs/heads/{b}"), &base);
                if current.as_deref().is_some_and(|c| same(c, &b)) {
                    r.tree = get_tree(cwd);
                }
            }
            rows.push(r);
        }
    }

    // --- PR ---
    let (prs, gh_problem) = match get_pr_map(cwd) {
        Ok(m) => (Some(m), None),
        Err(GhError::Unavailable(m)) => (None, Some(m)),
        Err(GhError::Failed(m)) => (None, Some(format!("gh failed: {m}"))),
        Err(GhError::BadJson(m)) => return Err(fail(1, m)),
    };

    let mut headers: Vec<String> =
        ["session", "role", "branch", "HEAD", "age", "tree"].iter().map(|s| s.to_string()).collect();
    headers.push(format!("vs {base}"));
    headers.extend(["PR".to_string(), "next".to_string()]);
    if worktree_mode {
        headers.push("path".to_string());
    }

    let mut table: Vec<Vec<String>> = Vec::new();
    for r in &rows {
        let session = r.branch.as_deref().and_then(|b| session_of.get(&b.to_lowercase())).map(|i| &sessions[*i]);
        let entry = match (&prs, r.branch.as_deref().filter(|b| !b.is_empty())) {
            (Some(m), Some(b)) => m.get(&b.to_lowercase()),
            _ => None,
        };
        let mut pr_num: Option<String> = None;
        let mut merged_num: Option<String> = None;
        let mut unpushed = false;
        let mut draft = false;
        if let Some(p) = entry.and_then(|e| e.open.as_ref()) {
            if truthy(&p.number) {
                pr_num = Some(number_text(&p.number));
            }
            draft = p.draft;
            unpushed = !r.head.is_empty() && !r.head.eq_ignore_ascii_case(&p.oid);
        } else if let Some(p) = entry.and_then(|e| e.merged.as_ref()) {
            let is_base = r.branch.as_deref().is_some_and(|b| same(b, &base));
            if !is_base && (r.head.is_empty() || r.head.eq_ignore_ascii_case(&p.oid) || r.state.ahead == Some(0)) && truthy(&p.number) {
                merged_num = Some(number_text(&p.number));
            }
        }
        // Злитий PR зараховується, лише коли в гілці немає нової роботи після нього.
        let pr_cell = if let Some(n) = &pr_num {
            format!("#{n}{}", if draft { " draft" } else { "" })
        } else if let Some(n) = &merged_num {
            format!("#{n} merged")
        } else if prs.is_some() {
            "\u{2014}".to_string()
        } else {
            "?".to_string()
        };
        let next = next_step(
            &NextInput {
                merged: merged_num.as_deref(),
                pr: pr_num.is_some(),
                unpushed,
                behind: r.state.behind,
                path: r.path.as_deref(),
                prunable: r.prunable,
            },
            &base,
            worktree_mode,
        );
        let mut cells = vec![
            session.map_or("-".to_string(), |s| s.name.clone()),
            session.map_or(String::new(), |s| s.role.clone()),
            if r.detached { "(detached)".to_string() } else { r.branch.clone().unwrap_or_default() },
            if r.head.is_empty() { "-".to_string() } else { r.head.chars().take(7).collect() },
            if !r.head.is_empty() && (!worktree_mode || r.path.as_deref().is_some_and(|p| !p.is_empty())) {
                format_age(r.state.age_sec)
            } else {
                "-".to_string()
            },
            r.tree.clone(),
            match r.state.ahead {
                None => "-".to_string(),
                Some(ah) => format!("+{ah} -{}", r.state.behind.unwrap_or(0)),
            },
            pr_cell,
            next,
        ];
        if worktree_mode {
            cells.push(r.path.clone().unwrap_or_default());
        }
        table.push(cells);
    }

    // Без файлу сесій колонки session/role порожні — не займати ними екран.
    let keep: Vec<usize> = if sessions.is_empty() { (2..headers.len()).collect() } else { (0..headers.len()).collect() };
    let hdr: Vec<String> = keep.iter().map(|&i| headers[i].clone()).collect();
    let body: Vec<Vec<String>> = table.iter().map(|c| keep.iter().map(|&i| c[i].clone()).collect()).collect();
    write_line(stdout, &format_table(&hdr, &body));
    if let Some(problem) = gh_problem {
        write_line(stdout, &format!("PR not checked: {problem}"));
        return Ok(3);
    }
    write_line(stdout, "next: session-board -Fetch");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn age_rounds_away_from_zero_and_clamps() {
        assert_eq!(format_age(None), "?");
        assert_eq!(format_age(Some(-500)), "0m");
        assert_eq!(format_age(Some(90)), "2m");
        assert_eq!(format_age(Some(3600 * 5 / 2)), "3h");
        assert_eq!(format_age(Some(86400 * 3 / 2)), "2d");
    }

    #[test]
    fn table_pads_by_utf16_and_trims_the_tail() {
        let t = format_table(&["a".into(), "bb".into()], &[vec!["\u{1F600}x".into(), "".into()]]);
        assert_eq!(t, "a    bb\n\u{1F600}x");
    }

    #[test]
    fn detached_worktree_parses_without_branch() {
        let w = parse_worktrees("worktree C:/r\nHEAD abc\nbranch refs/heads/main\n\nworktree C:/d\nHEAD def\ndetached\nprunable gone");
        assert_eq!(w[0].branch.as_deref(), Some("main"));
        assert!(w[1].branch.is_none() && w[1].detached && w[1].prunable);
    }

    #[test]
    fn session_keys_keep_file_order() {
        assert_eq!(top_level_keys(r#"{ "b": {"x": 1}, "a": "q,\"z\"", "c": [1, {"d": 2}] }"#), vec!["b", "a", "c"]);
    }
}
