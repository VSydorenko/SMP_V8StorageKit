#Requires -Version 7
Describe 'Порядок імпорту модулів у kit.ps1 (module-order.txt)' {
    BeforeAll {
        $script:LibDir    = (Resolve-Path "$PSScriptRoot/../lib").Path
        $script:ProbeFile = (Resolve-Path "$PSScriptRoot/fixtures/module-visibility-probe.ps1").Path
        $script:Modules   = @(Get-Content -LiteralPath (Join-Path $script:LibDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

        # Команди, які kit.ps1 і командні модулі кличуть напряму з глобальної області.
        $script:RequiredCommands = @(
            'Resolve-V8RepoRoot', 'Assert-SafeWorkPath', 'Read-KitYaml', 'ConvertTo-KitYaml', 'Read-V8Project', 'Read-V8ProjectLocalInfobase',
            'Read-KitManifest', 'Read-KitLocalOverlay', 'Resolve-KitInfobase', 'Save-KitOverlayAgentBase', 'New-KitFinding', 'Invoke-KitPreflight',
            'Select-KitSources', 'Test-KitBranchExists', 'Get-KitStorageBranchLastVersion', 'Test-KitStorageBranchInvariants',
            'Install-KitGitHooks', 'Test-KitGitHooks', 'Test-GitTextPolicy', 'Split-GitEolNoise', 'Read-AuthorMap',
            'Resolve-Author', 'Get-UnknownAuthors', 'Invoke-V8Designer', 'New-ExtensionInfobase', 'Get-StorageVersions',
            'Merge-KitBranchInto', 'New-KitStorageWorktree', 'Write-KitStorageVersion', 'Get-KitPendingVersions',
            'New-KitStorageInfobase', 'Invoke-KitStorageCheckout', 'Enter-KitStorageBind', 'Exit-KitStorageBind',
            'Export-KitTree', 'Compare-KitTrees', 'Get-KitBinaryPaths',
            'Get-KitVerifyVersion', 'Get-KitStorageActivity', 'Test-KitBranchUnborn',
            'Test-V8InfobaseBusy', 'Assert-V8InfobaseNotBusy', 'Get-KitRelativeFiles',
            'ConvertTo-V8IbSwitch', 'Get-KitVersionGapNote', 'New-KitStorageCommitMessage',
            'Remove-KitStorageWorktree', 'Resolve-KitAgentInfobasePath', 'Resolve-KitAgentBase', 'Test-KitSameInfobase',
            'Convert-KitEdtPath', 'Get-KitEdtRenamePlan', 'Get-KitDirtyRecords', 'Backup-KitDirtyFiles'
        )
        $output = & pwsh -NoProfile -File $script:ProbeFile -LibDir $script:LibDir `
            -CommandsCsv ($script:RequiredCommands -join ',') -ModulesCsv ($script:Modules -join ',') 2>&1 | Out-String
        $script:ProbeExitCode = $LASTEXITCODE
        $script:ProbeOutput   = $output
        $script:Visibility = @{}
        foreach ($line in ($output -split "`r?`n")) {
            if ($line -match '^(?<name>\S+)=(?<value>True|False)$') { $script:Visibility[$Matches.name] = [bool]::Parse($Matches.value) }
        }
    }

    It 'module-order.txt містить кожен lib/*.psm1, крім Environment' {
        $onDisk = @(Get-ChildItem -LiteralPath $script:LibDir -Filter '*.psm1' | ForEach-Object BaseName | Where-Object { $_ -ne 'Environment' })
        foreach ($m in $onDisk) { $script:Modules | Should -Contain $m -Because "модуль $m є в lib/, але не в module-order.txt" }
    }

    It 'усі команди видимі після імпорту в порядку module-order.txt' {
        $script:ProbeExitCode | Should -Be 0 -Because "probe мав відпрацювати без винятку; вивід:`n$script:ProbeOutput"
        foreach ($name in $script:RequiredCommands) {
            $script:Visibility[$name] | Should -BeTrue -Because "'$name' має бути видимою після імпорту всіх модулів kit.ps1"
        }
    }
}
