# D1. Скіл `v8storagekit:yaxunit` — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дати агентові в репозиторії-споживачі скіл, який пояснює, як працювати з тестами YaXUnit і як їх писати, не прив'язуючись до версії YaXUnit: деталі агент читає в самій документації.

**Architecture:** три markdown-файли в `skills/yaxunit/`. `SKILL.md` описує лише незмінне між версіями: модель, анатомію тестового модуля, ідеї API, порядок роботи. `references/docs-map.md` — навігаційна карта документації YaXUnit (розділ → що шукати → коли → адреса), а не її копія. `references/our-contour.md` — виміряні межі нашого контуру, кожна з датою й версією. Машинні правила для скілів (`tools/tests/Skills.Tests.ps1`) поширюються на новий скіл, а новий `Describe` перевіряє властивості, які роблять скіл незалежним від версії.

**Tech Stack:** Markdown; Pester 5 (`tools/tests/Skills.Tests.ps1`); PowerShell 7.

**Spec:** `docs/superpowers/specs/2026-09-23-test-contour-design.md`, §3 (Р5–Р7), §7, §9 п. 1.

## Global Constraints

- Скіл адресується як `v8storagekit:yaxunit`, і так само в перехресних посиланнях (правило 2 `CLAUDE.md`).
- `${CLAUDE_PLUGIN_ROOT}` — лише всередині шляху, у всіх `.md` скіла, включно з `references/` (правило 1 `CLAUDE.md`).
- Скіл **не прив'язаний до версії YaXUnit** (Р7). Номер версії може стояти лише в `our-contour.md`, при конкретному вимірі.
- **Жодних копій документації YaXUnit** (§7.3): карта містить назви розділів, опис «що там шукати» своїми словами й адреси.
- Правил із `.cursor/rules` YaXUnit не брати (§7.3).
- Конвенцію іменування скіл не фіксує. Він відсилає до сусідніх тестів і документів проєкту, а типову форму дає як запасний варіант (§7.2).
- Документація YaXUnit: сайт `https://bia-technologies.github.io/yaxunit/`, репозиторій `bia-technologies/yaxunit`, гілка `develop`, тека `documentation/docs/`. Ліцензія репозиторію — Apache-2.0 (`gh api repos/bia-technologies/yaxunit`, 2026-09-23).
- Версія плагіна: `1.1.0` → `1.2.0`, з рядком переходу в `skills/onboarding/references/upgrades.md` (правило 3 `CLAUDE.md`; інакше падає тест «upgrades.md описує перехід на ПОТОЧНУ версію»).
- Посилання на команду `kit tests` у скілі **не з'являється**: команди ще немає, її додає план D2 (§9 п. 1 спеки).
- Проєктні константи виконавця (коміт, мова, форми прогону тестів, контракт звіту) — у `.claude/skills/kit-dev/references/subagent-brief.md`.

## Review Focus

- **Посилання в карті веде на неіснуючу сторінку** (документацію перебудували). Очікування: тест перевіряє, що кожен рядок карти має адресу на сайті документації. Живу доступність перевіряє виконавець один раз WebFetch-ем (Task 2, крок 3). Тест мережі не чіпає: тест, що залежить від мережі, — червоний без причини.
- **Скіл непомітно прив'язався до версії.** Хтось дописав у `SKILL.md` «у 25.12 метод …». Очікування: тест забороняє номери версій виду `\d{2}\.\d{2}` у `SKILL.md` і `docs-map.md` (Task 1).
- **Межа в `our-contour.md` без дати чи версії.** Агент тоді не бачить, що вона могла застаріти. Очікування: тест вимагає, щоб кожен пункт списку межі мав і дату `YYYY-MM-DD`, і позначку джерела (`виміряно` / `з документації`) (Task 1).
- **Скіл лишився невидимим для агента.** Він є на диску, але `using-v8storagekit` на нього не веде, тож агент у сесії споживача про нього не дізнається. Очікування: тест вимагає рядок `v8storagekit:yaxunit` у таблиці намірів `using-v8storagekit` (Task 3).
- **Карта перетворилась на копію.** Очікування: тест обмежує довжину клітинки «що шукати» (≤ 200 символів) і забороняє блоки коду в `docs-map.md` (Task 1).

---

### Task 1: Тести скіла — червоні

**Files:**
- Modify: `tools/tests/Skills.Tests.ps1` (масив `$script:Allowed` у `BeforeAll` першого `Describe`; новий `Describe` у кінці файлу)

**Interfaces:**
- Consumes: наявний `Describe 'skills/*/SKILL.md — правила, які легко порушити'`: його `BeforeAll` будує `$script:Skills` і `$script:SkillDocs` з тек, чиє ім'я є в `$script:Allowed`.
- Produces: `'yaxunit'` у `$script:Allowed`. Від цього наявні `It` (frontmatter, `${CLAUDE_PLUGIN_ROOT}`, перехресні посилання, «немає тек поза переліком») поширюються на новий скіл.

- [ ] **Step 1: Додати `yaxunit` у перелік**

У `BeforeAll` першого `Describe` рядок

```powershell
        $script:Allowed = @('using-v8storagekit', 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify')   # migrate немає: спека 2f2da62, §9
```

замінити на

```powershell
        # yaxunit — довідковий скіл (D1, спека 2026-09-23 §7), не скіл життєвого циклу: у переліки
        # $lifecycle нижче він навмисно не входить — розділу «Межі» з -Apply у нього немає, бо команд він не кличе.
        $script:Allowed = @('using-v8storagekit', 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify', 'yaxunit')   # migrate немає: спека 2f2da62, §9
```

- [ ] **Step 2: Додати `Describe` для властивостей нового скіла**

У кінець файлу `tools/tests/Skills.Tests.ps1`:

```powershell
Describe 'skills/yaxunit — не прив''язаний до версії YaXUnit, карта замість копії (спека 2026-09-23 §7)' {
    BeforeAll {
        $script:Dir     = Join-Path $PSScriptRoot '../../skills/yaxunit'
        $script:Skill   = Join-Path $script:Dir 'SKILL.md'
        $script:Map     = Join-Path $script:Dir 'references/docs-map.md'
        $script:Contour = Join-Path $script:Dir 'references/our-contour.md'
        function script:Text([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 }
    }

    It 'три файли на місці, і SKILL.md веде в обидва references/' {
        foreach ($p in $script:Skill, $script:Map, $script:Contour) { $p | Should -Exist }
        $t = Text $script:Skill
        $t | Should -BeLike '*references/docs-map.md*'
        $t | Should -BeLike '*references/our-contour.md*'
    }

    It 'SKILL.md і docs-map.md не називають версії YaXUnit (Р7) — версія живе лише в our-contour.md' {
        # Форма версії YaXUnit — РР.ММ (25.12, 24.09). Дати YYYY-MM-DD під шаблон не потрапляють:
        # у них дефіс, а не крапка.
        foreach ($p in $script:Skill, $script:Map) {
            [regex]::Matches((Text $p), '(?<![\d.])\d{2}\.\d{2}(?![\d.])').Value |
                Should -BeNullOrEmpty -Because "$p не має прив'язуватись до версії YaXUnit"
        }
    }

    It 'docs-map.md — карта, а не копія: рядки таблиці з адресою сайту, клітинка «що шукати» коротка, без коду' {
        $t = Text $script:Map
        $t | Should -Not -Match '```' -Because 'блок коду в карті — ознака скопійованої документації'
        $rows = @(($t -split "`r?`n") | Where-Object { $_ -match '^\|' -and $_ -notmatch '^\|\s*-' -and $_ -notmatch '^\|\s*Розділ' })
        $rows.Count | Should -BeGreaterThan 10 -Because 'карта має покривати документацію, а не два розділи'
        foreach ($r in $rows) {
            $r | Should -Match 'https://bia-technologies\.github\.io/yaxunit/' -Because "рядок без адреси: $r"
            $cells = @($r.Trim('|').Split('|') | ForEach-Object Trim)
            $cells.Count | Should -Be 4 -Because "рядок має чотири колонки (Розділ | Що там шукати | Коли йти | Адреса): $r"
            $cells[1].Length | Should -BeLessOrEqual 200 -Because "клітинка «що шукати» розрослась у переказ: $r"
        }
        $t | Should -Match 'bia-technologies/yaxunit' -Because 'карта має називати репозиторій із прикладами (тести самого YaXUnit)'
    }

    It 'our-contour.md: кожна межа має дату й позначку джерела' {
        $items = @(((Text $script:Contour) -split "`r?`n") | Where-Object { $_ -match '^- \*\*' })
        $items.Count | Should -BeGreaterOrEqual 8 -Because 'спека §7.2 називає шість виміряних меж і дві з документації'
        foreach ($i in $items) {
            $i | Should -Match '\d{4}-\d{2}-\d{2}' -Because "межа без дати: $i"
            $i | Should -Match 'виміряно|з документації' -Because "межа без позначки джерела: $i"
        }
    }

    It 'SKILL.md не фіксує конвенцію іменування: спершу сусідні тести проєкту, типова форма — запасна' {
        $t = Text $script:Skill
        $t | Should -Match 'сусідні тести'
        $t | Should -Match '<Префікс>_Тесты<Предмет>'
    }

    It 'скіл не називає команди kit tests (її додає план D2)' {
        foreach ($p in $script:Skill, $script:Map, $script:Contour) {
            (Text $p) | Should -Not -Match 'kit(\.ps1)?"? tests' -Because 'команди kit tests ще немає'
        }
    }
}
```

- [ ] **Step 3: Прогнати тести й переконатись, що вони червоні з правильної причини**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`

Expected: FAIL лише в новому `Describe 'skills/yaxunit — …'`: усі його `It` червоні, бо файлів немає (`Should -Exist` / `Get-Content` на відсутньому шляху). Наявні `It` першого `Describe` лишаються зеленими: тека `skills/yaxunit` ще не існує і в `$script:Skills` не потрапляє, а посилань на `v8storagekit:yaxunit` ніде ще немає. Якщо впало щось поза новим `Describe`, зупинитись і з'ясувати причину до Task 2.

- [ ] **Step 4: Commit**

```bash
git add tools/tests/Skills.Tests.ps1
git commit -m "тести: властивості скіла v8storagekit:yaxunit (червоні, D1 Task 1)" --only -- tools/tests/Skills.Tests.ps1
```

---

### Task 2: Скіл `skills/yaxunit/` — три файли

**Files:**
- Create: `skills/yaxunit/SKILL.md`
- Create: `skills/yaxunit/references/docs-map.md`
- Create: `skills/yaxunit/references/our-contour.md`

**Interfaces:**
- Consumes: тести Task 1.
- Produces: адресу скіла `v8storagekit:yaxunit`, на яку посилається Task 3.

- [ ] **Step 1: `skills/yaxunit/SKILL.md`**

```markdown
---
name: yaxunit
description: Як працювати з тестами YaXUnit у репозиторії, підключеному до kit, — модель контуру, анатомія тестового модуля, ідеї API, порядок роботи, де в документації YaXUnit деталі й приклади. Тригери — «напиши тест», «покрий тестами», «YaXUnit», «юніт-тест 1С», «чому впав тест», «operation=test», «тестове розширення».
---

# yaxunit — тести YaXUnit у нашому контурі

Цей скіл дає **модель і порядок роботи**, а не довідку API. API YaXUnit змінюється від релізу до
релізу, тож назви методів, параметри й приклади бери з документації тієї версії, що стоїть у
базі: карта розділів — `references/docs-map.md`. Межі, які ми поміряли в нашому контурі,
лежать у `references/our-contour.md`. Прочитай його **до** першого запуску тестів: там
описано, чого документація не каже.

## Модель

- **Фреймворк — окреме розширення конфігурації** `YAXUNIT` у базі агента. У git його вихідників
  немає: файл `.cfe` завантажує `operation=tools-download tool=yaxunit` Уніки, а в базу його
  ставить людина або kit.
- **Тести — окреме розширення-source-set воркспейсу** (у SimplyConnect —
  `SimplyConnect_SMBru/tests/src`). У маніфесті `v8storagekit.yaml` воно оголошене як
  `{ truth: git }`: сховища в нього немає, джерело істини — git.
- **Тестовий модуль — загальний модуль тестового розширення.** Кожен модуль сам реєструє свої
  тести; фреймворк знаходить модулі й виконує зареєстроване.
- **Запуск — `operation=test` Уніки з `testRunner=yaxunit`**, `cwd` = воркспейс. Виконує тести
  Підприємство в базі агента.

## Анатомія тестового модуля

Точні імена методів дивись у документації своєї версії (розділи «Регистрация тестов», «Первый
тест», «Контекст», «События» — `references/docs-map.md`). Незмінні між версіями ідеї:

- **Реєстрація.** Експортна процедура-точка входу, яку викликає фреймворк; у ній кожен тест-метод
  додається за іменем, з уточненням, де він виконується (сервер, клієнт) і в якому режимі
  (у транзакції, з видаленням тестових даних).
- **Тест-метод.** Експортна процедура без параметрів: готує дані, викликає код, перевіряє
  результат твердженнями.
- **Події.** Обробники «перед/після всіх тестів модуля» і «перед/після кожного тесту» — для
  підготовки й прибирання.
- **Контекст.** Сховище значень між подіями й тестами одного прогону.

## Ідеї API

- **Твердження — fluent-ланцюжок:** «очікую, що значення … дорівнює / заповнене / має тип / містить».
  Каталог тверджень — у розділі «Утверждения».
- **Тестові дані** — генератори випадкових значень і конструктори об'єктів («створи елемент /
  документ з такими реквизитами й записати»). Розділ «Тестовые данные».
- **Моки.** Мокито підміняє методи **конфігурації** через `&Вместо` на запозичених методах. Методи
  розширень, платформи й зовнішніх обробок він **не** підміняє (межа — `references/our-contour.md`).
  Для HTTP та подібного є готові заглушки (розділ «Заглушки»).
- **Предикати** — опис умов для пошуку й перевірки колекцій.

## Порядок роботи

1. **Подивитись сусідні тести** в тестовому розширенні воркспейсу: як названі модулі, як
   влаштована реєстрація, чи є спільний модуль тестових даних, чи є помічник пізнього
   зв'язування (див. `references/our-contour.md`). Роби так, як уже зроблено в проєкті.
2. **Знайти приклад у документації** своєї версії (`references/docs-map.md`), а для
   нетривіального — у тестах самого YaXUnit (там само, розділ «Приклади»).
3. **Написати тест.** Один тест — одна поведінка; дані тест створює сам і сам по собі прибирає.
4. **`operation=syntax`**, далі **`operation=test`** — з обмеженнями з `references/our-contour.md`
   (зокрема: перед `test` потрібен `build` з `fullRebuild`).
5. **Розібрати падіння.** Якщо Уніка відповідає лише `timed out`, причину шукай у логах
   Підприємства прогону (шлях — `references/our-contour.md`), а не в самому тесті.

## Іменування

Конвенцію визначає проєкт, а не цей скіл: спершу сусідні тести й документи проєкту. Якщо в
проєкті ще немає жодного тесту, візьми типову форму `<Префікс>_Тесты<Предмет>` для модуля
(приклад SimplyConnect: `СМП_ТестыНумерацииПРРО`; спільні дані — `СМП_ТестыПРРОДанные`).
Конвенція самого YaXUnit (розділ «Именование тестов») писалась для його власних тестів.

## Межі

- Тести виконуються **лише в базі агента**, ніколи в базі людини.
- Скіл нічого не встановлює в базу й не знімає прапорців. Якщо контур зламаний (розширення
  немає, безпечний режим не знято), доповісти людині, що саме бачиш.
```

- [ ] **Step 2: `skills/yaxunit/references/docs-map.md`**

Основа — дерево `documentation/docs/` гілки `develop` (перелік знято `gh api repos/bia-technologies/yaxunit/git/trees/develop?recursive=1`, 2026-09-23). Адреса сторінки на сайті — `https://bia-technologies.github.io/yaxunit/docs/<шлях без .md>`. Правило для `index.md`: `…/<тека>/index.md` → `…/docs/<тека>`.

```markdown
# Карта документації YaXUnit

Документація живе на `https://bia-technologies.github.io/yaxunit/` і в репозиторії
`bia-technologies/yaxunit` (тека `documentation/docs/`). Тут лише **куди йти**: зміст читай на
сторінці, у версії, що стоїть у базі. Якщо адреса не відкривається, документацію перебудували:
знайди розділ за назвою на сайті й виправ рядок тут.

## Почати

| Розділ | Що там шукати | Коли йти | Адреса |
|---|---|---|---|
| Начало работы | загальна картина: що таке YaXUnit, з чого складається | перший раз | https://bia-technologies.github.io/yaxunit/docs/getting-started |
| Структура | як влаштований тестовий модуль і розширення з тестами | пишеш перший модуль | https://bia-technologies.github.io/yaxunit/docs/getting-started/structure |
| Первый тест | мінімальний тест від реєстрації до твердження | пишеш перший тест | https://bia-technologies.github.io/yaxunit/docs/getting-started/first-test |
| Fluent API | стиль ланцюжків, на якому стоїть весь API | читаєш чужий тест | https://bia-technologies.github.io/yaxunit/docs/getting-started/fluent-api |
| Рекомендации | що автори радять і від чого застерігають | перед великою серією тестів | https://bia-technologies.github.io/yaxunit/docs/getting-started/recomendations |
| Запуск | способи запуску | розбираєш, як Уніка запускає тести | https://bia-technologies.github.io/yaxunit/docs/getting-started/run/run |
| Конфигурация запуска | параметри файлу конфігурації прогону | тест-раннер поводиться дивно | https://bia-technologies.github.io/yaxunit/docs/getting-started/run/configuration |
| Установка | як ставиться розширення | контур у базі зламаний | https://bia-technologies.github.io/yaxunit/docs/getting-started/install/install |

## Писати тести

| Розділ | Що там шукати | Коли йти | Адреса |
|---|---|---|---|
| Регистрация тестов | точка входу модуля, додавання тестів, сервер/клієнт, режими | кожен новий модуль | https://bia-technologies.github.io/yaxunit/docs/features/test-registration |
| Контекст | збереження значень між подіями й тестами | тестам потрібен спільний стан | https://bia-technologies.github.io/yaxunit/docs/features/context |
| События | before/after для модуля й для кожного тесту | підготовка чи прибирання | https://bia-technologies.github.io/yaxunit/docs/features/events |
| Утверждения | каталог тверджень | будь-яка перевірка | https://bia-technologies.github.io/yaxunit/docs/features/assertions/assertions |
| Базовые утверждения | порівняння, тип, заповненість, колекції | звичайна перевірка значення | https://bia-technologies.github.io/yaxunit/docs/features/assertions/assertions-base |
| Утверждения для БД | перевірка записів у базі | тест змінює дані | https://bia-technologies.github.io/yaxunit/docs/features/assertions/assertions-db |
| Свои утверждения | як дописати власне твердження | стандартних бракує | https://bia-technologies.github.io/yaxunit/docs/features/assertions/assertions-custom |
| Предикаты | опис умов для колекцій і пошуку | перевірка «хоч один / кожен елемент» | https://bia-technologies.github.io/yaxunit/docs/features/predicates |
| Тестовые данные | загальна модель тестових даних | тесту потрібні дані | https://bia-technologies.github.io/yaxunit/docs/features/test-data/test-data |
| Генерация данных | генератори й конструктори об'єктів | створюєш елементи й документи | https://bia-technologies.github.io/yaxunit/docs/features/test-data/data-generation |
| Конструктор объектов | заповнення реквізитів і табличних частин | складний об'єкт | https://bia-technologies.github.io/yaxunit/docs/features/test-data/data-generation/object-builder |
| Записи регистров | конструктор наборів записів | тест залежить від регістра | https://bia-technologies.github.io/yaxunit/docs/features/test-data/data-generation/register-records-builder |
| Загрузка из макетов | дані з табличних макетів | багато однотипних даних | https://bia-technologies.github.io/yaxunit/docs/features/test-data/load-from-templates |
| Поиск данных | пошук наявних даних у базі | тест спирається на наявне | https://bia-technologies.github.io/yaxunit/docs/features/test-data/data-search |
| Удаление тестовых данных | автоматичне прибирання | тест лишає сміття | https://bia-technologies.github.io/yaxunit/docs/features/test-data/test-data-deletion |
| Варианты | параметризовані тести | той самий тест на кількох наборах | https://bia-technologies.github.io/yaxunit/docs/features/variants |
| Зависимости | залежності тестів від умов і даних | тест має передумову | https://bia-technologies.github.io/yaxunit/docs/features/dependencies |
| Именование тестов | конвенція авторів YaXUnit | у проєкті ще немає своєї | https://bia-technologies.github.io/yaxunit/docs/cook-book/test-naming |

## Ізоляція

| Розділ | Що там шукати | Коли йти | Адреса |
|---|---|---|---|
| Мокирование | загальний огляд підміни | код під тестом ходить назовні | https://bia-technologies.github.io/yaxunit/docs/features/mocking/mocking |
| Мокито | підміна методів конфігурації, обмеження | треба підмінити метод | https://bia-technologies.github.io/yaxunit/docs/features/mocking/mockito/mockito |
| Мокито — как это работает | механізм підміни | підміна не спрацьовує | https://bia-technologies.github.io/yaxunit/docs/features/mocking/mockito/how-to |
| Мокирование платформы | обхід для методів платформи | треба підмінити платформу | https://bia-technologies.github.io/yaxunit/docs/cook-book/platform-mocking |
| Заглушка HTTP-соединения | підміна HTTPСоединение | тест інтеграції по HTTP | https://bia-technologies.github.io/yaxunit/docs/features/mocking/stubs/http-connection |
| Заглушка HTTP-ответа | підміна HTTPОтвет | тест розбору відповіді | https://bia-technologies.github.io/yaxunit/docs/features/mocking/stubs/http-response |

## Допоміжне

| Розділ | Що там шукати | Коли йти | Адреса |
|---|---|---|---|
| Возможности | повний перелік можливостей | шукаєш, чи є готове | https://bia-technologies.github.io/yaxunit/docs/features/features |
| Вспомогательные модули | колекції, запити тощо | рутинні операції в тестах | https://bia-technologies.github.io/yaxunit/docs/features/auxiliary-modules |
| Конструктор текста | складання текстів для перевірок | перевірка великих текстів | https://bia-technologies.github.io/yaxunit/docs/features/text-constructor |
| Отчеты | формати звітів прогону | розбираєш звіт | https://bia-technologies.github.io/yaxunit/docs/features/reports/reports |
| Дымовые тесты | готові smoke-перевірки форм, ролей, записи | швидке широке покриття | https://bia-technologies.github.io/yaxunit/docs/features/smoke |
| Поведение движка | налаштування поведінки фреймворку | нестандартний прогін | https://bia-technologies.github.io/yaxunit/docs/features/customize-engine-behavior |
| Рецепты | готові розв'язки типових задач | задача схожа на типову | https://bia-technologies.github.io/yaxunit/docs/cook-book |

## Приклади

Найповніші приклади — тести самого YaXUnit у репозиторії `bia-technologies/yaxunit`, тека
`tests/src/CommonModules/`. Модулі з префіксом `ОМ_` тестують однойменні модулі фреймворку:
`ОМ_ЮТест` показує твердження, `ОМ_Мокито` і `ОМ_МокитоОбучение` — моки. Читати їх у тій гілці
чи тезі, що відповідає версії в базі.
```

- [ ] **Step 3: Перевірити кожну адресу карти один раз**

Для кожного рядка з адресою — `WebFetch` на адресу з промптом «назва сторінки й перший абзац». Якщо сторінка не відкривається або назва не та, знайти правильну адресу за назвою розділу на `https://bia-technologies.github.io/yaxunit/` і виправити рядок. Клітинку «що шукати» звірити з першим абзацом і, якщо треба, переписати **своїми словами**, не цитуючи. У звіті перелічити виправлені рядки: старе → нове.

- [ ] **Step 4: `skills/yaxunit/references/our-contour.md`**

```markdown
# Межі YaXUnit у нашому контурі

Кожна межа має дату, версію, на якій її міряли, і позначку джерела. **Виміряно** — сесія
YaXUnit-runner відтворювала межу в SimplyConnect_SMBru; сирий вивід лежить у пам'яті проєкту
SMP_SimplyConnect (`yaxunit-contour-how-to-run.md`, `yaxunit-needs-unsafe-mode.md`). **З
документації** — межу взято з документації YaXUnit, у нашому контурі її не відтворювали. Нова
версія YaXUnit може зняти будь-яку межу: якщо поводження інше, ніж описано, перевір і виправ
рядок, не обходь.

## Запуск

- **Перед кожним `operation=test` — `build` з `fullRebuild`.** Інакше правила обирають часткове
  завантаження, воно падає (`Ошибка чтения файла-списка загружаемых файлов`), і `test` зупиняється
  на `build prerequisite` з кодом 4. 14 випадків із 14, причину не з'ясовано. Виміряно
  2026-09-22, YaXUnit 25.12, Unica 0.12.x.
- **`operation=test` збирає всі source-set воркспейсу**, обмежити одним не можна. Виміряно
  2026-09-22, Unica 0.12.x.
- **`module` передавати без префікса `CommonModule.`**: з префіксом YaXUnit зациклюється
  (`Задано неправильное имя атрибута структуры`). Виміряно 2026-09-22, YaXUnit 25.12.
- **Артефакти успішного прогону раннер видаляє** (`cleaning successful test run directory`);
  каталог `build/temp/yaxunit/runs/<run>/` лишається лише після провалу, зберегти його способу
  немає (перевірено п'ять шляхів). Там же `enterprise.out.log` — справжня причина, коли Уніка
  каже лише `enterprise test run timed out`. Виміряно 2026-09-22, Unica 0.12.x.
- **Рядок підключення серверної бази — без внутрішніх лапок**: `Srvr=VSDEV;Ref=<база>;`. З
  лапками — `Сервер 1С:Предприятия не обнаружен`. Виміряно 2026-09-22, Unica 0.12.x.

## База

- **Розширення `YAXUNIT` має працювати не в безпечному режимі й без захисту від небезпечних
  дій.** Інакше воно падає на першому кроці, читаючи свій конфіг (`Расширение подключено в
  безопасном режиме. Чтение конфигурационного файла недоступно`,
  `ЮТПараметрыЗапускаСлужебный:372`). Прапорці — властивість підключення в базі: у git не
  лягають і зникають при перерозгортанні бази. Виміряно 2026-09-22, YaXUnit 25.12.

## Код тестів

- **Тестове розширення не може напряму викликати загальний модуль сусіднього продуктового
  розширення**: такий виклик не компілюється. Тому в кожному серверному тестовому модулі є
  приватний помічник пізнього зв'язування (SimplyConnect, задача `prro-test-contour-ru`,
  `common-context.md`, розділ «Конвенції коду тестів»). Виміряно до 2026-09-23 (спайк Task 1 плану
  переробки ПРРО; точну дату виконавець бере з `git log` SMP_SimplyConnect і ставить замість цієї).
- **Мокито не підміняє методи розширень.** Підміна «возможна только для методов конфигурации…
  недоступно для: методов платформы, методов расширений, методов внешних обработок». Продуктовий
  код, що живе в розширенні, моком не ізолюєш — лише дизайном: мережа в методі конфігурації або
  транспорт параметром. З документації 2026-09-23 (`features/mocking/mockito/mockito.md`,
  гілка develop), не виміряно.
- **Режим «у транзакції» відкочує лише серверні тести**, для клієнтських він ігнорується. На
  спільній серверній базі агента це єдиний захист від засмічення чужих даних. З документації
  2026-09-23, на VSDEV не виміряно.
```

- [ ] **Step 5: Прогнати тести**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`

Expected: PASS увесь набір. Нові `It` з Task 1 зелені. Наявні `It` з першого `Describe` тепер бачать `skills/yaxunit` (frontmatter, `${CLAUDE_PLUGIN_ROOT}`, перехресні посилання) — теж зелені.

- [ ] **Step 6: Мутаційна перевірка тестів Task 1 (на копії дерева, kit-dev case 7)**

На копії `skills/yaxunit/` (не в робочому дереві):
- дописати в `SKILL.md` рядок `у 25.12 метод змінився` → `It 'SKILL.md і docs-map.md не називають версії'` червоний;
- прибрати дату з одного пункту `our-contour.md` → `It 'our-contour.md: кожна межа має дату'` червоний;
- вставити блок коду в `docs-map.md` → `It 'docs-map.md — карта, а не копія'` червоний.

Кожну мутацію прогнати через `-Only Skills` на копії і повідомити в звіті, що тест почервонів. Робоче дерево не змінювати.

- [ ] **Step 7: Commit**

```bash
git add skills/yaxunit/SKILL.md skills/yaxunit/references/docs-map.md skills/yaxunit/references/our-contour.md
git commit -m "скіл v8storagekit:yaxunit: модель, карта документації, межі контуру (D1 Task 2)" --only -- skills/yaxunit/SKILL.md skills/yaxunit/references/docs-map.md skills/yaxunit/references/our-contour.md
```

---

### Task 3: Скіл видно агентові, документи й версія

**Files:**
- Modify: `skills/using-v8storagekit/SKILL.md` (таблиця «Куди йти за яким наміром»)
- Modify: `tools/tests/Skills.Tests.ps1` (новий `It` у `Describe 'skills/yaxunit …'`)
- Modify: `CLAUDE.md` (рядок `skills/` у таблиці «Структура»)
- Modify: `README.md` (рядок `skills/` у таблиці: «вісім скілів»)
- Modify: `.claude-plugin/plugin.json` (`version`)
- Modify: `skills/onboarding/references/upgrades.md` (таблиця переходів)

**Interfaces:**
- Consumes: адресу `v8storagekit:yaxunit` з Task 2.
- Produces: версію плагіна `1.2.0`. План D2 піднімає її далі.

- [ ] **Step 1: Тест — `using-v8storagekit` веде на новий скіл**

У `Describe 'skills/yaxunit — …'` додати:

```powershell
    It 'using-v8storagekit веде на v8storagekit:yaxunit у таблиці намірів — інакше агент споживача про скіл не дізнається' {
        $entry = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/using-v8storagekit/SKILL.md') -Raw -Encoding UTF8
        $row = @(($entry -split "`r?`n") | Where-Object { $_ -match '^\|' -and $_ -match 'v8storagekit:yaxunit' })
        $row.Count | Should -Be 1 -Because 'рядок таблиці «Куди йти за яким наміром» з v8storagekit:yaxunit'
        $row[0] | Should -Match 'тест'
    }
```

- [ ] **Step 2: Прогнати — червоний**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: FAIL рівно на новому `It` (`Expected 1, but got 0`).

- [ ] **Step 3: Рядок у таблиці намірів `using-v8storagekit`**

У `skills/using-v8storagekit/SKILL.md`, таблиця «Куди йти за яким наміром», після рядка `v8storagekit:verify` додати:

```markdown
| «напиши тест», «покрий тестами», «чому впав тест» | `v8storagekit:yaxunit` | — (тести пише агент, запускає `operation=test` Уніки) |
```

- [ ] **Step 4: Документи**

- `CLAUDE.md`, таблиця «Структура», рядок `skills/`: «Вісім скілів — вступний `using-v8storagekit` … і по одному на намір: `onboarding`, `sync`, `dump`, `reconcile`, `finish`, `provision`, `verify`.» замінити на «Дев'ять скілів — вступний `using-v8storagekit` (вантажить хук споживача), по одному на намір: `onboarding`, `sync`, `dump`, `reconcile`, `finish`, `provision`, `verify` — і довідковий `yaxunit` (тести YaXUnit, спека 2026-09-23 §7).» Решту рядка (про `references/gitsync-migration.md`) лишити й дописати: «`yaxunit` має `references/docs-map.md` і `references/our-contour.md`.»
- `README.md`, таблиця, рядок `| \`skills/\` | вісім скілів, які плагін роздає споживачам |` → `дев'ять скілів, які плагін роздає споживачам`.

Перевірка, що інших «вісім скілів» не лишилось: `grep -rn "вісім скіл\|Вісім скіл" --include=*.md . | grep -v docs/superpowers`. Має бути порожньо. Архівні плани й спеки в `docs/superpowers/` не правити: вони описують стан на свій момент.

- [ ] **Step 5: Версія і рядок переходу**

- `.claude-plugin/plugin.json`: `"version": "1.1.0"` → `"version": "1.2.0"`.
- `skills/onboarding/references/upgrades.md`, у таблицю переходів після рядка `1.0.0 | 1.1.0` додати:

```markdown
| 1.1.0 | 1.2.0 | Дій не потрібно — з'явився скіл `v8storagekit:yaxunit` (тести YaXUnit). Оновіть `kitVersion: 1.2.0` |
```

- [ ] **Step 6: Прогнати тести**

Run: `pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration`
Expected: PASS увесь набір. Зокрема `It 'onboarding посилається на upgrades.md, і той описує перехід на ПОТОЧНУ версію плагіна'` бачить `1.2.0`, а `Check.AgentBase` «версії збігаються» бере версію з `plugin.json` через фікстуру.

- [ ] **Step 7: Ручна перевірка правила 1 `CLAUDE.md`**

Run: `grep -rnP 'CLAUDE_PLUGIN_ROOT\}(?!/)' skills/`
Expected: порожньо.

- [ ] **Step 8: Commit**

```bash
git add skills/using-v8storagekit/SKILL.md tools/tests/Skills.Tests.ps1 CLAUDE.md README.md .claude-plugin/plugin.json skills/onboarding/references/upgrades.md
git commit -m "v8storagekit:yaxunit видно агентові; 1.2.0 (D1 Task 3)" --only -- skills/using-v8storagekit/SKILL.md tools/tests/Skills.Tests.ps1 CLAUDE.md README.md .claude-plugin/plugin.json skills/onboarding/references/upgrades.md
```

---

## Після плану

- Рев'ю гілки цілком. Кеш плагіна в споживачів оновлюється лише після push і бампу, а push — лише на явне прохання людини (правило «Межі» `CLAUDE.md`).
- Пілот: у сесії SimplyConnect попросити агента «напиши тест на <X>» і подивитись, чи він сам відкриває `v8storagekit:yaxunit`, іде за картою в документацію й читає `our-contour.md` до запуску.
