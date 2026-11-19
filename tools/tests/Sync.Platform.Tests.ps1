#Requires -Version 7
Describe 'kit sync/verify — платформу для бази агента обирає раннер, перед платформою agent release (Unica 0.16, спека 2026-11-19 §3.6 п.1, п.4, §4.2 п.14, п.20)' {
    # Обидві команди викликаються в цьому процесі, платформа й раннер мокаються за -ModuleName команди:
    # sync.psm1 / verify.psm1 кличуть Get-KitRunnerPath, Get-KitAgentPlatform, Invoke-KitAgentRelease прямо.
    # Нижче — платформний шар: Invoke-V8Designer мокається в StoragePlatform (UpdateCfg, дамп), звіт —
    # Get-StorageVersions у sync. Контроль «платформа дійшла» — ParameterFilter на $V8Path кожного
    # виклику Invoke-V8Designer: у справжньому Invoke-V8Designer порожній $V8Path тихо підміняється
    # Get-V8Path, тож саме відсутність -V8Path зробила б хибно-зеленим мок, що Get-V8Path не кликали.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/verify.psm1").Path -Force

        $script:FakeV8 = 'C:\fake\8.3.27.9999\bin\1cv8.exe'

        function script:New-KitFakeStorageVersion {
            param([int]$Version)
            [pscustomobject]@{
                Version = $Version; User = 'gitbot'; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = 'версія'; Added = @(); Modified = @(); Deleted = @()
                Timestamp = [datetime]'2026-01-01T09:00:00'
            }
        }
        # Основна конфігурація під сховищем, дзеркало вже на v6, у звіті v7.
        function script:New-PlatformRepo {
            param([string]$Name, $Workspaces)
            $p = @{ Root = (Join-Path $TestDrive $Name); WithHooks = $true; WithGitignore = $true; WithAgentBase = $true }
            if ($Workspaces) { $p.Workspaces = $Workspaces }
            $repo = New-KitFakeRepo @p
            $ctx0 = Invoke-KitPreflight -RepoRoot $repo
            $keys = @($ctx0.Workspaces | ForEach-Object { $_.Sources } | Where-Object Truth -eq 'storage' | ForEach-Object Key)
            $lines = @('storages:') + @(foreach ($k in $keys) {
                $d = Join-Path $TestDrive "$Name-storage-$k"; New-Item -ItemType Directory -Path $d -Force | Out-Null; "  ${k}: '$d'" })
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
            $repo
        }
        function script:New-MirroredPlatformRepo {
            param([string]$Name)
            $repo = New-PlatformRepo $Name
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
                -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 6')
            $repo
        }
    }

    BeforeEach {
        # Послідовність платформних подій — для перевірок порядку.
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName sync Get-KitRunnerPath { 'C:\fake\v8-runner.exe' }
        Mock -ModuleName sync Get-KitAgentPlatform { $script:Calls.Add('platform'); $script:FakeV8 }
        Mock -ModuleName sync Invoke-KitAgentRelease { $script:Calls.Add('release'); [pscustomobject]@{ released = $true; disconnected = $true } }
        Mock -ModuleName sync Get-StorageVersions { $script:Calls.Add('report'); , @(New-KitFakeStorageVersion -Version 7) }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }
        Mock -ModuleName StoragePlatform Invoke-V8Designer { $script:Calls.Add('designer'); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Основну платформу дає раннер: будь-який Get-V8Path у шляху sync (де б він не стояв) — регресія.
        Mock -ModuleName sync Get-V8Path { throw 'Get-V8Path у шляху sync: платформу має давати раннер' }
        Mock -ModuleName StoragePlatform Get-V8Path { throw 'Get-V8Path у StoragePlatform: платформу має давати раннер' }
        Mock -ModuleName StorageReport Get-V8Path { throw 'Get-V8Path у StorageReport: платформу має давати раннер' }

        Mock -ModuleName verify Get-KitRunnerPath { 'C:\fake\v8-runner.exe' }
        Mock -ModuleName verify Get-KitAgentPlatform { $script:Calls.Add('platform'); $script:FakeV8 }
        Mock -ModuleName verify Invoke-KitAgentRelease { $script:Calls.Add('release'); [pscustomobject]@{ released = $true; disconnected = $true } }
        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            $script:Calls.Add('checkout')
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value (New-KitFakeConfigurationXml -Name 'Alpha_SMB') -Encoding UTF8 -NoNewline
            1
        }
    }

    It 'sync -Apply: звіт і кожен виклик платформи отримують платформу раннера, Get-V8Path не кликається (контроль §8)' {
        $repo = New-MirroredPlatformRepo 'sync-apply'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        # UpdateCfg + DumpConfigToFiles однієї версії; жодного виклику без платформи раннера.
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2 -Exactly
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 1 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
        Should -Invoke -ModuleName sync Get-V8Path -Times 0 -Exactly
        Should -Invoke -ModuleName StoragePlatform Get-V8Path -Times 0 -Exactly
        $text | Should -BeLike '*Платформа:  8.3.27.9999 (обрав раннер)*'
    }

    It 'sync: порядок — платформа, agent release, звіт, лише потім платформні виклики (Apply)' {
        $repo = New-MirroredPlatformRepo 'sync-order'
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true 6>$null
        @($script:Calls) | Should -Be @('platform', 'release', 'report', 'designer', 'designer')
    }

    It 'sync без -Apply: прев''ю теж читає звіт через платформу — спершу платформа й release' {
        $repo = New-MirroredPlatformRepo 'sync-preview'
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) 6>$null
        @($script:Calls) | Should -Be @('platform', 'release', 'report')
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 1 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
    }

    It 'sync: платформа визначається раз на воркспейс, release — перед звітом кожного джерела' {
        $repo = New-PlatformRepo 'sync-cache' (New-KitClientWorkspaces)
        Mock -ModuleName sync Get-StorageVersions { $script:Calls.Add('report'); , @() }
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) 6>$null
        # Клієнтський воркспейс: три джерела (base, ExtA, Доработки) на одному воркспейсі.
        Should -Invoke -ModuleName sync Get-KitAgentPlatform -Times 1 -Exactly
        Should -Invoke -ModuleName sync Invoke-KitAgentRelease -Times 3 -Exactly
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 3 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
        @($script:Calls) | Should -Be @('platform', 'release', 'report', 'release', 'report', 'release', 'report')
    }

    It 'sync: явний -RunnerPath доходить до раннера, реєстр плагінів не опитується' {
        $repo = New-MirroredPlatformRepo 'sync-runnerpath'
        $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -RunnerPath 'C:\explicit\v8-runner.exe' 6>$null
        Should -Invoke -ModuleName sync Get-KitRunnerPath -Times 0 -Exactly
        Should -Invoke -ModuleName sync Get-KitAgentPlatform -Times 1 -Exactly -ParameterFilter { $RunnerPath -eq 'C:\explicit\v8-runner.exe' }
        Should -Invoke -ModuleName sync Invoke-KitAgentRelease -Times 1 -Exactly -ParameterFilter { $RunnerPath -eq 'C:\explicit\v8-runner.exe' }
    }

    It 'раннера немає: sync зупиняється до першого звернення до платформи, у тексті — пояснення з винятку' {
        $repo = New-MirroredPlatformRepo 'sync-no-runner'
        Mock -ModuleName sync Get-KitRunnerPath { throw 'Раннер не знайдено: Unica не встановлена. ПОЯСНЕННЯ-ТЕСТ' }
        $err = $null
        try { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Раннер не знайдено*ПОЯСНЕННЯ-ТЕСТ*'
        @($script:Calls).Count | Should -Be 0
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0 -Exactly
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly
    }

    It 'раннер не визначив платформу: sync зупиняється з текстом раннера до release і до звіту' {
        $repo = New-MirroredPlatformRepo 'sync-no-platform'
        Mock -ModuleName sync Get-KitAgentPlatform { throw 'Раннер не визначив платформу для воркспейсу X: no infobase is selected' }
        $err = $null
        try { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*no infobase is selected*'
        Should -Invoke -ModuleName sync Invoke-KitAgentRelease -Times 0 -Exactly
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0 -Exactly
    }

    It 'verify: платформа раннера й release — перед дампом; прив''язка і дамп отримують -V8Path' {
        $repo = New-MirroredPlatformRepo 'verify-order'
        $null = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB' 6>$null
        @($script:Calls) | Should -Be @('platform', 'release', 'checkout')
        Should -Invoke -ModuleName verify Invoke-KitStorageCheckout -Times 1 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
        Should -Invoke -ModuleName verify Enter-KitStorageBind -Times 1 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
        Should -Invoke -ModuleName verify Exit-KitStorageBind -Times 1 -Exactly -ParameterFilter { $V8Path -eq $script:FakeV8 }
    }

    It 'verify: явний -RunnerPath доходить до раннера; платформа — раз на воркспейс' {
        $repo = New-MirroredPlatformRepo 'verify-runnerpath'
        $text = & { $null = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB' -RunnerPath 'C:\explicit\v8-runner.exe' } 6>&1 | Out-String
        Should -Invoke -ModuleName verify Get-KitRunnerPath -Times 0 -Exactly
        Should -Invoke -ModuleName verify Get-KitAgentPlatform -Times 1 -Exactly -ParameterFilter { $RunnerPath -eq 'C:\explicit\v8-runner.exe' }
        Should -Invoke -ModuleName verify Invoke-KitAgentRelease -Times 1 -Exactly -ParameterFilter { $RunnerPath -eq 'C:\explicit\v8-runner.exe' }
        $text | Should -BeLike '*Платформа:  8.3.27.9999 (обрав раннер)*'
    }

    It 'verify: раннера немає — зупинка до release і до дампу, у тексті пояснення' {
        $repo = New-MirroredPlatformRepo 'verify-no-runner'
        Mock -ModuleName verify Get-KitRunnerPath { throw 'Раннер не знайдено: Unica не встановлена. ПОЯСНЕННЯ-ТЕСТ' }
        $err = $null
        try { $null = Invoke-KitVerify -Context (Invoke-KitPreflight -RepoRoot $repo) -Ref 'storage/Alpha_SMB' 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Раннер не знайдено*ПОЯСНЕННЯ-ТЕСТ*'
        @($script:Calls).Count | Should -Be 0
        Should -Invoke -ModuleName verify Invoke-KitStorageCheckout -Times 0 -Exactly
    }
}
