# Пілот kit 1.6.0 під Unica 0.16 — журнал тестера tehnokrat_unf

Бриф — повідомлення архітектора (сесія `unica-016-adaptation`) від 2026-11-20; основний журнал і пункти пілоту —
`2026-11-20-unica-016-pilot.md` (споживач BankExchange). Тут — лише споживач `R:\github\tehnokrat_unf`.

- Споживач: `tehnokrat_unf`, `kitVersion: 1.4.0`, гілка `main` чиста (`4bae2d94b`), Windows Server 2022.
- Джерела: `base` (УНФ на підтримці вендора, `truth: storage`, з поставкою) і `ТК_Адаптация` (`truth: storage`).
- База агента — серверна `tehnokrat_unf_sydorenko_claude` (накладка `tehnokrat/v8project.local.yaml`).
- Плагін: `v8storagekit@smp-v8storagekit-016` 1.6.0 (знімок `44dfd9a`); спека — коміт `25a6143`.
- Сесія тестера: `tehnokrat_unf_pilot`.

## Журнал

### 2026-11-20 — п.1. Хук старту в корені репо

**Умова.** Нова сесія Claude Code, cwd `R:\github\tehnokrat_unf`, репо ще у форматі 1.4.0 (`v8project.yaml` з `infobase:`,
без `providers`), плагін 1.6.0.

**Виклик.** Хук `SessionStart` плагіна (автоматично, без дій тестера).

**Сирий вивід.** Перше повідомлення сесії містить два блоки `<v8storagekit>`:

1. Блок «Стан сховищ» — **інлайн, без `<persisted-output>`**:

```
## Стан сховищ (kit session-check)

УВАГА: kit session-check завершився неочікуваним кодом 1 (очікувалось 0 або 3) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:
session-check — client Tehnokrat
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.yaml: стара форма 'infobase:' — kit читає базу агента лише з infobases.origin у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml і приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.6.0»).
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.yaml: немає providers — запис і завантаження бази агента мусить робити один виконавець (інваріант C1; дефект раннера #459). Додайте: providers: { push: designer, pull: designer, download: designer }.
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml: стара форма 'infobase:' — kit читає базу агента лише з infobases.origin у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml і приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.6.0»).
Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.

Репозиторій під kit. Правила контуру — скіл `v8storagekit:using-v8storagekit`: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем.
```

2. Окремий блок **під `<persisted-output>`** («Output too large (11.5KB)»), у контексті лише прев'ю ~2KB. Файл
   `tool-results/hook-…-SessionStart-…-additionalContext.txt` (17818 байт) містить повний вступ `using-v8storagekit`
   **і другу копію** «## Стан сховищ (kit session-check)» з тим самим текстом (рядки 135–143 файлу). Це вивід старого
   проєктного хука `.claude/hooks/session-start.ps1` (`.claude/settings.json` → `hooks.SessionStart`, `matcher:
   startup|clear|compact`), який перехід ще не прибрав. `kit check` (крок 3) назвав саме його: «Старий проєктний хук старту
   сесії … «Стан сховищ» з'явиться двічі».

**Висновок (умова: репо 1.4.0 з неприбраним проєктним хуком, сесія в корені, Windows Server 2022).** Блок хука плагіна —
«Стан сховищ» інлайн, без `<persisted-output>`, видно одразу: пункт виконано. Друга копія стану йде від старого шима, лежить
під `<persisted-output>` і з контексту не видна; передбачення `hook-shim` («двічі») підтвердилось, хоча агент бачить лише одну
копію. Вимір «рівно один раз» після прибирання шима — у наступній сесії (див. запис після кроку 5). Вміст стану — не сигнали,
а три відмови формату 1.4.0 з вказівкою на `upgrades.md` «1.4.0 → 1.6.0»: агент без зовнішніх знань бачить, куди йти. Зауваги:
- текст «неочікуваним кодом 1 (очікувалось 0 або 3) … НЕВІДОМИЙ … Зупинка» звучить як аварія, хоча причина — очікуваний
  незавершений перехід, і нижче вона названа точно; чи має session-check для «репо суперечливе» повертати окремий код — питання
  архітектору, не рішення тестера;
- блок плагіна сам вступу не несе — лише вказує завантажити скіл `using-v8storagekit`; це й зроблено першим кроком.

### 2026-11-20 — п.2. Процедура `upgrades.md` «1.4.0 → 1.6.0», кроки 1–8

Гілка переходу — `feature/kit-1.6.0` від `main` `4bae2d94b` (вибір власника).

**Крок 1.** Вже виконано власником: `claude plugin list` → `unica@unica` 0.16.0 (`unica-0.16-roots-cc800e0`),
`v8storagekit@smp-v8storagekit-016` 1.6.0 (`v8storagekit-1.6.0-44dfd9a`).

**Крок 2.** `check-environment.ps1` → EXIT 0; усі `[+]`, зокрема `unica 0.16 - 0.16.0` і `v8-runner 0.18 - 0.18.1`.
Зауважа: вивід кирилиці в Git Bash — кракозябри (кодова сторінка консолі), `kit check` у тому ж шелі — коректний UTF-8.

**Крок 3.** `kit check -RepoRoot .` → EXIT 1. Помилок 3: `infobase:` у `v8project.yaml`, немає `providers`, `infobase:` у
`v8project.local.yaml` (тексти — як у хуку п.1). Попереджень 3: `kitVersion` 1.4.0; `.githooks/pre-commit` відрізняється від
шаблону; старий проєктний хук (`.claude/settings.json` `hooks.SessionStart` + `.claude/hooks/session-start.ps1`).

**Крок 4.** `tehnokrat/v8project.yaml`: прибрано `builder: DESIGNER`, `execution_timeout: 3600000` (з коментарем «повна УНФ:
наповнення бази агента довше за 10 хв» — свідоме рішення), блок `infobase:` (`connection: 'File=build/ib'`, без `user`);
додано `providers` (designer ×3). `format`, `workPath`, `source-set` — без змін. `tehnokrat/v8project.local.yaml`:
`infobase:` → `infobases.origin.connection: 'Srvr=VSDEV;Ref=tehnokrat_unf_sydorenko_claude;'`, `user`/`password` не
писались (у старому блоці їх не було, вхід — автентифікацією ОС). Власнику повідомлено (за брифом архітектора, новіша
редакція п.4): ключ `execution_timeout` прибрано, довгі операції в Уніці 0.16 — справа Уніки й хоста; ключ не повертається.

**Крок 5.** З `.claude/settings.json` прибрано `hooks` (єдиний запис — `SessionStart` на `session-start.ps1`);
`git rm .claude/hooks/session-start.ps1`. `kit install-hooks -RepoRoot . -Apply` (з дозволу власника; різниця шаблону — лише
текст «dump/canon» → «dump чи pull Уніки») → «Готово. .githooks уже в індексі», EXIT 0.

**Крок 6.** Злиття дозволів JSON-парсером: записи Уніки 0.13 (`unica_project_map`, `unica_cf_info` … 33 шт.) прибрано,
перелік Уніки = шаблон (`unica_run` — у `allow`, `unica_apply` — у `ask`). Власних записів поза Унікою у споживача не було
— результат побайтово рівний шаблону (`s == t` → True).

**Крок 7.** `CLAUDE.md`: шапка й абзац споживача (зокрема 8.3.25 / `-DumpPlatform … -ForVersion N` — у 1.6.0 параметр
чинний, `sync.psm1`) — лишено; преамбула й розділи `##` — з шаблону, `<mainBranch>` → `main`. Розділів поза шаблоном у
споживача немає. Сім рядків споживача без відповідника в шаблоні показано власнику переліком (база через `infobase.*`,
кореневий `build/artifacts/`, `operation=build/make/test/syntax`, `kit build -Apply`, `operation=build` без `sourceSet`,
«`File=build/ib` — не секрет», хук `session-start.ps1`) — усі застарілі правила kit 1.4.0/Уніки 0.13; рішення власника —
прибрати всі. Процедура дала достатньо, щоб розкласти їх без знань поза текстом.

**Крок 8.** `kit check -RepoRoot .` → EXIT 0: «Помилок немає. Попереджень: 1» — лише `kitVersion` (знімає крок 10).
Попередження про поставку `base` немає.

### 2026-11-20 — п.3. Крок 9 для `base` (`truth: storage`, з поставкою) — лише `dryRun:true`

**Умова.** Після кроку 8; воркспейс Уніки `tehnokrat_unf/tehnokrat` (`unica.view {}` у корені сесії → «workspace is
uninitialized … no v8project.yaml», `available[0].workspaces: ["tehnokrat"]`); база агента — серверна, `infobases.origin`.

**Виклик 1.** `unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true,"workspace":"tehnokrat_unf/tehnokrat"}`

```
{"ok":true,"summary":"push planned overwriting the infobase with source set `base` without touching it yet; executing loads every set in full without checking the infobase generation, and changes made in the infobase since this working copy's last exchange are lost","data":{"op":"push","dryRun":true,"plan":{"full":false,"force":true,"generationProtection":false,"appliesDatabaseConfiguration":true,"steps":[{"mode":"full","sourceSet":"base"}],"targetStateKnownBeforeApply":false},"providerDispatched":false,"requiresPlatform":true},"warnings":[{"code":"infobase_overwritten","sourceSets":["base"],"message":"force:true overwrites the infobase: these sets are loaded in full without checking the infobase generation or this working copy's memory of it, and changes made in the infobase since the last exchange are lost"},{"code":"platform_line_written","message":"Unica added tools.platform.version: sources to v8project.local.yaml: the runner now runs on the platform line that writes the format of the sources; set tools.platform.version there to choose a platform yourself"}],"next":[{"tool":"unica.run","args":{"op":"push","args":{"force":true,"sourceSet":"base"},"dryRun":false},"reason":"execute with the current arguments"}]}
```

**Виклик 2.** `unica.run {"op":"pull","args":{"sourceSet":"base","force":true},"dryRun":true,"workspace":"tehnokrat_unf/tehnokrat"}`

```
{"ok":true,"summary":"pull planned a full export of source set `base`","data":{"op":"pull","dryRun":true,"plan":{"sourceSet":"base","extension":null,"mode":"full","plannedMode":"full","modeReason":null,"target":"cf/src","targetExists":true,"force":true,"replacesLocalSources":true,"localChanges":{"underGit":true,"files":0}},"providerDispatched":false,"requiresPlatform":true},"next":[{"tool":"unica.run","args":{"op":"pull","args":{"force":true,"sourceSet":"base"},"dryRun":false},"reason":"execute with the current arguments"}]}
```

**Висновок (умова: лише план, `providerDispatched:false`, платформу не піднято).** Відмови через правило `.gitignore`
`**/Ext/ParentConfigurations/` на рівні плану немає ні в `push`, ні в `pull`; `pull` бачить `localChanges.files: 0` під git.
Чи не відмовить виконання — не виміряно (план не доводить поведінку раннера при справжньому записі). Побічний ефект
`dryRun`: Уніка **записала** `tools: platform: version: sources` у `tehnokrat/v8project.local.yaml` (попередження
`platform_line_written`) — `dryRun` не повністю без змін; за `upgrades.md` ключ штатний. В плані `push` — `"full":false` поруч
із кроком `"mode":"full"` (поле `full` — аргумент виклику, не режим кроку; зауважа для читача). **СТОП** перед будь-яким
`dryRun:false` для `base` — рішення архітектора.

### 2026-11-20 — п.4. Крок 9 для `ТК_Адаптация` — `dryRun:true`

**Виклик.** `unica.run {"op":"push","args":{"sourceSet":"ТК_Адаптация","force":true},"dryRun":true,"workspace":"tehnokrat_unf/tehnokrat"}`

```
{"ok":true,"summary":"push planned overwriting the infobase with source set `ТК_Адаптация` without touching it yet; executing loads every set in full without checking the infobase generation, and changes made in the infobase since this working copy's last exchange are lost","data":{"op":"push","dryRun":true,"plan":{"full":false,"force":true,"generationProtection":false,"appliesDatabaseConfiguration":true,"steps":[{"mode":"full","sourceSet":"ТК_Адаптация"}],"targetStateKnownBeforeApply":false},"providerDispatched":false,"requiresPlatform":true},"warnings":[{"code":"infobase_overwritten","sourceSets":["ТК_Адаптация"],"message":"force:true overwrites the infobase: these sets are loaded in full without checking the infobase generation or this working copy's memory of it, and changes made in the infobase since the last exchange are lost"}],"next":[{"tool":"unica.run","args":{"op":"push","args":{"force":true,"sourceSet":"ТК_Адаптация"},"dryRun":false},"reason":"execute with the current arguments"}]}
```

**Висновок (план).** Повне завантаження лише набору розширення, `infobase_overwritten` — як очікувано. Справжній запуск — після
слова власника.

**Плагін.** Між кроком 8 і справжнім кроком 9 контролер перевстановив 1.6.0 на знімок `f610e73`
(`claude plugin list` о 14:13 → `v8storagekit-1.6.0-ca7ca74`). Кроки 1–8 і всі `dryRun` вище виконано на `44dfd9a`, справжні
кроки 9 — на новому знімку. Ця сесія стартувала з хуком `44dfd9a`.

### 2026-11-20 — п.4. Крок 9 для `ТК_Адаптация` — справжній `push force` (з дозволу власника) — ВІДМОВА платформи

**Виклик** (14:13). `unica.run {"op":"push","args":{"sourceSet":"ТК_Адаптация","force":true},"dryRun":false,"workspace":"tehnokrat_unf/tehnokrat"}`

```
Task failed: {"summary":"load failed for source-set 'ТК_Адаптация' with exit code 1; platform log: Несоответствие версий клиента и сервера 1С:Предприятия\r\nРазличаются версии клиента и сервера (8.3.27.2342 - 8.3.27.1644), клиентское приложение: Конфигуратор; platform log path: R:\github\tehnokrat_unf\tehnokrat\build\logs\platform\build-00-ТК_Адаптация-load.log","diagnostics":[{"code":"provider_unavailable","outcome":"needsHuman","message":"load failed for source-set 'ТК_Адаптация' with exit code 1; platform log: … (те саме)"}]}
```

Питання Уніки «Перезаписать базу…» власнику **не прийшло** — відмова сталась раніше, на підключенні Конфігуратора. Лог
платформи (273 байти) — лише ці два рядки; підрядків ліцензії немає. На машині встановлено 8.3.27.1644 і 8.3.27.2342;
`check-environment` (крок 2) знайшов `8.3.27.1644`; кластер `VSDEV` — 8.3.27.1644.

**Висновок (умова: серверна база агента, кластер 8.3.27.1644, у `v8project.local.yaml` —
`tools.platform.version: sources`, який Уніка дописала сама на `dryRun` п.3).** Раннер підняв найновіший клієнт рядка
8.3.27 (2342), а сервер — 1644: запис у серверну базу агента неможливий. [гіп] Причина — вибір платформи за `sources`
(«platform line that writes the format of the sources») без урахування версії кластера; не виміряно, що з іншим
значенням ключа запуск пройде. Тим самим шляхом піде й `pull base force` з рішення `d66a680` — його не запускаю. **СТОП**,
без повтору; ключ `tools.platform.version` не правлю (вибір платформи — рішення людини/архітектора).

### 2026-11-20 — п.4 (продовження). Пін платформи кластера і повтор `push` розширення

Рішення архітектора — спека `b75138e`, §4.2 п.25. За дозволом власника в `tehnokrat/v8project.local.yaml` блок `tools:`
замінено: `version: sources` → `version: "8.3.27.1644"` + `path: "C:\Program Files\1cv8\8.3.27.1644\bin"`. Інші рядки
не змінено.

**Перевірка (лише читання).** З теки воркспейсу виконано
`…/unica/0.16.0/bin/win-x64/v8-runner-windows-x86_64/v8-runner.exe platforms --json-message`. Результат: `ok: true`,
`data.selected.designer` = `{"path":"C:\Program Files\1cv8\8.3.27.1644\bin\1cv8.exe","version":"8.3.27.1644","source":"explicit","chosen_by":"newest"}`;
`thin_client` і `ibcmd` — теж 1644, `explicit`.

**`dryRun`.** Відповідь та сама, що в першому записі п.4: `ok`, `infobase_overwritten`. `platform_line_written` цього разу
немає: Уніка явний пін не переписує.

**Справжній запуск** (з дозволу власника, 14:18:45 → результат о 14:19:13, ≈30 с).
`unica.run {"op":"push","args":{"sourceSet":"ТК_Адаптация","force":true},"dryRun":false,"workspace":"tehnokrat_unf/tehnokrat"}`

```
{"ok":true,"summary":"push overwrote the infobase with source set `ТК_Адаптация`: every set was loaded in full without checking the infobase generation, and changes made in the infobase since this working copy's last exchange are lost; the infobase state is attested by the provider","data":{"op":"push","dryRun":false,"providerDispatched":true,"full":false,"force":true,"generationProtection":false,"appliesDatabaseConfiguration":true,"steps":[{"mode":"full","sourceSet":"ТК_Адаптация"}],"targetStateAttestedBy":"provider"},"changed":[{"infobase":true,"kind":"configuration","sourceSet":"ТК_Адаптация","mode":"full"}],"warnings":[{"code":"infobase_overwritten","sourceSets":["ТК_Адаптация"],"message":"force:true overwrote the infobase: …"}]}
```

Питання Уніки «Перезаписать базу «origin»…» власник **отримав і погодився** (його слова). У транскрипті агента цього
питання не видно — його бачить лише людина. Логи платформи: `…-load.log` і `…-update.log` по 3 байти (BOM),
`…-generation.log` — 45 байт; підрядків ліцензії немає.

**Висновок (умова: серверна база, пін 1644).** Крок 9 для розширення виконано. Модель «питання — людині, згода — від
людини» спрацювала.

### 2026-11-20 — п.3 (продовження). `base` за рішенням `d66a680`: рецепт поставки + `pull force`

1. VS Code git-розширення й Pylance для робочої області вимкнув власник (його відповідь).
2. 14:20:19, з дозволу власника: `rm -rf tehnokrat/cf/src/Ext/ParentConfigurations`. Вміст до видалення:
   `BASSmallBusiness.cf` (497464911 байт, 2026-10-05) і `.kit-bin-sha1` (`3e70dadb5dbd70c04e526b7c627ebec542ccc1d9`).
   `ParentConfigurations.bin` (2699898 байт, під git) лишився.
3. `pull` — справжній запуск без повторного `dryRun`. Його план з тими самими аргументами записано вище, у першому записі
   п.3.
   `unica.run {"op":"pull","args":{"sourceSet":"base","force":true},"dryRun":false,"workspace":"tehnokrat_unf/tehnokrat"}`.
   Тривалість: старт ≈14:20:30, у `cf/src/Configuration.xml` mtime 14:21:38, нотифікація до 14:22:02 — **≈1,5 хв** на
   повне вивантаження УНФ із серверної бази.
   ```
   {"ok":true,"summary":"pull exported source set `base` into `cf/src` in full mode","data":{"op":"pull","dryRun":false,"sourceSet":"base","extension":null,"mode":"full","performedMode":"full","modeReason":null,"target":"cf/src","state":"updated","providerDispatched":true},"changed":[{"path":"cf/src","kind":"updated"}]}
   ```
   `os error 5` не було. Логи: `dump-base-full.log` — 3 байти, `dump-base-generation.log` — `c2be45f7fd656e46b56f22fc5058392e00000000`;
   підрядків ліцензії немає.
4. **Вимір поставки після `pull`.** Тека `Ext/ParentConfigurations/` створена знову (14:20). У ній `BASSmallBusiness.cf`
   (497464911 байт — розмір як до видалення; sha1 нового `92c064265211a3f78a4f75d0c4beca25d5d22da2`, sha1 старого не
   знімався). **`.kit-bin-sha1` немає.** Через те, що теку перед `pull` видалено, вимір не розрізняє «pull стирає позначку»
   і «позначки не було, бо видалено теку». Цей запуск тезу [гіп] п.18 не перевіряє, лише показує, що `pull` позначку не
   відновлює. `.cf` з'явився.
   Файлів у `cf/src`, новіших за лог `push` розширення, — 22792 із 22793. Не переписано лише `ConfigDumpInfo.xml`
   (mtime 2026-10-05).
5. `kit supply-marker -RepoRoot . -Workspace tehnokrat -Source base` (знімок `ca7ca74`) → «base: буде записано позначку
   .kit-bin-sha1 без вивантаження. Для виконання додайте -Apply.», EXIT 0. З `-Apply` (дозвіл власника — разом із
   пп.2–4) → «base: позначку .kit-bin-sha1 записано (3e70dadb5dbd70c04e526b7c627ebec542ccc1d9); дерево не
   переписувалось.», EXIT 0. Позначка дорівнює sha1 `ParentConfigurations.bin` і значенню до видалення.
6. `git status --porcelain -- tehnokrat/cf/src` → **порожньо** (0 рядків). Крок завершено: 22792 файли, переписані платформою
   з серверної бази, побайтово рівні дереву git на `main` `4bae2d94b`.

**Висновок (умова: серверна база агента 8.3.27.1644, пін платформи, база після `push` розширення; основу ніхто не
перезавантажував).** Рецепт `d66a680` пройдено без відмов. Правило `.gitignore` `**/Ext/ParentConfigurations/` не завадило
ні `pull`, ні `supply-marker`. Байти `pull` 0.16 = байти дзеркала: тезу §4.2 п.12 на цій серверній базі виміряно — різниці
0. `kit check` після кроку → помилок немає, одне попередження (`kitVersion`).

### 2026-11-20 — крок 10

`kitVersion: 1.6.0` у `v8storagekit.yaml`; `kit check` (знімок `ca7ca74`) → «Помилок немає. Попереджень: 0.».
`git diff -- CLAUDE.md` показано власнику. Коміт з його погодження: `f3bd75bc7` на `feature/kit-1.6.0`, 6 шляхів явним
переліком (`v8storagekit.yaml`, `tehnokrat/v8project.yaml`, `.claude/settings.json`, `CLAUDE.md`,
`.claude/hooks/session-start.ps1` — видалення, `.githooks/pre-commit`). Не пушилось.

Зауважа до процедури: `git add <перелік>` з уже видаленим (`git rm`) шляхом дає «fatal: pathspec
'.claude/hooks/session-start.ps1' did not match any files». Видалений шлях іде лише в `commit --only -- …`, не в `add`.
Крок 10 цього не каже.

**Лишилось:** вимір «Стан сховищ рівно один раз, інлайн, без `<persisted-output>`» у першому повідомленні нової сесії в
корені `tehnokrat_unf`. Підсумковий знімок для виміру — `33c6fe7` (`~/.claude/local-marketplaces/v8storagekit-1.6.0-33c6fe7`, за архітектором;
до нього діяли `f610e73` → `ca7ca74`).
Після виміру — підсумок пілоту тут, і пілот закрито.

### 2026-11-20 — п.1 (повтор). Хук старту після переходу, знімок `33c6fe7`

**Умова.** Нова сесія Claude Code, cwd `R:\github\tehnokrat_unf`, гілка `feature/kit-1.6.0` чиста на `f3bd75bc7` (перехід
1.4.0 → 1.6.0 закомічено: проєктного хука немає — `.claude/` містить лише `settings.json`, у ньому ключа `hooks` немає).
Windows Server 2022.

**Знімок плагіна.** `claude plugin list`:

```
  ❯ v8storagekit@smp-v8storagekit-016
    Version: 1.6.0
    Read from: C:\Users\VSydorenko\.claude\local-marketplaces\v8storagekit-1.6.0-33c6fe7\v8storagekit
    Scope: user
    Status: ✔ enabled
```

Ім'я теки — не доказ, тому вміст звірено з комітом: `git show 33c6fe7:<шлях> | cmp - <знімок>/<шлях>` — рівні
`hooks/hooks.json`, `hooks/session-start.ps1`, `tools/kit.ps1`; файлів у знімку 202, у дереві `33c6fe7` — 202.

**Сирий вивід.** Контекст першого повідомлення сесії містить рівно один блок `<v8storagekit>` (другий блок старту —
`superpowers`, чужий), інлайн, без `<persisted-output>` і без посилань на `tool-results/`:

```
<v8storagekit>
## Стан сховищ (kit session-check)

session-check — client Tehnokrat
- base: дзеркало синхронне зі сховищем, main містить усе.
- ТК_Адаптация: дзеркало синхронне зі сховищем, main містить усе.

Репозиторій під kit. Правила контуру — скіл `v8storagekit:using-v8storagekit`: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем.
</v8storagekit>
```

Заголовок «## Стан сховищ» у контексті — один раз.

**Висновок (умова: репо після переходу без проєктного хука, сесія в корені, знімок `33c6fe7`, Windows Server 2022).**
Пункт виконано: «Стан сховищ» рівно один раз, інлайн, без `<persisted-output>`. Стан — сигнали, а не відмови формату: обидва
дзеркала синхронні, `main` містить усе. Межа виміру: спостерігач — сам агент, що читає власний контекст; здатність цього
спостерігача побачити дубль і `<persisted-output>` показав перший запис п.1 (там обидва було видно). Крок `compact`/`clear`
не вимірювався.

## Підсумок пілоту (за записами журналу)

Перехід `tehnokrat_unf` 1.4.0 → 1.6.0 під Unica 0.16 пройдено повністю: кроки 1–10 `upgrades.md`, крок 9 для обох джерел
справжнім запуском, `kit check` → 0 помилок / 0 попереджень, коміт `f3bd75bc7` на `feature/kit-1.6.0` (не пушився, PR немає),
хук старту — один блок стану. Процедура дала достатньо, щоб пройти її без знань поза текстом, з винятками нижче.

**Підтверджено вимірами:**
- хук плагіна: стан інлайн, без `<persisted-output>`; до прибирання шима — дубль під `<persisted-output>` (як передбачав
  `kit check`), після — рівно один раз (п.1, п.1-повтор);
- відмови формату 1.4.0 у хуку й `kit check` ведуть на `upgrades.md` «1.4.0 → 1.6.0» (п.1, п.2);
- `push force` розширення на серверну базу проходить, питання про перезапис отримує людина, не агент (п.4);
- рецепт `d66a680` для `base` з поставкою: `pull force` + `kit supply-marker` — байти `pull` 0.16 рівні дереву git (різниця 0
  на 22792 файлах), `.gitignore` `**/Ext/ParentConfigurations/` не заважає (п.3);
- зауважу кроку 10 про видалений шлях у `git add` закрито в `33c6fe7`.

**Дефекти й зауваги, що лишаються відкритими:**
1. Вибір платформи `tools.platform.version: sources` (дописує сама Уніка на `dryRun`) бере найновіший клієнт рядка 8.3.27
   без урахування версії кластера → «Различаются версии клиента и сервера (8.3.27.2342 - 8.3.27.1644)» (п.4). Обійдено явним
   піном (спека `b75138e` §4.2 п.25); причина — [гіп], не виміряно.
2. `dryRun` не без змін: записує `tools.platform.version: sources` у `v8project.local.yaml` (п.3).
3. Текст session-check «неочікуваним кодом 1 … НЕВІДОМИЙ … Зупинка» для очікуваного незавершеного переходу звучить як аварія;
   чи потрібен окремий код для «репо суперечливе» — питання архітектору (п.1).
4. Теза §4.2 п.18 (`pull` стирає `.kit-bin-sha1`) цим пілотом не перевірена: теку видалено до `pull` (п.3).
5. Дрібне: у плані `push` поле `"full":false` поруч із кроком `"mode":"full"` збиває читача (п.3); `check-environment.ps1` у
   Git Bash друкує кирилицю кракозябрами (п.2).

Пілот на `tehnokrat_unf` закрито.
