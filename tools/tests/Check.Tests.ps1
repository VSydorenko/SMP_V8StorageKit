#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        function script:Invoke-Check {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Репозиторій, у якому все правильно: хуки, політика тексту, gitignore.
        function script:New-GoodRepo {
            param([string]$Name, [hashtable]$Extra = @{})
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore @Extra
        }
    }

    It 'усе гаразд — код 0, лише інформаційні рядки' {
        $r = Invoke-Check -Repo (New-GoodRepo 'good')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
        $r.Output | Should -Not -Match '\[-\]'
    }

    It 'без маніфесту — код 1 і підказка на onboarding' {
        $repo = New-GoodRepo 'no-manifest'
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
    }

    It '§2.2: <Name> у Configuration.xml не збігається з ключем джерела — код 1, названо обидва' {
        $repo = New-GoodRepo 'name-mismatch'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'Alpha_OLD')
        git -C $repo commit -qam 'фікстура: інше ім''я в Configuration.xml'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_OLD*Alpha_SMB*Configuration.xml*'
    }

    It '§2.5: infobase.connection у v8project.local.yaml збігається з дев-базою з накладки — код 1' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It '§2.5: серверна база АГЕНТА у v8project.local.yaml, якої немає в накладці, — не помилка' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $repo = New-GoodRepo 'local-agent' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'"
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0
    }

    It '§2.6: truth: vendor без правила в .gitignore — код 1 (git check-ignore)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ignore') -WithHooks -WithGitattributes
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cf/src*.gitignore*'
    }

    It '§2.6: дерево платформи без -text — код 1 (git check-attr)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-text') -WithHooks -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*-text*'
    }

    It '§2.6: дерево, яке має бути в git, помилково гітігноровано — код 1' {
        $repo = New-GoodRepo 'over-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value 'Alpha_SMB/cfe/src/**'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*.gitignore*'
    }

    It '§2.6: vendor-дерево закомічене всупереч .gitignore (git add -f) — код 1, факт відстеження' {
        # Правило в .gitignore є (WithGitignore), тому питання "правил" мовчить — тут
        # інша перевірка: факт. Файл додано силою (git add -f), так само, як хтось міг би
        # це зробити руками попри правило.
        $repo = New-GoodRepo 'vendor-tracked'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'base')
        git -C $repo add -f -- Alpha_SMB/cf/src/Configuration.xml
        git -C $repo commit -qm 'фікстура: vendor закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cf/src*'
    }

    It '§3.2: немонотонна гілка storage/X — код 1; лінійна з кореневим комітом — 0' {
        $repo = New-GoodRepo 'branch'
        foreach ($v in 5, 9) {
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0

        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v7.xml' `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*storage/Alpha_SMB*9*7*'
    }

    It '§3.3: core.hooksPath не встановлено — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-hooks') -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*core.hooksPath*'
    }

    It '§2.3: той самий ключ truth: storage у двох воркспейсах — код 1' {
        $two = [ordered]@{
            'A' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'B' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dup-keys') -Workspaces $two -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Shared*A*B*'
    }

    It 'dump.from без накладки на машині — попередження, не помилка' {
        $r = Invoke-Check -Repo (New-GoodRepo 'no-overlay')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[!]*v8storagekit.local.yaml*'
    }

    It '-Workspace звужує перевірку; невідомий — код 1 з переліком' {
        $repo = New-GoodRepo 'ws-filter'
        (Invoke-Check -Repo $repo -More @('-Workspace', 'Alpha_SMB')).ExitCode | Should -Be 0
        $r = Invoke-Check -Repo $repo -More @('-Workspace', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*Alpha_SMB*"
    }

    It 'check нічого не змінює: статус робочої копії й HEAD ті самі' {
        $repo = New-GoodRepo 'readonly'
        $head = git -C $repo rev-parse HEAD
        Invoke-Check -Repo $repo | Out-Null
        git -C $repo rev-parse HEAD | Should -Be $head
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }
}
