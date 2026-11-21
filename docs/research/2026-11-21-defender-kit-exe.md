# Дослідження: Windows Defender і поставлений `kit.exe` (2026-11-21)

Датований запис дослідження — знімок на дату, не постійний опис. Мета — не перевіряти вдруге те, що
вже перевірено: що виміряно, що прочитано, де нічого не знайдено. Рішення, що з нього випливають, —
`CLAUDE.md` («Збірка `kit.exe` і Rust»), план #51 §14, ADR-0014 «Consequences».

Позначки: **[вимір]** — виміряно на машині розробника; **[док]** — офіційна документація;
**[звіт]** — звіт спільноти (issue, форум, блог); **[гіп]** — гіпотеза, не перевірена.

## 1. Питання

Чому Defender видаляє `bin/kit.exe` (Rust, непідписаний) і як поставляти бінарник так, щоб плагін не
втрачав єдиний вхід у споживача. Варіант «резервний PowerShell-вхід, коли exe недоступний» власник
відхилив: він знецінює перехід на Rust (ADR-0014).

## 2. Що сталося [вимір]

- Детекція: `Trojan:Win32/Bearfoos.A!ml` (ThreatID 2147731250). Суфікс `!ml` — вердикт моделі
  машинного навчання, не сигнатура.
- Машина: Windows Server 2022, Defender platform 4.18.26100.4, сигнатури 1.463.390.0;
  `MAPSReporting=2`, `SubmitSamplesConsent=1` (хмарний захист і надсилання зразків увімкнені),
  real-time і behavior monitoring увімкнені.
- Збірка під підозрою: локальна, `rust-lld` + бібліотеки `xwin` (без Visual Studio), rustc 1.100.0,
  `x86_64-pc-windows-msvc`, release з `lto`, `strip`, `panic=abort`; без підпису, без VERSIONINFO, без
  маніфесту, без Rich header.
- Хронологія: бінарник закомічено о 11:18; з ним того ж дня пройшов повний Pester-прогін (сотні
  запусків); о 13:19–13:20 Defender видалив його з робочого дерева, з тимчасових копій тестів (зокрема
  копії з індексу git — тобто байти коміту) і з `rust/target`. Раніше того ж дня позначали й іншу
  локальну збірку. Статичний скан `MpCmdRun -Scan -ScanType 3 -File … -DisableRemediation` тих самих
  байтів під час задачі давав «found no threats».
- Висновок з виміру: статичний скан не доводить, що файл переживе запуск; чистий прогін одразу після
  появи файлу теж не доводить. Затримка вердикту [гіп]: файл надсилається в хмару, вердикт приходить
  пізніше. Документації про таку затримку не знайдено.
- Варіанти профілю release (opt-level, lto, strip, panic, codegen-units — 9 варіантів) статичний скан
  проходили всі; один із них раніше позначали — детекція залежить від байтів, не від прапорця.

## 3. Порівняння з Унікою [вимір]

`unica-bootstrap.exe` (Уніка 0.12.3) на тій самій машині працює щодня без детекцій.

| | `kit.exe` (локальний) | `unica-bootstrap.exe` |
|---|---|---|
| Підпис | немає | немає |
| VERSIONINFO | немає | немає |
| Маніфест | немає | немає |
| Rich header (слід MSVC `link.exe`) | немає | є |
| Де зібрано | локально, `rust-lld` | GitHub Actions `windows-latest`, MSVC |
| Розмір | ~0,5 МБ | ~2,7 МБ |

Єдина виміряна структурна різниця — лінкер. Що саме вона впливає на вердикт — [гіп]: жодного джерела,
яке пов'язує Rich header чи `link.exe` з ML-детекціями Defender, не знайдено (розділ 5).

## 4. Експеримент: збірка на CI [вимір]

Гілка `exp/51-kit-exe-ci` (не зливається), workflow на `windows-latest`, MSVC `link.exe` 14.52,
rustc 1.100.0, атестація `actions/attest-build-provenance`.

| Варіант | Статичний скан | `-Only KitExe,SessionStartHook,SessionBoard` | Повний Pester | Детекції |
|---|---|---|---|---|
| V1: джерело без змін | чисто | 44/44 | 0 червоних | 0 |
| V2: V1 + VERSIONINFO і маніфест | чисто | 44/44 | — | 0 |

Обмеження: перевірка тривала менше години, а позначений локальний бінарник теж спершу пройшов
повний прогін. Результат — **попередній**; повторна перевірка через кілька годин і наступного дня
обов'язкова, перш ніж вважати збірку CI розв'язком. Вердикт `!ml` різниться між машинами (розділ 6),
тож чистий результат на одній машині не гарантує його в споживача.

## 5. Що каже Microsoft [док]

- Програми «білого списку» чи «запобігання хибним детекціям» для розробників немає; рекомендований
  захід — послідовно підписувати файли сертифікатом довіреного кореня: це допомагає дослідникам
  впізнати джерело й застосувати накопичене знання; рідко сертифікат потрапляє в довірені видавці.
  https://learn.microsoft.com/en-us/defender-xdr/developer-faq
- Хибна детекція: подати файл як software developer (Defender Security Intelligence, форма подання
  файлу), дочекатись остаточного рішення; незгода — форма зв'язку з розробником у результатах подання.
  Там само: «Submissions help ensure that unknown or suspicious software is scanned by the system to
  start establishing reputation»; довіра до нових програм і сертифікатів потребує часу.
  https://learn.microsoft.com/en-us/defender-xdr/criteria
- Критерії небажаного ПЗ (бандлінг, ухиляння від засобів безпеки, втручання в налаштування тощо) —
  kit нічого з цього не робить. https://learn.microsoft.com/en-us/defender-xdr/criteria
- Block at first sight: новий підозрілий файл → запит до хмари, яка вирішує «heuristics, machine
  learning, and automated analysis»; невирішений файл блокується й вивантажується в хмару. Сфера —
  файли з Інтернету. Порівняння «запуск проти ручного сканування» документація не дає.
  https://learn.microsoft.com/en-us/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus
- Блог співробітника Defender: найкращий захист — коли добру репутацію коду легко впізнати, тобто
  кожен файл підписано; блокування може бути не від антивірусу, а від політики підприємства.
  https://textslashplain.com/2026/01/27/microsoft-defender-false-positives/
- Рішення за поданням діє на конкретний файл; нова збірка може знову потребувати подання [звіт].
  https://comcomponent.com/en/blog/windows-defender-false-positive-guide/
- **Не знайдено:** що саме таке `!ml` в офіційній документації; строк розгляду подання; чи діє
  рішення на хеш, сімейство чи сертифікат.

## 6. Практика інших проєктів [звіт]

| Проєкт | Збірка | Детекція | Що зробили | Результат |
|---|---|---|---|---|
| [no-mistakes#535](https://github.com/kunchenguid/no-mistakes/issues/535) | Go, CI, непідписаний | `Bearfoos.A!ml` | свідомо відмовились від «packing, PE-layout tweaks, or other cat-and-mouse»; лише документація й подання | не розв'язано, повторилось на новіших версіях |
| [microsoft/apm#487](https://github.com/microsoft/apm/issues/487) | PyInstaller, CI, непідписаний | `Bearfoos.B!ml`, згодом `Wacatac.H!ml` | [PR #490](https://github.com/microsoft/apm/pull/490): VERSIONINFO, без UPX; [PR #1450](https://github.com/microsoft/apm/pull/1450): менше вбудованого тексту | ефект не підтверджено; підпис названо «the durable answer», не впроваджено |
| [upload-rust-binary-action#63](https://github.com/taiki-e/upload-rust-binary-action/issues/63) | Rust msvc, CI | `Sabsik.TE.A!ml` | нічого | зникло само через кілька тижнів |
| [lp_parser_rs#192](https://github.com/dandxy89/lp_parser_rs/issues/192) | Rust | `!ml` (назву не надано) | нічого | закрито як хибна детекція |
| [quickwin#4](https://github.com/quickwinlabs/quickwin/issues/4) | CI, непідписаний | `Sabsik.FL.A!ml` | нічого | той самий хеш чистий на іншій машині й сигнатурах |
| [форум Rust](https://users.rust-lang.org/t/trojan-win32-bearfoos-a-ml/137445) | Rust, локально | `Bearfoos.A!ml` | нічого | на тому самому файлі 5 видалень, 6-й запуск пройшов |

Спільне: усі бінарники непідписані; вердикт `!ml` нестабільний у часі й між машинами; жоден Rust- чи
Go-проєкт не прибрав детекцію прапорцями збірки; підпис скрізь називають постійним рішенням, але
ніде не впроваджено й не виміряно. Також `!ml` мали uv (https://github.com/astral-sh/uv/issues/1587),
WezTerm і інсталятор LLVM.

## 7. Підпис коду

- **Azure Artifact Signing** (колишній Trusted Signing): ~$9.99/міс; фізична особа — лише США й Канада,
  організація — ЄС, США, Канада, Британія [док/звіт].
  https://azure.microsoft.com/products/artifact-signing ;
  https://learn.microsoft.com/en-us/answers/questions/5810735/cant-create-a-new-trusted-signing-individual-ident
- **SignPath Foundation**: безкоштовно для OSS; потрібні OSI-ліцензія, публічний репозиторій, збірка на
  CI, MFA; сертифікат видається на Foundation. Інтеграція — дія
  `signpath/github-action-submit-signing-request` [док]. У репозиторії kit файлу ліцензії немає
  (`gh repo view` → `licenseInfo: null`) [вимір]. https://signpath.org/terms ;
  https://docs.signpath.io/trusted-build-systems/github
- **Certum Open Source Code Signing**: сертифікат фізичній особі з позначкою «Open Source Developer»,
  ключ у хмарі SimplySign, від ~€69; строк дії сертифіката — до 459 днів [звіт, сторінки магазину].
  Чи підписується автоматично на CI — не перевірено. https://shop.certum.eu/open-source-code-signing-on-simplysign.html
- **SSL.com IV (Individual Validated)**: сертифікат фізичній особі, ключ у хмарі eSigner; підтримано
  інструментом релізів Rust `dist` (`ssldotcom-windows-sign`) [док]. Доступність для громадянина
  України й ціну не перевірено. https://github.com/axodotdev/cargo-dist/blob/main/book/src/supplychain-security/signing/windows.md
- Що підпис прибирає саме ML-детекції Defender — **не доведено**: є звіти «допомогло» й звіти
  «підписаний файл усе одно позначили» [звіт].
  https://forum.juce.com/t/what-to-do-about-windows-defender-false-positives/66438

## 8. Технічні чинники PE

- VERSIONINFO, маніфест, Rich header, статичний CRT, розмір: задокументованого випадку, де зміна
  одного з них прибрала `!ml`, не знайдено. apm додав VERSIONINFO — результат не підтверджено [звіт].
- `winresource` (VERSIONINFO через `build.rs`) для MSVC потребує `rc.exe` з Windows SDK — на
  `windows-latest` він є, у локальній збірці через `xwin` ні [док]. kit компілює ресурс `rc.exe` у
  workflow, без нової залежності крейта. https://github.com/benjaminri/winresource
- Інструмент релізів Rust `dist` будує ту саму схему: збірка на CI, підпис (SSL.com чи Azure),
  атестація GitHub [док]. https://github.com/axodotdev/cargo-dist/blob/main/book/src/reference/config.md

## 9. Документація Claude Code

Про постачання нативних бінарників у плагінах документації не знайдено; хуки запускають файли через
`${CLAUDE_PLUGIN_ROOT}`. https://code.claude.com/docs/en/plugins-reference

## 10. Джерела, які не дали результату

- Context7 (`/microsoftdocs/defender-docs`) на запити про хибні детекції й `!ml` повертає API алертів,
  Sentinel і списки блокування Office 365 — для цього питання непридатний. Корисні в Context7:
  `/axodotdev/cargo-dist`, `/websites/signpath_io`, `/benjaminri/winresource`.
- Пошук про Rich header / `link.exe` проти `lld` у зв'язку з детекціями — порожньо.

## 11. Відкрите

1. Повторна перевірка збірки CI через кілька годин і наступного дня (розділ 4).
2. Чи подавати хеш у Microsoft на кожен реліз — потрібен акаунт власника.
3. Підпис: який сертифікат (Certum, SSL.com IV, SignPath після додавання ліцензії) — рішення власника.
4. Що бачать споживачі на інших машинах — даних немає.
