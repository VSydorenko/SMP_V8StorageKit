#Requires -Version 7
Describe 'kit install-hooks — хуки захисту й хук старту сесії одним кроком' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-InstallHooks { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit install-hooks -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }
    It 'прев''ю перелічує, що буде покладено, і нічого не кладе' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview')
        $r = Invoke-InstallHooks -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*.githooks*session-start.ps1*-Apply*'
        Join-Path $repo '.githooks' | Should -Not -Exist
    }
    It '-Apply кладе все; після цього kit check мовчить про hooks і hook-shim' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'apply') -WithGitattributes -WithGitignore
        $r = Invoke-InstallHooks -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        Join-Path $repo '.claude/hooks/session-start.ps1' | Should -Exist
        Join-Path $repo '.claude/settings.json' | Should -Exist
        (git -C $repo config --get core.hooksPath) | Should -Be '.githooks'
        # F10: хуки застейджені з режимом 100755 — саме він дістанеться кожному клону (git ls-files -s питає індекс, не ФС).
        # -c core.quotepath=false — той самий інваріант, що в production-коді (Hooks.psm1, check.psm1): git ls-files друкує
        # шляхи, і kit форсує цю конфігурацію за виклик завжди, без винятку для свідомо ASCII-шляхів (правило CLAUDE.md).
        foreach ($h in 'pre-commit', 'pre-merge-commit') { (git -c core.quotepath=false -C $repo ls-files -s -- ".githooks/$h") | Should -Match '^100755 ' }
        $check = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo 2>&1 | Out-String
        $check | Should -Not -BeLike '*core.hooksPath*'
        $check | Should -Not -Match '100644'
        $check | Should -Not -Match '\[!\].*session-start\.ps1'
    }
    It 'наявний .claude/settings.json не перезаписується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'keep')
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ "permissions": { "allow": ["Bash(echo:*)"] } }' -Encoding UTF8
        Invoke-InstallHooks -Repo $repo -More @('-Apply') | Out-Null
        (Get-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Raw) | Should -BeLike '*Bash(echo:*)*'
    }
    It 'на репозиторії без хуків вивід kit check називає команду install-hooks' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-mentions-command')
        $check = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo 2>&1 | Out-String
        $check | Should -BeLike '*install-hooks*'
    }
}
