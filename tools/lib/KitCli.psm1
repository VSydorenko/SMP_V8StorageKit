#Requires -Version 7
# Ported from agent-kit 0.9.1 lib/cli.mjs, modified.
<#
    Спільна поведінка команд kit (процесу й сховища): чесний код виходу, один рядок помилки,
    рядок `next:` і розбір аргументів у стилі PowerShell.

    Контракт (один для всіх команд, спека #51 D3):
      0 — так / виконано; 1 — зупинка / ні / відмова; 2 — помилка виклику (аргументи, невідома
      команда); 3 — НЕ ПЕРЕВІРЕНО: перевірка не відбулась (немає поля профілю, порожній діапазон,
      таймаут) — ніколи не зелений; 4 — виконано, є наступний крок (sync: дзеркало оновлено, злиття
      ні; verify/session-check: є що робити).
      Перший рядок stderr будь-якої помилки — `<команда>: ERROR <причина>`: у полі `| tail`
      ховав причину, а агенти шукали її в різних форматах.
      Останній рядок `next: <точний наступний крок>` — лише коли наступний крок детермінований;
      успіх без наступного кроку рядка `next:` не друкує.

    Вхід — tools/kit.ps1; команди процесу називає tools/commands/process-commands.txt.
#>
Set-StrictMode -Version Latest

# ---------- помилки з кодом виходу ----------

function New-KitCliError {
    <# Виняток із кодом виходу в Data['KitExitCode']: throw (New-KitCliError 'причина' 1). #>
    param([Parameter(Mandatory)][string]$Message, [ValidateSet(1, 2, 3, 4)][int]$ExitCode = 1)
    $e = [System.Exception]::new($Message)
    $e.Data['KitExitCode'] = $ExitCode
    $e
}

function New-KitRefusal {
    <# Код 1: команда відмовилась або перевірка провалилась. #>
    param([Parameter(Mandatory)][string]$Message)
    New-KitCliError -Message $Message -ExitCode 1
}

function New-KitUsageError {
    <# Код 2: помилка виклику (аргументи, невідома підкоманда). #>
    param([Parameter(Mandatory)][string]$Message)
    New-KitCliError -Message $Message -ExitCode 2
}

function New-KitNotChecked {
    <# Код 3: перевірка не відбулась — ніколи не зелений результат. #>
    param([Parameter(Mandatory)][string]$Message)
    New-KitCliError -Message $Message -ExitCode 3
}

# ---------- вивід ----------

function Write-KitLine {
    <# Рядок у stdout без форматування PowerShell (вивід читає агент через Bash). #>
    param([AllowEmptyString()][string]$Text = '')
    [Console]::Out.WriteLine($Text)
}

function Write-KitNext {
    <# Останній рядок успіху: точна наступна команда. #>
    param([Parameter(Mandatory)][string]$Text)
    [Console]::Out.WriteLine("next: $Text")
}

function Write-KitError {
    <#
        Перший рядок stderr — `<команда>: ERROR <причина>`. Решта тексту (після першого рядка) —
        підказка другими рядками. Для помилки виклику повний usage не друкуємо — лише вказівку
        на `-Help`: довгий usage після помилки обрізав причину в `| tail`.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Message,
        [int]$ExitCode = 1
    )
    $lines = @($Message -split "\r?\n")
    $first = $lines[0] -replace "^$([regex]::Escape($Command)):\s*(ERROR\s*)?", ''
    [Console]::Error.WriteLine("${Command}: ERROR $first")
    if ($ExitCode -eq 2) { [Console]::Error.WriteLine("usage: $Command -Help") }
    elseif ($lines.Count -gt 1) {
        $hint = ($lines | Select-Object -Skip 1) -join "`n"
        if ($hint.Trim()) { [Console]::Error.WriteLine($hint.Trim("`n")) }
    }
}

# ---------- аргументи ----------

function ConvertFrom-KitArguments {
    <#
    .SYNOPSIS
        Розбір сирих аргументів команди процесу: позиційні + `-Ім'я значення` / `-Ім'я:значення`
        / `-Прапорець`.
    .DESCRIPTION
        -Spec — @{ Model = 'string'; Exclude = 'list'; Branch = 'switch' }. Імена нечутливі до
        регістру; у Named лежать імена зі Spec. `-Help` (і звичне `--help`) приймається завжди.

        Невідоме ім'я, форма `--name` замість `-Name`, параметр без значення — помилка виклику
        (код 2). Значенням стає наступний токен, якщо він не є іменем зі Spec: так `-Note "-x"`
        працює, а `-Note -Model sonnet` (забули текст) — помилка, а не нотатка «-Model».
        Токен на кшталт `-5` (цифра після мінуса) — позиційний, не ім'я.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [hashtable]$Spec = @{}
    )
    $names = @{}
    foreach ($k in $Spec.Keys) {
        if ($Spec[$k] -notin @('string', 'list', 'switch')) { throw "ConvertFrom-KitArguments: тип '$($Spec[$k])' параметра $k — string, list або switch" }
        $names[$k.ToLowerInvariant()] = $k
    }
    $positional = [System.Collections.Generic.List[string]]::new()
    $named = @{}
    $help = $false
    $isName = { param($t) $t -match '^-([A-Za-z][A-Za-z0-9]*)(?::.*)?$' -and ($names.ContainsKey($Matches[1].ToLowerInvariant()) -or $Matches[1] -eq 'Help') }
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $t = [string]$Arguments[$i]
        if ($t -eq '--help' -or $t -eq '-h') { $help = $true; continue }
        if ($t -match '^--([A-Za-z][\w-]*)') {
            throw (New-KitUsageError "форма '$t' не підтримується: параметри пишуться як -Ім'я ($( ($Matches[1] -split '-' | ForEach-Object { if ($_) { $_.Substring(0,1).ToUpper() + $_.Substring(1) } }) -join '' ))")
        }
        if ($t -notmatch '^-([A-Za-z][A-Za-z0-9]*)(?::(.*))?$') { $positional.Add($t); continue }
        $raw = $Matches[1]
        $inline = if ($Matches.ContainsKey(2)) { $Matches[2] } else { $null }
        if ($raw -eq 'Help') { $help = $true; continue }
        $key = $raw.ToLowerInvariant()
        if (-not $names.ContainsKey($key)) {
            $known = @($Spec.Keys | Sort-Object | ForEach-Object { "-$_" })
            throw (New-KitUsageError "невідомий параметр -$raw$(if ($known) { " (відомі: $($known -join ', '))" } else { ' (команда не має іменованих параметрів)' })")
        }
        $name = $names[$key]
        $type = $Spec[$name]
        if ($type -eq 'switch') {
            if ($null -eq $inline) { $named[$name] = $true; continue }
            if ($inline -notin @('true', 'false', '$true', '$false')) { throw (New-KitUsageError "-${name}: прапорець без значення (або -${name}:true|false)") }
            $named[$name] = $inline -in @('true', '$true')
            continue
        }
        $value = $inline
        if ($null -eq $value) {
            if ($i + 1 -ge $Arguments.Count -or (& $isName ([string]$Arguments[$i + 1]))) { throw (New-KitUsageError "-$name потребує значення") }
            $value = [string]$Arguments[++$i]
        }
        if ($type -eq 'list') {
            if (-not $named.ContainsKey($name)) { $named[$name] = [System.Collections.Generic.List[string]]::new() }
            $named[$name].Add($value)
        } else { $named[$name] = $value }
    }
    [pscustomobject]@{ Positional = [string[]]$positional.ToArray(); Named = $named; Help = $help }
}

# ---------- вхід команди процесу ----------

function Get-KitProcessCommandNames {
    <# Імена команд процесу з tools/commands/process-commands.txt (рядки з # — коментарі). #>
    param([Parameter(Mandatory)][string]$ToolsDir)
    $file = Join-Path $ToolsDir 'commands/process-commands.txt'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    @(Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Get-KitProcessFunctionName {
    param([Parameter(Mandatory)][string]$Command)
    'Invoke-Kit' + ((($Command -split '-') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')
}

function Invoke-KitProcessEntry {
    <#
    .SYNOPSIS
        Запуск команди процесу: модуль tools/commands/<команда>.psm1 експортує
        Invoke-Kit<Команда> -Arguments [string[]] -RepoRoot <шлях> і повертає код виходу (int).
    .DESCRIPTION
        Кличе tools/kit.ps1 для команди процесу. Префлайту
        сховища тут немає: команди процесу не потребують маніфесту (ADR-0003).

        Будь-який виняток стає рядком `<команда>: ERROR …` і кодом із Data['KitExitCode']
        (типово 1). Команда, що повернула в pipeline щось, крім одного цілого, порушила контракт —
        це провал (1), а не тихий нуль.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ToolsDir
    )
    $known = @(Get-KitProcessCommandNames -ToolsDir $ToolsDir)
    $label = if ($Command) { $Command } else { 'kit' }
    if (-not $Command -or $known -notcontains $Command) {
        $what = if ($Command) { "невідома команда процесу '$Command'" } else { 'команду не вказано' }
        Write-KitError -Command $label -Message "$what; доступні: $(if ($known) { $known -join ', ' } else { 'жодної' })" -ExitCode 1
        return 2
    }
    $module = Join-Path $ToolsDir "commands/$Command.psm1"
    $fn = Get-KitProcessFunctionName -Command $Command
    try {
        if (-not (Test-Path -LiteralPath $module)) { throw "немає модуля commands/$Command.psm1" }
        Import-Module $module -Force -Global
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { throw "модуль commands/$Command.psm1 не експортує $fn" }
        $result = @(& $fn -Arguments $Arguments -RepoRoot $RepoRoot)
    } catch {
        $ex = $_.Exception
        $code = if ($null -ne $ex.Data -and $ex.Data.Contains('KitExitCode')) { [int]$ex.Data['KitExitCode'] } else { 1 }
        Write-KitError -Command $label -Message $ex.Message -ExitCode $code
        if (-not ($null -ne $ex.Data -and $ex.Data.Contains('KitExitCode')) -and $_.ScriptStackTrace) {
            [Console]::Error.WriteLine((@($_.ScriptStackTrace -split "\r?\n") | Select-Object -First 3) -join "`n")
        }
        return $code
    }
    if ($result.Count -ne 1 -or $result[0] -isnot [int]) {
        Write-KitError -Command $label -Message "контракт команди порушено: $fn має повернути один код виходу (int), повернула $($result.Count) значень" -ExitCode 1
        return 1
    }
    return $result[0]
}

Export-ModuleMember -Function New-KitCliError, New-KitRefusal, New-KitUsageError, New-KitNotChecked,
    Write-KitLine, Write-KitNext, Write-KitError, ConvertFrom-KitArguments,
    Get-KitProcessCommandNames, Get-KitProcessFunctionName, Invoke-KitProcessEntry
