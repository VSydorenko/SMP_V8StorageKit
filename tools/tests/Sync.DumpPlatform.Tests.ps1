#Requires -Version 7
Describe 'kit sync — версія, яку основна платформа не вивантажує: зупинка §4.1, -DumpPlatform/-ForVersion, -SkipVersion (спека 1.3.1, мок платформи)' {
    # Invoke-KitSync викликається в цьому процесі (як у Sync.Merge.Tests.ps1): Mock -ModuleName
    # діє лише в таблиці команд названого модуля. Платформний шар мокається цілком за
    # -ModuleName sync — sync.psm1 кличе Invoke-KitStorageCheckout, Invoke-KitStorageCheckoutViaPlatform,
    # Enter-/Exit-KitStorageBind, Get-V8Path і Get-KitInstalledPlatforms прямо. Кожен мок платформного
    # виклику пише крок у $script:Steps: «жоден UpdateCfg до відмови перевірки» тут = порожній
    # Steps і нуль викликів Enter-KitStorageBind (прив'язка стоїть перед першою версією).
    # Мок Get-KitInstalledPlatforms повертає масив БЕЗ унарної коми: функція production-коду теж
    # не загортає (споживач пише @(...)), а `, $масив` у моку дав би масив із одного елемента-масиву.
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
        # Основна конфігурація під сховищем, дзеркало вже на v33.
        function script:New-DumpRepo {
            param([string]$Name)
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -WithHooks -WithGitignore -WithAgentBase
            $sd = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $sd -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$sd'") -join "`n")
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/base' -RepoPath 'Alpha_SMB/cf/src' -FileName 'Configuration.xml' -Content '<x/>' -Trailers @('Storage-Source: base', 'Storage-Version: 33')
            $repo
        }
        # Звичайний запуск: виняток — у $script:SyncError, Write-Host — у поверненому тексті.
        function script:Invoke-DumpSync {
            param([string]$Repo, [hashtable]$Params = @{})
            $script:SyncError = $null
            $script:SyncResult = $null
            & { try { $script:SyncResult = Invoke-KitSync -Context (New-KitTestContext -Repo $Repo) @Params } catch { $script:SyncError = $_.Exception.Message } } 6>&1 | Out-String
        }
        function script:Get-Trailer {
            param([string]$Repo, [string]$Sha, [string]$Key)
            (git -C $Repo log -1 --format="%(trailers:key=$Key,valueonly)" $Sha | Where-Object { $_ }) -join ''
        }
        function script:New-DumpFailure {
            param([int]$Version)
            $ex = [System.InvalidOperationException]::new("Вивантаження версії $Version не вдалося: ПЛАТФОРМА-ВІДПОВІДЬ")
            $ex.Data['KitDumpFailure'] = $true
            $ex.Data['Version'] = $Version
            $ex.Data['PlatformPath'] = $script:Platforms[0].Path
            $ex.Data['Output'] = 'ПЛАТФОРМА-ВІДПОВІДЬ'
            $ex
        }
        $script:Platforms = @(
            [pscustomobject]@{ Version = '8.3.27.1644'; Arch = 'x64'; Path = 'C:\pf\8.3.27.1644\bin\1cv8.exe' }
            [pscustomobject]@{ Version = '8.3.25.1445'; Arch = 'x64'; Path = 'C:\pf\8.3.25.1445\bin\1cv8.exe' }
            [pscustomobject]@{ Version = '8.3.25.1445'; Arch = 'x86'; Path = 'C:\pf86\8.3.25.1445\bin\1cv8.exe' })
    }

    BeforeEach {
        $script:Steps = [System.Collections.Generic.List[string]]::new()
        $script:AltPaths = [System.Collections.Generic.List[string]]::new()
        $script:FailVersion = $null
        Mock -ModuleName sync Get-KitInstalledPlatforms { $script:Platforms }
        Mock -ModuleName sync Get-V8Path {
            param($Version)
            if ($Version) { ($script:Platforms | Where-Object Version -eq $Version | Select-Object -First 1).Path } else { $script:Platforms[0].Path }
        }
        Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34), (New-KitFakeStorageVersion -Version 35)) }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }
        Mock -ModuleName sync Enter-KitStorageBind { $script:Steps.Add('bind'); $false }
        Mock -ModuleName sync Exit-KitStorageBind { }
        Mock -ModuleName sync Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder, $User)
            $script:Steps.Add("checkout:$Version")
            if ($script:FailVersion -eq $Version) { throw (New-DumpFailure -Version $Version) }
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value "<v$Version/>" -Encoding UTF8 -NoNewline
            1
        }
        Mock -ModuleName sync Invoke-KitStorageCheckoutViaPlatform {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder, $WorkDir, $AltV8Path, $User)
            $script:Steps.Add("viaPlatform:$Version")
            $script:AltPaths.Add($AltV8Path)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value "<alt$Version/>" -Encoding UTF8 -NoNewline
            1
        }
    }

    It 'зупинка §4.1: основна платформа не вивантажила v34 — текст із платформою, переліком і двома виходами, дзеркало на v33, worktree прибрано' {
        $repo = New-DumpRepo 'stop41'
        $script:FailVersion = 34
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true }
        $script:SyncError | Should -BeLike '*34*не вивантажує*'
        $script:SyncError | Should -BeLike '*основна платформа 8.3.27.1644 не вивантажує*'
        $script:SyncError | Should -BeLike '*ПЛАТФОРМА-ВІДПОВІДЬ*'
        $script:SyncError | Should -BeLike '*x64: 8.3.27.1644 (основна), 8.3.25.1445*'
        $script:SyncError | Should -BeLike '*x86*8.3.25.1445*'
        $script:SyncError | Should -BeLike '*-DumpPlatform 8.3.25.1445 -ForVersion 34*'
        $script:SyncError | Should -BeLike '*-SkipVersion 34*'
        @($script:SyncError -split "`r?`n" | Where-Object { $_ -like '*-DumpPlatform 8.3.25.1445 -ForVersion 34*' }).Count | Should -Be 1
        @($script:SyncError -split "`r?`n" | Where-Object { $_ -like '*-DumpPlatform 8.3.27.1644*' }).Count | Should -Be 0
        $script:SyncError | Should -BeLike '*лишається на версії 33*'
        @(git -C $repo log --format=%H storage/base).Count | Should -Be 1
        Get-Trailer -Repo $repo -Sha 'storage/base' -Key 'Storage-Version' | Should -Be '33'
        Join-Path $repo 'build/sync/base/wt' | Should -Not -Exist
        $script:Steps | Should -Not -Contain 'checkout:35'
    }

    It 'зупинка §4.1 без інших платформ — замість команд -DumpPlatform пояснення; -SkipVersion лишається' {
        $repo = New-DumpRepo 'stop41-alone'
        $script:FailVersion = 34
        # Одна платформа — скаляр без обгортки-масиву (так і повертає Get-KitInstalledPlatforms).
        Mock -ModuleName sync Get-KitInstalledPlatforms { $script:Platforms[0] }
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true }
        $script:SyncError | Should -BeLike '*Інших платформ в оточенні немає*'
        $script:SyncError | Should -Not -BeLike '*-DumpPlatform*'
        $script:SyncError | Should -BeLike '*-SkipVersion 34*'
    }

    It '§6.2: пропуск v34 активний, коміту ще не було, v35 падає — «не підтримується», дзеркало на v33, стандартних команд для v35 немає' {
        $repo = New-DumpRepo 'skip-then-fail'
        $script:FailVersion = 35
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34 }
        $script:SyncError | Should -BeLike '*не вивантажує*'
        $script:SyncError | Should -BeLike '*ПЛАТФОРМА-ВІДПОВІДЬ*'
        $script:SyncError | Should -BeLike '*x86*8.3.25.1445*'
        $script:SyncError | Should -BeLike '*у 1.3.1 не підтримується*'
        $script:SyncError | Should -BeLike '*лишилось на версії 33*'
        $script:SyncError | Should -Not -BeLike '*-ForVersion 35*'
        $script:SyncError | Should -Not -BeLike '*-SkipVersion 35*'
        @(git -C $repo log --format=%H storage/base).Count | Should -Be 1
        Get-Trailer -Repo $repo -Sha 'storage/base' -Key 'Storage-Version' | Should -Be '33'
    }

    It '§6.2, суміжний випадок: -DumpPlatform … -ForVersion 34 закомітила v34, v35 падає — стандартні команди для v35' {
        $repo = New-DumpRepo 'dump-then-fail'
        $script:FailVersion = 35
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; DumpPlatform = '8.3.25.1445'; ForVersion = 34 }
        @(git -C $repo log --format=%H storage/base).Count | Should -Be 2
        Get-Trailer -Repo $repo -Sha 'storage/base' -Key 'Storage-Version' | Should -Be '34'
        $script:SyncError | Should -BeLike '*-DumpPlatform 8.3.25.1445 -ForVersion 35*'
        $script:SyncError | Should -BeLike '*-SkipVersion 35*'
        $script:SyncError | Should -Not -BeLike '*не підтримується*'
    }

    It '§6.2: пропуск v34 уже ліг у коміт v35, v36 падає — стандартні команди для v36 (гілка лише «ще не закомічено»)' {
        $repo = New-DumpRepo 'skip-commit-then-fail'
        Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34), (New-KitFakeStorageVersion -Version 35), (New-KitFakeStorageVersion -Version 36)) }
        $script:FailVersion = 36
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34 }
        $script:SyncError | Should -BeLike '*-ForVersion 36*'
        $script:SyncError | Should -Not -BeLike '*не підтримується*'
        Get-Trailer -Repo $repo -Sha 'storage/base' -Key 'Storage-Skipped' | Should -Be '34'
    }

    It 'зупинка §4.1, коли перелік платформ недоступний — відповідь платформи й вихід -SkipVersion все одно в тексті' {
        $repo = New-DumpRepo 'stop41-nolist'
        $script:FailVersion = 34
        Mock -ModuleName sync Get-KitInstalledPlatforms { throw 'ПЕРЕЛІК-ЗЛАМАНО' }
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true }
        $script:SyncError | Should -BeLike '*не вивантажує*'
        $script:SyncError | Should -BeLike '*ПЛАТФОРМА-ВІДПОВІДЬ*'
        $script:SyncError | Should -BeLike '*(перелік платформ недоступний: ПЕРЕЛІК-ЗЛАМАНО)*'
        $script:SyncError | Should -BeLike '*-SkipVersion 34*'
        $script:SyncError | Should -Not -BeLike '*Інших платформ в оточенні немає*'
    }

    It '-SkipVersion 34: пропущена версія не потребує автора — невідомий автор v34 не зупиняє, коміт v35 є' {
        $repo = New-DumpRepo 'skip-unattributed'
        Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34 -User 'stranger'), (New-KitFakeStorageVersion -Version 35)) }
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34 }
        $script:SyncError | Should -BeNullOrEmpty
        $shas = @(git -C $repo log --reverse --format=%H storage/base)
        $shas.Count | Should -Be 2
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Version' | Should -Be '35'
    }

    It '-DumpPlatform 8.3.25.1445 -ForVersion 34 -Apply: v34 — через обрану платформу (x64), v35 — основною; трейлер лише в v34' {
        $repo = New-DumpRepo 'dump-for'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; DumpPlatform = '8.3.25.1445'; ForVersion = 34 }
        $script:SyncError | Should -BeNullOrEmpty
        @($script:Steps | Where-Object { $_ -ne 'bind' }) | Should -Be @('viaPlatform:34', 'checkout:35')
        $script:AltPaths.Count | Should -Be 1
        $script:AltPaths[0] | Should -Be 'C:\pf\8.3.25.1445\bin\1cv8.exe'
        $shas = @(git -C $repo log --reverse --format=%H storage/base)
        $shas.Count | Should -Be 3
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Dump-Platform' | Should -Be '8.3.25.1445'
        Get-Trailer -Repo $repo -Sha $shas[2] -Key 'Storage-Dump-Platform' | Should -BeNullOrEmpty
        (git -C $repo log -1 --format=%B $shas[1]) -join "`n" | Should -BeLike '*основна платформа 8.3.27.1644 цю версію не вивантажує*'
        $script:SyncResult.Synced[0].DumpedVia | Should -Be '8.3.25.1445'
    }

    It '-SkipVersion 34 -Apply: коміту v34 немає, v35 несе Storage-Skipped: 34, платформа для v34 не кликалась' {
        $repo = New-DumpRepo 'skip'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34 }
        $script:SyncError | Should -BeNullOrEmpty
        $script:Steps | Should -Not -Contain 'checkout:34'
        $shas = @(git -C $repo log --reverse --format=%H storage/base)
        $shas.Count | Should -Be 2
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Version' | Should -Be '35'
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Skipped' | Should -Be '34'
        @(git -C $repo log --format=%B storage/base | Where-Object { $_ -match '^Storage-Version: 34$' }).Count | Should -Be 0
        @($script:SyncResult.Synced[0].Skipped) | Should -Be @(34)
        $script:SyncResult.Synced[0].DumpedVia | Should -BeNullOrEmpty
    }

    It '-SkipVersion 35 (не перша неперенесена) — зупинка до будь-якої платформної дії' {
        $repo = New-DumpRepo 'skip-not-first'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 35 }
        $script:SyncError | Should -BeLike '*-SkipVersion 35*не перша неперенесена версія*34*'
        $script:Steps.Count | Should -Be 0
        Should -Invoke -ModuleName sync Enter-KitStorageBind -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckout -Times 0 -Exactly -Scope It
    }

    It '-SkipVersion 34, у звіті лише v34 — зупинка «дочекайтесь», платформа для оновлення не кликалась' {
        $repo = New-DumpRepo 'skip-last'
        Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34)) }
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34 }
        $script:SyncError | Should -BeLike '*версія після 34*дочекайтесь*'
        $script:Steps.Count | Should -Be 0
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckout -Times 0 -Exactly -Scope It
    }

    It '-ForVersion 35 -DumpPlatform … (не перша неперенесена) — зупинка до UpdateCfg' {
        $repo = New-DumpRepo 'for-not-first'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; DumpPlatform = '8.3.25.1445'; ForVersion = 35 }
        $script:SyncError | Should -BeLike '*-ForVersion 35*не перша неперенесена версія*34*'
        $script:Steps.Count | Should -Be 0
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckoutViaPlatform -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckout -Times 0 -Exactly -Scope It
    }

    It '-DumpPlatform, якої немає в оточенні — зупинка з переліком, звіт не будувався' {
        $repo = New-DumpRepo 'no-such-platform'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; DumpPlatform = '8.3.20.1'; ForVersion = 34 }
        $script:SyncError | Should -BeLike '*8.3.20.1 в оточенні немає*'
        $script:SyncError | Should -BeLike '*x64: 8.3.27.1644 (основна), 8.3.25.1445*'
        $script:SyncError | Should -BeLike '*x86: 8.3.25.1445*'
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly -Scope It
    }

    It '-DumpPlatform = основна платформа — зупинка «це і є основна платформа», звіт не будувався' {
        $repo = New-DumpRepo 'dump-is-main'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; DumpPlatform = '8.3.27.1644'; ForVersion = 34 }
        $script:SyncError | Should -BeLike '*це і є основна платформа*'
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly -Scope It
    }

    It 'комбінації параметрів — зупинка на вході: <Name>' -ForEach @(
        @{ Name = '-DumpPlatform без -ForVersion'; Params = @{ Source = 'base'; DumpPlatform = '8.3.25.1445' }; Like = '*лише разом*' }
        @{ Name = '-ForVersion без -DumpPlatform'; Params = @{ Source = 'base'; ForVersion = 34 }; Like = '*лише разом*' }
        @{ Name = '-SkipVersion разом із -DumpPlatform/-ForVersion'; Params = @{ Source = 'base'; SkipVersion = 34; DumpPlatform = '8.3.25.1445'; ForVersion = 34 }; Like = '*взаємовиключні*' }
        @{ Name = '-SkipVersion без -Source'; Params = @{ SkipVersion = 34 }; Like = '*вкажіть -Source*' }
        @{ Name = '-DumpPlatform/-ForVersion без -Source'; Params = @{ DumpPlatform = '8.3.25.1445'; ForVersion = 34 }; Like = '*вкажіть -Source*' }
        @{ Name = '-SkipVersion 0'; Params = @{ Source = 'base'; SkipVersion = 0 }; Like = '*-SkipVersion*додатним*' }
        @{ Name = '-ForVersion 0'; Params = @{ Source = 'base'; DumpPlatform = '8.3.25.1445'; ForVersion = 0 }; Like = '*-ForVersion*додатним*' }
    ) {
        $repo = New-DumpRepo ('combo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = Invoke-DumpSync -Repo $repo -Params $Params
        $script:SyncError | Should -BeLike $Like
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly -Scope It
        $script:Steps.Count | Should -Be 0
    }

    It '-DumpPlatform для розширення — зупинка «не підтримується в 1.3.1», звіт не будувався' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-dump') -WithHooks -WithGitignore -WithAgentBase
        $sd = Join-Path $TestDrive 'ext-dump-storage'; New-Item -ItemType Directory -Path $sd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$sd'") -join "`n")
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'Alpha_SMB'; Apply = $true; DumpPlatform = '8.3.25.1445'; ForVersion = 34 }
        $script:SyncError | Should -BeLike '*не підтримується в 1.3.1*'
        Should -Invoke -ModuleName sync Get-StorageVersions -Times 0 -Exactly -Scope It
    }

    It 'прев''ю -DumpPlatform … -ForVersion 34: у переліку «платформою 8.3.25.1445» лише біля v34; обрана платформа не кликається' {
        $repo = New-DumpRepo 'preview-for'
        $text = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; DumpPlatform = '8.3.25.1445'; ForVersion = 34 }
        $script:SyncError | Should -BeNullOrEmpty
        $lines = @($text -split "`r?`n")
        @($lines | Where-Object { $_ -match 'v34 ' -and $_ -like '*платформою 8.3.25.1445*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'v35 ' -and $_ -like '*платформою*' }).Count | Should -Be 0
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckoutViaPlatform -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckout -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName sync Get-V8Path -Times 1 -Exactly -Scope It
    }

    It 'прев''ю -SkipVersion 34: v34 позначено «буде пропущено», платформа не кликається' {
        $repo = New-DumpRepo 'preview-skip'
        $text = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; SkipVersion = 34 }
        $script:SyncError | Should -BeNullOrEmpty
        $lines = @($text -split "`r?`n")
        @($lines | Where-Object { $_ -match 'v34 ' -and $_ -like '*буде пропущено*' }).Count | Should -Be 1
        $script:Steps.Count | Should -Be 0
    }

    It '-SkipVersion 34 -MaxVersions 1: пропущена версія не рахується — коміт рівно v35, v36 лишається' {
        $repo = New-DumpRepo 'skip-max'
        Mock -ModuleName sync Get-StorageVersions { , @((New-KitFakeStorageVersion -Version 34), (New-KitFakeStorageVersion -Version 35), (New-KitFakeStorageVersion -Version 36)) }
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true; SkipVersion = 34; MaxVersions = 1 }
        $script:SyncError | Should -BeNullOrEmpty
        $shas = @(git -C $repo log --reverse --format=%H storage/base)
        $shas.Count | Should -Be 2
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Version' | Should -Be '35'
        Get-Trailer -Repo $repo -Sha $shas[1] -Key 'Storage-Skipped' | Should -Be '34'
        @($script:Steps | Where-Object { $_ -like 'checkout:*' }) | Should -Be @('checkout:35')
    }

    It 'щасливий шлях без нових параметрів: ні Get-V8Path, ні Get-KitInstalledPlatforms не кликаються' {
        $repo = New-DumpRepo 'plain'
        $null = Invoke-DumpSync -Repo $repo -Params @{ Source = 'base'; Apply = $true }
        $script:SyncError | Should -BeNullOrEmpty
        @($script:Steps | Where-Object { $_ -like 'checkout:*' }) | Should -Be @('checkout:34', 'checkout:35')
        Should -Invoke -ModuleName sync Get-V8Path -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName sync Get-KitInstalledPlatforms -Times 0 -Exactly -Scope It
        $script:SyncResult.Synced[0].DumpedVia | Should -BeNullOrEmpty
        @($script:SyncResult.Synced[0].Skipped).Count | Should -Be 0
    }
}
