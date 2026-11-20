#Requires -Version 7
Describe 'kit supply-marker (§10 П5; колишній режим -MarkerOnly команди canon)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Run { param([string]$Repo, [string[]]$More)
            $out = & pwsh -NoProfile -File $script:Kit supply-marker -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:StorageWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
    }
    It 'позначки немає, .cf на місці, дерево чисте — пише позначку без бази агента й без платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ok') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $want = (Get-FileHash -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText($marker) | Should -Be $want
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
    }
    It 'без -Source — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nosrc') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        (Run -Repo $repo -More @('-Apply')).Output | Should -BeLike '*supply-marker потребує -Source*'
    }
    It 'набір EXTENSION — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ext') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $r = Run -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*позначка поставки буває лише в наборі CONFIGURATION*'
    }
    It 'немає .cf — код 1, рецепт pull' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nocf') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Remove-Item -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*немає .cf*pull*force:true*'
    }
    It 'брудне дерево — код 1, позначку не записано (запасна гілка §4.1)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-dirty') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Value '<!-- pull дав інші байти -->'
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*брудне*доповідь*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'стара позначка на місці (stale) — код 1, позначку не переписано (§10.1 П22: .cf цим pull не перевивантажувався)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-stale') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        [System.IO.File]::WriteAllText($marker, 'deadbeef')
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*стара позначка*не перевивантажувався*force:true*'
        [System.IO.File]::ReadAllText($marker) | Should -Be 'deadbeef'
    }
    It '.bin не описує поставку (16 байт) — код 1, позначку не записано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nodesc') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        [System.IO.File]::WriteAllBytes((Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..16))
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не описує поставку вендора*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'прев''ю без -Apply — код 0, повідомлення про -Apply, позначку не записано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-preview') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $r = Run -Repo $repo -More @('-Source', 'base')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*додайте -Apply*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'позначка вже актуальна (current) — код 0, нічого не пишеться' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-current') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $r = Run -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*вже відповідає .bin*'
    }
}
