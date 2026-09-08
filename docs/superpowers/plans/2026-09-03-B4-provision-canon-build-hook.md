# B4. `provision`, `canon`, `build`, хук старту сесії — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** база агента (`provision` — порожня або з `.dt`), канонізація дерева агента через
неї (`canon`), збірка `.epf` і збір артефактів (`build`), хук старту сесії, прив'язаний до
репозиторію-споживача (шим `.claude/hooks/session-start.ps1` + вступний скіл
`using-v8storagekit`); вилучення `load-ext.ps1`, `build.ps1` і `Read-V8LocalConnection`.

**Architecture:** усі три команди цілять **лише в базу агента**, яку визначають так само, як
Unica (`v8project.local.yaml` → `v8project.yaml`, спека §2.5), і зупиняються, якщо це
підключення збігається з дев-базою людини з накладки kit. `provision` — платформа
(`CREATEINFOBASE … /UseTemplate`), `canon` — `/DumpConfigToFiles` з бази агента назад у дерево,
`build` — `/LoadExternalDataProcessorOrReportFromFiles` для `.epf` плюс збір `.cf/.cfe`, які
Unica `make` поклала в `build/artifacts/`. Хук **не оголошується плагіном** (`hooks/hooks.json`
немає): він у `templates/settings.json` споживача, а шим сам знаходить плагін у реєстрі.

**Tech Stack:** PowerShell 7.5, Pester 5, платформа 1С 8.3.27.x (`Integration`: provision/canon),
Claude Code hooks (`SessionStart`, `hookSpecificOutput.additionalContext`).

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` — §2.5 (база агента),
§3.6 (`canon`), §4 (база агента), §5 (`provision`, `canon`, `build`), §6 (`using-v8storagekit`),
§7 (хук), §12 (тести «хук старту сесії», «build без платформи»), §13 (межі), §14 (B4).

## Global Constraints

- **PowerShell 7+**, `Set-StrictMode`, `$LASTEXITCODE`; мова — українська, ASCII-якорі.
- **Тести без платформи:** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  `Integration` (`provision` порожня і з `.dt`, `canon` round-trip, `build .epf`) — **не запускається
  до фінальної Task 5**, і там лише з підтвердженням користувача: один прогін на блок.
- **Агент ніколи не пише в базу людини** (принцип 3). `provision`/`canon` беруть підключення
  **тільки** з `Resolve-V8AgentInfobase`; якщо воно збігається з будь-яким `infobases:` накладки —
  зупинка до будь-якої дії. `load-ext.ps1` вилучається саме тому.
- **`-Apply` лише на явне прохання.** `provision -Force` стирає базу агента — це дозволено (§4),
  але лише з `-Apply -Force`.
- **Плагін не оголошує хуків** — файлу `hooks/hooks.json` у kit **не створювати**. Хук лише в
  `templates/settings.json`.
- **`${CLAUDE_PLUGIN_ROOT}` — тільки всередині шляху** у `SKILL.md`; у шимі його **немає
  взагалі** — шим сам знаходить плагін через реєстр (спека §7).
- **Скіли адресуються з префіксом** `v8storagekit:`.
- **Серверна база агента з `.dt`** — спайк, не робота (§13): `provision` на `Srvr=` зупиняється з
  поясненням.
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
- **`Mock -ModuleName` не перетинає межу модуля (знахідка B3):** щойно виклик платформи переїжджає з
  `commands/X.psm1` у `lib/Y.psm1`, моки `-ModuleName X` мовчки перестають перехоплювати — тести лишаються
  зеленими й тихо піднімають справжній `1cv8.exe`. Приймальна ознака тесту без платформи — не час виконання, а
  явне `Should -Invoke … -ModuleName <модуль, де ТЕПЕР живе виклик>`; при кожному перенесенні коду між модулями
  моки переадресовуються.
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
| Q2 | база агента | `infobase.connection` з `v8project.local.yaml`, інакше з `v8project.yaml`; kit іде за вказівником Unica; у накладці kit цього підключення немає | §2.5 |
| Q6 | `build` і `.cfe` | скіл кличе `operation=make` з `output=<корінь>/build/artifacts/<Ім'я>.cfe`; `kit build` збирає `.epf` і друкує теку; якщо Unica відмовить у шляху поза воркспейсом — `output=<воркспейс>/build/artifacts/…`, і `build` забирає звідти (реалізовано одразу: `build` збирає з обох місць) | §5 |
| Q7 | версії | локальний маркетплейс; без пушу | §14 |

---

- **Пастки, доведені в B1–B3 (кожна була Critical у рев'ю, і кожна прийшла з тексту плану):**
  - `WaitForExit()` **завжди з таймаутом** — без нього дефект дає зависання назавжди, а не помилку.
  - **Кодування задавати явно** там, де читається вивід git з іменами файлів: амбієнтне
    `[Console]::OutputEncoding` вірне лише всередині `kit.ps1`, а модулі викликають і тести, і
    хук — кирилиця псується мовчки.
  - `[Parameter(Mandatory)]` на **колекції** — разом з `[AllowEmptyCollection()]`: порожній масив
    тут типовий вхід (розширення без binary-файлів), а не крайній випадок.
  - `Measure-Object` і `.Count` на порожньому чи одноелементному вводі — через `@()`.
  - **Порівняння часу — з допуском:** файлова система і платформа дають різну гранулярність
    `mtime`, без допуску сигнал стає вічно-хибним.
  - Зовнішній виклик, що **змінює стан** (прив'язка до сховища, злиття, запуск платформи), — у
    `try`/`finally` зі звільненням у `finally`; інакше перший виняток лишає стан підвішеним.
  - **Тест мусить падати, якщо вирізати production-код.** Тест, що дублює формулу всередині себе
    або перевіряє поведінку зовнішнього інструмента, проходить і з видаленою командою — це вже
    ловили (`docs/follow-ups.md` §4).

## Як виконувати цей план (методика, ухвалена після B3)

B3 коштував ~3,3 млн токенів у субагентах і ~35 запусків агентів на ~2000 змінених рядків.
Розбір показав, що дорога не дрібність задач, а **рівномірна строгість**: однакове подвійне
рев'ю діставалось і задачі на 44 рядки, і задачі, що чіпає спільний диспетчер. Звідси правила.

- **Рев'ю за рівнем ризику, а не за фактом «задача завершена».** Кожна задача починається
  рядком `**Ризик:**` з одним із трьох рівнів:
  - `механічна` — вилучення файлів, тексти скілів, документація, перейменування. **Одне рев'ю
    на дешевій моделі**, і воно перевіряє не логіку, а guard-умови: `grep`-перевірки кроку
    «Прогін», префікс `v8storagekit:` у перехресних посиланнях, `${CLAUDE_PLUGIN_ROOT}` лише
    всередині шляху, наявність рядків меж у тексті скіла.
  - `спільний код` — чіпає диспетчер, модуль `lib/*.psm1`, який викликають інші команди, або
    формат, що читають сусідні задачі. **Одне рев'ю на сильній моделі.**
  - `властивість безпеки` — задача тримає межу зі спеки (агент не пише в базу людини; сховище
    лише читання; `-Apply` тільки на явне прохання; переписування чужого репозиторію).
    **Два рев'ю**, друге — вузьке, лише про цю властивість.
- **Код у плані — ескіз, а не транскрипція.** Усі чотири Critical, знайдені в B3, прийшли з
  тексту плану, а не з помилок виконавців: виконавці брали код дослівно, як і вимагалось.
  Детальність не знизила частку дефектів — вона перенесла їх із виконання в рев'ю, де довести
  дефект дорожче (прочитати код, відтворити сценарій, показати наслідок). Тому **рев'ю ставиться
  до коду з плану так само, як до свіжого коду виконавця**. Судження «це з плану, отже вже
  перевірене» хибне: такого статусу код у плані не має.
- **Текст задачі заморожений на час її виконання.** Автор планів, поки задача в роботі, вносить
  у файл **лише розблокувальні** правки — прямі відповіді на `NEEDS_CONTEXT` від виконавця. Усе
  інше (уточнення, покращення, наслідки свіжих рішень спеки) чекає кінця задачі й іде однією
  редакцією. У B3 коди виходу `session-check` переглядались **п'ять разів усередині роботи**, і
  один запуск виконавця згорів на 131 тис. токенів через суперечність, внесену проміжною
  редакцією. Це стосується і правок, що приходять зі спеки: нове рішення архітектора лягає в
  хвіст блоку, а не в живу задачу.
- **`Integration` — один прогін на блок**, у фінальній задачі, за підтвердженням користувача.
  Самі `Integration`-тести пишуться у своїх задачах і позначаються тегом, але **не запускаються**
  доти: живий прогін платформи дорогий і дає ту саму інформацію, зібраний в одну точку.
- **Дрібна механічна задача окремо не існує** — вона в складі задачі-споживача або фінальної
  задачі блоку. Окремо вона коштує повний цикл (виконавець + рев'ю + звіт) за 40 рядків змін.

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `tools/lib/V8Project.psm1` | `Resolve-V8AgentInfobase` повертає ще `User`; `Resolve-KitAgentInfobasePath` (File → абсолютний шлях, Srvr → як є) | 1 |
| `tools/lib/V8.psm1` | `New-V8FileInfobase -TemplatePath` (`/UseTemplate`); вилучення `Read-V8LocalConnection` | 1, 5 |
| `tools/lib/Manifest.psm1` | `Save-KitOverlayAgentBase` — записати `workspaces.<ws>.agentBase.template` у накладку | 1 |
| `tools/lib/AgentBase.psm1` | **новий.** `Resolve-KitAgentBase -Context -Workspace` — підключення, тип, шлях, аудит проти накладки; `Test-KitSameInfobase` — порівняння розібраних підключень, fail-closed | 1 |
| `tools/commands/provision.psm1` | **новий.** `Invoke-KitProvision` | 1 |
| `tools/commands/canon.psm1` | **новий.** `Invoke-KitCanon` | 2 |
| `tools/commands/build.psm1` | **новий.** `Invoke-KitBuild`; `tools/build.ps1` вилучається | 3 |
| `templates/settings.json` | блок `hooks.SessionStart` | 4 |
| `templates/hooks/session-start.ps1` | **новий.** Шим: реєстр плагінів → `kit.ps1 session-check` → JSON | 4 |
| `skills/using-v8storagekit/SKILL.md` | **новий.** Вступний скіл (§6) | 4 |
| `tools/commands/check.psm1` | перевірка `hook-shim`: шим і `settings.json` споживача | 4 |
| `tools/load-ext.ps1`, `tools/build.ps1` | **вилучаються** | 5 |
| `tools/tests/Build.Tests.ps1` | переписується цілком у Task 3 (**не** вилучається в Task 5 — знахідка P1 префлайту B4) | 3 |
| `tools/lib/module-order.txt` | + `AgentBase` після `V8Project` | 1 |
| тести: `AgentBase.Tests.ps1`, `Provision.Tests.ps1`, `Canon.Tests.ps1`, `Build.Tests.ps1` (новий), `SessionStartHook.Tests.ps1`, `Check.Tests.ps1`, `V8Project.Tests.ps1`, `Manifest.Tests.ps1`, `Templates.Tests.ps1` | | 1–5 |
| `templates/README.md`, `templates/CLAUDE.md`, `skills/storage-pipeline/SKILL.md`, `CLAUDE.md`, `docs/follow-ups.md` §7 | перехідні позначки; §7 закрито | 5 |

---

## Спільні контракти блоку

```
V8Project.psm1 (зміна)
  Resolve-V8AgentInfobase -Project : → {Connection; User; Origin}|$null      (User — infobase.user, якщо є; інакше '')
  Resolve-KitAgentInfobasePath -Project -Connection : → {Kind:'file'|'server'; Path (абс., лише file); IbSwitch}

AgentBase.psm1
  Test-KitSameInfobase -Left -Right : → bool. Порівнює РОЗІБРАНІ підключення, не рядки:
      file — GetFullPath обох, зрізаний кінцевий роздільник, OrdinalIgnoreCase;
      server — пара (Srvr, Ref) покомпонентно, незалежно від порядку ключів;
      різні Kind — $false. Не канонізується — КИДАЄ, а не повертає $false (див. Task 1 Step 6).
  Resolve-KitAgentBase -Context -Workspace <ws object> : → {Workspace; Connection; User; Origin; Kind; Path; IbSwitch; Exists:bool}|$null
      зупинка, якщо Connection збігається з будь-яким Context.Overlay.Infobases[*].Connection (база людини)

V8.psm1 (зміна)
  New-V8FileInfobase -Path -MustBeUnder [-TemplatePath <.dt>] [-V8Path] : CREATEINFOBASE File="…"; [/UseTemplate "…"]

Manifest.psm1 (додається)
  ConvertTo-KitYaml -Data : → [string] (Yaml.psm1; єдина точка запису YAML, симетрична Read-KitYaml)
  Save-KitOverlayAgentBase -OverlayPath -WorkspacePath -Template : пише/оновлює workspaces.<ws>.agentBase.template

commands
  Invoke-KitProvision -Context [-Workspace] [-Source] [-Apply] [-Force] [-Template <.dt>] [-Remember]
      : → {ExitCode; Provisioned: @({Workspace; Path; Template})}
  Invoke-KitCanon -Context [-Workspace] [-Source] [-Apply]
      : → {ExitCode; Canonized: @({Key; Files; Changed:int})}
  Invoke-KitBuild -Context [-Workspace] [-Source] [-Apply]
      : → {ExitCode; Artifacts: @(шляхи у build/artifacts)}

templates/hooks/session-start.ps1 (шим; самодостатній, без модулів kit)
  вхід: cwd = корінь репозиторію-споживача; реєстр $env:V8KIT_PLUGINS_REGISTRY або ~/.claude/plugins/installed_plugins.json
  вихід: {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}} або нічого, якщо плагіна немає;
  шим ЗАВЖДИ виходить з 0 (спека §7). Код kit session-check формує лише текст: 0 і 3 — вивід як є; 1 — текст
  зупинки з позначкою «перевірка не відпрацювала — стан сховищ невідомий» (мовчання читалось би як «нових версій немає»)
```

---

### Task 1: база агента — `AgentBase.psm1`, `provision` (§4)

**Ризик:** `властивість безпеки` — тримає принцип 3 «агент ніколи не пише в базу людини»: `Resolve-V8AgentInfobase` — єдине
джерело підключення, збіг із будь-яким `infobases:` накладки зупиняє до будь-якої дії. Плюс
`provision -Force` стирає базу. Друге рев'ю — вузьке, лише про ці дві межі.

**Files:**
- Modify: `tools/lib/V8Project.psm1` — `Resolve-V8AgentInfobase` + `User`; `Resolve-KitAgentInfobasePath`
- Modify: `tools/lib/Yaml.psm1` — `ConvertTo-KitYaml` (Step 5а, знахідка P5); `tools/tests/Yaml.Tests.ps1`
- Modify: `tools/lib/V8.psm1` — `New-V8FileInfobase -TemplatePath`
- Modify: `tools/lib/Manifest.psm1` — `Save-KitOverlayAgentBase`
- Create: `tools/lib/AgentBase.psm1`
- Create: `tools/commands/provision.psm1`
- Modify: `tools/lib/module-order.txt` — `AgentBase` після `V8Project`
- Tests: `tools/tests/V8Project.Tests.ps1`, `Manifest.Tests.ps1`, `AgentBase.Tests.ps1` (новий), `Provision.Tests.ps1` (новий), `V8.Tests.ps1` (`Integration` для `.dt`)

**Interfaces:** див. «Спільні контракти».

- [ ] **Step 1: Тести, що падають**

`V8Project.Tests.ps1`, новий Describe:

```powershell
Describe 'V8Project.psm1 — шлях і ключ бази агента' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        $script:Ws = Join-Path $TestDrive 'Ws_SMB'
        New-Item -ItemType Directory -Path $script:Ws -Force | Out-Null
        Copy-Item (Resolve-Path "$PSScriptRoot/fixtures/v8project-extension.yaml").Path (Join-Path $script:Ws 'v8project.yaml')
        $script:Project = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
    }
    AfterEach { Remove-Item (Join-Path $script:Ws 'v8project.local.yaml') -ErrorAction SilentlyContinue }

    It 'File=build/ib розв''язується від теки воркспейсу; ключ /F абсолютний' {
        $r = Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'File=build/ib'
        $r.Kind | Should -Be 'file'
        $r.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Ws 'build/ib')))
        $r.IbSwitch | Should -Be ('/F "{0}"' -f $r.Path)
    }
    It 'абсолютний File= лишається як є' {
        (Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'File="D:\ib\agent";').Path | Should -Be 'D:\ib\agent'
    }
    It 'Srvr= — server, ключ /S' {
        $r = Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'Srvr="VSDEV";Ref="agent";'
        $r.Kind | Should -Be 'server'
        $r.IbSwitch | Should -Be '/S "VSDEV\agent"'
    }
    It 'Resolve-V8AgentInfobase повертає user із накладки Уніки, коли він є' {
        Set-Content (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent"";'", "  user: 'Агент'")
        $r = Resolve-V8AgentInfobase -Project $script:Project
        $r.User | Should -Be 'Агент'
    }
}
```

`Manifest.Tests.ps1`, у Describe накладки:

```powershell
    It 'Save-KitOverlayAgentBase створює накладку або дописує agentBase.template, не ламаючи інше' {
        $p = Join-Path $TestDrive 'save-overlay.yaml'
        Save-KitOverlayAgentBase -OverlayPath $p -WorkspacePath 'Alpha_SMB' -Template 'D:\dumps\demo.dt'
        (Read-KitLocalOverlay -Path $p).Workspaces['Alpha_SMB'].AgentBaseTemplate | Should -Be 'D:\dumps\demo.dt'

        Set-Content -LiteralPath $p -Encoding UTF8 -Value @('infobases:', '  dev:', "    connection: 'File=x'", 'workspaces:', '  Alpha_SMB:', '    agentBase:', "      template: 'old.dt'")
        Save-KitOverlayAgentBase -OverlayPath $p -WorkspacePath 'Alpha_SMB' -Template 'new.dt'
        $o = Read-KitLocalOverlay -Path $p
        $o.Workspaces['Alpha_SMB'].AgentBaseTemplate | Should -Be 'new.dt'
        $o.Infobases['dev'].Connection | Should -Be 'File=x'
    }
```

`tools/tests/AgentBase.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'AgentBase.psm1 — база агента з вказівника Уніки, аудит проти бази людини' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/AgentBase.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'файлова база з v8project.yaml: шлях під воркспейсом, ще не існує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'file'
        $ab.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib')))
        $ab.Exists | Should -BeFalse
        $ab.Origin | Should -BeLike '*v8project.yaml'
    }

    It 'v8project.local.yaml перекриває на серверну; Origin — накладка Уніки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'server')
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'server'
        $ab.IbSwitch | Should -Be '/S "VSDEV\agent_alpha"'
        $ab.Origin | Should -BeLike '*v8project.local.yaml'
    }

    It 'підключення бази агента збігається з дев-базою людини з накладки kit — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*людини*devUNF*'   # порядок як у повідомленні: «…з дев-базою людини 'devUNF' із накладки kit» (P3)
    }

    It 'воркспейс без infobase: — $null' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws)
        Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] | Should -BeNullOrEmpty
    }
}
```

`tools/tests/Provision.Tests.ps1` (без платформи — зупинки й прев'ю):

```powershell
#Requires -Version 7
Describe 'kit provision — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Provision { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }

    It 'прев''ю: порожня файлова база під воркспейсом, без шаблону' {
        $r = Invoke-Provision -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*build*ib*порожн*-Apply*'
    }

    It 'шаблон із накладки показується в прев''ю; -Template перекриває його' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl') -OverlayText "workspaces:`n  Alpha_SMB:`n    agentBase:`n      template: 'D:\dumps\demo.dt'" -WithHooks
        (Invoke-Provision -Repo $repo).Output | Should -BeLike '*D:\dumps\demo.dt*'
        (Invoke-Provision -Repo $repo -More @('-Template', 'E:\other.dt')).Output | Should -BeLike '*E:\other.dt*'
    }

    It '-Apply з неіснуючим .dt — зупинка до платформи; бази не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-dt') -WithHooks
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Template', (Join-Path $TestDrive 'missing.dt'))
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*missing.dt*'
        Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
    }

    It 'база вже є, без -Force — зупинка з підказкою; з -Force без -Apply — лише прев''ю' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'exists') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'x'
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*-Force*'
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
    }

    It 'серверна база агента — зупинка з поясненням (спайк §13), навіть із -Apply' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv') -WithHooks
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent"";'")
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Srvr*кластер*'
    }

    It '-Remember без -Template — зупинка: нема що запам''ятовувати' {
        $r = Invoke-Provision -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'remember') -WithHooks) -More @('-Remember')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*-Template*'
    }
}

Describe 'kit provision — платформа: порожня база й база з .dt' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # .dt робимо самі: порожня ІБ → /DumpIB. Так тест не залежить від чужих файлів.
        $tmp = Join-Path $TestDrive 'dt-src'
        $ib = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $tmp 'ib') -MustBeUnder $tmp)
        $script:Dt = Join-Path $TestDrive 'empty.dt'
        (Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpIB "{0}"' -f $script:Dt)).ExitCode | Should -Be 0
    }
    It 'порожня база агента створюється під <ws>/build/ib' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty') -WithHooks
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
    }
    It 'база з .dt і -Remember: створена, шаблон записано в накладку; повторно — лише з -Force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'from-dt') -WithHooks
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply -Template $script:Dt -Remember 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
        (Get-Content (Join-Path $repo 'v8storagekit.local.yaml') -Raw) | Should -BeLike '*agentBase*empty.dt*'
        & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply -Force 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
```

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: `V8Project.psm1`** — розширити `Resolve-V8AgentInfobase` і додати `Resolve-KitAgentInfobasePath`

У `Read-V8ProjectLocalInfobase` повертати об'єкт замість рядка? Ні — лишити контракт B1
(рядок), а `user` читати окремою функцією-сестрою:

```powershell
function Read-V8ProjectLocalInfobaseUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $data = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $data -or -not $data.Contains('infobase') -or $data['infobase'] -isnot [System.Collections.IDictionary]) { return '' }
    if ($data['infobase'].Contains('user')) { return [string]$data['infobase']['user'] }
    ''
}
```

`Resolve-V8AgentInfobase` — обидві гілки повертають `User`: з накладки — `Read-V8ProjectLocalInfobaseUser`;
з проєкту — `''` (у `Read-V8Project` `infobase.user` не читається; закомічений `v8project.yaml`
користувача не несе — це секрет).

```powershell
function Resolve-KitAgentInfobasePath {
    <#
    .SYNOPSIS
        Підключення бази агента → тип, абсолютний шлях (для файлової), ключ платформи.
        Відносний File= розв'язується від теки конфіга — так само, як у Unica (A7).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$Connection)
    $value = $Connection.Trim()
    if ($value -match '(?i)\bsrvr\s*=') {
        return [pscustomobject]@{ Kind = 'server'; Path = $null; IbSwitch = (ConvertTo-V8IbSwitch -Connection $value) }
    }
    $raw = if ($value -match '(?i)\bfile\s*=\s*"?(?<p>[^";]+)"?') { $Matches['p'] } else { $value }
    $path = if ([System.IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $Project.Directory $raw }
    $path = [System.IO.Path]::GetFullPath($path)
    [pscustomobject]@{ Kind = 'file'; Path = $path; IbSwitch = ('/F "{0}"' -f $path) }
}
```

`V8Project.psm1` додає `Import-Module "$PSScriptRoot/V8.psm1"` (без `-Force`) заради
`ConvertTo-V8IbSwitch`. Експортувати обидві нові функції.

- [ ] **Step 4: `V8.psm1` — `New-V8FileInfobase -TemplatePath`**

У `param` додати `[string]$TemplatePath`; перед `$argLine`:

```powershell
    $template = ''
    if ($TemplatePath) {
        if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $TemplatePath" }
        $template = ' /UseTemplate "{0}"' -f (Resolve-Path -LiteralPath $TemplatePath).Path
    }
    $argLine = 'CREATEINFOBASE File="{0}";{1} /DisableStartupDialogs /Out "{2}"' -f $Path, $template, $log
```

(`Assert-SafeWorkPath` і перевірка шаблону — до `Get-V8Path`, як і решта запобіжників там.)

- [ ] **Step 5: `Manifest.psm1` — `Save-KitOverlayAgentBase`**

```powershell
function Save-KitOverlayAgentBase {
    <#
    .SYNOPSIS
        Записує workspaces.<ws>.agentBase.template у v8storagekit.local.yaml (створює файл, якщо його немає).
        Коментарі накладки при перезаписі губляться — це файл машини, не спільний.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OverlayPath, [Parameter(Mandatory)][string]$WorkspacePath, [Parameter(Mandatory)][string]$Template)
    Import-KitYamlModule
    $doc = $null
    if (Test-Path -LiteralPath $OverlayPath -PathType Leaf) { $doc = Read-KitYaml -Path $OverlayPath -AllowEmpty }
    if ($null -eq $doc) { $doc = [ordered]@{} }
    if (-not $doc.Contains('workspaces') -or $doc['workspaces'] -isnot [System.Collections.IDictionary]) { $doc['workspaces'] = [ordered]@{} }
    if (-not $doc['workspaces'].Contains($WorkspacePath) -or $doc['workspaces'][$WorkspacePath] -isnot [System.Collections.IDictionary]) { $doc['workspaces'][$WorkspacePath] = [ordered]@{} }
    $ws = $doc['workspaces'][$WorkspacePath]
    if (-not $ws.Contains('agentBase') -or $ws['agentBase'] -isnot [System.Collections.IDictionary]) { $ws['agentBase'] = [ordered]@{} }
    $ws['agentBase']['template'] = $Template
    $yaml = ConvertTo-KitYaml -Data $doc   # НЕ голий ConvertTo-Yaml — див. Step 5а
    Set-Content -LiteralPath $OverlayPath -Value $yaml -Encoding UTF8 -NoNewline
    Read-KitLocalOverlay -Path $OverlayPath | Out-Null   # перечитати — файл мусить проходити власну схему
}
```

Експортувати.

- [ ] **Step 5а: `ConvertTo-KitYaml` у `Yaml.psm1`** (знахідка P5 префлайту B4)

`Import-KitYamlModule` робить `Import-Module powershell-yaml` **без `-Global`**, тож команди
`powershell-yaml` осідають у session state `Yaml.psm1`. `Read-KitYaml` у тому ж модулі їх бачить,
а `Manifest.psm1` — ні: голий `ConvertTo-Yaml` там резолвиться лише через автозавантаження з
`PSModulePath`. Це працює на машині, де модуль встановлено штатно, і мовчки ламається там, де ні.
Гірше — воно обходить fail-closed-контракт `Import-KitYamlModule`: замість команди встановлення
користувач без модуля отримає «`ConvertTo-Yaml` не розпізнано як ім'я командлета».

```powershell
function ConvertTo-KitYaml {
    <#
    .SYNOPSIS
        Серіалізує мапу в YAML. Єдина точка запису, симетрична Read-KitYaml: гарантує, що
        powershell-yaml завантажений через Import-KitYamlModule (з його дружньою зупинкою), а не
        через автозавантаження з PSModulePath, якого на чужій машині може не бути.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Data)
    Import-KitYamlModule
    ConvertTo-Yaml -Data $Data
}
```

Додати до `Export-ModuleMember` у `Yaml.psm1`. `Import-Module -Global` як альтернативу **не
брати**: глобальний імпорт із бібліотечного модуля забруднює простір імен викликача.

Тест (`Yaml.Tests.ps1`): виклик `ConvertTo-KitYaml` у **чистому** дочірньому `pwsh`, де
`powershell-yaml` ще не імпортовано, повертає рядок і не кидає. Так перевіряється саме те, що
ламалось: доступність команди поза session state `Yaml.psm1`.

- [ ] **Step 6: `tools/lib/AgentBase.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/V8Project.psm1"

function Resolve-KitAgentBase {
    <#
    .SYNOPSIS
        База агента воркспейсу — так, як її бачить Unica (§2.5) — плюс аудит: це не база людини.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Workspace)

    $ib = Resolve-V8AgentInfobase -Project $Workspace.Project
    if ($null -eq $ib) { return $null }

    if ($Context.Overlay) {
        # Порівняння РОЗІБРАНИХ підключень (Test-KitSameInfobase), а не нормалізованих рядків.
        # Косметична нормалізація (пробіли, лапки, регістр, TrimEnd ';') пропускала два випадки,
        # відтворені прогоном у рев'ю безпеки B4: File="D:\Bases\X\" проти File=D:\Bases\X (та сама
        # тека) і Srvr="A";Ref="B"; проти Ref="B";Srvr="A"; (та сама база). Перший веде просто до
        # знищення дев-бази людини: аудит мовчить, Exists=$true, агент робить санкціоноване §4
        # provision -Apply -Force, а New-V8FileInfobase стирає теку через Remove-Item -Recurse -Force.
        $hit = @($Context.Overlay.Infobases.Values | Where-Object { Test-KitSameInfobase -Left $_.Connection -Right $ib.Connection }) | Select-Object -First 1
        if ($hit) {
            throw ("База агента воркспейсу '$($Workspace.Path)' ($($ib.Origin)) збігається з дев-базою людини '$($hit.Name)' із накладки kit. " +
                   'Kit ніколи не пише в базу людини (принцип 3): приберіть infobase: з v8project.local.yaml або дайте агентові окрему базу.')
        }
    }

    $resolved = Resolve-KitAgentInfobasePath -Project $Workspace.Project -Connection $ib.Connection
    [pscustomobject]@{
        Workspace = $Workspace.Path; Connection = $ib.Connection; User = $ib.User; Origin = $ib.Origin
        Kind = $resolved.Kind; Path = $resolved.Path; IbSwitch = $resolved.IbSwitch
        Exists = $(if ($resolved.Kind -eq 'file') { Test-Path -LiteralPath (Join-Path $resolved.Path '1Cv8.1CD') -PathType Leaf } else { $true })
    }
}

Export-ModuleMember -Function Resolve-KitAgentBase, Test-KitSameInfobase
```

`module-order.txt`: `AgentBase` після `V8Project`.

- [ ] **Step 6а: `Test-KitSameInfobase` — і чому вона кидає, а не повертає `$false`**

**Аудит безпеки не має права на відповідь «не знаю».** Порівняння підключень стоїть перед
`Remove-Item -Recurse -Force`, тож будь-яка невизначеність мусить вести до зупинки, а не до
`$false`: `$false` тут означає «це не база людини, працюй далі». Ціна зайвої зупинки — одне
уточнення в накладці; ціна мовчазного «немає збігу» — дев-база людини.

Кидати (з назвою обох підключень дослівно й вказівкою, що саме не розібралось):
- `Kind` не розпізнано — ні `File=`, ні `Srvr=`/`Ref=`, або майбутній формат;
- `Srvr=` без `Ref=` чи навпаки;
- порожній рядок підключення;
- **відносний `File=`** — для бази агента §2.5 дає базу відліку (тека воркспейсу, за Унікою), а для
  дев-бази людини в `infobases:` такого правила немає. Резолвити «від кореня репозиторію» свідомо
  відхилено: це дало б дві різні бази відліку в одному файлі накладки — пастка, якої ніхто не
  запам'ятає. Дев-база людини живе поза репозиторієм, відносний шлях там майже напевно описка.

Повертати `$false` можна лише тоді, коли обидва підключення **розібрані** й справді різні —
зокрема при різних `Kind`: тоді ми знаємо, що бази різні, а не «не знаємо нічого».

Тести (`AgentBase.Tests.ps1`), кожен рядок — окремий It, бо це межа безпеки:
- `File="D:\Bases\X\"` vs `File=D:\Bases\X` → `$true` (кінцевий роздільник);
- `File=D:\Bases\X` vs `File=d:\bases\x` → `$true` (регістр);
- `File=D:\Bases\X` vs `File=D:\Bases\Y` → `$false`;
- `Srvr="A";Ref="B";` vs `Ref="B";Srvr="A";` → `$true` (порядок ключів);
- `Srvr="A";Ref="B";` vs `Srvr="A";Ref="C";` → `$false`;
- `File=D:\X` vs `Srvr="A";Ref="B";` → `$false` (різні `Kind`, обидва розібрані);
- `Srvr="A";` без `Ref=`, порожній рядок, `Что-то=1`, `File=..\bases\x` → **кидає** в усіх чотирьох.

І окремий It на всю межу: накладка з `File="D:\Bases\SMP_UNF\"`, воркспейс із
`File=D:\Bases\SMP_UNF` → `Resolve-KitAgentBase` кидає «…людини…». Це той самий сценарій, що
відтворило рев'ю; без нього фікс не має охорони проти повернення.

**Заборона відносного `File=` у схемі накладки** (`Read-KitLocalOverlay`) — окреме питання до
архітектора (§2.5, поставлено 2026-09-08): там помилка виявилась би раніше й зрозуміліше. Одне
одному не суперечить: перевірка в схемі не скасовує цю гілку, лише робить так, щоб до неї рідше
доходило. Поки відповіді немає — місце перевірки тут.

- [ ] **Step 7: `tools/commands/provision.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Invoke-KitProvision {
    <#
    .SYNOPSIS
        База агента (спека §4): порожня файлова або з .dt (CREATEINFOBASE /UseTemplate). Її можна
        знести й розгорнути знову будь-коли (-Force). Далі — operation=build Уніки.
    .PARAMETER Template
        Файл .dt; без нього береться workspaces.<ws>.agentBase.template з накладки; без обох — порожня база.
    .PARAMETER Remember
        Записати -Template у v8storagekit.local.yaml (те, що робить скіл provision після питання).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Force,
        [string]$Template,
        [switch]$Remember
    )

    if ($Remember -and -not $Template) { throw 'Параметр -Remember потребує -Template <файл.dt>: нема що записувати в накладку.' }
    $workspaces = @($Context.Workspaces)
    if ($Workspace) {
        $workspaces = @($workspaces | Where-Object Path -eq $Workspace)
        if ($workspaces.Count -eq 0) { throw "Воркспейсу '$Workspace' немає в маніфесті. Є: $($Context.Workspaces.Path -join ', ')." }
    }
    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $Context.RepoRoot 'v8storagekit.local.yaml' }
    $done = [System.Collections.Generic.List[object]]::new()

    foreach ($ws in $workspaces) {
        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { Write-Host "- $($ws.Path): у v8project.yaml немає infobase: — бази агента тут не буває (зовнішні обробки)."; continue }

        # $wsTemplate, а НЕ $template: PowerShell реєстронечутливий до імен змінних, тож $template
        # і параметр $Template — та сама змінна. Присвоєння в тілі циклу перезаписало б параметр, і
        # шаблон, узятий з накладки воркспейсу 1, протік би у воркспейс 2 (знахідка P2 префлайту B4).
        $wsTemplate = $Template
        if (-not $wsTemplate -and $Context.Overlay -and $Context.Overlay.Workspaces.ContainsKey($ws.Path)) {
            $wsTemplate = $Context.Overlay.Workspaces[$ws.Path].AgentBaseTemplate
        }

        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        Write-Host "База:      $($ab.Connection)  ($($ab.Origin))"
        if ($ab.Kind -eq 'server') {
            throw ("База агента воркспейсу '$($ws.Path)' серверна (Srvr=). Kit її не створює: серверну базу створює людина в кластері, а розгортання " +
                   'з .dt на сервері — окремий спайк (спека §13). Далі — operation=init/build Уніки.')
        }
        Write-Host ('Шлях:      ' + $ab.Path + $(if ($ab.Exists) { '  (існує)' } else { '  (ще немає)' }))
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        if (-not $Apply) {
            # Рядок збирається ДО виклику: у списку аргументів команди '+' — не оператор, а окремий
            # аргумент, і Write-Host надрукував би літеральний плюс (P4; той самий клас, що -f після дужок).
            $hint = '  Це попередній перегляд. Для виконання додайте -Apply' + $(if ($ab.Exists) { ' -Force (база існує й буде перестворена).' } else { '.' })
            Write-Host $hint -ForegroundColor Cyan
            continue
        }
        if ($ab.Exists -and -not $Force) {
            throw "База агента вже є: $($ab.Path). Перестворити з нуля — kit provision -Workspace $($ws.Path) -Apply -Force."
        }
        if ($wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }

        # Межа для видалення — тека воркспейсу: база агента лежить у workPath Уніки під нею.
        Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $ws.FullPath -Description "база агента воркспейсу $($ws.Path)"
        Write-Host '  Створюю базу...'
        $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $ws.FullPath -TemplatePath $wsTemplate
        Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        Write-Host '  Далі: operation=build Уніки наповнює базу з джерел воркспейсу.' -ForegroundColor DarkGray

        if ($Remember) {
            Save-KitOverlayAgentBase -OverlayPath $overlayPath -WorkspacePath $ws.Path -Template $wsTemplate
            Write-Host "  Шаблон записано в $overlayPath (workspaces.$($ws.Path).agentBase.template)." -ForegroundColor DarkGray
        }
        $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $ab.Path; Template = $wsTemplate })
    }
    [pscustomobject]@{ ExitCode = 0; Provisioned = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitProvision
```

`New-V8FileInfobase -TemplatePath ''` — порожній рядок означає «без шаблону» (перевірка `if ($TemplatePath)`).

- [ ] **Step 8: Тести без Integration зелені; `ModuleImportOrder` — додати `Resolve-KitAgentBase`, `Test-KitSameInfobase`, `Save-KitOverlayAgentBase`, `Resolve-KitAgentInfobasePath`, `ConvertTo-KitYaml`; коміт**

```bash
git add tools/lib tools/commands/provision.psm1 tools/tests
git commit -m "B4: база агента за вказівником Уніки з аудитом проти бази людини; kit provision (порожня / з .dt)"
```

---

### Task 2: команда `canon` (§3.6)

**Ризик:** `спільний код` — пише в дерево агента, яке читають `verify` і `sync`; помилка тут отруює порівняння в B3.

Агент, що редагує через Unica, ніколи не має байт-канонічного дерева. `canon`: після
`operation=build` (Unica, робить агент) — `/DumpConfigToFiles` з бази агента назад у дерево
кожного джерела воркспейсу. Після цього різниця з чим завгодно семантична.

**Files:**
- Create: `tools/commands/canon.psm1`
- Create: `tools/tests/Canon.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-KitAgentBase`, `Select-KitSources`, `Invoke-V8Designer`, `Assert-V8InfobaseNotBusy`, `Assert-SafeWorkPath`.
- Produces: `Invoke-KitCanon -Context [-Workspace] [-Source] [-Apply]` → `{ExitCode; Canonized: @({Key; Files; Changed})}`. Канонізуються джерела `Type ∈ {CONFIGURATION, EXTENSION}` з `truth ∈ {storage, dump, git}`; `vendor` і зовнішні обробки пропускаються з поясненням.

- [ ] **Step 1: Тест `tools/tests/Canon.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit canon — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Canon { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }

    It 'прев''ю: розширення канонізується, vendor пропускається з поясненням' {
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*'
        $r.Output | Should -BeLike '*base*vendor*пропущен*'
        $r.Output | Should -BeLike '*-Apply*'
    }

    It 'бази агента ще немає — -Apply зупиняється до платформи з підказкою provision; дерево ціле' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-base') -WithHooks
        $r = Invoke-Canon -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*provision*'
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }

    It 'база агента = база людини з накладки — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'" -WithHooks
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
        $r = Invoke-Canon -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*людини*'
    }

    It 'воркспейс лише з зовнішніми обробками — нічого канонізувати, код 0' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }
}

Describe 'kit canon — round-trip дає нуль розбіжностей на канонічному дереві' -Tag Integration {
    # Порожня база агента + стаб розширення: канонічне дерево — те, що платформа сама віддала.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rt') -WithHooks -WithGitattributes -WithGitignore
        # база агента зі стабом Alpha_SMB (як робив би operation=build)
        $ib = New-ExtensionInfobase -Path (Join-Path $script:Repo 'Alpha_SMB/build/ib') -ExtensionName 'Alpha_SMB' `
            -StubPath (Resolve-Path "$PSScriptRoot/../assets/empty-extension").Path -MustBeUnder (Join-Path $script:Repo 'Alpha_SMB')
    }
    It 'перший canon переписує дерево платформою; другий не змінює жодного файла' {
        $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'канонічне дерево'
        $out2 = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out2
        (git -C $script:Repo status --porcelain -- Alpha_SMB/cfe/src) | Should -BeNullOrEmpty
        $out2 | Should -BeLike '*змінено файлів: 0*'
    }
}
```

- [ ] **Step 2: Реалізація `tools/commands/canon.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Invoke-KitCanon {
    <#
    .SYNOPSIS
        Канонізація дерева агента (спека §3.6): /DumpConfigToFiles з бази агента назад у дерево
        кожного джерела. Передумова — operation=build Уніки вже наповнив базу; kit цього не робить
        і не перевіряє інакше, ніж за наявністю бази.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

    $root = $Context.RepoRoot
    $selected = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
    $done = [System.Collections.Generic.List[object]]::new()
    $byWorkspace = $selected | Group-Object Workspace

    foreach ($group in $byWorkspace) {
        $ws = $Context.Workspaces | Where-Object Path -eq $group.Name | Select-Object -First 1
        $targets = @($group.Group | Where-Object { $_.Type -in @('CONFIGURATION', 'EXTENSION') -and $_.Truth -ne 'vendor' })
        $skipped = @($group.Group | Where-Object { $_ -notin $targets })

        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        foreach ($s in $skipped) {
            $why = if ($s.Truth -eq 'vendor') { 'truth: vendor — чужа конфігурація, її канон дає дамп бази людини (kit dump), не бази агента' }
                   else { "$($s.Type) — зовнішні обробки платформа не вивантажує через DumpConfigToFiles" }
            Write-Host "  - $($s.Key): пропущено ($why)." -ForegroundColor DarkGray
        }
        if ($targets.Count -eq 0) { continue }

        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { Write-Host "  у v8project.yaml немає infobase: — бази агента немає, канонізувати нічим."; continue }
        Write-Host "  База агента: $($ab.IbSwitch)  ($($ab.Origin))"
        foreach ($t in $targets) { Write-Host "  - $($t.Key) → $($t.RepoPath)" }

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply (дерева джерел будуть переписані платформою).' -ForegroundColor Cyan
            continue
        }
        if ($ab.Kind -eq 'file' -and -not $ab.Exists) {
            throw "Бази агента ще немає: $($ab.Path). Спершу kit provision -Workspace $($ws.Path) -Apply, потім operation=build Уніки, тоді canon."
        }

        foreach ($t in $targets) {
            Assert-SafeWorkPath -Path $t.FullPath -MustBeUnder $ws.FullPath -Description "дерево джерела $($t.Key)"
            if (Test-Path -LiteralPath $t.FullPath) { Remove-Item -LiteralPath $t.FullPath -Recurse -Force }
            New-Item -ItemType Directory -Path $t.FullPath -Force | Out-Null

            $ext = if ($t.Type -eq 'EXTENSION') { " -Extension $($t.Key)" } else { '' }
            $r = Invoke-V8Designer -IbSwitch $ab.IbSwitch -User $ab.User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $t.FullPath, $ext))
            if ($r.ExitCode -ne 0) {
                Assert-V8InfobaseNotBusy -Output $r.Output -Infobase "агента ($($ws.Path))"
                throw "Канонізація $($t.Key) не вдалася: $($r.Output)"
            }
            $files = @(Get-ChildItem -LiteralPath $t.FullPath -Recurse -File).Count
            # Розбиття по NUL, а не по рядках: pwsh ділить вивід нативної команди по \n, а -z дає
            # NUL-роздільник — конвеєр віддав би ОДИН рядок, тобто Changed = 1 за будь-якої кількості
            # змін. Integration-тест цього не ловить: нуль змін дає порожній вивід, і єдиний
            # перевірений випадок — саме той, що працює (знахідка P6 префлайту B4).
            $raw     = (git -C $root -c core.quotepath=false status --porcelain -z -- $t.RepoPath 2>$null | Out-String)
            $changed = @($raw -split "`0" | Where-Object { $_ }).Count
            Write-Host "  $($t.Key): файлів $files, змінено файлів: $changed" -ForegroundColor Green
            $done.Add([pscustomobject]@{ Key = $t.Key; Files = $files; Changed = $changed })
        }
    }
    [pscustomobject]@{ ExitCode = 0; Canonized = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitCanon
```

> `git status --porcelain` рахує лише невідстежені/змінені файли відносно індексу — це «що
> змінила канонізація відносно того, що агент мав у git», і саме цей diff далі читає агент.

- [ ] **Step 3: Тести без Integration зелені; Integration — з підтвердженням; коміт**

```bash
git add tools/commands/canon.psm1 tools/tests/Canon.Tests.ps1
git commit -m "B4: kit canon — дерево агента у формат платформи через базу агента"
```

---

### Task 3: команда `build` — `.epf` через платформу, збір артефактів (§5, Q6)

**Ризик:** `спільний код` — додає команду в диспетчер і читає `v8project.yaml`, який читають `provision` і `canon`.

`.cf`/`.cfe` — не kit: скіл кличе `operation=make` Уніки з
`output=<корінь>/build/artifacts/<Ім'я>.cfe`. `build` збирає `.epf` для кожного source-set
`EXTERNAL_DATA_PROCESSORS` (дискримінатор — тип у `v8project.yaml`, не ім'я теки: закриває
`follow-ups.md` §7) і забирає в `build/artifacts/` те, що Unica могла покласти в
`<воркспейс>/build/artifacts/` (запасний шлях Q6).

**Files:**
- Create: `tools/commands/build.psm1`
- Rewrite: `tools/tests/Build.Tests.ps1`
- Delete: `tools/build.ps1` (у Task 5)

**Interfaces:**
- Produces: `Invoke-KitBuild -Context [-Workspace] [-Source] [-Apply]` → `{ExitCode; Artifacts}`; `Get-KitEpfDescriptors -Source` → `@({Name; Path})`; `Copy-KitWorkspaceArtifacts -Context -Destination` → `@(скопійовані)`.

- [ ] **Step 1: Тест `tools/tests/Build.Tests.ps1` (переписати цілком), що падає**

```powershell
#Requires -Version 7
Describe 'kit build — виявлення й збір артефактів без платформи (§12)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Build { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:Ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'tools'     = @{ Sets = @(@{ Name = 'processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
        }
    }

    It 'знаходить обробки за типом source-set, а не за ім''ям теки epf' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'discover') -Workspaces $script:Ws -WithHooks
        foreach ($n in 'Обробка_А', 'Обробка_Б') {
            Set-Content -LiteralPath (Join-Path $repo "tools/src/$n.xml") -Value '<x/>' -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $repo "tools/src/$n") -Force | Out-Null
        }
        $r = Invoke-Build -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Обробка_А.epf*Обробка_Б.epf*'
        $r.Output | Should -BeLike '*Alpha_SMB*operation=make*'
        $r.Output | Should -BeLike '*-Apply*'
    }

    It '-Apply без платформи: артефакти з <воркспейс>/build/artifacts збираються в build/artifacts кореня' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'collect') -Workspaces ([ordered]@{ 'Alpha_SMB' = $script:Ws['Alpha_SMB'] }) -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/artifacts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/artifacts/Alpha_SMB.cfe') -Value 'cfe' -Encoding ascii
        $r = Invoke-Build -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'build/artifacts/Alpha_SMB.cfe' | Should -Exist
        $r.Output | Should -BeLike '*Alpha_SMB.cfe*'
    }

    It 'без жодних обробок і без артефактів — код 0 і пояснення, як зібрати .cfe' {
        $r = Invoke-Build -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'nothing') -WithHooks) -More @('-Apply')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*operation=make*build/artifacts*'
    }
}

Describe 'kit build — .epf через платформу' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Джерело обробки — з живого репозиторію (перший .xml у epf/src), лише читання.
        $script:Live = 'R:\github\SMP_BankExchange\epf\src'
    }
    It 'збирає .epf із живих вихідників у build/artifacts' {
        $desc = Get-ChildItem -LiteralPath $script:Live -Filter '*.xml' -File | Select-Object -First 1
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'bank_formats'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks
        Copy-Item -LiteralPath $desc.FullName -Destination (Join-Path $repo 'epf/src')
        Copy-Item -LiteralPath (Join-Path $script:Live $desc.BaseName) -Destination (Join-Path $repo 'epf/src' $desc.BaseName) -Recurse
        $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo "build/artifacts/$($desc.BaseName).epf" | Should -Exist
    }
}
```

- [ ] **Step 2: Реалізація `tools/commands/build.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Get-KitEpfDescriptors {
    <# Кожна обробка — <Name>.xml поруч із текою <Name> у source-set EXTERNAL_DATA_PROCESSORS. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    # Кома навмисно: викликач робить foreach ($d in (Get-KitEpfDescriptors …)) — (…), НЕ @(…) — див. F7.
    if (-not (Test-Path -LiteralPath $Source.FullPath)) { return , @() }
    , @(Get-ChildItem -LiteralPath $Source.FullPath -Filter '*.xml' -File | Sort-Object Name | ForEach-Object {   # кома навмисно (F7)
        [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName } })
}

function Copy-KitWorkspaceArtifacts {
    <#
    .SYNOPSIS
        Запасний шлях Q6: якщо Unica відмовила в output поза воркспейсом, make поклав .cf/.cfe у
        <воркспейс>/build/artifacts — забираємо їх у кореневу теку артефактів.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Destination)
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($ws in $Context.Workspaces) {
        $dir = Join-Path $ws.FullPath $ws.Project.WorkPath 'artifacts'
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in @('.cf', '.cfe', '.epf', '.erf') }) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Destination $f.Name) -Force
            $copied.Add((Join-Path $Destination $f.Name))
        }
    }
    # Кома навмисно: викликач робить foreach ($c in (Copy-KitWorkspaceArtifacts …)) — (…), НЕ @(…) — див. F7.
    , $copied.ToArray()
}

function Invoke-KitBuild {
    <#
    .SYNOPSIS
        .epf через платформу (/LoadExternalDataProcessorOrReportFromFiles) у build/artifacts, збір .cf/.cfe,
        які operation=make Уніки поклала в артефакти воркспейсів, і вміст теки на екран (спека §5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

    $root   = $Context.RepoRoot
    $outDir = Join-Path $root 'build/artifacts'
    $selected = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
    $epfSources = @($selected | Where-Object Type -eq 'EXTERNAL_DATA_PROCESSORS')
    $extSources = @($selected | Where-Object Type -eq 'EXTENSION')

    Write-Host "Артефакти: $outDir"
    $plan = @(foreach ($s in $epfSources) { foreach ($d in (Get-KitEpfDescriptors -Source $s)) { [pscustomobject]@{ Source = $s; Descriptor = $d } } })
    foreach ($p in $plan) { Write-Host "  .epf  $($p.Descriptor.Name).epf  ← $($p.Source.RepoPath)" }
    foreach ($e in $extSources) {
        Write-Host "  .cfe  $($e.Key).cfe — не kit: operation=make Уніки (cwd $($e.Workspace), source-set $($e.Key)) з output=$outDir\$($e.Key).cfe" -ForegroundColor DarkGray
    }
    if ($plan.Count -eq 0 -and $extSources.Count -eq 0) { Write-Host '  Джерел для збірки в цьому виборі немає.' }

    if (-not $Apply) {
        Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Artifacts = @() }
    }

    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $artifacts = [System.Collections.Generic.List[string]]::new()

    if ($plan.Count -gt 0) {
        $ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $root 'build/build-ib') -MustBeUnder (Join-Path $root 'build'))
        foreach ($p in $plan) {
            $target = Join-Path $outDir "$($p.Descriptor.Name).epf"
            Write-Host "→ $($p.Descriptor.Name).epf"
            $r = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
                '/LoadExternalDataProcessorOrReportFromFiles "{0}" "{1}"' -f $p.Descriptor.Path, $target)
            if ($r.ExitCode -ne 0) { throw "Збірка $($p.Descriptor.Name) не вдалася: $($r.Output)" }
            $artifacts.Add($target)
        }
    }

    foreach ($c in (Copy-KitWorkspaceArtifacts -Context $Context -Destination $outDir)) {
        Write-Host "← зібрано з воркспейсу: $(Split-Path -Leaf $c)"
        $artifacts.Add($c)
    }

    Write-Host ''
    $files = @(Get-ChildItem -LiteralPath $outDir -File)
    if ($files.Count -eq 0) {
        Write-Host "У $outDir порожньо. .cf/.cfe збирає operation=make Уніки з output=$outDir\<Ім'я>.cfe; .epf — з source-set EXTERNAL_DATA_PROCESSORS." -ForegroundColor Yellow
    } else {
        $files | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
    }
    [pscustomobject]@{ ExitCode = 0; Artifacts = $artifacts.ToArray() }
}

Export-ModuleMember -Function Invoke-KitBuild, Get-KitEpfDescriptors, Copy-KitWorkspaceArtifacts
```

- [ ] **Step 3: Тести без Integration зелені; коміт**

```bash
git add tools/commands/build.psm1 tools/tests/Build.Tests.ps1
git commit -m "B4: kit build — .epf за типом source-set, збір артефактів у build/artifacts"
```

---

### Task 4: хук старту сесії — шим, `templates/settings.json`, `using-v8storagekit`, перевірка в `check` (§6, §7)

**Ризик:** `властивість безпеки` — шим виконується на старті **кожної** сесії споживача — дефект ламає не команду, а всі сесії
репозиторію; плюс заборона `hooks/hooks.json` у плагіні. Друге рев'ю — вузьке: мовчазна
поведінка шима без плагіна в реєстрі, відсутність `hooks.json` і стеля часу (нижче).

**Умова приймання — контракт §7, не інженерне рішення цього блоку** (спека 434a729): шим
**обмежений у часі за конструкцією**. `session-check` виконується на старті кожної сесії
споживача, обходить `data/objects` сховищ і додатково викликає повний `check` з `git log`,
`ls-tree -r` і `check-attr` по всіх джерелах. Стеля не залежить від того, скільки це триває:
вона гарантує, що старт сесії не зависне за будь-якої поведінки сховища й мережі.

**Виміряно на живому репозиторії** (прогін B3, компаньйон `smp-bankexchange-44`): п'ять запусків
— 2623 мс (холодний), 2361, 2370, 2500, 2367. Стеля 15 с не під загрозою: штатний час — близько
1/6 від неї, і обмеження «близький до стелі лікується здешевленням» не настало. Обхід каталогів
виявився дешевим: найбільше сховище на машині — 2134 файли за **160 мс**, `СМП_BankExchange_SMB`
— 359 файлів за 60 мс. Попереднє формулювання цього плану («десятки тисяч блобів, часто на SMB»)
було припущенням автора і живими даними **не підтвердилось** — виправлено тут, щоб воно не
кочувало далі як факт.

Два обмеження зі спеки, які виконавцю змінювати не можна:

- **Стеля — запобіжник, а не бюджет.** Якщо замір покаже типовий час, **близький** до 15 с (не
  лише більший), здешевлюється `session-check`, а не піднімається стеля. Інакше стеля тихо стає
  нормою і кожна сесія починається п'ятнадцятисекундною паузою «за контрактом».
- **Завершувати процес kit дозволено лише тому, що `session-check` нічого не мутує** (§5,
  стовпець «Мутує: ні»). Це залежність конструкції, а не деталь: під цю стелю **ніколи** не
  може потрапити команда, яка пише — ні `sync`, ні `verify -Apply`, ні «заодно» щось на старті
  сесії. Убитий на півдорозі мутатор лишає стан підвішеним, і жоден рядок у контексті цього не
  виправить.

Здешевлювати `session-check` наразі **нема чого**, і напрямок, який здавався очевидним, замір
закрив: варіант «максимальний `mtime` по шард-теках першого рівня замість рекурсії» **викреслено**
— він зекономив би ~0,1 с із 2,4 с. (Саму гіпотезу компаньйон перевірив: максимальний `mtime`
шард-теки першого рівня збігся з максимальним у глибині на двох сховищах, але доведеною не
названа — остаточний доказ вимагає побачити зміну в момент створення версії, тобто запису у
сховище, який агенту заборонений. Дисципліна правильна, і тепер це вже неважливо.)

Якщо здешевлення колись знадобиться, ціль — **старт `pwsh` і імпорт модулів**, на які йде
основна частина цих 2,4 с, а не обхід каталогів. Кеш результату в
`.git/v8storagekit/session-check.json` за `mtime` маніфесту лишається в леджері B3 як єдиний
уцілілий варіант; брати його в роботу — рішення користувача, не автора плану.

Плагін хуків **не оголошує**. Хук живе в `.claude/settings.json` репозиторію-споживача й
викликає закомічений шим `.claude/hooks/session-start.ps1`, який сам знаходить плагін у
реєстрі, запускає `kit.ps1 session-check` і друкує JSON із контекстом: вступний скіл плюс стан
сховищ. Плагіна немає — нічого не друкує, код 0.

**Files:**
- Create: `templates/hooks/session-start.ps1`
- Modify: `templates/settings.json` — блок `hooks.SessionStart`
- Create: `skills/using-v8storagekit/SKILL.md`
- Modify: `tools/lib/Hooks.psm1` — `Install-KitSessionHook`, `Test-KitSessionHook`
- Modify: `tools/commands/check.psm1` — знахідки `hook-shim`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — `Copy-KitTools` копіює ще `templates/hooks`, `templates/settings.json`, `skills/using-v8storagekit`; `New-KitFakeRepo -WithSessionHook`
- Create: `tools/tests/SessionStartHook.Tests.ps1`
- Modify: `tools/tests/Templates.Tests.ps1`, `tools/tests/Check.Tests.ps1`

**Interfaces:**
- Produces: шим (контракт у «Спільних контрактах»); `Install-KitSessionHook -RepoRoot [-TemplatesDir]` → шляхи; `Test-KitSessionHook -RepoRoot [-TemplatesDir]` → `@(finding)` (`Check = 'hook-shim'`); у тексті скіла плейсхолдер `<корінь плагіна>`, який шим замінює фактичним шляхом.

- [ ] **Step 1: Тести, що падають**

`tools/tests/SessionStartHook.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'templates/hooks/session-start.ps1 — шим хука SessionStart (§7)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:KitRoot = Split-Path -Parent (Split-Path -Parent (Copy-KitTools -Root (Join-Path $TestDrive 'kit')))   # <TestDrive>/kit
        $script:Shim = Join-Path $script:KitRoot 'templates/hooks/session-start.ps1'

        # Реєстр плагінів: у тесті — власний файл, шлях передається змінною середовища.
        $script:Registry = Join-Path $TestDrive 'installed_plugins.json'
        @{ plugins = @{ 'v8storagekit@smp-v8storagekit' = @(@{ version = 'test'; installPath = $script:KitRoot }) } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Registry -Encoding UTF8
        $script:EmptyRegistry = Join-Path $TestDrive 'no-kit.json'
        @{ plugins = @{ 'unica@unica' = @(@{ version = '0.12.3'; installPath = 'C:\nope' }) } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:EmptyRegistry -Encoding UTF8

        function script:Invoke-Shim {
            param([string]$Cwd, [string]$Registry)
            $env:V8KIT_PLUGINS_REGISTRY = $Registry
            try {
                Push-Location $Cwd
                try { $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String } finally { Pop-Location }
            } finally { Remove-Item Env:V8KIT_PLUGINS_REGISTRY -ErrorAction SilentlyContinue }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'у репозиторії з маніфестом друкує валідний JSON: hookEventName = SessionStart, вступ і стан сховищ; дерево не змінене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Shim -Cwd $repo -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*using-v8storagekit*'
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*session-check*- Alpha_SMB:*'
        $json.hookSpecificOutput.additionalContext | Should -Not -BeLike '*<корінь плагіна>*'
        $json.hookSpecificOutput.additionalContext | Should -BeLike "*$script:KitRoot*"   # без -replace: у -BeLike екран — бектик, не бекслеш (P8)
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }

    It 'плагіна в реєстрі немає — нічого не друкує, код 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-plugin') -WithHooks
        $r = Invoke-Shim -Cwd $repo -Registry $script:EmptyRegistry
        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
    }

    It 'kit session-check упав (код 1) — шим не мовчить: позначка «стан невідомий» і текст зупинки, код шима 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken') -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Value 'version: 1' -Encoding UTF8   # маніфест без workspaces → префлайт кидає
        $r = Invoke-Shim -Cwd $repo -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*НЕВІДОМИЙ*workspaces*'
    }

    It 'без маніфесту в cwd — лише вступ і підказка onboarding' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        git -C $dir init -q
        $r = Invoke-Shim -Cwd $dir -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*onboarding*'
        $json.hookSpecificOutput.additionalContext | Should -Not -BeLike '*- Alpha_SMB:*'
    }
}

Describe 'Hooks.psm1 — встановлення й аудит шима' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates").Path
    }
    It 'Install-KitSessionHook кладе шим і settings.json; Test-KitSessionHook мовчить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'install')
        Install-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Join-Path $repo '.claude/hooks/session-start.ps1' | Should -Exist
        Join-Path $repo '.claude/settings.json' | Should -Exist
        @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates).Count | Should -Be 0
    }
    It 'без шима — info; змінений шим — warn із назвою файлу; settings.json без хука — warn' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit')
        $f = @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates)
        @($f | Where-Object { $_.Level -eq 'info' -and $_.Message -like '*session-start.ps1*' }).Count | Should -Be 1

        Install-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Add-Content -LiteralPath (Join-Path $repo '.claude/hooks/session-start.ps1') -Value '# локальна правка'
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ "permissions": { "allow": [] } }' -Encoding UTF8
        $f = @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates)
        @($f | Where-Object { $_.Level -eq 'warn' -and $_.Message -like '*session-start.ps1*шаблон*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Level -eq 'warn' -and $_.Message -like '*settings.json*SessionStart*' }).Count | Should -Be 1
    }
}
```

`Templates.Tests.ps1`, новий Describe:

```powershell
Describe 'templates/settings.json і using-v8storagekit — хук прив''язаний до репозиторію, не до плагіна (§7)' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'settings.json споживача має hooks.SessionStart на .claude/hooks/session-start.ps1 з matcher startup|clear|compact' {
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $hook = $s.hooks.SessionStart[0]
        $hook.matcher | Should -Be 'startup|clear|compact'
        $hook.hooks[0].command | Should -BeLike '*pwsh -NoProfile -File .claude/hooks/session-start.ps1*'
        $hook.hooks[0].async | Should -BeFalse
    }
    It 'плагін не оголошує власних хуків' {
        Join-Path $script:Root 'hooks/hooks.json' | Should -Not -Exist
    }
    It 'шим не містить CLAUDE_PLUGIN_ROOT і не імпортує модулів kit' {
        $shim = Get-Content -LiteralPath (Join-Path $script:Root 'templates/hooks/session-start.ps1') -Raw
        $shim | Should -Not -Match 'CLAUDE_PLUGIN_ROOT'
        $shim | Should -Not -Match 'Import-Module'
        $shim | Should -Match 'installed_plugins\.json'
    }
    It 'using-v8storagekit без токена CLAUDE_PLUGIN_ROOT, з префіксованими іменами скілів' {
        $skill = Get-Content -LiteralPath (Join-Path $script:Root 'skills/using-v8storagekit/SKILL.md') -Raw
        $skill | Should -Not -Match 'CLAUDE_PLUGIN_ROOT'
        foreach ($n in 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify', 'onboarding') { $skill | Should -Match "v8storagekit:$n" }
        $skill | Should -Match '<корінь плагіна>'
    }
}
```

`Check.Tests.ps1` — один It: репозиторій `-WithSessionHook` зі зміненим шимом → у виводі
`check` є `[!]` із `session-start.ps1`; без шима — `[i]` із `session-start.ps1`, код 0.

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: `templates/hooks/session-start.ps1`**

```powershell
#Requires -Version 7
<#
.SYNOPSIS
    Шим хука SessionStart для репозиторію під v8storagekit (спека §7). Закомічений у
    репозиторії-споживачі як .claude/hooks/session-start.ps1; його кладе скіл onboarding.
.DESCRIPTION
    Логіки тут немає: знайти плагін у реєстрі Claude Code, викликати kit.ps1 session-check у
    поточній теці й надрукувати контекст для сесії. Плагіна немає — мовчки, код 0. Нічого не
    змінює: рішення — людині, дія — скіл v8storagekit:sync.
    Оновлення: kit check порівнює цей файл із templates/hooks/session-start.ps1 плагіна.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-KitPluginRoot {
    $registry = if ($env:V8KIT_PLUGINS_REGISTRY) { $env:V8KIT_PLUGINS_REGISTRY } else { Join-Path $HOME '.claude/plugins/installed_plugins.json' }
    if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) { return $null }
    try { $json = Get-Content -LiteralPath $registry -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not ($json.PSObject.Properties.Name -contains 'plugins')) { return $null }
    # Ключі реєстру — '<плагін>@<маркетплейс>'; ім'я плагіна — до '@'.
    $entry = $json.plugins.PSObject.Properties | Where-Object { ($_.Name -split '@', 2)[0] -eq 'v8storagekit' } | Select-Object -First 1
    if (-not $entry) { return $null }
    $install = @($entry.Value) | Select-Object -First 1
    if (-not $install -or -not ($install.PSObject.Properties.Name -contains 'installPath')) { return $null }
    $root = [string]$install.installPath
    if (-not (Test-Path -LiteralPath (Join-Path $root 'tools/kit.ps1') -PathType Leaf)) { return $null }
    $root
}

$plugin = Get-KitPluginRoot
if (-not $plugin) { exit 0 }

$context = ''
try {
    $intro = ''
    $skill = Join-Path $plugin 'skills/using-v8storagekit/SKILL.md'
    if (Test-Path -LiteralPath $skill -PathType Leaf) {
        $intro = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $intro = [regex]::Replace($intro, '\A---\r?\n.*?\r?\n---\r?\n', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $intro = $intro.Replace('<корінь плагіна>', $plugin)
    }

    $cwd = (Get-Location).Path
    $status = ''
    if (-not (Test-Path -LiteralPath (Join-Path $cwd 'v8storagekit.yaml') -PathType Leaf)) {
        $status = "У теці $cwd немає v8storagekit.yaml: репозиторій не підключено до kit (скіл v8storagekit:onboarding) або сесія відкрита не в корені репозиторію."
    } else {
        # Стеля часу — обов'язкова: цей код виконується на старті КОЖНОЇ сесії, а session-check обходить
        # data/objects (часто SMB) і викликає повний check. Перевищення показуємо рядком, не мовчанням:
        # мовчання читалось би як «нових версій немає» — та сама логіка, що для коду 1.
        # Стеля — через змінну оточення, а не через накладку: шим за конструкцією не читає YAML
        # (жодних модулів kit, жодного парсера) — інакше він перестав би бути шимом.
        $timeoutSec = 15
        if ($env:V8KIT_SESSION_CHECK_TIMEOUT -match '^\d+$') { $timeoutSec = [int]$env:V8KIT_SESSION_CHECK_TIMEOUT }
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            # Вивід — у ФАЙЛИ, не в пайп: пайп без асинхронного читання дає дедлок на великому виводі
            # (знахідка B2 в Invoke-KitGitProcess). Список аргументів закритий: -Apply шим не передає
            # ніколи — session-check нічого не змінює, і передавати його нема чого.
            $proc = Start-Process -FilePath 'pwsh' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ArgumentList @('-NoProfile', '-File', (Join-Path $plugin 'tools/kit.ps1'), 'session-check', '-RepoRoot', $cwd)
            if ($proc.WaitForExit($timeoutSec * 1000)) {
                $raw = (((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) + (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8)) | Out-String).Trim()
                # Коди за змістом (спека §5): 0 — тиша, 3 — є сигнал — обидва друкуються як є; 1 — перевірка
                # не відпрацювала, і мовчати не можна.
                $status = if ($proc.ExitCode -eq 1) { "УВАГА: kit session-check не відпрацював (код 1) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:`n$raw" } else { $raw }
            } else {
                # Убивати процес дозволено рівно тому, що session-check нічого не мутує (§5).
                try { $proc.Kill($true) } catch { }
                $status = "УВАГА: kit session-check не вклався в $timeoutSec с — стан сховищ НЕВІДОМИЙ, не «без змін». Найчастіша причина — повільний доступ до сховища (SMB); перевірити вручну: kit.ps1 session-check -RepoRoot ."
                # Те, що kit устиг надрукувати, не пропадає: знахідки check виходять раніше за сигнали джерел.
                # Позначка «частково» обов'язкова — без неї обрізаний вивід читався б як повний, тобто як
                # «інших джерел не згадано, отже з ними все гаразд».
                $partial = ''
                try { $partial = ((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) | Out-String).Trim() } catch { }
                if ($partial) { $status = "$status`n`nЧастково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):`n$partial" }
            }
        } finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    $context = "<v8storagekit>`n$intro`n`n## Стан сховищ (kit session-check)`n`n$status`n</v8storagekit>"
} catch {
    $context = "<v8storagekit>`nХук v8storagekit не зміг зібрати стан: $($_.Exception.Message)`n</v8storagekit>"
}

[ordered]@{
    hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context }
} | ConvertTo-Json -Depth 4 -Compress
exit 0
```

Три It **власним `Context`** із своєю фікстурою (знахідка P7 префлайту B4: без неї `$script:FakePlugin`
не існує, а без `cwd` із маніфестом шим до підпроцесу взагалі не дійде — він раніше вийде на гілці
«немає v8storagekit.yaml»). Плагін тут **окремий** від `$script:KitRoot`: кожен It підміняє в ньому
`tools/kit.ps1` заглушкою, і робити це в копії справжнього kit не можна — зламало б сусідні It.

```powershell
Context 'стеля часу' {
    BeforeAll {
        # Окремий фейковий плагін: kit.ps1 підміняється в кожному It, скіл потрібен шиму для вступу.
        $script:FakePlugin = Join-Path $TestDrive 'fake-plugin'
        New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'tools') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'skills/using-v8storagekit') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakePlugin 'skills/using-v8storagekit/SKILL.md') -Encoding UTF8 -Value '# вступ'
        $script:FakeRegistry = Join-Path $TestDrive 'fake-registry.json'
        @{ plugins = @{ 'v8storagekit@smp-v8storagekit' = @(@{ version = 'test'; installPath = $script:FakePlugin }) } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:FakeRegistry -Encoding UTF8
        # Репо з маніфестом: без нього шим іде гілкою «немає v8storagekit.yaml» і session-check не кличе.
        $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
        New-Item -ItemType Directory -Path $script:FakeRepo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
        $script:PrevRegistry = $env:V8KIT_PLUGINS_REGISTRY
        $env:V8KIT_PLUGINS_REGISTRY = $script:FakeRegistry
        Push-Location $script:FakeRepo
    }
    AfterAll {
        Pop-Location
        if ($null -eq $script:PrevRegistry) { Remove-Item Env:\V8KIT_PLUGINS_REGISTRY -ErrorAction SilentlyContinue }
        else { $env:V8KIT_PLUGINS_REGISTRY = $script:PrevRegistry }
    }

It 'шим не чекає довше за стелю: повільний session-check дає рядок «не вклався», а не зависання' {
    Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'Start-Sleep -Seconds 30'
    $env:V8KIT_SESSION_CHECK_TIMEOUT = '1'
    try {
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String
        $sw.Stop()
    } finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
    $sw.Elapsed.TotalSeconds | Should -BeLessThan 20        # стеля 1 с + запас на старт pwsh
    $out | Should -BeLike '*не вклався*'
    ($out | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'   # JSON лишився валідним
}

It 'те, що kit устиг надрукувати до стелі, потрапляє у вивід із позначкою «частково»' {
    # Заглушка друкує знахідку check і зависає — як повільне джерело після вже виданих рядків check.
    Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 `
        -Value "'[!] хуків немає: kit install-hooks'", 'Start-Sleep -Seconds 30'
    $env:V8KIT_SESSION_CHECK_TIMEOUT = '2'   # 2 с: заглушка встигає надрукувати рядок і скинути буфер у файл
    try { $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String }
    finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
    $out | Should -BeLike '*Частково*'
    $out | Should -BeLike '*install-hooks*'
    $out | Should -BeLike '*повнота НЕ гарантована*'
}

It 'шим ніколи не передає -Apply' {
    # Заглушка друкує власні аргументи — шим мусить дати рівно session-check -RepoRoot <шлях>.
    Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'param([Parameter(ValueFromRemainingArguments)]$Rest) $Rest -join " "'
    $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String
    $out | Should -Not -BeLike '*-Apply*'
    $out | Should -BeLike '*session-check*-RepoRoot*'
}
}
```

Стелю прибирати у `finally`, а не після виклику: інакше падіння It лишає її в оточенні й
наступні тести йдуть з однією секундою.

- [ ] **Step 4: `templates/settings.json` — блок хука** (після `"permissions": {…}`, на тому ж рівні)

```json
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File .claude/hooks/session-start.ps1",
            "async": false,
            "timeout": 60
          }
        ]
      }
    ]
  }
```

Відносний шлях — від кореня репозиторію, який і є `cwd` сесії (спека §7).

- [ ] **Step 5: `skills/using-v8storagekit/SKILL.md`**

```markdown
---
name: using-v8storagekit
description: Вступ до контуру «сховище ↔ git» для агента 1С поруч з Unica — вантажиться хуком старту сесії в репозиторії-споживачі. Принципи, куди йти за яким наміром, як читати стан сховищ. Тригер — старт сесії; викликати вручну не потрібно.
---

# using-v8storagekit — як тут працює агент

Цей репозиторій підключено до плагіна `v8storagekit`: сховища конфігурацій 1С — істина,
git — робоче середовище агента, Unica — основний інструмент. Kit закриває рівно те, чого
Unica не вміє: сховища, дамп із живої бази, база агента, звірка git зі сховищем.

## Принципи

1. **Сховище — істина.** Коли git попереду сховища — це видимий борг «застосувати залишок», не помилка. У сховище kit не пише.
2. **Unica — основний інструмент; kit доповнює.** Редагування, валідація, збірка `.cf`/`.cfe`, тести, синтаксис — Unica.
3. **Агент працює у своїй базі й ніколи не пише в базу людини.** Базу людини kit лише читає (`dump`), і лише на явне прохання.
4. **Результат агента — зібрані файли** у `build/artifacts/`. Застосовує людина, у своїй базі, своїм Конфігуратором.
5. **Структура репозиторію — у `v8storagekit.yaml` і `v8project.yaml`.** Слів «клієнт» і «продукт» у логіці немає.
6. **Байти в git — байти платформи.** Перед порівнянням дерево канонізується (`canon`).

## Куди йти за яким наміром

| Намір | Скіл | Команда kit |
|---|---|---|
| «є нові версії у сховищі», «перенеси зі сховища» | `v8storagekit:sync` | `kit.ps1 sync [-Apply]` |
| «вивантаж конфігурацію з бази» | `v8storagekit:dump` | `kit.ps1 dump [-Apply]` |
| «я поклав частину в сховище» | `v8storagekit:reconcile` | `sync` → `canon` → `merge storage/*` у гілку задачі |
| «закриваємо задачу», «готуй PR» | `v8storagekit:finish` | `sync` → `canon` → `verify` → артефакти → PR |
| «розгорни / перезбери базу агента» | `v8storagekit:provision` | `kit.ps1 provision [-Apply] [-Force]` |
| «звір git зі сховищем» | `v8storagekit:verify` | `kit.ps1 verify [-Ref X] [-Apply]` |
| «підключи репозиторій / воркспейс / джерело» | `v8storagekit:onboarding` | `kit.ps1 check` |
| «переведи репозиторій на маніфест» | `v8storagekit:migrate` | разово |

Команди запускаються з кореня репозиторію:
`pwsh -NoProfile -File "<корінь плагіна>/tools/kit.ps1" <команда> -RepoRoot .`
Без `-Apply` жодна команда нічого не змінює в git, сховищі чи базах — але `sync`, `verify` і
`dump` без `-Apply` усе одно піднімають платформу. `-Apply` — лише на явне прохання людини.

## Маршрутизація до Unica

- редагувати метадані/форми/СКД/ролі — `unica.*`; валідувати — `cfe.validate`, `cf.validate`;
- накотити джерела в базу агента — `operation=build`; зібрати `.cf`/`.cfe` — `operation=make`
  з `output=<корінь репо>/build/artifacts/<Ім'я>.cfe`; тести — `operation=test`; синтаксис — `operation=syntax`;
- застосовні операції (`dryRun:false`) — лише на явне прохання, з названим ризиком.

## Як читати «Стан сховищ» нижче

Рядки `- <джерело>: …` — результат `kit session-check` (без платформи, нічого не змінює):
- «ймовірно нові версії … kit sync» — у сховищі писали після останнього дзеркала; спитайте людину, чи оновити;
- «коміти, не злиті в main … kit verify -Apply» — дзеркало попереду головної гілки;
- «дзеркала ще немає» — перший `sync` ще не робили;
- «недоступне» — шлях сховища не існує на цій машині. **Причини дві, протилежні, і вибір за людиною:**
  або шлях у маніфесті правильний, а машина інша — тоді перевизначити в накладці
  `v8storagekit.local.yaml`, `storages:`; або в маніфесті записане **не те сховище** — тоді правити
  `v8storagekit.yaml`. Другий випадок не теоретичний: у живому репозиторії маніфест указував на
  `…_ACC`, а джерелом було `…_BP` (`check.psm1`, знахідка `storage-path`). Не радьте накладку, не
  спитавши: накладка, що маскує помилку маніфесту, розводить репозиторій по машинах — на кожній
  він синхронізується зі свого сховища.

Хук лише повідомляє. Рішення — людині, дія — скіл `v8storagekit:sync`.

## Межі

Сховища — тільки читання. `-Apply` — лише на явне прохання. У базу людини kit не пише.
Підрядки `лиценз`, `ліценз`, `license`, `HASP` у виводі платформи — зупинка й доповідь.
```

- [ ] **Step 6: `Hooks.psm1` — `Install-KitSessionHook`, `Test-KitSessionHook`**

```powershell
$script:SessionHookRel = '.claude/hooks/session-start.ps1'
$script:SettingsRel    = '.claude/settings.json'

function Install-KitSessionHook {
    <# Кладе шим і, якщо settings.json немає, — шаблон settings.json (з хуком). Наявний settings.json не чіпає. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates')))
    $shimDst = Join-Path $RepoRoot $script:SessionHookRel
    New-Item -ItemType Directory -Path (Split-Path -Parent $shimDst) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplatesDir 'hooks/session-start.ps1') -Destination $shimDst -Force
    $installed = @($shimDst)
    $settingsDst = Join-Path $RepoRoot $script:SettingsRel
    if (-not (Test-Path -LiteralPath $settingsDst -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $TemplatesDir 'settings.json') -Destination $settingsDst -Force
        $installed += $settingsDst
    }
    # Без коми: викликачі (install-hooks) загортають у @(…) — див. F7.
    $installed
}

function Test-KitSessionHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates')))
    $findings = [System.Collections.Generic.List[object]]::new()
    $shim = Join-Path $RepoRoot $script:SessionHookRel
    $template = Join-Path $TemplatesDir 'hooks/session-start.ps1'
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
        $findings.Add((New-KitFinding -Level info -Check 'hook-shim' -Message "Хук старту сесії не встановлено ($script:SessionHookRel) — сесія не отримає стан сховищ; onboarding кладе його з templates/hooks/."))
    } elseif (Test-Path -LiteralPath $template -PathType Leaf) {
        $a = (Get-Content -LiteralPath $shim -Raw) -replace "`r`n", "`n"
        $b = (Get-Content -LiteralPath $template -Raw) -replace "`r`n", "`n"
        if ($a -ne $b) { $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "Шим $script:SessionHookRel відрізняється від шаблону плагіна (templates/hooks/session-start.ps1) — оновіть копію.")) }
    }
    $settings = Join-Path $RepoRoot $script:SettingsRel
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        $hasHook = $false
        try {
            $json = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'hooks' -and $json.hooks.PSObject.Properties.Name -contains 'SessionStart') {
                $hasHook = [bool](@($json.hooks.SessionStart | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*session-start.ps1*' }).Count)
            }
        } catch { $findings.Add((New-KitFinding -Level error -Check 'hook-shim' -Message "$script:SettingsRel не читається як JSON: $($_.Exception.Message)")) }
        if (-not $hasHook) { $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "У $script:SettingsRel немає hooks.SessionStart з командою .claude/hooks/session-start.ps1 — шим не запускатиметься (зразок: templates/settings.json).")) }
    }
    # Без коми: check і тести загортають у @(…) — див. F7.
    $findings.ToArray()
}
```

Експортувати обидві. У `check.psm1` після `Test-KitGitHooks`:
`foreach ($f in @(Test-KitSessionHook -RepoRoot $root)) { $findings.Add($f) }`.

`KitFixtures.psm1`: `Copy-KitTools` копіює додатково `templates/hooks`, `templates/settings.json`,
`skills/using-v8storagekit`; `New-KitFakeRepo -WithSessionHook` → `Install-KitSessionHook`.

- [ ] **Step 7: Тести зелені; перевірка правила `${CLAUDE_PLUGIN_ROOT}` (порожньо); коміт**

```bash
git add templates/hooks/session-start.ps1 templates/settings.json skills/using-v8storagekit/SKILL.md tools/lib/Hooks.psm1 tools/commands/check.psm1 tools/tests
git commit -m "B4: хук старту сесії, прив'язаний до репозиторію — шим, settings.json споживача, using-v8storagekit, аудит у check"
```

---

### Task 5: завершення блоку — вилучення, перехідні позначки, живий прогін

**Ризик:** `механічна` — вилучення й тексти; логіки немає. Одне рев'ю на дешевій моделі — лише guard-`grep`-и Step 3.
**Виконується одним циклом:** частина А (Steps 1–4) і частина Б (Steps 5–8) — один виконавець,
одне рев'ю, один звіт; коміт частини А окремий.

**Частина А: вилучення й перехідні позначки**

**Files:**
- Delete: `tools/load-ext.ps1`, `tools/build.ps1`
- Modify: `tools/lib/V8.psm1` — вилучити `Read-V8LocalConnection` (і з експорту); `tools/tests/V8.Tests.ps1` — її тести
- Modify: `templates/CLAUDE.md`, `templates/README.md`, `skills/storage-pipeline/SKILL.md`, `CLAUDE.md`, `docs/follow-ups.md` §7
- Modify (межа блоку, рішення автора планів за питанням префлайту B4): `docs/unica-contract.md`,
  `skills/product-onboarding/SKILL.md`, `docs/storage-and-git.md` — див. Step 2а

- [ ] **Step 1: Вилучити**

```bash
git rm -q tools/load-ext.ps1 tools/build.ps1
```

`V8.psm1`: видалити `Read-V8LocalConnection` цілком (рядки 59–119 у версії B1) та її ім'я з
`Export-ModuleMember`; у `V8.Tests.ps1` — усі It/Describe, що її згадують
(`Select-String -Pattern 'Read-V8LocalConnection' tools/tests/V8.Tests.ps1`). Конвенція
`devInfobase:` у `v8project.local.yaml` тепер **не читається взагалі**: дев-бази живуть у
`v8storagekit.local.yaml`; накладка Уніки — лише база агента.

- [ ] **Step 2: Перехідні позначки**

`templates/CLAUDE.md`, «Типові операції»: прибрати рядок «розкоти розширення в дев-базу»
(агент не пише в базу людини — принцип 3; розкатка у **базу агента** — `operation=build` Уніки);
рядок «збери cfe/epf» → «`kit.ps1 build -Apply` — `.epf` і збір артефактів; `.cfe` —
`operation=make` Уніки з `output=<корінь>/build/artifacts/<Ім'я>.cfe`». Абзац «Робота через
Unica» — рядок про `build.ps1` замінити на цю ж формулу.

`templates/README.md` — додати рядки: `hooks/session-start.ps1` → `.claude/hooks/session-start.ps1`;
примітка до `settings.json`: «містить хук SessionStart».

`skills/storage-pipeline/SKILL.md`, перехідна позначка: «`load-ext.ps1` вилучено (агент не
пише в базу людини); `build.ps1` → `kit.ps1 build`; база агента — `kit.ps1 provision`,
канонізація — `kit.ps1 canon`».

`CLAUDE.md` kit, рядок `tools/`: «Диспетчер `kit.ps1` з командами `check`, `sync`, `verify`,
`dump`, `session-check`, `provision`, `canon`, `build` у `commands/`; модулі `lib/*.psm1`;
тести `tests/`». Розділ «Зв'язок з Unica»: речення про `dump-config.ps1` замінити на
«`kit dump` існує заради операцій Уніки…»; про `tools/build.ps1` — на «`kit build` збирає лише
`.epf`; `.cf`/`.cfe` — `operation=make` Уніки». У «Правила, які легко порушити» додати п. 5:
«**Плагін не оголошує хуків.** `hooks/hooks.json` у kit не створювати: хук старту сесії живе в
`templates/settings.json` споживача й шимі `templates/hooks/session-start.ps1` (спека §7)».

`docs/follow-ups.md` §7 — дописати: «**Закрито в B4:** `kit build` знаходить обробки за
`type: EXTERNAL_DATA_PROCESSORS` у `v8project.yaml`, гілка `.cfe` вилучена (`operation=make`)».

- [ ] **Step 2а: Згадки вилученого коду поза списком вище** (межа B4/B8)

Правило, за яким це розділено: **застарілий опис чекає B8, застаріла інструкція — ні.** Опис дає
читачеві незбіг із кодом; інструкція змушує його діяти, і якщо вона суперечить межі, яку блок щойно
поставив, вона небезпечна саме зараз.

- `docs/unica-contract.md` (рядок про `Read-V8LocalConnection`) і `skills/product-onboarding/SKILL.md`
  (те саме) — по одному рядку кожен: функцію вилучено, дев-бази живуть у `v8storagekit.local.yaml`,
  накладка Уніки тримає лише базу агента. Те, що `product-onboarding` вилучається в B5, не привід
  лишати: між блоками плагін перевстановлюється, і скіл увесь цей час активний — та сама логіка, що
  вже застосована до `skills/storage-pipeline/SKILL.md` вище.
- `docs/storage-and-git.md` — **позначка плюс дві точкові правки**. Позначка на початку: «контур
  переїхав на `kit provision`/`canon`/`build`; розділ переписується в B8» — нею покриваються теки
  `build`, рядок «хто в kit її торкається» і згадка `build.ps1` у контракті: це опис.
  **Але рядок таблиці «git → база» і приклад запуску `load-ext.ps1` виправити на місці**, бо це
  інструкція: після Task 5 напрямок «git → база людини» перестає бути операцією kit узагалі
  (принцип 3). Напрямок стає «git → **база агента**» (`kit.ps1 build`, `operation=build` Уніки) з
  явним «у базу людини kit не пише ніколи»; рядок `load-ext.ps1` із блоку прикладів зникає.
  Позначка на початку документа таку таблицю не рятує: таблиці й блоки команд читають вибірково,
  часто `grep`-ом, не з початку файлу.

- [ ] **Step 3: Прогін і перевірки**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
grep -rln 'load-ext\|dump-config\|storage-sync\|devInfobase' tools/ templates/ skills/using-v8storagekit
test -e hooks/hooks.json && echo "ПОМИЛКА: hooks.json у плагіні" || echo "ok: плагін хуків не оголошує"
```

Перший `grep` — порожньо; другий — лише перехідна позначка в `skills/storage-pipeline/SKILL.md`
(вона не в списку) і `templates/CLAUDE.md` не має містити жодного зі старих імен.

- [ ] **Step 4: Коміт**

```bash
git add -A -- tools templates skills CLAUDE.md docs/follow-ups.md docs/unica-contract.md docs/storage-and-git.md
git commit --only -- tools templates skills CLAUDE.md docs/follow-ups.md docs/unica-contract.md docs/storage-and-git.md -m "B4: вилучено load-ext.ps1, build.ps1 і Read-V8LocalConnection; перехідні позначки під kit provision/canon/build"
```

---

**Частина Б: живий прогін блоку (за підтвердженням користувача)**

Єдина точка блоку, де запускається платформа і жива сесія. Маркетплейс зареєстровано локально
(B1 Task 10), тож плагін у реєстрі вказує на робочу копію.

- [ ] **Step 5: повний прогін з `Integration`** — усі три Describe блоку разом
  (`provision` порожня і з `.dt`, `canon` round-trip, `build` `.epf`), одним запуском:

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1
```

  До цього кроку `Integration` у блоці **не запускався жодного разу** — так задумано. Підрядки
  `лиценз`/`ліценз`/`license`/`HASP` у виводі платформи — зупинка й доповідь, не діагностика служб.

- [ ] **Step 6:** У синтетичному репозиторії з `Sync.Tests` (Integration) або на копії
  `New-KitFakeRepo -WithHooks -WithSessionHook -WithGitattributes -WithGitignore` відкрити
  сесію: `cd <репо>; claude -p "Назви джерела зі «Стану сховищ» у своєму контексті"`.
  Очікувано: відповідь містить `Alpha_SMB` (або ключ живого джерела) — хук спрацював.
- [ ] **Step 7:** Там же `kit check` — знахідок `hook-shim` немає.
- [ ] **Step 8:** У репозиторії **без** плагіна в реєстрі (тимчасово перейменувати ключ у копії
  реєстру й передати `V8KIT_PLUGINS_REGISTRY`) шим мовчить — уже покрито тестом; вручну не повторювати.

---

## Self-review

| Вимога спеки | Задача |
|---|---|
| база агента з вказівника Уніки; ніколи не база людини (Q2, принцип 3) | 1 |
| `provision`: порожня / з `.dt` (`CREATEINFOBASE /UseTemplate`), `-Force` перестворює; серверна — спайк (§4, §13) | 1 |
| запис вибору в `v8storagekit.local.yaml` (`agentBase.template`) — механізм для скіла provision (§2.5) | 1 |
| `canon`: `/DumpConfigToFiles` з бази агента назад у дерево; Unica `dump` не використовується (§3.6) | 2 |
| `build`: лише `.epf`; збір `.cf/.cfe` з `build/artifacts` воркспейсів (Q6); дискримінатор — тип source-set (follow-ups §7) | 3 |
| хук у `templates/settings.json`, шим без логіки, знаходить плагін через `installed_plugins.json`, формат `hookSpecificOutput`, мовчить без плагіна, нічого не змінює (§7) | 4 |
| `using-v8storagekit`: принципи, маршрутизація до скілів і Unica, як читати `session-check` (§6) | 4 |
| `check` порівнює шим із `templates/hooks/` (§7) | 4 |
| вилучення `load-ext.ps1` (§5), `build.ps1`, `Read-V8LocalConnection` | 5 |
| тести §12 «хук старту сесії» (валідний JSON, без плагіна — порожньо, без маніфесту — лише вступ, дерево не змінене, check помічає розбіжність) і «build без платформи» | 3, 4 |
| Integration: `provision` порожня і з `.dt`; `canon` round-trip; `build .epf` | 1–3 (тести), 5 (єдиний прогін) |

**Свідомо не в B4:** скіли життєвого циклу й `onboarding` (кладуть шим, пишуть маніфест,
питають `truth`/тип бази) — B5; `templates/CLAUDE.md` переписується цілком — B5.

**Узгодженість імен:** `Resolve-V8AgentInfobase` (+`User`), `Resolve-KitAgentInfobasePath`,
`Resolve-KitAgentBase`, `Save-KitOverlayAgentBase`, `New-V8FileInfobase -TemplatePath`,
`Invoke-KitProvision`, `Invoke-KitCanon`, `Invoke-KitBuild`, `Get-KitEpfDescriptors`,
`Copy-KitWorkspaceArtifacts`, `Install-KitSessionHook`, `Test-KitSessionHook` — однакові в
контрактах, коді й тестах; плейсхолдер `<корінь плагіна>` — у скілі й у шимі.
