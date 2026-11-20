#Requires -Version 7
# kit-setup: ідемпотентність, збереження чужого в settings.json, -DryRun без запису
# (оригінал — agent-kit 0.9.1 tests/kit-setup.test.mjs). Справжній kit-process.ps1 підпроцесом на
# синтетичному git-репо в TestDrive: — за зразком SessionBoard.Tests.ps1.
Describe 'kit-setup — підключення проєкту' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitProcess = Join-Path (Split-Path $script:Kit -Parent) 'kit-process.ps1'
        $script:Files = @('.claude/settings.json', '.gitignore', '.agents/kit.profile.json', '.worktreeinclude')

        function script:New-Repo {
            param([string]$Name)
            $repo = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $repo | Out-Null
            & git -C $repo init -q -b main 2>&1 | Out-Null
            $repo
        }
        function script:Invoke-Setup {
            param([string]$Repo, [string[]]$Arguments = @())
            Push-Location $Repo
            try { $out = & pwsh -NoProfile -File $script:KitProcess kit-setup @Arguments 2>&1 | Out-String; $code = $LASTEXITCODE }
            finally { Pop-Location }
            [pscustomobject]@{ Code = $code; Out = $out }
        }
        function script:Get-Hashes {
            param([string]$Repo)
            $script:Files | ForEach-Object {
                $p = Join-Path $Repo $_
                if (Test-Path -LiteralPath $p) { "$_=$((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash)" } else { "$_=<немає>" }
            }
        }
    }

    It 'повторний запуск нічого не змінює: байти всіх чотирьох файлів однакові' {
        $repo = New-Repo 'idem'
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'node_modules' -Encoding utf8NoBOM
        $r1 = Invoke-Setup $repo
        $r1.Code | Should -Be 0 -Because $r1.Out
        $first = Get-Hashes $repo
        $first | Should -Not -Contain '.claude/settings.json=<немає>'
        $first | Should -Not -Contain '.agents/kit.profile.json=<немає>'
        $r2 = Invoke-Setup $repo
        $r2.Code | Should -Be 0 -Because $r2.Out
        (Get-Hashes $repo) | Should -Be $first -Because $r2.Out
        $r2.Out | Should -Match '(?m)^next: kit-scan\r?$' -Because $r2.Out
    }

    It 'чуже правило й наявне Bash(pr-gate:*) лишаються на місці; нове дописується в кінець, у двох формах' {
        $repo = New-Repo 'keep'
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') | Out-Null
        $settings = Join-Path $repo '.claude/settings.json'
        Set-Content -LiteralPath $settings -Encoding utf8NoBOM -Value ([ordered]@{
                attribution = @{ commit = '' }
                permissions = [ordered]@{ deny = @('Bash(rm:*)'); allow = @('Bash(git status*)', 'Bash(pr-gate:*)') }
                env         = @{ A = '1' }
            } | ConvertTo-Json -Depth 5)
        $r = Invoke-Setup $repo -Arguments @('-NoGitignore', '-NoProfile', '-NoWorktreeInclude')
        $r.Code | Should -Be 0 -Because $r.Out
        $s = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -AsHashtable
        @($s.Keys) | Should -Be @('attribution', 'permissions', 'env')
        @($s.permissions.Keys) | Should -Be @('deny', 'allow')
        @($s.permissions.allow)[0..1] | Should -Be @('Bash(git status*)', 'Bash(pr-gate:*)')
        $s.permissions.allow | Should -Contain 'PowerShell(session-cost:*)'
        $s.permissions.allow | Should -Contain 'Bash(session-cost:*)'
        $s.permissions.allow | Should -Not -Contain 'Bash(pr-gate open:*)'
        $r.Out | Should -Match 'Bash\(pr-gate:\*\)'   # широке правило названо рядком-попередженням
        Test-Path -LiteralPath (Join-Path $repo '.gitignore') | Should -BeFalse
    }

    It '-DryRun нічого не пише й друкує diff' {
        $repo = New-Repo 'dry'
        $r = Invoke-Setup $repo -Arguments @('-DryRun')
        $r.Code | Should -Be 0 -Because $r.Out
        foreach ($f in $script:Files) { Test-Path -LiteralPath (Join-Path $repo $f) | Should -BeFalse -Because $f }
        $r.Out | Should -Match '(?m)^--- /dev/null\r?$'
        $r.Out | Should -Match '(?m)^\+\+\+ b/\.gitignore\r?$'
        $r.Out | Should -Match '(?m)^\+\.agents/out/\r?$'
    }
}
