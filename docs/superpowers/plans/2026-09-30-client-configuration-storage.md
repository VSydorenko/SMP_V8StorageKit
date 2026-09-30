# Основна конфігурація клієнта під сховищем — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kit обслуговує клієнтський воркспейс «основна конфігурація на підтримці вендора + кілька
розширень, усі під `truth: storage`»: поставка вендора (`.cf`) не потрапляє в git і не губиться
на диску, ознаки підтримки (`.bin`) лишаються в git, `sync` вивантажує розширення на свіжій
основній конфігурації, а перший запуск нового репозиторію чи свіжого клону має рецепт.

**Architecture:** один новий lib-модуль `Supply.psm1` оголошує шлях поставки і стан позначки
`.kit-bin-sha1`; наявні команди (`sync`, `verify`, `adopt`, `canon`, `check`, `provision`) беруть
звідти правило, а не пишуть свою копію. Решта — точкові зміни в `sync` (порядок, попередження,
`-MergeInto`), `check` (режим хуків з HEAD), `build` (резервна копія артефакту) і тексти скілів.
Нових ключів маніфесту немає: режим виводиться з пари `type: CONFIGURATION` + `truth: storage`.

**Tech Stack:** PowerShell 7, Pester 5, git, платформа 1С 8.3.27.x (у юніт-тестах мокується;
живий прогін — лише фінальний `Integration`, за підтвердженням користувача).

**Spec:** `docs/superpowers/specs/2026-09-30-client-configuration-storage-design.md`, редакція
коміту **`d2f8582`** (§6.3 — уточнення архітектора на питання автора плану). Архітектор рішення —
сесія `configuration-storage-spec`; уточнення до спеки — через неї, не самостійно.

**Відкрите питання (не входить у жодну задачу цього плану):** бутстрап розширення під
`truth: storage`, дерева якого ще немає (новий репозиторій над наявними сховищами розширень), —
питання 10 автора плану, передане власникові 2026-09-30. Архітектор рекомендує включити його в
обсяг зі спайком. Коли рішення прийде з хешем коміту спеки, план доповниться окремою задачею;
до того Task 10 **не** стверджує в текстах скілів, що рецепт (i) працює для розширень без
дерева.

## Global Constraints

- Мова коду, коментарів, повідомлень, комітів і документів — **українська**.
- Тести без `Integration` зелені після **кожної** задачі:
  `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  Без `-ExcludeTag Integration` не запускати — це живий `1cv8.exe`, він за підтвердженням.
- Коміт точково: `git add <явний перелік>` + `git commit --only -m "<…>" -- <ті самі шляхи>`.
  Без `-a`/`-A`. Жодних `git checkout --`, `restore`, `stash`, `clean`. Проєктні константи брифа —
  `.claude/skills/kit-dev/references/subagent-brief.md` (давати шляхом, не переказом).
- Версія — **1.3.0**, піднімається один раз, у Task 11 (`.claude-plugin/plugin.json`). Реліз і
  `git push` — лише за явним проханням користувача, у план не входять.
- **Нових ключів маніфесту немає** (спека §5.1): режим «клієнтська основна конфігурація» =
  `type: CONFIGURATION` у `v8project.yaml` + `truth: storage` у маніфесті.
- **Шлях поставки** — `Ext/ParentConfigurations/` відносно кореня дерева `CONFIGURATION`,
  оголошений **один раз** у `tools/lib/Supply.psm1` (спека §6.3.1). Жодна команда не пише цей
  літерал сама.
- **«`.bin` описує поставку»** = `Ext/ParentConfigurations.bin` існує й більший за **16 байт**
  (спека §6.3.2; 16 байт — `{6,0,0,0,1,0}` з BOM у конфігурації, знятої з підтримки).
- **Позначка** — `Ext/ParentConfigurations/.kit-bin-sha1`, вміст — SHA-1 `.bin` малими hex без
  переводу рядка; живе в ігнорованій теці, у YAML не пишеться (спека §5.1, §5.2).
- **Кожна версія сховища — повне вивантаження в спорожнену теку**; інкремент не вводити (§5.5).
- Методика — скіл `kit-dev`: `grep` перед новою перевіркою; фраза з виводу в тесті — спершу
  `grep` на унікальність по `tools/commands/` і `tools/lib/`; кожна нова перевірка
  супроводжується мутацією **на копії дерева** (вирізати рядок production → тест червоний,
  доказ — текст падіння); адресувати код іменем функції, не номером рядка.
- **Кожна нова експортована функція lib-модуля дописується в `$RequiredCommands`**
  (`tools/tests/ModuleImportOrder.Tests.ps1`). У цьому плані — вісім функцій `Supply.psm1`
  (Task 1).
- Фікстури, де команда пише в `build/`, беруть `-WithGitignore` (інакше `git status --porcelain`
  падає на робочому смітті самої команди).

## Review Focus

Вхідні форми, які спека має на увазі, але жоден сценарій спеки прямо не проганяє, — найімовірніші
першими. Для кожної тест додано в задачу, що володіє кодом.

1. **Старий репозиторій споживача (до 1.3.0) без рядка `**/Ext/ParentConfigurations/` у
   `.gitignore`.** `adopt -Apply` робить `git add -A -- <шлях джерела>` — без рядка ігнору
   `.cf` на сотні МБ застейджився б і пішов у коміт. Очікування: `adopt` ніколи не стейджить теку
   поставки, незалежно від `.gitignore` (pathspec `:(exclude)`). Тест — Task 4.
2. **Конфігурація, знята з підтримки (`.bin` рівно 16 байт), або без `.bin` узагалі.** Уся логіка
   поставки мусить мовчати: `check` без знахідок, `canon` без позначки, стан `none`. Тести —
   Task 1 (стан), Task 5 (`canon`), Task 6 (`check`).
3. **Тека поставки є, але `.cf` у ній немає (лише позначка) або `.cf` кілька.** Стан — `missing`,
   якщо жодного `*.cf`; кілька `.cf` не аномалія (позначка одна на `.bin`). Тест — Task 1.
4. **CONFIGURATION записано в маніфесті ПІСЛЯ розширень, і воркспейсів два.** Порядок `sync` —
   CONFIGURATION першим **усередині** воркспейсу, порядок воркспейсів і розширень між собою —
   маніфестний. Тест — Task 3 (фікстура навмисно ставить `base` другим).
5. **`-MergeInto` у гілку, де немає маніфесту (gitsync-`master`), або в неіснуючу гілку.**
   Очікування: злиття не відбувається, дзеркало лишається оновленим, код 2, текст із причиною;
   цільова гілка не зрушила. Тест — Task 3.

---

## Як виконувати цей план

Методика — `v8storagekit-agent-contour-plans` і скіл `kit-dev`, розділ «Пишу бриф субагенту»:

- Рядок `**Ризик:**` у кожній задачі визначає рев'ю: `механічна` — одне рев'ю на дешевій моделі
  (лише guard-умови); `спільний код` — одне на сильній; `властивість безпеки` — два, друге вузьке
  (лише названа властивість). За замовчуванням — одне рев'ю.
- Код у плані — **ескіз, не транскрипція**: рев'ю ставиться до нього як до свіжого коду виконавця.
  Якщо дослівний текст не працює — виправити мінімально й назвати в сумнівах із доказом.
- Текст задачі **заморожений** на час її виконання; правки спеки від архітектора з позначкою
  «хвіст» вкладаються на межі задач, «блокує» — зупинка задачі з поясненням.
- `Integration` — **один** прогін на блок, у Task 11, за підтвердженням користувача. Крок із
  дозволом користувача в бриф субагенту не потрапляє — його виконує контролер.
- Задачі йдуть по черзі (Task 1 дає модуль і фікстуру всім наступним). Паралельних
  імплементаторів немає: дерево спільне.

---

## File Structure

| Файл | Відповідальність | Що робимо |
|---|---|---|
| `tools/lib/Supply.psm1` | правило поставки вендора: шлях, «описує поставку», позначка, стан, рецепт | **створити** (Task 1) |
| `tools/lib/module-order.txt` | порядок імпорту | + `Supply` після `PathSafety`, до `StorageBranch` (Task 1) |
| `templates/gitignore` | політика git споживача | + `**/Ext/ParentConfigurations/` (Task 1) |
| `tools/tests/fixtures/KitFixtures.psm1` | синтетичний репозиторій | `Truth` на рівні source-set, `-WithSupply`, `New-KitClientWorkspaces` (Task 1) |
| `tools/lib/StorageBranch.psm1` | запис версії в дзеркало | `Write-KitStorageVersion` прибирає теку поставки (Task 2) |
| `tools/commands/sync.psm1` | реплей сховищ | порядок CONFIGURATION першим, попередження, `-MergeInto` + запобіжник (Task 3) |
| `tools/lib/TreeCompare.psm1` | порівняння дамп ↔ дерево | `Get-KitRelativeFiles` пропускає теку поставки (Task 4) |
| `tools/commands/adopt.psm1` | прийняття дзеркала в гілку | стирання крім поставки, копія пофайлово, `add` з `:(exclude)` (Task 4) |
| `tools/commands/canon.psm1` | канонізація | позначка `.kit-bin-sha1` після дампу CONFIGURATION (Task 5) |
| `tools/commands/check.psm1` | інваріанти | ігнор поставки в обидва боки, `.cf` не в індексі, стан поставки (Task 6) |
| `tools/lib/Hooks.psm1` | аудит хуків | режим `.githooks/*` з HEAD (Task 7, #16) |
| `tools/commands/provision.psm1` | база агента | порожня база законна для CONFIGURATION під `truth: storage`; стан поставки (Task 8) |
| `tools/commands/build.psm1` | артефакти | резервна копія наявного `.cf`/`.cfe` як `<Ім'я>_<sha8>.<ext>` (Task 9, #18) |
| `skills/onboarding/SKILL.md`, `references/gitsync-migration.md` | підключення | `-MergeInto` (Task 3); §3.6 хуки з HEAD (Task 7); три вихідні стани, база агента вже є (Task 10) |
| `skills/provision/SKILL.md` | база агента | рецепти (ii)/(iii), наявна серверна база, `operation=build` без `sourceSet` (Task 10) |
| `skills/finish/SKILL.md`, `skills/using-v8storagekit/SKILL.md`, `templates/CLAUDE.md` | процедури й шаблон | `.cf` поруч із `.cfe`, «порівняти й об'єднати»; #17 (Task 10) |
| `docs/unica-contract.md` | контракт з Унікою | #13 — провал часткового завантаження непомітний (Task 10) |
| `docs/storage-and-git.md` | архітектура контуру | поставка, порядок `sync`, `-MergeInto`, повний дамп як інваріант (Task 11) |
| `skills/onboarding/references/upgrades.md` | кроки оновлення | рядок і розділ `1.2.0 → 1.3.0` (Task 11) |
| `.claude-plugin/plugin.json` | версія | 1.3.0 (Task 11) |

**Урок C1, що діє й тут:** у переліку файлів задачі — не лише те, що змінюється, а й те, що про
змінюване розповідає. Задачі, що змінюють картину контуру, називають свій розділ
`docs/storage-and-git.md` у Task 11 явним пунктом; Task 11 відповідає за всі.

---

### Task 1: модуль `Supply.psm1`, рядок ігнору, фікстура клієнтського воркспейсу

**Ризик:** спільний код (одне рев'ю на сильній моделі).

**Files:**
- Create: `tools/lib/Supply.psm1`
- Modify: `tools/lib/module-order.txt` (+ `Supply` одразу після `PathSafety`; дописати причину в шапку-коментар, як для інших модулів)
- Modify: `templates/gitignore` (розділ «Побічні файли платформи» або новий розділ «Поставка вендора»)
- Modify: `templates/README.md` (рядок таблиці про `gitignore` — згадати поставку)
- Modify: `tools/tests/fixtures/KitFixtures.psm1` (`New-KitFakeRepo`: ключ `Truth` на source-set, перемикач `-WithSupply`; нова `New-KitClientWorkspaces`)
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` (`$RequiredCommands`)
- Test: `tools/tests/Supply.Tests.ps1` (створити), `tools/tests/Templates.Tests.ps1`, `tools/tests/KitFixtures.Tests.ps1`

**Interfaces:**
- Consumes: `Assert-SafeWorkPath -Path -MustBeUnder -Description` (`PathSafety.psm1`).
- Produces (усі експортовані):
  - `Get-KitSupplyRelativePath` → `[string] 'Ext/ParentConfigurations'`
  - `Test-KitSupplyRelativePath -RelativePath <string>` → `[bool]` — шлях відносно кореня дерева
    (`/` або `\`) дорівнює теці поставки або лежить під нею; порівняння `OrdinalIgnoreCase`.
  - `Test-KitSupplyDescribed -TreeRoot <string>` → `[bool]` — `.bin` існує й > 16 байт.
  - `Get-KitSupplyState -TreeRoot <string>` → `'none' | 'current' | 'stale' | 'missing'`
  - `Write-KitSupplyMarker -TreeRoot <string>` → `[string]` SHA-1 або `$null` (не описує
    поставку чи `.cf` немає — нічого не пише).
  - `Remove-KitSupplyDir -TreeRoot <string> -MustBeUnder <string>` → нічого; прибирає теку
    поставки, якщо є.
  - `Clear-KitTreeExceptSupply -TreeRoot <string> -MustBeUnder <string>` → нічого; стирає вміст
    дерева, крім теки поставки (сама тека `Ext` лишається, якщо в ній поставка).
  - `Get-KitSupplyRecipe -SourceKey <string> -MainBranch <string> -State <string>` → `[string]` —
    текст рецепта (ii)/(iii) для `check` і `provision` (одне джерело тексту).
  - Фікстура: `New-KitFakeRepo … -WithSupply`; ключ `Truth = 'storage'` у хеші source-set;
    `New-KitClientWorkspaces` → `[ordered]` словник для `-Workspaces`.

**Чому окремий модуль, а не «поруч із `PlatformJunk`»:** `PlatformJunk` оголошено тричі, а
`StorageBranch` (перший споживач) вантажиться раніше за обидва модулі з ним (спека §6.3.1).
Зведення потрійного `PlatformJunk` — поза обсягом, не чіпати.

- [ ] **Step 1: Тести модуля**

Створити `tools/tests/Supply.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Supply.psm1 — поставка вендора основної конфігурації' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Supply.psm1").Path -Force

        # Дерево CONFIGURATION: $BinBytes — розмір .bin (0 — файла немає), $Cf — імена .cf у теці поставки.
        function script:New-SupplyTree {
            param([string]$Name, [int]$BinBytes = 32, [string[]]$Cf = @('Vendor.cf'), [string]$Marker)
            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $root 'Ext') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Configuration.xml') -Value '<x/>' -Encoding UTF8
            if ($BinBytes -gt 0) {
                [System.IO.File]::WriteAllBytes((Join-Path $root 'Ext/ParentConfigurations.bin'), [byte[]](1..$BinBytes | ForEach-Object { $_ % 250 }))
            }
            if ($Cf.Count -gt 0 -or $Marker) { New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null }
            foreach ($c in $Cf) { Set-Content -LiteralPath (Join-Path $root "Ext/ParentConfigurations/$c") -Value 'cf' -Encoding ascii }
            if ($Marker) { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), $Marker) }
            $root
        }
    }

    It 'шлях поставки — одне оголошення' {
        Get-KitSupplyRelativePath | Should -BeExactly 'Ext/ParentConfigurations'
    }

    It 'Test-KitSupplyRelativePath: тека, вкладений файл, обидва роздільники; .bin і сусіди — ні' {
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations/BASSmallBusiness.cf' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext\ParentConfigurations\X.cf' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations.bin' | Should -BeFalse
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurationsX/a.cf' | Should -BeFalse
        Test-KitSupplyRelativePath -RelativePath 'Catalogs/Ext/ParentConfigurations/a.cf' | Should -BeFalse
    }

    It '.bin рівно 16 байт (знята з підтримки) — поставку не описує, стан none' {
        $t = New-SupplyTree -Name 'bin16' -BinBytes 16 -Cf @()
        Test-KitSupplyDescribed -TreeRoot $t | Should -BeFalse
        Get-KitSupplyState -TreeRoot $t | Should -Be 'none'
    }

    It '.bin немає взагалі — стан none' {
        $t = New-SupplyTree -Name 'nobin' -BinBytes 0 -Cf @()
        Get-KitSupplyState -TreeRoot $t | Should -Be 'none'
    }

    It '.bin 17 байт — поставку описує (межа не 16-включно)' {
        $t = New-SupplyTree -Name 'bin17' -BinBytes 17 -Cf @()
        Test-KitSupplyDescribed -TreeRoot $t | Should -BeTrue
    }

    It 'описує поставку, .cf немає — missing' {
        $t = New-SupplyTree -Name 'nocf' -Cf @()
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It 'є лише позначка, .cf немає — missing (позначка без .cf нічого не доводить)' {
        $t = New-SupplyTree -Name 'marker-only' -Cf @() -Marker 'abc'
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It '.cf є, позначки немає — missing' {
        $t = New-SupplyTree -Name 'nomarker'
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It 'Write-KitSupplyMarker пише SHA-1 .bin; стан стає current; кілька .cf — не аномалія' {
        $t = New-SupplyTree -Name 'write' -Cf @('A.cf', 'B.cf')
        $sha = Write-KitSupplyMarker -TreeRoot $t
        $sha | Should -Match '^[0-9a-f]{40}$'
        $expected = (Get-FileHash -LiteralPath (Join-Path $t 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        $sha | Should -Be $expected
        [System.IO.File]::ReadAllText((Join-Path $t 'Ext/ParentConfigurations/.kit-bin-sha1')) | Should -BeExactly $expected
        Get-KitSupplyState -TreeRoot $t | Should -Be 'current'
    }

    It 'підмінений .bin після позначки — stale' {
        $t = New-SupplyTree -Name 'stale'
        $null = Write-KitSupplyMarker -TreeRoot $t
        [System.IO.File]::WriteAllBytes((Join-Path $t 'Ext/ParentConfigurations.bin'), [byte[]](1..40))
        Get-KitSupplyState -TreeRoot $t | Should -Be 'stale'
    }

    It 'Write-KitSupplyMarker не пише нічого, коли .bin не описує поставку' {
        $t = New-SupplyTree -Name 'nowrite16' -BinBytes 16 -Cf @('A.cf')
        Write-KitSupplyMarker -TreeRoot $t | Should -BeNullOrEmpty
        Join-Path $t 'Ext/ParentConfigurations/.kit-bin-sha1' | Should -Not -Exist
    }

    It 'Remove-KitSupplyDir прибирає теку поставки, .bin лишає' {
        $t = New-SupplyTree -Name 'remove'
        Remove-KitSupplyDir -TreeRoot $t -MustBeUnder $TestDrive
        Join-Path $t 'Ext/ParentConfigurations' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations.bin' | Should -Exist
    }

    It 'Clear-KitTreeExceptSupply стирає все, крім теки поставки' {
        $t = New-SupplyTree -Name 'clear'
        Set-Content -LiteralPath (Join-Path $t 'Ext/Other.xml') -Value 'x' -Encoding UTF8
        Clear-KitTreeExceptSupply -TreeRoot $t -MustBeUnder $TestDrive
        Join-Path $t 'Configuration.xml' | Should -Not -Exist
        Join-Path $t 'Ext/Other.xml' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations.bin' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }

    It 'Clear-KitTreeExceptSupply поза межею — зупинка' {
        $t = New-SupplyTree -Name 'outside'
        { Clear-KitTreeExceptSupply -TreeRoot $t -MustBeUnder (Join-Path $TestDrive 'elsewhere') } | Should -Throw
        Join-Path $t 'Configuration.xml' | Should -Exist
    }

    It 'рецепт (ii)/(iii) називає головну гілку, verify, canon і operation=build' {
        $r = Get-KitSupplyRecipe -SourceKey 'base' -MainBranch 'main' -State 'stale'
        $r | Should -BeLike '*main*'
        $r | Should -BeLike '*kit verify -Source base*'
        $r | Should -BeLike '*kit canon -Source base -Apply*'
        $r | Should -BeLike '*operation=build*'
    }
}
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL у `Supply.Tests.ps1` — модуля `Supply.psm1` немає.

- [ ] **Step 3: Модуль**

Створити `tools/lib/Supply.psm1`:

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

# Поставка вендора основної конфігурації на підтримці (спека 2026-09-30 §5.2, §6.3.1). ЄДИНЕ
# оголошення шляху: sync, verify, adopt, canon, check і provision беруть його звідси. Шлях —
# відносно кореня дерева CONFIGURATION. У теці лежить <Ім'я>.cf поставки (0,5–1,1 ГБ — за межею
# 100 МБ на файл GitHub, тому поза git) і позначка .kit-bin-sha1 (стан машини, §5.1).
# Ext/ParentConfigurations.bin — ознаки підтримки (замки об'єктів) — ЛИШАЄТЬСЯ в git.
$script:SupplyRelativePath = 'Ext/ParentConfigurations'
$script:SupplyBinRelativePath = 'Ext/ParentConfigurations.bin'
$script:SupplyMarkerName = '.kit-bin-sha1'
# «.bin описує поставку» = файл більший за 16 байт (спека §6.3.2). Умова виміру: у знятих з
# підтримки конфігураціях (SMP_SMB_ukr_DEV, SMP_SMB_rus_DEV, 2026-09-30) файл рівно 16 байт —
# {6,0,0,0,1,0} з BOM. Ім'я .cf усередині .bin не розбираємо: формат не наш.
$script:SupplyEmptyBinBytes = 16

function Get-KitSupplyRelativePath { $script:SupplyRelativePath }

function Test-KitSupplyRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath)
    $rel = ($RelativePath -replace '\\', '/').TrimStart('/')
    # OrdinalIgnoreCase: NTFS і git з core.ignorecase=true на Windows не розрізняють регістр
    # цього шляху, і правило ігнору в .gitignore спрацює на будь-якому регістрі.
    $rel.Equals($script:SupplyRelativePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $rel.StartsWith("$script:SupplyRelativePath/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-KitSupplyDescribed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    $bin = Join-Path $TreeRoot $script:SupplyBinRelativePath
    (Test-Path -LiteralPath $bin -PathType Leaf) -and ((Get-Item -LiteralPath $bin).Length -gt $script:SupplyEmptyBinBytes)
}

function Get-KitSupplyBinSha1 {
    param([Parameter(Mandatory)][string]$TreeRoot)
    (Get-FileHash -LiteralPath (Join-Path $TreeRoot $script:SupplyBinRelativePath) -Algorithm SHA1).Hash.ToLowerInvariant()
}

function Get-KitSupplyState {
    <#
    .SYNOPSIS
        Стан поставки на цій машині (спека §5.2): none — .bin поставки не описує, правило не
        діє; current — позначка = SHA-1 поточного .bin; stale — позначка ≠ SHA-1; missing — .bin
        описує поставку, а .cf чи позначки немає.
    .DESCRIPTION
        Хибна тривога stale можлива й прийнята свідомо (§5.2): .bin змінюється й тоді, коли
        людина лише перевела об'єкт у редаговані. Перевідновити дешевше, ніж пропустити пару
        «новий .bin + старий .cf», яку платформа завантажить без відмови.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    if (-not (Test-KitSupplyDescribed -TreeRoot $TreeRoot)) { return 'none' }
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    $cf = @(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue)
    $marker = Join-Path $dir $script:SupplyMarkerName
    if ($cf.Count -eq 0 -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) { return 'missing' }
    $recorded = ([System.IO.File]::ReadAllText($marker)).Trim()
    if ($recorded -eq (Get-KitSupplyBinSha1 -TreeRoot $TreeRoot)) { 'current' } else { 'stale' }
}

function Write-KitSupplyMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    if (-not (Test-KitSupplyDescribed -TreeRoot $TreeRoot)) { return $null }
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    if (@(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue).Count -eq 0) { return $null }
    $sha = Get-KitSupplyBinSha1 -TreeRoot $TreeRoot
    # Без BOM і без переводу рядка: читається порівнянням рядків, а не редактором.
    [System.IO.File]::WriteAllText((Join-Path $dir $script:SupplyMarkerName), $sha)
    $sha
}

function Remove-KitSupplyDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder)
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Assert-SafeWorkPath -Path $dir -MustBeUnder $MustBeUnder -Description 'тека поставки вендора'
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Clear-KitTreeExceptSupply {
    <#
    .SYNOPSIS
        Стирає вміст дерева джерела, крім теки поставки (adopt, спека §5.2): у дзеркалі .cf
        немає, і повне стирання лишило б .bin без .cf — наступне повне завантаження впало б
        (спайк §4.2, варіант B).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder)
    Assert-SafeWorkPath -Path $TreeRoot -MustBeUnder $MustBeUnder -Description 'дерево джерела'
    if (-not (Test-Path -LiteralPath $TreeRoot)) { New-Item -ItemType Directory -Path $TreeRoot -Force | Out-Null; return }
    $parts = $script:SupplyRelativePath -split '/'   # 'Ext', 'ParentConfigurations'
    foreach ($item in @(Get-ChildItem -LiteralPath $TreeRoot -Force)) {
        if ($item.PSIsContainer -and $item.Name -ieq $parts[0]) {
            foreach ($inner in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                if ($inner.PSIsContainer -and $inner.Name -ieq $parts[1]) { continue }
                Remove-Item -LiteralPath $inner.FullName -Recurse -Force
            }
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function Get-KitSupplyRecipe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceKey, [Parameter(Mandatory)][string]$MainBranch, [Parameter(Mandatory)][string]$State)
    $what = if ($State -eq 'stale') {
        'поставка вендора застаріла: позначка .kit-bin-sha1 не збігається з поточним Ext/ParentConfigurations.bin (оновився реліз вендора або об''єкти переведено в редаговані — друге дає зайве, але безпечне відновлення)'
    } else {
        'поставка вендора відсутня: Ext/ParentConfigurations.bin описує поставку, а .cf чи позначки .kit-bin-sha1 на цій машині немає — повне завантаження в базу впаде'
    }
    "$what. Відновлення — лише на гілці ${MainBranch}, не на гілці задачі (canon переписує все дерево): " +
    "база агента є (інакше kit provision) → kit verify -Source $SourceKey (очікувано equal — він наповнює базу версією з дерева) → " +
    "kit canon -Source $SourceKey -Apply (вивантажує .cf і пише позначку) → operation=build Уніки. Ніколи canon на порожній базі: порожній дамп стирає дерево."
}

Export-ModuleMember -Function Get-KitSupplyRelativePath, Test-KitSupplyRelativePath, Test-KitSupplyDescribed, Get-KitSupplyState, Write-KitSupplyMarker, Remove-KitSupplyDir, Clear-KitTreeExceptSupply, Get-KitSupplyRecipe
```

Дописати `Supply` у `tools/lib/module-order.txt` одразу після `PathSafety` і в шапку-коментар:
`Supply — після PathSafety (Assert-SafeWorkPath) і до StorageBranch/TreeCompare, які беруть з нього
шлях поставки (спека 2026-09-30 §6.3.1).` Дописати всі вісім експортів у `$RequiredCommands`.

- [ ] **Step 4: Прогнати — має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, включно з `ModuleImportOrder.Tests.ps1`.

- [ ] **Step 5: Рядок ігнору в шаблоні — тест і правка**

У `tools/tests/Templates.Tests.ps1` поруч із наявними тестами `gitignore`:

```powershell
    It 'шаблон gitignore ігнорує поставку вендора, але не .bin ознак підтримки (спека 2026-09-30 §5.2)' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Encoding UTF8 | ForEach-Object { $_.Trim() })
        $lines | Should -Contain '**/Ext/ParentConfigurations/'
        # Форма «тека» (скісна риска в кінці) — контракт: правило без '/' ловило б і файл з тим
        # самим іменем, а форма з '*' — ще й Ext/ParentConfigurations.bin, який мусить бути в git.
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations'
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations*'
    }
```

Прогнати — FAIL. Дописати в `templates/gitignore`:

```gitignore
# Поставка вендора основної конфігурації на підтримці (.cf, 0,5–1,1 ГБ — поза лімітом 100 МБ на
# файл GitHub) і позначка актуальності .kit-bin-sha1 — стан машини, не репозиторію. Ознаки
# підтримки Ext/ParentConfigurations.bin ЛИШАЮТЬСЯ в git: без них губляться замки об'єктів.
# Для розширень і конфігурацій без підтримки теки немає — рядок ні на що не діє.
# Відновлення .cf на новій машині — kit canon з бази агента (скіл v8storagekit:provision).
**/Ext/ParentConfigurations/
```

У `templates/README.md` у рядок таблиці про `gitignore` додати «+ `**/Ext/ParentConfigurations/`
(поставка вендора поза git)». Прогнати — PASS.

- [ ] **Step 6: Фікстура клієнтського воркспейсу — тест**

У `tools/tests/KitFixtures.Tests.ps1`:

```powershell
    It 'клієнтський воркспейс: CONFIGURATION + два EXTENSION під truth: storage, base не першим у маніфесті' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'client') -Workspaces (New-KitClientWorkspaces) -WithGitignore -WithSupply
        $m = Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw
        $m | Should -Not -Match 'truth: vendor'
        ([regex]::Matches($m, 'truth: storage')).Count | Should -Be 3
        $m.IndexOf('ExtA:') | Should -BeLessThan $m.IndexOf('base:')
        # .bin — у git, .cf і позначка — на диску, поза git (як на машині після canon).
        $cfg = 'Client_UNF/cf/src'
        @(git -C $repo ls-files -- "$cfg/Ext/ParentConfigurations.bin").Count | Should -Be 1
        @(git -C $repo ls-files -- "$cfg/Ext/ParentConfigurations").Count | Should -Be 0
        Join-Path $repo "$cfg/Ext/ParentConfigurations/Vendor.cf" | Should -Exist
        Join-Path $repo "$cfg/Ext/ParentConfigurations/.kit-bin-sha1" | Should -Exist
        Join-Path $repo 'Client_UNF/cfe/Доработки/src/Configuration.xml' | Should -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }
```

Прогнати — FAIL (`New-KitClientWorkspaces` не існує).

- [ ] **Step 7: Фікстура — реалізація**

У `KitFixtures.psm1`:

1. `New-KitFakeRepo`: новий `[switch]$WithSupply`. У циклі по source-set: `$truth = if ($set.Contains('Truth')) { $set.Truth } elseif ($set.Type -eq 'CONFIGURATION') { 'vendor' } else { 'storage' }` (для `EXTERNAL_DATA_PROCESSORS` лишається `git`, як зараз). Гілка `'CONFIGURATION'`:
   - `vendor` — як зараз;
   - `storage` — дерево (лише без `-NoSourceTrees`, як для EXTENSION) отримує `Configuration.xml` (`New-KitFakeConfigurationXml -Name $set.Name`), маніфест — блок `truth: storage` + `storage: { path: '<неіснуючий>' }` тим самим прийомом, що для EXTENSION; якщо `-WithSupply` — `Ext/ParentConfigurations.bin` на 32 байти **до** коміту.
2. Рядки ігнору vendor у `-WithGitignore` — лише для CONFIGURATION з `vendor` (зараз — для кожного CONFIGURATION; після зміни `storage`-дерево помилково ігнорувалось би).
2а. `-WithGitattributes`: шаблон `templates/gitattributes` знає лише маски `**/cfe/src/**` і `**/epf/src/**`; для кожного source-set у git (CONFIGURATION не-`vendor`, EXTENSION), чий `Path` не `cfe/src`, дописати рядок `<ws>/<path>/** -text` — рівно те, що дописав би `onboarding` §3.4. Без цього `check` на клієнтській фікстурі дає `error gitattributes` на `cf/src` і `cfe/<Ім'я>/src`, і будь-яка асерція коду виходу `check` там перевіряла б не те.
2б. `Add-KitFakeStorageCommit`: перед `Set-Content` створювати батьківську теку файлу (`Split-Path -Parent`) — щоб `-FileName 'Ext/ParentConfigurations.bin'` працював (зараз створюється лише тека джерела).
3. **Після** першого коміту (поза `if (-not $NoCommit)`, але після нього), якщо `-WithSupply`: для кожного CONFIGURATION під `storage` покласти `Ext/ParentConfigurations/Vendor.cf` і позначку з SHA-1 `.bin` (через `Get-FileHash … SHA1`, малими, `WriteAllText` без BOM) — **без** `Import-Module Supply.psm1` (пастка вкладеного імпорту — див. великий коментар у `New-KitFakeRepo` про `Preflight.psm1`). Коментар: чому після коміту — так виглядає машина після `canon`: `.cf` на диску, поза git, незалежно від `.gitignore`.
4. Нова експортована `New-KitClientWorkspaces`:

```powershell
function New-KitClientWorkspaces {
    <#
    .SYNOPSIS
        Клієнтський воркспейс (спека 2026-09-30 §1, §7): основна конфігурація + ДВА розширення,
        усі під truth: storage. base навмисно ДРУГИМ — порядок sync (§5.4) мусить не залежати від
        порядку маніфесту. Друге розширення з кирилицею в імені — шляхи cfe/<Ім'я>/src.
    #>
    [ordered]@{
        'Client_UNF' = @{
            Infobase = 'File=build/ib'
            Sets     = @(
                @{ Name = 'ExtA';      Type = 'EXTENSION';     Path = 'cfe/ExtA/src' }
                @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
                @{ Name = 'Доработки'; Type = 'EXTENSION';     Path = 'cfe/Доработки/src' }
            )
        }
    }
}
```

Додати `New-KitClientWorkspaces` до `Export-ModuleMember` фікстури. Прогнати повний набір — PASS.
Якщо зміна п. 2 зачепила наявні тести (vendor-рядки) — розібратись, не підганяти: наявні
фікстури мають лише `vendor`-CONFIGURATION, поведінка для них не змінюється.

- [ ] **Step 8: Мутація (на копії дерева)**

На копії робочого дерева (не в самому дереві — kit-dev, case 7): змінити
`$script:SupplyEmptyBinBytes = 16` на `15` — тест «.bin рівно 16 байт» мусить почервоніти;
видалити рядок у `templates/gitignore` — тест шаблону мусить почервоніти. Тексти падінь — у звіт.

- [ ] **Step 9: Коміт**

```bash
git add tools/lib/Supply.psm1 tools/lib/module-order.txt templates/gitignore templates/README.md tools/tests/fixtures/KitFixtures.psm1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/Supply.Tests.ps1 tools/tests/Templates.Tests.ps1 tools/tests/KitFixtures.Tests.ps1
git commit --only -m "Supply.psm1: шлях поставки вендора, позначка .kit-bin-sha1; фікстура клієнтського воркспейсу" -- tools/lib/Supply.psm1 tools/lib/module-order.txt templates/gitignore templates/README.md tools/tests/fixtures/KitFixtures.psm1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/Supply.Tests.ps1 tools/tests/Templates.Tests.ps1 tools/tests/KitFixtures.Tests.ps1
```

---

### Task 2: дзеркало `storage/*` без поставки

**Ризик:** властивість безпеки (два рев'ю; друге вузьке — «чи може `.cf` потрапити в коміт
дзеркала хоч одним шляхом»). Дефект `main` 1 зі спеки §5.2: `.cf` у коміті `storage/<ключ>` →
`git push` на GitHub відмовить.

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` (`Write-KitStorageVersion`; `Import-Module "$PSScriptRoot/Supply.psm1"` у шапці, без `-Force`, як інші вкладені імпорти)
- Test: `tools/tests/StorageBranch.Tests.ps1`

**Interfaces:**
- Consumes: `Remove-KitSupplyDir -TreeRoot -MustBeUnder` (Task 1); `New-KitStorageWorktree`,
  `Write-KitStorageVersion` (наявні).
- Produces: інваріант «жоден коміт `storage/*` не містить `Ext/ParentConfigurations/`».

- [ ] **Step 1: Тест**

У `StorageBranch.Tests.ps1`, поруч із наявними тестами `Write-KitStorageVersion` (взяти за зразок
їхню підготовку worktree — тест із `-RepoPath 'Alpha_SMB/cfe/src'`):

```powershell
    It 'Write-KitStorageVersion: .bin іде в дзеркало, тека поставки (.cf, позначка) — ні (спека 2026-09-30 §5.2)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mirror-supply') -Workspaces (New-KitClientWorkspaces)
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/base' -Path (Join-Path $repo 'build/sync/base/wt')
        $src = Join-Path $wt.Path 'Client_UNF/cf/src'
        New-Item -ItemType Directory -Path (Join-Path $src 'Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Configuration.xml') -Value '<x/>' -Encoding UTF8
        [System.IO.File]::WriteAllBytes((Join-Path $src 'Ext/ParentConfigurations.bin'), [byte[]](1..32))
        Set-Content -LiteralPath (Join-Path $src 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $src 'Ext/ParentConfigurations/.kit-bin-sha1') -Value 'abc' -Encoding ascii
        try {
            $null = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Client_UNF/cf/src' `
                -Message "v1`n`nStorage-Source: base`nStorage-Version: 1" -AuthorName 'Test Bot' `
                -AuthorEmail 'test@example.invalid' -Timestamp ([datetime]'2026-01-01T09:00:00')
        } finally {
            Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        }
        $files = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only storage/base)
        $files | Should -Contain 'Client_UNF/cf/src/Ext/ParentConfigurations.bin'
        @($files | Where-Object { $_ -like 'Client_UNF/cf/src/Ext/ParentConfigurations/*' }).Count | Should -Be 0
    }
```

Імпорти в `BeforeAll` файлу: якщо файл вантажить модулі поштучно, додати `Supply.psm1` перед
`StorageBranch.psm1`, а `KitFixtures.psm1` — якщо його ще немає.

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — `ls-tree` показує `Vendor.cf` і `.kit-bin-sha1`.

- [ ] **Step 3: Реалізація**

У `Write-KitStorageVersion` одразу після циклу по `ConfigDumpInfo.xml`/`DumpFilesIndex.txt`:

```powershell
    # Поставка вендора (спека 2026-09-30 §5.2): у worktree дзеркала немає .gitignore, і
    # `git add -A` нижче забрав би .cf на 0,5–1,1 ГБ у коміт storage/<ключ> — push на GitHub
    # відмовить (ліміт 100 МБ на файл). У дзеркалі лишається лише .bin (ознаки підтримки).
    # Для розширень і конфігурацій без підтримки теки немає — виклик нічого не робить.
    Remove-KitSupplyDir -TreeRoot $target -MustBeUnder $WorktreePath
```

У `.DESCRIPTION` функції дописати речення про поставку поруч із реченням про службові файли.

- [ ] **Step 4: Прогнати — має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration` — PASS.

- [ ] **Step 5: Мутація (на копії дерева)**

Вирізати рядок `Remove-KitSupplyDir …` з копії `StorageBranch.psm1` — тест мусить почервоніти
текстом про `Vendor.cf` (спека §7 називає саме цю мутацію). Текст падіння — у звіт.

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1
git commit --only -m "sync: дзеркало storage/* без поставки вендора (.bin лишається)" -- tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1
```

---

### Task 3: `sync` — CONFIGURATION першим, попередження, `-MergeInto` із запобіжником (#15)

**Ризик:** спільний код (одне рев'ю на сильній моделі).

**Files:**
- Modify: `tools/commands/sync.psm1` (`Invoke-KitSync`, `Invoke-KitMainMerge`; нова приватна `Sort-KitSyncSources`)
- Modify: `skills/sync/SKILL.md` (параметр `-MergeInto`, попередження)
- Modify: `skills/onboarding/SKILL.md` (онбординг на гілці з PR — `-MergeInto`), `skills/onboarding/references/gitsync-migration.md` (крок 4)
- Test: `tools/tests/Sync.Order.Tests.ps1` (створити), `tools/tests/Sync.Merge.Tests.ps1`

**Interfaces:**
- Consumes: `New-KitClientWorkspaces`, `New-KitFakeRepo -WithAgentBase` (Task 1);
  `Test-KitBranchMergedInto`, `Merge-KitBranchInto` (`GitMerge.psm1`), `Test-KitBranchExists`.
- Produces: `Invoke-KitSync … [-MergeInto <string>]`; `Invoke-KitMainMerge -Context -Source -Into`
  (новий обов'язковий `-Into`). Код виходу 2 при відмові запобіжника — той самий, що при провалі злиття.

**Контракт (спека §5.4, §6.3.4):**
- Усередині кожного воркспейсу — спершу джерела `CONFIGURATION`, далі решта в маніфестному
  порядку; порядок воркспейсів — маніфестний. Сортування — стабільне, явним циклом, не
  `Sort-Object` (його стабільність і культура — зайве питання для рев'ю).
- Попередження — коли у вибірці є `EXTENSION` воркспейсу, в якому є `CONFIGURATION` під
  `truth: storage`, а сам він у вибірку **не** потрапив. Не зупинка. Друкується один раз на
  воркспейс, до першого джерела цього воркспейсу.
- `-MergeInto <гілка>` — куди робити перше злиття й злиття `-MergeMain`; типово
  `$Context.MainBranch`.
- Запобіжник: дзеркало ще не злите в цільову гілку (`Test-KitBranchMergedInto` = `$false`), а в
  цільовій гілці немає `v8storagekit.yaml` → злиття не виконується, текст з причиною й рецептом,
  результат — як провал злиття (`$false`, код 2). Перевірка — `git cat-file -e "<гілка>:v8storagekit.yaml"`
  (код 0 — є; інший — немає; `Test-KitBranchExists` перед нею — у гілки, якої немає, свій наявний
  текст від `Merge-KitBranchInto`).

- [ ] **Step 1: Перевірити фрази на унікальність**

```bash
grep -rn "не синхронізовано" tools/commands tools/lib
grep -rn "v8storagekit.yaml немає" tools/commands tools/lib
```

Expected: порожньо обидва. Якщо ні — узяти іншу розрізняльну фразу й вписати її і в код, і в тести
нижче (kit-dev, case 22).

- [ ] **Step 2: Тести порядку й попередження**

Створити `tools/tests/Sync.Order.Tests.ps1` (прийом — `Sync.Merge.Tests.ps1`: модулі в порядку
`module-order.txt`, `sync.psm1` у цьому процесі, моки платформи):

```powershell
#Requires -Version 7
Describe 'kit sync — порядок джерел клієнтського воркспейсу й попередження (мок платформи)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force

        function script:New-ClientRepo {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
            $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('storages:')
            foreach ($k in 'ExtA', 'base', 'Доработки') {
                $d = Join-Path $TestDrive "$Name-storage-$k"; New-Item -ItemType Directory -Path $d -Force | Out-Null
                $lines.Add("  ${k}: '$d'")
            }
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
            $repo
        }
    }

    BeforeEach {
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        # Прев'ю (без -Apply): платформа потрібна лише для звіту сховища, і його мокаємо; порядок
        # викликів звіту = порядок обробки джерел. '' — CONFIGURATION (ExtensionName порожній).
        Mock -ModuleName sync Get-StorageVersions {
            param($IbSwitch, $StoragePath, $ExtensionName)
            $script:Seen.Add($(if ($ExtensionName) { $ExtensionName } else { '<CONFIGURATION>' }))
            , @()
        }
        Mock -ModuleName StoragePlatform Invoke-V8Designer { throw 'платформа не мала викликатись у прев''ю' }
    }

    It 'CONFIGURATION обробляється першим, хоча в маніфесті він другий; розширення — у маніфестному порядку' {
        $repo = New-ClientRepo 'order'
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo)
        @($script:Seen) | Should -Be @('<CONFIGURATION>', 'ExtA', 'Доработки')
    }

    It '-Source <розширення> при CONFIGURATION під storage у воркспейсі — попередження, не зупинка' {
        $repo = New-ClientRepo 'warn-ext'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'ExtA' 6>&1 | Out-String
        $out | Should -BeLike '*base*не синхронізовано*'
        @($script:Seen) | Should -Be @('ExtA')
    }

    It 'повний прогін воркспейсу — попередження немає' {
        $repo = New-ClientRepo 'no-warn'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) 6>&1 | Out-String
        $out | Should -Not -BeLike '*не синхронізовано*'
    }

    It '-Source base — попередження немає' {
        $repo = New-ClientRepo 'no-warn-base'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'base' 6>&1 | Out-String
        $out | Should -Not -BeLike '*не синхронізовано*'
    }

    It 'два воркспейси: порядок воркспейсів маніфестний, CONFIGURATION першим у кожному' {
        $ws = New-KitClientWorkspaces
        $ws['Second_UNF'] = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'ExtC';  Type = 'EXTENSION';     Path = 'cfe/ExtC/src' }
            @{ Name = 'base2'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'two-ws') -Workspaces $ws -WithHooks -WithGitignore -WithAgentBase
        $lines = @('storages:') + @(foreach ($k in 'ExtA', 'base', 'Доработки', 'ExtC', 'base2') {
            $d = Join-Path $TestDrive "two-ws-storage-$k"; New-Item -ItemType Directory -Path $d -Force | Out-Null; "  ${k}: '$d'" })
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo)
        @($script:Seen) | Should -Be @('<CONFIGURATION>', 'ExtA', 'Доработки', '<CONFIGURATION>', 'ExtC')
    }
}
```

Примітка для виконавця: якщо `Write-Host` не ловиться `6>&1` у цій формі виклику — узяти прийом,
яким це вже робить інший тест набору (`grep -rn "6>&1" tools/tests`), і назвати в сумнівах.

- [ ] **Step 3: Тести `-MergeInto` і запобіжника**

У `Sync.Merge.Tests.ps1` (там уже є `New-KitTestContext` і `New-KitFakeStorageVersion`), новим
`Context` або поруч із тестами «дзеркало вже синхронне, -MergeMain РАЗОМ з -Apply»:

```powershell
    It '-MergeInto гілка без v8storagekit.yaml (gitsync-master) — злиття не виконується, код 2, гілка не зрушила' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-into-legacy') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'merge-into-legacy-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
        # Гілка без маніфесту — так виглядає master gitsync-репозиторію до переходу (#15).
        git -C $repo checkout -q --orphan legacy 2>&1 | Out-Null
        git -C $repo rm -rqf . 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'gitsync' -Encoding UTF8
        git -C $repo add README.md; git -C $repo commit -qm 'gitsync-стан' 2>&1 | Out-Null
        git -C $repo checkout -q main 2>&1 | Out-Null
        $legacyBefore = git -C $repo rev-parse legacy

        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5) }

        $ctx = New-KitTestContext -Repo $repo
        $out = Invoke-KitSync -Context $ctx -Apply $true -MergeMain -MergeInto 'legacy' 6>&1 | Out-String
        # Результат — останній об'єкт виводу; якщо 6>&1 змішує, взяти результат окремим викликом.
        $result = Invoke-KitSync -Context $ctx -Apply $true -MergeMain -MergeInto 'legacy'
        $result.ExitCode | Should -Be 2
        $out | Should -BeLike '*legacy*v8storagekit.yaml немає*'
        (git -C $repo rev-parse legacy) | Should -Be $legacyBefore
    }

    It '-MergeInto гілка онбордингу з маніфестом — злиття туди, main не зрушив' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-into-onb') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'merge-into-onb-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
        git -C $repo branch onboarding main
        $mainBefore = git -C $repo rev-parse main

        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5) }

        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -MergeMain -MergeInto 'onboarding'
        $result.ExitCode | Should -Be 0
        git -C $repo merge-base --is-ancestor storage/Alpha_SMB onboarding; $LASTEXITCODE | Should -Be 0
        (git -C $repo rev-parse main) | Should -Be $mainBefore
    }
```

(Подвійний виклик у першому тесті — ескіз; якщо результат і вивід зручніше взяти одним викликом,
зробити одним і назвати в сумнівах. Важливо: друге злиття не повинне ввійти в гілку — запобіжник
тримає обидва виклики.)

- [ ] **Step 4: Прогнати — має впасти**

Expected: FAIL — порядок `ExtA, <CONFIGURATION>, Доработки`; фрази попередження немає; параметра
`-MergeInto` немає.

- [ ] **Step 5: Реалізація**

У `sync.psm1`:

```powershell
function Sort-KitSyncSources {
    <#
    .SYNOPSIS
        Порядок sync (спека 2026-09-30 §5.4): усередині воркспейсу CONFIGURATION першим — після
        нього в базі агента остання перенесена версія основної конфігурації, і розширення
        вивантажуються на ній, а не на стані гілки задачі. Воркспейси й розширення — у порядку
        маніфесту. Явний цикл, а не Sort-Object: стабільність тут — контракт, а не деталь.
    #>
    param([AllowEmptyCollection()][object[]]$Sources)
    $wsOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Sources) { if (-not $wsOrder.Contains($s.Workspace)) { $wsOrder.Add($s.Workspace) } }
    foreach ($ws in $wsOrder) {
        $Sources | Where-Object { $_.Workspace -eq $ws -and $_.Type -eq 'CONFIGURATION' }
        $Sources | Where-Object { $_.Workspace -eq $ws -and $_.Type -ne 'CONFIGURATION' }
    }
}
```

В `Invoke-KitSync`:
1. Параметр `[string]$MergeInto`; одразу після валідації `-FromVersion`: `$into = if ($MergeInto) { $MergeInto } else { $Context.MainBranch }`.
2. Після `Select-KitSources`: `$sources = @(Sort-KitSyncSources -Sources $sources)`.
3. Попередження — перед циклом платформи (після fetch), по воркспейсах вибірки:

```powershell
    foreach ($wsName in @($sources.Workspace | Select-Object -Unique)) {
        $ws = @($Context.Workspaces | Where-Object Path -eq $wsName)[0]
        $cfg = @($ws.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })
        $selectedHere = @($sources | Where-Object Workspace -eq $wsName)
        if ($cfg.Count -gt 0 -and @($selectedHere | Where-Object Type -eq 'EXTENSION').Count -gt 0 -and
            @($selectedHere | Where-Object Type -eq 'CONFIGURATION').Count -eq 0) {
            Write-Host ("  УВАГА: основну конфігурацію '{0}' (truth: storage) у цьому прогоні не синхронізовано — " +
                "контекст вивантаження розширень воркспейсу '{1}' той, що зараз у базі агента. Повний прогін: kit sync -Workspace {1}." -f
                ($cfg.Key -join ', '), $wsName) -ForegroundColor Yellow
        }
    }
```

4. `Invoke-KitMainMerge`: параметр `[Parameter(Mandatory)][string]$Into` замість `$main = $Context.MainBranch`; усі виклики передають `-Into $into`. Тексти повтору — `kit sync -Source <ключ> -Apply -MergeMain` плюс ` -MergeInto <гілка>`, коли `$Into -ne $Context.MainBranch`. Запобіжник — після перевірки існування гілки, до `Merge-KitBranchInto`:

```powershell
    # Запобіжник #15 (спека 2026-09-30 §6.3.4): ПЕРШЕ злиття в гілку, де немає маніфесту, —
    # майже напевно не та гілка (master gitsync-репозиторію до переходу, коли маніфест і
    # перейменування лежать на гілці онбордингу). Там злиття проходить ЧИСТО — шляхи не
    # перетинаються — і кладе Designer-дерево в master ДО коміту конверсії: той самий
    # зворотний порядок, що обнуляє git blame (§9.2 спеки 2026-09-03).
    if (-not (Test-KitBranchMergedInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $Into)) {
        git -C $Context.RepoRoot cat-file -e "${Into}:v8storagekit.yaml" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("  Злиття не виконано: у гілці '{0}' v8storagekit.yaml немає — це перше злиття {1}, і маніфест живе на іншій гілці. " +
                "Злийте в гілку, де лежить маніфест: kit sync -Source {2} -Apply -MergeMain -MergeInto <гілка>." -f $Into, $Source.Branch, $Source.Key) -ForegroundColor Yellow
            Write-Host '  Дзеркало оновлено.' -ForegroundColor Yellow
            return $false
        }
    }
```

5. Оновити `.DESCRIPTION` `Invoke-KitSync` абзацом про порядок і `-MergeInto`.

- [ ] **Step 6: Прогнати — має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration` — PASS (наявні
`Sync.*` лишаються зеленими: для типової фікстури порядок не змінюється, `-Into` = `main`).

- [ ] **Step 7: Мутації (на копії дерева)**

(а) замінити виклик `Sort-KitSyncSources` на тотожність — тест порядку червоний;
(б) вирізати блок запобіжника — тест `legacy` червоний (гілка зрушила або код 0);
(в) вирізати `Write-Host` попередження — тест попередження червоний. Тексти падінь — у звіт.

- [ ] **Step 8: Тексти (#15)**

- `skills/sync/SKILL.md`: параметр `-MergeInto <гілка>` (куди перше злиття; типово `mainBranch`)
  і штатна зупинка «Злиття не виконано: у гілці '…' v8storagekit.yaml немає» з рецептом;
  попередження «основну конфігурацію … не синхронізовано» — що воно означає і що це не зупинка.
- `skills/onboarding/SKILL.md` §3.6/§4: питання «онбординг прямо в головну гілку чи на гілці з
  PR?»; для гілки — `sync … -MergeInto <гілка онбордингу>`, далі `verify -Ref <гілка>` → PR.
- `skills/onboarding/references/gitsync-migration.md` крок 4: назвати випадок, коли злиття в
  `mainBranch` **не** впало б (перейменування на гілці онбордингу, шляхи не перетинаються), і що
  тепер його ловить запобіжник; шлях — `-MergeInto <гілка онбордингу>`. Обхід через тимчасову
  правку `mainBranch` у маніфесті — прибрати як рекомендацію, якщо він там згаданий.

Перевірка: `grep -rnP 'CLAUDE_PLUGIN_ROOT\}(?!/)' skills/` — порожньо; перехресні посилання — з
префіксом `v8storagekit:`.

- [ ] **Step 9: Коміт**

```bash
git add tools/commands/sync.psm1 tools/tests/Sync.Order.Tests.ps1 tools/tests/Sync.Merge.Tests.ps1 skills/sync/SKILL.md skills/onboarding/SKILL.md skills/onboarding/references/gitsync-migration.md
git commit --only -m "sync: CONFIGURATION першим у воркспейсі, попередження, -MergeInto із запобіжником (#15)" -- tools/commands/sync.psm1 tools/tests/Sync.Order.Tests.ps1 tools/tests/Sync.Merge.Tests.ps1 skills/sync/SKILL.md skills/onboarding/SKILL.md skills/onboarding/references/gitsync-migration.md
```

---

### Task 4: `verify` і `adopt` не бачать поставки; `adopt` її не стирає й не стейджить

**Ризик:** властивість безпеки (два рев'ю; друге вузьке — «після `adopt -Apply` `.cf` на місці
й не в індексі, за будь-якого `.gitignore`»). Дефект `main` 2 зі спеки §5.2.

**Files:**
- Modify: `tools/lib/TreeCompare.psm1` (`Get-KitRelativeFiles`; `Import-Module "$PSScriptRoot/Supply.psm1"`)
- Modify: `tools/commands/adopt.psm1` (стирання, копіювання, `git add`)
- Test: `tools/tests/TreeCompare.Tests.ps1`, `tools/tests/Verify.Tests.ps1`, `tools/tests/Adopt.Tests.ps1`

**Interfaces:**
- Consumes: `Test-KitSupplyRelativePath`, `Clear-KitTreeExceptSupply`, `Get-KitSupplyRelativePath`
  (Task 1); `New-KitClientWorkspaces`, `-WithSupply` (Task 1).
- Produces: `Get-KitRelativeFiles` ніколи не повертає шляхів під `Ext/ParentConfigurations/`;
  `.bin` — повертає.

**Контракт (спека §6.3.3):** виключення — у `Get-KitRelativeFiles` (її кличуть рівно `verify` і
прев'ю `adopt`), тож одне місце закриває обидва. `.bin` лишається в порівнянні. У `adopt`
окремо: стирання крім поставки, копіювання **пофайлово** (див. нижче), `git add` з
`:(exclude)<шлях джерела>/Ext/ParentConfigurations` — щоб старий репозиторій без рядка ігнору
(Review Focus 1) не застейджив `.cf`.

**Чому пофайлово:** `Copy-Item -Path <mirror>\* -Destination <дерево> -Recurse` у наявну теку
`Ext` (вона тепер лишається — у ній поставка) у PowerShell може покласти теку **всередину**
(`Ext/Ext/…`) замість злиття. Тест нижче ловить саме це.

- [ ] **Step 1: Тест `Get-KitRelativeFiles`**

У `TreeCompare.Tests.ps1`:

```powershell
    It 'Get-KitRelativeFiles пропускає теку поставки, .bin лишає (спека 2026-09-30 §6.3.3)' {
        $root = Join-Path $TestDrive 'rel-supply'
        New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Configuration.xml') -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations.bin') -Value 'bin' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1') -Value 's' -Encoding UTF8
        $rel = @(Get-KitRelativeFiles -Root $root)
        $rel | Should -Contain 'Configuration.xml'
        $rel | Should -Contain 'Ext/ParentConfigurations.bin'
        @($rel | Where-Object { $_ -like 'Ext/ParentConfigurations/*' }).Count | Should -Be 0
    }
```

Імпорт `Supply.psm1` у `BeforeAll`, якщо файл вантажить модулі поштучно.

- [ ] **Step 2: Тести `verify` (мок платформи)**

У `Verify.Tests.ps1`, у `Describe` «мок платформного шару» (там є потрібні моки), два нові `It`:

```powershell
    It 'клієнтська основна конфігурація: .cf у дампі не дає OnlyInDump — equal' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-supply') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:Bin = 'bin-of-release-1-bytes-over-sixteen'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Client_UNF/cf/src' -FileName 'Configuration.xml' -Content '<x/>' -Trailers @('Storage-Source: base', 'Storage-Version: 1')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Client_UNF/cf/src' -FileName 'Ext/ParentConfigurations.bin' -Content $script:Bin -Trailers @('Storage-Source: base', 'Storage-Version: 2')
        $storageDir = Join-Path $TestDrive 'verify-supply-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")

        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path (Join-Path $Target 'Ext/ParentConfigurations') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value '<x/>' -Encoding UTF8 -NoNewline
            Set-Content -LiteralPath (Join-Path $Target 'Ext/ParentConfigurations.bin') -Value $script:Bin -Encoding UTF8 -NoNewline
            Set-Content -LiteralPath (Join-Path $Target 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding UTF8
            3
        }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'base' -Ref 'storage/base'
        $r.Results[0].Diff.OnlyInDump | Should -Not -Contain 'Ext/ParentConfigurations/Vendor.cf'
        $r.Results[0].Verdict | Should -Be 'equal'
    }

    It 'клієнтська основна конфігурація: змінений .bin — Content (ознаки підтримки порівнюються)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-supply-bin') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Client_UNF/cf/src' -FileName 'Configuration.xml' -Content '<x/>' -Trailers @('Storage-Source: base', 'Storage-Version: 1')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Client_UNF/cf/src' -FileName 'Ext/ParentConfigurations.bin' -Content 'bin-of-release-1-bytes-over-sixteen' -Trailers @('Storage-Source: base', 'Storage-Version: 2')
        $storageDir = Join-Path $TestDrive 'verify-supply-bin-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")

        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path (Join-Path $Target 'Ext/ParentConfigurations') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value '<x/>' -Encoding UTF8 -NoNewline
            Set-Content -LiteralPath (Join-Path $Target 'Ext/ParentConfigurations.bin') -Value 'bin-of-release-2-bytes-over-sixteen' -Encoding UTF8 -NoNewline
            Set-Content -LiteralPath (Join-Path $Target 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding UTF8
            3
        }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'base' -Ref 'storage/base'
        $r.Results[0].Diff.Content | Should -Contain 'Ext/ParentConfigurations.bin'
        $r.Results[0].Diff.OnlyInDump | Should -Not -Contain 'Ext/ParentConfigurations/Vendor.cf'
        $r.Results[0].Verdict | Should -Be 'ref-ahead'
    }
```

Третій `It` — розширення того самого воркспейсу (спека §7: `verify` — на кожному джерелі
окремо; друге розширення з кирилицею в імені):

```powershell
    It 'розширення клієнтського воркспейсу (Доработки) — equal, як і раніше' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-client-ext') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:ExtXml = New-KitFakeConfigurationXml -Name 'Доработки'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Доработки' -RepoPath 'Client_UNF/cfe/Доработки/src' -FileName 'Configuration.xml' -Content $script:ExtXml -Trailers @('Storage-Source: Доработки', 'Storage-Version: 1')
        $storageDir = Join-Path $TestDrive 'verify-client-ext-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Доработки: '$storageDir'") -join "`n")

        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:ExtXml -Encoding UTF8 -NoNewline
            1
        }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Доработки' -Ref 'storage/Доработки'
        $r.Results[0].Verdict | Should -Be 'equal'
    }
```

Підготовка продубльована навмисно: тести читаються поодинці.

- [ ] **Step 3: Тести `adopt`**

У `Adopt.Tests.ps1` новий `Describe` (підпроцес справжнього `kit.ps1`, як решта файлу):

```powershell
Describe 'kit adopt — основна конфігурація з поставкою вендора (спека 2026-09-30 §5.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:New-SupplyAdoptRepo {
            param([string]$Name, [switch]$NoSupplyIgnoreLine)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithSupply
            if ($NoSupplyIgnoreLine) {
                # Репозиторій до 1.3.0 (Review Focus 1): рядка ігнору поставки ще немає.
                $gi = Join-Path $repo '.gitignore'
                (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
                git -C $repo commit -qam 'gitignore без рядка поставки' 2>&1 | Out-Null
            }
            # Дзеркало: той самий Configuration.xml, НОВИЙ .bin, без .cf (як пише sync після Task 2).
            $env:V8KIT_SYNC = '1'
            try {
                git -C $repo checkout -q -b 'storage/base' 2>&1 | Out-Null
                [System.IO.File]::WriteAllBytes((Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..48))
                git -C $repo add -- 'Client_UNF/cf/src/Ext/ParentConfigurations.bin' 2>&1 | Out-Null
                git -C $repo commit -q -m 'sync: версія 3' -m 'Storage-Version: 3' 2>&1 | Out-Null
            } finally { Remove-Item Env:\V8KIT_SYNC -ErrorAction SilentlyContinue }
            git -C $repo checkout -q main 2>&1 | Out-Null
            $repo
        }
    }

    It 'прев''ю: .cf не в списку «ЗНИКНЕ», .bin — у «прийде зі сховища»' {
        $repo = New-SupplyAdoptRepo 'supply-preview'
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*Vendor.cf*'
        $r.Output | Should -BeLike '*ParentConfigurations.bin*'
    }

    It '-Apply: .cf лишається на диску, новий .bin на місці, без Ext/Ext, робоча копія чиста' {
        $repo = New-SupplyAdoptRepo 'supply-apply'
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        Join-Path $cfg 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        (Get-Item -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin')).Length | Should -Be 48
        Join-Path $cfg 'Ext/Ext' | Should -Not -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It '-Apply у репозиторії без рядка ігнору поставки — .cf не потрапляє ні в індекс, ні в коміт' {
        $repo = New-SupplyAdoptRepo 'supply-noignore' -NoSupplyIgnoreLine
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(git -C $repo ls-files -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }

    It 'розширення клієнтського воркспейсу (кирилиця в імені) — adopt -Apply працює як раніше' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-cyr') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore
        $env:V8KIT_SYNC = '1'
        try {
            git -C $repo checkout -q -b 'storage/Доработки' 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'Client_UNF/cfe/Доработки/src/New.xml') -Value 'нове' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            git -C $repo commit -q -m 'sync: версія 2' -m 'Storage-Version: 2' 2>&1 | Out-Null
        } finally { Remove-Item Env:\V8KIT_SYNC -ErrorAction SilentlyContinue }
        git -C $repo checkout -q main 2>&1 | Out-Null
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'Доработки', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'Client_UNF/cfe/Доработки/src/New.xml' | Should -Exist
    }
}
```

(У типовому `New-AdoptRepo` цього файлу дзеркало будується `checkout -b` з main — тут так само;
`-WithSupply` кладе `.cf` після коміту, тож у `storage/base` його немає.)

- [ ] **Step 4: Прогнати — має впасти**

Expected: FAIL — `Get-KitRelativeFiles` повертає `.cf`; `verify` дає `OnlyInDump`; прев'ю `adopt`
друкує `Vendor.cf`; `-Apply` стирає `.cf`; у репозиторії без рядка ігнору — `.cf` в індексі.

- [ ] **Step 5: Реалізація**

`TreeCompare.psm1`, `Get-KitRelativeFiles`: у `Where-Object` після фільтра `PlatformJunk` —
відносний шлях обчислюється до фільтра, тож переставити: спершу `ForEach-Object` у відносний
шлях, потім `Where-Object { -not (Test-KitSupplyRelativePath -RelativePath $_) }`. Фільтр імен
`PlatformJunk` лишити як є. Коментар: «поставка вендора — стан машини, не зміст дерева (спека
2026-09-30 §6.3.3); `.bin` порівнюється, як решта».

`adopt.psm1` у кроці заміни (замість `Remove-Item … ; New-Item … ; Copy-Item …`):

```powershell
            Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $ws.FullPath -Description "дерево джерела $($src.Key)"
            # Поставка вендора (спека 2026-09-30 §5.2): у дзеркалі .cf немає — повне стирання
            # лишило б .bin без .cf, і наступне повне завантаження впало б (спайк §4.2, варіант B).
            Clear-KitTreeExceptSupply -TreeRoot $src.FullPath -MustBeUnder $ws.FullPath
            # Пофайлово, не Copy-Item <mirror>\* -Recurse: тека Ext тепер може вже існувати (у ній
            # поставка), а рекурсивна копія теки в наявну теку кладе її ВСЕРЕДИНУ (Ext/Ext/…).
            $mirrorFull = (Resolve-Path -LiteralPath $mirrorDir).Path
            foreach ($f in @(Get-ChildItem -LiteralPath $mirrorFull -Recurse -File -Force)) {
                $dest = Join-Path $src.FullPath $f.FullName.Substring($mirrorFull.Length).TrimStart('\', '/')
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            }

            # :(exclude) — поставка не стейджиться НІКОЛИ, навіть у репозиторії, де рядка ігнору ще
            # немає (до kitVersion 1.3.0): інакше -A забрав би .cf на сотні МБ у коміт.
            $supplySpec = ':(exclude){0}/{1}' -f (($src.RepoPath -replace '\\', '/').TrimEnd('/')), (Get-KitSupplyRelativePath)
            $add = Invoke-KitGitProcess -RepoRoot $root -Arguments @('add', '-A', '--', $src.RepoPath, $supplySpec)
```

Коміт `--only -- $src.RepoPath` (гілка без merge) перечитує шляхи з робочого дерева — **перевірити
тестом «без рядка ігнору»**, що `.cf` туди не потрапляє. Якщо потрапляє — додати `$supplySpec` і
до pathspec коміту `--only` і назвати в сумнівах.

- [ ] **Step 6: Прогнати — має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration` — PASS (наявні
`Adopt.Tests.ps1` і `Verify.Tests.ps1` — зелені).

- [ ] **Step 7: Мутації (на копії дерева)**

(а) прибрати фільтр `Test-KitSupplyRelativePath` у `Get-KitRelativeFiles` — червоні тест
`TreeCompare`, перший тест `verify`, прев'ю `adopt`;
(б) повернути `Remove-Item -Recurse` дерева в `adopt` — червоний `-Apply` (`.cf` зник);
(в) прибрати `$supplySpec` з `git add` — червоний тест «без рядка ігнору»;
(г) повернути `Copy-Item <mirror>\* -Recurse` — перевірити, чи червоніє тест `Ext/Ext`; якщо ні
(поведінка PowerShell виявилась іншою) — записати факт у звіт, пофайлове копіювання лишити.

- [ ] **Step 8: Коміт**

```bash
git add tools/lib/TreeCompare.psm1 tools/commands/adopt.psm1 tools/tests/TreeCompare.Tests.ps1 tools/tests/Verify.Tests.ps1 tools/tests/Adopt.Tests.ps1
git commit --only -m "verify/adopt: поставка вендора поза порівнянням; adopt не стирає й не стейджить .cf" -- tools/lib/TreeCompare.psm1 tools/commands/adopt.psm1 tools/tests/TreeCompare.Tests.ps1 tools/tests/Verify.Tests.ps1 tools/tests/Adopt.Tests.ps1
```

---

### Task 5: `canon` пише позначку `.kit-bin-sha1`

**Ризик:** механічна (одне рев'ю, дешева модель, guard-умови: лише CONFIGURATION, лише коли `.bin` описує поставку).

**Files:**
- Modify: `tools/commands/canon.psm1` (`Invoke-KitCanon`, після успішного дампу цілі)
- Test: `tools/tests/Canon.Tests.ps1`

**Interfaces:**
- Consumes: `Write-KitSupplyMarker -TreeRoot` (Task 1); `New-KitClientWorkspaces` (Task 1).
- Produces: `Canonized[]` отримує поле `SupplyMarker` (`[string]` SHA-1 або `$null`).

- [ ] **Step 1: Тести**

У `Canon.Tests.ps1`, `Describe` з моком `Invoke-V8Designer` (`-ModuleName canon`):

```powershell
    It 'CONFIGURATION з поставкою: після дампу — позначка з SHA-1 .bin; розширення — без позначки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'canon-supply') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"(?<ext> -Extension)?') {
                $dir = $Matches.p
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value '<x/>' -Encoding UTF8
                if (-not $Matches.ext) {
                    New-Item -ItemType Directory -Path (Join-Path $dir 'Ext/ParentConfigurations') -Force | Out-Null
                    [System.IO.File]::WriteAllBytes((Join-Path $dir 'Ext/ParentConfigurations.bin'), [byte[]](1..64))
                    Set-Content -LiteralPath (Join-Path $dir 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding ascii
                }
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $result = Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        $expected = (Get-FileHash -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText((Join-Path $cfg 'Ext/ParentConfigurations/.kit-bin-sha1')) | Should -BeExactly $expected
        ($result.Canonized | Where-Object Key -eq 'base').SupplyMarker | Should -Be $expected
        Join-Path $repo 'Client_UNF/cfe/ExtA/src/Ext/ParentConfigurations' | Should -Not -Exist
        ($result.Canonized | Where-Object Key -eq 'ExtA').SupplyMarker | Should -BeNullOrEmpty
    }

    It 'CONFIGURATION, знята з підтримки (.bin 16 байт) — позначки немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'canon-supply-16') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"(?<ext> -Extension)?') {
                $dir = $Matches.p
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value '<x/>' -Encoding UTF8
                if (-not $Matches.ext) {
                    New-Item -ItemType Directory -Path (Join-Path $dir 'Ext/ParentConfigurations') -Force | Out-Null
                    [System.IO.File]::WriteAllBytes((Join-Path $dir 'Ext/ParentConfigurations.bin'), [byte[]](1..16))
                    Set-Content -LiteralPath (Join-Path $dir 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding ascii
                }
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $result = Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/.kit-bin-sha1' | Should -Not -Exist
        ($result.Canonized | Where-Object Key -eq 'base').SupplyMarker | Should -BeNullOrEmpty
    }
```

- [ ] **Step 2: Прогнати — має впасти.** Expected: FAIL — позначки немає, поля `SupplyMarker` немає.

- [ ] **Step 3: Реалізація**

В `Invoke-KitCanon` після перевірки `ExitCode` дампу цілі й перед підрахунком `$files`:

```powershell
            # Позначка поставки (спека 2026-09-30 §5.2, §5.3): canon — єдине місце, де .cf
            # з'являється на машині, тож саме тут фіксуємо, з яким .bin його вивантажено.
            $supplyMarker = $null
            if ($t.Type -eq 'CONFIGURATION') {
                $supplyMarker = Write-KitSupplyMarker -TreeRoot $t.FullPath
                if ($supplyMarker) { Write-Host "  $($t.Key): поставку вендора вивантажено, позначка .kit-bin-sha1 записана." -ForegroundColor DarkGray }
            }
```

`$files` рахується після позначки — тоді він включає позначку й `.cf`; це кількість файлів на
диску, не у git. Лишити так і не «виправляти»: число й раніше включало все, що вивантажила
платформа. До `$done.Add(...)` дописати `SupplyMarker = $supplyMarker`.

- [ ] **Step 4: Прогнати — має пройти.**

- [ ] **Step 5: Мутація (на копії).** Прибрати умову `$t.Type -eq 'CONFIGURATION'` не дасть
червоного (у розширенні `.bin` немає) — це очікувано; мутація, що мусить червоніти: вирізати
виклик `Write-KitSupplyMarker` — перший тест червоний. Текст — у звіт.

- [ ] **Step 6: Коміт**

```bash
git add tools/commands/canon.psm1 tools/tests/Canon.Tests.ps1
git commit --only -m "canon: позначка .kit-bin-sha1 після вивантаження CONFIGURATION з поставкою" -- tools/commands/canon.psm1 tools/tests/Canon.Tests.ps1
```

---

### Task 6: `check` — ігнор поставки в обидва боки, `.cf` не в індексі, стан поставки

**Ризик:** спільний код (одне рев'ю на сильній моделі).

**Files:**
- Modify: `tools/commands/check.psm1` (`Invoke-KitCheck`, цикл `foreach ($src in $all)`)
- Test: `tools/tests/Check.Supply.Tests.ps1` (створити; спільна підготовка — `fixtures/CheckSetup.ps1`)

**Interfaces:**
- Consumes: `Test-KitSupplyDescribed`, `Get-KitSupplyState`, `Get-KitSupplyRelativePath`,
  `Get-KitSupplyRecipe` (Task 1); `New-KitClientWorkspaces`, `-WithSupply`.
- Produces: знахідки `gitignore` (error) і `supply` (warn).

**Контракт (спека §5.2 таблиця, §6.3.8, §6.3.9):** для кожного джерела `Type = CONFIGURATION`,
`Truth ≠ vendor` (vendor-дерево ігнороване цілком — інваріант інший, наявний):

| Умова | Рівень | Суть тексту |
|---|---|---|
| `.bin` > 16 байт **і** тека поставки не під ігнором | error `gitignore` | «поставка вендора … не гітігнорована», рядок `**/Ext/ParentConfigurations/`, посилання на `references/upgrades.md` |
| `.bin` існує (будь-якого розміру) **і** сам під ігнором | error `gitignore` | «ознаки підтримки … гітігноровано» |
| у теці поставки щось відстежується індексом | error `gitignore` | «поставка вендора відстежується git», `git rm -r --cached -- '<шлях>'` |
| `Truth = storage` і стан `missing`/`stale` | warn `supply` | `Get-KitSupplyRecipe` |
| `.bin` ≤ 16 байт або немає | — | мовчить |

Проба ігнору теки: `git check-ignore --no-index -q -- "<RepoPath>/Ext/ParentConfigurations/"`
(скісна риска — питання про теку). **Step 2 перевіряє цю форму емпірично** до того, як на неї
спертись: git 2.53 на Windows мусить відповідати `0` на рядок `**/Ext/ParentConfigurations/` і
`1` без нього. Якщо форма з рискою не працює — пробувати наявний файл `.cf` (або вигаданий
`<тека>/probe.cf`), і назвати в сумнівах, яка форма взята й чому.

- [ ] **Step 1: Фрази на унікальність**

```bash
grep -rn "поставка вендора" tools/commands tools/lib
grep -rn "ознаки підтримки" tools/commands tools/lib
```

Expected: лише `tools/lib/Supply.psm1` (рецепт і коментарі). Тести нижче шукають
`'*не гітігнорована*'`, `'*ознаки підтримки*гітігноровано*'`, `'*відстежується git*поставк*'` — кожну
з цих фраз перевірити `grep`-ом: вона мусить бути лише в тій гілці `check`, яку тест перевіряє.

- [ ] **Step 2: Проба форми `check-ignore`**

```bash
tmp=$(mktemp -d) && git -C "$tmp" init -q && printf '**/Ext/ParentConfigurations/\n' > "$tmp/.gitignore" \
 && git -C "$tmp" check-ignore --no-index -q -- 'W/cf/src/Ext/ParentConfigurations/'; echo "з рядком: $?" \
 && : > "$tmp/.gitignore" && git -C "$tmp" check-ignore --no-index -q -- 'W/cf/src/Ext/ParentConfigurations/'; echo "без рядка: $?"
```

(`$tmp` — у скретчпаді сесії.) Expected: `з рядком: 0`, `без рядка: 1`. Сирий вивід — у звіт.

- [ ] **Step 3: Тести**

Створити `tools/tests/Check.Supply.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'kit check — поставка вендора основної конфігурації (спека 2026-09-30 §5.2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1')
        function script:New-ClientRepo {
            param([string]$Name)
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitattributes -WithGitignore -WithSupply
        }
        $script:Cfg = 'Client_UNF/cf/src'
    }

    It 'усе правильно: поставка під ігнором, .bin у git, позначка актуальна — без знахідок про поставку, код 0' {
        $repo = New-ClientRepo 'supply-good'
        $r = Invoke-Check -Repo $repo
        # Код 0 — ще й доказ, що check приймає здоровий клієнтський воркспейс (спека §1). Якщо тут
        # error — лагодити ФІКСТУРУ (вона мусить зображати здоровий репозиторій), не check, і
        # назвати причину в сумнівах.
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*поставк*'
        $r.Output | Should -Not -BeLike '*ознаки підтримки*'
    }

    It '.cf не під ігнором (репозиторій до 1.3.0) — error' {
        $repo = New-ClientRepo 'supply-not-ignored'
        $gi = Join-Path $repo '.gitignore'
        (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не гітігнорована*'
        $r.Output | Should -BeLike '*`*`*/Ext/ParentConfigurations/*'
    }

    It '.bin під ігнором — error' {
        $repo = New-ClientRepo 'supply-bin-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value '**/Ext/ParentConfigurations.bin'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*ознаки підтримки*гітігноровано*'
    }

    It '.cf закомічено силою — error з git rm -r --cached' {
        $repo = New-ClientRepo 'supply-tracked'
        git -C $repo add -f -- "$script:Cfg/Ext/ParentConfigurations/Vendor.cf"
        git -C $repo commit -qm 'поставку закомічено силою'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*відстежується git*поставк*'
        $r.Output | Should -BeLike "*git rm -r --cached*$script:Cfg/Ext/ParentConfigurations*"
    }

    It '.cf на диску немає — warn «відсутня» з рецептом, код 0' {
        $repo = New-ClientRepo 'supply-missing'
        Remove-Item -LiteralPath (Join-Path $repo "$script:Cfg/Ext/ParentConfigurations/Vendor.cf") -Force
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        # [!] — рівень warn у виводі check (Invoke-KitCheck: error → [-], warn → [!]).
        $r.Output | Should -Match '\[!\][^\r\n]*поставка вендора відсутня'
        $r.Output | Should -BeLike '*поставка вендора відсутня*kit verify -Source base*kit canon -Source base -Apply*'
    }

    It 'підмінений .bin (новий реліз) — warn «застаріла»' {
        $repo = New-ClientRepo 'supply-stale'
        [System.IO.File]::WriteAllBytes((Join-Path $repo "$script:Cfg/Ext/ParentConfigurations.bin"), [byte[]](1..99))
        git -C $repo commit -qam 'новий реліз вендора'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*поставка вендора застаріла*'
    }

    It 'знята з підтримки (.bin 16 байт), рядка ігнору немає — check мовчить про поставку' {
        $repo = New-ClientRepo 'supply-none'
        $gi = Join-Path $repo '.gitignore'
        (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
        Remove-Item -LiteralPath (Join-Path $repo "$script:Cfg/Ext/ParentConfigurations") -Recurse -Force
        [System.IO.File]::WriteAllBytes((Join-Path $repo "$script:Cfg/Ext/ParentConfigurations.bin"), [byte[]](1..16))
        git -C $repo commit -qam 'знято з підтримки'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*поставк*'
    }
}
```

(Шаблон `'*`*`*/Ext/…*'` — екранування `*` у `-BeLike`; якщо форма незручна, перевірити рядок
через `-match [regex]::Escape('**/Ext/ParentConfigurations/')`.) Перед тестами — три питання
kit-dev case 21: (а) чи `check` друкує `$f.Message` (так, лише його); (б) чи виконання дійде до
перевірки — жодна раніша зупинка `check` не спрацює на клієнтській фікстурі (перший тест доводить:
у ньому немає `error`); (в) чи тест червоний до зміни — Step 4.

- [ ] **Step 4: Прогнати — має впасти.** Expected: FAIL у всіх, крім «усе правильно» і «знята з
підтримки» (ті зелені й до зміни — це контрольні, їх червоність доводять мутації Step 7).

- [ ] **Step 5: Реалізація**

У `Invoke-KitCheck`, у `foreach ($src in $all)` після блоку `if ($src.Truth -ne 'vendor') { … }`:

```powershell
            # Поставка вендора основної конфігурації (спека 2026-09-30 §5.2, §6.3.8–9). Для vendor
            # дерево ігнороване цілком — інваріант інший (нижче). Для розширень і конфігурацій без
            # підтримки .bin поставки не описує, і перевірки мовчать.
            if ($src.Type -eq 'CONFIGURATION' -and $src.Truth -ne 'vendor') {
                $supplyRel = "$($src.RepoPath)/$(Get-KitSupplyRelativePath)"
                $binRel    = "$supplyRel.bin"
                if (Test-Path -LiteralPath (Join-Path $root $binRel) -PathType Leaf) {
                    git -C $root check-ignore --no-index -q -- $binRel 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 0) {
                        & $add error gitignore ("$tag`: '$binRel' гітігноровано — ознаки підтримки (замки об'єктів) мусять лежати в git. " +
                            'Приберіть правило, яке його ловить (перевірка: git check-ignore -v).')
                    } elseif ($code -gt 1) { & $add error gitignore "$tag`: git check-ignore завершився з кодом $code." }
                }
                if (Test-KitSupplyDescribed -TreeRoot $src.FullPath) {
                    git -C $root check-ignore --no-index -q -- "$supplyRel/" 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 1) {
                        & $add error gitignore ("$tag`: тека поставки вендора '$supplyRel/' не гітігнорована — .cf на сотні МБ потрапив би в git " +
                            "(ліміт GitHub 100 МБ на файл). Додайте в .gitignore рядок '**/Ext/ParentConfigurations/' " +
                            '(оновлення до kitVersion 1.3.0 — скіл v8storagekit:onboarding, references/upgrades.md).')
                    } elseif ($code -gt 1) { & $add error gitignore "$tag`: git check-ignore завершився з кодом $code." }
                }
                $trackedSupply = @(git -c core.quotepath=false -C $root ls-files -- $supplyRel 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    & $add error gitignore "$tag`: git ls-files завершився з кодом $LASTEXITCODE."
                } elseif ($trackedSupply.Count -gt 0) {
                    & $add error gitignore ("$tag`: поставка вендора відстежується git ($($trackedSupply.Count) файл(ів) у '$supplyRel') — " +
                        "приберіть з індексу: git rm -r --cached -- '$supplyRel'.")
                }
                if ($src.Truth -eq 'storage') {
                    $state = Get-KitSupplyState -TreeRoot $src.FullPath
                    if ($state -in 'missing', 'stale') {
                        & $add warn supply ("$tag`: " + (Get-KitSupplyRecipe -SourceKey $src.Key -MainBranch $Context.MainBranch -State $state))
                    }
                }
            }
```

Якщо Step 2 показав, що форма з рискою не працює, — замінити пробу на відповідну форму й
лишити коментар із сирим виміром.

- [ ] **Step 6: Прогнати — має пройти.**

- [ ] **Step 7: Мутації (на копії)**

Вирізати по черзі кожну з чотирьох гілок (`.bin` під ігнором; тека не під ігнором; відстежується;
стан) — відповідний тест червоний. Змінити `Test-KitSupplyDescribed` у `check` на `$true` — тест
«знята з підтримки» червоний (контроль, що мовчання — властивість, а не випадковість). Тексти — у звіт.

- [ ] **Step 8: Коміт**

```bash
git add tools/commands/check.psm1 tools/tests/Check.Supply.Tests.ps1
git commit --only -m "check: поставка вендора — ігнор в обидва боки, .cf не в індексі, стан позначки" -- tools/commands/check.psm1 tools/tests/Check.Supply.Tests.ps1
```

---

### Task 7: `check` бачить режим хуків у HEAD (#16); приймання першого коміту з коміту

**Ризик:** механічна (одне рев'ю, дешева модель).

**Files:**
- Modify: `tools/lib/Hooks.psm1` (`Test-KitGitHooks`, блок «Біт виконання»)
- Modify: `skills/onboarding/SKILL.md` (§3.6)
- Test: `tools/tests/Hooks.Tests.ps1`

**Interfaces:**
- Produces: нова знахідка `hooks` (warn), коли індекс каже `100755`, а HEAD — `100644`.

- [ ] **Step 1: Фраза на унікальність** — `grep -rn "у HEAD" tools/lib tools/commands`: знайти
розрізняльну фразу, якої ще немає (напр. «у коміті HEAD без біта виконання»).

- [ ] **Step 2: Тест**

У `Hooks.Tests.ps1` (там є тести «три стани хука»):

```powershell
    It 'індекс 100755, у HEAD 100644 (git commit --only перечитав файл з диска, #16) — warn' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'hooks-head') -WithHooks
        git -C $repo update-index --chmod=-x -- .githooks/pre-commit
        git -C $repo commit -qm 'хук без біта (як після commit --only на Windows)'
        git -C $repo update-index --chmod=+x -- .githooks/pre-commit
        $f = @(Test-KitGitHooks -RepoRoot $repo)
        @($f | Where-Object { $_.Message -like '*pre-commit*у коміті HEAD без біта виконання*' }).Count | Should -Be 1
    }

    It 'індекс і HEAD обидва 100755 — знахідки про HEAD немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'hooks-head-ok') -WithHooks
        @(Test-KitGitHooks -RepoRoot $repo | Where-Object { $_.Message -like '*у коміті HEAD*' }).Count | Should -Be 0
    }
```

- [ ] **Step 3: Прогнати — має впасти** (перший тест: індекс `100755`, наявна перевірка мовчить).

- [ ] **Step 4: Реалізація**

У `Test-KitGitHooks` після гілки `if ($Matches.mode -eq '100644') { … }`, для індексного
`100755`:

```powershell
            # #16: git commit --only <шляхи> НЕ бере індекс — перечитує файл із диска, і на Windows
            # (core.filemode=false) пише 100644, хоч в індексі лишається 100755. Індекс тоді бреше
            # про те, що отримає клон, — питаємо сам коміт.
            if ($Matches.mode -eq '100755') {
                $head = git -c core.quotepath=false -C $RepoRoot ls-tree HEAD -- "$script:HooksDirName/$name" 2>$null
                if ($LASTEXITCODE -eq 0 -and "$head" -match '^100644\s') {
                    $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                        "Хук $script:HooksDirName/$name у коміті HEAD без біта виконання (100644), хоч в індексі 100755 — так буває після " +
                        'git commit --only (перечитує файл з диска). Клон на Linux/macOS тихо проігнорує хук. Полагодити: закомітьте індекс ' +
                        "командою git commit без --only і без шляхів (індекс уже правильний).")))
                }
            }
```

(`ls-tree HEAD` на неіснуючому HEAD дає ненульовий код — тоді перевірки немає; це правильна
поведінка до першого коміту.)

- [ ] **Step 5: Прогнати — має пройти. Мутація (на копії):** вирізати блок — перший тест червоний.

- [ ] **Step 6: Текст `onboarding` §3.6**

- Приймальна перевірка — з **коміту**: `git ls-tree HEAD .githooks/` → `100755` для обох хуків
  (замість `git ls-files -s`, що дивиться в індекс).
- Пряма заборона: хуки **не** комітити через `git commit --only` — на Windows вона скидає режим
  на `100644` (#16); комітити їх окремою командою `git commit` без шляхів одразу після
  `install-hooks -Apply`.
- Коментар у блоці коду §3.6 про `git ls-files -s .githooks/` — виправити на `ls-tree HEAD`.

Перевірка: `grep -rn "ls-files -s .githooks" skills/` — порожньо або лише в поясненні, чому
індекс не підходить.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/Hooks.psm1 tools/tests/Hooks.Tests.ps1 skills/onboarding/SKILL.md
git commit --only -m "check: режим хуків з HEAD, не лише з індексу (#16); onboarding §3.6 — приймання з коміту" -- tools/lib/Hooks.psm1 tools/tests/Hooks.Tests.ps1 skills/onboarding/SKILL.md
```

---

### Task 8: `provision` — порожня база законна для основної конфігурації під сховищем; стан поставки

**Ризик:** спільний код (одне рев'ю на сильній моделі).

**Files:**
- Modify: `tools/commands/provision.psm1` (`Invoke-KitProvision`, `Test-KitConfigurationOwnerPresent`)
- Test: `tools/tests/Provision.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitSupplyState`, `Get-KitSupplyRecipe` (Task 1); `New-KitClientWorkspaces`.
- Produces: `Test-KitConfigurationOwnerPresent` лишається без змін сигнатури; нова приватна
  `Get-KitMissingOwnerSources -Workspace` → масив CONFIGURATION-джерел із порожнім деревом.

**Контракт (спека §5.3):** якщо всі CONFIGURATION-джерела з порожнім/відсутнім деревом мають
`truth: storage` — це законний старт рецепта (i): **не** зупинка, а підказка; решта шляху
`provision` без змін. Якщо серед порожніх є не-`storage` — наявна зупинка
`New-KitOwnerMissingMessage`. Для непорожнього дерева CONFIGURATION під `storage` — стан поставки
`missing`/`stale` друкується як попередження з `Get-KitSupplyRecipe` (і в прев'ю, і з `-Apply`).

- [ ] **Step 1: Переписати наявний тест, чий сенс змінюється**

`Provision.Tests.ps1`, тест «CONFIGURATION source-set truth: storage — повідомлення називає kit
sync як дешевий варіант» — фіксував зупинку, яка тепер скасовується рішенням спеки §5.3. Замінити
його (не видаляти мовчки — у коміті назвати причину):

```powershell
        It 'CONFIGURATION під truth: storage без дерева — не зупинка, а підказка рецепта (i): sync, потім canon (спека 2026-09-30 §5.3)' {
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'owner-storage-truth') -Workspaces $ws -WithHooks -NoSourceTrees
            # Прев'ю, не -Apply: -Apply створив би файлову ІБ справжньою платформою.
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -BeLike '*бракує власника*'
            $r.Output | Should -BeLike '*kit sync -Source base*-FromLatest*'
            $r.Output | Should -BeLike '*kit canon -Source base -Apply*'
        }

        It 'змішаний воркспейс: порожня CONFIGURATION під vendor — зупинка лишається' {
            # Типова фікстура: base — truth: vendor, дерево порожнє.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'owner-vendor-still') -WithHooks
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*бракує власника*'
        }

        It 'клієнтський воркспейс, поставка застаріла — попередження з рецептом, не зупинка' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'prov-stale') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithSupply
            [System.IO.File]::WriteAllBytes((Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..77))
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -BeLike '*поставка вендора застаріла*'
        }
```

Перевірити, що `-NoSourceTrees` + `Truth = 'storage'` у фікстурі не кладе `Configuration.xml`
(Task 1 п. 1 — під `if (-not $NoSourceTrees)`).

- [ ] **Step 2: Прогнати — має впасти** (перший і третій тест).

- [ ] **Step 3: Реалізація**

В `Invoke-KitProvision` замінити блок
`if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) { throw … }`:

```powershell
        if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) {
            $missing = @(Get-KitMissingOwnerSources -Workspace $ws)
            # Спека 2026-09-30 §5.3: основна конфігурація під сховищем без дерева — законний
            # старт нового репозиторію (рецепт (i)). Порожню базу наповнить sync (UpdateCfg на
            # порожній ІБ працює — спайк B2, спека 2026-09-03 §14), дерево — canon з неї. Це
            # закриває коло «provision радить sync, sync вимагає базу».
            if (@($missing | Where-Object Truth -ne 'storage').Count -gt 0) { throw (New-KitOwnerMissingMessage -Workspace $ws) }
            foreach ($m in $missing) {
                Write-Host ("  Основна конфігурація '{0}' (truth: storage) ще без дерева — порожня база законна (рецепт (i)). " +
                    'Після створення бази: kit sync -Source {0} -FromLatest -Apply (або -FromVersion N) → kit canon -Source {0} -Apply → operation=build Уніки.' -f $m.Key) -ForegroundColor Cyan
            }
        }
        foreach ($cfgSrc in @($ws.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })) {
            $state = Get-KitSupplyState -TreeRoot $cfgSrc.FullPath
            if ($state -in 'missing', 'stale') {
                Write-Host ('  УВАГА: ' + (Get-KitSupplyRecipe -SourceKey $cfgSrc.Key -MainBranch $Context.MainBranch -State $state)) -ForegroundColor Yellow
            }
        }
```

`Get-KitMissingOwnerSources` — приватна, поруч із `Test-KitConfigurationOwnerPresent`, та сама
перевірка «0 файлів у дереві», але повертає джерела (щоб логіка «порожнє» не розійшлась —
`Test-KitConfigurationOwnerPresent` переписати через неї: `@(Get-KitMissingOwnerSources …).Count -eq 0`).

- [ ] **Step 4: Прогнати — має пройти** (наявні тести власника — зелені).

- [ ] **Step 5: Мутації (на копії):** повернути безумовний `throw` — перший тест червоний;
вирізати цикл стану — третій червоний.

- [ ] **Step 6: Коміт**

```bash
git add tools/commands/provision.psm1 tools/tests/Provision.Tests.ps1
git commit --only -m "provision: порожня база законна для основної конфігурації під сховищем; стан поставки з рецептом" -- tools/commands/provision.psm1 tools/tests/Provision.Tests.ps1
```

У тілі коміту (через `-F`) назвати, що тест «truth: storage — повідомлення називає kit sync»
переписано, бо рішення спеки §5.3 скасувало зупинку, яку він фіксував.

---

### Task 9: `kit build` не затирає попередній артефакт (#18)

**Ризик:** механічна (одне рев'ю, дешева модель).

**Files:**
- Modify: `tools/commands/build.psm1` (`Copy-KitWorkspaceArtifacts`)
- Test: `tools/tests/Build.Tests.ps1`

**Interfaces:**
- Produces: перед перезаписом `<Destination>/<Ім'я>.<ext>` з **іншим** вмістом наявний файл
  перейменовується в `<Ім'я>_<sha8>.<ext>`, де `sha8` — перші 8 знаків SHA-1 наявного файлу
  малими (спека §6.3.7). Однаковий вміст — просто перезапис. Файл резервної копії вже є — не
  перезаписувати (той самий вміст за побудовою імені); наявний тоді просто замінюється.

- [ ] **Step 1: Тест**

У `Build.Tests.ps1` (функція експортована — `Export-ModuleMember … Copy-KitWorkspaceArtifacts`),
новий `Describe` з прямим викликом:

```powershell
Describe 'Copy-KitWorkspaceArtifacts — попередній артефакт не губиться (#18)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/build.psm1").Path -Force
    }

    It 'інший вміст — стара копія як <Ім''я>_<sha8>.cfe, нова на місці' {
        $wsDir = Join-Path $TestDrive 'ws'; $dest = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path (Join-Path $wsDir 'build/artifacts'), $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'Ext.cfe') -Value 'стара збірка' -Encoding UTF8
        $sha8 = (Get-FileHash -LiteralPath (Join-Path $dest 'Ext.cfe') -Algorithm SHA1).Hash.Substring(0, 8).ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $wsDir 'build/artifacts/Ext.cfe') -Value 'нова збірка' -Encoding UTF8
        $ws = [pscustomobject]@{ FullPath = $wsDir; Project = [pscustomobject]@{ WorkPath = 'build' } }
        $null = Copy-KitWorkspaceArtifacts -Workspaces @($ws) -Destination $dest
        (Get-Content -LiteralPath (Join-Path $dest 'Ext.cfe') -Raw).Trim() | Should -Be 'нова збірка'
        (Get-Content -LiteralPath (Join-Path $dest "Ext_$sha8.cfe") -Raw).Trim() | Should -Be 'стара збірка'
    }

    It 'той самий вміст — резервної копії немає' {
        $wsDir = Join-Path $TestDrive 'ws2'; $dest = Join-Path $TestDrive 'artifacts2'
        New-Item -ItemType Directory -Path (Join-Path $wsDir 'build/artifacts'), $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'Main.cf') -Value 'те саме' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $wsDir 'build/artifacts/Main.cf') -Value 'те саме' -Encoding UTF8
        $ws = [pscustomobject]@{ FullPath = $wsDir; Project = [pscustomobject]@{ WorkPath = 'build' } }
        $null = Copy-KitWorkspaceArtifacts -Workspaces @($ws) -Destination $dest
        @(Get-ChildItem -LiteralPath $dest -File).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Прогнати — має впасти.**

- [ ] **Step 3: Реалізація** — у циклі перед `Copy-Item`:

```powershell
            $target = Join-Path $Destination $f.Name
            # #18 (спека 2026-09-30 §6.3.7): чек-лист задачі посилається на хеш артефакту — мовчазний
            # перезапис робив той хеш посиланням у нікуди. Стару копію зберігаємо під sha8 її вмісту.
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $old = (Get-FileHash -LiteralPath $target -Algorithm SHA1).Hash.ToLowerInvariant()
                $new = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
                if ($old -ne $new) {
                    $backup = Join-Path $Destination ('{0}_{1}{2}' -f $f.BaseName, $old.Substring(0, 8), $f.Extension)
                    if (-not (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $target -Destination $backup }
                    Write-Host "  попередній $($f.Name) збережено як $(Split-Path -Leaf $backup)" -ForegroundColor DarkGray
                }
            }
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force
```

- [ ] **Step 4: Прогнати — має пройти. Мутація (на копії):** вирізати блок — перший тест червоний.

- [ ] **Step 5: Коміт**

```bash
git add tools/commands/build.psm1 tools/tests/Build.Tests.ps1
git commit --only -m "build: попередній артефакт .cf/.cfe зберігається як <Ім'я>_<sha8> (#18)" -- tools/commands/build.psm1 tools/tests/Build.Tests.ps1
```

---

### Task 10: тексти процедур — перший запуск, передача `.cf`, #13, #14, #17

**Ризик:** текст процедури — одне рев'ю на сильній моделі (рев'юер звіряє з §5.3, §5.6, §6.3
спеки, а не зі смаком).

**Files:**
- Modify: `skills/onboarding/SKILL.md`, `skills/provision/SKILL.md`, `skills/finish/SKILL.md`,
  `skills/using-v8storagekit/SKILL.md`, `templates/CLAUDE.md`, `docs/unica-contract.md`
- Test: `tools/tests/Skills.Tests.ps1` (лишається зеленим; нових тестів не треба, якщо не
  з'являються нові посилання на скіли)

**Зміст (кожен пункт — з розділом спеки, який він переказує; цитувати рішення, не вигадувати):**

1. `skills/onboarding/SKILL.md`:
   - §4 «Далі» / новий підрозділ «Клієнтська основна конфігурація»: три вихідні стани й рецепти
     з таблиці §5.3 дослівно за змістом — (i) новий репозиторій: `onboarding` → `provision`
     (порожня база) → `sync -Source <cfg> -FromLatest`/`-FromVersion` зі злиттям → `canon` →
     `operation=build`; (ii) свіжий клон: **на головній гілці** `provision` → `verify` (очікувано
     `equal`) → `canon` → `operation=build`; (iii) поставка застаріла — як (ii), лише на головній
     гілці. Обидва «чому» з §5.3: `canon` переписує все дерево (тому не на гілці задачі);
     ніколи `canon` на порожній базі (порожній дамп стирає дерево) — прийнятий ризик §6.3.9,
     тримається текстом. Для розширень, дерев яких ще немає, — **не** стверджувати, що рецепт (i)
     їх покриває (відкрите питання цього плану).
   - Питання #14 у розділі 3/4: «база агента вже є (серверна чи файлова з потрібною
     конфігурацією)?» — якщо так: `<ws>/v8project.local.yaml` з `infobase.connection` **і**
     `infobase.user` (після появи `.gitignore`), пароль — порожній (kit паролів бази агента не
     підтримує), і це **до** проби доступу до сховища (проба йде через базу агента);
     `provision` для такої бази не застосовний — він перестворив би її. Час реплею — розвести
     за типом бази: 4,8 с на версію (файлова, розширення на 121 файл) і ≈37 с на версію
     (серверна з повною УНФ ≈59 тис. файлів, розширення на 278 файлів) — з умовами виміру з #14.
2. `skills/provision/SKILL.md`: розділ 1 — основна конфігурація під `truth: storage` без дерева —
   законна порожня база (підказка `sync … -FromLatest` → `canon`); штатне попередження «поставка
   вендора відсутня/застаріла» з рецептом; #14 — `infobase.user` поруч із `infobase.connection`,
   наявна серверна база — не `provision`; #17 — `operation=build` без `sourceSet` вантажить **всю**
   основну конфігурацію; на серверній чи спільній базі агента (`infobase.user` заданий,
   підключення не файлове) — лише з явного підтвердження людини; для правок розширення —
   `sourceSet` розширення.
3. `skills/finish/SKILL.md` крок 7 і шаблон PR: `.cf` поруч із `.cfe`; для `.cf` — примітка
   «порівняти й об'єднати з конфігурацією з файлу, **не** завантажувати цілком (замінило б усю
   конфігурацію разом із поставкою й вимагало б захоплення всього сховища)» (§5.6). Артефакт не
   губиться при повторній збірці — `kit build` зберігає попередній як `<Ім'я>_<sha8>` (#18).
4. `skills/using-v8storagekit/SKILL.md` і `templates/CLAUDE.md`: те саме про `.cf` (одне речення
   кожен) і #17 (одне речення поруч з описом `operation=build`).
5. `docs/unica-contract.md`, розділ про `operation=build`/`syntax`: #13 — провал часткового
   завантаження (`-partial -listFile`) Уніка не робить помітним для `operation=syntax`; вимір
   (0 із 13, файлова база, 2026-09-22) з умовами; на серверній базі не виміряно. **Не**
   записувати `fullRebuild` як умову роботи (коментар власника в #13); `fullRebuild` усієї
   бази — крайній захід, який людина запускає свідомо. Читання `actions.log` kit не робить —
   окремий ішуз після виміру (§6.3.6).

- [ ] **Step 1:** Внести пункти 1–5.
- [ ] **Step 2:** Перевірки:

```bash
grep -rnP 'CLAUDE_PLUGIN_ROOT\}(?!/)' skills/
grep -rn "Unknown skill\|\`sync\`\b" skills/ | head
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

Expected: перша — порожньо; посилання на скіли — з префіксом `v8storagekit:`; набір — PASS.
Пошук за старими формулюваннями (глобальне правило «змінюючи рішення — знайти старе
формулювання»): `grep -rn "єдине, що тут може бути" templates/ skills/` — прибрати або уточнити
(#14 прямо на це вказує).

- [ ] **Step 3: Коміт**

```bash
git add skills/onboarding/SKILL.md skills/provision/SKILL.md skills/finish/SKILL.md skills/using-v8storagekit/SKILL.md templates/CLAUDE.md docs/unica-contract.md
git commit --only -m "скіли: перший запуск клієнтської конфігурації, .cf поруч із .cfe, база агента вже є (#14), build без sourceSet (#17), часткове завантаження (#13)" -- skills/onboarding/SKILL.md skills/provision/SKILL.md skills/finish/SKILL.md skills/using-v8storagekit/SKILL.md templates/CLAUDE.md docs/unica-contract.md
```

---

### Task 11: архітектурний документ, оновлення 1.2.0 → 1.3.0, версія, фінальне рев'ю, живий прогін

**Ризик:** механічна для текстів; фінальне рев'ю всієї гілки — обов'язкове (kit-dev, «рев'ю
контуру як цілого»); `Integration` — крок користувача.

**Files:**
- Modify: `docs/storage-and-git.md`, `skills/onboarding/references/upgrades.md`, `.claude-plugin/plugin.json`

- [ ] **Step 1: `docs/storage-and-git.md`** — розділи й зміст:
  - «Модель git» / «Як `storage/X` зливається у головну гілку»: `-MergeInto` і запобіжник «гілка
    без маніфесту» (#15);
  - «`verify`»: тека поставки поза порівнянням, `.bin` — побайтово;
  - «Канонізація дерева агента»: позначка `.kit-bin-sha1`, `canon` — єдине місце появи `.cf`,
    лише на головній гілці після `verify` = `equal`;
  - новий розділ «Поставка вендора основної конфігурації»: чому `.cf` поза git (100 МБ), чому
    `.bin` у git (замки), таблиця «де що робить» зі спеки §5.2, три стани позначки, спайк §4.2
    з умовами;
  - «Команди kit» / `sync`: CONFIGURATION першим у воркспейсі, свідоме обмеження §5.4
    (історичні версії розширення — на останній версії власника), попередження;
  - принцип «кожна версія — повний дамп у спорожнену теку» як інваріант (§5.5), з причиною —
    щоб його не «оптимізували».
- [ ] **Step 2: `upgrades.md`** — рядок таблиці `1.2.0 → 1.3.0` і розділ: що змінилось (поставка
  вендора поза git, `sync -MergeInto`, порядок `sync`, режим хуків з HEAD, резервні копії
  артефактів); кроки: (1) `claude plugin update` + нова сесія; (2) дописати `**/Ext/ParentConfigurations/`
  у `.gitignore`; (3) якщо в основній конфігурації під сховищем `.bin` > 16 байт — рецепт (ii) на
  головній гілці, щоб з'явились `.cf` і позначка; (4) `kit check` — без знахідок `gitignore`/`hooks`;
  якщо `check` каже про хук «у коміті HEAD без біта виконання» — `git commit` індексу без
  `--only`; (5) `kitVersion: 1.3.0`, коміт.
- [ ] **Step 3: версія** — `.claude-plugin/plugin.json`: `"version": "1.3.0"`. Прогнати набір —
  фікстура читає версію з `plugin.json`, тести `kitVersion` мусять лишитись зеленими.
- [ ] **Step 4: пошук залишків старих формулювань** (глобальне правило):

```bash
grep -rn "Remove-Item -LiteralPath \$src.FullPath -Recurse" tools/commands
grep -rn "ParentConfigurations" tools/commands tools/lib | grep -v "Supply.psm1"
```

Expected: перша — порожньо; друга — лише коментарі (літерал шляху в коді поза `Supply.psm1` —
знахідка: правило одного оголошення порушене).

- [ ] **Step 5: повний прогін** — `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`,
  дослівний підсумковий рядок Pester — у звіт.
- [ ] **Step 6: коміт**

```bash
git add docs/storage-and-git.md skills/onboarding/references/upgrades.md .claude-plugin/plugin.json
git commit --only -m "1.3.0: поставка вендора основної конфігурації — архітектурний документ, кроки оновлення, версія" -- docs/storage-and-git.md skills/onboarding/references/upgrades.md .claude-plugin/plugin.json
```

- [ ] **Step 7: фінальне рев'ю всієї гілки** (контролер, свіжий рев'юер на сильній моделі) —
  питання, які задачне рев'ю не ставить за побудовою: (а) чи є шлях, яким `.cf` потрапляє в
  будь-який коміт (`sync` → дзеркало, `adopt` → гілка, `verify -Apply` → звірочний коміт, злиття
  дзеркала в `main`); (б) чи всі споживачі беруть шлях із `Supply.psm1` (Step 4); (в) чи рецепти
  в `check`, `provision` і скілах — одне формулювання (`Get-KitSupplyRecipe`) і не суперечать
  §5.3; (г) чи тексти скілів не обіцяють рецепта (i) для розширень без дерева.
- [ ] **Step 8: `Integration` — лише за підтвердженням користувача, виконує контролер (у бриф не
  входить).** Пілот на справжньому клієнтському сховищі основної конфігурації **на підтримці**
  (`SMP_SMB_*_DEV` зняті з підтримки й поставку не перевіряють — спека §8): рецепт (i) з нуля,
  потім рецепт (ii) на свіжому клоні; час `UpdateCfg -v N` на повній конфігурації — у спеку §4
  через архітектора (`configuration-storage-spec`), з умовами виміру. Живі прогони платформи —
  за домовленістю, якою сесією (пам'ять `v8storagekit-agent-contour-plans`: компаньйон у
  `SMP_BankExchange`), — уточнити в користувача.
