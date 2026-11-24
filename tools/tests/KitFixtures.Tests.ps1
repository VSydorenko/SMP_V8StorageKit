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

    # check виконує kit.exe сам (блок B3). Фікстура ставить фальшивий pwsh.exe першим у PATH: якщо маршрут
    # `check` у main.rs не спрацював (чи фікстура взяла `kit` з PATH), `kit.exe` передав би команду диспетчеру —
    # і фальшивий pwsh лишив би маркер.
    It 'check через фікстуру не запускає pwsh (маркера немає); без маніфесту — звичайний звіт, а не помилка диспетчера' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'marker-check') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
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
}
