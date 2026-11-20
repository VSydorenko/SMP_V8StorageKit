# Пілот kit 1.6.0 під Unica 0.16 — журнал тестера tehnokrat_unf

Бриф — повідомлення архітектора (сесія `unica-016-adaptation`) від 2026-11-20; основний журнал і пункти пілоту —
`2026-11-20-unica-016-pilot.md` (споживач BankExchange). Тут — лише споживач `R:\github\tehnokrat_unf`.

- Споживач: `tehnokrat_unf`, `kitVersion: 1.4.0`, гілка `main` чиста (`4bae2d94b`), Windows Server 2022.
- Джерела: `base` (УНФ на підтримці вендора, `truth: storage`, з поставкою) і `ТК_Адаптация` (`truth: storage`).
- База агента — серверна `tehnokrat_unf_sydorenko_claude` (накладка `tehnokrat/v8project.local.yaml`).
- Плагін: `v8storagekit@smp-v8storagekit-016` 1.6.0 (знімок `44dfd9a`); спека — коміт `25a6143`.
- Сесія тестера: `tehnokrat_unf_pilot`.

## Журнал

### 2026-11-20 — п.1. Хук старту в корені репо

**Умова.** Нова сесія Claude Code, cwd `R:\github\tehnokrat_unf`, репо ще у форматі 1.4.0 (`v8project.yaml` з `infobase:`,
без `providers`), плагін 1.6.0.

**Виклик.** Хук `SessionStart` плагіна (автоматично, без дій тестера).

**Сирий вивід.** Перше повідомлення сесії містить два блоки `<v8storagekit>`:

1. Блок «Стан сховищ» — **інлайн, без `<persisted-output>`**:

```
## Стан сховищ (kit session-check)

УВАГА: kit session-check завершився неочікуваним кодом 1 (очікувалось 0 або 3) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:
session-check — client Tehnokrat
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.yaml: стара форма 'infobase:' — kit читає базу агента лише з infobases.origin у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml і приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.6.0»).
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.yaml: немає providers — запис і завантаження бази агента мусить робити один виконавець (інваріант C1; дефект раннера #459). Додайте: providers: { push: designer, pull: designer, download: designer }.
[-] R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml: стара форма 'infobase:' — kit читає базу агента лише з infobases.origin у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у R:\github\tehnokrat_unf\tehnokrat\v8project.local.yaml і приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.6.0»).
Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.

Репозиторій під kit. Правила контуру — скіл `v8storagekit:using-v8storagekit`: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем.
```

2. Окремий блок — вступ `using-v8storagekit` (11.5KB) — **під `<persisted-output>`**, у контексті лише прев'ю перших ~2KB, решта —
   у файлі `tool-results/hook-…-SessionStart-…-additionalContext.txt`.

**Висновок (умова: репо 1.4.0, сесія в корені, Windows Server 2022).** «Стан сховищ» видно одразу, без читання файлу — пункт
виконано. Блок рівно один. Вміст стану — не сигнали, а три відмови формату 1.4.0 з вказівкою на `upgrades.md` «1.4.0 → 1.6.0»:
агент без зовнішніх знань бачить, куди йти. Зауваги:
- текст «неочікуваним кодом 1 (очікувалось 0 або 3) … НЕВІДОМИЙ … Зупинка» звучить як аварія, хоча причина — очікуваний
  незавершений перехід, і нижче вона названа точно; чи має session-check для «репо суперечливе» повертати окремий код — питання
  архітектору, не рішення тестера;
- вступ `using-v8storagekit` під `<persisted-output>` — агентові видно лише прев'ю (принципи й початок таблиці намірів), решта
  правил контуру — лише якщо він прочитає файл або завантажить скіл (сам блок прямо велить завантажити скіл).
