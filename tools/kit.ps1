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
    # Не throw: сирий стек PowerShell суперечить охайному [-]-виводу. Код 1 — диспетчерська відмова.
    # Контракт кодів виходу: 0 — виконано; 1 — зупинка (throw будь-де: невідома команда,
    # префлайт, розбір аргументів, сама команда) або check із помилками; 2 — лише sync:
    # дзеркало оновлено, злиття не виконано; 3 — verify і session-check: є що робити. Тобто 2 і 3 —
    # коди команд, які ВІДПРАЦЮВАЛИ, а не «не запустились узагалі»: код виходу сам не
    # розрізняє «диспетчер відмовив» від «команда завершилась частковим успіхом» —
    # розрізняти треба з тексту виводу.
    Write-Host "$what Доступні: $($available -join ', '). Приклад: pwsh tools/kit.ps1 check -RepoRoot ." -ForegroundColor Red
    exit 1
}

# Команди процесу (tools/commands/process-commands.txt) — свій контракт (tools/lib/KitCli.psm1:
# 0/1/2/3, `<команда>: ERROR …`, `next:`), без префлайту сховища й маніфесту (ADR-0003), сирі
# аргументи. Звичайний вхід для них — обгортки bin/ через tools/kit-process.ps1: тут параметри
# диспетчера (-RepoRoot, -Workspace, -Source, -Apply) перехоплюють однойменні токени команди.
if ((Get-KitProcessCommandNames -ToolsDir $PSScriptRoot) -contains $Command) {
    if ($Workspace -or $Source -or $Apply) {
        Write-KitError -Command $Command -ExitCode 2 -Message "-Workspace/-Source/-Apply тут бере диспетчер kit.ps1, а не команда процесу; клич обгортку bin/$Command (tools/kit-process.ps1)"
        exit 2
    }
    exit (Invoke-KitProcessEntry -Command $Command -Arguments $CommandArgs -RepoRoot $RepoRoot -ToolsDir $PSScriptRoot)
}

Import-Module (Join-Path $commandsDir "$Command.psm1") -Force
$functionName ='Invoke-Kit' + ((($Command -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
if (-not (Get-Command -Name $functionName -ErrorAction SilentlyContinue)) {
    # Як і вище: не throw, код 1 — «команда не запустилась узагалі».
    Write-Host "Модуль команди commands/$Command.psm1 не експортує функцію $functionName." -ForegroundColor Red
    exit 1
}

# Префлайт, розбір аргументів і сам виклик команди — під одним try/catch: throw БУДЬ-ДЕ тут дає
# одну зупинку одним стилем (Write-Host, код 1), а не сирий стек pwsh.
try {
    # check і session-check — діагностика: вони мусять ДОПОВІСТИ про суперечливий репозиторій, а не впасти на
    # ньому. Решта команд без чистого префлайту не має з чим працювати.
    $context = Invoke-KitPreflight -RepoRoot $RepoRoot -Lenient:($Command -in @('check', 'session-check'))

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
            # $true лише справжньому [switch]-параметру команди: інакше True мовчки в'язалось би з
            # будь-яким типом — на [Nullable[int]] "kit verify -Version -Ref main" (забули число) тихо
            # звіряло б проти версії 1. Питаємо ТИП параметра функції, не вгадуємо за формою CLI.
            #
            # Свідома межа: скорочене ім'я (-Ver замість -Version) у словнику ПОВНИХ імен не знайдеться,
            # і скорочений [switch] дасть зупинку «потребує значення». Підтримуване — лише повне ім'я.
            $functionCmd = Get-Command -Name $functionName
            $param = $functionCmd.Parameters[$n]
            if ($param -and $param.ParameterType -eq [switch]) {
                $splat[$n] = $true
            } else {
                throw "Параметр -$n потребує значення — '$arg' без нього. Приклад: -$n <значення>."
            }
        }
    }

    # Спільні параметри передаються лише тим командам, які їх ОГОЛОШУЮТЬ. Команда оголошує лише те,
    # що вживає (це тримає тест): оголошений «для splat» і непрочитаний параметр мовчки нічого не
    # звужував би. Переданий людиною параметр, якого команда не приймає, — зупинка з переліком, а не тиша.
    $accepted = @((Get-Command -Name $functionName).Parameters.Keys)
    $common = @{ Context = $context }
    foreach ($shared in @(
            @{ Name = 'Workspace'; Given = [bool]$Workspace; Value = $Workspace },
            @{ Name = 'Source';    Given = [bool]$Source;    Value = $Source },
            @{ Name = 'Apply';     Given = [bool]$Apply;     Value = [bool]$Apply })) {
        if ($accepted -contains $shared.Name) { $common[$shared.Name] = $shared.Value; continue }
        if ($shared.Given) {
            $alsoAccepts = @('Workspace', 'Source', 'Apply') | Where-Object { $accepted -contains $_ }
            $what = if ($alsoAccepts) { "приймає лише: $($alsoAccepts -join ', ')" } else { 'не приймає жодного зі спільних параметрів' }
            throw "Команда '$Command' не приймає -$($shared.Name): вона $what."
        }
    }
    # Контракт суворий: людське команда друкує сама через Write-Host, а в success stream
    # (те, що потрапляє сюди, у $result) повертає лише $null або {ExitCode; …} — жодного
    # третього варіанту. Диспетчер повернене значення НЕ виводить, тільки читає ExitCode.
    $result = & $functionName @common @splat
} catch {
    # Сирий throw команди, префлайту чи розбору аргументів — охайний рядок і код 1 (не стек PowerShell,
    # що топив би зібрані знахідки). Контракт кодів виходу — у коментарі вище.
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
if ($null -ne $result -and ($result.PSObject.Properties.Name -contains 'ExitCode') -and $result.ExitCode -ne 0) {
    exit $result.ExitCode
}
# Успіх — явний код 0 (§5 п.3): без `exit` у `pwsh -Command "& kit.ps1 …"` $LASTEXITCODE лишається
# порожнім, і виклик не відрізнить успіх від «не виставлено».
exit 0
