# B5. Скіли життєвого циклу — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** сім скілів плагіна по одному на намір — `onboarding`, `sync`, `dump`, `reconcile`,
`finish`, `provision`, `verify` — які читають маніфест і ведуть людину й агента через життєвий
цикл задачі (спека §8) командами kit і операціями Unica; переписані `templates/CLAUDE.md` і
`templates/README.md`; вилучення трьох старих скілів; залежності A8–A11 в
`docs/unica-contract.md`.

**Architecture:** скіли — Markdown із frontmatter, як у superpowers: короткий вступ уже є
(`using-v8storagekit`, B4), решта — по одному на намір. Логіки в скілах немає: кожен каже,
**яку команду kit чи операцію Unica** запустити, **що спитати** людину (з варіантами) і **де
зупинитись**. Єдина нова команда kit — `install-hooks` (встановити `.githooks` і шим хука):
без неї `onboarding` мусив би імпортувати модулі з тексту скіла. Скіли перевіряються
тестами на **вміст** (guard-тести на роздавані артефакти, як `Templates.Tests.ps1`): правило
`${CLAUDE_PLUGIN_ROOT}` лише в шляху, префікс `v8storagekit:` у перехресних посиланнях,
жодних згадок вилучених скриптів, наявність питань із варіантами там, де спека вимагає
питати.

**Tech Stack:** Markdown (SKILL.md, frontmatter `name`/`description`), PowerShell 7.5 (одна
команда), Pester 5.

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` — §2.5 (kit питає
`truth` і тип бази), §2.6 (політики git під фактичні шляхи), §6 (таблиця скілів,
маршрутизація до Unica), §7 (шим кладе `onboarding`), §8 (життєвий цикл), §11 (A8–A11),
§13 (межі), §14 (B5).

## Global Constraints

- **Мова скілів — українська**; команди, шляхи, імена операцій Unica — як є.
- **`${CLAUDE_PLUGIN_ROOT}` — тільки всередині шляху** (`"${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1"`).
  Речення *про* токен — заборонені (CLAUDE.md, правило 1). Перевірка: `grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'` порожня.
- **Перехресні посилання — тільки з префіксом** `v8storagekit:<ім'я>`.
- **Скіл нічого не запускає без дозволу** користувача чи harness-запиту: `-Apply` лише на явне
  прохання (дієслово-наказ або підтвердження після прев'ю). Прев'ю `sync`/`verify`/`dump`
  піднімає платформу — скіл каже це людині перед запуском.
- **Сховища — тільки читання; база людини — тільки читання (`dump`); `git push`, `gh pr create` —
  лише за явним проханням і через запит дозволу harness** (`templates/settings.json` тримає їх в `ask`).
- **`templates/settings.json` дозволи Unica не змінювати**; `unica_runtime_execute` лишається без auto-allow.
- **Скіли ітерують маніфест** (`kit.ps1 check` / `session-check` показують воркспейси й джерела) —
  розгалуження «клієнт/продукт» у логіці немає (принцип 5).
- **Версію не піднімати. `git push` — ні.** Робота в `feature/agent-contour`.

### Рішення, узгоджені з архітектором

| # | Питання | Рішення | Де в спеці |
|---|---|---|---|
| Q7 | версії/маркетплейс | локальний маркетплейс уже стоїть; після B5 — **не пушити й не релізити**; перевірка скілів — `claude -p` у новій сесії | §14 |
| Q6 | `.cfe` у `finish` | `operation=make` з `output=<корінь репо>/build/artifacts/<Ім'я>.cfe`; якщо Unica відмовить — `output=<воркспейс>/build/artifacts/…`, `kit build` збирає | §5 |
| — | `repo-migration` (gitsync/EDT → kit) | скіл вилучається (спека B5); його процедура зберігається як довідка `docs/migration/legacy-gitsync-repo.md` — рішення по `SMP_OnlineExchange` окреме (§13), і без цього тексту його не ухвалити | §13, §14 |

---

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `tools/commands/install-hooks.psm1`, `tools/tests/InstallHooks.Tests.ps1` | **нові.** `kit install-hooks [-Apply]` — `.githooks` + `core.hooksPath` + шим і `settings.json` | 1 |
| `skills/onboarding/SKILL.md` | **новий.** Підключення репозиторію / воркспейсу / джерела; питання `truth`; політики git під фактичні шляхи; хуки; перший коміт; перший `sync`; `provision` | 2 |
| `skills/sync/SKILL.md` | **новий.** | 3 |
| `skills/dump/SKILL.md` | **новий.** | 3 |
| `skills/verify/SKILL.md` | **новий.** | 3 |
| `skills/provision/SKILL.md` | **новий.** Питання «порожня / `.dt` / серверна» | 4 |
| `skills/reconcile/SKILL.md` | **новий.** | 5 |
| `skills/finish/SKILL.md` | **новий.** | 5 |
| `skills/storage-pipeline/`, `skills/product-onboarding/`, `skills/repo-migration/` | **вилучаються** | 6 |
| `docs/migration/legacy-gitsync-repo.md` | **новий.** Довідка з тексту `repo-migration` (без frontmatter, без команд старого kit) | 6 |
| `templates/CLAUDE.md` | переписаний під модель 1.0 | 6 |
| `templates/README.md` | таблиця відповідностей під нові шаблони | 6 |
| `docs/unica-contract.md` | A8–A11 | 7 |
| `tools/tests/Skills.Tests.ps1` | **новий.** Guard-тести на вміст усіх скілів | 2–5 |
| `tools/tests/Templates.Tests.ps1` | оновлення під новий `templates/CLAUDE.md`; тест шаблону `v8project.yaml` переїжджає на `onboarding` | 6 |
| `CLAUDE.md` kit | таблиця «Структура»: сім скілів + `using-v8storagekit` | 7 |

---

## Спільні конвенції скілів (Interfaces)

- **Frontmatter:** `name: <тека>`, `description:` — одне речення «що робить» + «Тригери — «…», «…»».
- **Вступний абзац:** що робить скіл і що **не** робить (межа з Unica / іншим скілом).
- **Виявлення контексту:** завжди через `kit.ps1 check -RepoRoot .` (список воркспейсів і
  джерел у першому `[i]`-рядку) або `session-check`; ніколи — читанням теки «на око».
- **Команди** — у таблиці «Намір → команда», абсолютним шляхом:
  `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" <команда> -RepoRoot . …`
- **Питання людині** — `AskUserQuestion`, якщо інструмент доступний, інакше звичайним
  повідомленням; варіанти й наслідки — дослівно з розділу скіла.
- **«Штатні зупинки»** — розділ з текстами зупинок команд kit (ASCII-якорі) і що робити.
- **«Межі»** — сховище/база людини/`-Apply`/ліцензія/push, як у `templates/CLAUDE.md`.
- **Ланцюжок життєвого циклу** (§8) у кожному скілі одним рядком: `onboarding → sync → provision →
  (робота в Unica) → reconcile → finish → verify`.

```
commands/install-hooks.psm1
  Invoke-KitInstallHooks -Context [-Workspace] [-Source] [-Apply] : → {ExitCode; Installed:string[]}
      прев'ю: що буде покладено; -Apply: Install-KitGitHooks + Install-KitSessionHook, потім `git add .githooks/*` +
      `git update-index --chmod=+x .githooks/*` (режим 100755 в індексі — F10: інакше клон на POSIX дістає хук без біта
      виконання, і git мовчки його ігнорує); потім Test-KitGitHooks/Test-KitSessionHook мусять мовчати
```

---

### Task 1: команда `install-hooks`

`onboarding` має покласти `.githooks`, увімкнути `core.hooksPath`, покласти шим і
`settings.json` — без імпорту модулів із тексту скіла.

**Files:**
- Create: `tools/commands/install-hooks.psm1`
- Create: `tools/tests/InstallHooks.Tests.ps1`

**Interfaces:**
- Consumes: `Install-KitGitHooks`, `Install-KitSessionHook`, `Test-KitGitHooks`, `Test-KitSessionHook` (B1, B4).
- Produces: `Invoke-KitInstallHooks -Context [-Workspace] [-Source] [-Apply]` → `{ExitCode; Installed}`.

- [ ] **Step 1: Тест, що падає**

```powershell
#Requires -Version 7
Describe 'kit install-hooks — хуки захисту й хук старту сесії одним кроком' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-InstallHooks { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit install-hooks -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }
    It 'прев’ю перелічує, що буде покладено, і нічого не кладе' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview')
        $r = Invoke-InstallHooks -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*.githooks*session-start.ps1*-Apply*'
        Join-Path $repo '.githooks' | Should -Not -Exist
    }
    It '-Apply кладе все; після цього kit check мовчить про hooks і hook-shim' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'apply') -WithGitattributes -WithGitignore
        $r = Invoke-InstallHooks -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        Join-Path $repo '.claude/hooks/session-start.ps1' | Should -Exist
        Join-Path $repo '.claude/settings.json' | Should -Exist
        (git -C $repo config --get core.hooksPath) | Should -Be '.githooks'
        # F10: хуки застейджені з режимом 100755 — саме він дістанеться кожному клону (git ls-files -s питає індекс, не ФС)
        foreach ($h in 'pre-commit', 'pre-merge-commit') { (git -C $repo ls-files -s -- ".githooks/$h") | Should -Match '^100755 ' }
        $check = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo 2>&1 | Out-String
        $check | Should -Not -BeLike '*core.hooksPath*'
        $check | Should -Not -Match '100644'
        $check | Should -Not -Match '\[!\].*session-start\.ps1'
    }
    It 'наявний .claude/settings.json не перезаписується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'keep')
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ "permissions": { "allow": ["Bash(echo:*)"] } }' -Encoding UTF8
        Invoke-InstallHooks -Repo $repo -More @('-Apply') | Out-Null
        (Get-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Raw) | Should -BeLike '*Bash(echo:*)*'
    }
}
```

- [ ] **Step 2: Реалізація `tools/commands/install-hooks.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Invoke-KitInstallHooks {
    <#
    .SYNOPSIS
        Ставить у репозиторій-споживач хуки захисту storage/* (.githooks + core.hooksPath) і хук старту
        сесії (.claude/hooks/session-start.ps1 + .claude/settings.json, якщо його ще немає). Ідемпотентно.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )
    $root = $Context.RepoRoot
    Write-Host 'Буде покладено:'
    Write-Host '  .githooks/pre-commit, .githooks/pre-merge-commit  + git config core.hooksPath .githooks'
    Write-Host '  .claude/hooks/session-start.ps1  (+ .claude/settings.json, якщо його немає)'
    if (-not $Apply) {
        Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Installed = @() }
    }
    $installed = @(Install-KitGitHooks -RepoRoot $root) + @(Install-KitSessionHook -RepoRoot $root)
    foreach ($p in $installed) { Write-Host "  + $p" }
    # F10: біт виконання живе в індексі git, не в ФС Windows (core.filemode=false). Install-KitGitHooks індексу не
    # чіпає навмисно; це робить крок онбордингу — тут. Стейджимо лише хуки: решту (шим, settings) стейджить людина
    # чи скіл у першому коміті.
    $hookPaths = @(Get-KitHookNames | ForEach-Object { ".githooks/$_" })
    $out = git -C $root add -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git add .githooks завершився з кодом ${LASTEXITCODE}: $out" }
    $out = git -C $root update-index --chmod=+x -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git update-index --chmod=+x завершився з кодом ${LASTEXITCODE}: $out" }
    Write-Host '  + .githooks/* застейджено з режимом 100755 (біт виконання для клонів на POSIX)'
    $left = @(Test-KitGitHooks -RepoRoot $root) + @(Test-KitSessionHook -RepoRoot $root)
    $problems = @($left | Where-Object Level -ne 'info')
    foreach ($f in $problems) { Write-Host "  [$($f.Level)] $($f.Message)" -ForegroundColor Yellow }
    Write-Host 'Готово. .githooks уже в індексі; додайте .claude у перший коміт.' -ForegroundColor Green
    [pscustomobject]@{ ExitCode = $(if ($problems.Count) { 1 } else { 0 }); Installed = $installed }
}

Export-ModuleMember -Function Invoke-KitInstallHooks
```

- [ ] **Step 3: Повідомлення знахідок називають команду** (знахідка H1 живого прогону B1: повідомлення «хука немає»
  каже, чого бракує, і не каже, де взяти). У `Test-KitGitHooks` (`hooks`) і `Test-KitSessionHook` (`hook-shim`) до
  тексту про відсутній/незакомічений хук чи шим додати дію: `kit install-hooks -RepoRoot . -Apply` (джерело —
  `templates/githooks/`, `templates/hooks/` у теці плагіна; тека плагіна — `claude plugin list`). Тест у
  `InstallHooks.Tests.ps1`: на репозиторії без хуків вивід `kit check` містить `install-hooks`.

- [ ] **Step 4: Тести зелені; коміт**

```bash
git add tools/commands/install-hooks.psm1 tools/lib/Hooks.psm1 tools/tests/InstallHooks.Tests.ps1
git commit -m "B5: kit install-hooks — хуки захисту й хук старту сесії одним кроком для onboarding; повідомлення check називають команду"
```

---

### Task 2: скіл `onboarding` і guard-тести скілів

**Files:**
- Create: `skills/onboarding/SKILL.md`
- Create: `tools/tests/Skills.Tests.ps1`

- [ ] **Step 1: Guard-тести — `tools/tests/Skills.Tests.ps1`** (загальні на всі скіли + `onboarding`; наступні задачі додають свої `Context`)

```powershell
#Requires -Version 7
Describe 'skills/*/SKILL.md — правила, які легко порушити' {
    BeforeAll {
        $script:SkillsDir = (Resolve-Path "$PSScriptRoot/../../skills").Path
        $script:Skills = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Text = (Get-Content -LiteralPath (Join-Path $_.FullName 'SKILL.md') -Raw -Encoding UTF8) } })
        $script:Allowed = @('using-v8storagekit', 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify', 'migrate')
        function script:Skill([string]$Name) { ($script:Skills | Where-Object Name -eq $Name).Text }
    }

    It 'frontmatter: name = ім’я теки, description з тригерами' {
        foreach ($s in $script:Skills) {
            $s.Text | Should -Match "(?m)^name:\s*$([regex]::Escape($s.Name))\s*$"
            $s.Text | Should -Match '(?m)^description:.*Тригер'
        }
    }
    It '${CLAUDE_PLUGIN_ROOT} — лише всередині шляху (за токеном одразу /)' {
        foreach ($s in $script:Skills) {
            [regex]::Matches($s.Text, '\$\{CLAUDE_PLUGIN_ROOT\}(?!/)').Count | Should -Be 0 -Because "у $($s.Name) токен вжито не як частину шляху"
        }
    }
    It 'перехресні посилання — лише з префіксом v8storagekit: і лише на відомі скіли' {
        foreach ($s in $script:Skills) {
            foreach ($m in [regex]::Matches($s.Text, 'v8storagekit:([a-z8-]+)')) {
                $script:Allowed | Should -Contain $m.Groups[1].Value -Because "у $($s.Name) посилання на невідомий скіл"
            }
            foreach ($old in 'storage-pipeline', 'product-onboarding', 'repo-migration') {
                $s.Text | Should -Not -Match "v8storagekit:$old" -Because "у $($s.Name) посилання на вилучений скіл $old"
            }
        }
    }
    It 'жодних згадок вилучених скриптів і storage.json (крім using-v8storagekit і migrate, що пояснюють міграцію)' {
        foreach ($s in ($script:Skills | Where-Object { $_.Name -notin @('migrate') })) {
            $s.Text | Should -Not -Match 'storage-sync\.ps1|dump-config\.ps1|load-ext\.ps1|build\.ps1' -Because "у $($s.Name)"
        }
    }
    It 'кожен скіл життєвого циклу називає kit.ps1 повним шляхом через ${CLAUDE_PLUGIN_ROOT}' {
        foreach ($s in ($script:Skills | Where-Object { $_.Name -in @('onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify') })) {
            $s.Text | Should -Match '\$\{CLAUDE_PLUGIN_ROOT\}/tools/kit\.ps1' -Because "у $($s.Name)"
        }
    }

    Context 'onboarding' {
        It 'питає truth з чотирма варіантами й наслідками для git' {
            $t = Skill 'onboarding'
            foreach ($v in 'storage', 'dump', 'vendor', 'git') { $t | Should -Match "\*\*$v\*\*" }
            $t | Should -Match 'гітігноровано'
            $t | Should -Match 'мовчазного дефолту немає|Мовчазних дефолтів'
        }
        It 'шаблон v8project.yaml: база агента File=build/ib, name EXTENSION = ім’я розширення' {
            $t = Skill 'onboarding'
            $t | Should -Match "connection:\s*'File=build/ib'"
            $t | Should -Match '(?m)^\s*-\s*name:\s*<ІмʼяРозширення>'
        }
        It 'ставить хуки командою install-hooks, дописує -text і .gitignore під фактичні шляхи, перший коміт до -Apply' {
            $t = Skill 'onboarding'
            $t | Should -Match 'install-hooks'
            $t | Should -Match '<ws>/<path>/\*\* -text'
            $t | Should -Match 'перший коміт|Перший коміт'
            $t | Should -Match 'v8storagekit:migrate'
        }
    }
}
```

- [ ] **Step 2: Запустити — червоно** (`skills/onboarding` немає; старі скіли ще є — їхні
  frontmatter не пройдуть перевірку префіксів: це очікувано до Task 6; **тимчасово** можна
  запускати лише цей файл: `Invoke-Pester tools/tests/Skills.Tests.ps1`).

- [ ] **Step 3: `skills/onboarding/SKILL.md`**

````markdown
---
name: onboarding
description: Підключити до конвеєра «сховище ↔ git» репозиторій, новий воркспейс або нове джерело — записати маніфест v8storagekit.yaml (питаючи truth кожного джерела), v8project.yaml, політики git під фактичні шляхи, хуки, перший коміт; далі передати в sync і provision. Тригери — «підключи репозиторій», «підключи воркспейс», «додай джерело», «новий продукт у репо», «підключи клієнтську базу».
---

# onboarding — підключення репозиторію, воркспейсу або джерела

Скіл робить репозиторій видимим для kit: маніфест, воркспейси Уніки, політики git, хуки.
Він **питає** там, де kit не вгадує: `truth` кожного джерела, шлях і користувача сховища,
дев-базу для дампу. Мовчазних дефолтів для цих рішень немає. Скіл не мігрує старих
репозиторіїв (`storage.json`, gitsync/EDT) — це `v8storagekit:migrate`; не реплеїть сховище —
це `v8storagekit:sync`; не розгортає базу агента — це `v8storagekit:provision`.

Ланцюжок задачі: **onboarding** → sync → provision → (робота в Unica) → reconcile → finish → verify.
Усе — з кореня репозиторію-споживача.

## 1. Розвідка (лише читання)

1. Корінь: `git rev-parse --show-toplevel` збігається з поточною текою; інакше перейти в корінь.
2. Середовище: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/check-environment.ps1"` — усі
   рядки категорії «Конвеєр» мають бути `[+]` (PowerShell 7, git, платформа 8.3.27.x, модуль `powershell-yaml`).
3. Стан: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" check -RepoRoot .`
   - «Маніфест v8storagekit.yaml не знайдено» → **новий репозиторій** (розділ 2).
   - маніфест є → **додати воркспейс або джерело** (розділ 3); перший `[i]`-рядок показує, що вже підключено.
   - у підтеках лежить `storage.json`, або квартет `AUTHORS` + `VERSION` + `DT-INF/` + `ConfigDumpInfo.xml`
     разом — це старий репозиторій: зупинитись і запропонувати `v8storagekit:migrate`. Нічого не створювати.

## 2. Новий репозиторій

Спитати:
- **`product:` чи `client:`** і назву. `product` — рішення, що живе в кількох конфігураціях
  (кілька воркспейсів по одному розширенню); `client` — одна база клієнта з кількома розширеннями.
  Це метадані для назв артефактів і звітів; у логіці kit слів «клієнт»/«продукт» немає.
- **головна гілка**, якщо не `main` → `mainBranch:`.

Каркас із `${CLAUDE_PLUGIN_ROOT}/templates/` (відповідності — `${CLAUDE_PLUGIN_ROOT}/templates/README.md`):
`gitattributes` → `.gitattributes`, `gitignore` → `.gitignore`, `settings.json` → `.claude/settings.json`,
`CLAUDE.md` → `CLAUDE.md` (заповнити плейсхолдери), `AUTHORS.example` → `AUTHORS`,
`v8storagekit.yaml.example` → `v8storagekit.yaml` (переписати за відповідями нижче),
`v8storagekit.local.yaml.example` → `v8storagekit.local.yaml` (гітігнорований, лише локальне).
Далі — розділ 3 для кожного воркспейсу.

## 3. Воркспейс і його джерела

### 3.1 Тека воркспейсу

Ім'я теки = ім'я воркспейсу. Для воркспейсу з одним розширенням — ім'я розширення в 1С; для
клієнтської бази — ім'я бази/клієнта. Тека — безпосередньо в корені репозиторію. Якщо ім'я не
ASCII — сказати вголос: кириличні теки й імена розширень — прийнятий ризик, не пройдений
конвеєром до кінця (`${CLAUDE_PLUGIN_ROOT}/docs/follow-ups.md` §10).

### 3.2 `v8project.yaml`

Якщо файлу немає — створити (розкладка `<тип>/src`; для кількох розширень — `cfe/<Імʼя>/src`):

```yaml
format: DESIGNER
builder: DESIGNER
workPath: 'build'
execution_timeout: 600000
infobase:
  connection: 'File=build/ib'          # база АГЕНТА: машинна, похідна від git; kit сюди не пише, наповнює operation=build
source-set:
  - name: base
    type: CONFIGURATION
    path: 'cf/src'
  - name: <ІмʼяРозширення>              # = <Name> у cfe/…/Configuration.xml = ключ у sources: маніфесту
    type: EXTENSION
    path: 'cfe/src'
```

Воркспейс зовнішніх обробок — один source-set `type: EXTERNAL_DATA_PROCESSORS`, `path: 'src'`,
без `infobase:`. `name:` EXTENSION мусить дорівнювати імені розширення: v8-runner виводить
ім'я з source-set (`${CLAUDE_PLUGIN_ROOT}/docs/unica-contract.md`, B5–B6).

### 3.3 Питання `truth` — для кожного source-set, завжди

Мовчазного дефолту немає: відрізнити «наша конфігурація під сховищем» від «чужа, беремо
дампом» може лише людина. Варіанти й наслідки — дослівно:

- **storage** — істина у сховищі конфігурацій. У git з історією, гілка `storage/<ключ>`, наповнює
  `sync`. Наше розширення, або конфігурація клієнта, яку ведуть під сховищем.
- **dump** — істина в живій базі, лише поточний стан. У git без історії, наповнює `dump`; гілки немає.
- **vendor** — чужа конфігурація. У git **не потрапляє** (гітігноровано), локально — дамп для
  операцій Unica; гілки немає.
- **git** — зовнішнього джерела немає; пишуть люди й агент (зовнішні обробки).

Далі за відповіддю:
- `storage` → шлях сховища (`R:\СховищаРозширень_1С\…` або `R:\СховищаКонфігурацій_1С\…`) і
  користувач сховища (типово `gitbot`, пароль порожній; для спільного сховища в клієнтському репо —
  користувач за іменем бази). Ключ джерела = `name:`; для `truth: storage` ключі **унікальні в
  репозиторії** — при збігу перейменувати source-set (гілка `storage/<ключ>` одна).
- `dump` / `vendor` → ключ дев-бази для `dump: { from: <ключ> }` і для накладки: рядок підключення
  (`Srvr="…";Ref="…";` або `File="…"`) та користувач → `v8storagekit.local.yaml`, розділ
  `infobases:`. Kit із цієї бази лише читає.

Записати у `v8storagekit.yaml` (форма — `${CLAUDE_PLUGIN_ROOT}/templates/v8storagekit.yaml.example`).

### 3.4 Політики git під фактичні шляхи

Не покладатись на шаблонні `**/cfe/src/**`: дописати рядки з шляхів `v8project.yaml`:
- `.gitattributes`, після `* text=auto`: для **кожного** source-set — `<ws>/<path>/** -text`;
- `.gitignore`: для кожного `truth: vendor` — `<ws>/<path>/**`; поруч створити `<ws>/cf/README.md`
  з одним рядком «Базова конфігурація вивантажується локально (kit dump), у git не потрапляє».
Перевіряє `check` через `git check-attr` / `git check-ignore`.

### 3.5 Хуки й перевірка

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" install-hooks -RepoRoot . -Apply
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" check -RepoRoot .
```

`install-hooks` кладе `.githooks/` + `core.hooksPath`, шим `.claude/hooks/session-start.ps1` і
`.claude/settings.json` (якщо ще немає), і **стейджить хуки з режимом 100755** — інакше клон на
Linux/macOS дістав би їх без біта виконання, і git мовчки їх ігнорував би. `check` має завершитись
без `[-]`; `[!]` про недоступне сховище чи відсутню накладку — прийнятно, але назвати людині.
Приймальна перевірка: `git ls-files -s .githooks/` → `100755` для обох файлів.

### 3.6 Перший коміт — окремо, до будь-якого `-Apply`

```bash
git add v8storagekit.yaml <ws>/v8project.yaml <ws>/cf/README.md .gitattributes .gitignore .claude AUTHORS CLAUDE.md
git commit -m "onboarding: <ws> — маніфест, воркспейс Уніки, політики git, хуки"
# .githooks уже застейджено install-hooks з режимом 100755 — не перестейджувати через `git add -A` без потреби:
# сам `git add` режим не змінює, але `git ls-files -s .githooks/` після коміту має показати 100755.
```

Накладку `v8storagekit.local.yaml` не комітити — вона гітігнорована навмисно.

Приймальна перевірка одразу після коміту (вікно «хуки є на диску, але не в git» має закритись тут, і саме тому
коміт іде **до** будь-якого `-Apply`): `git ls-files -s .githooks/` → два рядки `100755`;
`kit check` — без `[-]` і без `[!]` про хуки.

## 4. Далі

- `v8storagekit:sync` — перший реплей джерел `truth: storage` (прев'ю, потім `-Apply` лише на
  прохання). Перше злиття в головну гілку робить сам `sync`. Зупинка на невідомих авторах — штатна:
  людина доповнює `AUTHORS`.
- `v8storagekit:provision` — база агента (питає тип: порожня / з `.dt` / серверна).
- Хук старту сесії почне показувати «Стан сховищ» з наступної сесії.

## 5. Штатні зупинки

- `Маніфест … — невідомий ключ '…'. Дозволені: …` — помилка у YAML; звірити з прикладом у `templates/`.
- `Джерело '…' … не відповідає жодному name: source-set` — ключ у `sources:` ≠ `name:` у `v8project.yaml`.
- `check`: `[-] … -text` або `[-] … .gitignore` — розділ 3.4 не завершено.
- `Ключ '…' з truth: storage повторюється у воркспейсах …` — перейменувати source-set в одному з них.
- `core.hooksPath не вказує на .githooks` — `install-hooks -Apply` не виконано.

## 6. Межі

Сховище й база людини — тільки читання. `-Apply` — лише на явне прохання. Нічого не пушити.
`truth` і тип бази агента не вгадувати — питати.
````

- [ ] **Step 4: Запустити `Skills.Tests.ps1` (лише цей файл до Task 6); перевірка `${CLAUDE_PLUGIN_ROOT}`; коміт**

```bash
git add skills/onboarding/SKILL.md tools/tests/Skills.Tests.ps1
git commit -m "B5: скіл onboarding — маніфест з питанням truth, політики git під фактичні шляхи, хуки, перший коміт"
```

---

### Task 3: скіли `sync`, `dump`, `verify`

**Files:**
- Create: `skills/sync/SKILL.md`, `skills/dump/SKILL.md`, `skills/verify/SKILL.md`
- Modify: `tools/tests/Skills.Tests.ps1` — три `Context`

- [ ] **Step 1: Guard-тести** (додати в `Skills.Tests.ps1`)

```powershell
    Context 'sync' {
        It 'session-check → прев’ю → -Apply лише на прохання; -MaxVersions; зупинки sync' {
            $t = Skill 'sync'
            $t | Should -Match 'session-check'
            $t | Should -Match 'kit\.ps1" sync -RepoRoot \.'
            $t | Should -Match '-MaxVersions'
            $t | Should -Match 'Невідомі автори'
            $t | Should -Match '-MergeMain'
            $t | Should -Match 'піднімає платформу|запускає платформу'
        }
    }
    Context 'dump' {
        It 'попереджає про Конфігуратор і тривалість; dump лише для dump/vendor' {
            $t = Skill 'dump'
            $t | Should -Match '20.40 хвилин'
            $t | Should -Match 'Конфігуратор'
            $t | Should -Match 'truth: dump|truth: vendor'
            $t | Should -Match 'infobases:'
        }
    }
    Context 'verify' {
        It 'чотири вердикти, лише CR → text-policy, звірочний коміт лише з -Apply' {
            $t = Skill 'verify'
            foreach ($v in 'equal', 'ref-ahead', 'storage-ahead', 'mixed') { $t | Should -Match $v }
            $t | Should -Match 'text-policy'
            $t | Should -Match '-Apply'
            $t | Should -Match 'merge-base'
        }
    }
```

- [ ] **Step 2: `skills/sync/SKILL.md`**

````markdown
---
name: sync
description: Перенести нові версії сховищ конфігурацій 1С у git — дзеркала storage/<джерело> через kit sync, з першим злиттям у головну гілку. Тригери — «є нові версії», «перенеси зі сховища», «синхронізуй сховище», «оновити дзеркало», «storage sync».
---

# sync — нові версії сховища → гілки `storage/*`

Сховище — істина; `storage/<джерело>` — його дзеркало в git, яке пише **лише** `kit sync`
(один коміт на версію, автор і дата зі звіту сховища через `AUTHORS`). У головну гілку
реплей не йде: перше злиття робить `sync`, наступні — звірочні коміти `v8storagekit:verify`
або злиття в гілку задачі у `v8storagekit:reconcile`.

Ланцюжок: onboarding → **sync** → provision → (робота в Unica) → reconcile → finish → verify.

## 1. Що є і що нового

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" session-check -RepoRoot .
```

Без платформи: по рядку на джерело `truth: storage` — «ймовірно нові версії» / «не злиті в
main» / «дзеркала ще немає» / «недоступне». Якщо джерел кілька і людина назвала одне —
далі працювати з `-Source <ключ>` (без `-Workspace`, якщо ключ унікальний; інакше `kit`
попросить `-Workspace`).

## 2. Прев'ю

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" sync -RepoRoot . [-Source <ключ>] [-MaxVersions <N>]
```

Це **не** безкоштовно: команда піднімає тимчасову ІБ у `build/sync/<ключ>/` і запускає
платформу, щоб прочитати звіт сховища (хвилина-дві, одна ліцензія). Нічого в git не змінює.
Показує: дзеркало на версії N, у сховищі M версій, перелік до перенесення (номер, дата,
автор, тема). `-MaxVersions` — для довгого хвоста (перший реплей великого сховища).

## 3. Виконання — лише на явне прохання

Дієслово-наказ («перенеси», «синхронізуй», «так, оновлюй») або підтвердження після прев'ю:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" sync -RepoRoot . [-Source <ключ>] [-MaxVersions <N>] -Apply
```

Що відбувається: worktree гілки `storage/<ключ>` під `build/sync/<ключ>/wt`, для кожної версії
`UpdateCfg -v N` → `DumpConfigToFiles` → коміт із трейлерами `Storage-Source/Storage-Version/
Extension-Version|Config-Version/Storage-User`; робоча копія й поточна гілка людини не
торкаються. Якщо гілки не було — після реплею **перше злиття** в головну гілку
(`--allow-unrelated-histories`). Якщо HEAD на головній гілці й копія брудна — злиття не
робиться, `sync` каже повторити `-MergeMain` після коміту/stash.

Після: показати людині рядок «Перенесено версій: N → storage/…» і, якщо було злиття, — його
коміт. Далі за потреби — `v8storagekit:verify`.

## 4. Штатні зупинки (не помилки скіла — розбір за людиною)

- `Каталог сховища не знайдено: …` — шлях не існує на цій машині: перевизначити в
  `v8storagekit.local.yaml` під `storages: <ключ>`.
- `Невідомі автори — додайте їх у AUTHORS` — список готовий до вставки; хто ці люди, знає лише
  власник. Мовчазна підстановка зіпсувала б авторство десятків комітів.
- `Дзеркало попереду сховища: … версія N, а у сховищі максимум M` — сховище відкотили або
  дзеркало писали не sync; `kit check` покаже інваріанти гілки.
- `Звіт сховища порожній (жодної версії), а дзеркало вже тримає версію N` — сховище недоступне
  або звіт пошкоджено.
- `Гілка storage/… вибрана в основній робочій копії` — перейти на іншу гілку й повторити.
- `Синхронізацію зупинено через невідомих авторів.` / підрядки `лиценз`, `ліценз`, `license`,
  `HASP` у виводі — зупинитись і доповісти; не чіпати служби, реєстр, `nethasp.ini`.

## 5. Межі

Сховище — тільки читання (`Report`, `UpdateCfg`; жодних `Commit/Lock/Unlock`). `-Apply` — лише на
прохання. У `storage/*` руками не комітити — хук відмовить. Нічого не пушити.
````

- [ ] **Step 3: `skills/dump/SKILL.md`**

````markdown
---
name: dump
description: Вивантажити поточний стан конфігурації або розширення з живої бази людини в дерево джерела з truth dump або vendor — kit dump за накладкою v8storagekit.local.yaml. Тригери — «вивантаж конфігурацію з бази», «онови cf/src», «дамп базової конфігурації», «вивантаж з дев-бази».
---

# dump — жива база людини → дерево джерела (лише читання бази)

Kit із бази людини лише **читає**, і лише на явне прохання. Куди — каже `v8project.yaml`
(шлях source-set); з якої бази — `dump: { from: <ключ> }` у маніфесті плюс `infobases:` у
`v8storagekit.local.yaml`. Джерела `truth: storage` не дампляться (для них `v8storagekit:sync`),
`truth: git` — не мають зовнішнього джерела.

## 1. Прев'ю

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" dump -RepoRoot . [-Source <ключ>]
```

Без платформи: база (`/F` або `/S`), користувач, ціль. Перед `-Apply` сказати людині:
- вивантаження конфігурації триває **20–40 хвилин** і займає 1–2 ГБ;
- база має бути **закрита в Конфігураторі** (монопольне захоплення); файли `.cfl` індикатором не є;
- ціль буде очищена й переписана; `truth: vendor` у git не потрапляє (гітігноровано), `truth: dump` —
  потрапляє без історії: коміт робить людина або агент у гілці задачі, на прохання.

## 2. Виконання — лише на явне прохання

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" dump -RepoRoot . -Source <ключ> -Apply
```

Після: кількість файлів; для `truth: dump` — запропонувати коміт у поточну гілку задачі.

## 3. Штатні зупинки

- `Дев-базу '…' не описано в v8storagekit.local.yaml під infobases:` — команда друкує готовий
  блок для вставки; підключення й користувача знає людина.
- `База '…' зайнята — її відкрито Конфігуратором…` — закрити Конфігуратор (для серверної — `rac
  session list`, якщо піднято `ras`) і повторити. Це порада kit, не сире повідомлення платформи.
- `Джерело '…' має truth: storage — dump працює лише з truth: dump або vendor` — потрібен `v8storagekit:sync`.
- Підрядки `лиценз`, `ліценз`, `license`, `HASP` — зупинка й доповідь.

## 4. Межі

База людини — тільки читання. Пароль kit не зберігає. `-Apply` — лише на прохання.
````

- [ ] **Step 4: `skills/verify/SKILL.md`**

````markdown
---
name: verify
description: Звірити дерево гілки (типово головної) зі сховищем — kit verify порівнює його з канонічним дампом сховища на злитій версії й класифікує розбіжності; з -Apply робить звірочний коміт. Тригери — «звір git зі сховищем», «чи все застосовано у сховищі», «main ≡ сховище?», «звірочний коміт», «verify».
---

# verify — інваріант «ref ≡ сховище»

Джерело порівняння незалежне: **дамп зі сховища** на версії, яку `<ref>` уже злив
(`git merge-base <ref> storage/X`), а не власна робоча копія — інакше платформі годували б те,
що вона сама й перевіряє. Дерево `<ref>` береться сирими блобами git, без конверсії.

## 1. Запуск

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" verify -RepoRoot . [-Ref <гілка>] [-Source <ключ>]
```

Без `-Ref` — головна гілка маніфесту. `-Ref storage/<ключ>` — канонічність самого дзеркала.
Команда піднімає платформу (тимчасова ІБ у `build/verify/<ключ>/`), у git нічого не змінює.

## 2. Як читати результат

Побайтово рівних N із M, далі списки: **лише CR** (зіпсована політика тексту —
`${CLAUDE_PLUGIN_ROOT}/docs/text-policy.md`, у git конвертували те, що не мали), **змістовні**
(git розійшовся зі сховищем; `binary` — лише побайтово), **тільки в дампі**, **тільки в
дереві**. `ConfigDumpInfo.xml` не рахується.

| Вердикт | Означає | Дія |
|---|---|---|
| `equal` | `<ref>` ≡ сховище на злитій версії | нічого |
| `ref-ahead` | у `<ref>` є робота, якої немає у сховищі | зібрати артефакт (`v8storagekit:finish` / `kit build`, `operation=make`) і **застосувати залишок у сховищі** — це робить людина в Конфігураторі |
| `storage-ahead` | у сховищі є версії повз `<ref>` (на дзеркалі коміти після merge-base) | звірочний коміт: `verify -Apply` |
| `mixed` | і те, і те | спершу `verify -Apply`, потім розбір залишку |

Код завершення 0 — `equal`; 3 — є що робити.

## 3. Звірочний коміт — лише на явне прохання

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" verify -RepoRoot . [-Ref <гілка>] -Apply
```

Зливає `storage/<ключ>` у `<ref>` (`--no-ff`): якщо `<ref>` вибраний і копія чиста — на місці;
брудна — зупинка; інший HEAD — через тимчасовий worktree. Конфлікт — злиття відкочено,
команда для ручного розбору в тексті зупинки.

## 4. Штатні зупинки

- `Гілки storage/… ще немає — дзеркало не створене. Спершу: kit sync.`
- `'…' ніколи не зливав storage/… — спільного предка немає. Спершу: kit sync` — перше злиття ще не було.
- `Гілка '…' вибрана, але робоча копія не чиста — у брудний … не зливаємо` — коміт/stash і повторити.
- `Злиття … не вдалося (конфлікт …) … git merge storage/…` — розв'язати вручну.
- `лиценз`/`ліценз`/`license`/`HASP` — зупинка й доповідь.

## 5. Межі

Сховище — тільки читання. Без `-Apply` git не змінюється. Нічого не пушити.
````

- [ ] **Step 5: `Skills.Tests.ps1` зелений (лише цей файл до Task 6); коміт**

```bash
git add skills/sync skills/dump skills/verify tools/tests/Skills.Tests.ps1
git commit -m "B5: скіли sync, dump, verify"
```

---

### Task 4: скіл `provision`

**Files:**
- Create: `skills/provision/SKILL.md`
- Modify: `tools/tests/Skills.Tests.ps1` — `Context 'provision'`

- [ ] **Step 1: Guard-тест**

```powershell
    Context 'provision' {
        It 'питає тип бази трьома варіантами й записує вибір у накладку; серверна — поза межами' {
            $t = Skill 'provision'
            $t | Should -Match '\*\*порожня\*\*'
            $t | Should -Match '\*\*з `?\.dt`?\*\*|\*\*з \.dt\*\*'
            $t | Should -Match '\*\*серверна\*\*'
            $t | Should -Match '-Remember'
            $t | Should -Match 'operation=build'
            $t | Should -Match 'v8project\.local\.yaml'
        }
    }
```

- [ ] **Step 2: `skills/provision/SKILL.md`**

````markdown
---
name: provision
description: Розгорнути або перестворити базу агента воркспейсу — порожню, з .dt або серверну — через kit provision, з питанням про тип бази й записом вибору в v8storagekit.local.yaml; далі наповнити її operation=build Уніки. Тригери — «розгорни базу», «перезбери базу агента», «створи базу для агента», «база агента зламана».
---

# provision — база агента

База агента оголошена в закоміченому `v8project.yaml` (`infobase.connection: 'File=build/ib'`)
або перевизначена на серверну у `v8project.local.yaml`. Її можна знести й розгорнути знову
будь-коли: у ній немає нічого, чого немає в git і сховищі. Kit **ніколи** не цілиться в базу
людини: якщо підключення бази агента збігається з дев-базою з накладки — команда зупиняється.

Ланцюжок: onboarding → sync → **provision** → (робота в Unica) → reconcile → finish → verify.

## 1. Який тип бази — питати, якщо не визначено

Прев'ю показує, що відомо:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" provision -RepoRoot . [-Workspace <ws>]
```

Тип визначений, якщо: у `v8storagekit.local.yaml` є `workspaces.<ws>.agentBase.template`
(база з `.dt`), або у `v8project.local.yaml` воркспейсу є `infobase.connection: 'Srvr=…'`
(серверна). Інакше **спитати** (AskUserQuestion, варіанти дослівно; мовчазного дефолту немає):

- **порожня** — файлова база під `<ws>/build/ib` без даних; далі `operation=build` Уніки накотить
  джерела. Найшвидше; годиться для розширень без залежності від даних.
- **з `.dt`** — файлова база з вивантаження (демо-база, копія робочої без персональних даних):
  людина називає шлях до файлу. Потрібна, коли тести чи форми залежать від даних.
- **серверна** — людина створює базу в кластері й дає підключення; kit її не створює (розгортання
  з `.dt` на сервері — окремий спайк). Вибір записується у `v8project.local.yaml` воркспейсу як
  `infobase: { connection: 'Srvr="…";Ref="…";' }` — це файл Уніки, і це єдине, що в ньому може бути.

## 2. Виконання — лише на явне прохання

Порожня:
```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" provision -RepoRoot . -Workspace <ws> -Apply
```
З `.dt` (і запам'ятати вибір у накладці kit):
```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" provision -RepoRoot . -Workspace <ws> -Apply -Template "<шлях>.dt" -Remember
```
Перестворити наявну — додати `-Force` (база агента стирається; це дозволено, у ній нічого свого).

Після: **наповнити базу** — `operation=build` Уніки (застосовна операція, `dryRun:false`, названий
ризик `runtime_risk_critical_non_abortable`) із `cwd` = тека воркспейсу. Kit цього не робить.

## 3. Штатні зупинки

- `База агента вже є: … Перестворити з нуля — … -Apply -Force` — без `-Force` не чіпаємо.
- `База агента воркспейсу '…' збігається з дев-базою людини '…'` — у `v8project.local.yaml` лежить
  підключення до бази людини; прибрати його або дати агентові окрему базу. Kit не пише в базу людини.
- `База агента … серверна (Srvr=). Kit її не створює` — створити в кластері вручну; далі `operation=init/build`.
- `Шаблон бази (.dt) не знайдено: …` — перевірити шлях.
- `Параметр -Remember потребує -Template` — нічого запам'ятовувати.

## 4. Межі

Лише база агента. `-Force` стирає її без питань — але лише з `-Apply`. Серверна база з `.dt` — не робиться.
````

- [ ] **Step 3: Тест зелений; коміт**

```bash
git add skills/provision tools/tests/Skills.Tests.ps1
git commit -m "B5: скіл provision — тип бази агента питається, вибір записується в накладку"
```

---

### Task 5: скіли `reconcile` і `finish` (§8, п. 5–6)

**Files:**
- Create: `skills/reconcile/SKILL.md`, `skills/finish/SKILL.md`
- Modify: `tools/tests/Skills.Tests.ps1` — два `Context`

- [ ] **Step 1: Guard-тести**

```powershell
    Context 'reconcile' {
        It 'sync → operation=build → canon → merge storage/* у гілку задачі → семантичний diff' {
            $t = Skill 'reconcile'
            $t | Should -Match 'kit\.ps1" sync'
            $t | Should -Match 'operation=build'
            $t | Should -Match 'kit\.ps1" canon'
            $t | Should -Match 'git merge --no-ff storage/'
            $t | Should -Match 'git diff'
            $t | Should -Not -Match 'rebase'
        }
    }
    Context 'finish' {
        It 'sync → canon → merge → verify → тести Unica → артефакти → PR; push і PR лише з дозволу' {
            $t = Skill 'finish'
            foreach ($m in 'kit\.ps1" sync', 'kit\.ps1" canon', 'kit\.ps1" verify', 'kit\.ps1" build', 'operation=test', 'operation=syntax', 'operation=make', 'gh pr create', 'build/artifacts') { $t | Should -Match $m }
            $t | Should -Match 'лише за явним проханням|лише на явне прохання'
            # R3: гейт «повідомити користувача» перед PR при суттєвих змінах зі сховища
            $t | Should -Match 'суттєв'
            $t | Should -Match 'ORIG_HEAD'
        }
    }
```

- [ ] **Step 2: `skills/reconcile/SKILL.md`**

````markdown
---
name: reconcile
description: Звести гілку задачі агента зі сховищем після того, як людина перенесла частину роботи в сховище — kit sync, канонізація дерева агента, злиття storage/* у гілку задачі, семантичний diff «що поглинуло сховище, що лишилось». Тригери — «я поклав частину в сховище», «я закомітив у сховище», «звір мою гілку зі сховищем», «reconcile».
---

# reconcile — людина перенесла частину роботи в сховище

Історія гілки задачі `F` лишається цілою: не rebase, не re-derive — **merge** дзеркала. Після
канонізації обидва боки в форматі платформи, тож конфлікти семантичні, і їх розв'язує агент.
Скільки завгодно раундів.

Ланцюжок: onboarding → sync → provision → (робота в Unica) → **reconcile** → finish → verify.

## 1. Передумови

- Поточна гілка — гілка задачі `F` (не головна, не `storage/*`): `git branch --show-current`.
- Робоча копія чиста або зміни закомічені в `F` (`git status --porcelain`).
- Людина сказала, які джерела торкнула (або всі `truth: storage` воркспейсу).

## 2. Кроки

1. **Нові версії зі сховища → дзеркало** (прев'ю, потім `-Apply` на прохання людини — вона щойно
   сама туди комітила, це і є прохання):
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" sync -RepoRoot . -Source <ключ> -Apply
   ```
2. **База агента — з поточного дерева `F`**: `operation=build` Уніки (`cwd` = воркспейс). Без цього
   `canon` вивантажить стару базу.
3. **Канонізація дерева агента**:
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" canon -RepoRoot . -Source <ключ> -Apply
   ```
   Якщо `canon` змінив файли — закомітити в `F`: `git commit -am "canon: дерево у форматі платформи"`.
4. **Злиття дзеркала в `F`** (у робочій копії, на поточній гілці):
   ```
   git merge --no-ff storage/<ключ> -m "reconcile: storage/<ключ> → <F>"
   ```
   Конфлікти — розв'язати семантично (Unica: `code.patch`, `form.edit`, потім знову
   `operation=build` → `canon`), завершити коміт злиття.
5. **Семантичний diff — що лишилось у `F` поза сховищем**:
   ```
   git diff --stat storage/<ключ> -- <ws>/<path>
   git diff storage/<ключ> -- <ws>/<path>
   ```
   Звіт людині: **що поглинуло сховище** (файли, які злиття зробило рівними) і **що лишилось**
   (файли в diff — залишок, який ще треба застосувати в сховищі). Порожній diff — усе в сховищі.

## 3. Штатні зупинки

- `sync`: див. `v8storagekit:sync` (невідомі автори, недоступне сховище).
- `canon`: `Бази агента ще немає … kit provision` — спершу `v8storagekit:provision`; `збігається з
  дев-базою людини` — kit не пише в базу людини.
- `git merge`: конфлікт — це нормально; не робити `--abort` мовчки, розв'язувати.
- Хук `pre-merge-commit` відмовляє — значить HEAD на `storage/*`: повернутись на `F`.

## 4. Межі

Сховище — тільки читання; реплей — лише через `sync`. У головну гілку тут не зливаємо
(звірочні коміти — `v8storagekit:verify`). Нічого не пушити.
````

- [ ] **Step 3: `skills/finish/SKILL.md`**

````markdown
---
name: finish
description: Закрити задачу агента — синхронізувати сховище, канонізувати дерево, злити дзеркало в гілку задачі, звірити її зі сховищем, прогнати тести й синтаксис Unica, зібрати артефакти, підготувати PR у головну гілку. Тригери — «закриваємо задачу», «готуй PR», «фінішуємо», «здай роботу», «finish».
---

# finish — закриття задачі: PR завжди повний

Головна гілка не отримувала роботи агента через реплей, тому PR `F → main` завжди несе всю
роботу. Артефакти в `build/artifacts/` застосовує людина у своїй базі; повідомити їх у PR.

Ланцюжок: onboarding → sync → provision → (робота в Unica) → reconcile → **finish** → verify.

## 1. Передумови

Поточна гілка — `F`; копія чиста; база агента є й наповнена (`operation=build` після останніх правок).

## 2. Кроки

1. **Сховище → дзеркало**: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" sync -RepoRoot . -Apply`
   (`-Apply` — після прев'ю й згоди; прохання «готуй PR» це включає, якщо людина не сказала інакше).
2. **Канонізація**: `operation=build` (Unica) → `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" canon -RepoRoot . -Apply`;
   зміни — комітом у `F`.
3. **Злиття дзеркал у `F`**: для кожного `truth: storage` воркспейсу — `git merge --no-ff storage/<ключ>`
   (як у `v8storagekit:reconcile`, розділ 2.4–2.5).
4. **Звірка `F` зі сховищем**: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" verify -RepoRoot . -Ref <F>`.
   Очікувано `ref-ahead` (робота задачі — це й є залишок для сховища) або `equal`; `storage-ahead`/`mixed`
   означає, що крок 3 не завершено.

   **Гейт «повідомити користувача» — зупинка перед кроком 5, якщо сталося суттєве** (вимога власника №13:
   звірити сховища, подивитись, що помінялось, при суттєвому — повідомити, далі за його рішенням).
   Суттєве — хоч одне з: (а) крок 1 приніс у дзеркало ≥1 нову версію (хтось комітив у сховище під час
   задачі); (б) злиття на кроці 3 мало конфлікти; (в) `verify` дав `storage-ahead` або `mixed`. Тоді
   **зупинитись** і доповісти: які версії й чиї (з виводу `sync`), що змінило злиття
   (`git diff --stat ORIG_HEAD..HEAD -- <ws>/<path>` одразу після merge), вердикт `verify`. Продовжувати
   до тестів і PR — лише за рішенням людини. Нічого суттєвого — йти далі без питання.
5. **Тести й синтаксис** (Unica, `cwd` = воркспейс): `operation=syntax`, потім `operation=test`
   (`testRunner=yaxunit` або `va`). Червоне — PR не готувати; повернутись до роботи.
6. **Артефакти**: `.cfe`/`.cf` — `operation=make` Уніки з `output=<корінь репо>/build/artifacts/<Ім'я>.cfe`
   (якщо Unica відмовить у шляху поза воркспейсом — `output=<воркспейс>/build/artifacts/<Ім'я>.cfe`);
   `.epf` і збір — `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/tools/kit.ps1" build -RepoRoot . -Apply`.
   `build/` гітігнорований: артефакти не комітяться, їхній перелік іде в PR.
7. **PR `F → <mainBranch>`** — **лише за явним проханням** і через запит дозволу harness (`git push`,
   `gh pr create` у `ask`). Тіло PR:
   ```
   ## Що зроблено
   <з коментарів комітів F>
   ## Сховище
   Дзеркала злиті: storage/<ключ> до версії <N> (verify -Ref <F>: <вердикт>)
   ## Артефакти для застосування (build/artifacts/)
   - <Ім'я>.cfe  — застосувати в базі <…> Конфігуратором
   ## Тести
   operation=test: <результат>; operation=syntax: <результат>
   ```
8. **Після злиття PR** (наступна сесія або на прохання): `v8storagekit:verify` на головній гілці —
   `equal` / `ref-ahead` (застосуйте залишок) / `storage-ahead` (звірочний коміт).

## 3. Штатні зупинки

`sync`, `canon`, `verify`, `build` — зупинки їхніх скілів. Червоні тести Unica — зупинка: PR не
готувати, доповісти. `gh pr create` відхилено класифікатором дозволів — сказати людині, не
шукати обхід.

## 4. Межі

Артефакти застосовує людина. `git push` і PR — лише за явним проханням. Сховище — тільки читання.
````

- [ ] **Step 4: Тести зелені (лише `Skills.Tests.ps1` до Task 6); коміт**

```bash
git add skills/reconcile skills/finish tools/tests/Skills.Tests.ps1
git commit -m "B5: скіли reconcile і finish — життєвий цикл задачі агента"
```

---

### Task 6: вилучення старих скілів, довідка про legacy-міграцію, `templates/CLAUDE.md` і `templates/README.md`

**Files:**
- Delete: `skills/storage-pipeline/`, `skills/product-onboarding/`, `skills/repo-migration/`
- Create: `docs/migration/legacy-gitsync-repo.md`
- Rewrite: `templates/CLAUDE.md`, `templates/README.md`
- Modify: `tools/tests/Templates.Tests.ps1`

- [ ] **Step 1: Зберегти знання зі `repo-migration` як довідку**

`docs/migration/legacy-gitsync-repo.md` — вміст `skills/repo-migration/SKILL.md` без frontmatter,
із шапкою:

```markdown
# Довідка: старий gitsync/EDT-репозиторій → v8storagekit

> Не скіл. Текст колишнього `repo-migration` (0.6.0) збережено як довідку: процедура розвідки,
> проби доступності сховища, страхувального bundle, конвертації EDT → Designer XML і чистої
> гілки чинна, але **кінцевий стан тепер інший** — маніфест `v8storagekit.yaml` і гілки
> `storage/*` (спека 2026-09-03, `v8storagekit:migrate`), а не `storage.json`. Розділи 7–8 про
> каркас і `storage.json` читати як історію. Потрібна для рішення по `SMP_OnlineExchange`
> (кирилична тека, EDT-вихідники) — спека §13.
```

Усі згадки `${CLAUDE_PLUGIN_ROOT}` у довідці замінити на «тека плагіна» (це не скіл, підстановки
немає — але й заплутувати не треба); команди `storage-sync.ps1`/`product-onboarding` — на
`kit.ps1 sync`/`v8storagekit:onboarding` з позначкою «(тепер)».

```bash
git rm -rq skills/storage-pipeline skills/product-onboarding skills/repo-migration
```

- [ ] **Step 2: `templates/CLAUDE.md` — переписати цілком**

```markdown
# <ІмʼяРепозиторію> — інструкції проєкту

<Один абзац: що це за рішення або клієнтська база, для яких конфігурацій.>

Репозиторій працює під плагіном Claude Code `v8storagekit`
(https://github.com/VSydorenko/SMP_V8StorageKit): сховища конфігурацій 1С — істина, git —
робоче середовище агента, Unica — основний інструмент. На старті сесії хук показує «Стан
сховищ» і вступ `using-v8storagekit`; далі — скіли по одному на намір.

## Структура

| Що | Де |
|---|---|
| Маніфест kit: воркспейси, джерела, `truth`, сховища | `v8storagekit.yaml` (корінь) |
| Локальне цієї машини: дев-бази, шляхи сховищ, шаблон `.dt` бази агента | `v8storagekit.local.yaml` (гітігнорований) |
| Воркспейс Уніки: source-set-и, база агента `File=build/ib` | `<Воркспейс>/v8project.yaml` |
| Серверна база агента (єдине, що тут може бути) | `<Воркспейс>/v8project.local.yaml` (гітігнорований, файл Уніки) |
| Вихідники платформи | `<Воркспейс>/<тип>/src` — шляхи з `v8project.yaml`; `truth: vendor` у git не потрапляє |
| Дзеркала сховищ | гілки `storage/<джерело>` — пише лише `kit sync` |
| Артефакти для людини | `build/artifacts/` (гітігноровано) |
| Мапа «користувач сховища → git-автор» | `AUTHORS` |

Воркспейси й джерела: `pwsh -NoProfile -File "<корінь плагіна>/tools/kit.ps1" check -RepoRoot .`
(перший рядок `[i]`). Корінь плагіна показує `claude plugin list`.

## Гілки

`<mainBranch>` — історія проєкту: злиття PR-ів і звірочні коміти. `storage/<джерело>` — дзеркало
сховища, лише дописується. `feature/<задача>` — гілка агента від головної; злиття дзеркала в
неї — `v8storagekit:reconcile`; PR — `v8storagekit:finish`. Реплей у головну гілку не йде.

## Наміри → скіли

| Намір | Скіл |
|---|---|
| нові версії у сховищі → git | `v8storagekit:sync` |
| вивантажити з бази людини (`truth: dump`/`vendor`) | `v8storagekit:dump` |
| людина перенесла частину в сховище | `v8storagekit:reconcile` |
| закрити задачу, PR | `v8storagekit:finish` |
| база агента | `v8storagekit:provision` |
| звірити git зі сховищем | `v8storagekit:verify` |
| додати воркспейс/джерело | `v8storagekit:onboarding` |

Редагування метаданих, форм, СКД, ролей; валідація; `operation=build/make/test/syntax` — Unica.

## Межі

- **Формат вихідників — Designer platform XML; платформа — гілка 8.3.27.x.**
- **Репозиторій може бути публічним.** Секрети й локальні шляхи — лише у гітігнорованих
  `v8storagekit.local.yaml` і `v8project.local.yaml`. `File=build/ib` у `v8project.yaml` — не
  секрет: відносний і однаковий у кожному клоні. Шлях сховища у маніфесті — свідомий виняток.
- **`truth: vendor` ніколи не комітиться** — код вендора.
- **Сховища — тільки читання.** Запис у сховище виконує людина в Конфігураторі. Гілки `storage/*`
  руками не редагуються — хук відмовить.
- **Агент працює у своїй базі й ніколи не пише в базу людини.** Базу людини kit лише читає
  (`dump`), і лише на явне прохання.
- **`-Apply` — лише на явне прохання.** `sync`, `verify`, `dump` без `-Apply` усе одно піднімають
  платформу (хвилина-дві, ліцензія) — але нічого не змінюють.
- **Ліцензія 1С.** Підрядки `лиценз`, `ліценз`, `license`, `HASP` у виводі платформи — зупинка й
  доповідь; служби, реєстр, `nethasp.ini` не чіпати.
- **`git push`, `gh pr create` — лише за явним проханням** (у `.claude/settings.json` — `ask`).

## Дозволи

`.claude/settings.json` дозволяє без запиту лише читання git і читальні інструменти Unica;
хук `SessionStart` запускає `.claude/hooks/session-start.ps1`. Команди kit — з підтвердженням
(правила дозволів працюють за префіксом, і дозвіл на прев'ю дозволив би `-Apply`).
```

- [ ] **Step 3: `templates/README.md`**

```markdown
# templates/

Файли, які плагін кладе в репозиторій-споживач (скіл `v8storagekit:onboarding`, команда
`kit install-hooks`). Два з них навмисно без провідної крапки — щоб не діяти на сам kit.

| Файл тут | Стає в репо-споживачі |
|---|---|
| `gitattributes` | `.gitattributes` (onboarding дописує `<ws>/<path>/** -text` під фактичні шляхи) |
| `gitignore` | `.gitignore` (onboarding дописує `<ws>/<path>/**` для `truth: vendor`) |
| `settings.json` | `.claude/settings.json` — дозволи + хук `SessionStart` |
| `hooks/session-start.ps1` | `.claude/hooks/session-start.ps1` — шим хука (без логіки) |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
| `CLAUDE.md` | `CLAUDE.md` |
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює onboarding за відповідями людини) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `AUTHORS.example` | `AUTHORS` (корінь) |
```

- [ ] **Step 4: `Templates.Tests.ps1`**

Describe «product-onboarding — шаблон v8project.yaml» → переписати на `skills/onboarding/SKILL.md`
(перевірки ті самі: `infobase:`, `connection: 'File=build/ib'`, `name: <ІмʼяРозширення>`, не
`name: <Продукт>`). Додати It: `templates/CLAUDE.md` згадує `v8storagekit.yaml`, `storage/`,
усі сім скілів із префіксом і не згадує `storage.json`, `storage-sync`, `load-ext`.

- [ ] **Step 5: Повний прогін, перевірки; коміт**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
grep -rn 'storage-pipeline\|product-onboarding\|repo-migration' skills/ templates/ tools/ README.md CLAUDE.md
```

Другий — порожньо; третій — лише `docs/migration/legacy-gitsync-repo.md` і `CLAUDE.md`/`README.md`
kit (їх переписує B8; тут — лишити).

```bash
git add -A skills templates docs/migration/legacy-gitsync-repo.md tools/tests/Templates.Tests.ps1
git commit -m "B5: вилучено старі скіли; довідка про legacy-міграцію; templates/CLAUDE.md і README під модель 1.0"
```

---

### Task 7: `docs/unica-contract.md` A8–A11; `CLAUDE.md` kit — структура

- [ ] **Step 1:** У таблицю розділу A `docs/unica-contract.md` після A7 додати рядки (дослівно зі спеки §11):

```markdown
| A8 | шлях source-set поза workspace root відхиляється (`source_set.path_unsafe`, `ready=false`) — спільний `epf/` мусить бути власним воркспейсом | розкладка §2.1 спеки agent-contour | `source_roots.rs:145-168`, `layout.rs:1012-1024`; спроба `../epf/src` дає `ready=false` |
| A9 | корінь воркспейсу = найближчий предок `cwd` з `v8project.yaml`; `config` кореня не міняє; кеш у `<корінь>/.build/unica` | `cwd` для Unica — тека воркспейсу; три теки `build` з різними власниками | `workspace.rs:21-44` |
| A10 | `operation=init` не приймає шаблон/`.dt` (лише `operation, config, workdir`) | база агента з `.dt` — `kit provision` через платформу | `tool_contracts.rs:561` |
| A11 | `project.status` бере `.gitattributes`/`.gitignore` від кореня git-репо через `check-attr --cached`/`check-ignore` | політики git під фактичні шляхи (§2.6) видно Уніці з кореня репо | `git.rs:786-799`, `resources.rs:573-583` |
```

Абзац після таблиці: «A8–A11 додано 2026-09 зі спеки agent-contour §11 (дослідницький воркфлоу
2026-09-02..03); джерела — звіт `unica_companion`, не власне читання Rust».

- [ ] **Step 2:** `CLAUDE.md` kit, таблиця «Структура», рядок `skills/`: «Вісім скілів — вступний
  `using-v8storagekit` (вантажить хук споживача) і по одному на намір: `onboarding`, `sync`, `dump`,
  `reconcile`, `finish`, `provision`, `verify` (`migrate` — B6)». Рядок `templates/`: «+ `hooks/`,
  `githooks/`, зразки маніфесту й накладки».

- [ ] **Step 3:** Перевірка живою сесією (локальний маркетплейс, за підтвердженням): у синтетичному
  репозиторії `claude -p "Invoke the skill named v8storagekit:sync and print only its first heading"`
  → `# sync — нові версії сховища → гілки storage/*`. Аналогічно `v8storagekit:onboarding`.

- [ ] **Step 4: Коміт**

```bash
git add docs/unica-contract.md CLAUDE.md
git commit -m "B5: unica-contract A8–A11; структура скілів у CLAUDE.md kit"
```

---

## Self-review

| Вимога спеки | Задача |
|---|---|
| скіли `onboarding`, `sync`, `dump`, `reconcile`, `finish`, `provision`, `verify` (§6) | 2–5 |
| `onboarding` **питає** `truth` з чотирма варіантами й наслідками; шлях/користувача сховища; дев-базу (§2.5) | 2 |
| політики git під фактичні шляхи з `v8project.yaml`, не шаблонні (§2.6) | 2 |
| `.githooks` + `core.hooksPath`; шим і `settings.json` з хуком кладе `onboarding` (§3.3, §7) | 1, 2 |
| `provision` **питає** тип бази (порожня / `.dt` / серверна) і записує у `v8storagekit.local.yaml` (§2.5, §4) | 4 |
| `reconcile`: `sync → canon → merge storage/* → F → семантичний diff`; не rebase (§3.1, §8.5) | 5 |
| `finish`: `sync → canon → merge → verify F → тести → артефакти → PR`; PR повний (§8.6) | 5 |
| маршрутизація до Unica; `unica_runtime_execute` без auto-allow (§6) | 5, 6 |
| переписані `templates/` (§14 B5) | 6 |
| вилучення старих скілів (§14 B5); знання `repo-migration` збережено як довідку для рішення по OnlineExchange (§13) | 6 |
| `unica-contract.md` A8–A11 (§11) | 7 |
| правила `${CLAUDE_PLUGIN_ROOT}` і префіксів — guard-тести на кожен скіл | 2 |

**Свідомо не в B5:** `migrate` — B6; `README.md`, `CLAUDE.md` kit цілком, `plugin.json` — B8.

**Узгодженість імен:** усі скіли посилаються на команди `kit.ps1 check|session-check|sync|dump|verify|canon|provision|build|install-hooks`
рівно з тими параметрами, що визначені в B1–B5 (`-Source`, `-Workspace`, `-Apply`, `-MaxVersions`, `-MergeMain`,
`-Ref`, `-Template`, `-Remember`, `-Force`); вердикти `verify` — як у B3; текст питання `truth` — як у
`templates/v8storagekit.yaml.example` (B1).
