# B3. `verify`, `dump`, `session-check` — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** три команди, що не потребують бази агента: `verify` — інваріант «ref ≡ сховище» з
класифікацією розбіжностей і звірочним комітом; `dump` — вивантаження з живої бази людини за
накладкою kit із розпізнаванням «база зайнята»; `session-check` — дешевий сигнал для хука
старту сесії без платформи.

**Architecture:** платформна робота зі сховищем (тимчасова ІБ → `UpdateCfg -v N` → дамп)
виноситься з `sync.psm1` у `StoragePlatform.psm1` і використовується і `sync`, і `verify`.
Дерево з git береться **сирими блобами** (`git cat-file --batch` через .NET Process), бо
`git archive` і checkout застосовують `eol=`-конверсію (перевірено в цій сесії) — і
порівняння показувало б стан робочої копії, а не git. Класифікація розбіжностей — чиста
функція над двома теками. `session-check` — лише файлова система й `git log`.

**Tech Stack:** PowerShell 7.5, Pester 5, git 2.53, платформа 1С 8.3.27.x (`Integration`).

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` — §3.5 (`verify`, версія
з merge-base), §5 (`dump`, «база зайнята», `session-check`), §12 (тести «verify §3.5»,
«session-check», «dump»), §14 (B3).

## Global Constraints

- **PowerShell 7+**, `Set-StrictMode -Version Latest`, `$LASTEXITCODE` після кожного `git`.
- **Мова** — українська; ASCII-якір у повідомленнях зупинки.
- **Тести без платформи:** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  `Integration` (`verify` проти живого сховища, `dump` із живої бази) — лише з підтвердженням
  користувача.
- **Сховища — тільки читання** (виняток `BindCfg`/`UnbindCfg` — як у B2). **База людини —
  тільки читання** (`dump`), і лише на явне прохання з `-Apply`.
- **`verify` без `-Apply` нічого не мутує в git.** Звірочний коміт — лише `-Apply`.
- **Ліцензія:** `Assert-NoLicenseProblem` на кожному виклику платформи.
- **`ConfigDumpInfo.xml` і `DumpFilesIndex.txt`** виключаються з порівняння завжди.
- **Версію не піднімати. `git push` — ні.** Робота в `feature/agent-contour`.
- **Kit не покладається на git-конфіг машини споживача (принцип 7 спеки; знахідка живого прогону B2):**
  `core.quotepath` типово `true`, і git екранує неASCII-шляхи вісімково в лапках у `ls-tree`, `ls-files`,
  `status`, `diff` — на репозиторії 1С це 240+ хибних «файлів поза шляхом». Правило (рев'ю B2):
  `-c core.quotepath=false` — на **кожному** git-виклику, що читає або друкує шляхи, без винятків;
  **`-z` додатково** — там, де викликач ділить вивід на записи **і** запис міг створити не kit (довільний ref,
  довільна робоча копія): `Export-KitTree`, `Get-KitBinaryPaths`, `canon status`. Пояснення: `quotepath`
  керує лише байтами ≥ 0x80, а `"`, `\` і перевід рядка git C-квотує завжди — `-z` прибирає саме це.
  Фікстурам заборонено виставляти `core.quotepath` — це маскувало б дефект (у SMP_BankExchange він був
  замаскований локальним `.git/config`).
- **`@(Get-ChildItem …).Count`, без винятків (знахідка B3, тричі):** під `Set-StrictMode -Version Latest`
  `(Get-ChildItem …).Count` кидає `PropertyNotFoundException` не лише на порожній теці, а й на теці **рівно з
  одним файлом** — `Get-ChildItem` повертає скалярний `FileInfo` без `.Count` (перевірено на pwsh 7.5.4).
  У продакшні це мовчить лише тому, що дамп конфігурації дає тисячі файлів. Те саме для будь-якого
  конвеєра, що може дати один елемент.
- **Уроки B1, обов'язкові для виконавця:**
  1. *Приймальна ознака попереджень* — не рахунок рядків `warning:` (недетермінований, змішує навмисне з
     випадковим), а іменна: «жоден `warning:` не називає файлу з цього diff'у».
  2. *Дисципліна коміту в спільній робочій копії* — лише `git add <явний перелік>` +
     `git commit --only -- <ті самі шляхи>`; ніяких `-a`/`-A`; після `git update-index` — комітити негайно.
  3. *Кеш плагіна — знімок, не лінк:* після кожного блоку (і перед живою перевіркою скілів/хука) —
     `claude plugin install v8storagekit@smp-v8storagekit` (або `update`) і **нова сесія**; без цього сесії
     бачать попередню версію робочої копії.
- **Контракт командного модуля — суворий (F12):** усе людське команда пише через `Write-Host`; у success
  stream повертається лише `$null` або `{ExitCode:int; …}`. Диспетчер `kit.ps1` забирає success stream у
  змінну й **не виводить** його — рядок, повернений командою (у т.ч. `Write-Output`), до stdout не дійде.
  Виклики функцій, які щось повертають, або присвоюються, або йдуть у `| Out-Null` / `$null = …`.
- **Параметри скриптів, що викликаються через `pwsh -File` (F11):** лише скалярні; масив `[string[]]`
  розкладається на CLI-токени, і дочірній зв'язувач бере перший. Список — рядок із роздільником (`-Csv`).
- **Конвенція масивів (знахідка виконавця B1, F7):** кома-обгортка `, $array` у поверненні й `@(…)` у
  викликача **несумісні** — `@(F)` над `, $a` бачить один елемент (перевірено на pwsh 7.5.4). На кожну функцію
  одна конвенція разом із її викликачами: або без коми й усі викликачі загортають у `@(…)`, або з комою й
  викликачі беруть результат присвоєнням чи `(F)`. Об'єкти-колекції, які pipeline розгортає (HashSet, List),
  повертати лише з комою (або `Write-Output -NoEnumerate`). Кожна кома в коді планів має коментар «навмисно».
- **Злиття в тестах (знахідка виконавця B1, F9):** `pre-merge-commit` git викликає лише при **чистому**
  авто-злитті; на конфлікті хука немає взагалі, а `HEAD` не рухається сам собою. Тому (а) тест, що перевіряє
  хук злиття, мусить спершу довести, що злиття чисте; (б) дерева `main` і дзеркала у фікстурах не мають
  колізій за шляхом із різним вмістом, якщо тест не про конфлікт. `New-KitFakeRepo` кладе на `main` фейковий
  `<ws>/cfe/src/Configuration.xml` — перед реплеєм справжнього сховища в те саме дерево його треба прибрати з `main`.

### Рішення, узгоджені з архітектором

| # | Питання | Рішення | Де в спеці |
|---|---|---|---|
| Q8 | версія для `verify <ref>` | трейлер `Storage-Version` коміту `git merge-base <ref> storage/X`; для `verify storage/X` це вершина; порожній merge-base → зупинка «спершу sync»; версії після merge-base — окремий інформаційний рядок | §3.5 |
| Q4 | звірочний коміт | `Merge-KitBranchInto` (B2) з тими самими трьома випадками | §3.4 |
| — | вихід із git для порівняння | сирі блоби (`cat-file --batch`), не `archive`/checkout — інакше «лише CR» діагностував би робочу копію, а не git | принцип 6 |

---

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `tools/lib/StoragePlatform.psm1` | **новий.** `Get-KitRepositoryArguments`, `New-KitStorageInfobase`, `Invoke-KitStorageCheckout` (UpdateCfg + дамп у теку), `Enter-KitStorageBind`/`Exit-KitStorageBind` | 1 |
| `tools/commands/sync.psm1` | використовує `StoragePlatform.psm1` замість інлайн-викликів | 1 |
| `tools/lib/V8.psm1` | `Test-V8InfobaseBusy`, `Assert-V8InfobaseNotBusy` — тексти «зайнято» трьома мовами | 2 |
| `tools/lib/TreeCompare.psm1` | **новий.** `Export-KitTree` (сирі блоби), `Get-KitBinaryPaths` (`git check-attr binary`), `Compare-KitTrees` (п'ять категорій) | 3 |
| `tools/lib/StorageBranch.psm1` | + `Get-KitVerifyVersion` (merge-base і трейлер), `Get-KitStorageActivity` (mtime `data/objects`) | 4, 6 |
| `tools/commands/verify.psm1` | **новий.** `Invoke-KitVerify` | 4 |
| `tools/commands/dump.psm1` | **новий.** `Invoke-KitDump` | 5 |
| `tools/commands/session-check.psm1` | **новий.** `Invoke-KitSessionCheck` | 6 |
| `tools/dump-config.ps1` | **вилучається** (стає `kit dump`) | 5 |
| `tools/lib/module-order.txt` | + `StoragePlatform`, `TreeCompare` | 1, 3 |
| `tools/tests/V8.Tests.ps1`, `TreeCompare.Tests.ps1`, `Verify.Tests.ps1`, `Dump.Tests.ps1`, `SessionCheck.Tests.ps1`, `StorageBranch.Tests.ps1` | тести | 2–6 |
| `skills/storage-pipeline/SKILL.md`, `templates/CLAUDE.md`, `CLAUDE.md`, `docs/follow-ups.md` | перехідні позначки: `dump-config.ps1` → `kit dump`; §14 follow-ups закрито | 5, 7 |

---

## Спільні контракти блоку

```
StoragePlatform.psm1
  Get-KitRepositoryArguments -Source : → @('/ConfigurationRepositoryF "…"', '/ConfigurationRepositoryN "…"', '/ConfigurationRepositoryP ""')
  New-KitStorageInfobase -Source -WorkDir -StubPath : → IbSwitch (EXTENSION — стаб під ім'ям джерела; CONFIGURATION — порожня ІБ)
  Enter-KitStorageBind -IbSwitch -Source : → bool (чи прив'язано; лише CONFIGURATION і лише коли $script:ConfigurationStorageNeedsBind)
  Exit-KitStorageBind  -IbSwitch -Source -Bound
  Invoke-KitStorageCheckout -IbSwitch -Source -Version <int> -Target <тека> : очищає Target, UpdateCfg -v Version [-Extension], DumpConfigToFiles у Target; прибирає ConfigDumpInfo.xml/DumpFilesIndex.txt

V8.psm1 (додається)
  Test-V8InfobaseBusy -Output : → bool
  Assert-V8InfobaseNotBusy -Output -Infobase <опис> : зупинка з порадою «закрийте Конфігуратор», якщо Busy

TreeCompare.psm1
  Export-KitTree -RepoRoot -Ref -RepoPath -Destination : → кількість файлів; байти = блоби git (без конверсії)
  Get-KitBinaryPaths -RepoRoot -RepoPath -RelativePaths <string[]> : → HashSet відносних шляхів з атрибутом binary
  Compare-KitTrees -DumpDir -TreeDir -BinaryPaths <HashSet> : → {Equal:int; CrOnly:string[]; Content:string[]; OnlyInDump:string[]; OnlyInTree:string[]; Total:int}

StorageBranch.psm1 (додається)
  Get-KitVerifyVersion -RepoRoot -Ref -Branch : → {Version:int; Commit:sha; NewerVersions:int[]}; зупинка, якщо merge-base порожній
  Get-KitStorageActivity -StoragePath : → {Accessible:bool; LatestObjectWrite:datetime|$null; Reason}
  Test-KitBranchUnborn -RepoRoot -Branch : → bool (HEAD — ненароджена гілка з цим ім'ям: symbolic-ref HEAD = refs/heads/<Branch>, а ref не існує)

commands
  Invoke-KitVerify -Context [-Workspace] [-Source] [-Apply] [-Ref <string>] [-Version <int>]
      : → {ExitCode: 0 рівні | 3 є розбіжності; Results: @({Key; Ref; Version; Verdict:'equal'|'ref-ahead'|'storage-ahead'|'mixed'; Diff; Merged})}
  Invoke-KitDump -Context [-Workspace] [-Source] [-Apply]
      : → {ExitCode; Dumped: @({Key; Target; Files})}
  Invoke-KitSessionCheck -Context [-Workspace] [-Source] [-Apply] [-AsJson]
      : → {ExitCode 0|1|3; CheckFindings; Signals} (спека §5, 72ccb2f, a7a5d45: «дзеркало є, головної гілки немає» — 3, не 1: незлиті = усі коміти дзеркала, дія відома; розрізнювач Test-KitBranchUnborn — свіжий репо (info, «зробіть перший коміт») чи описка в mainBranch (warn, «перевірте mainBranch:»); спершу Invoke-KitCheck -Quiet тим самим контекстом; error у check → 1, сигнали НЕ обчислюються; лише warn → [!]-рядки над сигналами, код від сигналів: 1 — хоч одне джерело «стан git не прочитано»; 3 — хоч один сигнал дії; 0 — тиша; «сховище недоступне» — 0 з рядком). Signals: @({Key; Branch; MirrorExists; LastMirrorDate; StorageWrite; NewInStorage:bool; UnmergedCommits:int; Accessible; Text})}
```

**Коди виходу `kit.ps1`** (єдина таблиця для всіх команд; коментар і код диспетчера мають їй відповідати —
станом на B2 диспетчер віддавав `2` на будь-який `throw`, що злипалось із частковим успіхом `sync`; B3 Task 4
Step 5а це виправляє):
`0` — виконано (для `check` — і лише з warn: warn — стан машини, автоматику не блокує); `1` — будь-яка зупинка: `throw` у команді, провал префлайту, невідома команда, `check` з помилками; коди задані ЗА ЗМІСТОМ (спека §5, 93f2052): 2 — стан змінено частково, рішення за людиною; 3 — нічого не змінено, але є що робити; `2` — `sync`: дзеркало оновлено, злиття в
головну гілку не виконано (команда відпрацювала, дія лишилась людині); `3` — `verify`: є що робити
(`ref-ahead`/`storage-ahead`/`mixed`) і `session-check`: є сигнал. Нові команди беруть із цієї таблиці, а не вигадують своє.

Робочі теки: `build/verify/<ключ>/{ib,dump,tree}`; `dump` пише прямо в `<воркспейс>/<шлях
source-set>` (це і є ціль). `session-check` файлів не створює.

---

### Task 1: `StoragePlatform.psm1` — спільний платформний шар для `sync` і `verify`

`verify` потребує рівно того самого, що й реплей одної версії в `sync`: тимчасова ІБ →
`UpdateCfg -v N` → дамп у теку. Виносимо з `sync.psm1` у lib; `sync` починає користуватись
цим шаром. Поведінка `sync` не змінюється — це підтверджують наявні тести.

**Files:**
- Create: `tools/lib/StoragePlatform.psm1`
- Modify: `tools/commands/sync.psm1` — виклики через новий модуль; `$script:ConfigurationStorageNeedsBind` переїжджає в lib
- Modify: `tools/lib/module-order.txt` — `StoragePlatform` після `StorageReport`
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` — `RequiredCommands` + `Invoke-KitStorageCheckout`, `New-KitStorageInfobase`
- Create: `tools/tests/StoragePlatform.Tests.ps1`

**Interfaces:**
- Consumes: `New-ExtensionInfobase`, `New-V8FileInfobase`, `Invoke-V8Designer`, `Assert-SafeWorkPath`.
- Produces: `Get-KitRepositoryArguments`, `Get-KitExtensionArgument`, `New-KitStorageInfobase`, `Enter-KitStorageBind`, `Exit-KitStorageBind`, `Invoke-KitStorageCheckout` (сигнатури — у «Спільних контрактах»).

- [ ] **Step 1: Тест `tools/tests/StoragePlatform.Tests.ps1`, що падає** (чисті функції; платформа не потрібна)

```powershell
#Requires -Version 7
Describe 'StoragePlatform.psm1 — аргументи платформи для сховища' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StoragePlatform.psm1").Path -Force
        $script:Ext = [pscustomobject]@{ Key = 'SMP_X'; Type = 'EXTENSION';     StoragePath = 'R:\S\X'; StorageUser = 'gitbot'; StoragePassword = '' }
        $script:Cfg = [pscustomobject]@{ Key = 'base';  Type = 'CONFIGURATION'; StoragePath = 'R:\S\C'; StorageUser = 'Alpen'; StoragePassword = 'secret' }
        $script:Epf = [pscustomobject]@{ Key = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; StoragePath = ''; StorageUser = ''; StoragePassword = '' }
    }

    It 'три аргументи підключення до сховища; користувач і пароль — із джерела (пароль лише з накладки, B2 Task 2a)' {
        $a = Get-KitRepositoryArguments -Source $script:Cfg
        $a | Should -Be @('/ConfigurationRepositoryF "R:\S\C"', '/ConfigurationRepositoryN "Alpen"', '/ConfigurationRepositoryP "secret"')
        (Get-KitRepositoryArguments -Source $script:Ext)[2] | Should -Be '/ConfigurationRepositoryP ""'
    }

    It '-Extension лише для EXTENSION, і з іменем джерела' {
        Get-KitExtensionArgument -Source $script:Ext | Should -Be ' -Extension SMP_X'
        Get-KitExtensionArgument -Source $script:Cfg | Should -Be ''
    }

    It 'New-KitStorageInfobase відмовляє зовнішнім обробкам до звернення до платформи' {
        { New-KitStorageInfobase -Source $script:Epf -WorkDir $TestDrive } | Should -Throw '*EXTERNAL_DATA_PROCESSORS*'
        Join-Path $TestDrive 'ib' | Should -Not -Exist
    }

    It 'Enter-KitStorageBind для розширення — завжди $false і без платформи' {
        Enter-KitStorageBind -IbSwitch '/F "x"' -Source $script:Ext | Should -BeFalse
    }
}
```

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: Реалізація `tools/lib/StoragePlatform.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/V8.psm1"

# Результат спайку B2 (спека §14, «Результат спайку»): чи потребує UpdateCfg для ОСНОВНОЇ
# конфігурації прив'язки ІБ до сховища. $true — kit робить ConfigurationRepositoryBindCfg під
# користувачем сховища на час роботи й знімає її UnbindCfg -force у finally: єдиний запис у
# сховище, який kit виконує. Значення перенесено з tools/commands/sync.psm1 (B2).
$script:ConfigurationStorageNeedsBind = $false
$script:DefaultStubPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/empty-extension'))
$script:PlatformJunk = @('ConfigDumpInfo.xml', 'DumpFilesIndex.txt')

function Get-KitRepositoryArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    # Кома навмисно: викликачі роблять (Get-KitRepositoryArguments …) + @(…), НЕ @(…) — див. F7.
    , @(
        '/ConfigurationRepositoryF "{0}"' -f $Source.StoragePath
        '/ConfigurationRepositoryN "{0}"' -f $Source.StorageUser
        '/ConfigurationRepositoryP "{0}"' -f $Source.StoragePassword   # пароль лише з накладки (B2 Task 2a); ніколи не друкувати
    )
}

function Get-KitExtensionArgument {
    <# -Extension належить команді-дії (ранбук, п. 1); для конфігурації — порожньо. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    if ($Source.Type -eq 'EXTENSION') { return " -Extension $($Source.Key)" }
    ''
}

function New-KitStorageInfobase {
    <#
    .SYNOPSIS
        Тимчасова ІБ під <WorkDir>/ib для читання сховища: розширення — зі стабом під іменем
        джерела (без нього сховище розширень відповідає «расширение … не найдено»);
        конфігурація — порожня ІБ.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$StubPath = $script:DefaultStubPath
    )
    $ibPath = Join-Path $WorkDir 'ib'
    switch ($Source.Type) {
        'EXTENSION'     { return (New-ExtensionInfobase -Path $ibPath -ExtensionName $Source.Key -StubPath $StubPath -MustBeUnder $WorkDir) }
        'CONFIGURATION' { return ('/F "{0}"' -f (New-V8FileInfobase -Path $ibPath -MustBeUnder $WorkDir)) }
        default         { throw "Джерело '$($Source.Key)' має тип $($Source.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION." }
    }
}

function Enter-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source)
    if ($Source.Type -ne 'CONFIGURATION' -or -not $script:ConfigurationStorageNeedsBind) { return $false }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
    if ($r.ExitCode -ne 0) { throw "Прив'язка тимчасової ІБ до сховища конфігурації не вдалася: $($r.Output)" }
    $true
}

function Exit-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source, [Parameter(Mandatory)][bool]$Bound)
    if (-not $Bound) { return }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) + @('/ConfigurationRepositoryUnbindCfg -force'))
    if ($r.ExitCode -ne 0) { Write-Host "УВАГА: не вдалося зняти прив'язку тимчасової ІБ до сховища ($($Source.StoragePath)): $($r.Output)" -ForegroundColor Red }
}

function Invoke-KitStorageCheckout {
    <#
    .SYNOPSIS
        Версія сховища → порожня тека: UpdateCfg -v N [-Extension], DumpConfigToFiles, без службових файлів платформи.
        Повертає кількість файлів у дампі.
    .DESCRIPTION
        ПАСТКА ПЛАТФОРМИ (спайк B2, 8.3.27.1644): /ConfigurationRepositoryUpdateCfg -v НЕ валідує аргумент —
        `-v 1 2 3 … 65` (список замість числа) платформа приймає, повертає 0 і «успешно завершено». Тому
        -Version тут типізований [int] (скаляр, масив у нього не пролізе), а викликачі передають рівно
        $v.Version з циклу. Інваріант «одна версія — один коміт» тримає verify, не sync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IbSwitch,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][int]$Version,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$MustBeUnder
    )
    $ext = Get-KitExtensionArgument -Source $Source
    $upd = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @(('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $Version, $ext)))
    if ($upd.ExitCode -ne 0) { throw "Оновлення до версії $Version не вдалося: $($upd.Output)" }

    # /DumpConfigToFiles не видаляє зниклих об'єктів — тека завжди порожня перед дампом.
    Assert-SafeWorkPath -Path $Target -MustBeUnder $MustBeUnder -Description "тека дампу версії $Version"
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $dump = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $Target, $ext))
    if ($dump.ExitCode -ne 0) { throw "Вивантаження версії $Version не вдалося: $($dump.Output)" }

    foreach ($junk in $script:PlatformJunk) {
        $j = Join-Path $Target $junk
        if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force }
    }
    @(Get-ChildItem -LiteralPath $Target -Recurse -File).Count   # @() обов'язкове: один файл дав би скаляр без .Count
}

Export-ModuleMember -Function Get-KitRepositoryArguments, Get-KitExtensionArgument, New-KitStorageInfobase, Enter-KitStorageBind, Exit-KitStorageBind, Invoke-KitStorageCheckout
```

- [ ] **Step 4: `sync.psm1` — через новий шар**

Вилучити з `sync.psm1` `$script:ConfigurationStorageNeedsBind` (значення зі спайку тепер у
`StoragePlatform.psm1` — перенести його) і `Get-KitRepositoryArguments`. У `Invoke-KitSync`:

- блок створення ІБ (`if ($src.Type -eq 'EXTENSION') {…} else {…}` і `$extArg`) →
  `$ibSwitch = New-KitStorageInfobase -Source $src -WorkDir $workDir`;
- `$extName` для `Get-StorageVersions` → `-ExtensionName $(if ($src.Type -eq 'EXTENSION') { $src.Key } else { '' })`;
- прив'язка: `$bound = Enter-KitStorageBind -IbSwitch $ibSwitch -Source $src` після `New-KitStorageWorktree`, у `finally` — `Exit-KitStorageBind -IbSwitch $ibSwitch -Source $src -Bound $bound` перед `Remove-KitStorageWorktree`;
- тіло циклу версій: рядки з `$upd`, `Clear-KitWorktreeSource`, `$dump` → один виклик (після цього `sync`
  `Clear-KitWorktreeSource` не кличе; функція **лишається** експортованою й покритою тестами як сервісний
  хелпер worktree — не мертвий код, а частина контракту StorageBranch.psm1)
  `$null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path`.

`module-order.txt`: додати `StoragePlatform` після `StorageReport`. У `ModuleImportOrder.Tests.ps1`
до `RequiredCommands` додати `'New-KitStorageInfobase', 'Invoke-KitStorageCheckout', 'Enter-KitStorageBind', 'Exit-KitStorageBind'`.

- [ ] **Step 4а: Два хвости B2 (фінальне рев'ю B2), закрити тут, бо цей Task і так чіпає sync і StorageBranch**

1. `Remove-KitStorageWorktree` у B2 замінив `throw` на попередження, щоб виняток із `finally` не витісняв
   дослівний текст помилки платформи; що первинний виняток справді доходить — живим прогоном **не доведено**.
   Тест у `StorageBranch.Tests.ps1` без платформи: створити worktree, відкрити файл усередині нього з
   `[System.IO.File]::Open($path, 'Open', 'Read', 'None')` (блокує видалення теки на Windows), потім
   `{ try { throw 'ПЛАТФОРМА-ВПАЛА' } finally { Remove-KitStorageWorktree -RepoRoot $repo -Path $wt } } |
   Should -Throw '*ПЛАТФОРМА-ВПАЛА*'` — саме первинний текст, не помилка worktree; після закриття дескриптора
   `git worktree prune` + повторний `Remove-KitStorageWorktree` прибирають теку.
2. `GitMerge.psm1` і `StorageBranch.psm1` беруть `git branch --show-current 2>&1` і використовують `$current`
   і в порівнянні, і в тексті помилки: будь-який stderr при коді 0 (наприклад, `safe.directory`) зробить
   порівняння хибним. Замінити на `$current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()`
   з перевіркою `$LASTEXITCODE` (та сама правка, що B2 зробив для `$dirty`). Тест: репозиторій із
   `-c advice.*`? — ні, stderr при коді 0 штучно не відтворюється надійно; достатньо, що обидва місця
   перевіряють код і беруть лише stdout — рев'ю читанням.

- [ ] **Step 5: Тести зелені** (без Integration); `Sync.Tests.ps1` без платформи має лишитись зеленим без змін.

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/StoragePlatform.psm1 tools/commands/sync.psm1 tools/lib/module-order.txt tools/tests/StoragePlatform.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1 tools/lib/StorageBranch.psm1 tools/lib/GitMerge.psm1 tools/tests/StorageBranch.Tests.ps1
git commit -m "B3: StoragePlatform.psm1 — спільний шар «версія сховища → дамп» для sync і verify"
```

---

### Task 2: розпізнавання «база зайнята» (§5)

**Files:**
- Modify: `tools/lib/V8.psm1` — `$script:InfobaseBusyPatterns`, `Test-V8InfobaseBusy`, `Assert-V8InfobaseNotBusy`
- Modify: `tools/tests/V8.Tests.ps1` — новий Describe

**Interfaces:**
- Produces: `Test-V8InfobaseBusy -Output` → `bool`; `Assert-V8InfobaseNotBusy -Output -Infobase` → зупинка з порадою.

- [ ] **Step 1: Тест, що падає** (у `V8.Tests.ps1`)

```powershell
Describe 'V8.psm1 — розпізнавання «база зайнята» (спека §5)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }

    It 'російський, український і англійський тексти платформи розпізнаються' -ForEach @(
        @{ Text = 'Ошибка блокировки информационной базы для конфигурирования. Информационная база уже открыта Конфигуратором' }
        @{ Text = 'Не удалось монопольно заблокировать информационную базу' }
        @{ Text = 'Помилка блокування інформаційної бази для конфігурування' }
        @{ Text = 'Не вдалося монопольно заблокувати інформаційну базу' }
        @{ Text = 'Error locking infobase for configuration. The infobase is already opened by Designer' }
        @{ Text = 'Failed to lock the infobase exclusively' }
    ) {
        Test-V8InfobaseBusy -Output $Text | Should -BeTrue
    }

    It 'інший текст і порожній вивід — не «зайнято»' {
        Test-V8InfobaseBusy -Output 'Неверные или отсутствующие параметры соединения' | Should -BeFalse
        Test-V8InfobaseBusy -Output '' | Should -BeFalse
    }

    It 'Assert-V8InfobaseNotBusy: порада «закрийте Конфігуратор» першою, сирий текст — у кінці; на іншому тексті мовчить' {
        $raw = 'Информационная база уже открыта Конфигуратором'
        $err = $null
        try { Assert-V8InfobaseNotBusy -Output $raw -Infobase 'devUNF' } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err.IndexOf('закрийте Конфігуратор', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeLessThan $err.IndexOf($raw)
        $err | Should -BeLike '*devUNF*.cfl*'
        { Assert-V8InfobaseNotBusy -Output 'усе гаразд' -Infobase 'devUNF' } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Реалізація у `V8.psm1`** (після `Assert-NoLicenseProblem`)

```powershell
# Тексти з ресурсів платформи про монопольне захоплення ІБ (дослідження, п. 4 спеки). Список
# розширюваний: якщо платформа відповіла іншим формулюванням — додайте його сюди, і тест
# «база зайнята» отримає новий рядок. Файли .cfl індикатором не є — лишаються після закриття.
$script:InfobaseBusyPatterns = @(
    'Ошибка блокировки информационной базы для конфигурирования'
    'уже открыта Конфигуратором'
    'Не удалось монопольно заблокировать информационную базу'
    'Помилка блокування інформаційної бази для конфігурування'
    'вже відкрита Конфігуратором'
    'Не вдалося монопольно заблокувати інформаційну базу'
    'Error locking infobase for configuration'
    'already opened by Designer'
    'Failed to lock the infobase exclusively'
    'Cannot lock the infobase exclusively'
)

function Test-V8InfobaseBusy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    foreach ($p in $script:InfobaseBusyPatterns) {
        if ($Output.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    $false
}

function Assert-V8InfobaseNotBusy {
    <#
    .SYNOPSIS
        Зупинка з порадою, а не сирим повідомленням, коли базу тримає Конфігуратор чи інший
        монопольний сеанс (спека §5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$Infobase
    )
    if (-not (Test-V8InfobaseBusy -Output $Output)) { return }
    throw ("База '$Infobase' зайнята — її відкрито Конфігуратором або іншим монопольним сеансом. Закрийте Конфігуратор " +
           "(для серверної бази — перевірте сеанси: rac session list, якщо піднято ras) і повторіть. Файли .cfl " +
           "індикатором не є — вони лишаються після закриття.`nПлатформа відповіла: $Output")
}
```

Додати обидві до `Export-ModuleMember`.

- [ ] **Step 3: Тести зелені; коміт**

```bash
git add tools/lib/V8.psm1 tools/tests/V8.Tests.ps1
git commit -m "B3: розпізнавання «база зайнята» трьома мовами — порада замість сирого тексту"
```

---

### Task 3: `TreeCompare.psm1` — дерево з git сирими блобами й класифікація розбіжностей (§3.5)

**Встановлений факт (перевірено в цій сесії):** і `git archive`, і checkout застосовують
`eol=`-конверсію з `.gitattributes`: файл із LF-блобом під `* text eol=crlf` виходить із CRLF.
Тому дерево для порівняння беремо **сирими блобами** через `git cat-file --batch`, читаючи
stdout як байтовий потік (.NET `Process`), — так «лише CR» означає «git-об'єкт розійшовся з
платформою», а не «ця машина інакше налаштована».

**Files:**
- Create: `tools/lib/TreeCompare.psm1`
- Create: `tools/tests/TreeCompare.Tests.ps1`
- Modify: `tools/lib/module-order.txt` — `TreeCompare` після `GitMerge`

**Interfaces:**
- Consumes: `Assert-SafeWorkPath`.
- Produces: `Export-KitTree -RepoRoot -Ref -RepoPath -Destination` → int; `Get-KitBinaryPaths -RepoRoot -RepoPath -RelativePaths` → `HashSet[string]`; `Compare-KitTrees -DumpDir -TreeDir -BinaryPaths` → `{Equal; CrOnly; Content; OnlyInDump; OnlyInTree; Total}`; `Get-KitRelativeFiles -Root` → `string[]` (відносні шляхи з `/`, без службових файлів).

- [ ] **Step 1: Тест `tools/tests/TreeCompare.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'TreeCompare.psm1 — дерево з git як сирі блоби' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'байти дорівнюють блобу навіть під * text eol=crlf і core.autocrlf=true; кириличні шляхи й вкладені теки цілі' {
        # ПОРЯДОК ВАЖЛИВИЙ (рев'ю B3, доведено пробою): явний атрибут `text` нормалізує блоб у LF на вході
        # незалежно від core.autocrlf, тож .gitattributes кладеться ПІСЛЯ коміту змішаного файла. Переставляти
        # кроки можна; послаблювати твердження нижче — ні: вони і є гарантія, заради якої існує Export-KitTree.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'raw')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/Forms/Форма/Ext'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $mixed = [byte[]](0x3C,0x61,0x3E,0x0D,0x0A,0x74,0x0A,0x74,0x3C,0x2F,0x61,0x3E)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'Form.xml'), $mixed)
        git -C $repo -c core.autocrlf=false add -A
        git -C $repo commit -q -m 'змішані кінці рядків як є'
        $rawId = (git -C $repo hash-object --no-filters (Join-Path $dir 'Form.xml')).Trim()
        (git -C $repo rev-parse 'main:Alpha_SMB/cfe/src/Forms/Форма/Ext/Form.xml').Trim() | Should -Be $rawId -Because 'блоб мусить лишитись змішаним — інакше тест перевіряє не те'
        # Тепер — умови, за яких checkout і archive конвертують, а Export-KitTree не має:
        git -C $repo config core.autocrlf true
        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value '* text eol=crlf' -Encoding ascii
        git -C $repo add .gitattributes
        git -C $repo commit -q -m 'політика eol=crlf після факту'

        $dest = Join-Path $repo 'build/verify/x/tree'
        $n = Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination $dest
        $n | Should -Be 2   # Configuration.xml фікстури + Form.xml
        $exported = Join-Path $dest 'Forms/Форма/Ext/Form.xml'
        $exported | Should -Exist
        [System.IO.File]::ReadAllBytes($exported) | Should -Be $mixed
        (git -C $repo hash-object --no-filters $exported).Trim() | Should -Be $rawId
    }

    It 'шлях, якого немає в ref — 0 файлів, порожня тека' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty')
        $dest = Join-Path $repo 'build/verify/x/tree'
        Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Nope/cfe/src' -Destination $dest | Should -Be 0
        @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count | Should -Be 0
    }

    It 'призначення поза build/ — відмова' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsafe')
        { Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination (Join-Path $repo 'Alpha_SMB') } | Should -Throw '*build*'
    }
}

Describe 'TreeCompare.psm1 — класифікація розбіжностей (§3.5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        $script:Dump = Join-Path $TestDrive 'dump'
        $script:Tree = Join-Path $TestDrive 'tree'
        foreach ($d in $script:Dump, $script:Tree) { New-Item -ItemType Directory -Path (Join-Path $d 'Ext') -Force | Out-Null }
        function script:W { param($Root, $Rel, [byte[]]$Bytes) [System.IO.File]::WriteAllBytes((Join-Path $Root $Rel), $Bytes) }
        $lf   = [System.Text.Encoding]::UTF8.GetBytes("a`nb`n")
        $crlf = [System.Text.Encoding]::UTF8.GetBytes("a`r`nb`r`n")
        $other = [System.Text.Encoding]::UTF8.GetBytes("a`nc`n")

        W $script:Dump 'equal.xml' $lf;        W $script:Tree 'equal.xml' $lf
        W $script:Dump 'cr-only.xml' $lf;      W $script:Tree 'cr-only.xml' $crlf
        W $script:Dump 'content.bsl' $lf;      W $script:Tree 'content.bsl' $other
        W $script:Dump 'only-dump.xml' $lf
        W $script:Tree 'only-tree.xml' $lf
        W $script:Dump 'Ext/pic.png' $lf;      W $script:Tree 'Ext/pic.png' $crlf      # binary: лише побайтово
        W $script:Dump 'ConfigDumpInfo.xml' $lf                                          # завжди ігнорується
        W $script:Tree 'DumpFilesIndex.txt' $lf                                          # завжди ігнорується

        $script:Binary = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $script:Binary.Add('Ext/pic.png') | Out-Null
    }

    It 'п''ять категорій, бінарник із різницею лише в CR — змістовна, службові файли не рахуються' {
        $r = Compare-KitTrees -DumpDir $script:Dump -TreeDir $script:Tree -BinaryPaths $script:Binary
        $r.Equal | Should -Be 1
        $r.CrOnly | Should -Be @('cr-only.xml')
        $r.Content | Should -Be @('Ext/pic.png', 'content.bsl')   # ordinal: 'E' (0x45) < 'c' (0x63); Sort-Object дав би навпаки
        $r.OnlyInDump | Should -Be @('only-dump.xml')
        $r.OnlyInTree | Should -Be @('only-tree.xml')
        $r.Total | Should -Be 6
    }

    It 'Get-KitRelativeFiles: шляхи з /, без ConfigDumpInfo.xml і DumpFilesIndex.txt' {
        $files = @(Get-KitRelativeFiles -Root $script:Dump)
        $files | Should -Contain 'Ext/pic.png'
        $files | Should -Not -Contain 'ConfigDumpInfo.xml'
    }

    It 'Get-KitBinaryPaths не зависає на обсязі реального дампу (800 кириличних шляхів)' {
        # Проба рев'ю B3: наївний «увесь stdin, потім ReadToEnd()» зависав назавжди від ~800 записів (буфер stdout).
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bulk') -WithGitattributes
        $paths = @(1..800 | ForEach-Object { "Catalogs/ДовгеІмʼяОбʼєкта_$_.xml" }) + @('Ext/pic.png')
        $set = Get-KitBinaryPaths -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -RelativePaths $paths
        $set.Contains('Ext/pic.png') | Should -BeTrue
        $set.Count | Should -Be 1
    }

    It 'Get-KitBinaryPaths питає git check-attr, а не читає .gitattributes' {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'attr') -WithGitattributes
        $set = Get-KitBinaryPaths -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -RelativePaths @('Ext/pic.png', 'Forms/Форма.xml', 'Ext/driver.bin')
        $set.Contains('Ext/pic.png') | Should -BeTrue
        $set.Contains('Ext/driver.bin') | Should -BeTrue
        $set.Contains('Forms/Форма.xml') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: Реалізація `tools/lib/TreeCompare.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

$script:PlatformJunk = @('ConfigDumpInfo.xml', 'DumpFilesIndex.txt')

function Read-KitStreamLine {
    # Рядок до \n із байтового потоку (заголовок cat-file --batch: "<sha> blob <size>").
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while (($b = $Stream.ReadByte()) -ge 0) {
        if ($b -eq 10) { break }
        $bytes.Add([byte]$b)
    }
    [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Copy-KitStreamBytes {
    param([Parameter(Mandatory)][System.IO.Stream]$From, [Parameter(Mandatory)][System.IO.Stream]$To, [Parameter(Mandatory)][int64]$Count)
    $buffer = New-Object byte[] 65536
    $left = $Count
    while ($left -gt 0) {
        $n = $From.Read($buffer, 0, [int][Math]::Min($buffer.Length, $left))
        if ($n -le 0) { throw 'Потік git cat-file обірвався до кінця блоба.' }
        $To.Write($buffer, 0, $n)
        $left -= $n
    }
}

function Invoke-KitGitProcess {
    <#
    .SYNOPSIS
        git як .NET Process: NUL-роздільники на вході (для -z --stdin), UTF-8 без перекодування PowerShell на
        виході, stderr окремо, код виходу — у результаті. Для потокових байтів (cat-file --batch) є Export-KitTree.
    .DESCRIPTION
        ОБИДВА вихідні потоки читаються асинхронно ДО запису stdin — це не стиль, а причина (проба рев'ю B3):
        наївна форма «записати весь stdin, потім ReadToEnd()» на 800 шляхах зависає назавжди — буфер stdout
        заповнюється, git блокується на записі й перестає читати stdin, а наш Write блокується назустріч.
        На двох шляхах у юніт-тесті цього не видно; вилазить на живому verify. Не «спрощувати» назад.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowEmptyCollection()][string[]]$StdinRecords = @()
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in (@('-C', $RepoRoot) + $Arguments)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()   # ДО запису stdin — інакше дедлок на великому виводі
        foreach ($rec in $StdinRecords) { $proc.StandardInput.Write($rec); $proc.StandardInput.Write([char]0) }
        $proc.StandardInput.Close()
        $stdout = $outTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $errTask.Result }
    } finally { $proc.Dispose() }
}

function Export-KitTree {
    <#
    .SYNOPSIS
        Дерево <Ref>:<RepoPath> у теку Destination — байт-у-байт із блобів git.
    .DESCRIPTION
        git archive і checkout застосовують eol-конверсію з .gitattributes (перевірено), а нам
        треба те, що ЛЕЖИТЬ у git: інакше «лише CR» діагностував би налаштування машини, а не
        стан репозиторію. Один процес cat-file --batch, запит-відповідь по блобу, stdout читаємо
        як байти через .NET Process — PowerShell-конвейєр перекодовував би вміст.
        Дедлоку, який ловить Invoke-KitGitProcess, тут НЕМАЄ і переробляти на асинхронне читання не
        треба: запис і читання чергуються по одному блобу — git не приймає наступного запиту, доки
        попередню відповідь не вичитано (проба рев'ю B3). stderr — асинхронно, бо його обсяг невідомий.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-SafeWorkPath -Path $Destination -MustBeUnder (Join-Path $RepoRoot 'build') -Description 'тека вивантаження дерева git'
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    # -z: шляхи сирі, NUL-роздільник — незалежно від core.quotepath машини (без -z кирилиця прийшла б екранованою в лапках).
    $raw = git -C $RepoRoot -c core.quotepath=false ls-tree -r -z $Ref -- $prefix 2>$null   # stderr не змішувати з даними
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree $Ref -- $prefix завершився з кодом ${LASTEXITCODE}." }
    $entries = @((@($raw) -join '') -split "`0" | Where-Object { $_ })
    if ($entries.Count -eq 0) { return 0 }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in @('-C', $RepoRoot, 'cat-file', '--batch')) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [System.Text.Encoding]::ASCII
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()   # читати асинхронно, інакше повний буфер stderr заблокує git
    $stdin = $proc.StandardInput
    $out   = $proc.StandardOutput.BaseStream
    $exit  = -1; $stderr = ''

    $count = 0
    try {
        foreach ($entry in $entries) {
            if ($entry -notmatch '^(?<mode>\d+) (?<type>\w+) (?<sha>[0-9a-f]{40})\t(?<path>.+)$') {
                throw "Нерозпізнаний рядок git ls-tree: '$entry'"
            }
            if ($Matches['type'] -ne 'blob') { continue }
            $sha = $Matches['sha']
            $rel = $Matches['path'].Substring($prefix.Length).TrimStart('/')

            $stdin.WriteLine($sha)
            $stdin.Flush()
            $header = Read-KitStreamLine -Stream $out
            if ($header -notmatch '^[0-9a-f]{40} blob (?<size>\d+)$') { throw "git cat-file --batch: неочікуваний заголовок '$header' для $rel" }
            $size = [int64]$Matches['size']

            $file = Join-Path $Destination $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            $fs = [System.IO.File]::Create($file)
            try { Copy-KitStreamBytes -From $out -To $fs -Count $size } finally { $fs.Dispose() }
            $out.ReadByte() | Out-Null   # завершальний \n після вмісту блоба
            $count++
        }
    } finally {
        $stdin.Close()
        $proc.WaitForExit()
        $exit = $proc.ExitCode; $stderr = $errTask.Result
        $proc.Dispose()
    }
    # .NET Process — теж нативний виклик: код виходу перевіряється, як і в кожного git.
    if ($exit -ne 0) { throw "git cat-file --batch завершився з кодом ${exit}: $stderr" }
    $count
}

function Get-KitRelativeFiles {
    <# Відносні шляхи файлів під Root з '/', без службових файлів платформи. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    # Без коми: усі викликачі загортають результат у @(…) — див. F7.
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $full = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File |
        Where-Object { $script:PlatformJunk -notcontains $_.Name } |
        ForEach-Object { $_.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/' })
    $files
}

function Get-KitBinaryPaths {
    <#
    .SYNOPSIS
        Які з відносних шляхів git вважає binary (макрос -text -diff -merge). Питає check-attr,
        а не читає .gitattributes — та сама логіка пріоритетів, що й у checkout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePaths
    )
    # HashSet — IEnumerable, pipeline розгорнув би його в рядки; кома тримає об'єкт цілим (F7).
    # Викликачі беруть результат присвоєнням: $binary = Get-KitBinaryPaths …
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($RelativePaths.Count -eq 0) { return , $set }   # кома навмисно (HashSet, F7)
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $records = @($RelativePaths | ForEach-Object { "$prefix/$_" })
    # -z перемикає і ВХІД на NUL-роздільник: подані через конвеєр рядки з \n git читає як ОДИН шлях, і набір
    # завжди порожній (рев'ю B3, доведено пробою). Тому stdin — через Process із NUL між записами; -z лишається,
    # бо без нього відповідь була б екранована за core.quotepath.
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'check-attr', '-z', 'binary', '--stdin') -StdinRecords $records
    if ($r.ExitCode -ne 0) { throw "git check-attr завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    $fields = @($r.Stdout -split "`0")
    # трійки: <шлях> \0 binary \0 <значення> \0
    for ($i = 0; $i + 2 -lt $fields.Count; $i += 3) {
        if ($fields[$i + 2] -eq 'set') { $set.Add($fields[$i].Substring($prefix.Length).TrimStart('/')) | Out-Null }
    }
    , $set   # кома навмисно: HashSet не має розгортатись pipeline; викликач бере присвоєнням (F7)
}

function Compare-KitTrees {
    <#
    .SYNOPSIS
        Класифікація розбіжностей дамп ↔ дерево (спека §3.5): рівні / лише CR / змістовна /
        тільки в дампі / тільки в дереві. binary — лише побайтово.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DumpDir,
        [Parameter(Mandatory)][string]$TreeDir,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$BinaryPaths
    )

    # Ordinal, не IgnoreCase: git регістрочутливий, і два файли, що різняться лише регістром, у дереві ref
    # можуть співіснувати — злиття їх в один сховало б розбіжність (рев'ю B3).
    $dump = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $DumpDir), [System.StringComparer]::Ordinal)
    $tree = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $TreeDir), [System.StringComparer]::Ordinal)
    $all = [System.Collections.Generic.HashSet[string]]::new($dump, [System.StringComparer]::Ordinal)
    $all.UnionWith($tree)

    $equal = 0
    $crOnly = [System.Collections.Generic.List[string]]::new()
    $content = [System.Collections.Generic.List[string]]::new()
    $onlyDump = [System.Collections.Generic.List[string]]::new()
    $onlyTree = [System.Collections.Generic.List[string]]::new()

    # Sort-Object порівнює за культурою: 'content' < 'Ext', а кирилиця йде ПЕРШОЮ ('ЯФайл' < 'content') — тобто
    # результат залежить від локалі машини. Ordinal — детермінований і збігається з git (проба рев'ю B3).
    $ordered = [System.Linq.Enumerable]::OrderBy([string[]]$all, [Func[string, string]] { param($x) $x }, [System.StringComparer]::Ordinal)
    foreach ($rel in $ordered) {
        $inDump = $dump.Contains($rel); $inTree = $tree.Contains($rel)
        if ($inDump -and -not $inTree) { $onlyDump.Add($rel); continue }
        if ($inTree -and -not $inDump) { $onlyTree.Add($rel); continue }
        $a = [System.IO.File]::ReadAllBytes((Join-Path $DumpDir $rel))
        $b = [System.IO.File]::ReadAllBytes((Join-Path $TreeDir $rel))
        if ([System.Linq.Enumerable]::SequenceEqual($a, $b)) { $equal++; continue }
        if ($BinaryPaths.Contains($rel)) { $content.Add($rel); continue }
        $a2 = [byte[]]($a | Where-Object { $_ -ne 13 })
        $b2 = [byte[]]($b | Where-Object { $_ -ne 13 })
        if ([System.Linq.Enumerable]::SequenceEqual($a2, $b2)) { $crOnly.Add($rel) } else { $content.Add($rel) }
    }

    [pscustomobject]@{
        Equal      = $equal
        CrOnly     = $crOnly.ToArray()
        Content    = $content.ToArray()
        OnlyInDump = $onlyDump.ToArray()
        OnlyInTree = $onlyTree.ToArray()
        Total      = $all.Count
    }
}

Export-ModuleMember -Function Invoke-KitGitProcess, Export-KitTree, Get-KitRelativeFiles, Get-KitBinaryPaths, Compare-KitTrees
```

> Фільтрація CR через `Where-Object` на великих файлах повільна; якщо дамп у 500 файлів
> порівнюється довше за 10 с — замінити на цикл із `MemoryStream`, не змінюючи контракту.
> Тест на п'ять категорій цього не помітить, тому вимір — лише на Integration у Task 4.

`module-order.txt`: `TreeCompare` після `GitMerge`. `ModuleImportOrder.Tests.ps1`:
`RequiredCommands` + `'Export-KitTree', 'Compare-KitTrees', 'Get-KitBinaryPaths'`.

- [ ] **Step 4: Тести зелені; коміт**

```bash
git add tools/lib/TreeCompare.psm1 tools/tests/TreeCompare.Tests.ps1 tools/lib/module-order.txt tools/tests/ModuleImportOrder.Tests.ps1
git commit -m "B3: TreeCompare.psm1 — дерево з git сирими блобами, класифікація розбіжностей на п'ять категорій"
```

---

### Task 4: команда `verify` (§3.5, Q8)

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` — `Get-KitVerifyVersion`
- Create: `tools/commands/verify.psm1`
- Create: `tools/tests/Verify.Tests.ps1`
- Modify: `tools/tests/StorageBranch.Tests.ps1` — Describe на `Get-KitVerifyVersion`

**Interfaces:**
- Consumes: `Select-KitSources`, `New-KitStorageInfobase`, `Enter-/Exit-KitStorageBind`, `Invoke-KitStorageCheckout`, `Export-KitTree`, `Get-KitRelativeFiles`, `Get-KitBinaryPaths`, `Compare-KitTrees`, `Merge-KitBranchInto`, `Test-KitBranchExists`.
- Produces: `Get-KitVerifyVersion -RepoRoot -Ref -Branch` → `{Version; Commit; NewerVersions}`; `Invoke-KitVerify -Context [-Workspace] [-Source] [-Apply] [-Ref] [-Version]` → `{ExitCode 0|3; Results}`. Вердикти: `equal`, `ref-ahead`, `storage-ahead`, `mixed`.

- [ ] **Step 1: Тест `Get-KitVerifyVersion`, що падає** (у `StorageBranch.Tests.ps1`, новий Describe)

```powershell
Describe 'StorageBranch.psm1 — версія для verify з merge-base (§3.5, Q8)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'vv') -WithHooks -WithGitattributes -WithGitignore
        foreach ($v in 5, 7) {
            Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
    }

    It 'main ще не зливав дзеркало — зупинка «спершу sync»' {
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB' } | Should -Throw '*sync*'
    }

    It 'verify storage/X — вершина гілки, новіших немає' {
        $r = Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'storage/Alpha_SMB' -Branch 'storage/Alpha_SMB'
        $r.Version | Should -Be 7
        $r.NewerVersions.Count | Should -Be 0
    }

    It 'після злиття: версія = остання злита; нові версії на дзеркалі — окремим списком' {
        Merge-KitBranchInto -RepoRoot $script:Repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        (Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB').Version | Should -Be 7

        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v9.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 9')
        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v12.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 12')
        $r = Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB'
        $r.Version | Should -Be 7
        $r.NewerVersions | Should -Be @(9, 12)
    }

    It 'гілка задачі від main успадковує merge-base' {
        git -C $script:Repo checkout -q -b feature/x
        (Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'feature/x' -Branch 'storage/Alpha_SMB').Version | Should -Be 7
        git -C $script:Repo checkout -q main
    }

    It 'невідомий ref і відсутня гілка дзеркала — зупинки з іменами' {
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'nope' -Branch 'storage/Alpha_SMB' } | Should -Throw "*'nope'*"
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Beta' } | Should -Throw '*storage/Beta*sync*'
    }
}
```

- [ ] **Step 2: Реалізація `Get-KitVerifyVersion` у `StorageBranch.psm1`**

```powershell
function Get-KitVerifyVersion {
    <#
    .SYNOPSIS
        Версія сховища, з якою порівнювати <Ref> (спека §3.5): трейлер коміту
        git merge-base <Ref> storage/X. Для Ref = storage/X — вершина. Версії на дзеркалі
        після merge-base — окремо, як інформація «сховище попереду».
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Branch
    )

    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) {
        throw "Гілки $Branch ще немає — дзеркало не створене. Спершу: kit sync."
    }
    git -C $RepoRoot rev-parse --verify --quiet "$Ref^{commit}" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Ref '$Ref' не знайдено в репозиторії." }

    $base = (git -C $RepoRoot merge-base $Ref $Branch 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $base) {
        throw "'$Ref' ніколи не зливав $Branch — спільного предка немає. Спершу: kit sync (перше злиття в головну гілку), тоді verify."
    }

    $value = (git -C $RepoRoot log -1 --format='%(trailers:key=Storage-Version,valueonly)' $base 2>&1 | Out-String).Trim()
    if ($value -notmatch '^\d+$') { throw "Коміт $($base.Substring(0,7)) (merge-base '$Ref' і $Branch) не має трейлера Storage-Version:. Розбір: kit check." }

    $newerRaw = git -C $RepoRoot log --reverse --format='%(trailers:key=Storage-Version,valueonly)' "$base..$Branch" 2>$null
    # Без перевірки збій git дав би порожній список → хибний equal, коли сховище насправді попереду (рев'ю B3).
    if ($LASTEXITCODE -ne 0) { throw "git log $($base.Substring(0,7))..$Branch завершився з кодом ${LASTEXITCODE} — verify не може визначити, чи є нові версії." }
    $newer = @(@($newerRaw) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

    [pscustomobject]@{ Version = [int]$value; Commit = $base; NewerVersions = $newer }
}
```

Додати до `Export-ModuleMember`.

- [ ] **Step 3: Тест `tools/tests/Verify.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit verify — штатні зупинки до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Verify {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit verify -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'дзеркала ще немає — зупинка «sync», build/verify не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-mirror') -WithHooks
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*storage/Alpha_SMB*sync*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'дзеркало є, але main його не зливав — зупинка «sync» до платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmerged') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*sync*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'без джерел truth: storage — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Verify -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It '-Ref невідомий — зупинка з його ім''ям' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-ref') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo -More @('-Ref', 'nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'nope'*"
    }
}

Describe 'kit verify — живе сховище: рівні → сховище попереду → звірочний коміт → рівні' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item 'R:\github\SMP_BankExchange\AUTHORS' (Join-Path $script:Repo 'AUTHORS') -Force
        # F9: прибрати фейковий Configuration.xml з main — інакше перше злиття дзеркала дасть add/add-конфлікт.
        git -C $script:Repo rm -rq -- SMP_BankExchange_SMB/cfe/src
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS; дерево джерела порожнє до першого sync'
        function script:Run { param([string[]]$Arguments) $out = & pwsh -NoProfile -File $script:Kit @Arguments -RepoRoot $script:Repo 2>&1 | Out-String; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        function script:Complete-Authors {
            param([string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8; $added = $true }
            }
            if ($added) { git -C $script:Repo commit -qam 'AUTHORS: тестові автори' }
            $added
        }
    }

    It 'після першого sync main ≡ сховище (нуль змістовних розбіжностей — знахідка BankExchange)' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 0 -Because $v.Output
        $v.Output | Should -BeLike '*equal*'
        $v.Output | Should -Not -Match '\[-\]'      # -BeLike трактує [-] як клас символів; -Match — літерально
    }

    It 'ще одна версія в дзеркалі — «сховище попереду»; -Apply робить звірочний коміт; далі знову рівні' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 3 -Because $v.Output
        $v.Output | Should -BeLike '*storage-ahead*'
        $mainBefore = git -C $script:Repo rev-parse main
        $a = Run @('verify', '-Apply')
        $a.ExitCode | Should -Be 3 -Because $a.Output     # звірка йшла проти старої версії; коміт зроблено
        (git -C $script:Repo rev-parse main) | Should -Not -Be $mainBefore
        $v2 = Run @('verify')
        $v2.ExitCode | Should -Be 0 -Because $v2.Output
    }
}
```

- [ ] **Step 4: Запустити без Integration — червоно (команди `verify` немає)**

- [ ] **Step 5: Реалізація `tools/commands/verify.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Write-KitDiffList {
    param([string]$Title, [AllowEmptyCollection()][string[]]$Items, [int]$Limit = 20)
    if ($Items.Count -eq 0) { return }
    Write-Host "  $Title ($($Items.Count)):"
    foreach ($i in ($Items | Select-Object -First $Limit)) { Write-Host "    $i" }
    if ($Items.Count -gt $Limit) { Write-Host "    … ще $($Items.Count - $Limit)" }
}

function Invoke-KitVerify {
    <#
    .SYNOPSIS
        Інваріант «<ref> ≡ сховище» (спека §3.5): дерево <ref> за шляхом джерела проти
        канонічного дампу зі сховища на версії з merge-base. Без -Apply нічого не змінює.
    .PARAMETER Ref
        Що звіряти. Типово — головна гілка маніфесту. storage/X — канонічність самого дзеркала.
    .PARAMETER Version
        Явна версія сховища замість версії з трейлера — для розслідувань.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Ref,
        [Nullable[int]]$Version
    )

    $root = $Context.RepoRoot
    $ref  = if ($Ref) { $Ref } else { $Context.MainBranch }
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — звіряти нічого.'
        return [pscustomobject]@{ ExitCode = 0; Results = @() }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $anyAction = $false

    # Усі перевірки git — до першого звернення до платформи: зупинки дешеві, платформа — ні.
    $plan = @(foreach ($src in $sources) {
        # Порядок: спершу інваріанти git (дзеркало, merge-base, ref) — вони перевіряються без сховища й дають
        # точнішу зупинку; шлях сховища — другим (P1 префлайту B3).
        $vv = Get-KitVerifyVersion -RepoRoot $root -Ref $ref -Branch $src.Branch
        if (-not (Test-Path -LiteralPath $src.StoragePath)) { throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)." }
        [pscustomobject]@{ Source = $src; Info = $vv; Version = $(if ($Version) { [int]$Version } else { $vv.Version }) }
    })

    foreach ($item in $plan) {
        $src = $item.Source; $vv = $item.Info; $ver = $item.Version
        Write-Host ''
        Write-Host "Джерело:  $($src.Workspace)/$($src.Key)  ·  ref: $ref  ·  версія сховища: $ver (merge-base $($vv.Commit.Substring(0, 7)))"
        if ($vv.NewerVersions.Count -gt 0) {
            Write-Host "  На $($src.Branch) після злитої версії є: $($vv.NewerVersions -join ', ') — сховище попереду '$ref'." -ForegroundColor Yellow
        }

        $workDir = Join-Path $root 'build/verify' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/verify') -Description "робоча тека verify $($src.Key)"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        Write-Host '  Тимчасова ІБ, версія зі сховища, дамп...'
        $ib = New-KitStorageInfobase -Source $src -WorkDir $workDir
        $bound = Enter-KitStorageBind -IbSwitch $ib -Source $src
        try {
            $dumpCount = Invoke-KitStorageCheckout -IbSwitch $ib -Source $src -Version $ver -Target (Join-Path $workDir 'dump') -MustBeUnder $workDir
        } finally {
            Exit-KitStorageBind -IbSwitch $ib -Source $src -Bound $bound
        }
        $treeDir = Join-Path $workDir 'tree'
        $treeCount = Export-KitTree -RepoRoot $root -Ref $ref -RepoPath $src.RepoPath -Destination $treeDir
        Write-Host "  Файлів: у дампі $dumpCount, у дереві '$ref' $treeCount"

        $allRel = @(@(Get-KitRelativeFiles -Root (Join-Path $workDir 'dump')) + @(Get-KitRelativeFiles -Root $treeDir) | Sort-Object -Unique)
        $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths $allRel
        $diff   = Compare-KitTrees -DumpDir (Join-Path $workDir 'dump') -TreeDir $treeDir -BinaryPaths $binary

        $differs = ($diff.CrOnly.Count + $diff.Content.Count + $diff.OnlyInDump.Count + $diff.OnlyInTree.Count) -gt 0
        $verdict = if (-not $differs -and $vv.NewerVersions.Count -eq 0) { 'equal' }
                   elseif (-not $differs) { 'storage-ahead' }
                   elseif ($vv.NewerVersions.Count -eq 0) { 'ref-ahead' }
                   else { 'mixed' }

        Write-Host "  Побайтово рівних: $($diff.Equal) із $($diff.Total)"
        Write-KitDiffList -Title 'лише CR (зіпсована політика тексту — docs/text-policy.md)' -Items $diff.CrOnly
        Write-KitDiffList -Title 'змістовні розбіжності' -Items $diff.Content
        Write-KitDiffList -Title 'тільки в дампі зі сховища' -Items $diff.OnlyInDump
        Write-KitDiffList -Title "тільки в дереві '$ref'" -Items $diff.OnlyInTree
        if ($diff.OnlyInDump.Count -gt 0) {
            # -f поза дужками PowerShell зв'язав би як -ForegroundColor (P4 префлайту B3) — оператор формату всередині.
            Write-Host (("  Увага: {0} файл(ів) є лише в дампі зі сховища — '{1}' їх ВТРАТИВ. Це не «робота, яку треба застосувати у сховищі», " +
                         "а прогалина в '{1}': перевірте злиття {2} у '{1}' і канонізацію.") -f $diff.OnlyInDump.Count, $ref, $src.Branch) -ForegroundColor Yellow
        }

        switch ($verdict) {
            'equal'         { Write-Host "  Вердикт: equal — '$ref' ≡ сховище (версія $ver)." -ForegroundColor Green }
            'storage-ahead' { Write-Host "  Вердикт: storage-ahead — у сховищі є версії повз '$ref'. Звірочний коміт: kit verify -Ref $ref -Apply" -ForegroundColor Yellow; $anyAction = $true }
            'ref-ahead'     { Write-Host "  Вердикт: ref-ahead — '$ref' розійшовся зі сховищем (версія $ver): змістовні/CR-розбіжності й «тільки в дереві» — робота, ще не застосована у сховищі (зберіть артефакт: kit build / operation=make); «тільки в дампі» — див. «Увага» вище." -ForegroundColor Yellow; $anyAction = $true }
            'mixed'         { Write-Host "  Вердикт: mixed — і '$ref' має незастосоване, і сховище пішло вперед. Спершу звірочний коміт (kit verify -Apply), потім розбір залишку." -ForegroundColor Yellow; $anyAction = $true }
        }

        $merged = $false
        if ($Apply -and $vv.NewerVersions.Count -gt 0) {
            $m = Merge-KitBranchInto -RepoRoot $root -Branch $src.Branch -Into $ref `
                -Message "verify: звірочний коміт $($src.Branch) → $ref (версія $($vv.NewerVersions[-1]))"
            Write-Host "  Звірочний коміт: $($m.Outcome) ($($m.Via)) $($m.Sha.Substring(0, 7))" -ForegroundColor Green
            $merged = ($m.Outcome -eq 'merged')
        } elseif ($Apply) {
            Write-Host '  -Apply: нових версій на дзеркалі немає — зливати нічого.' -ForegroundColor DarkGray
        }

        $results.Add([pscustomobject]@{ Key = $src.Key; Ref = $ref; Version = $ver; Verdict = $verdict; Diff = $diff; Merged = $merged })
    }

    [pscustomobject]@{ ExitCode = $(if ($anyAction) { 3 } else { 0 }); Results = $results.ToArray() }
}

Export-ModuleMember -Function Invoke-KitVerify
```

- [ ] **Step 5а: диспетчер `kit.ps1` — коди виходу й прапорці без значення** (знахідки виконавця B3; `verify`
  перший, кому це болить: у нього власний код 3)

1. `throw` будь-де (команда, префлайт, невідома команда) → код **1**, не 2: у блоці `catch` диспетчера
   `Write-Host` червоним тексту винятку і `exit 1`; `2` лишається лише за `sync` (частковий успіх), `3` — за
   `verify`. Тести в `Kit.Tests.ps1`: невідома команда → 1; команда, що кидає (probe з `-Throw`), → 1; у
   `Sync.Tests`/`Verify.Tests` уже є 2 і 3.
2. `-Ім'я` без значення диспетчер кладе `$true`; для числового параметра PowerShell мовчки робить із нього `1`
   (`kit verify -Version -Ref main` звіряв би проти версії 1 і радив «зберіть артефакт»). Правило диспетчера:
   `$true` без значення — лише якщо параметр функції команди має тип `[switch]`
   (`(Get-Command $functionName).Parameters[$n].ParameterType -eq [switch]`); інакше зупинка «параметр -$n
   потребує значення». Тести: `probe -Force` → force=True; `probe -Ref` без значення → 1 і `-Ref` у тексті.
   Локальний обхід у `verify` (`-Version` рядком) після цього не потрібен — прибрати, лишити `[Nullable[int]]`.

- [ ] **Step 6: Тести без Integration зелені; Integration — за підтвердженням користувача**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
pwsh -NoProfile -File tools/tests/Run-Tests.ps1
```

Очікувано в Integration: перший `verify` — `equal` на живому розширенні (те, що BankExchange
дав на 516 файлах). Якщо замість `equal` виходить `ref-ahead` з категорією «лише CR» — це
не збій тесту, а знахідка про політику тексту фікстури: перевірити, що `-WithGitattributes`
дав `.gitattributes` до першого `sync`, і що `Write-KitStorageVersion` викликає `git add`
з `-c core.autocrlf=false`.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/StorageBranch.psm1 tools/commands/verify.psm1 tools/tests/Verify.Tests.ps1 tools/tests/StorageBranch.Tests.ps1 tools/kit.ps1 tools/tests/Kit.Tests.ps1
git commit --only -- tools/lib/StorageBranch.psm1 tools/commands/verify.psm1 tools/tests/Verify.Tests.ps1 tools/tests/StorageBranch.Tests.ps1 tools/kit.ps1 tools/tests/Kit.Tests.ps1 -m "B3: kit verify — інваріант ref ≡ сховище з версією з merge-base і звірочним комітом"
```

---

### Task 5: команда `dump` (§5) і вилучення `dump-config.ps1`

**Files:**
- Create: `tools/commands/dump.psm1`
- Create: `tools/tests/Dump.Tests.ps1`
- Delete: `tools/dump-config.ps1`
- Modify: `skills/storage-pipeline/SKILL.md` (перехідна позначка), `templates/CLAUDE.md`, `CLAUDE.md` (рядок `tools/`), `README.md` (рядок про `tools/`: `dump-config` → `kit dump`; `docs/storage-and-git.md` і `docs/unica-contract.md` — B8, там переписуються цілком)

**Interfaces:**
- Consumes: `Select-KitSources -Truth @('dump','vendor')`, `Resolve-KitInfobase`, `ConvertTo-V8IbSwitch`, `Invoke-V8Designer`, `Assert-V8InfobaseNotBusy`, `Assert-SafeWorkPath`.
- Produces: `Invoke-KitDump -Context [-Workspace] [-Source] [-Apply]` → `{ExitCode; Dumped}`.

- [ ] **Step 1: Тест `tools/tests/Dump.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit dump — прев''ю і штатні зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Dump {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=""C:\bases\demo"";'`n    user: 'Адмін'"
    }

    It 'прев''ю: база, ціль і попередження про 20–40 хвилин; нічого не змінено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*/F "C:\bases\demo"*Alpha_SMB/cf/src*'
        $r.Output | Should -BeLike '*-Apply*'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'дев-бази з dump.from немає в накладці — зупинка з готовим блоком infobases:, ціль не чіпалась' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ib') -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/marker.txt') -Value 'є'
        $r = Invoke-Dump -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'dev'*infobases:*connection:*"
        Join-Path $repo 'Alpha_SMB/cf/src/marker.txt' | Should -Exist
    }

    It 'без джерел truth: dump/vendor — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Dump -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*dump*vendor*'
    }

    It '-Source на джерело з truth: storage — зупинка: дамп лише для dump/vendor' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrong-truth') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*storage*'
    }
}

Describe 'kit dump — жива дев-база (лише читання, 20–40 хв)' -Tag Integration -Skip:($env:V8KIT_LIVE_DUMP -ne '1') {
    # Запускається лише з V8KIT_LIVE_DUMP=1: це дорого й потребує доступу до бази людини.
    # -Skip: на Describe, а НЕ Set-ItResult у BeforeAll: Set-ItResult легальний лише всередині It,
    # а в BeforeAll кидає "a 'break' or 'continue' statement ... escaped from your code" і, без
    # захисту Pester, тихо обірвав би ВЕСЬ прогін без результату (живий прогін B3, pester#2669).
    # Виправлено в коді комітом 42eff34; тут — щоб текст плану не працював зразком для наступного.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $overlay = "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF_sydorenko"";'`n    user: 'Администратор'"
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }', "      Alpha_SMB: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -ManifestText $manifest -OverlayText $overlay -WithHooks -WithGitattributes -WithGitignore
    }
    It 'вивантажує конфігурацію в Alpha_SMB/cf/src; результат гітігнорований' {
        $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $script:Repo -Source base -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $script:Repo 'Alpha_SMB/cf/src/Configuration.xml' | Should -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Реалізація `tools/commands/dump.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Invoke-KitDump {
    <#
    .SYNOPSIS
        Дамп поточного стану живої бази людини в дерево джерела (truth: dump або vendor).
        Kit лише читає базу; куди — каже v8project.yaml; з якої бази — dump.from + накладка kit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

    $root = $Context.RepoRoot
    if ($Source) {
        $requested = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        foreach ($s in $requested) {
            if ($s.Truth -notin @('dump', 'vendor')) {
                throw "Джерело '$($s.Key)' має truth: $($s.Truth) — dump працює лише з truth: dump або vendor (для storage є sync, для git джерела немає)."
            }
        }
    }
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth @('dump', 'vendor'))
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: dump чи vendor — вивантажувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Dumped = @() }
    }

    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $root 'v8storagekit.local.yaml' }
    $plan = @(foreach ($src in $sources) {
        $ib = Resolve-KitInfobase -Overlay $Context.Overlay -Name $src.DumpFrom -OverlayPath $overlayPath
        [pscustomobject]@{ Source = $src; Infobase = $ib; IbSwitch = (ConvertTo-V8IbSwitch -Connection $ib.Connection) }
    })

    $dumped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $plan) {
        $src = $item.Source
        $wsFull = ($Context.Workspaces | Where-Object Path -eq $src.Workspace).FullPath
        Write-Host ''
        Write-Host "Джерело:  $($src.Workspace)/$($src.Key) ($($src.Type), truth: $($src.Truth))"
        Write-Host "База:     $($item.IbSwitch)  (dump.from: $($item.Infobase.Name), користувач $($item.Infobase.User))"
        Write-Host "Куди:     $($src.RepoPath)"

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            Write-Host '  Вивантаження конфігурації триває 20–40 хвилин і займає 1–2 ГБ; база має бути закрита в Конфігураторі.' -ForegroundColor Cyan
            continue
        }

        Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $wsFull -Description "ціль дампу джерела $($src.Key)"
        if (Test-Path -LiteralPath $src.FullPath) { Remove-Item -LiteralPath $src.FullPath -Recurse -Force }
        New-Item -ItemType Directory -Path $src.FullPath -Force | Out-Null

        $ext = if ($src.Type -eq 'EXTENSION') { " -Extension $($src.Key)" } else { '' }
        $r = Invoke-V8Designer -IbSwitch $item.IbSwitch -User $item.Infobase.User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $src.FullPath, $ext))
        if ($r.ExitCode -ne 0) {
            Assert-V8InfobaseNotBusy -Output $r.Output -Infobase $item.Infobase.Name
            throw "Вивантаження $($src.Key) не вдалося: $($r.Output)"
        }
        $count = @(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File).Count
        Write-Host "  Готово. Файлів: $count" -ForegroundColor Green
        $dumped.Add([pscustomobject]@{ Key = $src.Key; Target = $src.FullPath; Files = $count })
    }
    [pscustomobject]@{ ExitCode = 0; Dumped = $dumped.ToArray() }
}

Export-ModuleMember -Function Invoke-KitDump
```

- [ ] **Step 3: Вилучити `dump-config.ps1`; перехідні позначки**

```bash
git rm -q tools/dump-config.ps1
```

`skills/storage-pipeline/SKILL.md` — у перехідній позначці B2 додати рядок: «`dump-config.ps1`
вилучено — `kit.ps1 dump -RepoRoot . [-Source base] [-Apply]`; дев-база береться з
`v8storagekit.local.yaml` (`infobases:`), а не з `v8project.local.yaml`». У таблиці розділу 2
рядок «вивантаж базову конфігурацію» замінити на команду `kit.ps1 dump`.

`templates/CLAUDE.md` — рядок «вивантаж базову конфігурацію» → `kit.ps1 dump -Apply`; у
розділі «Структура» `v8project.local.yaml (gitignored: підключення й логіни)` →
«`v8storagekit.local.yaml` (gitignored: дев-бази, локальні шляхи сховищ); `v8project.local.yaml`
— файл Уніки, лише для серверної бази агента».

`CLAUDE.md` kit, рядок `tools/`: команди `check`, `sync`, `verify`, `dump`, `session-check`;
перехідні — `load-ext`, `build` (до B4).

`Templates.Tests.ps1`: якщо там є перевірка на `dump-config` — оновити на `kit.ps1 dump`. `README.md` kit: у переліку
`tools/` замінити `dump-config` на `kit dump` (мінімально, повне переписування — B8).

- [ ] **Step 4: Тести зелені; коміт**

```bash
# dump-config.ps1 уже застейджено через git rm у Step 3; ніяких -A (урок B1 №2)
git add tools/commands/dump.psm1 tools/tests/Dump.Tests.ps1 skills/storage-pipeline/SKILL.md templates/CLAUDE.md CLAUDE.md README.md
git commit --only -m "B3: kit dump — вивантаження з живої бази за накладкою kit, «база зайнята» як порада; dump-config.ps1 вилучено" -- tools/dump-config.ps1 tools/commands/dump.psm1 tools/tests/Dump.Tests.ps1 skills/storage-pipeline/SKILL.md templates/CLAUDE.md CLAUDE.md README.md
```

---

### Task 6: команда `session-check` (§5)

Дешевий сигнал без платформи: (а) чи є у сховищі записи новіші за дзеркало — за `mtime`
файлів під `<сховище>\data\objects\**` (не `1cv8ddb.1CD` — він переписується при кожному
інтерактивному підключенні); (б) чи є на `storage/X` коміти, не злиті в головну гілку.

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` — `Get-KitStorageActivity`, `Test-KitBranchUnborn`
- Modify: `tools/commands/check.psm1` — знахідка `main-branch` дворівнева (info/warn); `tools/tests/Check.Tests.ps1` — тест на обидва рівні
- Create: `tools/commands/session-check.psm1`
- Create: `tools/tests/SessionCheck.Tests.ps1`

**Interfaces:**
- Produces: `Get-KitStorageActivity -StoragePath` → `{Accessible; LatestObjectWrite (UTC)|$null; Reason}`; `Invoke-KitSessionCheck -Context [-Workspace] [-Source] [-Apply] [-AsJson]` → `{ExitCode 0; Signals}`; текстовий вивід — по рядку на джерело, кожен починається з `- <ключ>:`. B4 вбудовує цей текст у контекст сесії.

- [ ] **Step 1: Тест `tools/tests/SessionCheck.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Фейкове сховище: 1cv8ddb.1CD + data/objects/*. Шлях підставляється накладкою (storages:).
        function script:New-FakeStorage {
            param([string]$Name, [datetime]$ObjectsWrite, [datetime]$DbWrite)
            $s = Join-Path $TestDrive "storage-$Name"
            New-Item -ItemType Directory -Path (Join-Path $s 'data/objects/ab') -Force | Out-Null
            $obj = Join-Path $s 'data/objects/ab/cdef.bin'; Set-Content -LiteralPath $obj -Value 'obj'
            $db  = Join-Path $s '1cv8ddb.1CD';             Set-Content -LiteralPath $db  -Value 'db'
            (Get-Item $obj).LastWriteTimeUtc = $ObjectsWrite.ToUniversalTime()
            (Get-Item $db).LastWriteTimeUtc  = $DbWrite.ToUniversalTime()
            $s
        }
        function script:New-Repo {
            param([string]$Name, [string]$StoragePath, [datetime]$MirrorDate, [switch]$NoMirror, [switch]$Merge)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -OverlayText "storages:`n  Alpha_SMB: '$StoragePath'" -WithHooks -WithGitattributes -WithGitignore
            if (-not $NoMirror) {
                $stamp = $MirrorDate.ToString('yyyy-MM-ddTHH:mm:ss')
                $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp
                try { Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1') }
                finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
                if ($Merge) { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null }
            }
            # Слід фікстури: worktree remove прибирає wt, а порожню build/sync лишає — щоб твердження
            # «session-check не створює тек» перевіряло команду, а не фікстуру (P2 префлайту B3).
            Remove-Item -LiteralPath (Join-Path $repo 'build') -Recurse -Force -ErrorAction SilentlyContinue
            $repo
        }
        function script:Invoke-SessionCheck {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit session-check -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Old = [datetime]'2026-01-10T10:00:00'
        $script:New = [datetime]'2026-02-20T10:00:00'
    }

    It '(а) файли data/objects новіші за дзеркало → сигнал «нові версії»' {
        $s = New-FakeStorage -Name 'newer' -ObjectsWrite $script:New -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-newer' -StoragePath $s -MirrorDate $script:Old -Merge)
        $r.ExitCode | Should -Be 3     # є що робити (спека §5: коди за змістом)
        $r.Output | Should -BeLike '*- Alpha_SMB:*нові версії*kit sync*'
    }

    It '(а) файли data/objects старіші за дзеркало → тиша' {
        $s = New-FakeStorage -Name 'older' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-older' -StoragePath $s -MirrorDate $script:New -Merge)
        $r.ExitCode | Should -Be 0     # тиша → 0
        $r.Output | Should -Not -BeLike '*нові версії*'
        $r.Output | Should -BeLike '*- Alpha_SMB:*синхронн*'
    }

    It '(а) 1cv8ddb.1CD новіший, а data/objects — ні → тиша (mtime бази не індикатор)' {
        $s = New-FakeStorage -Name 'db-only' -ObjectsWrite $script:Old -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-db' -StoragePath $s -MirrorDate ([datetime]'2026-01-15T10:00:00') -Merge)
        $r.Output | Should -Not -BeLike '*нові версії*'
    }

    It '(б) коміти на storage/X, не злиті в main → сигнал із кількістю і підказкою verify' {
        $s = New-FakeStorage -Name 'unmerged' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'b-unmerged' -StoragePath $s -MirrorDate $script:New)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*1 *не злит*main*kit verify*'
    }

    It 'дзеркала ще немає при доступному сховищі → «дзеркала немає — kit sync», код 3' {
        $s = New-FakeStorage -Name 'nomirror' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'no-mirror' -StoragePath $s -MirrorDate $script:Old -NoMirror)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*дзеркала*немає*kit sync*'
    }

    It 'сховище недоступне на цій машині → рядок «недоступне», код 0; без дзеркала — ще й «дзеркала немає»' {
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'inaccessible' -StoragePath (Join-Path $TestDrive 'nope') -MirrorDate $script:Old -Merge)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*- Alpha_SMB:*недоступн*'
        $r2 = Invoke-SessionCheck -Repo (New-Repo -Name 'inaccessible-nomirror' -StoragePath (Join-Path $TestDrive 'nope') -MirrorDate $script:Old -NoMirror)
        $r2.ExitCode | Should -Be 0
        $r2.Output | Should -BeLike '*недоступн*Дзеркала*немає*'
    }

    It 'git log на НАЯВНІЙ гілці не відповів → код 1; рядок — або від check (інваріанти storage/*), або від сигналу' {
        # Гілка є (ref розв'язується), а об'єкт вершини видалено: rev-parse проходить, log/rev-list падають.
        # check обходить лог storage/* першим і, найімовірніше, зупиниться раніше за сигнал — закріпити той рядок,
        # який реально з'являється; обидва називають гілку.
        $s = New-FakeStorage -Name 'gitbroken' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'git-broken' -StoragePath $s -MirrorDate $script:Old -Merge
        $sha = (git -C $repo rev-parse storage/Alpha_SMB).Trim()
        Remove-Item -LiteralPath (Join-Path $repo ".git/objects/$($sha.Substring(0,2))/$($sha.Substring(2))") -Force
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*storage/Alpha_SMB*'
    }

    It 'гілки mainBranch немає, HEAD деінде (описка) → [!] від check, код 3, «перевірте mainBranch:»' {
        $s = New-FakeStorage -Name 'nomain' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'no-main' -StoragePath $s -MirrorDate $script:Old -Merge
        git -C $repo branch -m main trunk
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match '\[!\].*main'
        $r.Output | Should -BeLike "*- Alpha_SMB:*коміт*гілки 'main'*немає*перевірте mainBranch*"
        $r.Output | Should -Not -BeLike '*зробіть перший коміт*'
    }

    It 'свіжий репозиторій: unborn main і готове дзеркало → [i] від check, код 3, «зробіть перший коміт … -MergeMain»' {
        $s = New-FakeStorage -Name 'unborn' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unborn') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithHooks -WithGitattributes -WithGitignore -NoCommit
        # Дзеркало без жодного коміту в main: якщо `worktree add --orphan` відмовить на репо без комітів —
        # створити через `git checkout --orphan storage/Alpha_SMB` у головній копії, закомітити з V8KIT_SYNC=1
        # і повернутись на unborn main: `git checkout --orphan main; git rm -rq --cached .`.
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        (git -C $repo symbolic-ref -q HEAD) | Should -Be 'refs/heads/main'
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match '\[i\].*main'
        $r.Output | Should -BeLike '*- Alpha_SMB:*зробіть перший коміт*-MergeMain*'
    }

    It 'error у check (наприклад, накладка не гітігнорована) → код 1, [-]-рядок і «сигнали не обчислювались»; сигналів немає' {
        $s = New-FakeStorage -Name 'cherr' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'check-error' -StoragePath $s -MirrorDate $script:Old -Merge
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "build/`n" -Encoding UTF8   # без v8storagekit.local.yaml → error overlay-ignored
        git -C $repo commit -qam 'gitignore без накладки'
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[-\].*v8storagekit\.local\.yaml'
        $r.Output | Should -BeLike '*не обчислювались*kit check*'
        $r.Output | Should -Not -BeLike '*нові версії*'     # хоч сховище й новіше — сигнал не рахувався
    }

    It 'error у check (хуки не встановлені) → код 1 без сигналів; лише warn (немає накладки) → [!] над сигналами, код від сигналів' {
        $s = New-FakeStorage -Name 'hooks' -ObjectsWrite $script:New -DbWrite $script:New
        $noHooks = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-hooks') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithGitattributes -WithGitignore
        $r = Invoke-SessionCheck -Repo $noHooks
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*[-]*core.hooksPath*не обчислювались*'

        $warnOnly = New-Repo -Name 'warn-only' -StoragePath $s -MirrorDate $script:Old -Merge   # дев-бази base у накладці немає → warn dump-from
        $r2 = Invoke-SessionCheck -Repo $warnOnly
        $r2.ExitCode | Should -Be 3
        $r2.Output | Should -Match '\[!\].*dump\.from|\[!\].*infobases'
        $r2.Output | Should -BeLike '*- Alpha_SMB:*нові версії*'
    }

    It '-AsJson — валідний JSON з полями сигналу' {
        $s = New-FakeStorage -Name 'json' -ObjectsWrite $script:New -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'json' -StoragePath $s -MirrorDate $script:Old -Merge) -More @('-AsJson')
        $json = $r.Output | ConvertFrom-Json
        @($json).Count | Should -Be 1
        @($json)[0].Key | Should -Be 'Alpha_SMB'
        @($json)[0].NewInStorage | Should -BeTrue
    }

    It 'session-check нічого не змінює й не створює тек' {
        $s = New-FakeStorage -Name 'ro' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'ro' -StoragePath $s -MirrorDate $script:Old -Merge
        Invoke-SessionCheck -Repo $repo | Out-Null
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }
}
```

- [ ] **Step 2: `Get-KitStorageActivity` і `Test-KitBranchUnborn` у `StorageBranch.psm1`; розрізнювач у `check`**

```powershell
function Test-KitBranchUnborn {
    <#
    .SYNOPSIS
        Чи HEAD — ненароджена гілка з цим ім'ям (свіжий репозиторій до першого коміту): symbolic-ref HEAD
        указує на refs/heads/<Branch>, а самого ref ще немає. Спільний розрізнювач для check і session-check
        (спека a7a5d45): без нього порада «зробіть перший коміт» на описку в mainBranch створила б зайву гілку.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)
    $head = (git -C $RepoRoot symbolic-ref -q HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne "refs/heads/$Branch") { return $false }
    -not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)
}
```

У `check.psm1` (знахідка `main-branch` з B1) — два рівні замість одного: гілки немає **і** `Test-KitBranchUnborn`
→ `info` «свіжий репозиторій: головної гілки '<main>' ще немає — її створить перший коміт»; гілки немає, а HEAD
деінде → `warn` «гілки '<main>' з маніфесту немає — перевірте mainBranch: (описка?)». Тест у `Check.Tests.ps1`
на обидва.

- [ ] **Step 2а (було Step 2): `Get-KitStorageActivity`**

```powershell
function Get-KitStorageActivity {
    <#
    .SYNOPSIS
        Коли у сховище останнім разом писали об'єкти: максимальний mtime під data/objects/**.
        1cv8ddb.1CD не використовується — він оновлюється при кожному інтерактивному підключенні
        Конфігуратора (спека §5, дослідження п. 5).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StoragePath)
    $result = [pscustomobject]@{ Accessible = $false; LatestObjectWrite = $null; Reason = '' }
    if (-not (Test-Path -LiteralPath $StoragePath -PathType Container)) { $result.Reason = "каталог недоступний: $StoragePath"; return $result }
    $objects = Join-Path $StoragePath 'data/objects'
    $result.Accessible = $true
    if (-not (Test-Path -LiteralPath $objects -PathType Container)) { $result.Reason = 'у сховищі ще немає data/objects (жодної версії)'; return $result }
    $latest = Get-ChildItem -LiteralPath $objects -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property LastWriteTimeUtc -Maximum
    if ($latest.Count -gt 0) { $result.LatestObjectWrite = [datetime]$latest.Maximum }
    $result
}
```

Додати обидві до `Export-ModuleMember`.

- [ ] **Step 3: `tools/commands/session-check.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Спека §5: «повний check викликається явно і в session-check». Диспетчер імпортує лише запитаний командний
# модуль, тому check підключається тут (без -Force — не перезавантажувати вже наявний).
Import-Module "$PSScriptRoot/check.psm1"

function Invoke-KitSessionCheck {
    <#
    .SYNOPSIS
        Дешевий сигнал для старту сесії (спека §5, §7): без платформи, без ліцензії, один обхід
        каталогу на джерело. Спершу — повний check (-Quiet) тим самим контекстом: error → код 1 і сигнали
        не обчислюються (на storage/* з чужим комітом дата дзеркала нічого не означає — одне правило замість
        таблиці «які помилки ще дозволяють сигнали»); лише warn → [!]-рядки над сигналами, плюс [i] для знахідок
        із білого списку (main-branch — info-половина дворівневої знахідки). Нічого не змінює.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$AsJson
    )

    $root = $Context.RepoRoot
    $main = $Context.MainBranch
    $signals = [System.Collections.Generic.List[object]]::new()

    # --- Повний check першим (спека §5). Виняток із check — теж «репозиторій суперечливий», код 1.
    $checkFindings = @()
    try {
        $checkFindings = @((Invoke-KitCheck -Context $Context -Workspace $Workspace -Source $Source -Quiet).Findings)
    } catch {
        $checkFindings = @(New-KitFinding -Level error -Check 'check' -Message "check не відпрацював: $($_.Exception.Message)")
    }
    $checkErrors = @($checkFindings | Where-Object Level -eq 'error')
    # Недоступне сховище описує сигнал джерела (з порадою про накладку) — check-рядок про той самий шлях опускаємо.
    $checkWarns  = @($checkFindings | Where-Object { $_.Level -eq 'warn' -and $_.Check -ne 'storage-path' })
    # info друкуємо лише з білого списку: check дає info на кожному прогоні (рядок-зведення «Маніфест: …»), і
    # пускати всі означало б шум на кожному старті сесії. main-branch — інша річ: це info-половина дворівневої
    # знахідки Step 2 («свіжий репозиторій: гілку створить перший коміт»), без неї розрізнювач мертвий.
    $checkInfos  = @($checkFindings | Where-Object { $_.Level -eq 'info' -and $_.Check -in @('main-branch') })

    if ($checkErrors.Count -gt 0) {
        if ($AsJson) {
            Write-Host (ConvertTo-Json -InputObject ([pscustomobject]@{ CheckErrors = @($checkErrors.Message); Signals = @() }) -Depth 4)
        } else {
            Write-Host "session-check — $($Context.Kind) $($Context.Label)"
            foreach ($e in $checkErrors) { Write-Host "[-] $($e.Message)" -ForegroundColor Red }
            Write-Host 'Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.' -ForegroundColor Red
        }
        return [pscustomobject]@{ ExitCode = 1; CheckFindings = $checkFindings; Signals = @() }
    }

    $mainExists = Test-KitBranchExists -RepoRoot $root -Branch $main

    foreach ($src in @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)) {
        $mirror = Test-KitBranchExists -RepoRoot $root -Branch $src.Branch
        # Хук старту сесії: збій git тут — деградація до рядка «стан не прочитано», НЕ виняток (рев'ю B3).
        $lastMirror = $null; $gitProblem = $null
        if ($mirror) {
            $iso = (git -C $root log -1 --format=%aI $src.Branch 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $iso) { $gitProblem = "git log $($src.Branch) не відповів" }
            else { $lastMirror = ([datetimeoffset]$iso).UtcDateTime }
        }
        $activity = Get-KitStorageActivity -StoragePath $src.StoragePath
        $newInStorage = $false
        if ($activity.Accessible -and $activity.LatestObjectWrite -and -not $gitProblem) {
            # $null у $lastMirror дав би -gt → $true: сигнал на порожньому місці; тому лише за наявної дати.
            $newInStorage = (-not $mirror) -or ($null -ne $lastMirror -and $activity.LatestObjectWrite -gt $lastMirror)
        }
        # «Дзеркало є, головної гілки немає» — не «не знаю» (1), а 3: незлиті коміти — УСІ коміти дзеркала, і дія
        # відома (спека a7a5d45). sync у B2 сам породжує цей стан на свіжому репозиторії (перше злиття пропущено).
        # Розрізнювач: unborn main (свіжий репо) → «зробіть перший коміт»; HEAD деінде → «перевірте mainBranch:».
        $unmerged = 0; $mainMissing = $false
        if ($mirror -and -not $gitProblem) {
            $range = if ($mainExists) { "$main..$($src.Branch)" } else { $mainMissing = $true; $src.Branch }
            $countRaw = (git -C $root rev-list --count $range 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $countRaw -notmatch '^\d+$') { $gitProblem = "git rev-list $range не відповів" }
            else { $unmerged = [int]$countRaw }
        }

        $text = if ($gitProblem) {
            "- $($src.Key): стан git не прочитано ($gitProblem) — сигнал недоступний; розбір: kit check."
        } elseif (-not $activity.Accessible) {
            "- $($src.Key): сховище недоступне на цій машині ($($activity.Reason)) — перевизначте шлях у v8storagekit.local.yaml (storages:)." +
                $(if (-not $mirror) { " Дзеркала $($src.Branch) ще немає — перший sync стане можливим після доступу." } else { '' })
        } elseif (-not $mirror) {
            "- $($src.Key): дзеркала storage/$($src.Key) ще немає — перший реплей: kit sync -Source $($src.Key) -Apply."
        } else {
            $parts = [System.Collections.Generic.List[string]]::new()
            if ($newInStorage) {
                $parts.Add(("у сховищі ймовірно нові версії (запис {0:yyyy-MM-dd HH:mm} UTC після дзеркала {1:yyyy-MM-dd HH:mm} UTC) — оновити? kit sync -Source {2} -Apply" -f $activity.LatestObjectWrite, $lastMirror, $src.Key))
            }
            if ($unmerged -gt 0 -and $mainMissing) {
                if (Test-KitBranchUnborn -RepoRoot $root -Branch $main) {
                    $parts.Add("на $($src.Branch) є $unmerged коміт(и), а головної гілки '$main' ще немає — зробіть перший коміт у '$main', потім kit sync -Source $($src.Key) -Apply -MergeMain")
                } else {
                    $parts.Add("на $($src.Branch) є $unmerged коміт(и), а гілки '$main' з маніфесту немає — перевірте mainBranch: (описка?)")
                }
            } elseif ($unmerged -gt 0) {
                $parts.Add("на $($src.Branch) є $unmerged коміт(и), не злиті в $main — звірочний коміт: kit verify -Apply")
            }
            if ($parts.Count -eq 0) { $parts.Add("дзеркало синхронне зі сховищем, $main містить усе.") }
            "- $($src.Key): " + ($parts -join '; ')
        }

        $signals.Add([pscustomobject]@{
            Key = $src.Key; Branch = $src.Branch; MirrorExists = $mirror; LastMirrorDate = $lastMirror
            StorageWrite = $activity.LatestObjectWrite; NewInStorage = $newInStorage; UnmergedCommits = $unmerged
            Accessible = $activity.Accessible; GitProblem = $gitProblem; Text = $text
        })
    }

    if ($AsJson) {
        # Через Write-Host, не Write-Output: success stream забирає диспетчер і не друкує (контракт F12).
        Write-Host (ConvertTo-Json -InputObject $signals.ToArray() -Depth 4)
    } else {
        Write-Host "session-check — $($Context.Kind) $($Context.Label)"
        foreach ($i in $checkInfos) { Write-Host "[i] $($i.Message)" -ForegroundColor Gray }
        foreach ($w in $checkWarns) { Write-Host "[!] $($w.Message)" -ForegroundColor Yellow }   # warn/info не міняють коду: його визначають сигнали
        if ($signals.Count -eq 0) { Write-Host '- джерел truth: storage у маніфесті немає.' }
        foreach ($s in $signals) { Write-Host $s.Text }
    }
    # Коди за змістом (спека §5, f4307df), пріоритет: 1 — хоч одне джерело зі станом git, який не прочитано
    # (наявна гілка, а log/rev-list не відповіли; головної гілки немає) — репозиторій, той самий клас, що
    # зупинка check; інакше 3 — хоч один сигнал дії (нові версії, дзеркала немає при доступному сховищі,
    # незлиті коміти) — те саме, що storage-ahead у verify, лише дешево; інакше 0. «Сховище недоступне» — стан
    # машини, 0 з рядком. Винятку немає навмисно: хук на код 1 сам ставить позначку «стан НЕВІДОМИЙ» (§7).
    $exit = if (@($signals | Where-Object { $_.GitProblem }).Count) { 1 }
            elseif (@($signals | Where-Object { $_.NewInStorage -or $_.UnmergedCommits -gt 0 }).Count) { 3 }
            else { 0 }
    [pscustomobject]@{ ExitCode = $exit; CheckFindings = $checkFindings; Signals = $signals.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSessionCheck
```

> Диспетчер друкує лише те, що команда пише в хост (`Write-Host`); success stream він забирає у
> `$result` і не виводить — тому й `-AsJson` іде через `Write-Host`. Якщо в тесті `-AsJson` до JSON
> домішується інший текст — перевірити, що в гілці `-AsJson` немає інших `Write-Host`.

- [ ] **Step 3а: префлайт для `session-check` — поблажливий, як для `check`** (щілина, знайдена виконавцем B3)

Диспетчер робить префлайт `-Lenient` лише для `check`; для `session-check` суворий префлайт кидав би на
помилках свого рівня (немає маніфесту, нерозбірний YAML, немає теки воркспейсу чи `v8project.yaml`, ключ без
source-set) ДО виклику `Invoke-KitCheck` — сирий текст замість `[-]`-рядків і «сигнали не обчислювались», тобто
«одне правило» трималось би для помилок check, але не префлайту. У `kit.ps1`:

```powershell
# check і session-check — діагностика: вони мусять ДОПОВІСТИ про суперечливий репозиторій, а не впасти на ньому.
$context = Invoke-KitPreflight -RepoRoot $RepoRoot -Lenient:($Command -in @('check', 'session-check'))
```

Дублювання немає: `Invoke-KitCheck` починає з `Context.Findings` (B1), тож помилки префлайту стають його
`[-]`-рядками, і session-check друкує їх один раз через той самий шлях. Тест у `SessionCheck.Tests.ps1`: маніфест
`version: 1` без `workspaces` → код 1, у виводі `[-]`, `workspaces` і «не обчислювались» (той самий сценарій, що й
тест шима в B4). B6 додає до цього списку `migrate`.

- [ ] **Step 4: Тести зелені; коміт**

```bash
git add tools/kit.ps1 tools/lib/StorageBranch.psm1 tools/commands/check.psm1 tools/commands/session-check.psm1 tools/tests/Check.Tests.ps1 tools/tests/SessionCheck.Tests.ps1
git commit --only -- tools/kit.ps1 tools/lib/StorageBranch.psm1 tools/commands/check.psm1 tools/commands/session-check.psm1 tools/tests/Check.Tests.ps1 tools/tests/SessionCheck.Tests.ps1 -m "B3: kit session-check — нові версії за mtime data/objects і незлиті коміти дзеркала, без платформи"
```

---

### Task 7: завершення блоку

- [ ] **Step 1: `docs/follow-ups.md` §14** — дописати: «**Закрито в B3:** `kit verify` порівнює дерево ref із дампом зі сховища на версії з merge-base (§3.5); round-trip через власну робочу копію більше не є приймальною перевіркою».
- [ ] **Step 2: `ModuleImportOrder.Tests.ps1`** — переконатись, що `RequiredCommands` містить `Get-KitVerifyVersion`, `Get-KitStorageActivity`, `Test-V8InfobaseBusy`, `Assert-V8InfobaseNotBusy`.
- [ ] **Step 3: Повний прогін без Integration; перевірка `${CLAUDE_PLUGIN_ROOT}`** (порожньо).
- [ ] **Step 4: `kit check` на синтетичному репозиторії з `Sync.Tests` — код 0.**
- [ ] **Step 5: Коміт**

```bash
git add docs/follow-ups.md tools/tests/ModuleImportOrder.Tests.ps1
git commit -m "B3: follow-ups §14 закрито; список видимих команд для kit.ps1"
```

---

### Task 8: запаковане сховище і відбиток (хвіст після живого прогону)

**Ризик:** `властивість безпеки` — задача тримає інваріант «`session-check` нічого не мутує»
(§5, стовпець «Мутує: ні»), на якому стоїть стеля часу шима §7: убивати процес за стелею
законно **лише** тому, що вбивати нема чого. Дозволити команді оновлювати кеш — і стеля з
`kill` у B4 стають незаконними заднім числом. Друге рев'ю — вузьке, рівно про це: чи не з'явився
в `session-check` жоден запис на диск, прямий або через спільну функцію.

**Звідки задача.** Живий прогін B3 (компаньйон `smp-bankexchange-44`) знайшов `СМП_BankExchange_SMBru` —
справжнє сховище з 16 версіями, у якого `data/objects` **порожня**: усе запаковано в `data/pack`
(4 файли, 2,2 МБ). `session-check` відповів «шлях доступний, але не схожий на сховище 1С», і це
хибний діагноз у найгіршому місці: правильна дія — жодна, а людину відправляють перевіряти
маніфест і накладку, де все гаразд. Пакування не екзотика: у `СМП_BankExchange_SMB` видно обидва
стани одночасно (запаковане до 2024-03-16, свіже в `objects`), конфігураційні сховища мають по
60 pack-файлів. Рішення архітектора — спека `9f6ad5e` (§5, абзац «Запаковане сховище»; §12 (е))
і `0379351` (§3.2, розрізнення відбитка й файлу стану).

**Головне, що тут легко зіпсувати.** Тричі за блок ми ловили дефекти одного класу — **вічний
рядок**: сигнал, який ніщо не гасить (`mtime` без допуску, хибний all-clear, «не визначається»
для неактивного сховища). Кожну нову гілку сигналу перевіряйте питанням: **що її погасить і чи
настане ця подія сама?** Якщо відповідь «людина має щось зробити, але робити нема чого» — гілка
неправильна.

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` — `Get-KitStorageActivity` (pack, розпізнавання сховища)
- Create: `tools/lib/StorageImprint.psm1` — запис, читання і звірка відбитка
- Modify: `tools/lib/module-order.txt` — `StorageImprint` **після** `StorageBranch` (бере `Get-KitStorageActivity`)
- Modify: `tools/commands/sync.psm1` — запис відбитка після читання звіту
- Modify: `tools/commands/session-check.psm1` — гілка відбитка перед евристиками
- Modify: `templates/CLAUDE.md` — рядок про `build/session-check/` як локальний кеш
- Tests: `StorageBranch.Tests.ps1`, `StorageImprint.Tests.ps1` (новий), `Sync.Tests.ps1`, `SessionCheck.Tests.ps1`

**Interfaces:**

Consumes: `Get-KitStorageActivity` (Task 6), `Get-StorageVersions` і `$src` з `Select-KitSources`
(B2), дата дзеркала — та сама, що вже обчислює `Invoke-KitSessionCheck`.

Produces:

    Get-KitStorageActivity -StoragePath
      : → {Accessible:bool; IsStorage:bool; LatestObjectWrite:datetime|$null;
           LatestPackWrite:datetime|$null; PackFiles:object[]; Reason:string}
        IsStorage = 1cv8ddb.1CD є І (objects непорожня АБО pack непорожня) — спека §5.
        PackFiles — @({Name; Length; LastWriteTimeUtc}), відсортовані за Name (стабільний порядок
        для порівняння з відбитком). Порожній масив, не $null.

    Write-KitStorageImprint -RepoRoot -Key -StoragePath -Version
      : → [string] шлях записаного файла. Пише build/session-check/<Key>.json.

    Read-KitStorageImprint -RepoRoot -Key
      : → об'єкт відбитка або $null (немає файла, нечитаний JSON, чужа схема — усе одно $null:
        зіпсований кеш не має валити команду, він має зникнути з розгляду).

    Test-KitStorageImprintCurrent -Imprint -Activity
      : → bool. Диск (свіжий Get-KitStorageActivity) збігається з відбитком: LatestObjectWrite
        рівний **точно** і перелік PackFiles рівний за (Name, Length, LastWriteTimeUtc).
        Допуску тут НЕМАЄ і бути не повинно — обидві сторони порівняння знято одним годинником
        (файлова система сервера сховища). Допуск потрібен лише там, де mtime звіряється з датою
        автора коміту, тобто з годинником іншої машини (Task 6).

**Формат відбитка** (`build/session-check/<Key>.json`, UTF-8 без BOM):

    { "schema": 1, "key": "Alpha_SMB", "storagePath": "...", "version": 42,
      "readAtUtc": "2026-09-05T10:11:12.3456789Z", "latestObjectWriteUtc": "..." | null,
      "packFiles": [ { "name": "...", "length": 123, "lastWriteUtc": "..." } ] }

`schema` — щоб наступна зміна формату не читалась як «диск розійшовся»: інша схема → `$null` із
`Read-KitStorageImprint`, тобто повернення до евристик, а не хибна точна відповідь.

- [ ] **Step 1: Тести `Get-KitStorageActivity` з pack — падають**

У `StorageBranch.Tests.ps1`, до наявного Describe. Фікстура сховища має вміти три стани: лише
`objects`, лише `pack`, обидві. Перевірити:
- `1cv8ddb.1CD` + порожня `objects` + непорожня `pack` → `IsStorage = $true`, `LatestPackWrite`
  заповнений, `LatestObjectWrite` = `$null`, `Reason` порожній (це **не** причина скарги);
- `1cv8ddb.1CD` + обидві теки → обидві дати, `PackFiles` містить усі файли `pack`;
- каталог без `1cv8ddb.1CD` → `IsStorage = $false` (ось тут скарга доречна);
- `1cv8ddb.1CD` + обидві теки порожні → `IsStorage = $false`, `Reason` називає обидві теки, а не
  саму лише `objects` (стара порада шукала помилку не там);
- `pack` **рівно з одним файлом** → `PackFiles.Count` = 1 і виняток не кидається. Це не
  формальність: `@(Get-ChildItem …)` тут обов'язковий, голий `.Count` на одному файлі падає під
  `Set-StrictMode` — ловили тричі за блок.

- [ ] **Step 2: `Get-KitStorageActivity` — pack і `IsStorage`**

Розширити наявну функцію, не писати нову: її вже викликають `check` і `session-check`. Обидві
теки читаються одним зразком (`@(Get-ChildItem … -ErrorAction SilentlyContinue)`, `Count` першим,
`Measure-Object -Maximum` тільки на непорожньому — коментар C1 у поточному коді пояснює чому).
`Reason` заповнюється лише коли `IsStorage = $false`.

- [ ] **Step 3: Тести `StorageImprint.Tests.ps1` — падають**

Чисті функції, платформа не потрібна. Мінімальний набір, і третій пункт тут найважливіший:
- запис → читання: те саме значення, файл лежить у `build/session-check/<Key>.json`;
- `Read-KitStorageImprint` на відсутньому файлі, на битому JSON і на `schema: 2` → `$null`
  у всіх трьох випадках, **без винятку**;
- `Test-KitStorageImprintCurrent`: збіг → `$true`; **зміна лише `Length` одного pack-файла** →
  `$false`; **новий файл в `objects`** → `$false`; **зміна `mtime` pack-файла** → `$false`.
  Це і є охорона гілки «повернення до евристик»: без неї зелений набір проходив би, ніколи не
  виконавши жодного рядка цього шляху (у цьому блоці таке виявлялось чотири рази);
- відбиток, знятий і звірений **без жодної зміни диску між викликами**, дає `$true` — це та
  сама перевірка «один годинник», яку не можна оголошувати, її треба показати.

- [ ] **Step 4: `tools/lib/StorageImprint.psm1` і `module-order.txt`**

Три функції з контракту вище. `Write-KitStorageImprint` створює `build/session-check/` за
потреби (`New-Item -Force`), пише через `ConvertTo-Json -Depth 4` і `Set-Content -Encoding UTF8`.
Дати серіалізувати в UTF-строку формату `o` і читати назад явно — `ConvertFrom-Json` віддає їх
рядками, і мовчазне порівняння рядка з `[datetime]` дало б вічний `$false`, тобто вічне
повернення до евристик, яке ніхто б не помітив.

- [ ] **Step 5: Тести `Sync.Tests.ps1` — падають**

Найважливіший тест задачі, і він неочевидний:
- **відбиток пишеться в гілці «Нових версій немає»** — саме заради неактивного запакованого
  сховища вся конструкція й існує. Якщо запис поставити після розгалуження, фіча не працює рівно
  в тому випадку, для якого зроблена;
- відбиток пишеться **і без `-Apply` (прев'ю), і з `-Apply`** — два окремі It;
- `version` у відбитку дорівнює максимальній версії зі звіту, не кількості версій.

**Чому прев'ю пише файл — сказати в докстрінгу `sync`, а не лишати рев'юеру здогадуватись.**
Правило «прев'ю нічого не змінює» стосується git, сховища й баз — тобто стану, який хтось
побачить у комітах або в чужій системі. `build/` — робоча тека машини, гітігнорована цілком
(`templates/gitignore`, рядок `build/`), і те саме прев'ю вже кладе туди тимчасову ІБ і дампи.
Відбиток — знання, здобуте цим читанням звіту; викидати його, щоб дотриматись букви правила,
означало б платити повним прогоном платформи за кожну відповідь про запаковане сховище.

- [ ] **Step 6: `sync.psm1` — запис відбитка**

Місце одне і воно точне: **одразу після `Get-StorageVersions`** і обчислення `$maxVersion`
(поточні рядки 107–111), **до** `if ($pending.Count -eq 0) { … continue }`. Запис у `try/catch`:
збій запису кешу не має валити синхронізацію — попередження й далі.

- [ ] **Step 7: Тести `SessionCheck.Tests.ps1` — падають**

Гілка відбитка (перша, перед евристиками):
- відбиток є, диск не змінився, дзеркало на тій самій версії → код `0`, текст містить «версія N»
  і момент читання, і **не** містить «ймовірно»;
- те саме, але дзеркало на `M < N` → код `3`, текст називає обидві версії;
- відбиток є, але диск змінився (додати файл в `objects`) → евристики, текст знову «ймовірно»;
- відбитка немає (свіжий клон) → евристики.

Евристики (спека §5, три результати):
- `objects` новіші за дзеркало → «ймовірно нові версії», код `3`, **незалежно** від того, чи pack
  новіший;
- pack **не новіший** за дзеркало → звичайна логіка по `objects` (pack не згадується у виводі
  взагалі — інакше рядок про нього з'являвся б у половині репозиторіїв без причини);
- pack новіший за дзеркало, `objects` сигналу не дають → «усі об'єкти запаковані після останнього
  дзеркала — чи є нові версії, дешева перевірка сказати не може; точну відповідь дає
  `kit sync -Source <ключ>` без `-Apply`», код `3` (не `1`: команда дійшла до задуманого
  результату й назвала дію; не `0`: тиша читається як «змін немає»).

Інваріант задачі, окремим It:
- **`session-check` не створює і не змінює жодного файла.** Знімок дерева репозиторію (включно з
  `build/`) до і після прогону — байт у байт, включно з `mtime`. Це не стилістика: на цьому стоїть
  законність `kill` за стелею в шимі B4.

- [ ] **Step 8: `session-check.psm1` — гілка відбитка перед евристиками**

Порядок: `Read-KitStorageImprint` → якщо не `$null` і `Test-KitStorageImprintCurrent` → точна
відповідь; інакше евристики. Жодного запису, жодного «оновимо кеш, раз ми його вже прочитали» —
див. інваріант вище.

- [ ] **Step 8а: порожній заголовок при відмові префлайту** (знахідка живого прогону B4)

`session-check` без маніфесту друкує заголовок з порожнім іменем продукту — `session-check —  `,
з двома пробілами, — бо `$Context.Label` на невдалому префлайті порожній. Виглядає як обрізаний
вивід, а не як стан, і це перше, що бачить людина в немігрованому репозиторії. Друкувати заголовок
без роздільника, коли `Label` порожній (або підставляти шлях репозиторію). Тест: репо без маніфесту
→ у виводі немає рядка, що закінчується роздільником і пробілами.

- [ ] **Step 9: Кеш — не стан. Тексти**

Докстрінги `StorageImprint.psm1` і рядок у `templates/CLAUDE.md`: джерело істини про стан —
трейлер `Storage-Version` на вершині `storage/<ключ>`; відбиток гітігнорований, локальний для
машини, і **при видаленому відбитку все працює** — `session-check` просто повертається до
евристик. Формулювати саме так: це не примітка, а перевірка, що кеш не став станом. Різниця зі
`storage.json` — у ролі, не в місці файлу: той був єдиним джерелом, і його втрата ламала
синхронізацію.

- [ ] **Step 10: Прогін і коміт**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

```bash
git add tools/lib/StorageBranch.psm1 tools/lib/StorageImprint.psm1 tools/lib/module-order.txt tools/commands/sync.psm1 tools/commands/session-check.psm1 templates/CLAUDE.md tools/tests/StorageBranch.Tests.ps1 tools/tests/StorageImprint.Tests.ps1 tools/tests/Sync.Tests.ps1 tools/tests/SessionCheck.Tests.ps1
git commit --only -- tools/lib/StorageBranch.psm1 tools/lib/StorageImprint.psm1 tools/lib/module-order.txt tools/commands/sync.psm1 tools/commands/session-check.psm1 templates/CLAUDE.md tools/tests/StorageBranch.Tests.ps1 tools/tests/StorageImprint.Tests.ps1 tools/tests/Sync.Tests.ps1 tools/tests/SessionCheck.Tests.ps1 -m "B3: запаковане сховище розпізнається за data/pack; відбиток sync робить відповідь точною замість вічного «не визначається»"
```

---

## Self-review

| Вимога спеки | Задача |
|---|---|
| `verify`: дамп зі сховища як незалежне джерело, не робоча копія (§3.5) | 1, 4 |
| версія = merge-base `<ref>`/`storage/X`; вершина для `storage/X`; порожній merge-base → «спершу sync»; новіші версії — інформаційно (Q8) | 4 |
| п'ять категорій; binary — лише побайтово; `ConfigDumpInfo.xml` виключено (§3.5) | 3 |
| три результати й дії: рівні / ref попереду (артефакт) / сховище попереду (звірочний коміт `-Apply`) | 4 |
| `dump` для `truth: dump|vendor` за накладкою kit; «база зайнята» трьома мовами → порада (§5) | 2, 5 |
| `session-check`: mtime `data/objects`, не `1cv8ddb.1CD`; незлиті коміти; без платформи (§5) | 6 |
| вилучення `dump-config.ps1` (§5) | 5 |
| тести §12: «verify §3.5» (усі п'ять категорій, binary, ConfigDumpInfo, версія з трейлера при більшій у сховищі — через `-Version`/merge-base), «session-check» (а)(б), «dump» («зайнято» трьома мовами) | 2–6 |
| Integration: `verify` на живому сховищі; `dump` із живої бази (за `V8KIT_LIVE_DUMP=1`) | 4, 5 |
| запаковане сховище: розпізнавання за `1cv8ddb.1CD` і `objects` **або** `pack`; три результати сигналу; код `3` (спека 9f6ad5e §5) | 8 |
| відбиток `build/session-check/<ключ>.json`: `sync` пише (прев'ю і `-Apply`), `session-check` лише читає; кеш ≠ стан (9f6ad5e, 0379351 §3.2) | 8 |

**Свідомо не в B3:** `canon` (потребує бази агента) — B4; `hook-shim` у `check` — B4;
`load-ext.ps1`, `build.ps1`, `Read-V8LocalConnection` — B4; скіли — B5.

**Узгодженість імен:** `Get-KitRepositoryArguments`, `Get-KitExtensionArgument`,
`New-KitStorageInfobase`, `Enter-KitStorageBind`, `Exit-KitStorageBind`, `Invoke-KitStorageCheckout`,
`Test-V8InfobaseBusy`, `Assert-V8InfobaseNotBusy`, `Export-KitTree`, `Get-KitRelativeFiles`,
`Get-KitBinaryPaths`, `Compare-KitTrees`, `Get-KitVerifyVersion`, `Get-KitStorageActivity`,
`Invoke-KitVerify`, `Invoke-KitDump`, `Invoke-KitSessionCheck`, `Write-KitStorageImprint`,
`Read-KitStorageImprint`, `Test-KitStorageImprintCurrent` — однакові в контрактах, коді й
тестах; поля `Compare-KitTrees` (`Equal, CrOnly, Content, OnlyInDump, OnlyInTree, Total`) —
однакові в Task 3 і Task 4; вердикти `equal|ref-ahead|storage-ahead|mixed` — у коді й в
Integration-тесті.
