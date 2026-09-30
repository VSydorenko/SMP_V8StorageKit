#Requires -Version 7
Describe 'kit sync — порядок джерел клієнтського воркспейсу й попередження (мок платформи)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force

        function script:New-ClientRepo {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
            $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add('storages:')
            foreach ($k in 'ExtA', 'base', 'Доработки') {
                $d = Join-Path $TestDrive "$Name-storage-$k"; New-Item -ItemType Directory -Path $d -Force | Out-Null
                $lines.Add("  ${k}: '$d'")
            }
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
            $repo
        }
    }

    BeforeEach {
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        # Прев'ю (без -Apply): платформа потрібна лише для звіту сховища, і його мокаємо; порядок
        # викликів звіту = порядок обробки джерел. '<CONFIGURATION>' — ExtensionName порожній.
        Mock -ModuleName sync Get-StorageVersions {
            param($IbSwitch, $StoragePath, $ExtensionName)
            $script:Seen.Add($(if ($ExtensionName) { $ExtensionName } else { '<CONFIGURATION>' }))
            , @()
        }
        Mock -ModuleName StoragePlatform Invoke-V8Designer { throw 'платформа не мала викликатись у прев''ю' }
    }

    It 'CONFIGURATION обробляється першим, хоча в маніфесті він другий; розширення — у маніфестному порядку' {
        $repo = New-ClientRepo 'order'
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo)
        @($script:Seen) | Should -Be @('<CONFIGURATION>', 'ExtA', 'Доработки')
    }

    It '-Source з розширенням при CONFIGURATION під storage у воркспейсі — попередження, не зупинка' {
        $repo = New-ClientRepo 'warn-ext'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'ExtA' 6>&1 | Out-String
        $out | Should -BeLike '*base*не синхронізовано*'
        @($script:Seen) | Should -Be @('ExtA')
    }

    It 'повний прогін воркспейсу — попередження немає' {
        $repo = New-ClientRepo 'no-warn'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) 6>&1 | Out-String
        $out | Should -Not -BeLike '*не синхронізовано*'
    }

    It '-Source base — попередження немає' {
        $repo = New-ClientRepo 'no-warn-base'
        $out = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'base' 6>&1 | Out-String
        $out | Should -Not -BeLike '*не синхронізовано*'
    }

    It 'два воркспейси: порядок воркспейсів маніфестний, CONFIGURATION першим у кожному' {
        $ws = New-KitClientWorkspaces
        $ws['Second_UNF'] = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'ExtC';  Type = 'EXTENSION';     Path = 'cfe/ExtC/src' }
            @{ Name = 'base2'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'two-ws') -Workspaces $ws -WithHooks -WithGitignore -WithAgentBase
        $lines = @('storages:') + @(foreach ($k in 'ExtA', 'base', 'Доработки', 'ExtC', 'base2') {
            $d = Join-Path $TestDrive "two-ws-storage-$k"; New-Item -ItemType Directory -Path $d -Force | Out-Null; "  ${k}: '$d'" })
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo)
        @($script:Seen) | Should -Be @('<CONFIGURATION>', 'ExtA', 'Доработки', '<CONFIGURATION>', 'ExtC')
    }
}
