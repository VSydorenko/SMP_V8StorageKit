# B1. Маніфест `v8storagekit.yaml`, диспетчер `kit.ps1`, `check`, захист `storage/*` — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дати kit модель даних нового контуру — маніфест `v8storagekit.yaml` з локальною
накладкою, читання `v8project.yaml` Уніки, спільний префлайт, диспетчер `tools/kit.ps1`,
команду `check` з усіма інваріантами §2.6/§3.2/§3.3 спеки та версійовані git-хуки захисту
гілок `storage/*`.

**Architecture:** новий код лягає **поруч** зі старим: `storage-sync.ps1`, `dump-config.ps1`,
`build.ps1`, `load-ext.ps1` і `SyncState.psm1` у цьому блоці **не чіпаються** (їх вилучають
B2–B4). Додаються модулі `tools/lib/{Yaml,V8Project,Manifest,Preflight,StorageBranch,Hooks}.psm1`,
диспетчер `tools/kit.ps1`, перший командний модуль `tools/commands/check.psm1`, шаблони
`templates/githooks/*`, `templates/v8storagekit*.example`. Кожен модуль тестується сам;
дисптечер і `check` — підпроцесом на синтетичному репозиторії в `$TestDrive`.

**Tech Stack:** PowerShell 7.5, Pester 5, git 2.53 (`worktree --orphan`, `%(trailers:…)`),
модуль `powershell-yaml` (YamlDotNet) — **нова залежність категорії «Конвеєр»**.

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` — §2 (модель даних),
§3.2–3.3 (стан із git, захист гілок), §5 (префлайт і `check`), §12 (тести), §14 (B1).
Політика тексту — `docs/superpowers/specs/2026-08-31-unica-canon-transition-design.md` §5.2–5.3.

## Global Constraints

- **PowerShell 7+**, кожен скрипт і модуль під `Set-StrictMode -Version Latest`; скрипти —
  `$ErrorActionPreference = 'Stop'`. Нативні команди (`git`) перевіряються через
  `$LASTEXITCODE` явно — на цій машині `$PSNativeCommandUseErrorActionPreference = $false`.
- **Мова всього, що бачить людина** — українська: коментарі в коді, повідомлення, назви
  тестів, документація. Англійською — ідентифікатори, шляхи, команди, дослівні цитати
  виводу інструментів.
- **Прогін тестів:** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  У цьому плані платформа 1С не потрібна жодного разу; тег `Integration` не додається.
- **Форма тесту** — за `CLAUDE.md` і `docs/follow-ups.md` §4: тест виконує справжній
  артефакт (модуль імпортом або скрипт підпроцесом `pwsh -NoProfile -File`) у тимчасовому
  ізольованому git-репозиторії під `$TestDrive`; перевіряє і текст зупинки, і те, що
  наступний крок **не** відбувся. Дублювати формулу production-коду всередині тесту не
  можна.
- **Сховища конфігурацій — тільки читання.** У цьому блоці до сховищ і платформи звернень
  немає взагалі.
- **Вкладений `Import-Module` без `-Force`** усередині модулів (див. коментар у
  `tools/lib/StorageReport.psm1`); `-Force` — лише у скриптах верхнього рівня.
- **`${CLAUDE_PLUGIN_ROOT}` — тільки всередині шляху** в `SKILL.md`. У цьому блоці скіли не
  правляться.
- **Версію `plugin.json` не піднімати** — споживачам цей блок ще не роздається (бамп — B5/B8).
- **Кореневий `.gitattributes` kit** правиться лише для `templates/githooks/*` (рядок
  `text eol=lf`). `templates/gitattributes` — політика споживачів, правиться окремо (Task 7).
- **Коміт після кожної задачі — так. `git push` — ні**, ні на якому кроці.
- **Головна гілка kit — `main`; робота ведеться в гілці `feature/agent-contour`** (уже існує).

### Рішення, узгоджені з архітектором (2026-09-03, внесені в спеку комітами 75530fe, 6f95c75)

| # | Питання | Рішення | Де в спеці |
|---|---|---|---|
| Q1 | YAML-парсер | модуль **`powershell-yaml`** (PSGallery) як залежність «Конвеєр»; `check-environment.ps1` показує його; префлайт без модуля зупиняється з рядком `Install-Module powershell-yaml -Scope CurrentUser` | §2.4 |
| Q2 | база агента | kit іде за вказівником Unica: `infobase.connection` з `v8project.local.yaml`, якщо файл є, інакше з `v8project.yaml`. У накладці kit цього підключення **немає** (потрібно з B4; у B1 — лише аудит у `check`) | §2.5 |
| Q4 | злиття в `main` | `HEAD`=`main` і чисто → на місці; `HEAD`=`main` і брудно → зупинка; інакше — worktree `build/sync/_main/wt` (B2) | §3.4 |
| Q5 | головна гілка | необов'язковий кореневий ключ маніфесту `mainBranch`, типово `main` | §2.4 |
| Q7 | версія між блоками | **жодного пушу й проміжного релізу.** Для тестування блоків маркетплейс `smp-v8storagekit` перереєстровується на локальну теку робочої копії (Task 10 цього плану); повернення на GitHub і `1.0.0` — лише в B8 | §14 |
| Q8 | версія для `verify` | трейлер `git merge-base <ref> storage/X`, не вершина (B3) | §3.5 |
| Q9 | `-Source` без `-Workspace` | дозволено, якщо ключ унікальний у маніфесті; інакше зупинка з переліком воркспейсів | §5 |

---

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `tools/lib/Yaml.psm1` | **новий.** Єдина точка входу в YAML: перевірка наявності `powershell-yaml`, читання файлу UTF-8, `ConvertFrom-Yaml -Ordered`, fail-closed на порожньому файлі й не-мапі | 1 |
| `tools/tests/fixtures/manifest-product.yaml`, `manifest-client.yaml`, `overlay-sample.yaml`, `v8project-extension.yaml`, `v8project-epf.yaml` | **нові.** Дослівні приклади зі спеки §2.4–2.5 і живих репозиторіїв як фікстури | 1, 2, 3 |
| `tools/tests/Yaml.Tests.ps1` | **новий.** | 1 |
| `tools/check-environment.ps1` | рядок «Модуль powershell-yaml» у категорії «Конвеєр» | 1 |
| `tools/lib/V8Project.psm1` | **новий.** `Read-V8Project`, `Read-V8ProjectLocalInfobase` — читання файлів Уніки без жодних припущень про шляхи | 2 |
| `tools/tests/V8Project.Tests.ps1` | **новий.** | 2 |
| `tools/lib/Manifest.psm1` | **новий.** `Read-KitManifest`, `Read-KitLocalOverlay`, `Resolve-KitInfobase` — схема, значення за замовчуванням, зрозумілі відмови | 3 |
| `tools/tests/Manifest.Tests.ps1` | **новий.** | 3 |
| `tools/lib/Preflight.psm1` | **новий.** `Invoke-KitPreflight` збирає контекст команди; `Select-KitSources` фільтрує джерела за `-Workspace`/`-Source`/`-Truth` | 4 |
| `tools/tests/fixtures/KitFixtures.psm1` | **новий.** `New-KitFakeRepo` — синтетичний репозиторій-споживач для всіх тестів B1–B4 | 4 |
| `tools/tests/Preflight.Tests.ps1` | **новий.** | 4 |
| `tools/lib/StorageBranch.psm1` | **новий.** Стан синхронізації з git: імена гілок, трейлери, остання версія, інваріанти §3.2 | 5 |
| `tools/tests/StorageBranch.Tests.ps1` | **новий.** | 5 |
| `templates/githooks/pre-commit`, `templates/githooks/pre-merge-commit` | **нові.** Shell-хуки захисту `storage/*` (§3.3, шар 2) | 6 |
| `tools/lib/Hooks.psm1` | **новий.** `Install-KitGitHooks`, `Test-KitGitHooks` | 6 |
| `tools/tests/Hooks.Tests.ps1` | **новий.** | 6 |
| `.gitattributes` (kit), `templates/gitattributes` | `eol=lf` для хуків — у kit і в споживача | 6 |
| `tools/lib/module-order.txt` | **новий.** Порядок імпорту lib-модулів — одне джерело для `kit.ps1` і probe (закриває `follow-ups.md` §5) | 7 |
| `tools/kit.ps1` | **новий.** Диспетчер: UTF-8, імпорт модулів, префлайт, виклик `Invoke-Kit<Команда>` | 7 |
| `tools/tests/fixtures/module-visibility-probe.ps1`, `tools/tests/ModuleImportOrder.Tests.ps1` | probe читає `module-order.txt`; другий Describe для `kit.ps1` | 7 |
| `tools/tests/Kit.Tests.ps1` | **новий.** Диспетчер підпроцесом на фейковому репо | 7 |
| `tools/commands/check.psm1` | **новий.** `Invoke-KitCheck` — усі інваріанти повного `check` | 8 |
| `tools/tests/Check.Tests.ps1` | **новий.** | 8 |
| `templates/v8storagekit.yaml.example`, `templates/v8storagekit.local.yaml.example` | **нові.** Роздавані зразки | 9 |
| `templates/gitignore`, `templates/README.md`, `.claude/settings.json` (kit) | рядок `v8storagekit.local.yaml`; таблиця шаблонів; дозвіл на `kit.ps1 check` | 9 |
| `docs/follow-ups.md` | §5 позначити закритим; новий запис про `.githooks` у linked worktree | 9 |
| `~/.claude/plugins/known_marketplaces.json` (через `claude plugin marketplace`) | перереєстрація маркетплейсу на локальну робочу копію для тестування блоків | 10 |

---

## Спільні контракти блоку (Interfaces, які бачать усі задачі й наступні блоки)

Усі функції нижче — PowerShell, експортовані з названих модулів. Імена — точні; B2–B4
посилаються на них саме так.

```
Yaml.psm1
  Test-KitYamlModule            : → {Available:bool; Version:string; Reason:string}
  Read-KitYaml -Path [-AllowEmpty] : → OrderedDictionary | $null (лише з -AllowEmpty на порожньому/коментованому файлі)

V8Project.psm1
  Read-V8Project -Path          : → {Path; Directory; WorkPath:string; InfobaseConnection:string|$null;
                                     SourceSets: @({Name; Type; Path (відносний, '/'); FullPath})}
  Read-V8ProjectLocalInfobase -Path : → string|$null   (infobase.connection з v8project.local.yaml)
  Resolve-V8AgentInfobase -Project  : → {Connection; Origin}|$null  (local → project, §2.5)

Manifest.psm1
  Read-KitManifest -Path        : → {Path; Version=1; Kind:'product'|'client'; Label; MainBranch;
                                     Workspaces: @({Path; Sources: @({Key; Truth; StoragePath; StorageUser; DumpFrom})})}
  Read-KitLocalOverlay -Path    : → {Path; Infobases: hashtable name→{Name;Connection;User};
                                     Storages: hashtable key→path; Workspaces: hashtable path→{Path; AgentBaseTemplate}}
  Resolve-KitInfobase -Overlay -Name [-OverlayPath] : → {Name; Connection; User} або зупинка з підказкою

Preflight.psm1
  New-KitFinding -Level error|warn|info -Check <id> -Message : → {Level; Check; Message}
  Invoke-KitPreflight -RepoRoot [-Lenient] : → $ctx (див. нижче); без -Lenient кидає на першій проблемі
  Select-KitSources -Context [-Workspace] [-Source] [-Truth <string[]>] : → @(resolved source)

  $ctx = {
    RepoRoot; ManifestPath; OverlayPath|$null; Manifest; Overlay|$null;
    Kind; Label; MainBranch;
    Workspaces: @({ Path; FullPath; Project (Read-V8Project); Sources: @(resolved source) });
    Findings: List[finding]; Ok: bool
  }
  resolved source = { Key; Truth; Type; Workspace (Path); Path (відн. воркспейсу); RepoPath ('<ws>/<path>');
                      FullPath; StoragePath (уже з перевизначенням накладки); StorageUser; DumpFrom;
                      Branch ('storage/<Key>' для truth storage, інакше $null) }

StorageBranch.psm1
  Get-KitStorageBranchName -SourceKey            : → 'storage/<key>'
  Test-KitBranchExists -RepoRoot -Branch          : → bool
  Get-KitBranchCommits -RepoRoot -Ref             : → @({Sha; Parents:string[]; Trailers:OrderedDictionary}) від кореня
  Get-KitStorageBranchLastVersion -RepoRoot -Branch : → int|$null (гілки немає)
  Test-KitStorageBranchInvariants -RepoRoot -Branch -SourceKey -RepoPath : → @(finding)

Hooks.psm1
  Get-KitHookNames                                : → @('pre-commit','pre-merge-commit')
  Install-KitGitHooks -RepoRoot [-TemplatesDir]   : → @(шляхи встановлених файлів)
  Test-KitGitHooks -RepoRoot [-TemplatesDir]      : → @(finding)

commands/<name>.psm1
  Invoke-Kit<Name> -Context $ctx [-Workspace] [-Source] [-Apply:bool] [власні параметри]
    → $null або {ExitCode:int; …}. Зупинка — throw. Диспетчер завершує процес ExitCode.

tools/tests/fixtures/KitFixtures.psm1
  New-KitFakeRepo -Root [-ManifestText] [-OverlayText] [-Workspaces <hashtable>] [-WithHooks] [-WithGitattributes] [-WithGitignore] [-NoCommit]
    : → шлях кореня ізольованого git-репозиторію-споживача
```

**Повідомлення й тести на кирилицю.** Дочірній `pwsh` під CP866 підмінює «і» на «?» у всьому,
що йде через консольний хост (див. коментар у `tools/tests/StorageSync.Tests.ps1`). `kit.ps1`
виставляє UTF-8 сам, але падіння до цього рядка чи вивід сторонніх процесів можуть бути
покалічені. Тому **кожне повідомлення зупинки містить ASCII-якір** (ім'я файлу, ключа,
гілки, прапорця), а тести підпроцесних сценаріїв звіряють саме якір
(`'*v8project.yaml*'`, `'*core.hooksPath*'`, `'*storage/*'`), а не кириличну фразу.

---

### Task 1: `Yaml.psm1` — єдина точка входу в YAML і залежність `powershell-yaml`

Без цього модуля не читається ні маніфест, ні `v8project.yaml`. Він також дає
`check-environment.ps1` рядок про нову залежність.

**Files:**
- Create: `tools/lib/Yaml.psm1`
- Create: `tools/tests/Yaml.Tests.ps1`
- Create: `tools/tests/fixtures/manifest-product.yaml`, `tools/tests/fixtures/manifest-client.yaml`
- Modify: `tools/check-environment.ps1` (рядки 36–48: імпорт і новий рядок категорії «Конвеєр»; шапка `.DESCRIPTION`)

**Interfaces:**
- Consumes: нічого з kit.
- Produces: `Test-KitYamlModule`, `Import-KitYamlModule`, `Read-KitYaml -Path [-AllowEmpty]`.

- [ ] **Step 1: Встановити модуль на машині розробки** (одноразово; питає підтвердження — це зміна стану машини)

```powershell
Install-Module powershell-yaml -Scope CurrentUser -Force
Get-Module -ListAvailable powershell-yaml | Select-Object Name, Version
```

Очікувано: рядок із версією (0.4.x або новіша).

- [ ] **Step 2: Фікстури — дослівні приклади зі спеки §2.4**

`tools/tests/fixtures/manifest-product.yaml`:

```yaml
version: 1                          # версія схеми маніфесту
product: BankExchange               # АБО client: <назва>. Метадані: імена артефактів, звіти.

workspaces:
  - path: SMP_BankExchange_SMB      # тека з v8project.yaml
    sources:                        # ключ = name: source-set у v8project.yaml
      base:
        truth: vendor               # не наше, у git не потрапляє; локально — дамп
        dump: { from: devUNF }      # ключ підключення в local overlay
      SMP_BankExchange_SMB:
        truth: storage
        storage:
          path: 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
          user: gitbot              # типово gitbot; пароль порожній за конвенцією

  - path: SMP_BankExchange_SMBru
    sources:
      base: { truth: vendor, dump: { from: devUNFru } }
      SMP_BankExchange_SMBru:
        truth: storage
        storage: { path: 'R:\СховищаРозширень_1С\СМП_BankExchange_SMBru' }

  - path: epf
    sources:
      external-processors: { truth: git }
```

`tools/tests/fixtures/manifest-client.yaml`:

```yaml
version: 1
client: Alpenpharma
workspaces:
  - path: Alpenpharma_UNF
    sources:
      base:
        truth: storage              # конфігурація змінена і під сховищем — з історією
        storage: { path: 'R:\СховищаКонфігурацій_1С\Alpenpharma' }
      Адаптация:
        truth: storage
        storage: { path: 'R:\СховищаРозширень_1С\Alpenpharma_Адаптация' }
      SMP_BankExchange_SMB:
        truth: storage              # наше рішення зі спільного сховища
        storage:
          path: 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
          user: Alpenpharma         # користувач сховища за іменем бази
```

Обидва файли — UTF-8 **без BOM**, LF (кореневий `.gitattributes` kit дає `text=auto`, цього
досить).

- [ ] **Step 3: Тест, що падає**

`tools/tests/Yaml.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Yaml.psm1 — читання YAML через powershell-yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path
    }

    It 'модуль powershell-yaml доступний на цій машині (залежність категорії «Конвеєр»)' {
        (Test-KitYamlModule).Available | Should -BeTrue -Because (
            'без нього не читається ні маніфест, ні v8project.yaml: Install-Module powershell-yaml -Scope CurrentUser')
    }

    It 'читає продуктовий маніфест зі спеки: три воркспейси, flow-стиль і кириличні шляхи цілі' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
        $m['version'] | Should -Be 1
        $m['product'] | Should -Be 'BankExchange'
        @($m['workspaces']).Count | Should -Be 3
        $m['workspaces'][1]['sources']['base']['dump']['from'] | Should -Be 'devUNFru'
        $m['workspaces'][0]['sources']['SMP_BankExchange_SMB']['storage']['path'] |
            Should -Be 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
    }

    It 'читає клієнтський маніфест: кириличний ключ джерела на місці' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-client.yaml')
        $m['client'] | Should -Be 'Alpenpharma'
        @($m['workspaces'][0]['sources'].Keys) | Should -Contain 'Адаптация'
    }

    It 'зберігає порядок ключів — для звітів і майбутнього запису назад' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
        @($m.Keys)[0] | Should -Be 'version'
        @($m.Keys)[-1] | Should -Be 'workspaces'
    }

    It 'зупиняється на відсутньому файлі, називаючи шлях' {
        { Read-KitYaml -Path (Join-Path $TestDrive 'nope.yaml') } | Should -Throw '*nope.yaml*'
    }

    It 'зупиняється на порожньому файлі без -AllowEmpty і повертає $null з ним' {
        $f = Join-Path $TestDrive 'empty.yaml'
        Set-Content -LiteralPath $f -Value "# лише коментар`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*порожній*'
        Read-KitYaml -Path $f -AllowEmpty | Should -BeNullOrEmpty
    }

    It 'зупиняється, коли верхній рівень — список, а не мапа' {
        $f = Join-Path $TestDrive 'list.yaml'
        Set-Content -LiteralPath $f -Value "- a`n- b`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*мапою*'
    }

    It 'зупиняється на дубльованому ключі — дві дев-бази під одним іменем не проходять мовчки' {
        # Наступник запобіжника Read-V8LocalConnection на «два connection: під одним ключем»:
        # тепер це робить сам парсер (YamlDotNet відхиляє дубльовані ключі мапи). Якщо цей
        # тест колись пройде без винятку — powershell-yaml почав приймати дублікати, і
        # перевірку треба додати в Read-KitYaml явно, а не знімати тест.
        $f = Join-Path $TestDrive 'dup.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'infobases:'
            '  dev:'
            "    connection: 'File=a'"
            '  dev:'
            "    connection: 'File=b'"
        )
        { Read-KitYaml -Path $f } | Should -Throw
    }

    It 'зупиняється на зламаному YAML, називаючи файл' {
        $f = Join-Path $TestDrive 'broken.yaml'
        Set-Content -LiteralPath $f -Value "a: [1, 2`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*broken.yaml*'
    }
}
```

- [ ] **Step 4: Запустити — має впасти на відсутньому модулі**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

Очікувано: `Yaml.Tests.ps1` червоний — `Import-Module … Yaml.psm1` не знаходить файл.

- [ ] **Step 5: Реалізація `tools/lib/Yaml.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Єдине місце в kit, де відомо, ЯКИМ парсером читається YAML. Рішення (спека §2.4):
# модуль powershell-yaml із PSGallery — залежність категорії «Конвеєр». Регекс, яким
# читався v8project.local.yaml до 1.0, не витягне flow-стиль маніфесту
# (`{ truth: vendor, dump: { from: devUNF } }`), а вендорити YamlDotNet.dll у
# git-розповсюджуваний плагін означало б бінарник у репозиторії.
$script:YamlModuleName  = 'powershell-yaml'
$script:YamlInstallHint = "Install-Module $script:YamlModuleName -Scope CurrentUser"

function Test-KitYamlModule {
    <#
    .SYNOPSIS
        Чи встановлено powershell-yaml. Нічого не кидає — це звіт для check-environment.
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{ Available = $false; Version = ''; Reason = '' }
    $modules = @(Get-Module -ListAvailable -Name $script:YamlModuleName -ErrorAction SilentlyContinue)
    if ($modules.Count -eq 0) {
        $result.Reason = "Модуль $script:YamlModuleName не встановлено — $script:YamlInstallHint"
        return $result
    }
    $newest = $modules | Sort-Object Version -Descending | Select-Object -First 1
    $result.Version   = [string]$newest.Version
    $result.Available = $true
    $result
}

function Import-KitYamlModule {
    <#
    .SYNOPSIS
        Завантажує powershell-yaml або зупиняється з командою встановлення.
    #>
    [CmdletBinding()]
    param()

    if (Get-Module -Name $script:YamlModuleName) { return }
    $probe = Test-KitYamlModule
    if (-not $probe.Available) {
        throw "$($probe.Reason). Без нього kit не читає ні v8storagekit.yaml, ні v8project.yaml."
    }
    Import-Module $script:YamlModuleName -ErrorAction Stop
}

function Read-KitYaml {
    <#
    .SYNOPSIS
        Читає YAML-файл у впорядковану мапу. Fail-closed: не файл, порожньо, не мапа, не
        розбирається — зупинка з ім'ям файлу.
    .PARAMETER AllowEmpty
        Порожній або суто коментований файл — законний стан (наприклад, v8project.local.yaml
        без жодного ключа): повернути $null замість зупинки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowEmpty
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл не знайдено: $Path"
    }
    Import-KitYamlModule

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $data = ConvertFrom-Yaml -Yaml $text -Ordered
        } catch {
            throw "Файл $Path не розбирається як YAML: $($_.Exception.Message)"
        }
    }

    if ($null -eq $data) {
        if ($AllowEmpty) { return $null }
        throw "Файл $Path порожній — очікувався YAML-документ із мапою на верхньому рівні."
    }
    if ($data -isnot [System.Collections.IDictionary]) {
        throw "Файл $Path на верхньому рівні має бути мапою (ключ: значення), а не $($data.GetType().Name)."
    }
    $data
}

Export-ModuleMember -Function Test-KitYamlModule, Import-KitYamlModule, Read-KitYaml
```

- [ ] **Step 6: `check-environment.ps1` — новий рядок «Конвеєр»**

Після `Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force` додати
`Import-Module (Join-Path $PSScriptRoot 'lib/Yaml.psm1') -Force`. У блоці `# --- Конвеєр ---`
після перевірки git:

```powershell
$yaml = Test-KitYamlModule
$checks.Add((New-EnvironmentCheck -Name 'Модуль powershell-yaml' -Category 'Конвеєр' -Ok $yaml.Available `
    -Detail $(if ($yaml.Available) { "версія $($yaml.Version) — читає v8storagekit.yaml і v8project.yaml" } else { $yaml.Reason })))
```

У блоці виводу, у гілці `if ($blocking.Count -gt 0)` після рядка «Конвеєр запустити не вийде»:

```powershell
    if (-not $yaml.Available) {
        Write-Host ''
        Write-Host '  Встановити powershell-yaml (PSGallery):'
        Write-Host '    Install-Module powershell-yaml -Scope CurrentUser'
    }
```

У шапці `.DESCRIPTION` до рядка «Конвеєр — без цього скрипти tools/ не запустяться взагалі»
додати: «(PowerShell 7, git, платформа 8.3.27.x, модуль powershell-yaml)».

- [ ] **Step 7: Тести зелені; середовище показує новий рядок**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
pwsh -NoProfile -File tools/check-environment.ps1
```

Очікувано: усі тести зелені (включно з наявним `Environment.Tests.ps1`), у виводі середовища
`[+] Модуль powershell-yaml — версія …`.

- [ ] **Step 8: Коміт**

```bash
git add tools/lib/Yaml.psm1 tools/tests/Yaml.Tests.ps1 tools/tests/fixtures/manifest-product.yaml tools/tests/fixtures/manifest-client.yaml tools/check-environment.ps1
git commit -m "B1: Yaml.psm1 — powershell-yaml як залежність конвеєра, фікстури маніфестів зі спеки"
```

---

### Task 2: `V8Project.psm1` — читання `v8project.yaml` і вказівника на базу агента

Kit не припускає жодних шляхів: `cfe/src`, `cf/src`, `src` — усе береться звідси (§2.3).

**Files:**
- Create: `tools/lib/V8Project.psm1`
- Create: `tools/tests/V8Project.Tests.ps1`
- Create: `tools/tests/fixtures/v8project-extension.yaml`, `tools/tests/fixtures/v8project-epf.yaml`

**Interfaces:**
- Consumes: `Read-KitYaml` (Task 1).
- Produces: `Read-V8Project`, `Read-V8ProjectLocalInfobase`, `Resolve-V8AgentInfobase` (сигнатури — у «Спільних контрактах»). `SourceSets[].Path` — відносний до теки воркспейсу, з `/`, без завершального `/`; `FullPath` — абсолютний.

- [ ] **Step 1: Фікстури — живі файли `SMP_BankExchange`**

`tools/tests/fixtures/v8project-extension.yaml` (дослівно `SMP_BankExchange_SMB/v8project.yaml`):

```yaml
format: DESIGNER
builder: DESIGNER
workPath: 'build'
execution_timeout: 600000
infobase:
  connection: 'File=build/ib'
source-set:
  - name: base
    type: CONFIGURATION
    path: 'cf/src'
  - name: SMP_BankExchange_SMB
    type: EXTENSION
    path: 'cfe/src'
```

`tools/tests/fixtures/v8project-epf.yaml` (як `epf/v8project.yaml`, але з ім'ям source-set із
прикладу спеки — маніфест-фікстура посилається саме на нього):

```yaml
format: DESIGNER
builder: DESIGNER
workPath: 'build'
execution_timeout: 600000
source-set:
  - name: external-processors
    type: EXTERNAL_DATA_PROCESSORS
    path: 'src'
```

- [ ] **Step 2: Тест, що падає**

`tools/tests/V8Project.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'V8Project.psm1 — читання v8project.yaml Уніки' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path

        # Копія фікстури в окрему теку — FullPath має рахуватись від теки САМОГО файлу,
        # а v8project.local.yaml поруч із нею — з'являтись і зникати між тестами.
        $script:Ws = Join-Path $TestDrive 'Alpha_SMB'
        New-Item -ItemType Directory -Path $script:Ws -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'v8project-extension.yaml') `
            -Destination (Join-Path $script:Ws 'v8project.yaml')
    }
    AfterEach {
        Remove-Item -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -ErrorAction SilentlyContinue
    }

    It 'розбирає воркспейс розширення: два source-set-и, підключення бази агента, шляхи від теки конфіга' {
        $p = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
        $p.WorkPath | Should -Be 'build'
        $p.InfobaseConnection | Should -Be 'File=build/ib'
        $p.SourceSets.Count | Should -Be 2
        $p.SourceSets[1].Name | Should -Be 'SMP_BankExchange_SMB'
        $p.SourceSets[1].Type | Should -Be 'EXTENSION'
        $p.SourceSets[1].Path | Should -Be 'cfe/src'
        $p.SourceSets[1].FullPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Ws 'cfe/src')))
    }

    It 'воркспейс без infobase: (зовнішні обробки) дає InfobaseConnection = $null, а не помилку' {
        $p = Read-V8Project -Path (Join-Path $script:Fixtures 'v8project-epf.yaml')
        $p.InfobaseConnection | Should -BeNullOrEmpty
        $p.SourceSets[0].Type | Should -Be 'EXTERNAL_DATA_PROCESSORS'
        $p.SourceSets[0].Path | Should -Be 'src'
    }

    It 'зупиняється без розділу source-set' {
        $f = Join-Path $TestDrive 'no-sets.yaml'
        Set-Content -LiteralPath $f -Value "format: DESIGNER`n" -Encoding UTF8
        { Read-V8Project -Path $f } | Should -Throw '*source-set*'
    }

    It 'зупиняється на невідомому type source-set, називаючи його і відомі' {
        $f = Join-Path $TestDrive 'bad-type.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:', '  - name: x', '    type: REPORT', "    path: 'src'")
        { Read-V8Project -Path $f } | Should -Throw '*REPORT*EXTERNAL_DATA_PROCESSORS*'
    }

    It 'зупиняється, коли в елементі source-set бракує path' {
        $f = Join-Path $TestDrive 'no-path.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:', '  - name: x', '    type: EXTENSION')
        { Read-V8Project -Path $f } | Should -Throw "*'path'*"
    }

    It 'зупиняється на двох source-set-ах з однаковим name' {
        $f = Join-Path $TestDrive 'dup-name.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:',
            '  - name: x', '    type: EXTENSION', "    path: 'a'",
            '  - name: x', '    type: EXTENSION', "    path: 'b'")
        { Read-V8Project -Path $f } | Should -Throw '*двічі*'
    }

    Context 'v8project.local.yaml — вказівник Уніки на базу агента (§2.5)' {
        It 'без файлу — $null' {
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'з devInfobase: (стара конвенція kit), але без infobase: — $null' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'devInfobase:', "  connection: 'Srvr=""VSDEV"";Ref=""X"";'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'з infobase.connection — повертає рядок як є' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_ib"";'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') |
                Should -Be 'Srvr="VSDEV";Ref="agent_ib";'
        }

        It 'Resolve-V8AgentInfobase: накладка Уніки виграє у закоміченого конфіга й називає джерело' {
            $p = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
            (Resolve-V8AgentInfobase -Project $p).Connection | Should -Be 'File=build/ib'
            (Resolve-V8AgentInfobase -Project $p).Origin | Should -Be $p.Path

            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_ib"";'")
            $r = Resolve-V8AgentInfobase -Project $p
            $r.Connection | Should -Be 'Srvr="VSDEV";Ref="agent_ib";'
            $r.Origin | Should -BeLike '*v8project.local.yaml'
        }

        It 'Resolve-V8AgentInfobase без жодного підключення — $null (воркспейс epf)' {
            $p = Read-V8Project -Path (Join-Path $script:Fixtures 'v8project-epf.yaml')
            Resolve-V8AgentInfobase -Project $p | Should -BeNullOrEmpty
        }
    }
}
```

- [ ] **Step 3: Запустити — червоно (модуля немає)**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 4: Реалізація `tools/lib/V8Project.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — те саме застереження, що й довкола вкладених імпортів у StorageReport.psm1:
# не перезавантажувати вже наявний глобальний Yaml.
Import-Module "$PSScriptRoot/Yaml.psm1"

# Типи source-set, які kit уміє співставити з маніфестом. Інші (якби Unica їх додала)
# зупиняють читання: невідомий тип означає невідомі правила git для цього дерева.
$script:KnownSourceSetTypes = @('CONFIGURATION', 'EXTENSION', 'EXTERNAL_DATA_PROCESSORS')

function Read-V8Project {
    <#
    .SYNOPSIS
        Читає v8project.yaml Уніки — рівно ті поля, від яких залежить kit.
    .DESCRIPTION
        Kit не припускає розкладки воркспейсу (спека §2.3): де лежить cfe/src, cf/src чи src,
        каже цей файл. Тому кожен source-set мусить мати name/type/path, а type — бути з
        відомого списку. Шляхи повертаються і відносними (для .gitignore/.gitattributes і
        RepoPath), і абсолютними (для файлових операцій), розв'язаними від теки самого
        конфіга — так їх розв'язує і Unica (docs/unica-contract.md, A7).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $data = Read-KitYaml -Path $Path
    $full = (Resolve-Path -LiteralPath $Path).Path
    $dir  = Split-Path -Parent $full

    if (-not $data.Contains('source-set')) {
        throw "У $Path немає розділу source-set: — без нього Unica не бачить воркспейсу, а kit не має чого звірити з маніфестом."
    }
    $rawSets = $data['source-set']
    if ($rawSets -isnot [System.Collections.IList] -or $rawSets.Count -eq 0) {
        throw "Розділ source-set: у $Path має бути непорожнім списком."
    }

    $sets = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($item in $rawSets) {
        if ($item -isnot [System.Collections.IDictionary]) {
            throw "Елемент source-set у $Path не є мапою з ключами name/type/path."
        }
        foreach ($key in 'name', 'type', 'path') {
            if (-not $item.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$item[$key])) {
                throw "У source-set файлу $Path бракує ключа '$key'."
            }
        }
        $name    = [string]$item['name']
        $type    = [string]$item['type']
        $relPath = [string]$item['path']

        if ($script:KnownSourceSetTypes -notcontains $type) {
            throw "source-set '$name' у $Path має невідомий type '$type'. Kit знає: $($script:KnownSourceSetTypes -join ', ')."
        }
        if ($seen.ContainsKey($name)) {
            throw "source-set '$name' оголошено в $Path двічі."
        }
        $seen[$name] = $true

        $sets.Add([pscustomobject]@{
            Name     = $name
            Type     = $type
            Path     = (($relPath -replace '\\', '/').TrimEnd('/'))
            FullPath = [System.IO.Path]::GetFullPath((Join-Path $dir $relPath))
        })
    }

    $connection = $null
    if ($data.Contains('infobase') -and $data['infobase'] -is [System.Collections.IDictionary] -and
        $data['infobase'].Contains('connection') -and
        -not [string]::IsNullOrWhiteSpace([string]$data['infobase']['connection'])) {
        $connection = [string]$data['infobase']['connection']
    }

    $workPath = 'build'
    if ($data.Contains('workPath') -and -not [string]::IsNullOrWhiteSpace([string]$data['workPath'])) {
        $workPath = [string]$data['workPath']
    }

    [pscustomobject]@{
        Path               = $full
        Directory          = $dir
        WorkPath           = $workPath
        InfobaseConnection = $connection
        SourceSets         = $sets.ToArray()
    }
}

function Read-V8ProjectLocalInfobase {
    <#
    .SYNOPSIS
        infobase.connection з v8project.local.yaml або $null.
    .DESCRIPTION
        Це файл Уніки, і kit читає з нього рівно один ключ, і рівно з двох причин (спека
        §2.5): (1) canon/provision мусять цілитись у ту саму базу агента, яку наповнює
        operation=build, тож ідуть за вказівником Уніки; (2) check аудитує, чи не лежить
        тут підключення до бази ЛЮДИНИ з накладки kit. Жодне інше значення звідси kit не
        бере — дев-бази, сховища й шаблони .dt живуть у v8storagekit.local.yaml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $data = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $data -or -not $data.Contains('infobase')) { return $null }
    $ib = $data['infobase']
    if ($ib -isnot [System.Collections.IDictionary] -or -not $ib.Contains('connection')) { return $null }
    $connection = [string]$ib['connection']
    if ([string]::IsNullOrWhiteSpace($connection)) { return $null }
    $connection
}

function Resolve-V8AgentInfobase {
    <#
    .SYNOPSIS
        База агента так, як її бачить Unica: v8project.local.yaml → v8project.yaml.
    .DESCRIPTION
        Повертає сирий рядок підключення і файл-джерело. Відносний File= (наприклад
        'File=build/ib') тут НЕ розв'язується — це робить викликач від Project.Directory,
        коли справді збирає ключ /F для платформи (B4). $null — у воркспейсі бази немає
        (зовнішні обробки).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)

    $localPath = Join-Path $Project.Directory 'v8project.local.yaml'
    $local = Read-V8ProjectLocalInfobase -Path $localPath
    if ($local) {
        return [pscustomobject]@{ Connection = $local; Origin = $localPath }
    }
    if ($Project.InfobaseConnection) {
        return [pscustomobject]@{ Connection = $Project.InfobaseConnection; Origin = $Project.Path }
    }
    $null
}

Export-ModuleMember -Function Read-V8Project, Read-V8ProjectLocalInfobase, Resolve-V8AgentInfobase
```

- [ ] **Step 5: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/V8Project.psm1 tools/tests/V8Project.Tests.ps1 tools/tests/fixtures/v8project-extension.yaml tools/tests/fixtures/v8project-epf.yaml
git commit -m "B1: V8Project.psm1 — source-set-и й вказівник на базу агента з файлів Уніки"
```

---

### Task 3: `Manifest.psm1` — схема `v8storagekit.yaml` і накладки `v8storagekit.local.yaml`

Схема строга: невідомий ключ на будь-якому рівні — зупинка з переліком дозволених.
Помилка в маніфесті коштує дорожче за незручність — це файл, за яким `sync` вирішує, куди
писати гілки, а `dump` — яку теку стирати.

**Files:**
- Create: `tools/lib/Manifest.psm1`
- Create: `tools/tests/Manifest.Tests.ps1`
- Create: `tools/tests/fixtures/overlay-sample.yaml`

**Interfaces:**
- Consumes: `Read-KitYaml` (Task 1).
- Produces: `Read-KitManifest`, `Read-KitLocalOverlay`, `Resolve-KitInfobase` (сигнатури — у «Спільних контрактах»). Значення за замовчуванням: `StorageUser = 'gitbot'`, `MainBranch = 'main'`.

- [ ] **Step 1: Фікстура накладки — дослівно спека §2.5**

`tools/tests/fixtures/overlay-sample.yaml`:

```yaml
infobases:                          # живі бази, з яких kit ЛИШЕ читає
  devUNF:
    connection: 'Srvr="VSDEV";Ref="SMP_UNF_sydorenko";'
    user: 'Администратор'
  devUNFru:
    connection: 'Srvr="VSDEV";Ref="SMP_ruUNF_sydorenko";'
    user: 'Абдулов (директор)'

storages:                           # перевизначення шляхів сховищ на цій машині
  SMP_BankExchange_SMB: 'D:\mirror\СМП_BankExchange_SMB'

workspaces:
  SMP_BankExchange_SMB:
    agentBase:
      template: 'D:\dumps\UNF_demo.dt'   # розгорнути з .dt; без ключа — порожня через Unica init
```

- [ ] **Step 2: Тест, що падає**

`tools/tests/Manifest.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Manifest.psm1 — схема v8storagekit.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path

        # Усередині BeforeAll — інакше не доживе до фази run (див. StorageSync.Tests.ps1).
        function script:Write-Yaml {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Lines)
            $p = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $p -Value ($Lines -join "`n") -Encoding UTF8
            $p
        }
    }

    Context 'приклади зі спеки' {
        It 'продуктовий: kind/label, три воркспейси, truth і типові значення' {
            $m = Read-KitManifest -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
            $m.Kind | Should -Be 'product'
            $m.Label | Should -Be 'BankExchange'
            $m.MainBranch | Should -Be 'main'
            $m.Workspaces.Count | Should -Be 3

            $smb = $m.Workspaces[0].Sources | Where-Object Key -eq 'SMP_BankExchange_SMB'
            $smb.Truth | Should -Be 'storage'
            $smb.StoragePath | Should -Be 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
            $smb.StorageUser | Should -Be 'gitbot'

            $base = $m.Workspaces[0].Sources | Where-Object Key -eq 'base'
            $base.Truth | Should -Be 'vendor'
            $base.DumpFrom | Should -Be 'devUNF'
            $base.StoragePath | Should -BeNullOrEmpty

            # user не вказано — типовий gitbot
            ($m.Workspaces[1].Sources | Where-Object Key -eq 'SMP_BankExchange_SMBru').StorageUser | Should -Be 'gitbot'
            ($m.Workspaces[2].Sources | Where-Object Key -eq 'external-processors').Truth | Should -Be 'git'
        }

        It 'клієнтський: base під сховищем, кириличний ключ, користувач сховища за іменем бази' {
            $m = Read-KitManifest -Path (Join-Path $script:Fixtures 'manifest-client.yaml')
            $m.Kind | Should -Be 'client'
            $m.Label | Should -Be 'Alpenpharma'
            $src = $m.Workspaces[0].Sources
            ($src | Where-Object Key -eq 'base').Truth | Should -Be 'storage'
            $src.Key | Should -Contain 'Адаптация'
            ($src | Where-Object Key -eq 'SMP_BankExchange_SMB').StorageUser | Should -Be 'Alpenpharma'
        }
    }

    Context 'відмови схеми — кожна називає місце і причину' {
        It 'невідомий truth' {
            $p = Write-Yaml 'bad-truth.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: mirror }')
            { Read-KitManifest -Path $p } | Should -Throw "*'mirror'*storage, dump, vendor, git*"
        }
        It 'truth: storage без storage.path' {
            $p = Write-Yaml 'no-storage-path.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: storage, storage: { user: u } }')
            { Read-KitManifest -Path $p } | Should -Throw "*'path'*"
        }
        It 'truth: storage без блоку storage:' {
            $p = Write-Yaml 'no-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: storage }')
            { Read-KitManifest -Path $p } | Should -Throw '*storage:*'
        }
        It 'truth: storage зі storage: і dump: одночасно — суперечність' {
            $p = Write-Yaml 'storage-with-dump.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: storage, storage: { path: 'x' }, dump: { from: 'y' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*storage*dump:*'
        }
        It 'truth: vendor без dump.from' {
            $p = Write-Yaml 'no-from.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: vendor }')
            { Read-KitManifest -Path $p } | Should -Throw '*dump:*from*'
        }
        It 'truth: vendor: dump.from порожній при наявному блоці dump: — зупинка' {
            $p = Write-Yaml 'empty-dump-from.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: vendor, dump: { from: '' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*dump.from*порожній*'
        }
        It 'truth: dump зі storage: одночасно — суперечність' {
            $p = Write-Yaml 'dump-with-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: dump, dump: { from: 'x' }, storage: { path: 'y' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*dump*storage:*'
        }
        It 'truth: git зі storage: — суперечність' {
            $p = Write-Yaml 'git-with-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, storage: { path: 'x' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*git*storage*'
        }
        It 'truth: git з dump: — суперечність' {
            $p = Write-Yaml 'git-with-dump.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, dump: { from: 'x' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*git*dump*'
        }
        It 'невідомий кореневий ключ' {
            $p = Write-Yaml 'unknown-root.yaml' @('version: 1', 'product: X', 'products: Y', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw "*'products'*version, product, client, mainBranch, workspaces*"
        }
        It 'невідомий ключ усередині джерела (структуру описує v8project.yaml, не маніфест)' {
            $p = Write-Yaml 'unknown-source-key.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, path: 'cfe/src' }")
            { Read-KitManifest -Path $p } | Should -Throw "*'path'*truth, storage, dump*"
        }
        It 'product і client разом — зупинка' {
            $p = Write-Yaml 'both.yaml' @('version: 1', 'product: X', 'client: Y', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*product*client*'
        }
        It 'ні product, ні client — зупинка' {
            $p = Write-Yaml 'neither.yaml' @('version: 1', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*product*client*'
        }
        It 'version: 2 — зупинка' {
            $p = Write-Yaml 'v2.yaml' @('version: 2', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*version*'
        }
        It 'workspaces[].path із роздільником — зупинка (воркспейс лише безпосередньо в корені)' {
            $p = Write-Yaml 'nested-ws.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: a/b', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw "*'a/b'*"
        }
        It 'той самий воркспейс двічі — зупинка' {
            $p = Write-Yaml 'dup-ws.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }', '  - path: A', '    sources:', '      b: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*двічі*'
        }
    }

    Context 'mainBranch' {
        It 'типово main; явний master приймається' {
            $p = Write-Yaml 'master.yaml' @('version: 1', 'product: X', 'mainBranch: master', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            (Read-KitManifest -Path $p).MainBranch | Should -Be 'master'
        }
        It 'mainBranch у просторі storage/ — зупинка' {
            $p = Write-Yaml 'bad-main.yaml' @('version: 1', 'product: X', 'mainBranch: storage/x', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*mainBranch*'
        }
    }
}

Describe 'Manifest.psm1 — накладка v8storagekit.local.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path
        function script:Write-Yaml {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Lines)
            $p = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $p -Value ($Lines -join "`n") -Encoding UTF8
            $p
        }
    }

    It 'читає приклад зі спеки: дві дев-бази, перевизначення сховища, шаблон бази агента' {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Fixtures 'overlay-sample.yaml')
        $o.Infobases.Count | Should -Be 2
        $o.Infobases['devUNFru'].Connection | Should -Be 'Srvr="VSDEV";Ref="SMP_ruUNF_sydorenko";'
        $o.Infobases['devUNFru'].User | Should -Be 'Абдулов (директор)'
        $o.Storages['SMP_BankExchange_SMB'] | Should -Be 'D:\mirror\СМП_BankExchange_SMB'
        $o.Workspaces['SMP_BankExchange_SMB'].AgentBaseTemplate | Should -Be 'D:\dumps\UNF_demo.dt'
    }

    It 'порожня накладка — порожні таблиці, не помилка' {
        $p = Write-Yaml 'empty-overlay.yaml' @('# ще нічого')
        $o = Read-KitLocalOverlay -Path $p
        $o.Infobases.Count | Should -Be 0
        $o.Storages.Count | Should -Be 0
    }

    It 'невідомий кореневий ключ (наприклад, devInfobase зі старої конвенції) — зупинка' {
        $p = Write-Yaml 'old-overlay.yaml' @('devInfobase:', "  connection: 'File=x'")
        { Read-KitLocalOverlay -Path $p } | Should -Throw "*'devInfobase'*infobases, storages, workspaces*"
    }

    It 'дев-база без connection — зупинка' {
        $p = Write-Yaml 'no-conn.yaml' @('infobases:', '  dev:', "    user: 'u'")
        { Read-KitLocalOverlay -Path $p } | Should -Throw "*'connection'*"
    }

    It 'Resolve-KitInfobase: знайдено — об''єкт; немає — зупинка з готовим блоком для вставки' {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Fixtures 'overlay-sample.yaml')
        (Resolve-KitInfobase -Overlay $o -Name 'devUNF').User | Should -Be 'Администратор'
        { Resolve-KitInfobase -Overlay $o -Name 'devBP' } | Should -Throw '*devBP*infobases:*connection:*'
        { Resolve-KitInfobase -Overlay $null -Name 'devBP' } | Should -Throw '*devBP*'
    }
}
```

- [ ] **Step 3: Запустити — червоно**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 4: Реалізація `tools/lib/Manifest.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Yaml.psm1"

# Словник truth (спека §2.4) і типові значення. Це єдине місце, де вони оголошені.
$script:TruthValues         = @('storage', 'dump', 'vendor', 'git')
$script:DefaultStorageUser  = 'gitbot'
$script:DefaultMainBranch   = 'main'

function Assert-KitMapKeys {
    <#
    .SYNOPSIS
        Мапа має рівно дозволені ключі й усі обов'язкові. Невідомий ключ — зупинка з
        переліком дозволених: помилка в маніфесті не має проходити мовчки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Map,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string[]]$Required = @(),
        [Parameter(Mandatory)][string]$Where
    )

    if ($Map -isnot [System.Collections.IDictionary]) {
        throw "$Where має бути мапою (ключ: значення)."
    }
    foreach ($r in $Required) {
        if (-not $Map.Contains($r)) { throw "$Where — бракує обов'язкового ключа '$r'." }
    }
    foreach ($k in @($Map.Keys)) {
        if ($Allowed -notcontains [string]$k) {
            throw "$Where — невідомий ключ '$k'. Дозволені: $($Allowed -join ', ')."
        }
    }
}

function Read-KitManifest {
    <#
    .SYNOPSIS
        Читає й валідує v8storagekit.yaml (спека §2.4).
    .DESCRIPTION
        Маніфест не дублює структури — шляхи й типи описує v8project.yaml; тут лише truth
        кожного джерела й те, чого Unica не знає (сховище, дев-база). Звірка ключів sources
        з name: source-set-ів — робота Invoke-KitPreflight, не цього модуля.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $m = Read-KitYaml -Path $Path
    $where = "Маніфест $Path"
    Assert-KitMapKeys -Map $m -Allowed @('version', 'product', 'client', 'mainBranch', 'workspaces') `
        -Required @('version', 'workspaces') -Where $where

    if ([string]$m['version'] -ne '1') {
        throw "$where — version: $($m['version']) не підтримується; kit знає лише version: 1."
    }

    $hasProduct = $m.Contains('product')
    $hasClient  = $m.Contains('client')
    if ($hasProduct -eq $hasClient) {
        $state = if ($hasProduct) { 'вказано обидва' } else { 'не вказано жодного' }
        throw "$where — має бути рівно один із ключів product: або client: ($state)."
    }
    $label = if ($hasProduct) { [string]$m['product'] } else { [string]$m['client'] }
    if ([string]::IsNullOrWhiteSpace($label)) { throw "$where — значення product:/client: порожнє." }

    $mainBranch = $script:DefaultMainBranch
    if ($m.Contains('mainBranch')) {
        $mainBranch = [string]$m['mainBranch']
        if ([string]::IsNullOrWhiteSpace($mainBranch) -or $mainBranch -match '\s' -or $mainBranch.StartsWith('storage/')) {
            throw "$where — mainBranch: '$mainBranch' не схоже на ім'я гілки або лежить у просторі storage/, зарезервованому для дзеркал сховищ."
        }
    }

    $wsRaw = $m['workspaces']
    if ($wsRaw -isnot [System.Collections.IList] -or $wsRaw.Count -eq 0) {
        throw "$where — workspaces: має бути непорожнім списком."
    }

    $workspaces = [System.Collections.Generic.List[object]]::new()
    $seenPaths  = @{}
    foreach ($ws in $wsRaw) {
        Assert-KitMapKeys -Map $ws -Allowed @('path', 'sources') -Required @('path', 'sources') -Where "$where, елемент workspaces"
        $wsPath = ([string]$ws['path']).Trim()
        if (-not $wsPath -or $wsPath -match '[\\/]' -or $wsPath -eq '.' -or $wsPath -eq '..') {
            throw "$where — workspaces[].path '$wsPath' має бути ім'ям теки безпосередньо в корені репозиторію (без роздільників)."
        }
        if ($seenPaths.ContainsKey($wsPath)) { throw "$where — воркспейс '$wsPath' оголошено двічі." }
        $seenPaths[$wsPath] = $true

        $srcRaw = $ws['sources']
        if ($srcRaw -isnot [System.Collections.IDictionary] -or $srcRaw.Count -eq 0) {
            throw "$where, воркспейс '$wsPath' — sources: має бути непорожньою мапою «ключ джерела → опис»."
        }

        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($key in @($srcRaw.Keys)) {
            $src    = $srcRaw[$key]
            $swhere = "$where, воркспейс '$wsPath', джерело '$key'"
            Assert-KitMapKeys -Map $src -Allowed @('truth', 'storage', 'dump') -Required @('truth') -Where $swhere

            $truth = [string]$src['truth']
            if ($script:TruthValues -notcontains $truth) {
                throw "$swhere — truth: '$truth' невідомий. Дозволені: $($script:TruthValues -join ', ')."
            }

            $storagePath = $null; $storageUser = $null; $dumpFrom = $null
            switch ($truth) {
                'storage' {
                    if (-not $src.Contains('storage')) { throw "$swhere — truth: storage потребує блоку storage: { path: … }." }
                    if ($src.Contains('dump'))         { throw "$swhere — truth: storage не поєднується з dump:." }
                    Assert-KitMapKeys -Map $src['storage'] -Allowed @('path', 'user') -Required @('path') -Where "$swhere, storage"
                    $storagePath = [string]$src['storage']['path']
                    if ([string]::IsNullOrWhiteSpace($storagePath)) { throw "$swhere — storage.path порожній." }
                    $storageUser = $script:DefaultStorageUser
                    if ($src['storage'].Contains('user') -and -not [string]::IsNullOrWhiteSpace([string]$src['storage']['user'])) {
                        $storageUser = [string]$src['storage']['user']
                    }
                }
                { $_ -in @('dump', 'vendor') } {
                    if (-not $src.Contains('dump')) { throw "$swhere — truth: $truth потребує блоку dump: { from: <ключ у infobases: накладки> }." }
                    if ($src.Contains('storage'))   { throw "$swhere — truth: $truth не поєднується зі storage:." }
                    Assert-KitMapKeys -Map $src['dump'] -Allowed @('from') -Required @('from') -Where "$swhere, dump"
                    $dumpFrom = [string]$src['dump']['from']
                    if ([string]::IsNullOrWhiteSpace($dumpFrom)) { throw "$swhere — dump.from порожній." }
                }
                'git' {
                    if ($src.Contains('storage') -or $src.Contains('dump')) {
                        throw "$swhere — truth: git означає, що зовнішнього джерела немає: ні storage:, ні dump: тут не буває."
                    }
                }
            }

            $sources.Add([pscustomobject]@{
                Key         = [string]$key
                Truth       = $truth
                StoragePath = $storagePath
                StorageUser = $storageUser
                DumpFrom    = $dumpFrom
            })
        }
        $workspaces.Add([pscustomobject]@{ Path = $wsPath; Sources = $sources.ToArray() })
    }

    [pscustomobject]@{
        Path       = (Resolve-Path -LiteralPath $Path).Path
        Version    = 1
        Kind       = $(if ($hasProduct) { 'product' } else { 'client' })
        Label      = $label
        MainBranch = $mainBranch
        Workspaces = $workspaces.ToArray()
    }
}

function Read-KitLocalOverlay {
    <#
    .SYNOPSIS
        Читає v8storagekit.local.yaml (спека §2.5) — гітігноровану накладку цієї машини.
    .DESCRIPTION
        Тут живуть усі локальні сутності kit: дев-бази, з яких лише читаємо; перевизначення
        шляхів сховищ; шаблон .dt для бази агента. Файл порожній або відсутній — законно:
        повертаються порожні таблиці. Дубльований ключ (дві бази під одним ім'ям) відхиляє
        сам парсер — це наступник запобіжника Read-V8LocalConnection.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Infobases = @{}; Storages = @{}; Workspaces = @{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    $o = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $o) { return $result }
    $where = "Накладка $Path"
    Assert-KitMapKeys -Map $o -Allowed @('infobases', 'storages', 'workspaces') -Where $where

    if ($o.Contains('infobases')) {
        if ($o['infobases'] -isnot [System.Collections.IDictionary]) { throw "$where — infobases: має бути мапою «ім'я → { connection, user }»." }
        foreach ($name in @($o['infobases'].Keys)) {
            $ib = $o['infobases'][$name]
            Assert-KitMapKeys -Map $ib -Allowed @('connection', 'user') -Required @('connection') -Where "$where, infobases.$name"
            $conn = [string]$ib['connection']
            if ([string]::IsNullOrWhiteSpace($conn)) { throw "$where — infobases.$name.connection порожній." }
            $user = ''
            if ($ib.Contains('user')) { $user = [string]$ib['user'] }
            $result.Infobases[[string]$name] = [pscustomobject]@{ Name = [string]$name; Connection = $conn; User = $user }
        }
    }

    if ($o.Contains('storages')) {
        if ($o['storages'] -isnot [System.Collections.IDictionary]) { throw "$where — storages: має бути мапою «ключ джерела → шлях»." }
        foreach ($key in @($o['storages'].Keys)) {
            $p = [string]$o['storages'][$key]
            if ([string]::IsNullOrWhiteSpace($p)) { throw "$where — storages.$key порожній." }
            $result.Storages[[string]$key] = $p
        }
    }

    if ($o.Contains('workspaces')) {
        if ($o['workspaces'] -isnot [System.Collections.IDictionary]) { throw "$where — workspaces: має бути мапою «тека воркспейсу → { agentBase }»." }
        foreach ($wsPath in @($o['workspaces'].Keys)) {
            $ws = $o['workspaces'][$wsPath]
            Assert-KitMapKeys -Map $ws -Allowed @('agentBase') -Where "$where, workspaces.$wsPath"
            $template = $null
            if ($ws.Contains('agentBase')) {
                Assert-KitMapKeys -Map $ws['agentBase'] -Allowed @('template') -Where "$where, workspaces.$wsPath.agentBase"
                if ($ws['agentBase'].Contains('template')) { $template = [string]$ws['agentBase']['template'] }
            }
            $result.Workspaces[[string]$wsPath] = [pscustomobject]@{ Path = [string]$wsPath; AgentBaseTemplate = $template }
        }
    }

    $result
}

function Resolve-KitInfobase {
    <#
    .SYNOPSIS
        Дев-база за ключем dump.from — з накладки, або зупинка з готовим блоком для вставки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Overlay,
        [Parameter(Mandatory)][string]$Name,
        [string]$OverlayPath = 'v8storagekit.local.yaml'
    )

    if ($null -eq $Overlay -or -not $Overlay.Infobases.ContainsKey($Name)) {
        throw ("Дев-базу '$Name' не описано в $OverlayPath під infobases: — додайте блок`n" +
               "infobases:`n  ${Name}:`n    connection: 'Srvr=`"<сервер>`";Ref=`"<база>`";'   # або File=`"<шлях>`"`n    user: '<користувач>'")
    }
    $Overlay.Infobases[$Name]
}

Export-ModuleMember -Function Assert-KitMapKeys, Read-KitManifest, Read-KitLocalOverlay, Resolve-KitInfobase
```

- [ ] **Step 5: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/Manifest.psm1 tools/tests/Manifest.Tests.ps1 tools/tests/fixtures/overlay-sample.yaml
git commit -m "B1: Manifest.psm1 — строга схема v8storagekit.yaml і локальної накладки"
```

---

### Task 4: `Preflight.psm1` і фікстура `New-KitFakeRepo`

Префлайт збирає **контекст команди**: маніфест, накладка, кожен воркспейс із його
`v8project.yaml`, кожне джерело — уже розв'язане (тип, шляхи, сховище з перевизначенням,
гілка). Режим `-Lenient` — для `check`, якому треба назвати все, що не так, а не зупинитись
на першому.

Фікстура `New-KitFakeRepo` — синтетичний репозиторій-споживач, на якому працюють тести
B1–B4. Вона створюється тут, бо саме префлайт першим потребує «справжнього» дерева.

**Files:**
- Create: `tools/lib/Preflight.psm1`
- Create: `tools/tests/fixtures/KitFixtures.psm1`
- Create: `tools/tests/Preflight.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-V8RepoRoot` (`RepoRoot.psm1`), `Read-KitManifest`, `Read-KitLocalOverlay` (Task 3), `Read-V8Project` (Task 2).
- Produces: `New-KitFinding`, `Invoke-KitPreflight -RepoRoot [-Lenient]`, `Select-KitSources -Context [-Workspace] [-Source] [-Truth]`; фікстура `New-KitFakeRepo` (параметри — у «Спільних контрактах»; `-WithHooks` додає Task 6).

- [ ] **Step 1: Фікстура `tools/tests/fixtures/KitFixtures.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Синтетичний репозиторій-споживач для тестів kit.
.DESCRIPTION
    Створює під -Root ізольований git-репозиторій з маніфестом, накладкою (за бажанням),
    воркспейсами з v8project.yaml і мінімальними деревами джерел, AUTHORS і першим комітом
    на гілці main. Тести НЕ чіпають справжніх репозиторіїв цієї машини — лише це дерево.

    Типовий воркспейс — один, 'Alpha_SMB': base (CONFIGURATION, cf/src, truth: vendor)
    і Alpha_SMB (EXTENSION, cfe/src, truth: storage, шлях до сховища навмисно неіснуючий).
    -Workspaces переозначує набір; -ManifestText — пише маніфест дослівно замість
    згенерованого (для тестів схеми й розбіжностей).
#>

function Invoke-KitFakeGit {
    <#
    .SYNOPSIS
        git для фікстури з перевіркою коду виходу.
    .DESCRIPTION
        Global Constraints B1: нативні команди перевіряються через $LASTEXITCODE явно —
        на цій машині $PSNativeCommandUseErrorActionPreference = $false, тож git, що впав,
        сам винятку не кине. Фікстура довгограюча (задачі 6 і 8 будують на ній коміти й
        гілки storage/*), і мовчазний збій тут дав би провал далеко від причини.

        Навмисно проста функція — без [CmdletBinding()] і без param(): $args приймає усі
        токени позиційно, і PowerShell не намагається зіставити жоден з них з іменем
        оголошеного параметра. Варіант з [CmdletBinding()] і
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments ламав саме
        `git add -A`: "-A" PowerShell розпізнавав як скорочену форму -Arguments (унікальний
        префікс імені параметра серед оголошених), а не як аргумент git, і кидав "Missing an
        argument for parameter 'Arguments'". Внутрішній хелпер фікстури — не Export-ModuleMember.
    #>
    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($args -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")"
    }
    $out
}

function New-KitFakeConfigurationXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Мінімальний Designer XML: check читає перший <Name> — саме так лежить у справжньому
    # Configuration.xml (Properties → Name, рядок 44 у SMP_BankExchange_SMB).
    @(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.17">'
        '	<Configuration uuid="00000000-0000-0000-0000-000000000000">'
        '		<Properties>'
        "			<Name>$Name</Name>"
        '		</Properties>'
        '	</Configuration>'
        '</MetaDataObject>'
    ) -join "`r`n"
}

function New-KitFakeRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ManifestText,
        [string]$OverlayText,
        [System.Collections.IDictionary]$Workspaces,
        [switch]$WithGitattributes,
        [switch]$WithGitignore,
        [switch]$NoCommit
    )

    $kitRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-KitFakeGit -C $Root init -q | Out-Null
    Invoke-KitFakeGit -C $Root config user.email 'test@example.invalid' | Out-Null
    Invoke-KitFakeGit -C $Root config user.name 'Test Bot' | Out-Null
    Invoke-KitFakeGit -C $Root config commit.gpgsign false | Out-Null
    # Детермінованість, а не тиша: без цього фікстура успадковує core.autocrlf машини,
    # яка її запускає, і git add/commit нижче друкує "warning: CRLF will be replaced by
    # LF" щоразу, коли autocrlf глобально ввімкнено, — вивід тестів мав би залежати від
    # налаштувань чужого середовища.
    Invoke-KitFakeGit -C $Root config core.autocrlf false | Out-Null
    # Головна гілка — main незалежно від init.defaultBranch цієї машини.
    Invoke-KitFakeGit -C $Root symbolic-ref HEAD refs/heads/main | Out-Null

    if (-not $Workspaces) {
        $Workspaces = [ordered]@{
            'Alpha_SMB' = @{
                Infobase = 'File=build/ib'
                Sets     = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
    }

    $manifest = [System.Collections.Generic.List[string]]::new()
    $manifest.Add('version: 1')
    $manifest.Add('product: Fake')
    $manifest.Add('workspaces:')

    foreach ($wsName in @($Workspaces.Keys)) {
        $ws    = $Workspaces[$wsName]
        $wsDir = Join-Path $Root $wsName
        New-Item -ItemType Directory -Path $wsDir -Force | Out-Null

        $proj = [System.Collections.Generic.List[string]]::new()
        $proj.Add('format: DESIGNER'); $proj.Add('builder: DESIGNER'); $proj.Add("workPath: 'build'")
        if ($ws.Contains('Infobase') -and $ws['Infobase']) {
            $proj.Add('infobase:'); $proj.Add("  connection: '$($ws['Infobase'])'")
        }
        $proj.Add('source-set:')

        $manifest.Add("  - path: $wsName")
        $manifest.Add('    sources:')
        foreach ($set in $ws['Sets']) {
            $proj.Add("  - name: $($set.Name)"); $proj.Add("    type: $($set.Type)"); $proj.Add("    path: '$($set.Path)'")
            $setDir = Join-Path $wsDir $set.Path
            New-Item -ItemType Directory -Path $setDir -Force | Out-Null
            switch ($set.Type) {
                'CONFIGURATION' {
                    # vendor: дерево лишається порожнім і в git не потрапляє — як у споживача без дампу.
                    $manifest.Add("      $($set.Name): { truth: vendor, dump: { from: dev } }")
                }
                'EXTENSION' {
                    Set-Content -LiteralPath (Join-Path $setDir 'Configuration.xml') -Encoding UTF8 -NoNewline `
                        -Value (New-KitFakeConfigurationXml -Name $set.Name)
                    # Сховище навмисно неіснуюче: тести B1 до сховищ не звертаються, а перший
                    # же запуск sync упаде на «Каталог сховища не знайдено», не діставшись платформи.
                    $storage = Join-Path (Split-Path -Parent $Root) "no-such-storage-$($set.Name)"
                    $manifest.Add("      $($set.Name):")
                    $manifest.Add('        truth: storage')
                    $manifest.Add("        storage: { path: '$storage' }")
                }
                'EXTERNAL_DATA_PROCESSORS' {
                    Set-Content -LiteralPath (Join-Path $setDir 'README.md') -Value 'обробки' -Encoding UTF8
                    $manifest.Add("      $($set.Name): { truth: git }")
                }
            }
        }
        Set-Content -LiteralPath (Join-Path $wsDir 'v8project.yaml') -Value ($proj -join "`n") -Encoding UTF8
    }

    $manifestPath = Join-Path $Root 'v8storagekit.yaml'
    if ($PSBoundParameters.ContainsKey('ManifestText')) {
        Set-Content -LiteralPath $manifestPath -Value $ManifestText -Encoding UTF8
    } else {
        Set-Content -LiteralPath $manifestPath -Value ($manifest -join "`n") -Encoding UTF8
    }
    if ($OverlayText) {
        Set-Content -LiteralPath (Join-Path $Root 'v8storagekit.local.yaml') -Value $OverlayText -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $Root 'AUTHORS') -Value 'gitbot=Test Bot <test@example.invalid>' -Encoding UTF8

    if ($WithGitattributes) { Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitattributes') -Destination (Join-Path $Root '.gitattributes') }
    if ($WithGitignore)     { Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitignore')     -Destination (Join-Path $Root '.gitignore') }

    if (-not $NoCommit) {
        Invoke-KitFakeGit -C $Root add -A | Out-Null
        Invoke-KitFakeGit -C $Root commit -q -m 'фікстура: репозиторій-споживач' | Out-Null
    }
    $Root
}

Export-ModuleMember -Function New-KitFakeRepo, New-KitFakeConfigurationXml
```

- [ ] **Step 2: Тест, що падає**

`tools/tests/Preflight.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Preflight.psm1 — контекст команди з маніфесту, накладки й v8project.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'типовий репозиторій: один воркспейс, два джерела, усе розв''язано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ok')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ctx.Ok | Should -BeTrue
        $ctx.Kind | Should -Be 'product'
        $ctx.MainBranch | Should -Be 'main'
        $ctx.Overlay | Should -BeNullOrEmpty
        $ctx.Workspaces.Count | Should -Be 1

        $ws = $ctx.Workspaces[0]
        $ws.Path | Should -Be 'Alpha_SMB'
        $ws.Project.SourceSets.Count | Should -Be 2

        $ext = $ws.Sources | Where-Object Key -eq 'Alpha_SMB'
        $ext.Truth | Should -Be 'storage'
        $ext.Type | Should -Be 'EXTENSION'
        $ext.Path | Should -Be 'cfe/src'
        $ext.RepoPath | Should -Be 'Alpha_SMB/cfe/src'
        $ext.FullPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/cfe/src')))
        $ext.Branch | Should -Be 'storage/Alpha_SMB'
        $ext.StorageUser | Should -Be 'gitbot'

        $base = $ws.Sources | Where-Object Key -eq 'base'
        $base.Truth | Should -Be 'vendor'
        $base.Type | Should -Be 'CONFIGURATION'
        $base.DumpFrom | Should -Be 'dev'
        $base.Branch | Should -BeNullOrEmpty
    }

    It 'накладка перевизначає шлях сховища для цієї машини' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay') -OverlayText "storages:`n  Alpha_SMB: 'D:\mirror\alpha'"
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ctx.OverlayPath | Should -BeLike '*v8storagekit.local.yaml'
        ($ctx.Workspaces[0].Sources | Where-Object Key -eq 'Alpha_SMB').StoragePath | Should -Be 'D:\mirror\alpha'
    }

    It 'без маніфесту — зупинка з підказкою на onboarding; у -Lenient — знахідка, а не виняток' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-manifest')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*v8storagekit.yaml*onboarding*'

        $ctx = Invoke-KitPreflight -RepoRoot $repo -Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 1
        $ctx.Findings[0].Message | Should -BeLike '*v8storagekit.yaml*'
    }

    It 'воркспейс із маніфесту без теки — зупинка з його ім''ям' {
        $text = "version: 1`nproduct: Fake`nworkspaces:`n  - path: Ghost`n    sources:`n      g: { truth: git }"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ghost') -ManifestText $text
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw "*'Ghost'*"
    }

    It 'воркспейс без v8project.yaml — зупинка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-project')
        Remove-Item -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml')
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*Alpha_SMB*v8project.yaml*'
    }

    It 'ключ sources, якого немає серед name: source-set-ів — зупинка з переліком наявних' {
        $text = @(
            'version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            "      Alpha_SMB_typo: { truth: storage, storage: { path: 'x' } }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-key') -ManifestText $text
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw "*'Alpha_SMB_typo'*base, Alpha_SMB*"
    }

    It '-Lenient збирає ВСІ проблеми, а не першу' {
        $text = @(
            'version: 1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:', "      nope: { truth: git }",
            '  - path: Ghost',     '    sources:', "      g: { truth: git }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'lenient') -ManifestText $text
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 2
    }

    Context 'Select-KitSources' {
        BeforeAll {
            $two = [ordered]@{
                'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
                    @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
                'Alpha_ACC' = @{ Infobase = 'File=build/ib'; Sets = @(
                    @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_ACC'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
                'epf'       = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
            }
            $script:Ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'select') -Workspaces $two)
        }

        It 'без фільтрів — усі джерела всіх воркспейсів' {
            @(Select-KitSources -Context $script:Ctx).Count | Should -Be 5
        }
        It '-Truth звужує' {
            @(Select-KitSources -Context $script:Ctx -Truth storage).Key | Should -Be @('Alpha_SMB', 'Alpha_ACC')
        }
        It '-Workspace невідомий — зупинка з переліком' {
            { Select-KitSources -Context $script:Ctx -Workspace 'Beta' } | Should -Throw "*'Beta'*Alpha_SMB, Alpha_ACC, epf*"
        }
        It '-Source унікальний — без -Workspace знаходиться' {
            (Select-KitSources -Context $script:Ctx -Source 'Alpha_ACC').Workspace | Should -Be 'Alpha_ACC'
        }
        It '-Source у двох воркспейсах без -Workspace — зупинка, яка їх називає (Q9)' {
            { Select-KitSources -Context $script:Ctx -Source 'base' } | Should -Throw '*base*Alpha_SMB*Alpha_ACC*-Workspace*'
        }
        It '-Source із -Workspace — однозначно' {
            (Select-KitSources -Context $script:Ctx -Workspace 'Alpha_ACC' -Source 'base').RepoPath | Should -Be 'Alpha_ACC/cf/src'
        }
        It '-Source невідомий — зупинка' {
            { Select-KitSources -Context $script:Ctx -Source 'Nope' } | Should -Throw "*'Nope'*"
        }
    }
}
```

- [ ] **Step 3: Запустити — червоно**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 4: Реалізація `tools/lib/Preflight.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/RepoRoot.psm1"
Import-Module "$PSScriptRoot/Manifest.psm1"
Import-Module "$PSScriptRoot/V8Project.psm1"

$script:ManifestFileName = 'v8storagekit.yaml'
$script:OverlayFileName  = 'v8storagekit.local.yaml'

function New-KitFinding {
    <#
    .SYNOPSIS
        Один рядок звіту check/preflight. error — команда не має права продовжувати;
        warn — працює, але людині варто знати; info — стан, не проблема.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn', 'info')][string]$Level,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Level = $Level; Check = $Check; Message = $Message }
}

function Invoke-KitPreflight {
    <#
    .SYNOPSIS
        Спільний префлайт усіх команд kit (спека §5): маніфест, накладка, воркспейси,
        відповідність ключів джерел source-set-ам. Мілісекунди, без платформи й git-логу.
    .PARAMETER Lenient
        Не кидати, а збирати знахідки в Findings і виставити Ok=$false. Режим check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Lenient
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $ctx = [pscustomobject]@{
        RepoRoot = $null; ManifestPath = $null; OverlayPath = $null
        Manifest = $null; Overlay = $null
        Kind = $null; Label = $null; MainBranch = 'main'
        Workspaces = @(); Findings = $findings; Ok = $true
    }
    $fail = {
        param([string]$Check, [string]$Message)
        if (-not $Lenient) { throw $Message }
        $findings.Add((New-KitFinding -Level error -Check $Check -Message $Message))
        $ctx.Ok = $false
    }

    # Не git-репозиторій — нема з чим працювати навіть у check.
    $root = Resolve-V8RepoRoot -Path $RepoRoot
    $ctx.RepoRoot     = $root
    $ctx.ManifestPath = Join-Path $root $script:ManifestFileName

    if (-not (Test-Path -LiteralPath $ctx.ManifestPath -PathType Leaf)) {
        & $fail 'manifest' ("Маніфест $script:ManifestFileName не знайдено в $root. Репозиторій не підключено до kit — " +
                            'шлях уперед: скіл v8storagekit:onboarding.')
        return $ctx
    }
    try { $ctx.Manifest = Read-KitManifest -Path $ctx.ManifestPath }
    catch { & $fail 'manifest' $_.Exception.Message; return $ctx }
    $ctx.Kind = $ctx.Manifest.Kind; $ctx.Label = $ctx.Manifest.Label; $ctx.MainBranch = $ctx.Manifest.MainBranch

    $overlayPath = Join-Path $root $script:OverlayFileName
    if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
        $ctx.OverlayPath = $overlayPath
        try { $ctx.Overlay = Read-KitLocalOverlay -Path $overlayPath }
        catch { & $fail 'overlay' $_.Exception.Message }
    }

    $workspaces = [System.Collections.Generic.List[object]]::new()
    foreach ($ws in $ctx.Manifest.Workspaces) {
        $wsFull = Join-Path $root $ws.Path
        if (-not (Test-Path -LiteralPath $wsFull -PathType Container)) {
            & $fail 'workspace' "Воркспейс '$($ws.Path)' з маніфесту не знайдено в $root."
            continue
        }
        $projectPath = Join-Path $wsFull 'v8project.yaml'
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            & $fail 'workspace' "У воркспейсі '$($ws.Path)' немає v8project.yaml — структуру джерел описує саме він (спека §2.1)."
            continue
        }
        $project = $null
        try { $project = Read-V8Project -Path $projectPath }
        catch { & $fail 'workspace' $_.Exception.Message; continue }

        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($src in $ws.Sources) {
            $set = $project.SourceSets | Where-Object Name -eq $src.Key | Select-Object -First 1
            if (-not $set) {
                & $fail 'source' ("Джерело '$($src.Key)' воркспейсу '$($ws.Path)' не відповідає жодному name: source-set у " +
                                  "$($ws.Path)/v8project.yaml (є: $($project.SourceSets.Name -join ', ')).")
                continue
            }
            $storagePath = $src.StoragePath
            if ($src.Truth -eq 'storage' -and $ctx.Overlay -and $ctx.Overlay.Storages.ContainsKey($src.Key)) {
                $storagePath = $ctx.Overlay.Storages[$src.Key]
            }
            $sources.Add([pscustomobject]@{
                Key         = $src.Key
                Truth       = $src.Truth
                Type        = $set.Type
                Workspace   = $ws.Path
                Path        = $set.Path
                RepoPath    = "$($ws.Path)/$($set.Path)"
                FullPath    = $set.FullPath
                StoragePath = $storagePath
                StorageUser = $src.StorageUser
                DumpFrom    = $src.DumpFrom
                Branch      = $(if ($src.Truth -eq 'storage') { "storage/$($src.Key)" } else { $null })
            })
        }
        $workspaces.Add([pscustomobject]@{
            Path = $ws.Path; FullPath = $wsFull; Project = $project; Sources = $sources.ToArray()
        })
    }
    $ctx.Workspaces = $workspaces.ToArray()
    $ctx
}

function Select-KitSources {
    <#
    .SYNOPSIS
        Джерела за спільними параметрами -Workspace / -Source / -Truth (спека §5).
    .DESCRIPTION
        -Source без -Workspace дозволений лише коли ключ унікальний у маніфесті (Q9);
        інакше зупинка з переліком воркспейсів. Повертає масив (може бути порожнім) —
        що робити з порожнім, вирішує команда.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [string[]]$Truth
    )

    $workspaces = @($Context.Workspaces)
    if ($Workspace) {
        $selected = @($workspaces | Where-Object Path -eq $Workspace)
        if ($selected.Count -eq 0) {
            throw "Воркспейсу '$Workspace' немає в маніфесті. Є: $($workspaces.Path -join ', ')."
        }
        $workspaces = $selected
    }

    $sources = @($workspaces | ForEach-Object { $_.Sources })
    if ($Source) {
        $matched = @($sources | Where-Object Key -eq $Source)
        if ($matched.Count -eq 0) {
            $scope = if ($Workspace) { "у воркспейсі '$Workspace'" } else { 'у маніфесті' }
            throw "Джерела '$Source' немає $scope. Є: $(($sources.Key | Sort-Object -Unique) -join ', ')."
        }
        if ($matched.Count -gt 1) {
            throw ("Ключ '$Source' є у кількох воркспейсах: $($matched.Workspace -join ', ') — " +
                   'уточніть -Workspace.')
        }
        $sources = $matched
    }
    if ($Truth) {
        $sources = @($sources | Where-Object { $Truth -contains $_.Truth })
    }
    # Без коми-обгортки: виклики в кожному тесті обгортають @(...) самі (як і скрізь
    # у цьому репозиторії, напр. @($ctx.Findings | …)), а `, $sources` тут ламав саме
    # це — @(Select-KitSources …) додає ще один рівень масиву поверх уже "захищеного"
    # $sources, і .Count бачить розмір 1 замість справжньої кількості джерел. Перевірено
    # на pwsh 7.5.4: `function f { $a = @(1,2,3,4,5); , $a }; @(f).Count` дає 1, а не 5.
    $sources
}

Export-ModuleMember -Function New-KitFinding, Invoke-KitPreflight, Select-KitSources
```

- [ ] **Step 5: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 6: Коміт**

```bash
git add tools/lib/Preflight.psm1 tools/tests/fixtures/KitFixtures.psm1 tools/tests/Preflight.Tests.ps1
git commit -m "B1: Preflight.psm1 — контекст команди; фікстура New-KitFakeRepo для тестів"
```

---

### Task 5: `StorageBranch.psm1` — стан синхронізації виводиться з git (§3.2)

Файлу стану немає: «остання залита версія» = трейлер `Storage-Version:` останнього коміту
`storage/<ключ>`. Тут же — інваріанти гілки, які аудитує `check`: лінійна історія, трейлери,
строге зростання, дерево лише в межах шляху джерела.

**Встановлені факти (перевірено на git 2.53.0.windows.1 у цій сесії):**
`git log --format='%x1e%H%x1f%P%x1f%(trailers:only,unfold)'` дає по одному запису на коміт,
розділеному `\x1e`, з полями через `\x1f`; блок трейлерів — рядки `Ключ: значення`, кожен
трейлер із власним переводом рядка. `git rev-parse --verify --quiet refs/heads/<гілка>`
повертає 1 на відсутній гілці без виводу.

**Files:**
- Create: `tools/lib/StorageBranch.psm1`
- Create: `tools/tests/StorageBranch.Tests.ps1`

**Interfaces:**
- Consumes: `New-KitFinding` (Task 4), `New-KitFakeRepo` (тести).
- Produces: `Get-KitStorageBranchName`, `Test-KitBranchExists`, `Get-KitBranchCommits`, `Get-KitStorageBranchLastVersion`, `Test-KitStorageBranchInvariants` (сигнатури — у «Спільних контрактах»). B2 додасть сюди функції worktree.

- [ ] **Step 1: Тест, що падає**

`tools/tests/StorageBranch.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'StorageBranch.psm1 — стан синхронізації з git' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        # Гілку storage/X будуємо тим самим механізмом, що й майбутній sync (B2): orphan через
        # worktree, коміт у ньому, worktree прибирається. Хуки в цій фікстурі не встановлені —
        # тут перевіряються інваріанти, не захист.
        function script:Add-StorageCommit {
            param(
                [Parameter(Mandatory)][string]$Repo,
                [Parameter(Mandatory)][string]$Branch,
                [Parameter(Mandatory)][string]$RepoPath,
                [Parameter(Mandatory)][string]$FileName,
                # AllowEmptyCollection(): без нього Mandatory трактує -Trailers @() як
                # непереданий аргумент і кидає ParameterBindingValidationException. Той самий
                # фікс — у задачі 8 (Add-KitFakeStorageCommit у KitFixtures.psm1).
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Trailers,
                [string]$Subject = 'версія'
            )
            $wt = Join-Path $Repo "build/sync/wt-$([guid]::NewGuid().ToString('N'))"
            if (git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null) {
                git -C $Repo worktree add -q $wt $Branch
            } else {
                git -C $Repo worktree add -q --orphan -b $Branch $wt
            }
            $dir = Join-Path $wt $RepoPath
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $FileName) -Value "вміст $FileName" -Encoding UTF8
            git -C $wt add -A
            $msg = @($Subject, '') + $Trailers
            git -C $wt commit -q -m ($msg -join "`n")
            git -C $Repo worktree remove --force $wt
        }
    }

    It 'імʼя гілки джерела' {
        Get-KitStorageBranchName -SourceKey 'SMP_BankExchange_SMB' | Should -Be 'storage/SMP_BankExchange_SMB'
    }

    It 'гілки немає — LastVersion = $null, інваріантів немає що порушувати' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'none')
        Test-KitBranchExists -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeFalse
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeNullOrEmpty
        @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src').Count | Should -Be 0
    }

    It 'версії 17, 18, 21 — остання 21; кореневий коміт без батьків проходить; знахідок нуль' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ok')
        foreach ($v in 17, 18, 21) {
            Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v", 'Storage-User: gitbot')
        }
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 21
        $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
        $commits.Count | Should -Be 3
        $commits[0].Parents.Count | Should -Be 0
        $commits[1].Parents.Count | Should -Be 1
        $commits[2].Trailers['Storage-Version'] | Should -Be '21'
        @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src').Count | Should -Be 0
        # Робоча копія й HEAD основного дерева не рухались (§3.3, шар 1)
        git -C $repo branch --show-current | Should -Be 'main'
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }

    It 'немонотонний трейлер — помилка, яка називає обидві версії й коміт' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'nonmono')
        foreach ($v in 17, 21, 18) {
            Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        $f.Count | Should -Be 1
        $f[0].Level | Should -Be 'error'
        $f[0].Message | Should -BeLike '*21*18*'
    }

    It 'коміт без трейлера Storage-Version — помилка; LastVersion зупиняється, а не вгадує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'notrailer')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'b.xml' -Trailers @() -Subject 'ручний коміт без трейлерів'
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Version*').Count | Should -BeGreaterOrEqual 1
        { Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' } | Should -Throw '*Storage-Version*'
    }

    It 'merge-коміт на storage/X — помилка (два батьки), кореневий без батьків — ні' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        # Злиття main у гілку сховища — саме те, що забороняє §3.2. Робимо в тимчасовому worktree,
        # щоб не чіпати робочу копію, і без хуків (їх у цій фікстурі немає).
        $wt = Join-Path $repo 'build/sync/merge-wt'
        git -C $repo worktree add -q $wt 'storage/Alpha_SMB'
        git -C $wt merge -q --allow-unrelated-histories --no-edit -m "злиття main`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" main
        git -C $repo worktree remove --force $wt
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*батьк*').Count | Should -Be 1
    }

    It 'файл поза шляхом джерела в дереві storage/X — помилка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'stray')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Other/place' -FileName 'stray.txt' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 2')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Other/place/stray.txt*').Count | Should -Be 1
    }

    It 'Storage-Source іншого джерела — помилка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrongsource')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Beta', 'Storage-Version: 1')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Source*Beta*').Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Запустити — червоно**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 3: Реалізація `tools/lib/StorageBranch.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"

$script:BranchPrefix = 'storage/'

function Get-KitStorageBranchName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceKey)
    "$script:BranchPrefix$SourceKey"
}

function Test-KitBranchExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)
    git -C $RepoRoot rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

function Get-KitBranchCommits {
    <#
    .SYNOPSIS
        Коміти ref-а від кореня до вершини: Sha, Parents, Trailers — одним викликом git log.
    .DESCRIPTION
        Формат: запис на коміт через \x1e, поля через \x1f, трейлери — блок рядків
        «Ключ: значення» (%(trailers:only,unfold)). Розбирається тут, а не по одному
        interpret-trailers на коміт: на сотнях версій це різниця між секундою й хвилиною.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Ref)

    $raw = git -C $RepoRoot log --reverse --format='%x1e%H%x1f%P%x1f%(trailers:only,unfold)' $Ref 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git log $Ref завершився з кодом ${LASTEXITCODE}: $($raw -join "`n")" }

    $text    = (@($raw) -join "`n")
    $records = @($text -split [char]0x1e | Where-Object { $_.Trim() })
    $result  = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $records) {
        $parts    = $rec -split [char]0x1f, 3
        $trailers = [ordered]@{}
        if ($parts.Count -ge 3) {
            foreach ($line in ($parts[2] -split "`r?`n")) {
                if ($line -match '^(?<k>[A-Za-z][A-Za-z0-9-]*):\s*(?<v>.*)$') { $trailers[$Matches.k] = $Matches.v.Trim() }
            }
        }
        $parents = @()
        if ($parts.Count -ge 2 -and $parts[1].Trim()) { $parents = @($parts[1].Trim() -split '\s+') }
        $result.Add([pscustomobject]@{ Sha = $parts[0].Trim(); Parents = $parents; Trailers = $trailers })
    }
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $result.ToArray()
}

function Get-KitStorageBranchLastVersion {
    <#
    .SYNOPSIS
        «Остання залита версія» джерела — трейлер Storage-Version: вершини storage/<ключ>.
        Гілки немає → $null (реплеїти всі версії зі звіту). Вершина без трейлера → зупинка:
        гілку писав не sync, вгадувати стан не можна.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)

    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return $null }
    $raw = git -C $RepoRoot log -1 --format='%(trailers:key=Storage-Version,valueonly)' $Branch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git log $Branch завершився з кодом ${LASTEXITCODE}: $($raw -join "`n")" }
    $value = (@($raw) -join "`n").Trim()
    if ($value -notmatch '^\d+$') {
        throw "Вершина гілки $Branch не має числового трейлера Storage-Version: — гілку писав не sync. Розбір: kit check."
    }
    [int]$value
}

function Test-KitStorageBranchInvariants {
    <#
    .SYNOPSIS
        Інваріанти гілки дзеркала (спека §3.2): кожен коміт має Storage-Version і
        Storage-Source = ключ; версії строго зростають; батьків не більше одного (корінь —
        нуль); дерево лише під RepoPath. Повертає знахідки; порожньо — усе гаразд.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][string]$RepoPath
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    # Без coma-wrap (`, @()`): викликачі загортають результат у @(...), і кома тут дала б
    # один елемент (порожній вкладений масив) замість справжніх нуля елементів.
    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return @() }

    $prev = $null
    foreach ($c in (Get-KitBranchCommits -RepoRoot $RepoRoot -Ref $Branch)) {
        $short = $c.Sha.Substring(0, 7)
        if ($c.Parents.Count -gt 1) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: коміт $short має $($c.Parents.Count) батьків — merge-коміт на гілці сховища. " +
                'Гілки storage/* лише дописує sync; зливають ЇХ у main/F, а не навпаки.')))
        }
        if (-not $c.Trailers.Contains('Storage-Source')) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message "$Branch`: коміт $short без трейлера Storage-Source:."))
        } elseif ($c.Trailers['Storage-Source'] -ne $SourceKey) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: коміт $short має Storage-Source: '$($c.Trailers['Storage-Source'])', а гілка належить джерелу '$SourceKey'.")))
        }
        if (-not $c.Trailers.Contains('Storage-Version') -or $c.Trailers['Storage-Version'] -notmatch '^\d+$') {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message "$Branch`: коміт $short без числового трейлера Storage-Version:."))
            continue
        }
        $v = [int]$c.Trailers['Storage-Version']
        if ($null -ne $prev -and $v -le $prev) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: версії не зростають строго — після $prev іде $v (коміт $short).")))
        }
        $prev = $v
    }

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/') + '/'
    $tree = git -C $RepoRoot ls-tree -r --name-only $Branch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree $Branch завершився з кодом ${LASTEXITCODE}: $($tree -join "`n")" }
    $stray = @($tree | Where-Object { $_ -and -not $_.StartsWith($prefix) })
    foreach ($s in $stray) {
        $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
            "$Branch`: у дереві файл поза шляхом джерела '$RepoPath': $s.")))
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitStorageBranchName, Test-KitBranchExists, Get-KitBranchCommits, Get-KitStorageBranchLastVersion, Test-KitStorageBranchInvariants
```

- [ ] **Step 4: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 5: Коміт**

```bash
git add tools/lib/StorageBranch.psm1 tools/tests/StorageBranch.Tests.ps1
git commit -m "B1: StorageBranch.psm1 — остання версія й інваріанти storage/* з трейлерів git"
```

---

### Task 6: git-хуки захисту `storage/*` і `Hooks.psm1` (§3.3, шар 2)

Версійована тека `.githooks/` у репозиторії-споживачі з `pre-commit` і `pre-merge-commit`;
`core.hooksPath .githooks`. Хук відмовляє, якщо `HEAD` → `refs/heads/storage/*` і немає
`V8KIT_SYNC=1`.

**Встановлені факти (виправлено фінальним рев'ю, 2026-09; повний розбір — `docs/follow-ups.md`
§15):** відносний `core.hooksPath` у linked worktree (`git worktree add …`) спрацьовує лише
тоді, коли теку `.githooks` містить дерево САМОГО worktree, а не головної робочої копії —
перевірено двічі на git 2.53.0.windows.1: orphan-worktree без `.githooks` у своєму дереві
дає exit=0 (хук не спрацював) на коміті без `V8KIT_SYNC`, а worktree, чиє дерево `.githooks`
містить, дає exit=1 (спрацював). Тобто git розв'язує шлях від кореня свого власного
worktree. `sync` (B2) `worktree add --orphan` для гілки `storage/*` не наслідує `.githooks`
головної копії, тож шар 2 (pre-commit/pre-merge-commit) там реально не діє — повнота
захисту лишається на шарі 3 (`check`, інваріанти гілки, спека §3.3). `sync` усе одно
**мусить виставляти `V8KIT_SYNC=1`** на коміт у worktree — не як обхід дірки, а як
контракт: там, де тека `.githooks` таки є в дереві worktree, коміт без цієї змінної хук
законно відхилить. `pre-merge-commit` блокує коміт злиття, але `git merge`
завершується кодом 0 із текстом «Not committing merge» і лишає індекс у стані злиття —
тест перевіряє, що `HEAD` не змінився, а не код виходу.

**Ще один встановлений факт (знахідка рев'ю):** `Copy-Item` не переносить біт виконання, а
на POSIX git мовчки не запускає хук без нього — ні помилки, ні попередження, коміт у
`storage/*` просто проходить, і `check` при цьому доповідає «0 знахідок». На машині
розробки `core.filemode = false` (Windows): біт на файловій системі там не лише не
виставляється, а й **не читається**, тож перевіряти файлову систему безглуздо — значення
має лише режим, який git **записав у індекс** (`git ls-files -s <шлях>`), бо саме він
дістанеться кожному майбутньому клону на Linux/macOS. Звідси три наслідки нижче: шаблони
в цьому репозиторії йдуть у git як `100755`, `Install-KitGitHooks` виставляє біт явно на
POSIX (`chmod`, недоступний і непотрібний на Windows), а `Test-KitGitHooks` дістає
четвертий клас знахідки — `warn`, а не `error`, бо на Windows-контурі, для якого kit
зроблено, біт ні на що не впливає.

**Files:**
- Create: `templates/githooks/pre-commit`, `templates/githooks/pre-merge-commit`
- Create: `tools/lib/Hooks.psm1`
- Create: `tools/tests/Hooks.Tests.ps1`
- Modify: `.gitattributes` (kit) — рядок `templates/githooks/* text eol=lf`
- Modify: `templates/gitattributes` — рядок `.githooks/* text eol=lf` після `* text=auto`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — параметр `-WithHooks`
- Modify: `tools/tests/Templates.Tests.ps1` — новий Describe на `.githooks/*` у шаблоні

**Interfaces:**
- Consumes: `New-KitFinding` (Task 4).
- Produces: `Get-KitHookNames`, `Install-KitGitHooks -RepoRoot [-TemplatesDir]`, `Test-KitGitHooks -RepoRoot [-TemplatesDir]`; змінна середовища **`V8KIT_SYNC=1`** — єдиний дозвіл на запис у `storage/*` (B2 виставляє її на час коміту й прибирає у `finally`).

- [ ] **Step 1: Хуки в `templates/githooks/`**

`templates/githooks/pre-commit` (LF, без BOM):

```sh
#!/bin/sh
# v8storagekit — захист гілок storage/* (spec §3.3, шар 2).
# storage/<джерело> — дзеркало сховища конфігурацій 1С. Його пише лише `kit sync`, і лише
# він виставляє V8KIT_SYNC=1. Будь-який інший коміт сюди — помилка людини або агента:
# історія дзеркала мусить лишатись рівно історією сховища.
# Установлює скіл onboarding: копія в .githooks/ + `git config core.hooksPath .githooks`.
branch=$(git symbolic-ref -q HEAD) || exit 0
case "$branch" in
  refs/heads/storage/*)
    if [ "$V8KIT_SYNC" != "1" ]; then
      echo "v8storagekit: гілка '${branch#refs/heads/}' — дзеркало сховища, її пише лише 'kit sync'." >&2
      echo "  Коміт відхилено (pre-commit). Працюйте у гілці задачі від головної гілки." >&2
      exit 1
    fi
    ;;
esac
exit 0
```

`templates/githooks/pre-merge-commit` (LF, без BOM):

```sh
#!/bin/sh
# v8storagekit — захист гілок storage/* від злиття (spec §3.3, шар 2).
# storage/* зливають У main чи в гілку задачі, а не навпаки: merge-коміт на дзеркалі
# ламає інваріант «один коміт = одна версія сховища» (§3.2), і check його зловить.
branch=$(git symbolic-ref -q HEAD) || exit 0
case "$branch" in
  refs/heads/storage/*)
    if [ "$V8KIT_SYNC" != "1" ]; then
      echo "v8storagekit: у гілку '${branch#refs/heads/}' нічого не зливають — це дзеркало сховища." >&2
      echo "  Злиття відхилено (pre-merge-commit). Скасуйте його: git merge --abort" >&2
      exit 1
    fi
    ;;
esac
exit 0
```

- [ ] **Step 2: Політика тексту для хуків — у kit і в споживача**

`.gitattributes` kit, у кінець файлу:

```
# Shell-хуки, які плагін роздає споживачам у .githooks/. sh не пробачає CR у кінці
# рядка ("command not found: exit\r"), а ці файли не пише платформа — вони мусять
# бути LF у будь-якому клоні й у будь-якому кеші плагіна.
templates/githooks/* text eol=lf
```

`templates/gitattributes`, одразу після рядка `* text=auto`:

```
# Хуки захисту гілок storage/* (тека .githooks/, ставить v8storagekit). Виконує sh —
# рядки мають лишатись LF незалежно від core.autocrlf.
.githooks/* text eol=lf
```

Окремо (знахідка рев'ю) — сам режим у git-індексі, не лише вміст. Шаблони, з яких
`Install-KitGitHooks` копіює, мусять іти в git як `100755`, інакше кожен клон, узятий на
POSIX, успадкує невиконуваний хук:

```bash
git update-index --chmod=+x templates/githooks/pre-commit templates/githooks/pre-merge-commit
```

Перевірка: `git ls-files -s templates/githooks/` має дати `100755` для обох файлів. Це
зміна індексу — комітиться разом з рештою (Step 9), окремого кроку git add не треба.

- [ ] **Step 3: Тест на шаблон — у `tools/tests/Templates.Tests.ps1` новий Describe**

```powershell
Describe 'templates/githooks — хуки захисту storage/*' {
    BeforeAll {
        $script:HooksDir = (Resolve-Path "$PSScriptRoot/../../templates/githooks").Path
    }

    It 'обидва хуки на місці, з shebang sh і без CR' {
        foreach ($name in 'pre-commit', 'pre-merge-commit') {
            $p = Join-Path $script:HooksDir $name
            $p | Should -Exist
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $bytes | Should -Not -Contain ([byte]13) -Because "sh падає на CR у $name"
            (Get-Content -LiteralPath $p -TotalCount 1) | Should -Be '#!/bin/sh'
            (Get-Content -LiteralPath $p -Raw) | Should -Match 'V8KIT_SYNC'
        }
    }

    It 'шаблон gitattributes споживача тримає .githooks/* у LF' {
        $lines = @(Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot/../../templates/gitattributes").Path -Encoding UTF8)
        @($lines | Where-Object { $_ -match '^\.githooks/\*\s+text\s+eol=lf\s*$' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 4: Тест `tools/tests/Hooks.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'Hooks.psm1 і templates/githooks — захист storage/* (§3.3, шар 2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates/githooks").Path

        # Гілка storage/X у ГОЛОВНІЙ робочій копії — саме там людина чи агент могли б
        # помилково закомітити. Створюємо orphan і повертаємось на main.
        function script:New-RepoWithStorageBranch {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name)
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo checkout -q --orphan storage/Alpha_SMB
            git -C $repo rm -rq --cached . 2>$null
            git -C $repo clean -fdq -e .githooks
            New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/cfe/src') -Force | Out-Null
            # Файл НЕ Configuration.xml (знахідка F9, виправлена під час реалізації): main з
            # New-KitFakeRepo уже має Alpha_SMB/cfe/src/Configuration.xml зі справжнім вмістом
            # (New-KitFakeConfigurationXml). Однакова назва в orphan-гілці дала б реальний
            # git-конфлікт add/add при злитті (несумісні історії, той самий шлях, різний
            # вміст) — а pre-merge-commit git НЕ викликає, коли злиття впало на конфлікті:
            # тест на «злиття відхилено ХУКОМ» не дістався б хука і падав би на повідомленні
            # git про конфлікт замість повідомлення хука. Інша назва файлу прибирає збіг шляху.
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/StorageMirror.xml') -Value '<x/>'
            git -C $repo add -A -- Alpha_SMB
            $env:V8KIT_SYNC = '1'
            try { git -C $repo commit -q -m "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" }
            finally { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }
            git -C $repo checkout -q main
            $repo
        }
    }
    AfterEach { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }

    It 'Install-KitGitHooks кладе обидва файли й ставить core.hooksPath' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'install')
        $installed = @(Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
        $installed.Count | Should -Be 2
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        Join-Path $repo '.githooks/pre-merge-commit' | Should -Exist
        (git -C $repo config --get core.hooksPath) | Should -Be '.githooks'
    }

    It 'коміт на storage/X без V8KIT_SYNC відхилено; HEAD не зрушив' {
        $repo = New-RepoWithStorageBranch -Name 'reject'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/stray.xml') -Value '<y/>'
        git -C $repo add -A -- Alpha_SMB
        $out = git -C $repo commit -q -m 'ручний коміт' 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -BeLike "*v8storagekit*storage/Alpha_SMB*"
        (git -C $repo rev-parse HEAD) | Should -Be $before
    }

    It 'з V8KIT_SYNC=1 той самий коміт проходить' {
        $repo = New-RepoWithStorageBranch -Name 'allow'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/v2.xml') -Value '<z/>'
        git -C $repo add -A -- Alpha_SMB
        $env:V8KIT_SYNC = '1'
        git -C $repo commit -q -m "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        (git -C $repo rev-parse HEAD) | Should -Not -Be $before
    }

    It 'pre-merge-commit відхиляє злиття в storage/X: merge-коміту немає, HEAD той самий' {
        $repo = New-RepoWithStorageBranch -Name 'merge'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        $out = git -C $repo merge --no-ff --allow-unrelated-histories --no-edit main 2>&1 | Out-String
        $out | Should -BeLike '*v8storagekit*дзеркало*'
        (git -C $repo rev-parse HEAD) | Should -Be $before
        git -C $repo merge --abort 2>$null
    }

    It 'у звичайній гілці хук мовчить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'silent')
        Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'note.md') -Value 'робота'
        git -C $repo add -A
        git -C $repo commit -q -m 'звичайний коміт' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    Context 'Test-KitGitHooks — аудит для check' {
        It 'свіжий репозиторій без хуків — помилки про core.hooksPath і файли' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-none')
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*core.hooksPath*' }).Count | Should -Be 1
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*pre-commit*' }).Count | Should -BeGreaterOrEqual 1
        }
        It 'після встановлення — знахідок нуль' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-ok')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates).Count | Should -Be 0
        }
        It 'змінений хук — попередження про розбіжність із шаблоном плагіна' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-drift')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            Add-Content -LiteralPath (Join-Path $repo '.githooks/pre-commit') -Value '# локальна правка'
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $f.Count | Should -Be 1
            $f[0].Level | Should -Be 'warn'
            $f[0].Message | Should -BeLike '*pre-commit*шаблон*'
        }

        It 'закомічений хук без біта виконання — попередження саме про нього, не про пару' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-mode-warn')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo add .githooks
            # Форсуємо режим явно для обох файлів: на POSIX-раннері Install-KitGitHooks
            # уже сам виставив би 100755 (chmod), а на цій Windows-машині (core.filemode
            # false) git add дав би 100644 обом незалежно від нього — тест не покладається
            # на платформу прогону, а відтворює точний сценарій «один хук без біта».
            git -C $repo update-index --chmod=-x .githooks/pre-commit
            git -C $repo update-index --chmod=+x .githooks/pre-merge-commit
            git -C $repo commit -q -m 'хуки закомічено, pre-commit — без біта виконання'
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $f.Count | Should -Be 1
            $f[0].Level | Should -Be 'warn'
            $f[0].Message | Should -BeLike '*pre-commit*'
            $f[0].Message | Should -Not -BeLike '*pre-merge-commit*'
        }

        It 'встановлені, але ще не закомічені хуки — про біт виконання знахідок немає' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-mode-untracked')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            @($f | Where-Object { $_.Message -like '*біта виконання*' }).Count | Should -Be 0
        }
    }
}
```

- [ ] **Step 5: Запустити — червоно**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 6: Реалізація `tools/lib/Hooks.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"

$script:HooksDirName = '.githooks'
$script:HookNames    = @('pre-commit', 'pre-merge-commit')
$script:DefaultTemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates/githooks'))

function Get-KitHookNames {
    [CmdletBinding()]
    param()
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $script:HookNames
}

function Install-KitGitHooks {
    <#
    .SYNOPSIS
        Кладе хуки захисту storage/* у <репо>/.githooks і вмикає їх через core.hooksPath.
    .DESCRIPTION
        Копіює байт-у-байт із templates/githooks плагіна — це роздаваний артефакт, і
        Test-KitGitHooks звіряє встановлене саме з ним. Ідемпотентно: повторний виклик
        оновлює файли до шаблону.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $target = Join-Path $RepoRoot $script:HooksDirName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:HookNames) {
        $src = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Шаблон хука не знайдено: $src" }
        $dst = Join-Path $target $name
        Copy-Item -LiteralPath $src -Destination $dst -Force
        # На POSIX git не запускає хук без права виконання, і робить це МОВЧКИ. Copy-Item
        # біта не переносить, тож виставляємо явно. На Windows core.filemode = false,
        # біт там не має значення й chmod відсутній — гілка просто не виконується.
        if ($IsLinux -or $IsMacOS) {
            & chmod '+x' $dst
            if ($LASTEXITCODE -ne 0) { throw "chmod +x $dst завершився з кодом $LASTEXITCODE" }
        }
        $installed.Add($dst)
    }
    $out = git -C $RepoRoot config core.hooksPath $script:HooksDirName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git config core.hooksPath завершився з кодом ${LASTEXITCODE}: $out" }
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $installed.ToArray()
}

function Test-KitGitHooks {
    <#
    .SYNOPSIS
        Аудит для check: core.hooksPath увімкнено, обидва файли є, вміст = шаблон плагіна.
        Порівняння після нормалізації CRLF→LF: CR тут — окрема біда, і про неї каже .gitattributes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    $configured = (git -C $RepoRoot config --get core.hooksPath 2>$null | Out-String).Trim()
    if (($configured -replace '\\', '/').TrimEnd('/') -ne $script:HooksDirName) {
        $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
            "core.hooksPath не вказує на $script:HooksDirName (зараз: '$configured') — хуки захисту storage/* не працюють. " +
            "Увімкнути: git config core.hooksPath $script:HooksDirName (скіл onboarding робить це сам).")))
    }

    foreach ($name in $script:HookNames) {
        $installedPath = Join-Path $RepoRoot $script:HooksDirName $name
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
                "Хука $script:HooksDirName/$name немає — гілки storage/* не захищені від ручного коміту.")))
            continue
        }
        $templatePath = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { continue }
        $a = (Get-Content -LiteralPath $installedPath -Raw) -replace "`r`n", "`n"
        $b = (Get-Content -LiteralPath $templatePath  -Raw) -replace "`r`n", "`n"
        if ($a -ne $b) {
            $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                "Хук $script:HooksDirName/$name відрізняється від шаблону плагіна ($templatePath). " +
                'Оновіть копію з templates/githooks плагіна, якщо це не свідома локальна правка.')))
        }

        # Біт виконання — окрема знахідка від вмісту. На POSIX git не запускає хук без
        # нього і робить це мовчки: check при цьому доповів би "0 знахідок", хоча кожен
        # коміт у storage/* на такому клоні пройде повз захист. Питаємо саме git, а не
        # файлову систему: на Windows core.filemode = false, і те, що бачить ФС, не має
        # стосунку до режиму, який git запише в дерево майбутнього клону.
        $tracked = git -C $RepoRoot ls-files -s -- "$script:HooksDirName/$name" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ls-files -s $script:HooksDirName/$name завершився з кодом ${LASTEXITCODE}: $tracked" }
        $trackedLine = (@($tracked) -join "`n").Trim()
        if ($trackedLine -match '^(?<mode>\d{6})\s') {
            # Порожній вивід — хук ще не закомічено (онбординг не дійшов до git add), і це
            # не знахідка тут: Install-KitGitHooks свідомо не чіпає індекс споживача.
            if ($Matches.mode -eq '100644') {
                $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                    "Хук $script:HooksDirName/$name закомічено без біта виконання (режим 100644) — " +
                    "у клоні на Linux/macOS git тихо проігнорує хук, і storage/* лишиться незахищеним. " +
                    "Полагодити: git update-index --chmod=+x $script:HooksDirName/$name і закомітити.")))
            }
        }
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitHookNames, Install-KitGitHooks, Test-KitGitHooks
```

- [ ] **Step 7: `KitFixtures.psm1` — параметр `-WithHooks`**

До `param(...)` `New-KitFakeRepo` додати `[switch]$WithHooks`; перед блоком `if (-not $NoCommit)`:

```powershell
    if ($WithHooks) {
        Import-Module (Join-Path $kitRoot 'tools/lib/Hooks.psm1')
        Install-KitGitHooks -RepoRoot $Root -TemplatesDir (Join-Path $kitRoot 'templates/githooks') | Out-Null
    }
```

І всередині самого `if (-not $NoCommit)` (знахідка рев'ю) — виставити біт виконання в
індексі одразу після `git add -A`, до коміту:

```powershell
    if (-not $NoCommit) {
        Invoke-KitFakeGit -C $Root add -A | Out-Null
        if ($WithHooks) {
            # Фікстура зображає стан ПІСЛЯ онбордингу, а не зламану інсталяцію: у
            # справжньому репозиторії-споживачі біт виконання виставляє сама команда
            # `kit install-hooks -Apply` (блок B5). На цій машині core.filemode false,
            # тож звичайний `git add -A` вище запише .githooks/* як 100644 незалежно
            # від того, чи спрацював POSIX-chmod усередині Install-KitGitHooks (Task 6) —
            # без цього рядка кожен тест із -WithHooks ловив би зайву warn від
            # Test-KitGitHooks про хук без біта виконання. update-index діє лише на вже
            # проіндексований файл, тож рядок стоїть після add -A і до commit.
            Invoke-KitFakeGit -C $Root update-index --chmod=+x -- .githooks/pre-commit .githooks/pre-merge-commit | Out-Null
        }
        Invoke-KitFakeGit -C $Root commit -q -m 'фікстура: репозиторій-споживач' | Out-Null
    }
```

Через `Invoke-KitFakeGit`, як і решта викликів git у фікстурі — прямих викликів `git` тут
не додавати. Перевірка: у репозиторії `New-KitFakeRepo -WithHooks` і `git ls-files -s
.githooks/`, і `git ls-tree HEAD .githooks/` мають узгоджено дати `100755` для обох
файлів, а `Test-KitGitHooks` — 0 знахідок.

- [ ] **Step 8: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

Якщо хук не спрацьовує взагалі (коміт проходить без `V8KIT_SYNC`) — перевірити, що файли
в `templates/githooks/` не мають CR (`git ls-files --eol templates/githooks`) і що
`.gitattributes` kit уже містить рядок зі Step 2 **до** `git add` цих файлів.

- [ ] **Step 9: Коміт**

```bash
git add .gitattributes templates/gitattributes templates/githooks tools/lib/Hooks.psm1 tools/tests/Hooks.Tests.ps1 tools/tests/Templates.Tests.ps1 tools/tests/fixtures/KitFixtures.psm1
git commit -m "B1: хуки захисту storage/* (.githooks) і Hooks.psm1 — встановлення й аудит"
```

#### Доповнення з живого прогону (задача 11, S2)

Ці шість пунктів (S1–S3, правки 4–6) прийшли не з початкового плану, а з **живого прогону**
команди `check` на справжніх репозиторіях — окремий тестувальник знайшов місця, де команда
мовчить там, де мала б кричати. Стосовно цього Task 6:

**S2 — хуки лежать на диску, але не закомічені.** Наживо: тестувальник скопіював
`templates/githooks/*` у `.githooks/`, виставив `core.hooksPath` — `check` сказав, що все
добре, хоча в git хуків не було (наступний клон отримав би репозиторій без захисту
`storage/*`). Причина: `Test-KitGitHooks` уже викликав `git ls-files -s` для перевірки біта
виконання, але трактував порожній вивід (файл не в індексі) як «не знахідка». Виправлення —
`warn`, по одному на кожен незакомічений хук, у гілці `else` того самого regex-розбору
`git ls-files -s`. Межа, яку берегли: «застейджено, але не закомічено» — не знахідка (та сама
причина, що й раніше — `git ls-files -s` бачить індекс), закрита трьома тестами на три стани
хука (untracked/staged/committed) у `Hooks.Tests.ps1`.

---

### Task 7: диспетчер `tools/kit.ps1`, `module-order.txt`, probe

Один вхід для всіх команд: UTF-8 консолі, імпорт lib-модулів у зафіксованому порядку,
префлайт, виклик `Invoke-Kit<Команда>` з командного модуля. Порядок імпорту живе в
`tools/lib/module-order.txt` — його ж читає probe регресійного тесту (закриває
`docs/follow-ups.md` §5: список більше не дублюється вручну).

**Files:**
- Create: `tools/lib/module-order.txt`
- Create: `tools/kit.ps1`
- Create: `tools/commands/.gitkeep` (Task 8 замінить його на `check.psm1`)
- Modify: `tools/tests/fixtures/module-visibility-probe.ps1` — параметр `-Modules`
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1` — явний список для `storage-sync.ps1`, новий Describe для `kit.ps1`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — `Copy-KitTools`
- Create: `tools/tests/Kit.Tests.ps1`

**Interfaces:**
- Consumes: усі модулі Task 1–6.
- Produces: CLI `pwsh tools/kit.ps1 <команда> [-RepoRoot .] [-Workspace X] [-Source Y] [-Apply] [-Власні параметри]`; контракт командного модуля `Invoke-Kit<Name> -Context -Workspace -Source -Apply:bool …` → `$null` або `{ExitCode}`; фікстура `Copy-KitTools -Root <тека>` → шлях до скопійованого `kit.ps1`.

- [ ] **Step 1: `tools/lib/module-order.txt`**

```
# Порядок імпорту lib-модулів. Читають tools/kit.ps1 і tools/tests/fixtures/module-visibility-probe.ps1 —
# одне джерело для обох, щоб список не розходився (docs/follow-ups.md §5).
# Порядок важливий: PathSafety раніше за V8; Yaml раніше за V8Project/Manifest; Preflight раніше за
# StorageBranch/Hooks (вони беруть New-KitFinding); V8 раніше за StorageReport. Рядки з # ігноруються.
RepoRoot
PathSafety
Yaml
V8Project
Manifest
Preflight
StorageBranch
Hooks
GitOutput
Authors
V8
StorageReport
```

`SyncState` сюди навмисно не входить: він живе лише в старих скриптах і зникає в B2.

- [ ] **Step 2: probe читає список модулів параметром**

`tools/tests/fixtures/module-visibility-probe.ps1` — замінити блок `param` і сім рядків
`Import-Module` на:

```powershell
param(
    [Parameter(Mandatory)][string]$LibDir,
    [Parameter(Mandatory)][string]$CommandsCsv,
    [Parameter(Mandatory)][string]$ModulesCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in ($ModulesCsv -split ',')) {
    Import-Module (Join-Path $LibDir "$m.psm1") -Force
}
```

**Не `[string[]]$Modules` — рядок через кому, `$ModulesCsv`, за тим самим прийомом, що
й уже наявний `$CommandsCsv`.** Масив, переданий сплатом через `&` зовнішньому процесу
`pwsh -File`, не переживає межу процесу: PowerShell розсипає його на окремі токени
командного рядка, і `-File`-байндер дочірнього pwsh прив'язує до параметра-масиву лише
перший токен, а решту трактує як зайві позиційні аргументи — "A positional parameter
cannot be found that accepts argument …". Перевірено ізольованою репродукцією при
виконанні задачі 7 (`.superpowers/sdd/2026-09-03-B1-manifest-and-check/task-7-report.md`).

Шапку `.SYNOPSIS` оновити: «Імпортує lib-модулі у переданому порядку… Список для
`storage-sync.ps1` тест передає явно, для `kit.ps1` — читає з `tools/lib/module-order.txt`».

- [ ] **Step 3: `ModuleImportOrder.Tests.ps1` — два Describe**

У наявному Describe виклик probe стає:

```powershell
        $output = & pwsh -NoProfile -File $script:ProbeFile -LibDir $script:LibDir -CommandsCsv $csv `
            -ModulesCsv 'RepoRoot,PathSafety,V8,StorageReport,Authors,SyncState,GitOutput' 2>&1 | Out-String
```

Новий Describe у кінці файлу:

```powershell
Describe 'Порядок імпорту модулів у kit.ps1 (module-order.txt)' {
    BeforeAll {
        $script:LibDir    = (Resolve-Path "$PSScriptRoot/../lib").Path
        $script:ProbeFile = (Resolve-Path "$PSScriptRoot/fixtures/module-visibility-probe.ps1").Path
        $script:Modules   = @(Get-Content -LiteralPath (Join-Path $script:LibDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

        # Команди, які kit.ps1 і командні модулі кличуть напряму з глобальної області.
        $script:RequiredCommands = @(
            'Resolve-V8RepoRoot', 'Assert-SafeWorkPath', 'Read-KitYaml', 'Read-V8Project', 'Read-V8ProjectLocalInfobase',
            'Read-KitManifest', 'Read-KitLocalOverlay', 'Resolve-KitInfobase', 'New-KitFinding', 'Invoke-KitPreflight',
            'Select-KitSources', 'Test-KitBranchExists', 'Get-KitStorageBranchLastVersion', 'Test-KitStorageBranchInvariants',
            'Install-KitGitHooks', 'Test-KitGitHooks', 'Test-GitTextPolicy', 'Split-GitEolNoise', 'Read-AuthorMap',
            'Resolve-Author', 'Get-UnknownAuthors', 'Invoke-V8Designer', 'New-ExtensionInfobase', 'Get-StorageVersions'
        )
        $output = & pwsh -NoProfile -File $script:ProbeFile -LibDir $script:LibDir `
            -CommandsCsv ($script:RequiredCommands -join ',') -ModulesCsv ($script:Modules -join ',') 2>&1 | Out-String
        $script:ProbeExitCode = $LASTEXITCODE
        $script:ProbeOutput   = $output
        $script:Visibility = @{}
        foreach ($line in ($output -split "`r?`n")) {
            if ($line -match '^(?<name>\S+)=(?<value>True|False)$') { $script:Visibility[$Matches.name] = [bool]::Parse($Matches.value) }
        }
    }

    It 'module-order.txt містить кожен lib/*.psm1, крім SyncState' {
        $onDisk = @(Get-ChildItem -LiteralPath $script:LibDir -Filter '*.psm1' | ForEach-Object BaseName | Where-Object { $_ -ne 'SyncState' -and $_ -ne 'Environment' })
        foreach ($m in $onDisk) { $script:Modules | Should -Contain $m -Because "модуль $m є в lib/, але не в module-order.txt" }
    }

    It 'усі команди видимі після імпорту в порядку module-order.txt' {
        $script:ProbeExitCode | Should -Be 0 -Because "probe мав відпрацювати без винятку; вивід:`n$script:ProbeOutput"
        foreach ($name in $script:RequiredCommands) {
            $script:Visibility[$name] | Should -BeTrue -Because "'$name' має бути видимою після імпорту всіх модулів kit.ps1"
        }
    }
}
```

`Environment.psm1` виключено з перевірки повноти навмисно: його імпортує лише
`check-environment.ps1`, у kit.ps1 він не потрібен.

- [ ] **Step 4: `Copy-KitTools` у `KitFixtures.psm1`**

```powershell
function Copy-KitTools {
    <#
    .SYNOPSIS
        Копія kit.ps1, lib/, commands/ і templates/githooks у тимчасову теку зі збереженням
        відносної розкладки — щоб тести запускали справжній диспетчер підпроцесом, не
        чіпаючи робочої копії плагіна (той самий прийом, що в StorageSync.Tests.ps1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $kitRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    foreach ($rel in 'tools/lib', 'tools/commands', 'templates/githooks') {
        $dst = Join-Path $Root $rel
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $kitRoot "$rel/*") -Destination $dst -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $kitRoot 'tools/kit.ps1') -Destination (Join-Path $Root 'tools/kit.ps1') -Force
    Join-Path $Root 'tools/kit.ps1'
}
```

Додати `Copy-KitTools` до `Export-ModuleMember`.

- [ ] **Step 5: Тест `tools/tests/Kit.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit.ps1 — диспетчер команд' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Тестова команда: друкує, що отримала. Живе лише в копії — у справжньому tools/commands її немає.
        # Write-Host, не return: контракт команди суворий — success stream несе лише $null
        # або {ExitCode; …}, людське йде через Write-Host. probe зображає справжню команду
        # (check у задачі 8 друкує саме так), тож і тут повернене значення диспетчер не показує.
        Set-Content -LiteralPath (Join-Path (Split-Path $script:Kit) 'commands/probe.psm1') -Encoding UTF8 -Value @'
function Invoke-KitProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Ref = 'HEAD',
        [switch]$Force
    )
    Write-Host "PROBE workspaces=$($Context.Workspaces.Count) ws=$Workspace src=$Source apply=$Apply ref=$Ref force=$Force main=$($Context.MainBranch)"
}
Export-ModuleMember -Function Invoke-KitProbe
'@

        function script:Invoke-Kit {
            param([string[]]$Arguments)
            $out = & pwsh -NoProfile -File $script:Kit @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo')
    }

    It 'без команди — зупинка з переліком доступних' {
        $r = Invoke-Kit @('-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*probe*'
    }

    It 'невідома команда — зупинка з переліком доступних' {
        $r = Invoke-Kit @('frobnicate', '-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'frobnicate'*probe*"
    }

    It 'спільні й власні параметри доходять до команди; контекст після префлайту' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Workspace', 'Alpha_SMB', '-Ref', 'main', '-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*PROBE workspaces=1 ws=Alpha_SMB src= apply=False ref=main force=True main=main*'
    }

    It '-Apply передається як $true' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Apply')
        $r.Output | Should -BeLike '*apply=True*'
    }

    It 'невідомий власний параметр команди — зупинка, команда не виконана' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Bogus', '1')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'провал префлайту зупиняє до виклику команди' {
        $broken = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken')
        Remove-Item -LiteralPath (Join-Path $broken 'Alpha_SMB/v8project.yaml')
        $r = Invoke-Kit @('probe', '-RepoRoot', $broken)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8project.yaml*'
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'не git-репозиторій — зупинка' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-Kit @('probe', '-RepoRoot', $dir)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*.git*'
    }
}
```

- [ ] **Step 6: Запустити — червоно**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 7: Реалізація `tools/kit.ps1`** (і порожній `tools/commands/.gitkeep`)

```powershell
#Requires -Version 7
<#
.SYNOPSIS
    Диспетчер команд kit: pwsh tools/kit.ps1 <команда> [-RepoRoot .] [-Workspace X] [-Source Y] [-Apply] [власні параметри команди]
.DESCRIPTION
    Спільний префлайт (спека §5) і виклик Invoke-Kit<Команда> з tools/commands/<команда>.psm1.
    Команди не імпортують lib-модулів самі — їх імпортує цей файл у порядку
    tools/lib/module-order.txt, і командний модуль бачить їх із глобальної області.

    Власні параметри команди передаються після спільних як -Ім'я значення або -Прапорець і
    доходять до Invoke-Kit<Команда> сплатом; невідомий параметр зупиняє PowerShell ще на
    прив'язці — команда не виконується.
.EXAMPLE
    pwsh tools/kit.ps1 check -RepoRoot <шлях до репо-споживача>
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$RepoRoot = '.',
    [string]$Workspace,
    [string]$Source,
    [switch]$Apply,
    [Parameter(ValueFromRemainingArguments)][string[]]$CommandArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Кирилиця в повідомленнях доходить до людини й до тестів лише при UTF-8 (див. Run-Tests.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = Join-Path $PSScriptRoot 'lib'
$order = @(Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
foreach ($name in $order) {
    Import-Module (Join-Path $libDir "$name.psm1") -Force
}

$commandsDir = Join-Path $PSScriptRoot 'commands'
$available = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.psm1' -File | ForEach-Object BaseName | Sort-Object)
if (-not $Command -or $available -notcontains $Command) {
    $what = if ($Command) { "Невідома команда '$Command'." } else { 'Команду не вказано.' }
    throw "$what Доступні: $($available -join ', '). Приклад: pwsh tools/kit.ps1 check -RepoRoot ."
}

Import-Module (Join-Path $commandsDir "$Command.psm1") -Force
$functionName = 'Invoke-Kit' + ((($Command -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
if (-not (Get-Command -Name $functionName -ErrorAction SilentlyContinue)) {
    throw "Модуль команди commands/$Command.psm1 не експортує функцію $functionName."
}

# check показує ВСЕ, що не так (Lenient); решта команд без чистого префлайту не має з чим працювати.
$context = Invoke-KitPreflight -RepoRoot $RepoRoot -Lenient:($Command -eq 'check')

# Решта аргументів → іменовані параметри команди.
$splat = @{}
for ($i = 0; $i -lt $CommandArgs.Count; $i++) {
    $arg = $CommandArgs[$i]
    if ($arg -notmatch '^-(?<n>[A-Za-z][A-Za-z0-9]*)(?::(?<v>.+))?$') {
        throw "Не розпізнаю аргумент '$arg' — очікувалось -Ім'я значення або -Прапорець."
    }
    $n = $Matches['n']
    if ($Matches.ContainsKey('v')) { $splat[$n] = $Matches['v']; continue }
    if ($i + 1 -lt $CommandArgs.Count -and $CommandArgs[$i + 1] -notmatch '^-[A-Za-z]') {
        $splat[$n] = $CommandArgs[++$i]
    } else {
        $splat[$n] = $true
    }
}

$common = @{ Context = $context; Workspace = $Workspace; Source = $Source; Apply = [bool]$Apply }
# Контракт суворий: людське команда друкує сама через Write-Host, а в success stream
# (те, що потрапляє сюди, у $result) повертає лише $null або {ExitCode; …} — жодного
# третього варіанту. Диспетчер повернене значення НЕ виводить, тільки читає ExitCode.
$result = & $functionName @common @splat
if ($null -ne $result -and ($result.PSObject.Properties.Name -contains 'ExitCode') -and $result.ExitCode -ne 0) {
    exit $result.ExitCode
}
```

- [ ] **Step 8: Тести зелені**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 9: Коміт**

```bash
git add tools/kit.ps1 tools/lib/module-order.txt tools/commands/.gitkeep tools/tests/Kit.Tests.ps1 tools/tests/ModuleImportOrder.Tests.ps1 tools/tests/fixtures/module-visibility-probe.ps1 tools/tests/fixtures/KitFixtures.psm1
git commit -m "B1: kit.ps1 — диспетчер із префлайтом; module-order.txt як єдине джерело порядку імпорту"
```

#### Доповнення з живого прогону (задача 11, правка 6б)

Цей пункт (разом із S1–S3 і правками 4–5 у Task 8, S2 у Task 6) прийшов не з початкового
плану, а з **живого прогону** команди `check` на справжніх репозиторіях.

**Правка 6б — невідома команда падає сирим винятком.** `kit.ps1` кидав `throw` і на
невідомій, і на відсутній команді (рядки після `$available -notcontains $Command` вище) —
людина бачила стек PowerShell зі стек-фреймом і номером рядка, що суперечить охайному
`[-]`-виводу самого `check`. Виправлення — `Write-Host` червоним замість `throw`, і `exit 2`
замість неявного коду виходу винятку (PowerShell дає `1`). Код саме **2**, не абиякий
ненульовий: щоб «команда не запустилась узагалі» відрізнялось від коду, який повертає сама
команда (наприклад, `check` дає `1`, коли знайшла помилки, — інший сценарій). Тести
`Kit.Tests.ps1` — ті самі два («без команди», «невідома команда»), лише посилені з
`Should -Not -Be 0` до `Should -Be 2`.

Рев'ю знайшло той самий дефект подачі рядком нижче — гілку «модуль команди не експортує
`Invoke-Kit<Команда>`» (симетричний сценарій: не бракує команди, а сам плагінний код
несправний). Виправлено так само — `Write-Host` червоним + `exit 2`; окремого тесту немає
(сценарій вимагав би зіпсованого командного модуля, якого жодна фікстура зараз не будує).

---

### Task 8: команда `check` — усі інваріанти (§2.2, §2.5, §2.6, §3.2, §3.3)

`check` — єдина команда, що працює на «м'якому» префлайті: показує все, що не так, і
повертає код 1, якщо серед знахідок є помилки. Нічого не мутує, платформи не торкається.

**Files:**
- Create: `tools/commands/check.psm1` (і видалити `tools/commands/.gitkeep`)
- Create: `tools/tests/Check.Tests.ps1`
- Modify: `tools/tests/fixtures/KitFixtures.psm1` — `Add-KitFakeStorageCommit` (перенесення хелпера з `StorageBranch.Tests.ps1`)
- Modify: `tools/tests/StorageBranch.Tests.ps1` — використовує `Add-KitFakeStorageCommit` замість локального `Add-StorageCommit`

**Interfaces:**
- Consumes: `Select-KitSources`, `New-KitFinding`, `Test-GitTextPolicy`, `Test-KitBranchExists`, `Test-KitStorageBranchInvariants`, `Read-V8ProjectLocalInfobase`, `Test-KitGitHooks`.
- Produces: `Invoke-KitCheck -Context [-Workspace] [-Source] [-Apply] [-Quiet]` → `{ExitCode; Findings}`; хелпер `Add-KitFakeStorageCommit -Repo -Branch -RepoPath -FileName -Trailers [-Subject]`. Ідентифікатори перевірок (`Check`): `manifest`, `overlay`, `workspace`, `source`, `unique-keys`, `gitattributes`, `gitignore`, `storage-path`, `storage-branch`, `dump-from`, `config-name`, `local-audit`, `hooks`. B4 додасть `hook-shim`.

- [ ] **Step 1: Хелпер у фікстурах**

У `KitFixtures.psm1` додати (і експортувати):

```powershell
function Add-KitFakeStorageCommit {
    <#
    .SYNOPSIS
        Коміт на orphan-гілку storage/<X> тим самим механізмом, що й sync (B2): worktree,
        V8KIT_SYNC=1 на час коміту, worktree прибирається. Робоча копія не рухається.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Trailers,
        [string]$Subject = 'версія'
    )
    $wt = Join-Path $Repo "build/sync/wt-$([guid]::NewGuid().ToString('N'))"
    git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { git -C $Repo worktree add -q $wt $Branch }
    else                     { git -C $Repo worktree add -q --orphan -b $Branch $wt }
    $dir = Join-Path $wt $RepoPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir $FileName) -Value "вміст $FileName" -Encoding UTF8
    git -C $wt add -A
    $env:V8KIT_SYNC = '1'
    try { git -C $wt commit -q -m ((@($Subject, '') + $Trailers) -join "`n") }
    finally { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }
    git -C $Repo worktree remove --force $wt
}
```

У `StorageBranch.Tests.ps1` прибрати локальну `Add-StorageCommit` і замінити виклики на
`Add-KitFakeStorageCommit` (параметри ті самі). Прогнати тести — зелено, перш ніж іти далі.

- [ ] **Step 2: Тест `tools/tests/Check.Tests.ps1`, що падає**

```powershell
#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        function script:Invoke-Check {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Репозиторій, у якому все правильно: хуки, політика тексту, gitignore.
        function script:New-GoodRepo {
            param([string]$Name, [hashtable]$Extra = @{})
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore @Extra
        }
    }

    It 'усе гаразд — код 0, лише інформаційні рядки' {
        $r = Invoke-Check -Repo (New-GoodRepo 'good')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
        $r.Output | Should -Not -Match '\[-\]'
    }

    It 'без маніфесту — код 1 і підказка на onboarding' {
        $repo = New-GoodRepo 'no-manifest'
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
    }

    It '§2.2: <Name> у Configuration.xml не збігається з ключем джерела — код 1, названо обидва' {
        $repo = New-GoodRepo 'name-mismatch'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'Alpha_OLD')
        git -C $repo commit -qam 'фікстура: інше ім''я в Configuration.xml'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_OLD*Alpha_SMB*Configuration.xml*'
    }

    It '§2.5: infobase.connection у v8project.local.yaml збігається з дев-базою з накладки — код 1' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It '§2.5: серверна база АГЕНТА у v8project.local.yaml, якої немає в накладці, — не помилка' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $repo = New-GoodRepo 'local-agent' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'"
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0
    }

    It '§2.6: truth: vendor без правила в .gitignore — код 1 (git check-ignore)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ignore') -WithHooks -WithGitattributes
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cf/src*.gitignore*'
    }

    It '§2.6: дерево платформи без -text — код 1 (git check-attr)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-text') -WithHooks -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*-text*'
    }

    It '§2.6: дерево, яке має бути в git, помилково гітігноровано — код 1' {
        $repo = New-GoodRepo 'over-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value 'Alpha_SMB/cfe/src/**'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*.gitignore*'
    }

    It '§2.6: vendor-дерево закомічене всупереч .gitignore (git add -f) — код 1, факт відстеження' {
        # Правило в .gitignore є (WithGitignore), тому питання "правил" мовчить — тут
        # інша перевірка: факт. Файл додано силою (git add -f), так само, як хтось міг би
        # це зробити руками попри правило.
        $repo = New-GoodRepo 'vendor-tracked'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'base')
        git -C $repo add -f -- Alpha_SMB/cf/src/Configuration.xml
        git -C $repo commit -qm 'фікстура: vendor закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cf/src*'
    }

    It '§3.2: немонотонна гілка storage/X — код 1; лінійна з кореневим комітом — 0' {
        $repo = New-GoodRepo 'branch'
        foreach ($v in 5, 9) {
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0

        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v7.xml' `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*storage/Alpha_SMB*9*7*'
    }

    It '§3.3: core.hooksPath не встановлено — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-hooks') -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*core.hooksPath*'
    }

    It '§2.3: той самий ключ truth: storage у двох воркспейсах — код 1' {
        $two = [ordered]@{
            'A' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'B' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dup-keys') -Workspaces $two -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Shared*A*B*'
    }

    It 'dump.from без накладки на машині — попередження, не помилка' {
        $r = Invoke-Check -Repo (New-GoodRepo 'no-overlay')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[!]*v8storagekit.local.yaml*'
    }

    It '-Workspace звужує перевірку; невідомий — код 1 з переліком' {
        $repo = New-GoodRepo 'ws-filter'
        (Invoke-Check -Repo $repo -More @('-Workspace', 'Alpha_SMB')).ExitCode | Should -Be 0
        $r = Invoke-Check -Repo $repo -More @('-Workspace', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*Alpha_SMB*"
    }

    It 'check нічого не змінює: статус робочої копії й HEAD ті самі' {
        $repo = New-GoodRepo 'readonly'
        $head = git -C $repo rev-parse HEAD
        Invoke-Check -Repo $repo | Out-Null
        git -C $repo rev-parse HEAD | Should -Be $head
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Запустити — червоно (команди `check` немає: «Доступні: »)**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
```

- [ ] **Step 4: Реалізація `tools/commands/check.psm1`**

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Get-KitConfigurationName {
    <#
    .SYNOPSIS
        <Name> кореневого об'єкта з Configuration.xml — перше входження, як у Designer XML.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text -match '<Name>(?<n>[^<]+)</Name>') { return $Matches['n'].Trim() }
    $null
}

function Invoke-KitCheck {
    <#
    .SYNOPSIS
        Повний аудит репозиторію-споживача (спека §5): маніфест ↔ v8project.yaml ↔ .gitignore ↔
        .gitattributes ↔ Configuration.xml ↔ інваріанти storage/* ↔ накладки ↔ хуки.
        Нічого не змінює. Код 1 — є хоч одна помилка.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Quiet
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Context.Findings) { $findings.Add($f) }
    $add = { param([string]$Level, [string]$Check, [string]$Message) $findings.Add((New-KitFinding -Level $Level -Check $Check -Message $Message)) }
    $root = $Context.RepoRoot

    if ($Context.Manifest) {
        $all = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        $byTruth = (@($all | Group-Object Truth | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Count)" })) -join ', '
        & $add info manifest ("Маніфест: $($Context.Kind) $($Context.Label), головна гілка $($Context.MainBranch), " +
            "воркспейсів $($Context.Workspaces.Count), джерел у перевірці $($all.Count) ($byTruth).")

        # §2.3 — ключі truth: storage унікальні в межах репозиторію (гілка storage/<ключ> одна).
        $dups = @($Context.Workspaces | ForEach-Object { $_.Sources } | Where-Object Truth -eq 'storage' |
            Group-Object Key | Where-Object Count -gt 1)
        foreach ($d in $dups) {
            & $add error unique-keys ("Ключ '$($d.Name)' з truth: storage повторюється у воркспейсах $($d.Group.Workspace -join ', ') — " +
                "гілка storage/$($d.Name) була б спільною. Перейменуйте source-set в одному з них (§2.3).")
        }

        foreach ($src in $all) {
            $tag = "$($src.Workspace)/$($src.Key)"

            # §2.6 — усі дерева платформи, ЩО ПОТРАПЛЯЮТЬ У GIT, під -text. Питаємо git, не
            # читаємо .gitattributes. truth: vendor гітігноровано за визначенням, конверсія
            # на checkout йому не загрожує, і шаблон gitattributes навмисно не має для нього
            # правила — для vendor інваріант інший, нижче (check-ignore).
            if ($src.Truth -ne 'vendor') {
                try {
                    if (-not (Test-GitTextPolicy -RepoRoot $root -Path $src.RepoPath)) {
                        & $add error gitattributes ("$tag`: дерево '$($src.RepoPath)' не виведено з-під конверсії кінців рядків — " +
                            "додайте в .gitattributes рядок '$($src.RepoPath)/** -text' (docs/text-policy.md).")
                    }
                } catch {
                    & $add error gitattributes "$tag`: git check-attr не відповів: $($_.Exception.Message)"
                }

                # Дзеркальна перевірка до gitignore для vendor: дерево, яке МАЄ бути в git,
                # не повинно ловитись правилом .gitignore. Помилково широке правило викидає
                # вихідники з git мовчки — ні sync, ні canon цього не бачать.
                #
                # --no-index обов'язковий: без нього check-ignore звіряється з індексом і
                # НІКОЛИ не покаже вже трекований файл ігнорованим, хай яке правило
                # додай — це задокументована поведінка git (див. check-ignore -h), а не
                # артефакт. Без --no-index цей інваріант не ловив жодного випадку, коли
                # Configuration.xml уже закомічено (справжній репозиторій-споживач —
                # завжди саме такий стан).
                git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                $ignoredCode = $LASTEXITCODE
                if ($ignoredCode -eq 0) {
                    & $add error gitignore ("$tag`: дерево '$($src.RepoPath)' гітігноровано, хоч має потрапляти в git (truth: $($src.Truth)) — " +
                        'перевірте правила .gitignore.')
                } elseif ($ignoredCode -gt 1) {
                    & $add error gitignore "$tag`: git check-ignore завершився з кодом $ignoredCode."
                }
            }

            switch ($src.Truth) {
                'vendor' {
                    # Vendor — два РІЗНІ питання, не одне. `git check-ignore` без прапорця
                    # --no-index звіряється з індексом і НІКОЛИ не покаже вже трекований
                    # файл ігнорованим (задокументована поведінка git, не артефакт — див.
                    # git check-ignore -h: "--no-index — ignore index when checking").
                    # Без --no-index "не ігнорований" фактично означало "закомічений", і
                    # цей побічний ефект випадково ловив правильну тривогу для vendor, поки
                    # не з'явився --no-index у дзеркальній перевірці вище (без нього не
                    # ловилось зовсім протилежне — F5: над-широке правило проти вже
                    # закоміченого дерева, яке МАЄ бути в git). --no-index розвів ці два
                    # випадково злиті питання, тож тепер вони — дві окремі перевірки:

                    # (1) ПРАВИЛА: чи .gitignore справді ігнорує дерево.
                    git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 1) {
                        & $add error gitignore ("$tag`: '$($src.RepoPath)' не гітігноровано (truth: vendor) — чужа конфігурація потрапила б у git. " +
                            "Додайте в .gitignore рядок '$($src.RepoPath)/**' (перевірка: git check-ignore).")
                    } elseif ($code -gt 1) {
                        & $add error gitignore "$tag`: git check-ignore завершився з кодом $code."
                    }

                    # (2) ФАКТ: чи дерево справді не в git — незалежно від правил. Правило
                    # може бути на місці, а файли вже закомічені силою (git add -f) або з
                    # часів до появи правила: check-ignore з --no-index цього НЕ покаже
                    # (він свідомо ігнорує індекс), тому запитуємо індекс напряму. Код
                    # виходу git ls-files — 0 і на протеклому, і на здоровому дереві,
                    # розрізняє лише порожність виводу.
                    $tracked = @(git -C $root ls-files -- $src.RepoPath 2>$null)
                    if ($LASTEXITCODE -ne 0) {
                        & $add error gitignore "$tag`: git ls-files завершився з кодом $LASTEXITCODE."
                    } elseif ($tracked.Count -gt 0) {
                        & $add error gitignore ("$tag`: дерево '$($src.RepoPath)' (truth: vendor) відстежується git — у ньому $($tracked.Count) файл(ів), " +
                            'хоч чужа конфігурація не має потрапляти в репозиторій. Приберіть з індексу: ' +
                            "git rm -r --cached -- '$($src.RepoPath)'.")
                    }
                }
                'storage' {
                    if (-not (Test-Path -LiteralPath $src.StoragePath)) {
                        & $add warn storage-path ("$tag`: каталог сховища недоступний на цій машині: $($src.StoragePath). " +
                            "Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key).")
                    }
                    if (Test-KitBranchExists -RepoRoot $root -Branch $src.Branch) {
                        foreach ($f in @(Test-KitStorageBranchInvariants -RepoRoot $root -Branch $src.Branch -SourceKey $src.Key -RepoPath $src.RepoPath)) {
                            $findings.Add($f)
                        }
                    } else {
                        & $add info storage-branch "$tag`: гілки $($src.Branch) ще немає — її створить перший sync."
                    }
                }
            }

            if ($src.Truth -in @('dump', 'vendor')) {
                if (-not $Context.Overlay) {
                    & $add warn dump-from ("$tag`: dump.from '$($src.DumpFrom)', але накладки v8storagekit.local.yaml на цій машині немає — " +
                        'dump тут не запрацює, поки її не створити.')
                } elseif (-not $Context.Overlay.Infobases.ContainsKey($src.DumpFrom)) {
                    & $add warn dump-from "$tag`: дев-бази '$($src.DumpFrom)' немає в infobases: накладки $($Context.OverlayPath)."
                }
            }

            # §2.2 — ім'я розширення однакове в трьох місцях. vendor не наш, його не звіряємо.
            if ($src.Type -eq 'EXTENSION' -and $src.Truth -ne 'vendor') {
                $cfg = Join-Path $src.FullPath 'Configuration.xml'
                if (Test-Path -LiteralPath $cfg -PathType Leaf) {
                    $xmlName = Get-KitConfigurationName -Path $cfg
                    if (-not $xmlName) {
                        & $add warn config-name "$tag`: у $($src.RepoPath)/Configuration.xml не знайдено <Name>."
                    } elseif ($xmlName -ne $src.Key) {
                        & $add error config-name ("$tag`: <Name>$xmlName</Name> у $($src.RepoPath)/Configuration.xml не збігається з ключем джерела '$($src.Key)' — " +
                            'ім''я розширення має бути однаковим у name: source-set, <Name> і ключі маніфесту (§2.2).')
                    }
                } else {
                    & $add info config-name "$tag`: $($src.RepoPath)/Configuration.xml ще немає — дерево порожнє до першого sync."
                }
            }
        }

        # §2.5 — аудит v8project.local.yaml: підключення до бази ЛЮДИНИ під ключем Unica.
        foreach ($ws in $Context.Workspaces) {
            if ($Workspace -and $ws.Path -ne $Workspace) { continue }
            $localPath = Join-Path $ws.FullPath 'v8project.local.yaml'
            $localConn = $null
            try { $localConn = Read-V8ProjectLocalInfobase -Path $localPath }
            catch { & $add error local-audit "$($ws.Path)/v8project.local.yaml не читається: $($_.Exception.Message)" }
            if ($localConn -and $Context.Overlay) {
                $norm = { param([string]$s) (($s -replace '\s', '') -replace '"', '').TrimEnd(';').ToLowerInvariant() }
                $hit = @($Context.Overlay.Infobases.Values | Where-Object { (& $norm $_.Connection) -eq (& $norm $localConn) }) | Select-Object -First 1
                if ($hit) {
                    & $add error local-audit ("$($ws.Path)/v8project.local.yaml: infobase.connection збігається з дев-базою '$($hit.Name)' із накладки kit — " +
                        'це база людини під ключем Unica, і operation=build писав би в неї. Приберіть infobase: звідти; ' +
                        'у цьому файлі може бути лише серверна база АГЕНТА (§2.5).')
                }
            }
        }

        # §3.3, шар 2 — хуки.
        foreach ($f in @(Test-KitGitHooks -RepoRoot $root)) { $findings.Add($f) }
    }

    $errors = @($findings | Where-Object Level -eq 'error')
    $warns  = @($findings | Where-Object Level -eq 'warn')
    if (-not $Quiet) {
        Write-Host "kit check — $root"
        foreach ($f in $findings) {
            $mark  = switch ($f.Level) { 'error' { '[-]' } 'warn' { '[!]' } default { '[i]' } }
            $color = switch ($f.Level) { 'error' { 'Red' }  'warn' { 'Yellow' } default { 'Gray' } }
            Write-Host "$mark $($f.Message)" -ForegroundColor $color
        }
        Write-Host ''
        if ($errors.Count -eq 0) {
            Write-Host "Помилок немає. Попереджень: $($warns.Count)." -ForegroundColor Green
        } else {
            Write-Host "Помилок: $($errors.Count), попереджень: $($warns.Count)." -ForegroundColor Red
        }
    }

    [pscustomobject]@{
        ExitCode = $(if ($errors.Count -gt 0) { 1 } else { 0 })
        Findings = $findings.ToArray()
    }
}

Export-ModuleMember -Function Invoke-KitCheck, Get-KitConfigurationName
```

- [ ] **Step 5: Тести зелені; ручний прогін на живому репозиторії — лише читання**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
pwsh -NoProfile -File tools/kit.ps1 check -RepoRoot R:\github\SMP_BankExchange
```

Очікувано на `SMP_BankExchange`: код 1 з помилкою «Маніфест v8storagekit.yaml не знайдено …
onboarding» — репозиторій ще не мігрований, і це правильна відповідь. Нічого в ньому не
змінилось (`git -C R:\github\SMP_BankExchange status --porcelain` порожній).

- [ ] **Step 6: Коміт**

```bash
git rm -q tools/commands/.gitkeep
git add tools/commands/check.psm1 tools/tests/Check.Tests.ps1 tools/tests/fixtures/KitFixtures.psm1 tools/tests/StorageBranch.Tests.ps1
git commit -m "B1: kit check — маніфест, gitignore/gitattributes, <Name>, інваріанти storage/*, аудит накладки Уніки, хуки"
```

#### Доповнення з живого прогону (задача 11: S1, S3, правки 4 і 5)

Ці чотири пункти прийшли не з початкового плану, а з **живого прогону** команди `check` на
справжніх репозиторіях — окремий тестувальник знайшов місця, де команда мовчить там, де мала
б кричати (S2 — той самий прогін, розділ Task 6; правка 6б — Task 7).

**S1 — джерело є у `v8project.yaml`, але його немає в маніфесті.** Наживо: прибрали з
маніфесту блок розширення, лишивши `base` — `check` порахував 6 джерел замість 7 і сказав
«Помилок немає». Перевірка йшла лише в напрямку маніфест → `v8project.yaml` (Preflight.psm1),
зворотної не було. Виправлення — `warn`, `Check = 'undeclared-source'`, у **`check.psm1`**
(не в префлайті — розмежування принципове, префлайт відповідає «чи можу я працювати», `check`
— «чи все описано»), у тому самому циклі по воркспейсах, де вже стоїть аудит §2.5 (той самий
фільтр `-Workspace`). Джерела порівнюються з `$Context.Manifest.Workspaces` (оголошене
людиною), не з розв'язаними `$ws.Sources`.

**S3 — `v8storagekit.local.yaml` не гітігнорований.** Наживо: `.gitignore` мав
`v8project.local.yaml` (Уніки), але не мав `*.local.yaml` чи окремого рядка
`v8storagekit.local.yaml` — накладка з рядками підключення й користувачами сховищ
показувалась би як `??` і застейджилась би першим же `git add -A` у публічному репозиторії.
`error`, `Check = 'overlay-ignored'`, **рівно одна знахідка на репозиторій** — перевірка стоїть
поза циклом `foreach ($src in $all)` (`git check-ignore --no-index` на шлях
`v8storagekit.local.yaml` у корені), одразу після перевірки унікальності ключів §2.3.

**Правка 4 — текст warn про недоступний шлях сховища.** Рівень лишається `warn` (навмисно:
`check` не відрізнить «немає диска» від «помилка в маніфесті»), але повідомлення тепер називає
шлях, записаний у самому `v8storagekit.yaml` (окремий пошук по `$Context.Manifest`, бо
`$src.StoragePath` може бути вже перевизначений накладкою), і дає явну розвилку: перевизначити
в `v8storagekit.local.yaml`, якщо шлях правильний, а диска немає, або виправити
`v8storagekit.yaml`, якщо диск є. Живий приклад: маніфест указував `…СМП_BankExchange_ACC`, а
реальне сховище лежало під `…СМП_BankExchange_BP` — попередній текст радив би перевизначити
шлях, хоча треба було виправити маніфест.

**Правка 5а — «маніфест не знайдено» веде в глухий кут.** Повідомлення `Invoke-KitPreflight`
(`tools/lib/Preflight.psm1`, не `check.psm1`) досі посилалось на скіл
`v8storagekit:onboarding`, якого ще немає (з'явиться в B5) — а це перше й часто єдине
повідомлення, яке бачить новий споживач. Додано пряму дію поруч зі скілом (скіл лишається):
скопіювати `templates/v8storagekit.yaml.example` з теки плагіна в корінь як
`v8storagekit.yaml`, заповнити й запустити `kit check` ще раз. Тест, що на це спирається
(`Preflight.Tests.ps1`, «без маніфесту — зупинка з підказкою на onboarding»), лишився зеленим
без змін — обидва якорі (`v8storagekit.yaml`, `onboarding`) все ще в тексті.

---

### Task 9: роздавані зразки, `.gitignore` споживача, дозвіл на `check`, `follow-ups`

**Files:**
- Create: `templates/v8storagekit.yaml.example`, `templates/v8storagekit.local.yaml.example`
- Modify: `templates/gitignore` — рядок `v8storagekit.local.yaml`
- Modify: `templates/README.md` — таблиця відповідностей
- Modify: `tools/tests/Templates.Tests.ps1` — зразки проходять схему; `.gitignore` ігнорує накладку
- Modify: `.claude/settings.json` (kit) — дозвіл на `kit.ps1 check`
- Modify: `docs/follow-ups.md` — §5 закрито; новий запис про `.githooks` у linked worktree

- [ ] **Step 1: Тести на роздавані артефакти — у `Templates.Tests.ps1`**

```powershell
Describe 'templates/v8storagekit*.example — зразки проходять власну схему' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates").Path
    }

    It 'v8storagekit.yaml.example читається Read-KitManifest без зупинки' {
        $m = Read-KitManifest -Path (Join-Path $script:Templates 'v8storagekit.yaml.example')
        $m.Kind | Should -Be 'product'
        $m.Workspaces.Count | Should -BeGreaterOrEqual 2
    }

    It 'v8storagekit.local.yaml.example читається Read-KitLocalOverlay без зупинки' {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Templates 'v8storagekit.local.yaml.example')
        $o.Infobases.Count | Should -BeGreaterOrEqual 1
    }

    It 'шаблон gitignore ігнорує накладку kit і досі — накладку Уніки' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Encoding UTF8)
        $lines | Should -Contain 'v8storagekit.local.yaml'
        $lines | Should -Contain 'v8project.local.yaml'
    }
}
```

- [ ] **Step 2: Запустити — червоно**

- [ ] **Step 3: `templates/v8storagekit.yaml.example`**

```yaml
# v8storagekit.yaml — маніфест конвеєра «сховище ↔ git» (плагін v8storagekit, спека §2.4).
# Один файл у корені репозиторію. Структуру (шляхи, типи) НЕ описує — вона у v8project.yaml
# кожного воркспейсу; тут — лише truth кожного джерела й те, чого Unica не знає.
# Кладе й заповнює скіл v8storagekit:onboarding, питаючи truth для кожного джерела.
version: 1
product: <НазваПродукту>            # АБО client: <НазваКлієнта> — метадані для імен артефактів і звітів
# mainBranch: main                  # необов'язково; лише якщо головна гілка не main

workspaces:
  - path: <Воркспейс_UA>            # тека з v8project.yaml безпосередньо в корені репо
    sources:                        # ключ = name: source-set у <Воркспейс_UA>/v8project.yaml
      base:                         # базова конфігурація вендора
        truth: vendor               # не наше, у git не потрапляє (.gitignore); локально — дамп
        dump: { from: devUNF }      # ключ дев-бази з v8storagekit.local.yaml → infobases:
      <ІмʼяРозширення>:             # = <Name> у cfe/…/Configuration.xml = name: source-set
        truth: storage              # істина — сховище конфігурацій; гілка storage/<ІмʼяРозширення>
        storage:
          path: 'R:\СховищаРозширень_1С\<Сховище>'
          user: gitbot              # типово gitbot, пароль порожній

  - path: epf                       # спільні зовнішні обробки — власний воркспейс
    sources:
      external-processors: { truth: git }   # зовнішнього джерела немає: пишуть люди й агент

# Словник truth:
#   storage — сховище конфігурацій; sync дзеркалить у storage/<ключ>; у git з історією
#   dump    — жива база, лише поточний стан; dump пише в git без історії
#   vendor  — чужа конфігурація; dump лише локально, у git не потрапляє
#   git     — зовнішнього джерела немає
```

- [ ] **Step 4: `templates/v8storagekit.local.yaml.example`**

```yaml
# v8storagekit.local.yaml — локальна накладка kit (спека §2.5). ГІТІГНОРОВАНА.
# Тут живе все, що стосується цієї машини й цієї людини: дев-бази, з яких kit лише читає;
# інші шляхи до сховищ; шаблон .dt для бази агента. Kit НЕ ділить файлів з Unica:
# v8project.local.yaml — її файл, і в нього kit не пише нічого.
infobases:                          # живі бази — лише читання (dump)
  devUNF:
    connection: 'Srvr="<сервер>";Ref="<база>";'    # або File="<шлях до файлової бази>"
    user: '<користувач бази>'                      # пароль kit не зберігає — платформа спитає

storages:                           # перевизначення шляхів сховищ на цій машині (ключ = ключ джерела)
  # <ІмʼяРозширення>: 'D:\mirror\<Сховище>'

workspaces:                         # налаштування бази агента (B4: provision)
  # <Воркспейс_UA>:
  #   agentBase:
  #     template: 'D:\dumps\<демо>.dt'   # розгорнути базу агента з .dt; без ключа — порожня через Unica init
```

- [ ] **Step 5: `templates/gitignore`, `templates/README.md`**

У `templates/gitignore` блок «Локальні перевизначення» стає:

```
# Локальні перевизначення з підключеннями й логінами: накладка kit і накладка Уніки
v8storagekit.local.yaml
v8project.local.yaml
```

У таблиці `templates/README.md` додати рядки:

```
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює `v8storagekit:onboarding`) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
```

`storage.json.example` лишається в таблиці до B2 — його прибере той блок разом зі
`storage.json`-конвенцією.

- [ ] **Step 6: `.claude/settings.json` kit — дозвіл на `check`**

До `permissions.allow` після рядка з `check-environment.ps1`:

```json
      "Bash(pwsh -NoProfile -File tools/kit.ps1 check:*)"
```

`check` не мутує нічого й не має `-Apply`, тому префіксне правило безпечне — на відміну від
прев'ю `sync`, яке піднімає платформу (CLAUDE.md, «Дозволи»). Інші команди дозволів не
отримують.

- [ ] **Step 7: `docs/follow-ups.md` §5**

Одразу під заголовком `## 5. fixtures/module-visibility-probe.ps1 дублює список імпортів вручну`:

```markdown
> **Закрито в B1 (2026-09):** порядок імпорту тепер живе в `tools/lib/module-order.txt`;
> його читають і `tools/kit.ps1`, і probe. Тест `ModuleImportOrder.Tests.ps1` додатково
> перевіряє, що кожен `lib/*.psm1` (крім `SyncState`, що зникає в B2, і `Environment`,
> який kit.ps1 не потребує) є у списку. Опис нижче — історичний.
```

- [ ] **Step 8: `docs/follow-ups.md` — новий `## 15.` про `.githooks` у linked worktree**

У кінець файлу (перевірено: останній наявний — `## 14. Прогін -Apply не перевіряє
канонічності вихідників`) додати розділ `## 15.`. Встановлений факт Task 6, перевірений
у сесії планування: відносний `core.hooksPath .githooks` спрацьовує і в linked worktree
(`git worktree add …`), хоч теки `.githooks` там немає — git розв'язує його від головної
робочої копії. Наслідок: `sync` (B2), який комітить у гілку `storage/*` саме через
worktree, мусить сам виставляти `V8KIT_SYNC=1`, інакше власний хук відмовить йому в
коміті. Запис — не задача до розбору, а свідомо задокументована особливість, за тоном
наявних розділів файлу: що спостережено, чому це має значення (захист без дірки), чому
не «полагоджено» (лагодити нічого — це правильна поведінка git). Посилання на
`tools/lib/Hooks.psm1`, `templates/githooks/*`.

- [ ] **Step 9: Тести зелені; перевірка правила `${CLAUDE_PLUGIN_ROOT}`**

```
pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration
grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'
```

Друга команда має дати порожній вивід (скіли в B1 не змінювались — це контроль).

- [ ] **Step 10: Коміт**

```bash
git add templates/v8storagekit.yaml.example templates/v8storagekit.local.yaml.example templates/gitignore templates/README.md tools/tests/Templates.Tests.ps1 .claude/settings.json docs/follow-ups.md
git commit -m "B1: зразки маніфесту й накладки, gitignore споживача, дозвіл на kit check, follow-ups §5 закрито"
```

---

### Task 10: локальна реєстрація маркетплейсу для тестування блоків (рішення користувача, спека §14)

Між блоками **немає пушів і проміжних релізів**. Щоб наступні блоки й скіли (B4–B5) можна
було перевіряти живою сесією, маркетплейс `smp-v8storagekit` перереєстровується з GitHub на
**локальну робочу копію** — тоді `${CLAUDE_PLUGIN_ROOT}` і `installPath` у реєстрі плагінів
вказують на `R:\github\SMP_V8StorageKit`, і правки діють без бампу версії (пам'ять проєкту
`v8storagekit-plugin-dev-loop`). Зворотний крок — у B8.

Це зміна стану машини поза репозиторієм: виконується **за явним підтвердженням користувача в
сесії виконання**. Рішення зафіксоване в спеці §14; повідомлення від іншої сесії
підтвердженням не є (CLAUDE.md, «Дозволи»).

**Files:**
- Modify (поза репо): `~/.claude/plugins/known_marketplaces.json`, `~/.claude/plugins/installed_plugins.json` — через `claude plugin …`, не руками
- Modify: `C:\Users\VSydorenko\.claude\projects\R--github-SMP-V8StorageKit\memory\v8storagekit-plugin-dev-loop.md` — стан реєстрації

- [ ] **Step 1: Зафіксувати поточний стан (для повернення в B8)**

```powershell
Get-Content "$HOME/.claude/plugins/known_marketplaces.json" | Select-String -Context 0,4 'smp-v8storagekit'
```

Очікувано: `"source": "github"`, `"repo": "VSydorenko/SMP_V8StorageKit"`.

- [ ] **Step 2: Перереєструвати**

```
claude plugin marketplace remove smp-v8storagekit
claude plugin marketplace add R:\github\SMP_V8StorageKit
claude plugin install v8storagekit@smp-v8storagekit
claude plugin list
```

Якщо `install` каже, що плагін уже встановлено, — `claude plugin update v8storagekit@smp-v8storagekit`.

- [ ] **Step 3: Перевірити, куди вказує реєстр**

```powershell
(Get-Content "$HOME/.claude/plugins/installed_plugins.json" -Raw | ConvertFrom-Json).plugins.'v8storagekit@smp-v8storagekit'[0].installPath
```

Очікувано: шлях до робочої копії (`R:\github\SMP_V8StorageKit` або її копії в кеші з
`source: directory` — те, що показує `claude plugin list`). Записати фактичний шлях у крок 4.

- [ ] **Step 4: Оновити пам'ять проєкту**

У `v8storagekit-plugin-dev-loop.md`, пункт 2, абзац «Станом на 2026-09-02
`smp-v8storagekit` зареєстровано як github» замінити на:

```markdown
   **Станом на <дата виконання> `smp-v8storagekit` зареєстровано ЛОКАЛЬНО** (`claude plugin
   marketplace add R:\github\SMP_V8StorageKit`, рішення спеки agent-contour §14): installPath =
   `<фактичний шлях зі Step 3>`, правки в робочій копії діють після рестарту сесії без бампу
   версії. Повернення на GitHub і бамп 1.0.0 — блок B8. До того — жодних пушів і релізів.
```

- [ ] **Step 5: Нова сесія бачить локальний плагін**

```
claude -p "Invoke the skill named v8storagekit:storage-pipeline and print only its first heading"
```

Очікувано: заголовок скіла з робочої копії. (Скіли в B1 не змінювались — це перевірка
самого шляху, не вмісту.)

---

## Self-review (виконано автором плану)

**Покриття спеки для B1 (§14, рядок B1 + §12):**

| Вимога спеки | Задача |
|---|---|
| схема `v8storagekit.yaml` + local overlay, модуль читання (§2.4, §2.5) | 1, 3 |
| `kit.ps1` диспетчер із префлайтом (§5) | 4, 7 |
| `check`: маніфест ↔ `v8project.yaml` (§5) | 4, 8 |
| `check`: `<Name>` у `Configuration.xml` (§2.2) | 8 |
| `check`: аудит `v8project.local.yaml` (§2.5) | 2, 8 |
| `check`: `check-ignore` для vendor, `check-attr` для дерев платформи (§2.6) | 8 |
| `check`: інваріанти `storage/*` — трейлери, зростання, батьки, дерево (§3.2) | 5, 8 |
| `check`: хуки встановлені (§3.3) | 6, 8 |
| `.githooks` + встановлення, `V8KIT_SYNC` (§3.3, шар 2) | 6 |
| стан із git: остання версія з трейлера, порожня гілка → «немає» (§3.2) | 5 |
| унікальність ключів `truth: storage` (§2.3) | 8 |
| `mainBranch` (Q5), `-Source` без `-Workspace` (Q9) | 3, 4 |
| `powershell-yaml` у `check-environment` (Q1) | 1 |
| локальний маркетплейс (Q7, §14) | 10 |
| тести §12: «маніфест і накладка», «check §2.2/§2.5/§2.6/§3.2/§3.3», «хук», «стан із git» | 1–8 |

**Не входить у B1 (свідомо):** worktree для запису в `storage/*` і `V8KIT_SYNC` у `sync` — B2;
перевірка шима хука старту сесії в `check` (`hook-shim`) — B4; вилучення `storage.json`,
`SyncState.psm1`, старих скриптів — B2–B4; переписування скілів і `templates/CLAUDE.md` — B5.

**Узгодженість імен між задачами:** `Read-KitYaml`, `Read-V8Project`, `Read-KitManifest`,
`Read-KitLocalOverlay`, `New-KitFinding`, `Invoke-KitPreflight`, `Select-KitSources`,
`Test-KitStorageBranchInvariants`, `Get-KitStorageBranchLastVersion`, `Install-KitGitHooks`,
`Test-KitGitHooks`, `Invoke-KitCheck`, `New-KitFakeRepo`, `Copy-KitTools`,
`Add-KitFakeStorageCommit` — вживаються однаково в усіх задачах і в «Спільних контрактах».
Поля resolved source (`Key, Truth, Type, Workspace, Path, RepoPath, FullPath, StoragePath,
StorageUser, DumpFrom, Branch`) — однакові в Task 4 і Task 8.
