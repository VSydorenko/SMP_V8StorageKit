#Requires -Version 7
Describe 'GitMerge.psm1 — злиття storage/X у головну гілку (§3.4, Q4)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        function script:New-RepoWithMirror {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore
            # main вже має свій вміст поза шляхом джерела: AUTHORS, маніфест, v8project.yaml, README
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'проєкт' -Encoding UTF8
            git -C $repo add -A; git -C $repo commit -q -m 'README'
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'b.xml' -Content 'B1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 2')
            $repo
        }
    }

    It 'перше злиття (unrelated): файли main лишаються, файли сховища додаються; далі — already' {
        $repo = New-RepoWithMirror 'first'
        Test-KitBranchMergedInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' | Should -BeFalse
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: перше злиття storage/Alpha_SMB у main' -AllowUnrelated
        $r.Outcome | Should -Be 'merged'
        $r.Via | Should -Be 'in-place'
        Join-Path $repo 'README.md' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/a.xml' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/b.xml' | Should -Exist
        Test-KitBranchMergedInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' | Should -BeTrue
        (Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x').Outcome | Should -Be 'already'
    }

    It 'друге злиття (тристороннє): зміна й видалення зі сховища дійшли, файли main поза шляхом цілі' {
        $repo = New-RepoWithMirror 'second'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs.md') -Value 'робота в main' -Encoding UTF8
        git -C $repo add -A; git -C $repo commit -q -m 'main рухається далі'

        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A2' -RemoveFiles @('b.xml') -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'verify: звірочний коміт'
        $r.Outcome | Should -Be 'merged'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Raw) | Should -Be 'A2'
        Join-Path $repo 'Alpha_SMB/cfe/src/b.xml' | Should -Not -Exist
        Join-Path $repo 'docs.md' | Should -Exist
        Join-Path $repo 'README.md' | Should -Exist
        # merge-коміт має рівно двох батьків, і жоден із них не в storage/* (main не став дзеркалом)
        @((git -C $repo log -1 --format=%P main) -split ' ').Count | Should -Be 2
    }

    It 'HEAD на гілці задачі F: злиття йде через тимчасовий worktree; F не зрушила; worktree прибрано' {
        $repo = New-RepoWithMirror 'via-wt'
        git -C $repo checkout -q -b feature/task
        $fHead = git -C $repo rev-parse HEAD
        $mainBefore = git -C $repo rev-parse main
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated
        $r.Via | Should -Be 'worktree'
        (git -C $repo rev-parse HEAD) | Should -Be $fHead
        (git -C $repo branch --show-current) | Should -Be 'feature/task'
        (git -C $repo rev-parse main) | Should -Not -Be $mainBefore
        (git -C $repo rev-parse main) | Should -Be $r.Sha
        Join-Path $repo 'build/sync/_main/wt' | Should -Not -Exist
        @(git -C $repo worktree list).Count | Should -Be 1
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'HEAD = main, робоча копія брудна — зупинка, main не зрушив' {
        $repo = New-RepoWithMirror 'dirty'
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'незакомічена правка'
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw '*не чиста*'
        (git -C $repo rev-parse main) | Should -Be $before
    }

    It 'конфлікт: main змінив той самий файл — зупинка, злиття відкочено, MERGE_HEAD немає' {
        $repo = New-RepoWithMirror 'conflict'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Value 'A-main' -NoNewline
        git -C $repo add -A; git -C $repo commit -q -m 'main править a.xml'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A-storage' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' } | Should -Throw '*конфлікт*git merge storage/Alpha_SMB*'
        (git -C $repo rev-parse main) | Should -Be $before
        git -C $repo rev-parse -q --verify MERGE_HEAD 2>$null | Should -BeNullOrEmpty
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'головної гілки ще немає — зупинка з підказкою' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-main')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'trunk' -Message 'x' -AllowUnrelated } | Should -Throw "*'trunk'*"
    }
}
