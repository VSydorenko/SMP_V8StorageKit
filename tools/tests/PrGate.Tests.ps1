#Requires -Version 7
# pr-gate (перенесено з agent-kit 0.9.1): запобіжники, чия поломка мовчки дає хибний результат —
# push у base/main, злиття конфліктного PR, злиття не тієї голови, видалення гілки без підтвердженого
# MERGED, worktree у спільному дереві. Справжня команда `pr-gate` — підпроцесом
# (tools/kit.ps1) на синтетичному репо з bare-origin проти фальшивого gh.exe на початку PATH
# (fixtures/FakeGh.psm1). Кожен тест має контроль, що вміє впасти: нормальний шлях доходить до
# пишучого виклику, тож порожній журнал чи «нічого не змінилось» не означає, що фальшивка не
# підхоплена.
Describe 'pr-gate — запобіжники' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/FakeGh.psm1").Path -Force
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Bin = New-KitFakeGh -Dir (Join-Path $TestDrive 'fakebin')
        $script:Journal = Join-Path $TestDrive 'gh-calls.log'
        $script:Scenario = Join-Path $TestDrive 'scenario.json'
        $script:EmptyConfig = Join-Path $TestDrive 'xdg'   # машинний профіль не підмішується
        New-Item -ItemType Directory -Path $script:EmptyConfig | Out-Null
        $script:OldSha = 'a' * 40
        # Особа git — на весь файл: її потребують і підготовка репо, і сама команда (worktree, merge).
        $script:Git = @{ GIT_AUTHOR_NAME = 't'; GIT_AUTHOR_EMAIL = 't@t'; GIT_COMMITTER_NAME = 't'; GIT_COMMITTER_EMAIL = 't@t' }
        $script:SavedGit = @{}
        foreach ($k in $script:Git.Keys) { $script:SavedGit[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $script:Git[$k]) }

        # Головний checkout з bare-origin і одним комітом у main; профіль — хеш-таблиця.
        # SetEnvironmentVariable(k, $null) із PowerShell лишає порожню змінну, а не прибирає її: порожнє
        # GIT_AUTHOR_NAME ламало б git у наступних файлах того ж процесу.
        function script:Restore-PgEnv {
            param([string]$Name, $Value)
            if ($null -eq $Value) { Remove-Item -LiteralPath "env:$Name" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($Name, $Value) }
        }
        function script:New-PgRepo {
            param([string]$Name, [hashtable]$Profile)
            $origin = Join-Path $TestDrive "$Name-origin.git"
            $dir = Join-Path $TestDrive $Name
            git init -q --bare -b main $origin
            git init -q -b main $dir
            git -C $dir remote add origin $origin
            [System.IO.File]::WriteAllText((Join-Path $dir '.gitignore'), ".worktrees/`n.agents/`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'x.txt'), "x`n")
            git -C $dir add .gitignore x.txt
            git -C $dir commit -q -m init
            git -C $dir push -q origin main
            Set-PgProfile -Dir $dir -Profile $Profile
            [pscustomobject]@{ Dir = $dir; Origin = $origin }
        }
        function script:Set-PgProfile {
            param([string]$Dir, [hashtable]$Profile)
            New-Item -ItemType Directory -Path (Join-Path $Dir '.agents') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Dir '.agents/kit.profile.json'), ($Profile | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        }
        function script:Get-PgOriginBranches {
            param([string]$Origin)
            @(git -C $Origin for-each-ref --format='%(refname:short)' refs/heads)
        }
        # Відповідь `gh pr view --json …` для PR №5.
        function script:New-PrJson {
            param([hashtable]$Over = @{})
            $o = [ordered]@{
                number = 5; state = 'OPEN'; isDraft = $false; mergeable = 'MERGEABLE'; mergeStateStatus = 'CLEAN'
                headRefOid = $script:OldSha; headRefName = 'feat'; baseRefName = 'main'; isCrossRepository = $false
                url = 'https://github.com/acme/app/pull/5'; mergeCommit = $null; files = @(@{ path = 'x.txt' })
            }
            foreach ($k in $Over.Keys) { $o[$k] = $Over[$k] }
            $o | ConvertTo-Json -Compress
        }
        function script:Invoke-PrGateCmd {
            param([string]$Cwd, [string[]]$Arguments, [object[]]$Rules, [hashtable]$Default)
            Remove-Item -LiteralPath $script:Journal -ErrorAction SilentlyContinue
            $null = Write-KitFakeGhScenario -Path $script:Scenario -Rules $Rules -Default $(if ($Default) { $Default } else { @{} })
            $err = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            $saved = @{}
            $vars = @{ PATH = "$script:Bin$([System.IO.Path]::PathSeparator)$env:PATH"; FAKE_GH_LOG = $script:Journal; FAKE_GH_SCENARIO = $script:Scenario; XDG_CONFIG_HOME = $script:EmptyConfig } + $script:Git
            foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
            Push-Location $Cwd
            try { $out = & pwsh -NoProfile -File (Join-Path $script:KitRoot 'tools/kit.ps1') pr-gate @Arguments 2>$err; $code = $LASTEXITCODE }
            finally { Pop-Location; foreach ($k in $saved.Keys) { Restore-PgEnv $k $saved[$k] } }
            [pscustomobject]@{
                Code = $code; Out = ($out -join "`n"); Err = (Get-Content -LiteralPath $err -Raw -Encoding UTF8)
                Calls = @(Get-KitFakeGhCalls -Log $script:Journal)
            }
        }
    }

    AfterAll {
        foreach ($k in $script:SavedGit.Keys) { Restore-PgEnv $k $script:SavedGit[$k] }
    }

    It 'open на base і на main — відмова, push не відбувся (origin без нової гілки); контроль: гілка задачі пушиться' {
        $r = New-PgRepo -Name 'open' -Profile @{ pr = @{ base = 'develop' } }
        $rules = @(
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('pr', 'create'); stdout = 'https://github.com/acme/app/pull/5' }
        )
        $before = Get-PgOriginBranches $r.Origin

        # На main (а base — develop): main не пушиться ніколи.
        $onMain = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open') -Rules $rules
        $onMain.Code | Should -Be 2
        $onMain.Err | Should -Match 'не пушить захищену гілку'
        # На base.
        git -C $r.Dir switch -q -c develop
        $onBase = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open') -Rules $rules
        $onBase.Code | Should -Be 2
        $onBase.Err | Should -Match 'не пушить захищену гілку'
        Get-PgOriginBranches $r.Origin | Should -Be $before -Because 'відмова мала спрацювати до git push'

        # Контроль: гілка задачі — push і PR створено проти base з профілю.
        git -C $r.Dir switch -q -c feat
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open', '-Title', 'T') -Rules $rules
        $ok.Code | Should -Be 0 -Because $ok.Err
        Get-PgOriginBranches $r.Origin | Should -Contain 'feat'
        $ok.Calls | Should -Contain 'pr create --base develop --head feat --title T --fill'
    }

    It 'land: на конфлікті (mergeable=CONFLICTING) — відмова, у журналі gh немає pr merge' {
        $r = New-PgRepo -Name 'conflict' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        $rules = @(
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson @{ mergeable = 'CONFLICTING'; mergeStateStatus = 'DIRTY' }) }
            @{ prefix = @('pr', 'merge') }
        )
        $c = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        @($c.Calls | Where-Object { $_ -like 'pr view 5 --json*' }) | Should -Not -BeNullOrEmpty -Because 'гейт мав дійти до gh'
        @($c.Calls | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty
        $c.Code | Should -Be 1
        $c.Err | Should -Match 'конфлікті з main'
        ($c.Out + $c.Err) | Should -Match 'merge origin/main'
    }

    It 'land: голова змінилась після перевірки — GitHub відмовляє, код 1, гілку не видалено' {
        $r = New-PgRepo -Name 'headmoved' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        # PR після злиття стає MERGED (тож злиття без прив'язки до голови пройшло б до кінця й видалило гілку);
        # а `pr merge` із закріпленою старою головою GitHub відхиляє, бо голова вже інша.
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge'); has = @('--match-head-commit', $script:OldSha); exit = 1; stderr = 'Head branch was modified. Review and try the merge again.' }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api') }
        )
        $c = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $c.Code | Should -Be 1
        $c.Calls | Should -Contain "pr merge 5 --squash --match-head-commit $script:OldSha" -Because 'злиття має бути прив''язане до перевіреної голови'
        @($c.Calls | Where-Object { $_ -like 'api -X DELETE*' }) | Should -BeNullOrEmpty
    }

    It 'gh pr merge повернув 0, але PR досі OPEN — гілку не видалено, код 1; контроль: MERGED — видалення гілки є в журналі' {
        $r = New-PgRepo -Name 'notmerged' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        $rules = @(
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api') }
        )
        $bad = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $bad.Code | Should -Be 1
        $bad.Err | Should -Match 'гілку лишено'
        @($bad.Calls | Where-Object { $_ -like 'pr merge*' }).Count | Should -Be 1 -Because 'до перевірки стану злиття дійшло'
        @($bad.Calls | Where-Object { $_ -like 'api -X DELETE*' }) | Should -BeNullOrEmpty

        $okRules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }   # верхівка на origin = голова PR
            @{ prefix = @('api') }
        )
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $okRules
        $ok.Code | Should -Be 0 -Because $ok.Err
        $ok.Out | Should -Match 'ЗЛИТО #5 як ccccccc'
        $ok.Calls | Should -Contain 'api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat'
    }

    It 'remote-гілка з комітами після голови PR не видаляється: верхівка на origin != headRefOid — немає DELETE, є рядок пояснення' {
        $r = New-PgRepo -Name 'tipmoved' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        $moved = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = ('b' * 40) }
            @{ prefix = @('api') }
        )
        $extra = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $moved
        $extra.Code | Should -Be 0 -Because $extra.Err
        $extra.Calls | Should -Contain 'api repos/{owner}/{repo}/git/ref/heads/feat --jq .object.sha' -Because 'верхівку на origin читано перед видаленням'
        @($extra.Calls | Where-Object { $_ -like 'api -X DELETE*' }) | Should -BeNullOrEmpty
        $extra.Out | Should -Match 'віддалену гілку feat лишено'
        $extra.Out | Should -Match 'gh api -X DELETE repos/\{owner\}/\{repo\}/git/refs/heads/feat'
    }

    It 'land: prune не видаляє дзеркала storage/* (локальне й з origin), хоч вони вміщені в main; контроль: звичайна злита гілка видаляється' {
        $r = New-PgRepo -Name 'mirrors' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        git -C $r.Dir branch 'storage/МХ_Адаптация'
        git -C $r.Dir branch 'storage/base'
        git -C $r.Dir push -q origin 'storage/base'
        git -C $r.Dir branch 'old-merged'
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }
            @{ prefix = @('api') }
        )
        $res = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $res.Code | Should -Be 0 -Because $res.Err
        $left = @(git -C $r.Dir for-each-ref --format='%(refname:short)' refs/heads)
        $left | Should -Contain 'storage/МХ_Адаптация'
        $left | Should -Contain 'storage/base'
        $left | Should -Not -Contain 'old-merged' -Because 'контроль: prune дійшов до видалення злитої гілки'
        $res.Out | Should -Match 'видалено old-merged'
        $res.Out | Should -Not -Match 'storage/'
    }

    It 'open на гілці storage/* і з -Base storage/* — відмова, push не відбувся; контроль: гілка задачі пушиться' {
        $r = New-PgRepo -Name 'openmirror' -Profile @{ workspace = @{ mode = 'shared' } }
        $rules = @(@{ prefix = @('pr', 'list'); stdout = '[]' }, @{ prefix = @('pr', 'create'); stdout = 'https://github.com/acme/app/pull/7' })
        git -C $r.Dir switch -q -c 'storage/base'
        $m = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open') -Rules $rules
        $m.Code | Should -Not -Be 0
        $m.Err | Should -Match 'storage/\*'
        git -C $r.Dir switch -q -c 'task-1'
        $b = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open', '-Base', 'storage/base') -Rules $rules
        $b.Code | Should -Not -Be 0
        $b.Err | Should -Match 'дзеркало сховища'
        Get-PgOriginBranches $r.Origin | Should -Not -Contain 'storage/base'
        Get-PgOriginBranches $r.Origin | Should -Not -Contain 'task-1'
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open') -Rules $rules
        $ok.Code | Should -Be 0 -Because $ok.Err
        Get-PgOriginBranches $r.Origin | Should -Contain 'task-1'
    }

    It 'land: PR з форка, у storage/* чи зі storage/* — відмова без ready і merge; контроль: звичайний PR зливається' {
        $r = New-PgRepo -Name 'landguard' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        foreach ($over in @(@{ isCrossRepository = $true; isDraft = $true }, @{ baseRefName = 'storage/base' }, @{ headRefName = 'storage/base' })) {
            $res = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules @(@{ prefix = @('pr', 'view'); stdout = (New-PrJson $over) }, @{ prefix = @('pr') }, @{ prefix = @('api') })
            $res.Code | Should -Be 1 -Because ($over | ConvertTo-Json -Compress)
            $res.Err | Should -Match 'НЕ ЗЛИТО #5'
            @($res.Calls | Where-Object { $_ -like 'pr merge*' -or $_ -like 'pr ready*' }) | Should -BeNullOrEmpty
        }
        $okRules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }
            @{ prefix = @('api') }
        )
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $okRules
        $ok.Code | Should -Be 0 -Because $ok.Err
        @($ok.Calls | Where-Object { $_ -like 'pr merge*' }).Count | Should -Be 1
    }

    It 'land: pr.afterMerge з профілю робочого дерева не виконується; контроль: той самий з профілю на origin/main — виконується' {
        $am = @(@{ paths = @('**'); run = @('git', 'tag', 'am-ran') })
        $r = New-PgRepo -Name 'aftermerge' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash'; afterMerge = $am } }
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }
            @{ prefix = @('api') }
        )
        $bad = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $bad.Code | Should -Be 0 -Because $bad.Err
        @(git -C $r.Dir tag --list 'am-ran') | Should -BeNullOrEmpty
        $bad.Out | Should -Match 'pr\.afterMerge береться лише з .agents/kit\.profile\.json на origin/main'

        # Підміна локальних refs/remotes: профіль з afterMerge — на гілці задачі на origin, а локальні
        # origin/HEAD і origin/main переписано на неї. Головну гілку називає сам origin — argv не виконується.
        $other = Join-Path $TestDrive 'aftermerge-other'
        git clone -q $r.Origin $other
        New-Item -ItemType Directory -Path (Join-Path $other '.agents') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $r.Dir '.agents/kit.profile.json') -Destination (Join-Path $other '.agents/kit.profile.json')
        git -C $other add -f .agents/kit.profile.json
        git -C $other commit -q -m 'profile on task'
        git -C $other push -q origin HEAD:task-evil
        git -C $r.Dir fetch -q origin
        git -C $r.Dir update-ref refs/remotes/origin/main refs/remotes/origin/task-evil
        git -C $r.Dir remote set-head origin task-evil
        Remove-Item -LiteralPath (Join-Path $r.Dir '.agents/out') -Recurse -Force -ErrorAction SilentlyContinue
        $spoof = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $spoof.Code | Should -Be 0 -Because $spoof.Err
        @(git -C $r.Dir tag --list 'am-ran') | Should -BeNullOrEmpty
        git -C $r.Dir remote set-head origin main
        git -C $r.Dir fetch -q origin '+refs/heads/main:refs/remotes/origin/main'

        # Контроль: профіль закомічено й запушено в main — той самий argv виконується.
        git -C $r.Dir add -f .agents/kit.profile.json
        git -C $r.Dir commit -q -m profile
        git -C $r.Dir push -q origin main
        Remove-Item -LiteralPath (Join-Path $r.Dir '.agents/out') -Recurse -Force -ErrorAction SilentlyContinue   # позначка after-merge
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $ok.Code | Should -Be 0 -Because $ok.Err
        @(git -C $r.Dir tag --list 'am-ran') | Should -Be @('am-ran')
    }

    It 'land: v8storagekit.pr на головній гілці заміняє pr цілком — виконується afterMerge простору імен, не верхній (ADR-0020)' {
        $prof = [ordered]@{
            workspace = @{ mode = 'shared' }
            pr = [ordered]@{ mergeMethod = 'squash'; afterMerge = @(@{ paths = @('**'); run = @('git', 'tag', 'top-ran') }) }
            v8storagekit = [ordered]@{ pr = [ordered]@{ mergeMethod = 'squash'; afterMerge = @(@{ paths = @('**'); run = @('git', 'tag', 'ns-ran') }) } }
        }
        $r = New-PgRepo -Name 'amns' -Profile $prof
        git -C $r.Dir add -f .agents/kit.profile.json
        git -C $r.Dir commit -q -m profile
        git -C $r.Dir push -q origin main
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }
            @{ prefix = @('api') }
        )
        $res = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $res.Code | Should -Be 0 -Because $res.Err
        @(git -C $r.Dir tag --list 'ns-ran') | Should -Be @('ns-ran')
        @(git -C $r.Dir tag --list 'top-ran') | Should -BeNullOrEmpty -Because 'верхній pr.afterMerge іншої зони не виконується'
    }

    It 'land у shared, головний checkout на гілці PR: next — switch на base, ff і branch -d; не «тримає worktree»' {
        $r = New-PgRepo -Name 'sharedhead' -Profile @{ workspace = @{ mode = 'shared' }; pr = @{ mergeMethod = 'squash' } }
        git -C $r.Dir switch -q -c feat
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('pr', 'list'); stdout = '[]' }
            @{ prefix = @('api', 'repos/{owner}/{repo}/git/ref/heads/feat'); stdout = $script:OldSha }
            @{ prefix = @('api') }
        )
        $res = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('land', '5') -Rules $rules
        $res.Code | Should -Be 0 -Because $res.Err
        $res.Out | Should -Match 'next: .*switch main && git -C .* merge --ff-only origin/main && git -C .* branch -d feat'
        $res.Out | Should -Match 'на ній головний checkout'
        $res.Out | Should -Not -Match 'тримає worktree'
        (git -C $r.Dir branch --show-current) | Should -Be 'feat' -Because 'у shared HEAD спільного дерева не зсуваємо'
    }

    It 'start у workspace.mode = shared — код 1, жодної нової гілки чи worktree; контроль: у worktree-режимі start працює' {
        $r = New-PgRepo -Name 'shared' -Profile @{ workspace = @{ mode = 'shared' } }
        $rules = @(@{ prefix = @('issue', 'view'); stdout = '{"number":12,"title":"Fix thing","state":"OPEN"}' })
        $s = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('start', '12') -Rules $rules
        $s.Code | Should -Be 1
        $s.Err | Should -Match 'workspace\.mode = shared'
        @(git -C $r.Dir branch --list 'issue-*') | Should -BeNullOrEmpty
        @(git -C $r.Dir worktree list).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $r.Dir '.worktrees') | Should -BeFalse
        $s.Calls | Should -BeNullOrEmpty -Because 'відмова має бути до будь-якого звернення до GitHub'

        # Контроль: той самий репо в режимі worktree — гілка й worktree є.
        Set-PgProfile -Dir $r.Dir -Profile @{ workspace = @{ mode = 'worktree' } }
        $w = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('start', '12') -Rules $rules
        $w.Code | Should -Be 0 -Because $w.Err
        @(git -C $r.Dir branch --list 'issue-12-fix-thing').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $r.Dir '.worktrees/12-fix-thing') | Should -BeTrue
    }
}
