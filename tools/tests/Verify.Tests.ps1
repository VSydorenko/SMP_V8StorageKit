#Requires -Version 7
Describe 'kit verify — штатні зупинки до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Verify {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit verify -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'дзеркала ще немає — зупинка «sync», build/verify не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-mirror') -WithHooks
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*storage/Alpha_SMB*sync*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'дзеркало є, але main його не зливав — зупинка «sync» до платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmerged') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*sync*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'без джерел truth: storage — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Verify -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It '-Ref невідомий — зупинка з його ім''ям' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-ref') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo -More @('-Ref', 'nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'nope'*"
    }
}

Describe 'kit verify — живе сховище: рівні → сховище попереду → звірочний коміт → рівні' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item 'R:\github\SMP_BankExchange\AUTHORS' (Join-Path $script:Repo 'AUTHORS') -Force
        # F9: прибрати фейковий Configuration.xml з main — інакше перше злиття дзеркала дасть add/add-конфлікт.
        git -C $script:Repo rm -rq -- SMP_BankExchange_SMB/cfe/src
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS; дерево джерела порожнє до першого sync'
        function script:Run { param([string[]]$Arguments) $out = & pwsh -NoProfile -File $script:Kit @Arguments -RepoRoot $script:Repo 2>&1 | Out-String; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        function script:Complete-Authors {
            param([string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8; $added = $true }
            }
            if ($added) { git -C $script:Repo commit -qam 'AUTHORS: тестові автори' }
            $added
        }
    }

    It 'після першого sync main ≡ сховище (нуль змістовних розбіжностей — знахідка BankExchange)' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 0 -Because $v.Output
        $v.Output | Should -BeLike '*equal*'
        $v.Output | Should -Not -Match '\[-\]'      # -BeLike трактує [-] як клас символів; -Match — літерально
    }

    It 'ще одна версія в дзеркалі — «сховище попереду»; -Apply робить звірочний коміт; далі знову рівні' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 3 -Because $v.Output
        $v.Output | Should -BeLike '*storage-ahead*'
        $mainBefore = git -C $script:Repo rev-parse main
        $a = Run @('verify', '-Apply')
        $a.ExitCode | Should -Be 3 -Because $a.Output     # звірка йшла проти старої версії; коміт зроблено
        (git -C $script:Repo rev-parse main) | Should -Not -Be $mainBefore
        $v2 = Run @('verify')
        $v2.ExitCode | Should -Be 0 -Because $v2.Output
    }
}
