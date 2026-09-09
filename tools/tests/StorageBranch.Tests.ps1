#Requires -Version 7
Describe 'StorageBranch.psm1 — стан синхронізації з git' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        # Гілку storage/X будуємо тим самим механізмом, що й майбутній sync (B2): orphan через
        # worktree, коміт у ньому, worktree прибирається. Хуки в цій фікстурі не встановлені —
        # тут перевіряються інваріанти, не захист. Сам хелпер тепер живе у фікстурі
        # (Add-KitFakeStorageCommit, KitFixtures.psm1) — задача 8 переносить його звідси.
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
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
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
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        $f.Count | Should -Be 1
        $f[0].Level | Should -Be 'error'
        $f[0].Message | Should -BeLike '*21*18*'
    }

    It 'коміт без трейлера Storage-Version — помилка; LastVersion зупиняється, а не вгадує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'notrailer')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 3')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'b.xml' -Trailers @() -Subject 'ручний коміт без трейлерів'
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Version*').Count | Should -BeGreaterOrEqual 1
        { Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' } | Should -Throw '*Storage-Version*'
    }

    It 'merge-коміт на storage/X — помилка (два батьки), кореневий без батьків — ні' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
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
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Other/place' -FileName 'stray.txt' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 2')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Other/place/stray.txt*').Count | Should -Be 1
    }

    It 'кириличне ім''я файла під шляхом джерела — не хибний "поза шляхом" (git квотує non-ASCII, коли core.quotepath типово true)' {
        # Фікстура НЕ виставляє core.quotepath — це навмисно: kit має форсувати прапорець
        # у власному виклику git ls-tree, а не покладатись на налаштування репозиторію.
        # Без -c core.quotepath=false git ls-tree повертає рядок `"...\320\221....xml`
        # (з ЛАПКОЮ на початку через октальне екранування), StartsWith($prefix) хибний,
        # і файл, що насправді лежить під RepoPath, репортується як сторонній.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cyrillic')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'Банки.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*поза шляхом джерела*').Count | Should -Be 0
    }

    It 'Storage-Source іншого джерела — помилка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrongsource')
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Beta', 'Storage-Version: 1')
        $f = @(Test-KitStorageBranchInvariants -RepoRoot $repo -Branch 'storage/Alpha_SMB' -SourceKey 'Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src')
        @($f | Where-Object Message -like '*Storage-Source*Beta*').Count | Should -Be 1
    }
}

Describe 'Get-KitStorageActivity — mtime сховища без платформи (§5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force

        # Фейкове сховище: 1cv8ddb.1CD (за замовчуванням) + опційно файли в data/objects і/або
        # data/pack, з явним LastWriteTimeUtc — той самий приклад, що SessionCheck.Tests.ps1
        # (New-FakeStorage), тут локально, бо цей файл StorageBranch.psm1 не імпортує GitMerge.
        function script:New-FakeStorageDir {
            param(
                [Parameter(Mandatory)][string]$Path,
                [switch]$NoDb,
                [hashtable[]]$ObjectFiles = @(),
                [hashtable[]]$PackFiles = @()
            )
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            if (-not $NoDb) { Set-Content -LiteralPath (Join-Path $Path '1cv8ddb.1CD') -Value 'db' }
            foreach ($f in $ObjectFiles) {
                $dir = Join-Path $Path 'data/objects/ab'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $p = Join-Path $dir $f.Name
                Set-Content -LiteralPath $p -Value $f.Content
                (Get-Item $p).LastWriteTimeUtc = $f.Stamp.ToUniversalTime()
            }
            foreach ($f in $PackFiles) {
                $dir = Join-Path $Path 'data/pack'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $p = Join-Path $dir $f.Name
                Set-Content -LiteralPath $p -Value $f.Content
                (Get-Item $p).LastWriteTimeUtc = $f.Stamp.ToUniversalTime()
            }
        }
    }

    # Рев'ю раунд 2, C1 — саме цей стан (data/objects Є, але в ній жодного файла) падав:
    # Measure-Object -Maximum на справді порожньому вводі не дає Count=0, а не дає НІЧОГО, і
    # .Maximum на $null під StrictMode кидає "The property 'Count' cannot be found on this
    # object" замість дружнього Reason. Той самий зразок, що StorageReport.Tests.ps1:121.
    It 'усі чотири стани не падають під StrictMode (явний Should -Not -Throw)' {
        Set-StrictMode -Version Latest
        $missingRoot = Join-Path $TestDrive 'nope'
        $noObjects   = Join-Path $TestDrive 'no-objects'
        $emptyObjects = Join-Path $TestDrive 'empty-objects'
        $withFiles   = Join-Path $TestDrive 'with-files'
        New-Item -ItemType Directory -Path $noObjects -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $emptyObjects 'data/objects') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $withFiles 'data/objects/ab') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $withFiles 'data/objects/ab/cdef.bin') -Value 'x'

        { Get-KitStorageActivity -StoragePath $missingRoot } | Should -Not -Throw
        { Get-KitStorageActivity -StoragePath $noObjects } | Should -Not -Throw
        { Get-KitStorageActivity -StoragePath $emptyObjects } | Should -Not -Throw
        { Get-KitStorageActivity -StoragePath $withFiles } | Should -Not -Throw
    }

    It 'теки сховища немає — Accessible=$false, Reason називає шлях, LatestObjectWrite=$null' {
        $r = Get-KitStorageActivity -StoragePath (Join-Path $TestDrive 'truly-missing')
        $r.Accessible | Should -BeFalse
        $r.IsStorage | Should -BeFalse
        $r.Reason | Should -BeLike '*недоступний*'
        $r.LatestObjectWrite | Should -BeNullOrEmpty
    }

    It 'тека є, data/objects немає, 1cv8ddb.1CD є — Accessible=$true, Reason називає обидві теки, LatestObjectWrite=$null' {
        $s = Join-Path $TestDrive 'no-objects-2'
        New-FakeStorageDir -Path $s
        $r = Get-KitStorageActivity -StoragePath $s
        $r.Accessible | Should -BeTrue
        $r.IsStorage | Should -BeFalse
        $r.Reason | Should -BeLike '*data/objects*'
        $r.Reason | Should -BeLike '*data/pack*'
        $r.LatestObjectWrite | Should -BeNullOrEmpty
    }

    It 'data/objects є, але порожня (жодного файла), pack теж немає — Accessible=$true, IsStorage=$false, Reason називає порожність, LatestObjectWrite=$null' {
        $s = Join-Path $TestDrive 'empty-objects-2'
        New-FakeStorageDir -Path $s
        New-Item -ItemType Directory -Path (Join-Path $s 'data/objects') -Force | Out-Null
        $r = Get-KitStorageActivity -StoragePath $s
        $r.Accessible | Should -BeTrue
        $r.IsStorage | Should -BeFalse
        $r.Reason | Should -BeLike '*немає жодного файла*'
        $r.LatestObjectWrite | Should -BeNullOrEmpty
    }

    It 'у data/objects є файли, pack немає — IsStorage=$true, LatestObjectWrite = максимальний mtime, Reason порожній' {
        $s = Join-Path $TestDrive 'with-files-2'
        # ToUniversalTime() з невизначеним (не "Z") літералом — [datetime]'...' сам собою
        # парситься в Kind=Local (конвертує стрілки годинника), і пряме порівняння з
        # .LastWriteTimeUtc (Kind=Utc) хибно падає на розбіжності тиків, хоча мить та сама, —
        # зловлено живим прогоном цього тесту.
        $newerStamp = [datetime]'2026-03-01T00:00:00'
        New-FakeStorageDir -Path $s -ObjectFiles @(
            @{ Name = 'older.bin'; Content = 'a'; Stamp = [datetime]'2026-01-01T00:00:00' }
            @{ Name = 'newer.bin'; Content = 'b'; Stamp = $newerStamp }
        )
        $r = Get-KitStorageActivity -StoragePath $s
        $r.Accessible | Should -BeTrue
        $r.IsStorage | Should -BeTrue
        $r.Reason | Should -BeNullOrEmpty
        $r.LatestObjectWrite | Should -Be $newerStamp.ToUniversalTime()
        $r.LatestPackWrite | Should -BeNullOrEmpty
        @($r.PackFiles).Count | Should -Be 0
    }

    # Задача 8 (task-8-brief.md): пакування — норма, не аномалія. Живий прогін B3 знайшов справжнє
    # сховище з 16 версіями, чия data/objects порожня — уся історія в data/pack (4 файли, 2,2 МБ).
    Context 'Пакування (data/pack) — спека 9f6ad5e §5' {
        It 'порожня objects, непорожня pack — IsStorage=$true, LatestPackWrite заповнений, LatestObjectWrite=$null, Reason порожній' {
            $s = Join-Path $TestDrive 'packed-only'
            $stamp = [datetime]'2026-02-01T00:00:00'
            New-FakeStorageDir -Path $s -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = $stamp })
            New-Item -ItemType Directory -Path (Join-Path $s 'data/objects') -Force | Out-Null   # objects є, порожня
            $r = Get-KitStorageActivity -StoragePath $s
            $r.IsStorage | Should -BeTrue
            $r.LatestObjectWrite | Should -BeNullOrEmpty
            $r.LatestPackWrite | Should -Be $stamp.ToUniversalTime()
            $r.Reason | Should -BeNullOrEmpty
        }

        It 'обидві теки непорожні — обидві дати заповнені, PackFiles містить усі файли pack' {
            $s = Join-Path $TestDrive 'packed-both'
            New-FakeStorageDir -Path $s `
                -ObjectFiles @(@{ Name = 'a.bin'; Content = 'x'; Stamp = [datetime]'2026-01-05T00:00:00' }) `
                -PackFiles @(
                    @{ Name = '1.pack'; Content = 'p1'; Stamp = [datetime]'2026-01-10T00:00:00' }
                    @{ Name = '2.pack'; Content = 'p2'; Stamp = [datetime]'2026-01-15T00:00:00' }
                )
            $r = Get-KitStorageActivity -StoragePath $s
            $r.IsStorage | Should -BeTrue
            $r.LatestObjectWrite | Should -Not -BeNullOrEmpty
            $r.LatestPackWrite | Should -Be ([datetime]'2026-01-15T00:00:00').ToUniversalTime()
            @($r.PackFiles).Count | Should -Be 2
            (@($r.PackFiles).Name | Sort-Object) | Should -Be @('1.pack', '2.pack')
        }

        It 'каталог без 1cv8ddb.1CD (навіть з файлами в pack) — IsStorage=$false, скарга доречна' {
            $s = Join-Path $TestDrive 'no-db-with-pack'
            New-FakeStorageDir -Path $s -NoDb -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-01T00:00:00' })
            $r = Get-KitStorageActivity -StoragePath $s
            $r.Accessible | Should -BeTrue
            $r.IsStorage | Should -BeFalse
            $r.Reason | Should -BeLike '*1cv8ddb.1CD*'
        }

        It 'обидві теки порожні (1cv8ddb.1CD є) — IsStorage=$false, Reason називає ОБИДВІ теки, а не саму лише objects' {
            $s = Join-Path $TestDrive 'both-empty'
            New-FakeStorageDir -Path $s
            New-Item -ItemType Directory -Path (Join-Path $s 'data/objects') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $s 'data/pack') -Force | Out-Null
            $r = Get-KitStorageActivity -StoragePath $s
            $r.IsStorage | Should -BeFalse
            $r.Reason | Should -BeLike '*data/objects*'
            $r.Reason | Should -BeLike '*data/pack*'
        }

        It 'pack рівно з одним файлом — PackFiles.Count=1, виняток не кидається (StrictMode: @(Get-ChildItem) обов''язковий)' {
            Set-StrictMode -Version Latest
            $s = Join-Path $TestDrive 'packed-single'
            New-FakeStorageDir -Path $s -PackFiles @(@{ Name = 'only.pack'; Content = 'p'; Stamp = [datetime]'2026-01-01T00:00:00' })
            { Get-KitStorageActivity -StoragePath $s } | Should -Not -Throw
            $r = Get-KitStorageActivity -StoragePath $s
            @($r.PackFiles).Count | Should -Be 1
            $r.PackFiles[0].Name | Should -Be 'only.pack'
        }
    }
}

Describe 'StorageBranch.psm1 — план реплею й повідомлення коміту' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:All = @(2, 23, 24, 47 | ForEach-Object { [pscustomobject]@{ Version = $_ } })
        function script:New-Version {
            param([int]$Version, [string]$Comment = 'Правка форми', [string]$ConfigVersion = '1.2.3', [string]$User = 'Абдулов')
            [pscustomobject]@{ Version = $Version; User = $User; Date = '22.01.2026'; Time = '17:51:21'
                ConfigVersion = $ConfigVersion; Comment = $Comment; Label = ''; LabelComment = ''
                Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-22T17:51:21' }
        }
    }

    Context 'Get-KitPendingVersions' {
        It 'порожня гілка ($null) — усі версії зі звіту за зростанням' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null).Version | Should -Be @(2, 23, 24, 47)
        }
        It 'після 23 — лише 24 і 47 (перелік, не діапазон: пропуски штатні)' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion 23).Version | Should -Be @(24, 47)
        }
        It 'усе залито — порожній масив, а не $null (StrictMode-безпечно)' {
            Set-StrictMode -Version Latest
            $p = Get-KitPendingVersions -AllVersions $script:All -LastVersion 47
            { $p.Count } | Should -Not -Throw
            $p.Count | Should -Be 0
        }
        It '-MaxVersions обрізає з голови' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -MaxVersions 2).Version | Should -Be @(2, 23)
        }
        # Task 2 (task-2-brief.md, §9.4) — закріпити явно: -MaxVersions без -From* бере
        # найРАНІШУ версію. Це наявна, ПРАВИЛЬНА поведінка для дозаливки — саме її сплутали
        # зі "лише поточна", і саме тому з'явились -FromVersion/-FromLatest нижче. Тест
        # існує, щоб цю поведінку випадково не "полагодили" під час цієї ж задачі.
        It '-MaxVersions 1 БЕЗ -From* — найРАНІША версія (закріплення наявної поведінки, Task 2)' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -MaxVersions 1).Version | Should -Be @(2)
        }
        It 'дзеркало попереду сховища — зупинка' {
            { Get-KitPendingVersions -AllVersions $script:All -LastVersion 99 } | Should -Throw '*попереду*99*47*'
        }
        It 'порожній звіт при непорожньому дзеркалі — зупинка; при порожньому — порожньо' {
            { Get-KitPendingVersions -AllVersions @() -LastVersion 5 } | Should -Throw '*порожній*'
            (Get-KitPendingVersions -AllVersions @() -LastVersion $null).Count | Should -Be 0
        }
        It 'Get-KitVersionGapNote: мінімум у звіті > остання + 1 — інформаційний рядок; інакше $null' {
            $p = Get-KitPendingVersions -AllVersions $script:All -LastVersion 2
            Get-KitVersionGapNote -Pending $p -LastVersion 2 | Should -BeLike '*23*2*'
            Get-KitVersionGapNote -Pending (Get-KitPendingVersions -AllVersions $script:All -LastVersion 23) -LastVersion 23 | Should -BeNullOrEmpty
            Get-KitVersionGapNote -Pending $p -LastVersion $null | Should -BeNullOrEmpty
        }
    }

    Context 'Get-KitPendingVersions — -FromVersion/-FromLatest (Task 2, §9.4: глибина ЗВІДКИ, не скільки)' {
        # $script:All = 2, 23, 24, 47 (BeforeAll вище).
        It '-FromVersion 23 — версії від 23 ВКЛЮЧНО (не лише "більше за")' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromVersion 23).Version | Should -Be @(23, 24, 47)
        }
        It '-FromVersion і -MaxVersions комбінуються незалежно: -FromVersion 23 -MaxVersions 2 = 23 і 24' {
            (Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromVersion 23 -MaxVersions 2).Version | Should -Be @(23, 24)
        }
        It '-FromLatest — рівно одна версія, максимальна зі звіту (47)' {
            $p = Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromLatest
            @($p).Count | Should -Be 1
            $p.Version | Should -Be 47
        }
        It '-FromVersion 0 — зупинка (валідація параметра, не мовчазне приведення)' {
            { Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromVersion 0 } | Should -Throw '*додатн*'
        }
        It '-FromVersion від''ємний — зупинка' {
            { Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromVersion -5 } | Should -Throw '*додатн*'
        }
        It '-FromVersion більший за максимум зі звіту — зупинка з переліком доступних версій' {
            { Get-KitPendingVersions -AllVersions $script:All -LastVersion $null -FromVersion 999 } |
                Should -Throw '*999*2, 23, 24, 47*'
        }
    }

    Context 'New-KitStorageCommitMessage' {
        It 'розширення: тема, порожній рядок, чотири трейлери в цьому порядку' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 47) -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -Be "Правка форми`n`nStorage-Source: SMP_X`nStorage-Version: 47`nExtension-Version: 1.2.3`nStorage-User: Абдулов"
        }
        It 'конфігурація: Config-Version замість Extension-Version' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 3) -SourceKey 'base' -SourceType CONFIGURATION
            $m | Should -BeLike "*`nConfig-Version: 1.2.3`n*"
            $m | Should -Not -BeLike '*Extension-Version*'
        }
        It 'без версії конфігурації — трейлера версії немає; без коментаря — тема «Версія сховища N»' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 8 -Comment '' -ConfigVersion '') -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -Be "Версія сховища 8`n`nStorage-Source: SMP_X`nStorage-Version: 8`nStorage-User: Абдулов"
        }
        It 'багаторядковий коментар: перший непорожній рядок — тема, решта — тіло' {
            $m = New-KitStorageCommitMessage -Version (New-Version -Version 9 -Comment "`nТема`nДругий рядок`n  третій  ") -SourceKey 'SMP_X' -SourceType EXTENSION
            $m | Should -BeLike "Тема`n`nДругий рядок`n  третій`n`nStorage-Source: SMP_X*"
        }
    }
}

Describe 'StorageBranch.psm1 — worktree гілки дзеркала й коміт версії (§3.3, шар 1)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Stamp = [datetime]'2026-01-22T17:51:21'
    }

    It 'перший sync: orphan-гілка через worktree; коміт не рухає HEAD і робочу копію основного дерева' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'first') -WithHooks
        $headBefore = git -C $repo rev-parse HEAD
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $wt.Created | Should -BeTrue
        (git -C $wt.Path symbolic-ref -q HEAD) | Should -Be 'refs/heads/storage/Alpha_SMB'

        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        $target | Should -Exist
        Set-Content -LiteralPath (Join-Path $target 'Configuration.xml') -Value '<x/>' -NoNewline
        Set-Content -LiteralPath (Join-Path $target 'ConfigDumpInfo.xml') -Value '<junk/>' -NoNewline
        Set-Content -LiteralPath (Join-Path $target 'DumpFilesIndex.txt') -Value 'junk' -NoNewline

        $r = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' `
            -Message "v17`n`nStorage-Source: Alpha_SMB`nStorage-Version: 17`nStorage-User: Абдулов" `
            -AuthorName 'PrudnikovV' -AuthorEmail 'p@example.invalid' -Timestamp $script:Stamp
        $r.Empty | Should -BeFalse
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path

        # Гілка є, трейлери й автор на місці, сміття платформи в дереві немає
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 17
        (git -C $repo log -1 --format='%an|%aI' storage/Alpha_SMB) | Should -BeLike 'PrudnikovV|2026-01-22T17:51:21*'
        @(git -C $repo ls-tree -r --name-only storage/Alpha_SMB) | Should -Be @('Alpha_SMB/cfe/src/Configuration.xml')

        # Основне дерево не зрушило
        (git -C $repo rev-parse HEAD) | Should -Be $headBefore
        (git -C $repo branch --show-current) | Should -Be 'main'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        (Join-Path $repo 'build/sync/Alpha_SMB/wt') | Should -Not -Exist
        @(git -C $repo worktree list).Count | Should -Be 1
    }

    It 'повторний sync: worktree на наявну гілку, Created=false; однаковий дамп дає Empty=true й порожній коміт' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'again') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'Configuration.xml' -Content '<x/>' `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $wt.Created | Should -BeFalse
        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        @(Get-ChildItem $target).Count | Should -Be 0
        Set-Content -LiteralPath (Join-Path $target 'Configuration.xml') -Value '<x/>' -NoNewline
        $r = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' `
            -Message "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2`nStorage-User: gitbot" `
            -AuthorName 'Test Bot' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp
        $r.Empty | Should -BeTrue
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 2
    }

    It 'байти платформи лягають у git як є, навіть під core.autocrlf=true і без .gitattributes у worktree' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bytes') -WithHooks
        git -C $repo config core.autocrlf true
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src'
        # Змішані кінці рядків в одному файлі — саме так пише платформа (docs/text-policy.md)
        $mixed = [byte[]](0x3C,0x61,0x3E,0x0D,0x0A,0x74,0x0A,0x74,0x3C,0x2F,0x61,0x3E)
        [System.IO.File]::WriteAllBytes((Join-Path $target 'Form.xml'), $mixed)
        $rawId = (git -C $repo hash-object --no-filters (Join-Path $target 'Form.xml')).Trim()
        Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath 'Alpha_SMB/cfe/src' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" `
            -AuthorName 'T' -AuthorEmail 't@example.invalid' -Timestamp $script:Stamp | Out-Null
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        (git -C $repo rev-parse 'storage/Alpha_SMB:Alpha_SMB/cfe/src/Form.xml').Trim() | Should -Be $rawId
    }

    It 'залишок перерваного прогону (тека worktree є) — прибирається, новий worktree створюється' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'leftover') -WithHooks
        $path = Join-Path $repo 'build/sync/Alpha_SMB/wt'
        New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path $path | Out-Null
        # «Перервано»: worktree лишився зареєстрованим і на диску
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path $path } | Should -Not -Throw
        Remove-KitStorageWorktree -RepoRoot $repo -Path $path
    }

    It 'виняток із finally (Remove-KitStorageWorktree) не витісняє первинний виняток, навіть якщо тека заблокована' {
        # Рев'ю B2 (Blocker 1): Remove-KitStorageWorktree навмисно без throw, щоб не заступити
        # собою виняток, який уже летить із finally навколо реплею sync. Живим прогоном це не
        # доведено — тут заблокований на видалення файл (Windows-хендл, FileShare.None) змушує
        # git worktree remove і Remove-Item усередині впасти, і перевіряємо, що назовні йде
        # рівно первинний текст "ПЛАТФОРМА-ВПАЛА", а не будь-яка помилка прибирання worktree.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'lockedcleanup') -WithHooks
        $wt = New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt')
        $locked = Join-Path $wt.Path 'locked.txt'
        Set-Content -LiteralPath $locked -Value 'x' -NoNewline
        $handle = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            { try { throw 'ПЛАТФОРМА-ВПАЛА' } finally { Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path } } |
                Should -Throw '*ПЛАТФОРМА-ВПАЛА*'
        } finally {
            $handle.Dispose()
        }
        # Прибирання за собою: дескриптор закрито, тепер тека дійсно видаляється — інакше
        # осиротілий worktree й заблокована на той момент тека лишились би сміттям для інших тестів.
        git -C $repo worktree prune 2>$null | Out-Null
        Remove-KitStorageWorktree -RepoRoot $repo -Path $wt.Path
        $wt.Path | Should -Not -Exist
    }

    It 'гілка дзеркала вибрана в основній робочій копії — зупинка з поясненням' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'checkedout') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        git -C $repo checkout -q storage/Alpha_SMB
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'build/sync/Alpha_SMB/wt') } |
            Should -Throw '*storage/Alpha_SMB*вибрана*'
        git -C $repo checkout -q main
    }

    It 'шлях worktree поза build/sync — відмова (Assert-SafeWorkPath)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsafe')
        { New-KitStorageWorktree -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Path (Join-Path $repo 'Alpha_SMB') } | Should -Throw '*build*sync*'
    }

    It 'Get-KitCommitSha: неіснуючий ref — зупинка з кодом rev-parse; наявний ref — той самий SHA, що дає сирий git' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'commitsha')
        { Get-KitCommitSha -RepoRoot $repo -Ref 'no-such-ref' } | Should -Throw '*rev-parse*no-such-ref*'
        Get-KitCommitSha -RepoRoot $repo -Ref main | Should -Be (git -C $repo rev-parse main)
    }
}

Describe 'StorageBranch.psm1 — версія для verify з merge-base (§3.5, Q8)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'vv') -WithHooks -WithGitattributes -WithGitignore
        foreach ($v in 5, 7) {
            Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
    }

    It 'main ще не зливав дзеркало — зупинка «спершу sync»' {
        # '*ніколи не зливав*', не '*sync*' (рев'ю B3 раунд 2, Important 2): обидві зупинки
        # Get-KitVerifyVersion («гілки немає» і «ніколи не зливав») згадують sync у тексті —
        # '*sync*' не розрізнив би регресію, що плутає ці два стани, а «ніколи не зливав»
        # унікальне саме для стану «гілка є, спільного предка з ref немає».
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB' } | Should -Throw '*ніколи не зливав*'
    }

    It 'verify storage/X — вершина гілки, новіших немає' {
        $r = Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'storage/Alpha_SMB' -Branch 'storage/Alpha_SMB'
        $r.Version | Should -Be 7
        $r.NewerVersions.Count | Should -Be 0
    }

    It 'після злиття: версія = остання злита; нові версії на дзеркалі — окремим списком' {
        Merge-KitBranchInto -RepoRoot $script:Repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null
        (Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB').Version | Should -Be 7

        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v9.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 9')
        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v12.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 12')
        $r = Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Alpha_SMB'
        $r.Version | Should -Be 7
        $r.NewerVersions | Should -Be @(9, 12)
    }

    It 'гілка задачі від main успадковує merge-base' {
        git -C $script:Repo checkout -q -b feature/x
        (Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'feature/x' -Branch 'storage/Alpha_SMB').Version | Should -Be 7
        git -C $script:Repo checkout -q main
    }

    It 'невідомий ref і відсутня гілка дзеркала — зупинки з іменами' {
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'nope' -Branch 'storage/Alpha_SMB' } | Should -Throw "*'nope'*"
        { Get-KitVerifyVersion -RepoRoot $script:Repo -Ref 'main' -Branch 'storage/Beta' } | Should -Throw '*storage/Beta*sync*'
    }
}
