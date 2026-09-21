#Requires -Version 7
Set-StrictMode -Version Latest

<#
    Чиста логіка паралельного раннера tools/tests: вибір файлів тестів, розклад по воркерах,
    таблиця тривалостей і вердикт прогону. Без запуску Pester, без підпроцесів, без git —
    саме тому тестується в процесі (TestRunner.Tests.ps1), за десятки мілісекунд. Сам запуск
    воркерів (`pwsh` per bucket) лишається за Run-Tests.ps1 — цей модуль лише вирішує, ЩО
    і КУДИ роздати, і як прочитати підсумок.
#>

function Resolve-KitTestFiles {
    <#
    .SYNOPSIS
        Будує явний перелік файлів тестів для Pester — без рекурсії, з підтримкою -Only.
    .DESCRIPTION
        Get-ChildItem без рекурсії навмисно: lib/ лежить усередині tools/tests, і рекурсія
        затягнула б туди файли, яких -Only не бачить. Раннер віддає Pester явний перелік
        файлів, не теку.

        Без -Only — усі файли, відсортовані за іменем. З -Only <ім'я>: спершу шукається
        точна назва "<база>.Tests.ps1" — вона має перевагу, якщо існує. Інакше шукається
        група "<база>.*.Tests.ps1". Якщо не знайдено жодного — throw з переліком доступних
        базових імен (текст сумісний із наявним викликом у Run-Tests.ps1).
    .EXAMPLE
        Resolve-KitTestFiles -Root $PSScriptRoot -Only 'Sync', 'Verify'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Only = @()
    )

    $allFiles = @(Get-ChildItem -LiteralPath $Root -Filter '*.Tests.ps1' -File)

    if (-not $Only -or $Only.Count -eq 0) {
        # Кома перед масивом — не стиль, а необхідність: без неї "return" розгортає масив
        # у потік виводу, і виклик із рівно одним файлом (частий випадок -Only) повертав би
        # виклику голий рядок замість масиву з одним елементом.
        return ,@($allFiles | Sort-Object -Property Name | ForEach-Object { $_.FullName })
    }

    $result = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($name in $Only) {
        $base      = $name -replace '\.Tests\.ps1$', ''
        $exactLeaf = "$base.Tests.ps1"
        $exact     = @($allFiles | Where-Object { $_.Name -eq $exactLeaf })

        if ($exact.Count -gt 0) {
            $matches = $exact
        } else {
            # Екранування шаблону групи: без нього описка на кшталт -Only 'Ch*' мовчки
            # вибрала б групу (перший "*" з вводу користувача відпрацював би як wildcard),
            # замість того щоб зупинитись, бо такого файлу насправді немає.
            $escapedBase  = [System.Management.Automation.WildcardPattern]::Escape($base)
            $groupPattern = "$escapedBase.*.Tests.ps1"
            $matches      = @($allFiles | Where-Object { $_.Name -like $groupPattern } | Sort-Object -Property Name)

            if ($matches.Count -eq 0) {
                $available = ($allFiles | Sort-Object -Property Name | ForEach-Object { $_.Name -replace '\.Tests\.ps1$', '' }) -join ', '
                throw "Файла тестів '$exactLeaf' немає в $Root. Доступні: $available."
            }
        }

        foreach ($file in $matches) {
            if ($seen.Add($file.FullName)) {
                $result.Add($file.FullName)
            }
        }
    }

    # Та сама причина коми, що й вище: результат мусить лишитись масивом навіть коли
    # -Only звузив вибір до одного файлу.
    return ,@($result.ToArray())
}

function Split-KitTestFiles {
    <#
    .SYNOPSIS
        Жадібний розклад файлів тестів по воркерах (LPT — longest processing time first).
    .DESCRIPTION
        Вага файлу — з -Durations за іменем файлу (не повним шляхом). Файл без запису в
        таблиці важить як максимум відомих ваг; якщо таблиця порожня — усі файли важать 1,0.
        Файли сортуються спадно за вагою, за рівних ваг — за іменем (детермінізм). Кожен файл
        іде в кошик із найменшим поточним навантаженням; вибір кошика — стабільне сортування
        за навантаженням із взяттям першого, що робить розклад відтворюваним при рівних
        навантаженнях кошиків.
    .EXAMPLE
        Split-KitTestFiles -Files $files -Durations $durations -Workers 4
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Durations,
        [Parameter(Mandatory)][int]$Workers
    )

    if ($Workers -lt 1) {
        throw "Workers мусить бути не менше 1 (отримано $Workers)."
    }

    $maxKnown = 1.0
    if ($Durations.Count -gt 0) {
        $maxKnown = ($Durations.Values | Measure-Object -Maximum).Maximum
    }

    $weighted = foreach ($file in $Files) {
        $leaf = Split-Path -Path $file -Leaf
        $sec =
            if ($Durations.Count -eq 0) { 1.0 }
            elseif ($Durations.Contains($leaf)) { [double]$Durations[$leaf] }
            else { [double]$maxKnown }
        [pscustomobject]@{ File = $file; Name = $leaf; Sec = $sec }
    }

    $ordered = @($weighted | Sort-Object -Property @{ Expression = 'Sec'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })

    $buckets = @(for ($i = 1; $i -le $Workers; $i++) {
        [pscustomobject]@{ Index = $i; Files = [System.Collections.Generic.List[string]]::new(); Sec = 0.0 }
    })

    foreach ($item in $ordered) {
        $target = $buckets | Sort-Object -Property Sec -Stable | Select-Object -First 1
        $target.Files.Add($item.File)
        $target.Sec += $item.Sec
    }

    $result = foreach ($bucket in $buckets) {
        if ($bucket.Files.Count -gt 0) {
            [pscustomobject]@{ Index = $bucket.Index; Files = @($bucket.Files.ToArray()); Sec = $bucket.Sec }
        }
    }

    # Кома — щоб масив не розгорнувся при поверненні: з -Workers 1 (чи коли непорожній лише
    # один кошик) виклику інакше дістався б голий pscustomobject замість масиву з ним.
    return ,@($result)
}

function Read-KitTestDurations {
    <#
    .SYNOPSIS
        Читає таблицю тривалостей "ім'я файлу тестів → секунди" з засівного й виміряного JSON.
    .DESCRIPTION
        Засівний файл (SeedPath) — початкові орієнтовні ваги, закомічені в репозиторій.
        Виміряний (MeasuredPath) — реальні тривалості з попередніх прогонів; перекриває
        засівні значення за тим самим ключем. Відсутність будь-якого з файлів — не помилка
        (перший прогін на свіжому клоні не мав звідки взяти виміряне).
    .EXAMPLE
        Read-KitTestDurations -MeasuredPath $measured -SeedPath $seed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MeasuredPath,
        [Parameter(Mandatory)][string]$SeedPath
    )

    $durations = @{}

    foreach ($path in @($SeedPath, $MeasuredPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($property in $json.PSObject.Properties) {
                $durations[$property.Name] = [double]$property.Value
            }
        }
    }

    return $durations
}

function Write-KitTestDurations {
    <#
    .SYNOPSIS
        Пише таблицю тривалостей у JSON — ключі за алфавітом, значення округлені до 0,01.
    .DESCRIPTION
        Створює батьківську теку, якщо її ще нема. Стабільний порядок ключів і округлення
        роблять діфф файлу читабельним і не шумним між прогонами з мікросекундними
        коливаннями тривалості.
    .EXAMPLE
        Write-KitTestDurations -Path $measuredPath -Durations $durations
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Durations
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $ordered = [ordered]@{}
    foreach ($key in ($Durations.Keys | Sort-Object)) {
        $ordered[$key] = [math]::Round([double]$Durations[$key], 2)
    }

    $ordered | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-KitRunVerdict {
    <#
    .SYNOPSIS
        Зводить підсумки воркерів у єдиний вердикт прогону.
    .DESCRIPTION
        Зелено лише коли причин немає жодної. Причини збираються всі, не перша-ліпша:
        мертвий воркер (код виходу ≠ 0), брак підсумку (менше підсумків, ніж воркерів),
        розбіжність контейнерів із розданими файлами (хтось не виконався непоміченим),
        нуль виконаних тестів (мовчазне "0 тестів" паралельної форми) і впалі тести.
        Measure-Object -Sum на порожньому наборі повертає $null — усі суми зводяться до 0
        явно, інакше порівняння з числом дало б хибне "зелено".
    .EXAMPLE
        Get-KitRunVerdict -Summaries $summaries -DispatchedFiles $files -WorkerExitCodes $codes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Summaries,
        [Parameter(Mandatory)][string[]]$DispatchedFiles,
        [Parameter(Mandatory)][int[]]$WorkerExitCodes
    )

    $reasons = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $WorkerExitCodes.Count; $i++) {
        $code = $WorkerExitCodes[$i]
        if ($code -ne 0) {
            $reasons.Add("воркер $($i + 1) вийшов з кодом $code")
        }
    }

    if ($Summaries.Count -lt $WorkerExitCodes.Count) {
        $reasons.Add("підсумків: $($Summaries.Count), воркерів: $($WorkerExitCodes.Count) — хтось не лишив підсумку")
    }

    $containersSum = ($Summaries | Measure-Object -Property Containers -Sum).Sum
    if ($null -eq $containersSum) { $containersSum = 0 }
    if ($containersSum -ne $DispatchedFiles.Count) {
        $reasons.Add("виконано контейнерів: $containersSum, роздано файлів: $($DispatchedFiles.Count)")
    }

    $totalSum = ($Summaries | Measure-Object -Property TotalCount -Sum).Sum
    if ($null -eq $totalSum) { $totalSum = 0 }
    if ($totalSum -eq 0) {
        $reasons.Add('прогін не виконав жодного тесту')
    }

    $failedSum = ($Summaries | Measure-Object -Property FailedCount -Sum).Sum
    if ($null -eq $failedSum) { $failedSum = 0 }
    if ($failedSum -gt 0) {
        $reasons.Add("впало тестів: $failedSum")
    }

    [pscustomobject]@{
        Green       = ($reasons.Count -eq 0)
        Reasons     = @($reasons.ToArray())
        Containers  = $containersSum
        TotalCount  = $totalSum
        FailedCount = $failedSum
    }
}

Export-ModuleMember -Function Resolve-KitTestFiles, Split-KitTestFiles, Read-KitTestDurations, Write-KitTestDurations, Get-KitRunVerdict
