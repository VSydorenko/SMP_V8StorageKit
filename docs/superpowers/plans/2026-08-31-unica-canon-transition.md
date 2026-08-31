# Перехід конвеєра на канон Уніки — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** привести плагін `v8storagekit` у відповідність до канону Уніки — щоб база
воркспейсу була машинною й похідною від git, а вихідники в репозиторії-споживачі
побайтово збігалися з тим, що пише платформа.

**Architecture:** робота майже вся в артефактах, які плагін **роздає** споживачам —
`templates/gitattributes`, шаблон `v8project.yaml` у скілі `product-onboarding`,
документація. Виконуваного коду змінюється рівно одне місце: фільтр eol-попереджень у
`storage-sync.ps1` виноситься в тестований модуль і починає рахувати приховане. Тому
тести тут захищають **роздавані артефакти**, а не лише функції: саме їх отримує споживач,
і саме в них жив дефект.

**Tech Stack:** PowerShell 7, Pester 5, git attributes, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-31-unica-canon-transition-design.md`

## Global Constraints

- **PowerShell 7+**, усі скрипти під `Set-StrictMode -Version Latest` і
  `$ErrorActionPreference = 'Stop'`.
- **Мова всього, що бачить людина** — українська: коментарі, повідомлення, документація,
  назви тестів. Англійською лишаються тільки ідентифікатори, шляхи й дослівні цитати
  виводу інструментів.
- **Прогін тестів:** `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`.
  Саме ця форма дозволена без запиту. Повний прогін (без `-ExcludeTag`) запускає
  `1cv8.exe` — у цьому плані він не потрібен жодного разу.
- **Форма тесту** — за `CLAUDE.md`: тест мусить виконувати справжній артефакт
  (production-файл, production-функцію), а не переказувати його логіку всередині себе.
- **`${CLAUDE_PLUGIN_ROOT}` — тільки всередині шляху.** У тілі `SKILL.md` цей токен
  замінюється абсолютним шляхом при завантаженні; речення, яке про нього *розповідає*,
  після підстановки стає вказівкою вписати чужий абсолютний шлях. Перевірка (має бути
  порожньо): `grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'`
- **Скіли адресуються з префіксом плагіна** — `v8storagekit:storage-pipeline`, не голе ім'я.
- **Кореневий `.gitattributes` цього репозиторію не чіпати.** Правиться тільки
  `templates/gitattributes` — це різні політики для різних адресатів (`CLAUDE.md`,
  «Правила, які легко порушити», п. 4).
- **`templates/settings.json` не змінювати.** `unica_runtime_execute` навмисно лишається
  недозволеним.
- **Коміт після кожної задачі — так. `git push`, `gh pr create`, `gh release` — ні**,
  ні на якому кроці цього плану.

---

## File Structure

| Файл | Відповідальність | Задача |
|---|---|---|
| `templates/gitattributes` | політика тексту, яку плагін роздає споживачам | 1 |
| `docs/text-policy.md` | **новий.** Чому `-text`, як перевірити round-trip, як мігрувати наявне репо | 1 |
| `tools/tests/Templates.Tests.ps1` | **новий.** Guard-тести на роздавані артефакти | 1, 2 |
| `skills/product-onboarding/SKILL.md` | шаблон `v8project.yaml` для нового продукту | 2 |
| `tools/lib/GitOutput.psm1` | **новий.** Розбір виводу `git add` на видиме й приховане | 3 |
| `tools/tests/GitOutput.Tests.ps1` | **новий.** Тести цього модуля | 3 |
| `tools/storage-sync.ps1` | використання модуля замість інлайн-фільтра | 3 |
| `tools/tests/fixtures/module-visibility-probe.ps1` | дзеркало списку імпортів `storage-sync.ps1` | 3 |
| `tools/tests/ModuleImportOrder.Tests.ps1` | список команд, які мають лишатись видимими | 3 |
| `docs/storage-and-git.md` | архітектура контуру: дві бази | 4 |
| `skills/storage-pipeline/SKILL.md` | щоденний цикл: новий шлях збірки, round-trip | 4 |
| `templates/CLAUDE.md` | що роздається споживачу про роботу через Уніку | 4 |
| `CLAUDE.md` | таблиця «Де що шукати» | 4 |
| `tools/build.ps1` | коментар у шапці (рядки 5-8) | 4 |
| `docs/follow-ups.md` | чотири нові записи | 4 |
| `.claude-plugin/plugin.json` | версія 0.5.0 → 0.6.0 | 5 |

---

### Task 1: Політика тексту

Найризикованіша задача плану: без неї вихідники в кожному новому клоні псуються тихо.
Документ і правило їдуть разом — шапка правила посилається на документ, а документ без
правила описує неіснуючий стан.

**Files:**
- Modify: `templates/gitattributes` (переписати цілком)
- Create: `docs/text-policy.md`
- Test: `tools/tests/Templates.Tests.ps1`

**Interfaces:**
- Consumes: нічого з попередніх задач.
- Produces: `docs/text-policy.md` — на нього посилаються задача 3 (повідомлення
  `Split-GitEolNoise`) і задача 4 (`CLAUDE.md`, `storage-pipeline`). Шлях писати точно так.

- [ ] **Step 1: Написати падаючі тести**

Створити `tools/tests/Templates.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'templates/gitattributes — політика тексту' {
    # Тест читає справжній роздаваний артефакт, а не його переказ: саме цей файл
    # потрапляє в репозиторій-споживача, і саме в ньому жив дефект (конверсія
    # кінців рядків усередині текстових значень XML). Обґрунтування — docs/text-policy.md.
    BeforeAll {
        $script:Lines = @(Get-Content -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../templates/gitattributes").Path -Encoding UTF8)
    }

    It 'виводить дерева, які пише платформа, з-під конверсії git' {
        @($script:Lines | Where-Object { $_ -match '^\*\*/cfe/src/\*\*\s+-text\s*$' }).Count |
            Should -Be 1
        @($script:Lines | Where-Object { $_ -match '^\*\*/epf/src/\*\*\s+-text\s*$' }).Count |
            Should -Be 1
    }

    It 'не має жодного правила eol= на розширеннях, які пише платформа' {
        # Регресія: будь-яке eol= на .xml/.bsl/.html/.txt конвертує файл ЦІЛКОМ і
        # мовчки міняє текст усередині багаторядкових значень v8:content.
        $offenders = @($script:Lines |
            Where-Object { $_ -match '^\s*\*\.(xml|bsl|html|txt)\b.*\beol=' })
        $offenders | Should -BeNullOrEmpty -Because (
            "правило eol= на цих розширеннях псує вміст: " + ($offenders -join '; '))
    }

    It 'правила -text стоять після загального text=auto' {
        $catchAll = @($script:Lines | Select-String -Pattern '^\* text=auto')
        $catchAll.Count | Should -Be 1 -Because 'загальне правило має лишитись рівно одне'

        $textOff = @($script:Lines | Select-String -Pattern '^\*\*/(cfe|epf)/src/\*\*\s+-text')
        $textOff.Count | Should -Be 2

        foreach ($m in $textOff) {
            $m.LineNumber | Should -BeGreaterThan $catchAll[0].LineNumber -Because (
                'інакше загальне правило скасує -text: у git виграє останнє правило, що збіглося')
        }
    }

    It 'бінарний список накриває gif' {
        # Його відсутність давала repositoryReady=false в unica.project.status.
        $script:Lines | Should -Contain '*.gif binary'
    }
}
```

- [ ] **Step 2: Прогнати тести — мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — чотири тести з `Templates.Tests.ps1`. Перший і третій не знаходять правил
`-text`; другий знаходить `*.xml text eol=crlf` і `*.bsl text eol=crlf`; четвертий не
знаходить `*.gif binary`.

- [ ] **Step 3: Переписати `templates/gitattributes`**

Замінити вміст файлу цілком:

```gitattributes
# Політика тексту й кінця рядка. Переписана 2026-08-31 — попереднє обґрунтування
# ("платформа 1С пише CRLF") виявилось неточним і саме воно й давало дефект.
#
# Платформа пише кінці рядків ЗМІШАНО в межах одного файлу: структуру XML — через CRLF,
# а переводи всередині текстових значень (v8:content — підказки й заголовки елементів
# форм) — через LF. Виміряно: 166 файлів XML, 54939 CRLF і 62 LF, усі 62 всередині
# значень. Git конвертує файл ЦІЛКОМ і цієї різниці не бачить у принципі, тому жодне
# правило eol= тут не може бути правильним: eol=crlf мовчки міняє текст підказок,
# eol=lf псує структуру. Єдиний варіант, де і дані цілі, і git status чесний, — не
# конвертувати ці дерева взагалі.
#
# Повне обґрунтування, приймальна перевірка (round-trip через платформу) і процедура
# міграції наявного репозиторію — docs/text-policy.md у плагіні Claude Code
# v8storagekit (корінь плагіна показує команда /plugin у сесії Claude Code; цей файл
# не постачається в репозиторій-споживач разом із шаблонами).

# Файли, які пишуть люди. Без eol=: конверсія тут нічого не вирішує, а незалежність
# від локального core.autocrlf дає -text нижче — надійніше, ніж давало eol=crlf.
* text=auto

# Дерева, які пише платформа 1С. Git не конвертує їх узагалі, тому робоча копія в
# будь-якому клоні побайтово збігається з тим, що записав /DumpConfigToFiles.
# cf/src сюди не входить: він під **/cf/** у .gitignore і в git не потрапляє.
#
# ОЧІКУВАНО: unica.project.status видасть error git.text_resource_marked_binary на
# кожному файлі вихідників і порадить замінити -text на "text eol=lf". Цю пораду
# виконувати НЕ МОЖНА — вона повертає проблему "~900 змінених файлів на порожньому
# місці". Порівняння всіх трьох варіантів — docs/text-policy.md.
**/cfe/src/** -text
**/epf/src/** -text

# Бінарні макети розширення. Під -text вище конверсія їм уже не загрожує; рядки
# лишаються заради -diff/-merge на багатомегабайтних файлах (пілотна міграція
# SimplyConnect принесла два PE на 4,7 і 4,1 МБ, два ZIP на 2,7 і 0,6 МБ,
# криптомодуль на 0,5 МБ) і заради бінарників поза цими деревами.
#
# Ціна помилки тут асиметрична: конверсія всередині бінарника не падає й нічого не
# повідомляє — вона тихо псує байти, і виявиться це аж у клієнта, коли не підключиться
# драйвер. Тому список розширюють, а не скорочують.
*.bin binary
*.axdt binary
*.addin binary
*.epf binary
*.png binary
*.jpg binary
*.jpeg binary
*.gif binary
*.bmp binary
*.ico binary
*.zip binary
```

- [ ] **Step 4: Написати `docs/text-policy.md`**

Створити файл із таким вмістом:

```markdown
# Політика тексту: чому вихідники не конвертуються

Документ пояснює правило `-text` у `templates/gitattributes`, дає приймальну перевірку
канонічності вихідників і процедуру міграції репозиторію, який жив під старою політикою.

## Чому жодне правило `eol=` не годиться

Платформа 1С пише кінці рядків **змішано в межах одного файлу**:

| Що | Кінці рядків |
|---|---|
| структура XML | CRLF |
| переводи всередині текстових значень (`<v8:content>`: підказки, заголовки елементів форм) | **LF** |
| BSL | CRLF |
| довідка `Ext/Help/*.html`, текстові макети | LF |

Виміряно на реальному розширенні: 166 файлів XML, 54 939 CRLF і 62 LF — усі 62 всередині
значень.

Git конвертує файл **цілком**. Різниці між структурним переводом і переводом усередині
текстового значення він не бачить і бачити не може. Тому:

| Правило | Дані | Round-trip |
|---|---|---|
| `text eol=crlf` | **псуються** — 62 внутрішні LF стають CRLF, текст підказок мовчки змінюється | брудний |
| `text eol=lf` | цілі | **брудний на кожному XML** |
| `-text` | цілі | **чистий** |

`eol=lf` дає брудний round-trip тому, що робоча копія стала б суцільно LF, а платформа
пише змішано — це рівно та болячка з «~900 зміненими файлами на порожньому місці», заради
якої в шаблоні колись і з'явилось `eol=crlf`.

Симптом, який давало `eol=crlf`: порівняння зібраного `.cfe` зі сховищем у Конфігураторі
показувало «опис довідки змінився» на формах, яких ніхто не редагував.

## Діагностика Уніки, якої не треба «лагодити»

Під `-text` `unica.project.status` видає **error** `git.text_resource_marked_binary` на
кожному файлі вихідників (виміряно: 207) і радить замінити `-text` на `text eol=lf`.

**Цю пораду виконувати не можна** — таблиця вище показує, куди вона веде. Діагностика
відображає політику Уніки, а не поломку: `ready` лишається `true`, операції не
блокуються.

## Приймальна перевірка: round-trip через платформу

Єдина чесна відповідь на питання «чи канонічні наші вихідники». Ні `git status`, ні
`unica.cfe.validate` цього класу розходжень не бачать: перший порівнює нормалізований
вміст, другий не розв'язує типи базової конфігурації.

    /LoadConfigFromFiles <cfe/src> -Extension <Ім'я>      (у тимчасову ІБ)
    /DumpConfigToFiles  <порожня тимчасова тека> -Extension <Ім'я>
    diff -rq <тимчасова тека> <cfe/src>

Вивантажувати треба в **порожню** теку: `/DumpConfigToFiles` не видаляє зниклі об'єкти.
`ConfigDumpInfo.xml` відрізняється завжди (хеші версій) і в git не відстежується —
ігнорується.

**Пастка методу.** Вхід мусить бути **сирими git-об'єктами**. Якщо згодувати платформі
робочу копію, яку git конвертує, вона поверне рівно те, що в неї поклали, і це приймуть за
канон — круговий аргумент. Витягати вхід через `git cat-file blob` або перечек-аутом,
зробленим уже під `-text`.

## Міграція репозиторію, який жив під `eol=crlf`

Передумова: робоча копія чиста.

1. Оновити `.gitattributes` за шаблоном плагіна.
2. **Примусово перевикласти** дерево вихідників: видалити теку й
   `git checkout -- <Продукт>/cfe/src`. Просто додати правило недостатньо — git не
   перевикладає файли, вміст яких вважає незмінним, і робоча копія лишиться CRLF-ною.
3. Round-trip за розділом вище: завантажити в тимчасову ІБ, вивантажити в порожню теку,
   звірити, замінити `cfe/src` вмістом дампу.
4. `git add --renormalize <Продукт>/cfe/src` і коміт.
5. Решті команди — примусовий перечек-аут способом із кроку 2.

**Крок 2 не можна пропускати, а крок 4 не можна робити до кроку 3.** На пошкодженій
робочій копії `--renormalize` зафіксує пошкодження як канон.

**Межа відновлення.** Процедура повертає оригінал, бо структурні переводи платформа
генерує детерміновано, а переводи всередині значень пропускає наскрізь — в об'єктах git
вони лишились незміненими. Текстове значення, яке **спочатку** містило CRLF, відновити
неможливо: нормалізація незворотна. На пілотному розширенні таких немає — усі 62 переводи
припадають на 20 коротких значень інтерфейсу в 4 файлах, найдовше 429 символів.

## Довідкове

Платформа **не пише** завершального переводу рядка в XML — усі файли закінчуються на `>`
(перевірено: 166 зі 166). Правила в `.gitattributes` це не потребує, але будь-який
генератор XML має це враховувати, інакше побайтова звірка даватиме хибне спрацювання на
кожному згенерованому файлі.
```

- [ ] **Step 5: Прогнати тести — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, зокрема всі чотири з `Templates.Tests.ps1`. Наявні набори — без змін.

- [ ] **Step 6: Коміт**

```bash
git add templates/gitattributes docs/text-policy.md tools/tests/Templates.Tests.ps1
git commit -m "templates/gitattributes: -text замість eol= на деревах платформи

Платформа пише кінці рядків змішано в межах одного файлу: структура XML - CRLF,
переводи всередині v8:content - LF. Git конвертує файл цілком, тому eol=crlf мовчки
міняв текст підказок, а eol=lf зіпсував би структуру. docs/text-policy.md несе
обґрунтування, round-trip як приймальну перевірку і процедуру міграції наявних репо."
```

---

### Task 2: Шаблон воркспейсу в `product-onboarding`

**Files:**
- Modify: `skills/product-onboarding/SKILL.md:130-151`
- Test: `tools/tests/Templates.Tests.ps1` (дописати другий `Describe`)

**Interfaces:**
- Consumes: `docs/text-policy.md` із задачі 1 — на нього посилатись не обов'язково, але
  шлях має існувати, якщо скіл на нього пошлеться.
- Produces: шаблон `v8project.yaml`, на який спирається задача 4 (`storage-pipeline`
  описує збірку через базу воркспейсу, оголошену саме тут).

- [ ] **Step 1: Написати падаючий тест**

Дописати в кінець `tools/tests/Templates.Tests.ps1`:

```powershell
Describe 'product-onboarding — шаблон v8project.yaml' {
    BeforeAll {
        $script:Skill = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../skills/product-onboarding/SKILL.md").Path
    }

    It 'шаблон оголошує власну базу воркспейсу' {
        # Без цього блоку infobase.connection приходить з v8project.local.yaml і
        # вказує на серверну дев-базу - тобто Уніка мутує базу, де людина працює
        # Конфігуратором. Це і була першопричина всього розбору.
        $script:Skill | Should -Match "(?m)^\s*infobase:\s*$"
        $script:Skill | Should -Match "connection:\s*'File=build/ib'"
    }

    It 'імʼя EXTENSION-джерела береться з extensionName, а не з імені теки' {
        # v8-runner виводить імʼя розширення з імені source-set. Якщо там імʼя теки
        # продукту, operation=make падає на валідації:
        #   source-set 'X' resolves to extension 'X', expected 'SMP_X'
        $script:Skill | Should -Not -Match "(?m)^\s*-\s*name:\s*<Продукт>\s*$"
        $script:Skill | Should -Match "(?m)^\s*-\s*name:\s*<extensionName зі storage\.json>\s*$"
    }
}
```

- [ ] **Step 2: Прогнати тести — мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — обидва нові тести. Перший не знаходить `infobase:`; другий знаходить
`- name: <Продукт>`.

- [ ] **Step 3: Замінити блок шаблону в скілі**

У `skills/product-onboarding/SKILL.md` замінити YAML-блок пункту 4 (рядки 135-147) на:

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
  - name: <extensionName зі storage.json>
    type: EXTENSION
    path: 'cfe/src'
```

- [ ] **Step 4: Дописати пояснення під шаблоном**

Одразу після YAML-блоку, перед абзацом «Нагадайте користувачу», вставити:

```markdown
   Два місця в цьому шаблоні неочевидні, і обидва були дефектами до 0.6.0.

   **`infobase.connection` вказує на файлову базу під `build/`, а не на дев-базу.**
   Це база воркспейсу Уніки — машинна, повністю похідна від git, яку можна викинути й
   відтворити `operation=build`. Дев-база лишається людською: у ній працюють
   Конфігуратором і комітять у сховище, і торкаються її лише `dump-config.ps1` і
   `load-ext.ps1` на явне прохання. Без блоку `infobase:` підключення приходить із
   `v8project.local.yaml`, і Уніка починає мутувати робочу базу людини.

   **Ім'я EXTENSION-джерела мусить дорівнювати `extensionName` зі `storage.json`** —
   імені розширення в 1С, а не імені теки продукту. Вони законно різні: тека
   `SimplyConnect_SMBru`, розширення `SMP_SimplyConnect_SMBru`. Стороннiй v8-runner
   виводить ім'я розширення з імені source-set, і при розбіжності `operation=make`
   падає:

       validation error: source-set 'SimplyConnect_SMBru' resolves to extension
       'SimplyConnect_SMBru', expected 'SMP_SimplyConnect_SMBru'

   Правила немає в документації Уніки — воно відоме лише з тексту помилки й
   відстежується в `${CLAUDE_PLUGIN_ROOT}/docs/unica-contract.md`, B5-B6. Там же
   записано, що `operation=make` окремо вимагає `--extension`, попри вже переданий
   `--source-set`.

   **Звірка перед комітом:** якщо `<Продукт>/cfe/src/Configuration.xml` уже існує, його
   `<Name>` мусить дорівнювати `extensionName` зі `storage.json`. Розбіжність означає, що
   один із двох файлів правили руками, і вона зламає і збірку, і синхронізацію.
```

- [ ] **Step 5: Перевірити правило `${CLAUDE_PLUGIN_ROOT}`**

Run: `grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'`
Expected: порожній вивід. Доданий вище токен стоїть усередині шляху
(`${CLAUDE_PLUGIN_ROOT}/docs/unica-contract.md`), тож фільтр `/docs/` його прибирає.

- [ ] **Step 6: Прогнати тести — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, усі шість тестів `Templates.Tests.ps1`.

- [ ] **Step 7: Коміт**

```bash
git add skills/product-onboarding/SKILL.md tools/tests/Templates.Tests.ps1
git commit -m "product-onboarding: блок infobase і імʼя EXTENSION-джерела зі storage.json

Без infobase: базою воркспейсу Уніки ставала серверна дев-база, тому operation=build
мутував базу, де людина комітить у сховище. Імʼя source-set має дорівнювати імені
розширення в 1С - інакше operation=make падає на валідації v8-runner."
```

---

### Task 3: `Split-GitEolNoise` — фільтр стає рахованим

Під новою політикою попереджень про конверсію на деревах платформи бути не має. Тому
фільтр із зручності перетворюється на глушник сигналу — і має почати рахувати.

Заразом інлайн-блок виноситься у модуль: у теперішньому вигляді його неможливо
протестувати (він усередині циклу по версіях сховища, недосяжного без платформи), і
наявні тести змушені дублювати його регекс у себе — рівно та вада, яку `docs/follow-ups.md`
§4 називає дефектом культури тестів.

**Files:**
- Create: `tools/lib/GitOutput.psm1`
- Test: `tools/tests/GitOutput.Tests.ps1`
- Modify: `tools/storage-sync.ps1` (імпорт біля рядка 32; блок фільтра рядки 242-250)
- Modify: `tools/tests/fixtures/module-visibility-probe.ps1`
- Modify: `tools/tests/ModuleImportOrder.Tests.ps1:30-41`

**Interfaces:**
- Consumes: `docs/text-policy.md` із задачі 1 — згадується у тексті попередження.
- Produces: `Split-GitEolNoise -Line [object[]]` →
  `[pscustomobject]@{ Kept = [object[]]; Suppressed = [int] }`. Інших споживачів у плані
  немає.

- [ ] **Step 1: Написати падаючі тести**

Створити `tools/tests/GitOutput.Tests.ps1`:

```powershell
#Requires -Version 7
Describe 'Split-GitEolNoise' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitOutput.psm1").Path -Force
    }

    It 'ховає справжнє попередження git і рахує його' {
        # Вхід - вивід справжнього "git add" під конвертуючою політикою, а не вигаданий
        # рядок: форма повідомлення git тут і є предметом перевірки.
        $repo = Join-Path $TestDrive 'eol-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'Test Bot'
        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Encoding UTF8 `
            -Value '* text=auto eol=crlf'
        [System.IO.File]::WriteAllText((Join-Path $repo 'f.xml'), "<a/>`n<b/>`n",
            [System.Text.UTF8Encoding]::new($false))

        $addOutput = git -C $repo add -A 2>&1
        $LASTEXITCODE | Should -Be 0

        $result = Split-GitEolNoise -Line $addOutput
        $result.Suppressed | Should -BeGreaterThan 0
        $result.Kept | Should -BeNullOrEmpty
    }

    It 'лишає видимим будь-що, крім відомої форми' {
        $known = "warning: in the working copy of 'a.xml', LF will be replaced by CRLF the next time Git touches it"
        $other = 'warning: something totally unrelated happened'

        $result = Split-GitEolNoise -Line @($known, $other)

        $result.Suppressed | Should -Be 1
        @($result.Kept).Count | Should -Be 1
        @($result.Kept)[0].ToString() | Should -Be $other
    }

    It 'на порожньому вводі не падає й нічого не рахує' {
        # "git add" без змін не друкує нічого - викликач отримує $null, не масив.
        $result = Split-GitEolNoise -Line $null
        $result.Suppressed | Should -Be 0
        $result.Kept | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Прогнати тести — мають упасти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL — модуль `tools/lib/GitOutput.psm1` не існує, `Import-Module` кидає виняток.

- [ ] **Step 3: Написати модуль**

Створити `tools/lib/GitOutput.psm1`:

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest

function Split-GitEolNoise {
    <#
    .SYNOPSIS
        Розділяє вивід "git add" на видимі рядки й приховані попередження про конверсію
        кінців рядків.
    .DESCRIPTION
        До версії 0.6.0 шаблон .gitattributes ніс "* text=auto eol=crlf", і кожен
        "git add" щойно вивантаженого Designer XML друкував десятки попереджень
        "LF will be replaced by CRLF" — на реплеї довгого хвоста це сотні рядків, під
        якими губився корисний вивід. Тому storage-sync.ps1 їх фільтрував.

        Під чинною політикою (docs/text-policy.md: -text на деревах, які пише платформа)
        таких попереджень на вихідниках бути не має ВЗАГАЛІ. Тому кількість прихованого
        повертається окремо: викликач друкує її як сигнал, що політику в цьому
        репозиторії або зламано, або ще не мігровано. Фільтр без лічильника глушив би
        рівно той сигнал, заради якого політику й міняли.

        Прибирається лише ця відома форма; будь-що інше в stderr "git add" — реальний
        сигнал і лишається видимим.
    .EXAMPLE
        $r = Split-GitEolNoise -Line (git -C $repo add -A -- $Product 2>&1)
        $r.Kept | ForEach-Object { Write-Host $_ }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Line
    )

    $pattern = "^warning: in the working copy of '.+', " +
               "(LF will be replaced by CRLF|CRLF will be replaced by LF) " +
               "the next time Git touches it$"

    $all  = @($Line | Where-Object { $null -ne $_ })
    $kept = @($all | Where-Object { $_.ToString() -notmatch $pattern })

    [pscustomobject]@{
        Kept       = $kept
        Suppressed = $all.Count - $kept.Count
    }
}

Export-ModuleMember -Function Split-GitEolNoise
```

- [ ] **Step 4: Прогнати тести — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, три тести `GitOutput.Tests.ps1`.

- [ ] **Step 5: Підключити модуль у `storage-sync.ps1`**

Після рядка 32 (`Import-Module (Join-Path $PSScriptRoot 'lib/SyncState.psm1') -Force`)
додати:

```powershell
Import-Module (Join-Path $PSScriptRoot 'lib/GitOutput.psm1') -Force
```

Замінити блок фільтра (рядки 242-250, від коментаря `# Фільтруємо, а не глушимо:` до
рядка з `Write-Host $_`) на:

```powershell
        # Фільтруємо з лічильником, а не глушимо. Під чинною політикою
        # (.gitattributes: -text на деревах, які пише платформа) цих попереджень тут
        # не має бути взагалі — тому їхня поява це сигнал, що політику в репозиторії
        # зламано або ще не мігровано, а не шум. Обґрунтування й процедура міграції —
        # docs/text-policy.md у плагіні.
        $addNoise = Split-GitEolNoise -Line $addOutput
        $addNoise.Kept | ForEach-Object { Write-Host $_ }
        if ($addNoise.Suppressed -gt 0) {
            Write-Host ("  Приховано {0} попереджень git про конверсію кінців рядків." -f `
                $addNoise.Suppressed) -ForegroundColor Yellow
            Write-Host '  Під чинною політикою .gitattributes їх не має бути — див. docs/text-policy.md.' `
                -ForegroundColor Yellow
        }
```

- [ ] **Step 6: Оновити probe імпортів**

`docs/follow-ups.md` §5 фіксує, що `fixtures/module-visibility-probe.ps1` дзеркалить
список імпортів `storage-sync.ps1` вручну й ніщо цього не перевіряє. Новий модуль треба
додати туди явно, інакше probe розійдеться зі скриптом.

У `tools/tests/fixtures/module-visibility-probe.ps1` після рядка з `SyncState.psm1`
додати:

```powershell
Import-Module (Join-Path $LibDir 'GitOutput.psm1') -Force
```

У тому ж файлі, у блоці `.SYNOPSIS`, замінити «шість lib-модулів» на «сім lib-модулів».

У `tools/tests/ModuleImportOrder.Tests.ps1` додати `'Split-GitEolNoise'` останнім
елементом масиву `$script:RequiredCommands` (після `'Get-PendingVersions'`).

- [ ] **Step 7: Прогнати тести — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS. Зокрема `ModuleImportOrder.Tests.ps1` бачить `Split-GitEolNoise`
видимою в глобальній області, а два наявні тести фільтра в `StorageSync.Tests.ps1`
лишаються зеленими — вони перевіряють форму попередження git і поведінку регекса, а не
місце, де той регекс живе.

- [ ] **Step 8: Коміт**

```bash
git add tools/lib/GitOutput.psm1 tools/tests/GitOutput.Tests.ps1 tools/storage-sync.ps1 tools/tests/fixtures/module-visibility-probe.ps1 tools/tests/ModuleImportOrder.Tests.ps1
git commit -m "storage-sync: фільтр eol-попереджень стає рахованим і тестованим

Під політикою -text цих попереджень на вихідниках бути не має, тому мовчазний фільтр
глушив би сигнал про зламану політику. Заразом інлайн-блок винесено у Split-GitEolNoise:
тепер тест виконує production-функцію, а не дублює її регекс у себе."
```

---

### Task 4: Документація контуру

Одна задача, бо всі шість файлів описують ту саму зміну для різних читачів, і рев'ю має
бачити їх разом: розбіжність між ними гірша за відсутність будь-якого з них.

**Files:**
- Modify: `docs/storage-and-git.md` (розділ «Тека `build`» і таблиця напрямків)
- Modify: `skills/storage-pipeline/SKILL.md` (таблиця намірів і опис `build`)
- Modify: `templates/CLAUDE.md:69-74`
- Modify: `CLAUDE.md` (таблиця «Де що шукати»)
- Modify: `tools/build.ps1:5-8`
- Modify: `docs/follow-ups.md` (дописати чотири записи в кінець)

**Interfaces:**
- Consumes: `docs/text-policy.md` (задача 1), шаблон `v8project.yaml` (задача 2),
  повідомлення `Split-GitEolNoise` (задача 3), наявний `docs/unica-contract.md`.
- Produces: нічого для наступних задач.

- [ ] **Step 1: `docs/storage-and-git.md` — дві бази**

У розділі «Тека `build`» після абзацу про три різні теки `build` додати:

```markdown
## Дві бази, два власники

Контур торкається двох інформаційних баз, і плутати їх не можна — саме ця плутанина була
першопричиною того, що конвеєр розійшовся з каноном Unica.

| | Дев-база (людська) | База воркспейсу (машинна) |
|---|---|---|
| Де | сервер, підключена до сховища | файлова, `<Продукт>/build/ib` |
| Хто володіє | людина, Конфігуратор | Unica |
| Звідки стан | сховище | git: `cf/src` + `cfe/src` |
| Навіщо | комітити у сховище, дивитись на реальних даних | збірка, синтаксис-контроль, тести, запуск клієнта |
| Викинути й відтворити | ні | так, будь-коли |
| Хто в kit її торкається | `dump-config.ps1`, `load-ext.ps1` — на явне прохання | ніхто; це територія Unica |

Машинну базу оголошує блок `infobase:` у `<Продукт>/v8project.yaml`
(`connection: 'File=build/ib'`). Без нього підключення приходить із
`v8project.local.yaml` і вказує на дев-базу — тобто `operation=build` Unica починає
мутувати базу, де людина працює Конфігуратором.

Створення машинної бази коштує одноразово близько 11 хвилин на конфігурації розміру УНФ:
завантаження `cf/src` — 8 хв 55 с, `/UpdateDBCfg` — 2 хв 08 с; готова база займає 3.6 ГБ.
```

- [ ] **Step 2: `skills/storage-pipeline/SKILL.md` — новий шлях збірки й round-trip**

В описі операції **build** (розділ 2) після наявного абзацу додати:

```markdown
  **Два шляхи збірки `.cfe`, і вони не рівноцінні.** `build.ps1` вантажить розширення в
  тимчасову базу й одразу вивантажує `.cfe` — швидко, але **не перевіряє застосовність**
  розширення до конфігурації: `/UpdateDBCfg` не виконується, тому несумісність
  (наприклад, вендор змінив тип реквізиту, а розширення несе стару запозичену копію)
  проходить мовчки, і артефакт виглядає готовим. Канонічний шлях — `operation=build`
  плюс `operation=make` Unica у базі воркспейсу: `build` робить `update_db_cfg`, і саме
  він цю несумісність ловить. Обидві операції застосовні (`dryRun: false`) — тобто
  **лише на явне прохання користувача**, як і `-Apply`.

  **Приймальна перевірка вихідників — round-trip через платформу.** Ні `git status`, ні
  `unica.cfe.validate` не бачать класу розходжень, де вихідники в git відрізняються від
  того, що вважає канонічним платформа. Процедура — `${CLAUDE_PLUGIN_ROOT}/docs/text-policy.md`.
```

- [ ] **Step 3: `templates/CLAUDE.md` — виправити твердження про `make`**

Замінити абзац у розділі «Робота через Unica» (рядки 69-74) на:

```markdown
**Воркспейс — тека продукту, не корінь репозиторію** (автоскан Unica падає на першому
не-UTF-8 файлі; вузький корінь тримає BSL-індекс малим). База воркспейсу — файлова, під
`build/`, оголошена блоком `infobase:` у `v8project.yaml`: вона машинна й похідна від git,
а дев-база лишається людською.

Обмеження маршруту: `dump` на Windows fail-closed — вивантажує Конфігуратор через скрипти
плагіна; `make` для **`.epf`/`.erf`** на Windows падає на публікації артефакту — збирає
`build.ps1` плагіна. Для **`.cfe` це обмеження не діє**: `make` розширення публікує
артефакт напряму й перевірений. `cfe.borrow` і `cfe.diff` потребують вивантаженої
`cf/src`; вона ж — основа бази воркспейсу.
```

- [ ] **Step 4: `CLAUDE.md` — таблиця «Де що шукати»**

Додати два рядки в таблицю розділу «Де що шукати»:

```markdown
| Чому вихідники не конвертуються і як мігрувати репо | `docs/text-policy.md` |
| На що покладаємось в Unica й що там зламано | `docs/unica-contract.md` |
```

- [ ] **Step 5: `tools/build.ps1` — виправити коментар**

Замінити рядки 5-8 (блок `.DESCRIPTION`) на:

```powershell
.DESCRIPTION
    Збірка йде платформою напряму, а не через Unica. Причина НЕ в публікації артефакту:
    операція make для .cfe на Windows перевірена й працює (обмеження "Отказано в доступе,
    os error 5" стосується зовнішніх обробок, .epf/.erf). Причина в тому, що
    operation=build Unica обов'язково виконує update_db_cfg, а цьому скрипту він не
    потрібен для вивантаження .cfe.
    ЦІНА цього рішення: скрипт НЕ перевіряє застосовність розширення до конфігурації.
    Несумісність (вендор змінив тип реквізиту, а розширення несе стару запозичену копію)
    проходить мовчки, і .cfe виглядає готовим, хоч у базі не застосується. Перевіряє це
    лише канонічний шлях Unica — див. docs/storage-and-git.md.
```

- [ ] **Step 6: `docs/follow-ups.md` — чотири записи**

Дописати в кінець файлу:

```markdown
## 11. `Form.xml` із реплею без трьох елементів документа

Два файли `Documents/{ЧекККМ,ЧекККМВозврат}/Forms/ФормаДокумента/Ext/Form.xml` у пілотному
репозиторії не мають елементів `AutoTime`, `UsePostingMode` і `RepostOnWrite`, які
платформа дописує сама. Виявлено round-trip'ом (`docs/text-policy.md`). Файли прийшли з
гілки `main`, тобто з реплею сховища, а не з правок розробника.

Походження не встановлене. Дві підозри, і вони ведуть у різні місця: конвертація EDT→XML
під час `repo-migration` (обидва мігровані репозиторії прийшли з EDT) або сам реплей у
`storage-sync.ps1`. Розбір вимагає відтворення реплею на відомій версії сховища й звірки
з тим, що віддає платформа, — окремий цикл, який не можна зробити принагідно.

Наслідок обмежений: три відсутні елементи не заважають ні збірці, ні застосуванню, вони
дають шум у порівнянні зі сховищем.

## 12. Дефекти Unica й v8-runner

Ведуться окремо — `docs/unica-contract.md`. Там перелік із формою рішення й **зовнішньою
перевіркою** кожного пункту, трекінг апстрімних ішузів і процедура звірки після оновлення
плагіна. Тут навмисно не дублюється: два списки розійшлися б.

## 13. Платформа не пише завершального переводу рядка в XML

Усі файли Designer XML закінчуються на `>` без `\r\n` — перевірено на 166 файлах,
винятків нуль. Правила в `.gitattributes` це не потребує (git такого не додає), але
будь-який генератор XML у kit має це враховувати: інакше побайтова звірка дампу дасть
хибне спрацювання на кожному згенерованому файлі.

Зараз у kit генераторів XML немає — запис існує, щоб обмеження не довелось відкривати
заново тому, хто перший їх напише.

## 14. Прогін `-Apply` не перевіряє канонічності вихідників

`storage-sync.ps1` комітить те, що віддала платформа, і це правильно. Але жодна автоматична
перевірка не підтверджує, що вихідники в git лишаються тими, які платформа вважає
канонічними, — це робить лише round-trip (`docs/text-policy.md`), і робить його людина
вручну.

Вбудувати round-trip у `-Apply` було б дорого: це ще одне завантаження в тимчасову ІБ і
ще одне вивантаження на кожен прогін, тобто подвоєння вартості синхронізації заради
перевірки, яка спрацьовує раз на політику, а не раз на версію. Розумніший варіант —
окрема команда `verify`, яку запускають після міграції й після оновлення Unica; вона поки
не написана.
```

- [ ] **Step 7: Прогнати тести — мають пройти**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, без змін проти задачі 3. Зміни цієї задачі — документація й один
коментар; тести їх не покривають, тому прогін тут доводить лише відсутність регресії.

- [ ] **Step 8: Перевірити правила скілів**

Run: `grep -rn 'CLAUDE_PLUGIN_ROOT' skills/ | grep -v '/tools/\|/templates/\|/docs/'`
Expected: порожній вивід.

Run: `grep -rn 'storage-pipeline\|product-onboarding\|repo-migration' skills/ | grep -v 'v8storagekit:'`
Expected: збіги лише в заголовках і прозі, де йдеться про сам файл скіла, а не про
адресацію. Будь-яке місце, що **викликає** скіл голим іменем, треба виправити на
`v8storagekit:<ім'я>`.

- [ ] **Step 9: Коміт**

```bash
git add docs/storage-and-git.md skills/storage-pipeline/SKILL.md templates/CLAUDE.md CLAUDE.md tools/build.ps1 docs/follow-ups.md
git commit -m "docs: дві бази, канонічний шлях збірки, round-trip як приймальна перевірка

Виправлено твердження, що make Unica на Windows падає на публікації - воно вірне для
.epf/.erf і хибне для .cfe. Справжня ціна швидкої гілки build.ps1 названа прямо: вона не
перевіряє застосовність розширення до конфігурації."
```

---

### Task 5: Версія й фінальна перевірка

Без бампу версії `claude plugin update` не перезапише кеш споживача — уся робота
попередніх задач нікуди не дійде.

**Files:**
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: усе попереднє.
- Produces: нічого.

- [ ] **Step 1: Підняти версію**

У `.claude-plugin/plugin.json` замінити `"version": "0.5.0"` на `"version": "0.6.0"`.

- [ ] **Step 2: Перевірити, що JSON лишився валідним**

Run: `pwsh -NoProfile -Command "Get-Content .claude-plugin/plugin.json -Raw | ConvertFrom-Json | Select-Object name, version"`
Expected: `name` = `v8storagekit`, `version` = `0.6.0`, без винятку.

- [ ] **Step 3: Повний прогін тестів**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS, нуль провалених. Нові набори: `Templates.Tests.ps1` (6 тестів),
`GitOutput.Tests.ps1` (3 тести).

- [ ] **Step 4: Перевірити середовище**

Run: `pwsh -NoProfile -File tools/check-environment.ps1`
Expected: код виходу 0. Попередження про відсутню Unica (якщо є) на код виходу не
впливають — це категорія «Вихідники», не «Конвеєр».

- [ ] **Step 5: Звірити, що дерево чисте, а роздане — узгоджене**

Run: `git status --short`
Expected: порожньо, крім `.claude-plugin/plugin.json` до коміту наступним кроком.

Run: `grep -c 'eol=' templates/gitattributes`
Expected: `0`.

- [ ] **Step 6: Коміт**

```bash
git add .claude-plugin/plugin.json
git commit -m "plugin.json: версія 0.5.0 -> 0.6.0

Перехід конвеєра на канон Unica: база воркспейсу в шаблоні v8project.yaml, імʼя
EXTENSION-джерела зі storage.json, політика -text на деревах платформи, лічильник
прихованих eol-попереджень. Без бампу claude plugin update не перезапише кеш споживача."
```

---

## Що цей план навмисно НЕ робить

- **Не видаляє `.cfe`-гілку `build.ps1`.** Рішення відкладене: числа для повторного
  `build` Unica ще не отримані — заміри заблоковані несумісністю розширення в
  репозиторії-споживачі. Специфікація, §5.5, крок 2.
- **Не мігрує чужі репозиторії.** Процедура з `docs/text-policy.md` виконується в їхніх
  сесіях, їхніми людьми, з їхньою санкцією.
- **Не лагодить Unica.** Тільки фіксує залежності — `docs/unica-contract.md`.
- **Не чіпає кореневий `.gitattributes`** цього репозиторію й **не змінює**
  `templates/settings.json`.
- **Не пушить і не робить релізу.**
