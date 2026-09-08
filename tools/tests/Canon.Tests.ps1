#Requires -Version 7
Describe 'kit canon — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Canon { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }

    It 'прев''ю: розширення канонізується, vendor пропускається з поясненням' {
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*'
        $r.Output | Should -BeLike '*base*vendor*пропущен*'
        $r.Output | Should -BeLike '*-Apply*'
    }

    It 'бази агента ще немає — -Apply зупиняється до платформи з підказкою provision; дерево ціле' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-base') -WithHooks
        $r = Invoke-Canon -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*provision*'
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }

    It 'база агента = база людини з накладки — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'" -WithHooks
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
        $r = Invoke-Canon -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*людини*'
    }

    It 'воркспейс лише з зовнішніми обробками — нічого канонізувати, код 0' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }
}

Describe 'kit canon — мок платформного шару: лічильник Changed рахує кілька змінених файлів (P6)' {
    # Знахідка префлайту B4 (P6): `git status --porcelain -z` дає NUL-роздільник записів,
    # а PowerShell ділить вивід нативної команди по \n — увесь вивід приходить ОДНИМ рядком,
    # тож наївний @(... | Where-Object {...}).Count завжди дає 1 (чи 0) незалежно від
    # справжньої кількості змінених файлів. Тест — без платформи (Invoke-V8Designer
    # замокано; зміни у файлах робить сам мок через Set-Content, а не /DumpConfigToFiles) і
    # ловить САМЕ цей дефект: якщо вирізати правильне розбиття по "`0" і повернути наївний
    # підрахунок, тест впаде, бо коміт нижче лишає дерево З ОДНИМ уже відстеженим файлом
    # (Configuration.xml), а мок дописує до нього ще два — Changed мусить бути 3, не 1.
    #
    # Прийом узятий з Dump.Tests.ps1 ("мок платформного шару"): лаб-модулі в порядку
    # module-order.txt, потім САМЕ commands/canon.psm1 у ЦЬОМУ процесі (не підпроцесом
    # kit.ps1) — лише так Mock -ModuleName бачить приватний стіл команд canon.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/canon.psm1").Path -Force
    }

    It 'три файли, змінені мокованим "DumpConfigToFiles" — Changed = 3, не 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-count') -WithHooks
        # Дерево EXTENSION уже в git (Configuration.xml, комітнутий фікстурою). "База
        # агента" мусить виглядати як наявна (Kind=file, Exists перевіряє 1Cv8.1CD) —
        # той самий прийом, що в Provision.Tests.ps1 ("база вже є").
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                $dir = $Matches.p
                # Configuration.xml замінює вже відстежений файл (M); Two.xml і Three.xml —
                # нові (??). Разом три записи в git status --porcelain -z.
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value 'нова версія' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Two.xml') -Value 'два' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Three.xml') -Value 'три' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true

        $result.ExitCode | Should -Be 0
        $result.Canonized.Count | Should -Be 1
        $result.Canonized[0].Files | Should -Be 3
        $result.Canonized[0].Changed | Should -Be 3
        $result.Canonized[0].Changed | Should -BeGreaterThan 1
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1
    }
}

Describe 'kit canon — round-trip дає нуль розбіжностей на канонічному дереві' -Tag Integration {
    # Порожня база агента + стаб розширення: канонічне дерево — те, що платформа сама віддала.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rt') -WithHooks -WithGitattributes -WithGitignore
        # база агента зі стабом Alpha_SMB (як робив би operation=build)
        $ib = New-ExtensionInfobase -Path (Join-Path $script:Repo 'Alpha_SMB/build/ib') -ExtensionName 'Alpha_SMB' `
            -StubPath (Resolve-Path "$PSScriptRoot/../assets/empty-extension").Path -MustBeUnder (Join-Path $script:Repo 'Alpha_SMB')
    }
    It 'перший canon переписує дерево платформою; другий не змінює жодного файла' {
        $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'канонічне дерево'
        $out2 = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out2
        (git -C $script:Repo status --porcelain -- Alpha_SMB/cfe/src) | Should -BeNullOrEmpty
        $out2 | Should -BeLike '*змінено файлів: 0*'
    }
}
