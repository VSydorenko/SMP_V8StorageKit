# Швидкість набору тестів — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Звести повний прогін набору з 463 с до 55–70 с, не змінюючи команди, якою його запускають, і не втративши жодного тесту.

**Architecture:** `Run-Tests.ps1` роздає файли тестів `N` дочірнім процесам `pwsh` і зводить результати; чистá логіка розкладу й вердикту виноситься в `tools/tests/lib/TestRunner.psm1` і тестується в процесі. Чотири найважчі файли розрізаються фізично по наявних межах `Describe`/`Context` — перенос тексту, не переписування. Політика прогону в документах скорочується до однієї форми.

**Tech Stack:** PowerShell 7, Pester 5, `Start-Process` для воркерів, JSON для підсумків і таблиці тривалостей.

**Spec:** `docs/superpowers/specs/2026-09-18-test-suite-performance-design.md`

## Global Constraints

- **Мова** коду, коментарів, повідомлень про помилки, комітів і документів — **українська**.
- **PowerShell 7+**, **Pester 5+** (`Run-Tests.ps1` вимагає `-MinimumVersion 5.0`; `Environment.psm1` тримає ту саму межу).
- **Коміти точкові:** `git add <явний перелік>` + `git commit --only -m <повідомлення> -- <ті самі шляхи>`. Ніколи `-a`, `-A`, `.`. `-m` іде **до** `--`.
- **Ніколи** `git checkout -- <шлях>`, `git restore`, `git stash`, `git clean` — у спільному робочому дереві це знищує чужу незастейджену роботу безповоротно.
- **Чужі зміни в `git status` не чіпати.** Якщо задача вимагає торкнутись файлу, якого немає в її списку, — не робити, сказати контролерові.
- **Після кожної задачі набір без `Integration` зелений.** Форма прогону — та сама, що в §7 спеки.
- **Версію плагіна не бампати.** Жодна зміна цього плану не видима споживачам: єдиний торканий файл у `templates/` — правка застарілого коментаря (Task 11).
- **`hooks/hooks.json` у плагіні не створювати** (правило 5 `CLAUDE.md`).
- **Нові тести — за зразком** `Check.Tests.ps1`, `Sync.Tests.ps1`, `GitMerge.Tests.ps1`: справжній виконуваний код підпроцесом на синтетичному дереві, перевірка і тексту, і того, що наступний крок не відбувся. Кожна нова перевірка на вивід супроводжується **мутацією**: вирізати рядок production — тест мусить почервоніти.
- **`docs/follow-ups.md` §18 — обов'язкове:** будь-який процес, що кличе `Invoke-Pester`, виставляє `[Console]::OutputEncoding` і `$OutputEncoding` у UTF-8 **до** Pester. Інакше кириличний вивід дочірніх процесів читається кодовою сторінкою хосту і тести падають детерміновано.
- **Гілки `storage/*` пише лише `kit sync`.** `V8KIT_SYNC=1` виставляє тільки `Invoke-KitStorageBranch` і фікстура `Add-KitFakeStorageCommit`. Нічого нового тут не додається.

---

## File Structure

**Нове:**

| Файл | Відповідальність |
|---|---|
| `tools/tests/lib/TestRunner.psm1` | чиста логіка без побічних дій: вибір файлів за `-Only`, розклад по воркерах, читання/запис таблиці тривалостей, вердикт прогону. Тестується **в процесі**, без запуску воркерів |
| `tools/tests/lib/Invoke-TestWorker.ps1` | один воркер: UTF-8, `Invoke-Pester` по своєму переліку файлів, запис підсумку JSON |
| `tools/tests/TestRunner.Tests.ps1` | модульні тести `TestRunner.psm1` — найдешевший файл набору, десятки мілісекунд |
| `tools/tests/test-durations.seed.json` | засівна таблиця тривалостей (комітиться; оновлюється свідомо) |
| `tools/tests/fixtures/CheckSetup.ps1` | спільна підготовка п'яти файлів `Check.*` — **перенесена**, не написана |
| `tools/tests/fixtures/SessionCheckSetup.ps1` | те саме для п'яти файлів `SessionCheck.*` |
| `tools/tests/fixtures/RenameEdtSetup.ps1` | те саме для двох файлів, на які ділиться перший `Describe` `RenameEdt` |
| 19 нових `*.Tests.ps1` | результат розрізання чотирьох файлів (Tasks 6–9): 5 + 5 + 4 + 5 |

**Змінюється:** `tools/tests/Run-Tests.ps1` (орkестрація), `tools/tests/RunTests.Tests.ps1` (нові властивості контракту), `tools/tests/fixtures/KitFixtures.psm1` (+`Invoke-KitCommand`), `tools/tests/SessionStartHook.Tests.ps1` (одна стеля таймауту), `CLAUDE.md`, `README.md`, `.claude/settings.json`, `.claude/skills/kit-dev/SKILL.md`, `.claude/skills/kit-dev/references/{cases.md,subagent-brief.md}`, `templates/hooks/session-start.ps1` (коментар), сама спека (§5, дві уточнені деталі).

**Зникає:** `Check.Tests.ps1`, `SessionCheck.Tests.ps1`, `RenameEdt.Tests.ps1`, `Sync.Tests.ps1` — цілком переносяться в розрізані файли.

**Механізм спільної підготовки — dot-source, не модуль.** `BeforeAll` розрізаних файлів робить `. (Join-Path $PSScriptRoot 'fixtures/<X>Setup.ps1')`. Причина: перенесені хелпери користуються `$TestDrive` і `function script:` — усередині модуля перше не видно, а друге осідає в чужій області. Dot-source лишає обидві речі точно там, де вони були, тож **тіла `It` не змінюються жодним байтом** — а це умова доказу з Task 5.

---

## Block A — раннер

### Task 1: Чиста логіка раннера в окремому модулі

**Files:**
- Create: `tools/tests/lib/TestRunner.psm1`
- Test: `tools/tests/TestRunner.Tests.ps1`

**Interfaces — Produces:**

| Функція | Параметри | Повертає |
|---|---|---|
| `Resolve-KitTestFiles` | `-Root <string>`, `-Only <string[]>` | повні шляхи файлів тестів, без дублікатів, у порядку вибору |
| `Split-KitTestFiles` | `-Files <string[]>`, `-Durations <IDictionary>`, `-Workers <int>` | масив `[pscustomobject]{ Index; Files; Sec }`, порожні кошики відкинуті |
| `Read-KitTestDurations` | `-MeasuredPath <string>`, `-SeedPath <string>` | `hashtable` «ім'я файлу → секунди»; виміряне перекриває засівне; відсутній файл — не помилка |
| `Write-KitTestDurations` | `-Path <string>`, `-Durations <IDictionary>` | нічого; створює теку, пише JSON із ключами за алфавітом, значення округлені до 0,01 |
| `Get-KitRunVerdict` | `-Summaries <object[]>`, `-DispatchedFiles <string[]>`, `-WorkerExitCodes <int[]>` | `[pscustomobject]{ Green; Reasons; Containers; TotalCount; FailedCount }` |

**Правила, які треба закодувати саме так:**

`Resolve-KitTestFiles`
1. Перелік будується `Get-ChildItem -LiteralPath $Root -Filter '*.Tests.ps1' -File` — **без рекурсії**. Це навмисно: `lib/` лежить усередині `tools/tests`, і рекурсія затягнула б туди файли, яких `-Only` не бачить. Раннер віддає Pester **явний перелік файлів**, не теку, тож розбіжності «що знайшла рекурсія / що показує перелік доступних» більше не існує.
2. Без `-Only` — усі файли, відсортовані за іменем.
3. З `-Only <ім'я>`: відкинути суфікс `.Tests.ps1`, якщо він є. **Точна назва має перевагу:** якщо `<база>.Tests.ps1` існує — це він. Інакше група `<база>.*.Tests.ps1`. Інакше — `throw` з текстом, що містить `<база>.Tests.ps1` і `Доступні: <перелік>` (обидві підрядки вже перевіряють наявні тести `RunTests.Tests.ps1` — зберегти дослівно).
4. Шаблон групи екранувати `[System.Management.Automation.WildcardPattern]::Escape($base)`: інакше описка виду `-Only 'Ch*'` мовчки вибрала б групу замість зупинки.

`Split-KitTestFiles` — жадібний LPT:
1. Вага файлу — з `-Durations` за **іменем файлу** (не повним шляхом). Невідомий файл важить як **максимум відомих**; якщо таблиця порожня — усі по 1,0.
2. Сортування спадне за вагою, за рівних ваг — за іменем. Вибір кошика — `Sort-Object -Property Load -Stable | Select-Object -First 1`. Обидва `-Stable`/тайбрейк обов'язкові: без них розклад недетермінований, а детермінізм розкладу — властивість, яку Task 4 закріплює тестом.
3. `-Workers` менше 1 — `throw`.

`Get-KitRunVerdict` — зелено **лише** коли порожній перелік причин. Причини збираються всі, не перша:
- воркер із кодом виходу ≠ 0 → `воркер N вийшов з кодом X`;
- підсумків менше, ніж воркерів → `підсумків: A, воркерів: B — хтось не лишив підсумку`;
- сума `Containers` ≠ кількість розданих файлів → `виконано контейнерів: A, роздано файлів: B`;
- сума `TotalCount` = 0 → `прогін не виконав жодного тесту`;
- сума `FailedCount` > 0 → `впало тестів: N`.

`Measure-Object -Sum` на порожньому наборі повертає `$null` — усі суми звести до 0 явно, інакше порівняння з числом дасть хибне «зелено».

- [ ] **Step 1: Написати падаючі тести `tools/tests/TestRunner.Tests.ps1`**

Файл цілком у процесі, без підпроцесів і без git — має відпрацьовувати за десятки мілісекунд. Що саме мусить бути перевірено (по одному `It` на пункт, кожен із дискримінуючим боком):

| Що | Дискримінуючий бік |
|---|---|
| `-Only` з точною назвою бере рівно один файл | у результаті **немає** файлів групи `<база>.*` |
| `-Only` з іменем групи бере всі `<база>.*.Tests.ps1` | і **не** бере `<інше><база>.Tests.ps1` (напр. `Check` не тягне `SessionCheck`) |
| точна назва перемагає групу, коли існують і файл, і група | результат — один файл, не перелік |
| описка зупиняє | текст винятку містить `<база>.Tests.ps1` **і** `Доступні:` |
| `-Only 'Ch*'` зупиняє, а не вибирає групу | екранування підстановок працює |
| розклад детермінований | два виклики `Split-KitTestFiles` на тих самих входах дають **однакові** кошики |
| розклад балансує | на входах 88, 80, 41, 36, 33, 23 і 3 воркерах максимальне навантаження кошика **менше** за суму двох найважчих |
| невідомий файл важить як максимум відомих | файл без запису в таблиці не осідає в кошик із найважчим |
| виміряне перекриває засівне | значення з `-MeasuredPath` |
| вердикт: усе гаразд → `Green` | `Reasons` порожній |
| вердикт: мертвий воркер (код ≠ 0) → **не** `Green` | причина називає номер воркера |
| вердикт: бракує підсумку → **не** `Green` | причина називає обидві кількості |
| вердикт: контейнерів менше за роздані файли → **не** `Green` | ловить «файл не виконався й ніхто не помітив» |
| вердикт: нуль тестів → **не** `Green` | ловить мовчазні «0 тестів» у паралельній формі |
| вердикт: усі структурні умови справні, але тест впав → **не** `Green` | причина називає кількість |

- [ ] **Step 2: Прогнати — мусять упасти на відсутньому модулі**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only TestRunner`
Expected: FAIL — `TestRunner.psm1` ще немає.

- [ ] **Step 3: Написати `tools/tests/lib/TestRunner.psm1`** за таблицею інтерфейсів і правилами вище. `#Requires -Version 7`, `Set-StrictMode -Version Latest`, `Export-ModuleMember` на п'ять функцій.

- [ ] **Step 4: Прогнати — мусять пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only TestRunner`
Expected: PASS.

- [ ] **Step 5: Довести мутацією, що вердикт справді охороняє.** У копії модуля прибрати перевірку «сума `Containers` ≠ кількість розданих файлів». Відповідний тест мусить почервоніти. Якщо лишається зеленим — тест тавтологічний, переписати його, а не перевірку. Копію видалити.

- [ ] **Step 6: Коміт**

```bash
git add tools/tests/lib/TestRunner.psm1 tools/tests/TestRunner.Tests.ps1
git commit --only -m "тести: чиста логіка раннера — розклад, таблиця тривалостей, вердикт" -- tools/tests/lib/TestRunner.psm1 tools/tests/TestRunner.Tests.ps1
```

---

### Task 2: Воркер

**Files:**
- Create: `tools/tests/lib/Invoke-TestWorker.ps1`

**Interfaces — Consumes:** нічого з Task 1. **Produces:** формат підсумку, який читає Task 3.

**Параметри:** `-FileListPath <string>` (текстовий файл, один шлях на рядок), `-SummaryPath <string>`, `-ExcludeTag <string[]>`.

**Що робить, у цьому порядку:**
1. **UTF-8 першими двома рядками** — `follow-ups` §18. До `Import-Module Pester`, не після.
2. `Import-Module Pester -MinimumVersion 5.0`; `-ExcludeTag` розділити по комі тим самим ідіомом, що в `Run-Tests.ps1` (через `-File` кома приходить усередині елемента).
3. **По одному `Invoke-Pester` на файл**, не один виклик на весь перелік. Причини: дає тривалість кожного файлу для таблиці, дає прив'язку падіння до файлу, і дозволяє друкувати маркер `>>> ФАЙЛ <ім'я>` перед кожним. Накладна — лише повторний `New-PesterConfiguration`; імпорт Pester (≈547 мс) один на процес.
4. Конфігурація кожного виклику: `Run.Path` = один файл, `Run.PassThru = $true`, `Run.Exit = $false`, `Output.Verbosity = 'Detailed'`, `Filter.ExcludeTag` якщо задано.
5. Накопичити `Containers` (+1 на файл), `TotalCount`, `PassedCount`, `FailedCount`, `SkippedCount`, `Durations` (ім'я файлу → секунди, 0,01), `Failures` (`File`, `Name` з `ExpandedPath` тесту, `Message`).
6. Підсумок писати у `finally` — **навіть коли Pester кинув**. Виняток осідає в полі `Error`.
7. **Код виходу воркера означає «воркер зламався», а не «тест упав»:** 0, якщо дійшов до кінця й записав підсумок; 1, якщо поле `Error` непорожнє. Падіння тестів їдуть у підсумку. Без цього розділення вердикт Task 1 не може відрізнити мертвий воркер від червоного прогону.

- [ ] **Step 1: Написати воркер** за пунктами вище.

- [ ] **Step 2: Перевірити руками на двох найдешевших файлах**

```bash
pwsh -NoProfile -Command "Set-Content -Path $env:TEMP/wl.txt -Value @((Resolve-Path tools/tests/PathSafety.Tests.ps1).Path,(Resolve-Path tools/tests/RepoRoot.Tests.ps1).Path)"
pwsh -NoProfile -File tools/tests/lib/Invoke-TestWorker.ps1 -FileListPath $env:TEMP/wl.txt -SummaryPath $env:TEMP/ws.json -ExcludeTag Integration
cat $env:TEMP/ws.json
```
Expected: код виходу 0; у підсумку `Containers: 2`, `FailedCount: 0`, два ключі в `Durations`, `Error` порожній.

- [ ] **Step 3: Перевірити аварійну гілку.** Підсунути в перелік неіснуючий шлях. Expected: код виходу 1, підсумок **усе одно записаний**, `Error` непорожній. Це і є вхід, на якому вердикт Task 1 зробить прогін червоним.

- [ ] **Step 4: Коміт**

```bash
git add tools/tests/lib/Invoke-TestWorker.ps1
git commit --only -m "тести: воркер прогону — Pester по файлу, підсумок JSON, UTF-8 до Pester" -- tools/tests/lib/Invoke-TestWorker.ps1
```

---

### Task 3: `Run-Tests.ps1` — паралельність за замовчуванням

**Files:**
- Modify: `tools/tests/Run-Tests.ps1` (цілком переписується орkестрація; шапку з обґрунтуваннями зберегти й доповнити)
- Create: `tools/tests/test-durations.seed.json`
- Modify: `docs/superpowers/specs/2026-09-18-test-suite-performance-design.md` §5 (дві уточнені деталі — див. Step 5)

**Interfaces — Consumes:** усі п'ять функцій Task 1; воркер Task 2.

**Параметри після правки:** `-ExcludeTag <string[]>`, `-Only <string[]>`, `-Serial <switch>`, `-Workers <int>` (0 = автоматично), `-FullLog <switch>`.

**Дві гілки, і це головне в задачі:**

**Гілка одного процесу — `-Only` або `-Serial`.** Поводиться **точно як сьогодні**: `Invoke-Pester` у цьому ж процесі, `Run.Exit = $true`, `Output.Verbosity = 'Detailed'`, вивід послідовний і повний. Причина: у червоній фазі простий вивід цінніший за секунди, і всі чотири наявні тести `RunTests.Tests.ps1` перевіряють саме цю гілку — вона мусить лишитись сумісною дослівно.

**Гілка паралельного прогону — усе інше:**
1. Робоча тека `build/test-run/` (`build/` уже в `.gitignore`) — перестворюється щоразу.
2. `-Workers` за замовчуванням: `[Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount - 4))`. На цій машині (12 ядер) — 8. Число **підбирається виміром** у Task 12, не постулюється.
3. Таблиця: `Read-KitTestDurations -MeasuredPath build/test-durations.json -SeedPath tools/tests/test-durations.seed.json`.
4. Розклад — `Split-KitTestFiles`. Перелік файлів кожного воркера писати у `build/test-run/worker-<N>.files.txt`.
5. Воркери — `Start-Process pwsh -NoProfile -File lib/Invoke-TestWorker.ps1 … -NoNewWindow -PassThru` з **різними** файлами для stdout і stderr (один файл на два потоки — помилка `Start-Process`).
6. `WaitForExit()` на кожному, **і лише потім** читати `ExitCode`. Якщо `ExitCode` виявився `$null` — трактувати як збій воркера, не як 0.
7. Вердикт — `Get-KitRunVerdict`.
8. Таблицю тривалостей **злити**, не перезаписати: почати з прочитаної, накрити новими значеннями, записати. Так запис не губить файлів, яких цей прогін не торкався.

**Вивід — те, що агент читає, а не вісім логів.** Причина: сьогоднішній `Detailed`-вивід на 675 тестів — це десятки тисяч токенів у кожному результаті інструмента, і саме вони роблять цикл дорогим. Тому за замовчуванням:
- шапка: скільки файлів, скільки воркерів, де логи, **і сам розклад** — по рядку на воркер, `воркер <N>: <файли через кому, у порядку роздачі>`. Розклад у шапці не косметика: без нього Task 4 не може перевірити, що жоден розданий файл не загубився дорогою до воркера;
- кожне падіння: `<файл> :: <повне ім'я тесту>`, повідомлення, і **рядок відтворення** `… -Only <база файлу>`;
- підсумок: файлів `виконано/роздано`, тестів, впало, секунд;
- `ЗЕЛЕНО` (код 0) або `ЧЕРВОНО: <причини через "; ">` (код 1) і шлях до логів.

`-FullLog` додатково друкує логи воркерів **у порядку номерів воркерів**, а всередині — у порядку роздачі: так текст детермінований і два прогони можна порівняти.

- [ ] **Step 1: Переписати `Run-Tests.ps1`** за пунктами вище. Обґрунтування з наявної шапки (кодування — `follow-ups` §18; розділення по комі через `-File`; чому `Integration` питає підтвердження) **зберегти**: вони куплені живими прогонами. Дописати абзац про дві гілки й про те, чому код виходу воркера не означає падіння тесту.

- [ ] **Step 2: Прогнати наявні тести раннера — вони перевіряють гілку одного процесу**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only RunTests,TestRunner`
Expected: PASS, усі чотири наявні `It` у `RunTests.Tests.ps1` зелені без правок.

- [ ] **Step 3: Перший паралельний прогін — і одразу засівна таблиця**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: `ЗЕЛЕНО`, `виконано/роздано` збігаються. Записати час **і лік тестів** — це базове число для інваріанта Block B (після Task 1 воно вже не 675).
Потім скопіювати `build/test-durations.json` у `tools/tests/test-durations.seed.json` — це й є засів для свіжого клону.

- [ ] **Step 4: Довести, що «зелено» неможливе при мертвому воркері.** Тимчасово зламати воркер (наприклад, `throw` першим рядком у `Invoke-TestWorker.ps1`), прогнати, переконатися: код виходу ≠ 0 і причина названа. Поламане прибрати. Це ручна мутація; машинну ставить Task 4.

- [ ] **Step 5: Уточнити §5 спеки двома реченнями.** План розійшовся зі спекою у двох деталях, і спека приводиться до факту, а не навпаки:
  1. таблиця тривалостей має **дві** частини — виміряну в `build/` (за `.gitignore`) і засівну `tools/tests/test-durations.seed.json` (комітиться), бо інакше перший прогін у свіжому клоні розкладає файли навмання;
  2. за замовчуванням раннер друкує **підсумок і падіння**, а логи воркерів лишає файлами; повний друк — за `-FullLog`. Причина — токени агента, той самий аргумент, що в §4 спеки про розмір файлів.

- [ ] **Step 6: Коміт**

```bash
git add tools/tests/Run-Tests.ps1 tools/tests/test-durations.seed.json docs/superpowers/specs/2026-09-18-test-suite-performance-design.md
git commit --only -m "тести: паралельний прогін за замовчуванням — та сама команда, вісім воркерів" -- tools/tests/Run-Tests.ps1 tools/tests/test-durations.seed.json docs/superpowers/specs/2026-09-18-test-suite-performance-design.md
```

---

### Task 4: Машинна охорона нового контракту

**Files:**
- Modify: `tools/tests/RunTests.Tests.ps1` (додаються `It`; наявні чотири не чіпаються)

**Interfaces — Consumes:** `Run-Tests.ps1` після Task 3.

Нові `It` запускають раннер **підпроцесом**, як і наявні.

**Механізм — власна міні-пісочниця, не справжній набір.** Три властивості нижче на справжньому дереві перевірити неможливо: зіпсований воркер зіпсував би прогін усім, а груп `<база>.*` до Block B ще не існує. Тому тест будує під `$TestDrive` **міні-набір**: копіює `Run-Tests.ps1` і теку `lib/`, кладе поруч два найдешевші справжні файли (`PathSafety`, `RepoRoot`) і два синтетичні — `Проба.А.Tests.ps1`, `Проба.Б.Tests.ps1`, по одному тривіальному `It`. Раннер запускається **з копії**. Так Task 4 не залежить від Block B і нічого не ламає в робочому дереві.

`Copy-KitTools` для цього **не годиться**: він копіює `tools/lib`, `tools/commands`, `tools/assets`, `templates/` і `skills/`, але **не** `tools/tests/`. Потрібен маленький хелпер у самому файлі тесту — три `Copy-Item`; виносити його у фікстури нема потреби.

| Властивість | Як довести, що асерція здатна впасти |
|---|---|
| мертвий воркер робить прогін червоним | у копії зіпсувати `lib/Invoke-TestWorker.ps1` (`throw` першим рядком): **і** ненульовий код, **і** причина в тексті, **і** відсутність рядка `ЗЕЛЕНО` |
| `-Only <група>` вибирає всю групу | у копії `-Only Проба` дає обидва `Проба.*`, а `PathSafety` у вибірці **відсутній** |
| точна назва перемагає групу | докласти в копію `Проба.Tests.ps1`: `-Only Проба` бере **лише** його, не групу |
| описка досі зупиняє з переліком | наявний тест; переконатися, що новий текст винятку зберіг обидві підрядки (`<база>.Tests.ps1` і `Доступні:`) |
| у шапці розкладу кожен розданий файл рівно один раз | у копії з п'ятьма файлами й трьома воркерами: об'єднання переліків із шапки = перелік розданих файлів, без дублів і пропусків. Ловить «файл загубився дорогою до воркера» — те, чого лік контейнерів не ловить, бо він рахує **виконане**, а не **роздане** |
| кириличний вивід дочірнього процесу з-під воркера читається правильно | прогін **паралельною** гілкою на файлі, що порівнює кириличний вивід `git`/`kit` (`Hooks` або `InstallHooks`), мусить бути зелений. Мутація: прибрати два рядки UTF-8 із воркера — тест мусить почервоніти (`follow-ups` §18 у паралельній формі) |

Детермінізм розкладу тут **не** перевіряється: це властивість `Split-KitTestFiles`, уже закріплена модульним тестом Task 1, де вона коштує мілісекунди замість двох повних прогонів.

- [ ] **Step 1: Написати нові `It`** — падатимуть, бо властивостей ще немає або бо потрібен зіпсований воркер.
- [ ] **Step 2: Прогнати** `… -Only RunTests`. Expected: FAIL на нових.
- [ ] **Step 3: Доробити `Run-Tests.ps1`/воркер** до тих властивостей, яких бракує (наприклад, друк шапки розкладу, який тест читає).
- [ ] **Step 4: Прогнати** `… -Only RunTests`. Expected: PASS.
- [ ] **Step 5: Мутація UTF-8** — прибрати два рядки кодування у копії воркера, переконатися, що тест червоніє. Копію прибрати.
- [ ] **Step 6: Повний набір.** Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`. Expected: `ЗЕЛЕНО`.
- [ ] **Step 7: Коміт**

```bash
git add tools/tests/RunTests.Tests.ps1 tools/tests/Run-Tests.ps1 tools/tests/lib/Invoke-TestWorker.ps1
git commit --only -m "тести: контракт паралельного раннера під охороною — мертвий воркер, групи, UTF-8" -- tools/tests/RunTests.Tests.ps1 tools/tests/Run-Tests.ps1 tools/tests/lib/Invoke-TestWorker.ps1
```

**Після Block A повний набір мусить бути ~90–100 с** (стеля — `SessionCheck`, 88,5 с). Це проміжна, очікувана цифра; Block B прибирає стелю.

---

## Block B — розрізання

**Спільна процедура для Tasks 6–9, і вона важливіша за самі шви.**

Ризик розрізання — не зламаний тест, а **тест, який перестав виконуватись**. Проти нього — доказ нульовим diff'ом:

1. **До** розрізання зняти знімок: повний перелік імен тестів (`Describe > Context > It`) і результат кожного, відсортований. Найпростіше — прогін із `PassThru` і вивід `ExpandedPath` + `Result` у файл під `build/`.
2. Розрізати: `Describe` і `Context` у нових файлах лишаються **дослівно** тими самими (Pester розрізняє контейнери файлом, не іменем). Тіла `It` переносяться байт у байт.
3. **Після** — той самий знімок. `diff` мусить бути **порожнім**: та сама кількість, ті самі імена, ті самі результати.
4. Ненульовий diff — зупинка й розбір, а не «підправити знімок».
5. **Лік тестів — смоук, не доказ.** Блоки A і B **додають** тести (Task 1 — модульні тести раннера, Task 4 — охорона контракту, Task 5 — тест фікстури), тож число 675 зі спеки перестає діяти вже після Task 1. Інваріант розрізання формулюється інакше: **лік у прогоні безпосередньо ПЕРЕД розрізанням дорівнює ліку ПІСЛЯ нього**. Виконавець фіксує базове число перед кожною з задач 6–9 і звіряє після. Порожній diff із пункту 3 суворіший і має перевагу: рівний лік при непорожньому diff означає, що один тест зник, а інший з'явився, — і ловить це саме diff.

Знімки тримати в `build/` (гітігноровано), у коміт не тягнути.

---

### Task 5: `Invoke-KitCommand` у фікстурах

**Files:**
- Modify: `tools/tests/fixtures/KitFixtures.psm1`
- Test: `tools/tests/KitFixtures.Tests.ps1` (створити)

**Interfaces — Produces:** `Invoke-KitCommand -Kit <шлях до kit.ps1> -Command <ім'я> -Repo <шлях> -More <string[]>` → `[pscustomobject]{ ExitCode; Output }`.

**Чому це перша задача блоку.** Одинадцять файлів тестів визначають майже однакові `Invoke-Check`, `Invoke-Sync`, `Invoke-Provision`, `Invoke-Canon`, `Invoke-Dump`, `Invoke-Adopt`, `Invoke-Build`, `Invoke-Verify`, `Invoke-InstallHooks`, `Invoke-SessionCheck`, `Invoke-RenameEdt`. Після розрізання їх стане ще більше. Один спільний виклик прибирає дублювання — але робить його **єдиною точкою відмови**: якби він тихо ковтав ненульовий код виходу, зелено-завжди стали б усі E2E-тести відразу. Тому фікстура отримує власний тест, і це не формальність.

Локальні обгортки в файлах тестів **лишаються** — тонкими, делегуючими. Це умова того, що тіла `It` не змінюються.

- [ ] **Step 1: Написати падаючий тест фікстури.** Дві перевірки, обидві на справжньому `kit.ps1` у пісочниці (`Copy-KitTools`): успішна команда дає код 0 і текст у `Output`; **навмисно провалена** команда (наприклад, `check` на теці без маніфесту) дає **ненульовий** `ExitCode` і текст причини. Друга — головна: вона й ловить «фікстура ковтнула код».
- [ ] **Step 2: Прогнати.** Run: `… -Only KitFixtures`. Expected: FAIL — функції немає.
- [ ] **Step 3: Додати `Invoke-KitCommand`** у `KitFixtures.psm1` — та сама форма виклику, що вже стоїть в одинадцяти файлах (`& pwsh -NoProfile -File $Kit <команда> -RepoRoot <репо> @More 2>&1 | Out-String`, потім `$LASTEXITCODE`), плюс `Export-ModuleMember`. `-Repo` необов'язковий: `kit.ps1` без команди й без `-RepoRoot` теж треба вміти покликати.
- [ ] **Step 4: Прогнати.** Expected: PASS.
- [ ] **Step 5: Мутація.** У копії фікстури замінити повернення `ExitCode` на константу 0 — другий тест мусить почервоніти. Копію прибрати.
- [ ] **Step 6: Коміт**

```bash
git add tools/tests/fixtures/KitFixtures.psm1 tools/tests/KitFixtures.Tests.ps1
git commit --only -m "фікстури: спільний Invoke-KitCommand під власним тестом" -- tools/tests/fixtures/KitFixtures.psm1 tools/tests/KitFixtures.Tests.ps1
```

---

### Task 6: Розрізати `Check.Tests.ps1` (80,2 с → п'ять файлів ≈16 с)

**Files:**
- Create: `tools/tests/fixtures/CheckSetup.ps1` ← `Check.Tests.ps1:3-18` (тіло `BeforeAll`, дослівно)
- Create: п'ять файлів за таблицею нижче
- Delete: `tools/tests/Check.Tests.ps1`

`Check.Tests.ps1` — **один** `Describe` (рядок 2) на 40 `It`, тож шви проводяться за темами. Межі — за рядками наявного файлу (599 рядків усього):

| Новий файл | Рядки-джерело | `It` | Тема |
|---|---|---:|---|
| `Check.AgentBase.Tests.ps1` | 19–133 | 8 | база агента, версія плагіна проти структури |
| `Check.Manifest.Tests.ps1` | 134–262 | 7 | схема маніфесту, накладка в git, головна гілка |
| `Check.Names.Tests.ps1` | 263–349 | 7 | `<Name>` у `Configuration.xml`, конекшни §2.2/§2.5 |
| `Check.GitPolicy.Tests.ps1` | 350–476 | 10 | `.gitignore`/`.gitattributes` §2.6, артефакти, гілки `storage/*` §3.2, хуки §3.3 |
| `Check.Storage.Tests.ps1` | 477–597 | 8 | шлях сховища, `dump.from`, `-Workspace`, стійкість аудиту до збоїв git |

Кожен новий файл: `#Requires -Version 7`, той самий рядок `Describe 'kit check — інваріанти репозиторію-споживача' {` **дослівно**, `BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }`, далі перенесені `It`.

- [ ] **Step 1: Знімок «до»** — процедура блоку, пункт 1.
- [ ] **Step 2: Винести `BeforeAll`** (`Check.Tests.ps1:3-18`) у `fixtures/CheckSetup.ps1`. Усередині `Invoke-Check` замінити тіло на виклик `Invoke-KitCommand` з Task 5; `New-GoodRepo` перенести без змін. Решта — дослівно.
- [ ] **Step 3: Створити п'ять файлів,** перенісши `It` за таблицею. Нічого не переписувати, не перейменовувати, не групувати.
- [ ] **Step 4: Видалити `Check.Tests.ps1`** (`git rm` — деструктивна операція, спитати підтвердження, якщо класифікатор дозволів її перериває).
- [ ] **Step 5: Знімок «після» і diff.** Expected: **порожній diff**. Ненульовий — зупинка.
- [ ] **Step 6: Повний набір.** Expected: `ЗЕЛЕНО`, лік тестів **той самий, що у прогоні перед розрізанням** (пункт 5 спільної процедури).
- [ ] **Step 7: Коміт**

Видалення вже застейджене кроком 4 (`git rm` кладе його в індекс), тож тут лишається лише `git add` нових файлів. `git rm --cached` **не** вживати: він лишив би файл на диску незакомічeним.

```bash
git add tools/tests/fixtures/CheckSetup.ps1 tools/tests/Check.AgentBase.Tests.ps1 tools/tests/Check.Manifest.Tests.ps1 tools/tests/Check.Names.Tests.ps1 tools/tests/Check.GitPolicy.Tests.ps1 tools/tests/Check.Storage.Tests.ps1
git commit --only -m "тести: Check розрізано на п'ять файлів — стеля прогону з 80 с до 16 с" -- tools/tests/fixtures/CheckSetup.ps1 tools/tests/Check.AgentBase.Tests.ps1 tools/tests/Check.Manifest.Tests.ps1 tools/tests/Check.Names.Tests.ps1 tools/tests/Check.GitPolicy.Tests.ps1 tools/tests/Check.Storage.Tests.ps1 tools/tests/Check.Tests.ps1
```

---

### Task 7: Розрізати `SessionCheck.Tests.ps1` (88,5 с → п'ять файлів ≈18 с)

**Files:**
- Create: `tools/tests/fixtures/SessionCheckSetup.ps1` ← `SessionCheck.Tests.ps1:3-63` (тіло `BeforeAll`, дослівно: `New-FakeStorage`, `New-Repo`, `Invoke-SessionCheck`, `$script:Old`, `$script:New`, чотири `Import-Module` модулів `lib/`)
- Create: п'ять файлів
- Delete: `tools/tests/SessionCheck.Tests.ps1`

Файл — 451 рядок: `Describe` (2), спільний `BeforeAll` (3–63), далі три `It` на рівні `Describe`, два `Context`, ще вісімнадцять `It` на рівні `Describe` і третій `Context`.

| Новий файл | Рядки-джерело | `It` | Що переноситься |
|---|---|---:|---|
| `SessionCheck.Heuristics.Tests.ps1` | 64–115 | 6 | три `It` рівня `Describe` + `Context` «запаковане сховище (data/pack)» цілком |
| `SessionCheck.Imprint.Tests.ps1` | 116–157 | 4 | `Context` «відбиток сховища» цілком |
| `SessionCheck.Signals.Tests.ps1` | 158–218 | 6 | сигнали дзеркала й доступності сховища |
| `SessionCheck.Findings.Tests.ps1` | 219–400 | 12 | знахідки `check` над сигналами, `-AsJson`, інваріанти «нічого не змінює» |
| `SessionCheck.Origin.Tests.ps1` | 401–450 | 2 | `Context` «origin: відставання без мережі» цілком |

Той самий `Describe 'kit session-check — сигнал без платформи (§5)' {` дослівно в усіх п'яти; `BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }`.

**Чому dot-source, а не модуль:** `New-FakeStorage` і `New-Repo` користуються `$TestDrive`, а `New-Repo` кличе `Merge-KitBranchInto` з `GitMerge.psm1`, імпортований у цю саму область. Усередині модуля не видно ні першого, ні другого — це рівно та пастка вкладеного `Import-Module`, яку описує великий коментар у `KitFixtures.psm1` і `follow-ups` §5.

- [ ] **Step 1: Знімок «до».**
- [ ] **Step 2: Винести `BeforeAll`** (3–63) у `fixtures/SessionCheckSetup.ps1` **без жодної зміни**. `Invoke-SessionCheck` тут теж можна звести до `Invoke-KitCommand`, але лише якщо це не змінює `Output`/`ExitCode` — інакше лишити як є.
- [ ] **Step 3: Створити п'ять файлів** за таблицею.
- [ ] **Step 4: Видалити `SessionCheck.Tests.ps1`.**
- [ ] **Step 5: Знімок «після» і diff.** Expected: порожній.
- [ ] **Step 6: Повний набір.** Expected: `ЗЕЛЕНО`, лік тестів той самий, що перед розрізанням.
- [ ] **Step 7: Коміт** (за зразком Task 6).

---

### Task 8: Розрізати `RenameEdt.Tests.ps1` (94 КБ, 41,0 с → чотири файли ≈10 с)

**Files:**
- Create: `tools/tests/fixtures/RenameEdtSetup.ps1` ← тіло `BeforeAll` першого `Describe` (починається на `RenameEdt.Tests.ps1:23`, кінець — рядок, що закриває блок перед першим `It`)
- Create: чотири файли
- Delete: `tools/tests/RenameEdt.Tests.ps1`

Файл — 1082 рядки, три `Describe`; **два з трьох переносяться цілими**, без жодної спільної підготовки:

| Новий файл | Рядки-джерело | Що це |
|---|---|---|
| `RenameEdt.Commit.Tests.ps1` | `Describe` 22 + `BeforeAll` 23–… + перші `It` до 693 | коміт перейменування, властивість безпеки §9.2 |
| `RenameEdt.Rollback.Tests.ps1` | `Context` 694–719 + ті `It` першого `Describe`, що стосуються відкоту | запобіжник політики тексту, відкіт |
| `RenameEdt.GitMock.Tests.ps1` | **722–1033 цілком** | мок git-шару в процесі (власний `BeforeAll` на 728) |
| `RenameEdt.Unresolved.Tests.ps1` | **1035–1082 цілком** | межа Unmapped/Unresolved (власний `BeforeAll` на 1036) |

Поділ першого `Describe` між `Commit` і `Rollback` проводить виконавець за темами `It`: усе, що перевіряє **відкіт і запобіжники**, — у `Rollback`, решта — у `Commit`. **Якщо межа за темою не читається однозначно — не вгадувати:** покласти весь перший `Describe` у `RenameEdt.Commit.Tests.ps1`, а в `RenameEdt.Rollback.Tests.ps1` лишити тільки `Context` 694–719. Найбільший файл дерева все одно зменшується вдвічі, а ризику зіпсувати поділ немає. Обидва файли дот-сорсять `RenameEdtSetup.ps1`. Перший `Describe` має 14 хелперів (`Add-KitBreakRestoreHook`, `Add-KitMockEdtPair`, `Invoke-TestGit`, `Reset-KitGitMockState` та ін.) — усі йдуть у `RenameEdtSetup.ps1` разом, ділити їх не треба.

- [ ] **Step 1: Знімок «до».**
- [ ] **Step 2: Винести `BeforeAll`** першого `Describe` у `fixtures/RenameEdtSetup.ps1`, дослівно.
- [ ] **Step 3: Перенести `Describe` 2 і 3** у власні файли — **цілком, разом з їхніми `BeforeAll`**, нічого не виносячи.
- [ ] **Step 4: Поділити перший `Describe`** на `Commit` і `Rollback`, обидва з dot-source.
- [ ] **Step 5: Видалити `RenameEdt.Tests.ps1`.**
- [ ] **Step 6: Знімок «після» і diff.** Expected: порожній.
- [ ] **Step 7: Повний набір.** Expected: `ЗЕЛЕНО`, лік тестів той самий, що перед розрізанням.
- [ ] **Step 8: Коміт.**

---

### Task 9: Розрізати `Sync.Tests.ps1` (35,9 с → чотири файли ≈9 с + окремий `Integration`)

**Files:**
- Create: п'ять файлів
- Delete: `tools/tests/Sync.Tests.ps1`

**Спільної підготовки не потрібно взагалі:** шість `Describe` мають власні `BeforeAll`, тож кожен переноситься цілим блоком. 766 рядків:

| Новий файл | Рядки-джерело | `It` | Що це |
|---|---|---:|---|
| `Sync.Guards.Tests.ps1` | **2–123** | 10 | штатні зупинки до звернення до платформи |
| `Sync.Merge.Tests.ps1` | **125–339** | 6 | злиття в головну гілку, гейт `-Apply` |
| `Sync.Depth.Tests.ps1` | **341–514** | 11 | `-FromVersion`/`-FromLatest`, три `Context` із власними `BeforeEach` |
| `Sync.Origin.Tests.ps1` | **516–636** | 3 | `fetch` перед реплеєм, підказка про `push` |
| `Sync.Storage.Tests.ps1` | **638–723 + 725–766** | 6 | два `Describe` під `-Tag Integration` — реальне сховище розширення й конфігурації |

Останній рядок — окрема вигода: `Integration`-блоки збираються в один файл, і щоденний прогін його просто не бере.

У файлі два різні `function script:Invoke-Sync` (рядки 6 і 646) — вони належать різним `Describe` і їдуть кожен зі своїм. Не зводити їх до одного: другий обслуговує `Integration`-сценарій і може відрізнятись.

- [ ] **Step 1: Знімок «до».**
- [ ] **Step 2: Перенести п'ять блоків** за таблицею, кожен цілим.
- [ ] **Step 3: Видалити `Sync.Tests.ps1`.**
- [ ] **Step 4: Знімок «після» і diff.** Expected: порожній. `Integration`-тести в обох знімках однаково **пропущені** — знімок знімається тією самою формою `-ExcludeTag Integration`.
- [ ] **Step 5: Повний набір.** Expected: `ЗЕЛЕНО`, лік тестів той самий, що перед розрізанням.
- [ ] **Step 6: Коміт.**

**Після Block B повний набір мусить бути ~55–70 с,** а найдовший файл — `Provision` (33 с). Якщо стеля не впала — розбиратись, перш ніж іти в Block C.

---

## Block C — політика й приймання

### Task 10: Стеля таймауту, чутлива до завантаження

**Files:**
- Modify: `tools/tests/SessionStartHook.Tests.ps1` (один `It` — «те, що kit устиг надрукувати до стелі»)

Тест виставляє `V8KIT_SESSION_CHECK_TIMEOUT = 2`, і заглушка мусить встигнути запустити `pwsh` (263 мс без завантаження), надрукувати рядок і скинути буфер у файл **за ці 2 с**. Під вісьмома воркерами може не вкластися — тоді тест падає на відсутньому `install-hooks` у виводі, і це виглядає як флак від паралельності. Стеля піднімається до **6 с**: заглушка все одно спить 30 с, тож те, що тест перевіряє (частковий вивід до стелі), не міняється.

Сусідній `It` зі стелею 1 с **не чіпати**: його асерція — `BeLessThan 20`, запасу 19 с.

- [ ] **Step 1: Підняти стелю 2 → 6** і дописати коментар, **чому** саме: число охороняє від чутливості до завантаження машини, а не підібране навмання.
- [ ] **Step 2: Прогнати** `… -Only SessionStartHook`. Expected: PASS.
- [ ] **Step 3: Один повний набір.** Expected: `ЗЕЛЕНО`. П'ять прогонів підряд — критерій приймання §8 спеки — робляться **один раз**, у Task 12, коли число воркерів уже обране: тут вони міряли б не ту конфігурацію й коштували б тих самих п'яти хвилин двічі. Падіння на цьому кроці розбирається як **наявний дефект, який паралельність показала**, не як регрес від неї.
- [ ] **Step 4: Коміт**

```bash
git add tools/tests/SessionStartHook.Tests.ps1
git commit --only -m "тести: стеля таймауту хука сесії 2 -> 6 с — запас на завантажену машину" -- tools/tests/SessionStartHook.Tests.ps1
```

---

### Task 11: Політика прогону — п'ять документів

**Files:**
- Modify: `CLAUDE.md` (розділ «Тести», рядки ~48–75)
- Modify: `README.md` (~рядок 130)
- Modify: `.claude/skills/kit-dev/SKILL.md` (пункт «Червона фаза — `-Only <файл>`, не повний набір»)
- Modify: `.claude/skills/kit-dev/references/cases.md` (case 20)
- Modify: `.claude/skills/kit-dev/references/subagent-brief.md` (розділ «Прогін тестів»)
- Modify: `.claude/settings.json`
- Modify: `templates/hooks/session-start.ps1` (застарілий коментар про 600000 мс)

Команда прогону згадана в дереві приблизно у 120 місцях. Правиться **лише те, де описана політика** — плани в `docs/superpowers/plans/`, брифи й звіти в `.superpowers/sdd/`, історія `docs/follow-ups.md` **не чіпаються**: команда в них виконується дослівно й дає той самий результат, тільки швидше.

| Файл | Що робити |
|---|---|
| `CLAUDE.md` | Розділ «Тести» скоротити до однієї форми: прогін **завжди повний** (~60 с), `-Only` — відладка, `-Serial` — діагностика, `-FullLog` — коли треба всі логи. Абзац про кому в `-Only` **не видаляти, а замінити рядком-вказівником** на шапку `Run-Tests.ps1`, де обґрунтування вже лежить (правило `kit-dev` «скорочую інструкцію»: причина не зникає, а переїжджає туди, де діє). Додати, що `Integration` і надалі питає підтвердження |
| `README.md` | команда та сама; оновити тривалість у тексті |
| `kit-dev/SKILL.md` | пункт «Червона фаза — `-Only <файл>`, 1 с проти ~6,5 хв» → «прогін завжди повний; `-Only` — відладка». Посилання на case 20 лишити |
| `kit-dev/references/cases.md`, case 20 | історію **не переписувати**; дописати надбудову «після паралельного раннера (2026-09-22) правило змінилось: повний прогін коштує ~60 с, тож рівнів більше немає» — тією самою формою, якою `follow-ups` веде власну історію |
| `kit-dev/references/subagent-brief.md` | **найважливіша правка**: з цього шаблону народжується кожен майбутній бриф виконавця. Дві форми з межею «червона фаза / перед комітом» → одна команда. Заборону «без `-ExcludeTag Integration` не запускати ніколи» зберегти дослівно |
| `.claude/settings.json` | додати дозвіл на `-Serial`; **обидва наявні рядки лишити дослівно** — вони і є та форма, яку агенти вже вживають |
| `templates/hooks/session-start.ps1` | коментар посилається на «600000 мс, що в `tools/tests/Run-Tests.ps1`» — такого числа в раннері немає. Виправити на фактичне джерело стелі або прибрати посилання. Зміна **лише коментаря**, тож версію плагіна не бампати |

**`.claude/settings.json` правиться в сесії, де присутня людина, — не субагентом.** Дозволи є рішенням користувача, і субагент, що редагує власні дозволи, — саме той клас дії, якого тут не роблять. Решту файлів таблиці субагент править вільно.

- [ ] **Step 1: Правки за таблицею.**
- [ ] **Step 2: Перевірити, що нічого не розійшлось**

```bash
grep -rn "6,5 хв\|6.5 хв\|397 с\|~6,5" CLAUDE.md README.md .claude/skills/kit-dev/
grep -rn "Run-Tests" .claude/settings.json CLAUDE.md README.md
```
Expected: старі тривалості лишились **лише** там, де це історія (`cases.md`, `follow-ups`), і ніде — як чинна інструкція.

- [ ] **Step 3: Перевірити дозволи живим викликом.** Запустити `-Serial` і переконатися, що класифікатор не питає. Якщо питає — правило сформульоване не так, як виглядає команда.
- [ ] **Step 4: Прогнати `Skills.Tests.ps1`** — він перевіряє `.md` скілів, і правка `kit-dev` може його зачепити. Run: `… -Only Skills`. Expected: PASS.
- [ ] **Step 5: Коміт**

```bash
git add CLAUDE.md README.md .claude/settings.json .claude/skills/kit-dev/SKILL.md .claude/skills/kit-dev/references/cases.md .claude/skills/kit-dev/references/subagent-brief.md templates/hooks/session-start.ps1
git commit --only -m "політика прогону: одна форма замість трьох — повний набір коштує 60 с" -- CLAUDE.md README.md .claude/settings.json .claude/skills/kit-dev/SKILL.md .claude/skills/kit-dev/references/cases.md .claude/skills/kit-dev/references/subagent-brief.md templates/hooks/session-start.ps1
```

---

### Task 12: Приймання й підбір числа воркерів

**Files:**
- Modify: `tools/tests/test-durations.seed.json` (перезасів після розрізання)
- Modify: `docs/superpowers/specs/2026-09-18-test-suite-performance-design.md` (§4.1 — фактичні числа замість цільових)

- [ ] **Step 1: Підібрати `-Workers` виміром.** Прогнати повний набір із `-Workers 4`, `6`, `8`, `10`, записати час кожного. Взяти те, після якого виграш зникає; якщо оптимум не 8 — змінити типове значення в `Run-Tests.ps1` і сказати про це в спеці.
- [ ] **Step 2: Перезасіяти таблицю.** Після розрізання імена файлів інші, тож `tools/tests/test-durations.seed.json` перезаписати з `build/test-durations.json` останнього повного прогону.
- [ ] **Step 3: П'ять повних прогонів підряд на обраному числі воркерів.** Expected: п'ять `ЗЕЛЕНО`, розкид часу невеликий.
- [ ] **Step 4: Перевірити, що `-Only` працює на всіх нових групах.** `-Only Check`, `-Only SessionCheck`, `-Only RenameEdt`, `-Only Sync` — кожен мусить назвати свої файли й бути зеленим.
- [ ] **Step 5: Записати фактичні числа у §4.1 спеки** замість цільових: секунди повного прогону, найдовший файл, обране число воркерів. Якщо результат вийшов поза 55–70 с — написати, чому, а не підганяти текст.
- [ ] **Step 6: Повний набір із `Integration`** — один раз, за підтвердженням користувача (реально запускає `1cv8.exe`).
- [ ] **Step 7: Коміт**

```bash
git add tools/tests/test-durations.seed.json docs/superpowers/specs/2026-09-18-test-suite-performance-design.md tools/tests/Run-Tests.ps1
git commit --only -m "приймання: фактичні числа паралельного прогону, перезасів таблиці тривалостей" -- tools/tests/test-durations.seed.json docs/superpowers/specs/2026-09-18-test-suite-performance-design.md tools/tests/Run-Tests.ps1
```

---

## Покриття спеки

| Розділ спеки | Задача |
|---|---|
| §5 контракт раннера: механіка, UTF-8, розклад, форми, вердикт, вивід | Tasks 1–4 |
| §6 розрізання чотирьох файлів | Tasks 6–9 |
| §6.1 спільна підготовка у фікстури | Tasks 5–8 |
| §6.2 нульовий diff + власний тест фікстури | процедура Block B, Task 5 |
| §7 політика: п'ять правок | Task 11 |
| §8 ризик `SessionStartHook`, критерій п'яти прогонів | Task 10 |
| §9 «що не робимо» | нічого не реалізується — навмисно |
| §4.1 цільові числа | Task 12 замінює їх фактичними |

**Чого в спеці не було, а план додає** (обидва уточнення спека отримує в Task 3, Step 5): засівна таблиця тривалостей поруч із виміряною, і друк підсумку замість восьми логів за замовчуванням.

**Чого план навмисно не робить:** групування запусків підпроцесу, дешевша фікстура, ліниві модулі, обхід `powershell-yaml`, швидкий/повільний рівень набору, теплий воркер. Усі шість відкинуті у §9 спеки з числами; повертатись до них — рішення користувача, не самостійна ініціатива.
