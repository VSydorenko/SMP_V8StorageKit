# C2. `kit adopt`, видимість `origin`, тексти артефактів і `kitVersion` — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** гілка задачі приймає версію сховища заміною з видимою ціною (`kit adopt`), `kit` перестає
бути сліпим до `origin`, підказка про збірку `.cfe` збігається з тим, що Unica справді приймає, а
репозиторій-споживач несе версію структури й дізнається про оновлення плагіна на старті сесії.

**Architecture:** чотири незалежні теми, зведені в один план, бо кожна — дрібна доробка поверх
наявних деталей, а не нова підсистема. `adopt` збирається з готових блоків
(`Export-KitTree`, `Compare-KitTrees`, резервна копія з `canon`); `origin` — два git-виклики;
артефакти — правка трьох текстів без жодної зміни механіки; `kitVersion` — одне поле маніфесту й
одна перевірка `check`.

**Tech Stack:** PowerShell 7, Pester 5, git, платформа 1С 8.3.27.x (у цьому блоці не викликається).

**Spec:** `docs/superpowers/specs/2026-09-17-single-context-and-upgrades-design.md`, §5, §6, §7, §8.

**Попередній блок:** `docs/superpowers/plans/2026-09-17-C1-single-dump-context.md` — Task 4 цього
плану (скіли) спирається на нумерацію кроків `finish`, яку C1 уже змінив. Виконувати після C1.

## Global Constraints

- Мова коду, коментарів, повідомлень і документів — **українська**.
- Тести без `Integration` зелені після **кожної** задачі:
  `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
- Коміт точково: `git add <явний перелік>` + `git commit --only -- <ті самі шляхи>`. Без `-a`/`-A`.
- **Усе йде у версію 1.0.1** — та сама, що вже в `.claude-plugin/plugin.json`, разом із роботою
  архітектора на цій гілці. Бампу немає; реліз і `git push` — **лише за явним проханням
  користувача**, у цей план не входять.
- `kit adopt` мутує робоче дерево, тож без `-Apply` він **нічого не змінює** — це межа kit, не
  побажання.
- Методика — скіл `kit-dev`: `grep` перед новою перевіркою, guard на властивість а не на текст,
  мутація тестів лише на копії дерева, перенумерація документа тягне всі посилання, живий прогін
  після серії правок.
- **Кожна нова глобально видима функція дописується в `$RequiredCommands`**
  (`tools/tests/ModuleImportOrder.Tests.ps1:10`). У цьому плані їх чотири:
  `Get-KitDirtyRecords`, `Backup-KitDirtyFiles` (Task 1), `Get-KitOriginGap` (Task 5),
  `Get-KitPluginVersion` (Task 9). Без цього тест видимості мовчки не перевіряє нових експортів.
- **Фікстури тестів, де команда пише у `build/`, беруть `-WithGitignore`.** `New-KitFakeRepo`
  кладе шаблонний `.gitignore` лише за цим перемикачем, а `build/` ігнорується саме ним. Без
  нього асерція «`git status --porcelain` порожній» падає на власному робочому смітті команди —
  так уже роблять `Canon.Tests.ps1:351` і `Check.Tests.ps1:15`.

---

## File Structure

| Файл | Відповідальність | Що робимо |
|---|---|---|
| `tools/lib/TreeBackup.psm1` | резервна копія незакоміченого перед перезаписом дерева | **створити**: `Get-KitDirtyRecords`, `Backup-KitDirtyFiles` — винесені з `canon.psm1` |
| `tools/commands/canon.psm1` | канонізація дерева | перевести на `TreeBackup.psm1`, видалити дублікати функцій |
| `tools/commands/adopt.psm1` | прийняття версії сховища в гілку | **створити** |
| `tools/lib/module-order.txt` | порядок імпорту | + `TreeBackup` |
| `tools/lib/GitOutput.psm1` | git-хелпери виводу | + `Get-KitOriginGap` |
| `tools/commands/sync.psm1`, `verify.psm1` | команди сховища | + `git fetch`, + підказка про push |
| `tools/commands/session-check.psm1` | сигнал старту сесії | + рядок «позаду origin», **без мережі** |
| `tools/commands/build.psm1` | збірка артефактів | правка тексту підказки `output` |
| `tools/lib/Manifest.psm1` | розбір маніфесту | + обов'язкове поле `kitVersion` |
| `tools/lib/Preflight.psm1` | знахідки й префлайт | + `Get-KitPluginVersion` |
| `tools/commands/check.psm1` | інваріанти | + перевірка `kit-version` |
| `templates/v8storagekit.yaml.example`, `templates/CLAUDE.md` | що роздається споживачам | + `kitVersion`, правка тексту про `output` |
| `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md` | процедури | `git merge` → `kit adopt`; `output` відносний |
| `skills/onboarding/SKILL.md` | підключення репозиторію | пише `kitVersion`; посилання на `references/upgrades.md` |
| `skills/onboarding/references/upgrades.md` | кроки оновлення | **створити** |
| `docs/storage-and-git.md` | як влаштований контур «сховище ↔ git» | `adopt` як команда контуру; `origin` у картині світу |

**Урок C1, який цей план мусить врахувати:** у списку файлів задачі має бути не лише те, що
змінюється, а й **те, що про змінюване розповідає**. C1 переписав команди й скіли, але
`docs/storage-and-git.md` — документ, на який `CLAUDE.md` посилає за питанням «як влаштований
контур», — лишився стверджувати, що `verify` «завжди піднімає власну тимчасову ІБ». Плану цього
файлу в переліку не було, тож туди не подивився ніхто, і злиття гілки заблокувало саме це, а не
код (виправлено комітом `c18c78c`, одинадцять місць). Кожна задача нижче, що додає команду або
змінює картину контуру, тягне за собою цей документ.

---

### Task 1: винести резервну копію з `canon` у спільний модуль

**Files:**
- Create: `tools/lib/TreeBackup.psm1`
- Modify: `tools/commands/canon.psm1` (видалити `Get-KitCanonStatusRecords` і `Backup-KitCanonDirtyFiles`, кликати спільні)
- Modify: `tools/lib/module-order.txt`
- Test: `tools/tests/TreeBackup.Tests.ps1` (створити), `tools/tests/Canon.Tests.ps1` (лишити зеленим)

**Interfaces:**
- Produces:
  - `Get-KitDirtyRecords -RepoRoot <s> -RepoPath <s>` → масив `[pscustomobject]@{ Status; Path; OldPath }`
  - `Backup-KitDirtyFiles -RepoRoot <s> -RepoPath <s> -Records <object[]> -BackupRoot <s> -MustBeUnder <s>` → шлях копії або `$null`
- Consumes: `Invoke-KitGitProcess` (`TreeCompare.psm1`), `Assert-SafeWorkPath` (`PathSafety.psm1`).

**Чому виносимо, а не копіюємо:** `adopt` знищує дерево тим самим способом, що `canon`, і потребує
тієї самої страховки. Друга копія розбору `git status --porcelain -z -uall` розійшлася б із першою
тихо — рівно те, від чого застерігає `kit-dev` (case 5). Обидві функції в `canon.psm1` приватні й
уже мають розгорнуті коментарі про пастки формату `-z` (записи `R`/`C` несуть два шляхи) — їх
переносимо **дослівно**, разом із коментарями.

- [ ] **Step 1: Написати тест на новий модуль**

Створити `tools/tests/TreeBackup.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'TreeBackup.psm1 — знімок незакоміченого перед перезаписом дерева' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeBackup.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'невідстежувані файли потрапляють у перелік поштучно, а не однією текою' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dirty')
        $dir  = Join-Path $repo 'Alpha_SMB/cfe/src/Nova'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir "f$_.xml") -Value "x$_" -Encoding UTF8 }
        $rec = @(Get-KitDirtyRecords -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src')
        $rec.Count | Should -Be 3
    }

    It 'копія зберігає структуру відносно кореня джерела' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'copy')
        $dir  = Join-Path $repo 'Alpha_SMB/cfe/src/Nova'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'f.xml') -Value 'x' -Encoding UTF8
        $rec = @(Get-KitDirtyRecords -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src')
        $dst = Join-Path $TestDrive 'backup'
        Backup-KitDirtyFiles -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -Records $rec -BackupRoot $dst -MustBeUnder $TestDrive | Out-Null
        Join-Path $dst 'Nova/f.xml' | Should -Exist
    }

    It 'порожній перелік — $null і жодного звернення до диска' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'clean')
        $dst  = Join-Path $TestDrive 'backup-none'
        Backup-KitDirtyFiles -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -Records @() -BackupRoot $dst -MustBeUnder $TestDrive |
            Should -BeNullOrEmpty
        $dst | Should -Not -Exist
    }
}
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — файла `tools/lib/TreeBackup.psm1` немає.

- [ ] **Step 3: Створити модуль**

`tools/lib/TreeBackup.psm1`:

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в решті lib-модулів: не перезавантажувати вже наявний
# глобальний PathSafety і не ховати його експорти від глобальної області.
Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Get-KitDirtyRecords { <# … #> }
function Backup-KitDirtyFiles { <# … #> }

Export-ModuleMember -Function Get-KitDirtyRecords, Backup-KitDirtyFiles
```

Тіла обох функцій — **дослівний перенос** із `tools/commands/canon.psm1`
(`Get-KitCanonStatusRecords` → `Get-KitDirtyRecords`, `Backup-KitCanonDirtyFiles` →
`Backup-KitDirtyFiles`), разом із коментарями `.DESCRIPTION`. Змінюються лише імена й згадка
`Invoke-KitCanon` у тексті коментаря на «викликач». Логіку не чіпати: коментарі там описують
куплені живими прогонами пастки (розбір `-z` із записами `R`/`C`, `-uall`, збій git до
`Remove-Item`).

- [ ] **Step 4: Перевести `canon.psm1` на спільні функції**

Видалити з `canon.psm1` обидві приватні функції; у `Invoke-KitCanon` замінити виклики:

```powershell
            $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $t.RepoPath)
```

```powershell
                $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $t.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
```

і другий виклик лічильника `Changed` після дампу:

```powershell
            $changed = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $t.RepoPath).Count
```

- [ ] **Step 5: Додати `TreeBackup` у `module-order.txt`**

Рядком **після** `TreeCompare` (бере `Invoke-KitGitProcess`) і після `PathSafety`:

```
TreeBackup
```

І дописати в шапку-коментар: `TreeBackup — після PathSafety і TreeCompare (Assert-SafeWorkPath, Invoke-KitGitProcess; C2 Task 1)`.

- [ ] **Step 6: Прогнати — має пройти, зокрема наявні тести `canon`**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS. `Canon.Tests.ps1` зелений **без змін у ньому** — це і є доказ, що перенос
дослівний, а не переписаний.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/TreeBackup.psm1 tools/lib/module-order.txt tools/commands/canon.psm1 tools/tests/TreeBackup.Tests.ps1
git commit --only -- tools/lib/TreeBackup.psm1 tools/lib/module-order.txt tools/commands/canon.psm1 tools/tests/TreeBackup.Tests.ps1
```

Повідомлення: `TreeBackup: знімок незакоміченого — спільний для canon і adopt`.

---

### Task 2: `kit adopt` — прев'ю з ціною заміни

**Files:**
- Create: `tools/commands/adopt.psm1`
- Test: `tools/tests/Adopt.Tests.ps1` (створити)

**Interfaces:**
- Consumes: `Select-KitSources`, `Export-KitTree`, `Get-KitRelativeFiles`, `Get-KitBinaryPaths`,
  `Compare-KitTrees`, `Assert-SafeWorkPath`, `Test-KitBranchExists` (`StorageBranch.psm1`).
- Produces: `Invoke-KitAdopt -Context <ctx> [-Workspace <s>] [-Source <s>] [-Ref <s>] [-Apply <bool>]`
  → `[pscustomobject]@{ ExitCode = <int>; Adopted = <масив> }`. Task 3 додає гілку `-Apply`.

**Що таке `adopt` (спека §5):** сховище — істина в останній інстанції, і працює з ним лише людина.
Вона бере артефакт агента, перевіряє в Конфігураторі, можливо бере **частину** механізмів і кладе
у сховище свою версію. Тому агент не зливає своє зі сховищним, а **замінює** своє тим, що у
сховищі. `git merge --no-ff storage/<ключ>`, який стоїть у скілах сьогодні, лишив би в гілці те,
що людина свідомо не взяла.

- [ ] **Step 1: Написати падаючі тести**

Створити `tools/tests/Adopt.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'kit adopt — прев''ю показує ціну заміни' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Adopt {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit adopt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Репозиторій із дзеркалом: у гілці задачі є файл, якого немає у дзеркалі (робота, яку
        # людина у сховище не взяла), і файл, який у дзеркалі інший.
        function script:New-AdoptRepo {
            param([string]$Name)
            # -WithGitignore обов'язковий: adopt пише в <корінь>/build/adopt/<ключ>/mirror, і без
            # шаблонного .gitignore асерція «git status порожній» впаде на робочому смітті самої команди.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitignore
            $src  = Join-Path $repo 'Alpha_SMB/cfe/src'
            Set-Content -LiteralPath (Join-Path $src 'Shared.xml') -Value 'версія гілки' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $src 'OnlyInBranch.xml') -Value 'лише в гілці' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            git -C $repo commit -q -m 'робота агента' 2>&1 | Out-Null
            # Дзеркало: та сама тека, але Shared.xml інший і OnlyInBranch.xml відсутній.
            git -C $repo checkout -q -b 'storage/Alpha_SMB' 2>&1 | Out-Null
            Remove-Item -LiteralPath (Join-Path $src 'OnlyInBranch.xml') -Force
            Set-Content -LiteralPath (Join-Path $src 'Shared.xml') -Value 'версія сховища' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            $env:V8KIT_SYNC = '1'
            git -C $repo commit -q -m 'sync: версія 7' 2>&1 | Out-Null
            Remove-Item Env:\V8KIT_SYNC
            git -C $repo checkout -q main 2>&1 | Out-Null
            $repo
        }
    }

    It 'без -Apply нічого не змінює й називає обидва боки' {
        $repo = New-AdoptRepo -Name 'adopt-preview'
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*Shared.xml*'
        $r.Output   | Should -BeLike '*OnlyInBranch.xml*'
        $r.Output   | Should -BeLike '*-Apply*'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Shared.xml') -Raw).Trim() | Should -Be 'версія гілки'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'дзеркала немає — зупинка з іменем гілки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-no-mirror') -WithHooks
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*storage/Alpha_SMB*'
    }
}
```

- [ ] **Step 2: Прогнати — має впасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `Невідома команда 'adopt'`.

- [ ] **Step 3: Створити `tools/commands/adopt.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt (docs/follow-ups.md §5).

function Invoke-KitAdopt {
    <#
    .SYNOPSIS
        Гілка задачі приймає версію сховища ЗАМІНОЮ піддерева джерела, не злиттям
        (спека 2026-09-17 §5).
    .DESCRIPTION
        Сховище — істина в останній інстанції, і працює з ним лише людина: вона бере артефакт
        агента, перевіряє його в Конфігураторі, можливо бере ЧАСТИНУ механізмів і кладе у сховище
        свою версію. Тому агент не зливає своє зі сховищним — він замінює своє тим, що у сховищі.
        git merge лишив би в гілці те, що людина свідомо не взяла, і воно поїхало б у наступний
        артефакт.

        Прев'ю (без -Apply) — не формальність, а єдиний момент, коли видно ціну заміни: що прийде
        зі сховища і ЩО ЗНИКНЕ З ГІЛКИ. Друге важливіше: це робота агента, яку людина не взяла.
        Вона не втрачається (лишається в історії гілки до заміни), але рішення без неї
        ухвалювалося б наосліп.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [string]$Ref,
        [bool]$Apply
    )

    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — приймати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Adopted = @() }
    }

    $adopted = [System.Collections.Generic.List[object]]::new()

    foreach ($src in $sources) {
        $mirror = if ($Ref) { $Ref } else { $src.Branch }
        if (-not (Test-KitBranchExists -RepoRoot $root -Branch $mirror)) {
            throw "Гілки '$mirror' немає — дзеркало ще не створено. Спершу: kit sync -Source $($src.Key) -Apply."
        }

        Write-Host ''
        Write-Host "Джерело: $($src.Workspace)/$($src.Key)  ·  приймаємо з: $mirror"

        $workDir = Join-Path $root 'build/adopt' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/adopt') -Description "робоча тека adopt $($src.Key)"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $mirrorDir = Join-Path $workDir 'mirror'
        $null = Export-KitTree -RepoRoot $root -Ref $mirror -RepoPath $src.RepoPath -Destination $mirrorDir

        # TreeDir — РОБОЧА КОПІЯ, не експорт гілки: замінюється саме вона, і незакомічене в ній
        # зникне так само, як закомічене. Показати треба фактичний стан, а не стан HEAD.
        $relSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($rel in (@(Get-KitRelativeFiles -Root $mirrorDir) + @(Get-KitRelativeFiles -Root $src.FullPath))) { $relSet.Add($rel) | Out-Null }
        $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths ([string[]]$relSet)
        $diff   = Compare-KitTrees -DumpDir $mirrorDir -TreeDir $src.FullPath -BinaryPaths $binary

        $incoming = @($diff.Content) + @($diff.OnlyInDump)
        Write-Host "  Побайтово рівних: $($diff.Equal) із $($diff.Total)"
        Write-KitAdoptList -Title "прийде зі сховища ($mirror)" -Items $incoming
        Write-KitAdoptList -Title 'ЗНИКНЕ з гілки — робота, яку людина у сховище не взяла' -Items $diff.OnlyInTree -Loud

        $adopted.Add([pscustomobject]@{ Key = $src.Key; Mirror = $mirror; Incoming = $incoming.Count; Dropped = $diff.OnlyInTree.Count; Applied = $false })

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Заміна — з -Apply (дерево джерела буде переписане вмістом дзеркала).' -ForegroundColor Cyan
            continue
        }
    }

    [pscustomobject]@{ ExitCode = 0; Adopted = $adopted.ToArray() }
}

function Write-KitAdoptList {
    param([string]$Title, [AllowEmptyCollection()][string[]]$Items, [switch]$Loud, [int]$Limit = 20)
    if ($Items.Count -eq 0) { return }
    $color = if ($Loud) { 'Yellow' } else { 'Gray' }
    Write-Host "  $Title ($($Items.Count)):" -ForegroundColor $color
    foreach ($i in ($Items | Select-Object -First $Limit)) { Write-Host "    $i" -ForegroundColor $color }
    if ($Items.Count -gt $Limit) { Write-Host "    … ще $($Items.Count - $Limit)" -ForegroundColor $color }
}

Export-ModuleMember -Function Invoke-KitAdopt
```

- [ ] **Step 4: Прогнати — прев'ю має пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS обидва тести Task 2.

- [ ] **Step 5: Коміт**

```bash
git add tools/commands/adopt.psm1 tools/tests/Adopt.Tests.ps1
git commit --only -- tools/commands/adopt.psm1 tools/tests/Adopt.Tests.ps1
```

Повідомлення: `adopt: прев'ю заміни — що прийде зі сховища і що зникне з гілки`.

---

### Task 3: `kit adopt -Apply` — заміна з резервною копією

**Files:**
- Modify: `tools/commands/adopt.psm1`
- Test: `tools/tests/Adopt.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitDirtyRecords`, `Backup-KitDirtyFiles` (Task 1), `Invoke-KitGitProcess`.
- Produces: коміт у поточній гілці з повідомленням
  `adopt: <ключ> ← <гілка дзеркала> (версія <N>)`; поле `Applied = $true` у результаті.

**Чому не `git checkout <гілка> -- <шлях>`:** заміна робиться через `Export-KitTree` у тимчасову
теку плюс копіювання, а не `git checkout`. Причина не формальна: `git checkout -- <шлях>` знищує
незакомічене безповоротно (немає ні в індексі, ні в stash, ні в reflog), і на цьому вже згоріла
чужа робота в спільній робочій копії. `Export-KitTree` уже вживається у `verify`, тобто шлях
перевірений, і резервна копія лишається єдиним запобіжником, який тут потрібен.

- [ ] **Step 1: Написати падаючі тести**

```powershell
    It '-Apply замінює дерево вмістом дзеркала й прибирає зайве' {
        $repo = New-AdoptRepo -Name 'adopt-apply'
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Shared.xml') -Raw).Trim() | Should -Be 'версія сховища'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Not -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        (git -C $repo log -1 --format=%s) | Should -BeLike 'adopt: Alpha_SMB*'
    }

    It '-Apply складає незакомічене в резервну копію перед заміною' {
        $repo = New-AdoptRepo -Name 'adopt-backup'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Draft.xml') -Value 'чернетка' -Encoding UTF8
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.Output | Should -BeLike '*adopt-backup*'
        $copies = @(Get-ChildItem -Path (Join-Path $repo 'Alpha_SMB/build/adopt-backup') -Recurse -Filter 'Draft.xml' -ErrorAction SilentlyContinue)
        $copies.Count | Should -BeGreaterThan 0
    }

    It 'дерево вже збігається з дзеркалом — коміту немає' {
        $repo = New-AdoptRepo -Name 'adopt-noop'
        Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply') | Out-Null
        $before = (git -C $repo rev-parse HEAD)
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.Output | Should -BeLike '*уже збігається*'
        (git -C $repo rev-parse HEAD) | Should -Be $before
    }
```

- [ ] **Step 2: Прогнати — мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — `-Apply` наразі нічого не робить (гілка `continue` у Task 2).

- [ ] **Step 3: Реалізувати заміну**

У `Invoke-KitAdopt`, замість `if (-not $Apply) { … continue }` і далі:

```powershell
        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Заміна — з -Apply (дерево джерела буде переписане вмістом дзеркала).' -ForegroundColor Cyan
            continue
        }

        if ($incoming.Count -eq 0 -and $diff.OnlyInTree.Count -eq 0) {
            Write-Host '  Дерево вже збігається з дзеркалом — заміняти нічого.' -ForegroundColor DarkGray
            continue
        }

        # Страховка перед знищенням: те саме, що робить canon (спека §5). Копія лягає у
        # гітігноровану build/-теку воркспейсу, тож робочої копії не забруднює.
        $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $src.RepoPath)
        if ($dirty.Count -gt 0) {
            $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'adopt-backup' "$($src.Key)-$stamp"))
            $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $src.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
            Write-Host "  $($dirty.Count) незакомічених змін — копія перед заміною у $backupDir" -ForegroundColor Yellow
        }

        Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $root -Description "дерево джерела $($src.Key)"
        if (Test-Path -LiteralPath $src.FullPath) { Remove-Item -LiteralPath $src.FullPath -Recurse -Force }
        New-Item -ItemType Directory -Path $src.FullPath -Force | Out-Null
        Copy-Item -Path (Join-Path $mirrorDir '*') -Destination $src.FullPath -Recurse -Force

        # -A обов'язковий і саме на ШЛЯХУ джерела: він фіксує і нові файли, і ВИДАЛЕННЯ тих,
        # яких у дзеркалі немає. Обмеження pathspec-ом тримає межу «точковий коміт у спільній
        # робочій копії» — чужі зміни поза цим шляхом не потраплять.
        $add = Invoke-KitGitProcess -RepoRoot $root -Arguments @('add', '-A', '--', $src.RepoPath)
        if ($add.ExitCode -ne 0) { throw "git add для '$($src.RepoPath)' завершився з кодом $($add.ExitCode): $($add.Stderr)" }

        $version = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $mirror
        $message = "adopt: $($src.Key) ← $mirror (версія $version)"
        $commit  = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '--only', '-m', $message, '--', $src.RepoPath)
        if ($commit.ExitCode -ne 0) { throw "Коміт заміни не вдався (код $($commit.ExitCode)): $($commit.Stderr)" }

        Write-Host "  Замінено: прийшло $($incoming.Count), зникло $($diff.OnlyInTree.Count). Коміт: $message" -ForegroundColor Green
        $adopted[-1].Applied = $true
```

**Увага:** `$adopted.Add(...)` має статись **до** цього блоку (як у Task 2), інакше `$adopted[-1]`
звертається до порожнього списку.

- [ ] **Step 4: Прогнати — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 5: Мутаційна перевірка страховки (kit-dev, case 7 — на КОПІЇ дерева)**

У копії репозиторію прибрати блок `if ($dirty.Count -gt 0) { … }` — тест «складає незакомічене в
резервну копію» має **впасти**. Якщо лишається зеленим, він перевіряє не те. Копію видалити.

- [ ] **Step 6: Коміт**

```bash
git add tools/commands/adopt.psm1 tools/tests/Adopt.Tests.ps1
git commit --only -- tools/commands/adopt.psm1 tools/tests/Adopt.Tests.ps1
```

Повідомлення: `adopt -Apply: заміна піддерева вмістом дзеркала з копією незакоміченого`.

---

### Task 4: скіли переходять із `git merge` на `kit adopt`

**Files:**
- Modify: `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md`, `docs/storage-and-git.md`,
  `docs/superpowers/specs/2026-09-03-agent-contour-design.md`
- Test: `tools/tests/Skills.Tests.ps1`

**Interfaces:**
- Consumes: `kit adopt` (Task 2, 3).

**Замітати треба всі місця, а не команду.** Про злиття дзеркала в гілку задачі говорять **сім**
місць у цих файлах, і заміна лише двох рядків із командою лишила б документи описувати контур,
якого вже немає — рівно та помилка, що заблокувала злиття C1:

| файл | місце | що з ним |
|---|---|---|
| `skills/reconcile/SKILL.md:8` | «не rebase, не re-derive — **merge** дзеркала» | принцип переформулювати: історія гілки лишається цілою, але дерево джерела **заміняється**, а не зливається |
| `skills/reconcile/SKILL.md:41` | сама команда `git merge --no-ff` | → `kit adopt` (Step 3) |
| `skills/reconcile/SKILL.md:58` | зупинка «`git merge`: конфлікт — це нормально» | конфлікту злиття в цьому сценарії більше не буває — прибрати |
| `skills/reconcile/SKILL.md:59` | зупинка «Хук `pre-merge-commit` відмовляє» | у сценарії `adopt` не спрацьовує — прибрати (хук лишається, він охороняє інше) |
| `skills/finish/SKILL.md:23` | крок 3 | → `kit adopt` (Step 4) |
| `skills/finish/SKILL.md:40` | доповідь гейту: `git diff --stat ORIG_HEAD..HEAD` | після `adopt` немає `ORIG_HEAD` від merge — замінити на два списки прев'ю `adopt` |
| `skills/finish/SKILL.md` крок 8 | тіло PR: «Дзеркала злиті: storage/… до версії N» | «Дзеркала прийняті (`adopt`): storage/… до версії N» |
| `docs/storage-and-git.md:66, 82, 197` | діаграма й два абзаци про `merge storage/X` у `F` | переписати під заміну |

**Критерій «суттєвого» в гейті `finish` теж змінюється.** Пункт (б) — «злиття на кроці 3 мало
конфлікти» — після `adopt` беззмістовний. Замінити на: **«(б) прев'ю `adopt` показало непорожній
список „ЗНИКНЕ з гілки“»**, тобто людина не взяла частину роботи агента. Це сильніший сигнал за
попередній: конфлікт злиття був технічним проксі («щось розійшлося»), а цей — прямий і
семантичний, і саме заради нього `adopt` робився.

Скіл `finish` сам каже, що критерій живе у двох місцях: у ньому й у контурній спеці
(`docs/superpowers/specs/2026-09-03-agent-contour-design.md`, рядки 854–871). Правити **обидва**,
більше ніде.

**Межа, яку цей план НЕ переходить:** злиття дзеркала в **головну** гілку лишається злиттям —
`Invoke-KitMainMerge`, `Merge-KitBranchInto`, звірочний коміт `verify -Apply` і відповідний розділ
`storage-and-git.md` не змінюються. Головна гілка накопичує історію проєкту (PR-и, звірочні
коміти), і там merge доречний. `adopt` замінює прийняття лише в гілку **задачі**, де діє інша
семантика: не накопичення, а відповідність сховищу.

- [ ] **Step 1: Написати падаючий тест**

```powershell
    It 'reconcile і finish приймають версію сховища через adopt, а не git merge' {
        foreach ($s in @('reconcile', 'finish')) {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../skills/$s/SKILL.md") -Raw -Encoding UTF8
            $text | Should -BeLike '*kit.ps1" adopt*'
            $text | Should -Not -BeLike '*git merge --no-ff storage/*'
        }
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — обидва скіли містять `git merge --no-ff storage/<ключ>`.

- [ ] **Step 3: Правка `skills/reconcile/SKILL.md`**

Кроки 4–5 розділу 2 замінити на:

```markdown
4. **Прийняти версію сховища в `F`** — прев'ю, потім заміна:
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" adopt -RepoRoot . -Source <ключ>
   ```
   Прев'ю називає два списки: що **прийде зі сховища** і що **зникне з гілки**. Другий — робота
   агента, якої людина у сховище не взяла; показати його людині **до** заміни, бо саме вона
   вирішує долю цієї роботи. З її згодою — той самий виклик із `-Apply`.

5. **Звіт людині**: що поглинуло сховище (перший список прев'ю) і що лишилось поза ним (другий).
   Порожні обидва — дерево вже збігається зі сховищем, `adopt -Apply` не зробить коміту.
```

- [ ] **Step 4: Правка `skills/finish/SKILL.md`**

Крок 3 («Злиття дзеркал у `F`») замінити на:

```markdown
3. **Прийняти дзеркала в `F`**: для кожного `truth: storage`
   `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" adopt -RepoRoot . -Source <ключ>`
   — прев'ю, показ людині обох списків, і за її згодою `-Apply` (як у `v8storagekit:reconcile`,
   кроки 4–5 розділу 2).
```

- [ ] **Step 4а: Внести `adopt` у документ про контур**

`docs/storage-and-git.md` описує команди контуру й ролі гілок — саме його читає той, хто питає
«як це влаштовано». Нова команда там мусить з'явитись, інакше документ описуватиме контур, у
якому дзеркало потрапляє в гілку задачі злиттям (урок C1, див. шапку плану).

Що додати: рядок у таблицю команд (`adopt` — мутує так, дзеркало → гілка задачі), і в розділ про
ролі гілок — абзац про те, що гілка задачі приймає версію сховища **заміною**, з причиною
(людина кладе у сховище свою версію, можливо частину; злиття лишало б невзяте в гілці).
Переписати також три місця з таблиці вище: діаграму (рядок 66), абзац «переносять у сховище —
`merge storage/X` у `F`» (рядок 82) і рядок «У гілку задачі — так само, командою `merge storage/X`»
(рядок 197). Розділ про злиття в **головну** гілку не чіпати — там merge лишається.

Перевірка, що не лишилось старого опису:

```bash
grep -rn 'merge storage/\|merge --no-ff storage/' docs/ skills/ templates/
```

Expected: влучання лише там, де мова про **головну** гілку (`Invoke-KitMainMerge`, звірочний
коміт) або про історичну поведінку з явною позначкою «до 1.0.1». Жодного — про гілку задачі.

- [ ] **Step 5: Прогнати й перевірити токен**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

```bash
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
```

Expected: порожньо.

- [ ] **Step 6: Коміт**

```bash
git add skills/reconcile/SKILL.md skills/finish/SKILL.md docs/storage-and-git.md tools/tests/Skills.Tests.ps1
git commit --only -- skills/reconcile/SKILL.md skills/finish/SKILL.md docs/storage-and-git.md tools/tests/Skills.Tests.ps1
```

Повідомлення: `скіли: версія сховища приймається adopt-ом із показом ціни, не git merge`.

---

### Task 5: `origin` — `sync` і `verify` бачать віддалений стан

**Files:**
- Modify: `tools/lib/GitOutput.psm1` (+ `Get-KitOriginGap`)
- Modify: `tools/commands/sync.psm1`, `tools/commands/verify.psm1`
- Test: `tools/tests/GitOutput.Tests.ps1`, `tools/tests/Sync.Tests.ps1`

**Interfaces:**
- Produces: `Get-KitOriginGap -RepoRoot <s> -Branch <s>` →
  `[pscustomobject]@{ HasRemote = <bool>; Behind = <int>; Ahead = <int> }`. Використовують Task 5 і 6.

**Чому:** `kit` знає стан сховища й локальних гілок, але сліпий до `origin`. У ішузі #4 дзеркало
відставало на 3 коміти, `sync` упевнено доповів «у сховищі є нові версії», і агент розплутував
неіснуючу проблему. Розв'язалось одним `git fetch`.

- [ ] **Step 1: Написати падаючі тести**

У `tools/tests/GitOutput.Tests.ps1`:

```powershell
    It 'без remote — HasRemote=$false і нулі' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-remote')
        $g = Get-KitOriginGap -RepoRoot $repo -Branch 'main'
        $g.HasRemote | Should -BeFalse
        $g.Behind    | Should -Be 0
    }

    It 'локальна гілка позаду origin — Behind рахується' {
        $up   = Join-Path $TestDrive 'upstream'
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'behind')
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null
        # Коміт лише в origin: клонуємо, комітимо там, фетчимо назад.
        $work = Join-Path $TestDrive 'work'
        git clone -q $up $work 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'new.txt') -Value 'x' -Encoding UTF8
        git -C $work add -A 2>&1 | Out-Null
        git -C $work -c user.email=t@e.invalid -c user.name=T commit -q -m 'з іншої машини' 2>&1 | Out-Null
        git -C $work push -q origin main 2>&1 | Out-Null
        git -C $repo fetch -q origin 2>&1 | Out-Null
        $g = Get-KitOriginGap -RepoRoot $repo -Branch 'main'
        $g.HasRemote | Should -BeTrue
        $g.Behind    | Should -Be 1
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — `Get-KitOriginGap` не визначена.

- [ ] **Step 3: Додати `Get-KitOriginGap` у `GitOutput.psm1`**

```powershell
function Get-KitOriginGap {
    <#
    .SYNOPSIS
        Розходження локальної гілки з origin/<гілка> — БЕЗ мережі (спека 2026-09-17 §6).
    .DESCRIPTION
        Читає лише те, що вже є локально (refs/remotes). Мережу чіпає викликач, і лише там, де
        це дозволено: session-check працює під стелею часу хука старту сесії й fetch не робить.

        Відсутність remote чи remote-tracking гілки — легальний стан (репозиторій без origin,
        гілка ще не пушена), а не помилка: HasRemote=$false і нулі.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)

    $none = [pscustomobject]@{ HasRemote = $false; Behind = 0; Ahead = 0 }
    $ref  = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Branch")
    if ($ref.ExitCode -ne 0) { return $none }

    $counts = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-list', '--left-right', '--count', "$Branch...origin/$Branch")
    if ($counts.ExitCode -ne 0) { return $none }
    $parts = @($counts.Stdout.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne 2) { return $none }

    # left = коміти, які є лише локально (ahead); right = лише в origin (behind).
    [pscustomobject]@{ HasRemote = $true; Ahead = [int]$parts[0]; Behind = [int]$parts[1] }
}
```

Дописати ім'я в `Export-ModuleMember`. `GitOutput` у `module-order.txt` стоїть **після**
`TreeCompare`, тож `Invoke-KitGitProcess` уже доступна — перевірити це перед комітом, і якщо ні,
пересунути рядок.

- [ ] **Step 4: `git fetch` на початку `sync` і `verify`**

У `Invoke-KitSync` і `Invoke-KitVerify`, до циклу по джерелах:

```powershell
    # Fetch нічого не змінює в робочому дереві й не чіпає сховища, а знімає цілий клас хибних
    # висновків: локальне дзеркало, що відстало від origin, читається як «сховище попереду»
    # (ішуз #4). Недоступна мережа чи відсутній remote — попередження, не зупинка: репозиторій
    # без origin легальний.
    # Таймаути обов'язкові, і не заради швидкості: Invoke-KitGitProcess чекає на процес БЕЗ
    # обмеження часу (той самий клас, що docs/follow-ups.md §6 про платформу). Недоступний
    # SSH-хост тримав би прев'ю кілька хвилин на TCP-таймауті, а ключ під passphrase без
    # агента підвісив би його НАЗАВЖДИ — git чекав би вводу, якого в неінтерактивному процесі
    # не буде. BatchMode=yes перетворює це на швидку помилку, яку ми й показуємо попередженням.
    $fetch = Invoke-KitGitProcess -RepoRoot $root -Arguments @(
        '-c', 'core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=5',
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
        'fetch', '--quiet', '--no-tags', 'origin')
    if ($fetch.ExitCode -ne 0) {
        Write-Host "  УВАГА: git fetch origin не вдався (код $($fetch.ExitCode)) — стан origin може бути застарілим." -ForegroundColor Yellow
    }
```

- [ ] **Step 5: Підказка про push у підсумку `sync`**

Після рядка `Перенесено версій: …`:

```powershell
        $gap = Get-KitOriginGap -RepoRoot $root -Branch $src.Branch
        if ($gap.HasRemote -and $gap.Ahead -gt 0) {
            Write-Host ("  Дзеркало попереду origin на {0} — git push origin {1}" -f $gap.Ahead, $src.Branch) -ForegroundColor Yellow
        }
```

`push` kit не робить: межа «`git push` лише за явним проханням» лишається.

- [ ] **Step 6: Прогнати**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS.

- [ ] **Step 7: Коміт**

```bash
git add tools/lib/GitOutput.psm1 tools/commands/sync.psm1 tools/commands/verify.psm1 tools/tests/GitOutput.Tests.ps1
git commit --only -- tools/lib/GitOutput.psm1 tools/commands/sync.psm1 tools/commands/verify.psm1 tools/tests/GitOutput.Tests.ps1
```

Повідомлення: `sync/verify: fetch перед аналізом і підказка про push — origin більше не невидимий`.

---

### Task 6: `session-check` називає відставання від `origin` — без мережі

**Files:**
- Modify: `tools/commands/session-check.psm1`
- Test: `tools/tests/SessionCheck.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitOriginGap` (Task 5).

**Межа:** `session-check` викликається хуком старту сесії під стелею часу — **мережі він не
торкається**. Читає лише наявні remote-tracking refs.

- [ ] **Step 1: Написати падаючі тести**

```powershell
    It 'дзеркало позаду origin — рядок із порадою git fetch' {
        # Дзеркало, яке в origin пішло вперед, а локально лишилось позаду — рівно стан із ішузу #4.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-behind') -WithHooks
        $env:V8KIT_SYNC = '1'
        git -C $repo checkout -q -b 'storage/Alpha_SMB' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/A.xml') -Value 'v1' -Encoding UTF8
        git -C $repo add -A 2>&1 | Out-Null
        git -C $repo commit -q -m 'sync: версія 1' 2>&1 | Out-Null
        git -C $repo checkout -q main 2>&1 | Out-Null

        $up = Join-Path $TestDrive 'sc-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        # Коміт, який зробила «інша машина»: у bare-репозиторій через окрему робочу копію.
        $work = Join-Path $TestDrive 'sc-work'
        git clone -q $up $work 2>&1 | Out-Null
        git -C $work checkout -q 'storage/Alpha_SMB' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'Alpha_SMB/cfe/src/A.xml') -Value 'v2' -Encoding UTF8
        git -C $work add -A 2>&1 | Out-Null
        git -C $work -c user.email=t@e.invalid -c user.name=T commit -q -m 'sync: версія 2' 2>&1 | Out-Null
        git -C $work push -q origin 'storage/Alpha_SMB' 2>&1 | Out-Null
        Remove-Item Env:\V8KIT_SYNC

        # Локальний репозиторій дізнається про це лише фетчем — саме те, чого агент не робив.
        git -C $repo fetch -q origin 2>&1 | Out-Null

        $r = Invoke-SessionCheck -Repo $repo
        $r.Output | Should -BeLike '*позаду origin*'
        $r.Output | Should -BeLike '*git fetch*'
    }

    It 'session-check не викликає git fetch' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-nofetch') -WithHooks -WithGitignore
        # GIT_TRACE пише кожен запуск git у файл рядком виду
        #   trace: built-in: git fetch origin
        # — БЕЗ лапок навколо підкоманди (перевірено на git 2.53). Асерція на "*'fetch'*"
        # (у лапках) була б зелена завжди й не стверджувала б нічого — рівно той клас
        # тавтологічного guard'а, що docs/follow-ups.md §4 називає дефектом культури тестів.
        $trace = Join-Path $TestDrive 'git-trace.log'
        $env:GIT_TRACE = $trace
        Invoke-SessionCheck -Repo $repo | Out-Null
        Remove-Item Env:\GIT_TRACE
        $trace | Should -Exist -Because 'без трасування тест не стверджує нічого'
        (Get-Content -LiteralPath $trace -Raw) | Should -Not -BeLike '*built-in: git fetch*'
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — рядка про origin у виводі немає.

- [ ] **Step 3: Додати рядок у сигнали**

У циклі по джерелах `Invoke-KitSessionCheck`, поруч із обчисленням `$lastMirror`:

```powershell
        # Стан origin — з наявних refs, БЕЗ мережі (спека §6): два джерела правди (сховище й
        # origin) розходяться мовчки, і сліпота до другого дає впевнено хибну картину першого.
        $originGap = $null
        if ($mirror -and -not $gitProblem) {
            $originGap = Get-KitOriginGap -RepoRoot $root -Branch $src.Branch
        }
```

І там, де друкуються рядки джерела, додати:

```powershell
        if ($null -ne $originGap -and $originGap.HasRemote -and $originGap.Behind -gt 0) {
            Write-Host ("- {0}: локальна гілка {1} позаду origin на {2} комітів — git fetch" -f `
                $src.Key, $src.Branch, $originGap.Behind) -ForegroundColor Yellow
        }
```

**Увага:** у `-AsJson` формі верхнього рівня нічого не міняти — контракт «масив сигналів» уже
закріплений тестом; відставання додається окремим полем сигналу лише якщо це не ламає наявний
тест `@($json)[0].Key`.

- [ ] **Step 4: Прогнати**

Expected: PASS.

- [ ] **Step 5: Коміт**

```bash
git add tools/commands/session-check.psm1 tools/tests/SessionCheck.Tests.ps1
git commit --only -- tools/commands/session-check.psm1 tools/tests/SessionCheck.Tests.ps1
```

Повідомлення: `session-check: відставання від origin у сигналах, без жодного мережевого виклику`.

---

### Task 7: підказка про `.cfe` збігається з тим, що Unica приймає

**Files:**
- Modify: `tools/commands/build.psm1`
- Modify: `templates/CLAUDE.md`
- Modify: `skills/finish/SKILL.md`
- Test: `tools/tests/Build.Tests.ps1`, `tools/tests/Templates.Tests.ps1`

**Механіка не змінюється.** `Copy-KitWorkspaceArtifacts` уже забирає `.cf`/`.cfe` з
`<воркспейс>/build/artifacts` у кореневу теку. Правиться лише текст — у трьох місцях однаково.

- [ ] **Step 1: Написати падаючий тест**

У `tools/tests/Build.Tests.ps1`:

```powershell
    It 'підказка про .cfe друкує output, який Unica приймає — відносний до воркспейсу' {
        # Прев'ю (без -Apply) платформи не торкається.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'build-hint') -WithHooks
        $r = Invoke-Build -Repo $repo
        $r.Output | Should -BeLike '*output=build/artifacts/Alpha_SMB.cfe*'
        $r.Output | Should -Not -BeLike "*output=$repo*"
        $r.Output | Should -BeLike '*kit build*забере*'
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — підказка друкує абсолютний `output=<корінь>\build\artifacts\…`.

- [ ] **Step 3: Правка `tools/commands/build.psm1`**

Рядок підказки для розширень замінити на два:

```powershell
    foreach ($e in $extSources) {
        # output — ВІДНОСНИЙ до воркспейсу: Unica відмовляє в записі поза корінь воркспейсу
        # ("refusing to write outside workspace root"), а build/artifacts kit тримає в корені
        # репозиторію, тобто на рівень вище. Абсолютний шлях із кореня заборонений за
        # визначенням, і саме він стояв тут і в шаблоні CLAUDE.md до 1.0.1 (ішуз #5): агент
        # спершу отримував відмову, потім згадував обхід, потім копіював руками — щоразу.
        Write-Host "  .cfe  $($e.Key).cfe — не kit: operation=make Уніки (cwd $($e.Workspace), source-set $($e.Key), extension $($e.Key)) з output=build/artifacts/$($e.Key).cfe" -ForegroundColor DarkGray
        Write-Host "        файл ляже у $($e.Workspace)/build/artifacts/ — kit build -Apply забере його в $outDir" -ForegroundColor DarkGray
    }
```

- [ ] **Step 4: Правка `templates/CLAUDE.md`**

У рядку 44 (`Редагування метаданих … operation=build/make/test/syntax — Unica.`) додати після нього
абзац:

```markdown
**Збірка `.cfe`:** `operation=make` Уніки з `output=build/artifacts/<Ім'я>.cfe` — шлях
**відносний до воркспейсу**, бо поза свій корінь Unica писати відмовляється. Файл лягає у
`<Воркспейс>/build/artifacts/`, звідки `kit build -Apply` забирає його у кореневий
`build/artifacts/` разом із `.epf`.
```

- [ ] **Step 5: Правка `skills/finish/SKILL.md`**

У кроці про артефакти (після перенумерації з C1 — крок 7) замінити текст на:

```markdown
7. **Артефакти**: `.cfe`/`.cf` — `operation=make` Уніки з `output=build/artifacts/<Ім'я>.cfe`
   (відносний до воркспейсу: поза свій корінь Unica не пише). `.epf` і збір усього в кореневий
   `build/artifacts/` — `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" build -RepoRoot . -Apply`.
   `build/` гітігнорований: артефакти не комітяться, їхній перелік іде в PR.
```

- [ ] **Step 6: Прогнати**

Expected: PASS, зокрема `Templates.Tests.ps1`.

- [ ] **Step 7: Коміт**

```bash
git add tools/commands/build.psm1 templates/CLAUDE.md skills/finish/SKILL.md tools/tests/Build.Tests.ps1
git commit --only -- tools/commands/build.psm1 templates/CLAUDE.md skills/finish/SKILL.md tools/tests/Build.Tests.ps1
```

Повідомлення: `артефакти: output відносний до воркспейсу — підказка збігається з поведінкою Unica`.

---

### Task 8: `kitVersion` у маніфесті

**Files:**
- Modify: `tools/lib/Manifest.psm1`
- Modify: `templates/v8storagekit.yaml.example`
- Modify: `skills/onboarding/SKILL.md`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` (фікстура пише поле)
- Test: `tools/tests/Manifest.Tests.ps1`

**Interfaces:**
- Produces: поле `KitVersion` у результаті `Read-KitManifest` — читає Task 9.

**Семантика:** `kitVersion` — «до якої версії плагіна **доведено структуру**», а не «створено в».
Поле оновлюється після кожної міграції.

- [ ] **Step 1: Написати падаючі тести**

```powershell
    It 'kitVersion обов''язковий — маніфест без нього не читається' {
        $text = @('version: 1', 'product: Fake', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }') -join "`n"
        $path = Join-Path $TestDrive 'no-kitversion.yaml'
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        { Read-KitManifest -Path $path } | Should -Throw '*kitVersion*'
    }

    It 'kitVersion не схожий на X.Y.Z — зупинка' {
        $text = @('version: 1', 'kitVersion: остання', 'product: Fake', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }') -join "`n"
        $path = Join-Path $TestDrive 'bad-kitversion.yaml'
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        { Read-KitManifest -Path $path } | Should -Throw '*X.Y.Z*'
    }

    It 'kitVersion доходить до результату' {
        $text = @('version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }') -join "`n"
        $path = Join-Path $TestDrive 'good-kitversion.yaml'
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        (Read-KitManifest -Path $path).KitVersion | Should -Be '1.0.1'
    }
```

- [ ] **Step 2: Прогнати — мають упасти**

Expected: FAIL — `kitVersion` наразі невідомий ключ (`Assert-KitMapKeys` його відкине).

- [ ] **Step 3: Правка `Manifest.psm1`**

```powershell
    Assert-KitMapKeys -Map $m -Allowed @('version', 'kitVersion', 'product', 'client', 'mainBranch', 'workspaces') `
        -Required @('version', 'kitVersion', 'workspaces') -Where $where

    if ([string]$m['version'] -ne '1') {
        throw "$where — version: $($m['version']) не підтримується; kit знає лише version: 1."
    }

    # version: — версія СХЕМИ цього файлу; kitVersion: — до якої версії плагіна доведено
    # СТРУКТУРУ репозиторію (спека 2026-09-17 §8). Різні величини: схема змінюється рідко,
    # структура — з кожним оновленням, яке щось вимагає від споживача. Фолбеку на відсутнє поле
    # немає навмисно (рішення власника 2026-09-17): наявні репозиторії власник позначає сам.
    $kitVersion = [string]$m['kitVersion']
    if ($kitVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw ("$where — kitVersion: '$kitVersion' не схожий на X.Y.Z. Це версія плагіна, до якої доведено " +
               'структуру репозиторію; довести її й записати число — скіл v8storagekit:onboarding.')
    }
```

І в підсумковий об'єкт додати `KitVersion = $kitVersion`.

- [ ] **Step 4: Оновити зразок, фікстуру й `onboarding`**

`templates/v8storagekit.yaml.example` — після `version: 1`:

```yaml
kitVersion: 1.0.1                   # до якої версії плагіна доведено структуру репозиторію
                                    # (не «створено в»: оновлюється після кожної міграції)
```

`tools/tests/fixtures/KitFixtures.psm1` — у `New-KitFakeRepo`, одразу після
`$manifest.Add('version: 1')`:

```powershell
    $manifest.Add('kitVersion: 1.0.1')
```

`skills/onboarding/SKILL.md`, розділ 2 (новий репозиторій) — у перелік того, що пишеться в
маніфест, додати рядок про `kitVersion` поточного плагіна (число береться з
`.claude-plugin/plugin.json` кореня плагіна).

- [ ] **Step 5: Прогнати**

Expected: PASS. Якщо падають інші тести з власним `ManifestText` — дописати в них `kitVersion: 1.0.1`.

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/Manifest.psm1 templates/v8storagekit.yaml.example skills/onboarding/SKILL.md tools/tests/fixtures/KitFixtures.psm1 tools/tests/Manifest.Tests.ps1
git commit --only -- tools/lib/Manifest.psm1 templates/v8storagekit.yaml.example skills/onboarding/SKILL.md tools/tests/fixtures/KitFixtures.psm1 tools/tests/Manifest.Tests.ps1
```

Повідомлення: `маніфест: kitVersion — версія плагіна, до якої доведено структуру репозиторію`.

---

### Task 9: перевірка `kit-version` у `check`

**Files:**
- Modify: `tools/lib/Preflight.psm1` (+ `Get-KitPluginVersion`)
- Modify: `tools/commands/check.psm1`
- Test: `tools/tests/Check.Tests.ps1`

**Interfaces:**
- Produces: `Get-KitPluginVersion` → рядок версії з `.claude-plugin/plugin.json` плагіна;
  знахідка `kit-version` рівня `warn`.

**Доставка повідомлення нічого не коштує:** шим хука вже кличе `session-check`, той уже друкує
`warn` над сигналами, і його вивід іде в контекст сесії — тобто повідомлення бачить перший же
запит користувача.

- [ ] **Step 1: Написати падаючі тести**

```powershell
    It 'структура відстає від плагіна — warn kit-version із порадою onboarding' {
        $repo = New-GoodRepo -Name 'kv-behind'
        (Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw) `
            -replace 'kitVersion: .*', 'kitVersion: 0.9.0' |
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*kit-version*'
        $r.Output | Should -BeLike '*onboarding*'
    }

    It 'плагін старіший за структуру — warn із порадою оновити плагін' {
        $repo = New-GoodRepo -Name 'kv-ahead'
        (Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw) `
            -replace 'kitVersion: .*', 'kitVersion: 99.0.0' |
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*kit-version*'
        $r.Output | Should -BeLike '*claude plugin update*'
    }

    It 'версії збігаються — знахідки немає' {
        $repo = New-GoodRepo -Name 'kv-equal'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*kit-version*'
    }
```

Третій тест вимагає, щоб фікстура писала **поточну** версію плагіна. Якщо в Task 8 у фікстурі
вшито літерал `1.0.1`, а `plugin.json` уже інший — тест упаде й це правильний сигнал: замінити
літерал у фікстурі на читання `plugin.json` тим самим `Get-KitPluginVersion`.

- [ ] **Step 2: Прогнати — мають упасти**

Expected: FAIL — рядка `kit-version` немає.

- [ ] **Step 3: Додати `Get-KitPluginVersion` у `Preflight.psm1`**

```powershell
function Get-KitPluginVersion {
    <#
    .SYNOPSIS
        Версія цього плагіна з .claude-plugin/plugin.json — для порівняння з kitVersion маніфесту.
    .DESCRIPTION
        Шлях рахується від розташування модуля (tools/lib → корінь плагіна), а не від кореня
        репозиторію-споживача: kit виконується З плагіна, ПРОТИ чужого репозиторію.
    #>
    [CmdletBinding()]
    param()
    $path = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.claude-plugin/plugin.json'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return [string]((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).version) }
    catch { return $null }
}
```

Дописати ім'я в `Export-ModuleMember`.

- [ ] **Step 4: Додати перевірку в `check.psm1`**

Поруч із рештою перевірок маніфесту, через наявний скриптблок `$add` (`check.psm1:40`):

```powershell
    # Структура репозиторію-споживача має версію (спека §8). Порівнюємо з версією плагіна, який
    # зараз виконується. Обидва напрямки — warn: репозиторій несуперечливий, але правила
    # розходяться, і мовчати про це означає дати агентові працювати не тими правилами.
    $pluginVersion = Get-KitPluginVersion
    if ($pluginVersion -and $Context.Manifest.KitVersion) {
        $have = [version]$Context.Manifest.KitVersion
        $need = [version]$pluginVersion
        if ($have -lt $need) {
            & $add 'warn' 'kit-version' ("Структуру репозиторію доведено до v$have, а плагін уже v$need — " +
                'кроки оновлення: скіл v8storagekit:onboarding, references/upgrades.md.')
        } elseif ($have -gt $need) {
            & $add 'warn' 'kit-version' ("Структура репозиторію на v$have, а плагін у цьому оточенні старіший — v$need. " +
                'Оновіть плагін (claude plugin update), інакше агент працюватиме застарілими правилами.')
        }
    }
```

Поле `$Context.Manifest` — саме так: `Invoke-KitPreflight` створює його в контексті
(`Preflight.psm1:43`) і заповнює результатом `Read-KitManifest` (`Preflight.psm1:138`), тож
`KitVersion` із Task 8 доходить сюди без додаткової роботи.

- [ ] **Step 5: Прогнати**

Expected: PASS.

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/Preflight.psm1 tools/commands/check.psm1 tools/tests/Check.Tests.ps1
git commit --only -- tools/lib/Preflight.psm1 tools/commands/check.psm1 tools/tests/Check.Tests.ps1
```

Повідомлення: `check: kit-version — структура репозиторію і плагін звіряються в обидва боки`.

---

### Task 10: `references/upgrades.md` і перший рядок таблиці

**Files:**
- Create: `skills/onboarding/references/upgrades.md`
- Modify: `skills/onboarding/SKILL.md` (посилання)
- Test: `tools/tests/Skills.Tests.ps1`

- [ ] **Step 1: Написати падаючий тест**

```powershell
    It 'onboarding посилається на upgrades.md, і той описує перехід на 1.0.1' {
        $skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/onboarding/SKILL.md') -Raw -Encoding UTF8
        $skill | Should -BeLike '*references/upgrades.md*'
        $up = Join-Path $PSScriptRoot '../../skills/onboarding/references/upgrades.md'
        $up | Should -Exist
        (Get-Content -LiteralPath $up -Raw -Encoding UTF8) | Should -BeLike '*1.0.1*'
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — файла немає.

- [ ] **Step 3: Створити `skills/onboarding/references/upgrades.md`**

```markdown
# Оновлення структури репозиторію-споживача

`kit check` порівнює `kitVersion` у `v8storagekit.yaml` з версією плагіна й каже, коли вони
розійшлись. Тут — що саме робити для кожного переходу. Після виконання кроків **записати нову
`kitVersion` у маніфест**: інакше попередження повертатиметься щосесії.

| З версії | На версію | Що робити |
|---|---|---|
| 1.0.0 | 1.0.1 | Див. розділ «1.0.0 → 1.0.1» нижче — дампи переїхали в базу агента, формат дзеркал змінюється одноразово |

Переходи, які нічого не вимагають, теж лишаються в таблиці рядком «дій не потрібно, оновіть
`kitVersion`» — порожній рядок краще за відсутній: він відповідає на питання «а я нічого не
пропустив?».

## 1.0.0 → 1.0.1

**Що змінилось.** Дамп версії сховища виконується в базі агента воркспейсу, а не в тимчасовій ІБ
зі стабом. Розширення тепер серіалізується в контексті своєї базової конфігурації: посилання —
іменами (`Catalog.БанковскиеСчета.EmptyRef`) замість GUID, властивості за замовчуванням опущені.
Через це перший `sync` після оновлення дає один великий коміт зміни формату.

**Кроки.**

1. `claude plugin update` — і **нова сесія**: кеш плагіна інакше може лишитись старим.
2. Для кожного воркспейсу з джерелом `truth: storage` переконатись, що база агента є:
   `kit provision -Workspace <ws> -Apply`, якщо її ще немає.
3. `operation=build` Уніки (`cwd` = воркспейс) — наповнити базу з поточного дерева.
4. `kit sync -RepoRoot . -Apply` — дзеркало отримує один коміт зміни формату. Історію дзеркала
   **не переписуємо**: старі коміти лишаються у старому форматі, і це нормально.
5. Для кожної живої гілки задачі — `kit adopt -Source <ключ>` (прев'ю, показ людині обох списків)
   і `-Apply` з її згоди. Для головної гілки — `kit verify -Ref <mainBranch>`, очікується `equal`.
6. Записати `kitVersion: 1.0.1` у `v8storagekit.yaml` і закомітити.

**Чого очікувати у виводі.** Великий diff на першому `sync` — саме зміна формату, не робота
колеги: зникають рядки `<Behavior>Usual</Behavior>`, GUID-и в `DesignTimeRef` стають іменами.
Якщо крім цього видно змістовні правки — це вже робота зі сховища, розбирати звичайним порядком.
```

- [ ] **Step 4: Посилання в `SKILL.md`**

У розділ 4 («Далі») скіла `onboarding` додати:

```markdown
**Репозиторій уже підключений, а `check` каже `kit-version`?** Це не онбординг, а оновлення
структури під новий плагін — кроки кожного переходу в `references/upgrades.md`.
```

- [ ] **Step 5: Прогнати**

Expected: PASS.

- [ ] **Step 6: Коміт**

```bash
git add skills/onboarding/references/upgrades.md skills/onboarding/SKILL.md tools/tests/Skills.Tests.ps1
git commit --only -- skills/onboarding/references/upgrades.md skills/onboarding/SKILL.md tools/tests/Skills.Tests.ps1
```

Повідомлення: `onboarding: upgrades.md — кроки переходу 1.0.0 → 1.0.1`.

---

### Task 11: колізія «база агента = дев-база людини» перестає бути невидимою в `check`

**Files:**
- Modify: `tools/commands/check.psm1` (рядок 57 — `catch { continue }` у блоці `agent-base-required`)
- Test: `tools/tests/Check.Tests.ps1`

**Чому це тут, а не у `follow-ups`:** це **дефект плану C1**, не нова ідея. Task 5 того плану
задала текст `catch { continue }` з коментарем «збіг із базою людини вже описує інша знахідка» —
і припущення виявилось хибним. Знахідка `local-audit` (`check.psm1:370–399`) читає **лише**
`v8project.local.yaml` (`Read-V8ProjectLocalInfobase -Path $localPath`), тоді як
`Resolve-V8AgentInfobase` бере підключення з **обох** джерел: спершу `.local`, з фолбеком на
закомічений `v8project.yaml`. Отже для репозиторію, де `infobase:` стоїть прямо у `v8project.yaml`,
колізію не показує **жодна** знахідка `check`.

**Межа дефекту названа точно:** це прогалина в **завчасному попередженні**, не в безпеці. Сам
запобіжник у `Resolve-KitAgentBase` кидає безумовно, тож запису в базу людини не станеться за
жодних умов — `sync`, `canon` і `provision` зупиняться в момент запуску. Ціна — людина дізнається
про колізію тоді, коли вже запустила команду, а не на старті сесії.

- [ ] **Step 1: Написати падаючий тест**

```powershell
    It 'база агента з v8project.yaml (без .local) збігається з дев-базою людини — check це каже' {
        $repo = New-GoodRepo -Name 'agent-base-collision'
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        # Дев-база людини в накладці вказує на ту саму теку, що база агента у ЗАКОМІЧЕНОМУ
        # v8project.yaml — жодного v8project.local.yaml у репозиторії немає.
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*дев-базою людини*'
    }
```

- [ ] **Step 2: Прогнати — має впасти**

Expected: FAIL — `check` мовчить: `Resolve-KitAgentBase` кидає, а `catch { continue }` ковтає.

- [ ] **Step 3: Перетворити виняток на знахідку замість того, щоб його ковтати**

У `tools/commands/check.psm1`, у блоці `agent-base-required`:

```powershell
            $ab = $null
            try { $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws }
            catch {
                # Resolve-KitAgentBase кидає рівно на одному: база агента виявилась дев-базою
                # людини (принцип 3). Ковтати це не можна — попередній коментар тут стверджував,
                # що «збіг описує інша знахідка», і це було хибно: local-audit звіряє ЛИШЕ
                # v8project.local.yaml, а підключення законно буває й у закоміченому
                # v8project.yaml. Тоді про колізію не казав НІХТО, аж доки команда не падала.
                & $add 'error' 'agent-base-required' "$($ws.Path): $($_.Exception.Message)"
                continue
            }
```

Рівень `error`, не `warn`: це не «ще не готово до `sync`», а суперечність конфігурації, яку треба
розв'язати до будь-якої роботи — і всі команди на ній однаково зупиняються.

- [ ] **Step 4: Прогнати**

Expected: PASS. Наявний тест «база агента на місці — знахідки немає» має лишитись зеленим: у
ньому колізії немає, тож `Resolve-KitAgentBase` не кидає.

- [ ] **Step 5: Коміт**

```bash
git add tools/commands/check.psm1 tools/tests/Check.Tests.ps1
git commit --only -- tools/commands/check.psm1 tools/tests/Check.Tests.ps1
```

Повідомлення: `check: колізія бази агента з базою людини більше не мовчить, коли infobase у v8project.yaml`.

---

## Фінальна перевірка блоку

- [ ] **Повний прогін без `Integration`**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: усе зелене.

- [ ] **Живий прогін диспетчера** (kit-dev, case 19):

```bash
pwsh -NoProfile -File tools/kit.ps1 2>&1 | head -3
```

Expected: у переліку доступних команд є `adopt` — доказ, що новий командний модуль підхоплюється
диспетчером без реєстрації деінде.

- [ ] **Перевірки правил репозиторію** (мають бути порожні):

```bash
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
test -e hooks/hooks.json && echo "ПОМИЛКА: hooks.json у плагіні"
```

- [ ] **Версія плагіна** — переконатись, що `.claude-plugin/plugin.json` містить `1.0.1` і бамп
      **не потрібен**: уся ця робота виходить у тій самій версії, що й правка архітектора та
      коміт `29978e6`.

```bash
grep '"version"' .claude-plugin/plugin.json
```

- [ ] **Реліз — не в цьому плані.** Тег, `gh release` і оновлення `ref` у
      `.claude-plugin/marketplace.json` (він прив'язаний до тега) — **лише за явним проханням
      користувача**, окремим кроком після того, як він прийме роботу.

---

## Що цей блок НЕ робить

- не чіпає того, в якій базі виконуються дампи — це блок C1;
- не піднімає версію плагіна (вона вже 1.0.1) і не робить релізу;
- не видаляє стаба `tools/assets/empty-extension`, `New-KitStorageInfobase` і
  `New-ExtensionInfobase` — після живого прогону на кількох репозиторіях (спека §2);
- не перевіряє зворотності дампу з наповненої бази — спостерігаємо на живому використанні
  (спека §10 п.1).
