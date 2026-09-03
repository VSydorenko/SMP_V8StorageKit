# B2. `sync` у гілки `storage/*` — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** замінити `storage-sync.ps1` командою `kit sync`, яка реплеїть нові версії кожного
джерела з `truth: storage` в orphan-гілку `storage/<ключ>` через тимчасовий worktree, бере
стан із трейлерів git, робить перше злиття в головну гілку, і працює як для розширень, так і
для сховищ конфігурацій; вилучити `storage.json`, `SyncState.psm1` і старий скрипт.

**Architecture:** платформна частина (тимчасова ІБ, звіт сховища, `UpdateCfg`, `DumpConfigToFiles`)
лишається в `V8.psm1`/`StorageReport.psm1` майже без змін; git-частина розкладається на
тестовані без платформи функції — `New-/Remove-KitStorageWorktree`, `Write-KitStorageVersion`
(коміт уже вивантаженого дерева), `Merge-KitBranchInto` (три гілки рішення Q4),
`Get-KitPendingVersions`, `New-KitStorageCommitMessage`. Команда `sync` лише оркеструє.
Спайк зі сховищем конфігурації йде **першим** (спека §14): від його результату залежить,
чи потрібен `BindCfg`/`UnbindCfg` для `CONFIGURATION`.

**Tech Stack:** PowerShell 7.5, Pester 5, git 2.53 (`worktree add --orphan`, `merge --allow-unrelated-histories`,
`merge-base --is-ancestor`), платформа 1С 8.3.27.x (лише для тегу `Integration` і спайку).

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` — §3.1–3.4 (гілки, стан,
захист, злиття), §5 (`sync`), §12 (тести: «стан із git», «злиття §3.4», «worktree §3.3»),
§14 (B2, спайк сховища конфігурації). Політика тексту —
`docs/superpowers/specs/2026-08-31-unica-canon-transition-design.md` §5.2–5.3.

## Global Constraints

- **PowerShell 7+**, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`; кожен
  нативний виклик перевіряється через `$LASTEXITCODE`.
- **Мова всього, що бачить людина** — українська; ASCII-якір у кожному повідомленні зупинки
  (див. B1, «Спільні контракти»).
- **Прогін тестів без платформи:** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  **Повний прогін** (Task 1 спайк, Task 5 Integration) запускає `1cv8.exe` і читає **живі
  сховища** — виконується лише з підтвердженням користувача в сесії виконання.
- **Сховища конфігурацій — тільки читання.** `ConfigurationRepositoryReport`, `…UpdateCfg` —
  так. `…Commit`, `…Lock`, `…UnlockObjects` — ніколи. **Єдиний документований виняток**
  (спека §14): якщо спайк доведе, що `UpdateCfg` для основної конфігурації потребує
  `ConfigurationRepositoryBindCfg`, прив'язка робиться під користувачем `gitbot` і
  **обов'язково** знімається `ConfigurationRepositoryUnbindCfg -force` у `finally`.
- **`-Apply` — лише коли користувач явно попросив.** Прев'ю `sync` теж піднімає платформу.
- **Гілки `storage/*` пише лише `sync`, і лише з `V8KIT_SYNC=1`** на час коміту; змінна
  прибирається у `finally`. Хук B1 спрацьовує і в linked worktree (перевірено).
- **Байти в git — байти платформи.** У worktree гілки `storage/*` немає `.gitattributes`, тому
  `git add` там виконується з `-c core.autocrlf=false`, а `ConfigDumpInfo.xml` і
  `DumpFilesIndex.txt` видаляються з дампу до `git add` (у дереві дзеркала їх нема).
- **Ліцензія 1С:** `Assert-NoLicenseProblem` лишається на кожному виклику платформи.
- **Форма тесту** — за `CLAUDE.md`: справжній артефакт, ізольоване репо в `$TestDrive`, перевірка
  і тексту зупинки, і того, що наступний крок не відбувся.
- **Версію `plugin.json` не піднімати. `git push` — ні.**
- **Головна гілка kit — `main`; робота в `feature/agent-contour`.**
- **Відоме вікно між блоками:** Task 5 цього плану вилучає гілку `.cfe` зі старого `build.ps1`, а команда
  `kit build` з'являється лише в B4 Task 3. Між ними kit **не збирає `.cfe` взагалі** — це не дефект,
  а свідомий стан під локальним маркетплейсом без релізу (`.cfe` збирає `operation=make` Уніки); виконавцю
  B3 не шукати тут проблеми.

### Рішення, узгоджені з архітектором (спека після 6f95c75)

| # | Питання | Рішення | Де в спеці |
|---|---|---|---|
| Q3 | сховище конфігурації | спайк першим на **найменшому** живому сховищі з `R:\СховищаКонфігурацій_1С\` (19 сховищ, читає `gitbot`): (1) стаб не потрібен — порожня ІБ + `UpdateCfg -v N -force` без `-Extension`; (2) якщо платформа відмовить — `BindCfg -forceBindAlreadyBindedUser -forceReplaceCfg`, потім обов'язково `UnbindCfg -force`. Результат — у спеку §14 і в код | §14 |
| Q4 | куди зливати в `main` | `HEAD`=`main` і чисто → на місці; `HEAD`=`main` і брудно → зупинка; інакше → тимчасовий worktree `build/sync/_main/wt` | §3.4 |
| Q5 | `mainBranch` | з контексту префлайту (`$ctx.MainBranch`) | §2.4 |
| Q7 | версії/пуші | нічого не пушити; локальний маркетплейс уже стоїть (B1 Task 10) | §14 |

---

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `docs/superpowers/specs/2026-09-03-agent-contour-design.md` §14 | абзац «Результат спайку» — факт про `BindCfg` | 1 |
| `tools/lib/StorageReport.psm1` | `Get-StorageVersions`: `-ExtensionName` необов'язковий (сховище конфігурації — без `-Extension`) | 2 |
| `tools/lib/StorageBranch.psm1` | + `Get-KitPendingVersions`, `Get-KitVersionGapNote`, `New-KitStorageCommitMessage`, `New-KitStorageWorktree`, `Remove-KitStorageWorktree`, `Clear-KitWorktreeSource`, `Write-KitStorageVersion` | 2, 3 |
| `tools/lib/GitMerge.psm1` | **новий.** `Test-KitBranchMergedInto`, `Merge-KitBranchInto` — три гілки Q4, `--allow-unrelated-histories`, `--no-ff` | 3 |
| `tools/lib/module-order.txt` | + `GitMerge` після `StorageBranch` | 3 |
| `tools/commands/sync.psm1` | **новий.** `Invoke-KitSync` — оркестрація: префлайт-контекст → ІБ → звіт → прев'ю → реплей у worktree → перше злиття | 4 |
| `tools/tests/StorageReport.Tests.ps1` | тест на аргументи без `-Extension` | 2 |
| `tools/tests/StorageBranch.Tests.ps1` | + pending, message, worktree, `Write-KitStorageVersion` | 2, 3 |
| `tools/tests/GitMerge.Tests.ps1` | **новий.** сценарії §3.4 і Q4 | 3 |
| `tools/tests/Sync.Tests.ps1` | **новий.** `kit.ps1 sync` підпроцесом: штатні зупинки до платформи; `Integration` — реальні сховища | 4 |
| `tools/storage-sync.ps1`, `tools/lib/SyncState.psm1`, `tools/tests/StorageSync.Tests.ps1`, `tools/tests/SyncState.Tests.ps1`, `templates/storage.json.example` | **вилучаються** | 5 |
| `tools/lib/V8.psm1` | `Read-V8LocalStoragePath` вилучається (перевизначення — у накладці kit) | 5 |
| `tools/build.ps1` | без `SyncState`: лише гілка `.epf` (гілку `.cfe` вилучає спека §5; повна заміна на `kit build` — B4) | 5 |
| `tools/tests/Build.Tests.ps1`, `tools/tests/ModuleImportOrder.Tests.ps1`, `tools/tests/V8.Tests.ps1` | без тестів на вилучене | 5 |
| `templates/README.md`, `templates/CLAUDE.md`, `skills/storage-pipeline/SKILL.md` | перехідна позначка: `storage-sync.ps1` → `kit.ps1 sync`; повне переписування — B5 | 5 |
| `docs/follow-ups.md` | §4 і §14 — позначки про долю згаданих тестів і команди | 5 |

---

## Спільні контракти блоку

```
StorageReport.psm1
  Get-StorageVersions -IbSwitch -StoragePath -StorageUser -WorkDir [-ExtensionName]   (порожній → без -Extension)

StorageBranch.psm1 (додається до B1)
  Get-KitPendingVersions -AllVersions <@(report version)> -LastVersion <int|$null> [-MaxVersions <int>]
      : → @(version) за зростанням; зупинка, якщо LastVersion > max у звіті або звіт порожній при LastVersion ≠ $null
  New-KitStorageCommitMessage -Version <report version> -SourceKey -SourceType <CONFIGURATION|EXTENSION>
      : → string (тема, тіло, порожній рядок, трейлери Storage-Source/Storage-Version/Extension-Version|Config-Version/Storage-User)
  New-KitStorageWorktree -RepoRoot -Branch -Path : → {Path; Branch; Created:bool}  (orphan, якщо гілки нема)
  Remove-KitStorageWorktree -RepoRoot -Path
  Clear-KitWorktreeSource -WorktreePath -RepoPath : → абсолютний шлях порожньої теки <wt>/<RepoPath> (сюди дампить платформа)
  Write-KitStorageVersion -WorktreePath -RepoPath -Message -AuthorName -AuthorEmail -Timestamp <datetime>
      : → {Sha; Empty:bool}  — прибирає ConfigDumpInfo.xml/DumpFilesIndex.txt, git add -c core.autocrlf=false -- <RepoPath>,
        коміт з V8KIT_SYNC=1 і датами версії, --allow-empty

GitMerge.psm1
  Test-KitBranchMergedInto -RepoRoot -Branch -Into : → bool  (git merge-base --is-ancestor)
  Merge-KitBranchInto -RepoRoot -Branch -Into -Message [-AllowUnrelated] [-WorkDir]
      : → {Outcome:'merged'|'already'; Sha; Via:'in-place'|'worktree'}; зупинка на брудному Into або конфлікті

commands/sync.psm1
  Invoke-KitSync -Context [-Workspace] [-Source] [-Apply:bool] [-MaxVersions <int>] [-MergeMain]
      : → {ExitCode; Synced: @({Key; Versions:int[]; Branch; MergedIntoMain:bool})}
```

Робоча тека джерела: `build/sync/<ключ>/` — `ib/` (тимчасова ІБ), `wt/` (worktree гілки),
`dump/` (свіжий дамп версії), `storage-report.mxl`, `commit-message.txt`. Перестворюється на
кожен запуск. Тека злиття в головну гілку: `build/sync/_main/wt`.

---

### Task 1: Спайк — сховище конфігурації без `-Extension` (спека §14)

Мета: **факт**, а не гіпотеза — чи вміє порожня файлова ІБ узяти версію з сховища
**основної конфігурації** через `ConfigurationRepositoryUpdateCfg -v N -force` без
попередньої прив'язки. Результат визначає код Task 5.

Це читання живого сховища й запуск платформи — **лише з підтвердженням користувача**.
Нічого в сховищі не змінюється, крім задокументованого винятку (прив'язка/відв'язка
`gitbot`), і лише якщо шлях (1) не спрацює.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-03-agent-contour-design.md` §14 — абзац «Результат спайку (дата)»
- Create (тимчасово, у scratchpad сесії, не в репо й не в `$env:TEMP`): `spike-cfg-storage.ps1`; робоча тека спайку — там само

- [ ] **Step 1: Вибрати найменше сховище**

```powershell
Get-ChildItem 'R:\СховищаКонфігурацій_1С' -Directory | ForEach-Object {
    $db = Join-Path $_.FullName '1cv8ddb.1CD'
    [pscustomobject]@{ Name = $_.Name; MB = [math]::Round((Get-Item $db -ErrorAction SilentlyContinue).Length / 1MB, 1) }
} | Sort-Object MB | Select-Object -First 5
```

Узяти перше з ненульовим розміром. Записати ім'я — воно піде в звіт спайку й в Integration-тест Task 5.

- [ ] **Step 2: Скрипт спайку** (у scratchpad; шляхи підставити)

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop'
Import-Module R:\github\SMP_V8StorageKit\tools\lib\PathSafety.psm1 -Force
Import-Module R:\github\SMP_V8StorageKit\tools\lib\V8.psm1 -Force

$storage = 'R:\СховищаКонфігурацій_1С\<НАЙМЕНШЕ>'
$work    = Join-Path '<scratchpad сесії>' 'spike-cfg'   # шлях scratchpad — у системному промпті сесії виконавця; не $env:TEMP і не репозиторій
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
$ib = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $work 'ib') -MustBeUnder $work)
$repo = @('/ConfigurationRepositoryF "{0}"' -f $storage, '/ConfigurationRepositoryN "gitbot"', '/ConfigurationRepositoryP ""')

# (0) Звіт без -Extension — читання, завжди дозволене.
$r0 = Invoke-V8Designer -IbSwitch $ib -Arguments ($repo + @('/ConfigurationRepositoryReport "{0}" -NBegin 1 -IncludeCommentLinesWithDoubleSlash' -f (Join-Path $work 'report.mxl')))
"REPORT exit=$($r0.ExitCode)`n$($r0.Output)"
Import-Module R:\github\SMP_V8StorageKit\tools\lib\StorageReport.psm1 -Force
$versions = Read-StorageReport -Path (Join-Path $work 'report.mxl')
$v = ($versions | Select-Object -First 1).Version
"Версій у звіті: $($versions.Count); беремо мінімальну: $v"

# (1) UpdateCfg без прив'язки.
$r1 = Invoke-V8Designer -IbSwitch $ib -Arguments ($repo + @("/ConfigurationRepositoryUpdateCfg -v $v -force"))
"UPDATE-NO-BIND exit=$($r1.ExitCode)`n$($r1.Output)"

$dump = Join-Path $work 'dump'; New-Item -ItemType Directory -Path $dump | Out-Null
if ($r1.ExitCode -eq 0) {
    $d = Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpConfigToFiles "{0}"' -f $dump)
    "DUMP exit=$($d.ExitCode); файлів: $((Get-ChildItem $dump -Recurse -File).Count)"
    "РЕЗУЛЬТАТ: шлях (1) працює — BindCfg НЕ потрібен."
} else {
    # (2) Прив'язка → оновлення → дамп → ОБОВ'ЯЗКОВА відв'язка.
    $bound = $false
    try {
        $b = Invoke-V8Designer -IbSwitch $ib -Arguments ($repo + @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
        "BIND exit=$($b.ExitCode)`n$($b.Output)"
        $bound = ($b.ExitCode -eq 0)
        $r2 = Invoke-V8Designer -IbSwitch $ib -Arguments ($repo + @("/ConfigurationRepositoryUpdateCfg -v $v -force"))
        "UPDATE-AFTER-BIND exit=$($r2.ExitCode)`n$($r2.Output)"
        $d = Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpConfigToFiles "{0}"' -f $dump)
        "DUMP exit=$($d.ExitCode); файлів: $((Get-ChildItem $dump -Recurse -File).Count)"
        "РЕЗУЛЬТАТ: шлях (2) — BindCfg потрібен; текст відмови шляху (1) вище — це патерн для коду."
    } finally {
        if ($bound) {
            $u = Invoke-V8Designer -IbSwitch $ib -Arguments ($repo + @('/ConfigurationRepositoryUnbindCfg -force'))
            "UNBIND exit=$($u.ExitCode)`n$($u.Output)"
        }
    }
}
```

- [ ] **Step 3: Виконати, зберегти повний вивід** (`… *> spike-output.txt` у scratchpad). Якщо
  у виводі є `лиценз|ліценз|license|HASP` — `Assert-NoLicenseProblem` уже зупинив роботу: доповісти
  користувачу, спайк не повторювати.

- [ ] **Step 4: Записати результат у спеку §14** одразу після абзацу «Спайк у B2 — сховище конфігурації»:

```markdown
**Результат спайку (<дата>, сховище `<ім'я>`, платформа <версія>):** <один із двох варіантів:>
(1) `ConfigurationRepositoryUpdateCfg -v N -force` без `-Extension` працює на порожній ІБ без
прив'язки; `BindCfg`/`UnbindCfg` у kit не потрібні. | (2) без прив'язки платформа відмовляє
текстом «<дослівно>»; `BindCfg -forceBindAlreadyBindedUser -forceReplaceCfg` під `gitbot` +
`UpdateCfg` + `UnbindCfg -force` дають дамп із <N> файлів. `sync` робить прив'язку на час
реплею й знімає її у `finally` — це єдиний запис у сховище, який kit виконує.
```

- [ ] **Step 5: Коміт**

```bash
git add docs/superpowers/specs/2026-09-03-agent-contour-design.md
git commit -m "B2: результат спайку — сховище конфігурації без -Extension"
```

---

### Task 2: звіт без `-Extension`, `Get-KitPendingVersions`, `New-KitStorageCommitMessage`

**Files:**
- Modify: `tools/lib/StorageReport.psm1` — `Get-StorageReportArguments` (нова, чиста), `Get-StorageVersions` з необов'язковим `-ExtensionName`
- Modify: `tools/lib/StorageBranch.psm1` — `Get-KitPendingVersions`, `Get-KitVersionGapNote`, `New-KitStorageCommitMessage`
- Modify: `tools/tests/StorageReport.Tests.ps1`, `tools/tests/StorageBranch.Tests.ps1`

**Interfaces:**
- Consumes: об'єкт версії з `Read-StorageReport` (`Version, User, Date, Time, ConfigVersion, Comment, Timestamp`).
- Produces: `Get-StorageReportArguments -ReportPath -StoragePath -StorageUser [-ExtensionName]` → `string[]`; `Get-KitPendingVersions -AllVersions -LastVersion [-MaxVersions]` → `@(version)`; `Get-KitVersionGapNote -Pending -LastVersion` → `string|$null`; `New-KitStorageCommitMessage -Version -SourceKey -SourceType` → `string`.

- [ ] **Step 1: Тести, що падають**

У `tools/tests/StorageReport.Tests.ps1` новий Describe:

```powershell
Describe 'Get-StorageReportArguments — з розширенням і без' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageReport.psm1").Path -Force }

    It 'для розширення додає -Extension до команди-дії, не до /ConfigurationRepositoryF' {
        $a = Get-StorageReportArguments -ReportPath 'C:\w\r.mxl' -StoragePath 'R:\S' -StorageUser 'gitbot' -ExtensionName 'SMP_X'
        $a[0] | Should -Be '/ConfigurationRepositoryF "R:\S"'
        $a[1] | Should -Be '/ConfigurationRepositoryN "gitbot"'
        $a[2] | Should -Be '/ConfigurationRepositoryP ""'
        $a[3] | Should -Be '/ConfigurationRepositoryReport "C:\w\r.mxl" -NBegin 1 -IncludeCommentLinesWithDoubleSlash -Extension SMP_X'
    }

    It 'для сховища конфігурації -Extension немає взагалі' {
        $a = Get-StorageReportArguments -ReportPath 'C:\w\r.mxl' -StoragePath 'R:\S' -StorageUser 'gitbot'
        $a[3] | Should -Be '/ConfigurationRepositoryReport "C:\w\r.mxl" -NBegin 1 -IncludeCommentLinesWithDoubleSlash'
        ($a -join ' ') | Should -Not -Match '-Extension'
    }
}
```

У `tools/tests/StorageBranch.Tests.ps1` — новий Describe (наявний не чіпати):

```powershell
Describe 'StorageBranch.psm1 — план реплею й повідомлення коміту' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:All = @(2, 23, 24, 47 | ForEach-Object { [pscustomobject]@{ Version = $_ } })
        function script:New-Version {
            param([int]$Version, [string]$Comment = 'Правка форми', [string]$ConfigVersion = '1.2.3', [string]$User = 'Абдулов')
            [pscustomobject]@{ Version = $Version; User = $User; Date = '22.01.2026'; Time = '17:51:21'
                ConfigVersion = $ConfigVersion; Comment = $Comment; Label = ''; LabelComment = ''
                Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-22T17:51:21' }
        }
    }

    Context 'Get-KitPendingVersions' {
        It 'порожня гілка ($null) — усі версії зі звіту за зростанням' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null).Version | Should -Be @(2, 23, 24, 47)
        }
        It 'після 23 — лише 24 і 47 (перелік, не діапазон: пропуски штатні)' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion 23).Version | Should -Be @(24, 47)
        }
        It 'усе залито — порожній масив, а не $null (StrictMode-безпечно)' {
            Set-StrictMode -Version Latest
            $p = Get-KitPendingVersions -AllVersions $script:All -LastVersion 47
            { $p.Count } | Should -Not -Throw
            $p.Count | Should -Be 0
        }
        It '-MaxVersions обрізає з голови' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -MaxVersions 2).Version | Should -Be @(2, 23)
        }
        It 'дзеркало попереду сховища — зупинка' {
            { Get-KitPendingVersions -AllVersions $script:All -LastVersion 99 } | Should -Throw '*попереду*99*47*'
        }
        It 'порожній звіт при непорожньому дзеркалі — зупинка; при порожньому — порожньо' {
            { Get-KitPendingVersions -AllVersions @() -LastVersion 5 } | Should -Throw '*порожній*'
            (Get-KitPendingVersions -AllVersions @() -LastVersion $null).Count | Should -Be 0
        }
        It 'Get-KitVersionGapNote: мінімум у звіті > остання + 1 — інформаційний рядок; інакше $null' {
            $p = Get-KitPendingVersions -AllVersions $script:All -LastVersion 2
            Get-KitVersionGapNote -Pending $p -LastVersion 2 | Should -BeLike '*23*2*'
            Get-KitVersionGapNote -Pending (Get-KitPendingVersions -AllVersions $script:All -LastVersion 23) -LastVersion 23 | Should -BeNullOrEmpty
            Get-KitVersionGapNote -Pending $p -LastVersion $null | Should -BeNullOrEmpty
        }
    }

    Context 'New-KitStorageCommitMessage' {
        It 'розширення: тема, порожній рядок, чотири трейлери в цьому порядку' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 47) -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -Be "Правка форми`n`nStorage-Source: SMP_X`nStorage-Version: 47`nExtension-Version: 1.2.3`nStorage-User: Абдулов"
        }
        It 'конфігурація: Config-Version замість Extension-Version' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 3) -SourceKey 'base' -SourceType CONFIGURATION
            $m | Should -BeLike "*`nConfig-Version: 1.2.3`n*"
            $m | Should -Not -BeLike '*Extension-Version*'
        }
        It 'без версії конфігурації — трейлера версії немає; без коментаря — тема «Версія сховища N»' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 8 -Comment '' -ConfigVersion '') -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -Be "Версія сховища 8`n`nStorage-Source: SMP_X`nStorage-Version: 8`nStorage-User: Абдулов"
        }
        It 'багаторядковий коментар: перший непорожній рядок — тема, решта — тіло' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 9 -Comment "`nТема`nДругий рядок`n  третій  ") -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -BeLike "Тема`n`nДругий рядок`n  третій`n`nStorage-Source: SMP_X*"
        }
    }
}
```

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: `StorageReport.psm1`**

Додати перед `Get-StorageVersions` і змінити її:

```powershell
function Get-StorageReportArguments {
    <#
    .SYNOPSIS
        Аргументи Конфігуратора для звіту сховища. -Extension належить команді-дії
        (ранбук, п. 1); для сховища КОНФІГУРАЦІЇ його немає взагалі — сховище одне й
        те саме API, різниця лише в цьому ключі.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$StoragePath,
        [Parameter(Mandatory)][string]$StorageUser,
        [string]$ExtensionName = ''
    )
    $report = '/ConfigurationRepositoryReport "{0}" -NBegin 1 -IncludeCommentLinesWithDoubleSlash' -f $ReportPath
    if ($ExtensionName) { $report += " -Extension $ExtensionName" }
    , @(
        '/ConfigurationRepositoryF "{0}"' -f $StoragePath
        '/ConfigurationRepositoryN "{0}"' -f $StorageUser
        '/ConfigurationRepositoryP ""'
        $report
    )
}
```

У `Get-StorageVersions`: `[Parameter(Mandatory)][string]$ExtensionName` → `[string]$ExtensionName = ''`;
блок `Invoke-V8Designer -IbSwitch $IbSwitch -Arguments @(…)` замінити на

```powershell
    $result = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments (Get-StorageReportArguments `
        -ReportPath $reportPath -StoragePath $StoragePath -StorageUser $StorageUser -ExtensionName $ExtensionName)
```

(великий коментар про `-IncludeCommentLinesWithDoubleSlash` перенести до `Get-StorageReportArguments`).
Додати `Get-StorageReportArguments` до `Export-ModuleMember`.

- [ ] **Step 4: `StorageBranch.psm1` — три функції**

```powershell
function Get-KitPendingVersions {
    <#
    .SYNOPSIS
        Версії зі звіту, які ще не в дзеркалі: перелік із версіями > LastVersion (§3.2), не діапазон.
    .DESCRIPTION
        $null у LastVersion — гілки ще немає: реплеїти все. Два запобіжники успадковані від
        Get-PendingVersions (SyncState.psm1, вилучається): дзеркало попереду максимуму звіту, і
        порожній звіт при непорожньому дзеркалі — обидва зупинка, розбір за людиною.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllVersions,
        [Parameter(Mandatory)][AllowNull()][Nullable[int]]$LastVersion,
        [int]$MaxVersions = 0
    )

    $max = $null
    if ($AllVersions.Count -gt 0) { $max = ($AllVersions | Measure-Object -Property Version -Maximum).Maximum }

    if ($null -ne $LastVersion) {
        if ($AllVersions.Count -eq 0) {
            throw ("Звіт сховища порожній (жодної версії), а дзеркало вже тримає версію $LastVersion. Порожній звіт не " +
                   'підтверджує це — сховище могло стати недоступним чи звіт пошкодженим. Синхронізацію зупинено.')
        }
        if ($LastVersion -gt $max) {
            throw ("Дзеркало попереду сховища: у storage/* версія $LastVersion, а у сховищі максимум $max. " +
                   'Синхронізацію зупинено, розберіться з розбіжністю вручну.')
        }
    }

    $pending = @($AllVersions | Where-Object { $null -eq $LastVersion -or $_.Version -gt $LastVersion } | Sort-Object Version)
    if ($MaxVersions -gt 0) { $pending = @($pending | Select-Object -First $MaxVersions) }
    , $pending
}

function Get-KitVersionGapNote {
    <#
    .SYNOPSIS
        Інформаційний рядок, коли мінімум серед нових версій > остання + 1 — сховище оптимізували
        до того, як ми забрали проміжні (§3.2). Не помилка.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pending,
        [Parameter(Mandatory)][AllowNull()][Nullable[int]]$LastVersion
    )
    if ($null -eq $LastVersion -or $Pending.Count -eq 0) { return $null }
    $min = ($Pending | Measure-Object -Property Version -Minimum).Minimum
    if ($min -gt $LastVersion + 1) {
        return "У звіті найменша нова версія $min, а дзеркало на $LastVersion — проміжних версій у сховищі вже немає (оптимізовано)."
    }
    $null
}

function New-KitStorageCommitMessage {
    <#
    .SYNOPSIS
        Повідомлення коміту версії сховища: коментар версії + трейлери (§3.1).
        Storage-User — сирий рядок зі звіту, окремо від git-автора (docs/storage-and-git.md, «Три трейлери»).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Version,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][ValidateSet('CONFIGURATION', 'EXTENSION')][string]$SourceType
    )

    $lines   = @(([string]$Version.Comment) -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $subject = ($lines | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $subject) { $subject = "Версія сховища $($Version.Version)" }
    $body = @($lines | Select-Object -Skip ([array]::IndexOf($lines, $subject) + 1))

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($subject)
    if ($body.Count -gt 0 -and ($body -join '').Trim()) {
        $out.Add('')
        foreach ($b in $body) { $out.Add($b) }
    }
    $out.Add('')
    $out.Add("Storage-Source: $SourceKey")
    $out.Add("Storage-Version: $($Version.Version)")
    if ($Version.ConfigVersion) {
        $key = if ($SourceType -eq 'EXTENSION') { 'Extension-Version' } else { 'Config-Version' }
        $out.Add("${key}: $($Version.ConfigVersion)")
    }
    $out.Add("Storage-User: $($Version.User)")
    $out -join "`n"
}
```

Додати всі три до `Export-ModuleMember`.

- [ ] **Step 5: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/StorageReport.psm1 tools/lib/StorageBranch.psm1 tools/tests/StorageReport.Tests.ps1 tools/tests/StorageBranch.Tests.ps1
git commit -m "B2: звіт сховища без -Extension; план реплею й повідомлення коміту з трейлерами"
```

---

### Task 3: worktree гілки дзеркала, коміт версії, злиття в головну гілку

Git-половина `sync`, повністю тестована без платформи.

**Встановлені факти (перевірено в цій сесії на git 2.53):** `git worktree add --orphan -b
storage/X <шлях>` створює worktree з ненародженою гілкою; коміт у ньому не рухає `HEAD` і не
чіпає робочу копію основного дерева; `git worktree add <шлях> storage/X` — для наявної;
`git merge --allow-unrelated-histories` зливає orphan у гілку з іншими файлами; хук
`pre-commit` спрацьовує і в linked worktree.

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` — `New-KitStorageWorktree`, `Remove-KitStorageWorktree`, `Clear-KitWorktreeSource`, `Write-KitStorageVersion`
- Create: `tools/lib/GitMerge.psm1` — `Test-KitBranchMergedInto`, `Merge-KitBranchInto`
- Modify: `tools/lib/module-order.txt` — `GitMerge` після `StorageBranch`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — `Add-KitFakeStorageCommit` отримує `-Content` і `-RemoveFiles`
- Modify: `tools/tests/StorageBranch.Tests.ps1` — Describe «worktree і коміт версії»
- Create: `tools/tests/GitMerge.Tests.ps1`

**Interfaces:**
- Consumes: `Assert-SafeWorkPath`, `Test-KitBranchExists`, `New-KitFinding`.
- Produces:
  - `New-KitStorageWorktree -RepoRoot -Branch -Path` → `{Path; Branch; Created}`
  - `Remove-KitStorageWorktree -RepoRoot -Path`
  - `Clear-KitWorktreeSource -WorktreePath -RepoPath` → абсолютний шлях порожньої теки `<wt>/<RepoPath>` (сюди платформа дампить)
  - `Write-KitStorageVersion -WorktreePath -RepoPath -Message -AuthorName -AuthorEmail -Timestamp` → `{Sha; Empty}`
  - `Test-KitBranchMergedInto -RepoRoot -Branch -Into` → `bool`
  - `Merge-KitBranchInto -RepoRoot -Branch -Into -Message [-AllowUnrelated] [-WorkDir]` → `{Outcome:'merged'|'already'; Sha; Via:'in-place'|'worktree'|'none'}`

- [ ] **Step 1: Фікстура — розширити `Add-KitFakeStorageCommit`**

До `param` додати `[string]$Content` і `[string[]]$RemoveFiles = @()`; замінити рядок
`Set-Content … "вміст $FileName"` на:

```powershell
    if ($FileName) {
        $body = if ($PSBoundParameters.ContainsKey('Content')) { $Content } else { "вміст $FileName" }
        Set-Content -LiteralPath (Join-Path $dir $FileName) -Value $body -Encoding UTF8 -NoNewline
    }
    foreach ($rm in $RemoveFiles) { Remove-Item -LiteralPath (Join-Path $dir $rm) -Force -ErrorAction SilentlyContinue }
```

і зробити `$FileName` необов'язковим (`[string]$FileName = ''`).

- [ ] **Step 2: Тести, що падають — `StorageBranch.Tests.ps1`, новий Describe**

```powershell
Describe 'StorageBranch.psm1 — worktree гілки дзеркала й коміт версії (§3.3, шар 1)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Stamp = [datetime]'2026-01-22T17:51:21'
    }

    It 'перший sync: orphan-гілка через worktree; коміт не рухає HEAD і робочу копію основного дерева' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'first') -WithHooks
        $headBefore = git -C $repo rev-parse HEAD
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $wt.Created | Should -BeTrue
        (git -C $wt.Path symbolic-ref -q HEAD) | Should -Be 'refs/heads/storage/Alpha_SMB'

        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        $target | Should -Exist
        Set-Content -LiteralPath (Join-Path $target 'Configuration.xml') -Value '<x/>' -NoNewline
        Set-Content -LiteralPath (Join-Path $target 'ConfigDumpInfo.xml') -Value '<junk/>' -NoNewline
        Set-Content -LiteralPath (Join-Path $target 'DumpFilesIndex.txt') -Value 'junk' -NoNewline

        $r = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' `
            -Message "v17`n`nStorage-Source: Alpha_SMB`nStorage-Version: 17`nStorage-User: Абдулов" `
            -AuthorName 'PrudnikovV' -AuthorEmail 'p@example.invalid' -Timestamp $script:Stamp
        $r.Empty | Should -BeFalse
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path

        # Гілка є, трейлери й автор на місці, сміття платформи в дереві немає
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 17
        (git -C $repo log -1 --format='%an|%aI' storage/Alpha_SMB) | Should -BeLike 'PrudnikovV|2026-01-22T17:51:21*'
        @(git -C $repo ls-tree -r --name-only storage/Alpha_SMB) | Should -Be @('Alpha_SMB/cfe/src/Configuration.xml')

        # Основне дерево не зрушило
        (git -C $repo rev-parse HEAD) | Should -Be $headBefore
        (git -C $repo branch --show-current) | Should -Be 'main'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        (Join-Path $repo 'build/sync/Alpha_SMB/wt') | Should -Not -Exist
        @(git -C $repo worktree list).Count | Should -Be 1
    }

    It 'повторний sync: worktree на наявну гілку, Created=false; однаковий дамп дає Empty=true й порожній коміт' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'again') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'Configuration.xml' -Content '<x/>' `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $wt.Created | Should -BeFalse
        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        @(Get-ChildItem $target).Count | Should -Be 0
        Set-Content -LiteralPath (Join-Path $target 'Configuration.xml') -Value '<x/>' -NoNewline
        $r = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' `
            -Message "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2`nStorage-User: gitbot" `
            -AuthorName 'Test Bot' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp
        $r.Empty | Should -BeTrue
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 2
    }

    It 'байти платформи лягають у git як є, навіть під core.autocrlf=true і без .gitattributes у worktree' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bytes') -WithHooks
        git -C $repo config core.autocrlf true
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        # Змішані кінці рядків в одному файлі — саме так пише платформа (docs/text-policy.md)
        $mixed = [byte[]](0x3C,0x61,0x3E,0x0D,0x0A,0x74,0x0A,0x74,0x3C,0x2F,0x61,0x3E)
        [System.IO.File]::WriteAllBytes((Join-Path $target 'Form.xml'), $mixed)
        $rawId = (git -C $repo hash-object --no-filters (Join-Path $target 'Form.xml')).Trim()
        Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" `
            -AuthorName 'T' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp | Out-Null
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        (git -C $repo rev-parse 'storage/Alpha_SMB:Alpha_SMB/cfe/src/Form.xml').Trim() | Should -Be $rawId
    }

    It 'залишок перерваного прогону (тека worktree є) — прибирається, новий worktree створюється' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'leftover') -WithHooks
        $path = Join-Path $repo 'build/sync/Alpha_SMB/wt'
        New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path $path | Out-Null
        # «Перервано»: worktree лишився зареєстрованим і на диску
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path $path } | Should -Not -Throw
        Remove-KitStorageWorktree -RepoRoot $repo -Path $path
    }

    It 'гілка дзеркала вибрана в основній робочій копії — зупинка з поясненням' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'checkedout') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        git -C $repo checkout -q storage/Alpha_SMB
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt') } |
            Should -Throw '*storage/Alpha_SMB*вибрана*'
        git -C $repo checkout -q main
    }

    It 'шлях worktree поза build/sync — відмова (Assert-SafeWorkPath)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsafe')
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'Alpha_SMB') } | Should -Throw '*build*sync*'
    }
}
```

- [ ] **Step 3: Тест `tools/tests/GitMerge.Tests.ps1`, що падає** (спека §12, рядок «злиття §3.4»)

```powershell
#Requires -Version 7
Describe 'GitMerge.psm1 — злиття storage/X у головну гілку (§3.4, Q4)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        function script:New-RepoWithMirror {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore
            # main вже має свій вміст поза шляхом джерела: AUTHORS, маніфест, v8project.yaml, README
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'проєкт' -Encoding UTF8
            git -C $repo add -A; git -C $repo commit -q -m 'README'
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'b.xml' -Content 'B1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 2')
            $repo
        }
    }

    It 'перше злиття (unrelated): файли main лишаються, файли сховища додаються; далі — already' {
        $repo = New-RepoWithMirror 'first'
        Test-KitBranchMergedInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' | Should -BeFalse
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: перше злиття storage/Alpha_SMB у main' -AllowUnrelated
        $r.Outcome | Should -Be 'merged'
        $r.Via | Should -Be 'in-place'
        Join-Path $repo 'README.md' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/a.xml' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/b.xml' | Should -Exist
        Test-KitBranchMergedInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' | Should -BeTrue
        (Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x').Outcome | Should -Be 'already'
    }

    It 'друге злиття (тристороннє): зміна й видалення зі сховища дійшли, файли main поза шляхом цілі' {
        $repo = New-RepoWithMirror 'second'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs.md') -Value 'робота в main' -Encoding UTF8
        git -C $repo add -A; git -C $repo commit -q -m 'main рухається далі'

        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A2' -RemoveFiles @('b.xml') -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'verify: звірочний коміт'
        $r.Outcome | Should -Be 'merged'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Raw) | Should -Be 'A2'
        Join-Path $repo 'Alpha_SMB/cfe/src/b.xml' | Should -Not -Exist
        Join-Path $repo 'docs.md' | Should -Exist
        Join-Path $repo 'README.md' | Should -Exist
        # merge-коміт має рівно двох батьків, і жоден із них не в storage/* (main не став дзеркалом)
        @((git -C $repo log -1 --format=%P main) -split ' ').Count | Should -Be 2
    }

    It 'HEAD на гілці задачі F: злиття йде через тимчасовий worktree; F не зрушила; worktree прибрано' {
        $repo = New-RepoWithMirror 'via-wt'
        git -C $repo checkout -q -b feature/task
        $fHead = git -C $repo rev-parse HEAD
        $mainBefore = git -C $repo rev-parse main
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated
        $r.Via | Should -Be 'worktree'
        (git -C $repo rev-parse HEAD) | Should -Be $fHead
        (git -C $repo branch --show-current) | Should -Be 'feature/task'
        (git -C $repo rev-parse main) | Should -Not -Be $mainBefore
        (git -C $repo rev-parse main) | Should -Be $r.Sha
        Join-Path $repo 'build/sync/_main/wt' | Should -Not -Exist
        @(git -C $repo worktree list).Count | Should -Be 1
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'HEAD = main, робоча копія брудна — зупинка, main не зрушив' {
        $repo = New-RepoWithMirror 'dirty'
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'незакомічена правка'
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw '*не чиста*'
        (git -C $repo rev-parse main) | Should -Be $before
    }

    It 'конфлікт: main змінив той самий файл — зупинка, злиття відкочено, MERGE_HEAD немає' {
        $repo = New-RepoWithMirror 'conflict'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Value 'A-main' -NoNewline
        git -C $repo add -A; git -C $repo commit -q -m 'main править a.xml'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A-storage' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' } | Should -Throw '*конфлікт*git merge storage/Alpha_SMB*'
        (git -C $repo rev-parse main) | Should -Be $before
        git -C $repo rev-parse -q --verify MERGE_HEAD 2>$null | Should -BeNullOrEmpty
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'головної гілки ще немає — зупинка з підказкою' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-main')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'trunk' -Message 'x' -AllowUnrelated } | Should -Throw "*'trunk'*"
    }
}
```

- [ ] **Step 4: Запустити — червоно**

- [ ] **Step 5: `StorageBranch.psm1` — чотири функції** (додати `Import-Module "$PSScriptRoot/PathSafety.psm1"` угорі, без `-Force`)

```powershell
function New-KitStorageWorktree {
    <#
    .SYNOPSIS
        Worktree гілки дзеркала під build/sync: orphan, якщо гілки ще немає (§3.3, шар 1).
    .DESCRIPTION
        Робоча копія й поточна гілка людини не торкаються взагалі — тому запобіжник «чиста
        робоча копія перед -Apply» зі старого storage-sync.ps1 тут не потрібен. Залишок
        перерваного прогону (тека є, worktree зареєстрований) прибирається: у ньому немає
        нічого, чого не можна перевивантажити.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-SafeWorkPath -Path $Path -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'worktree гілки дзеркала'

    if (Test-Path -LiteralPath $Path) {
        git -C $RepoRoot worktree remove --force $Path 2>$null | Out-Null
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    }
    git -C $RepoRoot worktree prune 2>$null | Out-Null

    $exists = Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch
    if ($exists) {
        $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
        if ($current -eq $Branch) {
            throw "Гілка $Branch вибрана в основній робочій копії — перейдіть на іншу гілку (git checkout $(Split-Path -Leaf (git -C $RepoRoot symbolic-ref refs/remotes/origin/HEAD 2>$null) -ErrorAction SilentlyContinue)main) і повторіть."
        }
        $out = git -C $RepoRoot worktree add -q $Path $Branch 2>&1
    } else {
        $out = git -C $RepoRoot worktree add -q --orphan -b $Branch $Path 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "git worktree add для $Branch завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }

    [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Branch = $Branch; Created = (-not $exists) }
}
```

> Рядок із `symbolic-ref … origin/HEAD` у повідомленні спростити до сталого тексту
> `"перейдіть на головну гілку (git checkout <mainBranch>) і повторіть"` — викликач знає
> `mainBranch`, функція — ні; тримайте повідомлення без вгадувань:

```powershell
        if ($current -eq $Branch) {
            throw "Гілка $Branch вибрана в основній робочій копії — kit пише в неї лише через worktree. Перейдіть на головну гілку чи гілку задачі й повторіть."
        }
```

```powershell
function Remove-KitStorageWorktree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Path)
    $out = git -C $RepoRoot worktree remove --force $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git worktree remove $Path завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
    git -C $RepoRoot worktree prune 2>$null | Out-Null
}

function Clear-KitWorktreeSource {
    <#
    .SYNOPSIS
        Порожня тека <wt>/<RepoPath> під дамп версії: /DumpConfigToFiles не видаляє зниклих об'єктів.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorktreePath, [Parameter(Mandatory)][string]$RepoPath)
    $target = Join-Path $WorktreePath $RepoPath
    Assert-SafeWorkPath -Path $target -MustBeUnder $WorktreePath -Description 'тека джерела у worktree'
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    (Resolve-Path -LiteralPath $target).Path
}

function Write-KitStorageVersion {
    <#
    .SYNOPSIS
        Коміт уже вивантаженого дерева <wt>/<RepoPath> як однієї версії сховища.
    .DESCRIPTION
        У worktree гілки дзеркала немає .gitattributes (дерево — лише шлях джерела), тож git
        застосував би core.autocrlf машини. -c core.autocrlf=false тримає байти платформи як є —
        та сама гарантія, яку в main дає -text. ConfigDumpInfo.xml і DumpFilesIndex.txt —
        службові файли платформи, у дзеркалі їх немає (у споживача вони й так у .gitignore).
        V8KIT_SYNC=1 — дозвіл для хука B1, який спрацьовує і в linked worktree; дати автора й
        комітера — дата версії сховища. --allow-empty: сусідні версії можуть дати однаковий дамп,
        а коміт — єдиний носій автора, дати й коментаря версії.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$AuthorName,
        [Parameter(Mandatory)][string]$AuthorEmail,
        [Parameter(Mandatory)][datetime]$Timestamp
    )

    $target = Join-Path $WorktreePath $RepoPath
    foreach ($junk in 'ConfigDumpInfo.xml', 'DumpFilesIndex.txt') {
        $j = Join-Path $target $junk
        if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force }
    }

    $msgFile = Join-Path (Split-Path -Parent $WorktreePath) 'commit-message.txt'
    Set-Content -LiteralPath $msgFile -Value $Message -Encoding UTF8 -NoNewline

    $addOut = git -C $WorktreePath -c core.autocrlf=false -c core.safecrlf=false add -A -- $RepoPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git add у worktree завершився з кодом ${LASTEXITCODE}: $($addOut -join "`n")" }

    git -C $WorktreePath diff --cached --quiet -- $RepoPath
    $empty = ($LASTEXITCODE -eq 0)

    $stamp = $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
    $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp; $env:V8KIT_SYNC = '1'
    try {
        $out = git -C $WorktreePath -c core.autocrlf=false commit --author="$AuthorName <$AuthorEmail>" -F $msgFile --quiet --allow-empty 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git commit у worktree завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
    } finally {
        Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE, Env:V8KIT_SYNC -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Sha = (git -C $WorktreePath rev-parse HEAD).Trim(); Empty = $empty }
}
```

Додати всі чотири до `Export-ModuleMember`.

- [ ] **Step 6: `tools/lib/GitMerge.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/StorageBranch.psm1"

function Test-KitBranchMergedInto {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch, [Parameter(Mandatory)][string]$Into)
    git -C $RepoRoot merge-base --is-ancestor $Branch $Into 2>$null
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw "git merge-base --is-ancestor $Branch $Into завершився з кодом $LASTEXITCODE." }
    }
}

function Merge-KitBranchInto {
    <#
    .SYNOPSIS
        Зливає гілку дзеркала в головну (спека §3.4, рішення Q4).
    .DESCRIPTION
        Три випадки: HEAD = Into і чисто — на місці; HEAD = Into і брудно — зупинка (у брудний
        main не зливаємо); HEAD — інша гілка — тимчасовий worktree під build/sync/_main. Завжди
        --no-ff: main ніколи не є предком storage/X, але fast-forward тут перетворив би main
        на дзеркало, і краще, щоб git це навіть не розглядав. Конфлікт — abort і зупинка з
        командою для ручного розбору; стан гілки не змінюється.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Into,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllowUnrelated,
        [string]$WorkDir = (Join-Path $RepoRoot 'build/sync/_main/wt')
    )

    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Into)) {
        throw "Гілки '$Into' немає — нема куди зливати $Branch. Створіть перший коміт у головній гілці (скіл onboarding робить це першим)."
    }
    if (Test-KitBranchMergedInto -RepoRoot $RepoRoot -Branch $Branch -Into $Into) {
        return [pscustomobject]@{ Outcome = 'already'; Sha = (git -C $RepoRoot rev-parse $Into).Trim(); Via = 'none' }
    }

    $mergeArgs = @('merge', '--no-ff', '--no-edit', '-m', $Message)
    if ($AllowUnrelated) { $mergeArgs += '--allow-unrelated-histories' }
    $mergeArgs += $Branch

    $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
    if ($current -eq $Into) {
        $dirty = git -C $RepoRoot status --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git status завершився з кодом ${LASTEXITCODE}: $dirty" }
        if ($dirty) {
            throw ("Гілка '$Into' вибрана, але робоча копія не чиста — у брудний '$Into' не зливаємо. Закомітьте або сховайте " +
                   "зміни (git stash) і повторіть, або перейдіть на гілку задачі — тоді злиття піде через тимчасовий worktree.")
        }
        $out = git -C $RepoRoot @mergeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $RepoRoot merge --abort 2>$null | Out-Null
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        return [pscustomobject]@{ Outcome = 'merged'; Sha = (git -C $RepoRoot rev-parse $Into).Trim(); Via = 'in-place' }
    }

    Assert-SafeWorkPath -Path $WorkDir -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'worktree головної гілки'
    if (Test-Path -LiteralPath $WorkDir) {
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    }
    git -C $RepoRoot worktree prune 2>$null | Out-Null
    $add = git -C $RepoRoot worktree add -q $WorkDir $Into 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Не вдалося створити worktree для '$Into' (вибрана в іншому worktree?): $($add -join "`n")" }

    try {
        $out = git -C $WorkDir @mergeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $WorkDir merge --abort 2>$null | Out-Null
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        $sha = (git -C $WorkDir rev-parse HEAD).Trim()
    } finally {
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        git -C $RepoRoot worktree prune 2>$null | Out-Null
    }
    [pscustomobject]@{ Outcome = 'merged'; Sha = $sha; Via = 'worktree' }
}

Export-ModuleMember -Function Test-KitBranchMergedInto, Merge-KitBranchInto
```

У `tools/lib/module-order.txt` після `StorageBranch` додати рядок `GitMerge`. До
`$script:RequiredCommands` у Describe про kit.ps1 в `ModuleImportOrder.Tests.ps1` додати
`'Merge-KitBranchInto'`, `'New-KitStorageWorktree'`, `'Write-KitStorageVersion'`, `'Get-KitPendingVersions'`.

- [ ] **Step 7: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 8: Коміт**

```bash
git add tools/lib/StorageBranch.psm1 tools/lib/GitMerge.psm1 tools/lib/module-order.txt tools/tests/StorageBranch.Tests.ps1 tools/tests/GitMerge.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/fixtures/KitFixtures.psm1
git commit -m "B2: worktree гілки дзеркала, коміт версії з байтами платформи, злиття в головну гілку (Q4)"
```

---

### Task 4: команда `sync`

Оркестрація: для кожного джерела з `truth: storage` — тимчасова ІБ → звіт → план → прев'ю →
(з `-Apply`) реплей у worktree → перше злиття в головну гілку.

**Files:**
- Create: `tools/commands/sync.psm1`
- Create: `tools/tests/Sync.Tests.ps1` (штатні зупинки без платформи + `Integration`)

**Interfaces:**
- Consumes: усе з Task 2–3; `Select-KitSources`, `Read-AuthorMap`, `Resolve-Author`, `Get-UnknownAuthors`, `New-ExtensionInfobase`, `New-V8FileInfobase`, `Invoke-V8Designer`, `Get-StorageVersions`, `Assert-SafeWorkPath`; стаб `tools/assets/empty-extension`.
- Produces: `Invoke-KitSync -Context [-Workspace] [-Source] [-Apply] [-MaxVersions <int>] [-MergeMain]` → `{ExitCode (0 — ок; 2 — дзеркало оновлено, злиття в головну гілку не виконано); Synced}`; CLI `kit.ps1 sync …`.

- [ ] **Step 1: Тест `tools/tests/Sync.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit sync — штатні зупинки до звернення до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'немає джерел truth: storage — код 0 і пояснення, платформа не потрібна' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-storage') -Workspaces $ws -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It 'каталог сховища недоступний — зупинка з його шляхом ДО створення build/sync/<ключ> і без гілки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-dir') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*no-such-storage-Alpha_SMB*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'AUTHORS відсутній — зупинка до платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-authors') -WithHooks
        Remove-Item -LiteralPath (Join-Path $repo 'AUTHORS')
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*AUTHORS*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It '-Source невідомий — зупинка з переліком' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-source') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Source', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*"
    }

    It 'джерело truth: storage на EXTERNAL_DATA_PROCESSORS — зупинка (сховища для обробок не буває)' {
        $text = @('version: 1', 'product: Fake', 'workspaces:', '  - path: epf', '    sources:', "      tools: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-proc') -Workspaces $ws -ManifestText $text -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }
}

Describe 'kit sync — реальне сховище (перший і повторний реплей)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'   # живе сховище розширення; лише читання
        $script:Authors = 'R:\github\SMP_BankExchange\AUTHORS'

        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Невідомих авторів (нові користувачі сховища після останнього оновлення AUTHORS) — у тестову мапу.
        function script:Complete-Authors {
            param([string]$Repo, [string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") {
                    Add-Content -LiteralPath (Join-Path $Repo 'AUTHORS') -Encoding UTF8 -Value "$($Matches.u)=Test Author <test@example.invalid>"
                    $added = $true
                }
            }
            $added
        }

        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item -LiteralPath $script:Authors -Destination (Join-Path $script:Repo 'AUTHORS') -Force
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS з живого репо'
    }

    It 'сховище доступне (передумова)' {
        $script:Storage | Should -Exist
    }

    It 'прев’ю без -Apply нічого не міняє в git' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        if (Complete-Authors -Repo $script:Repo -Output $r.Output) {
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*попередній перегляд*'
        (git -C $script:Repo branch --list 'storage/*') | Should -BeNullOrEmpty
    }

    It 'перший реплей: дві версії в storage/X, трейлери, перше злиття в main, дерево під шляхом джерела' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '2')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $commits = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB')
        $commits.Count | Should -Be 2
        $commits[0].Parents.Count | Should -Be 0
        $commits[1].Trailers['Storage-Source'] | Should -Be 'SMP_BankExchange_SMB'
        [int]$commits[1].Trailers['Storage-Version'] | Should -BeGreaterThan ([int]$commits[0].Trailers['Storage-Version'])
        @(git -C $script:Repo ls-tree -r --name-only storage/SMP_BankExchange_SMB | Where-Object { $_ -notlike 'SMP_BankExchange_SMB/cfe/src/*' }).Count | Should -Be 0
        (git -C $script:Repo merge-base --is-ancestor storage/SMP_BankExchange_SMB main; $LASTEXITCODE) | Should -Be 0
        Join-Path $script:Repo 'SMP_BankExchange_SMB/cfe/src/Configuration.xml' | Should -Exist
        Join-Path $script:Repo 'build/sync/SMP_BankExchange_SMB/wt' | Should -Not -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'повторний реплей: ще одна версія, main не чіпається (звірочний коміт — verify, B3)' {
        $mainBefore = git -C $script:Repo rev-parse main
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '1')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB').Count | Should -Be 3
        (git -C $script:Repo rev-parse main) | Should -Be $mainBefore
    }

    It 'kit check після реплею — без помилок' {
        $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $script:Repo 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'kit sync — сховище КОНФІГУРАЦІЇ (без -Extension)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Найменше живе сховище конфігурації — те саме, що у спайку Task 1 (підставити ім'я).
        $script:CfgStorage = 'R:\СховищаКонфігурацій_1С\<НАЙМЕНШЕ ЗІ СПАЙКУ>'
        $ws = [ordered]@{ 'Client_UNF' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
        $manifest = @('version: 1', 'client: Client', 'workspaces:', '  - path: Client_UNF', '    sources:',
            '      base:', '        truth: storage', "        storage: { path: '$script:CfgStorage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cfg') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes
        # cf/src під truth: storage НЕ гітігнорований — шаблон gitignore для клієнтського репо B5 це врахує; тут .gitignore не кладемо.
    }

    It 'перша версія конфігурації лягає в storage/base з Config-Version і деревом під Client_UNF/cf/src' {
        $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        if ($r -match "=Ім'я <пошта>") {
            foreach ($line in ($r -split "`r?`n")) { if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8 } }
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        }
        $LASTEXITCODE | Should -Be 0 -Because $r
        $c = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/base')
        $c.Count | Should -Be 1
        $c[0].Trailers.Contains('Extension-Version') | Should -BeFalse
        Join-Path $script:Repo 'Client_UNF/cf/src/Configuration.xml' | Should -Exist
    }
}
```

- [ ] **Step 2: Запустити без Integration — червоно (команди `sync` немає)**

- [ ] **Step 3: Реалізація `tools/commands/sync.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Lib-модулі вже імпортував kit.ps1 (module-order.txt); тут — лише оркестрація.

# Спайк Task 1 (спека §14, «Результат спайку»): чи потребує UpdateCfg для ОСНОВНОЇ конфігурації
# прив'язки ІБ до сховища. $false — шлях (1) працює без прив'язки; $true — kit робить
# ConfigurationRepositoryBindCfg під користувачем сховища на час реплею й знімає її
# ConfigurationRepositoryUnbindCfg -force у finally — єдиний запис у сховище, який kit виконує.
$script:ConfigurationStorageNeedsBind = $false

function Get-UkrainianPluralForm {
    param([Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][string]$One, [Parameter(Mandatory)][string]$Few, [Parameter(Mandatory)][string]$Many)
    $mod100 = $Count % 100
    if ($mod100 -ge 11 -and $mod100 -le 14) { return $Many }
    switch ($Count % 10) { 1 { return $One } { $_ -ge 2 -and $_ -le 4 } { return $Few } default { return $Many } }
}

function Get-KitRepositoryArguments {
    param([Parameter(Mandatory)]$Source)
    , @(
        '/ConfigurationRepositoryF "{0}"' -f $Source.StoragePath
        '/ConfigurationRepositoryN "{0}"' -f $Source.StorageUser
        '/ConfigurationRepositoryP ""'
    )
}

function Invoke-KitMainMerge {
    <#
    .SYNOPSIS
        Перше злиття дзеркала в головну гілку (§3.4). Невдача злиття не скасовує реплею:
        дзеркало вже оновлено, і людина може повторити злиття командою з підказки.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Source)
    $main = $Context.MainBranch
    if (-not (Test-KitBranchExists -RepoRoot $Context.RepoRoot -Branch $main)) {
        Write-Host "  Головної гілки '$main' ще немає — злиття пропущено. Створіть перший коміт і повторіть: kit sync -Source $($Source.Key) -MergeMain" -ForegroundColor Yellow
        return $false
    }
    try {
        $r = Merge-KitBranchInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $main `
            -Message "sync: злиття $($Source.Branch) у $main" -AllowUnrelated
        if ($r.Outcome -eq 'merged') { Write-Host "  Злито в $main ($($r.Via)): $($r.Sha.Substring(0, 7))" -ForegroundColor Green }
        else { Write-Host "  $main уже містить $($Source.Branch)." -ForegroundColor DarkGray }
        return $true
    } catch {
        Write-Host "  Злиття в $main не виконано: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Дзеркало оновлено. Повторити злиття: kit sync -Source $($Source.Key) -MergeMain" -ForegroundColor Yellow
        return $false
    }
}

function Invoke-KitSync {
    <#
    .SYNOPSIS
        Реплей нових версій кожного джерела truth: storage у гілку storage/<ключ> (спека §3, §5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [int]$MaxVersions = 0,
        [switch]$MergeMain
    )

    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — синхронізувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Synced = @() }
    }
    foreach ($src in $sources) {
        if ($src.Type -notin @('CONFIGURATION', 'EXTENSION')) {
            throw "Джерело '$($src.Key)' має тип $($src.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION."
        }
    }

    $authors  = Read-AuthorMap -Path (Join-Path $root 'AUTHORS')
    $stubPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/empty-extension'))
    $results  = [System.Collections.Generic.List[object]]::new()
    $mergeFailed = $false

    foreach ($src in $sources) {
        Write-Host ''
        Write-Host "Джерело:    $($src.Workspace)/$($src.Key) ($($src.Type))"
        Write-Host "Сховище:    $($src.StoragePath) (користувач $($src.StorageUser))"
        Write-Host "Гілка:      $($src.Branch)"
        if (-not (Test-Path -LiteralPath $src.StoragePath)) {
            throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)."
        }

        $last = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $src.Branch
        Write-Host ('Дзеркало:   ' + $(if ($null -eq $last) { 'гілки ще немає — реплей усіх версій зі звіту' } else { "версія $last" }))

        # Робоча тека джерела — з нуля на кожен запуск. Worktree від перерваного прогону спершу знімаємо з реєстрації.
        $workDir = Join-Path $root 'build/sync' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/sync') -Description "робоча тека джерела $($src.Key)"
        git -C $root worktree remove --force (Join-Path $workDir 'wt') 2>$null | Out-Null
        git -C $root worktree prune 2>$null | Out-Null
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        Write-Host 'Створюю тимчасову ІБ і читаю історію сховища...'
        $extName = ''
        if ($src.Type -eq 'EXTENSION') {
            $extName  = $src.Key
            $ibSwitch = New-ExtensionInfobase -Path (Join-Path $workDir 'ib') -ExtensionName $extName -StubPath $stubPath -MustBeUnder $workDir
        } else {
            $ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $workDir 'ib') -MustBeUnder $workDir)
        }
        $extArg = if ($extName) { " -Extension $extName" } else { '' }

        $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath -ExtensionName $extName -StorageUser $src.StorageUser -WorkDir $workDir
        $maxVersion = if ($all.Count -gt 0) { ($all | Measure-Object -Property Version -Maximum).Maximum } else { 'немає' }
        Write-Host "У сховищі версій: $($all.Count), максимальна: $maxVersion"

        $pending = Get-KitPendingVersions -AllVersions $all -LastVersion $last -MaxVersions $MaxVersions
        $gap = Get-KitVersionGapNote -Pending $pending -LastVersion $last
        if ($gap) { Write-Host "  $gap" -ForegroundColor DarkGray }

        if ($pending.Count -eq 0) {
            Write-Host 'Нових версій немає — дзеркало синхронне зі сховищем.'
            $merged = $false
            if ($MergeMain -and $Apply -and $null -ne $last) { $merged = Invoke-KitMainMerge -Context $Context -Source $src; if (-not $merged) { $mergeFailed = $true } }
            $results.Add([pscustomobject]@{ Key = $src.Key; Versions = @(); Branch = $src.Branch; MergedIntoMain = $merged })
            continue
        }

        $unknown = Get-UnknownAuthors -Map $authors -StorageUsers ($pending.User)
        if ($unknown) {
            Write-Host ''
            Write-Host 'Невідомі автори — додайте їх у AUTHORS перед прогоном:' -ForegroundColor Yellow
            $unknown | ForEach-Object { Write-Host "  $_=Ім'я <пошта>" }
            throw 'Синхронізацію зупинено через невідомих авторів.'
        }

        Write-Host ''
        Write-Host "До перенесення версій: $($pending.Count)"
        foreach ($v in $pending) {
            $author = Resolve-Author -Map $authors -StorageUser $v.User
            $first  = ($v.Comment -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $first) { $first = "Версія сховища $($v.Version)" }
            Write-Host ("  v{0,-4} {1:yyyy-MM-dd HH:mm}  {2,-22} {3}" -f $v.Version, $v.Timestamp, $author.Name, $first)
        }

        if (-not $Apply) {
            Write-Host ''
            Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            continue
        }

        $wt   = New-KitStorageWorktree -RepoRoot $root -Branch $src.Branch -Path (Join-Path $workDir 'wt')
        $done = [System.Collections.Generic.List[int]]::new()
        $bound = $false
        try {
            if ($src.Type -eq 'CONFIGURATION' -and $script:ConfigurationStorageNeedsBind) {
                # Документований виняток із «сховища — тільки читання» (спека §14): прив'язка під gitbot,
                # знімається у finally нижче незалежно від результату реплею.
                $bind = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
                if ($bind.ExitCode -ne 0) { throw "Прив'язка тимчасової ІБ до сховища конфігурації не вдалася: $($bind.Output)" }
                $bound = $true
            }

            foreach ($v in $pending) {
                $author = Resolve-Author -Map $authors -StorageUser $v.User
                Write-Host "→ версія $($v.Version) ($($author.Name), $($v.Date))"

                $upd = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @(
                    ('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $v.Version, $extArg)))
                if ($upd.ExitCode -ne 0) { throw "Оновлення до версії $($v.Version) не вдалося: $($upd.Output)" }

                $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath $src.RepoPath
                $dump = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $target, $extArg))
                if ($dump.ExitCode -ne 0) { throw "Вивантаження версії $($v.Version) не вдалося: $($dump.Output)" }

                $message = New-KitStorageCommitMessage -Version $v -SourceKey $src.Key -SourceType $src.Type
                $commit  = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath $src.RepoPath -Message $message `
                    -AuthorName $author.Name -AuthorEmail $author.Email -Timestamp $v.Timestamp
                if ($commit.Empty) { Write-Host '  (без змін у джерелах — коміт лише фіксує запис версії сховища)' -ForegroundColor DarkGray }
                $done.Add($v.Version)
            }
        } finally {
            if ($bound) {
                $unbind = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @('/ConfigurationRepositoryUnbindCfg -force'))
                if ($unbind.ExitCode -ne 0) { Write-Host "УВАГА: не вдалося зняти прив'язку тимчасової ІБ до сховища: $($unbind.Output)" -ForegroundColor Red }
            }
            Remove-KitStorageWorktree -RepoRoot $root -Path $wt.Path
        }
        Write-Host ("Перенесено версій: {0} → {1}" -f $done.Count, $src.Branch) -ForegroundColor Green

        $merged = $false
        if ($wt.Created -or $MergeMain) {
            $merged = Invoke-KitMainMerge -Context $Context -Source $src
            if (-not $merged) { $mergeFailed = $true }
        }
        $results.Add([pscustomobject]@{ Key = $src.Key; Versions = $done.ToArray(); Branch = $src.Branch; MergedIntoMain = $merged })
    }

    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    [pscustomobject]@{ ExitCode = $(if ($mergeFailed) { 2 } else { 0 }); Synced = $results.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSync
```

Якщо спайк Task 1 дав шлях (2) — виставити `$script:ConfigurationStorageNeedsBind = $true` і
в коментарі над ним процитувати текст відмови платформи зі спайку. Якщо шлях (1) — лишити
`$false`; гілка з `BindCfg` залишається в коді як документований запасний шлях.

- [ ] **Step 4: Тести без платформи зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 5: Integration — за підтвердженням користувача** (читає живі сховища, запускає платформу)

У `Sync.Tests.ps1` підставити ім'я найменшого сховища конфігурації зі спайку, потім:

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1
```

Очікувано: обидва `Integration`-Describe зелені. Якщо `Невідомі автори` спрацьовує і після
автодоповнення AUTHORS — це збій регексу у `Complete-Authors`, а не сховища: звірити формат
рядка з виводом `Invoke-KitSync`.

- [ ] **Step 6: Коміт**

```bash
git add tools/commands/sync.psm1 tools/tests/Sync.Tests.ps1
git commit -m "B2: kit sync — реплей у storage/* через worktree, сховища конфігурацій, перше злиття в головну гілку"
```

---

### Task 5: вилучення `storage.json`-конвенції, `SyncState`, старого скрипта; перехідні позначки

`sync` працює — старий шлях більше не має права існувати поруч: два механізми стану
(`storage.json` і трейлери) розійшлися б за перший же тиждень.

**Files:**
- Delete: `tools/storage-sync.ps1`, `tools/lib/SyncState.psm1`, `tools/tests/StorageSync.Tests.ps1`, `tools/tests/SyncState.Tests.ps1`, `templates/storage.json.example`
- Modify: `tools/lib/V8.psm1` — вилучити `Read-V8LocalStoragePath` (і з `Export-ModuleMember`); `tools/tests/V8.Tests.ps1` — вилучити її тести
- Modify: `tools/build.ps1` — без `SyncState`, без гілки `.cfe`; `tools/tests/Build.Tests.ps1` — під нову поведінку
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` — вилучити Describe про `storage-sync.ps1`; `tools/tests/fixtures/module-visibility-probe.ps1` — шапка
- Modify: `templates/README.md` — без рядка `storage.json.example`
- Modify: `skills/storage-pipeline/SKILL.md`, `templates/CLAUDE.md`, `CLAUDE.md` — перехідна позначка
- Modify: `docs/follow-ups.md` — §4, §14

- [ ] **Step 1: Вилучити файли**

```bash
git rm -q tools/storage-sync.ps1 tools/lib/SyncState.psm1 tools/tests/StorageSync.Tests.ps1 tools/tests/SyncState.Tests.ps1 templates/storage.json.example
```

- [ ] **Step 2: `V8.psm1` — прибрати `Read-V8LocalStoragePath`**

Видалити функцію цілком (рядки 121–151) і її ім'я з `Export-ModuleMember`. У `V8.Tests.ps1`
видалити Describe/It, що згадують `Read-V8LocalStoragePath` (`Select-String -Pattern
'Read-V8LocalStoragePath' tools/tests/V8.Tests.ps1` покаже, які). Перевизначення шляху
сховища тепер — `storages:` у `v8storagekit.local.yaml` (B1, префлайт).

- [ ] **Step 3: `build.ps1` — лише `.epf`** (повна заміна на `kit build` — B4)

Замінити блок від `Import-Module (Join-Path $PSScriptRoot 'lib/SyncState.psm1') -Force` до кінця файлу на:

```powershell
$outDir  = Join-Path $repoRoot 'build/artifacts'
$buildIb = Join-Path $repoRoot 'build/build-ib'

# Перехідний стан (B2 → B4): збірка .cfe вилучена — це operation=make Уніки (спека §5), а
# storage.json, за яким цей скрипт знаходив розширення, більше не існує. Лишається .epf.
if ($Product -and $Product -ne 'epf') {
    throw "build.ps1 збирає лише .epf (тека epf/src). Збірка .cfe — operation=make Unica у базі агента; збирання артефактів — kit build (B4)."
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'epf/src'))) {
    throw "У $repoRoot немає epf/src — зовнішніх обробок для збірки не знайдено."
}

Write-Host 'Збирати: epf'
Write-Host "Куди:    $outDir"
if (-not $Apply) {
    Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
    return
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path $buildIb -MustBeUnder (Join-Path $repoRoot 'build'))
foreach ($desc in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'epf/src') -Filter '*.xml' -File) {
    $name   = [System.IO.Path]::GetFileNameWithoutExtension($desc.Name)
    $target = Join-Path $outDir "$name.epf"
    Write-Host "→ $name.epf"
    $r = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
        '/LoadExternalDataProcessorOrReportFromFiles "{0}" "{1}"' -f $desc.FullName, $target)
    if ($r.ExitCode -ne 0) { throw "Збірка $name не вдалася: $($r.Output)" }
}
Get-ChildItem -LiteralPath $outDir | Select-Object Name, Length | Format-Table
Write-Host 'Готово.' -ForegroundColor Green
```

Шапку `.SYNOPSIS/.DESCRIPTION` скоротити до «Збирає .epf обробок з epf/src у build/artifacts.
Перехідний скрипт до появи kit build (B4); .cfe збирає operation=make Unica». Прибрати
`$stubPath`.

`Build.Tests.ps1` переписати на три It: «без epf/src — зупинка з `epf/src` у тексті»;
«з epf/src прев'ю показує `epf` і `build/artifacts` і завершується 0»; «`-Product Other` —
зупинка з `operation=make`». Тести зі `storage.json` вилучити.

- [ ] **Step 4: `ModuleImportOrder.Tests.ps1` і probe**

Вилучити перший Describe («Порядок імпорту модулів у storage-sync.ps1») цілком; лишається
Describe про `kit.ps1`. У шапці `module-visibility-probe.ps1` прибрати згадку `storage-sync.ps1`.

- [ ] **Step 5: Перехідні позначки в документах, які переписує B5/B8**

`skills/storage-pipeline/SKILL.md` — одразу після frontmatter:

```markdown
> **Перехідний стан (B2, до переписування скілів у B5):** `storage-sync.ps1` вилучено. Нові
> версії сховища переносить `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" sync -RepoRoot .`
> (прев'ю) і те саме з `-Apply`. Репозиторій має бути описаний маніфестом `v8storagekit.yaml`
> (див. `${CLAUDE_PLUGIN_ROOT}/templates/v8storagekit.yaml.example`); `storage.json` більше
> не читається. Розділи 1, 2, 4 і 5 нижче описують СТАРИЙ механізм і чинні лише для
> `dump-config`, `load-ext` і `build`.
```

`templates/CLAUDE.md`, таблиця «Типові операції»: два рядки про `storage-sync` замінити на
один — «перенеси нові версії сховища в git» → `kit.ps1 sync -Apply` — по коміту на версію в
гілку `storage/<джерело>`; прев'ю без `-Apply`». Абзац про `storage.json` у «Структура»
замінити на «`v8storagekit.yaml` у корені (маніфест kit)».

`CLAUDE.md` kit, таблиця «Структура», рядок `tools/`: «Диспетчер `kit.ps1` з командами в
`commands/` (`check`, `sync`), модулі `lib/*.psm1`, Pester-тести `tests/`; перехідні скрипти
`dump-config`, `load-ext`, `build` — до B3/B4».

`templates/README.md` — вилучити рядок `storage.json.example`.

- [ ] **Step 6: `docs/follow-ups.md`**

§4 — доповнити абзацем: «**Оновлено в B2:** `StorageSync.Tests.ps1` вилучено разом зі
скриптом; зразком форми тесту тепер служать `tools/tests/Check.Tests.ps1`, `Sync.Tests.ps1`
(підпроцес `kit.ps1` на синтетичному репозиторії з `New-KitFakeRepo`) і `GitMerge.Tests.ps1`».
§14 — доповнити: «**B2:** канонічність тепер перевіряє окрема команда `verify` (B3) — проти
дампу зі сховища, не власної робочої копії».

- [ ] **Step 7: Повний прогін без платформи, перевірки цілісності**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
grep -rn 'storage.json\|SyncState\|storage-sync' tools/ templates/ | grep -v 'tools/tests/fixtures/storage-report' 
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
```

Перший `grep` має показати лише коментарі, що прямо кажуть «вилучено/більше не читається»
(у `build.ps1`, `StorageBranch.psm1`); другий — порожньо.

- [ ] **Step 8: Коміт**

```bash
git add -A tools templates skills/storage-pipeline/SKILL.md CLAUDE.md docs/follow-ups.md
git commit -m "B2: вилучено storage.json-конвенцію, SyncState і storage-sync.ps1; build.ps1 лише .epf; перехідні позначки"
```

---

### Task 6: контрольний прогін на живому репозиторії (лише читання)

- [ ] **Step 1:** `kit check` на `R:\github\SMP_BankExchange` — очікувано код 1, «маніфест не знайдено … onboarding»; `git -C R:\github\SMP_BankExchange status --porcelain` порожній.
- [ ] **Step 2:** `kit sync` на синтетичному репозиторії з фікстури `Sync.Tests.ps1` (Integration) — уже пройшов у Task 4 Step 5; повторно не запускати.
- [ ] **Step 3:** Переконатись, що `git log --oneline main..feature/agent-contour` містить коміти всіх шести задач і робоча копія чиста.

---

## Self-review

**Покриття спеки для B2 (§14, рядок B2 + §12):**

| Вимога | Задача |
|---|---|
| спайк сховища конфігурації першим; `BindCfg`+`UnbindCfg` як документований виняток | 1, 4 |
| orphan-гілки через worktree; робоча копія й `HEAD` не торкаються (§3.3, шар 1) | 3 |
| трейлери `Storage-Source/Storage-Version/Extension-Version|Config-Version/Storage-User` (§3.1) | 2 |
| стан із git: остання версія з трейлера; перелік, не діапазон; порожня гілка → усе (§3.2) | 2 (+B1 Task 5) |
| перше злиття в головну гілку `--allow-unrelated-histories`; три випадки Q4 (§3.4) | 3, 4 |
| сховища конфігурацій без `-Extension` | 1, 2, 4 |
| кілька джерел на воркспейс — цикл по `Select-KitSources -Truth storage` | 4 |
| `V8KIT_SYNC=1` лише на час коміту (§3.3, шар 2) | 3 |
| байти платформи в git без конверсії (принцип 6) | 3 |
| вилучення `storage.json`, `SyncState.psm1`, `storage-sync.ps1` | 5 |
| тести §12: «стан із git», «злиття §3.4», «worktree §3.3»; Integration «sync на реальному сховищі (перший і повторний)» | 2, 3, 4 |

**Свідомо не в B2:** `-text`-перевірка дерева, куди зливається `storage/*` — це `check`
(B1); звірочні коміти після першого злиття — `verify -Apply` (B3); злиття в `F` — скіл
`reconcile` (B5); `kit build` і вилучення `build.ps1`/`load-ext.ps1` — B4.

**Узгодженість імен:** `Get-KitPendingVersions`, `Get-KitVersionGapNote`,
`New-KitStorageCommitMessage`, `New-KitStorageWorktree`, `Remove-KitStorageWorktree`,
`Clear-KitWorktreeSource`, `Write-KitStorageVersion`, `Test-KitBranchMergedInto`,
`Merge-KitBranchInto`, `Get-StorageReportArguments`, `Invoke-KitSync`, `Invoke-KitMainMerge`,
`Get-KitRepositoryArguments` — однакові в контрактах, коді й тестах. Поля результату
`Merge-KitBranchInto` (`Outcome`, `Sha`, `Via`) і `Write-KitStorageVersion` (`Sha`, `Empty`) —
однакові в Task 3 і Task 4.
