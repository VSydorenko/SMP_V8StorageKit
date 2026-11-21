#Requires -Version 7
# session-board: злитий PR зараховується гілці лише тоді, коли в ній немає нової роботи після нього
# (оригінал — agent-kit 0.9.1 tests/session-board.test.mjs). Справжній bin/kit.exe підпроцесом
# на синтетичному репо (команда перенесена на Rust, спека #51 D8), gh — фальшивий gh.cmd першим у PATH підпроцесу.
Describe 'session-board — злитий PR і нова робота в гілці' {
    BeforeAll {
        $script:KitExe = (Resolve-Path "$PSScriptRoot/../../bin/kit.exe").Path
        function script:G { param([string]$Repo, [string[]]$A) $o = & git -C $Repo @A 2>&1; if ($LASTEXITCODE) { throw "git $A : $o" }; ([string]($o -join "`n")).Trim() }
        function script:Commit { param([string]$Repo, [string]$File) Set-Content -LiteralPath (Join-Path $Repo $File) -Value $File; G $Repo @('add', '-A'); G $Repo @('commit', '-q', '-m', $File) }
    }

    It 'shared: A (HEAD = headRefOid) — «#N merged», B (новий коміт після злитого PR) — ні; код 0' {
        $origin = Join-Path $TestDrive 'origin.git'
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $repo | Out-Null
        G $TestDrive @('init', '-q', '--bare', '-b', 'main', $origin)
        G $repo @('init', '-q', '-b', 'main')
        G $repo @('config', 'user.name', 't'); G $repo @('config', 'user.email', 't@t'); G $repo @('config', 'commit.gpgsign', 'false')
        G $repo @('remote', 'add', 'origin', $origin)
        Commit $repo 'init.txt'
        G $repo @('push', '-q', '-u', 'origin', 'main')
        G $repo @('checkout', '-q', '-b', 'feat-a'); Commit $repo 'a.txt'
        $headA = G $repo @('rev-parse', 'HEAD')
        G $repo @('checkout', '-q', 'main'); G $repo @('checkout', '-q', '-b', 'feat-b'); Commit $repo 'b1.txt'
        $oldB = G $repo @('rev-parse', 'HEAD')
        Commit $repo 'b2.txt'
        G $repo @('checkout', '-q', 'main')

        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Value '{ "workspace": { "mode": "shared" } }'
        $file = Join-Path $TestDrive 'sessions.json'
        Set-Content -LiteralPath $file -Value '{ "sa": { "branch": "feat-a", "role": "executor" }, "sb": "feat-b" }'

        $ghDir = Join-Path $TestDrive 'fakegh'
        New-Item -ItemType Directory -Path $ghDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ghDir 'open.json') -Value '[]'
        Set-Content -LiteralPath (Join-Path $ghDir 'merged.json') -Value (ConvertTo-Json -Compress @(
                @{ number = 11; headRefName = 'feat-a'; headRefOid = $headA },
                @{ number = 12; headRefName = 'feat-b'; headRefOid = $oldB }))
        Set-Content -LiteralPath (Join-Path $ghDir 'gh.cmd') -Encoding ascii -Value @('@echo off', 'if "%4"=="open" (type "%~dp0open.json") else (type "%~dp0merged.json")')

        $savedPath = $env:PATH
        $env:PATH = "$ghDir$([IO.Path]::PathSeparator)$savedPath"
        Push-Location $repo
        try { $out = & $script:KitExe session-board -Sessions $file 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { Pop-Location; $env:PATH = $savedPath }

        $code | Should -Be 0 -Because $out
        $rowA = @($out -split "\r?\n" | Where-Object { $_ -match '\bfeat-a\b' })
        $rowB = @($out -split "\r?\n" | Where-Object { $_ -match '\bfeat-b\b' })
        $rowA.Count | Should -Be 1 -Because $out
        $rowB.Count | Should -Be 1 -Because $out
        $rowA[0] | Should -Match '#11 merged'
        $rowB[0] | Should -Not -Match 'merged'
    }

    It 'shared: одна гілка поза base — таблиця з одним рядком, код 0 (масив з одного елемента не розгортається)' {
        $repo = Join-Path $TestDrive 'repo-one'
        New-Item -ItemType Directory -Path $repo | Out-Null
        G $repo @('init', '-q', '-b', 'main')
        G $repo @('config', 'user.name', 't'); G $repo @('config', 'user.email', 't@t'); G $repo @('config', 'commit.gpgsign', 'false')
        Commit $repo 'init.txt'
        G $repo @('checkout', '-q', '-b', 'feat-solo'); Commit $repo 'solo.txt'
        G $repo @('checkout', '-q', 'main')
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Value '{ "workspace": { "mode": "shared" } }'

        $ghDir = Join-Path $TestDrive 'fakegh-one'
        New-Item -ItemType Directory -Path $ghDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ghDir 'gh.cmd') -Encoding ascii -Value @('@echo off', 'echo []')

        $savedPath = $env:PATH
        $env:PATH = "$ghDir$([IO.Path]::PathSeparator)$savedPath"
        Push-Location $repo
        try { $out = & $script:KitExe session-board 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { Pop-Location; $env:PATH = $savedPath }

        $code | Should -Be 0 -Because $out
        $out | Should -Not -Match 'outside the bounds'
        @($out -split "\r?\n" | Where-Object { $_ -match '\bfeat-solo\b' }).Count | Should -Be 1 -Because $out
    }

    It 'worktree -All: detached worktree — рядок (detached), код 0 (PowerShell-версія падала на пустому ключі)' {
        $repo = Join-Path $TestDrive 'repo-det'
        New-Item -ItemType Directory -Path $repo | Out-Null
        G $repo @('init', '-q', '-b', 'main')
        G $repo @('config', 'user.name', 't'); G $repo @('config', 'user.email', 't@t'); G $repo @('config', 'commit.gpgsign', 'false')
        Commit $repo 'init.txt'
        $scratch = Join-Path $TestDrive 'scratch-copy'
        G $repo @('worktree', 'add', '-q', '--detach', $scratch, 'HEAD')
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Value '{ "workspace": { "mode": "worktree" } }'

        $ghDir = Join-Path $TestDrive 'fakegh-det'
        New-Item -ItemType Directory -Path $ghDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ghDir 'gh.cmd') -Encoding ascii -Value @('@echo off', 'echo []')

        $savedPath = $env:PATH
        $env:PATH = "$ghDir$([IO.Path]::PathSeparator)$savedPath"
        Push-Location $repo
        try {
            $plain = & $script:KitExe session-board 2>&1 | Out-String
            $all = & $script:KitExe session-board -All 2>&1 | Out-String; $code = $LASTEXITCODE
        } finally { Pop-Location; $env:PATH = $savedPath }

        $code | Should -Be 0 -Because $all
        $plain | Should -Not -Match '(detached)'
        @($all -split "?
" | Where-Object { $_ -match '(detached)' }).Count | Should -Be 1 -Because $all
    }
}
