#Requires -Version 7
Describe 'фікстура Invoke-KitCommand — спільний виклик kit.ps1 підпроцесом' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
    }

    It 'успішна команда — код 0 і текст у Output' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'good') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
    }

    # Головна перевірка фікстури (брифа Task 5, Step 1): Invoke-KitCommand стане єдиною
    # точкою відмови всіх E2E-тестів набору, тож саме тут ловиться "фікстура тихо ковтнула
    # ненульовий код виходу" — навмисно провалена команда на репозиторії без маніфесту.
    It 'навмисно провалена команда (check без маніфесту) — ненульовий ExitCode і текст причини' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-manifest') -WithHooks -WithGitattributes -WithGitignore
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
    }

    It 'клієнтський воркспейс: CONFIGURATION + два EXTENSION під truth: storage, base не першим у маніфесті' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'client') -Workspaces (New-KitClientWorkspaces) -WithGitignore -WithSupply
        $m = Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw
        $m | Should -Not -Match 'truth: vendor'
        ([regex]::Matches($m, 'truth: storage')).Count | Should -Be 3
        $m.IndexOf('ExtA:') | Should -BeLessThan $m.IndexOf('base:')
        # .bin — у git, .cf і позначка — на диску, поза git (як на машині після canon).
        $cfg = 'Client_UNF/cf/src'
        @(git -C $repo ls-files -- "$cfg/Ext/ParentConfigurations.bin").Count | Should -Be 1
        @(git -C $repo ls-files -- "$cfg/Ext/ParentConfigurations").Count | Should -Be 0
        Join-Path $repo "$cfg/Ext/ParentConfigurations/Vendor.cf" | Should -Exist
        Join-Path $repo "$cfg/Ext/ParentConfigurations/.kit-bin-sha1" | Should -Exist
        Join-Path $repo 'Client_UNF/cfe/Доработки/src/Configuration.xml' | Should -Exist
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }
}
