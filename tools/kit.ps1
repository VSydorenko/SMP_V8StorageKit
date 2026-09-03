#Requires -Version 7
<#
.SYNOPSIS
    Диспетчер команд kit: pwsh tools/kit.ps1 <команда> [-RepoRoot .] [-Workspace X] [-Source Y] [-Apply] [власні параметри команди]
.DESCRIPTION
    Спільний префлайт (спека §5) і виклик Invoke-Kit<Команда> з tools/commands/<команда>.psm1.
    Команди не імпортують lib-модулів самі — їх імпортує цей файл у порядку
    tools/lib/module-order.txt, і командний модуль бачить їх із глобальної області.

    Власні параметри команди передаються після спільних як -Ім'я значення або -Прапорець і
    доходять до Invoke-Kit<Команда> сплатом; невідомий параметр зупиняє PowerShell ще на
    прив'язці — команда не виконується.
.EXAMPLE
    pwsh tools/kit.ps1 check -RepoRoot <шлях до репо-споживача>
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$RepoRoot = '.',
    [string]$Workspace,
    [string]$Source,
    [switch]$Apply,
    [Parameter(ValueFromRemainingArguments)][string[]]$CommandArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Кирилиця в повідомленнях доходить до людини й до тестів лише при UTF-8 (див. Run-Tests.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = Join-Path $PSScriptRoot 'lib'
$order = @(Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
foreach ($name in $order) {
    Import-Module (Join-Path $libDir "$name.psm1") -Force
}

$commandsDir = Join-Path $PSScriptRoot 'commands'
$available = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.psm1' -File | ForEach-Object BaseName | Sort-Object)
if (-not $Command -or $available -notcontains $Command) {
    $what = if ($Command) { "Невідома команда '$Command'." } else { 'Команду не вказано.' }
    # Правка 6б (живий прогін задачі 11) — не throw: сирий стек PowerShell (номер рядка,
    # хвилясте підкреслення) суперечить охайному [-]-виводу самого check. Код 2 (не 1),
    # щоб «команда не запустилась узагалі» відрізнялось від «команда відпрацювала й
    # знайшла помилки» — той код повертає сама команда нижче, рядок 77-79.
    Write-Host "$what Доступні: $($available -join ', '). Приклад: pwsh tools/kit.ps1 check -RepoRoot ." -ForegroundColor Red
    exit 2
}

Import-Module (Join-Path $commandsDir "$Command.psm1") -Force
$functionName = 'Invoke-Kit' + ((($Command -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
if (-not (Get-Command -Name $functionName -ErrorAction SilentlyContinue)) {
    throw "Модуль команди commands/$Command.psm1 не експортує функцію $functionName."
}

# check показує ВСЕ, що не так (Lenient); решта команд без чистого префлайту не має з чим працювати.
$context = Invoke-KitPreflight -RepoRoot $RepoRoot -Lenient:($Command -eq 'check')

# Решта аргументів → іменовані параметри команди.
$splat = @{}
for ($i = 0; $i -lt $CommandArgs.Count; $i++) {
    $arg = $CommandArgs[$i]
    if ($arg -notmatch '^-(?<n>[A-Za-z][A-Za-z0-9]*)(?::(?<v>.+))?$') {
        throw "Не розпізнаю аргумент '$arg' — очікувалось -Ім'я значення або -Прапорець."
    }
    $n = $Matches['n']
    if ($Matches.ContainsKey('v')) { $splat[$n] = $Matches['v']; continue }
    if ($i + 1 -lt $CommandArgs.Count -and $CommandArgs[$i + 1] -notmatch '^-[A-Za-z]') {
        $splat[$n] = $CommandArgs[++$i]
    } else {
        $splat[$n] = $true
    }
}

$common = @{ Context = $context; Workspace = $Workspace; Source = $Source; Apply = [bool]$Apply }
# Контракт суворий: людське команда друкує сама через Write-Host, а в success stream
# (те, що потрапляє сюди, у $result) повертає лише $null або {ExitCode; …} — жодного
# третього варіанту. Диспетчер повернене значення НЕ виводить, тільки читає ExitCode.
$result = & $functionName @common @splat
if ($null -ne $result -and ($result.PSObject.Properties.Name -contains 'ExitCode') -and $result.ExitCode -ne 0) {
    exit $result.ExitCode
}
