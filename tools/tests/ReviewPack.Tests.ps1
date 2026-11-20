#Requires -Version 7
# review-pack (оригінал — agent-kit 0.9.1 tests/review-pack.test.mjs): лише запобіжники пакета.
# Запуск — підпроцесом через обгортку bin/review-pack з копії kit на синтетичному git-репо.
Describe 'review-pack — запобіжники діапазону й вливання основної гілки' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitRoot = Split-Path (Split-Path $script:Kit -Parent) -Parent

        function script:Invoke-G {
            param([string]$Dir, [string[]]$GitArgs)
            $o = & git -C $Dir -c user.name=kit-test -c user.email=kit-test@example.invalid -c core.autocrlf=false @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' '): $o" }
            "$($o | Select-Object -First 1)".Trim()
        }
        function script:Add-Commit {
            param([string]$Dir, [hashtable]$Files, [string]$Message)
            foreach ($rel in $Files.Keys) {
                $p = Join-Path $Dir $rel
                New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
                [System.IO.File]::WriteAllText($p, $Files[$rel], [System.Text.UTF8Encoding]::new($false))
            }
            Invoke-G $Dir @('add', '-A') | Out-Null
            Invoke-G $Dir @('commit', '-q', '-m', $Message) | Out-Null
            Invoke-G $Dir @('rev-parse', 'HEAD')
        }
        # main: c0; гілка feat: «task 1» (це BASE) → main отримує чужий коміт → [feat вливає main] → «task 2».
        function script:New-Repo {
            param([string]$Name, [switch]$MergeMain)
            $dir = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Invoke-G $dir @('init', '-q', '-b', 'main') | Out-Null
            $c0 = Add-Commit $dir @{ 'readme.txt' = "c0`n" } 'c0'
            Invoke-G $dir @('checkout', '-q', '-b', 'feat') | Out-Null
            $base = Add-Commit $dir @{ 'src/f.txt' = "f1`n" } 'task 1'
            Invoke-G $dir @('checkout', '-q', 'main') | Out-Null
            Add-Commit $dir @{ 'other.txt' = "someone else`n" } 'other: foreign work' | Out-Null
            Invoke-G $dir @('update-ref', 'refs/remotes/origin/main', 'main') | Out-Null
            Invoke-G $dir @('checkout', '-q', 'feat') | Out-Null
            if ($MergeMain) { Invoke-G $dir @('merge', '-q', '--no-edit', 'origin/main') | Out-Null }
            # CRLF у тілі діфу — норма для 1С: \r мусить дійти до пакета.
            Add-Commit $dir @{ 'src/f.txt' = "f1`nf2`n"; 'src/crlf.txt' = "a`r`nb`r`n" } 'task 2' | Out-Null
            [pscustomobject]@{ Dir = $dir; Base = $base; C0 = $c0 }
        }
        function script:Invoke-Pack {
            param([string]$Dir, [string[]]$Arguments)
            $errFile = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            Push-Location $Dir
            try { $out = & bash (Join-Path $script:KitRoot 'bin/review-pack') @Arguments 2>$errFile; $code = $LASTEXITCODE }
            finally { Pop-Location }
            [pscustomobject]@{
                ExitCode = $code
                Out      = @($out | ForEach-Object { [string]$_ })
                Err      = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        }
    }

    It 'base не предок голови і порожній діапазон — код 3 «не перевірено», файл пакета не створюється (<Case>)' -ForEach @(
        @{ Case = 'не предок'; Kind = 'side' }
        @{ Case = 'порожній'; Kind = 'empty' }
    ) {
        $repo = New-Repo "repo-guard-$Kind"
        Invoke-G $repo.Dir @('checkout', '-q', '-b', 'side', $repo.C0) | Out-Null
        Add-Commit $repo.Dir @{ 'side.txt' = "s`n" } 'side' | Out-Null
        Invoke-G $repo.Dir @('checkout', '-q', 'feat') | Out-Null
        $explicit = Join-Path $TestDrive "explicit-$Kind.md"
        $args2 = if ($Kind -eq 'side') { @('side', 'feat') } else { @('feat', 'feat') }
        $r = Invoke-Pack $repo.Dir ($args2 + @('-Out', $explicit))
        $r.ExitCode | Should -Be 3
        $r.Err[0] | Should -BeLike 'review-pack: ERROR *'
        $r.Err[0] | Should -BeLike $(if ($Kind -eq 'side') { '*не предок*' } else { '*порожній діапазон*' })
        Test-Path -LiteralPath $explicit | Should -BeFalse
        @(Get-ChildItem -Path (Join-Path $repo.Dir '.agents/out') -Filter 'review-*.md' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'гілка влила origin/main після base: коміти й зміни main не потрапляють у пакет, заголовок про це каже' {
        $repo = New-Repo 'repo-merged' -MergeMain
        $out = Join-Path $TestDrive 'merged.md'
        $r = Invoke-Pack $repo.Dir @($repo.Base, '-Out', $out)
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        ($r.Out -join "`n") | Should -BeLike '*origin/main влито: його змін немає в пакеті*'
        $text = Get-Content -LiteralPath $out -Raw -Encoding UTF8
        $text | Should -Not -Match 'other: foreign work'
        $text | Should -Not -Match 'other\.txt'
        $text | Should -Match 'task 2'
        $text | Should -Match 'Гілка влила origin/main: 1 його комітів виключено'
        $text | Should -Match '(?m)^\+f2\r?$'
        $text | Should -Not -Match '(?m)^\+f1\r?$' -Because 'task 1 — до base'
    }

    It 'контроль: той самий репо без вливання — пакет містить усі коміти гілки, CRLF у діфі збережено' {
        $repo = New-Repo 'repo-plain'
        $out = Join-Path $TestDrive 'plain.md'
        $r = Invoke-Pack $repo.Dir @($repo.C0, '-Out', $out)
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        ($r.Out -join "`n") | Should -Not -BeLike '*влито*'
        $text = Get-Content -LiteralPath $out -Raw -Encoding UTF8
        $text | Should -Match 'task 1'
        $text | Should -Match 'task 2'
        $text | Should -Not -Match 'Гілка влила'
        $text | Should -Match '\+a\r\n\+b\r\n'
        $r.Out[-1] | Should -BeLike 'next: *'
    }
}
