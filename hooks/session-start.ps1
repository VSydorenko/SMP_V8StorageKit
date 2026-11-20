#Requires -Version 7
<#
.SYNOPSIS
    Хук SessionStart плагіна v8storagekit (hooks/hooks.json): «Стан сховищ» і вказівка на скіл
    using-v8storagekit на старті сесії в репозиторії під kit. Текст скіла хук не вклеює.
.DESCRIPTION
    Логіки тут немає: знайти v8storagekit.yaml, викликати kit.ps1 session-check і надрукувати
    контекст для сесії. Нічого не змінює: рішення — людині, дія — скіл v8storagekit:sync.
    Блок правил спілкування власника (hooks/communication-rules.md) і рядок оновлення проєкту
    перенесено з agent-kit 0.9.1 hooks/session-rules.mjs (modified); читаються лише файли,
    без git, gh і мережі.

    ХУК СПРАЦЬОВУЄ В КОЖНІЙ СЕСІЇ МАШИНИ, зокрема в проєктах не про 1С. Тому критерій —
    маніфест АБО профіль процесу: v8storagekit.yaml шукається в теці проєкту сесії
    (CLAUDE_PROJECT_DIR) і в її предках; профіль — <корінь git>/.agents/kit.profile.json
    (корінь git — перша тека вгору від проєкту з .git, текою чи файлом). Ні маніфесту, ні
    профілю (або змінної немає) — нічого не друкується, код 0. Це перший і найдешевший
    крок: у не-1С проєкті хук не робить нічого, крім обходу предків і виходу.
    - маніфест у самій теці проєкту — контекст «Стан сховищ» і наприкінці блок правил;
    - маніфест лише в предку — те саме з -RepoRoot <предок> плюс попередження: Уніка
      бачитиме лише теку сесії, а воркспейси лежать у корені репозиторію (§3.3 п.5);
    - лише профіль — контекст із самого блоку правил і рядка оновлення; session-check не
      запускається. Профіль, що не читається (не JSON або kit.version не x.y.z), без
      маніфесту дає тишу, а з маніфестом — звичайний контекст без рядка оновлення.

    Гарантія «мовчки й код 0 завжди» — СТРУКТУРНА, не перелік місць, де щось може впасти:
    усе тіло — під зовнішнім try/catch/finally{exit 0}.
    Збій у не-1С проєкті не сміє ні друкувати, ні давати код, відмінний від 0.

    Матчери (hooks.json): startup|clear|compact. Вони лишають сесію без раніше доданого
    контексту (нова сесія або стиснена історія), тож хук мусить дати його знову. resume і fork
    успадковують транскрипт, у якому «Стан сховищ» уже є: другий екземпляр — шум без користі.
    Ціна рішення: після resume стан сховищ у контексті застарілий; свіжий — скіл
    v8storagekit:sync або kit session-check.

    Корінь плагіна — з $PSScriptRoot (скрипт лежить у самому плагіні), реєстру плагінів
    хук не читає.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Кодування — best-effort і ізольовано від решти: без прикріпленої консолі сеттер на Windows
# може кинути "The handle is invalid"; провал тут не сміє скасувати друк реального контексту.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Find-KitManifestDir {
    # Тека проєкту й предки — до першої з v8storagekit.yaml. Не знайдено — $null.
    param([string]$Start)
    $dir = $Start
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir 'v8storagekit.yaml') -PathType Leaf) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $null
}

function Find-GitRoot {
    # Тека проєкту й предки — до першої, де є .git (тека або файл — worktree). Без запуску git.
    param([string]$Start)
    $dir = $Start
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $null
}

function Get-RulesBlock {
    # Правила без провідного HTML-коментаря, обрізані. Файла немає — ''.
    param([string]$Plugin)
    $file = Join-Path $Plugin 'hooks/communication-rules.md'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $text = [regex]::Replace($text, '\A\s*<!--.*?-->', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $text.Trim()
}

function Get-UpgradeHint {
    # Аналог upgradeHint з agent-kit: проєкт відстав від плагіна — один рядок із числом кроків.
    # Розбір журналу мінімальний: лише те, що треба для числа. Нема що казати — ''.
    param([string]$Plugin, [string]$GitRoot, [string]$ProjectVersion)
    $pluginJson = Join-Path $Plugin '.claude-plugin/plugin.json'
    if (-not (Test-Path -LiteralPath $pluginJson -PathType Leaf)) { return '' }
    $meta = Get-Content -LiteralPath $pluginJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $pluginVersion = [string]$meta.version
    if ($pluginVersion -notmatch '^\d+\.\d+\.\d+$') { return '' }
    # Корінь git проєкту — сам цей плагін: оновлювати нічого.
    $rootJson = Join-Path $GitRoot '.claude-plugin/plugin.json'
    if (Test-Path -LiteralPath $rootJson -PathType Leaf) {
        try { if ((Get-Content -LiteralPath $rootJson -Raw -Encoding UTF8 | ConvertFrom-Json).name -eq $meta.name) { return '' } } catch { }
    }
    $changelog = Join-Path $Plugin 'CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $changelog -PathType Leaf)) { return '' }
    $from = [version]$ProjectVersion
    $to = [version]$pluginVersion
    if ($from -ge $to) { return '' }
    $steps = 0
    $inRange = $false
    $inChecklist = $false
    foreach ($line in (Get-Content -LiteralPath $changelog -Encoding UTF8)) {
        if ($line -match '^##\s+(\d+\.\d+\.\d+)\b') {
            $v = [version]$Matches[1]
            $inRange = ($v -gt $from -and $v -le $to)
            $inChecklist = $false
        } elseif ($line -match '^#{1,3}\s') {
            $inChecklist = $inRange -and ($line -match '^###\s+Чекліст оновлення проєкту')
        } elseif ($inChecklist -and $line -match '^- \[[ xX]\] ') {
            $steps++
        }
    }
    "v8storagekit: проєкт на $ProjectVersion, плагін $pluginVersion; кроків оновлення: $steps — власник запускає онбординг процесу."
}

# Єдиний рубіж гарантії: усе між сюди й друком JSON — під одним try/catch/finally{exit 0}.
try {
    $plugin = Split-Path -Parent $PSScriptRoot
    $project = $env:CLAUDE_PROJECT_DIR
    $repo = $null
    $gitRoot = $null
    if ($project -and (Test-Path -LiteralPath $project -PathType Container)) {
        $project = (Resolve-Path -LiteralPath $project).ProviderPath
        if (Test-Path -LiteralPath (Join-Path $plugin 'tools/kit.ps1') -PathType Leaf) {
            $repo = Find-KitManifestDir -Start $project
        }
        $gitRoot = Find-GitRoot -Start $project
    }

    # Профіль процесу: none — файла немає; ok — читається; bad — не JSON або kit.version не x.y.z.
    $profileState = 'none'
    $projectVersion = '0.1.0'
    if ($gitRoot) {
        $profileFile = Join-Path $gitRoot '.agents/kit.profile.json'
        if (Test-Path -LiteralPath $profileFile -PathType Leaf) {
            $profileState = 'ok'
            try {
                $prof = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $kitProp = if ($prof -and $prof.PSObject.Properties['kit']) { $prof.kit } else { $null }
                $verProp = if ($kitProp -and $kitProp.PSObject.Properties['version']) { $kitProp.version } else { $null }
                if ($null -ne $verProp) {
                    if (([string]$verProp) -match '^\d+\.\d+\.\d+$') { $projectVersion = [string]$verProp } else { $profileState = 'bad' }
                }
            } catch { $profileState = 'bad' }
        }
    }

    # Блок правил і рядок оновлення; збій тут не сміє скасувати друк решти.
    $rulesBlock = ''
    if ($repo -or $profileState -eq 'ok') {
        try {
            $rules = Get-RulesBlock -Plugin $plugin
            $hint = ''
            if ($profileState -eq 'ok') { try { $hint = Get-UpgradeHint -Plugin $plugin -GitRoot $gitRoot -ProjectVersion $projectVersion } catch { } }
            $rulesBlock = (@($rules, $hint) | Where-Object { $_ }) -join "`n`n"
        } catch { }
    }

    if (-not $repo -and $profileState -eq 'ok' -and $rulesBlock) {
        $context = "<v8storagekit>`n$rulesBlock`n</v8storagekit>"
        [ordered]@{
            hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context }
        } | ConvertTo-Json -Depth 4 -Compress
    }
    if ($repo) {
        $context = ''
        try {
            # Стеля часу — обов'язкова: цей код виконується на старті КОЖНОЇ сесії в репозиторії під kit,
            # а session-check обходить data/objects (часто SMB) і викликає повний check. Перевищення
            # показуємо рядком, не мовчанням: мовчання читалось би як «нових версій немає».
            # Стеля — через змінну оточення, а не через накладку: хук за конструкцією не читає YAML.
            $timeoutSec = 15
            $parsedTimeout = 0
            if ($env:V8KIT_SESSION_CHECK_TIMEOUT -and [int]::TryParse($env:V8KIT_SESSION_CHECK_TIMEOUT, [ref]$parsedTimeout) -and $parsedTimeout -ge 1 -and $parsedTimeout -le 600) {
                $timeoutSec = $parsedTimeout
            }
            $status = ''
            $outFile = $null
            $errFile = $null
            try {
                # Обидва тимчасові файли — всередині try: якщо другий GetTempFileName() кине,
                # finally все одно прибере вже створений перший.
                $outFile = [System.IO.Path]::GetTempFileName()
                $errFile = [System.IO.Path]::GetTempFileName()
                # Вивід — у ФАЙЛИ, не в пайп: пайп без асинхронного читання дає дедлок на великому виводі.
                # Список аргументів закритий: -Apply хук не передає ніколи — session-check нічого не змінює.
                $proc = Start-Process -FilePath 'pwsh' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                    -ArgumentList @('-NoProfile', '-File', (Join-Path $plugin 'tools/kit.ps1'), 'session-check', '-RepoRoot', $repo)
                if ($proc.WaitForExit($timeoutSec * 1000)) {
                    $raw = (((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) + (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8)) | Out-String).Trim()
                    # Коди за змістом (§5): 0 — тиша, 3 — є сигнал, 1 — репозиторій суперечливий (сигнали не
                    # обчислювались; вивід сам каже чому й що робити: «спершу kit check») — друкуються як є,
                    # але лише коли вивід непорожній. Код 0 з порожнім виводом — штатна тиша. Код 1/3 з порожнім
                    # виводом і БУДЬ-ЯКИЙ інший код — мовчати не можна (порожній $raw читався б як «нових версій немає»).
                    $status = if ($proc.ExitCode -eq 0 -or ($proc.ExitCode -in 1, 3 -and $raw)) {
                        $raw
                    } elseif ($proc.ExitCode -in 1, 3) {
                        "УВАГА: kit session-check завершився кодом $($proc.ExitCode) без жодного виводу — стан сховищ НЕВІДОМИЙ, не «без змін». Перевірити вручну: kit.ps1 session-check -RepoRoot ."
                    } else {
                        "УВАГА: kit session-check завершився неочікуваним кодом $($proc.ExitCode) (очікувалось 0, 1 або 3) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:`n$raw"
                    }
                } else {
                    # Убивати процес дозволено рівно тому, що session-check нічого не мутує.
                    try { $proc.Kill($true) } catch { }
                    $status = "УВАГА: kit session-check не вклався в $timeoutSec с — стан сховищ НЕВІДОМИЙ, не «без змін». Найчастіша причина — повільний доступ до сховища (SMB); перевірити вручну: kit.ps1 session-check -RepoRoot ."
                    # Те, що kit устиг надрукувати, не пропадає. Позначка «частково» обов'язкова: без неї
                    # обрізаний вивід читався б як повний.
                    $partial = ''
                    try { $partial = ((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) | Out-String).Trim() } catch { }
                    if ($partial) { $status = "$status`n`nЧастково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):`n$partial" }
                }
            } finally {
                if ($outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
                if ($errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
            }

            $warning = ''
            if ($repo -ne $project) {
                $warning = "УВАГА: сесію відкрито в $project, а корінь репозиторію kit — $repo. Уніка бачитиме лише цей воркспейс, а не весь репозиторій; відкрийте сесію в корені репозиторію.`n`n"
            }
            # Порядок: попередження → стан → вказівка на скіл → правила спілкування. Вступ НЕ вклеюється:
            # Claude Code велику частину виводу хука показує агентові лише прев'ю, тож найважливіше (стан)
            # стоїть першим, а правила контуру агент бере зі скіла, який йому тут названо.
            $pointer = "Репозиторій під kit. Правила контуру — скіл ``v8storagekit:using-v8storagekit``: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем."
            $tail = if ($rulesBlock) { "`n`n$rulesBlock" } else { '' }
            $context = "<v8storagekit>`n$warning## Стан сховищ (kit session-check)`n`n$status`n`n$pointer$tail`n</v8storagekit>"
        } catch {
            $context = "<v8storagekit>`nХук v8storagekit не зміг зібрати стан: $($_.Exception.Message)`n</v8storagekit>"
        }

        [ordered]@{
            hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context }
        } | ConvertTo-Json -Depth 4 -Compress
    }
} catch {
    # Неврахований збій не сміє друкувати нічого: з погляду виклику він виглядає як «тут нічого показувати».
} finally {
    exit 0
}
