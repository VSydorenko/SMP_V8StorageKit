#Requires -Version 7
Describe 'Preflight.psm1 — контекст команди з маніфесту, накладки й v8project.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'типовий репозиторій: один воркспейс, два джерела, усе розв''язано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ok')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ctx.Ok | Should -BeTrue
        $ctx.Kind | Should -Be 'product'
        $ctx.MainBranch | Should -Be 'main'
        $ctx.Overlay | Should -BeNullOrEmpty
        $ctx.Workspaces.Count | Should -Be 1

        $ws = $ctx.Workspaces[0]
        $ws.Path | Should -Be 'Alpha_SMB'
        $ws.Project.SourceSets.Count | Should -Be 2

        $ext = $ws.Sources | Where-Object Key -eq 'Alpha_SMB'
        $ext.Truth | Should -Be 'storage'
        $ext.Type | Should -Be 'EXTENSION'
        $ext.Path | Should -Be 'cfe/src'
        $ext.RepoPath | Should -Be 'Alpha_SMB/cfe/src'
        $ext.FullPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/cfe/src')))
        $ext.Branch | Should -Be 'storage/Alpha_SMB'
        $ext.StorageUser | Should -Be 'gitbot'

        $base = $ws.Sources | Where-Object Key -eq 'base'
        $base.Truth | Should -Be 'vendor'
        $base.Type | Should -Be 'CONFIGURATION'
        $base.DumpFrom | Should -Be 'dev'
        $base.Branch | Should -BeNullOrEmpty
    }

    It 'накладка перевизначає шлях сховища для цієї машини' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay') -OverlayText "storages:`n  Alpha_SMB: 'D:\mirror\alpha'"
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ctx.OverlayPath | Should -BeLike '*v8storagekit.local.yaml'
        ($ctx.Workspaces[0].Sources | Where-Object Key -eq 'Alpha_SMB').StoragePath | Should -Be 'D:\mirror\alpha'
    }

    It 'накладка перекриває користувача й пароль сховища, не чіпаючи шляху; пароль типово порожній' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-cred') -OverlayText "storages:`n  Alpha_SMB: { user: 'Сидоренко', password: 'secret' }"
        $src = (Invoke-KitPreflight -RepoRoot $repo).Workspaces[0].Sources | Where-Object Key -eq 'Alpha_SMB'
        $src.StoragePath | Should -BeLike '*no-such-storage-Alpha_SMB'
        $src.StorageUser | Should -Be 'Сидоренко'
        $src.StoragePassword | Should -Be 'secret'
        $plain = (Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'no-cred'))).Workspaces[0].Sources | Where-Object Key -eq 'Alpha_SMB'
        $plain.StorageUser | Should -Be 'gitbot'; $plain.StoragePassword | Should -Be ''
    }

    It 'без маніфесту — зупинка з підказкою на onboarding; у -Lenient — знахідка, а не виняток' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-manifest')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*v8storagekit.yaml*onboarding*'
        # "з теки плагіна" саме собою не каже, де та тека.
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*claude plugin list*'

        $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 1
        $ctx.Findings[0].Message | Should -BeLike '*v8storagekit.yaml*'
    }

    It 'без маніфесту, але з DT-INF/ (EDT-формат) — зупинка з вказівкою на convert раннера; у -Lenient — знахідка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'edt-no-manifest')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'cf/DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*формат*EDT*cf/DT-INF*convert*'
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
        $ctx.Ok | Should -BeFalse
        $ctx.Findings[0].Message | Should -BeLike '*cf/DT-INF*convert*'
    }

    It 'воркспейс із маніфесту без теки — зупинка з його ім''ям' {
        $text = "version: 1`nproduct: Fake`nworkspaces:`n  - path: Ghost`n    sources:`n      g: { truth: git }"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ghost') -ManifestText $text
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw "*'Ghost'*"
    }

    It 'воркспейс без v8project.yaml — зупинка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-project')
        Remove-Item -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml')
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*Alpha_SMB*v8project.yaml*'
    }

    It 'ключ sources, якого немає серед name: source-set-ів — зупинка з переліком наявних' {
        $text = @(
            'version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            "      Alpha_SMB_typo: { truth: storage, storage: { path: 'C:\x' } }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-key') -ManifestText $text
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw "*не відповідає жодному name: source-set*base, Alpha_SMB*"
    }

    It '-Lenient збирає ВСІ проблеми, а не першу' {
        $text = @(
            'version: 1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:', "      nope: { truth: git }",
            '  - path: Ghost',     '    sources:', "      g: { truth: git }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'lenient') -ManifestText $text
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 2
    }

    It '-Mode Check: kitVersion — знахідка kit-version, решта розбирається; Lenient і Strict на ньому зупиняються' {
        $text = "version: 1`nkitVersion: 1.0.1`nproduct: Fake`nworkspaces:`n  - path: Alpha_SMB`n    sources:`n      nope: { truth: git }"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'kitversion') -ManifestText $text
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Check
        $ctx.Ok | Should -BeFalse
        # Маніфест розібрано (Kind заповнено), а друга проблема (ключ sources) теж у знахідках.
        $ctx.Kind | Should -Be 'product'
        @($ctx.Findings | Where-Object Check -eq 'kit-version').Count | Should -Be 1
        @($ctx.Findings | Where-Object Check -eq 'source').Count | Should -Be 1
        $ctx.Findings[0].Message | Should -BeLike '*kitVersion*kit.profile.json*'
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*kitVersion прибрано*'
        $len = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
        $len.Kind | Should -BeNullOrEmpty
        @($len.Findings | Where-Object Check -eq 'manifest').Count | Should -Be 1
    }

    Context 'Select-KitSources' {
        BeforeAll {
            $two = [ordered]@{
                'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
                    @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
                'Alpha_ACC' = @{ Infobase = 'File=build/ib'; Sets = @(
                    @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_ACC'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
                'epf'       = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
            }
            $script:Ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'select') -Workspaces $two)
        }

        It 'без фільтрів — усі джерела всіх воркспейсів' {
            @(Select-KitSources -Context $script:Ctx).Count | Should -Be 5
        }
        It '-Truth звужує' {
            @(Select-KitSources -Context $script:Ctx -Truth storage).Key | Should -Be @('Alpha_SMB', 'Alpha_ACC')
        }
        It '-Workspace невідомий — зупинка з переліком' {
            { Select-KitSources -Context $script:Ctx -Workspace 'Beta' } | Should -Throw "*'Beta'*Alpha_SMB, Alpha_ACC, epf*"
        }
        It '-Source унікальний — без -Workspace знаходиться' {
            (Select-KitSources -Context $script:Ctx -Source 'Alpha_ACC').Workspace | Should -Be 'Alpha_ACC'
        }
        It '-Source у двох воркспейсах без -Workspace — зупинка, яка їх називає (Q9)' {
            { Select-KitSources -Context $script:Ctx -Source 'base' } | Should -Throw '*base*Alpha_SMB*Alpha_ACC*-Workspace*'
        }
        It '-Source із -Workspace — однозначно' {
            (Select-KitSources -Context $script:Ctx -Workspace 'Alpha_ACC' -Source 'base').RepoPath | Should -Be 'Alpha_ACC/cf/src'
        }
        It '-Source невідомий — зупинка' {
            { Select-KitSources -Context $script:Ctx -Source 'Nope' } | Should -Throw "*'Nope'*"
        }
    }
}
