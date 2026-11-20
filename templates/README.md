# templates/

Файли, які плагін кладе в репозиторій-споживач (скіл `v8storagekit:onboarding`, команда
`kit install-hooks`). Два з них навмисно без провідної крапки — щоб не діяти на сам kit.

| Файл тут | Стає в репо-споживачі |
|---|---|
| `gitattributes` | `.gitattributes` (onboarding дописує `<ws>/<path>/** -text` під фактичні шляхи) |
| `gitignore` | `.gitignore` (без загального `**/cf/**`; onboarding дописує `<ws>/<path>/**` для кожного `truth: vendor`) + `**/Ext/ParentConfigurations/` (поставка вендора поза git) |
| `settings.json` | `.claude/settings.json` — дозволи (читальні інструменти Уніки й `unica_run` — без запиту; `unica_apply` — з запитом; локальні команди процесу — без запиту в обох формах `Bash(…)`/`PowerShell(…)`, той самий перелік, що пише `kit-setup`, — звіряє `Templates.Tests.ps1`); хука `SessionStart` тут немає — його поставляє сам плагін (`hooks/hooks.json`) |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
| `CLAUDE.md` | `CLAUDE.md` (контур сховища й процес розробки; профіль процесу `.agents/kit.profile.json` кладе не цей шаблон, а `kit-setup` — скіл `v8storagekit:kit-onboard`) |
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює onboarding за відповідями людини) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `AUTHORS.example` | `AUTHORS` (корінь) |
