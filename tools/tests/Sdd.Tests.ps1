#Requires -Version 7
# sdd (оригінал — agent-kit 0.9.1 tests/sdd.test.mjs): лише запобіжники механіки виконання плану.
# Запуск — підпроцесом через обгортку bin/sdd з копії kit на синтетичному git-репо з планом.
Describe 'sdd — запобіжники журналу, вікон і раундів' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitRoot = Split-Path (Split-Path $script:Kit -Parent) -Parent

        $script:Plan = @'
# Demo plan

## Global Constraints
- Один шлях.

## Tasks

### Task 1: base
Do it.

### Task 1c: collation
Second.
'@

        function script:Invoke-G {
            param([string]$Dir, [string[]]$GitArgs)
            $o = & git -C $Dir -c user.name=kit-test -c user.email=kit-test@example.invalid -c core.autocrlf=false @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' '): $o" }
            "$($o | Select-Object -First 1)".Trim()
        }
        function script:Add-Commit {
            param([string]$Dir, [string]$Name)
            [System.IO.File]::WriteAllText((Join-Path $Dir $Name), $Name, [System.Text.UTF8Encoding]::new($false))
            Invoke-G $Dir @('add', '--', $Name) | Out-Null
            Invoke-G $Dir @('commit', '-q', '-m', $Name) | Out-Null
            Invoke-G $Dir @('rev-parse', 'HEAD')
        }
        function script:New-SddRepo {
            param([string]$Name)
            $dir = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $dir 'docs/plans') -Force | Out-Null
            Invoke-G $dir @('init', '-q', '-b', 'main') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'docs/plans/sub.md'), $script:Plan, [System.Text.UTF8Encoding]::new($false))
            Invoke-G $dir @('add', '-A') | Out-Null
            Invoke-G $dir @('commit', '-q', '-m', 'init') | Out-Null
            [pscustomobject]@{ Dir = $dir; Ws = Join-Path $dir '.agents/sdd/sub'; Head = (Invoke-G $dir @('rev-parse', 'HEAD')) }
        }
        function script:Invoke-Sdd {
            param([string]$Dir, [string[]]$Arguments)
            $errFile = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            Push-Location $Dir
            try { $out = & bash (Join-Path $script:KitRoot 'bin/sdd') @Arguments 2>$errFile; $code = $LASTEXITCODE }
            finally { Pop-Location }
            [pscustomobject]@{
                ExitCode = $code
                Out      = @($out | ForEach-Object { [string]$_ })
                Err      = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        }
        function script:Read-Ledger { param($Repo) [System.IO.File]::ReadAllText((Join-Path $Repo.Ws 'progress.md')) }
        function script:Add-Report {
            param($Repo, [string]$N, [string]$Text)
            [System.IO.File]::AppendAllText((Join-Path $Repo.Ws "task-$N-report.md"), $Text, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'третій раунд fix без -ApprovedBy — відмова; з ним рівно один раунд, наступний знову відмова' {
        $repo = New-SddRepo 'repo-fixlimit'
        Invoke-Sdd $repo.Dir @('init', 'docs/plans/sub.md') | Out-Null
        Invoke-Sdd $repo.Dir @('dispatch', '1') | Out-Null
        # Раунди з -Source controller: без пакета рецензії й комітів між ними — лічильник той самий.
        foreach ($round in 1..2) {
            (Invoke-Sdd $repo.Dir @('fix', '1', '-Source', 'controller', '-Note', "знахідка $round")).ExitCode | Should -Be 0
        }
        $refused = Invoke-Sdd $repo.Dir @('fix', '1', '-Source', 'controller', '-Note', 'знахідка 3')
        $refused.ExitCode | Should -Be 1
        $refused.Err[0] | Should -BeLike 'sdd: ERROR *-ApprovedBy*'
        (Read-Ledger $repo) | Should -Not -Match 'round 3'

        $extra = Invoke-Sdd $repo.Dir @('fix', '1', '-Source', 'controller', '-ApprovedBy', 'architect m4', '-Note', 'one more')
        $extra.ExitCode | Should -Be 0
        (Read-Ledger $repo) | Should -Match '(?m)^Task 1: fix \(round 3; type patch; source controller; approved architect m4\) — one more$'

        $again = Invoke-Sdd $repo.Dir @('fix', '1', '-Source', 'controller', '-Note', 'знахідка 4')
        $again.ExitCode | Should -Be 1
        (Read-Ledger $repo) | Should -Not -Match 'round 4'
    }

    It 'watch не бере Status, дописаний ДО відкриття вікна (зсув у байтах), і бере свіжий' {
        $repo = New-SddRepo 'repo-watch'
        Invoke-Sdd $repo.Dir @('init', 'docs/plans/sub.md') | Out-Null
        # Кирилиця в старому звіті: зсув у символах був би меншим за зсув у байтах і пустив би хвіст старого рядка.
        New-Item -ItemType Directory -Path $repo.Ws -Force | Out-Null
        Add-Report $repo '1' "# Звіт задачі`nStatus: СТАРИЙ`n"
        $reportPath = Join-Path $repo.Ws 'task-1-report.md'
        $bytes = [System.IO.File]::ReadAllBytes($reportPath).Length
        $chars = [System.IO.File]::ReadAllText($reportPath).Length
        $bytes | Should -BeGreaterThan $chars -Because 'без кирилиці байти й символи не розрізнити'
        Invoke-Sdd $repo.Dir @('dispatch', '1') | Out-Null
        # Довжина звіту на відкритті вікна — у БАЙТАХ: це зсув, від якого watch шукає свіжий Status.
        (Read-Ledger $repo) | Should -Match "(?m)^Window \(task 1\): open [0-9a-f]{40} at \S+; report $bytes — dispatch$"
        $stale = Invoke-Sdd $repo.Dir @('watch', '1', '-Timeout', '0.5', '-Interval', '0.1')
        $stale.ExitCode | Should -Be 3
        $stale.Err[0] | Should -BeLike 'sdd: ERROR watch:*'
        ($stale.Out -join "`n") | Should -Not -Match 'Status: СТАРИЙ  \('

        Add-Report $repo '1' "Status: СВІЖИЙ`n"
        $ok = Invoke-Sdd $repo.Dir @('watch', '1', '-Timeout', '5', '-Interval', '0.1')
        $ok.ExitCode | Should -Be 0
        $ok.Out[0] | Should -BeLike 'Status: СВІЖИЙ  (*'
    }

    It 'коміт іншої задачі між вікнами не входить у пакет review і в діапазон done; коміт контролера після watch — входить' {
        $repo = New-SddRepo 'repo-windows'
        Invoke-Sdd $repo.Dir @('init', 'docs/plans/sub.md') | Out-Null
        Invoke-Sdd $repo.Dir @('dispatch', '1') | Out-Null
        $a = Add-Commit $repo.Dir 'a.txt'
        Add-Report $repo '1' "Status: DONE`n"
        (Invoke-Sdd $repo.Dir @('watch', '1', '-Timeout', '5', '-Interval', '0.1')).ExitCode | Should -Be 0
        (Read-Ledger $repo) | Should -Not -Match 'Window \(task 1\): close' -Because 'watch вікна не закриває'
        # Контролер комітить задачу між watch і review: цей коміт належить вікну задачі.
        $k = Add-Commit $repo.Dir 'k.txt'
        # Задача 1c між вікнами задачі 1, потім коміт контролера.
        Invoke-Sdd $repo.Dir @('dispatch', '1c') | Out-Null
        $b = Add-Commit $repo.Dir 'b.txt'
        (Invoke-Sdd $repo.Dir @('done', '1c')).ExitCode | Should -Be 0
        Add-Commit $repo.Dir 'c.txt' | Out-Null

        $review = Invoke-Sdd $repo.Dir @('review', '1')
        $review.ExitCode | Should -Be 0
        (Read-Ledger $repo) | Should -Match "(?m)^Task 1: review \(commits $($repo.Head)\.\.$k\)$"
        $pack = [System.IO.File]::ReadAllText((Join-Path $repo.Ws 'task-1-review.md'))
        $pack | Should -Match 'a\.txt'
        $pack | Should -Match 'k\.txt'
        $pack | Should -Not -Match 'b\.txt|c\.txt'

        (Invoke-Sdd $repo.Dir @('done', '1')).ExitCode | Should -Be 0
        $ledger = Read-Ledger $repo
        $ledger | Should -Match "(?m)^Task 1: complete \(commits $($repo.Head)\.\.$k; review clean\)$"
        $ledger | Should -Match "(?m)^Task 1c: complete \(commits $k\.\.$b; review controller\)$"
    }

    It 'журнал іншого плану в робочій теці — відмова, файл не перезаписано (init, status, dispatch)' {
        $repo = New-SddRepo 'repo-foreign'
        Invoke-Sdd $repo.Dir @('init', 'docs/plans/sub.md') | Out-Null
        $foreign = "# SDD ledger — plan: docs/other.md`n"
        [System.IO.File]::WriteAllText((Join-Path $repo.Ws 'progress.md'), $foreign, [System.Text.UTF8Encoding]::new($false))
        foreach ($args2 in @(@('init', 'docs/plans/sub.md'), @('status', 'docs/plans/sub.md'), @('dispatch', 'docs/plans/sub.md', '1'))) {
            $r = Invoke-Sdd $repo.Dir $args2
            $r.ExitCode | Should -Be 1 -Because ($args2 -join ' ')
            $r.Err[0] | Should -BeLike 'sdd: ERROR *належить іншому плану*'
            (Read-Ledger $repo) | Should -BeExactly $foreign
        }
    }

    It 'dispatch задачі complete — відмова; повторний dispatch не зсуває BASE' {
        $repo = New-SddRepo 'repo-redispatch'
        Invoke-Sdd $repo.Dir @('init', 'docs/plans/sub.md') | Out-Null
        Invoke-Sdd $repo.Dir @('dispatch', '1', '-Model', 'opus') | Out-Null
        Add-Commit $repo.Dir 'a.txt' | Out-Null
        (Invoke-Sdd $repo.Dir @('dispatch', '1', '-Note', 'після паузи')).ExitCode | Should -Be 0
        $ledger = Read-Ledger $repo
        ([regex]::Matches($ledger, '\bbase ')).Count | Should -Be 1 -Because 'BASE записано лише першим dispatch'
        $ledger | Should -Match "(?m)^Task 1: dispatched \(base $($repo.Head); model opus\)$"
        $ledger | Should -Match '(?m)^Task 1: dispatched — після паузи$'

        $b = Add-Commit $repo.Dir 'b.txt'
        (Invoke-Sdd $repo.Dir @('done', '1')).ExitCode | Should -Be 0
        (Read-Ledger $repo) | Should -Match "(?m)^Task 1: complete \(commits $($repo.Head)\.\.$b; review controller\)$"

        $refused = Invoke-Sdd $repo.Dir @('dispatch', '1')
        $refused.ExitCode | Should -Be 1
        $refused.Err[0] | Should -BeLike 'sdd: ERROR *вже complete*'
    }
}
