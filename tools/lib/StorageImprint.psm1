#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

<#
.SYNOPSIS
    Відбиток «стан сховища, побачений останнім sync» — build/session-check/<Key>.json.
.DESCRIPTION
    Кеш, не стан (§3.2): джерело істини про те, що вже залито в git, —
    трейлер Storage-Version на вершині storage/<ключ>, і лишається ним завжди. Відбиток лише
    прискорює відповідь session-check, коли диск сховища не змінився з моменту, коли sync його
    востаннє читав, — замінює вічне «не визначається» (запаковане, неактивне сховище — data/objects
    порожня, sync без нових версій дзеркало не рухає, pack ніколи не «постаріє») на точну відповідь.
    Файл гітігнорований (build/), локальний для машини: якщо його видалити чи він пошкодиться,
    session-check просто повертається до евристик mtime (§5) — синхронізація цього не помічає.

    Пише лише sync (Write-KitStorageImprint) — і в прев'ю, і з -Apply (докстрінг Invoke-KitSync
    пояснює чому). session-check лише читає — інваріант «session-check нічого не мутує» тримає
    законність примусового вбивання його процесу за стелею часу.
#>

# Версія формату відбитка (поле schema у JSON). Наступна зміна формату мусить читатись як
# «відбитка немає» (Read-KitStorageImprint поверне $null, а не кине виняток) — не як «диск
# розійшовся з відбитком» і тим паче не як валідна точна відповідь зі старими полями.
$script:ImprintSchemaVersion = 1

function Get-KitStorageImprintPath {
    <# .SYNOPSIS Шлях до файла відбитка джерела — внутрішній хелпер, спільний для читання й запису. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Key)
    Join-Path $RepoRoot "build/session-check/$Key.json"
}

function Write-KitStorageImprint {
    <#
    .SYNOPSIS
        Знімок стану сховища (Get-KitStorageActivity) на момент, коли sync прочитав звіт, разом
        із версією зі звіту — build/session-check/<Key>.json.
    .DESCRIPTION
        Дати серіалізуються рядком формату 'o' (round-trip, з таймзоною) — ConvertFrom-Json на
        читанні віддає їх РЯДКАМИ, а не [datetime]: мовчазне порівняння рядка з [datetime] дало б
        вічний $false — непомітне вічне повернення до евристик. Тому запис у 'o'-форматі і явний
        [datetime]::Parse на читанні (Read-KitStorageImprint) — разом, як одна гарантія.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$StoragePath,
        [Parameter(Mandatory)][int]$Version
    )

    # Ключ джерела приходить із маніфесту БЕЗ перевірки на шляхоподібність, тож '..' у ключі вивів би
    # відбиток за межі build/session-check. Перевірка — ПЕРЕД зверненням до сховища (дешева першою).
    $path = Get-KitStorageImprintPath -RepoRoot $RepoRoot -Key $Key
    Assert-KitBuildPath -Path $path -MustBeUnder (Join-Path $RepoRoot 'build/session-check') -RepoRoot $RepoRoot -Description "відбиток сховища $Key"

    $activity = Get-KitStorageActivity -StoragePath $StoragePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null

    $doc = [ordered]@{
        schema              = $script:ImprintSchemaVersion
        key                 = $Key
        storagePath         = $StoragePath
        version             = $Version
        readAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
        latestObjectWriteUtc = if ($null -ne $activity.LatestObjectWrite) { $activity.LatestObjectWrite.ToUniversalTime().ToString('o') } else { $null }
        packFiles           = @($activity.PackFiles | ForEach-Object {
            [ordered]@{ name = $_.Name; length = [int64]$_.Length; lastWriteUtc = $_.LastWriteTimeUtc.ToUniversalTime().ToString('o') }
        })
    }
    ($doc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Read-KitStorageImprint {
    <#
    .SYNOPSIS
        Відбиток джерела, або $null — файла немає, JSON битий чи схема чужа: усі три випадки
        рівнозначні "відбитка немає", жоден не кидає винятку (зіпсований кеш не має валити команду).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Key
    )
    $path = Get-KitStorageImprintPath -RepoRoot $RepoRoot -Key $Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    try {
        $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not ($obj.PSObject.Properties.Name -contains 'schema') -or [int]$obj.schema -ne $script:ImprintSchemaVersion) { return $null }

        $ic    = [System.Globalization.CultureInfo]::InvariantCulture
        $style = [System.Globalization.DateTimeStyles]::RoundtripKind
        $packFiles = @($obj.packFiles | ForEach-Object {
            [pscustomobject]@{
                Name             = [string]$_.name
                Length           = [int64]$_.length
                LastWriteTimeUtc = [datetime]::Parse([string]$_.lastWriteUtc, $ic, $style)
            }
        })

        [pscustomobject]@{
            Schema               = [int]$obj.schema
            Key                  = [string]$obj.key
            StoragePath          = [string]$obj.storagePath
            Version              = [int]$obj.version
            ReadAtUtc            = [datetime]::Parse([string]$obj.readAtUtc, $ic, $style)
            LatestObjectWriteUtc = if ($null -ne $obj.latestObjectWriteUtc) { [datetime]::Parse([string]$obj.latestObjectWriteUtc, $ic, $style) } else { $null }
            PackFiles            = $packFiles
        }
    } catch {
        # Битий JSON, чужа схема з полями несумісного типу, зіпсована дата — усе одно "відбитка
        # немає", не зупинка команди. Навмисно широкий catch: перелік конкретних винятків, які
        # ConvertFrom-Json/[datetime]::Parse можуть кинути на довільно пошкодженому файлі, довший
        # за користь від його переліку.
        $null
    }
}

function Test-KitStorageImprintCurrent {
    <#
    .SYNOPSIS
        Чи диск (свіжий Get-KitStorageActivity) досі такий самий, як у відбитку.
    .DESCRIPTION
        Без допуску — і не повинно бути: обидві сторони порівняння знято ОДНИМ годинником
        (файлова система сервера сховища, і зараз, і коли sync читав звіт), на відміну від
        порівняння mtime з датою автора коміту дзеркала (StorageMirrorTolerance, session-check.psm1) —
        там годинники різні (сервер сховища проти машини, що комітила), і допуск там законний.
        Тут будь-яка розбіжність — доказ, що диск чіпали, і точній відповіді довіряти не можна.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Imprint,
        [Parameter(Mandatory)]$Activity
    )

    if ($null -eq $Imprint.LatestObjectWriteUtc) {
        if ($null -ne $Activity.LatestObjectWrite) { return $false }
    } elseif ($null -eq $Activity.LatestObjectWrite -or $Imprint.LatestObjectWriteUtc -ne $Activity.LatestObjectWrite) {
        return $false
    }

    $impPack = @($Imprint.PackFiles)
    $curPack = @($Activity.PackFiles)
    if ($impPack.Count -ne $curPack.Count) { return $false }
    for ($i = 0; $i -lt $impPack.Count; $i++) {
        if ($impPack[$i].Name -ne $curPack[$i].Name -or
            $impPack[$i].Length -ne $curPack[$i].Length -or
            $impPack[$i].LastWriteTimeUtc -ne $curPack[$i].LastWriteTimeUtc) { return $false }
    }
    $true
}

Export-ModuleMember -Function Write-KitStorageImprint, Read-KitStorageImprint, Test-KitStorageImprintCurrent
