#Requires -Version 7
Describe 'kit sync — крок вирівнювання пам''яті раннера (спека §4.1, §10 П3)' {
    # У процесі, з моком платформи — той самий прийом, що Sync.Merge.Tests.ps1 (див. шапку там):
    # Invoke-V8Designer — за -ModuleName StoragePlatform, Get-StorageVersions — за -ModuleName sync.
    # Мок /DumpConfigToFiles пише той самий Configuration.xml, що фікстура, — дзеркало й main мають
    # однакове дерево набору, і критерій виконується лише там, де мусить.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force
        function script:New-KitFakeStorageVersion { param([int]$Version)
            [pscustomobject]@{ Version = $Version; User = 'gitbot'; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = 'версія'; Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-01T09:00:00' } }
        function script:New-AlignRepo { param([string]$Name)
            # -WithGitignore обов'язковий: без нього невідстежувані v8storagekit.local.yaml і build/
            # роблять копію брудною, злиття в main відмовляє, і тест «pull» червоніє за будь-якої
            # реалізації (аудит Tasks 7–11).
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

    It 'перший sync, HEAD = main, дзеркало злито, дерево рівне й чисте — pull (з extension для розширення)' {
        $repo = New-AlignRepo -Name 'first'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.ExitCode | Should -Be 0
        $r.Synced[0].MergedIntoMain | Should -BeTrue
        @($r.AlignSteps) | Should -HaveCount 1
        $r.AlignSteps[0].Op | Should -Be 'pull'
        $r.AlignSteps[0].Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"Alpha_SMB","extension":"Alpha_SMB","force":true},"dryRun":true}'
        # Той самий крок — і в елементі Synced (споживачі читають його звідти, не з AlignSteps).
        $r.Synced[0].AlignStep.Op | Should -Be 'pull'
    }
    It 'серверна база агента — push force, хоча дерево рівне й чисте (§4.1, #184)' {
        $repo = New-AlignRepo -Name 'server'
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].BaseKind | Should -Be 'server'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'остання версія вивантажена -DumpPlatform — push force, не pull' {
        # -DumpPlatform — лише для CONFIGURATION (sync відмовляє для розширення), тож набір — основна
        # конфігурація truth: storage. Вміст мока збігається з фікстурою, щоб за звичайної платформи
        # критерій виконався і крок був би pull — тоді push доводить саме гілку -DumpPlatform.
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'
            Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'altplat') -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore
        $storageDir = Join-Path $TestDrive 'altplat-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")
        $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
        Mock -ModuleName sync Get-KitInstalledPlatforms { @([pscustomobject]@{ Version = '8.3.24.1000'; Arch = 'x64'; Path = 'C:\alt\1cv8.exe' }) }
        Mock -ModuleName sync Get-V8Path { 'C:\alt\1cv8.exe' }
        Mock -ModuleName sync Invoke-KitStorageCheckoutViaPlatform {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1 }
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -Source 'base' -ForVersion 7 -DumpPlatform '8.3.24.1000'
        # Доказ, що мок перехопив вивантаження альтернативною платформою (інакше пішов би справжній 1cv8.exe).
        Should -Invoke -ModuleName sync Invoke-KitStorageCheckoutViaPlatform -Times 1 -Exactly -Scope It
        $r.Synced[0].DumpedVia | Should -Be '8.3.24.1000'
        $r.AlignSteps[0].Op | Should -Be 'push'
    }
    It 'гілка задачі з власною зміною набору — push force' {
        $repo = New-AlignRepo -Name 'task'
        git -C $repo checkout -q -b feature/x
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Value '<!-- робота агента -->'
        git -C $repo commit -qam 'робота агента'
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].Op | Should -Be 'push'
        $r.AlignSteps[0].Steps[0] | Should -BeLike '*"op":"push"*"force":true*'
    }
    It 'невідстежуваний файл у наборі — злиття відмовляє, крок push (не pull, Review Focus 3)' {
        $repo = New-AlignRepo -Name 'dirty'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Новая.xml') -Value 'x' -Encoding UTF8
        $r = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.AlignSteps[0].Op | Should -Be 'push'
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
            BaseKind = 'file'; Op = 'blocked'; Supply = 'missing'; MarkerOnly = $false; Steps = @(); Recipe = 'рецепт' } }
        $repo = New-AlignRepo -Name 'blocked'
        $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines[-1] | Should -BeLike 'ЗУПИНКА:*'
        $text | Should -Not -BeLike '*Готово.*'
    }

    Context 'виняток функцій критерію — запасний крок, не зупинка (спека 3129c0d, П24)' {
        # Вхід, на якому Assert-KitCriterionInput кидає ВИНЯТОК: Context.RepoRoot — junction на
        # репозиторій. git rev-parse --show-toplevel віддає справжній шлях, і він не збігається з
        # RepoRoot ('не є коренем репозиторію'). До цього місця sync уже переніс версії й злив гілки
        # (git через junction працює), тож виняток виникає саме там, де Step 6а його й вимагає.
        BeforeAll {
            function script:New-JunctionContext { param([string]$Repo, [string]$Name)
                $link = Join-Path $TestDrive $Name
                New-Item -ItemType Junction -Path $link -Target $Repo | Out-Null
                $link }
            function script:Remove-Junction { param([string]$Link)
                # Лише сам перехід — вміст репозиторію не чіпаємо.
                if (Test-Path -LiteralPath $Link) { [System.IO.Directory]::Delete($Link) } }
        }

        It 'виняток критерію — надруковано push force, рядок «критерій не обчислено», код виходу як без винятку' {
            $control = New-AlignRepo -Name 'exc-control'
            $rc = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $control) -Apply $true

            $repo = New-AlignRepo -Name 'exc-ext'
            $link = New-JunctionContext -Repo $repo -Name 'exc-ext-link'
            try {
                $h = @{}
                $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $link) -Apply $true } 6>&1 | Out-String
            } finally { Remove-Junction -Link $link }
            $r = $h.R
            $text | Should -BeLike '*критерій не обчислено: *'
            $text | Should -BeLike '*не є коренем репозиторію*'
            $r.AlignSteps[0].Op | Should -Be 'push'
            $r.AlignSteps[0].Steps[0] | Should -BeLike '*"op":"push"*"force":true*'
            $text | Should -BeLike '*"op":"push"*"force":true*'
            $r.ExitCode | Should -Be $rc.ExitCode
            # Версії таки перенесено — виняток не скасував роботу, що вже була зроблена.
            $r.Synced[0].Versions | Should -Be @(7)
        }
        It 'той самий вхід із поставкою missing — blocked, ЗУПИНКА останньою' {
            $script:MockContent = New-KitFakeConfigurationXml -Name 'base'
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'
                Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'exc-cfg') -Workspaces $ws -WithHooks -WithAgentBase -WithGitignore -WithSupply
            $storageDir = Join-Path $TestDrive 'exc-cfg-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  base: '$storageDir'") -join "`n")
            # Поставка «missing»: .bin на місці, .cf зник.
            Remove-Item -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Recurse -Force
            (Get-KitSupplyState -TreeRoot (Join-Path $repo 'Alpha_SMB/cf/src')) | Should -Be 'missing'
            $link = New-JunctionContext -Repo $repo -Name 'exc-cfg-link'
            try {
                $h = @{}
                $text = & { $h.R = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $link) -Apply $true } 6>&1 | Out-String
            } finally { Remove-Junction -Link $link }
            $r = $h.R
            $text | Should -BeLike '*критерій не обчислено: *'
            $r.AlignSteps[0].Op | Should -Be 'blocked'
            $r.ExitCode | Should -Be 0
            $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
            $lines[-1] | Should -BeLike 'ЗУПИНКА:*'
            $text | Should -Not -BeLike '*Готово.*'
        }
        It 'без винятку рядка «критерій не обчислено» немає' {
            $repo = New-AlignRepo -Name 'exc-none'
            $text = & { $null = Invoke-KitSync -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } 6>&1 | Out-String
            $text | Should -Not -BeLike '*критерій не обчислено*'
        }
    }

    Context 'стан поставки не обчислено і виняток у пізнішому джерелі (спека 0174871)' {
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
                BaseKind = 'file'; Op = 'blocked'; Supply = 'missing'; MarkerOnly = $false; Steps = @(); Recipe = 'рецепт першого' } }
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
