# Ported from agent-kit 0.9.1 bin/pr-gate, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Тонка обгортка команди `pr-gate`: розбір аргументів (KitCli), читання профілю (KitProfile), виклик
# логіки з tools/lib/KitPrGate.psm1. Уся логіка й тексти — у KitPrGate: так вона перевіряється
# прямим Import-Module без запуску команди. Виняток gh перекладає сама логіка (код 3 — gh немає чи
# не залогінений, код 1 — збій gh).
Import-Module "$PSScriptRoot/../lib/KitPrGate.psm1"

function Get-PrGateSeconds {
    param([string]$Value, [string]$Name)
    $n = 0.0
    if (-not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or $n -lt 0) {
        throw (New-KitUsageError "-${Name}: потрібне число секунд")
    }
    $n
}

function Invoke-KitPrGate {
    <#
    .SYNOPSIS
        pr-gate: start, open, ready, merge, after-merge, land, cleanup, prune, scratch. Форми — `pr-gate help`.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        Base = 'string'; Title = 'string'; Draft = 'switch'; BodyFile = 'string'; Squash = 'switch'
        Merge = 'switch'; DryRun = 'switch'; Remote = 'switch'; MergeableTimeout = 'string'; Resume = 'switch'
    }
    if ($a.Help) { Write-KitLine (Get-PrGateUsage); return 0 }
    $pos = @($a.Positional)
    $step = if ($pos.Count) { $pos[0] } else { $null }
    $arg = if ($pos.Count -gt 1) { $pos[1] } else { $null }
    $extra = if ($pos.Count -gt 2) { $pos[2] } else { $null }
    $more = if ($pos.Count -gt 3) { $pos[3] } else { $null }
    $usageFail = { param($m) throw (New-KitUsageError "$m`n`n$(Get-PrGateUsage)") }

    if ($step -eq 'help') {
        if ($null -ne $arg -and $arg -ne 'profile') { & $usageFail 'help: очікувалось нічого або "profile"' }
        Write-KitLine $(if ($arg -eq 'profile') { Get-PrGateProfileUsage } else { Get-PrGateDetailUsage })
        return 0
    }
    if ($step -notin @('start', 'open', 'ready', 'merge', 'after-merge', 'land', 'cleanup', 'prune', 'scratch')) {
        & $usageFail $(if ($step) { "невідома підкоманда `"$step`"" } else { 'потрібна підкоманда' })
    }
    # Лишні позиційні — помилка виклику, а не мовчки відкинуте.
    $max = switch ($step) { 'start' { 3 } 'scratch' { 3 } default { 2 } }
    if ($pos.Count -gt $max) { & $usageFail "зайвий аргумент `"$($pos[$max])`"" }
    if ($null -ne $arg -and $step -in @('ready', 'merge', 'after-merge', 'land') -and $arg -notmatch '^\d+$') { & $usageFail "<pr> має бути числом, отримано `"$arg`"" }
    if ($step -eq 'open' -and $null -ne $arg) { & $usageFail 'open не приймає позиційних аргументів' }
    if ($step -eq 'prune' -and $null -ne $arg) { & $usageFail 'prune не приймає позиційних аргументів' }
    if ($step -eq 'scratch' -and $arg -notin @('add', 'rm')) { & $usageFail 'scratch: очікувалось add або rm' }
    if ($step -eq 'land' -and $a.Named['DryRun']) { & $usageFail 'land не має -DryRun; використай pr-gate merge <pr> -DryRun' }
    if ($step -eq 'land' -and -not $arg) { & $usageFail 'land: назви номер PR' }
    if ($a.Named['Squash'] -and $a.Named['Merge']) { & $usageFail 'використай -Squash або -Merge, не обидва' }

    $p = Get-KitProfile -RepoRoot $RepoRoot
    $base = [string](Get-KitProfileValue $p 'pr.base' -Default 'main')
    $wtRoot = Resolve-KitInsidePath -Value ([string](Get-KitProfileValue $p 'worktrees.root' -Default '.worktrees')) -Field 'worktrees.root'
    # workspace.mode читають лише кроки, що від нього залежать; поля не вгадуємо (код 3 з назвою поля).
    $mode = if ($step -in @('start', 'land')) { Assert-PrGateWorkspaceMode (Get-KitProfileValue $p 'workspace.mode') } else { $null }
    $afterMerge = if ($step -in @('land', 'after-merge')) { Get-KitProfileValue $p 'pr.afterMerge' -Default @() } else { @() }
    $outDir = if ($step -eq 'land') { Get-KitAgentsDir -Name out -RepoRoot $RepoRoot -Create } else { $null }
    $ctx = New-PrGateContext -Root $p.Root -MainRoot $p.MainRoot -Base $base -WorktreesRoot $wtRoot -WorkspaceMode $mode `
        -AfterMerge $afterMerge -OutDir $outDir

    $method = $null
    if ($step -in @('merge', 'land')) {
        $method = if ($a.Named['Squash']) { 'squash' } elseif ($a.Named['Merge']) { 'merge' } else { [string](Get-KitProfileValue $p 'pr.mergeMethod') }
        if ($method -notin @('squash', 'merge')) { throw (New-KitUsageError "pr.mergeMethod має бути `"squash`" або `"merge`", отримано `"$method`"") }
    }

    switch ($step) {
        'start' { return Invoke-PrGateStart -Ctx $ctx -Issue ([string]$arg) -Slug $extra -Resume:([bool]$a.Named['Resume']) }
        'open' { return Invoke-PrGateOpen -Ctx $ctx -Draft:([bool]$a.Named['Draft']) -Base $a.Named['Base'] -Title $a.Named['Title'] -BodyFile $a.Named['BodyFile'] }
        'ready' { return Invoke-PrGateReady -Ctx $ctx -Pr $arg }
        'merge' { return Invoke-PrGateMerge -Ctx $ctx -Pr $arg -Method $method -DryRun:([bool]$a.Named['DryRun']) }
        'after-merge' { return Invoke-PrGateAfterMerge -Ctx $ctx -Pr $arg }
        'land' {
            $timeout = if ($a.Named.ContainsKey('MergeableTimeout')) { Get-PrGateSeconds $a.Named['MergeableTimeout'] 'MergeableTimeout' } else { 120.0 }
            return Invoke-PrGateLand -Ctx $ctx -Pr $arg -Method $method -MergeableTimeout $timeout
        }
        'cleanup' { return Invoke-PrGateCleanup -Ctx $ctx -Path $arg }
        'prune' { return Invoke-PrGatePrune -Ctx $ctx -DryRun:([bool]$a.Named['DryRun']) -Remote:([bool]$a.Named['Remote']) }
        'scratch' {
            if ($arg -eq 'add') { return Invoke-PrGateScratchAdd -Ctx $ctx -Ref $(if ($extra) { $extra } else { 'HEAD' }) }
            return Invoke-PrGateScratchRm -Ctx $ctx -Path $extra
        }
    }
}

Export-ModuleMember -Function Invoke-KitPrGate
