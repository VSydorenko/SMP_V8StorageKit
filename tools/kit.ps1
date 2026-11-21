#Requires -Version 7
<#
.SYNOPSIS
    Єдиний PowerShell-диспетчер kit: pwsh -NoProfile -File tools/kit.ps1 <команда> [аргументи].
.DESCRIPTION
    Навмисно БЕЗ param-блоку: усі токени доходять сирими, і диспетчер розбирає їх сам. Параметри
    скрипта перехоплювали б однойменні токени команд ще на прив'язці PowerShell (`sdd fix 3 -Source
    controller` віддав би -Source диспетчеру).

    Токени: змінна оточення KIT_ARGV (JSON-масив рядків; її пише kit.exe) — диспетчер читає її й
    прибирає зі свого оточення до будь-якої іншої дії, щоб її не успадкували git, раннер чи 1cv8;
    змінної немає — $args (прямий виклик). Аргументи `pwsh -File` PowerShell переписує сам
    (`-Apply:false` доходить як `-Apply` + `False`), тому команда сховища не приймає позиційних
    токенів: такий токен — помилка виклику, команда не запускається.

    Команди процесу (tools/commands/process-commands.txt): імпорт лише розділу «процес» з
    tools/lib/module-order.txt, сирі аргументи команді, корінь — поточна тека (ADR-0003).
    Команди сховища: імпорт усього module-order.txt, розбір ConvertFrom-KitArguments за
    специфікацією з сигнатури Invoke-Kit<Команда> ([switch]/[bool] — прапорець, [string[]] —
    список, решта — рядок, без Context) плюс -RepoRoot (умовчання — поточна тека), префлайт і
    виклик іменованою сплатою (позиційної прив'язки функцій тут немає).

    Контракт кодів виходу — один для всіх команд (tools/lib/KitCli.psm1): 0 — так; 1 — зупинка;
    2 — помилка виклику; 3 — не перевірено; 4 — виконано, є наступний крок. Помилка — перший рядок
    stderr `<команда>: ERROR …`.
.EXAMPLE
    pwsh -NoProfile -File tools/kit.ps1 check -RepoRoot <шлях до репо-споживача>
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Кирилиця в повідомленнях доходить до людини й до тестів лише при UTF-8 (див. Run-Tests.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Stop-KitDispatch([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine("kit: ERROR $Message")
    exit $Code
}

# ---------- токени: KIT_ARGV або $args ----------
$tokens = $null
$kitArgv = [Environment]::GetEnvironmentVariable('KIT_ARGV')
if ($null -ne $kitArgv) {
    [Environment]::SetEnvironmentVariable('KIT_ARGV', $null)
    # System.Text.Json, не ConvertFrom-Json: той перетворює рядки, схожі на дату, на DateTime.
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($kitArgv)
        if ($doc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'очікувався JSON-масив рядків' }
        $tokens = [string[]]@(foreach ($el in $doc.RootElement.EnumerateArray()) {
                if ($el.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw "елемент масиву — $($el.ValueKind), очікувався рядок" }
                $el.GetString()
            })
    } catch {
        Stop-KitDispatch "KIT_ARGV не розібрано: $($_.Exception.Message)" 2
    }
} else {
    $tokens = [string[]]@(foreach ($a in $args) { [string]$a })
}

$command = if ($tokens.Count) { $tokens[0] } else { '' }
$rest = [string[]]@($tokens | Select-Object -Skip 1)

$libDir = Join-Path $PSScriptRoot 'lib'
$commandsDir = Join-Path $PSScriptRoot 'commands'
$processCommands = @(Get-Content -LiteralPath (Join-Path $commandsDir 'process-commands.txt') -Encoding UTF8 |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
$storageCommands = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.psm1' -File | ForEach-Object BaseName |
    Where-Object { $processCommands -notcontains $_ })

if (-not $command -or ($processCommands -notcontains $command -and $storageCommands -notcontains $command)) {
    $what = if ($command) { "невідома команда '$command'" } else { 'команду не вказано' }
    Stop-KitDispatch "$what; доступні: $((@($storageCommands) + @($processCommands) | Sort-Object -Unique) -join ', ')" 2
}

# ---------- команда процесу: лише розділ «процес» module-order.txt ----------
$isProcess = $processCommands -contains $command
$inSection = -not $isProcess
foreach ($line in Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -match '^#\s*==\s*процес\s*==') { $inSection = $true; continue }
    if (-not $inSection -or -not $t -or $t.StartsWith('#')) { continue }
    Import-Module (Join-Path $libDir "$t.psm1") -Force
}
if (-not (Get-Command -Name Invoke-KitProcessEntry -ErrorAction SilentlyContinue)) {
    Stop-KitDispatch 'у tools/lib/module-order.txt немає розділу «# == процес ==» з KitCli' 1
}

if ($isProcess) {
    exit (Invoke-KitProcessEntry -Command $command -Arguments $rest -RepoRoot (Get-Location).Path -ToolsDir $PSScriptRoot)
}

# ---------- команда сховища ----------
Import-Module (Join-Path $commandsDir "$command.psm1") -Force
$functionName = Get-KitProcessFunctionName -Command $command
$functionCmd = Get-Command -Name $functionName -ErrorAction SilentlyContinue
if (-not $functionCmd) {
    Write-KitError -Command $command -Message "модуль commands/$command.psm1 не експортує функцію $functionName"
    exit 1
}

# Специфікація розбору — із сигнатури функції команди. -Workspace/-Source/-Apply отримує лише та
# команда, що їх оголошує: інакше це «невідомий параметр», а не мовчки проігнорований.
$skip = @('Context') + [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
$params = @{}
$spec = @{ RepoRoot = 'string' }
foreach ($p in $functionCmd.Parameters.Values) {
    if ($skip -contains $p.Name) { continue }
    $params[$p.Name] = $p
    $spec[$p.Name] = if ($p.ParameterType -eq [switch] -or $p.ParameterType -eq [bool]) { 'switch' }
                     elseif ($p.ParameterType -eq [string[]]) { 'list' }
                     else { 'string' }
}

try {
    $parsed = ConvertFrom-KitArguments -Arguments $rest -Spec $spec
} catch {
    Write-KitError -Command $command -Message $_.Exception.Message -ExitCode 2
    exit 2
}
if ($parsed.Help) {
    $usage = foreach ($n in @($spec.Keys | Sort-Object)) {
        switch ($spec[$n]) { 'switch' { "[-$n]" } 'list' { "[-$n <значення> …]" } default { "[-$n <значення>]" } }
    }
    Write-KitLine "usage: kit $command $($usage -join ' ')"
    exit 0
}
if ($parsed.Positional.Count) {
    Write-KitError -Command $command -ExitCode 2 -Message ("позиційний токен '$($parsed.Positional[0])': команди сховища приймають лише -Ім'я значення і -Прапорець " +
        "(pwsh -File розщеплює -Ім'я:значення на два токени — пиши -Ім'я значення)")
    exit 2
}

# Значення — у тип параметра функції до виклику: помилка перетворення — помилка виклику (2), а не зупинка.
$splat = @{}
foreach ($n in @($parsed.Named.Keys)) {
    if ($n -eq 'RepoRoot') { continue }
    $v = $parsed.Named[$n]
    $type = $params[$n].ParameterType
    if ($type -eq [switch]) { $splat[$n] = [switch][bool]$v; continue }
    if ($type -eq [bool]) { $splat[$n] = [bool]$v; continue }
    if ($type -eq [string[]]) { $splat[$n] = [string[]]@($v); continue }
    if ($type -eq [string] -or $type -eq [object]) { $splat[$n] = [string]$v; continue }
    try {
        $splat[$n] = [System.Management.Automation.LanguagePrimitives]::ConvertTo($v, $type)
    } catch {
        $target = [Nullable]::GetUnderlyingType($type) ?? $type
        Write-KitError -Command $command -ExitCode 2 -Message "-${n}: значення '$v' не перетворюється на $($target.FullName)"
        exit 2
    }
}
# Атрибути перевірки параметра (ValidateSet, ValidateRange) — теж до префлайту: помилка аргументу з CLI —
# код 2 незалежно від стану репозиторію. Перевіряє сам PowerShell: змінна з цими атрибутами не приймає
# недопустимого значення ще в конструкторі.
foreach ($n in @($splat.Keys)) {
    $checks = @($params[$n].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateArgumentsAttribute] })
    if (-not $checks.Count) { continue }
    $attrs = [System.Collections.ObjectModel.Collection[Attribute]]::new()
    foreach ($c in $checks) { $attrs.Add($c) }
    try {
        $null = [System.Management.Automation.PSVariable]::new($n, $splat[$n], [System.Management.Automation.ScopedItemOptions]::None, $attrs)
    } catch {
        $rule = @(foreach ($c in $checks) {
                if ($c -is [System.Management.Automation.ValidateSetAttribute]) { "допустимо: $($c.ValidValues -join ', ')" }
                elseif ($c -is [System.Management.Automation.ValidateRangeAttribute]) { "діапазон $($c.MinRange)..$($c.MaxRange)" }
                else { $c.GetType().Name -replace 'Attribute$', '' }
            }) -join '; '
        Write-KitError -Command $command -ExitCode 2 -Message "-${n}: значення '$($splat[$n])' не проходить перевірку параметра ($rule)"
        exit 2
    }
}
$repoRoot = if ($parsed.Named.ContainsKey('RepoRoot')) { [string]$parsed.Named['RepoRoot'] } else { (Get-Location).Path }

# Префлайт і сама команда — під одним try/catch: throw будь-де — один рядок `<команда>: ERROR …` і код 1
# (або код із Data['KitExitCode'], або 2 за помилки прив'язки — нижче), а не сирий стек pwsh.
try {
    # check і session-check — діагностика: вони мусять ДОПОВІСТИ про суперечливий репозиторій, а не впасти на
    # ньому. Решта команд без чистого префлайту не має з чим працювати.
    $context = Invoke-KitPreflight -RepoRoot $repoRoot -Lenient:($command -in @('check', 'session-check'))
    # Контракт суворий: людське команда друкує сама через Write-Host, а в success stream повертає лише
    # $null або {ExitCode; …}. Диспетчер повернене значення НЕ виводить, тільки читає ExitCode.
    $result = & $functionName -Context $context @splat
} catch {
    $ex = $_.Exception
    # Помилка прив'язки параметра самої функції команди (ValidateSet, ValidateRange) — аргумент з CLI, тобто
    # помилка виклику (2). Прив'язка всередині команди (throw після старту) — зупинка (1).
    $code = if ($null -ne $ex.Data -and $ex.Data.Contains('KitExitCode')) { [int]$ex.Data['KitExitCode'] }
            elseif ($ex -is [System.Management.Automation.ParameterBindingException] -and $_.InvocationInfo -and
                    $_.InvocationInfo.MyCommand -and $_.InvocationInfo.MyCommand.Name -eq $functionName) { 2 }
            else { 1 }
    Write-KitError -Command $command -Message $ex.Message -ExitCode $code
    exit $code
}
if ($null -ne $result -and ($result.PSObject.Properties.Name -contains 'ExitCode') -and $result.ExitCode -ne 0) {
    exit $result.ExitCode
}
# Успіх — явний код 0: без `exit` у `pwsh -Command "& kit.ps1 …"` $LASTEXITCODE лишається
# порожнім, і виклик не відрізнить успіх від «не виставлено».
exit 0
