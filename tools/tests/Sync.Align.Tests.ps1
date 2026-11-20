#Requires -Version 7
Describe 'kit sync — крок вирівнювання пам''яті раннера' {
    # У процесі, з моком платформи — той самий прийом, що Sync.Merge.Tests.ps1 (див. шапку там):
    # Invoke-V8Designer — за -ModuleName StoragePlatform, Get-StorageVersions — за -ModuleName sync.
    # Мок /DumpConfigToFiles пише Configuration.xml, як фікстура. Крок після sync — завжди push force
    # (критерію рівності дерев немає), тож вміст дампу на крок не впливає.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force
        # Раннер Уніки — не справжній: платформу воркспейсу і agent release командою sync/verify беруть із цих моків
        # (Get-KitRunnerPath шукав би Уніку на машині, Get-KitAgentPlatform/Invoke-KitAgentRelease запускали б справжній v8-runner).
        Mock -ModuleName sync Get-KitRunnerPath { 'C:\fake\v8-runner.exe' }
        Mock -ModuleName sync Get-KitAgentPlatform { 'C:\fake\8.3.27.9999\bin\1cv8.exe' }
        Mock -ModuleName sync Invoke-KitAgentRelease { [pscustomobject]@{ released = $false; disconnected = $false } }
        function script:New-KitFakeStorageVersion { param([int]$Version)
            [pscustomobject]@{ Version = $Version; User = 'gitbot'; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = 'версія'; Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-01T09:00:00' } }
        function script:New-AlignRepo { param([string]$Name)
            # -WithGitignore обов'язковий: без нього невідстежувані v8storagekit.local.yaml і build/
            # роблять копію брудною, злиття в main відмовляє, і тест «pull» червоніє за будь-якої
            # реалізації.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithAgentBase -WithGitignore
            $storageDir = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            $repo }
    }
    BeforeEach {
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Mock -ModuleName StoragePlatform Invoke-V8Designer {
            $line = $Arguments -join ' '
            if ($line -match '/DumpConfigToFiles "(?<t>[^"]+)"') {
                New-Item -ItemType Directory -Path $Matches['t'] -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Matches['t'] 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7) }
    }

    It 'Два зрушені набори (CONFIGURATION без поставки + EXTENSION) — рівно два рядки push, по одному на набір, з force:true, без extension і без pull' {
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'two-push') -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore
        $d1 = Join-Path $TestDrive 'two-push-s1'; $d2 = Join-Path $TestDrive 'two-push-s2'
        New-Item -ItemType Directory -Path $d1, $d2 -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$d1'", "  Alpha_SMB: '$d2'") -join "`n")
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7) }
        $h = @{}
        $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $lines = @($text -split "`r?`n" | Where-Object { $_ -like '*unica.run {"op":"push"*' })
        $lines | Should -HaveCount 2
        $lines[0] | Should -BeLike '*"sourceSet":"base"*'
        $lines[1] | Should -BeLike '*"sourceSet":"Alpha_SMB"*'
        foreach ($l in $lines) {
            $l | Should -BeLike '*"force":true*'
            $l | Should -Not -BeLike '*"extension"*' -Because 'push Уніки приймає лише sourceSet/full/force/noApply'
        }
        $text | Should -Not -BeLike '*"op":"pull"*'
        @($h.R.AlignSteps) | Should -HaveCount 2
        $h.R.AlignSteps.Op | Should -Not -Contain 'blocked'
    }
    It 'виняток після успішного оновлення бази (запис версії впав) — крок push усе одно надруковано, виняток летить далі' {
        $repo = New-AlignRepo -Name 'throw-after-shift'
        Mock -ModuleName sync Write-KitStorageVersion { throw 'збій запису версії' }
        $h = @{}
        $text = & {
            try { Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true | Out-Null }
            catch { $h.Err = $_.Exception.Message }
        } 6>&1 | Out-String
        $h.Err | Should -BeLike '*збій запису версії*' -Because 'оригінальний виняток не проковтнуто'
        $lines = @($text -split "`r?`n" | Where-Object { $_ -like '*unica.run {"op":"push"*' })
        $lines | Should -HaveCount 1
        $lines[0] | Should -BeLike '*"sourceSet":"Alpha_SMB"*"force":true*'
        $text | Should -Not -BeLike '*Готово.*'
    }
    It 'злиття відмовило — код виходу 2, підсумок не каже «Готово»' {
        $repo = New-AlignRepo -Name 'merge-fail'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Новая.xml') -Value 'x' -Encoding UTF8
        $h = @{}
        $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $h.R.ExitCode | Should -Be 2
        $text | Should -Not -BeLike '*Готово.*'
        $text | Should -BeLike '*злиття в основну гілку не вдалось*'
    }
    It 'успішний sync закінчується «Готово.», без попереджень про збій злиття' {
        $repo = New-AlignRepo -Name 'done-ok'
        $h = @{}
        $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $h.R.ExitCode | Should -Be 0
        $text | Should -BeLike '*Готово.*'
        $text | Should -Not -BeLike '*не вдалось*'
    }
    It 'нових версій немає, злиття впало — підсумок не каже «Дзеркала оновлено», код виходу 2, кроку немає' {
        $repo = New-AlignRepo -Name 'none-merge-fail'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        Mock -ModuleName sync Invoke-KitMainMerge { $false }
        $h = @{}
        $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -MergeMain } 6>&1 | Out-String
        $h.R.ExitCode | Should -Be 2
        @($h.R.AlignSteps) | Should -HaveCount 0
        $text | Should -BeLike '*Нових версій не було, але злиття в основну гілку не вдалось*'
        $text | Should -Not -BeLike '*Дзеркала оновлено*'
        $text | Should -Not -BeLike '*Готово.*'
    }
    It 'blocked і збій злиття разом — підсумок називає обидва' {
        Mock -ModuleName sync Get-KitAlignStep { [pscustomobject]@{ SourceSet = 'Alpha_SMB'; Workspace = 'Alpha_SMB'; RepoPath = 'Alpha_SMB/cfe/src'
            Op = 'blocked'; Supply = 'missing'; Steps = @(); Recipe = 'рецепт' } }
        Mock -ModuleName sync Invoke-KitMainMerge { $false }
        $repo = New-AlignRepo -Name 'blocked-merge-fail'
        $h = @{}
        $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $h.R.ExitCode | Should -Be 2
        $text | Should -BeLike '*вирівнювання не завершено*Злиття в основну гілку теж не вдалось*'
        $text | Should -Not -BeLike '*Готово.*'
    }
    It 'нових версій немає — кроку немає (база не зрушена)' {
        $repo = New-AlignRepo -Name 'none'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        @($r.AlignSteps) | Should -HaveCount 0
        $r.Synced[0].AlignStep | Should -BeNullOrEmpty
    }
    It 'вивід: крок і контракт стану бази, без слова operation=' {
        $repo = New-AlignRepo -Name 'text'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $text | Should -BeLike "*вирівняти пам'ять раннера для 'Alpha_SMB'*"
        $text | Should -BeLike '*це контракт sync, не збій*'
        $text | Should -Not -BeLike '*operation=*'
    }
    It 'blocked: ЗУПИНКА — останній рядок виводу, підсумок не каже «Готово»' {
        Mock -ModuleName sync Get-KitAlignStep { [pscustomobject]@{ SourceSet = 'Alpha_SMB'; Workspace = 'Alpha_SMB'; RepoPath = 'Alpha_SMB/cfe/src'
            Op = 'blocked'; Supply = 'missing'; Steps = @(); Recipe = 'рецепт' } }
        $repo = New-AlignRepo -Name 'blocked'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines[-1] | Should -BeLike 'ЗУПИНКА:*'
        $text | Should -Not -BeLike '*Готово.*'
    }

    Context 'зупинка поставки: рецепт залежить від гілки' {
        BeforeAll {
            function script:New-SupplyMissingRepo { param([string]$Name)
                $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'
                    Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
                $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore -WithSupply
                $storageDir = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")
                # Поставка «missing»: .bin на місці, .cf зник.
                Remove-Item -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Recurse -Force
                $repo }
        }
        It 'на головній гілці: blocked, рецепт — повний pull і supply-marker, без push; ЗУПИНКА останньою' {
            $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
            $repo = New-SupplyMissingRepo -Name 'sup-main'
            (Get-KitSupplyState -TreeRoot (Join-Path $repo 'Alpha_SMB/cf/src')) | Should -Be 'missing'
            $h = @{}
            $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
            $h.R.AlignSteps[0].Op | Should -Be 'blocked'
            $h.R.AlignSteps[0].Recipe | Should -BeLike '*"op":"pull"*supply-marker -Workspace Alpha_SMB -Source base -Apply*'
            $h.R.AlignSteps[0].Recipe | Should -Not -BeLike '*"op":"push"*'
            $text | Should -Not -BeLike '*unica.run {"op":"push"*'
            @($text -split "`r?`n" | Where-Object { $_.Trim() })[-1] | Should -BeLike 'ЗУПИНКА:*'
            $text | Should -Not -BeLike '*Готово.*'
        }
        It 'виняток після успішного оновлення бази + поставка missing — ЗУПИНКА надрукована останньою, виняток летить далі' {
            $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
            $repo = New-SupplyMissingRepo -Name 'sup-throw'
            Mock -ModuleName sync Write-KitStorageVersion { throw 'збій запису версії' }
            $h = @{}
            $text = & {
                try { Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true | Out-Null }
                catch { $h.Err = $_.Exception.Message }
            } 6>&1 | Out-String
            $h.Err | Should -BeLike '*збій запису версії*'
            $text | Should -Not -BeLike '*unica.run {"op":"push"*'
            @($text -split "`r?`n" | Where-Object { $_.Trim() })[-1] | Should -BeLike 'ЗУПИНКА:*supply-marker*'
        }
        It 'на гілці задачі: blocked, рецепт «спершу поставка на головній гілці», без pull' {
            $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
            $repo = New-SupplyMissingRepo -Name 'sup-task'
            git -C $repo checkout -q -b feature/x
            $h = @{}
            $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
            $h.R.AlignSteps[0].Op | Should -Be 'blocked'
            $h.R.AlignSteps[0].Recipe | Should -BeLike '*спершу поставка на головній гілці*'
            $h.R.AlignSteps[0].Recipe | Should -Not -BeLike '*"op":"pull"*'
            $text | Should -Not -BeLike '*"op":"pull"*'
        }
    }

    Context 'стан поставки не обчислено і виняток у пізнішому джерелі' {
        It 'виняток Get-KitSupplyState після злиття — blocked і рядок «стан поставки не обчислено», не push' {
            $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'
                Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sup-exc') -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore
            $storageDir = Join-Path $TestDrive 'sup-exc-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")
            Mock -ModuleName UnicaStep Get-KitSupplyState { throw 'збій читання поставки' }
            $h = @{}
            $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
            $text | Should -BeLike '*стан поставки не обчислено: збій читання поставки*'
            $h.R.AlignSteps[0].Op | Should -Be 'blocked'
            $h.R.ExitCode | Should -Be 0
            $text | Should -Not -BeLike '*"op":"push"*'
            @($text -split "`r?`n" | Where-Object { $_.Trim() })[-1] | Should -BeLike 'ЗУПИНКА:*'
        }
        It 'виняток у другому джерелі не губить ЗУПИНКА першого — друк у finally, виняток летить далі' {
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
                @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
                @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'two') -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore
            $d1 = Join-Path $TestDrive 'two-s1'; $d2 = Join-Path $TestDrive 'two-s2'
            New-Item -ItemType Directory -Path $d1, $d2 -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$d1'", "  Alpha_SMB: '$d2'") -join "`n")
            Mock -ModuleName sync Get-StorageVersions {
                param($ExtensionName)
                if ($ExtensionName -eq 'Alpha_SMB') { throw 'збій звіту другого джерела' }
                , @(New-KitFakeStorageVersion -Version 7) }
            Mock -ModuleName sync Get-KitAlignStep { [pscustomobject]@{ SourceSet = 'base'; Workspace = 'Alpha_SMB'; RepoPath = 'Alpha_SMB/cf/src'
                Op = 'blocked'; Supply = 'missing'; Steps = @(); Recipe = 'рецепт першого' } }
            $h = @{}
            $text = & {
                try { Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true | Out-Null }
                catch { $h.Err = $_.Exception.Message }
            } 6>&1 | Out-String
            $h.Err | Should -BeLike '*збій звіту другого джерела*'
            $text | Should -BeLike '*ЗУПИНКА: рецепт першого*'
            $text | Should -Not -BeLike '*Готово.*'
        }
    }
}
