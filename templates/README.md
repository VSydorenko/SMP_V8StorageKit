# templates/

Файли, які плагін кладе в репозиторій-споживач (скіл `v8storagekit:onboarding`, команда
`kit install-hooks`). Два з них навмисно без провідної крапки — щоб не діяти на сам kit.

| Файл тут | Стає в репо-споживачі |
|---|---|
| `gitattributes` | `.gitattributes` (onboarding дописує `<ws>/<path>/** -text` під фактичні шляхи) |
| `gitignore` | `.gitignore` (без загального `**/cf/**`; onboarding дописує `<ws>/<path>/**` для кожного `truth: vendor`) |
| `settings.json` | `.claude/settings.json` — дозволи + хук `SessionStart` |
| `hooks/session-start.ps1` | `.claude/hooks/session-start.ps1` — шим хука (без логіки) |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
| `CLAUDE.md` | `CLAUDE.md` |
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює onboarding за відповідями людини) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `AUTHORS.example` | `AUTHORS` (корінь) |
