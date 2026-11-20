#Requires -Version 7
<#
.SYNOPSIS
    Хук SessionStart плагіна v8storagekit (hooks/hooks.json): «Стан сховищ» і вказівка на скіл
    using-v8storagekit на старті сесії в репозиторії під kit. Текст скіла хук не вклеює.
.DESCRIPTION
    Логіки тут немає: знайти v8storagekit.yaml, викликати kit.ps1 session-check і надрукувати
    контекст для сесії. Нічого не змінює: рішення — людині, дія — скіл v8storagekit:sync.

    ХУК СПРАЦЬОВУЄ В КОЖНІЙ СЕСІЇ МАШИНИ, зокрема в проєктах не про 1С. Тому критерій —
    маніфест: v8storagekit.yaml шукається в теці проєкту сесії (CLAUDE_PROJECT_DIR) і в її
    предках. Не знайдено (або змінної немає) — нічого не друкується, код 0. Це перший і
    найдешевший крок: у не-1С проєкті хук не робить нічого, крім обходу предків і виходу.
    - маніфест у самій теці проєкту — контекст «Стан сховищ»;
    - маніфест лише в предку — те саме з -RepoRoot <предок> плюс попередження: Уніка
      бачитиме лише теку сесії, а воркспейси лежать у корені репозиторію (§3.3 п.5).

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

# Єдиний рубіж гарантії: усе між сюди й друком JSON — під одним try/catch/finally{exit 0}.
try {
    $plugin = Split-Path -Parent $PSScriptRoot
    $project = $env:CLAUDE_PROJECT_DIR
    $repo = $null
    if ($project -and (Test-Path -LiteralPath $project -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $plugin 'tools/kit.ps1') -PathType Leaf)) {
        $project = (Resolve-Path -LiteralPath $project).ProviderPath
        $repo = Find-KitManifestDir -Start $project
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
                    # Коди за змістом (§5): 0 — тиша, 3 — є сигнал — друкуються як є;
                    # БУДЬ-ЯКИЙ інший код — мовчати не можна (порожній $raw читався б як «нових версій немає»).
                    $status = if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3) {
                        $raw
                    } else {
                        "УВАГА: kit session-check завершився неочікуваним кодом $($proc.ExitCode) (очікувалось 0 або 3) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:`n$raw"
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
            # Порядок: попередження → стан → вказівка на скіл. Вступ НЕ вклеюється: Claude Code велику
            # частину виводу хука показує агентові лише прев'ю, тож найважливіше (стан) стоїть першим,
            # а правила контуру агент бере зі скіла, який йому тут названо.
            $pointer = "Репозиторій під kit. Правила контуру — скіл ``v8storagekit:using-v8storagekit``: завантаж його перед першою командою kit, кроком Уніки над базою агента чи роботою зі сховищем."
            $context = "<v8storagekit>`n$warning## Стан сховищ (kit session-check)`n`n$status`n`n$pointer`n</v8storagekit>"
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
