# C1. Єдиний контекст дампу: `sync`, `verify` і `canon` в одній базі агента — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `sync` і `verify` вивантажують версії сховища з бази агента воркспейсу (де присутня
базова конфігурація), а не з тимчасової ІБ зі стабом — тож обидва боки порівняння `verify`
отримані в одному контексті, і формат перестає читатись як зміст.

**Architecture:** платформний шар (`StoragePlatform.psm1`) перестає створювати ІБ і починає
**резолвити** її через уже наявний `Resolve-KitAgentBase` (`AgentBase.psm1`), який несе запобіжник
«це не дев-база людини». Команди `sync` і `verify` міняють одну функцію на іншу й прокидають
користувача бази в платформні виклики. Стан бази після перемотування історії стає **оголошеним
контрактом**: команди його друкують, скіли ставлять `operation=build` окремим кроком.

**Tech Stack:** PowerShell 7, Pester 5, платформа 1С 8.3.27.x, git.

**Spec:** `docs/superpowers/specs/2026-09-17-single-context-and-upgrades-design.md`, §2, §3, §4, §9.

## Global Constraints

- Мова коду, коментарів, повідомлень і документів — **українська**.
- Тести без `Integration` зелені після **кожної** задачі:
  `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
- Коміт у спільній робочій копії — **точково**: `git add <явний перелік>` +
  `git commit --only -- <ті самі шляхи>`. Ніяких `-a`/`-A`.
- `-Apply` і будь-яка мутація сховища в цьому плані **не з'являються**: змінюється лише те, в
  якій базі виконується вже наявна операція.
- **Усе йде у версію 1.0.1** — ту саму, що вже стоїть у `.claude-plugin/plugin.json` і над якою
  триває робота на гілці `fix/source-parameter-1.0.1` (коміт `29978e6`) разом із правкою контурної
  спеки від архітектора (`18de2be`). Бампу версії цей план не робить: число вже правильне.
- Методика — проєктний скіл `kit-dev` (`.claude/skills/kit-dev/SKILL.md`): рівень ризику в брифі
  субагента, `grep` перед новою перевіркою, guard на властивість а не на текст, мутація тестів
  лише на копії дерева, живий прогін після серії фіксів.
- `New-KitStorageInfobase`, `New-ExtensionInfobase` і `tools/assets/empty-extension` у цьому плані
  **не видаляються** — вони лишаються без викликачів, і їхні наявні тести мають лишитись зеленими
  (спека §2, «Наслідок для стаба»; видалення — окреме рішення після живого прогону).

---

## File Structure

| Файл | Відповідальність | Що робимо |
|---|---|---|
| `tools/lib/StoragePlatform.psm1` | платформний шар «версія сховища → дамп» | + `Get-KitSourceInfobase`; `Invoke-KitStorageCheckout` приймає `-User` |
| `tools/lib/StorageReport.psm1` | читання звіту сховища | `Get-StorageVersions` приймає `-User` |
| `tools/lib/module-order.txt` | порядок імпорту | коментар про нову залежність StoragePlatform → AgentBase |
| `tools/commands/sync.psm1` | реплей версій у дзеркало | база агента замість тимчасової ІБ; контракт стану бази |
| `tools/commands/verify.psm1` | звірка ref зі сховищем | те саме на одній версії |
| `tools/commands/check.psm1` | інваріанти репозиторію | + перевірка `agent-base-required` |
| `tools/tests/StoragePlatform.Tests.ps1` | юніт платформного шару | + тести `Get-KitSourceInfobase` |
| `tools/tests/Sync.Tests.ps1` | наскрізні зупинки `sync` | + три зупинки на базі агента |
| `tools/tests/Verify.Tests.ps1` | наскрізні зупинки `verify` | + та сама зупинка |
| `tools/tests/Check.Tests.ps1` | знахідки `check` | + `agent-base-required` |
| `skills/sync/SKILL.md`, `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md` | процедури агента | `operation=build` після `sync`/`verify`; порядок кроків `finish` |

---

### Task 1: `Get-KitSourceInfobase` — база джерела замість створення ІБ

**Files:**
- Modify: `tools/lib/StoragePlatform.psm1` (додати імпорт `AgentBase.psm1` і функцію; `New-KitStorageInfobase` лишити без змін)
- Modify: `tools/lib/module-order.txt` (коментар)
- Test: `tools/tests/StoragePlatform.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-KitAgentBase -Context <контекст> -Workspace <об'єкт воркспейсу>`
  (`tools/lib/AgentBase.psm1`) — повертає `$null` або об'єкт із полями
  `Workspace, Connection, User, Origin, Kind, Path, IbSwitch, Exists`.
- Produces: `Get-KitSourceInfobase -Context <контекст> -Source <джерело>` → об'єкт
  `[pscustomobject]@{ IbSwitch = <string>; User = <string>; Workspace = <string> }`.
  Кидає виняток із рецептом, якщо бази немає. Використовують Task 3 (`sync`) і Task 4 (`verify`).

- [ ] **Step 1: Написати падаючі тести**

Додати в кінець `Describe` у `tools/tests/StoragePlatform.Tests.ps1`:

```powershell
    Context 'Get-KitSourceInfobase — база джерела' {
        BeforeAll {
            $script:Ctx = [pscustomobject]@{
                RepoRoot   = 'R:\repo'
                Workspaces = @([pscustomobject]@{ Path = 'Alpha_SMB'; FullPath = 'R:\repo\Alpha_SMB'; Project = 'проєкт' })
            }
            $script:Src = [pscustomobject]@{ Key = 'Alpha_SMB'; Type = 'EXTENSION'; Workspace = 'Alpha_SMB' }
        }

        It 'бази немає в v8project.yaml — зупинка з рецептом provision і build' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase { $null }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src } |
                Should -Throw '*kit provision*operation=build*'
        }

        It 'база оголошена, але файлу немає — та сама зупинка, з іменем воркспейсу' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/F "R:\repo\Alpha_SMB\build\ib"'; User = ''; Kind = 'file'; Exists = $false }
            }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src } | Should -Throw '*Alpha_SMB*'
        }

        It 'база на місці — повертає підключення й користувача' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/F "R:\repo\Alpha_SMB\build\ib"'; User = 'agent'; Kind = 'file'; Exists = $true }
            }
            $r = Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src
            $r.IbSwitch  | Should -Be '/F "R:\repo\Alpha_SMB\build\ib"'
            $r.User      | Should -Be 'agent'
            $r.Workspace | Should -Be 'Alpha_SMB'
        }

        It 'серверна база — Exists не перевіряється, підключення віддається як є' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/S "VSDEV\Alpha"'; User = 'agent'; Kind = 'server'; Exists = $true }
            }
            (Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src).IbSwitch | Should -Be '/S "VSDEV\Alpha"'
        }

        It 'воркспейсу джерела немає в контексті — зупинка, а не мовчазний $null' {
            $bad = [pscustomobject]@{ Key = 'X'; Type = 'EXTENSION'; Workspace = 'Beta' }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $bad } | Should -Throw '*Beta*'
        }
    }
```

- [ ] **Step 2: Прогнати — тести мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `The term 'Get-KitSourceInfobase' is not recognized`.

- [ ] **Step 3: Додати імпорт AgentBase у `StoragePlatform.psm1`**

Після наявних імпортів (рядки 4–5), у тому самому стилі й без `-Force`:

```powershell
# Без -Force — та сама конвенція, що для PathSafety і V8 вище. AgentBase у module-order.txt
# стоїть раніше за StoragePlatform, тож у kit.ps1 функція вже є глобально; явний імпорт тут
# потрібен для тестів, які вантажать цей модуль окремо від диспетчера.
Import-Module "$PSScriptRoot/AgentBase.psm1"
```

- [ ] **Step 4: Додати функцію**

Після `New-KitStorageInfobase`, до `Enter-KitStorageBind`:

```powershell
function Get-KitSourceInfobase {
    <#
    .SYNOPSIS
        База, в якій виконуються всі платформні операції джерела: база агента воркспейсу
        (спека 2026-09-17, §2, §3). Замінює New-KitStorageInfobase, яка створювала тимчасову
        ІБ зі стабом.
    .DESCRIPTION
        Серіалізація розширення залежить від того, чи є в базі конфігурація-власник: дамп у
        ІБ зі стабом дає GUID у DesignTimeRef і явні дефолти форм, дамп у базі з власником —
        імена й опущені дефолти. Доки sync/verify дампили зі стаба, а canon — з бази агента,
        verify показував формат як зміст (ішузи #3 і #6).

        Фолбеку на порожню ІБ тут немає НАВМИСНО: він повернув би другий формат у git —
        рівно той розкол, який ця зміна закриває. Тому бази немає — зупинка з рецептом.

        Запобіжник «це не дев-база людини» лежить у Resolve-KitAgentBase (принцип 3) і
        спрацьовує саме тут: після цієї зміни викликач робить ConfigurationRepositoryUpdateCfg,
        який ЗАМІНЮЄ конфігурацію в базі, — помилкове потрапляння в базу людини коштувало б
        її роботи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Source
    )

    $ws = @($Context.Workspaces | Where-Object Path -eq $Source.Workspace) | Select-Object -First 1
    if ($null -eq $ws) {
        throw "Воркспейсу '$($Source.Workspace)' немає в контексті маніфесту — джерело '$($Source.Key)' нікуди не прив'язане."
    }

    $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
    $recipe = ("Джерело '$($Source.Key)' (truth: storage) вивантажується в контексті базової конфігурації — " +
               "потрібна база агента воркспейсу '$($ws.Path)'. Спершу: kit provision -Workspace $($ws.Path) -Apply, " +
               'потім operation=build Уніки, тоді повторіть команду.')
    if ($null -eq $ab) { throw "У v8project.yaml воркспейсу '$($ws.Path)' немає infobase:. $recipe" }
    if ($ab.Kind -eq 'file' -and -not $ab.Exists) { throw "Бази агента ще немає на диску. $recipe" }

    [pscustomobject]@{ IbSwitch = $ab.IbSwitch; User = $ab.User; Workspace = $ws.Path }
}
```

І дописати в `Export-ModuleMember` ім'я `Get-KitSourceInfobase`.

- [ ] **Step 5: Оновити коментар `module-order.txt`**

У рядку про StoragePlatform дописати залежність:

```
# StoragePlatform — після PathSafety і V8 (New-ExtensionInfobase,
# New-V8FileInfobase, Invoke-V8Designer) І після AgentBase (Get-KitSourceInfobase бере
# Resolve-KitAgentBase, C1 Task 1);
```

- [ ] **Step 6: Прогнати — тести мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, зокрема наявні тести `New-KitStorageInfobase` — вони не мали змінитись.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/StoragePlatform.psm1 tools/lib/module-order.txt tools/tests/StoragePlatform.Tests.ps1
git commit --only -- tools/lib/StoragePlatform.psm1 tools/lib/module-order.txt tools/tests/StoragePlatform.Tests.ps1
```

Повідомлення: `StoragePlatform: Get-KitSourceInfobase — база агента як контекст дампу джерела`.

---

### Task 2: користувач бази прокидається в платформні виклики

**Files:**
- Modify: `tools/lib/StoragePlatform.psm1` (`Invoke-KitStorageCheckout`, `Enter-KitStorageBind`, `Exit-KitStorageBind`)
- Modify: `tools/lib/StorageReport.psm1` (`Get-StorageVersions`)
- Test: `tools/tests/StoragePlatform.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitSourceInfobase` (Task 1) — поле `User`.
- Produces: `Invoke-KitStorageCheckout -IbSwitch <s> -Source <s> -Version <int> -Target <s> -MustBeUnder <s> [-User <s>]`
  і `Get-StorageVersions … [-User <s>]`. Обидва передають `-User` у `Invoke-V8Designer`.

**Чому:** тимчасова ІБ створювалась без користувачів, тож `-User` був не потрібен. База агента
може мати користувача — `canon.psm1:226` і `dump.psm1:59` уже передають `-User $ab.User`. Без
цього `sync` у базі з користувачами відповість помилкою автентифікації замість роботи.

- [ ] **Step 1: Написати падаючий тест**

Додати в `tools/tests/StoragePlatform.Tests.ps1`, у `Context 'Get-KitSourceInfobase — база джерела'` сусідом:

```powershell
    Context 'користувач бази доходить до платформи' {
        It 'Invoke-KitStorageCheckout передає -User у Invoke-V8Designer' {
            $script:seen = @()
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $script:seen += $User
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $target = Join-Path $TestDrive 'dump'
            Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                -Target $target -MustBeUnder $TestDrive -User 'agent' | Out-Null
            $script:seen | Should -Contain 'agent'
        }

        It 'без -User викликає платформу без користувача — стара поведінка не змінилась' {
            $script:seen = @()
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $script:seen += [string]$User
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $target = Join-Path $TestDrive 'dump2'
            Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                -Target $target -MustBeUnder $TestDrive | Out-Null
            $script:seen | Should -Not -Contain 'agent'
        }
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `A parameter cannot be found that matches parameter name 'User'`.

- [ ] **Step 3: Додати параметр у `Invoke-KitStorageCheckout`**

У блок `param(...)` після `$MustBeUnder`:

```powershell
        [string]$User = ''
```

І в обидва виклики платформи всередині функції додати `-User $User`:

```powershell
    $upd = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @(('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $Version, $ext)))
```

```powershell
    $dump = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $Target, $ext))
```

`Invoke-V8Designer` уже ігнорує порожній `$User` (`if ($User) { … }`, `V8.psm1:129`), тож
поведінка без параметра не змінюється.

- [ ] **Step 4: Те саме для `Enter-KitStorageBind` і `Exit-KitStorageBind`**

Обидві отримують `[string]$User = ''` і передають `-User $User` у свій `Invoke-V8Designer`.
Причина: прив'язка конфігурації до сховища виконується в тій самій базі й тим самим
користувачем; лишити її без користувача означало б, що пара Bind/Unbind у базі з
автентифікацією розпадеться (Enter впаде, Exit не виконається).

- [ ] **Step 5: Те саме для `Get-StorageVersions`**

У `tools/lib/StorageReport.psm1` додати в `param(...)`:

```powershell
        [string]$User = ''
```

і передати в наявний виклик:

```powershell
    $result = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments (Get-StorageReportArguments `
        -ReportPath $reportPath -StoragePath $StoragePath -StorageUser $StorageUser `
        -StoragePassword $StoragePassword -ExtensionName $ExtensionName)
```

**Увага:** `-User` (користувач **бази**) і `-StorageUser` (користувач **сховища**) — різні речі
й не взаємозамінні. Не плутати: перший іде в `/N`, другий у `/ConfigurationRepositoryN`.

- [ ] **Step 6: Прогнати — має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/StoragePlatform.psm1 tools/lib/StorageReport.psm1 tools/tests/StoragePlatform.Tests.ps1
git commit --only -- tools/lib/StoragePlatform.psm1 tools/lib/StorageReport.psm1 tools/tests/StoragePlatform.Tests.ps1
```

Повідомлення: `платформний шар: користувач бази доходить до 1cv8 — база агента може його мати`.

---

### Task 3: `sync` працює в базі агента

**Files:**
- Modify: `tools/commands/sync.psm1`
- Test: `tools/tests/Sync.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitSourceInfobase` (Task 1), `-User` у `Get-StorageVersions` і
  `Invoke-KitStorageCheckout` (Task 2).
- Produces: підсумковий рядок `База агента воркспейсу '<ws>' тепер містить версію <N> зі сховища. Перед роботою: operation=build Уніки.`
  — на нього спирається Task 6 (скіли) і тести.

- [ ] **Step 1: Написати падаючі тести**

Додати в `tools/tests/Sync.Tests.ps1` у наявний `Describe`:

```powershell
    It 'бази агента немає — зупинка з рецептом, дамп не починається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-agent-base') -WithHooks
        # Каталог сховища має існувати, інакше sync зупиниться раніше — на ньому.
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*kit provision*'
        $r.Output   | Should -BeLike '*operation=build*'
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
    }

    It 'база агента збігається з дев-базою людини — зупинка до платформи (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-base') -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*дев-базою людини*'
    }

    It 'у v8project.yaml немає infobase: — зупинка з іменем воркспейсу' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-infobase') -Workspaces $ws -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*Alpha_SMB*'
        $r.Output   | Should -BeLike '*infobase*'
    }
```

- [ ] **Step 2: Прогнати — мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `sync` доходить до `Get-V8Path` або створює тимчасову ІБ замість зупинки.

- [ ] **Step 3: Замінити створення ІБ на резолв бази**

У `tools/commands/sync.psm1`, у рядку

```powershell
        Write-Host 'Створюю тимчасову ІБ і читаю історію сховища...'
        $ibSwitch = New-KitStorageInfobase -Source $src -WorkDir $workDir
```

замінити на

```powershell
        # Дамп — у базі агента воркспейсу, а не в тимчасовій ІБ зі стабом (спека 2026-09-17 §2):
        # серіалізація розширення залежить від присутності конфігурації-власника, і дамп зі
        # стаба давав GUID там, де canon дає імена. Get-KitSourceInfobase несе запобіжник
        # «це не дев-база людини» — критичний саме тут, бо UpdateCfg замінює конфігурацію в базі.
        $agent    = Get-KitSourceInfobase -Context $Context -Source $src
        $ibSwitch = $agent.IbSwitch
        Write-Host "База агента: $ibSwitch (воркспейс $($agent.Workspace))"
        Write-Host 'Читаю історію сховища...'
```

- [ ] **Step 4: Перенести резолв бази до перевірок, що йдуть до платформи**

Перевірка бази дешева (читання YAML) і має стояти поруч із перевіркою каталогу сховища, ДО
створення робочої теки. Перемістити рядок `$agent = Get-KitSourceInfobase …` угору — одразу
після блоку

```powershell
        if (-not (Test-Path -LiteralPath $src.StoragePath)) {
            throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)."
        }
```

а нижче лишити тільки `$ibSwitch = $agent.IbSwitch` і два `Write-Host`.

- [ ] **Step 5: Прокинути користувача бази у платформні виклики**

`Get-StorageVersions` — додати `-User $agent.User`:

```powershell
        $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath `
            -ExtensionName $(if ($src.Type -eq 'EXTENSION') { $src.Key } else { '' }) `
            -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -User $agent.User
```

`Invoke-KitStorageCheckout` у циклі реплею — так само:

```powershell
                $null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                    -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -User $agent.User
```

`Enter-KitStorageBind` / `Exit-KitStorageBind` — додати `-User $agent.User` в обидва виклики.

- [ ] **Step 6: Розпізнати «розширення не знайдено» і перекласти в рецепт**

У `tools/lib/StoragePlatform.psm1`, у `Invoke-KitStorageCheckout`, замінити зупинку після
`UpdateCfg`:

```powershell
    if ($upd.ExitCode -ne 0) { throw "Оновлення до версії $Version не вдалося: $($upd.Output)" }
```

на

```powershell
    if ($upd.ExitCode -ne 0) {
        Assert-V8InfobaseNotBusy -Output $upd.Output -Infobase 'агента'
        # База агента є, але порожня: operation=build у неї ще не вантажив розширення, і сховище
        # відповідає «расширение … не найдено». Сирий текст платформи тут читається як проблема
        # сховища, хоча проблема в базі — той самий прийом перекладу, що в Assert-V8InfobaseNotBusy.
        if ($Source.Type -eq 'EXTENSION' -and $upd.Output -match '(?i)расширени\w+ .*не найдено|розширенн\w+ .*не знайдено') {
            throw ("У базі немає розширення '$($Source.Key)' — вона ще не наповнена з дерева. " +
                   "Спершу operation=build Уніки (cwd — воркспейс), тоді повторіть.`nПлатформа відповіла: $($upd.Output)")
        }
        throw "Оновлення до версії $Version не вдалося: $($upd.Output)"
    }
```

- [ ] **Step 7: Надрукувати контракт стану бази**

Після рядка `Write-Host ("Перенесено версій: {0} → {1}" …)` додати:

```powershell
        # Контракт спеки §4: перемотування історії ЗАМІНЮЄ конфігурацію в базі агента, і база
        # лишається у стані останньої прочитаної версії. Це не побічний ефект, а оголошена
        # поведінка — мовчати про неї означало б, що наступний operation=syntax чи test побіжить
        # не на тому стані, який агент вважає своїм.
        Write-Host ("База агента воркспейсу '{0}' тепер містить версію {1} зі сховища. Перед роботою: operation=build Уніки." -f `
            $agent.Workspace, $done[-1]) -ForegroundColor Yellow
```

- [ ] **Step 8: Прогнати — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 9: Мутаційна перевірка запобіжника (kit-dev, case 6 і 7 — на КОПІЇ дерева)**

```bash
cp -r /r/github/SMP_V8StorageKit "$TMPDIR/kit-mutation" && cd "$TMPDIR/kit-mutation"
```

У копії замінити `Get-KitSourceInfobase -Context $Context -Source $src` на пряме
`Resolve-KitAgentBase` без перевірки збігу — тест «база агента збігається з дев-базою людини»
має **впасти**. Якщо він лишається зеленим — тест перевіряє не те, що треба, і його треба
переписати. Копію видалити після перевірки; у робочому дереві нічого не міняти.

- [ ] **Step 10: Коміт**

```bash
git add tools/commands/sync.psm1 tools/lib/StoragePlatform.psm1 tools/tests/Sync.Tests.ps1
git commit --only -- tools/commands/sync.psm1 tools/lib/StoragePlatform.psm1 tools/tests/Sync.Tests.ps1
```

Повідомлення: `sync: реплей версій у базі агента — один контекст із canon, GUID більше не потрапляють у дзеркало`.

---

### Task 4: `verify` працює в базі агента

**Files:**
- Modify: `tools/commands/verify.psm1`
- Test: `tools/tests/Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitSourceInfobase` (Task 1), `-User` (Task 2).
- Produces: той самий рядок контракту стану бази, що й Task 3, але з версією, яку звіряли.

- [ ] **Step 1: Написати падаючий тест**

Додати в `tools/tests/Verify.Tests.ps1`, у `Describe 'kit verify — штатні зупинки до платформи'`
(рядок 2), поруч із іншими зупинками. Хелпер `script:Invoke-Verify` там уже визначений (рядок 6) —
його й використовуємо:

```powershell
    It 'бази агента немає — verify зупиняється з рецептом, не створивши build/verify' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-no-base') -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        git -C $repo branch 'storage/Alpha_SMB' 2>&1 | Out-Null
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*kit provision*'
        Join-Path $repo 'build/verify/Alpha_SMB' | Should -Not -Exist
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `verify` створює `build/verify/Alpha_SMB` і йде до платформи.

- [ ] **Step 3: Додати резолв бази у план перевірок**

У `Invoke-KitVerify`, у блоці `$plan = @(foreach ($src in $sources) { … })`, після перевірки
шляху сховища додати резолв — саме тут, бо цей блок і є «усі перевірки до першого звернення до
платформи»:

```powershell
        $agent = Get-KitSourceInfobase -Context $Context -Source $src
        [pscustomobject]@{ Source = $src; Info = $vv; Agent = $agent; Version = $(if ($null -ne $Version) { [int]$Version } else { $vv.Version }) }
```

- [ ] **Step 4: Використати базу замість створення ІБ**

Замінити

```powershell
        Write-Host '  Тимчасова ІБ, версія зі сховища, дамп...'
        $ib = New-KitStorageInfobase -Source $src -WorkDir $workDir
```

на

```powershell
        $ib = $item.Agent.IbSwitch
        Write-Host "  База агента ($ib), версія зі сховища, дамп..."
```

і розширити розпакування плану на початку циклу:

```powershell
        $src = $item.Source; $vv = $item.Info; $ver = $item.Version; $agent = $item.Agent
```

- [ ] **Step 5: Прокинути користувача й надрукувати контракт**

`Enter-KitStorageBind`, `Exit-KitStorageBind`, `Invoke-KitStorageCheckout` — додати `-User $agent.User`.
Після рядка `Write-Host "  Файлів: у дампі $dumpCount, у дереві '$ref' $treeCount"` додати:

```powershell
        Write-Host ("  База агента воркспейсу '{0}' тепер містить версію {1} зі сховища. Перед роботою: operation=build Уніки." -f `
            $agent.Workspace, $ver) -ForegroundColor Yellow
```

- [ ] **Step 6: Прибрати створення теки `ib` у робочій теці verify**

Рядок `$workDir = Join-Path $root 'build/verify' $src.Key` лишається — там ще живуть `dump` і
`tree`. Нічого видаляти не треба: `ib` тепер просто не створюється.

- [ ] **Step 7: Прогнати — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 8: Коміт**

```bash
git add tools/commands/verify.psm1 tools/tests/Verify.Tests.ps1
git commit --only -- tools/commands/verify.psm1 tools/tests/Verify.Tests.ps1
```

Повідомлення: `verify: звірка в базі агента — обидва боки порівняння в одному контексті`.

---

### Task 5: `check` попереджає про відсутню базу заздалегідь

**Files:**
- Modify: `tools/commands/check.psm1`
- Test: `tools/tests/Check.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-KitAgentBase`, `New-KitFinding -Level warn -Check 'agent-base-required' -Message <текст>`.
- Produces: знахідка `agent-base-required` — її читає `session-check` (він друкує всі `warn` над
  сигналами без змін у своєму коді).

**Чому окремою перевіркою, а не покладатись на зупинку `sync`:** сказати на старті сесії дешевше,
ніж після того, як людина запустила команду. `grep` перед написанням (kit-dev, case 5): наявної
перевірки на базу агента в `check.psm1` немає — там є лише звірка підключення з дев-базою
людини (рядки 359–367).

- [ ] **Step 1: Написати падаючий тест**

```powershell
    It 'джерело truth: storage у воркспейсі без бази агента — warn agent-base-required' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-no-base') -Workspaces $ws -WithHooks
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*agent-base-required*'
        $r.Output | Should -BeLike '*Alpha_SMB*'
    }

    It 'база агента на місці — знахідки немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-with-base') -WithHooks
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*agent-base-required*'
    }
```

Обидва тести йдуть у `Describe 'kit check — інваріанти репозиторію-споживача'` (рядок 2);
хелпер `script:Invoke-Check` там уже визначений (рядок 7).

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — рядка `agent-base-required` у виводі немає.

- [ ] **Step 3: Додати перевірку**

У `Invoke-KitCheck`, там де вже обходяться джерела, додати:

```powershell
    # Після C1 дамп версії сховища виконується в базі агента (спека 2026-09-17 §3), тож для
    # кожного truth: storage база — передумова, а не зручність. Сказати на старті сесії дешевше,
    # ніж зупинити sync, який людина вже запустила. warn, не error: репозиторій несуперечливий —
    # просто ще не готовий до sync на ЦІЙ машині.
    foreach ($src in @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)) {
        $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1
        if ($null -eq $ws) { continue }
        $ab = $null
        try { $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws } catch { continue }  # збіг із базою людини вже описує інша знахідка
        if ($null -eq $ab -or ($ab.Kind -eq 'file' -and -not $ab.Exists)) {
            & $add 'warn' 'agent-base-required' (
                "Джерело '$($src.Key)' (truth: storage) вивантажується в контексті базової конфігурації, а бази агента " +
                "воркспейсу '$($ws.Path)' немає: kit provision -Workspace $($ws.Path) -Apply, потім operation=build Уніки.")
        }
    }
```

Місце вставки — після блоку, що вже викликає `Select-KitSources` (`check.psm1:44`), у тій самій
функції `Invoke-KitCheck`. Знахідки тут додають **не** прямим `$findings.Add(...)`, а готовим
скриптблоком `$add` (`check.psm1:40`) — це конвенція файлу: `& $add <рівень> <ім'я> <текст>`.

- [ ] **Step 4: Прогнати — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 5: Коміт**

```bash
git add tools/commands/check.psm1 tools/tests/Check.Tests.ps1
git commit --only -- tools/commands/check.psm1 tools/tests/Check.Tests.ps1
```

Повідомлення: `check: agent-base-required — база агента потрібна кожному truth: storage`.

---

### Task 6: скіли отримують `operation=build` і правильний порядок кроків

**Files:**
- Modify: `skills/sync/SKILL.md`
- Modify: `skills/reconcile/SKILL.md`
- Modify: `skills/finish/SKILL.md`
- Test: `tools/tests/Skills.Tests.ps1`

**Interfaces:**
- Consumes: рядок контракту з Task 3 і Task 4.
- Produces: процедури, в яких `operation=build` стоїть після `sync`/`verify`, а не перед самим
  лише `canon`.

**Чому це не косметика:** у `finish` `verify` — крок 4, тести Unica — крок 5. Після C1 `verify`
лишає базу у стані сховища, тож тести побігли б **не на тому стані**, який іде в PR. Порядок
кроків — частина виправлення, а не документація до нього.

- [ ] **Step 1: Написати падаючий тест**

У `tools/tests/Skills.Tests.ps1`:

```powershell
    It 'finish ставить operation=build між verify і тестами' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/finish/SKILL.md') -Raw -Encoding UTF8
        $posVerify = $text.IndexOf('kit.ps1" verify')
        $posBuild  = $text.IndexOf('operation=build', $posVerify)
        $posTests  = $text.IndexOf('operation=syntax', $posVerify)
        $posVerify | Should -BeGreaterThan -1
        $posBuild  | Should -BeGreaterThan $posVerify
        $posTests  | Should -BeGreaterThan $posBuild
    }

    It 'sync і reconcile попереджають, що база лишається у стані сховища' {
        foreach ($s in @('sync', 'reconcile')) {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../skills/$s/SKILL.md") -Raw -Encoding UTF8
            $text | Should -BeLike '*operation=build*'
        }
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — у `finish` `operation=build` стоїть перед `verify`, не після.

- [ ] **Step 3: Правка `skills/sync/SKILL.md`**

Після кроку, що запускає `kit sync -Apply`, додати:

```markdown
**Після `sync` база агента містить версію зі сховища, а не ваше дерево.** Це оголошений контракт
(спека 2026-09-17 §4), і `sync` друкує про це рядком. Перед будь-якою роботою з базою — синтаксисом,
тестами, збіркою — `operation=build` Уніки (`cwd` = воркспейс).
```

- [ ] **Step 4: Правка `skills/reconcile/SKILL.md`**

Крок 2 («База агента — з поточного дерева `F`») лишається, але отримує причину, яка тепер
подвійна:

```markdown
2. **База агента — з поточного дерева `F`**: `operation=build` Уніки (`cwd` = воркспейс). Два
   приводи, не один: (а) `canon` переписує дерево з бази, і без свіжого `build` він знищить
   незакомічене; (б) крок 1 (`sync`) щойно лишив базу у стані версії сховища — це контракт, а не
   збій (спека 2026-09-17 §4).
```

- [ ] **Step 5: Правка `skills/finish/SKILL.md` — новий порядок**

Кроки 4–5 переписати так:

```markdown
4. **Звірка `F` зі сховищем**: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" verify -RepoRoot . -Ref <F>`.
   Очікувано `ref-ahead` (робота задачі — це й є залишок для сховища) або `equal`; `storage-ahead`/`mixed`
   означає, що крок 3 не завершено.

   **Гейт «повідомити користувача»** — без змін (див. нижче).

5. **Відновити базу агента**: `operation=build` Уніки (`cwd` = воркспейс). Крок 4 лишив базу у
   стані версії сховища (спека 2026-09-17 §4) — без цього кроку тести побіжать не на тому стані,
   який іде в PR.

6. **Тести й синтаксис** (Unica, `cwd` = воркспейс): `operation=syntax`, потім `operation=test`
   (`testRunner=yaxunit` або `va`). Червоне — PR не готувати; повернутись до роботи.
```

Далі перенумерувати наявні кроки «Артефакти» → 7 і «PR» → 8.

**Перенумерація тягне посилання** (kit-dev, case 9): `grep -rn 'крок 5\|крок 6\|крок 7' skills/ docs/`
і поправити кожне влучання, що вказує на зсунуті кроки, — не лише в самому файлі.

- [ ] **Step 6: Прогнати — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, зокрема наявні тести `Skills.Tests.ps1` про структуру скілів.

- [ ] **Step 7: Перевірити правило `${CLAUDE_PLUGIN_ROOT}`**

```bash
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
```

Expected: порожньо. Токен допустимий лише **всередині шляху** — речення *про* токен після
підстановки стане вказівкою вписати абсолютний шлях конкретної машини.

- [ ] **Step 8: Коміт**

```bash
git add skills/sync/SKILL.md skills/reconcile/SKILL.md skills/finish/SKILL.md tools/tests/Skills.Tests.ps1
git commit --only -- skills/sync/SKILL.md skills/reconcile/SKILL.md skills/finish/SKILL.md tools/tests/Skills.Tests.ps1
```

Повідомлення: `скіли: operation=build після sync і verify — база лишається у стані сховища`.

---

## Фінальна перевірка блоку

- [ ] **Повний прогін без `Integration`**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: усе зелене.

- [ ] **Живий прогін після серії правок** (kit-dev, case 19 — фікс сам породжує дефект поруч,
      і бачить це лише запуск):

```bash
pwsh -NoProfile -File tools/kit.ps1 check -RepoRoot . 2>&1 | head -20
```

Expected: префлайт зупиняється на відсутньому `v8storagekit.yaml` — цей репозиторій не є
споживачем, і саме така відповідь підтверджує, що диспетчер і модулі вантажаться без помилок
імпорту після зміни `module-order.txt`.

- [ ] **Інтеграційний прогін — за окремим підтвердженням користувача** (kit-dev, case 8):
      на репозиторії з розширенням, що має власні об'єкти, послідовність `sync` → `operation=build`
      → `canon` → `verify` має дати `equal` без «змістовних розбіжностей». Це і є приймальна
      ознака всього блоку: доти зміна вважається неперевіреною, скільки б юніт-тестів не було
      зелених.

---

## Що цей блок НЕ робить

- не додає `kit adopt`, не чіпає `origin`, не править текстів про артефакти й не вводить
  `kitVersion` — усе це блок **C2** (спека §5–§8), який виходить у тій самій версії 1.0.1;
- не видаляє стаба, `New-KitStorageInfobase` і `New-ExtensionInfobase` (спека §2 — після живого
  прогону на кількох репозиторіях).
