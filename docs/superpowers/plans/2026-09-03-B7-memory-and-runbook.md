# B7. Пам'ять і ранбук під новий канон — план реалізації

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking. Це блок про **глобальне оточення користувача** (ранбук, скіл `unica-1c`, пам'ять п'яти проєктів) — інші репозиторії, інші межі дозволів; виконувати в окремій сесії, кожну правку показувати користувачу перед записом.

**Goal:** прибрати з ранбука, особистого скіла `unica-1c` і пам'яті проєктів твердження, що
суперечать канону 1.0 (реплей у поточну гілку, `storage.json`, `load-ext` як «наступний крок»,
дві бази), і додати маршрутизацію до kit там, де Unica не вміє.

**Architecture:** лише текстові правки поза репозиторієм kit. Джерело істини — спека §10 і
плани B1–B6. Нічого не вигадувати: кожна правка — заміна конкретного застарілого твердження
на чинне, з посиланням на команду/скіл 1.0.

**Spec:** `docs/superpowers/specs/2026-09-03-agent-contour-design.md` §10; §1 (принципи), §3 (модель git), §5 (команди), §6 (скіли).

## Global Constraints

- Файли поза репозиторієм kit: `~/.claude/1c-work-runbook.md`, `~/.claude/skills/unica-1c/SKILL.md`,
  `~/.claude/projects/*/memory/*.md`. Перед кожним записом — показати diff користувачу.
- Пам'ять: формат із frontmatter (`name`, `description`, `metadata.type`); одна пам'ять — один
  факт; суперечливе — переписати або видалити; індекс `MEMORY.md` — по рядку на файл.
- Мова — українська. Нічого не пушити (це не git-репозиторії, але правило лишається для kit).

---

### Task 1: ранбук `~/.claude/1c-work-runbook.md`

- [ ] **Step 1: Розділ «Сховища конфігурацій і розширень — перевірений рецепт»** — після чотирикрокового
  конвеєра додати абзац: «Kit 1.0 реплеїть **не в поточну гілку**, а в orphan-гілки `storage/<джерело>`
  через worktree (`kit sync`); стан — трейлер `Storage-Version` вершини гілки, файлу стану немає.
  Сховище конфігурації (без `-Extension`): <результат спайку B2 зі спеки §14>». П. 5 («ітеруйся
  переліком зі звіту») — лишити; додати «п. 8: `UpdateDBCfg` — лише база агента (`operation=build`),
  у базу людини kit не пише; дві бази — агента (`<ws>/build/ib`) і людини (лише `kit dump`)».
- [ ] **Step 2: Розділ про BankExchange** — уже історія; дописати один рядок: «стан 1.0 —
  `R:\github\SMP_V8StorageKit\docs\storage-and-git.md`».
- [ ] **Step 3: «Куди дивитись за чим»** — рядок «сховище ↔ git»: скіли `v8storagekit:sync|verify|reconcile|finish`,
  маніфест `v8storagekit.yaml`; `storage.json` більше немає.
- [ ] **Step 4:** Показати diff користувачу; записати.

### Task 2: `~/.claude/skills/unica-1c/SKILL.md` — маршрутизація до kit

- [ ] **Step 1:** Додати розділ «Що Unica не вміє — kit»: сховища конфігурацій (`kit sync`,
  `verify`), дамп із живої бази людини (`kit dump`), база агента з `.dt` (`kit provision`),
  канонізація дерева (`kit canon`), `.epf` (`kit build`); скіли з префіксом `v8storagekit:`.
- [ ] **Step 2:** Прибрати згадки `storage-sync.ps1`, `dump-config.ps1`, `load-ext.ps1`, `build.ps1`,
  `storage.json`, якщо є (`Select-String`).
- [ ] **Step 3:** Показати diff; записати.

### Task 3: пам'ять проєктів

Для кожного файлу: прочитати, знайти твердження, що суперечать §1.3–1.4/§3, переписати або видалити;
оновити відповідний `MEMORY.md`.

- [ ] **SimplyConnect** — `cfe-build-needs-base-config` (відхилений кеш — перевірити актуальність;
  збірка `.cfe` тепер `operation=make` у базі агента), `simplyconnect-storage-migration` (`load-ext`
  як «наступний крок» → **видалити** твердження; наступний крок — міграція `v8storagekit:migrate`
  після тестового репо).
- [ ] **BankExchange** — `bankexchange-infrastructure-map` (`load-ext` на базах під сховищем → замінити:
  «агент у базу людини не пише; розкатка — `operation=build` у базу агента»).
- [ ] **SimplyAddinConnect** — `unica-plugin`, `1c-headless-epf-verification`: звірити з `kit build`
  (`.epf` через `/LoadExternalDataProcessorOrReportFromFiles`) — переписати лише суперечливе.
- [ ] **Kit** — `v8storagekit-plugin-dev-loop` (B1 Task 10 уже оновив стан маркетплейсу; додати:
  команди через `kit.ps1`, префікси скілів 1.0, `claude -p` для перевірки). Нова пам'ять (тип
  `project`): `v8storagekit-agent-contour-status` — які блоки виконано, що лишилось (B8, живі
  репозиторії), де тестовий репо; з датами.
- [ ] `verification-agent-builds-human-applies` — уже відповідає §1.3–1.4; не чіпати.
- [ ] Кожен `MEMORY.md` — по рядку на файл, без вмісту.

### Task 4: перевірка

- [ ] `Select-String -Path ~/.claude/1c-work-runbook.md, ~/.claude/skills/unica-1c/SKILL.md, ~/.claude/projects/*/memory/*.md -Pattern 'storage-sync|dump-config|load-ext|storage\.json'`
  — лише історичні згадки з явною позначкою «до 1.0».
- [ ] Коротка доповідь користувачу: що змінено, що видалено, що лишено як історію.

## Self-review

| §10 спеки | Задача |
|---|---|
| ранбук: «Сховища» (реплей у `storage/*`), BankExchange як історія, п. 8 (`UpdateDBCfg`, дві бази) | 1 |
| `unica-1c/SKILL.md`: маршрутизація до kit | 2 |
| пам'ять SimplyConnect, BankExchange, SimplyAddinConnect, kit; суперечливе — переписати/видалити | 3 |
