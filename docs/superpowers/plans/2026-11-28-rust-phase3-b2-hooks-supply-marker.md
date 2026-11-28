# План B2 «`install-hooks`, `supply-marker`» — фаза 3 переходу на Rust (#54)

Статус: на прийняття архітектором (`smp-v8storagekit-cd`). Issue блоку: #158.
Спека: `docs/superpowers/specs/2026-11-28-rust-phase3-storage-design.md` §3 (рядок B2), §5.0, §5.2, §6; ADR-0014 п. 7,
ADR-0021 п. 1, ADR-0023.
Якорі після: злиття B1 (#157; план B1 — PR #174, після злиття — у теці планів).
Робоча копія: `workspace.mode = worktree`, `.worktrees/54-rust-phase3`, гілка коду від #158 після злиття B1. Спільного
рантайму немає. Спільні ресурси: замок `-Full` (правило 2 спільних правил ночі); `bin/kit.exe` — лише з CI. Код —
після сигналу архітектора.

## Мета

`kit install-hooks` і `kit supply-marker` виконує `kit.exe` без PowerShell. Модулі `install-hooks.psm1`,
`supply-marker.psm1`, `Hooks.psm1` і функція `Write-KitSupplyMarker` прибрані. Блок — перший, що переносить
команди на основі B1, тож він перевіряє на малому обсязі весь шлях переносу: еталон PowerShell, маршрут фікстури,
таблиці покриття, бінарник CI.

## Архітектура

Дві команди в `main.rs` з власними специфікаціями `cli::parse`; код команд — новий модуль на команду
(`install_hooks`, `supply_marker`; імена — на розсуд виконавця). `install-hooks` бере шаблони з
`hooks::plugin_templates_dir` (та сама тека, з якою звіряє `check`) і залишковий аудит — наявні `hooks::audit` і
`hooks::legacy_session_hook`. `supply-marker` бере джерело з `config::select_sources`, стан поставки — з
`supply::state`, SHA-1 — з `supply::bin_sha1`, брудні записи — з `worktree_state` (B1). Звіт команди й хвіст виводу
— помічник контракту B1.

## Глобальні обмеження

- Поведінка й тексти — побайтно як PowerShell на цільовому коміті (задача 0), крім відомих відмінностей рішення 3.
- PowerShell-копії, які ще кличуть інші команди (`Get-KitSupplyState`, `Test-KitSupplyDescribed`,
  `Get-KitSupplyRelativePath`, `Get-KitDirtyRecords`, `Select-KitSources`), не чіпаються; прибирається лише функція
  з останнім споживачем у цьому блоці (`grep -rlw` по `tools/commands tools/lib tools/kit.ps1 tools/*.ps1`).
- Pester-перевірки з `kit.exe` — доказ лише на бінарнику CI (як у B1, «Бінарник»).

## Рішення

| # | Рішення | Вплив на спеку |
| --- | --- | --- |
| 1 | Еталон PowerShell — закомічена фікстура `tools/tests/fixtures/phase3-reference/<команда>/`: вхід сценарію, stdout, stderr, код, стан після (файли, `git config core.hooksPath`, режими індексу) на кожен `It` файлів `InstallHooks.Tests.ps1` і `SupplyMarker.Tests.ps1`; знімає скрипт задачі 1 підпроцесом диспетчера PowerShell на цільовому коміті. Звірку тримає Pester-тест на `kit.exe` з закритою таблицею відмінностей: червоний і на розбіжності поза таблицею, і на рядку таблиці, що не проявився (ADR-0021 п. 1). Тест лишається регресійним і після B6 | немає (§5.0 «Еталон») |
| 2 | `-Workspace`/`-Source` у `install-hooks` — невідомий параметр, код 2, як диспетчер зараз (параметрів команда не оголошує) | немає |
| 3 | Відомі відмінності: (а) `install-hooks` перевіряє `.githooks` і файли хуків безпечним робочим шляхом з межею — корінь репозиторію (посилання дорогою — відмова до запису; PowerShell писав крізь посилання); (б) гілки `chmod +x` для POSIX немає — `kit.exe` лише Windows (`build.rs`), біт виконання ставить індекс, як зараз. Запис у шапці модуля й у таблиці відмінностей тесту рішення 1 | немає (§5.0) |
| 4 | `Hooks.Tests.ps1`: тести поведінки шаблонів хуків (`pre-commit`, `pre-merge-commit` на справжньому git) лишаються, їхня підготовка кладе хуки через `kit.exe install-hooks -Apply`; тести аудиту (`Test-KitGitHooks`) — у таблицю «`It` → Rust-тест `hooks::audit`» (рішення 10 B1); `It` без Rust-покриття — новий Rust-тест | немає |
| 5 | `Supply.Tests.ps1` `It` про `Write-KitSupplyMarker` — у таблицю «`It` → тест»: чорна скринька `SupplyMarker` чи Rust-тест модуля команди | немає |
| 6 | Версія — наступний вільний patch лінії 2.0 на момент злиття; `CHANGELOG.md` і `skills/onboarding/references/upgrades.md`: команди ті самі, відмінності рішення 3; чекліст «Нічого робити не треба.» | немає |

## Інтерфейси

Дає: `kit install-hooks` (`-RepoRoot`, `-Apply`), `kit supply-marker` (`-RepoRoot`, `-Workspace`, `-Source`,
`-Apply`) — параметри, вивід і коди як зараз (спека §5.2); тест звірки з еталоном (рішення 1) — зразок для B3–B5.
Бере: B1 — помічник контракту, `cli::parse`, `path_safety`, `worktree_state`, маршрут і мапу параметрів фікстури;
наявні `hooks`, `supply`, `config`.

## Інваріанти безпеки

| # | Інваріант | Перевірка, що ловить дефект |
| --- | --- | --- |
| I1 | `install-hooks` не пише крізь посилання | Rust-тест: `.githooks` — junction на теку поза репозиторієм → відмова, ціль не змінилась; без junction — хуки покладено (двійник) |
| I2 | Хуки — байти шаблону | тест рішення 1 і Rust-тест: файл `.githooks/<ім'я>` побайтно дорівнює `templates/githooks/<ім'я>`; контроль — змінений шаблон у фікстурі дає інший файл |
| I3 | `.claude/settings.json` не змінюється | наявний `It` `InstallHooks.Tests.ps1` («лишається байт-у-байт») на `kit.exe` |
| I4 | Позначку поставки не записано без усіх передумов | кожен `It` `SupplyMarker.Tests.ps1` на `kit.exe`: код 1 і позначки немає (чи вона не змінилась) на кожній передумові; двійник — щасливий шлях пише позначку |
| I5 | Позначка — SHA-1 `.bin` малими літерами без BOM і переводу рядка | Rust-тест: байти файла дорівнюють 40 символам `supply::bin_sha1`; `supply::state` після запису — `current` |
| I6 | `kit.exe` для цих команд не запускає `pwsh` | запобіжник фальшивого `pwsh` фікстури (масив перенесених команд, B1 рішення 9) |

## Задачі

| # | Назва | Вага | Після |
| --- | --- | --- | --- |
| 0 | Звірка якорів, цільовий коміт | trivial | злиття B1 |
| 1 | Еталон PowerShell і тест звірки | standard | 0 |
| 2 | `install-hooks` у Rust | standard | 1 |
| 3 | `supply-marker` у Rust | standard | 1 |
| 4 | Тести модулів, що зникають; прибирання PowerShell | standard | 2, 3 |
| 5 | Версія, бінарник, фінал | standard | 4 |

## Задача 0

Звірити якорі плану з `main` після злиття B1: цільовий коміт `main` — у журналі; `git log <коміт плану>..main --
tools/commands/install-hooks.psm1 tools/commands/supply-marker.psm1 tools/lib/Hooks.psm1 tools/lib/Supply.psm1
tools/tests/InstallHooks.Tests.ps1 tools/tests/SupplyMarker.Tests.ps1 tools/tests/Hooks.Tests.ps1` — зміна стає
поправкою плану тим самим комітом. Перевірити, що текст зупинки `supply-marker` для похідного набору (#152) є на
цільовому коміті. `doc anchors` зелений. Гілка коду від #158.
Перевірка: лише документи.

## Задача 1 — еталон PowerShell і тест звірки

Скрипт знімання еталону й Pester-тест звірки за рішенням 1; таблиця відмінностей — рядки рішення 3. До задач 2–3
тест звірки зелений на диспетчері PowerShell (контроль, що скрипт і тест бачать ту саму поведінку) і червоний на
навмисно зміненому рядку еталону (контроль, що звірка вміє впасти).
Done-when: еталон закомічено; обидва контролі показано в журналі задачі.
Перевірка: Pester — новий тест звірки.

## Задача 2 — `install-hooks` у Rust

Команда за спекою §5.2 і рішеннями 2–3: прев'ю — код 0 без змін; `-Apply` — тека й файли хуків (безпечний робочий
шлях), `core.hooksPath`, `git add` і `update-index --chmod=+x` обох файлів, залишковий аудит, код 1 лише за error.
Маршрут `kit.exe`, рядок у масиві перенесених команд фікстури.
Done-when: I1, I2 і режим `100755` обох хуків в індексі — Rust-тести на справжньому git; тест звірки на `kit.exe`
— «не перевірено до бінарника», доказ у задачі 5.
Перевірка: `cargo test`.

## Задача 3 — `supply-marker` у Rust

Команда за спекою §5.2: передумови в порядку PowerShell, тексти побайтно, похідний набір — зупинка, запис позначки
(I5). Маршрут і рядок у масиві фікстури.
Done-when: I4 (Rust-тести на кожну передумову з двійником), I5 зелені; тест звірки на `kit.exe` — як у задачі 2.
Перевірка: `cargo test`.

## Задача 4 — тести модулів, що зникають; прибирання PowerShell

`Hooks.Tests.ps1` за рішенням 4; `Supply.Tests.ps1` за рішенням 5; таблиці «`It` → тест» — шапкою Rust-тестового файла
з звіркою кількості (B1 рішення 10). Прибрати `tools/commands/install-hooks.psm1`, `tools/commands/supply-marker.psm1`,
`tools/lib/Hooks.psm1`, рядок `Hooks` у `tools/lib/module-order.txt`, `Write-KitSupplyMarker` у `Supply.psm1` і рядки
в документах, що називають прибрані функції як живі (`docs/storage-and-git.md`, скіли — `grep -rn`).
Done-when: `grep -rlw` кожної прибраної функції по `tools/` порожній, крім історичних згадок у `CHANGELOG.md`;
`ModuleImportOrder`, `PathSafety.Structure`, `Skills` зелені.
Перевірка: Pester `-Only Hooks,Supply,ModuleImportOrder,PathSafety.Structure,Skills` (тести з `kit.exe` — у задачі 5).

## Задача 5 — версія, бінарник, фінал

Рішення 6; бінарник `bin/kit.exe` з CI окремим комітом; Defender (`Get-MpThreatDetection`) після запусків.
Done-when: на коміті з бінарником CI зелені тест звірки, `InstallHooks`, `SupplyMarker`, `Hooks`, `Supply`,
`KitExe`, `BinWrapper` і `-Full` (за замком); записів Defender немає; PR з `Closes #158`.
Перевірка: `-Full`.

## Задачі власника

Немає: дозволів і шаблонів споживача блок не змінює.

## Підсумок аудиту

Заповнюється після аудиту.
