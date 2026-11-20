---
name: unica-1c
description: Карта роботи з 1С через Уніку 0.16 поруч із kit — вхід через unica.view, поділ kit/Уніка, пастки платформи, діагностичний виклик MCP. Тригер — задача з 1С: метадані, форма, BSL, .epf/.cfe, v8project.yaml, «unica», «юніка».
---

# Unica — 1С-розробка через MCP

Плагін [IngvarConsulting/unica](https://github.com/IngvarConsulting/unica) дає агенту один
MCP-сервер `unica` і скіли `unica:<ім'я>`. Скіл — карта: що де лежить. Контракт кожного виклику
бери з скіла Уніки та з відповіді самого сервера, не з пам'яті й не з цього файла.

## Вхід

1. У теці проєкту 1С виклич `unica.view {}`: він називає воркспейс, набори вихідників (префікс
   набору — з відповіді, `main` не умовчання), їхній стан і `setup` для `v8project.yaml`.
   Якщо потрібної теки в відповіді немає — скіл `v8storagekit:unica-folders`.
2. Далі веде скіл `unica:unica-dev`: пошук (`unica.search`), читання вузла за логічною адресою
   (`unica.view`), операції вузла (`can`), зміна двома кроками (`unica.apply`: план, потім
   виконання з `executionToken`), перевірка (`unica.check`), довідка (`unica.docs`), збірка й
   база (`unica.run {}` віддає словник операцій). Перегляд адрес і сторінок — `unica:source-access`.
3. Предметні скіли: BSL — `unica:code-patch`, `unica:code-search`, `unica:code-diagnostics`,
   `unica:code-review`; метадані — `unica:meta-add`, `unica:meta-edit`, `unica:meta-info`; форми —
   `unica:form-edit`, `unica:form-events`; розширення — `unica:cfe-init`, `unica:cfe-borrow`,
   `unica:cfe-diff`, `unica:cfe-patch-method`; решту добирай за описом у списку скілів.

Результат без `cursor` у відповіді повний; з `cursor` — це сторінка, продовжуй з тими самими
адресою й `limit` (`unica:code-diagnostics`, `unica:source-access`). Порожня неповна видача не
доводить відсутності предмета.

## Поділ роботи kit і Уніки

Kit не викликає Уніку; Уніка не знає про сховища конфігурацій. Контракт і процедура звірки після
оновлення плагіна — `docs/unica-contract.md` у репозиторії плагіна.

| Що | Хто |
|---|---|
| Вихідники в git, редагування, перевірка, збірка `.cf`/`.cfe`/`.epf`/`.erf` | Уніка: `unica.apply`, `unica.check`, `unica.run` з `"op":"make"` |
| Наповнення бази агента, вирівнювання з деревом | Уніка: `unica.run` з `"op":"push"`; `force:true` завжди питає людину |
| Канон дерева з бази агента | Уніка: `unica.run` з `"op":"pull"` і `force:true` |
| Сховище конфігурації ↔ git (`sync`, `verify`), вивантаження з бази людини (`dump`), підключення бази агента (`provision`) | kit: `v8storagekit:sync`, `v8storagekit:verify`, `v8storagekit:dump`, `v8storagekit:provision` |

Правила контуру й маршрутизація за наміром — `v8storagekit:using-v8storagekit`. Мутуючі виклики
Уніки (`unica.apply`, `unica.run`) — лише коли це входить у доручення людини; `dryRun:true`
(план) — першим.

## Куди дивитись

| Питання | Файл |
|---|---|
| `v8project.yaml`, `v8project.local.yaml`, `.gitignore`, вивантаження Конфігуратором | `references/project-contour.md` |
| Пастки платформи 1С і YaXUnit, виміряні на практиці | `references/platform-traps.md` |
| Доопрацювання форм у розширенні без запозичення форми | `references/extension-forms.md` |
| Службовий користувач ІБ із розширення (БСП) | `v8storagekit:1c-bsp-service-user` |
| WebSocket-клієнт у розширенні | `v8storagekit:1c-websocket-client` |
| Тексти кількома мовами | `v8storagekit:1c-localization` |

Джерело правди про 0.16 — кеш плагіна Уніки (`<тека конфігурації Claude>/plugins/cache/unica/unica/<версія>`):
`skills/<ім'я>/SKILL.md` і `references/tooling/v8project.md`.

## Виклик MCP поза сесією

MCP-сервер піднімається на старті сесії. Щоб подивитись інструменти без перезапуску (діагностика,
перевірка після оновлення) — `scripts/unica-call.ps1` (PowerShell 7). Він бере найбільшу версію
плагіна в кеші й запускає команду з її `.mcp.json`:

```powershell
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/skills/unica-1c/scripts/unica-call.ps1" --tools
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/skills/unica-1c/scripts/unica-call.ps1" --schema unica.view
```

Коди виходу: 0 успіх, 1 помилка сервера, 64 невірне використання, 66 каталог плагіна не знайдено.
Надійно працюють лише `--tools` і `--schema`: робочі виклики вимагають контексту хоста сесії.
Мутуючі інструменти цим скриптом не кликати.

## Правила, які легко порушити

- **Ліцензія 1С**: якщо у виводі `лиценз`/`license`/`HASP` — зупинись і скажи людині. Не чіпай
  служби, реєстр, `nethasp.ini`, файли ліцензій.
- **Credentials**: невідомі — питай людину; зондувати базу, щоб їх вгадати, не можна. Пароль у
  `v8project.yaml` не писати; він живе в `v8project.local.yaml`, який не комітять.
- Перед вивантаженням — `git status --short`, щоб не змішати чужі правки з вивантаженням.
- Якщо `src/` не порожній — не наповнюй базу автоматично: спитай, що джерело правди, база чи git.
- Відмову `non_fast_forward` чи `untracked_base` Уніки на `push` не обходь `force:true` сам:
  вибір між `pull` бази й перезаписом бази — за людиною.
- `epf-init`/`erf-init` вимагають глобальний `format: DESIGNER` (або без нього); при `EDT` — зупинись.
- Скіли цього плагіна — з префіксом `v8storagekit:`, скіли Уніки — `unica:`; голе ім'я дає
  `Unknown skill`.
