# Адаптація kit до Unica 0.16 (kit 1.6.0) — план імплементації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kit 1.6.0 доповнює Уніку 0.16, а не дублює її: `canon` і `build` ідуть, `provision` звужується, після `sync`/`verify` завжди один крок `push force:true`, платформу для бази агента kit бере в раннера, хук старту сесії постачає сам плагін.

**Architecture:** Дельта до коду 1.5.0 на гілці `feature/unica-0.16`. Ядро (`sync`, `verify`, `adopt`, сховище, автори, githooks) лишається. Новий модуль `Runner.psm1` — єдине місце, де kit запускає `v8-runner`. `UnicaStep.psm1` втрачає критерій вирівнювання. Решта — прибирання, тексти скілів і документація.

**Tech Stack:** PowerShell 7, Pester 5, git, платформа 1С 8.3.27.x, `powershell-yaml`; Unica 0.16 (збірка §1 спеки або upstream 0.16) з v8-runner 0.18.x.

**Spec:** `docs/superpowers/specs/2026-11-19-unica-016-adaptation-design.md` на коміті **`cc82a4f`** (звірка плану архітектором — §4.2 п.15–18). Посилання `§N` нижче ведуть у цю спеку, «спека 1.5.0» — `docs/superpowers/specs/2026-10-11-unica-013-adaptation-design.md`. Архітектор — сесія `unica-016-adaptation`. Якщо план розходиться зі спекою або спека мовчить, виконавець зупиняється й питає архітектора, сам не обирає.

**Форма плану (вимога власника 2026-11-19).** План не містить готового коду. Він називає задачі, файли, імена й сигнатури, значення зі спеки, патерни й антипатерни та перевірки, які мусять бути в тестах. Код пише виконавець.

## Global Constraints

- **Без сумісності**: kit 1.6.0 говорить лише мовою Уніки 0.16. 1.5.0 не випускався, сумісності з ним теж немає (§4.1, р.9).
- **Межа kit ↔ Уніка**: kit не викликає Уніку. Він лише друкує крок `unica.run …`, і виконує цей крок агент.
- **Раннер — інструмент kit** (§3.6). Але kit не пише пам'ять раннера в обхід його команд. У 1.6.0 kit бере з раннера лише `platforms` і `agent release`.
- **Крок після `sync`/`verify`**: `unica.run {"op":"push","args":{"sourceSet":<набір>,"force":true},…}` для кожного зрушеного набору, завжди з явним `sourceSet` (§3.1, §4.2 п.7). Для набору `EXTENSION` у `pull` додається `extension` = ім'я набору (§3.2).
- Ім'я набору = ключ джерела маніфесту = `name:` у `v8project.yaml` = ім'я розширення (§4.2 п.7).
- `providers: {push: designer, pull: designer, download: designer}` — інваріант контуру (§3.8 п.2).
- Kit не друкує `workspace` у кроках `unica.run` і не рахує ім'я простору Уніки (§3.3).
- Kit не роздає `MCP_TOOL_TIMEOUT` і ніде не згадує `unica.task.*` (§5 п.1).
- Kit не видаляє базу агента (§3.4 п.3). Серверних баз не створює (§3.4 п.1).
- Політика кінців рядків `-text` лишається (§3.9).
- Перевірка версій (§4.2 п.4): Уніка нижче 0.16 — `error`; мінор вище 0.16 — `warn` з процедурою `docs/unica-contract.md`. Раннер з установки Уніки: мінор ≠ 0.18 — `warn`; раннера немає — `error`.
- Сховища — лише читання. База людини — лише читання. `-Apply` — лише на явне прохання. Підрядки `лиценз`/`ліценз`/`license`/`HASP` у виводі платформи — зупинка й доповідь.
- Версія плагіна — **1.6.0**. `ref` у `marketplace.json` не чіпати: реліз — лише після локального пілоту.
- Тексти — українською. `${CLAUDE_PLUGIN_ROOT}` у скілах — лише всередині шляху. Скіли — з префіксом `v8storagekit:`.
- Тести: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration` — повний прогін після кожної задачі. `Integration` — один прогін у фіналі, з підтвердженням людини.
- Межа тестів — правило «лише ключове» (§8): контракт між сторонами, інваріант безпеки й один контроль, що вміє впасти. Нові тести пишуться за зразком `Check.*`/`Sync.*`: підпроцес справжнього `kit.ps1` на `New-KitFakeRepo` або мок у межах модуля, як у наявних `Sync.*.Tests.ps1`. Перелік тестів у задачі — верхня межа.
- Коміт робить лише контролер: `git add <перелік>` + `git commit --only -F <файл> -- <перелік>`. Без `-a`/`-A`, без `git checkout --`/`restore`/`stash`/`clean`. Повідомлення закінчується рядком `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Бриф субагента — `.claude/skills/kit-dev/references/subagent-brief.md` шляхом плюс специфіка задачі. Модель і зусилля — явно. Бриф називає хеш закоміченого плану.
- Постійна документація — без номерів рядків, кількостей і результатів прогонів (`~/.claude/CLAUDE.md`).

## Review Focus

1. **`v8-runner platforms` відповідає `"ok": false` з кодом виходу 0** [вимір автора плану, 2026-11-19, раннер 0.18.1]. Так буває, коли в `v8project.local.yaml` немає `infobases.origin`. Якщо kit дивиться лише на код виходу, він прочитає порожній шлях як платформу. Очікувано — зупинка з текстом `data.message` раннера. Тест — Task 1, крок 1.
2. **Поставка вендора `missing`/`stale` на гілці задачі.** Рецепт зупинки, написаний для головної гілки (`pull force`), на гілці задачі замінив би роботу людини. Очікувано — різні тексти зупинки на головній гілці й на гілці задачі. На головній рецепт закінчується позначкою поставки, без `push force` (§4.2 п.18). На гілці задачі в тексті немає `"op":"pull"`. Тест — Task 3, крок 1.
3. **Тека бази агента є, але без `1Cv8.1CD`, або в ній зламана база.** Kit 1.5.0 перестворював базу з `-Force`. Тепер kit нічого не видаляє і нічого не створює поверх наявної теки. Очікувано — зупинка, яка називає людині **дві** теки до видалення: теку бази і пам'ять раннера `<воркспейс>/.local/infobases/origin/` (§4.2 п.16). Без другої нова база лишилася б зі старою пам'яттю й `push` пропустив би набори (клас #25). Обидві теки цілі. Тест — Task 6, крок 1.
4. **Сесія відкрита в підтеці репозиторію-споживача.** Хук шукає `v8storagekit.yaml` у предках, друкує контекст і попереджає, що Уніка бачитиме лише цей воркспейс. Окремий випадок — `pwsh` без `CLAUDE_PROJECT_DIR` (ручний запуск): тоді хук мовчить, а не шукає в поточній теці. Тест — Task 8, крок 1.
5. **Споживач оновив плагін, а старий проєктний хук лишився.** «Стан сховищ» показується двічі. `kit check` мусить назвати обидва старі шматки: запис `SessionStart` у `.claude/settings.json`, що веде на `.claude/hooks/session-start.ps1`, і сам файл шима. Тест — Task 8, крок 1.

---

## Структура файлів

| Файл | Що змінюється |
|---|---|
| `tools/lib/Runner.psm1` | **новий** — пошук раннера в установці Уніки, версія, `platforms`, `agent release` |
| `tools/lib/module-order.txt` | `Runner` після `Environment` (бере `Get-UnicaInstallation`) і до `StoragePlatform` |
| `tools/lib/UnicaStep.psm1` | без критерію; `Get-KitAlignStep` — `push force` або `blocked` за поставкою |
| `tools/lib/StoragePlatform.psm1`, `StorageReport.psm1`, `V8.psm1` | явний `-V8Path` у пакетних викликах бази агента |
| `tools/commands/sync.psm1`, `verify.psm1` | платформа раннера, `agent release`, без критерію |
| `tools/commands/canon.psm1` | **видаляється** |
| `tools/commands/supply-marker.psm1` | **новий** — колишній `canon -MarkerOnly` |
| `tools/commands/build.psm1` | **видаляється** |
| `tools/commands/provision.psm1` | без `-Force`, `-ServerBase New`, видалень і маркер-фази |
| `tools/commands/check.psm1`, `tools/lib/V8Project.psm1`, `tools/lib/Environment.psm1`, `tools/check-environment.ps1` | версії, ключі конфігу, старі хуки, підсумок |
| `tools/lib/Hooks.psm1`, `tools/commands/install-hooks.psm1` | шим більше не ставиться; знахідка старого проєктного хука |
| `hooks/hooks.json`, `hooks/session-start.ps1` | **нові** — хук плагіна (із `templates/hooks/session-start.ps1`, який видаляється) |
| `templates/settings.json` | без `hooks`, без `unica_task_*`, `unica_run` → `allow` |
| `skills/*/SKILL.md`, `skills/onboarding/references/upgrades.md` | тексти кроків, перехід «1.4.0 → 1.6.0» |
| `skills/unica-folders/SKILL.md` | **новий** — «Уніка не бачить теку» (§3.12 9б) |
| `CLAUDE.md`, `README.md`, `docs/storage-and-git.md`, `docs/unica-contract.md`, `docs/follow-ups.md`, `templates/CLAUDE.md`, `templates/README.md` | документація |
| `.claude-plugin/plugin.json` | 1.6.0, опис без «збірки .epf» |
| `tools/tests/*` | видалення тестів прибраних гілок; нові ключові — у задачах |

**Правило звірки прибраного (§3.2 п.2, §3.4 п.3, §8).** Функцію видаляють, коли в `tools/commands` і `tools/lib` не лишилось жодного виклику, а не за назвою файлу. Перевірка — `grep -rn '<ім'я>' tools --include=*.psm1 --include=*.ps1` без `head`. Відомий стан коду на старті плану (`d996d81`):
- `PathSafety` (`Assert-SafeWorkPath`, `Remove-KitDirectory`) і `TreeBackup` (`Get-KitDirtyRecords`, `Backup-KitDirtyFiles`, `Get-KitInvisibleWork`) викликають `adopt`, `dump`, `sync`, `verify` → лишаються. #34, П24 і П25 переносяться для цих команд.
- `Get-KitProtectedPaths` і `Find-KitProtectedCollisions` бере `Find-KitAgentBaseCollisions`, тобто аудит `check` → лишаються. Зникає лише маркер-фаза `provision`.
- Функції критерію в `UnicaStep` (`Test-KitSetTreeEqual`, `Test-KitSetClean`, `Test-KitRefIsHead`, `Write-KitCriterionNotComputed`, `Assert-KitCriterionInput`) кличуть лише `sync`/`verify` → ідуть разом з критерієм.

---

### Task 1: `Runner.psm1` — раннер як інструмент kit

Ризик: **спільний код** (кожна пакетна операція бази агента піде через нього).

**Files:**
- Create: `tools/lib/Runner.psm1`, `tools/tests/Runner.Tests.ps1`, `tools/tests/fixtures/runner/` (знімки справжніх відповідей)
- Modify: `tools/lib/module-order.txt`, `tools/tests/ModuleImportOrder.Tests.ps1` (якщо він перелічує модулі)

**Interfaces:**
- Consumes: `Get-UnicaInstallation` (`Environment.psm1`) → `.InstallPath`, `.PathExists`.
- Produces:
  - `Get-KitRunnerPath [-InstalledPluginsPath <string>] → string`. Шлях `<InstallPath>/bin/win-x64/v8-runner-windows-x86_64/v8-runner.exe` [вимір: кеш `unica/0.16.0` цієї машини]. Немає Уніки чи файла — виняток з поясненням, що саме не знайдено. Запасного `Get-V8Path` немає (§4.2 п.5).
  - `Get-KitRunnerVersion -RunnerPath <string> → string`. З `v8-runner --version` береться `0.18.1` з рядка `v8-runner 0.18.1`.
  - `Invoke-KitRunner -RunnerPath <string> -Arguments <string[]> -WorkingDirectory <string> → pscustomobject` — **єдина точка запуску раннера і точка моку для тестів**. Повертає розібраний JSON `--json-message`: `ok`, `data`, `error`, `warnings`.
  - `Get-KitAgentPlatform -Project <об'єкт V8Project воркспейсу> [-RunnerPath] → string` — шлях `data.selected.designer.path`.
  - `Invoke-KitAgentRelease -Project <…> [-RunnerPath] → pscustomobject` — `released`, `disconnected`.

**Патерни.**
- Успіх відповіді — поле `ok`, не код виходу. Раннер 0.18.1 на помилці конфігу відповідає `"ok": false`, `error.code: invalid_argument` і кодом виходу 0 [вимір 2026-11-19].
- `--config` — `v8project.yaml` воркспейсу. Робоча тека процесу — тека воркспейсу. Раннер кладе журнал `build/logs/mcp/actions.log` під `workPath` [вимір], і це прийнятно: тека `build/` гітігнорована.
- `platforms` вимагає `infobases.origin` у `v8project.local.yaml`, інакше відповідає `no infobase is selected` [вимір]. Для `sync`/`verify` база агента є завжди, бо її вже вимагає `Get-KitSourceInfobase`. Текст зупинки kit передає `data.message` раннера дослівно.
- Вивід процесу читається через файли, не через пайп: див. знахідку B2 в `Invoke-KitGitProcess`.

**Антипатерни.** Не тримати другий шлях запуску раннера поза `Invoke-KitRunner`. Не шукати раннер `Get-ChildItem -Recurse` по всьому кешу плагінів: версій Уніки в кеші кілька (`0.12.3` поруч з `0.16.0`), і рекурсія знайшла б не ту.

- [ ] **Step 0: Зняти справжні відповіді раннера.** На синтетичному воркспейсі у scratch: `v8project.yaml` з одним набором `CONFIGURATION`, `v8project.local.yaml` з `infobases.origin.connection: 'File=build/ib'`, бази не існує. Зняти вивід `platforms --json-message`, `agent release --json-message`, а також `platforms` без `v8project.local.yaml` (відповідь `ok:false`). Покласти в `tools/tests/fixtures/runner/` як файли JSON. Обидві команди за документацією раннера нічого не запускають і не пишуть у базу (C, `platforms`, `agent release`).
- [ ] **Step 1: Тести** (`Runner.Tests.ps1`, мок `Invoke-KitRunner`, знімки зі Step 0):
  - `Get-KitAgentPlatform` на знімку `ok:true` повертає значення `data.selected.designer.path` зі знімка.
  - Review Focus 1: на знімку `ok:false` — виняток, текст якого містить підрядок з `data.message` знімка (`no infobase is selected`). Шляху не повертає.
  - `Get-KitRunnerPath` на фальшивому реєстрі без файла раннера — виняток, і `Get-V8Path` не викликається (мок `Get-V8Path` з `Should -Invoke -Times 0`).
  - Контроль, що вміє впасти: тест на `ok:false` мусить почервоніти, якщо в production перевірку `ok` замінити перевіркою коду виходу. Мутацію робити на копії дерева.
- [ ] **Step 2: Прогін — тести червоні** (функцій немає).
- [ ] **Step 3: Реалізувати модуль і додати його в `module-order.txt`** з рядком причини порядку в шапці файлу, за наявним зразком.
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 2: `sync`/`verify` — платформа раннера й `agent release`

Ризик: **спільний код**. Закриває #35 для `sync`/`verify` (§3.6 п.4). `dump` лишається на `Get-V8Path` (§4.2 п.5).

**Files:**
- Modify: `tools/commands/sync.psm1`, `tools/commands/verify.psm1`, `tools/lib/StoragePlatform.psm1`, `tools/lib/StorageReport.psm1`, `tools/lib/V8.psm1`
- Test: `tools/tests/Sync.Platform.Tests.ps1` (новий); правки моків у наявних `Sync.*`/`Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitAgentPlatform`, `Invoke-KitAgentRelease` (Task 1).
- Produces: кожна функція, що запускає платформу в базі агента, приймає `[string]$V8Path` і передає його далі до `Invoke-V8Designer`/`New-V8FileInfobase`. Це `Get-StorageVersions`, `Invoke-KitStorageCheckout`, `Invoke-KitStorageCheckoutViaPlatform` (основна платформа), `New-KitStorageInfobase`, `Enter-/Exit-KitStorageBind`.

**Рішення (§4.2 п.14).**
- Платформу визначають один раз на воркспейс, до першого звернення до платформи для джерел цього воркспейсу, і передають явним `-V8Path`. Тимчасова ІБ розширення (запасний шлях §6.9) теж іде на цій платформі.
- `-DumpPlatform`: «основна платформа», з якою порівнюється `-DumpPlatform`, — це платформа раннера, а не `Get-V8Path`. Шлях альтернативної платформи й далі береться з `Get-KitInstalledPlatforms`. Платформа раннера потрібна тут ще до `Select-KitSources`, бо валідація параметрів стоїть першою. Тож або порівняння переїжджає після визначення воркспейсу, або платформу визначають за `-Source`. Виконавець обирає перше, якщо друге вимагає дублювати `Select-KitSources`.
- `Invoke-KitAgentRelease` викликається перед кожною пакетною операцією в базі агента. Для `sync` — перед `Get-StorageVersions` джерела. Для `verify` — перед `Invoke-KitStorageCheckout`. Відповідь `released:false` — норма, без друку.
- Прев'ю `sync` (без `-Apply`) теж читає звіт через платформу, тож платформа й `release` потрібні й там.

**Патерни.** Явний параметр, переданий згори вниз. Додатковий рядок у виводі: `Платформа:  <версія> (обрав раннер)` — поруч із «База агента».

**Антипатерни.** Не робити модульну змінну, яка перевизначає `Get-V8Path`: прихований глобальний стан тихо протік би в `dump`. Не лишати `if (-not $V8Path) { $V8Path = Get-V8Path }` як мовчазний запасний шлях у функціях сховища. Для них `-V8Path` стає обов'язковим, а запасний шлях лишається лише в `Invoke-V8Designer` заради `dump`.

- [ ] **Step 1: Тести** (`Sync.Platform.Tests.ps1`, моки за зразком `Sync.DumpPlatform.Tests.ps1`):
  - Контроль §8: мок `Get-KitAgentPlatform` повертає `C:\fake\8.3.27.9999\bin\1cv8.exe`. Кожен виклик `Invoke-V8Designer` за `sync -Apply` отримує саме цей `-V8Path`, а `Get-V8Path` не викликається жодного разу.
  - Раннера немає (мок `Get-KitRunnerPath` кидає): `sync` зупиняється до першого `Invoke-V8Designer`, і в тексті зупинки є пояснення з винятку.
  - Порядок: `Invoke-KitAgentRelease` викликано раніше за перший `Invoke-V8Designer` джерела. Те саме для `verify`.
  - Перед тим як писати перевірку на фразу виводу, пройти три питання `kit-dev` (case 21) і довести унікальність фрази `grep`-ом (case 22).
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Реалізація.**
- [ ] **Step 4: Повний прогін — зелений.** Наявні `Sync.*`-тести, що мокали `Get-V8Path`, переводяться на мок `Get-KitAgentPlatform`/`Invoke-KitAgentRelease`. Асерції тестів не послаблювати.
- [ ] **Step 5: Коміт.**

### Task 3: Крок після `sync`/`verify` — завжди `push force`, без критерію

Ризик: **властивість безпеки** (крок захищає від суміші версії сховища з git, §3.1 «Виміряно А4»). Потрібні два рев'ю.

**Files:**
- Modify: `tools/lib/UnicaStep.psm1`, `tools/commands/sync.psm1`, `tools/commands/verify.psm1`
- Test: `tools/tests/UnicaStep.Tests.ps1` (переписати), `tools/tests/Sync.Align.Tests.ps1` (переписати або видалити критерійні випадки)

**Interfaces:**
- Produces: `Get-KitAlignStep -Source <джерело> -OnMainBranch <bool> → pscustomobject { SourceSet; Workspace; RepoPath; Op ('push'|'blocked'); Supply; Steps; Recipe }`. Параметри `-Criterion` і `-BaseKind` зникають. `Write-KitAlignStep` і `Write-KitAlignStops` зберігають сигнатури.
- Прибираються: `Test-KitSetTreeEqual`, `Test-KitSetClean`, `Test-KitRefIsHead`, `Write-KitCriterionNotComputed`, `Assert-KitCriterionInput`. Перевірити, що `provision` більше не кличе `Get-KitAlignStep`: після Task 6 його тексти кроку не залежать від виду бази.

**Значення зі спеки.**
- Поставка `none`/`current` → `Op = 'push'`, один крок `push` з `sourceSet` і `force:true` (§3.1 наслідок 1, §4.2 п.7).
- Поставка `missing`/`stale`/`unknown` (лише `CONFIGURATION`) → `Op = 'blocked'` (§4.2 п.9). Текст `Recipe`:
  - на головній гілці: `pull force:true` Уніки цього набору → `kit supply-marker -Workspace <ws> -Source <набір> -Apply` — і все. Після повного `pull` база, дерево й пам'ять Уніки узгоджені, тож `push force` не потрібен (§4.2 п.18). Після `pull` `git status --porcelain -- <шлях набору>` мусить бути порожнім; непорожній — зупинка й доповідь людині. Цей запобіжник уже живе в `Invoke-KitCanonMarkerOnly` і переходить у Task 4;
  - на гілці задачі: зупинка «спершу поставка на головній гілці», без рядка `"op":"pull"`.
- Текст кроку `Write-KitAlignStep` (§3.1 наслідки 2, 5, 6). Уніка спитає людину про перезапис бази `origin` — це очікувано, не обходити й не повторювати без відповіді. Крок виконується лише в інтерактивній сесії, основній чи в субагенті, не в `claude -p`. `cancelled` — зупинка з доповіддю «база агента не вирівняна; наступний `push` відмовить», без повтору. Фраза «без питання людині» з тексту 1.5.0 зникає.
- `OnMainBranch` обчислює викликач: поточна гілка = `$Context.MainBranch`. Для `verify -Ref` — та сама умова за поточною гілкою, не за `-Ref`.
- Запасний шлях `sync` (розширення в тимчасовій ІБ) кроку не друкує, як і в 1.5.0. Його рядок про `push force` лишається.

**Патерни.** Блок `finally` у `sync`, який друкує вже обчислені кроки й рядки ЗУПИНКА після підсумку, переноситься як є. Він захищає від втрати кроку, коли падає пізніше джерело (спека 1.5.0, 0174871).

**Антипатерни.** Не лишати «на всяк випадок» обчислення дерев чи чистоти. Не вводити позначку «база вирівняна» (§4.2 п.1: окремого гарда стану бази немає).

- [ ] **Step 1: Тести** (рівно ці):
  - §8: після `sync -Apply` з двома зрушеними наборами (CONFIGURATION без поставки + EXTENSION) у виводі рівно два рядки `unica.run {"op":"push"`, по одному на набір. Кожен рядок містить `"sourceSet":"<ключ>"` і `"force":true`. Рядка `"op":"pull"` немає. Вивід — справжній `kit.ps1` підпроцесом або мок платформи за зразком `Sync.Align.Tests.ps1`.
  - Те саме для `verify` з одним набором.
  - Review Focus 2: `Get-KitAlignStep` для `CONFIGURATION` з поставкою `stale` дає `Op = 'blocked'`. З `-OnMainBranch $true` `Recipe` містить `"op":"pull"` і `supply-marker` і не містить `"op":"push"`. З `$false` — не містить `"op":"pull"`.
  - Контроль: вирізати гілку `blocked` у копії дерева — тест на `stale` мусить почервоніти.
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Реалізація;** видалити функції критерію і їхні тести.
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 4: `canon` прибирається; режим позначки поставки — `kit supply-marker`

Ризик: **спільний код**.

**Files:**
- Delete: `tools/commands/canon.psm1`, `tools/tests/Canon.Tests.ps1` (тести режиму `-MarkerOnly` переносяться)
- Create: `tools/commands/supply-marker.psm1`, `tools/tests/SupplyMarker.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-KitSupplyMarker -Context -Workspace -Source -Apply`. Поведінка й передумови — як у `Invoke-KitCanonMarkerOnly` на старті плану: лише `CONFIGURATION`; `.bin` описує поставку; `.cf` на місці; `current` → нічого писати; `stale` → відмова; брудне дерево → відмова. Тексти відмов, що радять «крок pull Уніки, надрукований kit sync чи kit verify», переписати: тепер `pull` дає рецепт зупинки (Task 3) або скіл.
- Диспетчер шукає функцію `Invoke-Kit<Команда>` за ім'ям команди через дефіси, тож для `supply-marker` це `Invoke-KitSupplyMarker`. Перевірити наявним тестом диспетчера в `Kit.Tests.ps1`.

**Звірка прибраного.** `canon-backup/` і `Backup-KitDirtyFiles` лишаються, бо їх кличе `adopt`. Перевірити, чи `adopt` пише в ту саму теку `canon-backup`. Якщо так — назва теки лишається (вона в історії споживачів), але тексти, що пов'язують її з `canon`, переписуються. Після задачі пошук `canon` по `tools/commands` і `tools/lib` (без `-MarkerOnly`) мусить знаходити лише коментарі історії, які пояснюють походження, або нічого. Кожен збіг виконавець перелічує в звіті.

- [ ] **Step 1: Перенести тести режиму** з `Canon.Tests.ps1` у `SupplyMarker.Tests.ps1` з новим ім'ям команди. Асерції не змінювати, крім імені команди й переписаних текстів.
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Нова команда; видалити `canon.psm1` і решту `Canon.Tests.ps1`.**
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 5: `build` прибирається

Ризик: **механічна**.

**Files:**
- Delete: `tools/commands/build.psm1`, `tools/tests/Build.Tests.ps1`
- Modify: усе, що називає `kit build` або `build/artifacts/` як роботу kit (пошук `grep -rn "kit build\|commands/build\|build/artifacts" tools skills templates`)

**Рішення (§3.5).** Збірку будь-яких артефактів робить `make` Уніки. Kit не копіює `.cf`/`.cfe` у кореневу `build/artifacts/`. Тестова ІБ для `.epf` і її платформа йдуть разом з командою. Перевірити, чи `New-ExtensionInfobase`/`New-V8FileInfobase` ще комусь потрібні: `New-V8FileInfobase` бере `provision` (Task 6) і `-DumpPlatform`.

- [ ] **Step 1: Видалити команду й тести, прибрати виклики.**
- [ ] **Step 2: Повний прогін — зелений.** Пошук вище по `tools/` має бути порожнім. Скіли й документацію правлять Tasks 10–12.
- [ ] **Step 3: Коміт.**

### Task 6: `provision` — лише перевірки, запис підключення й кроки

Ризик: **властивість безпеки** (kit більше нічого не видаляє, §3.4 п.3). Потрібні два рев'ю.

**Files:**
- Modify: `tools/commands/provision.psm1`, `tools/lib/V8Project.psm1` (нова функція шляху пам'яті)
- Test: `tools/tests/Provision.Tests.ps1` (видалити випадки `-Force`, П26, маркер-фази, `-ServerBase New`, `CrSQLDB`)

**Interfaces:**
- Produces: `Get-KitRunnerMemoryPath -Project <об'єкт V8Project воркспейсу> [-Infobase <string> = 'origin'] → string` — `<Project.Directory>/.local/infobases/<Infobase>`. Єдине місце, де kit знає, де лежить пам'ять раннера: її беруть `provision` (текст зупинки) і аудит `AgentBase` (Task 7).

**Рішення.**
- Параметри: `-Force` і значення `New` у `-ServerBase` зникають. `-ServerBase Existing` лишається, бо серверну базу дала людина (§4.1 П8). `-Template`/`-Remember` лишаються.
- Пам'ять раннера 0.18 лежить у `<тека v8project.yaml>/.local/infobases/origin/` (`hashes/`, `dump-info/`, `generation.json`), а не в `<workPath>/infobases/origin/`, як у 1.5.0 (§4.2 п.15). Усі згадки старого шляху в `provision` і його тестах прибираються.
- Файлова база, тека за шляхом бази **існує** (з `1Cv8.1CD` чи без) → зупинка. Текст називає дві теки, які людина видаляє: теку бази і `<воркспейс>/.local/infobases/origin/`. Далі — «і виконайте крок» і крок створення (§3.4 п.3, п.4; §4.2 п.16). Kit нічого не видаляє.
- Файлової бази немає:
  - дерево основної конфігурації придатне → кроки Уніки. Без `.dt`: `infobase.create`, далі **звичайний** `push` без `force` — база створюється з набором `CONFIGURATION`, і раннер його пам'ятає (§4.2 п.17). З `.dt`: `infobase.restore` з `mode:create`, далі `push` з `force:true` (restore пам'яті не пише);
  - дерево непридатне (немає дерева — рецепт (i), або поставка `missing`/`stale` — рецепт (ii)) → kit сам створює порожню файлову базу (`New-V8FileInfobase` на платформі раннера, Task 1) і друкує рецепт `sync`/`verify` (§3.4 п.4). Текст рецепту про крок вирівнювання переписати: після `sync`/`verify` — їхній крок `push force` або зупинка поставки. Розгалуження «файлова/серверна» у тексті зникає.
- Серверна база (`-ServerBase Existing`): kit нічого не видаляє, і пам'ять раннера теж (§3.4 п.3). Друкується крок `push force:true`: пам'яті про наявну базу немає, і `force` її перезаписує (§4.2 п.17).
- Прибираються `Invoke-KitProtectedPathsMarkerPhase` і два проходи. Перевірки «база агента ≠ база людини» (`Resolve-KitAgentBase`), межі `workPath` і перетину з деревами джерел лишаються, бо `New-V8FileInfobase` пише в теку бази (§3.4 п.5).
- Дефект пілоту §5 п.3: код виходу. З'ясувати, чому `$LASTEXITCODE` порожній після `pwsh -Command`, і виправити так, щоб `provision` повертав 0/1 за контрактом `kit.ps1`.

**Антипатерни.** Не лишати «м'якого» видалення порожньої теки бази: правило «kit не видаляє» без винятків.

- [ ] **Step 1: Тести** (рівно ці):
  - Review Focus 3: тека бази існує без `1Cv8.1CD`, з файлом-маркером тесту всередині; тека `<воркспейс>/.local/infobases/origin/` теж є, зі своїм маркером. `provision -Apply` зупиняється з кодом 1. У виводі є обидва шляхи й слово «видаліть». Обидва маркери на місці.
  - Те саме для теки з `1Cv8.1CD`.
  - Придатне дерево без `.dt`: після `infobase.create` надруковано `"op":"push"` без `"force":true`. З `.dt`: після `infobase.restore` — `push` з `"force":true`.
  - Рецепт (ii): дерево є, поставка `stale`, бази немає → `-Apply` створює базу (мок `New-V8FileInfobase` викликано) і не друкує `infobase.create`.
  - Код виходу підпроцесу `kit.ps1 provision` на зупинці — 1, на успіху — 0 (§5 п.3).
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Реалізація, видалення машинерії П26.**
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 7: `kit check` і `check-environment` — версії, конфіг, підсумок

Ризик: **спільний код**.

**Files:**
- Modify: `tools/lib/Environment.psm1` (`Get-KitUnicaVersionVerdict`), `tools/lib/V8Project.psm1` (перевірки ключів), `tools/commands/check.psm1`, `tools/check-environment.ps1`
- Test: `tools/tests/Check.*.Tests.ps1`, `Environment.Tests.ps1`, `V8Project.Tests.ps1`

**Значення.**
- Уніка: нижче 0.16 → `error`; 0.16.x → `ok`; мінор вище 0.16 → `warn` з посиланням на процедуру звірки `docs/unica-contract.md` (§4.2 п.4).
- Раннер (`Get-KitRunnerPath` + `Get-KitRunnerVersion`): немає → `error`; мінор ≠ 0.18 → `warn`; ідентифікатор перевірки — новий `runner-version`. Збірку форку від upstream не розрізняти.
- Прибрати перевірки ключів, які раннер відхиляє сам: `builder`, `execution_timeout`, `execution_timeout_seconds`, `basePath`, `push.partialLoadThreshold` (§3.8 п.3). Лишаються `providers` = `designer` для `push`/`pull`/`download`, форма `infobases.origin` (стара `infobase:` → `error`) і аудит бази агента.
- `tools.platform.version` у `v8project.local.yaml` — не знахідка: Уніка дописує цей ключ сама (§7.1 «Побічне»).
- Дефект пілоту §5 п.2: коли є помилки конфігу, підсумок має рахувати воркспейси й джерела маніфесту, а не 0.
- Аудит бази агента (`Get-KitProtectedPaths` вид `othermemory`, `Find-KitAgentBaseCollisions` ціль `memory` в `AgentBase.psm1`) рахує пам'ять раннера як `<workPath>/infobases` — шлях 1.5.0. Для раннера 0.18 це `<тека v8project.yaml>/.local/infobases` (§4.2 п.15). Перевести обидва місця на `Get-KitRunnerMemoryPath` (Task 6) — без власних копій шляху (kit-dev case 5). Тест — наявний тест аудиту перетину з пам'яттю чужого воркспейсу, переведений на новий шлях: база агента, покладена в `.local/infobases` іншого воркспейсу, дає знахідку.
- `-InstalledPluginsPath` лишається (П21) і доходить до пошуку раннера. Фальшивий реєстр тестів (`New-KitFakeUnicaRegistry`) отримує типову версію `0.16.0` і, за потреби, фальшивий файл раннера. Як тест check перевіряє версію раннера без справжнього `.exe` — мок `Get-KitRunnerVersion` або фальшивий реєстр з теками; виконавець обирає форму наявних `Check.*`.

- [ ] **Step 1: Тести** (рівно ці, §8):
  - `check` на воркспейсі з `tools.platform.version` у `v8project.local.yaml` не друкує знахідки про цей ключ. Контроль, що вміє впасти, — той самий файл зі сторонньою опискою ключа `infobase:` дає `error`.
  - `providers.pull: agent` → `error` з підрядком, який `grep` знаходить лише в гілці перевірки `providers`.
  - Уніка `0.15.2` → `error`, `0.17.0` → `warn`; раннера немає → `error`.
  - Підсумок за помилки конфігу називає ненульову кількість воркспейсів маніфесту.
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Реалізація.**
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 8: Хук старту сесії — у плагіні (#42)

Ризик: **спільний код** (хук спрацьовує в кожній сесії машини, і в проєктах не про 1С теж).

**Files:**
- Create: `hooks/hooks.json`, `hooks/session-start.ps1` (перенесення з `templates/hooks/session-start.ps1` через `git mv`)
- Modify: `tools/lib/Hooks.psm1` (`Install-KitSessionHook` зникає; знахідка `hook-shim` стає знахідкою старого проєктного хука), `tools/commands/install-hooks.psm1` (лише githooks і `.claude/settings.json`), `tools/tests/SessionStartHook.Tests.ps1`, `tools/tests/Hooks.Tests.ps1`, `tools/tests/InstallHooks.Tests.ps1`
- Modify: `CLAUDE.md` — прибрати правило 5 і його перевірку `test -e hooks/hooks.json`. Згадки знайти пошуком `hooks.json` і `Плагін не оголошує хуків` по всьому дереву (§3.12 9а).

**Факти Claude Code** [док `hooks.md`, `plugins/manifest-reference.md`, `plugins/components.md`, звірено 2026-11-19]:
- `hooks/hooks.json` має верхню обгортку `"hooks"`, без неї файл не вантажиться. Матчери `SessionStart`: `startup`, `resume`, `clear`, `compact`, `fork`.
- `${CLAUDE_PLUGIN_ROOT}` розкривається в `command`. Процес хука отримує `CLAUDE_PLUGIN_ROOT` і `CLAUDE_PROJECT_DIR`.
- На Windows рядок `command` виконує Git Bash (без нього — PowerShell). Поле `shell: "powershell"` запускає PowerShell напряму.
- Ненульовий код, крім 2, — неблокувальна помилка з позначкою в транскрипті. Stdout хука з кодом 0 іде в контекст Claude.

**Рішення.**
- Критерій (§4.2 п.6): шукати `v8storagekit.yaml` у `CLAUDE_PROJECT_DIR` і в його предках. У самій теці — контекст «Стан сховищ», як у шимі 1.5.0. У предку — те саме, `session-check` з `-RepoRoot <предок>`, плюс попередження §3.3 п.5 («Уніка бачитиме лише цей воркспейс»). Ніде або змінної немає — мовчки, код 0.
- Пошук плагіна в реєстрі (`Get-KitPluginRoot`) зникає: скрипт лежить у самому плагіні й бере корінь із `$PSScriptRoot` або `CLAUDE_PLUGIN_ROOT`. Структурна гарантія «мовчки й код 0» (зовнішній `try/catch/finally{exit 0}`) переноситься.
- Команда в `hooks.json` не ламає сесію без `pwsh` (§4.2 п.6). Форма команди — рішення виконавця за фактами вище. Вимога: без `pwsh` у `PATH` хук завершується кодом 0 без виводу. Варіант з `shell: "powershell"` (Windows PowerShell 5) годиться, лише якщо він сам перевіряє наявність `pwsh` і не виконує тіла скрипта.
- `kit check`: у `.claude/settings.json` споживача є `hooks.SessionStart` з командою, що веде на `.claude/hooks/session-start.ps1`, або є сам файл шима → `warn` з рецептом прибрати обидва (§3.12 9а).
- Контекст ішуї гілки — поза обсягом (§4.2 п.13 (а)).

- [ ] **Step 1: Тести** (рівно ці):
  - Хук підпроцесом з `CLAUDE_PROJECT_DIR` = тека без `v8storagekit.yaml` і без предка з ним: код 0, вивід порожній.
  - Review Focus 4: `CLAUDE_PROJECT_DIR` = підтека фальшивого репо → вивід містить контекст і попередження. Попередження шукати за підрядком, який `grep` знаходить лише в гілці «предок».
  - `CLAUDE_PROJECT_DIR` = корінь репо → контекст без попередження.
  - Review Focus 5: `check` на репо зі старим `SessionStart` у `.claude/settings.json` і файлом шима → `warn`, що називає обидва шляхи. Контроль — без них цього `warn` немає.
  - Структурний тест: `hooks/hooks.json` розбирається як JSON і має обгортку `hooks.SessionStart`. Команда посилається на `${CLAUDE_PLUGIN_ROOT}/hooks/session-start.ps1`, і за токеном одразу йде `/`.
- [ ] **Step 2: Прогін — червоні.**
- [ ] **Step 3: Реалізація; `git mv` шима; правка `CLAUDE.md`.**
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Ручна перевірка на Windows (контролер, не субагент):** нова сесія в корені споживача (локальний маркетплейс — Task 13) показує «Стан сховищ» один раз.
- [ ] **Step 6: Коміт.**

### Task 9: `templates/settings.json` і запобіжник словника

Ризик: **механічна**.

**Files:**
- Modify: `templates/settings.json`, `tools/tests/Vocabulary.Tests.ps1`, `tools/tests/Templates.Tests.ps1` (якщо він перевіряє `hooks` чи перелік дозволів)

**Значення.**
- `allow` += `mcp__plugin_unica_unica__unica_run` (§3.13 п.1). `ask` лишає `unica_apply` (§4.2 п.14). Прибрати `unica_task_get`, `unica_task_result`, `unica_task_cancel` — їх немає в живому `tools/list` (§7.1 Б3). Розділ `hooks` прибрати повністю.
- Плагін не може постачати `permissions` [док: у стандартному складі плагіна немає `settings.json` з дозволами, `plugins/manifest-reference.md`], тож дозволи лишаються в шаблоні (§4.2 п.13 (б)). Причину записує Task 12 у `README.md`.
- Запобіжник словника (§8): до заборонених імен додати `unica_task_` у будь-якій формі (`unica.task.*`, `unica_task_*`). Скан і далі по `skills/`, `templates/`, текстах `tools/`. Прибрані команди kit (`canon`, `build`, `-MarkerOnly`) у запобіжник додає Task 12, коли тексти вже чисті: набір лишається зеленим після кожної задачі.
- `upgrades.md`: розділ «1.4.0 → 1.5.0» історичний. Виконавець вирішує, прибрати його (1.5.0 не випускався, переходу на нього не буває) чи вивести зі скану. Розділ «1.4.0 → 1.6.0» (Task 11) сканується.

**Антипатерн (kit-dev case 6).** Шаблон перевірки, що описує конкретні рядки тексту, а не властивість. Кожне нове заборонене ім'я перевіряється мутацією: вписати його в копію скіла — набір червоніє.

- [ ] **Step 1: Розширити запобіжник на `unica_task_`;** прогін — червоний на `templates/settings.json`.
- [ ] **Step 2: Правка `templates/settings.json`;** повний прогін — зелений.
- [ ] **Step 3: Коміт.**

### Task 10: Скіли контуру — `using-v8storagekit`, `sync`, `verify`, `reconcile`, `finish`, `provision`

Ризик: **спільний код** (тексти виконує агент споживача дослівно).

**Files:** `skills/using-v8storagekit/SKILL.md`, `skills/sync/SKILL.md`, `skills/verify/SKILL.md`, `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md`, `skills/provision/SKILL.md`

**Що має бути в текстах (кожен пункт — зі спеки):**
- `using-v8storagekit`, таблиця кроків:
  - після `sync`/`verify` — `push force:true` на зрушений набір, Уніка спитає людину, лише в інтерактивній сесії, `cancelled` — зупинка (§3.1);
  - сітка `infobase_state_unverified` → `push force:true` для названих наборів (§3.1 наслідок 3);
  - `push full:true` по набору — знання Уніки (#13, П20);
  - речення про воркспейс із заголовка виводу (§3.3 п.3);
  - попередження не виконувати пораду Уніки замінити `-text` (§3.9 п.3);
  - жодного `workspace`, `unica.task.*`, `MCP_TOOL_TIMEOUT`.
- `reconcile`, `finish`: крок «база агента — з дерева `F`» і канонізація стають одним списком «`push force:true` → `pull force:true`» з явним `sourceSet` і `extension` для розширення (§4.2 п.1, п.11). `cancelled` на `push force` — зупинка до `pull`. Обидва скіли — інтерактивні процедури (§4.2 п.2).
- Обґрунтування канонізації переписати за правилом `kit-dev` «Змінилась причина чужого кроку». Тепер це `pull force` Уніки: на чистому наборі він не питає людину, а незбережене захищає питання Уніки, тож рядок про `canon-backup` зникає. Причина «прев'ю `adopt` семантичне» лишається, бо канон і дзеркало — одна платформа (§3.2 «Виміряно А3», §3.7).
- `finish`: крок «артефакти» — `make` Уніки, без копіювання kit (§3.5 п.4). `unica.check` лишається.
- `provision`: без `-Force` і `-ServerBase New`. Зламана база → людина видаляє теку, далі крок. Серверну створює людина в кластері.
- Зупинки на кшталт «`sync`, `canon`, `verify`, `build` — зупинки їхніх скілів» — переписати.

- [ ] **Step 1: Правка текстів.**
- [ ] **Step 2: Повний прогін:** `Skills.Tests.ps1`, перевірка `${CLAUDE_PLUGIN_ROOT}` і запобіжник словника (тепер у частині цих скілів зелений).
- [ ] **Step 3: Коміт.**

### Task 11: `onboarding`, перехід «1.4.0 → 1.6.0», новий скіл про теки Уніки

Ризик: **спільний код**.

**Files:** `skills/onboarding/SKILL.md`, `skills/onboarding/references/upgrades.md`, `skills/onboarding/references/gitsync-migration.md` (якщо він називає шаблон `v8project.yaml` чи хуки), `skills/unica-folders/SKILL.md` (новий)

**Що має бути.**
- `onboarding` (§3.8 п.1, §3.3 п.4, §3.12 9а):
  - власного шаблону `v8project.yaml` немає: агент бере `setup` з `unica.view {}` і дописує лише `providers: designer` і ім'я набору розширення;
  - сесія відкривається в корені репозиторію-споживача;
  - хуків у `.claude/settings.json` скіл не пише; `install-hooks` ставить лише githooks і `settings.json`;
  - у переліку `git add` немає `.claude/hooks/session-start.ps1`.
- `upgrades.md`, розділ «1.4.0 → 1.6.0» (§9):
  - старі проєктні хуки прибрати (`kit check` їх називає);
  - `unica_task_*` прибрати з `settings.json`, `unica_run` перенести в `allow`;
  - ключі, які раннер відхиляє, прибрати (раннер сам назве ключ);
  - `infobases.origin` і `providers` — як у 1.5.0;
  - `canon`/`build` більше немає — що замість них;
  - як злити власний `CLAUDE.md` споживача з шаблоном (§5 п.4): процедура злиття, а не «скопіювати»;
  - рядок таблиці версій «1.4.0 → 1.6.0».
- `v8storagekit:unica-folders` (§3.12 9б):
  - тригери: агент збирається працювати Унікою з текою поза сесією; `unica.view {}` теки не перелічує; Уніка відмовила, бо тека поза множиною хоста;
  - зміст: причина (`INV.WORKSPACE.HOST-CONTEXT`) і три варіанти: сесія в корені потрібного репозиторію, `/add-dir`, `permissions.additionalDirectories` в особистому `.claude/settings.local.json`;
  - запис у файл — лише після явної згоди людини, через JSON-парсер, бо невалідний файл Claude Code тихо ігнорує;
  - діє з наступного виклику без перезапуску [вимір `unica_helper`, `claude -p`; в інтерактивній сесії не виміряно — у тексті так і сказати];
  - хука, що додає теки сам, немає; нагадування на старті сесії немає.
- Ім'я скіла `unica-folders` — рішення автора плану. Архітектор може замінити його до старту виконання.

- [ ] **Step 1: Тексти.**
- [ ] **Step 2: Повний прогін** (`Skills.Tests.ps1` бачить новий скіл, перевіряє префікси й токен).
- [ ] **Step 3: Коміт.**

### Task 12: Постійна документація, версія, ішуї

Ризик: **механічна** (тексти), але знайти треба всі старі формулювання.

**Files:** `CLAUDE.md`, `README.md`, `docs/storage-and-git.md`, `docs/unica-contract.md`, `docs/follow-ups.md`, `docs/text-policy.md`, `templates/CLAUDE.md`, `templates/README.md`, `templates/gitignore`/`githooks` (якщо називають `canon`/`build`), `.claude-plugin/plugin.json`

**Що змінюється.**
- Розділи з формулюванням «kit не викликає CLI раннера» переписати на «раннер — інструмент kit; kit не пише пам'ять раннера в обхід його команд» (§3.6). Місця шукати `grep -rn "CLI раннера"` по всьому дереву, а не за цим переліком. Сюди ж розділ «Зв'язок з Unica» в `CLAUDE.md` (§9).
- `docs/unica-contract.md`:
  - ціль звірки — Уніка 0.16 і раннер 0.18;
  - «серверна — завжди push force» переписати: вирівнювання завжди `push force` для будь-якої бази, канон `pull force` на серверній дозволено, рівність байтів там [гіп] (§4.2 п.12);
  - рядки контракту про `canon`, `build`, критерій, П17 — за фактами §3;
  - Уніка дописує `tools.platform.version`;
  - пам'ять раннера 0.18 — `<тека v8project.yaml>/.local/infobases/<база>/`, у `workPath` лише журнали (§4.2 п.15). Те саме переписати в `docs/storage-and-git.md`. Старий шлях `<workPath>/infobases` шукати по всьому дереву поза `docs/superpowers/`.
- `README.md`: хук у плагіні; дозволи лишаються в `templates/settings.json`, бо плагін не постачає `permissions` (§4.2 п.13 (б)), — рішення з причиною.
- `templates/CLAUDE.md`: сесія в корені репозиторію; попередження про `-text` лишається; без `canon`/`build`.
- `docs/follow-ups.md`: позиції, які закрила адаптація (#12, #25, #35 для `sync`/`verify`, ПЛ1), позначити за станом предмета (`kit-dev`: знімати з обліку за станом, а не за свіжістю). Тут же записати трек §3.10 (внесок у раннер) як відкладену роботу з причиною.
- `.claude-plugin/plugin.json`: `version` → `1.6.0`; в описі прибрати «збірка .epf».
- Ішуї — після злиття, контролер (`gh` за правилом `~/.claude/CLAUDE.md`):
  - #42 — коментар про обсяг (контекст ішуї гілки поза 1.6.0);
  - #35 — коментар «закрито для sync/verify, dump поза обсягом»;
  - #12 і #25 — закриваються посиланням на спеку й PR.

- [ ] **Step 1: Пошуки старих формулювань по всьому дереву** (`canon`, `kit build`, `CLI раннера`, `без питання людині`, `MarkerOnly`, `-ServerBase New`, `provision -Force`, `unica_task`, `session-start.ps1`). Рахувати збіги по файлах без `head`. Кожен збіг поза `docs/superpowers/` (архів спек і планів не правиться) — виправити або назвати в звіті, чому лишається.
- [ ] **Step 2: Правки.**
- [ ] **Step 3: Додати в запобіжник словника прибрані команди kit** у формі виклику — `kit.ps1" canon`, `kit.ps1" build`, `kit canon`, `kit build`, `-MarkerOnly` (§8). Мутація на копії: вписати `kit canon` у скіл — набір червоніє.
- [ ] **Step 4: Повний прогін — зелений.**
- [ ] **Step 5: Коміт.**

### Task 13: Фінал — рев'ю гілки, Integration, локальний маркетплейс

- [ ] **Step 1: Рев'ю всієї гілки** (на сильній моделі, `kit-dev`: «рев'ю контуру як цілого обов'язкове»). Питання до рев'юера:
  - чи є стан, у якому `sync` перевів версії, а кроку `push force` агент не побачив (виняток пізнішого джерела, запасний шлях, `blocked`);
  - чи лишився запуск платформи в базі агента повз `-V8Path`.
- [ ] **Step 2: Integration-прогін** — `pwsh -NoProfile -File tools/tests/Run-Tests.ps1` без `-ExcludeTag`, лише з підтвердженням людини. Тести Integration, що створюють базу через `provision -Force` чи кличуть `canon`/`build`, переписати до прогону, без втрати того, що вони доводять.
- [ ] **Step 3: Локальний маркетплейс 1.6.0 і бриф пілоту.** Пілот — окрема фаза за правилом `release-after-local-pilot`. Пункти пілоту, які вже названо:
  - процедура `upgrades.md` «1.4.0 → 1.6.0» на живому споживачі;
  - рівність байтів `pull force` на серверній базі агента (§4.2 п.12, [гіп]);
  - `CONFIGURATION` у сховищі поводиться як розширення (§4.2 п.3);
  - хук плагіна в інтерактивній сесії на Windows (Task 8, Step 5).
- [ ] **Step 4: PR у `main`** — лише після пілоту й зеленого рев'ю другої сторони (архітектор), за правилом `~/.claude/CLAUDE.md`.

---

## Трасування «пункт спеки → задача плану»

| Пункт спеки | Задача |
|---|---|
| §3.1 р.1–2, наслідки 1–6; «Виміряно А4», Б1 | 3 (код і текст кроку), 10 (скіли) |
| §3.2 р.1 (`canon` → `pull force` у скілах) | 4, 10 |
| §3.2 р.2 (захист стирання лише для `canon`) | 4 (звірка за викликами) |
| §3.2 р.3 (позначка поставки) | 4 (`supply-marker`) |
| §3.3 р.1–2 (без `workspace`) | 3 (тексти кроків), 9 (запобіжник), 10 |
| §3.3 р.3 (речення в `using`) | 10 |
| §3.3 р.4 (сесія в корені) | 11, 12 (`templates/CLAUDE.md`) |
| §3.3 р.5 (попередження хука) | 8 |
| §3.3 р.6 (kit теки хоста не розширює) | 8 (хук нічого не пише), 11 (`unica-folders` — лише за згодою) |
| §3.4 р.1–2 (серверні — людина; `New` знято) | 6, 10 |
| §3.4 р.3 (kit не видаляє) | 6 |
| §3.4 р.4 (порожня база за (i)/(ii)) | 6 |
| §3.4 р.5 (аудит бази людини) | 6 (лишається), 7 |
| §3.5 р.1–4 (`build` прибрано, `make` Уніки) | 5, 10 (`finish`) |
| §3.6 п.1 (`agent release`) | 1, 2 |
| §3.6 п.2 (раннер з установки Уніки) | 1 |
| §3.6 п.3 (інші команди — за потреби) | — (не вводяться) |
| §3.6 п.4 (платформа з `platforms`, #35) | 1, 2, 12 (коментар у #35) |
| §3.6 «оновити документацію» | 12 |
| §3.7 (дзеркало — kit на платформі раннера) | 2 |
| §3.8 р.1 (рецепт `v8project.yaml` від Уніки) | 11 |
| §3.8 р.2 (`providers: designer`) | 7, 11 |
| §3.8 р.3 (`kit check` лише те, на що спирається kit) | 7 |
| §3.9 р.1–4 (`-text`) | 10, 12 (#12) |
| §3.10 (без форку; трек upstream) | 12 (`follow-ups`) |
| §3.11 (`dump` без змін) | 2 (`dump` поза `-V8Path` раннера) |
| §3.12 9а (хук у плагіні, правило 5, старі хуки) | 8, 11 |
| §3.12 9б (скіл про теки) | 11 |
| §3.13 р.1 (`unica_run` у `allow`, `unica_apply` — `ask`) | 9 |
| §3.13 р.2–4 (хук автозгоди) | — (знято рішенням власника, Б4) |
| §4.1 р.1, р.5, §4.3 п.2/2а/3/4, П12/П23, П13, #34, П25 | переноситься без змін коду; 4/6 не чіпають цих функцій (правило звірки прибраного) |
| §4.1 р.2 (CLI раннера) | 1, 2, 12 |
| §4.1 р.3 (`canon` знято) | 4 |
| §4.1 р.4 (база — хто першим наповнює, звужено) | 6 |
| §4.1 р.6 / §4.4 п.3 (`settings.json` з іменами Б3) | 9 |
| §4.1 р.7 (серверна, пароль) | 6 (`New` знято), пароль — без змін |
| §4.1 рядки «вирівнювання», П3/П4, П17 | 3 |
| §4.1 рядки «`provision`», П7, П26, П8, П16 | 6 |
| §4.1 рядки §4.3 п.1, п.5; П9/П10/П18/П19 | 7, 11 |
| §4.1 рядки §4.4 п.1, п.5, П2 (одна функція друку) | 3 |
| §4.1 рядки §4.4 п.2 (`finish`: `unica.check`, артефакти) | 10 |
| §4.1 рядки §4.4 п.4, П11 (версії) | 7 |
| §4.1 рядок §4.5 (документація) | 12 |
| §4.1 рядок §4.6 #25 | 3, 10, 12 |
| §4.1 рядок §4.6 #13, П20 | 10 |
| §4.1 П5/П15 (позначка, рецепти) | 3 (рецепт зупинки), 4, 6 |
| §4.1 П14 (запобіжник словника) | 9 |
| §4.1 П21 (`-InstalledPluginsPath`) | 7 |
| §4.1 П24 (невидима робота) | правило звірки прибраного (`adopt`, `dump` лишають) |
| §4.1 ПЛ1, §10.4 | 12 (`follow-ups`) |
| §4.2 п.1, п.2, п.11 | 10 |
| §4.2 п.3 | 13 (пілот) |
| §4.2 п.4 | 7 |
| §4.2 п.5 | 1, 2 |
| §4.2 п.6 | 8 |
| §4.2 п.7 | 3 |
| §4.2 п.9 | 3 |
| §4.2 п.10 | 6 |
| §4.2 п.12 | 10, 12, 13 |
| §4.2 п.13 | 8 (поза обсягом), 9, 12 |
| §4.2 п.14 | 2, 4, 9 |
| §4.2 п.15 (пам'ять раннера в `.local`) | 6, 7 (аудит), 12 |
| §4.2 п.16 (дві теки в зупинці) | 6 |
| §4.2 п.17 (звичайний `push` після `infobase.create`) | 6 |
| §4.2 п.18 (рецепт поставки без `push force`) | 3 |
| §5 п.1 (довгі операції — справа Уніки) | 9 (запобіжник `unica_task_`), 10 |
| §5 п.2 (підсумок `check`) | 7 |
| §5 п.3 (код виходу `provision`) | 6 |
| §5 п.4 (злиття `CLAUDE.md`) | 11 |
| §6 Р1 | 2 (`agent release`) |
| §7.1 «Побічне» (`tools.platform.version`) | 7 |
| §8 «Видаляються» | 3, 4, 5, 6, 7 |
| §8 «Нові, лише ключові» | 2, 3, 7, 8, 9 |
| §8 «Пілот» | 13 |
| §9 (бамп, `upgrades.md`, `CLAUDE.md`) | 8, 11, 12 |
