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
    # хвилясте підкреслення) суперечить охайному [-]-виводу самого check. Код 1 тут —
    # диспетчерська відмова ще до виклику команди (рев'ю B3 раунд 3, Step 5а: код був 2 —
    # розійшовся з таблицею нижче, зайнявши те саме число, що штатний частковий успіх sync).
    # Контракт кодів виходу: 0 — виконано; 1 — зупинка (throw будь-де: невідома команда,
    # префлайт, розбір аргументів, сама команда) або check із помилками; 2 — лише sync:
    # дзеркало оновлено, злиття не виконано; 3 — verify і session-check: є що робити. Тобто 2 і 3 —
    # коди команд, які ВІДПРАЦЮВАЛИ, а не «не запустились узагалі»: код виходу сам не
    # розрізняє «диспетчер відмовив» від «команда завершилась частковим успіхом» —
    # розрізняти треба з тексту виводу.
    Write-Host "$what Доступні: $($available -join ', '). Приклад: pwsh tools/kit.ps1 check -RepoRoot ." -ForegroundColor Red
    exit 1
}

Import-Module (Join-Path $commandsDir "$Command.psm1") -Force
$functionName = 'Invoke-Kit' + ((($Command -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
if (-not (Get-Command -Name $functionName -ErrorAction SilentlyContinue)) {
    # Той самий дефект подачі, що й вище (Правка 6б, живий прогін задачі 11), лише рядком
    # нижче: не throw, код 1 (рев'ю B3 раунд 3) — так само «команда не запустилась
    # узагалі», а не «команда відпрацювала й знайшла помилки».
    Write-Host "Модуль команди commands/$Command.psm1 не експортує функцію $functionName." -ForegroundColor Red
    exit 1
}

# Префлайт, розбір аргументів і сам виклик команди — під одним try/catch (рев'ю B3 раунд 3,
# Step 5а): раніше Invoke-KitPreflight і цикл розбору CommandArgs стояли ПОЗА try/catch, і їхній
# throw діставався до самого верху скрипта — pwsh друкував сирий стек (номер рядка, хвилясте
# підкреслення) замість охайного Write-Host, хоча код виходу випадково збігався (1, поведінка
# pwsh -File за замовчуванням на непійманий termination error). Один try/catch на весь
# диспетчерський розбір дає одну зупинку одним стилем на throw БУДЬ-ДЕ в цій частині — команда,
# префлайт, розбір аргументів, невідомий параметр команди.
try {
    # check і session-check — діагностика: вони мусять ДОПОВІСТИ про суперечливий репозиторій, а не впасти на
    # ньому (Task 6, Step 3а). Решта команд без чистого префлайту не має з чим працювати.
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
            # $true лише справжньому [switch]-параметру команди (рев'ю B3 раунд 3, Step 5а):
            # раніше -Ім'я без значення завжди давало $true, і воно мовчки в'язалось із будь-яким
            # типом параметра — найгірше на [Nullable[int]] (bool -> int, True стає 1): "kit verify
            # -Version -Ref main" (забули число) тихо звіряло проти версії 1 сховища. Питаємо ТИП
            # параметра функції команди напряму, не вгадуємо за формою CLI.
            #
            # Межа, яку свідомо НЕ обробляємо (задокументовано, не випадково пропущено): PowerShell
            # дозволяє скорочувати імена параметрів (-Ver замість -Version) при справжньому виклику
            # функції, але $functionCmd.Parameters — словник ПОВНИХ імен, і Parameters['Ver'] на
            # скороченні не знайде нічого навіть для параметра, який насправді [switch]. Тому
            # скорочене ім'я [switch]-параметра тут дасть хибну зупинку "потребує значення" замість
            # тихого прийняття як прапорця. Ніде в kit (skills, документація, тести) скорочені імена
            # не використовуються — усі приклади й усі команди пишуть повне ім'я параметра, тож ціна
            # цієї межі не впала на жоден наявний сценарій; повне ім'я лишається єдиним підтримуваним
            # способом викликати kit.ps1 з CLI.
            $functionCmd = Get-Command -Name $functionName
            $param = $functionCmd.Parameters[$n]
            if ($param -and $param.ParameterType -eq [switch]) {
                $splat[$n] = $true
            } else {
                throw "Параметр -$n потребує значення — '$arg' без нього. Приклад: -$n <значення>."
            }
        }
    }

    $common = @{ Context = $context; Workspace = $Workspace; Source = $Source; Apply = [bool]$Apply }
    # Контракт суворий: людське команда друкує сама через Write-Host, а в success stream
    # (те, що потрапляє сюди, у $result) повертає лише $null або {ExitCode; …} — жодного
    # третього варіанту. Диспетчер повернене значення НЕ виводить, тільки читає ExitCode.
    $result = & $functionName @common @splat
} catch {
    # Правка 8 (фінальне рев'ю) — той самий дефект подачі, що вище (Правка 6б, живий
    # прогін задачі 11): сирий throw усередині команди (наприклад Select-KitSources на
    # невідомому -Workspace/-Source) без цього виходив стеком PowerShell і топив уже
    # зібрані check-ом знахідки. Код 1 тут (рев'ю B3 раунд 3, Step 5а — був 2, конфліктував
    # зі штатним частковим успіхом sync) — та сама диспетчерська відмова, що й вище:
    # команда (чи префлайт, чи розбір аргументів усередині цього самого try) впала до
    # того, як повернула структурований результат. Контракт кодів виходу команд — у
    # коментарі вище.
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
if ($null -ne $result -and ($result.PSObject.Properties.Name -contains 'ExitCode') -and $result.ExitCode -ne 0) {
    exit $result.ExitCode
}
