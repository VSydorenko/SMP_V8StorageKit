# Перейменування регістром і незалежність від налаштувань git — план реалізації (1.4.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** перейменування об'єкта 1С лише регістром кириличної літери проходить `sync` → злиття →
`adopt` → `verify` без фантомних дублікатів і без ручного втручання; дефект, якщо з'явиться, не
проходить ні `check`, ні `verify`, ні pre-commit; результат не залежить від `core.ignorecase`,
`core.autocrlf`, `core.safecrlf` машини.

**Architecture:** новий модуль `CaseGuard.psm1` дає спільні примітиви (перелік шляхів ref через
`ls-tree -z`, групування шляхів за юнікодним регістром, інваріант «індекс піддерева ≡ диск»). Коміт
дзеркала й `adopt` перед `add -A` знімають індекс піддерева (`rm --cached`) і перевіряють інваріант до
коміту. `Merge-KitBranchInto` зливає без робочої копії (`merge-tree` → `commit-tree` → `update-ref`, на
місці — `read-tree --reset -u`). `verify` бачить групи регістру з переліку git і має запобіжник
лічильника. `check`, хук pre-commit і `check-environment` — запобіжники.

**Tech Stack:** PowerShell 7, Pester 5, git ≥ 2.38 (на машині — 2.53.0.windows.1), `perl` з Git for
Windows (лише хук). Платформа 1С у тестах не потрібна.

**Spec:** `docs/superpowers/specs/2026-10-04-case-renames-and-git-settings-design.md`, редакція коміту
**`de9e86d`** (доповнення при плануванні: `commit --only`, мінімум git, вартість хука). Автор спеки й
плану — сесія `smp-v8storagekit-c7`; власник рішень — людина.

## Global Constraints

- **Проєктні константи брифа** — `.claude/skills/kit-dev/references/subagent-brief.md` (мова, форма
  прогону, заборони git, звіт, рев'ю). Бриф субагента дає цей файл шляхом, не переказом.
- **Коміти робить контролер** (оркеструвальна сесія) з дозволу людини: класифікатор блокує
  `git commit` із субагента. Виконавець стейджить явним переліком і готує файл повідомлення; крок
  «Коміт» нижче виконує контролер. Повідомлення закінчується рядком
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Прогін — завжди повний: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`;
  повні прогони в спільному дереві — послідовно (раннер стирає `build/test-run`). `-Only` — лише для
  відладки.
- **Протокол «контроль уміє впасти»** (kit-dev, case 7): мутацію production-коду робити лише на копії
  дерева — `Copy-Item tools <scratch>/tools -Recurse`, правка в копії, прогін
  `pwsh -NoProfile -File <scratch>/tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only <Файл>`.
  У робочому дереві production не мутувати.
- **Перевірка на фразу виводу** (kit-dev, case 22): перед `Should -BeLike '*фраза*'` — `grep` фрази
  по `tools/commands/` і `tools/lib/` (і `templates/githooks/` для хука): вона мусить траплятись лише в
  гілці, яку тест перевіряє.
- git ≥ **2.38.0** (спека §4.4): `merge-tree --write-tree --name-only -z --allow-unrelated-histories`.
- Юнікодне складання регістру — `[System.StringComparer]::OrdinalIgnoreCase`; ніде не `tr`, не
  ASCII-нижній регістр, не голий конвеєр git (спека §4.4).
- Вивід git із шляхами — через `Invoke-KitGitProcess` (`tools/lib/TreeCompare.psm1`, UTF-8) з `-z` і
  `-c core.quotepath=false`.
- Ремонту дзеркал немає й не додається (спека §3).
- Версія плагіна — **1.4.0** (`.claude-plugin/plugin.json`), піднімається в задачі 9.

## Review Focus

1. **Тека джерела з ігнорованим файлом, якого немає в `Test-KitComparableRelativePath`** (наприклад,
   локальний `*.bak` під `cf/src`, ігнорований `.gitignore`): інваріант «індекс ≡ диск» в `adopt`
   мусить не впасти хибно на файлі, який git ігнорує. Тест — задача 3, крок «ігнорований файл».
2. **`<Into>` вибрана в linked worktree** (не в основній копії): kit не має пересувати гілку під
   чужою робочою копією. Тест — задача 4.
3. **Злиття, де дзеркало приносить файл, що вже лежить у робочій копії як невідстежуваний**:
   `read-tree --reset -u` перезаписав би його мовчки; вимога чистої копії мусить зупинити раніше.
   Тест — задача 4 (невідстежуваний файл = брудна копія).
4. **Перелік шляхів ref порожній або з одним шляхом** (джерело без файлів, свіжа гілка): спільні
   функції не падають під StrictMode і повертають порожні колекції. Тест — задача 1.
5. **Повторний `verify` після `-Apply` на дереві з групами регістру**: вердикт не `equal` і код 3,
   навіть коли решта розбіжностей нульова. Тест — задача 5.

---

## Файлова структура

| Файл | Відповідальність |
|---|---|
| `tools/lib/CaseGuard.psm1` (новий) | `Get-KitTreePaths`, `Get-KitCaseCollisions`, `Assert-KitIndexMatchesDisk` |
| `tools/lib/TreeCompare.psm1` | `Test-KitComparableRelativePath` (одне джерело фільтра службових і поставки); `Compare-KitTrees -CaseCollisions -ClassifyCase` |
| `tools/lib/module-order.txt` | `CaseGuard` після `TreeCompare` |
| `tools/lib/StorageBranch.psm1` | `rm --cached` + інваріант у `Write-KitStorageVersion`; групи регістру й `Get-KitTreePaths` у `Test-KitStorageBranchInvariants` |
| `tools/commands/adopt.psm1` | `-text` до руйнівного кроку; `rm --cached`; `-c` EOL; коміт без `--only`; інваріант |
| `tools/lib/GitMerge.psm1` | `Merge-KitBranchInto` без робочої копії |
| `tools/commands/verify.psm1` | групи регістру, запобіжник лічильника, вивід і вердикт |
| `tools/commands/check.psm1` | групи регістру в `HEAD` під шляхом джерела |
| `tools/lib/Environment.psm1`, `tools/check-environment.ps1` | git ≥ 2.38 |
| `templates/githooks/pre-commit` | блок регістру через `perl` |
| `tools/tests/fixtures/KitFixtures.psm1` | `Set-KitFakeBranchTree` — коміт довільного дерева без робочої копії |
| тести | `CaseGuard.Tests.ps1` (новий), `StorageBranch.Tests.ps1`, `Adopt.Tests.ps1`, `GitMerge.Tests.ps1`, `TreeCompare.Tests.ps1`, `Verify.Tests.ps1`, `Check.Storage.Tests.ps1`, `Hooks.Tests.ps1`, `Environment.Tests.ps1`, `ModuleImportOrder.Tests.ps1`, `KitFixtures.Tests.ps1` |
| документи | `docs/storage-and-git.md`, `docs/text-policy.md`, `docs/follow-ups.md`, `skills/{sync,reconcile,finish,dump,verify}/SKILL.md` |

## Порядок і рівні ризику

| Задача | Залежить від | Ризик (kit-dev) |
|---|---|---|
| 1. CaseGuard + фікстура | — | спільний код |
| 2. Коміт дзеркала | 1 | властивість безпеки |
| 3. adopt | 1 | властивість безпеки |
| 4. Злиття | 1 (фікстура) | властивість безпеки |
| 5. verify | 1 | спільний код |
| 6. check | 1 | спільний код |
| 7. Хук pre-commit | — | спільний код (роздається споживачам) |
| 8. Версія git | — | механічна |
| 9. Документи, скіли, версія | 2–8 | механічна |
| 10. Рев'ю контуру й пілот | 1–9 | — (контролер) |

---

### Task 1: Спільні примітиви регістру й фікстура довільного дерева

**Files:**
- Create: `tools/lib/CaseGuard.psm1`
- Modify: `tools/lib/TreeCompare.psm1` (функція `Get-KitRelativeFiles`, `Export-ModuleMember`)
- Modify: `tools/lib/module-order.txt`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` (нова `Set-KitFakeBranchTree`, `Export-ModuleMember`)
- Create: `tools/tests/CaseGuard.Tests.ps1`
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` (`$script:RequiredCommands`)
- Modify: `tools/tests/KitFixtures.Tests.ps1`

**Interfaces:**
- Produces:
  - `Test-KitComparableRelativePath -RelativePath <string>` → `[bool]`: `$false` для службових файлів
    платформи (`ConfigDumpInfo.xml`, `DumpFilesIndex.txt` на будь-якій глибині) і шляхів поставки.
  - `Get-KitTreePaths -RepoRoot <string> -Ref <string> [-Path <string>]` → `string[]` повних шляхів
    файлів ref (порожній масив, якщо немає).
  - `Get-KitCaseCollisions -Paths <string[]>` → масив груп; група — `string[]` (≥ 2 шляхи) у порядку
    `Ordinal`; групи впорядковані за першим елементом `Ordinal`. Порожньо — `@()`.
  - `Assert-KitIndexMatchesDisk -RepoRoot <string> -RepoPath <string>` → нічого або виняток з
    префіксом `Індекс '<RepoPath>' не збігається з деревом на диску`.
  - Фікстура: `Set-KitFakeBranchTree -Repo <string> -Branch <string> -Files <IDictionary шлях→вміст>
    -Message <string> [-Parent <string>]` → SHA коміту. Дерево коміту — рівно `-Files`; батько —
    `-Parent`, інакше поточна вершина гілки, якщо є; робоча копія не рухається.

- [ ] **Step 1: Тест фікстури (падає — функції ще немає)**

У `tools/tests/KitFixtures.Tests.ps1`, у наявний `Describe`, додати:

```powershell
    It 'Set-KitFakeBranchTree: записує два шляхи, що різняться лише кириличним регістром; робоча копія не рухається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fake-tree')
        $head = git -C $repo rev-parse HEAD
        $sha = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'old'
            'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'new'
        })
        (git -C $repo rev-parse storage/Alpha_SMB) | Should -Be $sha
        $paths = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only storage/Alpha_SMB)
        $paths | Should -HaveCount 2
        $paths | Should -Contain 'Alpha_SMB/cfe/src/T/Образецанализ.xml'
        $paths | Should -Contain 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'
        (git -C $repo rev-parse HEAD) | Should -Be $head
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        # Другий коміт — батько = попередня вершина
        $sha2 = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message 'v2' -Files ([ordered]@{ 'Alpha_SMB/cfe/src/a.xml' = 'A' })
        (git -C $repo rev-parse "$sha2^") | Should -Be $sha
    }
```

- [ ] **Step 2: Прогін — червоний** (`Set-KitFakeBranchTree` не знайдено).

- [ ] **Step 3: Фікстура**

У `tools/tests/fixtures/KitFixtures.psm1` після `Add-KitFakeStorageCommit`:

```powershell
function Set-KitFakeBranchTree {
    <#
    .SYNOPSIS
        Коміт на гілку з деревом рівно з -Files — без робочої копії, через тимчасовий GIT_INDEX_FILE.
    .DESCRIPTION
        Робоча копія на NTFS не може тримати два шляхи, що різняться лише регістром, і git не
        переводить її через кириличне перейменування регістром (спека 2026-10-04 §2). Тестам злиття,
        adopt, verify і check потрібні саме такі дерева — тому плумбінг: hash-object → update-index
        --cacheinfo → write-tree → commit-tree → update-ref. -c core.ignorecase=false на update-index —
        щоб git не зіставляв варіанти регістру й записав обидва, незалежно від налаштування машини.
        Якщо гілка вибрана в робочій копії, update-ref лишить індекс і диск застарілими — викликач
        це знає й бере для такого випадку окрему гілку.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [Parameter(Mandatory)][string]$Message,
        [string]$Parent
    )
    $idx = Join-Path ([System.IO.Path]::GetTempPath()) "kit-fake-index-$([guid]::NewGuid().ToString('N'))"
    $env:GIT_INDEX_FILE = $idx
    try {
        foreach ($path in @($Files.Keys)) {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmp, [string]$Files[$path], [System.Text.UTF8Encoding]::new($false))
                $sha = ([string](@(Invoke-KitFakeGit -C $Repo hash-object -w --no-filters -- $tmp)[-1])).Trim()
            } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Invoke-KitFakeGit -C $Repo -c core.ignorecase=false update-index --add --cacheinfo "100644,$sha,$path" | Out-Null
        }
        $tree = ([string](@(Invoke-KitFakeGit -C $Repo write-tree)[-1])).Trim()
    } finally {
        Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue
    }
    $parentArgs = @()
    if ($Parent) { $parentArgs = @('-p', $Parent) }
    else {
        # Код 1 = гілки ще немає, не збій (той самий навмисно не загорнутий патерн, що Add-KitFakeStorageCommit).
        git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $parentArgs = @('-p', "refs/heads/$Branch") }
    }
    $msgFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($msgFile, $Message, [System.Text.UTF8Encoding]::new($false))
        $commit = ([string](@(Invoke-KitFakeGit -C $Repo commit-tree $tree @parentArgs -F $msgFile)[-1])).Trim()
    } finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $Repo update-ref "refs/heads/$Branch" $commit | Out-Null
    $commit
}
```

У `Export-ModuleMember` фікстури дописати `Set-KitFakeBranchTree`.

- [ ] **Step 4: Прогін — тест фікстури зелений.**

- [ ] **Step 5: Тести примітивів (падають — модуля ще немає)**

Створити `tools/tests/CaseGuard.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'CaseGuard.psm1 — шляхи, що різняться лише регістром (спека 2026-10-04 §4.4)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/CaseGuard.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'Get-KitCaseCollisions: кирилична пара — одна група в порядку Ordinal; ASCII-пара теж; різні шляхи — ні' {
        $g = @(Get-KitCaseCollisions -Paths @('a/Образецанализ.xml', 'b/x.xml', 'a/ОбразецАнализ.xml', 'c/Readme.md', 'c/README.md'))
        $g | Should -HaveCount 2
        $g[0] | Should -Be @('a/ОбразецАнализ.xml', 'a/Образецанализ.xml')
        $g[1] | Should -Be @('c/README.md', 'c/Readme.md')
    }

    It 'Get-KitCaseCollisions: порожній вхід і один шлях — порожній результат під StrictMode' {
        @(Get-KitCaseCollisions -Paths @()) | Should -HaveCount 0
        @(Get-KitCaseCollisions -Paths @('a/Форма.xml')) | Should -HaveCount 0
    }

    It 'Get-KitCaseCollisions: однакові шляхи двічі — не група' {
        @(Get-KitCaseCollisions -Paths @('a/Форма.xml', 'a/Форма.xml')) | Should -HaveCount 0
    }

    It 'Get-KitTreePaths: кириличні шляхи цілі, -Path звужує, порожня тека — порожньо' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'paths')
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message 'v1' -Files ([ordered]@{
            'Alpha_SMB/cfe/src/T/Образецанализ.xml' = '1'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = '2'; 'other/x.txt' = '3'
        }) | Out-Null
        $all = @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB')
        $all | Should -HaveCount 3
        $src = @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB' -Path 'Alpha_SMB/cfe/src')
        $src | Should -HaveCount 2
        $src | Should -Contain 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'
        @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB' -Path 'nope') | Should -HaveCount 0
        @(Get-KitCaseCollisions -Paths $src) | Should -HaveCount 1
    }

    It 'Get-KitTreePaths: невідомий ref — виняток з кодом git' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'paths-bad')
        { Get-KitTreePaths -RepoRoot $repo -Ref 'no-such-ref' } | Should -Throw '*git ls-tree*no-such-ref*'
    }

    It 'Assert-KitIndexMatchesDisk: збіг — без винятку; службові файли й поставка на диску не рахуються' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'match')
        $src = Join-Path $repo 'Alpha_SMB/cfe/src'
        Set-Content -LiteralPath (Join-Path $src 'ConfigDumpInfo.xml') -Value 'junk'
        New-Item -ItemType Directory -Path (Join-Path $src 'Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Not -Throw
    }

    It 'Assert-KitIndexMatchesDisk: фантом в індексі (кириличний старий регістр) — виняток з обома переліками' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ghost')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/T'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'ОбразецАнализ.xml') -Value 'x' -NoNewline
        git -C $repo add -- 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'
        $sha = (git -C $repo hash-object -w -- (Join-Path $dir 'ОбразецАнализ.xml')).Trim()
        git -C $repo -c core.ignorecase=false update-index --add --cacheinfo "100644,$sha,Alpha_SMB/cfe/src/T/Образецанализ.xml"
        $err = { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "Індекс 'Alpha_SMB/cfe/src' не збігається з деревом на диску*"
        $err.Exception.Message | Should -BeLike '*T/Образецанализ.xml*'
    }

    It 'Assert-KitIndexMatchesDisk: файл, який git ігнорує, на диску не рахується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ignored')
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value '*.bak' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/local.bak') -Value 'b'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Not -Throw
    }

    It 'Assert-KitIndexMatchesDisk: файл на диску, якого немає в індексі — виняток' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'untracked')
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/New.xml') -Value 'n'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Throw '*New.xml*'
    }
}
```

Перед тим як писати `Should -BeLike` на текст винятку — `grep -rn "не збігається з деревом на диску" tools/lib tools/commands` має дати лише `CaseGuard.psm1` (після кроку 7).

- [ ] **Step 6: Прогін — червоний** (модуля немає).

- [ ] **Step 7: Реалізація**

`tools/lib/TreeCompare.psm1` — перед `Get-KitRelativeFiles`:

```powershell
function Test-KitComparableRelativePath {
    <#
    .SYNOPSIS
        Чи бере відносний шлях участь у звірці дерев: не службовий файл платформи й не поставка вендора.
    .DESCRIPTION
        Одне джерело фільтра для Get-KitRelativeFiles (диск) і CaseGuard (індекс, перелік git) —
        два фільтри з різною логікою розходилися б тихо (kit-dev, «пишу перевірку»).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)
    $leaf = ($RelativePath -split '/')[-1]
    ($script:PlatformJunk -notcontains $leaf) -and -not (Test-KitSupplyRelativePath -RelativePath $RelativePath)
}
```

У `Get-KitRelativeFiles` замінити конвеєр на:

```powershell
    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File |
        ForEach-Object { $_.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/' } |
        Where-Object { Test-KitComparableRelativePath -RelativePath $_ })
```

(коментар про поставку над ним лишити, дописавши «фільтр — Test-KitComparableRelativePath»). У
`Export-ModuleMember` дописати `Test-KitComparableRelativePath`.

Створити `tools/lib/CaseGuard.psm1`:

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — конвенція lib-модулів (той самий прийом, що GitOutput.psm1): не перезавантажувати вже
# наявний глобальний TreeCompare. Звідти — Invoke-KitGitProcess, Get-KitRelativeFiles,
# Test-KitComparableRelativePath.
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Get-KitTreePaths {
    <#
    .SYNOPSIS
        Повні шляхи файлів ref (опційно під -Path) — сирі, UTF-8, незалежно від консолі.
    .DESCRIPTION
        ls-tree -r -z через Invoke-KitGitProcess: голий конвеєр PowerShell декодує вивід за кодуванням
        консолі й на cp866 калічить кирилицю (рев'ю B3), а без -z git квотує не-ASCII у лапках.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [string]$Path
    )
    $gitArgs = @('-c', 'core.quotepath=false', 'ls-tree', '-r', '-z', '--name-only', $Ref)
    if ($Path) { $gitArgs += @('--', (($Path -replace '\\', '/').TrimEnd('/'))) }
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments $gitArgs
    if ($r.ExitCode -ne 0) { throw "git ls-tree $Ref завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    @($r.Stdout -split "`0" | Where-Object { $_ })
}

function Get-KitCaseCollisions {
    <#
    .SYNOPSIS
        Групи шляхів, що різняться лише регістром — за юнікодним складанням, як у NTFS.
    .DESCRIPTION
        OrdinalIgnoreCase, а не ASCII: core.ignorecase у git складає лише a–z (memihash), тому
        кириличну пару git вважає двома файлами, а NTFS — одним (спека 2026-10-04 §2). tr і
        ASCII-нижній регістр дають на кирилиці хибні 0 (виміряно interoptica).
        Без coma-wrap на результаті: викликачі загортають його в @(...). Кожна група виходить
        одним елементом (кома перед масивом групи).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)
    $map = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) {
        if (-not $map.ContainsKey($p)) { $map[$p] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
        [void]$map[$p].Add($p)
    }
    $groups = [System.Collections.Generic.List[string[]]]::new()
    foreach ($set in $map.Values) {
        if ($set.Count -lt 2) { continue }
        $arr = [string[]]@($set)
        [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
        $groups.Add($arr)
    }
    $sorted = [System.Linq.Enumerable]::OrderBy($groups, [Func[string[], string]] { param($g) $g[0] }, [System.StringComparer]::Ordinal)
    foreach ($g in $sorted) { , $g }
}

function Assert-KitIndexMatchesDisk {
    <#
    .SYNOPSIS
        Інваріант спеки 2026-10-04 §4.1: індекс піддерева ≡ файли на диску, побайтово за іменем (Ordinal).
    .DESCRIPTION
        Ловить фантом (старий регістр лишився в індексі), загублений ASCII-регістр і будь-яку іншу
        евристику git, яка розводить індекс із диском. Службові файли й поставку не рахує
        (Test-KitComparableRelativePath — той самий фільтр, що в verify). Кидає до коміту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath
    )
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $ls = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-files', '-z', '--', $prefix)
    if ($ls.ExitCode -ne 0) { throw "git ls-files -- $prefix завершився з кодом $($ls.ExitCode): $($ls.Stderr)" }
    $index = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in ($ls.Stdout -split "`0")) {
        if (-not $p) { continue }
        $rel = $p.Substring($prefix.Length).TrimStart('/')
        if (Test-KitComparableRelativePath -RelativePath $rel) { [void]$index.Add($rel) }
    }
    $disk = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-KitRelativeFiles -Root (Join-Path $RepoRoot $prefix)), [System.StringComparer]::Ordinal)
    # Файли, які git ігнорує, у дерево за визначенням не входять — їх не рахуємо (інакше дзеркало з
    # файлом, який споживач ігнорує, зупиняло б adopt уже після стирання дерева). У worktree дзеркала
    # .gitignore немає — перелік порожній.
    $ign = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--', $prefix)
    if ($ign.ExitCode -ne 0) { throw "git ls-files --ignored -- $prefix завершився з кодом $($ign.ExitCode): $($ign.Stderr)" }
    foreach ($p in ($ign.Stdout -split "`0")) {
        if ($p) { [void]$disk.Remove($p.Substring($prefix.Length).TrimStart('/')) }
    }
    $onlyIndex = @($index | Where-Object { -not $disk.Contains($_) } | Sort-Object -CaseSensitive)
    $onlyDisk  = @($disk  | Where-Object { -not $index.Contains($_) } | Sort-Object -CaseSensitive)
    if ($onlyIndex.Count -eq 0 -and $onlyDisk.Count -eq 0) { return }
    $fmt = { param($list) $shown = @($list | Select-Object -First 5); ($shown -join ', ') + $(if ($list.Count -gt 5) { ", …і ще $($list.Count - 5)" } else { '' }) }
    throw ("Індекс '$prefix' не збігається з деревом на диску після git add — коміт не створено (спека 2026-10-04 §4.1; " +
           'ймовірна причина — перейменування лише регістром, яке git на Windows не розпізнав). ' +
           "Лише в індексі ($($onlyIndex.Count)): $(& $fmt $onlyIndex). Лише на диску ($($onlyDisk.Count)): $(& $fmt $onlyDisk).")
}

Export-ModuleMember -Function Get-KitTreePaths, Get-KitCaseCollisions, Assert-KitIndexMatchesDisk
```

`tools/lib/module-order.txt`: рядок `CaseGuard` одразу після `TreeCompare`; у шапку коментаря дописати
«CaseGuard — після TreeCompare (Invoke-KitGitProcess, Get-KitRelativeFiles,
Test-KitComparableRelativePath; StorageBranch імпортує його вкладено, як AgentBase — V8)».

`tools/tests/ModuleImportOrder.Tests.ps1`: у `$script:RequiredCommands` дописати
`'Get-KitTreePaths', 'Get-KitCaseCollisions', 'Assert-KitIndexMatchesDisk', 'Test-KitComparableRelativePath'`.

- [ ] **Step 8: Прогін повний — зелений** (у т. ч. `TreeCompare.Tests.ps1` «Get-KitRelativeFiles: …»
  без змін поведінки й `ModuleImportOrder.Tests.ps1`).

- [ ] **Step 9: Контроль уміє впасти.** На копії дерева в `Get-KitCaseCollisions` замінити
  `OrdinalIgnoreCase` на `Ordinal` → тести «кирилична пара» червоні; в
  `Assert-KitIndexMatchesDisk` замінити `throw (...)` на `return` → тести «фантом» і «файл на диску»
  червоні; прибрати блок `--ignored` → тест «ігнорує» червоний. Записати прогони у звіт.

- [ ] **Step 10: Коміт (контролер)**

```bash
git add tools/lib/CaseGuard.psm1 tools/lib/TreeCompare.psm1 tools/lib/module-order.txt tools/tests/fixtures/KitFixtures.psm1 tools/tests/CaseGuard.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/KitFixtures.Tests.ps1
git commit --only -F <файл повідомлення> -- tools/lib/CaseGuard.psm1 tools/lib/TreeCompare.psm1 tools/lib/module-order.txt tools/tests/fixtures/KitFixtures.psm1 tools/tests/CaseGuard.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/KitFixtures.Tests.ps1
```

(Коміти коду kit — `--only` безпечний: це не дерево з кириличним перейменуванням регістром.)

---

### Task 2: Коміт дзеркала — `rm --cached` і інваріант

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` (`Write-KitStorageVersion`, імпорти на початку файлу)
- Test: `tools/tests/StorageBranch.Tests.ps1` (Describe «StorageBranch.psm1 — worktree гілки дзеркала й коміт версії»)

**Interfaces:**
- Consumes: `Assert-KitIndexMatchesDisk`, `Set-KitFakeBranchTree` (задача 1).
- Produces: `Write-KitStorageVersion` — сигнатура й результат (`Sha`, `Empty`) без змін; новий виняток
  з `Assert-KitIndexMatchesDisk`, якщо індекс розійшовся з диском.

- [ ] **Step 1: Тести (падають)**

У зазначений `Describe` додати:

```powershell
    It '<Case>: перейменування лише регістром — у коміті дзеркала лише новий регістр, без фантома (#31)' -ForEach @(
        @{ Case = 'кирилиця'; Old = 'Образецанализ'; New = 'ОбразецАнализ' }
        @{ Case = 'ASCII';    Old = 'Sampleabc';     New = 'SampleaBc' }
    ) {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "case-$Case") -WithHooks
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
            "Alpha_SMB/cfe/src/T/$Old.xml" = 'xml'; "Alpha_SMB/cfe/src/T/$Old/Ext/T.bin" = 'bin'
        }) | Out-Null
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        try {
            $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
            New-Item -ItemType Directory -Path (Join-Path $target "T/$New/Ext") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target "T/$New.xml") -Value 'xml' -NoNewline
            Set-Content -LiteralPath (Join-Path $target "T/$New/Ext/T.bin") -Value 'bin' -NoNewline
            Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' -Message "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" `
                -AuthorName 'T' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp | Out-Null
        } finally { Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path }
        $paths = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only storage/Alpha_SMB)
        $paths | Should -Be @("Alpha_SMB/cfe/src/T/$New.xml", "Alpha_SMB/cfe/src/T/$New/Ext/T.bin")
    }

    It 'глобальний конфіг за порадою ГітКонвертера (autocrlf=true, safecrlf=true) — байти платформи в blob як є' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'gitconverter-global') -WithHooks
        $cfg = Join-Path $TestDrive 'gitconverter.gitconfig'
        Set-Content -LiteralPath $cfg -Value "[core]`n`tautocrlf = true`n`tsafecrlf = true" -Encoding ascii
        $env:GIT_CONFIG_GLOBAL = $cfg
        try {
            $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
            try {
                $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
                $mixed = [byte[]](0x3C,0x61,0x3E,0x0D,0x0A,0x74,0x0A,0x74,0x3C,0x2F,0x61,0x3E)
                [System.IO.File]::WriteAllBytes((Join-Path $target 'Form.xml'), $mixed)
                $rawId = (git -C $repo hash-object --no-filters (Join-Path $target 'Form.xml')).Trim()
                Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" `
                    -AuthorName 'T' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp | Out-Null
            } finally { Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path }
        } finally { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
        (git -C $repo rev-parse 'storage/Alpha_SMB:Alpha_SMB/cfe/src/Form.xml').Trim() | Should -Be $rawId
    }
```

- [ ] **Step 2: Прогін — червоні обидва варіанти `-ForEach`** (кирилиця: у дереві 3 шляхи — фантом
  `T/Образецанализ/Ext/T.bin`; ASCII: старий регістр). Тест `GIT_CONFIG_GLOBAL` — зелений уже зараз
  (захист `-c` є); його контроль — крок 5.

- [ ] **Step 3: Реалізація**

`tools/lib/StorageBranch.psm1`, імпорти на початку: дописати `Import-Module "$PSScriptRoot/CaseGuard.psm1"`.

У `Write-KitStorageVersion`, у `try` перед рядком `$addOut = git -C $WorktreePath -c core.autocrlf=false ... add -A -- $RepoPath 2>&1`:

```powershell
        # Індекс піддерева — наново з того, що вивантажила платформа (спека 2026-10-04 §4.1). Без
        # цього `add -A` при core.ignorecase=true лишає запис старого регістру: git складає регістр
        # лише ASCII (memihash), а lstat старого шляху на NTFS успішний — кирилична зміна регістру
        # дає фантом поруч із новим шляхом, ASCII — губить новий регістр. Clear-KitWorktreeSource
        # уже лишив на диску рівно дамп, тож нічого живого цим не втрачається.
        $rmOut = git -C $WorktreePath rm -r -q --cached --ignore-unmatch -- $RepoPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git rm --cached у worktree завершився з кодом ${LASTEXITCODE}: $($rmOut -join "`n")" }
```

Одразу після перевірки коду `add` (рядок `if ($LASTEXITCODE -ne 0) { throw "git add у worktree ...`):

```powershell
        Assert-KitIndexMatchesDisk -RepoRoot $WorktreePath -RepoPath $RepoPath
```

У `.DESCRIPTION` функції дописати речення: «Індекс піддерева знімається (`rm --cached`) перед `add -A`
і звіряється з диском до коміту — перейменування лише регістром (спека 2026-10-04 §4.1).»

- [ ] **Step 4: Прогін повний — зелений.**

- [ ] **Step 5: Контроль уміє впасти** (копія дерева): (а) прибрати рядок `git rm ... --cached` →
  тести `-ForEach` червоні; (б) прибрати `-c core.safecrlf=false` і `-c core.autocrlf=false` з `add` →
  тест `GIT_CONFIG_GLOBAL` червоний (`fatal: LF would be replaced by CRLF`); (в) прибрати лише
  `Assert-KitIndexMatchesDisk` при прибраному `rm --cached` — тест червоний з фантомом у дереві
  (інваріант — другий рубіж). Три прогони — у звіт.

- [ ] **Step 6: Коміт (контролер)** — `tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1`.

---

### Task 3: `adopt` — `-text` до руйнівного кроку, `rm --cached`, коміт без `--only`

**Files:**
- Modify: `tools/commands/adopt.psm1` (функція `Invoke-KitAdopt`)
- Test: `tools/tests/Adopt.Tests.ps1`

**Interfaces:**
- Consumes: `Assert-KitIndexMatchesDisk`, `Set-KitFakeBranchTree` (задача 1); `Test-GitTextPolicy`
  (`tools/lib/GitOutput.psm1`, без змін).
- Produces: поведінка `kit adopt -Apply` (CLI без змін); нова зупинка до стирання дерева з текстом
  `не виведено з-під конверсії кінців рядків`.

- [ ] **Step 1: Підготовка наявних тестів.** `Test-GitTextPolicy` у `adopt` вимагатиме `-text` на
  шляху джерела. У `Adopt.Tests.ps1` знайти всі виклики `New-KitFakeRepo` (у `New-AdoptRepo` і в інших
  `Describe`) і дописати `-WithGitattributes` там, де його немає (фікстура дописує рядки `-text` під
  фактичні шляхи, зокрема клієнтський `cf/src` і `cfe/<Ім'я>/src`). Прогін `Adopt.Tests.ps1` — зелений
  на поточному коді (зміна фікстури поведінки не міняє).

- [ ] **Step 2: Нові тести (падають)**

У `Describe 'kit adopt — прев''ю показує ціну заміни'` додати:

```powershell
    It 'кириличне перейменування регістром, шлях зі злиттям — у коміті adopt лише новий регістр' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-case-merge') -WithHooks -WithGitignore -WithGitattributes
        $src = Join-Path $repo 'Alpha_SMB/cfe/src'
        New-Item -ItemType Directory -Path (Join-Path $src 'T/Образецанализ/Ext') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'T/Образецанализ.xml') -Value 'xml' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'T/Образецанализ/Ext/T.bin') -Value 'bin' -NoNewline
        git -C $repo add -A 2>&1 | Out-Null; git -C $repo commit -q -m 'робота зі старим регістром' 2>&1 | Out-Null
        $conf = [System.IO.File]::ReadAllText((Join-Path $src 'Configuration.xml'))
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "sync: версія 7`n`nStorage-Source: Alpha_SMB`nStorage-Version: 7" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/Configuration.xml' = $conf
            'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin' = 'bin'
        }) | Out-Null
        $r = Invoke-Adopt -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $tree = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD -- 'Alpha_SMB/cfe/src/T')
        $tree | Should -Be @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        @(git -C $repo log -1 --format=%P HEAD) -split ' ' | Should -HaveCount 2
    }

    It 'кириличне перейменування регістром, дзеркало вже предок (коміт без злиття) — без фантома' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-case-plain') -WithHooks -WithGitignore -WithGitattributes
        $mirror = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "sync: версія 7`n`nStorage-Source: Alpha_SMB`nStorage-Version: 7" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin' = 'bin'
        })
        # Гілка задачі — нащадок дзеркала, але зі старим регістром (дзеркало вже предок → adopt комітить без merge).
        Set-KitFakeBranchTree -Repo $repo -Branch 'task' -Parent $mirror -Message 'локально старий регістр' -Files ([ordered]@{
            'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/Образецанализ/Ext/T.bin' = 'bin'
            'v8storagekit.yaml' = (Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw)
            'Alpha_SMB/v8project.yaml' = (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Raw)
            '.gitattributes' = (Get-Content -LiteralPath (Join-Path $repo '.gitattributes') -Raw)
            '.gitignore' = (Get-Content -LiteralPath (Join-Path $repo '.gitignore') -Raw)
            'AUTHORS' = (Get-Content -LiteralPath (Join-Path $repo 'AUTHORS') -Raw)
        }) | Out-Null
        git -C $repo checkout -q -f task 2>&1 | Out-Null
        $r = Invoke-Adopt -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $tree = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD -- 'Alpha_SMB/cfe/src/T')
        $tree | Should -Be @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        @(git -C $repo log -1 --format=%P HEAD) -split ' ' | Should -HaveCount 1
    }

    It 'шлях джерела без -text — зупинка до стирання дерева, дерево ціле, коміту немає' {
        $repo = New-AdoptRepo 'adopt-no-text'
        # Перекрити -text з шаблону для цього шляху: остання відповідна лінія перемагає.
        Add-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value 'Alpha_SMB/cfe/src/** text' -Encoding UTF8
        git -C $repo add .gitattributes 2>&1 | Out-Null; git -C $repo commit -q -m 'зламана політика' 2>&1 | Out-Null
        $head = git -C $repo rev-parse HEAD
        $r = Invoke-Adopt -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*не виведено з-під конверсії кінців рядків*'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Exist
        (git -C $repo rev-parse HEAD) | Should -Be $head
    }

    It 'дзеркало несе файл, який споживач ігнорує, — інваріант «індекс ≡ диск» не зупиняє adopt' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-ignored-file') -WithHooks -WithGitignore -WithGitattributes
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Value '*.bak' -Encoding UTF8
        git -C $repo add .gitignore 2>&1 | Out-Null; git -C $repo commit -q -m 'ігнор *.bak' 2>&1 | Out-Null
        $conf = [System.IO.File]::ReadAllText((Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'))
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "sync: версія 7`n`nStorage-Source: Alpha_SMB`nStorage-Version: 7" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/Configuration.xml' = $conf; 'Alpha_SMB/cfe/src/New.xml' = 'n'; 'Alpha_SMB/cfe/src/local.bak' = 'b'
        }) | Out-Null
        $r = Invoke-Adopt -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD -- 'Alpha_SMB/cfe/src') | Should -Not -Contain 'Alpha_SMB/cfe/src/local.bak'
    }

    It 'глобальний конфіг ГітКонвертера (autocrlf=true, safecrlf=true): змішаний файл із дзеркала — blob побайтово' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-gitconverter') -WithHooks -WithGitignore -WithGitattributes
        $conf = [System.IO.File]::ReadAllText((Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'))
        $mixed = "<a>`r`nt`nt</a>"
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "sync: версія 7`n`nStorage-Source: Alpha_SMB`nStorage-Version: 7" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/Configuration.xml' = $conf; 'Alpha_SMB/cfe/src/Form.xml' = $mixed
        }) | Out-Null
        $mirrorBlob = (git -C $repo rev-parse 'storage/Alpha_SMB:Alpha_SMB/cfe/src/Form.xml').Trim()
        $cfg = Join-Path $TestDrive 'adopt-gitconverter.gitconfig'
        Set-Content -LiteralPath $cfg -Value "[core]`n`tautocrlf = true`n`tsafecrlf = true" -Encoding ascii
        $env:GIT_CONFIG_GLOBAL = $cfg
        try { $r = Invoke-Adopt -Repo $repo -More @('-Apply') } finally { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (git -C $repo rev-parse 'HEAD:Alpha_SMB/cfe/src/Form.xml').Trim() | Should -Be $mirrorBlob
    }
```

Перед `Should -BeLike '*не виведено з-під конверсії кінців рядків*'` — `grep -rn "не виведено з-під конверсії" tools/commands tools/lib`: зараз фраза є в `check.psm1`; тест іде через `adopt`, тож має з'явитись і в `adopt.psm1` — переконатись, що `adopt` до `check` не звертається (він не звертається: `kit.ps1` вантажить лише модуль команди).

- [ ] **Step 3: Прогін — червоні:** «шлях зі злиттям» (фантом `T/Образецанализ/Ext/T.bin`), «без
  злиття» (`commit --only` воскрешає обидва старі шляхи), «без -text» (adopt проходить). «Ігнорований
  файл» і «ГітКонвертер» можуть бути зеленими — це запобіжники для кроків 4–5.

- [ ] **Step 4: Реалізація** (`tools/commands/adopt.psm1`, `Invoke-KitAdopt`)

(а) Одразу після рядка `$version = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $mirror`:

```powershell
        # -text на шляху джерела — ДО першого руйнівного кроку (спека 2026-10-04 §4.1). Без нього
        # git застосує core.autocrlf/core.safecrlf машини: за порадою ГітКонвертера (autocrlf=true,
        # safecrlf=true) add відмовить уже ПІСЛЯ стирання дерева, з safecrlf=warn — мовчки нормалізує
        # змішані кінці рядків платформи. Досі це ловив лише kit check.
        if (-not (Test-GitTextPolicy -RepoRoot $root -Path $src.RepoPath)) {
            throw ("Дерево '$($src.RepoPath)' не виведено з-під конверсії кінців рядків — adopt зупиняється до стирання дерева. " +
                   "Додайте в .gitattributes рядок '$($src.RepoPath)/** -text' окремим комітом (docs/text-policy.md) і повторіть adopt.")
        }
```

(б) Перед `$addArgs = @('add', '-A', '--', $src.RepoPath)`:

```powershell
            # Індекс піддерева — наново з дерева дзеркала (спека 2026-10-04 §4.1): без цього `add -A`
            # при core.ignorecase=true лишає запис старого регістру (git складає лише ASCII, а lstat
            # старого шляху на NTFS успішний). Поставка в індексі не буває (перевірено вище), тож rm
            # її не зачіпає.
            $rm = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rm', '-r', '-q', '--cached', '--ignore-unmatch', '--', $src.RepoPath)
            if ($rm.ExitCode -ne 0) { throw "git rm --cached для '$($src.RepoPath)' завершився з кодом $($rm.ExitCode): $($rm.Stderr)" }
```

(в) Рядок `$addArgs = @('add', '-A', '--', $src.RepoPath)` замінити на:

```powershell
            $addArgs = @('-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', 'add', '-A', '--', $src.RepoPath)
```

(г) Після `Remove-KitSupplyFromIndex -RepoRoot $root -SupplyPath $supplyRel`:

```powershell
            Assert-KitIndexMatchesDisk -RepoRoot $root -RepoPath $src.RepoPath
```

(ґ) Гілку коміту без злиття

```powershell
            } else {
                $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '--only', '-m', $message, '--', $src.RepoPath)
            }
```

замінити на коміт без `--only`, а коментар над `if ($viaMerge)` переписати: обидві гілки тепер комітять
індекс як є; причина для гілки без злиття — `commit --only -- <шлях>` накладає записи `HEAD` під
pathspec і перечитує їх із диска, тож старий регістр на NTFS «існує» й фантом воскресає (спека
2026-10-04 §4.1, факт); межу «точковий коміт» тримає guard «немає незакомічених змін поза шляхом
джерела» вище. Код:

```powershell
            $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '-m', $message)
```

(тобто `if ($viaMerge) { … } else { … }` згортається в один виклик; `$viaMerge` лишається потрібним
блоку `catch` нижче).

Перевірити `grep -n "commit', '--only'" tools/commands/adopt.psm1` — порожньо.

- [ ] **Step 5: Прогін повний — зелений.** Тест «файл, який споживач ігнорує» тримає Review Focus 1:
  без блоку `--ignored` в `Assert-KitIndexMatchesDisk` (задача 1) він червоний — `local.bak` лежить на
  диску після копіювання дзеркала, а `add -A` його не бере.

- [ ] **Step 6: Контроль уміє впасти** (копія дерева): (а) повернути `commit --only` → «без злиття»
  червоний; (б) прибрати `rm --cached` → «зі злиттям» червоний; (в) прибрати перевірку `-text` → «без
  -text» червоний. Три прогони — у звіт.

- [ ] **Step 7: Коміт (контролер)** — `tools/commands/adopt.psm1 tools/tests/Adopt.Tests.ps1`.

---

### Task 4: Злиття без робочої копії — `Merge-KitBranchInto`

**Files:**
- Modify: `tools/lib/GitMerge.psm1` (`Merge-KitBranchInto`, імпорти)
- Test: `tools/tests/GitMerge.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-KitGitProcess` (TreeCompare), `Test-KitBranchExists`, `Get-KitCommitSha`
  (StorageBranch), `Set-KitFakeBranchTree` (фікстура).
- Produces: `Merge-KitBranchInto -RepoRoot -Branch -Into -Message [-AllowUnrelated]` (параметр
  `-WorkDir` **прибрано**) → `[pscustomobject]@{ Outcome = 'merged'|'already'; Sha; Via = 'in-place'|'ref'|'none' }`.
  `Via = 'ref'` замінює колишнє `'worktree'`: `<Into>` не вибрана тут — пересунуто лише гілку.
  Викликачі (`sync.psm1` — `Invoke-KitMainMerge`, `verify.psm1`) друкують `Via` як є — правок не треба.

- [ ] **Step 1: Оновити наявний тест** «HEAD на гілці задачі F: …»: заголовок →
  `'HEAD на гілці задачі F: злиття лише пересуває main; F і робоча копія не зрушили; worktree не створюється'`;
  `$r.Via | Should -Be 'worktree'` → `$r.Via | Should -Be 'ref'`; решту асерцій лишити (зокрема
  `build/sync/_main/wt` не існує й `worktree list` — 1 рядок). Тест конфлікту: асерцію
  `Should -Throw '*конфлікт*git merge storage/Alpha_SMB*'` лишити — новий текст її задовольняє.

- [ ] **Step 2: Нові тести (падають)**

У `Describe 'GitMerge.psm1 — …'` додати (хелпер у `BeforeAll` поруч із `New-RepoWithMirror`):

```powershell
        function script:New-RepoWithCaseRename {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
                'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/Образецанализ/Ext/T.bin' = 'bin'
            }) | Out-Null
            Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" -Files ([ordered]@{
                'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin' = 'bin'
            }) | Out-Null
            $repo
        }
```

```powershell
    It 'кириличне перейменування регістром, main вибрана тут — merged in-place; диск і індекс у новому регістрі (#31)' {
        $repo = New-RepoWithCaseRename 'case-inplace'
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: злиття v2'
        $r.Outcome | Should -Be 'merged'
        $r.Via | Should -Be 'in-place'
        @(git -c core.quotepath=false -C $repo ls-files -- 'Alpha_SMB/cfe/src/T') |
            Should -Be @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name) | Should -Contain 'ОбразецАнализ.xml'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        @((git -C $repo log -1 --format=%P main) -split ' ') | Should -HaveCount 2
        (git -C $repo log -1 --format=%s main) | Should -Be 'sync: злиття v2'
    }

    It 'кириличне перейменування регістром, HEAD на гілці задачі — merged через ref; F і диск не зрушили' {
        $repo = New-RepoWithCaseRename 'case-ref'
        git -C $repo checkout -q -b feature/task
        $before = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name)
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: злиття v2'
        $r.Via | Should -Be 'ref'
        @(git -c core.quotepath=false -C $repo ls-tree -r --name-only main -- 'Alpha_SMB/cfe/src/T') |
            Should -Be @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name) | Should -Be $before
        (git -C $repo branch --show-current) | Should -Be 'feature/task'
    }

    It 'невідстежуваний файл у main — брудна копія, зупинка до злиття; main не зрушив, файл цілий' {
        $repo = New-RepoWithMirror 'untracked'
        Set-Content -LiteralPath (Join-Path $repo 'notes.txt') -Value 'моя чернетка'
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw '*не чиста*notes.txt*'
        (git -C $repo rev-parse main) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $repo 'notes.txt') -Raw).Trim() | Should -Be 'моя чернетка'
    }

    It 'main вибрана в іншому worktree — зупинка, main не зрушив' {
        $repo = New-RepoWithMirror 'other-wt'
        git -C $repo checkout -q -b feature/task
        $wt = Join-Path $TestDrive 'other-wt-main'
        git -C $repo worktree add -q $wt main
        try {
            $before = git -C $repo rev-parse main
            { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw "*'main' вибрана в іншому worktree*"
            (git -C $repo rev-parse main) | Should -Be $before
        } finally { git -C $repo worktree remove --force $wt 2>$null }
    }

    It 'ціль — storage/*: зупинка до будь-якої дії' {
        $repo = New-RepoWithMirror 'into-storage'
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'main' -Into 'storage/Alpha_SMB' -Message 'x' -AllowUnrelated } | Should -Throw '*storage/Alpha_SMB*дзеркало сховища*'
    }

    It 'конфлікт: нічого не змінено, merge --abort не викликався (немає хибного «незавершеного злиття»)' {
        $repo = New-RepoWithMirror 'conflict-new'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Value 'A-main' -NoNewline
        git -C $repo add -A; git -C $repo commit -q -m 'main править a.xml'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A-storage' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $err = { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Нічого не змінено*Alpha_SMB/cfe/src/a.xml*'
        $err.Exception.Message | Should -Not -BeLike '*незавершеному*'
    }
```

Перегони «гілку пересунули між `merge-tree` і `update-ref`» юніт-тестом не відтворити (нативний git
не мокується, а тест, що лише кличе злиття, був би тавтологією — kit-dev «обидва боки умови»). Тому
перевірка старого значення в `update-ref` — пункт рев'ю задачі читанням коду, не тест.

Перед асерціями на текст — `grep -rn "Нічого не змінено\|вибрана в іншому worktree\|дзеркало сховища" tools/lib tools/commands`: «дзеркало сховища» є й у `sync.psm1`/`StorageBranch.psm1`; тест кличе `Merge-KitBranchInto` напряму, тож збіг можливий лише з `GitMerge.psm1` — прийнятно; асерція звужена ще й `*storage/Alpha_SMB*`.

- [ ] **Step 3: Прогін — червоні:** обидва кириличні (git merge відмовляє), «невідстежуваний» (поточний
  код сам відмовляє як «не чиста»? — так, `status --porcelain` бачить `??`; тест може бути зеленим —
  запобіжник регресії для нового механізму), «інший worktree» (поточний код дає інший текст), «ціль —
  storage/*», «конфлікт» (поточний текст без «Нічого не змінено»), оновлений «F» (`Via`).

- [ ] **Step 4: Реалізація** — `tools/lib/GitMerge.psm1`

Імпорти: дописати `Import-Module "$PSScriptRoot/TreeCompare.psm1"` (Invoke-KitGitProcess).

`Merge-KitBranchInto` замінити повністю:

```powershell
function Merge-KitBranchInto {
    <#
    .SYNOPSIS
        Зливає гілку дзеркала в головну гілку чи гілку задачі (спека §3.4, рішення Q4) — без робочої копії.
    .DESCRIPTION
        Злиття рахує git merge-tree --write-tree (той самий ort, що git merge), коміт — commit-tree з
        двома батьками, гілку пересуває update-ref з перевіркою старого значення. Робочу копію
        оновлює лише одна команда — read-tree --reset -u HEAD — і лише коли <Into> вибрана тут.
        Причина (спека 2026-10-04 §2, §4.2): git на Windows не переводить робочу копію через
        перейменування лише регістром не-ASCII імені — merge/checkout/reset --keep/read-tree -m
        відмовляють з «untracked working tree files would be overwritten», навіть на чистому коміті.
        Проходять лише merge-tree і примусове read-tree --reset -u.
        Випадки: <Into> вибрана тут і чиста — злиття на місці (Via=in-place); вибрана тут і брудна
        (зокрема невідстежувані файли — read-tree --reset їх не захищає) — зупинка; вибрана в іншому
        worktree — зупинка (update-ref пересунув би гілку під чужою копією); не вибрана ніде —
        пересувається лише гілка (Via=ref). Конфлікт — зупинка, НІЧОГО не змінено, merge --abort не
        потрібен. Хуки pre-merge-commit/post-merge не викликаються: перший охороняв лише storage/* —
        тепер це перевірка нижче.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Into,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllowUnrelated
    )

    if ($Into -like 'storage/*') {
        throw "У гілку '$Into' нічого не зливають — це дзеркало сховища (гілки storage/* пише лише kit sync). Зливають storage/* у головну гілку чи гілку задачі."
    }
    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Into)) {
        throw "Гілки '$Into' немає — нема куди зливати $Branch. Створіть перший коміт у головній гілці (скіл onboarding робить це першим)."
    }
    if (Test-KitBranchMergedInto -RepoRoot $RepoRoot -Branch $Branch -Into $Into) {
        return [pscustomobject]@{ Outcome = 'already'; Sha = (Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into); Via = 'none' }
    }

    # Залишок тимчасового worktree kit ≤ 1.3.1 (build/sync/_main/wt) — прибрати, якщо є: нова схема його не створює.
    $legacy = Join-Path $RepoRoot 'build/sync/_main/wt'
    if (Test-Path -LiteralPath $legacy) {
        Assert-SafeWorkPath -Path $legacy -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'залишок worktree головної гілки'
        git -C $RepoRoot worktree remove --force $legacy 2>$null | Out-Null
        if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Recurse -Force }
        git -C $RepoRoot worktree prune 2>$null | Out-Null
    }

    # 2>$null, не 2>&1: $current читається як ім'я гілки (той самий принцип, що StorageBranch.psm1).
    $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git branch --show-current у $RepoRoot завершився з кодом ${LASTEXITCODE}." }
    $here = ($current -eq $Into)
    if ($here) {
        # -c core.quotepath=false і 2>$null — див. історію в коментарях попередньої редакції (B2):
        # перелік має бути шляхами, не попередженнями git.
        $dirty = git -c core.quotepath=false -C $RepoRoot status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git status завершився з кодом ${LASTEXITCODE}." }
        if ($dirty) {
            $lines = @($dirty)
            $shown = @($lines | Select-Object -First 5)
            $more  = $lines.Count - $shown.Count
            $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
            throw ("Гілка '$Into' вибрана, але робоча копія не чиста — у брудний '$Into' не зливаємо. Незакомічені шляхи:`n$detail`n" +
                   "Закомітьте або сховайте зміни (git stash) і повторіть, або перейдіть на гілку задачі — тоді злиття лише пересуне '$Into'.")
        }
    } else {
        $wl = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('worktree', 'list', '--porcelain')
        if ($wl.ExitCode -ne 0) { throw "git worktree list завершився з кодом $($wl.ExitCode): $($wl.Stderr)" }
        if (@($wl.Stdout -split "`n" | Where-Object { $_.Trim() -eq "branch refs/heads/$Into" }).Count -gt 0) {
            throw ("Гілка '$Into' вибрана в іншому worktree — kit не пересуває гілку під чужою робочою копією. " +
                   "Повторіть злиття там, де '$Into' вибрана, або приберіть той worktree.")
        }
    }

    $old = Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into
    $mtArgs = @('-c', 'core.quotepath=false', 'merge-tree', '--write-tree', '--name-only', '-z')
    if ($AllowUnrelated) { $mtArgs += '--allow-unrelated-histories' }
    $mtArgs += @($old, $Branch)
    $mt = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments $mtArgs
    $fields = @($mt.Stdout -split "`0")
    switch ($mt.ExitCode) {
        0 { }
        1 {
            # -z --name-only: <дерево>\0<шлях>\0…\0\0<повідомлення> — конфліктні шляхи до першого порожнього поля.
            $conflicts = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $fields.Count -and $fields[$i]; $i++) { $conflicts.Add($fields[$i]) }
            $shown = @($conflicts | Select-Object -First 5)
            $more  = $conflicts.Count - $shown.Count
            $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
            throw ("Злиття $Branch → $Into не вдалося: конфлікт. Нічого не змінено — гілка '$Into' і робоча копія ті самі. " +
                   "Конфліктні шляхи:`n$detail`nРозв'яжіть вручну: git merge $Branch. Увага: якщо серед змін є перейменування " +
                   'лише регістром не-ASCII імен, ручний git merge на Windows сам відмовить з «would be overwritten» ' +
                   '(docs/storage-and-git.md, «Перейменування регістром»).')
        }
        129 { throw "git merge-tree не розпізнав --write-tree — потрібен git ≥ 2.38. Оновіть git і повторіть. git: $($mt.Stderr)" }
        default { throw "git merge-tree $Branch → $Into завершився з кодом $($mt.ExitCode): $($mt.Stderr)" }
    }
    $tree = $fields[0].Trim()

    $msgFile = Join-Path $RepoRoot "build/sync/merge-message-$([guid]::NewGuid().ToString('N')).txt"
    New-Item -ItemType Directory -Path (Split-Path -Parent $msgFile) -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText($msgFile, $Message, [System.Text.UTF8Encoding]::new($false))
        $ct = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('commit-tree', $tree, '-p', $old, '-p', $Branch, '-F', $msgFile)
        if ($ct.ExitCode -ne 0) { throw "git commit-tree завершився з кодом $($ct.ExitCode): $($ct.Stderr)" }
    } finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
    $new = $ct.Stdout.Trim()

    $ur = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('update-ref', '-m', "kit: $Message", "refs/heads/$Into", $new, $old)
    if ($ur.ExitCode -ne 0) {
        throw ("Гілку '$Into' пересунули, поки kit рахував злиття (update-ref з перевіркою старого значення відмовив) — " +
               "нічого не змінено. Повторіть команду. git: $($ur.Stderr)")
    }

    if ($here) {
        $rt = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('read-tree', '--reset', '-u', 'HEAD')
        if ($rt.ExitCode -ne 0) {
            throw ("Коміт злиття $($new.Substring(0, 7)) уже створено і гілку '$Into' пересунуто, але робоча копія не оновилась " +
                   "(git read-tree --reset -u HEAD, код $($rt.ExitCode): $($rt.Stderr)). Відновлення — та сама команда: " +
                   'git read-tree --reset -u HEAD (робоча копія була чистою до злиття, тож нічого не втрачається).')
        }
        return [pscustomobject]@{ Outcome = 'merged'; Sha = $new; Via = 'in-place' }
    }
    [pscustomobject]@{ Outcome = 'merged'; Sha = $new; Via = 'ref' }
}
```

Перевірити `grep -rn "\-WorkDir" tools` — жоден викликач не передає `-WorkDir` (на момент планування —
так; якщо знайдеться, прибрати аргумент і назвати в сумнівах).

- [ ] **Step 5: Прогін повний — зелений** (зокрема `Sync.Merge.Tests.ps1`, `SessionCheck.*`,
  `StorageBranch.Tests.ps1` — вони кличуть `Merge-KitBranchInto` як фікстуру).

- [ ] **Step 6: Контроль уміє впасти** (копія дерева): (а) замінити блок `merge-tree`/`commit-tree`/
  `update-ref` на попередній `git merge --no-ff` → кириличні тести червоні; (б) прибрати перевірку
  `worktree list` → «інший worktree» червоний; (в) прибрати перевірку `storage/*` → тест червоний.
  Три прогони — у звіт.

- [ ] **Step 7: Коміт (контролер)** — `tools/lib/GitMerge.psm1 tools/tests/GitMerge.Tests.ps1`.

---

### Task 5: `verify` — групи регістру, «лише регістр шляху», запобіжник лічильника

**Files:**
- Modify: `tools/lib/TreeCompare.psm1` (`Compare-KitTrees`)
- Modify: `tools/commands/verify.psm1` (`Invoke-KitVerify`)
- Test: `tools/tests/TreeCompare.Tests.ps1`, `tools/tests/Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitTreePaths`, `Get-KitCaseCollisions`, `Test-KitComparableRelativePath`, `Set-KitFakeBranchTree`.
- Produces: `Compare-KitTrees -DumpDir -TreeDir -BinaryPaths [-CaseCollisions <object[]>] [-ClassifyCase]` →
  наявні поля + `CaseCollisions` (масив `{ Paths = string[]; InDump = string|$null }`) + `CaseOnly`
  (масив `{ Dump = string; Tree = string; ContentEqual = bool }`). Без `-ClassifyCase` `CaseOnly`
  порожній і `OnlyInDump`/`OnlyInTree` такі, як раніше — **прев'ю `adopt` поведінки не змінює**
  (`adopt` кличе `Compare-KitTrees` без нових параметрів; клас «лише регістр» прибрав би пару з
  `OnlyInDump`/`OnlyInTree`, і `adopt` хибно сказав би «вже збігається»).

- [ ] **Step 1: Юніт-тести `Compare-KitTrees` (падають)**

У `tools/tests/TreeCompare.Tests.ps1`, у `Describe`, де стоїть тест «п'ять категорій…» (той самий
`BeforeAll`), додати:

```powershell
    It 'CaseCollisions: член групи, що є в дампі, — справжній; група не потрапляє в OnlyIn*/Equal' {
        $d = Join-Path $TestDrive 'cc-dump'; $t = Join-Path $TestDrive 'cc-tree'
        New-Item -ItemType Directory -Path (Join-Path $d 'T'), (Join-Path $t 'T') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'T/ОбразецАнализ.xml') -Value 'x' -NoNewline
        Set-Content -LiteralPath (Join-Path $t 'T/Образецанализ.xml') -Value 'x' -NoNewline   # NTFS: обидва члени — один файл
        $groups = @(, [string[]]@('T/ОбразецАнализ.xml', 'T/Образецанализ.xml'))
        $r = Compare-KitTrees -DumpDir $d -TreeDir $t -BinaryPaths ([System.Collections.Generic.HashSet[string]]::new()) -CaseCollisions $groups
        $r.CaseCollisions | Should -HaveCount 1
        $r.CaseCollisions[0].InDump | Should -Be 'T/ОбразецАнализ.xml'
        $r.OnlyInDump | Should -HaveCount 0
        $r.OnlyInTree | Should -HaveCount 0
    }

    It 'CaseOnly лише з -ClassifyCase: пара «дамп/дерево» різниться тільки регістром' {
        $d = Join-Path $TestDrive 'co-dump'; $t = Join-Path $TestDrive 'co-tree'
        New-Item -ItemType Directory -Path $d, $t -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'SampleaBc.xml') -Value 'same' -NoNewline
        Set-Content -LiteralPath (Join-Path $t 'Sampleabc.xml') -Value 'same' -NoNewline
        $empty = [System.Collections.Generic.HashSet[string]]::new()
        $plain = Compare-KitTrees -DumpDir $d -TreeDir $t -BinaryPaths $empty
        $plain.CaseOnly | Should -HaveCount 0
        $plain.OnlyInDump | Should -Be @('SampleaBc.xml')
        $plain.OnlyInTree | Should -Be @('Sampleabc.xml')
        $cls = Compare-KitTrees -DumpDir $d -TreeDir $t -BinaryPaths $empty -ClassifyCase
        $cls.CaseOnly | Should -HaveCount 1
        $cls.CaseOnly[0].Dump | Should -Be 'SampleaBc.xml'
        $cls.CaseOnly[0].Tree | Should -Be 'Sampleabc.xml'
        $cls.CaseOnly[0].ContentEqual | Should -BeTrue
        $cls.OnlyInDump | Should -HaveCount 0
        $cls.OnlyInTree | Should -HaveCount 0
    }
```

- [ ] **Step 2: Прогін — червоні** (параметрів немає).

- [ ] **Step 3: Реалізація `Compare-KitTrees`** (`tools/lib/TreeCompare.psm1`)

У `param(...)` після `$BinaryPaths` дописати:

```powershell
        # Групи шляхів, що різняться лише регістром (Get-KitCaseCollisions, CaseGuard.psm1), — відносні
        # до TreeDir. На NTFS члени групи вже злились в один файл при експорті, тож порівнювати їх як
        # звичайні шляхи безглуздо: вони звітуються окремим класом (спека 2026-10-04 §4.3).
        [AllowEmptyCollection()][object[]]$CaseCollisions = @(),
        # Клас «лише регістр шляху» — лише на явний запит verify. adopt кличе без нього: пара мусить
        # лишатись в OnlyInDump/OnlyInTree, інакше прев'ю adopt сказало б «вже збігається».
        [switch]$ClassifyCase
```

Після побудови `$all` (`$all.UnionWith($tree)`):

```powershell
    $collided = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $caseCollisions = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $CaseCollisions) {
        foreach ($p in $g) { [void]$collided.Add($p) }
        $real = @($g | Where-Object { $dump.Contains($_) })
        $caseCollisions.Add([pscustomobject]@{ Paths = [string[]]$g; InDump = $(if ($real.Count -gt 0) { $real[0] } else { $null }) })
    }
```

На початку тіла циклу `foreach ($rel in $ordered) {`:

```powershell
        if ($collided.Contains($rel)) { continue }
```

Після циклу, перед `[pscustomobject]@{`:

```powershell
    $caseOnly = [System.Collections.Generic.List[object]]::new()
    if ($ClassifyCase -and $onlyDump.Count -gt 0 -and $onlyTree.Count -gt 0) {
        $treeByFold = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $onlyTree) {
            if (-not $treeByFold.ContainsKey($t)) { $treeByFold[$t] = [System.Collections.Generic.List[string]]::new() }
            $treeByFold[$t].Add($t)
        }
        foreach ($d in @($onlyDump)) {
            if (-not $treeByFold.ContainsKey($d) -or $treeByFold[$d].Count -ne 1) { continue }
            $t = $treeByFold[$d][0]
            $same = [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes((Join-Path $DumpDir $d)), [System.IO.File]::ReadAllBytes((Join-Path $TreeDir $t)))
            $caseOnly.Add([pscustomobject]@{ Dump = $d; Tree = $t; ContentEqual = $same })
            [void]$onlyDump.Remove($d); [void]$onlyTree.Remove($t)
        }
    }
```

У результат дописати `CaseCollisions = $caseCollisions.ToArray()` і `CaseOnly = $caseOnly.ToArray()`.

- [ ] **Step 4: Прогін повний — зелений** (зокрема `Adopt.Tests.ps1` без змін поведінки).

- [ ] **Step 5: Тести `verify` (падають)**

У `tools/tests/Verify.Tests.ps1`, усередині того `Describe`, де стоїть «жоден файл не позначений
binary — verify … доходить до вердикту equal» (його `BeforeAll` імпортує `verify.psm1` і `Preflight`),
додати **вкладений** `Context 'регістр шляхів (спека 2026-10-04 §4.3)' { … }` з власним `BeforeAll`
(Pester 5 не дозволяє другий `BeforeAll` в одному блоці) і трьома тестами нижче всередині нього:

```powershell
    BeforeAll {
        function script:New-VerifyCaseRepo {
            param([string]$Name, [System.Collections.IDictionary]$Files)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files $Files | Out-Null
            $storageDir = Join-Path $TestDrive "$Name-storage"
            New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            $repo
        }
    }

    It 'дерево з кириличним фантомом — не equal, група з позначеним справжнім членом, код 3 (#32)' {
        $repo = New-VerifyCaseRepo 'verify-phantom' ([ordered]@{
            'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'x'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'x'
        })
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path (Join-Path $Target 'T') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'T/ОбразецАнализ.xml') -Value 'x' -NoNewline
            1
        }
        $result = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB'
        $result.Results[0].Verdict | Should -Not -Be 'equal'
        $result.ExitCode | Should -Be 3
        $result.Results[0].Diff.CaseCollisions | Should -HaveCount 1
        $result.Results[0].Diff.CaseCollisions[0].InDump | Should -Be 'T/ОбразецАнализ.xml'
    }

    It 'дерево зі старим ASCII-регістром — клас «лише регістр шляху», не пара додано/видалено' {
        $repo = New-VerifyCaseRepo 'verify-ascii' ([ordered]@{ 'Alpha_SMB/cfe/src/Sampleabc.xml' = 'x' })
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'SampleaBc.xml') -Value 'x' -NoNewline
            1
        }
        $result = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB'
        $result.Results[0].Verdict | Should -Not -Be 'equal'
        $result.Results[0].Diff.CaseOnly | Should -HaveCount 1
        $result.Results[0].Diff.OnlyInDump | Should -HaveCount 0
    }

    It 'запобіжник лічильника: файлів у теці дерева менше, ніж очікує перелік git — виняток, не вердикт' {
        $repo = New-VerifyCaseRepo 'verify-tripwire' ([ordered]@{ 'Alpha_SMB/cfe/src/a.xml' = 'a'; 'Alpha_SMB/cfe/src/b.xml' = 'b' })
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null; 0
        }
        Mock -ModuleName verify Export-KitTree {
            param($RepoRoot, $Ref, $RepoPath, $Destination)
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Destination 'a.xml') -Value 'a' -NoNewline
            2
        }
        { Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB' } | Should -Throw '*verify не ручається за звірку*'
    }
```

Перед асерцією на текст — `grep -rn "не ручається за звірку" tools` має дати лише `verify.psm1`.

- [ ] **Step 6: Прогін — червоні** (verdict `equal` для фантома; `CaseOnly` немає; запобіжника немає).

- [ ] **Step 7: Реалізація `verify.psm1`** (`Invoke-KitVerify`)

Після рядка `Write-Host "  Файлів: у дампі $dumpCount, у дереві '$ref' $treeCount"`:

```powershell
        # Групи регістру — з ПЕРЕЛІКУ git, не з диска (спека 2026-10-04 §4.3): на NTFS члени групи вже
        # злились в один файл при експорті. Запобіжник лічильника: інша розбіжність між переліком і
        # теки дерева — файлова система з'їла шляхи з невідомої причини, і вердикт був би неправдою.
        $prefix = ($src.RepoPath -replace '\\', '/').TrimEnd('/')
        $treeRel = @(Get-KitTreePaths -RepoRoot $root -Ref $ref -Path $prefix |
            ForEach-Object { $_.Substring($prefix.Length).TrimStart('/') } |
            Where-Object { Test-KitComparableRelativePath -RelativePath $_ })
        $collisions = @(Get-KitCaseCollisions -Paths $treeRel)
        $collapsed = 0
        foreach ($g in $collisions) { $collapsed += $g.Count - 1 }
        $onDisk = @(Get-KitRelativeFiles -Root $treeDir).Count
        if ($onDisk -ne ($treeRel.Count - $collapsed)) {
            throw ("Дерево '$ref' після експорту має $onDisk файл(ів), а з переліку git очікувалось $($treeRel.Count - $collapsed) " +
                   "(з поправкою на $($collisions.Count) груп(и) регістр-дублікатів) — файлова система втратила шляхи з невідомої причини; " +
                   'verify не ручається за звірку.')
        }
```

Виклик `Compare-KitTrees` доповнити: `-CaseCollisions $collisions -ClassifyCase`.

`$differs` — додати `+ $diff.CaseCollisions.Count + $diff.CaseOnly.Count`.

Після `Write-KitDiffList -Title "тільки в дереві '$ref'" -Items $diff.OnlyInTree`:

```powershell
        Write-KitDiffList -Title "регістр-дублікати в дереві '$ref' (на Windows — один файл)" -Items @($diff.CaseCollisions | ForEach-Object {
            $real = $_.InDump
            ($_.Paths | ForEach-Object { if ($_ -ceq $real) { "$_ (як у дампі)" } else { "$_ (фантом)" } }) -join ' | '
        })
        Write-KitDiffList -Title 'лише регістр шляху (дамп ↔ дерево)' -Items @($diff.CaseOnly | ForEach-Object {
            "$($_.Dump) ↔ $($_.Tree)" + $(if ($_.ContentEqual) { '' } else { ' (вміст теж різниться)' })
        })
        if ($diff.CaseCollisions.Count -gt 0 -or $diff.CaseOnly.Count -gt 0) {
            Write-Host ("  Увага: розбіжності регістру — дефект дерева git, а не робота для сховища. Злиття такого дерева на Windows " +
                        "впаде з «would be overwritten». Джерело — запис дзеркала kit ≤ 1.3.1 (docs/storage-and-git.md, «Перейменування регістром»).") -ForegroundColor Yellow
        }
```

У тексті вердикту `ref-ahead` нічого не змінювати (рядок «Увага» вище пояснює клас).

- [ ] **Step 8: Прогін повний — зелений.**

- [ ] **Step 9: Контроль уміє впасти** (копія дерева): (а) прибрати `-CaseCollisions $collisions` з
  виклику → тест «фантом» червоний (вердикт `equal`, як у #32); (б) прибрати `throw` запобіжника →
  «запобіжник» червоний. Два прогони — у звіт.

- [ ] **Step 10: Коміт (контролер)** — `tools/lib/TreeCompare.psm1 tools/commands/verify.psm1 tools/tests/TreeCompare.Tests.ps1 tools/tests/Verify.Tests.ps1`.

---

### Task 6: `check` — групи регістру у вершині `storage/*` і в `HEAD`

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` (`Test-KitStorageBranchInvariants`)
- Modify: `tools/commands/check.psm1` (поруч із перевіркою `Test-GitTextPolicy` для джерела)
- Test: `tools/tests/StorageBranch.Tests.ps1` (Describe з `Test-KitStorageBranchInvariants`), `tools/tests/Check.Storage.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitTreePaths`, `Get-KitCaseCollisions`, `Set-KitFakeBranchTree`.
- Produces: знахідка `error` з `Check = 'storage-branch'` (вершина дзеркала) і `Check = 'case-collision'`
  (`HEAD`), текст містить `різняться лише регістром`.

- [ ] **Step 1: Тести (падають)**

`tools/tests/StorageBranch.Tests.ps1`, у `Describe`, де тестується `Test-KitStorageBranchInvariants`
(знайти за іменем функції):

```powershell
    It 'вершина з кириличною парою регістру — error з групою; кириличні шляхи не дають хибних «поза шляхом джерела»' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'inv-case')
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
            'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'x'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'x'
        }) | Out-Null
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        $f | Should -HaveCount 1
        $f[0].Level | Should -Be 'error'
        $f[0].Message | Should -BeLike '*різняться лише регістром*T/ОбразецАнализ.xml | Alpha_SMB/cfe/src/T/Образецанализ.xml*'
    }
```

`tools/tests/Check.Storage.Tests.ps1`:

```powershell
    It 'HEAD з кириличною парою регістру під шляхом джерела — error case-collision, код 1' {
        $repo = New-GoodRepo 'head-case'
        $files = [ordered]@{}
        foreach ($p in @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD)) {
            $files[$p] = [string](git -C $repo show "HEAD:$p" | Out-String)
        }
        $files['Alpha_SMB/cfe/src/T/Образецанализ.xml'] = 'x'
        $files['Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'] = 'x'
        $sha = Set-KitFakeBranchTree -Repo $repo -Branch 'case-branch' -Parent (git -C $repo rev-parse HEAD) -Message 'пара регістру' -Files $files
        # HEAD → нова гілка без checkout робочої копії: check читає лише дерево HEAD.
        git -C $repo symbolic-ref HEAD refs/heads/case-branch
        git -C $repo read-tree $sha
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*у HEAD*різняться лише регістром*'
    }
```

(Біт виконання хуків у `files` втрачається — `Set-KitFakeBranchTree` пише 100644; якщо через це
`check` дає ще й warn про хуки — асерція на конкретний рядок від цього не залежить.)

Перед асерціями — `grep -rn "різняться лише регістром" tools/lib tools/commands`: після кроку 3 —
`StorageBranch.psm1`, `check.psm1`, `verify.psm1`? (у `verify` фраза інша — «регістр-дублікати»);
асерції звужені ще й `*у HEAD*` / шляхами групи.

- [ ] **Step 2: Прогін — червоні.**

- [ ] **Step 3: Реалізація**

`Test-KitStorageBranchInvariants`: блок від `$prefix = ($RepoPath -replace …` до `$stray = …` замінити
на (коментар про `core.quotepath` переписати: тепер перелік іде через `Get-KitTreePaths` — `-z`, UTF-8):

```powershell
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/') + '/'
    # Get-KitTreePaths (CaseGuard): ls-tree -r -z через Invoke-KitGitProcess — UTF-8 незалежно від
    # консолі й без квотування не-ASCII. Колишній голий конвеєр `git ls-tree | …` декодував вивід за
    # кодуванням консолі: на cp866 кирилиця ламалась, і групування регістру нижче давало б хибні 0.
    $tree = @(Get-KitTreePaths -RepoRoot $RepoRoot -Ref $Branch)
    $stray = @($tree | Where-Object { $_ -and -not $_.StartsWith($prefix) })
```

Після блоку `if ($stray.Count -gt 0) { … }`:

```powershell
    $groups = @(Get-KitCaseCollisions -Paths $tree)
    if ($groups.Count -gt 0) {
        $shown = @($groups | Select-Object -First 5 | ForEach-Object { $_ -join ' | ' })
        $more  = $groups.Count - $shown.Count
        $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
            "$Branch`: у вершині $($groups.Count) груп(и) шляхів, що різняться лише регістром (на Windows — один файл; " +
            "злиття в робочу гілку впаде): $($shown -join '; ')$(if ($more -gt 0) { "; …і ще $more" } else { '' }). " +
            'Розбір: docs/storage-and-git.md, «Перейменування регістром».')))
    }
```

`check.psm1` — у тілі `if ($src.Truth -ne 'vendor') {`, одразу після `try/catch` з `Test-GitTextPolicy`:

```powershell
                # Групи регістру в HEAD під шляхом джерела (спека 2026-10-04 §4.4): фантом приходить і
                # ручним `git add -A` після dump/canon, не лише з дзеркала.
                try {
                    if ((Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '-q', '--verify', 'HEAD')).ExitCode -eq 0) {
                        $groups = @(Get-KitCaseCollisions -Paths @(Get-KitTreePaths -RepoRoot $root -Ref 'HEAD' -Path $src.RepoPath))
                        if ($groups.Count -gt 0) {
                            $shown = @($groups | Select-Object -First 5 | ForEach-Object { $_ -join ' | ' })
                            & $add error case-collision ("$tag`: у HEAD $($groups.Count) груп(и) шляхів, що різняться лише регістром: " +
                                "$($shown -join '; ')$(if ($groups.Count -gt 5) { "; …і ще $($groups.Count - 5)" } else { '' }). " +
                                'Зніміть фантом з індексу (git rm --cached -- <шлях>) і закомітьте без --only; розбір — docs/storage-and-git.md, «Перейменування регістром».')
                        }
                    }
                } catch {
                    & $add error case-collision "$tag`: перевірка регістру в HEAD впала: $($_.Exception.Message)"
                }
```

- [ ] **Step 4: Прогін повний — зелений** (зокрема наявні тести інваріантів і «check нічого не змінює»).

- [ ] **Step 5: Контроль уміє впасти** (копія): `OrdinalIgnoreCase` → `Ordinal` у
  `Get-KitCaseCollisions` → обидва нові тести червоні. У звіт.

- [ ] **Step 6: Коміт (контролер)** — `tools/lib/StorageBranch.psm1 tools/commands/check.psm1 tools/tests/StorageBranch.Tests.ps1 tools/tests/Check.Storage.Tests.ps1`.

---

### Task 7: Хук pre-commit — пари регістру в індексі

**Files:**
- Modify: `templates/githooks/pre-commit`
- Test: `tools/tests/Hooks.Tests.ps1`

**Interfaces:**
- Produces: хук відхиляє коміт, якщо в індексі (зокрема тимчасовому індексі `commit --only`) є шляхи,
  що різняться лише регістром; текст `v8storagekit: в індексі є шляхи, що різняться лише регістром`.

- [ ] **Step 1: Тести (падають)**

У `tools/tests/Hooks.Tests.ps1`, поруч із «у звичайній гілці хук мовчить»:

```powershell
    It 'commit --only після кириличного перейменування регістром (фантом воскресає) — відхилено; звичайний коміт проходить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'case-hook')
        Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/T'
        New-Item -ItemType Directory -Path (Join-Path $dir 'Образецанализ/Ext') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Образецанализ.xml') -Value 'xml' -NoNewline
        Set-Content -LiteralPath (Join-Path $dir 'Образецанализ/Ext/T.bin') -Value 'bin' -NoNewline
        git -C $repo add -A; git -C $repo commit -q -m 'старий регістр' 2>&1 | Out-Null
        Remove-Item -LiteralPath $dir -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $dir 'ОбразецАнализ/Ext') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'ОбразецАнализ.xml') -Value 'xml' -NoNewline
        Set-Content -LiteralPath (Join-Path $dir 'ОбразецАнализ/Ext/T.bin') -Value 'bin' -NoNewline
        git -C $repo rm -r -q --cached -- Alpha_SMB/cfe/src/T
        git -C $repo add -- Alpha_SMB/cfe/src/T
        $before = git -C $repo rev-parse HEAD
        $out = git -C $repo commit -q --only -m 'з --only' -- Alpha_SMB/cfe/src/T 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -BeLike '*в індексі є шляхи, що різняться лише регістром*'
        (git -C $repo rev-parse HEAD) | Should -Be $before
        git -C $repo commit -q -m 'без --only' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD -- Alpha_SMB/cfe/src/T) |
            Should -Be @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
    }

    It 'ASCII-імена, що різняться не лише регістром, — хук мовчить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'case-hook-ascii')
        Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Readme.md') -Value 'a'
        Set-Content -LiteralPath (Join-Path $repo 'Readme2.md') -Value 'b'
        git -C $repo add -A; git -C $repo commit -q -m 'різні імена' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
```

`grep -rn "різняться лише регістром" templates/githooks` — після кроку 3 лише `pre-commit`.

- [ ] **Step 2: Прогін — червоний перший тест.**

- [ ] **Step 3: Реалізація** — `templates/githooks/pre-commit`: шапку доповнити рядком про другу
  перевірку; перед фінальним `exit 0` вставити:

```sh
# Шляхи, що різняться лише регістром (спека kit 2026-10-04 §4.4). На Windows це один файл: злиття
# такого дерева в робочу копію впаде, а git із core.ignorecase складає регістр лише ASCII і
# кириличної пари не бачить. Типова причина — `git add -A` або `git commit --only -- <шлях>` після
# перейменування лише регістром (--only перечитує старий регістр із диска). Хук бачить і тимчасовий
# індекс --only (GIT_INDEX_FILE). perl — з Git for Windows: lc на декодованому UTF-8 складає весь
# Юнікод; sh/tr цього не вміють. Без perl перевірка пропускається (захист тримають kit check/verify).
if command -v perl >/dev/null 2>&1; then
  dups=$(git ls-files -z | perl -0 -ne 'chomp; utf8::decode($_); push @{$h{lc $_}}, $_; END { binmode STDOUT, ":encoding(UTF-8)"; for my $k (sort keys %h) { my @g = @{$h{$k}}; print join(" | ", @g), "\n" if @g > 1 } }')
  if [ -n "$dups" ]; then
    echo "v8storagekit: в індексі є шляхи, що різняться лише регістром (на Windows це один файл):" >&2
    echo "$dups" | head -n 5 >&2
    echo "  Коміт відхилено (pre-commit). Зніміть фантом з індексу: git rm --cached -- <шлях>;" >&2
    echo "  дерево після dump/canon комітьте без --only (docs kit: storage-and-git.md, «Перейменування регістром»)." >&2
    exit 1
  fi
else
  echo "v8storagekit: perl не знайдено — перевірку регістру шляхів пропущено (pre-commit)." >&2
fi
```

Файл зберегти з LF (правило `.githooks/* text eol=lf` у шаблоні стосується споживача; у kit
`templates/githooks/pre-commit` — перевірити `git ls-files --eol templates/githooks/pre-commit` до і
після: `i/lf w/lf`).

- [ ] **Step 4: Прогін повний — зелений** (зокрема тести `Test-KitGitHooks` про розбіжність із
  шаблоном — вони порівнюють встановлений файл із шаблоном, а фікстура ставить хук із шаблону).

- [ ] **Step 5: Контроль уміє впасти** (копія): прибрати `exit 1` у блоці → перший тест червоний. У звіт.

- [ ] **Step 6: Коміт (контролер)** — `templates/githooks/pre-commit tools/tests/Hooks.Tests.ps1`.

---

### Task 8: Версія git ≥ 2.38 у `check-environment`

**Files:**
- Modify: `tools/lib/Environment.psm1` (`Get-GitAvailability`, нова `Test-KitGitVersionSupported`)
- Modify: `tools/check-environment.ps1` (рядок перевірки `git`)
- Test: `tools/tests/Environment.Tests.ps1`

**Interfaces:**
- Produces: `Test-KitGitVersionSupported -VersionText <string> [-Minimum <version> = '2.38']` → `[bool]`;
  `Get-GitAvailability` → додатково `Supported` (`[bool]`) і `Minimum` (`'2.38'`).

- [ ] **Step 1: Тести (падають)**

```powershell
Describe 'Test-KitGitVersionSupported (злиття через merge-tree потребує git ≥ 2.38)' {
    It '<Text> → <Ok>' -ForEach @(
        @{ Text = 'git version 2.37.1';             Ok = $false }
        @{ Text = 'git version 2.38.0';             Ok = $true }
        @{ Text = 'git version 2.53.0.windows.1';   Ok = $true }
        @{ Text = 'щось інше';                      Ok = $false }
    ) {
        Test-KitGitVersionSupported -VersionText $Text | Should -Be $Ok
    }

    It 'Get-GitAvailability повідомляє Supported і Minimum' {
        $g = Get-GitAvailability
        $g.Minimum | Should -Be '2.38'
        $g.Supported | Should -BeTrue
    }
}
```

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація**

`Environment.psm1`:

```powershell
function Test-KitGitVersionSupported {
    <#
    .SYNOPSIS
        Чи достатня версія git для kit: злиття дзеркала йде через merge-tree --write-tree (спека 2026-10-04 §4.2).
    .DESCRIPTION
        Мінімум 2.38.0: Documentation/git-merge-tree.txt у тегу v2.38.0 описує --write-tree, --name-only,
        -z і --allow-unrelated-histories, у v2.37.0 — жодного.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionText, [version]$Minimum = '2.38')
    if ($VersionText -notmatch 'git version (?<v>\d+\.\d+(\.\d+)?)') { return $false }
    [version]$Matches['v'] -ge $Minimum
}
```

У `Get-GitAvailability`: до `$result` додати `Supported = $false` і `Minimum = '2.38'`; після
успішного читання версії — `$result.Supported = Test-KitGitVersionSupported -VersionText $result.Version`.
Експортувати `Test-KitGitVersionSupported` (перевірити, як модуль експортує функції — `Export-ModuleMember`
внизу файлу або без нього).

`check-environment.ps1` — рядок перевірки `git` замінити:

```powershell
$git = Get-GitAvailability
$checks.Add((New-EnvironmentCheck -Name "git ≥ $($git.Minimum)" -Category 'Конвеєр' -Ok ($git.Available -and $git.Supported) `
    -Detail $(if (-not $git.Available) { $git.Reason } elseif (-not $git.Supported) { "$($git.Version) — замало: злиття дзеркала потребує git ≥ $($git.Minimum) (merge-tree --write-tree)" } else { $git.Version })))
```

- [ ] **Step 4: Прогін повний — зелений** (зокрема тест «check-environment.ps1: unica не впливає на код
  виходу»).

- [ ] **Step 5: Коміт (контролер)** — `tools/lib/Environment.psm1 tools/check-environment.ps1 tools/tests/Environment.Tests.ps1`.

---

### Task 9: Документи, скіли, follow-ups, версія 1.4.0

**Files:**
- Modify: `docs/storage-and-git.md`, `docs/text-policy.md`, `docs/follow-ups.md`
- Modify: `skills/sync/SKILL.md`, `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md`, `skills/dump/SKILL.md`, `skills/verify/SKILL.md`
- Modify: `.claude-plugin/plugin.json`

Правила (CLAUDE.md користувача й проєкту): правити Edit/Write, не скриптами; постійна документація —
ідеї, інваріанти, причини, **без номерів рядків, лічильників, хешів як доказу стану**; скіли адресують
скіли з префіксом `v8storagekit:`; `${CLAUDE_PLUGIN_ROOT}` — лише всередині шляху.

- [ ] **Step 1: Знайти всі залишки старого механізму злиття**

```bash
grep -rn "_main\|тимчасов[а-я]* worktree\|merge --abort\|незавершен" docs skills README.md templates tools/commands tools/lib
```

Кожен збіг, що описує злиття дзеркала (не `adopt`, не хук `pre-merge-commit` для `storage/*`, не
`adopt`-ів `merge --abort`), переписати під новий механізм. Відомі на момент планування: розділ
«Як `storage/X` зливається у головну гілку» (абзац «Куди фізично йде злиття…») і таблиця «Три теки
`build`» у `docs/storage-and-git.md`; `skills/sync/SKILL.md` (абзац про конфлікт злиття, `git merge
--abort`, код 2); `skills/verify/SKILL.md` (речення «інший HEAD — через тимчасовий worktree. Конфлікт —
злиття відкочено»).

- [ ] **Step 2: `docs/storage-and-git.md`**

(а) Абзац «**Куди фізично йде злиття в головну гілку**» замінити змістом: злиття рахує `merge-tree`
без робочої копії, коміт — `commit-tree` з двома батьками, гілку пересуває `update-ref` з перевіркою
старого значення; якщо ціль вибрана тут і чиста — `read-tree --reset -u HEAD`; брудна (зокрема
невідстежувані файли) — зупинка з переліком; ціль вибрана в іншому worktree — зупинка; ціль не вибрана
ніде — пересувається лише гілка; конфлікт — зупинка, нічого не змінено; причина — розділ
«Перейменування регістром». Прибрати згадку `build/sync/_main/wt` і з таблиці «Три теки `build`».

(б) Новий розділ **«Перейменування регістром»** (після «Як `storage/X` зливається у головну гілку»):
корінь (git складає регістр лише ASCII — `memihash`; NTFS — увесь Юнікод); два наслідки (фантом при
`add -A`, відмова переходу робочої копії навіть на чистому коміті; `commit --only` воскрешає фантом);
інваріант «індекс піддерева ≡ диск» і де він тримається (коміт дзеркала, `adopt`); чому злиття без
робочої копії; що бачать люди й що робити (стару Windows-копію — `git fetch` + `git reset --hard
origin/<гілка>` на чистій копії або свіжий клон; коміт дерева після `dump`/`canon` — `git rm -r
--cached` + `git add` + коміт без `--only`); запобіжники (`check`, `verify`, pre-commit); як роблять
gitsync (`add -A`, той самий дефект фантомів) і ГітКонвертер (явні коміти перейменувань за
`DumpFilesIndex.txt`) і чому в них не видно відмови злиття (не зливають гілку дзеркала в робочу
копію). Без лічильників і номерів рядків.

(в) Розділ «Kit не покладається на git-конфіг машини»: дописати пункти про `core.ignorecase`
(складає лише ASCII — kit не покладається на нього: `rm --cached`, інваріант, `merge-tree`) і про
`core.safecrlf` (порада ГітКонвертера `safecrlf=true` змусила б `add` відмовити на змішаних кінцях
рядків; kit форсує `-c core.safecrlf=false` поруч із `core.autocrlf=false` у коміті дзеркала й
`adopt`, а `adopt` ще й вимагає `-text` до стирання дерева).

- [ ] **Step 3: `docs/text-policy.md`** — новий розділ «Налаштування за порадою 1С:ГітКонвертера»:
порада (Windows `autocrlf=true` + `safecrlf=true`; сам ГітКонвертер — `safecrlf=warn`) — основний
сценарій машини користувача; що робить кожне з дампом платформи (`safecrlf=true` — відмова `add`,
`warn` — незворотна нормалізація до LF); чому kit дає той самий результат (`-text` має пріоритет над
`core.autocrlf`; явні `-c` у коміті дзеркала й `adopt`; `adopt` перевіряє `-text` до стирання); що
репозиторій, створений ГітКонвертером, уже має нормалізовані blob-и (посилання на «Межа
відновлення»).

- [ ] **Step 4: `docs/follow-ups.md`** — новий пункт (наступний номер після останнього): «Явні коміти
перейменувань за `DumpFilesIndex.txt` (як ГітКонвертер)»: що дало б (історія перейменувань об'єктів 1С
за UUID, а не за вмістом); чому не зараз (регістрової вади не знімає — `git mv` при кириличній зміні
регістру на Windows падає; git і так розпізнає `R` за вмістом); рішення брати — за власником.

- [ ] **Step 5: Скіли**

- `skills/sync/SKILL.md` — абзац про конфлікт злиття: конфлікт — зупинка, нічого не змінено, код 2,
  повтор тією самою командою після ручного розбору; додати підказку: якщо після `sync` перемикання
  гілок / `pull` у Windows-копії падає з «would be overwritten» — це перейменування лише регістром, не
  пошкодження: на чистій копії `git fetch` + `git reset --hard origin/<гілка>` (або свіжий клон).
- `skills/reconcile/SKILL.md` — рядок «Якщо `canon` змінив файли — закомітити в `F`: `git commit -am …`»
  замінити: `git rm -r -q --cached -- <шлях джерела>`, `git add -- <шлях джерела>`, перевірити
  `git diff --cached --name-only` (лише цей шлях), `git commit -m "canon: дерево у форматі платформи"`
  — без `-a` і без `--only` (пояснення одним реченням: `-a` не додає нових файлів, `--only` воскрешає
  фантом при перейменуванні регістром); та сама підказка про «would be overwritten».
- `skills/finish/SKILL.md` і `skills/dump/SKILL.md` — там, де описано коміт дерева після `dump`/
  `canon` (знайти `grep -n "commit\|git add" skills/finish/SKILL.md skills/dump/SKILL.md`; якщо кроку
  коміту немає — додати один абзац у місце, де скіл передає дерево людині на коміт), — та сама форма
  коміту.
- `skills/verify/SKILL.md` — речення про тимчасовий worktree/відкіт злиття замінити на новий механізм;
  додати рядок про класи «регістр-дублікати» і «лише регістр шляху» серед розбіжностей.

Після правок: `grep -rnP 'CLAUDE_PLUGIN_ROOT\}(?!/)' skills/` — порожньо.

- [ ] **Step 6: Версія** — `.claude-plugin/plugin.json`: `"version": "1.4.0"`.

- [ ] **Step 7: Прогін повний — зелений** (зокрема `Skills.Tests.ps1`, `Templates.Tests.ps1` і тести,
  що звіряють `kitVersion` фікстури з `plugin.json`).

- [ ] **Step 8: Коміт (контролер)** — явний перелік змінених документів, скілів і `plugin.json`.

---

### Task 10: Рев'ю контуру, приймання, пілот (контролер)

Не бриф субагенту: кроки з дозволом людини виконує контролер (kit-dev, «пишу бриф»).

- [ ] **Step 1: Рев'ю всієї гілки** (kit-dev, «роблю рев'ю»: задачі 1–5 разом будують один механізм).
  Питання рев'ю контуру: (а) чи є стан, у якому всі тести зелені, а фантом проходить у `main` —
  `sync` (задача 2) → злиття (4) → `verify` (5) → `check` (6) на одному синтетичному репо з
  кириличним перейменуванням; (б) чи обидва боки кожного вердикту з незалежних джерел (запобіжник
  лічильника: перелік git проти диска — так; інваріант індексу: `ls-files` проти диска — так);
  (в) `grep -rn "commit.*--only" tools/commands tools/lib` — жодного коміту дерева платформи з `--only`.

- [ ] **Step 2: Повний прогін** `Run-Tests.ps1 -ExcludeTag Integration` — зелений; дослівний
  підсумковий рядок Pester — у звіт.

- [ ] **Step 3: Локальний маркетплейс** (пам'ять «реліз після локального пілоту»): встановити гілку
  як локальний маркетплейс, нова сесія, перевірити наявність `v8storagekit:*` скілів і версію 1.4.0.

- [ ] **Step 4: Пілот interoptica** (з дозволу людини; координація через агента
  `interoptica_unf_runner`): `kit verify -Source base -Ref aba3a85 -Version 396`. `-Version`
  обов'язковий: після переписування історії спільний предок `aba3a85` і `storage/base` — коміт v182,
  і без `-Version` звірка пішла б проти v182. Очікується не `equal` (`mixed`: на дзеркалі після
  merge-base є версії), 17 груп регістр-дублікатів, фантоми позначені, інших розбіжностей — нуль. На
  `-Ref storage/base` (`feadd8f`) — `equal`. Далі реплей v397+ і перше злиття в `feature/onboarding` через kit; `check`
  без `error`.

- [ ] **Step 5: Пілот tehnokrat** (з дозволу людини; агент `tehnokrat-unf-51`): наступний
  `sync -MergeMain -MergeInto feature/onboarding` — `merged`, `status` чистий, `check` без `error`.

- [ ] **Step 6: Реліз** — лише після кроків 4–5 і окремого прохання людини: PR у `main`, злиття, тег
  `v1.4.0`, `ref` у `marketplace.json`.

---

## Трасування «пункт спеки → задача»

| Пункт спеки | Задача |
|---|---|
| §4.1 інваріант «індекс ≡ диск», спільна перевірка | 1 (`Assert-KitIndexMatchesDisk`), 2, 3 |
| §4.1 коміт дзеркала `rm --cached` | 2 |
| §4.1 adopt: `-text` до руйнівного кроку, `rm --cached`, `-c` EOL, без `--only` | 3 |
| §4.1 факт `commit --only` | 3 (adopt), 7 (хук), 9 (скіли) |
| §4.2 злиття без робочої копії, усі кроки 1–6, прибирання `_main` | 4 |
| §4.3 групи з переліку git, запобіжник лічильника, два класи, вивід, вердикт | 5 |
| §4.4 спільна функція | 1 |
| §4.4 check: `storage/*`, `HEAD`, перехід на `Invoke-KitGitProcess` | 6 |
| §4.4 хук `perl` | 7 |
| §4.4 версія git | 4 (запобіжник у злитті), 8 |
| §4.5 скіли, `storage-and-git.md`, `text-policy.md`, `follow-ups.md` | 9 |
| §5 версія 1.4.0 | 9 |
| §6 тести | 1–8 |
| §6 приймання на живому | 10 |
| §3 «ремонту немає» | (нічого не додається; рев'ю контуру перевіряє, що немає) |
