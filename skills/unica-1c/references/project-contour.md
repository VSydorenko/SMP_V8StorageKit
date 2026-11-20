# Робочий контур проєкту

Контракт `v8project.yaml` — `references/tooling/v8project.md` у кеші плагіна Уніки (джерело
правди); тут лише те, що потрібне агентові під руку.

## Що не потрапляє в git

- `.build/` — робочий кеш Уніки й раннера (`.build/v8-runner`, `.build/unica`). Пиши в
  `.gitignore` **без** провідного слеша, щоб ловило в кожному воркспейсі репозиторію.
- `ConfigDumpInfo.xml` з коренем `<ConfigDumpInfo>` — службовий файл платформи, локальний стан
  конкретної ІБ. Не комітити й не вважати ознакою формату вихідників. (Виняток: справжній
  дескриптор об'єкта, який реально називається `ConfigDumpInfo`, — вихідник.)
- `build/` (`workPath`, якщо заданий) і `v8project.local.yaml`.

## Два файли

`v8project.yaml` — спільний, у git: формат і набори вихідників.

```yaml
format: DESIGNER
source-set:
  - name: main
    type: CONFIGURATION          # CONFIGURATION | EXTENSION | EXTERNAL_DATA_PROCESSORS | EXTERNAL_REPORTS
    path: 'src'
```

`v8project.local.yaml` — машинний, не в git: база й локальні перевизначення (`workPath`,
`providers`, `tools`, `tests`, `mcp`; не `source-set` і не `format`).

```yaml
infobases:
  origin:
    connection: 'File=build/ib'   # серверна: 'Srvr="srv01";Ref="dev";'
```

Блок `infobases` у спільному `v8project.yaml` раннер відхиляє. Відносні шляхи розв'язуються від
каталогу головного конфіга. Файл заводить людина чи агент своїми засобами: інструмента створення
`v8project.yaml` у Уніці немає; вміст бери з `setup` у відповіді `unica.view {}`, потім
`unica.check {}` скаже про готовність. Воркспейс — найближча тека з `v8project.yaml` вгору від
`cwd`; роби `cwd` вузьким (тека з 1С-вихідниками, не корінь змішаного репозиторію).

Дерево лише з зовнішніх обробок теж оформлюється своїм `v8project.yaml` із типом
`EXTERNAL_DATA_PROCESSORS`; збірку `.epf` описує `unica.run` з `"op":"make"` (набір з рівно одним
зовнішнім об'єктом і оголошена основна конфігурація воркспейсу).

## Вивантаження конфігурації Конфігуратором

Для бази людини (kit: `v8storagekit:dump`) або коли потрібен дамп напряму:

```powershell
& "C:\Program Files\1cv8\<версія 8.3.27.x>\bin\1cv8.exe" DESIGNER `
  /IBConnectionString "Srvr=""<сервер>"";Ref=""MY_DEV"";" /N "<користувач>" /P "<пароль>" `
  /DumpConfigToFiles "<repo>\src" `
  /DisableStartupDialogs /Out "<repo>\.build\dump.log"
```

- розширення: `-Extension <Ім'я>` або `-AllExtensions`;
- інкрементально (швидше): `-update -force`; потребує `ConfigDumpInfo.xml` у каталозі
  вивантаження — він локальний, не в git;
- без Конфігуратора: `ibcmd infobase config export <каталог>` (каталог — позиційний аргумент;
  ключі підключення підбирай, запускаючи команду: вона називає, чого бракує).

Правила запуску `1cv8.exe` (`Start-Process`, лапки, кирилиця) і безпечний вибір бази —
`references/infobases.md`.

Платформу бери ту саму лінію, що й для дерева (8.3.27.x): різні платформи пишуть різний формат
`Configuration.xml`.
