# Ported from agent-kit 0.9.1 bin/track, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Тонка обгортка команди `track`: розбір аргументів (KitCli), читання профілю (KitProfile), виклик
# логіки з tools/lib/KitTrack.psm1, переклад винятків gh у коди виходу й друк. Уся логіка й тексти —
# у KitTrack: так вона перевіряється прямим Import-Module без запуску команди.
Import-Module "$PSScriptRoot/../lib/KitTrack.psm1"
Import-Module "$PSScriptRoot/../lib/GhRun.psm1"

function Invoke-KitTrack {
    <#
    .SYNOPSIS
        track: status, spec, milestone — статус роботи лише в GitHub. Форми — `track -Help`.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        Milestone = 'string'; Parent = 'string'; DryRun = 'switch'
        Due = 'string'; Description = 'string'; State = 'string'
    }
    if ($a.Help) { Write-KitLine (Get-TrackUsage); return 0 }
    $cmd = if ($a.Positional.Count) { $a.Positional[0] } else { $null }
    $rest = @($a.Positional | Select-Object -Skip 1)
    $usage = Get-TrackUsage
    switch ($cmd) {
        'status' { if ($rest.Count) { throw (New-KitUsageError "track status не приймає позиційних аргументів`n`n$usage") } }
        'spec' { if ($rest.Count -ne 1) { throw (New-KitUsageError "track spec <спека.md>`n`n$usage") } }
        'milestone' { if ($rest.Count -ne 1) { throw (New-KitUsageError "track milestone <назва>`n`n$usage") } }
        default {
            $what = if ($cmd) { "невідома підкоманда `"$cmd`"" } else { 'потрібна підкоманда' }
            throw (New-KitUsageError "$what`n`n$usage")
        }
    }
    $opts = @{}
    foreach ($k in $a.Named.Keys) { $opts[$k] = $a.Named[$k] }

    $p = Get-KitProfile -RepoRoot $RepoRoot
    $repo = Get-KitProfileValue $p 'track.repo' -Default $null
    $labels = Get-KitProfileValue $p 'track.labels' -Default $null
    $ctx = New-TrackContext -Root $p.Root -Repo $(if ($repo) { [string]$repo } else { $null }) -Labels $(if ($labels -is [System.Collections.IDictionary]) { $labels } else { $null })

    try {
        $res = switch ($cmd) {
            'status' { Invoke-TrackStatus -Ctx $ctx -Options $opts }
            'spec' { Invoke-TrackSpec -Ctx $ctx -File $rest[0] -WorkDir (Get-Location).Path -Options $opts }
            'milestone' { Invoke-TrackMilestone -Ctx $ctx -Title $rest[0] -Options $opts }
        }
    } catch [KitGhUnavailable] {
        throw (New-KitNotChecked "не перевірено: $($_.Exception.Message)")
    } catch [KitGhError] {
        throw (New-KitRefusal $_.Exception.Message)
    }
    foreach ($line in $res.Lines) { Write-KitLine $line }
    Write-KitNext $res.Next
    return 0
}

Export-ModuleMember -Function Invoke-KitTrack
