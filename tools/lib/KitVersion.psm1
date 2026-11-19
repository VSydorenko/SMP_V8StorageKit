#Requires -Version 7
# Ported from agent-kit 0.9.1 lib/kit-version.mjs, modified.
<#
    Версія плагіна й журнал змін. Плагін читається з кешу споживача, тож оновлення діє одразу
    скрізь, а проєкт, підключений раніше, не знає, що відстав. Тому:
      версія плагіна  — .claude-plugin/plugin.json, поле version;
      версія проєкту  — kit.version у .agents/kit.profile.json (поля немає — 0.1.0);
      що зробити при оновленні — чекліст запису в CHANGELOG.md у корені плагіна.
    Тут єдиний розбір формату для kit-setup, kit-scan і перевірок; хук старту сесії читає той самий
    формат власним мінімальним кодом (він навмисно без модулів) — міняючи формат, міняй обидва.

    Функції чисті: нічого не друкують, помилки форми журналу повертають списком Problems.
#>
Set-StrictMode -Version Latest

$script:ChangelogFile = 'CHANGELOG.md'
$script:PluginFile = '.claude-plugin/plugin.json'
$script:ProfileFile = '.agents/kit.profile.json'
# Проєкти, підключені до появи версій, поля не мають: це стан першого підключення.
$script:DefaultProjectVersion = '0.1.0'
$script:ChangesHeading = 'Що змінилось'
$script:StepsHeading = 'Чекліст оновлення проєкту'
$script:NoAction = 'Нічого робити не треба.'

function ConvertTo-KitVersion {
    <# [version] або $null для не-semver (рівно x.y.z). #>
    param($Value)
    if ($Value -is [string] -and $Value -match '^\d+\.\d+\.\d+$') { return [version]$Value }
    return $null
}

function Compare-KitVersion {
    <# -1 / 0 / 1; не-semver — виняток. #>
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $x = ConvertTo-KitVersion $A
    $y = ConvertTo-KitVersion $B
    if (-not $x) { throw "не версія x.y.z: $A" }
    if (-not $y) { throw "не версія x.y.z: $B" }
    $x.CompareTo($y)
}

function Get-KitBumpKind {
    <# Який розряд піднято від From до To: major | minor | patch | $null (не вище). #>
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if ((Compare-KitVersion -A $To -B $From) -le 0) { return $null }
    $x = ConvertTo-KitVersion $From
    $y = ConvertTo-KitVersion $To
    if ($x.Major -ne $y.Major) { 'major' } elseif ($x.Minor -ne $y.Minor) { 'minor' } else { 'patch' }
}

function Get-KitPluginRoot {
    <# Корінь плагіна: tools/lib → tools → корінь. #>
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Read-KitChangelog {
    <#
    .SYNOPSIS
        Записи журналу згори вниз і проблеми форми.
    .DESCRIPTION
        Запис: Version, Date, Line, Changes, Steps, NoAction. Проблема: Line, What.
        Пункт чекліста — один рядок `- [ ] …`; замість нього допустимий рядок «Нічого робити не треба.».
        Вступ файла (до першого `## <цифра>`) — опис формату зі своїми заголовками, не запис.
    #>
    param([string]$Path, [string]$Text)
    $problems = [System.Collections.Generic.List[object]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not $PSBoundParameters.ContainsKey('Text')) {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $problems.Add([pscustomobject]@{ Line = 1; What = "$script:ChangelogFile відсутній" })
            return [pscustomobject]@{ Entries = @(); Problems = $problems.ToArray() }
        }
        $Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    $entry = $null
    $section = $null
    $n = 0
    foreach ($raw in ($Text -split "\r?\n")) {
        $n++
        $line = $raw.TrimEnd()
        if ($line.StartsWith('## ')) {
            if (-not $entry -and $line -notmatch '^## \d') { continue }
            $m = [regex]::Match($line, '^## (\S+) — (\S+)\s*$')
            $entry = [pscustomobject]@{
                Version = if ($m.Success) { $m.Groups[1].Value } else { $null }
                Date = if ($m.Success) { $m.Groups[2].Value } else { $null }
                Line = $n
                Changes = [System.Collections.Generic.List[string]]::new()
                Steps = [System.Collections.Generic.List[string]]::new()
                NoAction = $false
                Sections = [System.Collections.Generic.HashSet[string]]::new()
            }
            $entries.Add($entry)
            $section = $null
            if (-not $m.Success -or -not (ConvertTo-KitVersion $m.Groups[1].Value) -or $m.Groups[2].Value -notmatch '^\d{4}-\d{2}-\d{2}$') {
                $problems.Add([pscustomobject]@{ Line = $n; What = 'заголовок запису має бути "## <x.y.z> — <РРРР-ММ-ДД>"' })
            }
            continue
        }
        if (-not $entry) { continue }
        if ($line.StartsWith('### ')) {
            $name = $line.Substring(4).Trim()
            $section = switch ($name) { $script:ChangesHeading { 'changes' } $script:StepsHeading { 'steps' } default { $null } }
            if (-not $section) { $problems.Add([pscustomobject]@{ Line = $n; What = "невідомий розділ `"$name`" — лише `"### $script:ChangesHeading`" або `"### $script:StepsHeading`"" }) }
            else { [void]$entry.Sections.Add($section) }
            continue
        }
        if (-not $line.Trim() -or -not $section) { continue }
        if ($section -eq 'changes') {
            if ($line.StartsWith('- ')) { $entry.Changes.Add($line.Substring(2).Trim()) }
            continue
        }
        if ($line -match '^- \[[ xX]\] (.+)$') { $entry.Steps.Add($Matches[1].Trim()) }
        elseif ($line.Trim() -eq $script:NoAction) { $entry.NoAction = $true }
        else { $problems.Add([pscustomobject]@{ Line = $n; What = "рядок чекліста має бути `"- [ ] <одна дія>`" або `"$script:NoAction`"" }) }
    }
    foreach ($e in $entries) {
        if (-not $e.Sections.Contains('changes')) { $problems.Add([pscustomobject]@{ Line = $e.Line; What = "$($e.Version): немає розділу `"### $script:ChangesHeading`"" }) }
        if (-not $e.Sections.Contains('steps')) { $problems.Add([pscustomobject]@{ Line = $e.Line; What = "$($e.Version): немає розділу `"### $script:StepsHeading`"" }) }
        elseif ($e.Steps.Count -and $e.NoAction) { $problems.Add([pscustomobject]@{ Line = $e.Line; What = "$($e.Version): у чеклісті є і пункти, і `"$script:NoAction`" — лиши одне" }) }
        elseif (-not $e.Steps.Count -and -not $e.NoAction) { $problems.Add([pscustomobject]@{ Line = $e.Line; What = "$($e.Version): порожній чекліст — додай `"- [ ] …`" або `"$script:NoAction`"" }) }
    }
    # Новий запис — зверху: версії строго спадають.
    for ($i = 1; $i -lt $entries.Count; $i++) {
        $a = $entries[$i - 1]
        $b = $entries[$i]
        if ((ConvertTo-KitVersion $a.Version) -and (ConvertTo-KitVersion $b.Version) -and (Compare-KitVersion -A $a.Version -B $b.Version) -le 0) {
            $problems.Add([pscustomobject]@{ Line = $b.Line; What = "$($b.Version) не нижча за $($a.Version) — найновіший запис зверху, кожна версія один раз" })
        }
    }
    [pscustomobject]@{ Entries = $entries.ToArray(); Problems = $problems.ToArray() }
}

function Get-KitPluginInfo {
    <# Версія плагіна й журнал із теки плагіна: Version, Entries, Problems. Немає plugin.json — «не перевірено». #>
    param([string]$PluginRoot = (Get-KitPluginRoot))
    $pj = Join-Path $PluginRoot $script:PluginFile
    if (-not (Test-Path -LiteralPath $pj -PathType Leaf)) { throw (New-KitNotChecked "немає $script:PluginFile у $PluginRoot") }
    try { $version = [string](Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version }
    catch { throw (New-KitNotChecked "не читається ${pj}: $($_.Exception.Message)") }
    $log = Read-KitChangelog -Path (Join-Path $PluginRoot $script:ChangelogFile)
    [pscustomobject]@{ Version = $version; Entries = $log.Entries; Problems = $log.Problems }
}

function Get-KitProjectVersion {
    <#
    .SYNOPSIS
        Версія проєкту з профілю: Version, Source, Error.
    .DESCRIPTION
        Source: profile — поле є; default — профіль без поля (підключено до версій, 0.1.0);
        none — профілю немає; invalid — поле не x.y.z або профіль не читається (тоді Error).
    #>
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root $script:ProfileFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ Version = $null; Source = 'none'; Error = $null } }
    try { $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return [pscustomobject]@{ Version = $null; Source = 'invalid'; Error = "не читається ${script:ProfileFile}: $($_.Exception.Message)" } }
    $kit = if ($data -is [System.Collections.IDictionary] -and $data.Contains('kit')) { $data['kit'] } else { $null }
    if (-not ($kit -is [System.Collections.IDictionary]) -or -not $kit.Contains('version')) {
        return [pscustomobject]@{ Version = $script:DefaultProjectVersion; Source = 'default'; Error = $null }
    }
    $v = $kit['version']
    if (-not (ConvertTo-KitVersion $v)) {
        return [pscustomobject]@{ Version = $null; Source = 'invalid'; Error = "kit.version `"$v`" у $script:ProfileFile не є x.y.z" }
    }
    [pscustomobject]@{ Version = [string]$v; Source = 'profile'; Error = $null }
}

function Get-KitPendingEntries {
    <# Записи з версіями в (From, To], від старшого до новішого — порядок виконання. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    @($Entries | Where-Object {
            (ConvertTo-KitVersion $_.Version) -and (Compare-KitVersion -A $_.Version -B $From) -gt 0 -and (Compare-KitVersion -A $_.Version -B $To) -le 0
        } | Sort-Object { ConvertTo-KitVersion $_.Version })
}

function Test-KitPluginRepo {
    <# Чи Root — сам плагін (головний checkout чи worktree): тоді версія проєкту не має сенсу. #>
    param([Parameter(Mandatory)][string]$Root, [string]$PluginRoot = (Get-KitPluginRoot))
    try {
        $name = { param($d) (Get-Content -LiteralPath (Join-Path $d $script:PluginFile) -Raw -Encoding UTF8 | ConvertFrom-Json).name }
        $a = & $name $Root
        $b = & $name $PluginRoot
        return ([bool]$a -and $a -eq $b)
    } catch { return $false }
}

Export-ModuleMember -Function ConvertTo-KitVersion, Compare-KitVersion, Get-KitBumpKind, Get-KitPluginRoot,
    Read-KitChangelog, Get-KitPluginInfo, Get-KitProjectVersion, Get-KitPendingEntries, Test-KitPluginRepo
