#Requires -Version 7
Describe 'kit sync — запасний шлях для розширення без бази агента (спека 2026-09-30 §6.9, мок платформи)' {
    # Інваріанти: перемикання на тимчасову ІБ із заглушкою — лише для EXTENSION і лише на відповіді
    # «розширення не знайдено»; весь прогін джерела (звіт і кожна версія) іде в тимчасовій ІБ;
    # база агента не чіпається. Запасний шлях — ознака ДЖЕРЕЛА (Synced[].Fallback), не прогону.
    # Invoke-KitSync викликається в цьому процесі (як у Sync.Merge.Tests.ps1): Mock -ModuleName
    # діє лише в таблиці команд названого модуля.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force

        function script:New-KitTestContext {
            param([Parameter(Mandatory)][string]$Repo)
            Invoke-KitPreflight -RepoRoot $Repo
        }
        function script:New-KitFakeStorageVersion {
            param([int]$Version, [string]$User = 'gitbot', [string]$Comment = 'версія')
            [pscustomobject]@{
                Version = $Version; User = $User; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = $Comment; Added = @(); Modified = @(); Deleted = @()
                Timestamp = [datetime]'2026-01-01T09:00:00'
            }
        }
        # WithAgentBase: без бази агента виконання зупинилось би в Get-KitSourceInfobase ДО звіту, і
        # тест не дійшов би до запасного шляху (kit-dev, case 21 (б)). Каталог сховища — реальний,
        # з накладки: перевірка його існування стоїть перед звітом.
        function script:New-FallbackRepo {
            param([string]$Name, [System.Collections.IDictionary]$Workspaces)
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
        $script:TmpIb = '/F "fallback-temp-ib"'
        $script:NotFound = 'Не вдалося побудувати звіт сховища R:\s : Расширение конфигурации с указанным именем не найдено'
    }

    BeforeEach {
        $script:DesignerIb = [System.Collections.Generic.List[string]]::new()
        $script:ReportUsers = [System.Collections.Generic.List[string]]::new()
        $script:NotFoundFor = @('Alpha_SMB')
        Mock -ModuleName sync New-KitStorageInfobase { $script:TmpIb }
        Mock -ModuleName sync Get-StorageVersions {
            param($IbSwitch, $StoragePath, $ExtensionName, $StorageUser, $StoragePassword, $WorkDir, $User)
            if ($IbSwitch -ne $script:TmpIb -and $ExtensionName -in $script:NotFoundFor) { throw $script:NotFound }
            if ($IbSwitch -eq $script:TmpIb) { $script:ReportUsers.Add([string]$User) }
            , @((New-KitFakeStorageVersion -Version 1), (New-KitFakeStorageVersion -Version 2))
        }
        Mock -ModuleName StoragePlatform Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User)
            $script:DesignerIb.Add($IbSwitch)
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }
    }

    It 'розширення «не знайдено» в базі агента — прогін у тимчасовій ІБ, попередження, коміти, база агента не чіпана' {
        $repo = New-FallbackRepo 'fb-ext'
        $out = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true 6>&1 | Out-String
        $out | Should -BeLike '*прогін у тимчасовій ІБ із заглушкою*'
        $out | Should -BeLike '*База агента не змінювалась*'
        $out | Should -Not -BeLike '*тепер містить версію*'
        @(git -C $repo log --format=%H storage/Alpha_SMB).Count | Should -Be 2
        # Кожна платформна операція (UpdateCfg і дамп кожної версії) — лише в тимчасовій ІБ.
        $script:DesignerIb.Count | Should -BeGreaterThan 0
        @($script:DesignerIb | Where-Object { $_ -ne $script:TmpIb }).Count | Should -Be 0
        # Користувач тимчасової ІБ — порожній (у ній користувачів немає), не користувач бази агента.
        @($script:ReportUsers | Where-Object { $_ }).Count | Should -Be 0
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 1 -Exactly -Scope It
    }

    It 'Fallback — поле запису джерела: одне розширення запасним шляхом, інше штатно в тому самому прогоні' {
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }
            @{ Name = 'Beta_SMB';  Type = 'EXTENSION'; Path = 'cfe2/src' }) } }
        $repo = New-FallbackRepo 'fb-two' -Workspaces $ws
        $r = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true 6>$null
        $r.Synced.Count | Should -Be 2
        @($r.Synced | Where-Object Key -eq 'Alpha_SMB')[0].Fallback | Should -BeTrue
        @($r.Synced | Where-Object Key -eq 'Beta_SMB')[0].Fallback | Should -BeFalse
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 1 -Exactly -Scope It
    }

    It 'прев''ю (без -Apply) теж перемикається: звіт у тимчасовій ІБ, гілка не створюється' {
        $repo = New-FallbackRepo 'fb-preview'
        $null = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) 6>$null
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 1 -Exactly -Scope It
        @($script:ReportUsers).Count | Should -Be 1
        git -C $repo rev-parse --verify --quiet refs/heads/storage/Alpha_SMB 2>$null | Should -BeNullOrEmpty
    }

    It 'CONFIGURATION на тому самому тексті — зупинка, як зараз, без тимчасової ІБ' {
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
        $repo = New-FallbackRepo 'fb-cfg' -Workspaces $ws
        $script:NotFoundFor = @('')
        { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) 6>$null } | Should -Throw '*не найдено*'
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 0 -Scope It
    }

    It 'розширення, інша помилка звіту (автентифікація) — зупинка, без тимчасової ІБ' {
        $repo = New-FallbackRepo 'fb-auth'
        Mock -ModuleName sync Get-StorageVersions { throw 'Не вдалося побудувати звіт сховища R:\s : Ошибка аутентификации в хранилище конфигурации' }
        { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) 6>$null } | Should -Throw '*аутентификации*'
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 0 -Scope It
    }

    It 'розширення, яке Є в базі агента — запасний шлях не вмикається' {
        $repo = New-FallbackRepo 'fb-present'
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 1) }
        $null = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) 6>$null
        Should -Invoke -ModuleName sync New-KitStorageInfobase -Times 0 -Scope It
    }
}
