#Requires -Version 7
<#
.SYNOPSIS
    Прогін тестового набору tools/tests через Pester.
.DESCRIPTION
    За замовчуванням запускає все, включно з тестами під тегом Integration
    (New-ExtensionInfobase у V8.Tests.ps1), які реально запускають 1cv8.exe,
    створюють файлову інформаційну базу й завантажують у неї розширення — це вже
    не read-only операція. M8 фінального ревʼю: .claude/settings.json auto-allow
    (без запиту) дозволяє лише виклик із -ExcludeTag Integration, який лишається
    суто читанням; повний прогін (цей файл без параметрів, як у "Типових операціях"
    CLAUDE.md) і надалі питає підтвердження.

    -Only <імена> звужує прогін до названих файлів тестів. TDD вимагає двох прогонів
    на задачу — у ЧЕРВОНІЙ фазі ("тест має впасти") достатньо того файлу, який щойно
    змінили, і саме тому -Only лишається однопроцесним і послідовним (див. нижче):
    у цій фазі простий вивід цінніший за секунди. Повний набір лишається обов'язковим
    ПЕРЕД комітом і після серії фіксів: звужений прогін не бачить регресій у сусідніх
    файлах, а саме їх тут ловили найчастіше (вимір блоку C1, 2026-09-17: ≈52 хв із
    ≈97 хв стінного часу виконавців пішли на повні прогони, більшість — у червоній фазі).

    ДВІ ГІЛКИ ОРКЕСТРАЦІЇ (Task 2+3 "Швидкість набору тестів"):

    1. Гілка одного процесу — вмикається -Only або -Serial. Поводиться точно як завжди:
       один `Invoke-Pester` у цьому ж процесі, `Run.Exit = $true`, вивід `Detailed` і
       послідовний. Усі чотири наявні `It` у RunTests.Tests.ps1 перевіряють саме цю
       гілку — вона мусить лишатись сумісною дослівно, тому змінена тут лише всередині:
       перелік файлів тепер будує Resolve-KitTestFiles (tools/tests/lib/TestRunner.psm1)
       замість дубльованої інлайн-логіки, поведінка й повідомлення про помилки ті самі.

    2. Гілка паралельного прогону — усе інше, тобто типовий виклик без -Only/-Serial.
       Файли розкладаються по -Workers дочірніх процесах `pwsh` (Split-KitTestFiles),
       кожен виконує tools/tests/lib/Invoke-TestWorker.ps1 і лишає підсумок JSON.
       Код виходу ВОРКЕРА означає "воркер зламався" (не дійшов до кінця свого переліку
       й не записав підсумок як слід), а НЕ "у нього впав тест" — впалі тести й так
       видно через FailedCount підсумку. Без цього розділення Get-KitRunVerdict не міг
       би відрізнити мертвий воркер (переліку немає, читати нема що) від звичайного
       червоного прогону (перелік є, у ньому просто впалі тести). Вердикт зводить
       Get-KitRunVerdict: зелено лише коли жоден воркер не вийшов з ненульовим кодом,
       кожен лишив підсумок, сума виконаних контейнерів дорівнює числу розданих файлів,
       тестів виконано більше нуля і жоден не впав.

       Вивід за замовчуванням — компактний: шапка (файли, воркери, логи, розклад по
       рядку на воркер), самі падіння з рядком відтворення, підсумок і вердикт. Причина
       та сама, що в §4 спеки про розмір файлів: сьогоднішній Detailed-вивід на весь
       набір — десятки тисяч токенів у кожному результаті інструмента агента. Повні логи
       воркерів лишаються файлами під build/test-run/; надрукувати їх дослівно (у порядку
       номера воркера, а всередині — у порядку роздачі файлів) можна прапорцем -FullLog.
.EXAMPLE
    pwsh tools/tests/Run-Tests.ps1                                       # усе, разом з Integration, паралельно
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration                # без запуску платформи, паралельно
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only Sync     # група Sync.*.Tests.ps1 (5 файлів), один процес
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only Sync,Verify
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Serial        # усе послідовно, для діагностики
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Workers 4     # паралельно, але з 4 воркерами
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -FullLog       # + дослівні логи воркерів
#>
[CmdletBinding()]
param(
    [string[]]$ExcludeTag = @(),
    # Ім'я файлу тестів із tools/tests — з розширенням чи без: 'Sync' і 'Sync.Tests.ps1'
    # рівноцінні. Шлях не приймається навмисно: прогін цього набору, не довільного файла.
    [string[]]$Only = @(),
    # Послідовно, в один процес, для діагностики — та сама гілка, що й -Only без імені.
    [switch]$Serial,
    # 0 = автоматично: Max(2, Min(8, ProcessorCount - 4)). Актуально лише для паралельної гілки.
    [int]$Workers = 0,
    # Друкує логи воркерів дослівно (у порядку номера воркера, всередині — у порядку роздачі).
    [switch]$FullLog
)

# Кирилиця в порівняннях доходить із дочірніх процесів лише при UTF-8: під кодовою
# сторінкою 866 (типовий запуск із Git Bash) тести Environment.Tests.ps1 падали на
# Should -Match із кириличним літералом, хоча код був справний. Це стосується і
# паралельної гілки: кожен воркер — це теж свіжий pwsh, і він виставляє те саме собі
# окремо (docs/follow-ups.md §18) — тут кодування потрібне для власного виводу цього
# процесу (шапка, підсумок, вердикт) і для гілки одного процесу.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module Pester -MinimumVersion 5.0
Import-Module "$PSScriptRoot/lib/TestRunner.psm1" -Force

# Розділення по комі власноруч — не примха, а єдиний спосіб, щоб задокументована форма
# запуску працювала. `pwsh -File <скрипт> -Only Sync,Verify` (саме її називає дозволеною
# CLAUDE.md) віддає «Sync,Verify» ОДНИМ рядком: прив'язку масиву робить парсер PowerShell,
# а через -File аргументи приходять уже розібраними оболонкою, і кома лишається всередині
# елемента. Наслідок був тихо-гучний: скрипт шукав файл «Sync,Verify.Tests.ps1» і падав із
# переліком доступних — тобто запобіжник нижче спрацьовував, але на рівному місці, і форма
# з CLAUDE.md не працювала жодного разу (виявлено виконавцем у сесії C2, 2026-09-17).
# Через -Command те саме працювало, бо там рядок розбирає парсер. Той самий ідіом воркер
# застосовує до себе окремо — він теж запускається через -File.
$Only       = @($Only       | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ExcludeTag = @($ExcludeTag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($Serial -or $Only.Count -gt 0) {
    # --- Гілка одного процесу: точно як завжди, лише резолвинг файлів через Task 1. -----
    # Неіснуючий файл — зупинка з переліком, а не мовчазний прогін нуля тестів: описка в
    # -Only інакше дала б "Tests Passed: 0, Failed: 0" і прочиталась би як успіх.
    $files = Resolve-KitTestFiles -Root $PSScriptRoot -Only $Only

    $config = New-PesterConfiguration
    $config.Run.Path         = @($files)
    $config.Output.Verbosity = 'Detailed'
    $config.Run.Exit         = $true
    if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
    Invoke-Pester -Configuration $config
    return
}

# --- Гілка паралельного прогону -----------------------------------------------------
Import-Module "$PSScriptRoot/../lib/PathSafety.psm1" -Force

$repoRoot    = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$buildRoot   = Join-Path $repoRoot 'build'
$testRunRoot = Join-Path $buildRoot 'test-run'

# Робоча тека перестворюється щоразу — build/ у .gitignore, спільне дерево не бруднимо.
Assert-SafeWorkPath -Path $testRunRoot -MustBeUnder $buildRoot -Description 'робоча тека паралельного прогону tools/tests'
if (Test-Path -LiteralPath $testRunRoot) { Remove-Item -LiteralPath $testRunRoot -Recurse -Force }
New-Item -ItemType Directory -Path $testRunRoot -Force | Out-Null

$workerCount = if ($Workers -gt 0) { $Workers } else { [Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount - 4)) }

# Таблиця тривалостей — дві частини: засівна (закомічена, для свіжого клону) і виміряна
# (build/, перекриває засівну за тим самим ключем). Відсутність будь-якої — не помилка.
$measuredPath = Join-Path $buildRoot 'test-durations.json'
$seedPath     = Join-Path $PSScriptRoot 'test-durations.seed.json'
$durations    = Read-KitTestDurations -MeasuredPath $measuredPath -SeedPath $seedPath

$files   = Resolve-KitTestFiles -Root $PSScriptRoot -Only @()
$buckets = Split-KitTestFiles -Files $files -Durations $durations -Workers $workerCount

# --- Шапка: файли, воркери, логи, і сам розклад (Task 4 звіряє за ним, що жоден файл --
# не загубився дорогою до воркера — формат "воркер <N>: <файли через кому>" не косметика).
Write-Host "Файлів: $($files.Count), воркерів: $($buckets.Count), логи: $testRunRoot"
foreach ($bucket in $buckets) {
    $names = ($bucket.Files | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '
    Write-Host "воркер $($bucket.Index): $names"
}

$excludeArg = if ($ExcludeTag) { $ExcludeTag -join ',' } else { $null }
$workerScript = "$PSScriptRoot/lib/Invoke-TestWorker.ps1"

# Причини, яких не бачить Get-KitRunVerdict (він не знає про сам факт запуску процесу чи
# про читаність JSON) — збираються тут і йдуть у підсумковий вердикт поруч із його
# причинами. Без цього невдалий Start-Process чи пошкоджений підсумок або впали б сирим
# стеком (мета «зелено неможливе помилково, і причина названа» цього не переживе), або
# затерлись би загальною фразою «хтось не лишив підсумку», яка не називає, який саме файл
# і чому непридатний.
$launchErrors = [System.Collections.Generic.List[string]]::new()

$workerProcs = @(foreach ($bucket in $buckets) {
    $fileListPath = Join-Path $testRunRoot "worker-$($bucket.Index).files.txt"
    $summaryPath  = Join-Path $testRunRoot "worker-$($bucket.Index).summary.json"
    $stdoutPath   = Join-Path $testRunRoot "worker-$($bucket.Index).stdout.log"
    $stderrPath   = Join-Path $testRunRoot "worker-$($bucket.Index).stderr.log"

    Set-Content -LiteralPath $fileListPath -Value $bucket.Files -Encoding utf8NoBOM

    $argumentList = @('-NoProfile', '-File', $workerScript, '-FileListPath', $fileListPath, '-SummaryPath', $summaryPath)
    if ($excludeArg) { $argumentList += @('-ExcludeTag', $excludeArg) }

    $process = $null
    try {
        # Різні файли для stdout і stderr — один файл на два потоки Start-Process не приймає.
        $process = Start-Process -FilePath 'pwsh' -ArgumentList $argumentList -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    } catch {
        $launchErrors.Add("воркер $($bucket.Index): не вдалося запустити процес — $($_.Exception.Message)")
    }

    [pscustomobject]@{
        Index       = $bucket.Index
        Files       = $bucket.Files
        Process     = $process
        SummaryPath = $summaryPath
        StdoutPath  = $stdoutPath
        StderrPath  = $stderrPath
    }
})

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# WaitForExit() на кожному — і лише ПОТІМ читати ExitCode. $null там означає збій
# воркера (процес не завершився штатно), а не 0 — трактувати інакше було б мовчазним
# "зелено" там, де насправді нема чим його підтвердити. Процес, який не вдалось запустити
# ($process лишився $null — причина вже названа в $launchErrors), так само рахується як 1:
# інакше він мовчки випав би із суми кодів виходу.
$exitCodes = foreach ($w in $workerProcs) {
    if ($null -eq $w.Process) {
        1
    } else {
        $w.Process.WaitForExit()
        $code = $w.Process.ExitCode
        if ($null -eq $code) { $code = 1 }
        $code
    }
}

$stopwatch.Stop()

# Пошкоджений чи обрізаний JSON (воркера вбито посеред запису) не має падати сирим стеком:
# ловиться тут, а сам шлях файлу йде в $summaryErrors, щоб причина називала конкретний
# файл, а не тільки загальну розбіжність лічильників у Get-KitRunVerdict.
$summaryErrors = [System.Collections.Generic.List[string]]::new()
# ФІНАЛЬНЕ РЕВ'Ю ГІЛКИ, п.2: Invoke-TestWorker.ps1 пише причину власної смерті в поле
# `Error` підсумку (виняток, спійманий у власному try/catch воркера — не лише "код виходу
# ≠ 0", а й ЩО саме сталось), і до цього фіксу тут його ніхто не читав: людина бачила
# "воркер 3 вийшов з кодом 1" без жодного тексту причини. $workerErrors збирається в тому
# самому проході, що будує $summaries, — другий прохід по вже прочитаному JSON був би
# зайвим.
$workerErrors  = [System.Collections.Generic.List[string]]::new()
$summaries = @(foreach ($w in $workerProcs) {
    if (Test-Path -LiteralPath $w.SummaryPath -PathType Leaf) {
        try {
            $parsedSummary = Get-Content -LiteralPath $w.SummaryPath -Raw | ConvertFrom-Json
        } catch {
            $summaryErrors.Add("воркер $($w.Index): підсумок '$($w.SummaryPath)' пошкоджено — $($_.Exception.Message)")
            continue
        }
        if ($parsedSummary.Error) {
            $workerErrors.Add("воркер $($w.Index): $($parsedSummary.Error)")
        }
        $parsedSummary
    }
})

$dispatchedFiles = @($buckets | ForEach-Object { $_.Files })
$verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles $dispatchedFiles -WorkerExitCodes @($exitCodes)

# Таблицю тривалостей ЗЛИТИ, не перезаписати: почати з прочитаної (seed+measured), накрити
# новими значеннями з підсумків воркерів. Інакше запис губив би тривалості файлів, яких
# цей прогін не торкнувся (наприклад — воркер зламався до того, як дійшов до якогось файлу).
$mergedDurations = @{}
foreach ($key in $durations.Keys) { $mergedDurations[$key] = $durations[$key] }
foreach ($summary in $summaries) {
    if ($summary.Durations) {
        foreach ($property in $summary.Durations.PSObject.Properties) {
            $mergedDurations[$property.Name] = [double]$property.Value
        }
    }
}
Write-KitTestDurations -Path $measuredPath -Durations $mergedDurations

if ($FullLog) {
    foreach ($w in ($workerProcs | Sort-Object -Property Index)) {
        Write-Host ''
        Write-Host "===== воркер $($w.Index) ====="
        if (Test-Path -LiteralPath $w.StdoutPath -PathType Leaf) {
            Get-Content -LiteralPath $w.StdoutPath -Raw | Write-Host
        }
        # ФІНАЛЬНЕ РЕВ'Ю ГІЛКИ, п.5: stderr не друкувався НІКОЛИ — а саме туди осідає смерть
        # самого процесу (нативний крах pwsh, необроблений виняток до власного try/catch
        # воркера), якої stdout не бачить. Друкується лише коли непорожній — щоб не
        # засмічувати звичайний зелений прогін порожніми заголовками.
        if ((Test-Path -LiteralPath $w.StderrPath -PathType Leaf) -and (Get-Item -LiteralPath $w.StderrPath).Length -gt 0) {
            Write-Host "----- воркер $($w.Index): stderr -----"
            Get-Content -LiteralPath $w.StderrPath -Raw | Write-Host
        }
    }
}

Write-Host ''
foreach ($summary in $summaries) {
    foreach ($failure in @($summary.Failures)) {
        $base = $failure.File -replace '\.Tests\.ps1$', ''
        $exclude = if ($excludeArg) { " -ExcludeTag $excludeArg" } else { '' }
        Write-Host "$($failure.File) :: $($failure.Name)"
        Write-Host "  $($failure.Message)"
        Write-Host "  pwsh -NoProfile -File tools/tests/Run-Tests.ps1$exclude -Only $base"
    }
}

# NotRunCount — тести, відфільтровані тегом (-ExcludeTag), а не пропущені (-Skip) і не
# впалі: Pester рахує їх у TotalCount, але не в SkippedCount, тому "тестів: $TotalCount"
# сам по собі неоднозначний — один прогін уже прочитали як "загублено 15 тестів", хоча
# насправді жоден не зник, вони просто відфільтровані. Той самий "?.Sum"-ідіом, що в
# Get-KitRunVerdict (Task 1): Measure-Object -Sum на порожньому наборі повертає $null.
$notRunSum = ($summaries | Measure-Object -Property NotRunCount -Sum)?.Sum
if ($null -eq $notRunSum) { $notRunSum = 0 }
$executedCount = $verdict.TotalCount - $notRunSum

# Причини Get-KitRunVerdict не знають про невдалий запуск процесу чи пошкоджений підсумок
# (Get-KitRunVerdict читає лише те, що йому дали, — самих цих подій не бачить), тому
# зводяться в одну причину поруч. Зелено лише коли немає жодної з усіх трьох джерел.
$allReasons = @($verdict.Reasons) + @($launchErrors) + @($summaryErrors) + @($workerErrors)
$isGreen    = $verdict.Green -and ($launchErrors.Count -eq 0) -and ($summaryErrors.Count -eq 0) -and ($workerErrors.Count -eq 0)

Write-Host ''
Write-Host "файлів: $($verdict.Containers)/$($dispatchedFiles.Count), тестів: $($verdict.TotalCount) (виконано $executedCount, відфільтровано тегом $notRunSum), впало: $($verdict.FailedCount), час: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) с"

if ($isGreen) {
    Write-Host "ЗЕЛЕНО. Логи: $testRunRoot"
    exit 0
} else {
    Write-Host "ЧЕРВОНО: $($allReasons -join '; '). Логи: $testRunRoot"
    exit 1
}
