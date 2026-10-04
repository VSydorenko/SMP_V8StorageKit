#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — конвенція lib-модулів (той самий прийом, що GitOutput.psm1): не перезавантажувати вже
# наявний глобальний TreeCompare. Звідти — Invoke-KitGitProcess, Get-KitRelativeFiles,
# Test-KitComparableRelativePath.
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Get-KitTreePaths {
    <#
    .SYNOPSIS
        Повні шляхи файлів ref (опційно під -Path) — сирі, UTF-8, незалежно від консолі.
    .DESCRIPTION
        ls-tree -r -z через Invoke-KitGitProcess: голий конвеєр PowerShell декодує вивід за кодуванням
        консолі й на cp866 калічить кирилицю (рев'ю B3), а без -z git квотує не-ASCII у лапках.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [string]$Path
    )
    $gitArgs = @('-c', 'core.quotepath=false', 'ls-tree', '-r', '-z', '--name-only', $Ref)
    if ($Path) { $gitArgs += @('--', (($Path -replace '\\', '/').TrimEnd('/'))) }
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments $gitArgs
    if ($r.ExitCode -ne 0) { throw "git ls-tree $Ref завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    @($r.Stdout -split "`0" | Where-Object { $_ })
}

function Get-KitCaseCollisions {
    <#
    .SYNOPSIS
        Групи шляхів, що різняться лише регістром — за юнікодним складанням, як у NTFS.
    .DESCRIPTION
        OrdinalIgnoreCase, а не ASCII: core.ignorecase у git складає лише a–z (memihash), тому
        кириличну пару git вважає двома файлами, а NTFS — одним (спека 2026-10-04 §2). tr і
        ASCII-нижній регістр дають на кирилиці хибні 0 (виміряно interoptica).
        Без coma-wrap на результаті: викликачі загортають його в @(...). Кожна група виходить
        одним елементом (кома перед масивом групи).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)
    $map = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) {
        if (-not $map.ContainsKey($p)) { $map[$p] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
        [void]$map[$p].Add($p)
    }
    $groups = [System.Collections.Generic.List[string[]]]::new()
    foreach ($set in $map.Values) {
        if ($set.Count -lt 2) { continue }
        $arr = [string[]]@($set)
        [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
        $groups.Add($arr)
    }
    $sorted = [System.Linq.Enumerable]::OrderBy($groups, [Func[string[], string]] { param($g) $g[0] }, [System.StringComparer]::Ordinal)
    foreach ($g in $sorted) { , $g }
}

function Assert-KitIndexMatchesDisk {
    <#
    .SYNOPSIS
        Інваріант спеки 2026-10-04 §4.1: індекс піддерева ≡ файли на диску, побайтово за іменем (Ordinal).
    .DESCRIPTION
        Ловить фантом (старий регістр лишився в індексі), загублений ASCII-регістр і будь-яку іншу
        евристику git, яка розводить індекс із диском. Службові файли й поставку не рахує
        (Test-KitComparableRelativePath — той самий фільтр, що в verify). Кидає до коміту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath
    )
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $ls = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-files', '-z', '--', $prefix)
    if ($ls.ExitCode -ne 0) { throw "git ls-files -- $prefix завершився з кодом $($ls.ExitCode): $($ls.Stderr)" }
    $index = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in ($ls.Stdout -split "`0")) {
        if (-not $p) { continue }
        $rel = $p.Substring($prefix.Length).TrimStart('/')
        if (Test-KitComparableRelativePath -RelativePath $rel) { [void]$index.Add($rel) }
    }
    $disk = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-KitRelativeFiles -Root (Join-Path $RepoRoot $prefix)), [System.StringComparer]::Ordinal)
    # Файли, які git ігнорує, у дерево за визначенням не входять — їх не рахуємо (інакше дзеркало з
    # файлом, який споживач ігнорує, зупиняло б adopt уже після стирання дерева). У worktree дзеркала
    # .gitignore немає — перелік порожній.
    $ign = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--', $prefix)
    if ($ign.ExitCode -ne 0) { throw "git ls-files --ignored -- $prefix завершився з кодом $($ign.ExitCode): $($ign.Stderr)" }
    foreach ($p in ($ign.Stdout -split "`0")) {
        if ($p) { [void]$disk.Remove($p.Substring($prefix.Length).TrimStart('/')) }
    }
    $onlyIndex = @($index | Where-Object { -not $disk.Contains($_) } | Sort-Object -CaseSensitive)
    $onlyDisk  = @($disk  | Where-Object { -not $index.Contains($_) } | Sort-Object -CaseSensitive)
    if ($onlyIndex.Count -eq 0 -and $onlyDisk.Count -eq 0) { return }
    $fmt = { param($list) $shown = @($list | Select-Object -First 5); ($shown -join ', ') + $(if ($list.Count -gt 5) { ", …і ще $($list.Count - 5)" } else { '' }) }
    throw ("Індекс '$prefix' не збігається з деревом на диску після git add — коміт не створено (спека 2026-10-04 §4.1; " +
           'ймовірна причина — перейменування лише регістром, яке git на Windows не розпізнав). ' +
           "Лише в індексі ($($onlyIndex.Count)): $(& $fmt $onlyIndex). Лише на диску ($($onlyDisk.Count)): $(& $fmt $onlyDisk).")
}

Export-ModuleMember -Function Get-KitTreePaths, Get-KitCaseCollisions, Assert-KitIndexMatchesDisk
