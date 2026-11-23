# Перехід на Rust, фаза 2: `check`, `session-check`, конфігурація й раннер

Issue: #53 — статус живе в GitHub (`track`), не в цьому файлі
Glossary: `docs/GLOSSARY.md` · ADR: ADR-0014, ADR-0018, ADR-0019 · Parent: —

## 1. Goal

Команди `kit check` і `kit session-check` виконує `kit.exe` без PowerShell. Разом із ними в Rust
переходять читання конфігурації (маніфест, накладка, `v8project.yaml`), префлайт і запуск раннера. Після
фази хук старту сесії в репозиторії 1С не запускає `pwsh`. Наступні споживачі отримують готові модулі:
блок B2 спеки 1С (`kit step`) — запуск раннера й контекст воркспейсу, фаза 3 (#54) — конфігурацію й префлайт.
Поведінка обох команд — та сама, крім винятків ADR-0014 п. 7.

## 2. Out of scope

- Команди, що пишуть: `sync`, `verify`, `adopt`, `provision`, `dump`, `supply-marker`, `install-hooks` —
  фаза 3 (#54). Вони лишаються в PowerShell зі своїми копіями спільних функцій (§5.0).
- Запис відбитка сховища (`Write-KitStorageImprint`) і запис накладки (`Save-KitOverlayAgentBase`) — фаза 3;
  фаза 2 відбиток і накладку лише читає.
- Команди процесу (`sdd`, `pr-gate`, `doc`, …) — фаза 4 (#55).
- Команда `kit step` — блок B2 спеки `2026-11-20-1c-specificity-design.md`; фаза 2 дає їй модулі (§4).
- `tools/check-environment.ps1` лишається PowerShell-скриптом; вердикти версій бере з `kit.exe` (§5.2).
- Зміна поведінки `check` чи `session-check` понад винятки ADR-0014 п. 7.

## 3. Blocks

| Block | Scope | Done when | Depends on |
| --- | --- | --- | --- |
| B1 Конфігурація | модуль `config` крейта: читання YAML (ADR-0018), маніфест і накладка, `v8project.yaml` і `v8project.local.yaml`, база агента воркспейсу, розбір рядка підключення з маскуванням секретів, префлайт (суворий і поблажливий) зі знахідками (§5.1) | тести паритету на кожній фікстурі маніфесту зелені: контекст і знахідки Rust-префлайту дорівнюють PowerShell-префлайту; помилка на кожен клас неправильного файла має тест, що червоніє без перевірки | — |
| B2 Раннер і Уніка | модуль `runner` — єдине місце запуску раннера (ADR-0019): установлена Уніка з реєстру плагінів, вердикти версій Уніки й раннера, запуск, конверт раннера; приховані підкоманди для PowerShell; `Runner.psm1` і `check-environment.ps1` переходять на них (§5.2) | запобіжник «раннер запускається лише в модулі `runner`» має влучення й контроль, що вміє впасти; тести `Runner` і `Environment` зелені, а `check-environment.ps1` на фальшивому реєстрі друкує ті самі вердикти, що до зміни; лапкування — тест на аргументах із пробілом, лапкою й кінцевим `\` | — |
| B3 `kit check` | команда `check` у Rust: усі перевірки §5.3, вивід і коди як зараз; диспетчер не отримує `check`; `commands/check.psm1` видалено за ADR-0014 п. 7 | усі Pester-файли `Check.*`, `Secrets`, `Templates` зелені проти `kit.exe` (фікстура `Invoke-KitCommand` кличе `kit.exe check`); еталон виводу PowerShell на фікстурах знято до видалення модуля й звірено | B1 (`config`), B2 (`runner`, `unica`) |
| B4 `kit session-check` і хук | команда `session-check` у Rust (§5.4); хук `session-start` кличе `kit.exe session-check` дочірнім процесом замість передачі PowerShell; `commands/session-check.psm1` видалено за ADR-0014 п. 7 | усі `SessionCheck.*` і `SessionStartHook` зелені проти `kit.exe`; у репозиторії з маніфестом хук не запускає `pwsh` (тест фальшивим `pwsh.exe`, що лишає маркер); стеля часу й текст «НЕВІДОМИЙ» — як зараз | B3 (`check` як функція), злиття гілки `feature/onboarding-target-state` (вона змінює `session-check.psm1` і `StorageBranch.psm1`) |

## 4. Interfaces

| Interface | Kind | Owner block | Consumers | Defined in |
| --- | --- | --- | --- | --- |
| `config`: типи маніфесту, накладки, воркспейсу, source-set, бази агента; префлайт → контекст і знахідки | API крейта | B1 | B3, B4, спека 1С B2, фаза 3 | §5.1 |
| знахідка `{рівень, перевірка, повідомлення}` | тип | B1 | B3, B4 | §5.1 |
| `runner`: запуск раннера → конверт раннера; `platforms`, `agent release`, `--version` | API крейта | B2 | B3, спека 1С B2, фаза 3 | §5.2 |
| `unica`: установлена Уніка з реєстру плагінів; вердикти версій Уніки й раннера | API крейта | B2 | B3, `check-environment.ps1` (через підкоманду) | §5.2 |
| прихована підкоманда запуску раннера: аргументи раннера → конверт і код без змін | підкоманда `kit.exe` | B2 | `tools/lib/Runner.psm1` | §5.2 |
| прихована підкоманда вердиктів інструментів → JSON | підкоманда `kit.exe` | B2 | `tools/check-environment.ps1` | §5.2 |
| `kit check`: параметри, вивід, коди | CLI | B3 | користувачі, скіли, B4 | §5.3 |
| `check` як функція (знахідки без друку, режим `-Quiet`) | API крейта | B3 | B4 | §5.3 |
| `kit session-check`: параметри, вивід, коди | CLI | B4 | хук `session-start`, скіли | §5.4 |
| відбиток сховища `build/session-check/<ключ>.json` | файл | наявний: `StorageImprint.psm1` (пише `sync`, фаза 3) | B4 (читає) | §5.4 |

## 5. Blocks in detail

### 5.0 Спільні правила фази

- **Порядок переносу** — ADR-0014 п. 7: Rust-команда → наявні Pester-тести команди зелені проти `kit.exe`
  як чорна скринька → еталон виводу PowerShell на фікстурах знято до видалення модуля → модуль команди
  прибрано. Байти, які kit порівнює чи хешує, не змінюються.
- **Спільні функції.** Функцію, яку кличе ще й PowerShell-команда фази 3, переносять у Rust, а її
  PowerShell-копію лишають, доки її кличе хоч одна PowerShell-команда. Перелік на дату спеки:
  `Select-KitSources`, `Resolve-KitAgentBase`, `New-KitAgentBaseMissingMessage`, `Find-KitAgentBaseCollisions`,
  `Test-KitPathsOverlap`, `Get-KitRunnerMemoryPath`, `Test-KitOnMainBranch`, `Test-KitBranchExists`,
  `Get-KitStorageBranchLastVersion`, `Get-KitOriginGap`, `Test-GitTextPolicy`, `Get-KitTreePaths`,
  `Get-KitCaseCollisions`, `Get-KitSupply*`, `Test-KitGitHooks`, `Test-KitLegacySessionHook`, `Invoke-KitPreflight`
  (диспетчер кличе його для кожної PowerShell-команди). Актуальний перелік — `grep -rlw <функція> tools/commands`.
  Однаковість копій тримають наявні тести PowerShell-функцій і тести паритету B1.
- **Виняток зі спільних функцій — запуск раннера:** копії немає, PowerShell кличе `kit.exe` (ADR-0019).
- **PowerShell заморожено** (ADR-0014 п. 7): у фазі змінюються лише `Runner.psm1` (запуск через `kit.exe`),
  `check-environment.ps1` (вердикти через `kit.exe`), фікстура тестів `Invoke-KitCommand` (команди фази — через
  `kit.exe`) і видалення модулів двох команд.
- **Фаза нічого не пише** у репозиторій, сховище чи базу: лише тимчасові файли виводу дочірніх процесів, які
  прибирає сама. Тримає це наявний тест «`session-check` нічого не змінює й не створює тек» проти `kit.exe`.
- **Зовнішні процеси фази** — лише git (через ядро `git`, ADR-0014 п. 5) і раннер (через `runner`).

### 5.1 B1 Конфігурація

- **YAML** — `serde_yaml` (ADR-0018). Контракт читання як у `Read-KitYaml`: файл, що не розбирається, порожній
  обов'язковий файл чи корінь не мапа — помилка з іменем файла; порожній необов'язковий файл (`-AllowEmpty`) —
  порожня мапа. Порядок ключів зберігається (читання як `ConvertFrom-Yaml -Ordered`): від нього залежить порядок
  джерел і знахідок у виводі.
- **Маніфест `v8storagekit.yaml` і накладка `v8storagekit.local.yaml`** — власні типи з тими самими правилами,
  що `Read-KitManifest` і `Read-KitLocalOverlay`: обов'язкові ключі, форма шляху сховища, невідомий ключ —
  помилка, старий рядок `kitVersion:` — помилка з рецептом.
- **`v8project.yaml`** — деревом (ADR-0018 п. 2): kit бере лише source-set-и (ім'я, тип, шлях) і поля своєї
  політики (`Get-V8ProjectConfigProblems`: стара `infobase:`, `providers` = `designer`, форма `infobases`).
  **`v8project.local.yaml`** — лише `infobases.origin`.
- **База агента** воркспейсу (`Resolve-KitAgentBase`): вид (файлова чи серверна), шлях, наявність `1Cv8.1CD`;
  перетини баз і пам'яті раннера між воркспейсами (`Find-KitAgentBaseCollisions`, канонічні шляхи).
- **Рядок підключення** (`ConvertFrom-V8Connection`): `File=`/`Srvr=`+`Ref=`, облікові дані. Секрет (пароль)
  ніколи не потрапляє у вивід: маскування як `Hide-V8Secrets`; пароль із лапкою — відмова
  (`Assert-V8SecretQuoteFree`).
- **Префлайт**: суворий (перша помилка — зупинка з кодом 1) і поблажливий (`-Lenient`: усі помилки стають
  знахідками, контекст — наскільки вдалося зібрати; так його кличуть `check` і `session-check`). Вибір джерел
  за `-Workspace`/`-Source`/`-Truth` — як `Select-KitSources`.
- **Тест паритету**: на кожній фікстурі `tools/tests/fixtures/manifest-*.yaml` і на синтетичних репозиторіях
  `New-KitFakeRepo` контекст і знахідки Rust-префлайту (прихованою підкомандою або через `check`) дорівнюють
  PowerShell-префлайту. Тест живе, доки живе PowerShell-копія префлайту.

### 5.2 B2 Раннер і Уніка

- **Установлена Уніка** — з `~/.claude/plugins/installed_plugins.json` (запис `unica@…`): версія й `installPath`,
  як `Get-UnicaInstallation`. Тести передають інший реєстр явним параметром, не змінною оточення.
- **Раннер** — `<installPath>/bin/win-x64/v8-runner-windows-x86_64/v8-runner.exe`; запасного пошуку немає
  (кеш тримає кілька версій Уніки). Тести передають шлях фальшивого раннера явним параметром.
- **Вердикти версій**: Уніка — за мінором (протестований мінор задає код, як `Get-KitUnicaVersionVerdict`);
  раннер — `--version` → `v8-runner X.Y.Z`, вердикт за мінором (`Get-KitRunnerVerdict`). Протестовані мінори
  живуть в одному місці — модулі `unica`.
- **Запуск** (ADR-0019): аргументи передаються з лапкуванням за правилами `CommandLineToArgvW`;
  `--config <воркспейс>/v8project.yaml`, аргументи команди, `--json-message`; stdout — конверт раннера,
  stderr зберігається для тексту помилки; стеля часу задає викликач. Конверт, що не розбирається, —
  помилка з дослівним stdout і stderr. Код раннера й `error` конверта kit не перетлумачує.
- **Приховані підкоманди `kit.exe`** (не в `-Help`): запуск раннера для PowerShell (конверт і код без змін;
  шлях раннера — з Уніки або явним параметром) і вердикти інструментів одним JSON для `check-environment.ps1`.
  `Start-KitRunnerProcess` у `Runner.psm1` стає викликом першої; решта `Runner.psm1` — без змін логіки.
- **Запобіжник**: поза модулем `runner` Rust-код раннер не запускає — правило в `rust/tests/git_guard.rs` або
  поруч, тією самою лексичною схемою, з контролем, що вміє впасти.

### 5.3 B3 `kit check`

- **Параметри** як зараз: `-RepoRoot`, `-Workspace`, `-Source`, `-Quiet`, `-InstalledPluginsPath`, `-RunnerPath`;
  форма виклику й коди — ADR-0014 п. 4.
- **Перевірки** — той самий набір і ті самі ідентифікатори у виводі: `manifest`, `overlay`, `workspace`, `source`,
  `unica-version`, `runner-version`, `agent-base-required`, `main-branch`, `unique-keys`, `overlay-ignored`,
  `overlay-connection`, `gitattributes`, `case-collision`, `gitignore`, `supply`, `storage-path`, `storage-branch`,
  `dump-from`, `config-name`, `undeclared-source`, `build-artifacts`, `local-ignored`, `local-audit`, `hooks`,
  `hook-shim`. Що кожна читає — git (через ядро), дерево, маніфест, накладка, `v8project(.local).yaml`, реєстр
  плагінів, раннер `--version`.
- **Інваріанти `storage/*`** (`storage-branch`): трейлери й версії комітів, колізії регістру дерева — читанням
  git, без запису.
- **`check` як функція** для B4: повертає знахідки без друку (`-Quiet`); `runner-version` і `unica-version`
  сигналів `session-check` не блокують (як `$MachineStateChecks`).
- **Вивід** звіряється з еталоном PowerShell побайтно.

### 5.4 B4 `kit session-check` і хук

- **Поведінка** як зараз (з урахуванням гілки `feature/onboarding-target-state`, від якої блок залежить):
  спершу `check` як функція; помилка `check` — код 1 без сигналів; далі на кожне джерело `truth: storage` —
  дзеркало `storage/<ключ>`, активність сховища (`1cv8ddb.1CD`, `data/objects`, `data/pack`), відбиток сховища,
  відставання від `origin` без мережі; коди 0/1/4, рядок `next:` за ADR-0014 п. 4. Параметри як зараз:
  `-RepoRoot`, `-Workspace`, `-Source`, `-AsJson`, `-InstalledPluginsPath`, `-RunnerPath`. `-AsJson` — одна форма
  верхнього рівня і на успіху, і на помилці; звіряється з еталоном розібраними значеннями (ADR-0014 п. 7),
  текстовий вивід — побайтно.
- **Відбиток сховища** — лише читання формату, який пише `sync` (`StorageImprint.psm1`, фаза 3); схема й версія
  відбитка не змінюються.
- **Хук `session-start`**: у репозиторії з маніфестом кличе `kit.exe session-check` дочірнім процесом з тією
  самою стелею часу (`V8KIT_SESSION_CHECK_TIMEOUT`, 15 с за умовчанням), убивством дерева на стелі й текстом
  «стан сховищ НЕВІДОМИЙ»; передачі PowerShell і `pwsh` у хуку більше немає.

## 6. Security and data integrity

- **Секрети.** Рядки підключення накладки й `v8project.local.yaml` можуть містити пароль. Пароль не потрапляє
  ні у вивід `check`/`session-check`, ні в текст помилки, ні в конверт, який kit друкує; перевірка — наявний
  `Secrets.Tests.ps1` проти `kit.exe` плюс тест на текст помилки розбору рядка підключення.
- **Межі довіри.** Маніфест, накладка й `v8project*.yaml` — вміст репозиторію; хук читає їх у кожній сесії. Збій
  розбору — знахідка чи помилка, не паніка; затяжний розбір обмежує стеля часу хука. Глибину й розгортання
  якорів YAML обмежує `serde_yaml` (unverified: план B1 перевіряє фікстурою з вкладеними якорями, що розбір
  завершується помилкою чи результатом, а не зависанням).
- **Раннер** береться лише з `installPath` установленої Уніки; шлях із маніфесту чи оточення не приймається.
- **Без запису** — §5.0; фаза не торкається сховища, бази агента й гілок `storage/*`.
- **Часткові дані.** Поблажливий префлайт збирає контекст частково; `check` і `session-check` друкують знахідки
  про відсутнє, а не мовчать про нього (як зараз), і жодна перевірка не стає зеленою на неповному контексті.

## 7. Open questions

Немає: розвилки фази технічні й вирішені в ADR-0018, ADR-0019 і §5.
