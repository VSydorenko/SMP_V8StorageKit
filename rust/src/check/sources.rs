// Перевірки одного джерела (`<воркспейс>/<ключ>`) у порядку PowerShell: `gitattributes`, `case-collision`,
// `gitignore` (дерево), далі поставка вендора (`gitignore`, `supply`), `gitignore` vendor (правила й факт),
// `storage-path`, `storage-branch`, `dump-from`, `config-name`.

use super::Collector;
use super::gitq::{has_head, ignored, query, slashed, text_unset};
use crate::case_guard::case_collisions;
use crate::config::yaml::eq_ci;
use crate::config::{Context, Level, Source, Truth, is_server_storage_path, mask_storage_path};
use crate::storage_branch::{self, branch_exists};
use crate::supply::{self, Purpose, RecipeState, State};
use std::fs;
use std::io;
use std::path::Path;

use super::PROBE_CEILING as STORAGE_PROBE_CEILING;

pub(super) fn dir_exists(path: &str) -> bool {
    fs::metadata(path).is_ok()
}

/// Стартує проби каталогів сховищ усіх джерел `truth: storage` заздалегідь (паралельно): кожна зі стелею 5 с від
/// свого старту; `storage_path` потім збирає результати в порядку джерел.
pub(super) fn prefetch_storage_probes(c: &mut Collector, ctx: &Context, opts: &super::Options) {
    if ctx.manifest.is_none() {
        return;
    }
    for src in super::selected_sources(ctx, opts) {
        if src.truth != Truth::Storage {
            continue;
        }
        let path = src.storage_path.clone().unwrap_or_default();
        if !is_server_storage_path(&path) {
            let probe = c.probes_seam.dir_exists;
            c.probes.start(&path, STORAGE_PROBE_CEILING, probe);
        }
    }
}

pub(super) fn check_source(c: &mut Collector, ctx: &Context, src: &Source) {
    let root = Path::new(&ctx.repo_root);
    let tag = format!("{}/{}", src.workspace, src.key);

    // Усі дерева платформи, що потрапляють у git, — під -text. truth: vendor гітігноровано за визначенням,
    // тож для нього інваріант інший (нижче).
    if src.truth != Truth::Vendor {
        gitattributes(c, root, &tag, src);
        case_collision(c, root, &tag, src);
        tree_not_ignored(c, root, &tag, src);
    }

    // Поставка вендора основної конфігурації. Для vendor дерево ігнороване цілком (інваріант інший, нижче); для
    // розширень і конфігурацій без підтримки `.bin` поставки не описує, і перевірки мовчать.
    if src.type_name.eq_ignore_ascii_case("CONFIGURATION") && src.truth != Truth::Vendor {
        supply_checks(c, ctx, &tag, src);
    }

    if src.truth == Truth::Vendor {
        vendor_tree(c, root, &tag, src);
    }
    if src.truth == Truth::Storage {
        storage_path(c, ctx, &tag, src);
        storage_branch_audit(c, root, &tag, src);
    }

    if matches!(src.truth, Truth::Dump | Truth::Vendor) {
        dump_from(c, ctx, &tag, src);
    }
    // Ім'я розширення однакове в трьох місцях. vendor не наш, його не звіряємо.
    if src.type_name.eq_ignore_ascii_case("EXTENSION") && src.truth != Truth::Vendor {
        config_name(c, &tag, src);
    }
}

/// `gitattributes` (рішення 14): питаємо САМ git про один файл `<шлях>/Configuration.xml` — правила `-text`
/// прив'язані до шляху, а `git status` при хибній політиці чистий завжди.
fn gitattributes(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", slashed(&src.repo_path));
    match text_unset(root, &probe) {
        Ok(true) => {}
        Ok(false) => c.add(
            Level::Error,
            "gitattributes",
            format!(
                "{tag}: дерево '{p}' не виведено з-під конверсії кінців рядків — додайте в .gitattributes рядок '{p}/** -text' (docs/text-policy.md).",
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked(
            "gitattributes",
            &format!("{tag}: політика кінців рядків дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// `case-collision` (рішення 13): групи регістру в HEAD під шляхом джерела. Немає `HEAD` — не застосовується.
fn case_collision(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let what = format!("{tag}: регістр шляхів у HEAD");
    let paths = match has_head(root) {
        Ok(false) => return,
        Ok(true) => c.head_under(root, &slashed(&src.repo_path)),
        Err(reason) => Err(reason),
    };
    let paths = match paths {
        Ok(p) => p,
        Err(reason) => return c.unchecked("case-collision", &what, &reason),
    };
    let groups = case_collisions(&paths);
    if groups.is_empty() {
        return;
    }
    let shown: Vec<String> = groups.iter().take(5).map(|g| g.join(" | ")).collect();
    let more = if groups.len() > 5 {
        format!("; …і ще {}", groups.len().saturating_sub(5))
    } else {
        String::new()
    };
    c.add(
        Level::Error,
        "case-collision",
        format!(
            "{tag}: у HEAD {} груп(и) шляхів, що різняться лише регістром: {}{more}. Зніміть фантом з індексу (git rm --cached -- <шлях>) і закомітьте без --only; розбір — docs/storage-and-git.md, «Перейменування регістром».",
            groups.len(),
            shown.join("; ")
        ),
    );
}

/// Дерево, яке МАЄ бути в git, не повинно ловитись правилом `.gitignore`: помилково широке правило викидає
/// вихідники з git мовчки. `--no-index` обов'язковий — інакше відстежений `Configuration.xml` ніколи не
/// показався б ігнорованим.
fn tree_not_ignored(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", src.repo_path);
    match ignored(root, &probe) {
        Ok(false) => {}
        Ok(true) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: дерево '{}' гітігноровано, хоч має потрапляти в git (truth: {}) — перевірте правила .gitignore.",
                src.repo_path,
                src.truth.as_str()
            ),
        ),
        Err(reason) => c.unchecked(
            "gitignore",
            &format!("{tag}: гітігнорування дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// vendor — два РІЗНІ питання: ПРАВИЛА (дерево ігнорується) і ФАКТ (дерево не в індексі). Страж (рішення 2):
/// збій git — error «не перевірено».
fn vendor_tree(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let probe = format!("{}/Configuration.xml", src.repo_path);
    let rules = ignored(root, &probe).and_then(|ok| {
        // Файл дерева в іншому регістрі може лишитися поза правилом.
        if ok && !c.unignored(root, &src.repo_path)?.is_empty() {
            return Ok(false);
        }
        Ok(ok)
    });
    match rules {
        Ok(true) => {}
        Ok(false) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: '{p}' не гітігноровано (truth: vendor) — чужа конфігурація потрапила б у git. Додайте в .gitignore рядок '{p}/**' (перевірка: git check-ignore).",
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked_error(
            "gitignore",
            &format!("{tag}: гітігнорування дерева '{}'", src.repo_path),
            &reason,
        ),
    }
    // Правило може бути на місці, а файли вже закомічені (`git add -f`): check-ignore --no-index індекс
    // свідомо ігнорує, тож питаємо індекс напряму.
    match c.tracked(root, &src.repo_path) {
        Ok(files) if files.is_empty() => {}
        Ok(files) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: дерево '{p}' (truth: vendor) відстежується git — у ньому {} файл(ів), хоч чужа конфігурація не має потрапляти в репозиторій. Приберіть з індексу: git rm -r --cached -- '{p}'.",
                files.len(),
                p = src.repo_path
            ),
        ),
        Err(reason) => c.unchecked_error(
            "gitignore",
            &format!("{tag}: відстеження дерева '{}'", src.repo_path),
            &reason,
        ),
    }
}

/// `dump-from`: джерело `dump`/`vendor` береться з дев-бази накладки. Накладки немає — warn; накладка є, але не
/// розібрана (рішення 7), — мовчимо: помилка `overlay` уже error, а казати «накладки немає» було б неправдою.
fn dump_from(c: &mut Collector, ctx: &Context, tag: &str, src: &Source) {
    let from = src.dump_from.as_deref().unwrap_or_default();
    match (&ctx.overlay, &ctx.overlay_path) {
        (Some(overlay), path) => {
            if overlay.infobase(from).is_none() {
                c.add(
                    Level::Warn,
                    "dump-from",
                    format!(
                        "{tag}: дев-бази '{from}' немає в infobases: накладки {}.",
                        path.as_deref().unwrap_or_default()
                    ),
                );
            }
        }
        (None, None) => c.add(
            Level::Warn,
            "dump-from",
            format!(
                "{tag}: dump.from '{from}', але накладки v8storagekit.local.yaml на цій машині немає — dump тут не запрацює, поки її не створити (зразок: templates/v8storagekit.local.yaml.example)."
            ),
        ),
        (None, Some(_)) => {}
    }
}

/// Поставка вендора (рішення 8): `.bin` у git, тека поставки й позначка поза git, стан поставки на цій машині.
/// Проба ігнору теки — питанням про вигаданий файл у ній, НЕ про теку з кінцевою скісною рискою: у `.gitignore` з
/// CRLF порожній рядок змушує `check-ignore` відповідати 0 на будь-який шлях із кінцевою рискою.
fn supply_checks(c: &mut Collector, ctx: &Context, tag: &str, src: &Source) {
    let root = Path::new(&ctx.repo_root);
    let tree = Path::new(&src.full_path);
    let supply_rel = format!("{}/{}", src.repo_path, supply::RELATIVE_PATH);
    let bin_rel = format!("{}/{}", src.repo_path, supply::BIN_RELATIVE_PATH);

    // `.bin` мусить лежати в git.
    match fs::metadata(root.join(&bin_rel)) {
        Ok(m) if m.is_file() => match ignored(root, &bin_rel) {
            Ok(true) => c.add(
                Level::Error,
                "gitignore",
                format!(
                    "{tag}: ознаки підтримки (замки об'єктів) '{bin_rel}' гітігноровано — вони мусять лежати в git. Приберіть правило, яке його ловить (перевірка: git check-ignore -v)."
                ),
            ),
            Ok(false) => {}
            Err(reason) => c.unchecked(
                "gitignore",
                &format!("{tag}: гітігнорування '{bin_rel}'"),
                &reason,
            ),
        },
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => c.unchecked(
            "gitignore",
            &format!("{tag}: ознаки підтримки '{bin_rel}'"),
            &e.to_string(),
        ),
    }

    // `.bin` не прочитано — один рядок «не перевірено» на збій читання (рішення 8): стан поставки нижче його не
    // повторює.
    let mut bin_unreadable = false;
    match supply::is_described(tree) {
        Ok(true) => {
            // Дві проби: `.cf` і позначка `.kit-bin-sha1` (стан машини, теж не для git) — правило лише на `*.cf` чи з
            // винятком для позначки ловило б одну з двох. Перша ж невдала зупиняє перебір.
            for probe in ["probe.cf", supply::MARKER_NAME] {
                match ignored(root, &format!("{supply_rel}/{probe}")) {
                    Ok(true) => continue,
                    Ok(false) => c.add(
                        Level::Error,
                        "gitignore",
                        format!(
                            "{tag}: тека поставки вендора '{supply_rel}/' не гітігнорована — .cf на сотні МБ потрапив би в git (ліміт GitHub 100 МБ на файл). Додайте в .gitignore рядок '**/Ext/ParentConfigurations/'."
                        ),
                    ),
                    Err(reason) => c.unchecked(
                        "gitignore",
                        &format!("{tag}: гітігнорування теки поставки '{supply_rel}/'"),
                        &reason,
                    ),
                }
                break;
            }
        }
        Ok(false) => {}
        Err(e) => {
            bin_unreadable = true;
            c.unchecked(
                "supply",
                &format!("{tag}: ознаки підтримки '{bin_rel}'"),
                &e.to_string(),
            );
        }
    }

    match c.tracked(root, &supply_rel) {
        Ok(files) if files.is_empty() => {}
        Ok(files) => c.add(
            Level::Error,
            "gitignore",
            format!(
                "{tag}: поставка вендора відстежується git ({} файл(ів) у '{supply_rel}') — приберіть з індексу й закомітьте окремим комітом (файли на диску лишаться): git rm -r --cached -- '{supply_rel}', потім git commit.",
                files.len()
            ),
        ),
        Err(reason) => c.unchecked(
            "gitignore",
            &format!("{tag}: відстеження поставки вендора '{supply_rel}'"),
            &reason,
        ),
    }

    if src.truth != Truth::Storage || bin_unreadable {
        return;
    }
    let (state, detail) = match supply::state(tree) {
        State::Missing => (RecipeState::Missing, None),
        State::Stale => (RecipeState::Stale, None),
        State::Unknown(detail) => (RecipeState::Unknown, Some(detail)),
        State::None | State::Current => return,
    };
    // Варіант рецепту — за поточною гілкою.
    let recipe = supply::recipe(
        &src.key,
        &src.workspace,
        &ctx.main_branch,
        state,
        Purpose::Check,
        on_main_branch(root, &ctx.main_branch),
    );
    match detail {
        None => c.add(Level::Warn, "supply", format!("{tag}: {recipe}")),
        Some(detail) => c.unchecked(
            "supply",
            &format!("{tag}: поставка вендора"),
            &format!("{detail}; {recipe}"),
        ),
    }
}

/// Чи поточна гілка — головна (чутливо до регістру: гілки git його розрізняють). Від'єднаний HEAD і збій git —
/// `false`: консервативний варіант «спершу поставка на головній гілці».
fn on_main_branch(root: &Path, main_branch: &str) -> bool {
    query(root, &["branch", "--show-current"], &[0]).is_ok_and(|o| {
        let current = String::from_utf8_lossy(&o.stdout);
        let current = current.trim();
        !current.is_empty() && current == main_branch
    })
}

/// `storage-path`: каталог сховища (файловий) існує на цій машині. Серверна адреса файлово не пробується (рішення
/// 4). Будь-який текст зі шляхом — без userinfo.
fn storage_path(c: &mut Collector, ctx: &Context, tag: &str, src: &Source) {
    let effective = src.storage_path.clone().unwrap_or_default();
    if is_server_storage_path(&effective) {
        return c.add(
            Level::Info,
            "storage-path",
            format!(
                "{tag}: серверне сховище — доступність check не перевіряє: '{}'.",
                mask_storage_path(&effective)
            ),
        );
    }
    let probe = c.probes_seam.dir_exists;
    let exists = c.probes.wait(&effective, STORAGE_PROBE_CEILING, probe);
    match exists {
        Some(true) => {}
        None => c.unchecked(
            "storage-path",
            &format!("{tag}: каталог сховища '{}'", mask_storage_path(&effective)),
            &format!(
                "каталог сховища не відповів за {} с",
                STORAGE_PROBE_CEILING.as_secs()
            ),
        ),
        // warn: check не відрізнить «немає доступу до диска» (законно) від описки в маніфесті — тож текст показує
        // обидві розвилки, а не одну.
        Some(false) => {
            let manifest_path = ctx
                .manifest
                .as_ref()
                .and_then(|m| m.workspaces.iter().find(|w| eq_ci(&w.path, &src.workspace)))
                .and_then(|w| w.sources.iter().find(|s| s.key == src.key))
                .and_then(|s| s.storage_path.clone())
                .unwrap_or_else(|| effective.clone());
            let note = if !eq_ci(&manifest_path, &effective) {
                format!(
                    "перевизначено в v8storagekit.local.yaml на '{}'; у самому v8storagekit.yaml записано: '{}'",
                    mask_storage_path(&effective),
                    mask_storage_path(&manifest_path)
                )
            } else {
                format!(
                    "'{}', як записано в v8storagekit.yaml",
                    mask_storage_path(&manifest_path)
                )
            };
            c.add(
                Level::Warn,
                "storage-path",
                format!(
                    "{tag}: каталог сховища недоступний на цій машині: {note}. Якщо шлях правильний, а диска зараз немає — перевизначте його в накладці storages: {}: {{ path: … }}; якщо диск є, а шлях помилковий — виправте v8storagekit.yaml.",
                    src.key
                ),
            );
        }
    }
}

/// `storage-branch`: гілка дзеркала є — аудит інваріантів; немає — info. Збій git — «не перевірено» (рішення 5).
fn storage_branch_audit(c: &mut Collector, root: &Path, tag: &str, src: &Source) {
    let Some(branch) = src.branch.as_deref() else {
        return;
    };
    match branch_exists(root, branch) {
        Ok(false) => c.add(
            Level::Info,
            "storage-branch",
            format!("{tag}: гілки {branch} ще немає — її створить перший sync."),
        ),
        Err(reason) => c.unchecked(
            "storage-branch",
            &format!("{tag}: наявність гілки {branch}"),
            &reason,
        ),
        Ok(true) => {
            let audit = storage_branch::invariants(root, branch, &src.key, &src.repo_path);
            for message in audit.errors {
                c.add(Level::Error, "storage-branch", message);
            }
            if let Some(reason) = audit.failure {
                c.unchecked(
                    "storage-branch",
                    &format!("{tag}: інваріанти гілки {branch}"),
                    &reason,
                );
            }
        }
    }
}

/// `<Name>` кореневого об'єкта з `Configuration.xml` — перше входження, як у Designer XML (без XML-парсера,
/// рішення 10): `<Name>` без регістру, далі одна чи більше літер без `<` і `</Name>`.
pub(super) fn configuration_name(text: &str) -> Option<String> {
    const OPEN: &str = "<name>";
    let lower = text.to_ascii_lowercase();
    let mut from = 0usize;
    while let Some(found) = lower.get(from..).and_then(|t| t.find(OPEN)) {
        let start = from.saturating_add(found).saturating_add(OPEN.len());
        let rest = text.get(start..)?;
        let end = rest.find('<')?;
        if end > 0
            && lower
                .get(start.saturating_add(end)..)?
                .starts_with("</name>")
        {
            return rest.get(..end).map(|n| n.trim().to_string());
        }
        from = start;
    }
    None
}

/// `config-name`: ім'я розширення в `<Name>` дорівнює ключу джерела (без регістру: імена 1С регістронезалежні).
fn config_name(c: &mut Collector, tag: &str, src: &Source) {
    let cfg = Path::new(&src.full_path).join("Configuration.xml");
    let shown = format!("{}/Configuration.xml", src.repo_path);
    match fs::metadata(&cfg) {
        Ok(m) if m.is_file() => {}
        Ok(_) => return,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return c.add(
                Level::Info,
                "config-name",
                format!("{tag}: {shown} ще немає — дерево порожнє до першого sync."),
            );
        }
        Err(e) => {
            return c.unchecked("config-name", &format!("{tag}: {shown}"), &e.to_string());
        }
    }
    let bytes = match fs::read(&cfg) {
        Ok(b) => b,
        Err(e) => return c.unchecked("config-name", &format!("{tag}: {shown}"), &e.to_string()),
    };
    let text = String::from_utf8_lossy(bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes));
    match configuration_name(&text).filter(|n| !n.is_empty()) {
        None => c.add(
            Level::Warn,
            "config-name",
            format!("{tag}: у {shown} не знайдено <Name>."),
        ),
        Some(name) if !eq_ci(&name, &src.key) => c.add(
            Level::Error,
            "config-name",
            format!(
                "{tag}: <Name>{name}</Name> у {shown} не збігається з ключем джерела '{}' — ім'я розширення має бути однаковим у name: source-set, <Name> і ключі маніфесту.",
                src.key
            ),
        ),
        Some(_) => {}
    }
}

#[cfg(test)]
mod tests {
    use super::configuration_name;
    use crate::check::DirProbes;
    use std::time::{Duration, Instant};

    // Стеля проби каталогу сховища (рішення 4): повільна проба не повісить `check`; швидка відповідає як є.
    #[test]
    fn probe_ceiling_cuts_a_hanging_probe_and_passes_a_fast_one() {
        let mut probes = DirProbes::default();
        let started = Instant::now();
        let slow = probes.wait("s", Duration::from_millis(100), |_| {
            std::thread::sleep(Duration::from_secs(3));
            true
        });
        assert_eq!(slow, None);
        assert!(started.elapsed() < Duration::from_secs(2));
        let fast = probes.wait("x", Duration::from_secs(5), |p| p == "x");
        assert_eq!(fast, Some(true));
    }

    // Рішення архітектора (п. 7): проби стартують разом, результат — той самий, що послідовно, і в порядку запитів.
    #[test]
    fn parallel_probes_with_different_delays_give_the_sequential_answers_in_request_order() {
        let delays = [("a", 300u64, true), ("b", 50, false), ("c", 200, true)];
        let probe = |name: &'static str, ms: u64, ans: bool| {
            move |_: &str| {
                std::thread::sleep(Duration::from_millis(ms));
                let _ = name;
                ans
            }
        };
        // Послідовно: кожна проба стартує, коли до неї дійшла черга.
        let mut seq = DirProbes::default();
        let t = Instant::now();
        let sequential: Vec<_> = delays
            .iter()
            .map(|(n, ms, ans)| seq.wait(n, Duration::from_secs(5), probe(n, *ms, *ans)))
            .collect();
        let sequential_time = t.elapsed();
        // Паралельно: усі стартують заздалегідь, збір — у тому самому порядку.
        let mut par = DirProbes::default();
        let t = Instant::now();
        for (n, ms, ans) in delays {
            par.start(n, Duration::from_secs(5), probe(n, ms, ans));
        }
        let parallel: Vec<_> = delays
            .iter()
            .map(|(n, ms, ans)| par.wait(n, Duration::from_secs(5), probe(n, *ms, *ans)))
            .collect();
        let parallel_time = t.elapsed();
        assert_eq!(parallel, sequential);
        assert_eq!(parallel, vec![Some(true), Some(false), Some(true)]);
        assert!(
            sequential_time >= Duration::from_millis(550),
            "{sequential_time:?}"
        );
        assert!(
            parallel_time < Duration::from_millis(500),
            "{parallel_time:?}"
        );
    }

    #[test]
    fn configuration_name_is_the_first_well_formed_occurrence() {
        assert_eq!(
            configuration_name("<a><NAME> Ext </NAME><Name>Other</Name></a>").as_deref(),
            Some("Ext")
        );
        // Перше входження з вкладеним тегом не збігається з шаблоном — береться наступне.
        assert_eq!(
            configuration_name("<Name><x/></Name><Name>Real</Name>").as_deref(),
            Some("Real")
        );
        assert_eq!(configuration_name("<Name></Name><x/>"), None);
        assert_eq!(configuration_name("<Name>без закриття"), None);
    }
}
