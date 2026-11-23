# План B2 «Раннер і Уніка» — фаза 2 переходу на Rust (#53)

## 1. Шапка

- **Статус:** на прийманні архітектора (сесія `smp-v8storagekit-4c`). Автор — сесія плану B1/B2; виконує інша сесія.
- **Якорі після X:** немає; план спирається на `origin/main` `3aaa0fd`.
- **Режим робочої копії:** `worktree` (профіль `.agents/kit.profile.json`); гілка від `origin/main` через
  `pr-gate start 53 <ім'я>`. Спільного рантайму блок не має: справжній раннер і база агента не потрібні,
  усі тести — на фальшивому реєстрі й фальшивому раннері.
- **Хто збирає `kit.exe`:** виконавець задачі на цій машині (MSVC є), `tools/build-kit-exe.ps1`; бінарник і
  зміна `rust/` — одним комітом. Задача 2 залежить від закоміченого бінарника задачі 1: PowerShell кличе
  `bin/kit.exe` свого дерева.
- **Заборони:** файли B1 не чіпати (модуль `config`, його створює B1). PowerShell змінюється лише в `tools/lib/Runner.psm1`
  (функція запуску) і `tools/check-environment.ps1` (вердикти), спека §5.0. Справжній раннер не запускати.

## 2. Мета / Архітектура / Спека

**Мета.** Раннер Уніки запускає лише модуль `runner` крейта `kit`: Rust-код фази 2 і спеки 1С кличе його
API, а PowerShell до фази 3 — приховану підкоманду `kit.exe`. Вердикти версій Уніки й раннера дає модуль
`unica`; `check-environment.ps1` бере їх з `kit.exe`.

**Архітектура.** Два бібліотечні модулі (`lib.rs`): `unica` — реєстр плагінів, установлена Уніка, шлях
раннера в ній, протестовані мінори, вердикти; `runner` — єдиний запуск процесу раннера, конверт раннера,
`--version`. Дві приховані підкоманди в `main.rs` — тонкі обгортки над API. Запобіжник «раннер лише в модулі
`runner`» — правило в `rust/tests/git_guard.rs` тією самою лексичною схемою, що для git.

**Спека.** `docs/superpowers/specs/2026-11-23-rust-phase2-session-check-design.md` §3 (рядок B2), §4 (рядки
`runner`, `unica`, дві приховані підкоманди), §5.0, §5.2, §6 («Вивід раннера», «Раннер»). ADR-0014 (п. 4, 5, 7),
ADR-0019. Глосарій: «конверт раннера».

## 3. Глобальні обмеження

- Нових залежностей немає (`serde_json` уже є, без фічі `preserve_order`: вона змінила б порядок ключів у
  наявному JSON-виводі крейта).
- Шлях раннера — лише з `installPath` установленої Уніки або з явного параметра; з маніфесту, накладки й
  оточення — ніколи (§6). Реєстр — явний параметр або `<домашня тека>/.claude/plugins/installed_plugins.json`;
  домашню теку виконавець бере так само, як її бачить `$HOME` у `pwsh` на Windows (виміряти, не припускати).
- Код раннера, `ok` і `error` конверта kit не перетлумачує; вивід раннера не маскує (§6).
- Тексти вердиктів і помилок — ті самі, що в `Get-UnicaInstallation`, `Get-KitUnicaVersionVerdict`,
  `Get-KitRunnerPath`, `Get-KitRunnerVersion`, `Get-KitRunnerVerdict` (дослівно).
- Решта `Runner.psm1` — без змін логіки (ADR-0019 п. 2); `Invoke-KitRunner` лишається точкою моку тестів.
- Наявні тести лишаються зеленими: `cargo test`, `-Only Runner,Environment,KitExe`.

## 4. Рішення

| # | Рішення | Вплив на спеку |
|---|---|---|
| 1 | Підкоманда запуску — `kit.exe runner-exec <шлях раннера> <робоча тека> <аргумент>…`: два позиційні токени, далі аргументи раннера дослівно, без `cli::parse` (він відхиляє `--config`, `--json-message`, `--version`). stdin, stdout і stderr раннера успадковані: байти йдуть без перетворень, тимчасових файлів у `kit.exe` немає. Код `kit.exe` — код раннера. Власна помилка (`Раннер не знайдено`, не запустився) — `runner-exec: ERROR …` у stderr з кодом 1: PowerShell розрізняти її не мусить, бо `Invoke-KitRunner` вирішує за `ok` конверта, а не за кодом, і кидає виняток із stderr на не-JSON. | немає |
| 2 | `Start-KitRunnerProcess` кличе `kit.exe runner-exec` свого дерева через `System.Diagnostics.ProcessStartInfo.ArgumentList` (.NET лапкує кожен аргумент сам) з асинхронним читанням stdout і stderr (UTF-8) — без власного рядка аргументів. `ConvertTo-KitRunnerArgLine` зникає: копії правил `CommandLineToArgvW` у PowerShell більше немає (ADR-0019, «Why»). Перевірка `Test-Path` шляху раннера й форма результату `{ExitCode; Stdout; Stderr}` лишаються. | немає |
| 3 | Підкоманда вердиктів — `kit.exe tool-verdicts [-InstalledPluginsPath p] [-RunnerPath p]` (`cli::parse`) → один JSON: `unica` (поля `Get-UnicaInstallation` + `level`, `message` вердикту), `runner` (`level`, `message`, `version`). Код 0, коли JSON надруковано, і на вердикті `error`; 2 — помилка виклику. `check-environment.ps1` кличе `bin/kit.exe` свого дерева й не імпортує більше `Runner.psm1` для вердиктів. | немає |
| 4 | Реєстр плагінів читається з порядком записів файла: «перший запис `unica@…`» — як `Select-Object -First 1` у PowerShell. Без `preserve_order` — потоковим розбором об'єкта `plugins` у вектор пар. | немає |
| 5 | Тест лапкування — на справжньому PE, що друкує свій argv (тестова ціль cargo, не `.cmd`: для пакетних файлів `std::process::Command` лапкує за правилами `cmd.exe`, і тест виміряв би не те). Ціль у `bin/` не потрапляє. Фальшивий раннер Pester `tools/tests/fixtures/runner/v8-runner.cmd` лишається для тестів `Runner`/`Environment`. | немає |
| 6 | Стеля часу — параметр виклику API (`Option<Duration>`); на стелі — `proc::kill_tree` і помилка «стеля часу» з тим виводом, що встиг прийти. Підкоманда `runner-exec` стелі не має: PowerShell-викликачі її не мають і зараз. | немає |
| 7 | Протестовані мінори Уніки (`0.16`) і раннера (`0.18`) у Rust — лише в модулі `unica`. PowerShell-копії (`Environment.psm1`, `Runner.psm1`) лишаються до B3: їх кличе `commands/check.psm1`. Однаковість до B3 тримає порівняння вердиктів задачі 2. | немає; нотатка для B3 |

## 5. Інтерфейси

**Дає** (споживачі: B3, спека 1С B2 `kit step`, фаза 3 #54). Сигнатури фіксуються зараз; імена полів — виконавця.

- `unica::Installation { installed, version, install_path, path_exists, reason }` і
  `unica::installation(registry: &Path) -> Installation` — як `Get-UnicaInstallation` (не падає, причина — текстом).
  `unica::default_registry() -> Option<PathBuf>`.
- `unica::Verdict { level: Level, message: String, version: String }`;
  `unica::unica_verdict(&Installation) -> Verdict`, `unica::runner_verdict(runner: Option<&Path>, registry: &Path)
  -> Verdict` — як `Get-KitUnicaVersionVerdict` і `Get-KitRunnerVerdict`.
- `runner::installed_runner(registry: &Path) -> Result<PathBuf, String>` — як `Get-KitRunnerPath`.
- `runner::run(runner: &Path, workspace_dir: &Path, args: &[&OsStr], timeout: Option<Duration>) ->
  Result<Envelope, RunError>`: `--config <workspace_dir>/v8project.yaml`, аргументи, `--json-message`, робоча
  тека — `workspace_dir`. `Envelope { exit_code, ok, command, data, warnings, error: Option<{code, kind,
  message}>, raw: Value }` — конверт без перетлумачення. `RunError`: не запустився; стеля часу; не JSON чи без
  `ok` — з кодом, дослівними stdout і stderr.
- `runner::exec(runner, cwd, args, timeout) -> Result<RawOutput { exit_code, stdout, stderr }, RunError>` — сирий
  запуск без `--config` (для `--version` і для тестів).
- `runner::version(runner: &Path) -> Result<String, String>` — як `Get-KitRunnerVersion`.
- Приховані підкоманди `runner-exec`, `tool-verdicts` — рішення 1 і 3; не в `-Help`.

**Бере:** `proc::kill_tree` (наявний). Від B1 — нічого.

## 6. Інваріанти безпеки

| Інваріант | Перевірка, що ловить дефект |
|---|---|
| Поза модулем `runner` Rust-код раннер не запускає. | Правило в `git_guard.rs`: поза `src/runner.rs` / `src/runner/**` — влучення на літерал `v8-runner` (без регістру, з `.exe` і шляхом); динамічний `Command::new` модуля `runner` — новий запис `ALLOWED_DYNAMIC`. Позитивний двійник: у модулі `runner` правило дає влучення. Контроль, що вміє впасти: синтетичне джерело з `Command::new("v8-runner.exe")` поза модулем — червоне. |
| Шлях раннера не береться з оточення, маніфесту чи накладки. | Тест: змінна оточення з іншим шляхом раннера й маніфест із полем шляху не змінюють вибраного шляху (`installed_runner` на фальшивому реєстрі). Червоніє, якщо код почне читати оточення. |
| Аргументи доходять до раннера дослівно. | Тест лапкування (рішення 5): аргументи з пробілом, лапкою, кінцевим `\` і `\` перед лапкою, порожній аргумент → argv-луна повертає їх без змін; і через API, і через `runner-exec`. Червоніє на ручному склеюванні рядка без лапкування. |

## 7. Частини

Немає: одна підсистема, одна ціна помилки.

## 8. Задачі

| # | Задача | Файли | Готово, коли | Після | Перевірка |
|---|---|---|---|---|---|
| 0 | Звірка якорів і базова лінія | — (вивід у `.agents/out/`) | `doc anchors` плану без зламаних якорів; вивід `check-environment.ps1` на фальшивих реєстрах чотирьох станів (`Environment.Tests.ps1`, Describe `check-environment.ps1: Уніка й раннер…`: Уніки немає; 0.15.2; 0.16.0 + фальшивий раннер 0.18.1, і 0.17.0; раннера немає) знято на `origin/main` і збережено | — | — |
| 1 | Модулі `unica` і `runner`, підкоманди, запобіжник | `rust/src/{unica,runner}.rs` (або теки), `lib.rs`, `main.rs`, `rust/tests/git_guard.rs`, тест лапкування й argv-луна | API за §5; `runner-exec`, `tool-verdicts` за рішеннями 1 і 3; правило запобіжника з двійником і контролем; тест лапкування зелений; збірка поставки закомічена разом із джерелом | 0 | `cargo test`; `-Only KitExe` |
| 2 | PowerShell на `kit.exe` | `tools/lib/Runner.psm1` (лише `Start-KitRunnerProcess`, прибрати `ConvertTo-KitRunnerArgLine`), `tools/check-environment.ps1` | `Runner.Tests` і `Environment.Tests` зелені; рядки Уніки й раннера `check-environment.ps1` на чотирьох станах задачі 0 дослівно дорівнюють базовій лінії; `grep -rn 'Start-Process' tools/lib/Runner.psm1` без влучень | 1 | `-Only Runner,Environment,KitExe`; фінал — `-Full` |

**«Готово, коли» блоку** (спека §3, дослівно): запобіжник «раннер запускається лише в модулі `runner`» має
влучення й контроль, що вміє впасти; тести `Runner` і `Environment` зелені, а `check-environment.ps1` на
фальшивому реєстрі друкує ті самі вердикти, що до зміни; лапкування — тест на аргументах із пробілом, лапкою й
кінцевим `\`.

## 9. Задача 0

Звірка якорів і базова лінія `check-environment.ps1` (рядок задачі 0 вище). Дельти спеки з кодом немає:
`Runner.psm1`, `Environment.psm1` і `check-environment.ps1` між `e25ae14` і `3aaa0fd` не змінювались
(`git diff e25ae14..origin/main -- tools/lib/Runner.psm1 tools/lib/Environment.psm1 tools/check-environment.ps1`).

## 10. Задачі власника

Немає.

## 11. Підсумок аудиту

(після аудиту)
