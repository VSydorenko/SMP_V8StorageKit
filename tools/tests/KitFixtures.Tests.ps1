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
        $paths | Should -Contain 'Alpha_SMB/cfe/src/T/Образецанализ.xml'
        $paths | Should -Contain 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'
        (git -C $repo rev-parse HEAD) | Should -Be $head
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        # Другий коміт — батько = попередня вершина
        $sha2 = Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message 'v2' -Files ([ordered]@{ 'Alpha_SMB/cfe/src/a.xml' = 'A' })
        (git -C $repo rev-parse "$sha2^") | Should -Be $sha
    }
}
