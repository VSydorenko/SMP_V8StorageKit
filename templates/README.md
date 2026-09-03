# templates/

Файли для копіювання в репо-споживач при онбордингу чи міграції (скіли
`product-onboarding` і `repo-migration`). Два з них навмисно без провідної крапки —
щоб не діяти на сам kit.

| Файл тут | Стає в репо-споживачі |
|---|---|
| `gitattributes` | `.gitattributes` |
| `gitignore` | `.gitignore` |
| `settings.json` | `.claude/settings.json` |
| `CLAUDE.md` | `CLAUDE.md` |
| `storage.json.example` | `<Продукт>/storage.json` |
| `AUTHORS.example` | `AUTHORS` (у корені репо, не в теці продукту) |
| `v8storagekit.yaml.example` | `v8storagekit.yaml` (корінь; заповнює `v8storagekit:onboarding`) |
| `v8storagekit.local.yaml.example` | `v8storagekit.local.yaml` (корінь; гітігнорований) |
| `githooks/pre-commit`, `githooks/pre-merge-commit` | `.githooks/…` + `git config core.hooksPath .githooks` |
