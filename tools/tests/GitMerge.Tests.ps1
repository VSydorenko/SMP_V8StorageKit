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

        function script:New-RepoWithIgnoredClash {
            # -LocalName відмінне від -MirrorName лише регістром — ігнорований файл на диску й доданий шлях на NTFS один файл.
            param([string]$Name, [string]$LocalContent, [string]$LocalName = 'x.bin', [string]$MirrorName = 'x.bin')
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'проєкт' -Encoding UTF8
            git -C $repo add -A; git -C $repo commit -q -m 'README'
            # Обидва регістри розширення — щоб ігнорування не залежало від core.ignorecase машини.
            Add-Content -LiteralPath (Join-Path $repo '.git/info/exclude') -Value @('*.bin', '*.BIN')
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
                "Alpha_SMB/cfe/src/$MirrorName" = 'mirror'; 'Alpha_SMB/cfe/src/a.xml' = 'A1'
            }) | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/cfe/src') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo "Alpha_SMB/cfe/src/$LocalName") -Value $LocalContent -NoNewline
            $repo
        }

        function script:New-RepoWithCaseRename {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files ([ordered]@{
                'Alpha_SMB/cfe/src/T/Образецанализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/Образецанализ/Ext/T.bin' = 'bin'
            }) | Out-Null
            Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
            Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" -Files ([ordered]@{
                'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml' = 'xml'; 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin' = 'bin'
            }) | Out-Null
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

    It 'HEAD на гілці задачі F: злиття лише пересуває main; F і робоча копія не зрушили; worktree не створюється' {
        $repo = New-RepoWithMirror 'via-wt'
        git -C $repo checkout -q -b feature/task
        $fHead = git -C $repo rev-parse HEAD
        $mainBefore = git -C $repo rev-parse main
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated
        $r.Via | Should -Be 'ref'
        (git -C $repo rev-parse HEAD) | Should -Be $fHead
        (git -C $repo branch --show-current) | Should -Be 'feature/task'
        (git -C $repo rev-parse main) | Should -Not -Be $mainBefore
        (git -C $repo rev-parse main) | Should -Be $r.Sha
        Join-Path $repo 'build/sync/_main/wt' | Should -Not -Exist
        @(git -C $repo worktree list).Count | Should -Be 1
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'HEAD = main, робоча копія брудна — зупинка з переліком брудних шляхів, main не зрушив' {
        $repo = New-RepoWithMirror 'dirty'
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'незакомічена правка'
        $before = git -C $repo rev-parse main
        $err = { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } |
            Should -Throw '*не чиста*' -PassThru
        # Перелік брудних шляхів (доданий у цьому блоці для діагностованості) — не лише факт "не чиста".
        $err.Exception.Message | Should -BeLike '*README.md*'
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

    It 'кириличне перейменування регістром, main вибрана тут — merged in-place; диск і індекс у новому регістрі (#31)' {
        $repo = New-RepoWithCaseRename 'case-inplace'
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: злиття v2'
        $r.Outcome | Should -Be 'merged'
        $r.Via | Should -Be 'in-place'
        # Шляхи, що різняться лише регістром, порівнюємо чутливо: -Be/-Contain в Pester нечутливі й пройшли б на старому регістрі.
        @(git -c core.quotepath=false -C $repo ls-files -- 'Alpha_SMB/cfe/src/T') |
            Should -BeExactly @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name)
        ($onDisk -ccontains 'ОбразецАнализ.xml') | Should -BeTrue -Because "на диску: $($onDisk -join ', ')"
        ($onDisk -ccontains 'Образецанализ.xml') | Should -BeFalse -Because "на диску лишився старий регістр: $($onDisk -join ', ')"
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        @((git -C $repo log -1 --format=%P main) -split ' ') | Should -HaveCount 2
        (git -C $repo log -1 --format=%s main) | Should -Be 'sync: злиття v2'
    }

    It 'кириличне перейменування регістром, HEAD на гілці задачі — merged через ref; F і диск не зрушили' {
        $repo = New-RepoWithCaseRename 'case-ref'
        git -C $repo checkout -q -b feature/task
        $before = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name)
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'sync: злиття v2'
        $r.Via | Should -Be 'ref'
        @(git -c core.quotepath=false -C $repo ls-tree -r --name-only main -- 'Alpha_SMB/cfe/src/T') |
            Should -BeExactly @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/ОбразецАнализ/Ext/T.bin')
        @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/T') -Name) | Should -BeExactly $before
        (git -C $repo branch --show-current) | Should -Be 'feature/task'
    }

    It 'невідстежуваний файл у main — брудна копія, зупинка до злиття; main не зрушив, файл цілий' {
        $repo = New-RepoWithMirror 'untracked'
        Set-Content -LiteralPath (Join-Path $repo 'notes.txt') -Value 'моя чернетка'
        $before = git -C $repo rev-parse main
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw '*не чиста*notes.txt*'
        (git -C $repo rev-parse main) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $repo 'notes.txt') -Raw).Trim() | Should -Be 'моя чернетка'
    }

    It 'ігнорований невідстежуваний файл збігається зі шляхом, який приносить дзеркало — зупинка, main не зрушив, вміст цілий' {
        $repo = New-RepoWithIgnoredClash 'ignored-clash' 'precious'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty -Because 'файл ігнорований, status його не показує'
        $before = git -C $repo rev-parse main
        $err = { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*ігноровані невідстежувані файли*Нічого не змінено*Alpha_SMB/cfe/src/x.bin*'
        (git -C $repo rev-parse main) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/x.bin') -Raw) | Should -BeExactly 'precious'
        Join-Path $repo 'Alpha_SMB/cfe/src/a.xml' | Should -Not -Exist
    }

    It 'ігнорований файл відрізняється від доданого шляху лише регістром (кирилиця) — на NTFS той самий файл: зупинка, вміст цілий' {
        $repo = New-RepoWithIgnoredClash 'ignored-case-clash' 'precious' -LocalName 'Ф.BIN' -MirrorName 'ф.bin'
        $before = git -C $repo rev-parse main
        $err = { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLikeExactly '*ігноровані невідстежувані файли*Нічого не змінено*Alpha_SMB/cfe/src/Ф.BIN (дзеркало приносить Alpha_SMB/cfe/src/ф.bin)*'
        (git -C $repo rev-parse main) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Ф.BIN') -Raw) | Should -BeExactly 'precious'
    }

    It 'ігнорований невідстежуваний файл із тим самим вмістом, що в дзеркалі — не втрата, merged' {
        $repo = New-RepoWithIgnoredClash 'ignored-same' 'mirror'
        $r = Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated
        $r.Outcome | Should -Be 'merged'
        $r.Via | Should -Be 'in-place'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/x.bin') -Raw) | Should -BeExactly 'mirror'
    }

    It 'main вибрана в іншому worktree — зупинка, main не зрушив' {
        $repo = New-RepoWithMirror 'other-wt'
        git -C $repo checkout -q -b feature/task
        $wt = Join-Path $TestDrive 'other-wt-main'
        git -C $repo worktree add -q $wt main
        try {
            $before = git -C $repo rev-parse main
            { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' -AllowUnrelated } | Should -Throw "*'main' вибрана в іншому worktree*"
            (git -C $repo rev-parse main) | Should -Be $before
        } finally { git -C $repo worktree remove --force $wt 2>$null }
    }

    It 'ціль — storage/*: зупинка до будь-якої дії' {
        $repo = New-RepoWithMirror 'into-storage'
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'main' -Into 'storage/Alpha_SMB' -Message 'x' -AllowUnrelated } | Should -Throw '*storage/Alpha_SMB*дзеркало сховища*'
    }

    It 'конфлікт: нічого не змінено, merge --abort не викликався (немає хибного «незавершеного злиття»)' {
        $repo = New-RepoWithMirror 'conflict-new'
        Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/a.xml') -Value 'A-main' -NoNewline
        git -C $repo add -A; git -C $repo commit -q -m 'main править a.xml'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Content 'A-storage' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        $err = { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Нічого не змінено*Alpha_SMB/cfe/src/a.xml*'
        $err.Exception.Message | Should -Not -BeLike '*незавершеному*'
    }

    It 'головної гілки ще немає — зупинка з підказкою' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-main')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'trunk' -Message 'x' -AllowUnrelated } | Should -Throw "*'trunk'*"
    }
}
