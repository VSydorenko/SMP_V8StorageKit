# Версія сховища, яку основна платформа не вивантажує — план реалізації (1.3.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** коли основна платформа (8.3.27) не вивантажує конкретну версію основної конфігурації,
`sync` зупиняється з поясненням і переліком фактично встановлених платформ, а зі згоди людини —
вивантажує цю одну версію обраною платформою (`-DumpPlatform`) або свідомо її пропускає
(`-SkipVersion`), і реплей іде далі.

**Architecture:** `V8.psm1` дізнається, які платформи встановлено (`Get-KitInstalledPlatforms`).
`Invoke-KitStorageCheckout` на збої вивантаження після успішного `UpdateCfg` кидає розпізнаваний
виняток; текст для людини будують викликачі (`sync` — з командами, `verify` — без). Новий крок
`Invoke-KitStorageCheckoutViaPlatform` зберігає конфігурацію бази агента в `.cf` основною
платформою і вивантажує її обраною платформою в тимчасовій файловій ІБ. Трейлери
`Storage-Dump-Platform` і `Storage-Skipped` пише `New-KitStorageCommitMessage`.

**Tech Stack:** PowerShell 7, Pester 5, git, платформа 1С 8.3.27.x (у тестах мокується; живий
прогін — пілот `interoptica_unf`, за підтвердженням користувача).

**Spec:** `docs/superpowers/specs/2026-10-01-dump-platform-fallback-design.md`, редакція коміту
**`cebd9ed`** (§6.1 — відповіді архітектора на 6 питань автора плану). Архітектор рішення — сесія
`configuration-storage-spec`; автор плану й консультант виконавця — `smp-v8storagekit-59`.

## Global Constraints

- Мова коду, коментарів, повідомлень, комітів і документів — **українська**.
- Тести без `Integration` зелені після **кожної** задачі:
  `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`. Повні прогони в
  спільному дереві — **послідовно**: `Run-Tests.ps1` на старті стирає спільну `build/test-run`
  (`docs/follow-ups.md` §26), два одночасні прогони гублять результат.
- Коміт точково: `git add <явний перелік>` + `git commit --only -m "<…>" -- <ті самі шляхи>`;
  комітить контролер, не субагент. Проєктні константи брифа —
  `.claude/skills/kit-dev/references/subagent-brief.md` (давати шляхом).
- Версія — **1.3.1**, піднімається один раз, у Task 5. Реліз і `git push` — лише за явним
  проханням користувача.
- **Сховище — лише читання.** Обрана платформа не відкриває ні сховища, ні серверної бази агента —
  лише тимчасову файлову ІБ під `build/sync/<ключ>/alt-ib` (спека §4.3 п.3).
- **Лише явно:** `-DumpPlatform` і `-SkipVersion` ніколи не вмикаються автоматично; кожен — рівно
  для однієї версії, рівно для одного джерела (`-Source` обов'язковий, §6.1.4); взаємовиключні
  (§6.1.5).
- **Шум формату прийнято свідомо** (спека §3): коміт версії, вивантаженої іншою платформою, міняє
  формат на тисячах файлів, наступний повертає. Нормалізувати формат текстом — заборонено (це був
  би власний конвертер, §2).
- Принцип «кожна версія — повне вивантаження в спорожнену теку» діє й для іншої платформи (§4.5).
- Методика — скіл `kit-dev`: `grep` перед новою перевіркою; фраза з виводу в тесті — `grep` на
  унікальність по `tools/commands/` і `tools/lib/`; кожна нова перевірка — з мутацією **на копії
  дерева**, доказ — текст падіння; адресувати код іменем функції, не номером рядка.
- Нова експортована функція lib-модуля → `$RequiredCommands`
  (`tools/tests/ModuleImportOrder.Tests.ps1`): `Get-KitInstalledPlatforms`,
  `Invoke-KitStorageCheckoutViaPlatform`, `Test-KitDumpFailure`.
- Постійні тексти (скіли, `docs/storage-and-git.md`) — без кількостей і результатів прогонів
  (правило «Зміст постійної документації» глобального `CLAUDE.md`); числа живуть у спеці §2.

## Review Focus

1. **Збій вивантаження «база зайнята» або ліцензія** — не §4.1, а наявні зупинки
   (`Assert-V8InfobaseNotBusy`, `Assert-NoLicenseProblem` у `Invoke-V8Designer`). Тест — Task 2.
2. **Збій `UpdateCfg` (не вивантаження)** — не §4.1: розпізнаваний виняток лише для збою
   `/DumpConfigToFiles` **після успішного** `UpdateCfg`. Тест — Task 2.
3. **Дзеркало після зупинки §4.1** — коміти попередніх версій прогону лишаються, версії N коміту
   немає, worktree прибрано. Тест — Task 4.
4. **`-DumpPlatform` з версією основної платформи або відсутньою в оточенні; `-SkipVersion` на
   останній версії звіту; `-ForVersion` ≠ першої неперенесеної** — зупинка до `UpdateCfg`, жодного
   виклику платформи для оновлення. Тести — Task 4.
5. **`verify`, коли merge-base припадає на версію, яку основна платформа не вивантажує** — текст
   без порад `sync -DumpPlatform` (§6.1.1). Тест — Task 4.

---

## Як виконувати цей план

- Рядок `**Ризик:**` визначає рев'ю: `механічна` — одне на дешевій моделі; `спільний код` — одне
  на сильній; `властивість безпеки` — два, друге вузьке. За замовчуванням — одне.
- Код у плані — **ескіз**: рев'ю ставиться до нього як до свіжого коду виконавця; відхилення —
  мінімальне й назване в сумнівах із доказом.
- Текст задачі **заморожений** на час її виконання; уточнення архітектора — «хвіст» на межі задач.
- Задачі — по черзі (Task 4 спирається на 1–3). `Integration` — лише пілот, за підтвердженням
  користувача, виконує контролер (у бриф не входить).

---

## File Structure

| Файл | Відповідальність | Що робимо |
|---|---|---|
| `tools/lib/V8.psm1` | платформа | `Get-KitInstalledPlatforms`; `Get-V8Path` шукає явну `-Version` в x64 і x86 (Task 1) |
| `tools/lib/StoragePlatform.psm1` | версія сховища → тека | спільне `UpdateCfg`; розпізнаваний виняток збою вивантаження; `Invoke-KitStorageCheckoutViaPlatform` (Task 2) |
| `tools/lib/StorageBranch.psm1` | повідомлення коміту | `New-KitStorageCommitMessage -DumpPlatform -MainPlatform -SkippedVersion` (Task 3) |
| `tools/commands/sync.psm1` | реплей | параметри, перевірки, текст §4.1, гілка іншої платформи, пропуск (Task 4) |
| `tools/commands/verify.psm1` | звірка | текст §6.1.1 на розпізнаваному винятку (Task 4) |
| `tools/kit.ps1` | диспетчер | перевірити, що `-ForVersion`/`-SkipVersion` без значення зупиняються, `-DumpPlatform` приймає рядок; змін коду, ймовірно, не треба (Task 4) |
| `skills/sync/SKILL.md`, `docs/storage-and-git.md`, `skills/onboarding/references/upgrades.md`, `.claude-plugin/plugin.json` | тексти й версія | Task 5 |

---

### Task 1: перелік встановлених платформ і пошук явної версії

**Ризик:** механічна (одне рев'ю, дешева модель).

**Files:**
- Modify: `tools/lib/V8.psm1` (`Get-V8Path`; нова `Get-KitInstalledPlatforms`)
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1`
- Test: `tools/tests/V8.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-KitInstalledPlatforms [-Roots <hashtable>]` → масив `[pscustomobject]@{ Version = '8.3.25.1445'; Arch = 'x64'|'x86'; Path = '<…>\bin\1cv8.exe' }`,
    відсортований за версією (як `[version]`) за спаданням, у межах версії — x64 перед x86. Типово
    `Roots = [ordered]@{ x64 = 'C:\Program Files\1cv8'; x86 = 'C:\Program Files (x86)\1cv8' }`;
    параметр — для тестів (`$TestDrive`). Тека береться, лише коли її ім'я — чотири числа через
    крапку **і** фактично існує `bin\1cv8.exe` (§4.2: «фактично існує»).
  - `Get-V8Path -Version <v> [-Roots …]` — коли `-Version` передано **явно**
    (`$PSBoundParameters.ContainsKey('Version')`), шукає точну версію в обох коренях (x64 першим) і,
    не знайшовши, кидає з переліком `Get-KitInstalledPlatforms`. Без явної `-Version` — поведінка
    без змін (8.3.27.1644 → будь-яка 8.3.27.* у x64), §6.1.6.

- [ ] **Step 1: Тести**

У `V8.Tests.ps1`:

```powershell
    Context 'Get-KitInstalledPlatforms — платформи оточення (спека 1.3.1 §4.2)' {
        BeforeAll {
            function script:New-FakePlatform {
                param([string]$Root, [string]$Version, [switch]$NoExe)
                $bin = Join-Path $Root "$Version\bin"
                New-Item -ItemType Directory -Path $bin -Force | Out-Null
                if (-not $NoExe) { Set-Content -LiteralPath (Join-Path $bin '1cv8.exe') -Value 'stub' -Encoding ascii }
            }
            $script:X64 = Join-Path $TestDrive 'pf'; $script:X86 = Join-Path $TestDrive 'pf86'
            New-FakePlatform -Root $script:X64 -Version '8.3.27.1644'
            New-FakePlatform -Root $script:X64 -Version '8.3.25.1445'
            New-FakePlatform -Root $script:X86 -Version '8.3.25.1445'
            New-FakePlatform -Root $script:X86 -Version '8.3.24.1000'
            New-FakePlatform -Root $script:X64 -Version '8.3.23.9999' -NoExe          # тека без 1cv8.exe — не платформа
            New-Item -ItemType Directory -Path (Join-Path $script:X64 'common') -Force | Out-Null   # не версія
            $script:Roots = [ordered]@{ x64 = $script:X64; x86 = $script:X86 }
        }

        It 'лише теки-версії з фактичним bin\1cv8.exe; обидві розрядності; за спаданням версії, x64 першим' {
            $p = @(Get-KitInstalledPlatforms -Roots $script:Roots)
            @($p | ForEach-Object { "$($_.Version)/$($_.Arch)" }) | Should -Be @('8.3.27.1644/x64', '8.3.25.1445/x64', '8.3.25.1445/x86', '8.3.24.1000/x86')
            $p[0].Path | Should -Be (Join-Path $script:X64 '8.3.27.1644\bin\1cv8.exe')
        }

        It 'коренів немає — порожній масив, не $null і не виняток' {
            $p = Get-KitInstalledPlatforms -Roots ([ordered]@{ x64 = (Join-Path $TestDrive 'none'); x86 = (Join-Path $TestDrive 'none86') })
            , $p | Should -BeOfType [object[]]
            $p.Count | Should -Be 0
        }

        It 'Get-V8Path з явною версією знаходить її в x86, коли в x64 її немає' {
            Get-V8Path -Version '8.3.24.1000' -Roots $script:Roots | Should -Be (Join-Path $script:X86 '8.3.24.1000\bin\1cv8.exe')
        }

        It 'Get-V8Path з явною версією, яка є в обох — x64' {
            Get-V8Path -Version '8.3.25.1445' -Roots $script:Roots | Should -Be (Join-Path $script:X64 '8.3.25.1445\bin\1cv8.exe')
        }

        It 'Get-V8Path з явною відсутньою версією — зупинка з переліком наявних' {
            { Get-V8Path -Version '8.3.22.1' -Roots $script:Roots } | Should -Throw '*8.3.25.1445*'
        }
    }
```

(Типова гілка `Get-V8Path` без `-Version` дивиться на справжній `C:\Program Files\1cv8` — її
наявні тести не змінюються; нових тестів на неї не писати, вона не змінюється.)

- [ ] **Step 2: Прогнати — має впасти.**

- [ ] **Step 3: Реалізація**

```powershell
$script:DefaultPlatformRoots = [ordered]@{ x64 = 'C:\Program Files\1cv8'; x86 = 'C:\Program Files (x86)\1cv8' }

function Get-KitInstalledPlatforms {
    <#
    .SYNOPSIS
        Платформи 1С, фактично встановлені в оточенні (спека 1.3.1 §4.2): теки-версії під x64- і
        x86-коренем, у яких існує bin\1cv8.exe. Тека без exe — залишок деінсталяції, не платформа.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Roots = $script:DefaultPlatformRoots)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($arch in @($Roots.Keys)) {
        $root = $Roots[$arch]
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            $exe = Join-Path $d.FullName 'bin\1cv8.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $found.Add([pscustomobject]@{ Version = $d.Name; Arch = $arch; Path = $exe })
            }
        }
    }
    $archRank = @{ x64 = 0; x86 = 1 }
    , @($found | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { $archRank[$_.Arch] } })
}
```

`Get-V8Path`: додати `[System.Collections.IDictionary]$Roots = $script:DefaultPlatformRoots`; на
початку тіла:

```powershell
    if ($PSBoundParameters.ContainsKey('Version')) {
        # Явна версія (спека 1.3.1 §6.1.6) — точний збіг у будь-якому корені, x64 першим. Типовий
        # пошук нижче (без -Version) лишається як був: лише x64, гілка 8.3.27.
        $exact = @(Get-KitInstalledPlatforms -Roots $Roots | Where-Object Version -eq $Version) | Select-Object -First 1
        if ($exact) { return $exact.Path }
        $have = @(Get-KitInstalledPlatforms -Roots $Roots | ForEach-Object { "$($_.Version) ($($_.Arch))" })
        throw "Платформи $Version в оточенні немає. Встановлено: $(if ($have) { $have -join ', ' } else { 'жодної' })."
    }
```

Перевірити `grep -rn "Get-V8Path -Version" tools/`: якщо наявний код уже передає `-Version` явно
типовим значенням — нова гілка змінила б його поведінку; тоді назвати в сумнівах і узгодити з
консультантом. Дописати `Get-KitInstalledPlatforms` в `Export-ModuleMember` і `$RequiredCommands`.

- [ ] **Step 4: Прогнати — має пройти.**
- [ ] **Step 5: Мутація (на копії):** прибрати перевірку `Test-Path … 1cv8.exe` — перший тест червоний (`8.3.23.9999` з'явиться).
- [ ] **Step 6: Коміт**

```bash
git add tools/lib/V8.psm1 tools/tests/V8.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1
git commit --only -m "V8: перелік встановлених платформ (x64 і x86), Get-V8Path шукає явну версію в обох коренях" -- tools/lib/V8.psm1 tools/tests/V8.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1
```

---

### Task 2: розпізнаваний виняток збою вивантаження і крок іншої платформи

**Ризик:** спільний код (одне рев'ю на сильній моделі; окреме питання — «чи може обрана платформа
відкрити сховище або базу агента»).

**Files:**
- Modify: `tools/lib/StoragePlatform.psm1` (`Invoke-KitStorageCheckout`; нові приватна `Invoke-KitStorageUpdate`, експортовані `Test-KitDumpFailure`, `Invoke-KitStorageCheckoutViaPlatform`)
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1`
- Test: `tools/tests/StoragePlatform.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-V8Designer … -V8Path`, `New-V8FileInfobase -Path -MustBeUnder -V8Path`, `Get-V8Path` (Task 1).
- Produces:
  - Виняток збою вивантаження: `[System.InvalidOperationException]` з повідомленням
    `Вивантаження версії <N> не вдалося: <вивід>` (той самий текст, що зараз — наявні тести й
    тексти, що на нього спираються, лишаються чинними) і полями `Exception.Data`:
    `KitDumpFailure = $true`, `Version = <int>`, `PlatformPath = <шлях 1cv8.exe основної платформи>`,
    `Output = <сирий вивід>`.
  - `Test-KitDumpFailure -ErrorRecord <ErrorRecord>` → `[bool]` — чи це той самий виняток (одне місце
    розпізнавання для `sync` і `verify`).
  - `Invoke-KitStorageCheckoutViaPlatform -IbSwitch -Source -Version -Target -MustBeUnder -WorkDir -AltV8Path [-User]`
    → кількість файлів дампу (як `Invoke-KitStorageCheckout`).

**Контракт (спека §4.1, §4.3, §6.1.1):**
- Розпізнаваний виняток — лише коли `UpdateCfg` повернув 0, а `/DumpConfigToFiles` — ненульовий
  код. Перед ним — `Assert-V8InfobaseNotBusy` на виводі дампу (база зайнята — своя зупинка).
  Ліцензія вже кидає `Invoke-V8Designer` (`Assert-NoLicenseProblem`) — до нашого коду не доходить.
- `Invoke-KitStorageCheckoutViaPlatform`, по кроках:
  1. основна платформа: той самий `UpdateCfg -v N` (спільна `Invoke-KitStorageUpdate`, не копія);
  2. основна платформа, та сама база: `/DumpCfg "<WorkDir>\v<N>.cf"`;
  3. обрана платформа: `New-V8FileInfobase -Path <WorkDir>\alt-ib -MustBeUnder <WorkDir> -V8Path <AltV8Path>`;
  4. обрана платформа, `IbSwitch '/F "<alt-ib>"'`, без користувача: `/LoadCfg "<v<N>.cf>"`, потім
     `/DumpConfigToFiles "<Target>"` у спорожнену теку `Target`;
  5. прибрати `PlatformJunk` (як `Invoke-KitStorageCheckout`); поставку прибирає далі
     `Write-KitStorageVersion` (1.3.0) — тут не дублювати.
  Кожен ненульовий код — зупинка з назвою кроку й платформи. Сховище й база агента обраною
  платформою **не** відкриваються: перевіряє тест на `V8Path`/`IbSwitch` кожного виклику.

- [ ] **Step 1: Тести**

У `StoragePlatform.Tests.ps1` (є `$script:Ext`, `$script:Cfg`, прийом моку `Invoke-V8Designer`):

```powershell
    Context 'збій вивантаження після успішного UpdateCfg — розпізнаваний виняток (спека 1.3.1 §6.1.1)' {
        It 'UpdateCfg 0, DumpConfigToFiles 1 — виняток із Data: версія, платформа, вивід; Test-KitDumpFailure = $true' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                if (($Arguments -join ' ') -match 'DumpConfigToFiles') { return [pscustomobject]@{ ExitCode = 1; Output = 'Неправильный путь к файлу. Схема не зарегистрирована' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            Mock -ModuleName StoragePlatform Get-V8Path { 'C:\pf\8.3.27.1644\bin\1cv8.exe' }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34') -MustBeUnder $TestDrive }
            catch { $rec = $_ }
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeTrue
            $rec.Exception.Message | Should -BeLike '*Вивантаження версії 34 не вдалося*Схема не зарегистрирована*'
            $rec.Exception.Data['Version'] | Should -Be 34
            $rec.Exception.Data['PlatformPath'] | Should -BeLike '*8.3.27.1644*'
        }

        It 'збій UpdateCfg — НЕ розпізнаваний виняток вивантаження' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 1; Output = 'Внутренняя ошибка' } }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34u') -MustBeUnder $TestDrive } catch { $rec = $_ }
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeFalse
        }

        It 'дамп упав, бо база зайнята — зупинка «зайнята», не розпізнаваний виняток' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments)
                if (($Arguments -join ' ') -match 'DumpConfigToFiles') { return [pscustomobject]@{ ExitCode = 1; Output = 'Ошибка блокировки информационной базы для конфигурирования' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34b') -MustBeUnder $TestDrive } catch { $rec = $_ }
            $rec.Exception.Message | Should -BeLike '*зайнята*'
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeFalse
        }
    }

    Context 'Invoke-KitStorageCheckoutViaPlatform — вивантаження обраною платформою (спека 1.3.1 §4.3)' {
        It 'послідовність: основна UpdateCfg і DumpCfg у базі агента → обрана CREATEINFOBASE, LoadCfg, DumpConfigToFiles у тимчасовій ІБ' {
            $script:Calls = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName StoragePlatform Get-V8Path { 'MAIN' }
            Mock -ModuleName StoragePlatform New-V8FileInfobase {
                param($Path, $MustBeUnder, $TemplatePath, $V8Path)
                $script:Calls.Add("CREATEINFOBASE|$V8Path|$Path"); New-Item -ItemType Directory -Path $Path -Force | Out-Null; $Path
            }
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $a = $Arguments -join ' '
                $verb = if ($a -match 'UpdateCfg') { 'UpdateCfg' } elseif ($a -match '/DumpCfg') { 'DumpCfg' } elseif ($a -match '/LoadCfg') { 'LoadCfg' } elseif ($a -match 'DumpConfigToFiles') { 'DumpConfigToFiles' } else { $a }
                $who = if ($V8Path) { $V8Path } else { 'MAIN' }
                $script:Calls.Add("$verb|$who|$IbSwitch")
                if ($a -match '/DumpCfg "(?<f>[^"]+)"') { Set-Content -LiteralPath $Matches.f -Value 'cf' -Encoding ascii }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $work = Join-Path $TestDrive 'via'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch '/S "srv\agent"' -Source $script:Cfg -Version 34 `
                -Target (Join-Path $work 'tree') -MustBeUnder $work -WorkDir $work -AltV8Path 'ALT'
            $altIb = '/F "{0}"' -f (Join-Path $work 'alt-ib')
            @($script:Calls) | Should -Be @(
                'UpdateCfg|MAIN|/S "srv\agent"'
                'DumpCfg|MAIN|/S "srv\agent"'
                "CREATEINFOBASE|ALT|$(Join-Path $work 'alt-ib')"
                "LoadCfg|ALT|$altIb"
                "DumpConfigToFiles|ALT|$altIb")
            # Обрана платформа ніколи не бачить ні бази агента, ні аргументів сховища.
            @($script:Calls | Where-Object { $_ -like '*|ALT|*srv*' }).Count | Should -Be 0
        }

        It 'обрана платформа впала на LoadCfg — зупинка з назвою кроку й платформи' {
            Mock -ModuleName StoragePlatform Get-V8Path { 'MAIN' }
            Mock -ModuleName StoragePlatform New-V8FileInfobase { param($Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; $Path }
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $a = $Arguments -join ' '
                if ($a -match '/DumpCfg "(?<f>[^"]+)"') { Set-Content -LiteralPath $Matches.f -Value 'cf' -Encoding ascii }
                if ($a -match '/LoadCfg') { return [pscustomobject]@{ ExitCode = 1; Output = 'файл пошкоджено' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $work = Join-Path $TestDrive 'via-fail'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            { Invoke-KitStorageCheckoutViaPlatform -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 `
                -Target (Join-Path $work 'tree') -MustBeUnder $work -WorkDir $work -AltV8Path 'ALT' } | Should -Throw '*LoadCfg*ALT*файл пошкоджено*'
        }
    }
```

(Як `IbSwitch` тимчасової ІБ записано — `'/F "<шлях>"'` — звірити з тим, що повертає/будує код;
якщо форма інша, підправити очікування й назвати.)

- [ ] **Step 2: Прогнати — має впасти.**

- [ ] **Step 3: Реалізація**

- Винести з `Invoke-KitStorageCheckout` блок `UpdateCfg` (з перекладом «зайнята» і «розширення не
  знайдено») у приватну `Invoke-KitStorageUpdate -IbSwitch -Source -Version [-User]`;
  `Invoke-KitStorageCheckout` кличе її.
- У `Invoke-KitStorageCheckout` замість `throw "Вивантаження версії …"`:

```powershell
    if ($dump.ExitCode -ne 0) {
        Assert-V8InfobaseNotBusy -Output $dump.Output -Infobase 'агента'
        # Спека 1.3.1 §4.1, §6.1.1: збій вивантаження ПІСЛЯ успішного UpdateCfg — розпізнаваний
        # виняток; текст для людини будує викликач (sync — з командами -DumpPlatform/-SkipVersion,
        # verify — без них). Повідомлення лишається тим самим, що й до 1.3.1.
        $ex = [System.InvalidOperationException]::new("Вивантаження версії $Version не вдалося: $($dump.Output)")
        $ex.Data['KitDumpFailure'] = $true
        $ex.Data['Version'] = $Version
        $ex.Data['PlatformPath'] = (Get-V8Path)
        $ex.Data['Output'] = $dump.Output
        throw $ex
    }
```

- `Test-KitDumpFailure`:

```powershell
function Test-KitDumpFailure {
    [CmdletBinding()]
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $null -ne $ErrorRecord -and $ErrorRecord.Exception.Data.Contains('KitDumpFailure') -and [bool]$ErrorRecord.Exception.Data['KitDumpFailure']
}
```

- `Invoke-KitStorageCheckoutViaPlatform` — за кроками контракту; `.cf` і `alt-ib` під `$WorkDir`
  (`Assert-SafeWorkPath -MustBeUnder $WorkDir` перед записом); `Target` — спорожнити, як у
  `Invoke-KitStorageCheckout`. Розширення — `throw` «вивантаження іншою платформою для EXTENSION не
  підтримується в 1.3.1» (§4.3; захист другого рівня, перший — у `sync`). Коментар у шапці функції:
  чому `.cf`, а не сховище обраною платформою (клієнт іншої версії не підключиться до кластера
  основної; сховище — лише основною платформою).
- `Export-ModuleMember` + `$RequiredCommands`: `Test-KitDumpFailure`, `Invoke-KitStorageCheckoutViaPlatform`.

- [ ] **Step 4: Прогнати — має пройти** (наявні тести `Invoke-KitStorageCheckout` зелені — текст винятку той самий).
- [ ] **Step 5: Мутації (на копії):** (а) прибрати `Data['KitDumpFailure']` — перший тест червоний; (б) у кроці 4 передати `-V8Path` основної платформи — тест послідовності червоний; (в) прибрати `Assert-V8InfobaseNotBusy` перед винятком — тест «зайнята» червоний.
- [ ] **Step 6: Коміт**

```bash
git add tools/lib/StoragePlatform.psm1 tools/tests/StoragePlatform.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1
git commit --only -m "StoragePlatform: розпізнаваний виняток збою вивантаження; вивантаження версії обраною платформою через .cf" -- tools/lib/StoragePlatform.psm1 tools/tests/StoragePlatform.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1
```

---

### Task 3: трейлери `Storage-Dump-Platform` і `Storage-Skipped`

**Ризик:** механічна (одне рев'ю, дешева модель).

**Files:**
- Modify: `tools/lib/StorageBranch.psm1` (`New-KitStorageCommitMessage`)
- Test: `tools/tests/StorageBranch.Tests.ps1`

**Interfaces:**
- Produces: `New-KitStorageCommitMessage -Version -SourceKey -SourceType [-DumpPlatform <string>] [-MainPlatform <string>] [-SkippedVersion <int[]>]`.
  - `-DumpPlatform X -MainPlatform Y` → рядок тіла `вивантажено платформою X: основна платформа Y цю версію не вивантажує` і трейлер `Storage-Dump-Platform: X`.
  - `-SkippedVersion N` → рядок тіла `версію N пропущено: жодна платформа не вивантажує` і трейлер `Storage-Skipped: N` (масив — по трейлеру на номер; у 1.3.1 завжди один).
  - Рядки тіла — **перед** блоком трейлерів, відокремлені порожнім рядком; трейлери — після наявних (`Storage-User` лишається), щоб `git interpret-trailers` бачив один блок.

- [ ] **Step 1: Тести**

```powershell
    It 'New-KitStorageCommitMessage: -DumpPlatform — рядок пояснення й трейлер Storage-Dump-Platform; git читає його як трейлер' {
        $v = [pscustomobject]@{ Version = 34; User = 'u'; Comment = 'Додата форма'; ConfigVersion = '' }
        $m = New-KitStorageCommitMessage -Version $v -SourceKey 'base' -SourceType 'CONFIGURATION' -DumpPlatform '8.3.25.1445' -MainPlatform '8.3.27.1644'
        $m | Should -BeLike '*вивантажено платформою 8.3.25.1445: основна платформа 8.3.27.1644 цю версію не вивантажує*'
        ($m | git interpret-trailers --parse) | Should -Contain 'Storage-Dump-Platform: 8.3.25.1445'
        ($m | git interpret-trailers --parse) | Should -Contain 'Storage-Version: 34'
    }

    It 'New-KitStorageCommitMessage: -SkippedVersion — рядок пояснення й трейлер Storage-Skipped' {
        $v = [pscustomobject]@{ Version = 35; User = 'u'; Comment = 'Відновив стандартну форму'; ConfigVersion = '' }
        $m = New-KitStorageCommitMessage -Version $v -SourceKey 'base' -SourceType 'CONFIGURATION' -SkippedVersion 34
        $m | Should -BeLike '*версію 34 пропущено: жодна платформа не вивантажує*'
        ($m | git interpret-trailers --parse) | Should -Contain 'Storage-Skipped: 34'
    }

    It 'New-KitStorageCommitMessage без нових параметрів — без нових рядків (поведінка не змінилась)' {
        $v = [pscustomobject]@{ Version = 7; User = 'u'; Comment = 'x'; ConfigVersion = '' }
        $m = New-KitStorageCommitMessage -Version $v -SourceKey 'base' -SourceType 'CONFIGURATION'
        $m | Should -Not -BeLike '*Storage-Dump-Platform*'
        $m | Should -Not -BeLike '*Storage-Skipped*'
    }
```

(`git interpret-trailers --parse` читає stdin; якщо в PowerShell форма з конвеєром дає інший
вивід — узяти той прийом, яким `Get-KitBranchCommits` читає трейлери, і назвати.)

- [ ] **Step 2: Прогнати — має впасти. Step 3: Реалізація** — у `New-KitStorageCommitMessage` перед `$out.Add('')`, що відкриває трейлери, додати рядки пояснень (кожен з порожнім рядком перед блоком), після `Storage-User` — нові трейлери.
- [ ] **Step 4: Прогнати — має пройти. Step 5: Мутація (на копії):** прибрати трейлер `Storage-Dump-Platform` — перший тест червоний.
- [ ] **Step 6: Коміт**

```bash
git add tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1
git commit --only -m "StorageBranch: трейлери Storage-Dump-Platform і Storage-Skipped у повідомленні коміту версії" -- tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1
```

---

### Task 4: `sync -DumpPlatform/-ForVersion/-SkipVersion`, зупинка §4.1; текст `verify`

**Ризик:** спільний код (одне рев'ю на сильній моделі; окремі питання — «чи може версія N
отримати коміт основною платформою після зупинки» і «чи кличеться `UpdateCfg` до відмови будь-якої
перевірки параметрів»).

**Files:**
- Modify: `tools/commands/sync.psm1` (`Invoke-KitSync`)
- Modify: `tools/commands/verify.psm1` (`Invoke-KitVerify`, виклик `Invoke-KitStorageCheckout`)
- Modify (лише якщо тест диспетчера покаже потребу): `tools/kit.ps1`
- Test: `tools/tests/Sync.DumpPlatform.Tests.ps1` (створити), `tools/tests/Verify.Tests.ps1`, `tools/tests/Kit.Tests.ps1`

**Interfaces:**
- Consumes: `Get-KitInstalledPlatforms`, `Get-V8Path -Version` (Task 1); `Test-KitDumpFailure`,
  `Invoke-KitStorageCheckoutViaPlatform` (Task 2); `New-KitStorageCommitMessage -DumpPlatform -MainPlatform -SkippedVersion` (Task 3).
- Produces: `Invoke-KitSync … [-DumpPlatform <string>] [-ForVersion <Nullable[int]>] [-SkipVersion <Nullable[int]>]`;
  запис `Synced[]` отримує `DumpedVia` (`[string]` версія платформи або `$null`) і `Skipped` (`[int[]]`).

**Контракт (спека §4.1, §4.3, §4.4, §6.1):**

Перевірки — у порядку «дешеве першим»:
1. **На вході, до `Select-KitSources`:** `-DumpPlatform` і `-ForVersion` — лише разом; `-ForVersion`,
   `-SkipVersion` > 0; `-DumpPlatform`/`-ForVersion` і `-SkipVersion` — взаємовиключні (§6.1.5);
   будь-який із трьох вимагає `-Source` (§6.1.4); `-DumpPlatform` має бути в
   `Get-KitInstalledPlatforms` (інакше — зупинка з переліком) і **не** дорівнювати версії основної
   платформи (`Get-V8Path` без `-Version` → версія з шляху; «це і є основна платформа»).
2. **Після `Select-KitSources`:** `-DumpPlatform` — лише для `CONFIGURATION` (для `EXTENSION` —
   «не підтримується в 1.3.1»).
3. **Після звіту, до першого `UpdateCfg`:** `-ForVersion` / `-SkipVersion` мусить дорівнювати першій
   неперенесеній версії (спершу `Get-KitPendingVersions` без `-MaxVersions`; §4.3, §6.1.2); для
   `-SkipVersion` — у звіті мусить бути версія після N (§6.1.3, інакше «пропуск можливий, лише коли
   у звіті є версія після N — дочекайтесь її»). `-MaxVersions` пропущену не рахує: при
   `-SkipVersion` брати `MaxVersions + 1` і потім викинути N — наступна версія завжди в прогоні.
   Пропущену версію викинути **до** перевірки авторів (`Get-KitUnattributedVersions`) — автора для
   неї не треба.

Прев'ю (без `-Apply`): у переліку версій позначити `← платформою <X>` / `← буде пропущено`;
обрану платформу не кликати (§6.1.5).

Реплей:
- версія `-ForVersion` → `Invoke-KitStorageCheckoutViaPlatform -WorkDir $workDir -AltV8Path (Get-V8Path -Version $DumpPlatform)`,
  повідомлення — з `-DumpPlatform $DumpPlatform -MainPlatform <основна>`;
- перша закомічена версія після пропущеної — з `-SkippedVersion $SkipVersion`;
- решта — як зараз.

Зупинка §4.1 — `catch` навколо `Invoke-KitStorageCheckout` у циклі: якщо `Test-KitDumpFailure`, —
`throw` з текстом (worktree прибирає наявний `finally`, коміти попередніх версій лишаються):

```
Версію <N> основної конфігурації '<ключ>' основна платформа <версія з PlatformPath> не вивантажує.
Дзеркало <гілка> лишається на версії <остання закомічена>; часткового коміту немає.
Платформа відповіла: <Output>
Встановлені платформи:
  x64: 8.3.27.1644 (основна), 8.3.25.1445
  x86: 8.3.25.1445
Вивантажити цю версію іншою платформою (зі згоди людини):
  kit sync -RepoRoot . -Source <ключ> -Apply -DumpPlatform 8.3.25.1445 -ForVersion <N>
Якщо жодна платформа не вивантажує — пропустити версію явно:
  kit sync -RepoRoot . -Source <ключ> -Apply -SkipVersion <N>
```

(Команда `-DumpPlatform` — по рядку на кожну іншу встановлену версію, без дублів x64/x86; якщо
інших немає — замість команд «інших платформ в оточенні немає — встановіть іншу версію або
пропустіть версію».)

`verify`: `catch` навколо `Invoke-KitStorageCheckout`; на `Test-KitDumpFailure` — `throw`
«Версію <N> основна платформа <версія> не вивантажує — verify на ній неможливий. Звірте наступну
версію (`-Version`) або вершину, вивантажену основною платформою. Платформа відповіла: …» — без
`-DumpPlatform`/`-SkipVersion` (§6.1.1).

- [ ] **Step 1: `grep` на унікальність фраз і на диспетчер**

```bash
grep -rn "не вивантажує" tools/commands tools/lib
grep -rn "verify на ній неможливий" tools/commands tools/lib
grep -n "Nullable\|ParameterType" tools/kit.ps1
```

- [ ] **Step 2: Тести `sync`**

Створити `tools/tests/Sync.DumpPlatform.Tests.ps1` — `BeforeAll` дослівно як у
`Sync.Merge.Tests.ps1` (модулі за `module-order.txt`, `sync.psm1` у процесі, `New-KitTestContext`,
`New-KitFakeStorageVersion`). Підготовка — основна конфігурація під сховищем із дзеркалом на v33:

```powershell
        function script:New-DumpRepo {
            param([string]$Name)
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -WithHooks -WithGitignore -WithAgentBase
            $sd = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $sd -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$sd'") -join "`n")
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Alpha_SMB/cf/src' -FileName 'Configuration.xml' -Content '<x/>' -Trailers @('Storage-Source: base', 'Storage-Version: 33')
            $repo
        }
        $script:Platforms = @(
            [pscustomobject]@{ Version = '8.3.27.1644'; Arch = 'x64'; Path = 'C:\pf\8.3.27.1644\bin\1cv8.exe' }
            [pscustomobject]@{ Version = '8.3.25.1445'; Arch = 'x64'; Path = 'C:\pf\8.3.25.1445\bin\1cv8.exe' }
            [pscustomobject]@{ Version = '8.3.25.1445'; Arch = 'x86'; Path = 'C:\pf86\8.3.25.1445\bin\1cv8.exe' })
```

`BeforeEach`: `Mock -ModuleName sync Get-KitInstalledPlatforms { , $script:Platforms }`;
`Mock -ModuleName sync Get-V8Path { param($Version) if ($Version) { ($script:Platforms | Where-Object Version -eq $Version | Select-Object -First 1).Path } else { $script:Platforms[0].Path } }`;
`Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34), (New-KitFakeStorageVersion -Version 35)) }`;
`Mock -ModuleName sync Invoke-KitMainMerge { $true }`. Платформу (`Invoke-KitStorageCheckout`,
`Invoke-KitStorageCheckoutViaPlatform`) мокати за `-ModuleName sync` (кличе `sync.psm1`), фіксуючи
виклики в `$script:Steps`.

Тести (кожен — окремий `It`; текст наводжу стисло, виконавець розписує повністю за зразком
`Sync.Fallback.Tests.ps1` / `Sync.Authors.Tests.ps1`):

1. **Зупинка §4.1:** `Invoke-KitStorageCheckout` для v34 кидає виняток із `Data.KitDumpFailure`
   (зібрати так само, як Task 2: `InvalidOperationException` + `Data`), `-Apply` → виняток, у тексті
   `'*34*не вивантажує*'`, `'*x86*8.3.25.1445*'`, `'*-DumpPlatform 8.3.25.1445 -ForVersion 34*'`,
   `'*-SkipVersion 34*'`; рядок `-DumpPlatform 8.3.25.1445` — рівно **один** (без дубля x64/x86);
   `git log storage/base` — вершина з `Storage-Version: 33`, комітів не додалось; теки
   `build/sync/base/wt` немає.
2. **`-DumpPlatform 8.3.25.1445 -ForVersion 34 -Source base -Apply`:** v34 — через
   `Invoke-KitStorageCheckoutViaPlatform` з `AltV8Path` `C:\pf\8.3.25.1445\…` (x64), v35 — через
   `Invoke-KitStorageCheckout`; у коміті v34 трейлер `Storage-Dump-Platform: 8.3.25.1445`, у v35 —
   немає; `Synced[0].DumpedVia` = `8.3.25.1445`.
3. **`-SkipVersion 34 -Source base -Apply`:** коміту з `Storage-Version: 34` немає; коміт v35 має
   `Storage-Skipped: 34`; `Invoke-KitStorageCheckout` для 34 не кликався.
4. **`-SkipVersion 35`** (≠ першої неперенесеної 34) — зупинка, `Invoke-KitStorageCheckout` 0 разів.
5. **`-SkipVersion 34`, у звіті лише v34** (мок звіту — одна версія) — зупинка «дочекайтесь»,
   платформа для оновлення 0 разів.
6. **`-ForVersion 35 -DumpPlatform 8.3.25.1445`** (≠ 34) — зупинка до `UpdateCfg`.
7. **`-DumpPlatform 8.3.20.1 -ForVersion 34`** (немає в оточенні) — зупинка з переліком, `Get-StorageVersions` 0 разів.
8. **`-DumpPlatform 8.3.27.1644 -ForVersion 34`** (основна) — зупинка «це і є основна платформа».
9. **`-DumpPlatform 8.3.25.1445` без `-ForVersion`**; **`-ForVersion 34` без `-DumpPlatform`**;
   **`-SkipVersion 34 -DumpPlatform … -ForVersion 34`** (взаємовиключні); **без `-Source`** — по
   зупинці на вході, `Get-StorageVersions` 0 разів.
10. **`-DumpPlatform` для EXTENSION** (типова фікстура, `-Source Alpha_SMB`) — зупинка «не підтримується в 1.3.1».
11. **Прев'ю `-DumpPlatform 8.3.25.1445 -ForVersion 34 -Source base`** (без `-Apply`): вивід
    `'*34*платформою 8.3.25.1445*'`, `Invoke-KitStorageCheckoutViaPlatform` 0 разів.
12. **`-SkipVersion 34 -MaxVersions 1`** — прогін комітить саме v35 (пропущена не рахується).

- [ ] **Step 3: Тест `verify`**

У `Verify.Tests.ps1` (Describe «мок платформного шару»): `Invoke-KitStorageCheckout` кидає той
самий розпізнаваний виняток → `Invoke-KitVerify` кидає з `'*verify на ній неможливий*'` і
**без** `'*-DumpPlatform*'` та `'*-SkipVersion*'`.

- [ ] **Step 4: Тест диспетчера**

У `Kit.Tests.ps1` (підпроцес `kit.ps1`): `sync -ForVersion` без значення — зупинка «потребує
значення»; `sync -SkipVersion abc` — зупинка (не тиха конверсія). Якщо обидва вже зелені без змін
`kit.ps1` — змін у ньому не робити, у звіті так і сказати.

- [ ] **Step 5: Прогнати — має впасти** (крім тестів диспетчера, якщо вони зелені вже).

- [ ] **Step 6: Реалізація** — за контрактом вище. Ескіз гілки в циклі реплею:

```powershell
                try {
                    if ($null -ne $ForVersion -and $v.Version -eq $ForVersion) {
                        $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                            -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -WorkDir $workDir `
                            -AltV8Path (Get-V8Path -Version $DumpPlatform) -User $ibUser
                        $msgArgs = @{ DumpPlatform = $DumpPlatform; MainPlatform = $mainPlatformVersion }
                    } else {
                        $null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                            -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -User $ibUser
                        $msgArgs = @{}
                    }
                } catch {
                    if (Test-KitDumpFailure -ErrorRecord $_) { throw (New-KitDumpStopMessage -Source $src -ErrorRecord $_ -LastCommitted $(if ($done.Count) { $done[-1] } else { $last })) }
                    throw
                }
                if ($null -ne $SkipVersion -and -not $skipNoted) { $msgArgs.SkippedVersion = @($SkipVersion); $skipNoted = $true }
                $message = New-KitStorageCommitMessage -Version $v -SourceKey $src.Key -SourceType $src.Type @msgArgs
```

`New-KitDumpStopMessage` — приватна в `sync.psm1`, будує текст §4.1 з `Get-KitInstalledPlatforms` і
`ErrorRecord.Exception.Data`. `$mainPlatformVersion` — ім'я теки-версії з `Get-V8Path` (без
`-Version`), обчислене один раз на вході.

- [ ] **Step 7: Прогнати — має пройти** (повний набір, послідовно).
- [ ] **Step 8: Мутації (на копії):** (а) прибрати `catch`-переклад `Test-KitDumpFailure` у `sync` — тест 1 червоний; (б) прибрати перевірку «≠ першої неперенесеної» — тести 4/6 червоні; (в) прибрати перевірку «є версія після N» — тест 5 червоний; (г) прибрати `-SkippedVersion` у повідомленні — тест 3 червоний; (д) у `verify` повторно використати текст `sync` — тест `verify` червоний.
- [ ] **Step 9: Коміт**

```bash
git add tools/commands/sync.psm1 tools/commands/verify.psm1 tools/tests/Sync.DumpPlatform.Tests.ps1 tools/tests/Verify.Tests.ps1 tools/tests/Kit.Tests.ps1
git commit --only -m "sync: зупинка на версії, яку основна платформа не вивантажує; -DumpPlatform/-ForVersion і -SkipVersion; verify без порад sync" -- tools/commands/sync.psm1 tools/commands/verify.psm1 tools/tests/Sync.DumpPlatform.Tests.ps1 tools/tests/Verify.Tests.ps1 tools/tests/Kit.Tests.ps1
```

(+ `tools/kit.ps1`, якщо Step 4 вимагав змін.)

---

### Task 5: тексти, оновлення, версія 1.3.1; фінальне рев'ю; пілот

**Ризик:** механічна для текстів; фінальне рев'ю гілки — обов'язкове; пілот — крок користувача.

**Files:**
- Modify: `skills/sync/SKILL.md`, `docs/storage-and-git.md`, `skills/onboarding/references/upgrades.md`, `.claude-plugin/plugin.json`

- [ ] **Step 1: `skills/sync/SKILL.md`** — штатна зупинка «Версію N … основна платформа … не
  вивантажує»: показати людині перелік платформ із виводу як є, спитати, яку взяти (або пропуск),
  виконати команду з виводу **лише після її відповіді**; нагадати, що коміт іншої платформи міняє
  формат на багатьох файлах, а наступний повертає — це прийнято (спека §3), не дефект.
  Параметри `-DumpPlatform`/`-ForVersion`/`-SkipVersion` — коротко, з обмеженнями §6.1.
- [ ] **Step 2: `docs/storage-and-git.md`** — розділ «Версія, яку основна платформа не вивантажує»:
  інваріант (рішення людини, одна версія, одне джерело, лише основна конфігурація), чому через `.cf`
  і тимчасову файлову ІБ (обрана платформа не підключається ні до кластера основної, ні до
  сховища), шум формату як прийнятий, трейлери `Storage-Dump-Platform`/`Storage-Skipped` у розділі
  про трейлери, `verify` на такій версії неможливий. Без чисел — посилання на спеку §2.
- [ ] **Step 3: `upgrades.md`** — рядок таблиці «1.3.0 → 1.3.1: дій не потрібно, оновіть
  `kitVersion`» (§6.1.6).
- [ ] **Step 4: `plugin.json`** → `1.3.1`. Прогнати набір — зелений.
- [ ] **Step 5: коміт**

```bash
git add skills/sync/SKILL.md docs/storage-and-git.md skills/onboarding/references/upgrades.md .claude-plugin/plugin.json
git commit --only -m "1.3.1: версія, яку основна платформа не вивантажує — скіл sync, архітектурний документ, оновлення, версія" -- skills/sync/SKILL.md docs/storage-and-git.md skills/onboarding/references/upgrades.md .claude-plugin/plugin.json
```

- [ ] **Step 6: фінальне рев'ю гілки** (свіжий рев'юер, сильна модель): (а) чи може обрана платформа
  відкрити сховище чи базу агента; (б) чи може версія N після зупинки отримати коміт основною
  платформою; (в) чи кожна перевірка параметрів спрацьовує до `UpdateCfg`; (г) чи текст `verify`
  не радить `sync`; (д) `grep -rn "1.3.0" skills/ templates/` — нічого не обіцяє «з версії 1.3.0»
  того, що змінилось.
- [ ] **Step 7: пілот (`Integration`) — лише за підтвердженням користувача, виконує контролер.**
  `interoptica_unf`, основна конфігурація, версія 34, `-DumpPlatform 8.3.25.1445 -ForVersion 34`.
  Першим кроком — чи працює `/DumpCfg` основною платформою з бази агента після `UpdateCfg -v 34`
  (спека §7). Приймання (§6): коміт v34 у `storage/base` з трейлером `Storage-Dump-Platform`, без
  поставки (`.cf`); v35 — знову основною платформою; `verify -Source base` на вершині — `equal`.
  Сирий вивід — архітекторові.

---

## Трасування «пункт спеки → задача плану»

Спека — редакція `cebd9ed`.

| Пункт спеки | Суть | Задача |
|---|---|---|
| §1 проблема, §2 факти | версія 34 не вивантажується 8.3.27, вивантажується 8.3.25 | контекст; приймання — Task 5 Step 7 |
| §3 рішення: зупинка, перелік встановлених платформ, виконання зі згоди | — | Task 4 (зупинка §4.1, `-DumpPlatform`), Task 1 (перелік) |
| §3 рішення: шум формату прийнято | — | Global Constraints; Task 5 Step 1–2 (тексти) |
| §4.1 зупинка з поясненням (версія, платформа, вивід, перелік x64/x86, команди) | — | Task 2 (виняток), Task 4 (текст, тест 1) |
| §4.1 не «база зайнята», не ліцензія | — | Task 2 (тест «зайнята»; ліцензію кидає `Invoke-V8Designer`) |
| §4.2 `Get-KitInstalledPlatforms`; `Get-V8Path` обидва корені | — | Task 1 |
| §4.3 `-DumpPlatform -ForVersion`: лише CONFIGURATION, одна версія | — | Task 4 (перевірки 1–3, тести 2, 6–10) |
| §4.3 кроки: UpdateCfg, DumpCfg основною; тимчасова ІБ, LoadCfg, DumpConfigToFiles обраною; серверна база й сховище обраною не відкриваються | — | Task 2 (`Invoke-KitStorageCheckoutViaPlatform`, тест послідовності) |
| §4.3 п.4 прибирання службових файлів і поставки | — | Task 2 (`PlatformJunk`); поставка — `Write-KitStorageVersion` (1.3.0), без змін |
| §4.3 п.5 трейлер `Storage-Dump-Platform` і рядок у повідомленні | — | Task 3 |
| §4.3 п.6 решта версій — основною | — | Task 4 (тест 2) |
| §4.3 `-ForVersion` = версія зупинки; `-DumpPlatform` поза переліком — зупинка | — | Task 4 (тести 6, 7) |
| §4.4 `-SkipVersion`: коміту немає, трейлер `Storage-Skipped` на наступному, лише явно, номер у звіті | — | Task 3, Task 4 (тести 3–5, 12) |
| §4.5 verify/canon/adopt/dump/provision без змін; повний дамп діє | — | Task 4 лише текст `verify` (§6.1.1); решта не чіпається |
| §5 обсяг (V8, StoragePlatform, sync, kit.ps1, StorageBranch, скіл, docs, plugin.json) | — | Task 1–5; `kit.ps1` — Task 4 Step 4 (за потреби) |
| §6 перевірка: тести з мутаціями | — | Task 1–4, кроки «Мутації» |
| §6 живий прогін, приймання | — | Task 5 Step 7 |
| §6.1.1 розпізнаваний виняток; `verify` без команд `sync` | — | Task 2, Task 4 (тест `verify`) |
| §6.1.2 `-SkipVersion` = перша неперенесена | — | Task 4 (тест 4) |
| §6.1.3 `-SkipVersion` без наступної версії — зупинка; `-MaxVersions` пропущену не рахує | — | Task 4 (тести 5, 12) |
| §6.1.4 `-Source` обов'язковий | — | Task 4 (тест 9) |
| §6.1.5 взаємовиключність; прев'ю без обраної платформи | — | Task 4 (тести 9, 11) |
| §6.1.6 `Get-V8Path` x86 лише за явною версією; x64 перевага; рядок `upgrades.md` | — | Task 1, Task 5 Step 3 |
| §7 `/DumpCfg` з бази агента — перевірити першим у пілоті | — | Task 5 Step 7 |
