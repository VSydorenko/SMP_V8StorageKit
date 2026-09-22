#Requires -Version 7
<#
.SYNOPSIS
    Воркер паралельного прогону: виконує Pester по одному файлу тестів за раз для свого
    підмножини й пише підсумок у JSON.
.DESCRIPTION
    Запускається `Run-Tests.ps1` окремим процесом `pwsh` (`Start-Process`) — один на кошик
    файлів, зібраний `Split-KitTestFiles`. Сам воркер нічого не планує й нічого не зводить:
    він лише виконує названі файли й документує, що з ними сталось.

    UTF-8 консолі виставляється ПЕРШИМИ ДВОМА РЯДКАМИ, до `Import-Module Pester` —
    `docs/follow-ups.md` §18: кодування консолі виставляє лише `Run-Tests.ps1`, і кожен
    свіжий `pwsh`, який сам кличе Pester, без цих рядків детерміновано падає на порівнянні
    кирилиці з виводу дочірнього процесу. Під вісьмома паралельними воркерами це виглядало б
    як масовий флак — а це той самий, уже задокументований, детермінований дефект.

    По одному `Invoke-Pester` на файл, не один виклик на весь перелік: це дає тривалість
    кожного файлу окремо (для таблиці розкладу наступного прогону), прив'язує падіння до
    конкретного файлу й дозволяє надрукувати маркер перед кожним. Накладна — лише повторний
    `New-PesterConfiguration`; сам імпорт Pester (≈547 мс) один на процес.

    Підсумок пишеться в `finally` — навіть коли перелік містить неіснуючий файл чи Pester
    інакше кидає виняток: часткові накопичені лічильники йдуть у підсумок як є, а сам виняток
    осідає в полі `Error`. Код виходу воркера навмисно НЕ дорівнює "є впалі тести": він означає
    "воркер дійшов до кінця й записав підсумок" (0) чи "воркер зламався" (1, `Error` непорожнє).
    Без цього розділення `Get-KitRunVerdict` (Task 1) не міг би відрізнити мертвий воркер від
    звичайного червоного прогону — впалі тести й так видно через `FailedCount` підсумку.
.PARAMETER FileListPath
    Текстовий файл з одним повним шляхом до файлу тестів на рядок.
.PARAMETER SummaryPath
    Куди записати підсумок JSON (UTF-8 без BOM).
.PARAMETER ExcludeTag
    Теги для виключення. Розділення по комі — власноруч, тим самим ідіомом, що в
    `Run-Tests.ps1`: воркер теж запускається через `-File`, де кома в елементі масиву
    приходить УСЕРЕДИНІ рядка (оболонка вже розібрала аргументи до того, як їх побачив
    парсер PowerShell), і без ручного розбиття `-ExcludeTag Integration` дійшов би до
    `Filter.ExcludeTag` як єдиний тег `"Integration"` лише випадково — а перелік із кількох
    тегів через кому мовчки не спрацював би.
.EXAMPLE
    pwsh -NoProfile -File tools/tests/lib/Invoke-TestWorker.ps1 `
        -FileListPath build/test-run/worker-1.files.txt `
        -SummaryPath build/test-run/worker-1.summary.json `
        -ExcludeTag Integration
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FileListPath,
    [Parameter(Mandatory)][string]$SummaryPath,
    [string[]]$ExcludeTag = @()
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module Pester -MinimumVersion 5.0

$ExcludeTag = @($ExcludeTag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$containers   = 0
$totalCount   = 0
$passedCount  = 0
$failedCount  = 0
$skippedCount = 0
$notRunCount  = 0
$durations    = @{}
$failures     = [System.Collections.Generic.List[pscustomobject]]::new()
$errorText    = $null

try {
    $files = @(
        Get-Content -LiteralPath $FileListPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    foreach ($file in $files) {
        $leaf = Split-Path -Path $file -Leaf
        Write-Host ">>> ФАЙЛ $leaf"

        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Файл тестів '$file' не знайдено."
        }

        $config = New-PesterConfiguration
        $config.Run.Path        = $file
        $config.Run.PassThru    = $true
        $config.Run.Exit        = $false
        $config.Output.Verbosity = 'Detailed'
        if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }

        $result = Invoke-Pester -Configuration $config

        $containers++
        $totalCount   += $result.TotalCount
        $passedCount  += $result.PassedCount
        $failedCount  += $result.FailedCount
        $skippedCount += $result.SkippedCount
        $notRunCount  += $result.NotRunCount
        $durations[$leaf] = [math]::Round($result.Duration.TotalSeconds, 2)

        foreach ($test in $result.Failed) {
            $message = ($test.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join '; '
            $failures.Add([pscustomobject]@{
                File    = $leaf
                Name    = $test.ExpandedPath
                Message = $message
            })
        }
    }
}
catch {
    $errorText = $_.Exception.Message
}
finally {
    $summary = [pscustomobject]@{
        Containers   = $containers
        TotalCount   = $totalCount
        PassedCount  = $passedCount
        FailedCount  = $failedCount
        SkippedCount = $skippedCount
        NotRunCount  = $notRunCount
        Durations    = $durations
        Failures     = @($failures.ToArray())
        Error        = $errorText
    }

    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding utf8NoBOM
}

if ($errorText) {
    exit 1
} else {
    exit 0
}
