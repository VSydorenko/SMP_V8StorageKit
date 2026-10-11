# Адаптація kit до Unica 0.13 і v8-runner 0.14 — план імплементації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kit 1.5.0 говорить лише мовою Уніки 0.13. База агента живе в `infobases.origin` (з паролем і серверним варіантом). Після команд, що зрушили базу агента, kit друкує один точний крок вирівнювання пам'яті раннера. Попутно закриваються ішуї #25, #26, #34 і #13.

**Architecture:** Чотири фази (спека §6, рішення власника 2026-10-12).

Фаза A — уся адаптація кодом і документами за шляхом [док] спеки; тести kit Уніки не потребують. До неї входять:
- конфіг і читання бази (`V8Project`/`AgentBase`), пароль, #34, лапки, версія Уніки, словник текстів;
- новий модуль `UnicaStep.psm1`, що форматує виклики `unica.run` і вирішує крок вирівнювання (`pull` або `push force`, із запасними гілками-зупинками);
- `sync`/`verify` друкують крок; `canon -MarkerOnly`;
- `provision` вирішує, хто створює базу;
- скіли, шаблони, документація, перехід 1.4.0 → 1.5.0.

Фаза B — kit 1.5.0 у локальному маркетплейсі й самодостатній бриф агента-тестера з журналом. Фаза C — пілот: власник оновлює плагіни в момент пілоту. Фаза D — виправлення за пілотом і реліз.

Kit сам раннер не викликає.

**Tech Stack:** PowerShell 7, Pester 5, git ≥ 2.38, платформа 1С 8.3.27.x, модуль `powershell-yaml`; Unica 0.13.x (MCP) — лише в пілоті й тексті.

**Spec:** `docs/superpowers/specs/2026-10-11-unica-013-adaptation-design.md` на коміті **`8d94204`** (§2.2 і §4.1 — уточнення за першоджерелами Уніки 0.13; §6 — порядок «пілот після адаптації», пункти пілоту 12–13 і «Відкіт до пілоту»; §10 і §10.1 — рішення архітектора за питаннями й аудитом цього плану). План пройшов чотири аудити (код Tasks 1–6, код Tasks 7–11, першоджерела Unica 0.13 і v8-runner 0.14, Tasks 12–21 і повнота); знахідки внесено, рішення архітектора за ними — у розділі «Свідомі відхилення» наприкінці. Архітектор — сесія `unica-013-adaptation-spec`. Розбіжність плану зі спекою або пілоту зі спекою — зупинка й питання архітекторові, не вибір виконавця.

## Global Constraints

- **Без сумісності з 1.4.0 і Унікою 0.12** (спека §3 рішення 9): «kit 1.5.0 говорить лише мовою Уніки 0.13 і читає лише конфіг 0.13. Жодних запасних читань старих форм, аліасів старого словника, режимів «якщо Уніка 0.12». Старе в репозиторії споживача — `error` з рецептом міграції».
- Unica 0.13.0 возить **v8-runner 0.14.0** «і приймає лише цю версію раннера» (§2.1). Перевірена версія Уніки — **0.13.x**; будь-який патч 0.13.x — норма (§10 П11).
- **Kit не викликає CLI раннера сам** (§3 рішення 2). Платформу kit кличе сам лише там, де раннер нічого не пропонує: сховище (`sync`, `verify`), дев-база людини (`dump`), тимчасові бази (`build` для `.epf`, `-DumpPlatform`) і порожня база за непридатного дерева (§3 рішення 4).
- **Kit кодом `v8project*.yaml` не пише ніколи**; `infobases.origin` пише скіл `provision` (§10 П16).
- `providers: {push: designer, pull: designer, download: designer}` — **у закоміченому** `v8project.yaml`; відсутній або ≠ `designer` для `push`/`pull`/`download` → `error`; інші ключі `providers` вільні (§4.3 п. 1, §10 П10).
- Форма виклику, яку друкує kit: `unica.run {"op": …, "args": {…}, "dryRun": true|false}`; `infobase` не друкувати — він за замовчуванням `origin` (§10 П2). Уніка вимагає явний булів `dryRun` у кожному виклику, але прев'ю першим не вимагає (`v13_run_dictionary.rs`: `previewRequired: false`, `dryRunRequired: true`); kit **за власною конвенцією** друкує спершу `"dryRun":true`, потім той самий виклик з `false`. Не називати це «вимогою Уніки».
- Для набору `EXTENSION` `pull` несе `extension` = ім'я набору (схема `pull` Уніки 0.13: «required for an extension source set and must match it»); `make` `.cfe` — так само `extension`, для `.cf` — без нього.
- `force:true` на базі агента — без питання людині (§4.1); база агента похідна (§3 рішення 1).
- `unica_run` і `unica_apply` у `templates/settings.json` — з запитом (§3 рішення 6).
- Платформа — гілка **8.3.27.x**; підрядки `лиценз`, `ліценз`, `license`, `HASP` у виводі платформи — зупинка й доповідь.
- `-Apply` — лише на явне прохання людини. Сховища — лише читання. База людини — лише читання.
- Версія плагіна — **1.5.0** (`.claude-plugin/plugin.json`); `ref` у `marketplace.json` не чіпати — реліз лише після локального пілоту (пам'ять `release-after-local-pilot`).
- Тексти для людини й агента — українською. `${CLAUDE_PLUGIN_ROOT}` у скілах — лише всередині шляху (за токеном одразу `/`). Скіли — з префіксом `v8storagekit:`.
- Прогін тестів — одна форма, завжди повна: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`. `Integration` — один прогін на блок, у фіналі, з підтвердженням людини.
- Коміт — лише контролер, з дозволу людини: `git add <явний перелік>` + `git commit --only -F <файл повідомлення> -- <той самий перелік>`; без `-a`/`-A`; жодних `git checkout --`/`restore`/`stash`/`clean`. Повідомлення закінчується рядком `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Постійна документація — без номерів рядків, кількостей і результатів прогонів; замість числа — спосіб дістати.
- Бриф субагента — за `.claude/skills/kit-dev/references/subagent-brief.md` (шляхом, не переказом); модель і зусилля — явно.

## Review Focus

Випадки, які спека мається на увазі, але жоден тест задач не перевіряв би без цього розділу; кожен рядок має тест у названій задачі.

1. **Кириличне ім'я набору в надрукованому JSON.** Агент копіює рядок `unica.run …` дослівно, тож `ConvertTo-Json` мусить лишити кирилицю як є, без `\uXXXX`. Тест — Task 6, крок 1.
2. **Пароль з подвійною лапкою.** Маска `Hide-V8Secrets` (`"[^"]*"`) обірвалась би на внутрішній лапці й показала хвіст пароля. `Invoke-V8Designer` відмовляє на `"` у паролі, не друкуючи сам пароль. Тест — Task 4, крок 1.
3. **Нова, ще не закомічена форма агента під шляхом набору.** `git diff` її не бачить, а `pull` стер би її. «Чисте дерево» рахується через `git status --porcelain` (невідстежувані рахуються), і невідстежуваний файл дає `push`, не `pull`. Тест — Task 7, крок 1.
4. **`infobases.origin` є, але `connection` порожній.** Тиха відсутність бази виглядала б як «не налаштована» з порадою `provision`, хоча людина саме налаштовувала. Це знахідка конфігу з рецептом. Тест — Task 3, крок 1.
5. **`verify -Ref <sha>` чи тег, від'єднаний HEAD.** Порівняння «`-Ref` = HEAD» іде через `^{commit}` обох боків, не через ім'я гілки. Тест — Task 7, крок 1.

---

## Структура файлів

| Файл | Що змінюється |
|---|---|
| `docs/superpowers/pilots/2026-10-12-unica-013-pilot.md` | **новий** — журнал пілоту (фаза B; заповнює агент-тестер у фазі C) |
| `docs/superpowers/pilots/2026-10-12-unica-013-tester-brief.md` | **новий** — самодостатній бриф агента-тестера (фаза B) |
| `tools/lib/PathSafety.psm1` | `Remove-KitDirectory` (#34) |
| усі `tools/lib/*.psm1`, `tools/commands/*.psm1` з `Remove-Item … -Recurse` | виклики → `Remove-KitDirectory` |
| `tools/lib/V8.psm1` | `ConvertFrom-V8Connection` приймає парні лапки; `Invoke-V8Designer` відмовляє на `"` у паролі |
| `tools/lib/V8Project.psm1` | читання лише `infobases.origin`; `Get-V8ProjectConfigProblems`; `Providers`; без `InfobaseConnection` |
| `tools/lib/Preflight.psm1` | знахідки конфігу → `fail 'workspace'` |
| `tools/lib/AgentBase.psm1` | `Password`, `Dbms`; `Test-KitWorkspaceNeedsAgentBase`, `New-KitAgentBaseMissingMessage` |
| `tools/lib/StoragePlatform.psm1`, `tools/lib/StorageReport.psm1` | пароль; тексти рецептів |
| `tools/lib/Environment.psm1`, `tools/check-environment.ps1` | `Get-KitUnicaVersionVerdict` |
| `tools/lib/UnicaStep.psm1` | **новий** — `Format-KitUnicaRun`, `Write-KitNextSteps`, критерій і крок вирівнювання |
| `tools/lib/module-order.txt` | + `Environment`, + `UnicaStep` |
| `tools/lib/Supply.psm1` | рецепт поставки без `canon`-дампу |
| `tools/commands/check.psm1` | версія Уніки; аудит `infobases.origin`; П16 |
| `tools/commands/sync.psm1`, `verify.psm1` | пароль; крок вирівнювання; `AlignSteps` |
| `tools/commands/canon.psm1` | пароль; режим `-MarkerOnly` |
| `tools/commands/provision.psm1` | переписано за §4.2/§10 |
| `tools/commands/build.psm1` | тексти `make` |
| `tools/tests/fixtures/KitFixtures.psm1` | нова форма конфігу; `Set-KitFakeAgentBase`; фальшивий реєстр Уніки 0.13 |
| `tools/tests/fixtures/v8project-*.yaml` | нова форма |
| `tools/tests/UnicaStep.Tests.ps1`, `Sync.Align.Tests.ps1`, `Vocabulary.Tests.ps1` | **нові** |
| наявні `*.Tests.ps1`, що фіксують старий словник чи форму | переписуються в задачі, що змінює код |
| `skills/*/SKILL.md`, `skills/onboarding/references/upgrades.md` | новий словник, крок, `provision`, рецепти поставки, розділ 1.4.0 → 1.5.0 |
| `templates/settings.json`, `templates/CLAUDE.md`, `templates/README.md` | поверхня 0.13 |
| `CLAUDE.md`, `README.md`, `docs/storage-and-git.md`, `docs/text-policy.md`, `docs/unica-contract.md` | документація 0.13 |
| `docs/v8-runner-migration.md` | **знімається з обліку** |
| `.claude-plugin/plugin.json` | 1.5.0 |

## Порядок і фази (спека §6, §10 П1 на `8d94204`)

```
Фаза A — адаптація (код і документи, за шляхом [док]; тести kit Уніки не потребують)
  1 (#34) ─┐
  2 (лапки)├─► 3 (конфіг) ─► 4 (П16, пароль) ─► 5 (версія Уніки) ─► 6 (UnicaStep, тексти)
           │                                                        │
           │   7 (крок вирівнювання) ◄──────────────────────────────┘
           │   ├─► 8 (canon -MarkerOnly) ─► 9 (sync) ─► 10 (verify) ─► 11 (provision)
           │   └──────────────────────────────────────────────────────► 12 (скіли, шаблони)
           └─► 13 (запобіжник словника, після 12) ─► 14 (settings.json) ─► 15 (документи)
               ─► 16 (upgrades.md, 1.5.0) ─► 17 (рев'ю гілки, Integration)
Фаза B — підготовка пілоту: 18 (kit 1.5.0 у локальному маркетплейсі), 19 (бриф агента-тестера, журнал)
Фаза C — пілот: 20 (власник обирає репо, запускає тестера й одночасно оновлює плагіни)
Фаза D — 21 (виправлення за пілотом окремими задачами, реліз)
```

Уніку на цій машині до фази C **не оновлювати**: оновлення зупиняє всіх агентів на kit 1.4.0 (спека §6).

**Код, що залежить від пунктів пілоту 2, 3 і 11, має вже закладені запасні гілки** (спека §6):
- брудне дерево після `pull` — зупинка з доповіддю (текст кроку в Task 7, скіли в Task 12);
- поставка без `.cf` — зупинка з рецептом (`Get-KitAlignStep`, Op `blocked`, Task 7).

Пілот підтверджує шлях або вмикає запасний — дизайн він не переписує. Суперечність пілоту зі спекою — зупинка: архітектор править спеку окремим комітом, виправлення — окремі задачі фази D.

---

## Фаза A — адаптація

### Task 1: `Remove-KitDirectory` і заміна всіх `Remove-Item -Recurse` (#34)

**Рівень ризику:** спільний код (видалення тек у кожній команді).

**Files:**
- Modify: `tools/lib/PathSafety.psm1`
- Modify: кожен файл у `tools/commands/`, `tools/lib/`, `tools/kit.ps1`, де некоментований рядок містить `Remove-Item` разом з `-Recurse` (перелік — `grep`, не ішуя: `grep -rn "Remove-Item" tools/commands tools/lib tools/kit.ps1 | grep -- "-Recurse"`)
- Test: `tools/tests/PathSafety.Tests.ps1`

**Interfaces:**
- Produces: `Remove-KitDirectory -Path <string> [-Attempts <int>=5] [-DelayMs <int>=200]` — відсутній шлях → тиша; файл → виняток; інакше дерево видалено або виняток після вичерпаних спроб.

- [ ] **Step 1: Тести** — дописати в кінець `tools/tests/PathSafety.Tests.ps1`:

```powershell
Describe 'Remove-KitDirectory (#34)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force }

    It 'видаляє дерево з read-only файлом у підтеці' {
        $d = Join-Path $TestDrive 'ro'
        New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
        $f = Join-Path $d 'sub/x.txt'
        Set-Content -LiteralPath $f -Value 'x'
        Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $true
        Remove-KitDirectory -Path $d
        Test-Path -LiteralPath $d | Should -BeFalse
    }
    It 'відсутня тека — тиша, не виняток' {
        { Remove-KitDirectory -Path (Join-Path $TestDrive 'nope') } | Should -Not -Throw
    }
    It 'шлях до файлу — виняток, файл цілий' {
        $f = Join-Path $TestDrive 'f.txt'; Set-Content -LiteralPath $f -Value 'x'
        { Remove-KitDirectory -Path $f } | Should -Throw '*не тека*'
        Test-Path -LiteralPath $f | Should -BeTrue
    }
    It 'тека з атрибутом ReadOnly (а не лише файл) — видаляється, як це робив Remove-Item -Force' {
        $d = Join-Path $TestDrive 'rodir'
        $sub = Join-Path $d 'sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'x.txt') -Value 'x'
        (Get-Item -LiteralPath $sub).Attributes = 'ReadOnly, Directory'
        Remove-KitDirectory -Path $d
        Test-Path -LiteralPath $d | Should -BeFalse
    }
    It 'зайнятий файл — рівно Attempts спроб (Attempts-1 повторів у Verbose) і виняток, тека ціла' {
        $d = Join-Path $TestDrive 'locked'; New-Item -ItemType Directory -Path $d | Out-Null
        $f = Join-Path $d 'x.txt'; Set-Content -LiteralPath $f -Value 'x'
        $h = [System.IO.File]::Open($f, 'Open', 'Read', 'None')
        $msgs = [System.Collections.Generic.List[string]]::new(); $threw = $false
        try {
            try { Remove-KitDirectory -Path $d -Attempts 3 -DelayMs 10 -Verbose 4>&1 | ForEach-Object { $msgs.Add([string]$_.Message) } }
            catch { $threw = $true }
        } finally { $h.Dispose() }
        $threw | Should -BeTrue
        @($msgs | Where-Object { $_ -like '*спроба*' }).Count | Should -Be 2
        Test-Path -LiteralPath $d | Should -BeTrue
    }
}

Describe 'Запобіжник #34: жодного Remove-Item -Recurse у коді kit' {
    # Межа виміру (не ширша за неї): ловиться Remove-Item і -Recurse в одному рядку. Рядок
    # продовження (бектік) і псевдоніми rm/ri/del тест не бачить — на момент написання таких
    # місць у tools/ немає (grep по 'Recurse').
    It 'tools/commands, tools/lib, tools/kit.ps1 — без Remove-Item з -Recurse поза коментарями' {
        $root = (Resolve-Path "$PSScriptRoot/..").Path
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'commands'), (Join-Path $root 'lib') -Filter '*.psm1' -File) +
                 @(Get-Item -LiteralPath (Join-Path $root 'kit.ps1'))
        $hits = foreach ($f in $files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
            $text = [regex]::Replace($text, '(?s)<#.*?#>', '')
            $n = 0
            foreach ($line in ($text -split "`n")) {
                $n++
                $code = $line.Trim()
                if ($code.StartsWith('#')) { continue }
                if ($code -match 'Remove-Item\b' -and $code -match '-Recurse\b') { "$($f.Name): $code" }
            }
        }
        @($hits) | Should -BeNullOrEmpty -Because 'рекурсивне видалення — лише Remove-KitDirectory (#34)'
    }
}
```

- [ ] **Step 2: Прогін — червоний.** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`. Очікувано: `CommandNotFoundException` на `Remove-KitDirectory`; запобіжник перелічує нинішні рядки.

- [ ] **Step 3: Реалізація** — у `tools/lib/PathSafety.psm1` перед `Export-ModuleMember`:

```powershell
function Remove-KitDirectory {
    <#
    .SYNOPSIS
        Рекурсивне видалення теки з повторами (#34) — єдине місце рекурсивного видалення в kit.
    .DESCRIPTION
        Remove-Item -Recurse під pwsh 7.6 на Windows Server недетерміновано падає на зайнятому
        файлі (антивірус, індексатор, щойно закритий 1cv8). [System.IO.Directory]::Delete не
        знімає атрибута ReadOnly ні з файлів, ні з тек (на теці з ReadOnly .NET кидає IOException,
        не UnauthorizedAccessException — перевірено аудитом плану), тож перед КОЖНИМ повтором
        атрибут знімається з усього дерева, а на IOException ще й пауза, що росте з номером
        спроби. Межу шляху тут не перевіряють: викликач робить Assert-SafeWorkPath ДО виклику,
        як і раніше перед Remove-Item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 50)][int]$Attempts = 5,
        [ValidateRange(0, 10000)][int]$DelayMs = 200
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Remove-KitDirectory: '$Path' не тека — файли видаляє викликач сам (Remove-Item без -Recurse)."
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $clearReadOnly = {
        $all = @($full) + @([System.IO.Directory]::EnumerateFileSystemEntries($full, '*', [System.IO.SearchOption]::AllDirectories))
        foreach ($entry in $all) {
            $attr = [System.IO.File]::GetAttributes($entry)
            if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
                [System.IO.File]::SetAttributes($entry, $attr -band (-bnot [System.IO.FileAttributes]::ReadOnly))
            }
        }
    }
    for ($i = 1; ; $i++) {
        try {
            [System.IO.Directory]::Delete($full, $true)
            return
        } catch [System.IO.DirectoryNotFoundException] {
            return
        } catch [System.UnauthorizedAccessException] {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "Remove-KitDirectory: спроба $i — доступ заборонено, знімаю ReadOnly у '$full'"
            & $clearReadOnly
        } catch [System.IO.IOException] {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "Remove-KitDirectory: спроба $i — $($_.Exception.Message); повтор через $($DelayMs * $i) мс"
            try { & $clearReadOnly } catch { Write-Verbose "Remove-KitDirectory: зняти ReadOnly не вдалось — $($_.Exception.Message)" }
            Start-Sleep -Milliseconds ($DelayMs * $i)
        }
    }
}
```

Export: `Export-ModuleMember -Function Assert-SafeWorkPath, Remove-KitDirectory`.

- [ ] **Step 4: Заміна викликів.** Спершу для **кожного** рядка грепу визначити читанням, тека це, файл чи «будь-що» (цикли на кшталт `foreach ($leftover in @($cf, $altIbPath))` у `StoragePlatform.psm1` прибирають і файл `.cf`, і теку `alt-ib`; `Supply.psm1` — `$inner`/`$item`; `V8.psm1` у `New-V8FileInfobase`). `Remove-KitDirectory` на файлі кидає «не тека», тож змішане місце без розділення перестало б прибирати файл. Тоді переписати за формою:
  - `if (Test-Path -LiteralPath X) { Remove-Item -LiteralPath X -Recurse -Force }` → `Remove-KitDirectory -Path X`.
  - Для елемента, що може бути й файлом (`Clear-KitTreeExceptSupply` у `Supply.psm1`):

    ```powershell
    if ($inner.PSIsContainer) { Remove-KitDirectory -Path $inner.FullName } else { Remove-Item -LiteralPath $inner.FullName -Force }
    ```

  - Місце з `-ErrorAction SilentlyContinue` (best-effort прибирання в `StorageBranch.psm1`) → `try { Remove-KitDirectory -Path $Path } catch { Write-Verbose "…: $($_.Exception.Message)" }`. Семантика «не валити» лишається.
  - Змішаний цикл у `StoragePlatform.psm1` (файл `$cf` і тека `$altIbPath`, `-ErrorAction Stop` усередині `try`) — розділити, семантику обробки помилки лишити тією, що була:

    ```powershell
    if (Test-Path -LiteralPath $cf -PathType Leaf) { Remove-Item -LiteralPath $cf -Force -ErrorAction Stop }
    Remove-KitDirectory -Path $altIbPath
    ```

  - Інше місце з `-ErrorAction Stop` на теці → простий виклик `Remove-KitDirectory`.
  - `Assert-SafeWorkPath` перед викликом лишається там, де був.

  Коментарі, що згадують `Remove-Item -Recurse -Force` як механізм (у `canon.psm1`, `TreeBackup.psm1`, `AgentBase.psm1`, `V8.psm1`, `provision.psm1`), переписати на `Remove-KitDirectory`. Причина в коментарі лишається (kit-dev, «змінилась причина чужого кроку»).

- [ ] **Step 5: Прогін — зелений.** Та сама команда; весь набір зелений.

- [ ] **Step 6: Мутація запобіжника — на копії дерева.** Скопіювати `tools/` у теку скретчпада. У копії `tools/lib/Supply.psm1` дописати некоментований рядок `Remove-Item -LiteralPath $x -Recurse -Force`. Прогнати `Invoke-Pester -Path <копія>/tests/PathSafety.Tests.ps1`: тест «без Remove-Item з -Recurse» червоний, у тексті падіння — `Supply.psm1: Remove-Item -LiteralPath $x -Recurse -Force`. Текст падіння — у звіт.

- [ ] **Step 7 (контролер, з дозволу людини): Коміт** — `git add` явним переліком змінених файлів (`git status --porcelain` → лише ці), `git commit --only -F <файл> -- <перелік>`. Тема: `#34: Remove-KitDirectory — рекурсивне видалення з повторами`.

### Task 2: Парні лапки в рядку підключення (§4.3 п. 4)

**Рівень ризику:** властивість безпеки (розбір підключення живить аудит «база агента ≠ база людини»).

**Files:**
- Modify: `tools/lib/V8.psm1` (`ConvertFrom-V8Connection`)
- Modify: `tools/lib/AgentBase.psm1` (лише коментарі `Get-KitInfobaseCanonicalForm`, `Test-KitSameInfobase`, `Resolve-KitAgentBase` про лапки)
- Modify: `tools/commands/check.psm1` — лише коментарі, що стверджують «лапки — помилка, fail-closed» (знайти: `grep -n "лапк" tools/commands/check.psm1`)
- Test: `tools/tests/V8.Tests.ps1` (тести відмови на лапках, `ConvertTo-V8IbSwitch` на лапках), `tools/tests/AgentBase.Tests.ps1` (тест лапок), `tools/tests/Check.Names.Tests.ps1` (тести «`*лапках*`»). Повний перелік — `grep -rn "лапк\|Srvr=\"" tools/tests`; кожен збіг переглянути

**Interfaces:**
- Produces: `ConvertFrom-V8Connection` — той самий вихід `{Kind; Server; Ref; File}`. Значення в парних лапках навколо всього значення знімаються. Непарна лапка чи лапка всередині значення — виняток.

- [ ] **Step 1: Тести** — у `tools/tests/V8.Tests.ps1` замінити тести, що чекали відмови на `Srvr="…"`, таким блоком:

```powershell
Describe 'ConvertFrom-V8Connection — лапки (спека 2026-10-11 §4.3 п. 4)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }
    It 'парні лапки навколо значень знімаються: <C>' -ForEach @(
        @{ C = 'Srvr="VSDEV";Ref="SMP_UNF";'; Kind = 'server'; S = 'VSDEV'; R = 'SMP_UNF'; F = $null }
        @{ C = 'File="D:\Bases\X"';          Kind = 'file';   S = $null;   R = $null;     F = 'D:\Bases\X' }
        @{ C = 'Srvr=VSDEV;Ref="SMP_UNF"';    Kind = 'server'; S = 'VSDEV'; R = 'SMP_UNF'; F = $null }
    ) {
        $p = ConvertFrom-V8Connection -Connection $C
        $p.Kind | Should -Be $Kind; $p.Server | Should -Be $S; $p.Ref | Should -Be $R; $p.File | Should -Be $F
    }
    It 'непарна лапка — виняток з ключем: <C>' -ForEach @(
        @{ C = 'Srvr="VSDEV;Ref=SMP_UNF' }
        @{ C = 'Srvr=VS"DEV;Ref=SMP_UNF' }
        @{ C = 'File="D:\a;b"' }
    ) {
        { ConvertFrom-V8Connection -Connection $C } | Should -Throw '*непарні лапки*'
    }
    It 'лапки в імені ключа — виняток' {
        { ConvertFrom-V8Connection -Connection '"Srvr"=VSDEV;Ref=X' } | Should -Throw '*імені ключа*'
    }
}
```

У `tools/tests/AgentBase.Tests.ps1` — тест ідентичності:

```powershell
It 'Srvr у лапках і без лапок — та сама база (§4.3 п. 4)' {
    Test-KitSameInfobase -Left 'Srvr="VSDEV";Ref="SMP_UNF";' -Right 'Ref=smp_unf;Srvr=vsdev' | Should -BeTrue
}
```

- [ ] **Step 2: Прогін — червоний.** Очікувано: `*непарні лапки*` не знайдено, бо зараз кидає `*записано в лапках*`; парні лапки кидають.

- [ ] **Step 3: Реалізація** — у `ConvertFrom-V8Connection`:
  - прибрати блок `if ($value.Contains('"')) { … throw … }`;
  - у циклі по `$part` після `$val = $Matches['val'].Trim()` вставити:

```powershell
        if ($key.Contains('"')) {
            throw "Рядок підключення '$Connection' містить лапки в імені ключа '$key'."
        }
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2).Trim()
        }
        if ($val.Contains('"')) {
            throw ("Рядок підключення '$Connection' містить непарні лапки у значенні ключа '$key': лапки " +
                   'допускаються лише парою навколо всього значення (Srvr="SRV";Ref="BASE";). Шлях у File= не може ' +
                   "містити ';' ні в лапках, ні без них.")
        }
```

Перевірка порожнього значення лишається **після** зняття лапок (`Ref=""` — порожнє значення).

  Переписати `.DESCRIPTION`:
  - раннер 0.14 сам знімає парні лапки й передає `/S srv\ref` (спека §2.2, [код `connection.rs`]);
  - kit знімає їх для порівняння баз;
  - форма без лапок лишається коректною;
  - непарна лапка — помилка;
  - відома межа `;` у шляху лишається.

  Факт `issue #9` (Уніка 0.12 у лапках не підключалась) — одним реченням як історія.

- [ ] **Step 4: Коментарі `AgentBase.psm1` і `check.psm1`** — абзаци «значення в лапках — fail-closed/помилка» переписати: лапки парою — та сама база, непарні — `Parsed=$false` з текстом винятку (fail-closed лишається для нерозбірного). Тексти про лапки поза `tools/` (скіли, `templates/v8storagekit.local.yaml.example`, `docs/`, `upgrades.md`) — Tasks 12, 15, 16.

- [ ] **Step 5: Прогін — зелений.** Тести `Check.*`, що чекали знахідки на лапках, переписати: парні лапки → знахідки немає; непарні → `error` з `*непарні лапки*`. Перш ніж писати перевірку на фразу, переконатися `grep -rn "непарні лапки" tools/commands tools/lib`, що вона трапляється лише в `V8.psm1`.

- [ ] **Step 6: Мутація** — на копії дерева прибрати рядок `$val = $val.Substring(…)`. Тест «парні лапки знімаються» червоний; текст падіння — у звіт.

- [ ] **Step 7 (контролер, з дозволу людини): Коміт.** Тема: `§4.3 п.4: парні лапки в підключенні приймаються, непарні — помилка`.

### Task 3: Конфіг воркспейсу 0.13 — читання `infobases.origin`, знахідки конфігу, префлайт

**Рівень ризику:** властивість безпеки (аудит «база агента ≠ база людини» не має стати fail-open) + спільний код (фікстура всіх тестів).

**Files:**
- Modify: `tools/lib/V8Project.psm1`
- Modify: `tools/lib/Preflight.psm1` (цикл воркспейсів у `Invoke-KitPreflight`, перед `Read-V8Project`)
- Modify: `tools/commands/check.psm1` (блок «аудит v8project.local.yaml»: читання `infobases.origin`, тексти)
- Modify: `tools/tests/fixtures/KitFixtures.psm1`, `tools/tests/fixtures/v8project-extension.yaml`, `tools/tests/fixtures/v8project-epf.yaml`
- Test: `tools/tests/V8Project.Tests.ps1`, `tools/tests/Check.Manifest.Tests.ps1` (новий `Describe`); тести, що пишуть `infobase:` у `v8project.local.yaml` (`grep -rln "'infobase:'" tools/tests`), — на `Set-KitFakeAgentBase`

**Interfaces:**
- Produces:
  - `Read-V8Project -Path` → `{Path; Directory; WorkPath; Providers; SourceSets}`. `InfobaseConnection` **прибрано**. `Providers` — `IDictionary` або `$null`.
  - `Read-V8ProjectLocalInfobase -Path` → `$null` або `{Connection; User; Password; Dbms}` (`Dbms` — `IDictionary` або `$null`).
  - `Read-V8ProjectLocalInfobaseUser` — **видалено**.
  - `Resolve-V8AgentInfobase -Project` → `$null` або `{Connection; Origin; User; Password; Dbms}`; `Origin` — шлях `v8project.local.yaml`.
  - `Get-V8ProjectConfigProblems -Directory <тека воркспейсу>` → `string[]`, кожен рядок — повідомлення з рецептом.
  - `KitFixtures`: `Set-KitFakeAgentBase -Repo <string> -Workspace <string> -Connection <string> [-User] [-Password] [-Dbms <IDictionary>]`.

- [ ] **Step 1: Тести.** У `tools/tests/V8Project.Tests.ps1` додати:

```powershell
Describe 'Get-V8ProjectConfigProblems (спека §4.3 п. 3, 5; §10 П9, П10)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        function script:New-Ws { param([string]$Name, [string[]]$Project, [string[]]$Local)
            $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'v8project.yaml') -Encoding UTF8 -Value ($Project -join "`n")
            if ($Local) { Set-Content -LiteralPath (Join-Path $d 'v8project.local.yaml') -Encoding UTF8 -Value ($Local -join "`n") }
            $d }
        $script:Clean = @('format: DESIGNER', "workPath: 'build'", 'providers:', '  push: designer', '  pull: designer', '  download: designer',
            'source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
    }
    It 'чиста форма 0.13 — знахідок немає (вкладений tests.execution_timeout_seconds законний)' {
        $d = New-Ws -Name 'clean' -Project ($script:Clean + @('tests:', '  execution_timeout_seconds: 600')) -Local @('infobases:', '  origin:', "    connection: 'File=build/ib'")
        @(Get-V8ProjectConfigProblems -Directory $d) | Should -BeNullOrEmpty
    }
    It 'усі застарілі ключі — усі знахідки разом, кожна з рецептом' {
        $proj = @('builder: DESIGNER', 'execution_timeout: 600000', 'basePath: x', 'push:', '  partialLoadThreshold: 10',
                  'infobase:', "  connection: 'File=build/ib'") + $script:Clean
        $d = New-Ws -Name 'old' -Project $proj -Local @('infobase:', "  connection: 'File=build/ib'")
        $p = @(Get-V8ProjectConfigProblems -Directory $d)
        ($p -join "`n") | Should -BeLike "*'builder'*Видаліть рядок*"
        ($p -join "`n") | Should -BeLike "*'execution_timeout'*"
        ($p -join "`n") | Should -BeLike "*'basePath'*"
        ($p -join "`n") | Should -BeLike "*'push.partialLoadThreshold'*"
        @($p | Where-Object { $_ -like "*стара форма 'infobase:'*infobases.origin*" }).Count | Should -Be 2
    }
    It 'infobases у закоміченому v8project.yaml — знахідка з переносом у local' {
        $d = New-Ws -Name 'committed' -Project ($script:Clean + @('infobases:', '  origin:', "    connection: 'File=build/ib'"))
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike '*infobases*закомічен*v8project.local.yaml*'
    }
    It 'infobases з іменем, крім origin, — знахідка' {
        $d = New-Ws -Name 'other' -Project $script:Clean -Local @('infobases:', '  dev:', "    connection: 'File=D:\x'")
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike "*'dev'*лише origin*"
    }
    It 'origin без connection — знахідка, а не тиха відсутність бази (Review Focus 4)' {
        $d = New-Ws -Name 'noconn' -Project $script:Clean -Local @('infobases:', '  origin:', "    user: 'agent'")
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike '*infobases.origin*connection*'
    }
    It 'providers: <Case>' -ForEach @(
        @{ Case = 'відсутній';         Lines = @() ;                                                     Want = "*providers*push: designer*" }
        @{ Case = 'pull інший';        Lines = @('providers:', '  push: designer', '  pull: agent', '  download: designer'); Want = "*providers.pull*agent*designer*" }
        @{ Case = 'download відсутній'; Lines = @('providers:', '  push: designer', '  pull: designer');  Want = "*providers.download*" }
    ) {
        $proj = @('format: DESIGNER') + $Lines + @('source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
        $d = New-Ws -Name ("prov-" + [guid]::NewGuid().ToString('N')) -Project $proj
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike $Want
    }
    It 'інші ключі providers вільні' {
        $proj = @('format: DESIGNER', 'providers:', '  push: designer', '  pull: designer', '  download: designer', '  make: agent',
                  'source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
        $d = New-Ws -Name 'prov-extra' -Project $proj
        @(Get-V8ProjectConfigProblems -Directory $d) | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-V8AgentInfobase — лише infobases.origin у v8project.local.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
    }
    It 'повертає connection, user, password, dbms і Origin = local' {
        $d = Join-Path $TestDrive 'ws'; New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content (Join-Path $d 'v8project.local.yaml') -Encoding UTF8 -Value (@(
            'infobases:', '  origin:', "    connection: 'Srvr=VSDEV;Ref=agent;'", "    user: 'Агент'", "    password: 'p@ss'",
            '    dbms:', '      kind: PostgreSQL', '      server: pg1', '      name: agent_db', '      locale: uk') -join "`n")
        $ib = Resolve-V8AgentInfobase -Project ([pscustomobject]@{ Directory = $d; Path = (Join-Path $d 'v8project.yaml') })
        $ib.Connection | Should -Be 'Srvr=VSDEV;Ref=agent;'
        $ib.User | Should -Be 'Агент'
        $ib.Password | Should -Be 'p@ss'
        $ib.Dbms['name'] | Should -Be 'agent_db'
        $ib.Origin | Should -BeLike '*v8project.local.yaml'
    }
    It 'немає v8project.local.yaml — $null (бази не налаштовано)' {
        $d = Join-Path $TestDrive 'ws2'; New-Item -ItemType Directory -Path $d | Out-Null
        Resolve-V8AgentInfobase -Project ([pscustomobject]@{ Directory = $d; Path = (Join-Path $d 'v8project.yaml') }) | Should -BeNullOrEmpty
    }
}
```

У `tools/tests/Check.Manifest.Tests.ps1` новий `Describe`; підпроцес `kit.ps1` на синтетичному репо — зразок `Check.*`:

```powershell
Describe 'kit check і решта команд — застарілий конфіг Уніки зупиняє все (§10 П9)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Run { param([string]$Repo, [string[]]$Cmd)
            $out = & pwsh -NoProfile -File $script:Kit @Cmd -RepoRoot $Repo 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }
    It 'check: builder і infobase: у v8project.yaml — код 1, обидві знахідки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-cfg') -WithHooks -WithGitignore
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value @('builder: DESIGNER', 'infobase:', "  connection: 'File=build/ib'")
        $r = Run -Repo $repo -Cmd @('check')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*'builder'*"
        $r.Output | Should -BeLike "*стара форма 'infobase:'*"
    }
    It 'sync на застарілому конфігу — зупинка на префлайті, build/sync не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-sync') -WithHooks -WithGitignore
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value 'execution_timeout: 600000'
        $r = Run -Repo $repo -Cmd @('sync')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*'execution_timeout'*"
        Test-Path -LiteralPath (Join-Path $repo 'build/sync') | Should -BeFalse
    }
}
```

> Перевірки (kit-dev, case 21/22), до написання коду:
> - `grep -rn "Видаліть рядок\|стара форма 'infobase:'" tools/` — фрази мають з'явитись лише в `Get-V8ProjectConfigProblems`;
> - `check` друкує `$f.Message`, тож тест шукає текст повідомлення, а не ім'я перевірки;
> - префлайт зупиняє команду до платформи — тому `build/sync` не створено. Перед тим як писати тест, перевірити читанням `tools/kit.ps1`, що знахідка `error` префлайту справді зупиняє всі команди, крім `check`/`session-check` (так сьогодні працює відсутній `v8project.yaml`); якщо ні — зупинка й питання контролеру, не обхід.

- [ ] **Step 2: Прогін — червоний.** Очікувано: `Get-V8ProjectConfigProblems` не знайдено; `check` на `builder:` дає код 0.

- [ ] **Step 3: Реалізація `V8Project.psm1`.**
  - У `Read-V8Project`:
    - прибрати блок `$connection` і поле `InfobaseConnection`;
    - додати `Providers = $(if ($data.Contains('providers') -and $data['providers'] -is [System.Collections.IDictionary]) { $data['providers'] } else { $null })`;
    - `.DESCRIPTION` доповнити: «База агента тут не читається — лише `infobases.origin` у `v8project.local.yaml` (Resolve-V8AgentInfobase)».
  - Замінити `Read-V8ProjectLocalInfobase` і видалити `Read-V8ProjectLocalInfobaseUser`:

```powershell
function Read-V8ProjectLocalInfobase {
    <#
    .SYNOPSIS
        infobases.origin з v8project.local.yaml → {Connection; User; Password; Dbms} або $null.
    .DESCRIPTION
        Єдина форма бази агента в kit 1.5.0 (спека 2026-10-11 §4.3 п. 2–3, рішення 9): та сама, з
        якої базу бере Уніка 0.13. Старої infobase: kit не читає зовсім — вона знахідка
        Get-V8ProjectConfigProblems, а не запасне читання. $null — бази не налаштовано на цій
        машині (свіжий клон): що це означає, вирішує викликач за типами наборів воркспейсу
        (Test-KitWorkspaceNeedsAgentBase, AgentBase.psm1). Пароль іде лише в Invoke-V8Designer
        і ніколи у вивід.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $data = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $data -or -not $data.Contains('infobases')) { return $null }
    $ibs = $data['infobases']
    if ($ibs -isnot [System.Collections.IDictionary] -or -not $ibs.Contains('origin')) { return $null }
    $o = $ibs['origin']
    if ($o -isnot [System.Collections.IDictionary]) { return $null }
    $connection = if ($o.Contains('connection')) { [string]$o['connection'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($connection)) { return $null }
    [pscustomobject]@{
        Connection = $connection
        User       = $(if ($o.Contains('user')) { [string]$o['user'] } else { '' })
        Password   = $(if ($o.Contains('password')) { [string]$o['password'] } else { '' })
        Dbms       = $(if ($o.Contains('dbms') -and $o['dbms'] -is [System.Collections.IDictionary]) { $o['dbms'] } else { $null })
    }
}
```

  - `Resolve-V8AgentInfobase`:

```powershell
    $localPath = Join-Path $Project.Directory 'v8project.local.yaml'
    $o = Read-V8ProjectLocalInfobase -Path $localPath
    if ($null -eq $o) { return $null }
    [pscustomobject]@{ Connection = $o.Connection; Origin = $localPath; User = $o.User; Password = $o.Password; Dbms = $o.Dbms }
```

  (у `.SYNOPSIS`: «База агента так, як її бачить Unica 0.13: `infobases.origin` у `v8project.local.yaml`, і лише там».)

  - Нова функція:

```powershell
function Get-V8ProjectConfigProblems {
    <#
    .SYNOPSIS
        Знахідки конфігу воркспейсу, з яким Уніка 0.13 чи kit 1.5.0 не працюють, — кожна з рецептом.
    .DESCRIPTION
        Одне місце правил (спека 2026-10-11 §4.3 п. 3, 5; §10 П9, П10): префлайт перетворює кожен
        рядок на fail 'workspace', тож на застарілому конфігу зупиняється БУДЬ-ЯКА команда kit, а
        kit check показує всі рядки разом. Сумісних читань немає (рішення 9): стара форма — це
        знахідка, не другий шлях.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    $problems = [System.Collections.Generic.List[string]]::new()
    $localPath = Join-Path $Directory 'v8project.local.yaml'
    $files = @(
        [pscustomobject]@{ Path = (Join-Path $Directory 'v8project.yaml'); Committed = $true }
        [pscustomobject]@{ Path = $localPath; Committed = $false }
    )
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) { continue }
        $data = Read-KitYaml -Path $file.Path -AllowEmpty
        if ($null -eq $data) { continue }
        $p = $file.Path

        # Лише верхній рівень: вкладений tests.execution_timeout_seconds Уніка 0.13 приймає
        # (runner_014.rs, validate_layer); builder відхиляє сам раннер 0.14.
        foreach ($key in 'builder', 'execution_timeout', 'execution_timeout_seconds', 'basePath') {
            if ($data.Contains($key)) { $problems.Add("${p}: ключ '$key' Уніка 0.13 / v8-runner 0.14 не приймають — з ним вони відмовляються працювати. Видаліть рядок.") }
        }
        foreach ($section in 'push', 'build') {
            if ($data.Contains($section) -and $data[$section] -is [System.Collections.IDictionary] -and $data[$section].Contains('partialLoadThreshold')) {
                $problems.Add("${p}: ключ '$section.partialLoadThreshold' Уніка 0.13 не приймає. Видаліть рядок.")
            }
        }
        if ($data.Contains('source-set') -and $data['source-set'] -is [System.Collections.IList]) {
            foreach ($set in $data['source-set']) {
                if ($set -is [System.Collections.IDictionary] -and $set.Contains('basePath')) {
                    $problems.Add("${p}: ключ 'basePath' у source-set '$($set['name'])' Уніка 0.13 не приймає. Видаліть рядок.")
                }
            }
        }
        if ($data.Contains('infobase')) {
            # Політика kit (рішення 9 спеки), не відмова Уніки: Уніка 0.13 стару форму ще приймає
            # проєкцією — тому в тексті не писати, що її «відхиляє Уніка».
            $problems.Add("${p}: стара форма 'infobase:' — kit 1.5.0 читає базу агента лише з infobases.origin " +
                "у $localPath (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у $localPath і " +
                'приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.5.0»).')
        }
        if ($data.Contains('infobases')) {
            if ($file.Committed) {
                $problems.Add("${p}: infobases у закоміченому v8project.yaml — база агента машинна й може нести пароль. Перенесіть блок у $localPath (гітігнорований).")
            } elseif ($data['infobases'] -is [System.Collections.IDictionary]) {
                foreach ($name in @($data['infobases'].Keys)) {
                    if ($name -ne 'origin') {
                        $problems.Add("${p}: infobases.'$name' — Уніка обслуговує лише origin, і kit читає лише origin; інша назва означала б, що аудит перевіряє не ту базу. Перейменуйте на origin або приберіть.")
                    }
                }
                if ($data['infobases'].Contains('origin')) {
                    $o = $data['infobases']['origin']
                    if ($o -isnot [System.Collections.IDictionary] -or -not $o.Contains('connection') -or [string]::IsNullOrWhiteSpace([string]$o['connection'])) {
                        $problems.Add("${p}: infobases.origin без connection — база агента оголошена, але не описана. Допишіть connection: 'File=build/ib' (файлова) або 'Srvr=…;Ref=…;' (серверна) — скіл v8storagekit:provision.")
                    }
                }
            }
        }
        if ($file.Committed) {
            $providers = if ($data.Contains('providers')) { $data['providers'] } else { $null }
            if ($providers -isnot [System.Collections.IDictionary]) {
                $problems.Add("${p}: немає providers — запис і завантаження бази агента мусить робити один виконавець (інваріант C1; дефект раннера #459). Додайте: providers: { push: designer, pull: designer, download: designer }.")
            } else {
                foreach ($op in 'push', 'pull', 'download') {
                    $v = if ($providers.Contains($op)) { [string]$providers[$op] } else { '' }
                    if ($v -ne 'designer') {
                        $shown = if ($v) { "'$v'" } else { 'відсутній' }
                        $problems.Add("${p}: providers.$op — $shown, потрібно designer (інваріант C1; агентський режим раннера на Windows не заміряний, #429).")
                    }
                }
            }
        }
    }
    # БЕЗ коми-обгортки: викликачі загортають у @(...), і `, $arr` дав би масив з ОДНОГО
    # елемента навіть без знахідок (аудит плану: @(f).Count = 1) — префлайт тоді пропускав би
    # кожен воркспейс. Той самий урок, що в Select-KitSources.
    $problems.ToArray()
}
```

`Export-ModuleMember -Function Read-V8Project, Read-V8ProjectLocalInfobase, Resolve-V8AgentInfobase, Resolve-KitAgentInfobasePath, Get-V8ProjectConfigProblems`.

- [ ] **Step 4: Префлайт** — у `Invoke-KitPreflight`, у циклі воркспейсів, одразу після перевірки наявності `v8project.yaml` і **до** `Read-V8Project`:

```powershell
        $cfgProblems = @()
        try { $cfgProblems = @(Get-V8ProjectConfigProblems -Directory $wsFull) }
        catch { & $fail 'workspace' "Конфіг Уніки воркспейсу '$($ws.Path)' не читається: $($_.Exception.Message)"; continue }
        foreach ($problem in $cfgProblems) { & $fail 'workspace' $problem }
        if ($cfgProblems.Count -gt 0) { continue }
```

- [ ] **Step 5: `check.psm1`, аудит `v8project.local.yaml`.**
  - `$localConn = $null; try { $localIb = Read-V8ProjectLocalInfobase -Path $localPath; if ($localIb) { $localConn = $localIb.Connection } } catch { … як було … }`.
  - Тексти знахідок: `infobase.connection` → `infobases.origin.connection`; «operation=build писав би в неї. Приберіть infobase: звідти» → «Уніка (`push`) писала б у неї. Приберіть infobases.origin звідти й дайте агентові окрему базу (v8storagekit:provision)».

- [ ] **Step 6: Фікстура `KitFixtures.psm1`.**
  - Після `config core.autocrlf false`:

    ```powershell
    Add-Content -LiteralPath (Join-Path $Root '.git/info/exclude') -Value 'v8project.local.yaml' -Encoding UTF8
    ```

    Коментар: файл Уніки гітігнорований у кожного споживача; без цього `git add -A` фікстури закомітив би його, а злиття в main відмовило б на брудній копії.
  - Блок `$proj`:

```powershell
        $proj = [System.Collections.Generic.List[string]]::new()
        $proj.Add('format: DESIGNER'); $proj.Add("workPath: 'build'")
        $proj.Add('providers:'); $proj.Add('  push: designer'); $proj.Add('  pull: designer'); $proj.Add('  download: designer')
        if ($ws.Contains('Infobase') -and $ws['Infobase']) {
            Set-Content -LiteralPath (Join-Path $wsDir 'v8project.local.yaml') -Encoding UTF8 -Value (
                @('infobases:', '  origin:', "    connection: '$($ws['Infobase'])'") -join "`n")
            if ($WithAgentBase) { … як було … }
        }
```

  - Нова функція — **додати в явний перелік `Export-ModuleMember` наприкінці `KitFixtures.psm1`**:

```powershell
function Set-KitFakeAgentBase {
    <#
    .SYNOPSIS
        Пише <Workspace>/v8project.local.yaml у формі 0.13 (infobases.origin) — замість ручного Set-Content у тестах.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Workspace = 'Alpha_SMB',
        [Parameter(Mandatory)][string]$Connection,
        [string]$User,
        [string]$Password,
        [System.Collections.IDictionary]$Dbms
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('infobases:'); $lines.Add('  origin:'); $lines.Add("    connection: '$Connection'")
    if ($User)     { $lines.Add("    user: '$User'") }
    if ($Password) { $lines.Add("    password: '$Password'") }
    if ($Dbms) {
        $lines.Add('    dbms:')
        foreach ($k in @($Dbms.Keys)) { $lines.Add("      ${k}: '$($Dbms[$k])'") }
    }
    Set-Content -LiteralPath (Join-Path (Join-Path $Repo $Workspace) 'v8project.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
}
```

  - `v8project-extension.yaml`, `v8project-epf.yaml`: прибрати `builder`, `execution_timeout`, `infobase:`; додати блок `providers` (три ключі).

- [ ] **Step 7: Наявні тести.**
  - Кожен запис старої форми в `v8project.local.yaml` — і в одинарних лапках (`@('infobase:', …)`), і в подвійних (`"infobase:`n  connection…"`, `"infobase:`r`n …"`) — → `Set-KitFakeAgentBase -Repo $repo -Connection '…'`. Перелік — `grep -rn "infobase:" tools/tests` (без лапок), до нуля збігів поза тестами самої знахідки «стара форма». Відомі місця: `Check.Names.Tests.ps1` (вісім), `Check.Manifest.Tests.ps1`, `Canon.Tests.ps1`, `Provision.Tests.ps1` (кілька), `AgentBase.Tests.ps1`.
  - Тести, що читали `InfobaseConnection` чи `Read-V8ProjectLocalInfobaseUser`, переписати на нові поля; `AgentBase.Tests.ps1` «Origin … `*v8project.yaml`» → `*v8project.local.yaml`; `V8Project.Tests.ps1` «накладка Уніки виграє у закоміченого» — прибрати (закоміченої бази більше немає), покриття — новий `Describe 'Resolve-V8AgentInfobase …'`.
  - Тест `Check.AgentBase` про базу «лише в закоміченому `v8project.yaml`» — тепер це знахідка конфігу; переписати на очікування `error` з `*стара форма 'infobase:'*`.
  - `.git/info/exclude` у фікстурі прибирає знахідку `local-ignored` у репо без `-WithGitignore` (`git check-ignore --no-index` бачить exclude). Тесту на цю знахідку зараз немає; додати в `Check.Manifest.Tests.ps1`:

```powershell
    It 'v8project.local.yaml не гітігноровано правилом репозиторію — error local-ignored (exclude фікстури прибрано)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'local-not-ignored') -WithHooks
        $ex = Join-Path $repo '.git/info/exclude'
        Set-Content -LiteralPath $ex -Value (@(Get-Content -LiteralPath $ex | Where-Object { $_ -ne 'v8project.local.yaml' })) -Encoding UTF8
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo
        $r.Output | Should -BeLike '*v8project.local.yaml не гітігноровано*'
    }
```

  - Нові тести підпроцесом кличуть наявний `Invoke-KitCommand -Kit … -Command … -Repo …` (`KitFixtures.psm1`), а не власний `Run`-хелпер — одна точка запуску, у якої є свій тест. У прикладах цього плану `Run`/`Invoke-Provision` замінити на неї, якщо сигнатура дозволяє передати додаткові аргументи; інакше лишити наявний хелпер файлу.

- [ ] **Step 8: Прогін — зелений** (повний набір).

- [ ] **Step 9: Мутація** — на копії дерева прибрати в `Preflight.psm1` рядок `if ($cfgProblems.Count -gt 0) { continue }` разом із циклом `foreach ($problem …)`. Тест «sync на застарілому конфігу» червоний (код 0 або інший текст); текст падіння — у звіт.

- [ ] **Step 10 (контролер, з дозволу людини): Коміт.** Тема: `§4.3 п.3/п.5: база агента лише з infobases.origin; застарілий конфіг Уніки — помилка скрізь`.

### Task 4: Вид воркспейсу (П16) і пароль бази агента (#26)

**Рівень ризику:** властивість безпеки (пароль не потрапляє у вивід) → два рев'ю.

**Files:**
- Modify: `tools/lib/AgentBase.psm1` (`Resolve-KitAgentBase` + дві нові функції)
- Modify: `tools/lib/V8.psm1` (`Invoke-V8Designer` — відмова на `"` у паролі)
- Modify: `tools/lib/StoragePlatform.psm1`:
  - `Get-KitSourceInfobase`;
  - `-Password` у `Invoke-KitStorageUpdate`, `Invoke-KitStorageCheckout`, `Invoke-KitStorageCheckoutViaPlatform` — лише виклики з базою агента; виклики тимчасової `alt-ib` без пароля;
  - `Enter-/Exit-KitStorageBind` **не чіпати** (§10 П12).
- Modify: `tools/lib/StorageReport.psm1` — `-Password` (пароль **бази агента**) у `Get-StorageVersions` і в тій функції звіту, що кличе `Invoke-V8Designer`; **не** в `Get-StorageReportArguments` — там лише `StoragePassword` сховища, інша сутність.
- Modify: `tools/commands/sync.psm1`, `verify.psm1`, `canon.psm1` — передача пароля.
- Modify: `tools/commands/check.psm1` — знахідка `agent-base-required`.
- Test: `tools/tests/AgentBase.Tests.ps1`, `V8.Tests.ps1`, `StoragePlatform.Tests.ps1`, `Canon.Tests.ps1`, `Check.AgentBase.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-V8AgentInfobase` (Task 3) → `{Connection; Origin; User; Password; Dbms}`.
- Produces:
  - `Resolve-KitAgentBase` → `{Workspace; Connection; User; Password; Dbms; Origin; Kind; Path; IbSwitch; Exists}` або `$null`;
  - `Test-KitWorkspaceNeedsAgentBase -Workspace` → `bool` (є набір `CONFIGURATION` чи `EXTENSION`);
  - `New-KitAgentBaseMissingMessage -WorkspacePath` → `string`;
  - `Get-KitSourceInfobase` → `{IbSwitch; User; Password; Kind; Workspace}` (`Kind` — `file`/`server`, для кроку вирівнювання Tasks 9–10);
  - `Invoke-KitStorageCheckout … [-Password <string>]`, `Invoke-KitStorageCheckoutViaPlatform … [-Password]`, `Get-StorageVersions … [-Password]`.

- [ ] **Step 1: Тести.**

`tools/tests/V8.Tests.ps1`:

```powershell
Describe 'Invoke-V8Designer — пароль (#26, Review Focus 2)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }
    It 'пароль із подвійною лапкою — відмова до запуску платформи, пароль у тексті не з''являється' {
        $err = $null
        try { Invoke-V8Designer -IbSwitch '/F "C:\x"' -Arguments @('/DumpCfg "C:\y.cf"') -Password 'ab"c-секрет' -V8Path 'C:\no-such\1cv8.exe' }
        catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*подвійну лапку*'
        $err | Should -Not -BeLike '*секрет*'
    }
    It 'пароль у Write-Verbose замасковано, але платформа його отримує' {
        Mock -ModuleName V8 Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $old = $global:VerbosePreference; $global:VerbosePreference = 'Continue'
        try { $out = & { Invoke-V8Designer -IbSwitch '/F "C:\x"' -Arguments @('/DumpCfg "C:\y.cf"') -User 'agent' -Password 'S3cr3t-Пароль' -V8Path 'C:\fake\1cv8.exe' } 4>&1 | Out-String }
        finally { $global:VerbosePreference = $old }
        $out | Should -Not -BeLike '*S3cr3t*'
        $out | Should -BeLike '*/P "[*][*][*]"*'
        Should -Invoke -ModuleName V8 Start-Process -Times 1 -ParameterFilter { $ArgumentList -like '*/P "S3cr3t-Пароль"*' }
    }
}
```

`tools/tests/Canon.Tests.ps1` — новий `Describe` у процесі (зразок — блок «мок платформного шару» у `Verify.Tests.ps1`: завантаження `module-order.txt`, потім командний модуль):

```powershell
Describe 'kit canon — пароль бази агента доходить до платформи й не потрапляє у вивід (#26, §10 П12)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/canon.psm1").Path -Force
    }
    It 'canon -Apply: /P "***" у Verbose, справжній пароль — лише в аргументах Start-Process' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'pwd') -WithHooks -WithAgentBase
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -User 'agent' -Password 'S3cr3t-Пароль'
        # Без моку Get-V8Path тест залежав би від установленої платформи 8.3.27.x (kit-dev (б)).
        Mock -ModuleName V8 Get-V8Path { 'C:\fake\1cv8.exe' }
        Mock -ModuleName V8 Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $old = $global:VerbosePreference; $global:VerbosePreference = 'Continue'
        try { $out = & { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } *>&1 | Out-String }
        finally { $global:VerbosePreference = $old }
        $out | Should -Not -BeLike '*S3cr3t*'
        Should -Invoke -ModuleName V8 Start-Process -ParameterFilter { $ArgumentList -like '*/N "agent"*/P "S3cr3t-Пароль"*' }
    }
}
```

`tools/tests/StoragePlatform.Tests.ps1`:

```powershell
It 'Invoke-KitStorageCheckout передає -Password в обидва виклики платформи (UpdateCfg і DumpConfigToFiles)' {
    Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    $src = [pscustomobject]@{ Key = 'Alpha_SMB'; Type = 'EXTENSION'; StoragePath = 'C:\s'; StorageUser = 'u'; StoragePassword = '' }
    $t = Join-Path $TestDrive 'co'
    $null = Invoke-KitStorageCheckout -IbSwitch '/F "C:\ib"' -Source $src -Version 3 -Target $t -MustBeUnder $TestDrive -User 'agent' -Password 'pw'
    Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2 -Exactly -ParameterFilter { $Password -eq 'pw' -and $User -eq 'agent' }
}
It 'Invoke-KitStorageCheckoutViaPlatform: пароль — у UpdateCfg і DumpCfg бази агента, НЕ в LoadCfg/дампі тимчасової alt-ib' {
    Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    Mock -ModuleName StoragePlatform New-V8FileInfobase { $Path }
    $src = [pscustomobject]@{ Key = 'base'; Type = 'CONFIGURATION'; StoragePath = 'C:\s'; StorageUser = 'u'; StoragePassword = '' }
    $wd = Join-Path $TestDrive 'via'; New-Item -ItemType Directory -Path $wd -Force | Out-Null
    try {
        $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch '/F "C:\ib"' -Source $src -Version 3 -Target (Join-Path $wd 'out') `
            -MustBeUnder $wd -WorkDir $wd -AltV8Path 'C:\alt\1cv8.exe' -User 'agent' -Password 'pw'
    } catch { }   # виклик може впасти далі на відсутньому .cf від моку — перевіряємо лише аргументи викликів платформи
    Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -ParameterFilter { $IbSwitch -eq '/F "C:\ib"' -and $Password -eq 'pw' } -Times 2 -Exactly
    Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -ParameterFilter { $IbSwitch -ne '/F "C:\ib"' -and $Password } -Times 0 -Exactly
}
```

`tools/tests/StorageReport.Tests.ps1` (наявний файл мокає `Invoke-V8Designer` за `-ModuleName StorageReport`):

```powershell
It 'Get-StorageVersions передає пароль бази агента в Invoke-V8Designer, а пароль сховища — лише аргументом /ConfigurationRepositoryP' {
    Mock -ModuleName StorageReport Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    $wd = Join-Path $TestDrive 'rep'; New-Item -ItemType Directory -Path $wd -Force | Out-Null
    try { $null = Get-StorageVersions -IbSwitch '/F "C:\ib"' -StoragePath 'C:\s' -StorageUser 'su' -StoragePassword 'sp' -WorkDir $wd -User 'agent' -Password 'pw' } catch { }
    Should -Invoke -ModuleName StorageReport Invoke-V8Designer -ParameterFilter { $Password -eq 'pw' -and $User -eq 'agent' } -Times 1
}
```

(Імена параметрів `Get-StorageVersions` звірити з фактичною сигнатурою перед написанням; `try/catch` — бо мок не пише файлу звіту, і розбір після виклику може кинути.)

`tools/tests/AgentBase.Tests.ps1`:

```powershell
It 'П16: воркспейс з EXTENSION без infobases.origin — потребує бази, Resolve-KitAgentBase дає $null' {
    $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-origin') -Workspaces ([ordered]@{
        'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } })
    $ctx = Invoke-KitPreflight -RepoRoot $repo
    $ws = $ctx.Workspaces[0]
    Test-KitWorkspaceNeedsAgentBase -Workspace $ws | Should -BeTrue
    Resolve-KitAgentBase -Context $ctx -Workspace $ws | Should -BeNullOrEmpty
    New-KitAgentBaseMissingMessage -WorkspacePath 'Alpha_SMB' | Should -BeLike '*infobases.origin*v8storagekit:provision*'
}
It 'П16: воркспейс лише з EXTERNAL_DATA_PROCESSORS — бази не потребує' {
    $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces ([ordered]@{
        'Epf' = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } })
    $ctx = Invoke-KitPreflight -RepoRoot $repo
    Test-KitWorkspaceNeedsAgentBase -Workspace $ctx.Workspaces[0] | Should -BeFalse
}
```

(Ці тести імпортують модулі так само, як решта `AgentBase.Tests.ps1`; якщо файл не вантажить `Preflight`, — імпорт за `module-order.txt`, як вище.)

`tools/tests/Check.AgentBase.Tests.ps1` — підпроцес:

```powershell
It 'П16: truth: storage без infobases.origin — warn з рецептом v8storagekit:provision, не error' {
    $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'p16') -WithHooks -WithGitignore -Workspaces ([ordered]@{
        'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } })
    $r = Invoke-Check -Repo $repo
    $r.Output | Should -BeLike '*[!]*Alpha_SMB*не налаштована*v8storagekit:provision*'
}
```

(`Invoke-Check` — наявний хелпер файлу. Якщо хелпер зветься інакше, — його ім'я з `BeforeAll` того самого файлу.)

> Перевірки до коду:
> - `grep -rn "не налаштована" tools/commands tools/lib` — фраза лише в `New-KitAgentBaseMissingMessage`;
> - `grep -rn "подвійну лапку" tools/` — лише в `Invoke-V8Designer`.

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: `AgentBase.psm1`.**
  - У `Resolve-KitAgentBase` в об'єкт результату додати `Password = $ib.Password; Dbms = $ib.Dbms`.
  - У `.DESCRIPTION` замінити «v8project.local.yaml або v8project.yaml» на «`infobases.origin` у `v8project.local.yaml`».
  - `$null` — «бази не налаштовано на цій машині»; що це означає, вирішує викликач через `Test-KitWorkspaceNeedsAgentBase`.
  - Текст збігу з дев-базою: «приберіть `infobases.origin` з v8project.local.yaml або дайте агентові окрему базу».
  - Нові функції (додати в `Export-ModuleMember`):

```powershell
function Test-KitWorkspaceNeedsAgentBase {
    <#
    .SYNOPSIS
        Чи потребує воркспейс бази агента — за ТИПАМИ наборів, не за наявністю бази (спека §10 П16).
    .DESCRIPTION
        До 1.5.0 «у v8project.yaml немає infobase:» означало «зовнішні обробки». Тепер база живе
        лише в гітігнорованому v8project.local.yaml, і на свіжому клоні її немає ніде — без цієї
        функції свіжий клон воркспейсу з розширенням виглядав би як воркспейс обробок, і kit
        мовчав би там, де мусить зупинити з рецептом.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)
    @($Workspace.Project.SourceSets | Where-Object { $_.Type -in 'CONFIGURATION', 'EXTENSION' }).Count -gt 0
}

function New-KitAgentBaseMissingMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)
    ("База агента воркспейсу '$WorkspacePath' не налаштована: у $WorkspacePath/v8project.local.yaml немає infobases.origin " +
     '(файл гітігнорований — на свіжому клоні його ще немає). Налаштувати й розгорнути базу — скіл v8storagekit:provision, тоді повторіть команду.')
}
```

- [ ] **Step 4: `Invoke-V8Designer`** — першим рядком тіла, до `Get-V8Path`:

```powershell
    if ($Password -and $Password.Contains('"')) {
        throw ('Пароль бази містить подвійну лапку — платформа не приймає його в /P "…", а маска виводу (Hide-V8Secrets) ' +
               'обірвалась би на ній і показала б решту пароля. Змініть пароль користувача бази.')
    }
```

- [ ] **Step 5: Передача пароля.** У кожній названій функції — параметр `[string]$Password = ''` і `-Password $Password` у виклик `Invoke-V8Designer` з базою агента.
  - `sync.psm1`:
    - поруч з `$ibUser = $agent.User` — `$ibPassword = $agent.Password`;
    - у гілці запасного шляху — `$ibPassword = ''`;
    - `-Password $ibPassword` у обидва `Get-StorageVersions`, `Invoke-KitStorageCheckout`, `Invoke-KitStorageCheckoutViaPlatform`.
  - `verify.psm1`: `-Password $agent.Password` в `Invoke-KitStorageCheckout`.
  - `canon.psm1`: `-Password $ab.Password` в `Invoke-V8Designer`.

- [ ] **Step 6: Відсутня база (П16).**
  - `Get-KitSourceInfobase` (`StoragePlatform.psm1`):

```powershell
    $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
    if ($null -eq $ab) { throw (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path) }
    if ($ab.Kind -eq 'file' -and -not $ab.Exists) {
        throw ("Бази агента воркспейсу '$($ws.Path)' ще немає на диску ($($ab.Path)), а джерело '$($Source.Key)' (truth: storage) " +
               'вивантажується в контексті базової конфігурації. Спершу v8storagekit:provision (kit provision -Workspace ' +
               "$($ws.Path) -Apply і надрукований ним крок), тоді повторіть команду.")
    }
    [pscustomobject]@{ IbSwitch = $ab.IbSwitch; User = $ab.User; Password = $ab.Password; Kind = $ab.Kind; Workspace = $ws.Path }
```

  (`Kind` — `file`/`server`; його бере крок вирівнювання `sync`/`verify`, Tasks 9–10. Моки `Get-KitSourceInfobase` у наявних тестах, що повертають об'єкт без `Kind`, дописати `Kind = 'file'`.)

  - `canon.psm1`:
    - рядок `if ($null -eq $ab) { … 'у v8project.yaml немає infobase:' … }` → `if ($null -eq $ab) { throw (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path) }` (цілі canon — лише `CONFIGURATION`/`EXTENSION`, тож бази потребує завжди);
    - зупинка «Бази агента ще немає» → `"Бази агента ще немає: $($ab.Path). Спершу v8storagekit:provision, тоді canon."`.
  - `check.psm1`, знахідка `agent-base-required`:

```powershell
            if ($null -eq $ab) {
                & $add 'warn' 'agent-base-required' ("Джерело '$($src.Key)' (truth: storage) вивантажується в контексті базової конфігурації. " + (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path))
            } elseif ($ab.Kind -eq 'file' -and -not $ab.Exists) {
                & $add 'warn' 'agent-base-required' ("Джерело '$($src.Key)' (truth: storage) вивантажується в контексті базової конфігурації, а бази агента " +
                    "воркспейсу '$($ws.Path)' ще немає на диску: v8storagekit:provision.")
            }
```

  - Тести, що чекали старих рецептів, переписати (унікальність кожної нової фрази — `grep` по `tools/`):
    - `StoragePlatform.Tests.ps1` «`*kit provision*operation=build*`» → `*v8storagekit:provision*`; у трьох моках `Resolve-KitAgentBase` того самого файлу дописати `Password = ''` — інакше під StrictMode `PropertyNotFound` на `$ab.Password`;
    - `Check.AgentBase.Tests.ps1`: позитивна перевірка `*kit provision*` → `*v8storagekit:provision*`; заперечна `-Not -BeLike '*kit provision*'` → `-Not -BeLike '*v8storagekit:provision*'` (інакше тавтологія — нового тексту з пробілом «kit provision» немає взагалі);
    - `Sync.Guards.Tests.ps1`: перевірка `*kit provision*` + `*operation=build*` → `*v8storagekit:provision*` (друга фраза зникає разом зі старим текстом); тест «немає infobase:» → П16 «не налаштована».

- [ ] **Step 7: Прогін — зелений.**

- [ ] **Step 8: Мутації — на копії дерева, кожна окремо, текст падіння у звіт:**
  - (а) у `Hide-V8Secrets` прибрати `-replace …` (повернути `$ArgLine`) — червоніють обидва тести «замасковано» (`V8.Tests`) і «canon -Apply» (`Canon.Tests`);
  - (б) у `canon.psm1` прибрати `-Password $ab.Password` — червоніє `ParameterFilter` тесту canon;
  - (в) у `sync.psm1` прибрати `-Password $ibPassword` з виклику `Get-StorageVersions` — червоніє тест нижче (Step 8а).

- [ ] **Step 8а: Тест проводки пароля через `sync`** — у `tools/tests/Sync.Merge.Tests.ps1` (той самий `BeforeAll` з `module-order.txt` і моками), бо тести модулів окремо не бачать, що `sync` пароль узагалі передає:

```powershell
    It '#26: sync передає пароль бази агента в Get-StorageVersions і в Invoke-KitStorageCheckout' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'pwd-sync') -WithHooks -WithAgentBase -WithGitignore
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -User 'agent' -Password 'pw'
        $storageDir = Join-Path $TestDrive 'pwd-sync-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7) }
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        Should -Invoke -ModuleName sync Get-StorageVersions -ParameterFilter { $Password -eq 'pw' -and $User -eq 'agent' } -Times 1
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -ParameterFilter { $Password -eq 'pw' } -Times 2
    }
```

- [ ] **Step 9 (контролер, з дозволу людини): Коміт.** Тема: `#26 і §10 П16: пароль бази агента в усіх викликах платформи; вид воркспейсу за типами наборів`.

### Task 5: Версія Уніки як вимога (§4.4 п. 4, §10 П11)

**Рівень ризику:** спільний код (`check` біжить у кожній сесії через `session-check`).

**Files:**
- Modify: `tools/lib/Environment.psm1` (нова `Get-KitUnicaVersionVerdict`)
- Modify: `tools/lib/module-order.txt` — додати `Environment` одразу після `RepoRoot`; у шапці файлу дописати: «Environment — без залежностей; check бере звідти Get-UnicaInstallation і Get-KitUnicaVersionVerdict»
- Modify: `tools/commands/check.psm1` — параметр `-InstalledPluginsPath`, знахідка `unica-version` на початку `Invoke-KitCheck`, **поза** `if ($Context.Manifest)`
- Modify: `tools/commands/session-check.psm1` — параметр `-InstalledPluginsPath`, прокидається в `Invoke-KitCheck`
- Modify: `tools/check-environment.ps1` — блок «Вихідники»
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — `New-KitFakeUnicaRegistry`; `Invoke-KitCommand` для `check`/`session-check` додає `-InstalledPluginsPath` фальшивого реєстру, якщо викликач його не передав
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` — прибрати виняток «крім Environment» (фільтр `-ne 'Environment'` і слова в назві `It`), додати в `RequiredCommands` `Get-UnicaInstallation`, `Get-KitUnicaVersionVerdict`
- Modify: кожен тест, що кличе `check`/`session-check` в обхід `Invoke-KitCommand` (підпроцес напряму чи `Invoke-KitCheck`/`Invoke-KitSessionCheck` у процесі) — передати `-InstalledPluginsPath (New-KitFakeUnicaRegistry)`. Перелік — `grep -rn "Invoke-KitCheck\|Invoke-KitSessionCheck\|kit.ps1.* check\|\$script:Kit check\|\$script:Kit session-check" tools/tests`
- Test: `tools/tests/Environment.Tests.ps1`, `tools/tests/Check.Manifest.Tests.ps1`

**Interfaces:**
- Consumes: `Get-UnicaInstallation -InstalledPluginsPath` → `{Installed; Version; InstallPath; PathExists; Reason}`.
- Produces:
  - `Get-KitUnicaVersionVerdict -Installation` → `{Level = 'ok'|'info'|'warn'|'error'; Message}`;
  - `kit check [-InstalledPluginsPath <шлях>]`, `kit session-check [-InstalledPluginsPath <шлях>]` — за замовчуванням реєстр машини `~/.claude/plugins/installed_plugins.json` (спека §10.1 П21: жодної змінної оточення, яку production читає заради тестів);
  - `New-KitFakeUnicaRegistry [-Version <string>='0.13.0']` (`KitFixtures`) → шлях до фальшивого `installed_plugins.json` у `$TestDrive`.

- [ ] **Step 1: Тести.** `tools/tests/Environment.Tests.ps1`:

```powershell
Describe 'Get-KitUnicaVersionVerdict (§4.4 п. 4, §10 П11)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/Environment.psm1").Path -Force }
    It '<V> → <Level>' -ForEach @(
        @{ V = '0.12.3'; Level = 'error' }
        @{ V = '0.13.0'; Level = 'ok' }
        @{ V = '0.13.9'; Level = 'ok' }
        @{ V = '0.14.0'; Level = 'warn' }
        @{ V = '1.0.0';  Level = 'warn' }
        @{ V = 'dev';    Level = 'warn' }
    ) {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = $V; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Level | Should -Be $Level
    }
    It 'error називає рецепт оновлення' {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = '0.12.3'; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Message | Should -BeLike '*0.12.3*claude plugin update unica@unica*нову сесію*'
    }
    It 'warn називає процедуру E контракту' {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = '0.14.0'; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Message | Should -BeLike '*процедур*E*unica-contract.md*'
    }
    It 'Уніки немає — info, kit працює й без неї' {
        $i = [pscustomobject]@{ Installed = $false; PathExists = $false; Version = ''; InstallPath = ''; Reason = 'немає в реєстрі' }
        $v = Get-KitUnicaVersionVerdict -Installation $i
        $v.Level | Should -Be 'info'
        $v.Message | Should -BeLike '*немає в реєстрі*'
    }
}
```

`tools/tests/Check.Manifest.Tests.ps1`:

```powershell
Describe 'kit check — версія Уніки (§4.4 п. 4)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
    }
    It 'Уніка 0.12.3 у реєстрі — код 1, рецепт оновлення' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-unica') -WithHooks -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.12.3'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*[-]*0.12.3*claude plugin update unica@unica*'
    }
    It 'Уніка 0.13.0 — знахідки unica-version немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'new-unica') -WithHooks -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.13.0'))
        $r.Output | Should -Not -BeLike '*плагін unica*'
    }
    It 'session-check прокидає -InstalledPluginsPath у check' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-unica') -WithHooks -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'session-check' -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.12.3'))
        $r.Output | Should -BeLike '*0.12.3*'
    }
}
```

> Перевірка до коду (kit-dev (а)): чи `session-check` друкує знахідки `check` рівня `error` (а не лише свої рядки «Стан сховищ»). Якщо ні — третій тест перевіряє `-AsJson` чи інший канал, яким `session-check` показує знахідки check; не підганяти текст.

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: `Environment.psm1`:**

```powershell
# Перевірена мінорна версія Уніки (спека 2026-10-11 §4.4 п. 4, §10 П11): будь-який патч 0.13.x — норма.
$script:UnicaTestedMinor = [version]'0.13'

function Get-KitUnicaVersionVerdict {
    <#
    .SYNOPSIS
        Висновок про версію встановленої Уніки: ok | info (немає) | warn (новіша чи нерозбірна) | error (< 0.13).
    .DESCRIPTION
        Kit говорить лише мовою Уніки 0.13 (рішення 9 спеки): на 0.12 скіли й шаблони посилаються на
        інструменти, яких там немає, а Уніка, новіша за перевірену, могла знову змінити контракт —
        тоді спершу процедура E docs/unica-contract.md. Без Уніки конвеєр kit працює (CLAUDE.md
        «Зв'язок з Unica»), тому це info, а не помилка.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Installation)

    if (-not $Installation.Installed -or -not $Installation.PathExists) {
        return [pscustomobject]@{ Level = 'info'; Message = ("Плагін unica не знайдено ($($Installation.Reason)): конвеєр kit працює й без нього, " +
            'але працювати з вихідниками, які він синхронізує, нічим.') }
    }
    $raw = [string]$Installation.Version
    if ($raw -notmatch '^(?<maj>\d+)\.(?<min>\d+)(\.\d+)?') {
        return [pscustomobject]@{ Level = 'warn'; Message = "Версію плагіна unica '$raw' не розібрано — kit перевірено на Уніці 0.13.x." }
    }
    $minor = [version]('{0}.{1}' -f $Matches['maj'], $Matches['min'])
    if ($minor -lt $script:UnicaTestedMinor) {
        return [pscustomobject]@{ Level = 'error'; Message = ("Плагін unica $raw старіший за 0.13: kit говорить лише мовою Уніки 0.13 (v8-runner 0.14), " +
            'старого словника в скілах і шаблонах більше немає. Оновіть Уніку — claude plugin marketplace update unica; ' +
            'claude plugin update unica@unica — і почніть нову сесію (оновлення перемикає всі репозиторії машини).') }
    }
    if ($minor -gt $script:UnicaTestedMinor) {
        return [pscustomobject]@{ Level = 'warn'; Message = ("Плагін unica $raw новіший за перевірену 0.13.x: перед роботою звірте контракт " +
            'за процедурою E docs/unica-contract.md (у репозиторії плагіна v8storagekit).') }
    }
    [pscustomobject]@{ Level = 'ok'; Message = "Плагін unica $raw." }
}
```

Додати в `Export-ModuleMember`.

- [ ] **Step 4: `check.psm1` і `session-check.psm1`.**
  - `Invoke-KitCheck`: параметр `[string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json')`. Одразу після `$root = $Context.RepoRoot`:

```powershell
    # Спека 2026-10-11 §4.4 п. 4: версія Уніки — вимога. Реєстр машинний (Уніка — плагін рівня
    # користувача); параметр -InstalledPluginsPath — той самий інтерфейс, що в check-environment.ps1
    # (§10.1 П21: жодної змінної оточення заради тестів). Поза if ($Context.Manifest): стан машини.
    $unicaVerdict = Get-KitUnicaVersionVerdict -Installation (Get-UnicaInstallation -InstalledPluginsPath $InstalledPluginsPath)
    if ($unicaVerdict.Level -ne 'ok') { & $add $unicaVerdict.Level 'unica-version' $unicaVerdict.Message }
```

  - `Invoke-KitSessionCheck`: той самий параметр з тим самим умовчанням; виклик `Invoke-KitCheck … -Quiet` отримує `-InstalledPluginsPath $InstalledPluginsPath`.
  - Хук старту сесії споживача (`templates/hooks/session-start.ps1`) параметра не передає — і не мусить: у споживача діє реєстр машини. Тести шима (`SessionStartHook.Tests.ps1`) — перевірити, що їхні очікування не залежать від знахідки `unica-version`. Якщо залежать — зупинка й питання контролеру (не обхід через змінну оточення).

- [ ] **Step 5: `check-environment.ps1`, блок «Вихідники»:**

```powershell
$unica = Get-UnicaInstallation -InstalledPluginsPath $InstalledPluginsPath
$unicaVerdict = Get-KitUnicaVersionVerdict -Installation $unica
$unicaOk = $unica.Installed -and $unica.PathExists -and $unicaVerdict.Level -ne 'error'
$unicaDetail = if ($unica.Installed -and $unica.PathExists) {
    "версія $($unica.Version), $($unica.InstallPath)" + $(if ($unicaVerdict.Level -in 'error', 'warn') { " — $($unicaVerdict.Message)" } else { '' })
} else {
    $unica.Reason
}
```

- [ ] **Step 6: `KitFixtures.psm1`.**
  - Нова функція (у явний `Export-ModuleMember`):

```powershell
function New-KitFakeUnicaRegistry {
    <#
    .SYNOPSIS
        Фальшивий installed_plugins.json з Унікою заданої версії — для -InstalledPluginsPath kit check
        і session-check (спека §10.1 П21). Тести не залежать від того, яка Уніка стоїть на машині.
    #>
    [CmdletBinding()]
    param([string]$Version = '0.13.0')
    $dir = Join-Path $TestDrive "fake-unica-$Version-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'installed_plugins.json'
    Set-Content -LiteralPath $path -Encoding UTF8 -Value (
        @{ plugins = @{ 'unica@unica' = @(@{ version = $Version; installPath = $dir }) } } | ConvertTo-Json -Depth 5)
    $path
}
```

  (`$TestDrive` видно з функції модуля, що викликається з `It`/`BeforeAll` Pester; якщо ні — параметр `-Root` з умовчанням `$TestDrive` у викликача.)
  - `Invoke-KitCommand`: якщо `-Command` — `check` чи `session-check` і в `-More` немає `-InstalledPluginsPath`, дописати `-InstalledPluginsPath (New-KitFakeUnicaRegistry)`. Коментар: «тест, що навмисно перевіряє реєстр машини, передає параметр сам». Тест на це — у `KitFixtures.Tests.ps1`: виклик `check` без параметра на фікстурі не дає знахідки `unica-version` незалежно від машини.

- [ ] **Step 7: Прогін — зелений.** Кожен виклик `check`/`session-check` поза `Invoke-KitCommand` (перелік — grep із «Files») передає `-InstalledPluginsPath (New-KitFakeUnicaRegistry)`. Тест, що параметр забув, на цій машині (Уніка 0.12.3) червоніє — це очікувана сигналізація, не дефект.

- [ ] **Step 8: Мутація** — на копії дерева в `Get-KitUnicaVersionVerdict` поміняти `-lt` на `-le`. Червоніє тест `0.13.0 → ok`. Текст падіння — у звіт.

- [ ] **Step 9 (контролер, з дозволу людини): Коміт.** Тема: `§4.4 п.4: версія Уніки — вимога в kit check і check-environment`.

### Task 6: `UnicaStep.psm1` — форма виклику; новий словник у текстах `tools/` (§4.4 п. 5)

**Рівень ризику:** механічна (тексти) + спільний код (новий модуль).

**Files:**
- Create: `tools/lib/UnicaStep.psm1`
- Modify: `tools/lib/module-order.txt` — `UnicaStep` одразу після `GitOutput`; у шапці: «UnicaStep — після Supply, TreeCompare і TreeBackup (Get-KitSupplyState, Invoke-KitGitProcess, Get-KitDirtyRecords), імпортує їх вкладено без -Force, як AgentBase — V8; StoragePlatform імпортує UnicaStep вкладено (Format-KitUnicaRun) — для тестів, що вантажать StoragePlatform окремо»
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` — у `RequiredCommands` додати `Format-KitUnicaRun`, `Write-KitNextSteps`, `Remove-KitDirectory`, `Test-KitWorkspaceNeedsAgentBase`, `New-KitAgentBaseMissingMessage`, `Get-V8ProjectConfigProblems` (і далі кожну нову глобальну функцію Tasks 7–11 — у тій задачі, що її вводить)
- Modify texts:
  - `tools/commands/build.psm1` — підказка `.cfe` у прев'ю і рядок «У … порожньо»;
  - `tools/lib/StoragePlatform.psm1` — `Invoke-KitStorageUpdate`, гілка «розширення не знайдено»;
  - `tools/commands/sync.psm1` — попередження запасного шляху («Формат історичних комітів…»);
  - `tools/commands/verify.psm1` — вердикт `ref-ahead`.
  - Тексти `provision.psm1`, `Supply.psm1`, повідомлення про стан бази в `sync`/`verify` — у Tasks 8–11.
- Create test: `tools/tests/UnicaStep.Tests.ps1`
- Modify tests: `Build.Tests.ps1`, `StoragePlatform.Tests.ps1`, `Sync.Guards.Tests.ps1` — рядки з `operation=` (`grep -n "operation=" tools/tests/*.ps1`)

**Interfaces:**
- Produces:
  - `Format-KitUnicaRun -Op <string> -Arguments <IDictionary> [-DryRun <bool>=$true]` → `string` виду `unica.run {"op":"…","args":{…},"dryRun":true}`;
  - `Write-KitNextSteps -Title <string> -Steps <string[]>` → друк нумерованого переліку; рядкам, що починаються з `unica.run `, дописує «— спершу так, потім той самий виклик з "dryRun":false».

- [ ] **Step 1: Тести** — `tools/tests/UnicaStep.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Format-KitUnicaRun (спека §10 П2)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
    }
    It 'точна форма {op, args, dryRun}, infobase не друкується' {
        Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = 'base'; force = $true }) |
            Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
    }
    It 'dryRun:false на вимогу; порожні args — {}' {
        Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{}) -DryRun $false |
            Should -BeExactly 'unica.run {"op":"infobase.create","args":{},"dryRun":false}'
    }
    It 'кирилиця в імені набору — як є, без \u-екранування (Review Focus 1)' {
        $s = Format-KitUnicaRun -Op 'pull' -Arguments ([ordered]@{ sourceSet = 'Доработки'; force = $true })
        $s | Should -BeLike '*"sourceSet":"Доработки"*'
        $s | Should -Not -BeLike '*\u04*'
    }
    It 'шлях Windows — валідний JSON (бекслеш подвоєно)' {
        $s = Format-KitUnicaRun -Op 'infobase.restore' -Arguments ([ordered]@{ input = 'D:\dumps\demo.dt'; mode = 'create' })
        $s | Should -BeLike '*"input":"D:\\dumps\\demo.dt"*'
        ($s.Substring('unica.run '.Length) | ConvertFrom-Json).args.input | Should -Be 'D:\dumps\demo.dt'
    }
}

Describe 'Write-KitNextSteps' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
    }
    It 'порожній перелік — нічого не друкує' {
        (& { Write-KitNextSteps -Title 'Далі:' -Steps @() } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
    }
    It 'unica.run отримує нагадування про dryRun:false, крок kit — ні' {
        $out = & { Write-KitNextSteps -Title 'Далі:' -Steps @('unica.run {"op":"push","args":{},"dryRun":true}', 'kit verify -Source base') } 6>&1 | Out-String
        $lines = @($out -split "`r?`n" | Where-Object { $_ -match '^\s+\d\.' })
        $lines[0] | Should -BeLike '*"dryRun":false*'
        $lines[1] | Should -Not -BeLike '*dryRun*'
    }
}
```

- [ ] **Step 2: Прогін — червоний** (`Format-KitUnicaRun` не знайдено).

- [ ] **Step 3: `tools/lib/UnicaStep.psm1`:**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в AgentBase.psm1 (не перезавантажувати глобальні модулі):
# Supply дає Get-KitSupplyState, TreeCompare — Invoke-KitGitProcess (критерій вирівнювання нижче).
Import-Module "$PSScriptRoot/Supply.psm1"
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Format-KitUnicaRun {
    <#
    .SYNOPSIS
        Виклик unica.run у формі Уніки 0.13 — рядок, який агент виконує дослівно (спека §4.1, §10 П2).
    .DESCRIPTION
        Одна функція форматування на весь kit: скіли не переказують виклик, а кажуть «виконай крок,
        надрукований командою» (§4.4 п. 1). infobase не друкується — він за замовчуванням origin, а
        іншої бази Уніка не обслуговує. ConvertTo-Json у PowerShell 7 екранує лише керівні символи,
        тож кирилиця імені набору лишається читабельною й копіюється дослівно. dryRun:true першим —
        конвенція kit, не вимога Уніки (вона вимагає лише явний булів dryRun): превью показує
        попередження infobase_overwritten до виконання (спека §4.1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Op,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments,
        [bool]$DryRun = $true
    )
    $call = [ordered]@{ op = $Op; args = $Arguments; dryRun = $DryRun }
    'unica.run ' + ($call | ConvertTo-Json -Compress -Depth 5)
}

function Write-KitNextSteps {
    <#
    .SYNOPSIS
        Друк «Далі:» — нумеровані кроки; для unica.run нагадує про dryRun:true → false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Steps
    )
    if ($Steps.Count -eq 0) { return }
    Write-Host "  $Title" -ForegroundColor Cyan
    $i = 0
    foreach ($s in $Steps) {
        $i++
        $tail = if ($s.StartsWith('unica.run ')) { '   — спершу так, потім той самий виклик з "dryRun":false' } else { '' }
        Write-Host "    $i. $s$tail" -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function Format-KitUnicaRun, Write-KitNextSteps
```

- [ ] **Step 4: Тексти.**
  - `build.psm1`, підказка `.cfe`:

```powershell
        $make = Format-KitUnicaRun -Op 'make' -Arguments ([ordered]@{ sourceSet = $e.Key; extension = $e.Key; output = "build/artifacts/$($e.Key).cfe" })
        Write-Host "  .cfe  $($e.Key).cfe — не kit: $make (воркспейс $($e.Workspace); output відносний до воркспейсу)" -ForegroundColor DarkGray
```

    і «У $outDir порожньо. .cf/.cfe збирає unica.run op=make з output=build/artifacts/<Ім'я>.cfe (відносний до воркспейсу); .epf — з source-set EXTERNAL_DATA_PROCESSORS.»
  - `StoragePlatform.psm1`, «розширення не знайдено»:

```powershell
            # force:true — набору ще немає в пам'яті раннера, звичайний push відповів би no_memory (спека §2.2).
            $push = Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = $Source.Key; force = $true })
            $ws = if ($Source.PSObject.Properties['Workspace']) { " (воркспейс '$($Source.Workspace)')" } else { '' }
            throw ("У базі агента немає розширення '$($Source.Key)' — дерево розширення ще не завантажене в базу. " +
                   "Спершу$ws`: $push, потім той самий виклик з `"dryRun`":false; тоді повторіть.`nПлатформа відповіла: $($upd.Output)")
```

  - `StoragePlatform.psm1`: після вкладеного імпорту `AgentBase.psm1` — `Import-Module "$PSScriptRoot/UnicaStep.psm1"` (без `-Force`) з тим самим коментарем «для тестів, які вантажать цей модуль окремо».
  - `sync.psm1`, запасний шлях: «…після злиття й `push` Уніки з `"force":true` для цього розширення (його ще немає в пам'яті раннера, звичайний `push` відповів би `no_memory`) наступні версії підуть у базі агента…» замість «після злиття й operation=build».
  - `verify.psm1`, `ref-ahead`: «(зберіть артефакт: kit build і unica.run op=make)».
  - Коментарі коду з `operation=build`/`operation=make` у цих файлах — переписати новим словником (Task 13 перевіряє лише некоментовані рядки, але читач коментаря не мусить вивчати знятий словник).

- [ ] **Step 5: Наявні тести.**
  - `Build.Tests.ps1`: `*Alpha_SMB*operation=make*` → `*Alpha_SMB*"op":"make"*`; `-Not -BeLike '*operation=make*'` → `-Not -BeLike '*"op":"make"*'`; інші рядки з `operation=make` — новою формою.
  - `StoragePlatform.Tests.ps1`, контекст «розширення не знайдено»: `*operation=build*` → `*"op":"push"*"sourceSet":"*`; заперечні — так само.
  - `Sync.Guards.Tests.ps1` — рядок з `operation=build`: переписати на фразу нового тексту, тієї гілки, яку тест перевіряє.

  Перед кожною перевіркою на фразу — `grep` по `tools/commands`, `tools/lib`: фраза лише в цій гілці (kit-dev, case 22).

- [ ] **Step 6: Прогін — зелений.**

- [ ] **Step 7: Мутація** — на копії дерева в `build.psm1` прибрати рядок `$make = …` (і його друк). Червоніє тест `Build.Tests` «`*"op":"make"*`»; текст падіння — у звіт.

- [ ] **Step 8 (контролер, з дозволу людини): Коміт.** Тема: `§4.4 п.5: UnicaStep — форма виклику unica.run; тексти tools/ новим словником`.

---

### Task 7: Критерій і крок вирівнювання пам'яті раннера (§4.1, §10 П3–П5, §10.1)

**Рівень ризику:** властивість безпеки (`pull force` переписує дерево набору з бази; хибний `pull` стер би незакомічену роботу) → два рев'ю.

**Files:**
- Modify: `tools/lib/UnicaStep.psm1`
- Test: `tools/tests/UnicaStep.Tests.ps1`

**Interfaces:**
- Consumes:
  - `Format-KitUnicaRun`, `Write-KitNextSteps` (Task 6);
  - `Get-KitSupplyState -TreeRoot` → `none|current|stale|missing` (`Supply.psm1`);
  - `Invoke-KitGitProcess -RepoRoot -Arguments` → `{ExitCode; Stdout; Stderr}` (`TreeCompare.psm1`);
  - `Get-KitDirtyRecords -RepoRoot -RepoPath` (`TreeBackup.psm1`; `status --porcelain -z -uall`, без ігнорованих) — одна семантика «чисте дерево» на kit.
- Produces:
  - `Test-KitSetTreeEqual -RepoRoot -RepoPath -Left <rev> -Right <rev>` → `bool` (ідентифікатори git-дерева набору рівні; відсутній шлях на будь-якому боці → `$false`);
  - `Test-KitSetClean -RepoRoot -RepoPath` → `bool` (`Get-KitDirtyRecords` порожній; невідстежувані рахуються, гітігноровані — ні); збій git → виняток;
  - `Test-KitRefIsHead -RepoRoot -Ref` → `bool` (`<Ref>^{commit}` == `HEAD^{commit}`);
  - `Get-KitAlignStep -Source <джерело префлайту> -Criterion <bool> -BaseKind 'file'|'server'` → `[pscustomobject]@{ SourceSet; Workspace; RepoPath; BaseKind; Op = 'pull'|'push'|'blocked'; Supply; MarkerOnly; Steps = string[]; Recipe }`;
  - `Write-KitAlignStep -Step` — друк кроку `pull`/`push` (для `blocked` нічого не друкує);
  - `Write-KitAlignStops -Steps <object[]>` — рядки `ЗУПИНКА: …` для всіх `blocked`; викликач друкує їх **останніми**, після підсумку команди (умова архітектора до відхилення 2).

Логіка `Get-KitAlignStep` (спека §4.1 і §10 П5 на `8d94204`):

| База | Критерій | Поставка (`CONFIGURATION`) | Op | Steps |
|---|---|---|---|---|
| файлова | так | `none` / не `CONFIGURATION` | `pull` | `unica.run pull {sourceSet, [extension для EXTENSION], force:true}` |
| файлова | так | ≠ `none` | `pull` | той самий `pull` + `kit canon -Workspace <ws> -Source <ключ> -MarkerOnly -Apply` |
| серверна | так | `none` / `current` | `push` | `unica.run push {sourceSet, force:true}` |
| серверна | так | `missing` / `stale` | `push` | `kit canon -Workspace <ws> -Source <ключ> -Apply` (дає `.cf` і позначку; дерево не змінюється — воно дорівнює базі) + `push force` |
| будь-яка | ні | `none` / `current` | `push` | `unica.run push {sourceSet, force:true}` |
| будь-яка | ні | `missing` / `stale` | `blocked` | порожньо; `Recipe` — «вирівняти на головній гілці: `verify` на HEAD → надрукований крок → позначка» |

Серверна — завжди `push force` (§4.1): з `providers: designer` Конфігуратор у кластері покоління не віддає (#184), звірки там немає ніколи, і вирівняти хеш-пам'ять нічим.

- [ ] **Step 1: Тести** — дописати в `tools/tests/UnicaStep.Tests.ps1`:

```powershell
Describe 'Критерій вирівнювання на справжньому git (§10 П3, П4; Review Focus 3, 5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'crit') -WithHooks -WithGitignore
        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
    }
    It 'дерево набору в HEAD і в дзеркалі однакове — рівні' {
        Test-KitSetTreeEqual -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' -Left 'HEAD' -Right 'storage/Alpha_SMB' | Should -BeTrue
    }
    It 'шляху немає на одному боці — не рівні, не виняток' {
        Test-KitSetTreeEqual -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/nope' -Left 'HEAD' -Right 'storage/Alpha_SMB' | Should -BeFalse
    }
    It 'невідстежуваний файл під шляхом набору — дерево НЕ чисте (Review Focus 3)' {
        $f = Join-Path $script:Repo 'Alpha_SMB/cfe/src/Новая.xml'
        Set-Content -LiteralPath $f -Value 'нова форма' -Encoding UTF8
        try { Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeFalse }
        finally { Remove-Item -LiteralPath $f -Force }
        Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue
    }
    It 'гітігнорований файл під шляхом набору — дерево чисте' {
        $d = Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext/ParentConfigurations'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Vendor.cf') -Value 'cf' -Encoding ascii
        try { Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue }
        finally { Remove-KitDirectory -Path (Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext') }
    }
    It 'Test-KitRefIsHead: ім''я гілки, sha і від''єднаний HEAD — через ^{commit} (Review Focus 5)' {
        $sha = (git -C $script:Repo rev-parse HEAD).Trim()
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'main' | Should -BeTrue
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref $sha | Should -BeTrue
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'storage/Alpha_SMB' | Should -BeFalse
        git -C $script:Repo checkout -q --detach $sha
        try { Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'main' | Should -BeTrue }
        finally { git -C $script:Repo checkout -q main }
    }
}

Describe 'Get-KitAlignStep — таблиця §10 П5' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        function script:New-Set { param([string]$Type, [string]$Supply)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null
            if ($Supply -ne 'none') {
                [System.IO.File]::WriteAllBytes((Join-Path $root 'Ext/ParentConfigurations.bin'), [byte[]](1..32))
                $sha = (Get-FileHash -LiteralPath (Join-Path $root 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
                if ($Supply -in 'current', 'stale') { Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations/V.cf') -Value 'cf' -Encoding ascii }
                if ($Supply -eq 'current') { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), $sha) }
                if ($Supply -eq 'stale')   { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), 'deadbeef') }
            }
            [pscustomobject]@{ Key = 'base'; Type = $Type; FullPath = $root; RepoPath = 'Ws/cf/src'; Workspace = 'Ws' }
        }
    }
    It '<Kind>: <Type>/<Supply>, критерій <C> → <Op>, MarkerOnly <M>' -ForEach @(
        @{ Kind = 'file';   Type = 'EXTENSION';     Supply = 'none';    C = $true;  Op = 'pull';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'missing'; C = $true;  Op = 'pull';    M = $true }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'current'; C = $true;  Op = 'pull';    M = $true }
        @{ Kind = 'file';   Type = 'EXTENSION';     Supply = 'none';    C = $false; Op = 'push';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'current'; C = $false; Op = 'push';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'missing'; C = $false; Op = 'blocked'; M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'stale';   C = $false; Op = 'blocked'; M = $false }
        @{ Kind = 'server'; Type = 'EXTENSION';     Supply = 'none';    C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'current'; C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'missing'; C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'missing'; C = $false; Op = 'blocked'; M = $false }
    ) {
        $s = Get-KitAlignStep -Source (New-Set -Type $Type -Supply $Supply) -Criterion $C -BaseKind $Kind
        $s.Op | Should -Be $Op
        $s.MarkerOnly | Should -Be $M
    }
    It 'файлова pull CONFIGURATION: точний виклик і позначка з -Workspace другим кроком' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $true -BaseKind 'file'
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"base","force":true},"dryRun":true}'
        $s.Steps[1] | Should -BeExactly 'kit canon -Workspace Ws -Source base -MarkerOnly -Apply'
    }
    It 'файлова pull EXTENSION: extension = ім''я набору (схема pull Уніки 0.13)' {
        $set = New-Set -Type 'EXTENSION' -Supply 'none'; $set.Key = 'Alpha_SMB'
        $s = Get-KitAlignStep -Source $set -Criterion $true -BaseKind 'file'
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"Alpha_SMB","extension":"Alpha_SMB","force":true},"dryRun":true}'
    }
    It 'серверна, критерій є, поставка без .cf: спершу kit canon (не MarkerOnly), потім push force' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $true -BaseKind 'server'
        $s.Steps[0] | Should -BeExactly 'kit canon -Workspace Ws -Source base -Apply'
        $s.Steps[1] | Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
        ($s.Steps -join "`n") | Should -Not -BeLike '*"op":"pull"*'
    }
    It 'push: force:true, без позначки' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
        @($s.Steps) | Should -HaveCount 1
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
    }
    It 'blocked: кроків немає, рецепт називає verify з -Workspace і MarkerOnly' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $false -BaseKind 'file'
        @($s.Steps) | Should -HaveCount 0
        $s.Recipe | Should -BeLike '*kit verify -Workspace Ws -Source base*-MarkerOnly*'
    }
    It 'Write-KitAlignStep мовчить про blocked; Write-KitAlignStops друкує ЗУПИНКА лише для blocked' {
        $b = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $false -BaseKind 'file'
        $p = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
        (& { Write-KitAlignStep -Step $b } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
        $out = & { Write-KitAlignStops -Steps @($p, $b) } 6>&1 | Out-String
        @($out -split "`r?`n" | Where-Object { $_ -like '*ЗУПИНКА:*' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація** — у `UnicaStep.psm1` до `Export-ModuleMember`:

```powershell
function Test-KitSetTreeEqual {
    <#
    .SYNOPSIS
        Чи однакове git-дерево набору у двох ревізіях — ідентифікатор дерева, не вміст файлів (§4.1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    $p = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $l = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "${Left}:$p")
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "${Right}:$p")
    if ($l.ExitCode -ne 0 -or $r.ExitCode -ne 0) { return $false }
    $l.Stdout.Trim() -eq $r.Stdout.Trim()
}

function Test-KitSetClean {
    <#
    .SYNOPSIS
        Чи чисте робоче дерево набору (§4.1) — та сама семантика, що в страховці canon (Get-KitDirtyRecords).
    .DESCRIPTION
        Невідстежувані файли рахуються: pull force переписує дерево з бази, і невідстежувана нова
        форма агента зникла б безслідно (Review Focus 3) — тому не git diff. Гітігноровані файли
        (поставка вендора) не рахуються. Одна функція «брудне дерево» на kit (kit-dev: друга
        перевірка з іншою логікою гірша за жодну).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$RepoPath)
    @(Get-KitDirtyRecords -RepoRoot $RepoRoot -RepoPath $RepoPath).Count -eq 0
}

function Test-KitRefIsHead {
    <#
    .SYNOPSIS
        Чи вказує -Ref на той самий коміт, що й HEAD (§10 П4) — через ^{commit}, тож працює для
        імені гілки, тегу, sha і від'єднаного HEAD.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Ref)
    $h = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    $x = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($h.ExitCode -ne 0 -or $x.ExitCode -ne 0) { return $false }
    $h.Stdout.Trim() -eq $x.Stdout.Trim()
}

function Get-KitAlignStep {
    <#
    .SYNOPSIS
        Один точний крок вирівнювання пам'яті раннера для набору, базу якого зрушив kit (§4.1, §10 П3–П5).
    .DESCRIPTION
        Критерій (обчислює викликач) — kit довів, що дерево набору в робочій копії дорівнює тому, що
        він щойно вивантажив з бази, і дерево чисте. Тоді pull force: одне вивантаження, файли не
        змінюються, пам'ять раннера стає правильною. Інакше push force — повне завантаження з git,
        для бази агента безпечне за побудовою (рішення 1 спеки).

        Поставка вендора (CONFIGURATION, стан ≠ none), файлова база: pull --force стирає каталог
        набору разом з ігнорованими, але повне вивантаження платформи кладе .cf поставки заново (на
        цьому стоїть canon 1.4.0); знищується лише позначка .kit-bin-sha1, і її пише власник —
        canon у режимі -MarkerOnly, без вивантаження (§10 П5 на 8d94204).
        Серверна база — pull немає ніколи (§4.1: з providers: designer у кластері покоління не
        звіряється, #184); поставку без .cf там дає повний canon (дерево не змінюється — воно
        дорівнює базі), а тоді push force.
        Без критерію push force можливий лише з .cf на місці (current); missing/stale дають
        'blocked' з рецептом — push без .cf упав би на повному завантаженні. Це й є запасна гілка
        спеки §6: пілот вирішує, чи вона колись спрацює, але не прибирає її.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][bool]$Criterion,
        [Parameter(Mandatory)][ValidateSet('file', 'server')][string]$BaseKind
    )

    $set = $Source.Key
    $ws = $Source.Workspace
    $supply = if ($Source.Type -eq 'CONFIGURATION') { Get-KitSupplyState -TreeRoot $Source.FullPath } else { 'none' }
    $step = [pscustomobject]@{ SourceSet = $set; Workspace = $ws; RepoPath = $Source.RepoPath; BaseKind = $BaseKind
        Op = $null; Supply = $supply; MarkerOnly = $false; Steps = @(); Recipe = $null }
    $pushForce = Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = $set; force = $true })

    if ($Criterion -and $BaseKind -eq 'file') {
        $step.Op = 'pull'
        $pullArgs = [ordered]@{ sourceSet = $set }
        # Схема pull Уніки 0.13: extension «required for an extension source set and must match it»;
        # ім'я набору = ім'я розширення (обхід B5-B6).
        if ($Source.Type -eq 'EXTENSION') { $pullArgs['extension'] = $set }
        $pullArgs['force'] = $true
        $steps = @(Format-KitUnicaRun -Op 'pull' -Arguments $pullArgs)
        if ($supply -ne 'none') {
            $step.MarkerOnly = $true
            $steps += "kit canon -Workspace $ws -Source $set -MarkerOnly -Apply"
        }
        $step.Steps = $steps
        return $step
    }
    if ($Criterion -and $BaseKind -eq 'server') {
        $step.Op = 'push'
        $step.Steps = if ($supply -in 'missing', 'stale') { @("kit canon -Workspace $ws -Source $set -Apply", $pushForce) } else { @($pushForce) }
        return $step
    }
    if ($supply -in 'none', 'current') {
        $step.Op = 'push'
        $step.Steps = @($pushForce)
        return $step
    }
    $step.Op = 'blocked'
    $step.Recipe = ("Вирівняти пам'ять раннера для '$set' (воркспейс $ws) зараз неможливо: дерево набору не збігається з тим, що kit вивантажив, " +
        "а поставка вендора $supply — push force без .cf упав би на повному завантаженні. Рецепт — на головній гілці (HEAD = головна, " +
        "дерево чисте): kit verify -Workspace $ws -Source $set → крок, який він надрукує (файлова: pull Уніки й kit canon -Workspace $ws -Source $set -MarkerOnly -Apply; " +
        'серверна: kit canon і push force). Зупинка й доповідь людині, без обходу.')
    $step
}

function Write-KitAlignStep {
    <#
    .SYNOPSIS
        Друк кроку pull/push одразу після набору. Для 'blocked' — нічого: зупинки друкує
        Write-KitAlignStops ОСТАННІМИ, після підсумку команди (умова архітектора до Op 'blocked').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step)
    if ($Step.Op -eq 'blocked') { return }
    $why = if ($Step.Op -eq 'pull') { 'дерево набору дорівнює вивантаженому kit' } else { 'повне завантаження набору з git' }
    Write-KitNextSteps -Title "Далі — вирівняти пам'ять раннера для '$($Step.SourceSet)' (воркспейс $($Step.Workspace); $($Step.Op): $why), без питання людині:" -Steps $Step.Steps
    if ($Step.Op -eq 'pull') {
        Write-Host "    Після pull: git status --porcelain -- $($Step.RepoPath) мусить бути порожнім. Непорожній — вивантаження раннера дало інші байти, ніж kit: зупинка й доповідь людині, не робота для агента." -ForegroundColor Cyan
    }
}

function Write-KitAlignStops {
    <#
    .SYNOPSIS
        Рядки «ЗУПИНКА: …» для кроків 'blocked' — викликач друкує їх останніми, після підсумку.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps)
    foreach ($s in @($Steps | Where-Object { $_.Op -eq 'blocked' })) {
        Write-Host "ЗУПИНКА: $($s.Recipe)" -ForegroundColor Red
    }
}
```

Export: `Export-ModuleMember -Function Format-KitUnicaRun, Write-KitNextSteps, Test-KitSetTreeEqual, Test-KitSetClean, Test-KitRefIsHead, Get-KitAlignStep, Write-KitAlignStep, Write-KitAlignStops`. Нові глобальні функції — у `RequiredCommands` `ModuleImportOrder.Tests.ps1`.

- [ ] **Step 4: Прогін — зелений.**

- [ ] **Step 5: Мутації — на копії дерева, кожна окремо, текст падіння у звіт:**
  - (а) тіло `Test-KitSetClean` замінити на `$true` — червоніє «невідстежуваний файл»;
  - (б) у `Get-KitAlignStep` замінити `$supply -in 'none', 'current'` на `$true` — червоніють рядки `blocked`;
  - (в) прибрати умову `-and $BaseKind -eq 'file'` у гілці `pull` — червоніють рядки `server … критерій $true`;
  - (г) прибрати рядок `$pullArgs['extension'] = $set` — червоніє тест «pull EXTENSION».

- [ ] **Step 6 (контролер, з дозволу людини): Коміт.** Тема: `§4.1, §10 П3–П5: критерій і крок вирівнювання пам'яті раннера`.

### Task 8: `canon -MarkerOnly`; рецепт поставки (§10 П5)

**Рівень ризику:** спільний код.

**Files:**
- Modify: `tools/commands/canon.psm1` (параметр `-MarkerOnly`, нова приватна `Invoke-KitCanonMarkerOnly`)
- Modify: `tools/lib/Supply.psm1` (`Get-KitSupplyRecipe` — текст)
- Test: `tools/tests/Canon.Tests.ps1`, `tools/tests/Supply.Tests.ps1`

**Interfaces:**
- Consumes: `Test-KitSupplyDescribed`, `Get-KitSupplyRelativePath`, `Write-KitSupplyMarker` (`Supply.psm1`); `Get-KitDirtyRecords -RepoRoot -RepoPath` (`TreeBackup.psm1`).
- Produces: `kit canon -Source <ключ> -MarkerOnly [-Apply]` — без бази агента й без вивантаження пише `.kit-bin-sha1`; результат `{ExitCode = 0; Canonized = @({Key; Files = 0; Changed = 0; Backup = $null; SupplyMarker = <sha>})}`.

- [ ] **Step 1: Тести** — `tools/tests/Canon.Tests.ps1`, підпроцес (хелпер файлу для запуску `kit.ps1`; якщо зветься інакше — його ім'я з `BeforeAll`):

```powershell
Describe 'kit canon -MarkerOnly (§10 П5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Run { param([string]$Repo, [string[]]$More)
            $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:StorageWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
    }
    It 'позначки немає, .cf на місці, дерево чисте — пише позначку без бази агента й без платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ok') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 0
        $want = (Get-FileHash -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText($marker) | Should -Be $want
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
    }
    It 'без -Source — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nosrc') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        (Run -Repo $repo -More @('-MarkerOnly', '-Apply')).Output | Should -BeLike '*-MarkerOnly потребує -Source*'
    }
    It 'набір EXTENSION — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ext') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $r = Run -Repo $repo -More @('-Source', 'Alpha_SMB', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*позначка поставки буває лише в наборі CONFIGURATION*'
    }
    It 'немає .cf — код 1, рецепт pull' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nocf') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Remove-Item -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*немає .cf*pull*'
    }
    It 'брудне дерево — код 1, позначку не записано (запасна гілка §4.1)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-dirty') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Value '<!-- pull дав інші байти -->'
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*брудне*доповідь*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It '.cf старіший за .bin — код 1, позначку не записано (pull не оновив поставку; пара «новий .bin + старий .cf»)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-old-cf') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $cf = Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Select-Object -First 1
        $cf.LastWriteTimeUtc = (Get-Item -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin')).LastWriteTimeUtc.AddMinutes(-5)
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*.cf старіший за*.bin*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}
```

Наявні тести, що ламаються від нового тексту `Get-KitSupplyRecipe`, — переписати всі три:
- `tools/tests/Supply.Tests.ps1`, тест «рецепт (ii)/(iii)»: `*operation=build*` і `*kit canon -Source base -Apply*` → `*kit verify -Source base*pull*kit canon -Source base -MarkerOnly -Apply*`; речення «У рецепті (i)… canon … до PR» → `*У рецепті (i)*kit sync -Source base*`; додати `$r | Should -Not -BeLike '*(вивантажує .cf і пише позначку)*'` — канону-дампу для поставки більше немає;
- `tools/tests/Check.Supply.Tests.ps1`: `*поставка вендора відсутня*kit verify -Source base*kit canon -Source base -Apply*` → `*поставка вендора відсутня*kit verify -Source base*-MarkerOnly*`.

> Перевірки до коду (kit-dev, case 21):
> - `grep -rn "MarkerOnly потребує\|буває лише в наборі CONFIGURATION\|немає .cf" tools/` — фрази лише в новій функції;
> - фікстура `-WithSupply` пише `.bin` у git, а `.cf` і позначку — після коміту, гітігноровано;
> - чи гітігнорує `-WithGitignore` теку `Ext/ParentConfigurations/` (`templates/gitignore`) — інакше «дерево брудне» спрацює на `.cf`, а не на зміненому файлі.

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація `canon.psm1`.**
  - Параметр `[switch]$MarkerOnly` в `Invoke-KitCanon`.
  - Перший рядок тіла: `if ($MarkerOnly) { return (Invoke-KitCanonMarkerOnly -Context $Context -Workspace $Workspace -Source $Source -Apply $Apply) }`.
  - У `.DESCRIPTION` — абзац: «`-MarkerOnly` (спека §10 П5): позначку поставки пише її власник — canon — і після `pull` Уніки, який уже поклав `.cf`; тоді вивантажувати знову нема чого». Приватна функція:

```powershell
function Invoke-KitCanonMarkerOnly {
    <#
    .SYNOPSIS
        canon без вивантаження: лише .kit-bin-sha1 для набору CONFIGURATION, .cf якого вже поклав pull Уніки.
    .DESCRIPTION
        Передумови спеки §10 П5 — набір CONFIGURATION, .bin описує поставку, .cf на місці, дерево
        набору чисте. Брудне дерево після pull — запасна гілка §4.1: вивантаження раннера дало інші
        байти, ніж kit, і позначка засвідчила б стан, якого kit не перевіряв. Бази агента цей режим
        не потребує й платформи не кличе.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [string]$Workspace, [string]$Source, [bool]$Apply)

    if (-not $Source) { throw '-MarkerOnly потребує -Source <ключ основної конфігурації>: режим пише позначку поставки рівно одному набору.' }
    $src = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)[0]
    if ($src.Type -ne 'CONFIGURATION') {
        throw "-MarkerOnly: '$($src.Key)' — $($src.Type), а позначка поставки буває лише в наборі CONFIGURATION."
    }
    if (-not (Test-KitSupplyDescribed -TreeRoot $src.FullPath)) {
        throw "-MarkerOnly: Ext/ParentConfigurations.bin набору '$($src.Key)' не описує поставку вендора — позначка не потрібна."
    }
    $dir = Join-Path $src.FullPath (Get-KitSupplyRelativePath)
    $cfFiles = @(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue)
    if ($cfFiles.Count -eq 0) {
        throw "-MarkerOnly: у $dir немає .cf — позначку нема чим підтвердити. Спершу крок pull Уніки, надрукований kit sync чи kit verify."
    }
    # Позначка засвідчує пару «.bin ↔ .cf». .bin пише git (злиття, checkout), .cf — вивантаження
    # (pull); .cf, старіший за .bin, означає, що pull поставку не оновив, і позначка освятила б
    # пару «новий .bin + старий .cf» — саме те, від чого захищає стан stale.
    $binTime = (Get-Item -LiteralPath (Join-Path $src.FullPath 'Ext/ParentConfigurations.bin')).LastWriteTimeUtc
    if (@($cfFiles | Where-Object { $_.LastWriteTimeUtc -lt $binTime }).Count -gt 0) {
        throw ("-MarkerOnly: .cf старіший за Ext/ParentConfigurations.bin — pull не оновив поставку вендора. Позначку не записано. " +
               "Зупинка й доповідь людині; відновлення поставки — kit canon -Source $($src.Key) -Apply на головній гілці.")
    }
    $dirty = @(Get-KitDirtyRecords -RepoRoot $Context.RepoRoot -RepoPath $src.RepoPath)
    if ($dirty.Count -gt 0) {
        throw ("-MarkerOnly: дерево '$($src.RepoPath)' брудне ($($dirty.Count) змін після pull) — вивантаження раннера дало інші байти, " +
               'ніж kit, або в дереві чужа робота. Позначку не записано. Зупинка й доповідь людині: git status -- ' + $src.RepoPath)
    }
    if (-not $Apply) {
        Write-Host "  $($src.Key): буде записано позначку .kit-bin-sha1 без вивантаження. Для виконання додайте -Apply." -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Canonized = @() }
    }
    $sha = Write-KitSupplyMarker -TreeRoot $src.FullPath
    Write-Host "  $($src.Key): позначку .kit-bin-sha1 записано ($sha); дерево не переписувалось." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Canonized = @([pscustomobject]@{ Key = $src.Key; Files = 0; Changed = 0; Backup = $null; SupplyMarker = $sha }) }
}
```

  `Export-ModuleMember` модуля лишається `Invoke-KitCanon` (приватна функція не експортується).

- [ ] **Step 4: `Get-KitSupplyRecipe`** — текст після `$what.`:

```powershell
    "$what. Відновлення — лише на гілці ${MainBranch} (HEAD = ${MainBranch}, дерево чисте), не на гілці задачі: база агента є " +
    "(інакше v8storagekit:provision) → kit verify -Source $SourceKey (очікувано equal; verify наповнить базу версією зі сховища — " +
    "merge-base — і надрукує крок: на файловій базі pull Уніки та kit canon -Source $SourceKey -MarkerOnly -Apply, на серверній — kit canon і push) " +
    "→ виконати надруковане. У рецепті (i) (новий репозиторій, онбординг на гілці через sync -MergeInto) той самий крок друкує kit sync -Source $SourceKey."
```

  Коментарі `Supply.psm1` про «canon — єдине місце, де `.cf` з'являється на машині» → «`.cf` кладе вивантаження з бази агента — `canon` або `pull` Уніки; позначку пише лише `canon`». Той самий коментар у `canon.psm1` біля `Write-KitSupplyMarker` переписати так само.

- [ ] **Step 5: Прогін — зелений.**

- [ ] **Step 6: Мутації** — на копії дерева, кожна окремо: (а) прибрати перевірку `$dirty.Count -gt 0` — червоніє «брудне дерево»; (б) прибрати перевірку `LastWriteTimeUtc -lt $binTime` — червоніє «.cf старіший за .bin». Тексти падінь — у звіт.

- [ ] **Step 7 (контролер, з дозволу людини): Коміт.** Тема: `§10 П5: canon -MarkerOnly; рецепт поставки через verify → pull → позначку`.

### Task 9: `sync` друкує крок вирівнювання (§4.1, §10 П3)

**Рівень ризику:** властивість безпеки (хибний `pull` після `sync`) → два рев'ю.

**Files:**
- Modify: `tools/commands/sync.psm1` (блок після «Перенесено версій», повідомлення про базу, злиття; обидва `$results.Add`; підсумок «Готово.»; результат)
- Create test: `tools/tests/Sync.Align.Tests.ps1`

**Interfaces:**
- Consumes: `Test-KitSetTreeEqual`, `Test-KitSetClean`, `Get-KitAlignStep -BaseKind`, `Write-KitAlignStep`, `Write-KitAlignStops` (Task 7); `Get-KitSourceInfobase` → `{…; Kind}` (Task 4).
- Produces: `Invoke-KitSync` → `{ExitCode; Synced; AlignSteps = object[]}`; **кожен** елемент `Synced` (обидва місця `$results.Add`, зокрема гілка «нових версій немає») — ще й поле `AlignStep` (`$null`, якщо кроку немає).

Критерій (спека §10 П3; формулювання — дерево, а не «злиття»; відхилення 1 прийнято архітектором):
- кроку немає — запасний шлях (тимчасова ІБ) або 0 перенесених версій;
- `pull`-критерій — `Test-KitSetTreeEqual -Left HEAD -Right storage/<ключ>` **і** `Test-KitSetClean` після спроби злиття **і** остання перенесена версія вивантажена **основною** платформою. Якщо остання версія — `-ForVersion` з `-DumpPlatform`, дерево дзеркала — дамп іншої платформи, і рівність «дерево = те, що віддасть база основною платформою» не доведено (аудит Tasks 7–11);
- тип бази (`file`/`server`) — з `Get-KitSourceInfobase`; серверна — завжди `push force` (Task 7);
- `push force` — інакше, зокрема коли злиття впало: тоді дерево не чисте чи не рівне.

Порядок друку (умова архітектора до Op `blocked`): кроки `pull`/`push` — одразу після набору; рядки `ЗУПИНКА:` — **останніми**, після підсумку; підсумок не каже «Готово» для набору зі зупинкою.

- [ ] **Step 1: Тести** — `tools/tests/Sync.Align.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'kit sync — крок вирівнювання пам''яті раннера (спека §4.1, §10 П3)' {
    # У процесі, з моком платформи — той самий прийом, що Sync.Merge.Tests.ps1 (див. шапку там):
    # Invoke-V8Designer — за -ModuleName StoragePlatform, Get-StorageVersions — за -ModuleName sync.
    # Мок /DumpConfigToFiles пише той самий Configuration.xml, що фікстура, — дзеркало й main мають
    # однакове дерево набору, і критерій виконується лише там, де мусить.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force
        function script:New-KitFakeStorageVersion { param([int]$Version)
            [pscustomobject]@{ Version = $Version; User = 'gitbot'; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = 'версія'; Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-01T09:00:00' } }
        function script:New-AlignRepo { param([string]$Name)
            # -WithGitignore обов'язковий: без нього невідстежувані v8storagekit.local.yaml і build/
            # роблять копію брудною, злиття в main відмовляє, і тест «pull» червоніє за будь-якої
            # реалізації (аудит Tasks 7–11).
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithAgentBase -WithGitignore
            $storageDir = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            $repo }
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
    }
    BeforeEach {
        Mock -ModuleName StoragePlatform Invoke-V8Designer {
            $line = $Arguments -join ' '
            if ($line -match '/DumpConfigToFiles "(?<t>[^"]+)"') {
                New-Item -ItemType Directory -Path $Matches['t'] -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Matches['t'] 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7) }
    }

    It 'перший sync, HEAD = main, дзеркало злито, дерево рівне й чисте — pull (з extension для розширення)' {
        $repo = New-AlignRepo -Name 'first'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.ExitCode | Should -Be 0
        $r.Synced[0].MergedIntoMain | Should -BeTrue
        @($r.AlignSteps) | Should -HaveCount 1
        $r.AlignSteps[0].Op | Should -Be 'pull'
        $r.AlignSteps[0].Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"Alpha_SMB","extension":"Alpha_SMB","force":true},"dryRun":true}'
    }
    It 'серверна база агента — push force, хоча дерево рівне й чисте (§4.1, #184)' {
        $repo = New-AlignRepo -Name 'server'
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].BaseKind | Should -Be 'server'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'остання версія вивантажена -DumpPlatform — push force, не pull' {
        $repo = New-AlignRepo -Name 'altplat'
        Mock -ModuleName sync Get-KitInstalledPlatforms { @([pscustomobject]@{ Version = '8.3.24.1000'; Arch = 'x64'; Path = 'C:\alt\1cv8.exe' }) }
        Mock -ModuleName sync Get-V8Path { 'C:\alt\1cv8.exe' }
        Mock -ModuleName sync Invoke-KitStorageCheckoutViaPlatform {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -ForVersion 7 -DumpPlatform '8.3.24.1000'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'гілка задачі з власною зміною набору — push force' {
        $repo = New-AlignRepo -Name 'task'
        git -C $repo checkout -q -b feature/x
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Value '<!-- робота агента -->'
        git -C $repo commit -qam 'робота агента'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].Op | Should -Be 'push'
        $r.AlignSteps[0].Steps[0] | Should -BeLike '*"op":"push"*"force":true*'
    }
    It 'невідстежуваний файл у наборі — злиття відмовляє, крок push (не pull, Review Focus 3)' {
        $repo = New-AlignRepo -Name 'dirty'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Новая.xml') -Value 'x' -Encoding UTF8
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'нових версій немає — кроку немає (база не зрушена)' {
        $repo = New-AlignRepo -Name 'none'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        @($r.AlignSteps) | Should -HaveCount 0
    }
    It 'вивід: крок і контракт стану бази, без слова operation=' {
        $repo = New-AlignRepo -Name 'text'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $text | Should -BeLike "*вирівняти пам'ять раннера для 'Alpha_SMB'*"
        $text | Should -BeLike '*це контракт sync, не збій*'
        $text | Should -Not -BeLike '*operation=*'
    }
}
```

> Перевірки до коду (kit-dev, case 21):
> - (б) у тесті «невідстежуваний файл» `Invoke-KitMainMerge` повертає `$false` (злиття відмовило на брудній копії), а не кидає назовні — перевірено аудитом; тест очікує `push`;
> - (б) тест «-DumpPlatform»: імена й форма параметрів `Invoke-KitSync` (`-ForVersion`, `-DumpPlatform`) і того, як `sync` вибирає альтернативну платформу (`Get-KitInstalledPlatforms`/`Get-V8Path` — у якому модулі їх мокати), звірити з фактичним `sync.psm1` до написання; мок має перехопити все, що інакше пішло б у справжній `1cv8.exe` (`Should -Invoke` як доказ);
> - (в) тест «перший sync → pull» червоний до зміни: `AlignSteps` не існує.

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація** — у `Invoke-KitSync`:
  - перед циклом джерел: `$alignSteps = [System.Collections.Generic.List[object]]::new()`;
  - блок повідомлень про базу агента (після `$originGap`) і злиття:

```powershell
        # Контракт спеки 2026-09-17 §4: перемотування історії ЗАМІНЮЄ конфігурацію в базі агента — це
        # оголошена поведінка. Після неї пам'ять покоління раннера (v8-runner 0.14) розходиться з базою,
        # і push Уніки відмовить; тому sync закінчується одним точним кроком вирівнювання (спека
        # 2026-10-11 §4.1). Запасний шлях базу агента не чіпав — вирівнювати нічого.
        if ($fallback) {
            Write-Host ("База агента не змінювалась (запасний шлях). Далі: злиття дзеркала → push Уніки з `"force`":true для цього розширення " +
                "(його ще немає в пам'яті раннера; звичайний push відповів би no_memory) — розширення з'явиться в базі агента.") -ForegroundColor Yellow
        } else {
            Write-Host ("База агента воркспейсу '{0}' тепер містить версію {1} зі сховища — це контракт sync, не збій." -f `
                $agent.Workspace, $done[-1]) -ForegroundColor Yellow
        }

        $merged = $false
        if ($wt.Created -or $MergeMain) {
            $merged = Invoke-KitMainMerge -Context $Context -Source $src -Into $into
            if (-not $merged) { $mergeFailed = $true }
        }

        # Критерій pull (§10 П3) — дерево, а не факт злиття: kit довів, що дерево набору в робочій
        # копії дорівнює тому, що він щойно вивантажив (вершина дзеркала), і що воно чисте. Злиття, що
        # впало, лишає дерево брудним чи іншим — і дає push force без окремої гілки коду.
        $alignStep = $null
        if (-not $fallback -and $done.Count -gt 0) {
            # Остання версія з -DumpPlatform — дерево дзеркала дала інша платформа, рівність із тим,
            # що віддасть база основною платформою, не доведено.
            $lastViaAlt = $hasFor -and ($done[-1] -eq [int]$ForVersion)
            $criterion = (-not $lastViaAlt) -and
                         (Test-KitSetTreeEqual -RepoRoot $root -RepoPath $src.RepoPath -Left 'HEAD' -Right $src.Branch) -and
                         (Test-KitSetClean -RepoRoot $root -RepoPath $src.RepoPath)
            $alignStep = Get-KitAlignStep -Source $src -Criterion $criterion -BaseKind $agent.Kind
            Write-KitAlignStep -Step $alignStep
            $alignSteps.Add($alignStep)
        }
```

  (`$hasFor`, `$ForVersion` — наявні змінні/параметри `Invoke-KitSync`; звірити імена з фактичним кодом.)
  - В **обидва** `$results.Add(...)` (гілка «Нових версій немає» і основна) додати `AlignStep = $alignStep` / `AlignStep = $null`. Перелік — `grep -n "results.Add" tools/commands/sync.psm1`.
  - Підсумок наприкінці `Invoke-KitSync`:

```powershell
    Write-Host ''
    $blocked = @($alignSteps | Where-Object Op -eq 'blocked')
    if ($blocked.Count -eq 0) {
        Write-Host 'Готово.' -ForegroundColor Green
    } else {
        Write-Host ("Дзеркала оновлено, але вирівнювання не завершено для: {0} — див. ЗУПИНКА нижче." -f (($blocked.SourceSet) -join ', ')) -ForegroundColor Yellow
    }
    Write-KitAlignStops -Steps $alignSteps.ToArray()
    [pscustomobject]@{ ExitCode = $(if ($mergeFailed) { 2 } else { 0 }); Synced = $results.ToArray(); AlignSteps = $alignSteps.ToArray() }
```

  - Ранні `return`, що повертають `Synced`, також отримують `AlignSteps = @()`. Перелік — `grep -n "Synced =" tools/commands/sync.psm1`.

- [ ] **Step 4: Тест порядку «ЗУПИНКА останньою»** — дописати в `Sync.Align.Tests.ps1`:

```powershell
    It 'blocked: ЗУПИНКА — останній рядок виводу, підсумок не каже «Готово»' {
        Mock -ModuleName sync Get-KitAlignStep { [pscustomobject]@{ SourceSet = 'Alpha_SMB'; Workspace = 'Alpha_SMB'; RepoPath = 'Alpha_SMB/cfe/src'
            BaseKind = 'file'; Op = 'blocked'; Supply = 'missing'; MarkerOnly = $false; Steps = @(); Recipe = 'рецепт' } }
        $repo = New-AlignRepo -Name 'blocked'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines[-1] | Should -BeLike 'ЗУПИНКА:*'
        $text | Should -Not -BeLike '*Готово.*'
    }
```

  (Мок `Get-KitAlignStep` за `-ModuleName sync` — бо sync кличе його напряму; поставку `missing` на розширенні фікстура не дає.)

- [ ] **Step 5: Прогін — зелений.**

- [ ] **Step 6: Мутації** — на копії дерева, кожна окремо, текст падіння у звіт:
  - (а) прибрати `(Test-KitSetTreeEqual …) -and` — червоніє «гілка задачі»;
  - (б) прибрати `-and (Test-KitSetClean …)` — червоніє «невідстежуваний файл»;
  - (в) прибрати `(-not $lastViaAlt) -and` — червоніє «-DumpPlatform»;
  - (г) перенести `Write-KitAlignStops` вище «Готово» — червоніє «ЗУПИНКА останньою».

- [ ] **Step 7 (контролер, з дозволу людини): Коміт.** Тема: `§4.1: sync друкує крок вирівнювання (pull за доведеною рівністю дерева, інакше push force); #25`.

### Task 10: `verify` друкує крок вирівнювання (§4.1, §10 П4)

**Рівень ризику:** властивість безпеки → два рев'ю.

**Files:**
- Modify: `tools/commands/verify.psm1`
- Test: `tools/tests/Verify.Tests.ps1` (у `Describe` «мок платформного шару»)

**Interfaces:**
- Consumes: `Test-KitRefIsHead`, `Test-KitSetClean`, `Get-KitAlignStep -BaseKind`, `Write-KitAlignStep`, `Write-KitAlignStops` (Task 7); `Get-KitSourceInfobase` → `{…; Kind}` (Task 4).
- Produces: `Invoke-KitVerify` → `{ExitCode; Results; AlignSteps}`; кожен елемент `Results` — ще й `AlignStep`.

Критерій (§10 П4): `verdict -eq 'equal'` **і** `Test-KitRefIsHead -Ref $ref` **і** `Test-KitSetClean` → `pull`; будь-який інший вердикт → `push force` (або `blocked` за поставки `missing`/`stale`).

- [ ] **Step 1: Тести** — у `Verify.Tests.ps1`, у `Describe 'kit verify — мок платформного шару…'`, нові `It` з тим самим моком `Invoke-KitStorageCheckout` (`$script:MockContent`):

```powershell
    It 'equal, але -Ref = дзеркало, а не HEAD — push force (§10 П4)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'al-ref') -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $storageDir = Join-Path $TestDrive 'al-ref-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB'
        $r.Results[0].Verdict | Should -Be 'equal'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'equal, -Ref main = HEAD, дерево чисте — pull' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'al-head') -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        git -C $repo merge -q --no-edit --allow-unrelated-histories storage/Alpha_SMB
        $storageDir = Join-Path $TestDrive 'al-head-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'main'
        $r.Results[0].Verdict | Should -Be 'equal'
        $r.AlignSteps[0].Op | Should -Be 'pull'
        $r.AlignSteps[0].Steps[0] | Should -BeLike '*"op":"pull"*"sourceSet":"Alpha_SMB"*'
    }
    It 'ref-ahead на HEAD — push force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'al-ahead') -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        git -C $repo merge -q --no-edit --allow-unrelated-histories storage/Alpha_SMB
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Value '<!-- робота -->'
        git -C $repo commit -qam 'робота'
        $storageDir = Join-Path $TestDrive 'al-ahead-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'main'
        $r.Results[0].Verdict | Should -Be 'ref-ahead'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'equal, -Ref main = HEAD, але невідстежуваний файл у наборі — push force (pull стер би його)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'al-dirty') -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        git -C $repo merge -q --no-edit --allow-unrelated-histories storage/Alpha_SMB
        $storageDir = Join-Path $TestDrive 'al-dirty-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Новая.xml') -Value 'робота агента' -Encoding UTF8
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'main'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
```

> Перевірка до коду (kit-dev (б)): `verify` порівнює дерево `-Ref` (коміт), а не робочу копію, тож невідстежуваний `Новая.xml` вердикту `equal` не зіпсує — тест перевіряє саме половину критерію «дерево чисте». Якщо вердикт виявиться не `equal`, тест не перевіряє того, що мусить: зупинка й питання контролеру.

> Перевірка до коду: злиття `storage/*` у `main` git-ом у тесті не спіткнеться на хуку `pre-merge-commit` фікстури? Якщо спіткнеться — `$env:V8KIT_SYNC = '1'` на час `git merge` у тесті (так дзеркало пише kit), з коментарем чому.

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація** — у `Invoke-KitVerify`:
  - `$alignSteps = [System.Collections.Generic.List[object]]::new()` перед циклом `foreach ($item in $plan)`.
  - Рядок «База агента … тепер містить версію … Перед роботою: operation=build Уніки» → `("  База агента воркспейсу '{0}' тепер містить версію {1} зі сховища — це контракт verify, не збій." -f $agent.Workspace, $ver)`.
  - Після `switch ($verdict) { … }`:

```powershell
        # Спека 2026-10-11 §4.1, §10 П4: verify зрушив базу агента (UpdateCfg до версії merge-base).
        # pull — лише коли kit довів рівність: вердикт equal, звіряли саме HEAD, дерево набору чисте.
        $criterion = ($verdict -eq 'equal') -and (Test-KitRefIsHead -RepoRoot $root -Ref $ref) -and
                     (Test-KitSetClean -RepoRoot $root -RepoPath $src.RepoPath)
        $alignStep = Get-KitAlignStep -Source $src -Criterion $criterion -BaseKind $agent.Kind
        Write-KitAlignStep -Step $alignStep
        $alignSteps.Add($alignStep)
```

  - Наприкінці `Invoke-KitVerify`, перед поверненням: `Write-KitAlignStops -Steps $alignSteps.ToArray()` — рядки `ЗУПИНКА:` останніми (умова архітектора до Op `blocked`).

  - У `$results.Add(...)` — `AlignStep = $alignStep`.
  - Повернення: `[pscustomobject]@{ ExitCode = …; Results = $results.ToArray(); AlignSteps = $alignSteps.ToArray() }`. Раннє повернення «немає джерел» → `AlignSteps = @()`.

- [ ] **Step 4: Прогін — зелений.**

- [ ] **Step 5: Мутації** — на копії дерева, кожна окремо: (а) прибрати `-and (Test-KitRefIsHead …)` — червоніє «equal, але -Ref = дзеркало»; (б) прибрати `-and (Test-KitSetClean …)` — червоніє «невідстежуваний файл у наборі». Тексти падінь — у звіт.

- [ ] **Step 6 (контролер, з дозволу людини): Коміт.** Тема: `§4.1, §10 П4: verify друкує крок вирівнювання`.

### Task 11: `provision` — хто створює базу (§4.2, §3 рішення 4, §10 П7, П8, П15, П16)

**Рівень ризику:** властивість безпеки (видалення теки бази й пам'яті раннера) → два рев'ю.

**Files:**
- Modify: `tools/commands/provision.psm1`:
  - `Invoke-KitProvision` — переписати тіло циклу й параметри;
  - нові приватні `Get-KitConfigurationFitness`, `Get-KitProvisionNextKitStep`, `Get-KitProvisionSteps`;
  - `New-KitOwnerMissingMessage` — тексти;
  - `Test-KitConfigurationOwnerPresent` — `.DESCRIPTION`.
- Test: `tools/tests/Provision.Tests.ps1` (переписати тести, що чекали `CREATEINFOBASE` на придатному дереві, зупинку «серверна … Kit її не створює», «у v8project.yaml немає infobase:»)

**Interfaces:**
- Consumes:
  - `Resolve-KitAgentBase` (з `Password`, `Dbms`), `Test-KitWorkspaceNeedsAgentBase`, `New-KitAgentBaseMissingMessage` (Task 4);
  - `Format-KitUnicaRun`, `Write-KitNextSteps` (Task 6);
  - `Remove-KitDirectory` (Task 1);
  - `Get-KitSupplyState`; `New-V8FileInfobase`.
- Produces: `kit provision [-Workspace] [-Source] [-Apply] [-Force] [-Template <.dt>] [-Remember] [-ServerBase New|Existing]` → `{ExitCode = 0; Provisioned = @({Workspace; Path; Template; CreatedBy = 'kit'|'unica'|'existing'; Steps = string[]})}`.

Таблиця рішень (спека §4.2 на `8d94204` + §10):

| База | Дерево `CONFIGURATION` (`truth: storage`) | `-Apply` робить kit | Кроки |
|---|---|---|---|
| файлова, без `.dt` | придатне | прибирає теку бази й `<workPath>/infobases/origin` | `infobase.create {}` → `push {}` |
| файлова, без `.dt` | не придатне: (i) порожнє / (ii) поставка `missing`/`stale` | прибирає обидві; `CREATEINFOBASE` порожньої | (i) `kit sync -Source <к> -FromLatest -Apply`; (ii) `kit verify -Source <к>` |
| файлова, `.dt` | придатне / ні | прибирає обидві | `infobase.restore {input, mode:create}` → `push {force}` / наступний крок kit |
| серверна, `-ServerBase New` | придатне / ні | прибирає `<workPath>/infobases/origin` | `infobase.create {}` → `push {force}` / наступний крок kit |
| серверна, `-ServerBase Existing` | придатне / ні | прибирає `<workPath>/infobases/origin` | `push {force}` / наступний крок kit |
| серверна без `-ServerBase` | — | зупинка з рецептом | — |
| немає `infobases.origin`, є `CONFIGURATION`/`EXTENSION` | — | зупинка `New-KitAgentBaseMissingMessage` | — |
| лише `EXTERNAL_DATA_PROCESSORS` | — | «бази тут не буває», далі | — |

- [ ] **Step 1: Тести** — `tools/tests/Provision.Tests.ps1`, підпроцес. Хелпери `Invoke-Provision`, `Add-KitOwnerTree` — наявні у файлі.

```powershell
Describe 'kit provision 1.5.0 — хто створює базу (спека §4.2, §10)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Provision { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        function script:Add-Owner { param([string]$Repo)
            $dir = Join-Path $Repo 'Alpha_SMB/cf/src'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base') }
        $script:StorageWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
    }

    It 'файлова, дерево придатне: прев''ю друкує infobase.create і push, без CREATEINFOBASE' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fit') -WithHooks
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*unica.run {"op":"infobase.create","args":{},"dryRun":true}*'
        $r.Output | Should -BeLike '*unica.run {"op":"push","args":{},"dryRun":true}*'
    }
    It 'файлова придатна, -Apply -Force: прибрано теку бази й пам''ять раннера, бази kit не створював (П7)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fit-force') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path (Join-Path $mem 'hashes') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'generation.json') -Value '{}' -Encoding UTF8
        $owner = Join-Path $repo 'Alpha_SMB/build/infobases/owner.json'
        Set-Content -LiteralPath $owner -Value '{}' -Encoding UTF8
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
        Test-Path -LiteralPath $mem | Should -BeFalse
        Test-Path -LiteralPath $owner | Should -BeTrue -Because 'мітку власника й замок поруч не чіпати (§10 П7)'
        $r.Output | Should -BeLike '*"op":"infobase.create"*'
    }
    It 'база існує, -Apply без -Force — зупинка, нічого не прибрано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'exists') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*База агента вже є*-Force*'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'рецепт (i): truth: storage, дерева немає — прев''ю: kit створить порожню, далі kit sync' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'r1') -Workspaces $script:StorageWs -NoSourceTrees -WithHooks
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*не придатне*рецепт (i)*'
        $r.Output | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $r.Output | Should -Not -BeLike '*"op":"infobase.create"*'
    }
    It 'рецепт (ii): поставка без .cf — прев''ю: далі kit verify, не push' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'r2') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Remove-Item -Force
        $r = Invoke-Provision -Repo $repo
        $r.Output | Should -BeLike '*рецепт (ii)*'
        $r.Output | Should -BeLike '*kit verify -Source base*'
        $r.Output | Should -Not -BeLike '*"op":"push"*'
    }
    It 'з .dt: infobase.restore з абсолютним шляхом, потім push force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dt') -WithHooks
        Add-Owner -Repo $repo
        $dt = Join-Path $TestDrive 'demo.dt'; Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Template', $dt)
        $r.Output | Should -BeLike '*"op":"infobase.restore","args":{"input":"*demo.dt","mode":"create"}*'
        $r.Output | Should -BeLike '*"op":"push","args":{"force":true}*'
    }
    It 'серверна без -ServerBase — код 1, рецепт з обома варіантами' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-ServerBase New*-ServerBase Existing*'
    }
    It 'серверна New без dbms — код 1, називає відсутні ключі' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-nodbms') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL' })
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*server, name, locale*'
    }
    It 'серверна New: прев''ю — застереження CrSQLDB з іменем бази даних, infobase.create, push force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-new') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk' })
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike "*CrSQLDB=Y*'agent_db'*'pg1'*"
        $r.Output | Should -BeLike '*"op":"infobase.create"*"op":"push","args":{"force":true}*'
    }
    It 'серверна Existing -Apply: прибрано пам''ять раннера, крок push force (П7)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-ex') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing', '-Apply')
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $mem | Should -BeFalse
        $r.Output | Should -BeLike '*"op":"push","args":{"force":true}*'
    }
    It '-ServerBase на файловій базі — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file-sb') -WithHooks
        Add-Owner -Repo $repo
        (Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')).ExitCode | Should -Be 1
    }
    It 'П16: немає infobases.origin — код 1, рецепт v8storagekit:provision' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-origin') -WithHooks -Workspaces ([ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } })
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не налаштована*v8storagekit:provision*'
    }
    It 'П16: лише зовнішні обробки — код 0, «бази тут не буває»' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -WithHooks -Workspaces ([ordered]@{
            'Epf' = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } })
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*бази агента тут не буває*'
    }
}
```

> Перевірки до коду (kit-dev, case 21/22):
> - (а) `grep -rn "не придатне\|бази агента тут не буває\|CrSQLDB=Y" tools/` — фрази лише в `provision.psm1`;
> - (б) зупинка власника (`New-KitOwnerMissingMessage`) стоїть раніше за придатність — тест «рецепт (i)» мусить пройти повз неї (порожнє дерево під `truth: storage` власника не зупиняє, див. `Get-KitMissingOwnerSources` і фільтр `Truth -ne 'storage'`);
> - (в) тести на `infobase.create` червоні до зміни: зараз прев'ю друкує «порожня база (без .dt)».

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: Реалізація — приватні функції** у `provision.psm1` (перед `Invoke-KitProvision`):

```powershell
function Get-KitConfigurationFitness {
    <#
    .SYNOPSIS
        Чи придатне дерево основної конфігурації до повного завантаження в базу (спека §3 рішення 4).
    .DESCRIPTION
        «Базу створює той, хто першим її наповнює». Придатне → першою наповнює Уніка (infobase.create
        імпортує набір CONFIGURATION). Не придатне — truth: storage і (i) дерева ще немає або (ii)
        поставка вендора missing/stale, тобто .bin без .cf — повне завантаження впало б. Тоді першим
        наповнює kit зі сховища (sync чи verify), і порожню файлову базу створює теж kit. truth:
        vendor/dump сюди не входять: їхнє дерево приходить з kit dump разом із поставкою, а відсутність
        власника ловить New-KitOwnerMissingMessage раніше.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)
    foreach ($src in @($Workspace.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })) {
        if (@(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
            return [pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'i'; Supply = $null }
        }
        $state = Get-KitSupplyState -TreeRoot $src.FullPath
        if ($state -in 'missing', 'stale') {
            return [pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'ii'; Supply = $state }
        }
    }
    [pscustomobject]@{ Fit = $true; Source = $null; Recipe = $null; Supply = $null }
}

function Get-KitProvisionNextKitStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fitness, [Parameter(Mandatory)][string]$MainBranch)
    $k = $Fitness.Source.Key
    if ($Fitness.Recipe -eq 'i') {
        return ("kit sync -Source $k -FromLatest -Apply (або -FromVersion N) — на головній гілці чи гілці онбордингу; sync наповнить " +
                "базу й надрукує крок вирівнювання Уніки (pull і позначку поставки)")
    }
    "kit verify -Source $k — на гілці $MainBranch (HEAD = $MainBranch, дерево чисте); очікувано equal, verify наповнить базу й надрукує pull Уніки та kit canon -Source $k -MarkerOnly -Apply"
}

function Get-KitProvisionSteps {
    <#
    .SYNOPSIS
        Кроки після рішення provision — одна таблиця спеки §4.2 (на 8d94204) замість розгалужень по тексту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('file-empty', 'file-dt', 'server-new', 'server-existing')][string]$Kind,
        [Parameter(Mandatory)]$Fitness,
        [string]$TemplatePath,
        [Parameter(Mandatory)][string]$MainBranch
    )
    $steps = [System.Collections.Generic.List[string]]::new()
    if ($Kind -eq 'file-empty') {
        if ($Fitness.Fit) {
            $steps.Add((Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{})))
            $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{})))
        } else {
            $steps.Add((Get-KitProvisionNextKitStep -Fitness $Fitness -MainBranch $MainBranch))
        }
        return , $steps.ToArray()
    }
    if ($Kind -eq 'file-dt')    { $steps.Add((Format-KitUnicaRun -Op 'infobase.restore' -Arguments ([ordered]@{ input = $TemplatePath; mode = 'create' }))) }
    if ($Kind -eq 'server-new') { $steps.Add((Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{}))) }
    if ($Fitness.Fit) { $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ force = $true }))) }
    else              { $steps.Add((Get-KitProvisionNextKitStep -Fitness $Fitness -MainBranch $MainBranch)) }
    , $steps.ToArray()
}
```

- [ ] **Step 4: Реалізація — `Invoke-KitProvision`.**
  - Параметр `[ValidateSet('New', 'Existing')][string]$ServerBase` у `param()`.
  - `.SYNOPSIS`/`.DESCRIPTION`: «База агента (спека 2026-10-11 §4.2): kit вирішує, перевіряє, прибирає стару базу й пам'ять раннера; створює той, хто першим наповнює (§3 рішення 4)».
  - Тіло циклу `foreach ($ws in $workspaces)` до блоку `-Remember` (сам блок `-Remember` лишається):

```powershell
        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        if (-not (Test-KitWorkspaceNeedsAgentBase -Workspace $ws)) {
            Write-Host '  У воркспейсі лише зовнішні обробки — бази агента тут не буває.'
            continue
        }
        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { throw (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path) }

        $wsTemplate = $Template
        if (-not $wsTemplate -and $Context.Overlay -and $Context.Overlay.Workspaces.ContainsKey($ws.Path)) {
            $wsTemplate = $Context.Overlay.Workspaces[$ws.Path].AgentBaseTemplate
        }
        Write-Host "База:      $($ab.Connection)  ($($ab.Origin))"

        # Вісь власника — до вибору типу бази (рішення користувача 2026-09-10): truth: storage без
        # дерева — не зупинка, а рецепт (i) нижче (Get-KitConfigurationFitness).
        if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) {
            $missing = @(Get-KitMissingOwnerSources -Workspace $ws)
            if (@($missing | Where-Object Truth -ne 'storage').Count -gt 0) { throw (New-KitOwnerMissingMessage -Workspace $ws) }
        }
        $fitness = Get-KitConfigurationFitness -Workspace $ws
        if (-not $fitness.Fit) {
            $why = if ($fitness.Recipe -eq 'i') { 'дерева ще немає — рецепт (i)' } else { "поставка вендора $($fitness.Supply) — рецепт (ii)" }
            Write-Host ("  Дерево основної конфігурації '{0}' не придатне до завантаження ({1}): першим базу наповнить kit зі сховища, тож і створить її kit." -f $fitness.Source.Key, $why) -ForegroundColor Cyan
        }

        # F7 (рев'ю B4 Task 1): межа видалення — робоча тека воркспейсу (workPath), не вся тека.
        $agentWork = Join-Path $ws.FullPath $ws.Project.WorkPath
        Assert-SafeWorkPath -Path $agentWork -MustBeUnder $ws.FullPath -Description "робоча тека воркспейсу $($ws.Path) (workPath у v8project.yaml)"
        # Спека §10 П7: пам'ять раннера знищеної чи чужої бази — інакше старі хеші розширень стали б
        # «своєю» пам'яттю нової бази, і push пропустив би їх (клас #25). Мітку власника й замок поруч
        # (інші файли <workPath>/infobases/) не чіпати.
        $memoryDir = Join-Path $agentWork 'infobases/origin'
        Assert-SafeWorkPath -Path $memoryDir -MustBeUnder $agentWork -Description "пам'ять раннера бази origin воркспейсу $($ws.Path)"

        if ($ab.Kind -eq 'server') {
            if (-not $ServerBase) {
                throw ("База агента воркспейсу '$($ws.Path)' серверна ($($ab.Connection)). Вкажіть -ServerBase New — Уніка створить її в " +
                       'кластері з infobases.origin.dbms, або -ServerBase Existing — базу дала людина, kit лише прибере пам''ять раннера й надрукує крок.')
            }
            if ($wsTemplate) { throw "-Template (.dt) для серверної бази агента не підтримується: розгортання .dt на сервері — поза обсягом. Приберіть -Template чи agentBase.template з накладки." }
            if ($ServerBase -eq 'New') {
                $missingDbms = @('kind', 'server', 'name', 'locale' | Where-Object {
                    $null -eq $ab.Dbms -or -not $ab.Dbms.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$ab.Dbms[$_]) })
                if ($missingDbms.Count -gt 0) {
                    throw ("Для -ServerBase New у $($ab.Origin) під infobases.origin.dbms бракує: $($missingDbms -join ', '). " +
                           'Їх і реквізити адміністратора кластера питає в людини скіл v8storagekit:provision.')
                }
                $crWarn = ("  УВАГА: раннер створює базу з CrSQLDB=Y — він МОВЧКИ бере наявну базу даних СУБД з тим самим іменем ('{0}' на '{1}'). " +
                           "Ім'я бази даних підтверджує людина до кроку. Регламентні завдання в новій базі вимкнено (SchJobDn=Y). " +
                           'Адміністратор кластера — infobases.origin.cluster { user, password } (SUsr/SPwd).') -f $ab.Dbms['name'], $ab.Dbms['server']
                Write-Host $crWarn -ForegroundColor Yellow
            }
            $kind = if ($ServerBase -eq 'New') { 'server-new' } else { 'server-existing' }
            $steps = Get-KitProvisionSteps -Kind $kind -Fitness $fitness -MainBranch $Context.MainBranch
            if (-not $Apply) {
                Write-Host "  Це попередній перегляд. Для виконання додайте -Apply (kit прибере пам'ять раннера $memoryDir)." -ForegroundColor Cyan
                Write-KitNextSteps -Title 'Далі:' -Steps $steps
                continue
            }
            Remove-KitDirectory -Path $memoryDir
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $null; Template = $null
                CreatedBy = $(if ($ServerBase -eq 'New') { 'unica' } else { 'existing' }); Steps = $steps })
            continue
        }
        if ($ServerBase) { throw "-ServerBase стосується лише серверної бази агента, а в $($ab.Origin) — файлова ($($ab.Connection))." }

        Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $agentWork -Description "база агента воркспейсу $($ws.Path)"
        Write-Host ('Шлях:      ' + $ab.Path + $(if ($ab.Exists) { '  (існує)' } else { '  (ще немає)' }))
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        $kind = if ($wsTemplate) { 'file-dt' } else { 'file-empty' }
        $templateFull = if ($wsTemplate -and (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { (Resolve-Path -LiteralPath $wsTemplate).Path } else { $wsTemplate }
        $steps = Get-KitProvisionSteps -Kind $kind -Fitness $fitness -TemplatePath $templateFull -MainBranch $Context.MainBranch
        $kitCreates = ($kind -eq 'file-empty' -and -not $fitness.Fit)

        if (-not $Apply) {
            $previewNote = '  Це попередній перегляд. Для виконання додайте -Apply' + $(if ($ab.Exists) { ' -Force (база існує й буде прибрана разом із пам''яттю раннера).' } else { '.' })
            Write-Host $previewNote -ForegroundColor Cyan
            if ($kitCreates) { Write-Host '  З -Apply kit сам створить порожню файлову базу.' -ForegroundColor Cyan }
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            if ($Remember) { Write-Host '  Шаблон буде записано в накладку разом із -Apply (-Remember саме по собі нічого не пише).' -ForegroundColor DarkGray }
            continue
        }
        if ($ab.Exists -and -not $Force) {
            throw "База агента вже є: $($ab.Path). Перестворити з нуля — kit provision -Workspace $($ws.Path) -Apply -Force."
        }
        if ($wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }

        Remove-KitDirectory -Path $ab.Path
        Remove-KitDirectory -Path $memoryDir
        if ($kitCreates) {
            Write-Host '  Створюю порожню базу (першим її наповнить kit зі сховища)...'
            $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $agentWork
            Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        } else {
            Write-Host "  Стару базу й пам'ять раннера прибрано; базу створює Уніка — крок нижче." -ForegroundColor Green
        }
        Write-KitNextSteps -Title 'Далі:' -Steps $steps
```

  - `$done.Add(...)` наприкінці файлової гілки: `[pscustomobject]@{ Workspace = $ws.Path; Path = $ab.Path; Template = $wsTemplate; CreatedBy = $(if ($kitCreates) { 'kit' } else { 'unica' }); Steps = $steps }`.
  - Цикл попередження про поставку (`Get-KitSupplyRecipe` для `missing`/`stale`) і друк «рецепт (i) … operation=build» **прибрати**: обидва випадки тепер — придатність.
  - `New-KitOwnerMissingMessage`: «наповнюється operation=build Уніки, а build спершу вантажить власника» → «наповнюється push Уніки, а push спершу вантажить власника». «operation=build без нього так само не проходить» → «push без нього так само не проходить». Варіант «серверна база, яку створює людина в кластері» → «серверна база, яку дала людина (kit provision -ServerBase Existing)».
  - Коментарі з `operation=build` — новим словником.

- [ ] **Step 4а: Розбір парсером** до прогону тестів — синтаксична помилка в модулі ламає завантаження всього `kit.ps1`, і набір червоніє не там:

```powershell
$errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path tools/commands/provision.psm1), [ref]$null, [ref]$errs); $errs
```

  Очікувано: порожньо. (Перша редакція цього плану мала тут зайву дужку біля `-f` — `Write-Host (…) -f …` PowerShell читає як параметр `Write-Host`; рядок складається у змінну до виклику.)

- [ ] **Step 5: Наявні тести `Provision.Tests.ps1`.** Тести, що чекали старої поведінки (знайдено аудитом; перелік звірити `grep`-ом):
  - «серверна база — зупинка `*Srvr*кластер*`»: фікстура з порожнім vendor-деревом тепер зупиняється раніше на власнику — переписати на новий `Describe` (додати власника) або прибрати як покритий тестом «серверна без -ServerBase»;
  - «рецепт (i)» з очікуваннями `*Основна конфігурація 'base'*` і `*kit canon -Source base -Apply*` → покрито новим «рецепт (i)»;
  - «поставка застаріла» з `*поставка вендора застаріла*` → новий текст друкує стан `stale` у фразі придатності; переписати очікування на `*поставка вендора stale*рецепт (ii)*`;
  - «у v8project.yaml немає infobase:» → П16;
  - **`Integration`** «порожня база агента створюється під build/ib» і «база з .dt і -Remember: створена…»: для придатного дерева й `.dt` базу тепер створює Уніка, а не kit, тож `1Cv8.1CD` не з'явиться. Переписати на непридатне дерево (рецепт (i) — kit створює порожню базу, `-Apply` з платформою) і на «`.dt`: `-Remember` записав шаблон у накладку, кроки надруковано, база kit не створена». Ці два видно лише в прогоні `Integration` (Task 17) — переписати зараз, не чекати фіналу.

  Переписати або прибрати, якщо новий `Describe` вище покриває той самий випадок. Прибирання — з рядком у звіті, яким тестом покрито. Тест «П16: лише зовнішні обробки» зелений ще до зміни (поведінка вже була) — червоніє лише від мутації «прибрати перевірку `Test-KitWorkspaceNeedsAgentBase`», і це записати.

- [ ] **Step 6: Прогін — зелений.**

- [ ] **Step 7: Мутації — на копії дерева, кожна окремо, текст падіння у звіт:**
  - (а) прибрати `Remove-KitDirectory -Path $memoryDir` у файловій гілці — червоніє «-Apply -Force: прибрано … пам'ять раннера»;
  - (б) у `Get-KitConfigurationFitness` прибрати перевірку `missing`/`stale` — червоніє «рецепт (ii)»;
  - (в) прибрати перевірку `Test-KitWorkspaceNeedsAgentBase` — червоніє «П16: лише зовнішні обробки».

- [ ] **Step 8 (контролер, з дозволу людини): Коміт.** Тема: `§4.2, §10 П7/П8/П15/П16: provision — базу створює той, хто першим наповнює; серверна база агента`.

### Task 12: Скіли й шаблони — поверхня 0.13, крок з виводу команди, `provision`, рецепти поставки (§4.3 п. 1–2, §4.4 п. 1–2, §4.6 #13/#25, §10 П5/П15)

**Рівень ризику:** механічна (текст), але з наслідками для поведінки агента-споживача → рев'ю на сильній моделі з читанням дифу скілів рядок за рядком.

**Files:**
- Modify: `skills/using-v8storagekit/SKILL.md`, `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md` (і поле `description` у frontmatter), `skills/sync/SKILL.md`, `skills/verify/SKILL.md`, `skills/provision/SKILL.md` (і `description`), `skills/onboarding/SKILL.md`, `skills/onboarding/references/gitsync-migration.md` (якщо грep знаходить там старий словник), `skills/dump/SKILL.md` (якщо знаходить)
- Modify: `templates/CLAUDE.md`, `templates/README.md`, `templates/v8storagekit.local.yaml.example` (речення «лапки не приймаються»), `templates/gitignore` (коментар «Відновлення .cf … kit canon з бази агента»), `templates/gitattributes` (коментар про `unica.project.status`)
- Test: `tools/tests/Skills.Tests.ps1`, `tools/tests/Templates.Tests.ps1`

**Interfaces:**
- Consumes (тексти мусять називати рівно ці форми):
  - `kit canon -Source <к> -MarkerOnly -Apply` (Task 8);
  - друк кроку `Далі — вирівняти пам'ять раннера …` (Task 7);
  - `kit provision … -ServerBase New|Existing` (Task 11);
  - форма `unica.run {"op":…,"args":{…},"dryRun":…}` (Task 6).

Повний перелік місць — три пошуки, кожен до нуля збігів (крім історичних розділів `upgrades.md`, Task 16):
1. шаблон запобіжника Task 13 (`Get-RemovedPattern`) — запустити як інструмент пошуку по `skills/` і `templates/` ще до Task 13;
2. `grep -rn "builder\|execution_timeout\|infobase\.\(connection\|user\)\|паролів бази агента" skills templates`;
3. `grep -rni "лапк" skills templates` і `grep -rn "canon" skills templates` — кожне твердження «лапки не приймаються» і «поставку відновлює `canon`-дамп» переглянути проти Tasks 2 і 8.

Відомі місця поза названими кроками: `skills/onboarding/SKILL.md` — абзац про дев-бази «без лапок — kit лапки відхиляє» і рядок із `cfe.borrow`/`cfe.diff`/`cfe.validate` (у Step 8).

**Тексти, що цитують зняті імена, валять запобіжник Task 13** — тож ні скіл, ні шаблон не перелічує старих імен навіть як «знято»: замість цього — «перелік знятої поверхні — `tools/tests/Vocabulary.Tests.ps1`».

- [ ] **Step 1: Тести** — у `tools/tests/Skills.Tests.ps1` замінити `It`, що фіксують старий словник. Тест шаблону перевіряє **саме блок закоміченого `v8project.yaml`**, а не весь текст скіла (інакше повернення `infobases:` у закомічений шаблон лишилось би зеленим — блок `v8project.local.yaml` у тому самому скілі містить `infobases:`):

```powershell
        It 'шаблон v8project.yaml 0.13: providers designer, без builder/execution_timeout і без бази; база — infobases.origin у блоці local' {
            $t = Skill 'onboarding'
            $blocks = [regex]::Matches($t, '(?ms)^```yaml\s*\r?\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value }
            $committed = @($blocks | Where-Object { $_ -match '(?m)^format:\s*DESIGNER' })
            $committed | Should -HaveCount 1
            $c = $committed[0]
            $c | Should -Match '(?m)^providers:\s*$'
            foreach ($op in 'push', 'pull', 'download') { $c | Should -Match "(?m)^\s+${op}:\s*designer" }
            $c | Should -Not -Match '(?m)^\s*(builder|execution_timeout|infobase|infobases):'
            $c | Should -Match '(?m)^\s*-\s*name:\s*<ІмʼяРозширення>'
            $local = @($blocks | Where-Object { $_ -match '(?m)^infobases:\s*$' -and $_ -match '(?m)^\s+origin:\s*$' })
            $local | Should -Not -BeNullOrEmpty
            $t.IndexOf('v8project.local.yaml') | Should -BeLessThan $t.IndexOf($local[0]) -Because 'блок бази стоїть після назви файлу, у який його пишуть'
        }
```

  У `Templates.Tests.ps1` наявний `It 'C2 Task 7: абзац «Збірка .cfe»…'` — `Should -Match 'output=build/artifacts/<Ім''я>\.cfe'` → `Should -Match '"output":"build/artifacts/<Ім''я>\.cfe"'`; заперечну перевірку (`output=<корінь`) лишити.

```powershell
    Context 'provision' {
        It 'три типи бази, -ServerBase New|Existing, CrSQLDB, infobases.origin, -Remember, крок з виводу' {
            $t = Skill 'provision'
            $t | Should -Match '\*\*порожня\*\*'
            $t | Should -Match '\*\*з `?\.dt`?\*\*|\*\*з \.dt\*\*'
            $t | Should -Match '\*\*серверна\*\*'
            $t | Should -Match '-ServerBase New'
            $t | Should -Match '-ServerBase Existing'
            $t | Should -Match 'CrSQLDB'
            $t | Should -Match 'infobases\.origin'
            $t | Should -Match '-Remember'
            $t | Should -Match 'надрукован'
        }
    }
    Context 'reconcile' {
        It 'sync → крок, надрукований sync (push force) → canon → adopt; #25' {
            $t = Skill 'reconcile'
            $t | Should -Match 'kit\.ps1" sync'
            $t | Should -Match 'надрукован'
            $t | Should -Match '"force":true'
            $t | Should -Match 'non_fast_forward'
            $t | Should -Match 'kit\.ps1" canon'
            $t | Should -Match 'kit\.ps1" adopt'
            $t | Should -Match 'зникне з гілки'
            $t | Should -Match 'не rebase'
            $t | Should -Not -Match 'git rebase'
            $t | Should -Not -Match 'git merge --no-ff storage/'
        }
    }
    Context 'finish' {
        It 'sync → canon → adopt → verify → крок verify → unica.check → артефакти → PR; push і PR лише з дозволу' {
            $t = Skill 'finish'
            foreach ($m in 'kit\.ps1" sync', 'kit\.ps1" canon', 'kit\.ps1" adopt', 'kit\.ps1" verify', 'kit\.ps1" build',
                           'unica\.check', '"op":"make"', 'gh pr create', 'build/artifacts') { $t | Should -Match $m }
            $t | Should -Not -Match 'testRunner'
            $t | Should -Match 'лише за явним проханням|лише на явне прохання'
            $t | Should -Match 'суттєв'
            $t | Should -Match 'ЗНИКНЕ з гілки'
            $t | Should -Match '--name-only'
            $t | Should -Not -Match 'ORIG_HEAD'
        }
    }
```

  `It 'finish ставить operation=build між verify і тестами'` → нова форма:

```powershell
    It 'finish ставить крок, надрукований verify, між verify і unica.check' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/finish/SKILL.md') -Raw -Encoding UTF8
        $posVerify = $text.IndexOf('kit.ps1" verify')
        $posStep   = $text.IndexOf('надрукован', $posVerify)
        $posCheck  = $text.IndexOf('unica.check', $posVerify)
        $posVerify | Should -BeGreaterThan -1
        $posStep   | Should -BeGreaterThan $posVerify
        $posCheck  | Should -BeGreaterThan $posStep
    }
```

  `It 'sync, verify і reconcile попереджають, що база лишається у стані сховища'` — замість `*operation=build*` перевірити `*надрукован*` і лишити `*контракт*`. Коментар біля тесту: чому два твердження (історія C1 — лишити, причину переписати).

  Новий `It`:

```powershell
    It 'using-v8storagekit: маршрутизація 0.13, крок з виводу, сітка infobase_state_unverified, виняток force (П17), ЗУПИНКА, #13' {
        $t = Skill 'using-v8storagekit'
        foreach ($m in 'unica\.view', 'unica\.check', 'unica\.apply', 'executionToken', 'object\.borrow', 'unica\.task\.result',
                       '"op":"push"', '"full":true', '"op":"make"', 'non_fast_forward', 'no_memory', 'infobase_state_unverified',
                       'надрукован', '"dryRun":true', 'ЗУПИНКА', 'Для будь-якої іншої бази правило Уніки діє без винятків') {
            $t | Should -Match $m
        }
        $t | Should -Not -Match 'одинадцять'   # кількість — не в постійному тексті
    }
    It 'sync, verify, reconcile наказують перевірити ЗУПИНКА й не йти далі' {
        foreach ($s in @('sync', 'verify', 'reconcile')) {
            (Skill $s) | Should -Match 'ЗУПИНКА' -Because "$s мусить зупиняти агента на кроці blocked (умова архітектора)"
        }
    }
```

  У `tools/tests/Templates.Tests.ps1` `It 'шаблон оголошує власну базу воркспейсу'` замінити:

```powershell
    It 'шаблон v8project.yaml не оголошує бази агента: вона машинна, у infobases.origin v8project.local.yaml (спека §4.3 п. 2–3)' {
        $script:Skill | Should -Not -Match "(?m)^\s*infobase:\s*$"
        $script:Skill | Should -Match "(?m)^\s*providers:\s*$"
        $script:Skill | Should -Match "connection:\s*'File=build/ib'"   # тепер — у блоці v8project.local.yaml розділу 3.2.1
    }
```

  У `Templates.Tests.ps1`, `Describe` про `templates/CLAUDE.md`:

```powershell
    It 'templates/CLAUDE.md говорить мовою Уніки 0.13' {
        $c = Get-Content -LiteralPath (Join-Path $script:Root 'templates/CLAUDE.md') -Raw -Encoding UTF8
        $c | Should -Not -Match 'operation='
        $c | Should -Match 'infobases\.origin'
        $c | Should -Match '"op":"make"'
        $c | Should -Match 'unica\.check'
    }
```

  (`$script:Root` — наявна змінна того `Describe`; якщо там інша — взяти її.)

- [ ] **Step 2: Прогін — червоний.**

- [ ] **Step 3: `skills/using-v8storagekit/SKILL.md`.**
  - Принцип 2 → «**Unica — основний інструмент; kit доповнює.** Редагування, перевірка, завантаження в базу агента, збірка `.cf`/`.cfe` — Unica 0.13.»
  - Розділ «Маршрутизація до Unica» замінити цілком:

````markdown
## Маршрутизація до Unica (0.13)

Kit говорить лише мовою Уніки 0.13. Стара поверхня 0.12 знята без аліасів; її перелік — у
запобіжнику kit `tools/tests/Vocabulary.Tests.ps1` (тут не повторюється).

| Що | Виклик |
|---|---|
| огляд воркспейсу | `unica.view {}` |
| готовність воркспейсу, політика git | `unica.check {}` |
| перевірка коду й метаданих | `unica.check {at: <шлях або логічна адреса>}` |
| пошук, адреса, документація, різниця | `unica.search`, `unica.resolve`, `unica.docs`, `unica.diff` |
| правка вихідників (зокрема запозичення в розширення — операція `object.borrow`) | `unica.apply`: план → `executionToken` → застосування |
| завантажити дерево в базу агента | `unica.run {"op":"push","args":{"sourceSet":"<набір>"},"dryRun":true}` |
| перезібрати лише одне розширення, не всю базу | `unica.run {"op":"push","args":{"sourceSet":"<розширення>","full":true},"dryRun":true}` — `full` теж звіряє покоління: без пам'яті раннера відповідь `no_memory`, і тоді — той самий виклик з `"force":true` (лише база агента, див. нижче) |
| зібрати `.cf`/`.cfe` | `unica.run {"op":"make","args":{"sourceSet":"<набір>","extension":"<ім'я>","output":"build/artifacts/<ім'я>.cfe"},"dryRun":true}` — `output` відносний до воркспейсу (поза свій корінь Уніка не пише), `extension` обов'язковий для `.cfe` |
| довга операція | `unica.task.get`, `unica.task.result` |

Уніка вимагає явний `"dryRun"` у кожному `unica.run`; kit **за власною конвенцією** друкує
спершу `"dryRun":true` (превью показує попередження на кшталт `infobase_overwritten` до виконання),
потім той самий виклик з `"dryRun":false`.

**Крок, надрукований командою kit, — виконати дослівно.** `sync`, `verify` і `provision` зрушують
чи створюють базу агента й завершуються рядками «Далі …» — точний `unica.run …` і, для поставки
вендора, `kit canon … -MarkerOnly -Apply` (файлова база) чи `kit canon … -Apply` (серверна). Їх не
переказують і не замінюють своїм. Після `pull` — `git status --porcelain -- <шлях набору>`:
непорожній вивід означає, що вивантаження раннера дало інші байти, ніж kit, — зупинка й доповідь,
не робота для агента. **Рядок `ЗУПИНКА: …` наприкінці виводу команди — зупинка з доповіддю людині,
без обходу і без наступних кроків скіла**; поле `AlignSteps` з `Op = 'blocked'` означає те саме.

**`force:true` на базі агента — виняток із правила Уніки** («never add force:true on your own after
a non_fast_forward or no_memory refusal … belongs to the user»). Правило Уніки захищає базу, в яку
могли писати поза цією робочою копією. База агента в контурі kit (`infobases.origin`, перевірена kit
як не база людини) за побудовою похідна від git: людина в ній не працює, сховище — істина. Тому для
неї рішення про `force:true` власник прийняв заздалегідь, і агент виконує надрукований kit крок без
питання. Для будь-якої іншої бази правило Уніки діє без винятків.

**Сітка на пропущений крок.** Від пропущеного кроку захищає лише сам надрукований крок, а не раннер:
набір з **незміненим** деревом звичайний `push` пропускає без звірки покоління, а на серверній базі
звірки немає взагалі. Тому в контурі kit `infobase_state_unverified` або `non_fast_forward` (чи
`no_memory`) у відповіді `push` бази агента — **не ігнорувати**, а виконати
`unica.run {"op":"push","args":{"sourceSet":"<набір>","force":true},"dryRun":true}` для кожного
названого набору — повне завантаження з git, безпечне для бази агента за побудовою.

`push` без `sourceSet` вантажить **усі оголошені набори** воркспейсу: на серверній базі агента —
лише з явного підтвердження людини (кроки, які надрукував `provision -ServerBase …`, підтверджено
тим `-Apply`, на яке людина погодилась); для правок розширення — `sourceSet` цього розширення.
`.cf` основної конфігурації людина в сховищі «порівнює й об'єднує з конфігурацією з файлу», а не
завантажує цілком. Застосовні операції Уніки поза кроками kit (`unica.apply` з `executionToken`,
`unica.run` з `"dryRun":false`) — лише на явне прохання, з названим ризиком.
````

- [ ] **Step 4: `skills/reconcile/SKILL.md`, крок 2** — замінити:

```markdown
2. **База агента — з поточного дерева `F`**: виконати крок, який `sync` надрукував у кроці 1 для
   цього набору («Далі — вирівняти пам'ять раннера …»). На гілці задачі це
   `unica.run {"op":"push","args":{"sourceSet":"<ключ>","force":true},"dryRun":true}` — повне
   завантаження гілки задачі в базу, кеш Уніки участі не бере. Звичайний `push` тут не годиться:
   набір з незміненим деревом гілки він пропускає без звірки покоління (відповідь
   `infobase_state_unverified`) — це й був дефект #25 (у 1.4.0 крок мовчки відповідав `skipped`, і
   прев'ю `adopt` виходило хибно порожнім). Від #25 захищає саме надрукований крок; якщо його таки
   пропущено, діє сітка з `v8storagekit:using-v8storagekit` (`infobase_state_unverified` → `push` з
   `"force":true`). Якщо `sync` нових версій не приніс, кроку він не друкує — база не зрушена, і досить
   звичайного `push`, коли дерево `F` змінювалось. Рядок `ЗУПИНКА: …` наприкінці виводу `sync` —
   зупинка: кроки 3–5 не виконувати, доповісти людині.
   Три приводи для кроку, не один: (а) `canon` переписує дерево з бази, і без свіжого завантаження він
   знищить незакомічене; (б) крок 1 (`sync`) щойно лишив базу у стані версії сховища — це контракт,
   а не збій (спека 2026-09-17 §4); (в) канонізація робить прев'ю кроку 4 **семантичним** — див.
   нижче. Якщо крок таки пропущено, незбережене лежить у `<workPath>/canon-backup/<ключ>-<час>/` —
   `canon` копіює його туди й друкує шлях. Це шлях відновлення, а не привід пропускати крок.
```

  У кроці 4/5 додати речення: «Після `adopt -Apply` база вже вирівняна кроком 2 — звичайний `push` Уніки довантажить прийняте дерево.» Розділ «Штатні зупинки»: `canon` «Бази агента ще немає … kit provision» → «… v8storagekit:provision»; додати «`База агента воркспейсу '…' не налаштована` — `v8storagekit:provision`».

- [ ] **Step 5: `skills/finish/SKILL.md`.**
  - Передумови: «база агента є й наповнена (`push` Уніки після останніх правок)».
  - Крок 2: «**Канонізація**: крок, надрукований `sync` у кроці 1 (або звичайний `push`, якщо `sync` нових версій не приніс) → `… canon -RepoRoot . -Apply`; …» (решта кроку без змін).
  - Крок 5: «**Відновити базу агента**: крок, надрукований `verify` у кроці 4 (на гілці задачі — `push` з `"force":true`). `verify` лишив базу у стані версії сховища (контракт, спека 2026-09-17 §4) — без цього кроку перевірка коду побіжить не на тому стані, який іде в PR.»
  - Крок 6 → «**Перевірка коду** (Unica, `cwd` = воркспейс): `unica.check {}` по воркспейсу і `unica.check {at: <модуль або корінь набору>}` по модулях і коренях наборів, змінених у гілці (`git -c core.quotepath=false diff --name-only <mainBranch>...HEAD`). Помилки — PR не готувати; повернутись до роботи. Запуску тестів (YaXUnit/VA) Уніка 0.13 не має — цього кроку немає.»
  - Крок 7: `.cfe`/`.cf` — `unica.run {"op":"make","args":{"sourceSet":"<набір>","extension":"<ім'я>","output":"build/artifacts/<ім'я>.cfe"},"dryRun":true}` (відносний до воркспейсу: поза свій корінь Уніка не пише); решта без змін.
  - Шаблон PR: розділ `## Тести` → `## Перевірка` з рядком `unica.check: <результат>`.
  - Штатні зупинки: «Червоні тести Unica» → «Помилки `unica.check`»; додати «рядок `ЗУПИНКА: …` наприкінці виводу `sync`/`verify` — зупинка з доповіддю».
  - frontmatter `description`: «прогнати тести й синтаксис Unica» → «перевірити код Унікою (`unica.check`)».

- [ ] **Step 6: `skills/sync/SKILL.md`, `skills/verify/SKILL.md`.**
  - `sync`, абзац «Після `sync` база агента містить версію зі сховища…»:

```markdown
**Після `sync` база агента містить версію зі сховища, а не ваше дерево.** Це оголошений контракт
(спека 2026-09-17 §4). Пам'ять раннера Уніки після цього розходиться з базою, тому `sync` для
кожного зрушеного набору друкує один крок вирівнювання — виконати його дослівно
(`v8storagekit:using-v8storagekit`, «Крок, надрукований командою kit»). Раннер пропущеного кроку
сам не ловить: набір з незміненим деревом звичайний `push` пропускає з попередженням
`infobase_state_unverified` — і за цим попередженням виконати `push` з `"force":true`.
Рядок `ЗУПИНКА: …` наприкінці виводу — зупинка з доповіддю людині: далі не йти.
```

  - `verify`, абзац «Після `verify` база агента містить версію зі сховища…» (у `verify` він сформульований інакше — «`verify` друкує про це рядком»): окремий текст тієї самої суті:

```markdown
**Після `verify` база агента містить версію зі сховища, а не ваше дерево.** Це оголошений контракт
(спека 2026-09-17 §4), і `verify` друкує про це рядком, а за ним — крок вирівнювання пам'яті раннера
для кожного набору. Виконати його дослівно (`v8storagekit:using-v8storagekit`, «Крок, надрукований
командою kit»), перш ніж працювати з базою: перевіряти код, збирати. Рядок `ЗУПИНКА: …` наприкінці
виводу — зупинка з доповіддю людині: далі не йти.
```

  - Абзац запасного шляху в `sync` — `operation=build` у ньому вжито **тричі**; кожне → «`push` Уніки з `"force":true` для цього розширення (його ще немає в пам'яті раннера)».
  - `verify`, рядок вердикту `ref-ahead`: `operation=make` → `unica.run` з `"op":"make"`.

- [ ] **Step 7: `skills/provision/SKILL.md` — переписати цілком** за тією самою розбивкою розділів (1 власник, 2 тип, 3 виконання, 4 зупинки, 5 межі). Зміст:
  - **frontmatter `description`:** «…далі наповнити її operation=build Уніки» → «…далі — кроки, які надрукує kit provision (Уніка створює чи наповнює базу)». Тригери лишаються.
  - **Вступ.** База агента — `infobases.origin` у `<ws>/v8project.local.yaml` (гітігнорований файл Уніки). Його пише **цей скіл** (Edit), kit кодом `v8project*.yaml` не пише ніколи. Kit **ніколи не цілиться в базу людини** (аудит лишається) — фразу зберегти дослівно; так само зберегти «лише на явне прохання» в межах і кроці виконання (регекс тесту «Межі» в `Skills.Tests.ps1` знає саме це формулювання).
  - **§1 власник:** зміст той самий. Заміни словника: «наповнена `operation=build`» → «наповнена `push` Уніки»; рецепт (i) — нижче. Абзац «Поставка вендора» → «Дерево основної конфігурації не придатне до завантаження (`truth: storage`: дерева немає — рецепт (i); поставка без `.cf` чи застаріла — рецепт (ii)) — `kit provision` сам створить порожню файлову базу й надрукує наступний крок kit: `kit sync -Source <ключ> -FromLatest -Apply` для (i), `kit verify -Source <ключ>` на головній гілці для (ii). Наповнює базу kit, а пам'ять раннера вирівнює крок, який надрукує `sync`/`verify` (на файловій базі — `pull` і `kit canon … -MarkerOnly -Apply`; на серверній — `kit canon … -Apply` і `push` з `"force":true`).»
  - **§2 тип бази** (AskUserQuestion, варіанти дослівно):
    - **порожня** — файлова: скіл пише `infobases: { origin: { connection: 'File=build/ib' } }`; базу створює Уніка (`infobase.create`), якщо дерево придатне, інакше kit.
    - **з `.dt`** — шлях до файлу; `-Template … -Remember`; Уніка розгортає (`infobase.restore`).
    - **серверна** — два підваріанти:
      - **нова** (`-ServerBase New`): скіл питає й пише `connection: 'Srvr=…;Ref=…;'`, `user`, `password`, `dbms: { kind, server, name, locale, user, password }` і адміністратора кластера `cluster: { user, password }` (раннер передає їх у `SUsr`/`SPwd` рядка `CREATEINFOBASE`; спека §2.2 на `8d94204`). Секцію `dbms` для файлової бази не писати — раннер її відхиляє. **До кроку** назвати людині застереження з прев'ю: `CrSQLDB=Y` мовчки бере наявну базу даних СУБД з тим самим іменем — ім'я бази даних підтверджує людина. База створюється з `SchJobDn=Y`;
      - **наявна** (`-ServerBase Existing`): базу дала людина; скіл пише `connection`, `user`, `password`; kit прибирає пам'ять раннера й друкує `push` з `"force":true`.
    - Пароль бази агента — у `infobases.origin.password` того самого файлу (kit і Уніка беруть його звідти; у вивід не потрапляє; подвійна лапка в паролі — зупинка kit). Лапки в рядку підключення — парою навколо значення або без лапок; непарна лапка — помилка.
  - **§3 виконання** — команди (прев'ю → `-Apply` лише на явне прохання), `-Force` для наявної файлової (kit прибирає теку бази й `<workPath>/infobases/origin/` — пам'ять раннера; без цього старі хеші розширень стали б «своєю» пам'яттю нової бази; мітку власника й замок поруч kit не чіпає). **Далі — кроки, надруковані `provision`, дослівно**; для серверної бази згода людини на `-Apply` покриває й надруковані кроки (`push` усіх наборів з `"force":true`).
  - **§4 штатні зупинки** — новий перелік:
    - «не налаштована» → записати `infobases.origin`;
    - «серверна … Вкажіть -ServerBase New … або -ServerBase Existing»;
    - «Для -ServerBase New … бракує: …» → спитати реквізити;
    - «-ServerBase стосується лише серверної»;
    - «База агента вже є … -Force»;
    - «збігається з дев-базою людини»;
    - «Шаблон бази (.dt) не знайдено»;
    - «-Remember потребує -Template»;
    - «непарні лапки»;
    - «подвійну лапку» (пароль).

    Пункт про лапки 1.4.0 («Лапки kit не приймає») — **прибрати** (спека §4.3 п. 4).
  - **§5 межі:** лише база агента; `-Force` — лише з `-Apply`; серверна з `.dt` — не робиться.

- [ ] **Step 8: `skills/onboarding/SKILL.md`.**
  - §3.2 — шаблон:

```yaml
format: DESIGNER
workPath: 'build'
providers:                     # інваріант контуру: запис і завантаження бази агента — один виконавець (дефект раннера #459)
  push: designer
  pull: designer
  download: designer
source-set:
  - name: base
    type: CONFIGURATION
    path: 'cf/src'
  - name: <ІмʼяРозширення>
    type: EXTENSION
    path: 'cfe/src'
```

  - Абзац «`execution_timeout: 600000` … вистачає не всім» — **прибрати повністю** (ключа в 0.13 немає).
  - Абзац про `name:` — без змін, крім «без `infobase:`» → «бази агента воркспейс обробок не має, але `providers` обов'язкові й тут (kit check вимагає їх у кожному закоміченому `v8project.yaml`)».
  - Абзац про дев-бази «без лапок — kit лапки відхиляє, форма одна на весь контур» → «лапки — лише парою навколо значення або без лапок; непарна лапка — зупинка».
  - Рядок про операції Уніки над розширенням (`cfe.borrow`/`cfe.diff`/`cfe.validate`) → «запозичення (`unica.apply`, операція `object.borrow`), різниця (`unica.diff`), перевірка (`unica.check`)».
  - Новий абзац після шаблону: «Базу агента в закоміченому файлі не оголошують: вона машинна й може нести пароль. Її пише `v8storagekit:provision` у `<ws>/v8project.local.yaml`:» і блок:

```yaml
infobases:
  origin:
    connection: 'File=build/ib'
```

  - §3.2.1 «База агента вже є? — Так»: `infobases.origin` з `connection`, `user` і `password` (пароль тепер підтримується); «Рядок підключення — без лапок» → «лапки — лише парою навколо значення або без лапок»; «`provision` для такої бази не застосовний» → «серверну наявну вирівнює `kit provision -ServerBase Existing` (прибирає пам'ять раннера й друкує `push` з `"force":true`); файлову наявну `provision` перестворив би — її лише вписують».
  - Розділ «Клієнтська основна конфігурація під сховищем» — таблиця рецептів:
    - (i) `onboarding` → `provision` (kit створить порожню базу) → `sync -Source <ключ> -FromLatest -Apply` (або `-FromVersion N`) зі злиттям у головну гілку або гілку онбордингу (`-MergeInto`) → **крок, надрукований `sync`** (файлова база: `pull` Уніки й `kit canon … -MarkerOnly -Apply`; серверна: `kit canon … -Apply` і `push` з `"force":true`);
    - (ii) **на головній гілці**: `provision` (kit створить порожню базу) → `verify -Source <ключ>` (очікувано `equal`) → **крок, надрукований `verify`** (той самий);
    - (iii) той самий рецепт, що (ii), лише на головній гілці.

    Абзаци «Чому саме так»:
    - «`canon` переписує все дерево» лишається як причина «лише на гілці без роботи агента» — тепер для `pull`, що так само переписує дерево набору з бази;
    - «Ніколи `canon` на порожній базі» → «`.cf` поставки кладе повне вивантаження з бази, наповненої `sync`/`verify`: на файловій — `pull` Уніки (він стирає каталог набору разом з ігнорованими, але платформа виводить `.cf` заново; позначку дописує `canon -MarkerOnly`), на серверній — `canon`. Окремого `canon` для поставки на файловій більше не треба (спека §10 П5). Правило «ніколи `canon` на порожній базі» лишається для канонізації роботи агента»;
    - «від `operation=build`» → «від `push` Уніки»;
    - «Розширення без дерева» — `canon -Source <основна> -Apply` → крок, надрукований `sync` основної конфігурації; `operation=build` → `push` Уніки.

  - Таблицю/абзаци про поставку прочитати повністю ще раз: жодного речення, що канонізація відновлює поставку (kit-dev, «змінилась причина чужого кроку»).

- [ ] **Step 9: `templates/CLAUDE.md`.**
  - Структура, рядки:
    - «Воркспейс Уніки: source-set-и, `providers` (`designer` — інваріант контуру) | `<Воркспейс>/v8project.yaml`»;
    - «База агента — `infobases.origin` (`connection`, `user`, `password`; для серверної нової — `dbms`); пише скіл `v8storagekit:provision` | `<Воркспейс>/v8project.local.yaml` (гітігнорований, файл Уніки)».
  - «Редагування…; `operation=build/make/test/syntax` — Unica» → «Редагування (`unica.apply`), перевірка (`unica.check`), завантаження в базу агента й збірка (`unica.run`) — Unica 0.13; маршрутизація — `v8storagekit:using-v8storagekit`».
  - «Збірка `.cfe`»: `unica.run {"op":"make","args":{"sourceSet":"<Ім'я>","extension":"<Ім'я>","output":"build/artifacts/<Ім'я>.cfe"},"dryRun":true}` — далі без змін.
  - «`operation=build` без `sourceSet`…» → «`push` Уніки без `sourceSet` вантажить усі оголошені набори воркспейсу. На серверній базі агента — лише з явного підтвердження людини; для правок розширення — `sourceSet` цього розширення. Після команд kit, що зрушили базу, — крок, який вони надрукували; `force:true` у ньому — виняток лише для бази агента (`v8storagekit:using-v8storagekit`)».
  - «Межі»: «`File=build/ib` у `v8project.yaml` — не секрет…» → «База агента й її пароль — лише в гітігнорованому `v8project.local.yaml`».
  - «Дозволи»: «читальні інструменти Unica» → «читальні інструменти Unica (перелік — `permissions.allow` у `.claude/settings.json`); `unica_run` і `unica_apply` — з запитом (`permissions.ask`)». Без переліку імен у постійному тексті.
  - `templates/v8storagekit.local.yaml.example`: речення «лапки не приймаються» → «лапки — лише парою навколо значення або без лапок».
  - `templates/gitignore`: коментар «Відновлення .cf на новій машині — kit canon з бази агента» → «Відновлення .cf на новій машині — крок, який надрукує kit verify (pull Уніки або kit canon) — skills/onboarding, рецепт (ii)».
  - `templates/gitattributes`: коментар про `unica.project.status` → «ОЧІКУВАНО: `unica.check {}` видасть `git.text_resource_marked_binary` [гіп, пункт пілоту 6]» — без старого імені.

  `templates/README.md` — рядок `settings.json`: «дозволи (читальні інструменти Уніки; `unica_run`/`unica_apply` — з запитом) + хук `SessionStart`».

- [ ] **Step 10: Прогін — зелений.** Повторити `grep` з шапки задачі — нуль збігів (крім позначених історичних).

- [ ] **Step 11: Перевірка `${CLAUDE_PLUGIN_ROOT}`** — `grep -rnP 'CLAUDE_PLUGIN_ROOT\}(?!/)' skills/` порожньо.

- [ ] **Step 12 (контролер, з дозволу людини): Коміт.** Тема: `§4.3–4.4: скіли й шаблони мовою Уніки 0.13; крок з виводу команди; provision; рецепти поставки без canon-дампу`.

### Task 13: Запобіжник словника — знята поверхня 0.12.3 і `operation=` (§8, §10 П14)

**Рівень ризику:** guard.

**Files:**
- Create: `tools/tests/Vocabulary.Tests.ps1`

**Interfaces:**
- Consumes: стан дерева після Tasks 6–12.

Перелік знятих імен поверхні 0.12.3 — усі інструменти MCP `unica` 0.12.3 (`mcp__plugin_unica_unica__unica_<x>_<y>`), ще й скіл `unica:v8-runner`. Кожне ім'я ловиться у трьох формах:
- `unica_<x>_<y>`;
- `unica.<x>.<y>`;
- голе `<x>.<y>` (саме так старі імена стояли в скілах: `cfe.validate`, `project.status`).

Шаблон будується з переліку, не з `\w+` (§10 П14).

- [ ] **Step 1: Тест** — `tools/tests/Vocabulary.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Запобіжник словника Уніки 0.12.3 (спека 2026-10-11 §8, §10 П14)' {
    BeforeAll {
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        # Повний перелік інструментів MCP unica 0.12.3 (mcp__plugin_unica_unica__unica_<x>_<y>) — знята
        # поверхня; Уніка 0.13 не має жодного з цих імен і аліасів до них (спека §2.1).
        $script:Removed = @(
            'build_dump', 'build_load', 'build_make', 'build_run', 'build_update',
            'cf_edit', 'cf_info', 'cf_init', 'cf_validate',
            'cfe_borrow', 'cfe_diff', 'cfe_init', 'cfe_patch_method', 'cfe_validate',
            'code_definition', 'code_diagnostics', 'code_graph', 'code_outline', 'code_patch', 'code_search',
            'dcs_compile', 'dcs_edit', 'dcs_info', 'dcs_validate',
            'documentation_get', 'documentation_search', 'epf_init', 'erf_init',
            'form_add', 'form_compile', 'form_edit', 'form_info', 'form_remove', 'form_validate',
            'help_add', 'interface_edit', 'interface_validate',
            'meta_add', 'meta_edit', 'meta_info', 'meta_remove',
            'mxl_compile', 'mxl_decompile', 'mxl_info', 'mxl_validate',
            'project_map', 'project_status',
            'role_compile', 'role_edit', 'role_info', 'role_validate',
            'runtime_execute', 'runtime_job_cancel', 'runtime_job_list', 'runtime_job_logs', 'runtime_job_start', 'runtime_job_status', 'runtime_job_wait',
            'source_children', 'source_locate', 'source_read', 'source_resolve', 'source_resources',
            'standards_explain', 'standards_search',
            'subsystem_compile', 'subsystem_edit', 'subsystem_info', 'subsystem_validate',
            'support_edit', 'template_add', 'template_remove', 'xdto_edit', 'xdto_info')

        function script:Get-RemovedPattern {
            # Повне MCP-ім'я (mcp__plugin_unica_unica__unica_x_y) — окремий необов'язковий префікс:
            # без нього lookbehind (?<![\w…]) забороняв би '_' перед 'unica_' і повні імена не
            # ловились би зовсім (аудит плану). '$' у lookbehind — щоб не ловити $meta.Add( у коді.
            $alts = foreach ($name in $script:Removed) {
                $seg = $name -split '_'
                '(?:mcp__plugin_unica_unica__)?(?:unica[._])?' + [regex]::Escape($seg[0]) + '[._]' + (($seg[1..($seg.Count - 1)] | ForEach-Object { [regex]::Escape($_) }) -join '[._-]')
            }
            '(?<![\w.:$-])(?:' + ($alts -join '|') + ')(?![\w])|operation=|unica:v8-runner'
        }
        function script:Get-ScannedLines { param([string]$Root)
            $md = @(Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Filter '*.md' -File -Recurse) +
                  @(Get-ChildItem -LiteralPath (Join-Path $Root 'templates') -File -Recurse)
            foreach ($f in $md) {
                $n = 0
                # upgrades.md: розділи переходів до 1.4.0 — історія словником своєї епохи (з приміткою
                # на початку файлу, Task 16); скануються лише розділ «1.4.0 → 1.5.0» і все після нього.
                $scan = $f.Name -ne 'upgrades.md'
                foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
                    $n++
                    if (-not $scan -and $line -match '^##\s+1\.4\.0\s+→\s+1\.5\.0') { $scan = $true }
                    if ($scan) { [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line } }
                }
            }
            $code = @(Get-ChildItem -LiteralPath (Join-Path $Root 'tools/commands'), (Join-Path $Root 'tools/lib') -Filter '*.psm1' -File) +
                    @(Get-Item -LiteralPath (Join-Path $Root 'tools/kit.ps1'), (Join-Path $Root 'tools/check-environment.ps1'))
            foreach ($f in $code) {
                $text = [regex]::Replace((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8), '(?s)<#.*?#>', { param($m) "`n" * ($m.Value.Split("`n").Count - 1) })
                $n = 0
                foreach ($line in ($text -split "`n")) {
                    $n++
                    if ($line.Trim().StartsWith('#')) { continue }
                    [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line }
                }
            }
        }
        $script:Pattern = Get-RemovedPattern
    }

    It 'на дереві kit — нуль збігів у skills/, templates/ і некоментованому коді tools/' {
        $hits = @(Get-ScannedLines -Root $script:KitRoot | Where-Object { $_.Text -match $script:Pattern } |
            ForEach-Object { "$([IO.Path]::GetRelativePath($script:KitRoot, $_.File)):$($_.Line): $($_.Text.Trim())" })
        $hits | Should -BeNullOrEmpty -Because 'kit 1.5.0 говорить лише мовою Уніки 0.13 (рішення 9 спеки)'
    }

    It 'шаблон ловить кожну форму: <Probe>' -ForEach @(
        @{ Probe = 'валідувати — `cfe.validate`' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_project_status' }
        @{ Probe = 'unica.code.search' }
        @{ Probe = 'operation=build' }
        @{ Probe = 'скіл unica:v8-runner' }
        @{ Probe = 'unica_cfe_patch_method' }
    ) {
        $Probe | Should -Match $script:Pattern
    }

    It 'шаблон НЕ чіпає нову поверхню 0.13: <Probe>' -ForEach @(
        @{ Probe = 'unica.view {}' }
        @{ Probe = 'unica.check {at: x}' }
        @{ Probe = 'unica.diff' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_search' }
        @{ Probe = 'unica.run {"op":"make"}' }
        @{ Probe = 'unica.apply object.borrow' }
        @{ Probe = 'unica.task.result' }
        @{ Probe = 'скіл unica:cfe-borrow' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_task_result' }
        @{ Probe = '$template.Add(1); $meta.Add(2)' }
    ) {
        $Probe | Should -Not -Match $script:Pattern
    }

    It 'шаблон ловить повне MCP-ім''я: <Probe>' -ForEach @(
        @{ Probe = '"mcp__plugin_unica_unica__unica_cfe_borrow",' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_build_dump' }
    ) {
        $Probe | Should -Match $script:Pattern
    }

    It 'негативний контроль: на дереві до адаптації (коміт плану 5743282) збіги є в усіх трьох зонах' {
        $old = Join-Path $TestDrive 'old-tree'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        $tar = Join-Path $TestDrive 'old.tar'
        git -C $script:KitRoot archive --format=tar -o $tar 5743282 -- skills templates tools
        tar -xf $tar -C $old
        $hits = @(Get-ScannedLines -Root $old | Where-Object { $_.Text -match $script:Pattern })
        foreach ($zone in 'skills', 'templates', 'tools') {
            @($hits | Where-Object { [IO.Path]::GetRelativePath($old, $_.File) -like "$zone*" }).Count |
                Should -BeGreaterThan 0 -Because "запобіжник мусить бачити старий словник у зоні $zone"
        }
    }
}
```

- [ ] **Step 2: Прогін.** Очікувано: зелений, якщо Tasks 6–12 прибрали все. Червоний — кожен рядок `hits` виправити в тексті, що належить відповідній задачі (повідомити контролера, якщо це файл чужої задачі).

- [ ] **Step 3: Мутація — на копії дерева.**
  - (а) дописати в копію `skills/sync/SKILL.md` рядок `Далі — operation=build Уніки.` — перший `It` червоний, у тексті падіння — `skills\sync\SKILL.md:<n>: Далі — operation=build Уніки.`;
  - (б) окремо дописати в некоментований рядок копії `tools/commands/build.psm1` `'cfe.validate'` — червоний із цим файлом;
  - (в) окремо додати в `permissions.allow` копії `templates/settings.json` рядок `"mcp__plugin_unica_unica__unica_cfe_borrow",` — червоний із цим файлом;
  - (г) окремо дописати `operation=build` у копію `skills/onboarding/references/upgrades.md` **після** заголовка «1.4.0 → 1.5.0» — червоний; той самий рядок у розділі «1.0.0 → 1.1.0» — зелений (історія не сканується).

  Усі тексти падіння — у звіт.

- [ ] **Step 4 (контролер, з дозволу людини): Коміт.** Тема: `§8: запобіжник словника — знята поверхня Уніки 0.12.3 і operation=`.

### Task 14: `templates/settings.json` — дозволи Уніки 0.13 (§4.4 п. 3, §10 П1)

**Рівень ризику:** механічна, але дозволи — безпека → рев'ю на сильній моделі.

**Files:**
- Modify: `templates/settings.json`
- Test: `tools/tests/Templates.Tests.ps1`

Імена — за правилом «крапки → `_`» [гіп]; пункт 7 пілоту їх підтверджує (§10 П1), розбіжність — задача фази D.

- [ ] **Step 1: Тест** — у `Describe 'templates/settings.json …'`:

```powershell
    It 'дозволи Уніки 0.13: рівно читальні інструменти в allow; run/apply/task_cancel — явно в ask (спека §4.4 п. 3)' {
        # task_get/task_result/task_cancel існують лише в профілі Compatibility (клієнт без нативних
        # MCP Tasks); у профілі Native їх немає, і зайвий дозвіл нешкідливий.
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $unica = @($s.permissions.allow | Where-Object { $_ -like 'mcp__plugin_unica_unica__*' } | Sort-Object)
        $want = @('view', 'search', 'resolve', 'docs', 'check', 'diff', 'task_get', 'task_result') |
            ForEach-Object { "mcp__plugin_unica_unica__unica_$_" } | Sort-Object
        ($unica -join "`n") | Should -Be ($want -join "`n")
        foreach ($name in 'unica_run', 'unica_apply', 'unica_task_cancel') {
            @($s.permissions.allow) | Should -Not -Contain "mcp__plugin_unica_unica__$name"
            @($s.permissions.ask)   | Should -Contain "mcp__plugin_unica_unica__$name" -Because 'відсутність в allow не гарантує запиту в режимах acceptEdits/bypass'
        }
    }
```

- [ ] **Step 2: Прогін — червоний** (34 старі імена).

- [ ] **Step 3:** у `permissions.allow` замінити всі 34 рядки `mcp__plugin_unica_unica__…` на вісім:

```json
      "mcp__plugin_unica_unica__unica_view",
      "mcp__plugin_unica_unica__unica_search",
      "mcp__plugin_unica_unica__unica_resolve",
      "mcp__plugin_unica_unica__unica_docs",
      "mcp__plugin_unica_unica__unica_check",
      "mcp__plugin_unica_unica__unica_diff",
      "mcp__plugin_unica_unica__unica_task_get",
      "mcp__plugin_unica_unica__unica_task_result"
```

  У `permissions.ask` (поруч із `git push` тощо) дописати `"mcp__plugin_unica_unica__unica_run"`, `"mcp__plugin_unica_unica__unica_apply"`, `"mcp__plugin_unica_unica__unica_task_cancel"` — «з запитом» (§3 рішення 6) явно, а не відсутністю в `allow`. JSON має лишитись валідним (кома після останнього елемента масиву — ні). Імена за правилом «крапки → `_`» підтверджено на 0.12.3 (`unica.build.dump` ↔ `unica_build_dump`); пункт 7 пілоту звіряє з живим `tools/list` 0.13.

- [ ] **Step 4: Прогін — зелений.**

- [ ] **Step 5 (контролер, з дозволу людини): Коміт.** Тема: `§4.4 п.3: settings.json споживача — дозволи Уніки 0.13`.

### Task 15: Документація (§4.5)

**Рівень ризику:** механічна → рев'ю на дешевій моделі, але з читанням `docs/unica-contract.md` цілком.

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/storage-and-git.md`, `docs/text-policy.md`, `docs/unica-contract.md`, `docs/follow-ups.md` (лише місця зі старим словником, без зміни суті записів), `docs/migration/legacy-gitsync-repo.md` (абзац з `execution_timeout: 3600000` і посиланням на знятий абзац onboarding §3.2)
- Delete: `docs/v8-runner-migration.md` (знімається з обліку — висновки переносяться в контракт)

Правило постійної документації — без номерів рядків, кількостей і результатів прогонів; замість числа — спосіб дістати. Перелік місць — три пошуки по `CLAUDE.md README.md docs/ -r` (з підтеками, `docs/superpowers/` — поза обсягом, це історія):
1. шаблон запобіжника Task 13 (`Get-RemovedPattern`) як інструмент пошуку — він знаходить і `unica.project.status`/`unica.cfe.validate` у `docs/text-policy.md`, які простий `operation=` пропускає;
2. `grep -rn "v8-runner-migration\|infobase\.connection\|execution_timeout\|builder\|34 MCP\|паролів бази агента" CLAUDE.md README.md docs --exclude-dir=superpowers`;
3. `grep -rni "лапк" docs --exclude-dir=superpowers` — твердження «kit лапки не приймає» (є в `docs/storage-and-git.md`) переписати за Task 2.

- [ ] **Step 1: `docs/unica-contract.md` — за процедурою E (розділ E того самого файлу).**
  - «Зафіксований стан» (і шапка документа, що посилається на `v8-runner-migration.md`) — Unica 0.13.0, v8-runner 0.14.0 (форк `IngvarConsulting/v8-runner-rust`).
  - A/B/D — **кожен** пункт контракту отримує статус на 0.13, без пропусків:
    - закриті за кодом — B1, B2, D4, B8: позначити «закрито в 0.13» з джерелом [код/док] зі спеки §2.1;
    - змінені — A2–A5, A10, A12 (лапки: раннер знімає парні `"`/`'`, непарна — рядок не серверний; kit приймає парою — §4.3 п. 4), B10: переписати за спекою §2;
    - A6 — тепер читання `infobases.origin` у `v8project.local.yaml`;
    - без змін — A7–A9, A11, B5-B6, B7, B9 (`git.text_resource_marked_binary` під `-text` — `error`, #641), а також нові `git.index_eol_not_lf` (`error`; файли під `-text` у неї не потрапляють), `git.mixed_eol`;
    - настало — D5;
    - не класифіковані спекою — A1 (`make` у `build/artifacts` воркспейсу; пункт пілоту 4), B3, B4, D1–D3: «статус на 0.13 не перевірено [гіп]».
    - розділи «Трекінг в апстрімі» і «Постійні детектори» — переглянути на 0.13 (знятих інструментів у детекторах лишатись не мусить).
  - Новий пункт «Пам'ять покоління v8-runner 0.14» — зміст спеки §2.2 і §4.1 на `8d94204`: токен; `<workPath>/infobases/<база>/` (зокрема `new-owner.json`, `copied-from.json`; мітка власника й замок — поза текою); хто пише (`push`; `pull` — покоління лише незмінне; `infobase create` — лише хеші); `no_memory`/`non_fast_forward`; **незмінене дерево — `infobase_state_unverified` без звірки**; `pull --force` стирає каталог разом з ігнорованими; межі #459/#184/#429; чому `providers: designer` і чому серверна — завжди `push force`; крок вирівнювання kit і сітка в `using-v8storagekit`.
  - Новий пункт «`force` на базі агента проти правила Уніки» — текст §10.1 П17.
  - Розділ F («Що готує v0.13») — **зняти**.
  - Висновки `docs/v8-runner-migration.md` §2 («ядро kit не дублюється раннером», підтверджено на 0.14/0.15: сховища в раннері немає, #220) — перенести одним підрозділом.
  - Тези, не підтверджені живим прогоном, позначати [гіп] до фази C.
- [ ] **Step 2: Зняти `docs/v8-runner-migration.md`.** `git rm docs/v8-runner-migration.md`; усі посилання на нього (`grep -rn "v8-runner-migration" --exclude-dir=.git .`, крім спеки й цього плану, які описують історію) — прибрати. Рядок таблиці «Де що шукати» в `CLAUDE.md` прибрати. Перевірка — `grep` дає лише спеку й план.
- [ ] **Step 3: `CLAUDE.md`, розділ «Зв'язок з Unica».**
  - Уніка 0.13 і раннер 0.14.
  - «`kit.ps1 dump` існує рівно заради операцій Уніки (`cfe.borrow`, `cfe.diff`, `cfe.validate`)» → «заради операцій Уніки над розширенням (запозичення через `unica.apply`, різниця, перевірка), яким потрібен склад конфігурації-власника».
  - «`templates/settings.json` дозволяє 34 MCP-інструменти» → без числа: «дозволяє читальні MCP-інструменти Уніки (`permissions.allow`), а `unica_run`/`unica_apply` — лише з запитом (`permissions.ask`); перелік — `grep -o 'mcp__plugin_unica[a-z_]*' templates/settings.json`».
  - «`.cf`/`.cfe` kit сам не будує — це `operation=make`» → «`unica.run` з `"op":"make"`».
  - «звужений грep на `mcp__|Invoke-Unica|operation=(build|make)`» → `mcp__|Invoke-Unica|unica\.run` з поясненням очікуваного результату: збіги є — це **рядки друку** кроків (`UnicaStep.psm1`, повідомлення команд), а не виклики; твердження «у `tools/` немає виклику Unica» лишається правдивим.
  - Новий абзац: «Kit не викликає CLI раннера сам; база агента — територія раннера, доступ лише через Уніку. Команди kit, що зрушують базу агента, друкують крок вирівнювання (`docs/storage-and-git.md`)».
  - «Структура»: `tools/` — лічильник команд, якщо він є в тексті, не міняти (команд не додається).
- [ ] **Step 4: `docs/storage-and-git.md`** — розділи про базу агента:
  - `infobases.origin` у `v8project.local.yaml`, пароль, серверна база;
  - вирівнювання пам'яті раннера: таблиця «команда → крок» зі спеки §4.1 — **як принцип і критерій** (файлова: `pull` за доведеною рівністю, інакше `push force`; серверна: завжди `push force`; захищає надрукований крок, сітка — `infobase_state_unverified` у `using-v8storagekit`), без прикладів виводу;
  - хто створює базу (§3 рішення 4);
  - поставка: `.cf` дає повне вивантаження (`canon`, а на файловій базі й `pull`), позначку пише лише `canon` (повний чи `-MarkerOnly`);
  - лапки в рядку підключення — парою приймаються (за Task 2), не «kit лапки не приймає»;
  - три теки під `build/` (`ib`, `infobases/`, `artifacts`) і що з них чиє: `infobases/origin` — пам'ять раннера, kit прибирає її лише в `provision`.

  Кожне `operation=build` → `push` Уніки.
- [ ] **Step 5: `docs/text-policy.md`, `README.md`, `docs/follow-ups.md`, `docs/migration/legacy-gitsync-repo.md`** — місця з пошуків шапки новим словником; у `legacy-gitsync-repo.md` абзац про `execution_timeout` прибрати (ключа в 0.13 немає, посилання на onboarding §3.2 веде в знятий абзац). У `follow-ups.md` суть записів не міняти — лише назви операцій. Запис про #34/#26/#25/#13, якщо такий є в `follow-ups.md`, — позначити «закрито в 1.5.0» з посиланням на спеку.
- [ ] **Step 6: Прогін — зелений** (тести читають `CLAUDE.md`/`README.md`?); повторний `grep` з шапки — лише історичні цитати з поясненням.
- [ ] **Step 7 (контролер, з дозволу людини): Коміт** — разом із `git rm`: `git add <перелік>`; `git commit --only -F <файл> -- <перелік, включно з docs/v8-runner-migration.md>`. Тема: `§4.5: документація на Уніку 0.13; v8-runner-migration.md знято з обліку`.

### Task 16: Перехід 1.4.0 → 1.5.0 і версія плагіна (§5)

**Рівень ризику:** механічна (`upgrades.md` читають споживачі — рев'ю читанням як процедури).

**Files:**
- Modify: `skills/onboarding/references/upgrades.md`
- Modify: `.claude-plugin/plugin.json` (`"version": "1.5.0"`)
- Test: наявний `Skills.Tests` «upgrades.md описує перехід на ПОТОЧНУ версію» — стане червоним від бампу й зеленим від розділу

- [ ] **Step 1: Бамп** `.claude-plugin/plugin.json` → `1.5.0`. Прогін — червоніє тест «upgrades.md … ПОТОЧНУ версію» (очікувано: `*1.5.0*` не знайдено). Записати текст падіння.

- [ ] **Step 2: `upgrades.md`** — рядок таблиці «| 1.4.0 | 1.5.0 | Див. розділ «1.4.0 → 1.5.0» нижче — Unica 0.13, база агента в `infobases.origin`, `providers`, крок вирівнювання |» і розділ:

````markdown
## 1.4.0 → 1.5.0

**Що змінилось.** Kit говорить лише мовою Уніки 0.13 (v8-runner 0.14) і читає лише її конфіг —
сумісного режиму з Унікою 0.12 немає:
- `v8project.yaml` без `builder`, `execution_timeout`, `partialLoadThreshold`, `basePath` і з
  обов'язковими `providers` (`push`, `pull`, `download` — `designer`);
- база агента — лише `infobases.origin` у гітігнорованому `v8project.local.yaml` (з `user` і
  `password`; для нової серверної — `dbms` і `cluster`). Стара `infobase:` у будь-якому з двох
  файлів — помилка `kit check` і зупинка кожної команди. Це політика kit (одна форма), а не відмова
  Уніки: Уніка 0.13 стару форму ще приймає;
- `sync`, `verify` і `provision` друкують точний наступний крок Уніки (вирівнювання пам'яті
  раннера); поставка вендора відновлюється через `verify` → надрукований крок (на файловій базі
  `pull` і `kit canon -MarkerOnly`, на серверній — `kit canon` і `push`);
- `kit provision` прибирає пам'ять раннера знищеної бази, створює порожню базу сам лише тоді, коли
  дерево основної конфігурації не придатне до завантаження, і знає серверну базу агента
  (`-ServerBase New|Existing`);
- рядок підключення в лапках приймається, якщо лапки парні навколо значення [гіп до пункту пілоту 5];
- `kit check` вимагає Уніку 0.13.x.

**Кроки.** Кроки 1, 7 і 8 робить або явно погоджує людина.

1. **Машинний крок людини, один раз на машину.** Оновлення Уніки зупиняє роботу агентів у
   репозиторіях, що ще на kit 1.4.0, і перемикає **всі** репозиторії машини: решту переводьте цим
   самим розділом до наступної роботи в них. Порядок (без `marketplace update` перед `update` кеш
   лишається старим):
   ```
   claude plugin marketplace update unica
   claude plugin update unica@unica
   claude plugin marketplace update smp-v8storagekit
   claude plugin update v8storagekit@smp-v8storagekit
   ```
   Тоді **нова сесія**; перший старт MCP Уніки качає рантайм. Ознака, що оновлення справді
   відбулось, — версії в `claude plugin list` і нові скіли, а не текст відповіді `update`: він може
   сказати «вже встановлено» й нічого не зробити. Тоді лікує лише `claude plugin uninstall …` →
   `claude plugin install …` і нова сесія.
2. `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/check-environment.ps1"` — рядок `Плагін unica`
   з версією 0.13.x без зауважень.
3. `kit check -RepoRoot .` — перелік застарілого: кожна знахідка конфігу називає файл і рецепт.
4. Для кожного воркспейсу:
   - у `<ws>/v8project.yaml` видалити рядки `builder`, `execution_timeout` (і `partialLoadThreshold`,
     `basePath`, якщо є), прибрати блок `infobase:` (запам'ятати його `connection` і `user`) і додати —
     **у кожен воркспейс, зокрема воркспейс зовнішніх обробок**:
     ```yaml
     providers:
       push: designer
       pull: designer
       download: designer
     ```
   - **лише для воркспейсів з наборами `CONFIGURATION`/`EXTENSION`** — у `<ws>/v8project.local.yaml`
     (створити, якщо немає; файл гітігнорований) база агента зі значенням `connection` з прибраного
     блоку `infobase:` (типово `File=build/ib`):
     ```yaml
     infobases:
       origin:
         connection: 'File=build/ib'
     ```
     для серверної — `connection: 'Srvr=…;Ref=…;'`, `user`, `password`. Старий блок `infobase:` з
     цього файлу — прибрати.
5. `.claude/settings.json` і розділи `CLAUDE.md` про Уніку — з шаблонів плагіна
   (`templates/settings.json`, `templates/CLAUDE.md`): дозволи на інструменти Уніки 0.13.
6. `kit check -RepoRoot .` — помилок немає.
7. **Перший `push` бази агента після переходу — з `force`**, лише для наборів `CONFIGURATION`/
   `EXTENSION` воркспейсів, де база агента є (немає — спершу `v8storagekit:provision`; воркспейс
   обробок бази не має):
   `unica.run {"op":"push","args":{"sourceSet":"<набір>","force":true},"dryRun":true}`, потім з
   `"dryRun":false`. Пам'ять раннера 0.5.1 не переноситься; перше завантаження й так повне.
   Набір `CONFIGURATION` з поставкою вендора без `.cf` (`kit check` попереджає «поставка вендора
   відсутня/застаріла») — **не** `push`: спершу рецепт поставки з `v8storagekit:onboarding`
   (рецепт (ii)), бо повне завантаження без `.cf` впаде.
8. Записати `kitVersion: 1.5.0` у `v8storagekit.yaml` і закомітити разом із `v8project.yaml`
   воркспейсів, `.claude/settings.json` і `CLAUDE.md` — явним переліком шляхів, з погодження людини.

**Чого очікувати у виводі.** До кроку 4 — помилки `kit check` на ключах `builder`/`infobase:`/
відсутніх `providers` і зупинка будь-якої іншої команди kit з тими самими текстами. Після кроку 4 на
свіжій машині без `v8project.local.yaml` — попередження «База агента … не налаштована»: його знімає
`v8storagekit:provision`.
````

  Розділ «1.1.0 → 1.2.0» («лапки заборонені»): дописати одне речення в кінець — «З 1.5.0 парні лапки знову приймаються — див. «1.4.0 → 1.5.0»». Сам розділ історії не переписувати.

  Примітка на початку `upgrades.md` (одразу після вступного абзацу, до таблиці): «Розділи переходів до 1.4.0 включно написано словником своєї епохи (Уніка 0.12: `operation=build` тощо). Хто йде ланцюжком переходів на машині з Унікою 0.13, читає `operation=build` як `push` Уніки, а `operation=make` — як `unica.run` з `"op":"make"` (маршрутизація — `v8storagekit:using-v8storagekit`).» Запобіжник Task 13 сканує `upgrades.md` лише від розділу «1.4.0 → 1.5.0», тож історичні розділи не переписуються.

- [ ] **Step 3: Прогін — зелений.**

- [ ] **Step 4 (контролер, з дозволу людини): Коміт.** Тема: `1.5.0: перехід 1.4.0 → 1.5.0 в upgrades.md, бамп plugin.json`.

### Task 17: Рев'ю гілки як цілого, `Integration`, звірка з архітектором (кінець фази A)

**Рівень ризику:** рев'ю контуру (kit-dev, «Роблю рев'ю»).

- [ ] **Step 1: Рев'ю гілки** `git diff main..HEAD` одним рев'юером на сильній моделі (бриф — `.claude/skills/kit-dev/references/subagent-brief.md` + цей план + спека `8d94204`). Обов'язкові питання:
  - (а) чи є стан, у якому всі тести зелені, а kit друкує `pull`, хоча дерево не дорівнює вивантаженому (стик Tasks 7/9/10);
  - (б) чи кожна команда, що зрушує базу агента, друкує рівно один крок на набір (таблиця §4.1);
  - (в) чи немає запасного читання старої форми конфігу (рішення 9) — `grep -rn "'infobase'" tools/` лише в `Get-V8ProjectConfigProblems`;
  - (г) чи пароль ніде не друкується (`grep -rn "Password" tools/commands` — лише передача);
  - (ґ) обидва боки кожного критерію — з незалежних джерел (`HEAD` проти дзеркала / проти `-Ref`, не одне джерело двічі);
  - (д) чи є шлях, де для серверної бази агента друкується `pull` (не мусить бути ніколи — §4.1 на `8d94204`), і чи `pull` для `EXTENSION` скрізь несе `extension`;
  - (е) чи рядки `ЗУПИНКА:` скрізь друкуються останніми, а підсумок не каже «Готово» для набору зі зупинкою;
  - (є) чи жоден текст для людини чи агента не приписує Уніці відмову, яка є політикою kit (§10.1 П19), і чи «спершу `dryRun:true`» ніде не названо вимогою Уніки.

  Знахідки — окремими задачами-фіксами з тим самим циклом.
- [ ] **Step 2 (з підтвердженням людини): `Integration`** — `pwsh -NoProfile -File tools/tests/Run-Tests.ps1` без `-ExcludeTag`. Запускає `1cv8.exe`, створює файлову ІБ. Сирий підсумок — у звіт; підрядки ліцензії — зупинка.
- [ ] **Step 3: Трасування.** Таблицю «Трасування» з кінця плану доповнити хешами комітів задач і надіслати архітекторові `unica-013-adaptation-spec` на звірку. Без його підтвердження фаза B не стартує.

---

## Фаза B — підготовка пілоту

### Task 18: kit 1.5.0 у локальному маркетплейсі — підготовка (без перемикання)

**Рівень ризику:** незворотний крок поза репозиторієм — **лише контролер, з окремого дозволу людини**; у бриф субагента не потрапляє.

Перемикання маркетплейсу й оновлення плагінів — машинна дія, що зупиняє агентів на 1.4.0. Тому тут лише **готуються й перевіряються читанням** команди, а виконує їх власник у фазі C (Task 20) разом з оновленням Уніки (спека §6). **У цій задачі жодної команди `claude plugin install|update|uninstall|marketplace add|update` на профілі машини не виконувати.**

- [ ] **Step 1: Маршрут уперед (kit 1.5.0 з робочої копії).** З'ясувати, як зареєструвати локальне джерело плагіна `v8storagekit` під тим самим ідентифікатором `v8storagekit@smp-v8storagekit`. `.claude-plugin/marketplace.json` репозиторію зараз указує на `url` з `ref: v1.4.0`, тож `marketplace add <робоча копія>` поставив би 1.4.0 з GitHub.
  - Спосіб, що працював у B1: пам'ять `v8storagekit-plugin-dev-loop` — локальний маркетплейс, `install` копіює знімок робочої копії в кеш.
  - Поточну форму джерела-шляху звірити з документацією Claude Code (агент `claude-code-guide`, `model: sonnet`), не з пам'яті.
  - Якщо потрібна практична перевірка встановлення, — лише в **ізольованому профілі** (`CLAUDE_CONFIG_DIR` на теку скретчпада), ніколи на профілі машини; результат: kit 1.5.0 лягає в окремий каталог кешу версії `1.5.0`.
  - `marketplace.json` у гілці **не змінювати** — `ref` міняється лише на релізі (фаза D).
- [ ] **Step 2: Маршрут відкоту (Unica 0.12.3 і kit 1.4.0)** — встановлюється й перевіряється **читанням до перемикання** (спека §6, «Відкіт до пілоту»):
  - **Уніка.** Пастка з README Уніки: теги `v0.9.1`…`v0.13.0-rc.5` несуть каталог **попередньої** версії й ставлять не свою версію, тож «`#v0.12.3`» не означає 0.12.3 автоматично. За README і `marketplace.json` маркетплейсу `IngvarConsulting/unica-marketplace` знайти ref, що справді ставить 0.12.3 (звірити поле `version` у каталозі цього ref через `gh api`), і записати точні команди відкоту.
  - **kit.** Повернути маркетплейс `smp-v8storagekit` на GitHub (`ref: v1.4.0`) і переставити плагін.
  - **Правило kit-dev «Оновлюю кеш плагіна».** `install`/`update` можуть відповісти «вже встановлено» й нічого не зробити; лікує лише `uninstall` → `install` і нова сесія. Ознака успіху — версії в `claude plugin list` і наявність (чи відсутність) характерних скілів версії, а не текст відповіді команди. Для Уніки 0.12.3 — скіл `unica:v8-runner` є; для 0.13 — його немає.
- [ ] **Step 3:** обидва маршрути — точним переліком команд з ознаками успіху — у розділ «Власник: перемикання і відкіт» брифу тестера (Task 19).

### Task 19: Самодостатній бриф агента-тестера і журнал пілоту

**Рівень ризику:** документ для агента без нашого контексту — рев'ю читанням «чи виконає його той, хто бачить лише цей файл».

**Files:**
- Create: `docs/superpowers/pilots/2026-10-12-unica-013-tester-brief.md`
- Create: `docs/superpowers/pilots/2026-10-12-unica-013-pilot.md`

- [ ] **Step 1: Бриф** — самодостатній: агент-тестер працює в репо-споживачі, не бачить ні kit, ні спеки, ні цієї розмови. Розділи:
  1. **Мета** — перевірити kit 1.5.0 з Унікою 0.13 на живому споживачі; нічого не виправляти, лише фіксувати. Чотири речення про контур: сховище → git, база агента, крок вирівнювання.
  2. **Як знайти kit і що означають слова** (тестер не бачить ні репозиторію kit, ні спеки):
     - корінь плагіна — `claude plugin list` → рядок `v8storagekit@smp-v8storagekit`, шлях встановлення; команди kit — `pwsh -NoProfile -File "<корінь>/tools/kit.ps1" <команда> -RepoRoot .`;
     - глосарій: **набір** (`sourceSet`) — елемент `source-set:` у `v8project.yaml`, його `name`; **ключ** — те саме ім'я в маніфесті `v8storagekit.yaml`; **база агента** — `infobases.origin` у `v8project.local.yaml`; **пам'ять раннера** — `<workPath>/infobases/origin/` (`generation.json`, `hashes/`); **крок вирівнювання** — рядки «Далі — вирівняти пам'ять раннера …» у виводі `kit sync`/`verify`; **поставка вендора** — `Ext/ParentConfigurations.bin` у git і гітігнорований `.cf` з позначкою `.kit-bin-sha1`.
  3. **Межі** (дослівно):
     - сховища — лише читання;
     - база людини — лише читання; `push`/`push force` і `-ServerBase Existing` — **лише на базі, яку власник явно назвав одноразовою базою агента**;
     - `-Apply` — у межах кроків брифу, інакше не робити;
     - `git push`, PR, злиття в головну гілку споживача — ніколи;
     - підрядки `лиценз`/`ліценз`/`license`/`HASP` — зупинка й доповідь;
     - будь-яка розбіжність із «Очікувано» — зупинка пункту, сирий вивід у журнал, перехід до наступного незалежного пункту;
     - **без обходів і без пояснень собі**;
     - **секрети**: перед записом виводу в журнал вичитати його на пароль бази агента, пароль сховища, `dbms`/`cluster`-реквізити й рядки підключення з ними; збіг — замінити на `<приховано>` і записати в журнал рядок «витік у виводі, див. п. N» (це сам по собі дефект для архітектора). Журнал власник комітить лише після власної вичитки.
  4. **Власник: перемикання і відкіт** — обидва маршрути з Task 18 з ознаками успіху; нова сесія; `check-environment.ps1`.
  5. **Пункт 0 — перехід** за `upgrades.md` «1.4.0 → 1.5.0» на пілотній гілці споживача, крок за кроком; кожен крок — вивід у журнал. Це водночас прохід процедури (спека §8).
  6. **Пункти 1–13** спеки §6 (на `8d94204`), кожен з командою, «Очікувано» за спекою і «Записати»:
     1. `push` з `providers: designer` → `generation.json` у `<workPath>/infobases/origin/`;
     2. `kit sync -Source <ключ> -Apply` (файлова база) → надрукований крок → `pull` (для розширення — з `extension`) → `git status --porcelain -- <набір>` порожній; стан `Ext/ParentConfigurations/`;
     3. `kit provision -Apply -Force` (файлова, придатне дерево) → `infobase.create` → `push` без `sourceSet` (усі набори); з `.dt` → `infobase.restore` (чи пише `generation.json`); `-ServerBase Existing` на наявній серверній одноразовій базі → `push force`;
     4. `make` → `.cfe` у `<ws>/build/artifacts`; `kit build -Apply` забирає;
     5. `Srvr="…";Ref="…"` у лапках → `push` проходить;
     6. `unica.check {}` під `-text` → перелік `git.*`;
     7. перелік інструментів Уніки, які бачить сесія (повні імена) — проти `templates/settings.json`;
     8. серверна нова: `infobases.origin.dbms` і `infobases.origin.cluster {user, password}` → `kit provision -ServerBase New` → `infobase.create` → `push force`; після `sync` на серверній — надруковано `push force`, а не `pull` (лише якщо власник дав кластер; інакше «не відтворено»);
     9. `user`/`password` у базі агента: `push` Уніки, `kit sync`, `kit canon` — вхід без запиту пароля, пароль у виводі відсутній;
     10. `unica.apply` нового й зміненого `.xml`/`.bsl` у файлі з CRLF → профіль кінців рядків;
     11. `pull force` на `CONFIGURATION` з поставкою → `.cf` у `Ext/ParentConfigurations/`; `kit canon -MarkerOnly -Apply` → позначка; `infobase.create` на придатному дереві з поставкою `current`;
     12. **рецепт (ii) наскрізно** — свіжий клон, поставка без `.cf`: `kit provision` (kit створює порожню базу) → `kit verify -Source <ключ>` → надрукований `pull` → `kit canon … -MarkerOnly -Apply` → звичайний `push` → `kit check` без знахідок поставки;
     13. **приймальний критерій #25**: гілка задачі з роботою, не перенесеною в сховище; власник кладе в сховище частину → `kit sync -Apply` (надруковано `push` з `"force":true`) → цей крок → `kit canon` → прев'ю `kit adopt` називає саме неперенесену роботу в «зникне». Окремо (сітка): звичайний `push` замість надрукованого кроку на незміненому дереві гілки відповідає `infobase_state_unverified` з назвою набору (а не мовчить), і скіл за цим попередженням виконує `push` з `"force":true`.
  7. **Формат журналу** — для кожного пункту: команда, сирий вивід (без обрізання, але з приховуванням секретів за правилом «Межі»), «Висновок: підтверджено / спростовано / не відтворено» з умовою виміру.
  8. **Куди писати** — абсолютний шлях журналу в робочій копії kit (`R:\github\SMP_V8StorageKit\docs\superpowers\pilots\2026-10-12-unica-013-pilot.md`), лише цей файл; нічого в kit не комітити.
- [ ] **Step 2: Журнал** — шаблон із заголовками «Середовище», «П.0 перехід», «П.1» … «П.13», «Підсумок для архітектора». У шапці — спека `8d94204`, коміт kit, з якого встановлено 1.5.0.
- [ ] **Step 3 (контролер, з дозволу людини): Коміт** обох файлів. Тема: `пілот Unica 0.13: бриф агента-тестера й журнал`.

---

## Фаза C — пілот

### Task 20: Пілот (власник)

Не задача для агента цієї сесії. Кроки власника:
- обрати репо-споживача (основна конфігурація під `truth: storage` з поставкою й розширення — щоб покрити пункти 2, 11);
- створити пілотну гілку;
- **в той самий момент** оновити плагіни за розділом «Власник: перемикання» брифу;
- запустити в репо-споживачі агента-тестера з брифом.

Сесія kit на цей час дерево kit не чіпає (крім журналу, який пише тестер). Після пілоту контролер:
- читає журнал;
- комітить його (з дозволу людини);
- надсилає архітекторові `unica-013-adaptation-spec` посилання на коміт і перелік «спростовано».

---

## Фаза D — виправлення й реліз

### Task 21: Виправлення за пілотом і реліз

- [ ] **Step 1:** на кожне «спростовано» — рішення архітектора й правка спеки окремим комітом. Потім задача-фікс у цьому плані з тим самим циклом (тест, що червоніє на зафіксованому в журналі вході; реалізація; мутація; коміт). Очікувані місця, де фікс лягає без зміни дизайну:
  - п. 2 брудне → крок завжди `push` для набору (`Get-KitAlignStep`);
  - п. 7 інші імена → `templates/settings.json` і запобіжник;
  - п. 8 інша форма `cluster` → скіл `provision`;
  - п. 11 `.cf` після `pull` не з'явився → для файлової бази та сама гілка, що для серверної: `kit canon`, потім `push force` (спека §10 П5 на `8d94204`);
  - п. 5 → `docs/unica-contract.md` A12.
- [ ] **Step 1а: Зняти [гіп] за вимірами.** Для кожного підтвердженого пункту — `[гіп]` → `[вимір]` (з датою й умовою) у `docs/unica-contract.md`; для спростованого — виправлення текстів, що на ньому стоять (Tasks 2, 12, 15, 16: лапки в `upgrades.md` і скілах, `push` без `sourceSet`, `.cf` після `pull`, імена інструментів). Перелік місць — `grep -rn "\[гіп" skills templates docs --exclude-dir=superpowers`.
- [ ] **Step 2:** повторний прохід пунктів журналу, які зачепив фікс.
- [ ] **Step 3 — реліз, кожен крок лише за явним проханням людини** (`git push`, `gh pr create`, `gh release` — `ask`):
  - PR `feature/unica-0.13` → `main`;
  - злиття;
  - тег `v1.5.0`, GitHub Release;
  - окремий коміт `ref: v1.5.0` у `.claude-plugin/marketplace.json` і повернення маркетплейсу машини на GitHub.

  Закриття ішуй #25, #26, #34, #13 (і #12, якщо пункт 10 пілоту підтвердив профіль кінців рядків) — з посиланням на коміти, лише з дозволу людини.

---

## Трасування «пункт спеки → задача» (спека `8d94204`, §9)

| Пункт спеки | Задача |
|---|---|
| §6, §10 П1 — фази A/B/C/D | A: Tasks 1–17; B: 18–19; C: 20; D: 21 |
| §6 пункти 12–13 (рецепт (ii) наскрізно; приймальний критерій #25), «Відкіт до пілоту» | Task 19 (пункти брифу 12–13), Task 18 Step 2 (маршрут відкоту Уніки й kit) |
| §2.2, §4.1 на `8d94204` — серверна база завжди `push force`; `pull` лише файлова; `extension` у `pull` розширення; `dryRun` — конвенція kit; сітка `infobase_state_unverified` | Task 7 (`-BaseKind`, `extension`), Tasks 9–10 (`Kind` з `Get-KitSourceInfobase`), Task 6 (коментар `Format-KitUnicaRun`), Task 12 (`using-v8storagekit`, `reconcile`, `sync`, `verify`) |
| §10.1 П17 — `force` на базі агента проти правила Уніки | Task 12 Step 3 (дослівно), Task 15 (контракт) |
| §10.1 П18 — шаблон `providers` лише три ключі; ключа `launch` немає | Task 3 (тест «інші ключі вільні» — `make: agent`), Task 12 Step 8 |
| §10.1 П19 — тексти `kit check` не приписують відмову Уніці | Task 3 (`Get-V8ProjectConfigProblems`), Task 16 |
| §10.1 П20 — `push full:true` звіряє покоління, `no_memory` → `push force` | Task 12 Step 3 (таблиця маршрутизації) |
| §10.1 П21 — `-InstalledPluginsPath` замість змінної оточення | Task 5 |
| §10 П5/П15, §3 рішення 4 — хто створює базу; `canon` «лише позначка»; рецепти (i)/(ii) без `canon` | Task 11 (`Get-KitConfigurationFitness`, `Get-KitProvisionSteps`), Task 8 (`-MarkerOnly`, `Get-KitSupplyRecipe`), Task 12 (onboarding, provision) |
| §10 П7 — `provision -Force` прибирає `<workPath>/infobases/origin/`, мітку власника й замок не чіпає | Task 11 |
| §10 П16 — вид воркспейсу за типами наборів; `provision` без `origin` зупиняється | Task 4 (`Test-KitWorkspaceNeedsAgentBase`), Task 11 |
| §4.1 — вирівнювання: `sync`, `verify`, `adopt`/`reconcile` — критерій і друк кроку | Task 7 (критерій, крок), Task 9 (`sync`), Task 10 (`verify`), Task 12 (`reconcile`, `finish`, `using`) |
| §4.2 — `provision`: кроки за типом бази | Task 11 |
| §4.3 п. 1–2 — шаблон `onboarding`, скіл `provision` | Task 12 |
| §4.3 п. 2а — пароль (#26) | Task 3 (читання), Task 4 (передача, маска) |
| §4.3 п. 3 — читання лише `infobases.origin`; стара форма — помилка | Task 3 |
| §4.3 п. 4 — лапки | Task 2; текст `upgrades.md` — Task 16; A12 — Task 15 |
| §4.3 п. 5, §4.4 п. 4 — перевірки `kit check`, версія Уніки | Task 3 (`Get-V8ProjectConfigProblems`, префлайт), Task 5 |
| §4.4 п. 1–2, 5 — скіли, `templates/CLAUDE.md`, тексти `tools/` | Task 6 (тексти `tools/`), Tasks 8–11 (тексти команд), Task 12 |
| §4.4 п. 3 — `settings.json` | Task 14 |
| §4.5 — документація, `unica-contract.md`, зняття `v8-runner-migration.md` | Task 15 |
| §4.6 #34 | Task 1 |
| §4.6 #13, #25 | Task 12 (`using-v8storagekit` — `push full:true`; `reconcile` крок 2), Task 9 (крок `push force` після `sync`) |
| §4.6 #12, #19, #9 | #12 — пункт 10 пілоту (Task 19/20), без коду; #19 — поза обсягом; #9 — Task 2 |
| §5 — `upgrades.md` 1.4.0 → 1.5.0, бамп 1.5.0 | Task 16 |
| §8 — тести kit і запобіжник словника; прохід `upgrades.md` на живому споживачі | Tasks 1–14 (тести в кожній), Task 13 (запобіжник), Task 19 п. 0 + Task 20 (прохід) |

**Свідомі відхилення плану від буквального тексту спеки й рішення архітектора за ними:**
1. Критерій `sync` (§10 П3, пункт (б) «злиття впало → `push force`»): окремої гілки коду немає — це наслідок критерію «дерево рівне й чисте». **Прийнято** архітектором: інваріант — рівність дерев і чисте дерево; (б) був його наслідком. Доповнено за аудитом: остання версія з `-DumpPlatform` критерій знімає (Task 9).
2. Op `blocked` у `sync`/`verify` — рядок `ЗУПИНКА:` і елемент `AlignSteps` з `Op = 'blocked'`, код виходу не змінюється. **Прийнято з умовами**, обидві в плані: (а) `ЗУПИНКА:` друкується останньою, підсумок не каже «Готово» (Task 7 `Write-KitAlignStops`, Task 9 Step 3–4, Task 10 Step 3); (б) скіли `sync`, `verify`, `reconcile` наказують перевірити й не йти далі (Task 12 Steps 4, 6; тест у Step 1).
3. `provision` для файлової придатної бази друкує `push` **без** `sourceSet` — **[док]**, не [гіп]: `CAPABILITIES.md` раннера, розділ «infobase create» («первый push его не грузит, а расширения досылает целиком»); пункт 3 пілоту лише підтверджує.
4. Реєстр плагінів для тестів — **змінну оточення відхилено**; замість неї параметр `kit check|session-check -InstalledPluginsPath` (спека §10.1 П21, Task 5).

**Що аудити змінили в плані** (знахідки чотирьох аудитів на коміті плану `5743282`, звірені; спростованих немає):
- критичні: кома-обгортка `Get-V8ProjectConfigProblems` (`@(f).Count = 1` без знахідок — префлайт пропускав би кожен воркспейс); синтаксична помилка `Write-Host (…) -f` у `provision` (модуль не завантажився б; додано крок розбору парсером); тест `sync` «pull», червоний за будь-якої реалізації (бракувало `-WithGitignore`); запобіжник словника сліпий до повних MCP-імен, сам падав би на тексті Task 12 і на історичних розділах `upgrades.md`;
- з першоджерел Уніки 0.13 / раннера 0.14: `pull` розширення вимагає `extension`; серверна база — завжди `push force` (#184); `dryRun` першим — конвенція kit; незмінене дерево дає `infobase_state_unverified` без звірки (захищає лише надрукований крок + сітка в скілі); ключі `cluster{user,password}`; `providers` без ключа `launch`; `execution_timeout_seconds` верхнього рівня;
- решта: `Remove-KitDirectory` знімає ReadOnly і з тек, змішані місця «файл/тека»; тести, що не могли впасти (лічильник спроб, половина критерію `verify`, проводка пароля через `sync`/`Get-StorageVersions`/`DumpCfg`); перелік наявних тестів, що ламаються (`Supply`, `Check.Supply`, `Check.AgentBase`, `Sync.Guards`, `StoragePlatform`, `Provision`, `ModuleImportOrder`); `-MarkerOnly` не освячує `.cf`, старіший за `.bin`; `-Workspace` у надрукованих командах kit; маршрут відкоту Уніки й ізоляція перевірок маркетплейсу; секрети в журналі пілоту; `upgrades.md` — порядок маркетплейсів, кроки людини, `push force` лише для наборів з базою.

