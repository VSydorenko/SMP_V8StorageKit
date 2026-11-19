#Requires -Version 7
# pr-gate (перенесено з agent-kit 0.9.1): запобіжники, чия поломка мовчки дає хибний результат —
# push у base/main, злиття конфліктного PR, злиття не тієї голови, видалення гілки без підтвердженого
# MERGED, worktree у спільному дереві. Справжня команда `pr-gate` — підпроцесом
# (tools/kit-process.ps1) на синтетичному репо з bare-origin проти фальшивого gh.exe на початку PATH
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
                url = 'https://github.com/acme/app/pull/5'; mergeCommit = $null
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
            try { $out = & pwsh -NoProfile -File (Join-Path $script:KitRoot 'tools/kit-process.ps1') pr-gate @Arguments 2>$err; $code = $LASTEXITCODE }
            finally { Pop-Location; foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
            [pscustomobject]@{
                Code = $code; Out = ($out -join "`n"); Err = (Get-Content -LiteralPath $err -Raw -Encoding UTF8)
                Calls = @(Get-KitFakeGhCalls -Log $script:Journal)
            }
        }
    }

    AfterAll {
        foreach ($k in $script:SavedGit.Keys) { [Environment]::SetEnvironmentVariable($k, $script:SavedGit[$k]) }
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
        $onMain.Err | Should -Match 'не пушить main'
        # На base.
        git -C $r.Dir switch -q -c develop
        $onBase = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open') -Rules $rules
        $onBase.Code | Should -Be 2
        $onBase.Err | Should -Match 'не пушить базову гілку'
        Get-PgOriginBranches $r.Origin | Should -Be $before -Because 'відмова мала спрацювати до git push'

        # Контроль: гілка задачі — push і PR створено проти base з профілю.
        git -C $r.Dir switch -q -c feat
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('open', '-Title', 'T') -Rules $rules
        $ok.Code | Should -Be 0 -Because $ok.Err
        Get-PgOriginBranches $r.Origin | Should -Contain 'feat'
        $ok.Calls | Should -Contain 'pr create --base develop --head feat --title T --fill'
    }

    It 'merge на конфлікті (mergeable=CONFLICTING) — відмова, у журналі gh немає pr merge' {
        $r = New-PgRepo -Name 'conflict' -Profile @{ pr = @{ mergeMethod = 'squash' } }
        $rules = @(
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson @{ mergeable = 'CONFLICTING'; mergeStateStatus = 'DIRTY' }) }
            @{ prefix = @('pr', 'merge') }
        )
        $c = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('merge', '5') -Rules $rules
        @($c.Calls | Where-Object { $_ -like 'pr view 5 --json*' }) | Should -Not -BeNullOrEmpty -Because 'гейт мав дійти до gh'
        @($c.Calls | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty
        $c.Code | Should -Be 1
        $c.Err | Should -Match 'конфлікті з main'
        $c.Err | Should -Match 'merge origin/main'
    }

    It 'merge: голова змінилась після перевірки — GitHub відмовляє, код 1, гілку не видалено' {
        $r = New-PgRepo -Name 'headmoved' -Profile @{ pr = @{ mergeMethod = 'squash' } }
        # PR після злиття стає MERGED (тож злиття без прив'язки до голови пройшло б до кінця й видалило гілку);
        # а `pr merge` із закріпленою старою головою GitHub відхиляє, бо голова вже інша.
        $rules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge'); has = @('--match-head-commit', $script:OldSha); exit = 1; stderr = 'Head branch was modified. Review and try the merge again.' }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api') }
        )
        $c = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('merge', '5') -Rules $rules
        $c.Code | Should -Be 1
        $c.Calls | Should -Contain "pr merge 5 --squash --match-head-commit $script:OldSha" -Because 'злиття має бути прив''язане до перевіреної голови'
        @($c.Calls | Where-Object { $_ -like 'api -X DELETE*' }) | Should -BeNullOrEmpty
    }

    It 'gh pr merge повернув 0, але PR досі OPEN — гілку не видалено, код 1; контроль: MERGED — видалення гілки є в журналі' {
        $r = New-PgRepo -Name 'notmerged' -Profile @{ pr = @{ mergeMethod = 'squash' } }
        $rules = @(
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api') }
        )
        $bad = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('merge', '5') -Rules $rules
        $bad.Code | Should -Be 1
        $bad.Err | Should -Match 'гілку лишено'
        @($bad.Calls | Where-Object { $_ -like 'pr merge*' }).Count | Should -Be 1 -Because 'до перевірки стану злиття дійшло'
        @($bad.Calls | Where-Object { $_ -like 'api -X DELETE*' }) | Should -BeNullOrEmpty

        $okRules = @(
            @{ prefix = @('pr', 'view'); after = @('pr', 'merge'); stdout = (New-PrJson @{ state = 'MERGED'; mergeCommit = @{ oid = 'c' * 40 } }) }
            @{ prefix = @('pr', 'view'); stdout = (New-PrJson) }
            @{ prefix = @('pr', 'merge') }
            @{ prefix = @('api') }
        )
        $ok = Invoke-PrGateCmd -Cwd $r.Dir -Arguments @('merge', '5') -Rules $okRules
        $ok.Code | Should -Be 0 -Because $ok.Err
        $ok.Out | Should -Match 'ЗЛИТО #5 як ccccccc'
        $ok.Calls | Should -Contain 'api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat'
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
