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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'client') -Workspaces (New-KitClientWorkspaces) -WithGitignore -WithSupply -WithGitattributes
        $attrs = @(Get-Content -LiteralPath (Join-Path $repo '.gitattributes') -Encoding UTF8)
        $attrs | Should -Contain 'Client_UNF/cf/src/** -text'
        $attrs | Should -Contain 'Client_UNF/cfe/Доработки/src/** -text'
        $attrs | Should -Contain 'Client_UNF/cfe/ExtA/src/** -text'
        $m =Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw
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

    It 'Set-KitFakeBranchTree: записує два шляхи, що різняться лише кириличним регістром; робоча копія не рухається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fake-tree')
        $head = git -C $repo rev-parse HEAD
        # Літерал @{}/[ordered]@{} регістронезалежний і відхиляє пару як дубль ключа — потрібен Ordinal-словник.
        $files = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        $files['Alpha_SMB/cfe/src/T/Образецанализ.xml'] = 'old'
        $files['Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'] = 'new'
        $sha = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" -Files $files
        (git -C $repo rev-parse storage/Alpha_SMB) | Should -Be $sha
        $paths = @(git -c core.quotepath=false -C $repo ls-tree -r --name-only storage/Alpha_SMB)
        $paths | Should -HaveCount 2
        # -ccontains, не Should -Contain: Pester порівнює рядки нечутливо до регістру.
        ($paths -ccontains 'Alpha_SMB/cfe/src/T/Образецанализ.xml') | Should -BeTrue -Because "у переліку: $($paths -join ', ')"
        ($paths -ccontains 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml') | Should -BeTrue -Because "у переліку: $($paths -join ', ')"
        (git -C $repo rev-parse HEAD) | Should -Be $head
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        # Другий коміт — батько = попередня вершина
        $sha2 = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message 'v2' -Files ([ordered]@{ 'Alpha_SMB/cfe/src/a.xml' = 'A' })
        (git -C $repo rev-parse "$sha2^") | Should -Be $sha
    }

    # Task 5: Invoke-KitCommand сам підставляє фальшивий реєстр Уніки для check/session-check. Щоб
    # тест не залежав від Уніки на машині, підпроцесу ховаємо справжній домашній каталог (HOME і
    # USERPROFILE → порожня тека): без підстановки kit побачив би «реєстр не знайдено» — info зі
    # словами «Плагін unica», а з підстановкою 0.13.0 знахідки unica-version немає зовсім.
    It 'check без -InstalledPluginsPath: фікстура підставляє фальшивий реєстр, знахідки unica-version немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fake-unica') -WithHooks -WithGitattributes -WithGitignore
        $emptyHome = Join-Path $TestDrive 'empty-home'
        New-Item -ItemType Directory -Path $emptyHome -Force | Out-Null
        $oldHome = $env:HOME; $oldProfile = $env:USERPROFILE
        try {
            $env:HOME = $emptyHome; $env:USERPROFILE = $emptyHome
            $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo
        } finally { $env:HOME = $oldHome; $env:USERPROFILE = $oldProfile }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*плагін unica*'
    }
    It 'check з явним -InstalledPluginsPath: фікстура свого не додає (явний реєстр виграє)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'explicit-unica') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.11.7'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*0.11.7*'
    }
    It 'New-KitFakeUnicaRegistry: файл читається Get-UnicaInstallation з заданою версією' {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Environment.psm1").Path -Force
        $i = Get-UnicaInstallation -InstalledPluginsPath (New-KitFakeUnicaRegistry -Version '0.13.4')
        $i.Installed | Should -BeTrue
        $i.PathExists | Should -BeTrue
        $i.Version | Should -Be '0.13.4'
    }
}
