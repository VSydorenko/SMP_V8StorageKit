# План: Онбординг — звірка з цільовим станом (B1–B3)

## 1. Шапка

- **Статус:** чернетка на прийманні. Приймає архітектор kit (сесія `unica-016-adaptation`). Автор і виконавець —
  сесія `smp-v8storagekit-1f`.
- **Спека:** `docs/superpowers/specs/2026-11-23-onboarding-target-state-design.md`, коміт `1f85bb1`. Issue: спека #99,
  B1 #96, B2 #97, B3 #98.
- **Якорі після P0:** мала задача архітектора злита в гілку (PR #100, `3b2ae90`) і влита в робочу копію
  (`148e853`): межі `pr-gate`, frontmatter #95, правило тек для тимчасового, запис `CHANGELOG.md` 1.6.13 і розділ
  `1.6.12 → 1.6.13` в `skills/onboarding/references/upgrades.md`. B2 розблоковано.
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
  `kit-setup` не читають YAML модулем `Yaml.psm1` і не імпортують `Hooks.psm1`.
- Версію не піднімати: блок дописує пункти в наявний запис `CHANGELOG.md` 1.6.13 і в розділ `1.6.12 → 1.6.13`
  `skills/onboarding/references/upgrades.md` (бриф архітектора).
- Наявні тести лишаються зеленими; тест, що фіксує стару поведінку, змінюється в тій самій задачі, що й
  поведінка. Нові тести — за зразком `Check.*.Tests.ps1` (підпроцес диспетчера на `New-KitFakeRepo`, текст і
  «наступний крок не відбувся»), кожен з контролем, що вміє впасти. Перелік тестів у done-when — верхня межа;
  додаткові входи в той самий тест (рядки фікстури) — не новий тест.
- Прогін у задачі — `-Only <змінені файли тестів і викликачі>`; `-Full` — лише T7.

## 4. Рішення

| # | Рішення | Вплив на спеку |
| --- | --- | --- |
| D1 | `Invoke-KitPreflight` отримує режим `-Mode Strict\|Lenient\|Check` замість `-Lenient`; диспетчер дає `Check` лише команді `check`, `Lenient` — `session-check`. `Read-KitManifest -AllowKitVersion` не кидає й повертає ознаку `HasKitVersion` за **тією самою** умовою, що суворий режим (`$m.Contains('kitVersion')`), — незалежно від значення: порожнє `kitVersion:` теж знахідка. Префлайт у режимі `Check` за цією ознакою додає знахідку `error` з тегом `kit-version` і розбирає решту. Без перемикача `Read-KitManifest` кидає, як тепер. | немає |
| D2 | `session-check` лишається в режимі `Lenient`: на `kitVersion` маніфест не читається, `check` зупиняється на знахідці `manifest`, `session-check` дає код 1. Поведінка не змінюється. | немає |
| D3 | Файл застарілих імен — `tools/assets/obsolete-names.json`. Формат: `skills` (стара назва без префікса → нова), `commands` (старий виклик → заміна; `tools/kit.ps1` → `kit`, `kit build` → `unica.run` `"op":"make"`), `unicaTools` (повні імена інструментів, заміни немає — «прибрати»). Читає його одна функція `Get-KitObsoleteNames` у `KitVersion.psm1` (розділ процесу). Жодне ім'я `unicaTools` не збігається з правилом чинного `templates/settings.json` — це перевіряє тест (7). | немає (§5.2 віддає місце й формат плану) |
| D4 | `kit-scan` читає `kitVersion` з `v8storagekit.yaml` рядковим виразом по ключу верхнього рівня, без YAML-модуля (обмеження ADR-0002). Значення не `x.y.z` — стан `invalid` з приміткою. | немає |
| D5 | Нове значення стану `Kit version` у `-Json`: `connected-before`. Умова: у маніфесті є `kitVersion`, а профілю немає **або** профіль без `kit.version`. Профіль з `kit.version` має пріоритет над маніфестом. | немає |
| D6 | **На затвердження архітектора.** Профіль без `kit.version` (тепер нормальний стан до останнього коміту PR) і без `kitVersion` у маніфесті: `kit-scan` дає стан `no-version` — «`kit.version` немає — запише `kit-setup -SetVersion` останнім комітом PR» **без** переліку кроків від 0.1.0; `Get-SetupVersionNote` (`kit-setup`) — той самий текст. `Get-KitProjectVersion` не змінюється (`Source = 'default'`), змінюється лише тлумачення в `kit-scan` і `kit-setup`. **Відоме обмеження:** хук старту сесії (`rust/src/session_start.rs`, `upgrade_hint`) на такому профілі й далі друкує «проєкт на 0.1.0… кроків оновлення N» — лише на гілці PR онбордингу, бо в головну гілку профіль приходить разом із `kit.version`. Rust план не чіпає (обмеження розділу 3); виправлення — у фазі порту `kit-scan`/`kit-setup` (#53/#55). | §5.2 «До того `kit-scan` показує розрив версії» — уточнити: розрив без переліку кроків; хук — відоме обмеження |
| D7 | Прапорець запису версії — `kit-setup -SetVersion`. Окремий режим: змінює лише `kit.version` у наявному профілі (решта файлу без змін). Профілю немає — код 1 з дією «спершу `kit-setup`». Профіль не розбирається як JSON-об'єкт — код 3 без запису (не `Get-SetupProfileData`, що ковтає помилку). Разом з іншими прапорцями, крім `-DryRun`, — код 2. Запис — той самий атомарний помічник, що для `settings.json` (D13). | немає (§5.2 віддає ім'я плану) |
| D8 | Єдине джерело цільових правил для `kit-setup` — `templates/settings.json` плагіна (`Get-KitPluginRoot`); перелік `$script:KitCommands` у `kit-setup.psm1` зникає. `Templates.Tests.ps1` тримає дві перевірки: (1) **незалежний орієнтир** — правила команд процесу в шаблоні дорівнюють переліку-літералу в самому тесті (локальні команди процесу плюс `pr-gate open/ready/land`, у двох формах; нова команда процесу без рішення про дозвіл — червоне); (2) **шаблон ↔ `kit-setup`** — на фікстурі з ознакою 1С результат дорівнює шаблону повністю (`allow`, `ask`, `deny`), на фікстурі без 1С — шаблону без правил Уніки в `allow` (D9). Чинні регекс `$process` і заборона `pr-gate (open\|ready\|land)` у тесті переписуються за §5.3. | немає |
| D9 | **На затвердження архітектора.** Правила `mcp__plugin_unica_unica__*` з `allow` шаблону `kit-setup` додає лише в репозиторії 1С (`Test-SetupIs1C`). Правила `ask` і `deny` шаблону, пункти (б) і (в) §5.2 діють завжди: `ask` лише звужує права, і `unica_apply` в `ask` потрібен і проєкту, де ознак 1С ще немає. Причина: проєкт лише з процесом не має Уніки, а `unica_run` в `allow` без потреби розширює права. Проєкт 1С, де `v8project.yaml` ще не з'явився, отримає `allow` Уніки повторним `kit-setup` (крок тексту B3). | §5.2 (а) — додати: «правила Уніки з `allow` шаблону — лише в репозиторії 1С» |
| D10 | Форма правил шаблону — `Bash(<команда>:*)` і `PowerShell(<команда>:*)`. `ask` шаблону — рівно 8 правил команд: `git push`, `gh pr create`, `gh pr merge`, `gh release`, кожна у двох формах (плюс `unica_apply`). | §5.3 пише `Bash(… *)` і ставить `gh release` поза «у формах» — привести до `:*` і двох форм для всіх чотирьох |
| D11 | Код «є що робити» `session-check` — **4**, не 3 (`tools/commands/session-check.psm1`, обчислення `$exit`; контракт `CLAUDE.md`). Текст B3 каже про код 4. | §5.4, пункт #65 — «код 4» |
| D12 | Шим хука. Вхід — `hooks.SessionStart[]` (групи `{matcher, hooks[]}`), команда — у `hooks[].command`. Прибирається **внутрішній елемент** `hooks[]`, чия команда після заміни `\` на `/` містить `.claude/hooks/session-start.ps1`; група — лише коли її `hooks[]` спорожнів; `SessionStart` і `hooks` — лише коли спорожніли. Власний хук у тій самій групі лишається. Збіг навмисно вужчий за `Test-KitLegacySessionHook` (`*session-start.ps1*`, `tools/lib/Hooks.psm1`): `check` попереджає ширше, а прибирає `kit-setup` лише шим kit. Файл шима `kit-setup` не видаляє (`git rm` — крок тексту `skills/onboarding/references/upgrades.md`). | немає |
| D13 | Правило злиття (§5.2 (а)): правило шаблону додається до списку L, якщо його немає **в тому самому списку** L; до `allow` — лише якщо його немає ще й в `ask` чи `deny` проєкту (строгіше рішення проєкту перемагає). Отже `git push` в `allow` проєкту не заважає додати його в `ask`, а `unica_run` в `ask` проєкту не потрапляє в `allow`. Запис будь-якого файлу `kit-setup` — один помічник: серіалізувати, розібрати результат у пам'яті, записати тимчасовий файл поруч, атомарно замінити; збій — зупинка без запису. | §5.2 (а) — уточнити «яких немає в тому самому списку» |
| D14 | **На затвердження архітектора.** Широкі правила першого покоління шаблону `Bash(git branch:*)`, `PowerShell(git branch:*)` (пропускають `git branch -D/-f`, зокрема на `storage/*`) — до переліку попереджень `$script:BroadOld` з замінником `git branch --list:*`, `git branch --show-current`. Попередження, не прибирання: контракт «прибирає лише точні застарілі імена Уніки й шим» не змінюється. | §5.2 — додати до попереджень `kit-setup` |

**Застарілі інструменти Уніки (D3, вимір 2026-11-23).** Усі імена `mcp__plugin_unica_unica__unica_*` з історії
`templates/settings.json` (`git log -- templates/settings.json`, 7 комітів) мінус 8 інструментів, які Claude Code
бачить у Уніки 0.16: `apply`, `check`, `diff`, `docs`, `resolve`, `run`, `search`, `view` (перелік MCP-інструментів
сесії; те саме — `docs/unica-contract.md`, розділ дозволів: «інструментів задач (`unica_task_*`) у ньому немає»).
`unica-call.ps1` з `--tools` показує ще `task.*`, але правила дозволів Claude Code з ними не зіставляються. Залишок —
37 суфіксів після `unica_`: `cf_info cf_validate cfe_diff cfe_validate code_definition code_diagnostics code_graph
code_outline code_search dcs_info dcs_validate documentation_get documentation_search form_info form_validate
interface_validate meta_info mxl_decompile mxl_info mxl_validate project_map project_status role_info role_validate
source_children source_locate source_read source_resolve source_resources standards_explain standards_search
subsystem_info subsystem_validate task_cancel task_get task_result xdto_info`.

## 5. Інтерфейси

| Інтерфейс | Дає | Бере | Контракт |
| --- | --- | --- | --- |
| знахідка `check` `kit-version` | T1 | T6 (текст) | `error` (маркер `[-]`); дія — «видалити рядок `kitVersion:` з `v8storagekit.yaml`; версію проєкту тримає `.agents/kit.profile.json`»; решта перевірок триває; код `check` — 1 |
| режим префлайту `Check` | T1 | — | лише для `check`; для решти команд `kitVersion` — зупинка з тією самою дією |
| `templates/v8project.yaml` | T2 | T6, споживачі | форма воркспейсу Уніки 0.16; кожне правило шаблону перевіряє `check` |
| дія `warn undeclared-source` | T2 | T6 | називає рядок `.gitattributes` (`<шлях>/** -text`) для `git`/`storage` і рядок `.gitignore` (`<шлях>/**`) для `vendor` |
| `tools/assets/obsolete-names.json` + `Get-KitObsoleteNames` | T3 | T4 (`unicaTools`), T6 (`skills/onboarding/references/upgrades.md` посилається) | D3 |
| стан `connected-before` / `no-version` у `Kit version` `kit-scan` (текст і `-Json`) | T3 | T5, T6 | D5, D6; для `connected-before` — `kit check -RepoRoot .` і чеклісти версій, новіших за версію з маніфесту |
| розділ застарілих імен `kit-scan` | T3 | T6 | рядок на збіг: файл, стара назва, заміна |
| злиття `settings.json` у `kit-setup` | T4 | T6 | §5.2 (а)–(г), D8, D9, D12, D13, D14 |
| цільовий `templates/settings.json` | T4 | T6, споживачі | §5.3, D10 |
| `kit-setup -SetVersion`; версія плагіна у виводі `kit-setup` | T5 | T6 | D7 |

## 6. Інваріанти безпеки

Тест (3) B2 тримає одну фікстуру `settings.json`: застаріле ім'я Уніки в `allow`, в `ask` і в `deny`; чинне
`unica_view` в `allow`; `unica_run` в `ask` (форма Уніки 0.13); `unica_apply` в `allow`; `Bash(git push:*)` в `allow`
і в `ask`; власне правило проєкту; власний `deny`; група `SessionStart` зі шимом (шлях з `\`) і власним хуком в одному
`hooks[]` плюс окрема група з власним хуком.

| Інваріант | Перевірка, що ловить дефект |
| --- | --- |
| `deny` проєкту не змінюється ніколи, навіть застаріле ім'я в ньому | тест (3): `permissions.deny` після злиття дорівнює вхідному поелементно. Мутація «прибирати застарілі з усіх трьох списків» — червоне на застарілому імені в `deny` |
| З `ask` прибираються лише точні застарілі імена; інше в `ask` не прибирається й не переноситься в `allow` | тест (3): `unica_run` лишився в `ask` і не з'явився в `allow`; застаріле в `ask` прибрано. Мутація «перенести `ask` у `allow`» чи «додати в `allow` правило, що є в `ask` проєкту» — червоне |
| Правило, яке шаблон тримає в `ask`, у `allow` не потрапляє; `unica_apply` з `allow` переходить у `ask` | тест (3): `unica_apply` лише в `ask`. Мутація «додати в `ask`, не прибравши з `allow`» — червоне |
| Наявність правила перевіряється в тому самому списку (D13) | тест (3): `Bash(git push:*)` в `allow` проєкту → після злиття є і в `ask`. Мутація «наявність за всіма списками» — червоне (тут варіант фікстури без `git push` в `ask`) |
| Прибирається лише **точний** збіг із застарілим іменем | тест (3): у diff немає рядка `-` для `unica_view` і для власного правила. Мутація «збіг за префіксом `mcp__plugin_unica`» — червоне на diff, хоч (а) і повернув би `unica_view` |
| Шим прибирається елементом, власний хук лишається | тест (3): власний хук у групі шима й окрема група — на місці; шим з `\` прибрано. Мутація «прибрати всю групу» — червоне |
| Без запиту — лише `pr-gate open/ready/land`; широкого `pr-gate:*` немає; `ask` — рівно 8 правил команд D10 | тест (7): кожне з 8 правил `ask` присутнє поіменно; `pr-gate open/ready/land` в `allow` в обох формах; `pr-gate:*` відсутнє; `unicaTools` не перетинається з шаблоном. Мутації «нема `PowerShell(gh release:*)`», «`Bash(pr-gate:*)` у шаблоні», «`gh pr merge` прибрано з `ask`» — червоне |
| Невалідний JSON на вході — зупинка без запису | тест (4): `settings.json` байт-у-байт той самий, код не 0, `.gitignore` і профіль не створено. Тест тримає лише **вхід**; запис через тимчасовий файл і розбір результату (D13) перевіряє рев'ю коду T4 — у звіті задачі назвати рядки помічника |
| Невалідний профіль — `-SetVersion` не пише | тест (5): зламаний `.agents/kit.profile.json` → код 3, файл байт-у-байт той самий |
| `-NoPermissions` вимикає все злиття, включно з прибиранням | тест (3): з `-NoPermissions` diff `settings.json` порожній |
| `check` не дає зеленого на маніфесті з `kitVersion` | тест (1) B1, випадок «чистий репозиторій (`New-GoodRepo`) + лише `kitVersion`» → код 1 і рядок `[-]` з дією про `kitVersion`; випадок `kitVersion:` без значення → код 1. Мутації «знахідка `warn`» і «знахідка за значенням поля» — червоне |
| Інші команди на `kitVersion` не працюють | тест (2) B1: `sync` зупиняється з текстом про `kitVersion` (не пізніше, на раннері), дзеркал `storage/*` не створено; `session-check` — код 1 |

## 7. Частини з власним done-when

Немає окремих частин: B1, B2, B3 приймаються разом одним PR архітектора; межі задач — нижче.

## 8. Задачі

**T0 — звірка якорів і поправки до спеки.** Файли: спека, план. Звірити якорі спеки з кодом на HEAD гілки
(`doc anchors` спеки й плану); внести в спеку затверджені поправки D6, D9, D10, D11, D13, D14 (формулювання — з
колонки «Вплив на спеку»). Done when: `doc anchors` обох файлів без зламаних, крім файлів, які створять T2/T3;
поправки закомічено одним комітом зі згадкою D-номерів. Залежність: приймання плану. Перевірка: голий
`Run-Tests.ps1` (тести `Docs`).

**T1 — `kitVersion` у режимі `check` (B1, §5.1).** Файли: `tools/lib/Manifest.psm1`, `tools/lib/Preflight.psm1`,
`tools/kit.ps1`, тести `Check.Manifest.Tests.ps1`, `Manifest.Tests.ps1`, `Preflight.Tests.ps1` (виклики `-Lenient` →
`-Mode Lenient`, одна перевірка `-Mode Check` на рівні модуля). Done when: тест (1) — маніфест з `kitVersion` і блоком
`infobase:` у `v8project.yaml` → `check` друкує обидві знахідки, код 1; випадки «лише `kitVersion`» і «порожнє
`kitVersion:`» → код 1 і рядок `[-]` (розділ 6); тест (2) — `sync` і `session-check` зупиняються з дією «видалити
`kitVersion`», дзеркала не створено; наявний тест `Read-KitManifest` на `kitVersion` лишається (без перемикача —
виняток). Залежність: T0. Перевірка: `-Only Check.Manifest,Manifest,Preflight,SessionCheck.Findings` + файли, що
кличуть `Invoke-KitPreflight` (`grep -rln Invoke-KitPreflight tools/tests`).

**T2 — шаблон `v8project.yaml` і дія `undeclared-source` (B1, §5.1).** Файли: `templates/v8project.yaml` (новий),
`templates/README.md`, `tools/commands/check.psm1`, `Check.Manifest.Tests.ps1` (поруч із наявним тестом
`undeclared-source`). Done when: тест (3) — незаявлений source-set → `warn undeclared-source`, код 0, дія називає
рядок `<шлях>/** -text` для `git`/`storage` і `<шлях>/**` у `.gitignore` для `vendor`; контроль — заявлений set без
рядка `-text` дає `error` з `<шлях>/** -text` (наявний тест у `Check.GitPolicy.Tests.ps1`, якщо він є, не дублювати);
`kit check` на синтетичному репозиторії з копією шаблону не дає знахідок `workspace` (ручний прогін, вивід — у звіті
задачі, нового тесту немає). Залежність: T1 (той самий `check.psm1` і тест — послідовно). Перевірка:
`-Only Check.Manifest,Check.GitPolicy,Templates`.

**T3 — `kit-scan`: проєкт, підключений раніше, і застарілі імена (B2, §5.2).** Файли:
`tools/assets/obsolete-names.json` (новий), `tools/lib/KitVersion.psm1`, `tools/commands/kit-scan.psm1`,
`KitScan.Tests.ps1`. Done when: тест (1) — маніфест `kitVersion: 1.4.0` без профілю → «підключено раніше (1.4.0)»,
`kit check -RepoRoot .` і чеклісти новіших версій; у `-Json` — `connected-before`; тест (2) — `CLAUDE.md` з
`v8storagekit:reconcile`, `/v8storagekit:sync` і `tools/kit.ps1` → рядок на кожне з заміною; контроль — `kit sync`,
голе `dump` і чинне `v8storagekit:storage-sync` рядка не дають; стан `no-version` за D6 (якщо D6 затверджено).
Пошук — цілі токени без урахування регістру, у файлах §5.2; гітігноровані робочі теки `.agents/` (`out`, `sdd`,
`briefs`, `private.dir`) і корінь worktree пропускаються. Залежність: T0. Перевірка: `-Only KitScan` + викликачі
`Get-KitProjectVersion` (`grep -rln Get-KitProjectVersion tools/tests`).

**T4 — злиття `settings.json` і цільовий шаблон (B2, §5.2–§5.3).** Файли: `tools/commands/kit-setup.psm1`,
`templates/settings.json`, `templates/README.md` (рядок `settings.json`), `KitSetup.Tests.ps1`, `Templates.Tests.ps1`.
Done when: тест (3) на фікстурі розділу 6 — `kit-setup -DryRun` показує прибрати застаріле з `allow` і `ask`, перенести
`unica_apply` в `ask`, додати `pr-gate open/ready/land` і `git push` в `ask`, прибрати лише шим; усі інваріанти розділу
6 для злиття виконані; з `-NoPermissions` diff `settings.json` порожній; тест (4) — невалідний JSON за розділом 6;
тест (7) — зміст шаблону за §5.3 і D10; `Templates.Tests.ps1` за D8 (обидві перевірки, кожна червоніє на розбіжності);
попередження D14 і про широке `pr-gate:*` — за §5.3; довідка команди (`$script:Usage`, шапка модуля) описує новий
контракт злиття. Залежність: T3 (`Get-KitObsoleteNames`). Перевірка: `-Only KitSetup,Templates,PrGate`. Рев'ю задачі —
два рецензенти (безпекова зміна), один з них на лінзі розділу 6.

**T5 — профіль: `kit.version` останнім (B2, §5.2).** Файли: `tools/commands/kit-setup.psm1`, `KitSetup.Tests.ps1`.
Done when: тест (5) — новий профіль без `kit.version`; `kit-scan` показує стан за D6; `kit-setup -SetVersion`
записує версію плагіна й більше нічого не змінює у файлі; зламаний профіль → код 3, файл той самий;
`Get-SetupVersionNote` за D6; тест (6) — профіль без знайдених `docs.specs`/`docs.plans` не має для них ні поля, ні
TODO, `pr.base`/`pr.mergeMethod` — TODO, як тепер; вивід `kit-setup` містить версію плагіна. Залежність: T4 (той самий
файл). Перевірка: `-Only KitSetup,KitScan`.

**T6 — текст онбордингу (B3, §5.4).** Файли: `skills/onboarding/SKILL.md`, `skills/onboarding/references/upgrades.md`,
`skills/onboarding/references/process.md`, `skills/onboarding/references/storage.md`, `templates/CLAUDE.md`,
`docs/unica-contract.md`, `skills/storage-sync/SKILL.md`, `skills/storage-rules/SKILL.md`,
`skills/infobase-agent/SKILL.md`, `skills/infobase-dump/SKILL.md`; згадки `kit-setup` у `README.md`. Done when:
рецепт кроку 9 (розділ `1.4.0 → 1.6.0`) без безумовного видалення `Ext/ParentConfigurations/` і без безумовного
закриття VS Code, з розвилкою для людини за класами змін; таблиця «Довідка по версіях» — рядок на кожен розділ
версії; розділ із замінами імен посилається на `tools/assets/obsolete-names.json`, а не копіює; порядок для
проєкту, підключеного раніше, — `kit-scan` → `kit check` → відхилення обох → кроки Уніки → `kit-setup -SetVersion`
останнім комітом; повторний скан, коли версія плагіна у звіті й на застосуванні різна; повторний `kit-setup`
після появи `v8project.yaml` (D9); `templates/CLAUDE.md` — межа «Межі» і розділ «Дозволи» за ADR-0017 (через
`pr-gate` без запиту; голі `git push`/`gh pr` — з запитом); дотичні тексти §5.4 (кириличні шляхи, код 4 за D11,
тривалість реплею як умова виміру, рядки «Трекінг в апстрімі» #63); старі формулювання прибрано пошуком по всіх
документах (`grep -rn` по `skills/ templates/ docs/ README.md`). Залежність: T2, T5. Перевірка: голий
`Run-Tests.ps1` (тести `Docs`: `Skills`, `KitScan`, `Templates`).

**T7 — журнал і фінал блоку.** Файли: `CHANGELOG.md` (запис 1.6.13), `skills/onboarding/references/upgrades.md`
(розділ `1.6.12 → 1.6.13`). Done when: запис 1.6.13 має пункти B1–B3 і чекліст для проєкту (прогнати
`kit-scan`, `kit check`, `kit-setup -DryRun` → застосувати; `kit-setup -SetVersion` останнім комітом); `-Full`
зелений; хеш верхівки передано архітектору. Залежність: T6. Перевірка: `-Full`.

## 9. Задача 0

Див. T0 у розділі 8.

## 10. Задачі власника

Немає: міграцію споживачів (зокрема MamHub) власник робить сам; PR у `main` відкриває й зливає архітектор.

## 11. Підсумок аудиту

Буде дописано після раунду 2.
