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
            if ($MirrorIsAncestor) {
                # Гілка без злиття: дзеркало вже предок HEAD («Already up to date»), а гілка задачі має роботу поверх.
                git -C $repo merge -q --ff-only 'storage/base' 2>&1 | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'Client_UNF/cf/src/OnlyInBranch.xml') -Value 'лише в гілці' -Encoding UTF8
                git -C $repo add -- 'Client_UNF/cf/src/OnlyInBranch.xml' 2>&1 | Out-Null
                git -C $repo commit -q -m 'робота агента' 2>&1 | Out-Null
            }
            # Після дзеркала: у дзеркалі поставки бути не може (sync її не пише).
            if ($TrackSupply) {
                git -C $repo add -f -- 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' 2>&1 | Out-Null
                git -C $repo commit -q -m 'поставка відстежується (помилково)' 2>&1 | Out-Null
            }
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

Describe 'kit adopt — основна конфігурація з поставкою вендора (спека 2026-09-30 §5.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:New-SupplyAdoptRepo {
            param([string]$Name, [switch]$NoSupplyIgnoreLine, [switch]$NegatedIgnore, [switch]$TrackSupply, [switch]$CrlfIgnore, [switch]$MirrorIsAncestor)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithSupply
            if ($NoSupplyIgnoreLine) {
                # Репозиторій до 1.3.0 (Review Focus 1): рядка ігнору поставки ще немає.
                $gi = Join-Path $repo '.gitignore'
                (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
                git -C $repo commit -qam 'gitignore без рядка поставки' 2>&1 | Out-Null
            }
            if ($CrlfIgnore) {
                # CRLF + порожній рядок + без рядка поставки: форма проби з кінцевою рискою хибила б «ігнорується».
                [System.IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "build/`r`n`r`n*.tmp`r`n")
                git -C $repo commit -qam 'gitignore CRLF без рядка поставки' 2>&1 | Out-Null
            }
            if ($NegatedIgnore) {
                # Правило з негацією: тека НЕ ігнорується цілком, .cf — «неігнорований» (рев'ю Task 4, Important 1).
                $gi = Join-Path $repo '.gitignore'
                $keep = @(Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' })
                Set-Content -LiteralPath $gi -Encoding UTF8 -Value ($keep + '**/Ext/ParentConfigurations/*' + '!**/Ext/ParentConfigurations/*.cf')
                git -C $repo commit -qam 'gitignore з негацією .cf' 2>&1 | Out-Null
            }
            # Дзеркало: той самий Configuration.xml, НОВИЙ .bin, без .cf (як пише sync після Task 2).
            $env:V8KIT_SYNC = '1'
            try {
                git -C $repo checkout -q -b 'storage/base' 2>&1 | Out-Null
                [System.IO.File]::WriteAllBytes((Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..48))
                git -C $repo add -- 'Client_UNF/cf/src/Ext/ParentConfigurations.bin' 2>&1 | Out-Null
                git -C $repo commit -q -m 'sync: версія 3' -m 'Storage-Version: 3' 2>&1 | Out-Null
            } finally { Remove-Item Env:\V8KIT_SYNC -ErrorAction SilentlyContinue }
            git -C $repo checkout -q main 2>&1 | Out-Null
            if ($MirrorIsAncestor) {
                # Гілка без злиття: дзеркало вже предок HEAD («Already up to date»), а гілка задачі має роботу поверх.
                git -C $repo merge -q --ff-only 'storage/base' 2>&1 | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'Client_UNF/cf/src/OnlyInBranch.xml') -Value 'лише в гілці' -Encoding UTF8
                git -C $repo add -- 'Client_UNF/cf/src/OnlyInBranch.xml' 2>&1 | Out-Null
                git -C $repo commit -q -m 'робота агента' 2>&1 | Out-Null
            }
            # Після дзеркала: у дзеркалі поставки бути не може (sync її не пише).
            if ($TrackSupply) {
                git -C $repo add -f -- 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' 2>&1 | Out-Null
                git -C $repo commit -q -m 'поставка відстежується (помилково)' 2>&1 | Out-Null
            }
            $repo
        }
    }

    It 'прев''ю: .cf не в списку «ЗНИКНЕ», .bin — у «прийде зі сховища»' {
        $repo = New-SupplyAdoptRepo 'supply-preview'
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*Vendor.cf*'
        $r.Output | Should -BeLike '*ParentConfigurations.bin*'
    }

    It '-Apply: .cf лишається на диску, новий .bin на місці, без Ext/Ext, робоча копія чиста' {
        $repo = New-SupplyAdoptRepo 'supply-apply'
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        Join-Path $cfg 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        (Get-Item -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin')).Length | Should -Be 48
        Join-Path $cfg 'Ext/Ext' | Should -Not -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        @(git -C $repo ls-files -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
    }

    It '-Apply з CRLF-.gitignore (порожній рядок, без рядка поставки) — exclude додається: .cf не в індексі й не в HEAD, без попередження' {
        $repo = New-SupplyAdoptRepo 'supply-crlf' -CrlfIgnore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*потрапила в індекс*'
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }
    It '<Case>: рецепт БЕЗ коміту — зупинка до стирання, дерево й .cf на місці, текст із рецептом' -ForEach @(
        @{ Case = 'гілка без злиття'; Ancestor = $true }
        @{ Case = 'гілка зі злиттям'; Ancestor = $false }
    ) {
        $repo = if ($Ancestor) { New-SupplyAdoptRepo 'recipe-nocommit-a' -TrackSupply -MirrorIsAncestor } else { New-SupplyAdoptRepo 'recipe-nocommit-m' -TrackSupply }
        git -C $repo rm -r -q --cached -- 'Client_UNF/cf/src/Ext/ParentConfigurations' 2>&1 | Out-Null
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Поставка вендора відстежується git*'
        $r.Output | Should -BeLike "*git rm -r --cached -- 'Client_UNF/cf/src/Ext/ParentConfigurations'*"
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        Join-Path $cfg 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        (Get-Item -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin')).Length | Should -Be $(if ($Ancestor) { 48 } else { 32 }) -Because 'дерево не перезаписане'
    }

    It '<Case>: рецепт З комітом — adopt -Apply проходить, .cf на диску, не в ls-files і не в ls-tree HEAD' -ForEach @(
        @{ Case = 'гілка без злиття'; Ancestor = $true }
        @{ Case = 'гілка зі злиттям'; Ancestor = $false }
    ) {
        $repo = if ($Ancestor) { New-SupplyAdoptRepo 'recipe-commit-a' -TrackSupply -MirrorIsAncestor } else { New-SupplyAdoptRepo 'recipe-commit-m' -TrackSupply }
        git -C $repo rm -r -q --cached -- 'Client_UNF/cf/src/Ext/ParentConfigurations' 2>&1 | Out-Null
        git -C $repo commit -q -m 'поставка поза git' 2>&1 | Out-Null
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        @(git -C $repo ls-files -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0 -Because $r.Output
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0 -Because $r.Output
    }
    It '-Apply з .gitignore з негацією (!*.cf) — .cf ні в індексі, ні в HEAD, лишається на диску' {
        $repo = New-SupplyAdoptRepo 'supply-negation' -NegatedIgnore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        @(git -C $repo ls-files -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0 -Because $r.Output
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0 -Because $r.Output
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        (git -C $repo rev-parse -q --verify MERGE_HEAD 2>$null) | Should -BeNullOrEmpty -Because 'відкат мусить прибрати незавершене злиття'
    }

    It '-Apply, коли поставку відстежує git — зупинка ДО стирання дерева з рецептом git rm --cached' {
        $repo = New-SupplyAdoptRepo 'supply-tracked' -TrackSupply
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Поставка вендора відстежується git*'
        $r.Output | Should -BeLike "*git rm -r --cached -- 'Client_UNF/cf/src/Ext/ParentConfigurations'*"
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        Join-Path $cfg 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        (Get-Item -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin')).Length | Should -Be 32 -Because 'дерево не перезаписане'
        (git -C $repo rev-parse -q --verify MERGE_HEAD 2>$null) | Should -BeNullOrEmpty
    }

    It '-Apply у репозиторії без рядка ігнору поставки — .cf не потрапляє ні в індекс, ні в коміт' {
        $repo = New-SupplyAdoptRepo 'supply-noignore' -NoSupplyIgnoreLine
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'base', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(git -C $repo ls-files -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        @(git -C $repo ls-tree -r --name-only HEAD -- 'Client_UNF/cf/src/Ext/ParentConfigurations').Count | Should -Be 0
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }

    It 'розширення клієнтського воркспейсу (кирилиця в імені) — adopt -Apply працює як раніше' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-cyr') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore
        $env:V8KIT_SYNC = '1'
        try {
            git -C $repo checkout -q -b 'storage/Доработки' 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'Client_UNF/cfe/Доработки/src/New.xml') -Value 'нове' -Encoding UTF8
            git -C $repo add -A 2>&1 | Out-Null
            git -C $repo commit -q -m 'sync: версія 2' -m 'Storage-Version: 2' 2>&1 | Out-Null
        } finally { Remove-Item Env:\V8KIT_SYNC -ErrorAction SilentlyContinue }
        git -C $repo checkout -q main 2>&1 | Out-Null
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'adopt' -Repo $repo -More @('-Source', 'Доработки', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'Client_UNF/cfe/Доработки/src/New.xml' | Should -Exist
    }
}

Describe 'Remove-KitSupplyFromIndex — страховка: поставка знімається з індексу, файл на диску цілий' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/adopt.psm1").Path -Force
        function script:New-StagedSupplyRepo {
            param([string]$Name, [switch]$Merge)
            $repo = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            git -C $repo init -q -b main 2>&1 | Out-Null
            git -C $repo config user.email 'a@b.c'; git -C $repo config user.name 'n'
            Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'a'
            git -C $repo add -A 2>&1 | Out-Null; git -C $repo commit -q -m init 2>&1 | Out-Null
            if ($Merge) {
                git -C $repo checkout -q -b other 2>&1 | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'o.txt') -Value 'o'
                git -C $repo add -A 2>&1 | Out-Null; git -C $repo commit -q -m other 2>&1 | Out-Null
                git -C $repo checkout -q main 2>&1 | Out-Null
                git -C $repo merge --no-commit --no-ff -s ours other 2>&1 | Out-Null
            }
            $dir = Join-Path $repo 'src/Ext/ParentConfigurations'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Vendor.cf') -Value 'cf'
            Set-Content -LiteralPath (Join-Path $repo 'src/Other.xml') -Value 'x'
            git -C $repo add -A 2>&1 | Out-Null
            $repo
        }
    }

    It '<Case>: знімає .cf з індексу, файл на диску, чужий застейджений файл лишається' -ForEach @(
        @{ Case = 'без злиття'; Merge = $false }
        @{ Case = 'у стані злиття (MERGE_HEAD)'; Merge = $true }
    ) {
        $repo = if ($Merge) { New-StagedSupplyRepo 'idx-merge' -Merge } else { New-StagedSupplyRepo 'idx-plain' }
        @(git -C $repo diff --cached --name-only -- 'src/Ext/ParentConfigurations').Count | Should -Be 1 -Because 'передумова: .cf застейджено'
        $removed = @(InModuleScope adopt -Parameters @{ R = $repo } { Remove-KitSupplyFromIndex -RepoRoot $R -SupplyPath 'src/Ext/ParentConfigurations' 3>$null })
        $removed | Should -Contain 'src/Ext/ParentConfigurations/Vendor.cf'
        @(git -C $repo diff --cached --name-only -- 'src/Ext/ParentConfigurations').Count | Should -Be 0
        Join-Path $repo 'src/Ext/ParentConfigurations/Vendor.cf' | Should -Exist
        @(git -C $repo diff --cached --name-only -- 'src/Other.xml').Count | Should -Be 1
        if ($Merge) { (git -C $repo rev-parse -q --verify MERGE_HEAD) | Should -Not -BeNullOrEmpty -Because 'злиття не скасовано' }
    }

    It 'нічого не застейджено — порожній результат, без змін' {
        $repo = New-StagedSupplyRepo 'idx-none'
        git -C $repo reset -q 2>&1 | Out-Null
        @(InModuleScope adopt -Parameters @{ R = $repo } { Remove-KitSupplyFromIndex -RepoRoot $R -SupplyPath 'src/Ext/ParentConfigurations' }).Count | Should -Be 0
    }
}
