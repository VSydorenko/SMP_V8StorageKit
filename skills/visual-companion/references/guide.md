<!-- Ported from agent-kit 0.9.1 skills/visual-companion/references/guide.md, modified. Originally from superpowers 7.0.1 skills/brainstorming/visual-companion.md (MIT, (c) 2025 Jesse Vincent), modified for v8storagekit: trimmed to what drives the server. See ../LICENSE-superpowers. -->

# Посібник visual companion

## Зміст

1. Як це працює
2. Цикл
3. Фрагменти вмісту
4. CSS-класи
5. Події
6. Діагностика

## 1. Як це працює

Сервер стежить за `screen_dir` і віддає браузеру найновіший `.html`-файл. Файл, що починається з `<!DOCTYPE` або `<html>`, віддається як є (лише додається допоміжний скрипт). Усе інше — **фрагмент**: сервер обгортає його в рамку (заголовок, тема, статус зʼєднання, обробка кліків). За замовчуванням пиши фрагменти.

Кліки по варіантах потрапляють у `$STATE_DIR/events`, по одному JSON-обʼєкту на рядок. Файл очищується, коли ти публікуєш новий екран.

## 2. Цикл

1. **Перевір, що сервер живий**, перш ніж публікувати екран чи згадувати URL: `$STATE_DIR/server-info` існує, а `$STATE_DIR/server-stopped` — ні. Якщо сервер зупинився, запусти `start-server.ps1` знову з тим самим `-ProjectDir`: він повторно бере порт і ключ, відкрита вкладка перепідключається сама.
2. **Запиши новий файл** у `screen_dir` інструментом Write (не heredoc). Змістовні імена — `layout.html`, `layout-v2.html`. Імена не перевикористовуй.
3. **Заверши хід**: повтори URL, одним рядком скажи, що на екрані, попроси власника відповісти в терміналі (клік по варіанту необовʼязковий).
4. **Наступний хід**: прочитай `$STATE_DIR/events`, якщо файл є, і обʼєднай із текстом власника. Текст первинний; `choice` останньої події `click` зазвичай і є остаточним вибором.
5. **Ітеруй** новим файлом або йди далі. Коли наступний крок браузера не потребує, опублікуй екран очікування, щоб розв'язаний вибір не лишався на показі:

```html
<div style="display:flex;align-items:center;justify-content:center;min-height:60vh">
  <p class="subtitle">Продовжуємо в терміналі…</p>
</div>
```

## 3. Фрагменти вмісту

```html
<h2>Який макет зручніший?</h2>
<p class="subtitle">Порівняйте читабельність і ієрархію</p>

<div class="options">
  <div class="option" data-choice="a" onclick="toggleSelect(this)">
    <div class="letter">A</div>
    <div class="content"><h3>Одна колонка</h3><p>Фокус на тексті</p></div>
  </div>
  <div class="option" data-choice="b" onclick="toggleSelect(this)">
    <div class="letter">B</div>
    <div class="content"><h3>Дві колонки</h3><p>Навігація збоку</p></div>
  </div>
</div>
```

`<html>`, CSS чи `<script>` не потрібні. Питання клади на сторінку; 2–4 варіанти на екран.

## 4. CSS-класи

| Клас | Призначення |
|---|---|
| `.options` > `.option[data-choice]` з `.letter`, `.content` | вибір A/B/C; `data-multiselect` на `.options` — кілька виборів |
| `.cards` > `.card[data-choice]` з `.card-image`, `.card-body` | візуальні дизайни картками |
| `.mockup` > `.mockup-header`, `.mockup-body` | один макет у рамці |
| `.split` | два макети поруч |
| `.pros-cons` > `.pros`, `.cons` | колонки «за» і «проти» |
| `.mock-nav`, `.mock-sidebar`, `.mock-content`, `.mock-button`, `.mock-input`, `.placeholder` | блоки каркаса |
| `h2`, `h3`, `.subtitle`, `.section`, `.label` | заголовок, підзаголовок, другорядний текст, блок, мала позначка |

Кожен клікабельний елемент потребує `data-choice` і `onclick="toggleSelect(this)"`. Повний CSS — `scripts/frame-template.html`.

## 5. Події

```jsonl
{"type":"click","choice":"a","text":"Одна колонка","timestamp":1706000101}
{"type":"click","choice":"b","text":"Дві колонки","timestamp":1706000115}
```

Файлу подій немає — власник не клікав; спирайся лише на його текст.

## 6. Діагностика

| Симптом | Дія |
|---|---|
| Старт друкує `{"error": ...killed...}` | Процес прибрало середовище. Запусти з `-Foreground` у виклику Bash із `run_in_background: true`; наступного ходу прочитай `$STATE_DIR/server-info`. |
| Старт друкує `{"error": "Server failed to start within N seconds …"}` | Машина завантажена. Запусти знову з `$env:VC_START_TIMEOUT = '60'` перед скриптом. |
| Власник не відкриває URL (віддалене середовище чи контейнер) | Перезапусти з `-BindHost 0.0.0.0 -UrlHost <досяжний хост>`. |
| Загубився JSON зі старту | Прочитай `<проєкт>/.agents/out/companion/<сесія>/state/server-info`. |
| Браузер показує «stopped» | Сервер вичерпав час простою або сесія закінчилась. Запусти знову з тим самим `-ProjectDir`. |
