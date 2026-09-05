#Requires -Version 7
Describe 'kit dump — прев''ю і штатні зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Dump {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=""C:\bases\demo"";'`n    user: 'Адмін'"
    }

    It 'прев''ю: база, ціль і попередження про 20–40 хвилин; нічого не змінено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*/F "C:\bases\demo"*Alpha_SMB/cf/src*'
        $r.Output | Should -BeLike '*-Apply*'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'дев-бази з dump.from немає в накладці — зупинка з готовим блоком infobases:, ціль не чіпалась' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ib') -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/marker.txt') -Value 'є'
        $r = Invoke-Dump -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'dev'*infobases:*connection:*"
        Join-Path $repo 'Alpha_SMB/cf/src/marker.txt' | Should -Exist
    }

    It 'без джерел truth: dump/vendor — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Dump -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*dump*vendor*'
    }

    It '-Source на джерело з truth: storage — зупинка: дамп лише для dump/vendor' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrong-truth') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*storage*'
    }
}

Describe 'kit dump — жива дев-база (лише читання, 20–40 хв)' -Tag Integration {
    # Запускається лише з V8KIT_LIVE_DUMP=1: це дорого й потребує доступу до бази людини.
    BeforeAll {
        if ($env:V8KIT_LIVE_DUMP -ne '1') { Set-ItResult -Skipped -Because 'V8KIT_LIVE_DUMP не виставлено' }
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $overlay = "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF_sydorenko"";'`n    user: 'Администратор'"
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }', "      Alpha_SMB: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -ManifestText $manifest -OverlayText $overlay -WithHooks -WithGitattributes -WithGitignore
    }
    It 'вивантажує конфігурацію в Alpha_SMB/cf/src; результат гітігнорований' {
        $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $script:Repo -Source base -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $script:Repo 'Alpha_SMB/cf/src/Configuration.xml' | Should -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }
}
