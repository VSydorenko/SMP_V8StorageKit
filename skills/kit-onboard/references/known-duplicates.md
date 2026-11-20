<!-- Ported from agent-kit 0.9.1 skills/kit-onboard/references/known-duplicates.md, modified. -->
# Відомі залишки й прототипи

Те, що трапляється в 1С-проєктах, які вели процес через superpowers і власні ручні адаптації, до підключення (`kit-scan`). `kit-scan` знає ці шляхи; схожі файли знаходить за назвою й вмістом. Переліки доповнюють за живими проєктами; рядок скану — не вирок (див. скіл).

## Скіли superpowers → скіли v8storagekit

| Залишок | Заміна в kit | Звичайний клас |
| --- | --- | --- |
| `superpowers:brainstorming` у `CLAUDE.md`, проєктних командах, пам'яті | `v8storagekit:discuss` (спека — `v8storagekit:spec`) | replace |
| `superpowers:writing-plans` | `v8storagekit:plan` | replace |
| `superpowers:subagent-driven-development`, `superpowers:executing-plans` | `v8storagekit:execute` (журнал — `sdd`) | replace |
| `superpowers:requesting-code-review`, `superpowers:receiving-code-review` | `v8storagekit:landed-review`, агенти `v8storagekit:task-reviewer`, `v8storagekit:code-reviewer` | replace |
| `superpowers:finishing-a-development-branch` | `v8storagekit:finish` (репо з `v8storagekit.yaml`) або `pr-gate` | replace |
| `superpowers:using-git-worktrees` | режим `workspace.mode` профілю (ADR-0005): у 1С `shared`, без worktree | replace |
| `superpowers:verification-before-completion` | правило kit: без «готово» без виводу команди, виконаної цього ходу | replace |
| `superpowers:test-driven-development` | <!-- tests: ADR-0004, pending owner discussion --> тести — мінімум, лише на логіку й механізми, що справді треба перевіряти; форму називає бриф задачі | replace / remove за рішенням власника |
| `superpowers:systematic-debugging`, `superpowers:dispatching-parallel-agents` | частини kit немає за рішенням власника | remove |
| `superpowers:using-superpowers`, `superpowers:writing-skills` | без заміни в проєкті | remove |

## Файли superpowers у проєкті

| Залишок | Заміна в kit | Звичайний клас |
| --- | --- | --- |
| `docs/superpowers/specs/*` | спеки в `docs.specs` профілю; формат — `v8storagekit:spec` | keep (жива спека), перенести за потреби |
| `docs/superpowers/plans/*` | плани в `docs.plans`; формат — `v8storagekit:plan` | keep (жива) / delete через `v8storagekit:close-block` (завершена) |
| `docs/superpowers/handoff/*` | жива передача між сесіями; після прийняття — `close-block` | keep, потім delete |
| `.superpowers/sdd/<блок>/` (журнали: `progress.md`, `HANDOFF.md`) | журнали kit — `.agents/sdd/<блок>/`; старі читаються на місці, не переносяться | read-in-place; `close-block` прибирає |

## Ручні адаптації в пам'яті → що kit робить сам

| Залишок у пам'яті | Що замінює | Звичайний клас |
| --- | --- | --- |
| адаптація SDD «без worktree, без паралельних виконавців, що самі білдять/тестують» | `v8storagekit:execute`, режим `shared` (ADR-0005) | pointer |
| «субагенти не комітять — комітить контролер» | правило `v8storagekit:execute` і текст агента `v8storagekit:implementer` | pointer; специфіка дозволів класифікатора — keep |
| «коміти точково: `git add <перелік>` + `git commit --only`; без stash/reset/`checkout --`» | правило режиму `shared` у `execute` і тексті агентів | pointer |
| журнал виконання блоку (шлях, формат) | `sdd` і `.agents/sdd/<блок>/` | pointer |
| прогін тестів «лише зачеплене, повний раз у фіналі» (`kit-scan` ловить за ознаками `лише зачеплене`, `повний набір`, `повний прогін` — регулярний вираз, можливі хибні збіги: читай файл) | <!-- tests: ADR-0004, pending owner discussion --> форму називає бриф задачі | keep до рішення власника |
| пам'ять про стиль відповідей (українська мова, терміни) | правила сесії з хука kit | delete |
| пам'ять про ролі сесій (архітектор / виконавець), стан блоку | `v8storagekit:architect`, файл стану, `track` | pointer (ролі) / keep-as-history (стан закритого блоку) |

## Залишки ручного рев'ю й команд

| Проєктний файл | Заміна в kit | Звичайний клас |
| --- | --- | --- |
| `.claude/commands/*` з процедурою обговорення, дослідження, виконання плану, рев'ю роботи агента, архівування задач, ревізії пам'яті | скіли `discuss`, `research`, `execute`, `landed-review`, `close-block`, `kit-onboard` | remove |
| проєктні агенти й скіли рев'ю коду (`.claude/agents/code-review*.md`, `.agents/skills/code-review/`) | скіл `landed-review`, агенти `code-reviewer`, `code-review-verifier` | keep-knowledge: предметні критерії → файл, названий полем `review.criteria`; процедуру прибрати |
| проєктна копія пошуку по коду чи дослідника | Уніка (`unica.search`, `unica.view`) і агент `researcher` | remove |
| `superpowers:*` у `CLAUDE.md` / проєктних командах | таблиця «Скіли superpowers» вище | replace |
| кореневе правило «commit or push only when the owner asks» | рядок брифу архітектора `Push:` + `pr-gate` | replace: «Агенти комітять у гілках блоків, як кажуть задачі плану, і пушать їх через `pr-gate open -Draft`, коли каже бриф архітектора; ніколи force, ніколи main чи база. Зливає архітектор, коли перевірку пройдено.» — текст адаптує проєкт, схвалює власник |

## Підключення контуру сховища

Не залишок і не крок цього скіла: контур «сховище ↔ git» підключає `v8storagekit:onboarding`.

Частину kit, якої ще нема (`kit-scan` позначає її «planned»), не видаляй у проєкті: познач рядок `keep` з issue, що її замінить. Виняток — planned лише одна з альтернатив заміни, а інша вже є (рядок `superpowers:finishing-a-development-branch`: `v8storagekit:finish` є, `pr-gate` planned): тоді **replace** наявною.
