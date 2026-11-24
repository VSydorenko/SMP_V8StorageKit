#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

<#
.SYNOPSIS
    Відбиток «стан сховища, побачений останнім sync» — build/session-check/<Key>.json.
.DESCRIPTION
    Кеш, не стан: джерело істини про те, що вже залито в git, —
    трейлер Storage-Version на вершині storage/<ключ>, і лишається ним завжди. Відбиток лише
    прискорює відповідь session-check (його читає Rust: `rust/src/session_check/`), коли диск сховища не змінився з моменту, коли sync його
    востаннє читав, — замінює вічне «не визначається» (запаковане, неактивне сховище — data/objects
    порожня, sync без нових версій дзеркало не рухає, pack ніколи не «постаріє») на точну відповідь.
    Файл гітігнорований (build/), локальний для машини: якщо його видалити чи він пошкодиться,
    session-check просто повертається до евристик mtime — синхронізація цього не помічає.

    Пише лише sync (Write-KitStorageImprint) — і в прев'ю, і з -Apply (докстрінг Invoke-KitSync
    пояснює чому). Читає й звіряє з диском лише Rust-команда session-check; вона нічого не мутує —
    інваріант тримає законність примусового вбивання її процесу за стелею часу. Формат файла —
    контракт між цим записом і тим читанням.
#>

# Версія формату відбитка (поле schema у JSON). Наступна зміна формату мусить читатись як
# «відбитка немає» (читач в Rust відкидає чужу схему, а не падає) — не як «диск
# розійшовся з відбитком» і тим паче не як валідна точна відповідь зі старими полями.
$script:ImprintSchemaVersion = 1

function Get-KitStorageImprintPath {
    <# .SYNOPSIS Шлях до файла відбитка джерела — внутрішній хелпер, використовується записом. #>
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
        розбір дат на читанні (Rust, `rust/src/session_check/`) — разом, як одна гарантія.
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

Export-ModuleMember -Function Write-KitStorageImprint
