#Requires -Version 7
Describe 'kit adopt — прев''ю показує ціну заміни' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Adopt {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit adopt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Репозиторій із дзеркалом: у гілці задачі є файл, якого немає у дзеркалі (робота, яку
        # людина у сховище не взяла), і файл, який у дзеркалі інший.
        function script:New-AdoptRepo {
            param([string]$Name)
            # -WithGitignore обов'язковий: adopt пише в <корінь>/build/adopt/<ключ>/mirror, і без
            # шаблонного .gitignore асерція «git status порожній» впаде на робочому смітті самої команди.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitignore
            $src  = Join-Path $repo 'Alpha_SMB/cfe/src'
            Set-Content -LiteralPath (Join-Path $src 'Shared.xml') -Value 'версія гілки' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $src 'OnlyInBranch.xml') -Value 'лише в гілці' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            git -C $repo commit -q -m 'робота агента' 2>&1 | Out-Null
            # Дзеркало: та сама тека, але Shared.xml інший і OnlyInBranch.xml відсутній.
            git -C $repo checkout -q -b 'storage/Alpha_SMB' 2>&1 | Out-Null
            Remove-Item -LiteralPath (Join-Path $src 'OnlyInBranch.xml') -Force
            Set-Content -LiteralPath (Join-Path $src 'Shared.xml') -Value 'версія сховища' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            $env:V8KIT_SYNC = '1'
            # Трейлер Storage-Version: обов'язковий — Get-KitStorageBranchLastVersion (яку -Apply
            # бере для тексту коміту "adopt: … (версія N)") читає його і зупиняється на вершині без
            # нього ("гілку писав не sync"). Два -m: git сам вставляє порожній рядок між ними, тож
            # другий абзац читається як трейлер (той самий формат, що складає New-KitStorageCommitMessage).
            git -C $repo commit -q -m 'sync: версія 7' -m 'Storage-Version: 7' 2>&1 | Out-Null
            Remove-Item Env:\V8KIT_SYNC
            git -C $repo checkout -q main 2>&1 | Out-Null
            $repo
        }
    }

    It 'без -Apply нічого не змінює й називає обидва боки' {
        $repo = New-AdoptRepo -Name 'adopt-preview'
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*Shared.xml*'
        $r.Output   | Should -BeLike '*OnlyInBranch.xml*'
        $r.Output   | Should -BeLike '*-Apply*'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Shared.xml') -Raw).Trim() | Should -Be 'версія гілки'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'дзеркала немає — зупинка з іменем гілки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-no-mirror') -WithHooks
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*storage/Alpha_SMB*'
    }

    It '-Apply замінює дерево вмістом дзеркала й прибирає зайве' {
        $repo = New-AdoptRepo -Name 'adopt-apply'
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Shared.xml') -Raw).Trim() | Should -Be 'версія сховища'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Not -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        (git -C $repo log -1 --format=%s) | Should -BeLike 'adopt: Alpha_SMB*'
    }

    It '-Apply складає незакомічене в резервну копію перед заміною' {
        $repo = New-AdoptRepo -Name 'adopt-backup'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Draft.xml') -Value 'чернетка' -Encoding UTF8
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.Output | Should -BeLike '*adopt-backup*'
        $copies = @(Get-ChildItem -Path (Join-Path $repo 'Alpha_SMB/build/adopt-backup') -Recurse -Filter 'Draft.xml' -ErrorAction SilentlyContinue)
        $copies.Count | Should -BeGreaterThan 0
    }

    It 'дерево вже збігається з дзеркалом — коміту немає' {
        $repo = New-AdoptRepo -Name 'adopt-noop'
        Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply') | Out-Null
        $before = (git -C $repo rev-parse HEAD)
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.Output | Should -BeLike '*вже збігається*'
        (git -C $repo rev-parse HEAD) | Should -Be $before
    }

    It 'файл різниться лише CR — прев''ю називає окремо, -Apply замінює і не каже «вже збігається»' {
        # Регресія рев'ю фікс-раунду 1: CrOnly ігнорувався і в перевірці no-op, і в прев'ю —
        # дерево, що різниться з дзеркалом лише кінцями рядків, виглядало як «вже збігається»,
        # хоча CRLF/LF-розбіжність — підпис зламаної політики тексту (docs/text-policy.md), а
        # не шум, і verify.psm1 на тому самому дереві доповів би протилежне.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'adopt-cronly') -WithHooks -WithGitignore
        $src  = Join-Path $repo 'Alpha_SMB/cfe/src'
        Set-Content -LiteralPath (Join-Path $src 'CrOnly.xml') -Value "рядок`r`n" -Encoding UTF8 -NoNewline
        git -C $repo add -A 2>&1 | Out-Null
        git -C $repo commit -q -m 'робота агента' 2>&1 | Out-Null
        # Дзеркало: той самий текст, але без CR (LF-only) — саме та різниця, яку Compare-KitTrees
        # класифікує як CrOnly (побайтово різні, однакові після вилучення \r).
        git -C $repo checkout -q -b 'storage/Alpha_SMB' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'CrOnly.xml') -Value "рядок`n" -Encoding UTF8 -NoNewline
        git -C $repo add -A 2>&1 | Out-Null
        $env:V8KIT_SYNC = '1'
        git -C $repo commit -q -m 'sync: версія 7' -m 'Storage-Version: 7' 2>&1 | Out-Null
        Remove-Item Env:\V8KIT_SYNC
        git -C $repo checkout -q main 2>&1 | Out-Null

        $preview = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB')
        $preview.Output | Should -BeLike '*лише CR*'
        $preview.Output | Should -BeLike '*CrOnly.xml*'

        $apply = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $apply.ExitCode | Should -Be 0
        $apply.Output   | Should -Not -BeLike '*вже збігається*'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/CrOnly.xml') -Raw) | Should -Be "рядок`n"
    }

    It '-Apply рухає ancestry: дзеркало стає предком гілки задачі через один злиттєвий коміт' {
        # Фінальне рев'ю C2, Critical: verify визначає версію сховища через git merge-base
        # (Get-KitVerifyVersion, StorageBranch.psm1:556), а заміна піддерева сама по собі
        # merge-base не рухає. Властивість, на якій тримається verify, — рівно ці дві: дзеркало
        # мусить стати ПРЕДКОМ гілки задачі, і коміт заміни мусить бути ЗЛИТТЄВИМ (двобатьківським).
        $repo = New-AdoptRepo -Name 'adopt-ancestry'
        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 0

        git -C $repo merge-base --is-ancestor 'storage/Alpha_SMB' HEAD
        $LASTEXITCODE | Should -Be 0

        (git -C $repo rev-list --count --merges 'HEAD~1..HEAD' | Out-String).Trim() | Should -Be '1'
    }

    It 'guard спрацьовує ДО Remove-Item: чужа незакомічена зміна поза шляхом джерела зупиняє -Apply' {
        # Фінальне рев'ю C2, Critical, «Чотири умови» п.1: коміт заміни йде через git merge, а
        # партійний коміт (--only) git під час злиття забороняє — тож коміт після merge
        # неминуче йде БЕЗ pathspec і фіксує ВЕСЬ індекс. Без guard'а чужа незакомічена робота
        # поза шляхом джерела поїхала б у цей коміт непомітно. Доказ, що зупинка стається ДО
        # знищення, а не після, — OnlyInBranch.xml (усередині шляху джерела) досі на місці.
        $repo = New-AdoptRepo -Name 'adopt-guard-outside'
        $strayPath = Join-Path $repo 'stray-outside.txt'
        Set-Content -LiteralPath $strayPath -Value 'чужа незакомічена робота поза шляхом джерела' -Encoding UTF8

        $r = Invoke-Adopt -Repo $repo -More @('-Source', 'Alpha_SMB', '-Apply')

        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*stray-outside.txt*'
        Join-Path $repo 'Alpha_SMB/cfe/src/OnlyInBranch.xml' | Should -Exist
        (Get-Content -LiteralPath $strayPath -Raw) | Should -BeLike '*чужа незакомічена робота*'
    }
}
