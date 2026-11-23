# План: Онбординг — звірка з цільовим станом (B1–B3)

## 1. Шапка

- **Статус:** чернетка на прийманні. Приймає архітектор kit (сесія `unica-016-adaptation`). Автор і виконавець —
  сесія `smp-v8storagekit-1f`.
- **Спека:** `docs/superpowers/specs/2026-11-23-onboarding-target-state-design.md`, коміт `1f85bb1`. Issue: спека #99,
  B1 #96, B2 #97, B3 #98.
- **Якорі після P0:** задачі B2 і B3 спираються на малу задачу архітектора — гілку `fix/prgate-storage-frontmatter`
  (межі `pr-gate`, frontmatter #95, правило тек для тимчасового, запис `CHANGELOG.md` 1.6.13 і розділ
  `1.6.12 → 1.6.13` в `skills/onboarding/references/upgrades.md`). Перед T3 — `git merge origin/feature/onboarding-target-state` у робочу копію.
- **Робоча копія:** режим `worktree`, `.worktrees/onboarding-target-state`, гілка `feature/onboarding-target-state`.
  Спільного рантайму (бази агента, стенду) немає. Імплементатори — по одному за раз (одна робоча копія).
  Тимчасові файли — `.agents/out/` головного checkout.
- **Коміти:** контролер, точково (`git add <перелік>` + `git commit --only`). Субагенти лише стейджать.
- **Заборони:** репозиторії-споживачі не чіпати; сховища — лише читання; `-Apply` не запускати.

## 2. Мета / Архітектура / Спека

**Мета.** Онбординг проєкту будь-якої версії бачить усі відхилення від цільового стану kit рядками з дією, а
текст скілу веде через них без обходів (спека §1, ADR-0016).

**Архітектура.** Контур сховища: `check` отримує власний режим префлайту, у якому `kitVersion` — знахідка, а не
зупинка (§5.1). Процес: `kit-scan` розпізнає проєкт, підключений раніше, і шукає застарілі імена з одного файлу
даних; `kit-setup` зливає `.claude/settings.json` з `templates/settings.json` як із цільовим станом і пише
`kit.version` окремим явним викликом (§5.2, §5.3). Текст онбордингу спирається на вивід цих команд (§5.4).

**Спека:** §3 (блоки), §4 (інтерфейси), §5.1–§5.4 (деталі), §6 (безпека).

## 3. Глобальні обмеження

- Поведінку змінюємо в PowerShell **до** порту на Rust (ADR-0014): `rust/` і `bin/kit.exe` не змінюються.
- Команди процесу не імпортують модулів сховища (ADR-0002, `tools/lib/module-order.txt`): `kit-scan` і
  `kit-setup` не читають YAML модулем `Yaml.psm1`.
- Версію не піднімати: блок дописує пункти в наявний запис `CHANGELOG.md` 1.6.13 і в розділ `1.6.12 → 1.6.13`
  `skills/onboarding/references/upgrades.md` (бриф архітектора).
- Наявні тести лишаються зеленими; тест, що фіксує стару поведінку, змінюється в тій самій задачі, що й
  поведінка. Нові тести — за зразком `Check.*.Tests.ps1` (підпроцес диспетчера на `New-KitFakeRepo`, текст і
  «наступний крок не відбувся»), кожен з контролем, що вміє впасти. Перелік тестів у done-when — верхня межа.
- Прогін у задачі — `-Only <змінені файли тестів і викликачі>`; `-Full` — лише T7.

## 4. Рішення

| # | Рішення | Вплив на спеку |
| --- | --- | --- |
| D1 | `Invoke-KitPreflight` отримує режим `-Mode Strict\|Lenient\|Check` замість `-Lenient`; диспетчер дає `Check` лише команді `check`, `Lenient` — `session-check`. `Read-KitManifest -AllowKitVersion` не кидає на `kitVersion` і повертає поле `KitVersion`; префлайт у режимі `Check` додає знахідку `error` з тегом `kit-version` і розбирає решту. Без перемикача `Read-KitManifest` кидає, як тепер. | немає |
| D2 | `session-check` лишається в режимі `Lenient`: на `kitVersion` маніфест не читається, `check` зупиняється на знахідці `manifest`, `session-check` дає код 1. Поведінка не змінюється; тест (2) її фіксує. | немає |
| D3 | Файл застарілих імен — `tools/assets/obsolete-names.json`. Формат: `skills` (стара назва без префікса → нова), `commands` (старий виклик → заміна; `tools/kit.ps1` → `kit`, `kit build` → `unica.run` `"op":"make"`), `unicaTools` (повні імена інструментів, заміни немає — «прибрати»). Читає його одна функція `Get-KitObsoleteNames` у `KitVersion.psm1` (розділ процесу). Перелік `unicaTools` нижче — вимір автора плану. | немає (§5.2 віддає місце й формат плану) |
| D4 | `kit-scan` читає `kitVersion` з `v8storagekit.yaml` рядковим виразом по ключу верхнього рівня, без YAML-модуля (обмеження ADR-0002). Значення не `x.y.z` — стан `invalid` з приміткою. | немає |
| D5 | Нове значення стану `Kit version` у `-Json`: `connected-before`. Умова: у маніфесті є `kitVersion`, а профілю немає **або** профіль без `kit.version`. Профіль з `kit.version` має пріоритет над маніфестом. | немає |
| D6 | **На затвердження архітектора.** Профіль без `kit.version` (тепер це нормальний стан до останнього коміту PR) і без `kitVersion` у маніфесті: `kit-scan` дає стан `no-version` — рядок «`kit.version` немає — запише `kit-setup -SetVersion` останнім комітом PR» **без** переліку кроків від 0.1.0. Причина: інакше новий проєкт отримує в звіті чеклісти всіх версій журналу. Профілі епохи до версій (0.1.0) правило «без сумісності зі старими версіями» не підтримує, їхні відхилення показують `check` і `kit-scan`. | §5.2 «До того `kit-scan` показує розрив версії» — уточнити, що розрив без переліку кроків |
| D7 | Прапорець запису версії — `kit-setup -SetVersion`. Окремий режим: змінює лише `kit.version` у наявному профілі (решта файлу без змін), профілю немає — код 1 з дією «спершу `kit-setup`»; разом з іншими прапорцями, крім `-DryRun`, — код 2. | немає (§5.2 віддає ім'я плану) |
| D8 | Єдине джерело цільових правил — `templates/settings.json` плагіна (`Get-KitPluginRoot`); перелік `$script:KitCommands` у `kit-setup.psm1` зникає. `Templates.Tests.ps1` тоді звіряє шаблон із результатом `kit-setup` на порожньому репозиторії. | немає |
| D9 | **На затвердження архітектора.** Правила `mcp__plugin_unica_unica__*` шаблону `kit-setup` додає лише в репозиторії 1С (`Test-SetupIs1C`); решту правил шаблону — завжди. Причина: проєкт лише з процесом не має Уніки, а дозвіл на її мутуючий `unica_run` без потреби розширює права. Пункти (б) і (в) §5.2 діють завжди. | §5.2 (а): «правила шаблону, яких немає, — додати; правила Уніки — лише в репозиторії 1С» |
| D10 | Форма правил `ask` у шаблоні — `Bash(<команда>:*)` і `PowerShell(<команда>:*)`, як решта шаблону й перевірки `Templates.Tests.ps1`. | §5.3 пише `Bash(… *)` — привести до `:*` |
| D11 | Код «є що робити» `session-check` — **4**, не 3 (`tools/commands/session-check.psm1`, обчислення `$exit`; контракт `CLAUDE.md`). Текст B3 каже про код 4. | §5.4, пункт #65 — «код 4» |
| D12 | Шим хука: `check` уже знаходить старий запис `hooks.SessionStart` (`Test-KitLegacySessionHook`); `kit-setup` (г) прибирає лише той запис, команда якого містить `.claude/hooks/session-start.ps1`; сам файл шима не видаляє (його `git rm` — крок тексту `skills/onboarding/references/upgrades.md`). | немає |

**Застарілі інструменти Уніки (D3, вимір 2026-11-23).** Усі імена `mcp__plugin_unica_unica__unica_*` з історії
`templates/settings.json` (`git log -- templates/settings.json`, 7 комітів) мінус інструменти установленої Уніки
(`skills/1c-unica/scripts/unica-call.ps1` з `--tools`: `apply`, `check`, `diff`, `docs`, `resolve`, `run`, `search`,
`task.cancel`, `task.get`, `task.result`, `view`). Залишок — 34 суфікси після `unica_`:
`cf_info cf_validate cfe_diff cfe_validate code_definition code_diagnostics code_graph code_outline code_search
dcs_info dcs_validate documentation_get documentation_search form_info form_validate interface_validate meta_info
mxl_decompile mxl_info mxl_validate project_map project_status role_info role_validate source_children source_locate
source_read source_resolve source_resources standards_explain standards_search subsystem_info subsystem_validate
xdto_info`.

## 5. Інтерфейси

| Інтерфейс | Дає | Бере | Контракт |
| --- | --- | --- | --- |
| знахідка `check` `kit-version` | T1 | T6 (текст) | `error`; дія — «видалити рядок `kitVersion:` з `v8storagekit.yaml`; версію проєкту тримає `.agents/kit.profile.json`»; решта перевірок триває; код `check` — 1 |
| режим префлайту `Check` | T1 | — | лише для `check`; для решти команд `kitVersion` — зупинка з тією самою дією |
| `templates/v8project.yaml` | T2 | T6, споживачі | форма воркспейсу Уніки 0.16; кожне правило шаблону перевіряє `check` |
| дія `warn undeclared-source` | T2 | T6 | називає рядок `.gitattributes` (`<шлях>/** -text`) для `git`/`storage` і рядок `.gitignore` (`<шлях>/**`) для `vendor` |
| `tools/assets/obsolete-names.json` + `Get-KitObsoleteNames` | T3 | T4 (`unicaTools`), T6 (`skills/onboarding/references/upgrades.md` посилається) | D3 |
| стан `connected-before` / `no-version` у `Kit version` `kit-scan` (текст і `-Json`) | T3 | T6 | D5, D6; для `connected-before` — `kit check -RepoRoot .` і чеклісти версій, новіших за версію з маніфесту |
| розділ застарілих імен `kit-scan` | T3 | T6 | рядок на збіг: файл, стара назва, заміна |
| злиття `settings.json` у `kit-setup` | T4 | T6 | §5.2 (а)–(г), D8, D9 |
| цільовий `templates/settings.json` | T4 | T6, споживачі | §5.3, D10 |
| `kit-setup -SetVersion`; версія плагіна у виводі `kit-setup` | T5 | T6 | D7 |

## 6. Інваріанти безпеки

| Інваріант | Перевірка, що ловить дефект |
| --- | --- |
| Злиття ніколи не прибирає правило з `deny` і не прибирає й не переносить правило з `ask` проєкту | тест (3) B2: `deny` і `git push` в `ask` після злиття ті самі. Мутація «прибирати застарілі з усіх трьох списків» чи «переносити `ask` у `allow`» — червоне |
| Правило, яке шаблон тримає в `ask`, у `allow` не потрапляє; `unica_apply` з `allow` переходить у `ask` | тест (3): `unica_apply` в `allow` проєкту → після злиття лише в `ask`. Мутація «додати відсутнє в `allow`, не прибравши звідти» — червоне |
| Прибирається лише **точний** збіг із застарілим іменем | тест (3): власне правило проєкту лишається. Мутація «збіг за префіксом `mcp__plugin_unica`» прибрала б і чинні правила — червоне на чинних `unica_view` проєкту |
| Без запиту — лише `pr-gate open/ready/land`; широкого `pr-gate:*` у шаблоні немає; `git push`, `gh pr create`, `gh pr merge`, `gh release` — в `ask` | тест (7) B2 (зміст шаблону); мутація «`Bash(pr-gate:*)` у шаблоні» чи «`gh pr merge` прибрано з `ask`» — червоне |
| Невалідний JSON на вході — зупинка без запису; запис атомарний з розбором результату до заміни | тест (4): файл байт-у-байт той самий, код не 0. Мутація «писати до розбору» — червоне |
| `-NoPermissions` вимикає все злиття, включно з прибиранням | один рядок у тесті (3): з `-NoPermissions` diff `settings.json` порожній |
| `check` не дає зеленого на маніфесті з `kitVersion` | тест (1) B1: код 1 і знахідка `kit-version`. Мутація «режим `Check` додає знахідку `warn`» — червоне |
| Інші команди на `kitVersion` не працюють | тест (2) B1: `sync` і `session-check` зупиняються, наступного кроку немає (дзеркала `storage/*` не створено) |

## 7. Частини з власним done-when

Немає окремих частин: B1, B2, B3 приймаються разом одним PR архітектора; межі задач — нижче.

## 8. Задачі

**T0 — звірка якорів і поправки до спеки.** Файли: спека, план. Звірити якорі спеки з кодом на HEAD гілки
(`doc anchors` спеки й плану); внести в спеку поправки D6, D9, D10, D11 після затвердження архітектором. Done
when: `doc anchors` обох файлів без зламаних; поправки закомічено одним комітом зі згадкою D-номерів. Залежність:
приймання плану. Перевірка: голий `Run-Tests.ps1` (тести `Docs`).

**T1 — `kitVersion` у режимі `check` (B1, §5.1).** Файли: `tools/lib/Manifest.psm1`, `tools/lib/Preflight.psm1`,
`tools/kit.ps1`, тести `Check.Manifest.Tests.ps1`, `Manifest.Tests.ps1`. Done when: тест (1) — маніфест з
`kitVersion` і блоком `infobase:` у `v8project.yaml` → `check` друкує знахідки `kit-version` і `workspace`, код 1;
тест (2) — той самий репозиторій → `sync` і `session-check` зупиняються з дією «видалити `kitVersion`», дзеркала
не створено; наявний тест `Read-KitManifest` на `kitVersion` лишається (без перемикача — виняток). Залежність: T0.
Перевірка: `-Only Check.Manifest,Manifest,SessionCheck.Findings` + файли, що кличуть `Invoke-KitPreflight`
(`grep -rln Invoke-KitPreflight tools/tests`).

**T2 — шаблон `v8project.yaml` і дія `undeclared-source` (B1, §5.1).** Файли: `templates/v8project.yaml` (новий),
`templates/README.md`, `tools/commands/check.psm1`, тест у `Check.GitPolicy.Tests.ps1`. Done when: тест (3) —
незаявлений source-set → `warn undeclared-source`, код 0, дія називає рядок `<шлях>/** -text` для `git`/`storage` і
`<шлях>/**` у `.gitignore` для `vendor`; контроль — заявлений set без рядка `-text` дає `error` з `<шлях>/** -text`
(наявний тест, якщо він є, не дублювати); `kit check` на синтетичному репозиторії з копією шаблону не дає знахідок
`workspace` (ручний прогін, вивід — у звіті задачі, нового тесту немає). Залежність: T1 (один файл
`check.psm1` — послідовно). Перевірка: `-Only Check.GitPolicy,Templates`.

**T3 — `kit-scan`: проєкт, підключений раніше, і застарілі імена (B2, §5.2).** Старт — після злиття P0 у гілку
(`git merge origin/feature/onboarding-target-state`). Файли: `tools/assets/obsolete-names.json` (новий),
`tools/lib/KitVersion.psm1`, `tools/commands/kit-scan.psm1`, `KitScan.Tests.ps1`. Done when: тест (1) — маніфест
`kitVersion: 1.4.0` без профілю → «підключено раніше (1.4.0)», `kit check -RepoRoot .` і чеклісти новіших версій;
у `-Json` — `connected-before`; тест (2) — `CLAUDE.md` з `v8storagekit:reconcile`, `/v8storagekit:sync` і
`tools/kit.ps1` → рядок на кожне з заміною; контроль — `kit sync`, голе `dump` і чинне
`v8storagekit:storage-sync` рядка не дають; стан `no-version` за D6 (якщо D6 затверджено). Пошук — цілі токени без
урахування регістру, у файлах §5.2; гітігноровані робочі теки `.agents/` (`out`, `sdd`, `briefs`, `private.dir`) і
корінь worktree пропускаються. Залежність: T0, P0. Перевірка: `-Only KitScan` + викликачі `Get-KitProjectVersion`.

**T4 — злиття `settings.json` і цільовий шаблон (B2, §5.2–§5.3).** Файли: `tools/commands/kit-setup.psm1`,
`templates/settings.json`, `templates/README.md` (рядок `settings.json`), `KitSetup.Tests.ps1`, `Templates.Tests.ps1`.
Done when: тест (3) — вхід за §3 рядком B2 → `kit-setup -DryRun` показує прибрати застаріле, перенести
`unica_apply` в `ask`, додати `pr-gate open/ready/land`, прибрати лише запис шима; `git push` в `ask`, власне
правило, `deny` і власний хук без змін; з `-NoPermissions` diff `settings.json` порожній; тест (4) — невалідний
JSON → код не 0, файл байт-у-байт той самий; тест (7) — зміст шаблону за §5.3 і D10, широкого `pr-gate:*` немає;
перевірка `Templates.Tests.ps1` «шаблон ↔ kit-setup» оновлена за D8 і червоніє, якщо шаблон і результат
`kit-setup` розходяться; довідка команди (`$script:Usage`, шапка) і текст попередження про широке `pr-gate:*`
переписані за §5.3. Залежність: T3 (`Get-KitObsoleteNames`). Перевірка: `-Only KitSetup,Templates,PrGate`.

**T5 — профіль: `kit.version` останнім (B2, §5.2).** Файли: `tools/commands/kit-setup.psm1`, `KitSetup.Tests.ps1`.
Done when: тест (5) — новий профіль без `kit.version`; `kit-scan` показує розрив (стан за D6); `kit-setup
-SetVersion` записує версію плагіна й більше нічого не змінює у файлі; тест (6) — профіль без знайдених
`docs.specs`/`docs.plans` не має для них ні поля, ні TODO, `pr.base`/`pr.mergeMethod` — TODO, як тепер; вивід
`kit-setup` містить версію плагіна. Залежність: T4 (той самий файл). Перевірка: `-Only KitSetup,KitScan`.

**T6 — текст онбордингу (B3, §5.4).** Файли: `skills/onboarding/SKILL.md`, `skills/onboarding/references/upgrades.md`,
`skills/onboarding/references/process.md`, `skills/onboarding/references/storage.md`, `templates/CLAUDE.md`,
`docs/unica-contract.md`, `skills/storage-sync/SKILL.md`, `skills/storage-rules/SKILL.md`,
`skills/infobase-agent/SKILL.md`, `skills/infobase-dump/SKILL.md`; згадки `kit-setup` у `README.md`. Done when:
рецепт кроку 9 (розділ `1.4.0 → 1.6.0`) без безумовного видалення `Ext/ParentConfigurations/` і без безумовного
закриття VS Code, з розвилкою для людини за класами змін; таблиця «Довідка по версіях» — рядок на кожен розділ
версії; розділ із замінами імен посилається на `tools/assets/obsolete-names.json`, а не копіює; порядок для
проєкту, підключеного раніше, — `kit-scan` → `kit check` → відхилення обох → кроки Уніки → `kit-setup -SetVersion`
останнім комітом; повторний скан, коли версія плагіна у звіті й на застосуванні різна; `templates/CLAUDE.md` —
межа «Межі» і розділ «Дозволи» за ADR-0017 (через `pr-gate` без запиту; голі `git push`/`gh pr` — з запитом);
дотичні тексти §5.4 (кириличні шляхи, код 4 за D11, тривалість реплею як умова виміру, рядки «Трекінг в
апстрімі» #63); старі формулювання прибрано пошуком по всіх документах (`grep -rn` по `skills/ templates/ docs/
README.md`). Залежність: T2, T5. Перевірка: голий `Run-Tests.ps1` (тести `Docs`: `Skills`, `KitScan`, `Templates`).

**T7 — журнал і фінал блоку.** Файли: `CHANGELOG.md` (запис 1.6.13), `skills/onboarding/references/upgrades.md`
(розділ `1.6.12 → 1.6.13`). Done when: запис 1.6.13 має пункти B1–B3 і чекліст для проєкту (прогнати
`kit-scan`, `kit check`, `kit-setup -DryRun` → застосувати; `kit-setup -SetVersion` останнім комітом); `-Full`
зелений; хеш верхівки передано архітектору. Залежність: T6. Перевірка: `-Full`.

## 9. Задача 0

Див. T0 у розділі 8: якорі спеки й плану; поправки D6, D9, D10, D11 до спеки — одним комітом після затвердження.

## 10. Задачі власника

Немає: міграцію споживачів (зокрема MamHub) власник робить сам; PR у `main` відкриває й зливає архітектор.

## 11. Підсумок аудиту

Буде дописано після раунду 1.
