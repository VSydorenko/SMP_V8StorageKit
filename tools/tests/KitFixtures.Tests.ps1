#Requires -Version 7
Describe 'фікстура Invoke-KitCommand — спільний виклик kit.ps1 підпроцесом' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
    }

    # Головна перевірка фікстури: Invoke-KitCommand стане єдиною
    # точкою відмови всіх E2E-тестів набору, тож саме тут ловиться "фікстура тихо ковтнула
    # ненульовий код виходу" — навмисно провалена команда на репозиторії без маніфесту.
    It 'навмисно провалена команда (check без маніфесту) — ненульовий ExitCode і текст причини' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-manifest') -WithHooks -WithGitattributes -WithGitignore
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
    }

    # check виконує kit.exe сам. Фікстура ставить фальшивий pwsh.exe першим у PATH: якщо маршрут
    # `check` у main.rs не спрацював (чи фікстура взяла `kit` з PATH), `kit.exe` передав би команду диспетчеру —
    # і фальшивий pwsh лишив би маркер.
    It 'check через фікстуру не запускає pwsh (маркера немає); без маніфесту — звичайний звіт, а не помилка диспетчера' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'marker-check') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-KitFakePwsh -Kit $script:Kit).Marker | Should -Not -Exist
    }

    # session-check виконує kit.exe сам: та сама гарантія фікстури, що для check.
    It 'session-check через фікстуру не запускає pwsh (маркера немає); звичайний звіт, а не помилка диспетчера' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'marker-session-check') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'session-check' -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike 'session-check — product Fake*'
        (Get-KitFakePwsh -Kit $script:Kit).Marker | Should -Not -Exist
    }

    It 'контроль маркера: неперенесена команда через ТОЙ САМИЙ kit.exe і PATH запускає фальшивий pwsh — маркер є' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'marker-control') -WithHooks -WithGitattributes -WithGitignore
        $fake = Get-KitFakePwsh -Kit $script:Kit
        Remove-Item -LiteralPath $fake.Marker -Force -ErrorAction SilentlyContinue
        $saved = @{ PATH = $env:PATH; M = $env:FAKE_PWSH_MARKER }
        try {
            $env:PATH = "$($fake.Bin);$env:PATH"
            $env:FAKE_PWSH_MARKER = $fake.Marker
            & (Get-KitExe -Kit $script:Kit) verify -RepoRoot $repo 2>&1 | Out-Null
        } finally {
            $env:PATH = $saved.PATH
            if ($null -eq $saved.M) { Remove-Item Env:FAKE_PWSH_MARKER -ErrorAction SilentlyContinue } else { $env:FAKE_PWSH_MARKER = $saved.M }
        }
        $fake.Marker | Should -Exist
        Get-Content -LiteralPath $fake.Marker -Raw | Should -BeLike '*-NoProfile -File *kit.ps1*'
        Remove-Item -LiteralPath $fake.Marker -Force
    }

    # Диспетчер PowerShell шукає команду без регістру (-notcontains), тож і маршрути kit.exe — без регістру: інакше
    # `kit.exe Check` пішов би в pwsh і виконав старий PowerShell-`check` (без маски userinfo шляху сховища).
    Context 'регістр імені команди' {
        BeforeAll {
            $script:CaseRepo = New-KitFakeRepo -Root (Join-Path $TestDrive 'case-repo') -WithHooks -WithGitattributes -WithGitignore
            $script:Fake = Get-KitFakePwsh -Kit $script:Kit
            # Без маніфесту: хук session-start не запускає pwsh ні з маніфестом (session-check — kit.exe), ні без; тут репозиторій без маніфесту, щоб нічого зайвого не виконувалось.
            $script:CasePlain = Join-Path $TestDrive 'case-plain'
            New-Item -ItemType Directory -Path (Join-Path $script:CasePlain '.git') -Force | Out-Null
            function script:Invoke-WithFakePwsh([string[]]$Tokens) {
                Remove-Item -LiteralPath $script:Fake.Marker -Force -ErrorAction SilentlyContinue
                $saved = @{ PATH = $env:PATH; M = $env:FAKE_PWSH_MARKER }
                Push-Location $script:CasePlain
                try {
                    $env:PATH = "$($script:Fake.Bin);$env:PATH"
                    $env:FAKE_PWSH_MARKER = $script:Fake.Marker
                    $out = '' | & (Get-KitExe -Kit $script:Kit) @Tokens 2>&1 | Out-String
                    $code = $LASTEXITCODE
                } finally {
                    Pop-Location
                    $env:PATH = $saved.PATH
                    if ($null -eq $saved.M) { Remove-Item Env:FAKE_PWSH_MARKER -ErrorAction SilentlyContinue } else { $env:FAKE_PWSH_MARKER = $saved.M }
                }
                [pscustomobject]@{ ExitCode = $code; Output = $out; Launched = (Test-Path -LiteralPath $script:Fake.Marker) }
            }
        }
        It 'маршрут <Route> у формі <Given> не падає в диспетчер PowerShell (маркера немає), код і вивід — як у малих літер' -ForEach @(
            @{ Route = 'check'; Given = 'Check'; Rest = @('-Help') }
            @{ Route = 'check'; Given = 'CHECK'; Rest = @('-Help') }
            @{ Route = 'session-check'; Given = 'Session-Check'; Rest = @('-Help') }
            @{ Route = 'session-start'; Given = 'Session-Start'; Rest = @() }
            @{ Route = 'subagent-start'; Given = 'SUBAGENT-START'; Rest = @() }
            @{ Route = 'pretool-1c'; Given = 'PRETOOL-1C'; Rest = @() }
            @{ Route = 'session-board'; Given = 'Session-Board'; Rest = @() }
            @{ Route = 'config-preflight'; Given = 'Config-Preflight'; Rest = @('-Help') }
            @{ Route = 'runner-exec'; Given = 'Runner-Exec'; Rest = @() }
            @{ Route = 'tool-verdicts'; Given = 'Tool-Verdicts'; Rest = @('-Help') }
            @{ Route = 'source-fingerprint'; Given = 'Source-Fingerprint'; Rest = @() }
        ) {
            $mixed = Invoke-WithFakePwsh (@($Given) + $Rest)
            $mixed.Launched | Should -BeFalse -Because "kit.exe $Given пішов у pwsh: $($mixed.Output)"
            $lower = Invoke-WithFakePwsh (@($Route) + $Rest)
            $lower.Launched | Should -BeFalse
            $mixed.ExitCode | Should -Be $lower.ExitCode
            if ($Route -in 'check', 'session-check', 'tool-verdicts', 'runner-exec') { $mixed.Output | Should -Be $lower.Output }
        }
        It 'контроль: неперенесена команда в іншому регістрі (Verify) іде в pwsh — маркер є' {
            (Invoke-WithFakePwsh @('Verify', '-RepoRoot', $script:CaseRepo)).Launched | Should -BeTrue
        }
        It 'маска userinfo: kit.exe Check друкує tcp://***@host, а не шлях з паролем' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'case-userinfo') -WithHooks -WithGitignore -OverlayText "storages:`n  Alpha_SMB: 'tcp://user:MARKZ9@host/x'"
            $r = Invoke-WithFakePwsh @('Check', '-RepoRoot', $repo, '-InstalledPluginsPath', (New-KitFakeUnicaRegistry))
            $r.Launched | Should -BeFalse
            $r.Output.Contains('MARKZ9') | Should -BeFalse -Because $r.Output
            $r.Output.Contains('tcp://***@host/x') | Should -BeTrue -Because $r.Output
        }
    }
}
