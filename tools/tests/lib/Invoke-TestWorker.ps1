#Requires -Version 7
<#
.SYNOPSIS
    Воркер паралельного прогону: виконує Pester по одному файлу тестів за раз для свого
    підмножини й пише підсумок у JSON.
.DESCRIPTION
    Запускається `Run-Tests.ps1` окремим процесом `pwsh` (`Start-Process`) — один на кошик
    файлів, зібраний `Split-KitTestFiles`. Сам воркер нічого не планує й нічого не зводить:
    він лише виконує названі файли й документує, що з ними сталось.

    UTF-8 консолі виставляється ПЕРШИМИ ДВОМА РЯДКАМИ, до `Import-Module Pester` — той
    самий фікс, що `docs/follow-ups.md` §18 документує для будь-якого свіжого `pwsh`, який
    сам кличе Pester і порівнює кирилицю з виводу дочірнього процесу.

    У БОЙОВОМУ шляху (`Run-Tests.ps1` спавнить цей скрипт через `Start-Process -NoNewWindow`)
    ці два рядки НАДЛИШКОВІ: `-NoNewWindow` ділить консоль із предком, а `Run-Tests.ps1`
    сам виставляє те саме кодування ПЕРШИМИ рядками (78-79 на момент цього запису — номер
    дрейфує, шукай `[Console]::OutputEncoding` біля початку файлу) ще до спавну — воркер
    успадковує вже виправлену консоль незалежно від власних рядків. Виміряно (Task 4,
    фікс-раунд 1, `tools/tests/RunTests.Tests.ps1`): прибрати ці два рядки лише в копії
    воркера й прогнати паралельну гілку через `Run-Tests.ps1` — лишається ЗЕЛЕНИМ; те саме
    впало б лише за умови, що прибрати кодування ще й у самого `Run-Tests.ps1`.

    Рядки тут несучі для ІЗОЛЬОВАНОГО прямого виклику цього скрипту — саме такого, який
    показує `.EXAMPLE` нижче, поза оркестрацією `Run-Tests.ps1` (відлагодження одного
    воркера, чи будь-який інший виклик без предка, що вже виправив консоль). Прибирати їх
    не варто: у бойовому шляху вони не заважають, а прямий виклик без них падає
    детерміновано — саме так, як і задокументовано в §18.

    Надлишковість у бойовому шляху УМОВНА, не контрактна: вона тримається на тому, що
    `Run-Tests.ps1` спавнить цей скрипт саме через `-NoNewWindow`, ділячи консоль із предком,
    який кодову сторінку вже виправив. Спільна консоль — властивість СПОСОБУ запуску, а не
    гарантія самого виклику. Хто дасть воркеру приховане вікно, запустить його під службою чи
    в CI без консолі — відбере успадковану кодову сторінку, і ці два рядки знову стануть
    несучими навіть у виклику, який виглядає як бойовий. Тест на ІЗОЛЬОВАНІЙ консолі
    (`Invoke-KitRunnerSandboxIsolated` у `RunTests.Tests.ps1`, `Start-Process` без
    `-NoNewWindow`) цього не помітить — саме тому, що він перевіряє інший спосіб запуску, не
    той, яким сьогодні користується `Run-Tests.ps1`.

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

    ФІНАЛЬНЕ РЕВ'Ю ГІЛКИ, п.1 (діра в центральній властивості "хибне ЗЕЛЕНО неможливе"): файл,
    що впав на дискавері (синтаксична помилка, битий `BeforeDiscovery`, битий `-ForEach`), дає
    `$result.TotalCount = 0` і `$result.FailedCount = 0` — Pester не запускає ЖОДНОГО тесту, тож
    старий код бачив порожній файл як "виконаний контейнер" і мовчав. Сам провал видно лише через
    `$result.FailedContainersCount` (і докладно — через `$result.FailedContainers`, кожен елемент
    якого несе `.Item` (шлях) і `.ErrorRecord` (текст помилки дискавері)). Тому нижче накопичується
    окремий лічильник `$failedContainersCount`, а кожен провалений контейнер іде в той самий
    список `$failures`, що й провалені тести (`Name = '(дискавері)'` — маркер, за яким
    `Get-KitRunVerdict` відрізняє провал контейнера від провалу тесту). Перевірено емпірично
    (Pester 6.1.0, `Invoke-Pester -PassThru`): і синтаксична помилка файлу, і `throw` в
    `BeforeDiscovery` дають однаковий відбиток `FailedContainersCount = 1, FailedCount = 0,
    TotalCount = 0`. Провал усередині `BeforeAll` — інша форма: Pester сам заводить синтетичний
    провалений тест (`$result.Failed` непорожній, `FailedCount > 0`), і його вже ловить наявний
    цикл `foreach ($test in $result.Failed)` нижче — окремої обробки не потребує.
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

$containers            = 0
$totalCount            = 0
$passedCount           = 0
$failedCount           = 0
$skippedCount          = 0
$notRunCount           = 0
$failedContainersCount = 0
$durations             = @{}
$failures              = [System.Collections.Generic.List[pscustomobject]]::new()
$errorText             = $null

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
        $totalCount            += $result.TotalCount
        $passedCount           += $result.PassedCount
        $failedCount           += $result.FailedCount
        $skippedCount          += $result.SkippedCount
        $notRunCount           += $result.NotRunCount
        $failedContainersCount += $result.FailedContainersCount
        $durations[$leaf] = [math]::Round($result.Duration.TotalSeconds, 2)

        foreach ($test in $result.Failed) {
            $message = ($test.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join '; '
            $failures.Add([pscustomobject]@{
                File    = $leaf
                Name    = $test.ExpandedPath
                Message = $message
            })
        }

        # Провал контейнера (дискавері) — синтаксична помилка файлу чи throw у
        # BeforeDiscovery: Pester не рахує це провалом ТЕСТУ ($result.Failed тут порожній),
        # тому без цього циклу файл лишався б непоміченим (див. ФІНАЛЬНЕ РЕВ'Ю ГІЛКИ, п.1
        # вище). Name = '(дискавері)' — маркер, за яким Get-KitRunVerdict відрізняє цей запис
        # від провалу звичайного тесту.
        foreach ($container in $result.FailedContainers) {
            $message = ($container.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join '; '
            $failures.Add([pscustomobject]@{
                File    = $leaf
                Name    = '(дискавері)'
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
        Containers            = $containers
        TotalCount            = $totalCount
        PassedCount           = $passedCount
        FailedCount           = $failedCount
        SkippedCount          = $skippedCount
        NotRunCount           = $notRunCount
        FailedContainersCount = $failedContainersCount
        Durations             = $durations
        Failures              = @($failures.ToArray())
        Error                 = $errorText
    }

    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding utf8NoBOM
}

if ($errorText) {
    exit 1
} else {
    exit 0
}
