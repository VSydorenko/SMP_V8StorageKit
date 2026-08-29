# SMP_V8StorageKit

Плагін Claude Code: конвеєр «сховище конфігурацій 1С ↔ git» для репозиторіїв SMP_*.
Походження — SMP_BankExchange (перезапуск 2026-08); скрипти й тести перенесені звідти.

## Встановлення

    claude plugin marketplace add VSydorenko/SMP_V8StorageKit
    claude plugin install v8storagekit@smp-v8storagekit

## Що всередині

- `tools/` — скрипти конвеєра (storage-sync, dump-config, load-ext, build) + модулі + Pester-тести
- `skills/` — storage-pipeline (щоденний цикл), product-onboarding (новий продукт), repo-migration (міграція старого репо)
- `templates/` — шаблони файлів репо-споживача (CLAUDE.md, .gitattributes, .gitignore, settings.json, storage.json)
- `docs/` — архітектура контуру «сховище ↔ git»

Скіли реєструються з префіксом плагіна: викликаються як `v8storagekit:storage-pipeline`,
`v8storagekit:product-onboarding`, `v8storagekit:repo-migration` (не голим іменем зі
`skills/` вище — плагін-реєстр додає префікс сам, і без нього виклик впаде з `Unknown skill`).

## Розробка

Робоча копія — звичайний клон. Живе тестування на реальному проєкті:

    claude --plugin-dir R:\github\SMP_V8StorageKit

`/reload-plugins` підхоплює правки без перезапуску сесії. Тести:

    pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration

Повний прогін (з тегом Integration) реально запускає 1cv8.exe і створює файлову ІБ.
