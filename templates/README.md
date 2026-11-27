# templates/

Файли, які плагін кладе в репозиторій-споживач (скіл `v8storagekit:onboarding`, команда
`kit install-hooks`). Два з них навмисно без провідної крапки — щоб не діяти на сам kit.

| Файл тут | Стає в репо-споживачі |
|---|---|
| `gitattributes` | `.gitattributes` (onboarding дописує `<ws>/<path>/** -text` під фактичні шляхи) |
| `gitignore` | `.gitignore` (без загального `**/cf/**`; onboarding дописує `<ws>/<path>/**` для кожного `truth: vendor`) + `**/Ext/ParentConfigurations/` (поставка вендора поза git) |
| `settings.json` | `.claude/settings.json` — дозволи й цільовий стан, з яким `kit-setup` лише звіряє налаштування проєкту (звіт для читання; kit файл не копіює й не пише — права не автоматизуються; єдине джерело правил звіту; у проєкті без ознак 1С — без правил Уніки в `allow`). Без запиту: читальні інструменти Уніки, `unica_run` і `unica_apply`, локальні команди процесу й `pr-gate open`/`ready`/`land` (ADR-0017) — в обох формах `Bash(…)`/`PowerShell(…)`. З запитом: голі `git push`, `gh pr create`, `gh pr merge`, `gh release` — в обох формах. Перелік правил команд процесу звіряє з орієнтиром і з результатом `kit-setup` `Templates.Tests.ps1`; хука `SessionStart` тут немає — його поставляє сам плагін (`hooks/hooks.json`) |
| `v8project.yaml.example` | `<воркспейс>/v8project.yaml` — форма воркспейсу Уніки 0.16 (`providers`, `source-set`, без `infobase:`); заповнює onboarding; кожне правило перевіряє `check`. Суфікс `.example` обов'язковий: файл з ім'ям `v8project.yaml` у теці першого рівня робить сам kit «репозиторієм 1С» для детекторів (хук SubagentStart, `kit-setup`, пошук воркспейсів Уніки) — тримає `SubagentStartHook.Tests.ps1` |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
| `CLAUDE.md` | `CLAUDE.md` (контур сховища й процес розробки; профіль процесу `.agents/kit.profile.json` кладе не цей шаблон, а `kit-setup` — скіл `v8storagekit:onboarding`) |
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює onboarding за відповідями людини) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `AUTHORS.example` | `AUTHORS` (корінь) |
