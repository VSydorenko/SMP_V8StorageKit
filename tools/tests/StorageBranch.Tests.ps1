#Requires -Version 7
Describe 'StorageBranch.psm1 — стан синхронізації з git' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        # Гілку storage/X будуємо тим самим механізмом, що й майбутній sync (B2): orphan через
        # worktree, коміт у ньому, worktree прибирається. Хуки в цій фікстурі не встановлені —
        # тут перевіряються інваріанти, не захист.
        function script:Add-StorageCommit {
            param(
                [Parameter(Mandatory)][string]$Repo,
                [Parameter(Mandatory)][string]$Branch,
                [Parameter(Mandatory)][string]$RepoPath,
                [Parameter(Mandatory)][string]$FileName,
                # AllowEmptyCollection(): без нього Mandatory трактує порожній масив як
                # непереданий аргумент і кидає ParameterBindingValidationException ("Cannot
                # bind argument ... because it is an empty array") — а тест «коміт без
                # трейлера» саме й передає -Trailers @(), щоб змоделювати ручний коміт без
                # жодного трейлера. Той самий дефект брифа і той самий фікс — у задачі 8,
                # де цей хелпер стає Add-KitFakeStorageCommit у KitFixtures.psm1.
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Trailers,
                [string]$Subject = 'версія'
            )
            $wt = Join-Path $Repo "build/sync/wt-$([guid]::NewGuid().ToString('N'))"
            if (git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null) {
                git -C $Repo worktree add -q $wt $Branch
            } else {
                git -C $Repo worktree add -q --orphan -b $Branch $wt
            }
            $dir = Join-Path $wt $RepoPath
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir $FileName) -Value "вміст $FileName" -Encoding UTF8
            git -C $wt add -A
            $msg = @($Subject, '') + $Trailers
            git -C $wt commit -q -m ($msg -join "`n")
            git -C $Repo worktree remove --force $wt
        }
    }

    It 'імʼя гілки джерела' {
        Get-KitStorageBranchName -SourceKey 'SMP_BankExchange_SMB' | Should -Be 'storage/SMP_BankExchange_SMB'
    }

    It 'гілки немає — LastVersion = $null, інваріантів немає що порушувати' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'none')
        Test-KitBranchExists -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeFalse
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeNullOrEmpty
        @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src').Count | Should -Be 0
    }

    It 'версії 17, 18, 21 — остання 21; кореневий коміт без батьків проходить; знахідок нуль' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ok')
        foreach ($v in 17, 18, 21) {
            Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v", 'Storage-User: gitbot')
        }
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 21
        $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
        $commits.Count | Should -Be 3
        $commits[0].Parents.Count | Should -Be 0
        $commits[1].Parents.Count | Should -Be 1
        $commits[2].Trailers['Storage-Version'] | Should -Be '21'
        @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src').Count | Should -Be 0
        # Робоча копія й HEAD основного дерева не рухались (§3.3, шар 1)
        git -C $repo branch --show-current | Should -Be 'main'
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }

    It 'немонотонний трейлер — помилка, яка називає обидві версії й коміт' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'nonmono')
        foreach ($v in 17, 21, 18) {
            Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        $f.Count | Should -Be 1
        $f[0].Level | Should -Be 'error'
        $f[0].Message | Should -BeLike '*21*18*'
    }

    It 'коміт без трейлера Storage-Version — помилка; LastVersion зупиняється, а не вгадує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'notrailer')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'b.xml' -Trailers @() -Subject 'ручний коміт без трейлерів'
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Version*').Count | Should -BeGreaterOrEqual 1
        { Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' } | Should -Throw '*Storage-Version*'
    }

    It 'merge-коміт на storage/X — помилка (два батьки), кореневий без батьків — ні' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        # Злиття main у гілку сховища — саме те, що забороняє §3.2. Робимо в тимчасовому worktree,
        # щоб не чіпати робочу копію, і без хуків (їх у цій фікстурі немає).
        $wt = Join-Path $repo 'build/sync/merge-wt'
        git -C $repo worktree add -q $wt 'storage/Alpha_SMB'
        git -C $wt merge -q --allow-unrelated-histories --no-edit -m "злиття main`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" main
        git -C $repo worktree remove --force $wt
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*батьк*').Count | Should -Be 1
    }

    It 'файл поза шляхом джерела в дереві storage/X — помилка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'stray')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Other/place' -FileName 'stray.txt' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 2')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Other/place/stray.txt*').Count | Should -Be 1
    }

    It 'Storage-Source іншого джерела — помилка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrongsource')
        Add-StorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Beta', 'Storage-Version: 1')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Source*Beta*').Count | Should -Be 1
    }
}
