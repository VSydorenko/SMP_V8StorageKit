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
        # H3 — "з теки плагіна" саме собою не каже, де та тека.
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*claude plugin list*'

        $ctx = Invoke-KitPreflight -RepoRoot $repo -Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 1
        $ctx.Findings[0].Message | Should -BeLike '*v8storagekit.yaml*'
    }

    # H5 (фінальне рев'ю) — до 0.6.0 конвенція клала storage.json у кожну підтеку продукту;
    # такий репозиторій уже має все, що потрібно маніфесту (шляхи сховищ, імена розширень,
    # дев-бази), просто не в тому файлі. Порада "пишіть v8storagekit.yaml руками" для нього
    # хибна — правильний шлях називає конкретний скіл.
    #
    # Знахідка живого прогону B5, Task 6 (Step 6в): порада називала скіл v8storagekit:migrate
    # і команду kit migrate, яких за чинною спекою (2026-09-03, §9) не буде НІКОЛИ — усі вхідні
    # форми, включно з цією, веде v8storagekit:onboarding. Асерт перецілено на властивість «на
    # репозиторії 0.6.0 порада називає РЕАЛЬНИЙ шлях», а не на слово migrate: та сама перевірка
    # тепер ловила б і регрес назад на неіснуючий migrate, і мовчання (порада без шляху взагалі).
    It 'H5: без маніфесту, але зі storage.json у підтеці — підказка на репозиторій 0.6.0 і v8storagekit:onboarding' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'legacy-no-manifest')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/storage.json') -Value '{}' -Encoding UTF8
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*0.6.0*v8storagekit:onboarding*'
    }

    # Task 2а (task-2-brief.md, знахідка прогону B5) — ознака gitsync-вивантаження: DT-INF/
    # поруч із текою вихідників, БЕЗ storage.json (skills/onboarding/SKILL.md §5, skills/onboarding/references/gitsync-migration.md).
    # Виміряно на живому парку (правка координатора під час цієї задачі): DT-INF/ лежить на
    # РІЗНИХ глибинах — у корені репозиторію, на глибині 1 (усередині підпродукту), і навіть
    # ДВІЧІ в одному репозиторії (окремо cf/ і cfe/). Три тести нижче покривають усі три силуети
    # на СИНТЕТИЧНИХ фікстурах — не на живих репозиторіях парку.
    It 'Task 2а: DT-INF/ У КОРЕНІ репозиторію (без storage.json) — підказка на формат gitsync-вивантаження і onboarding' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-root')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*DT-INF*v8storagekit:onboarding*'
    }

    It 'Task 2а: DT-INF/ на ГЛИБИНІ 1 (усередині підпродукту, без storage.json) — та сама підказка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-depth1')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*DT-INF*v8storagekit:onboarding*'
    }

    It 'Task 2а: ДВА DT-INF в одному репозиторії (cf/ і cfe/) — повідомлення називає ОБИДВА, не лише перший' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-two')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'cf/DT-INF') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'cfe/DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*cf/DT-INF*cfe/DT-INF*'
    }

    It 'Task 2а: DT-INF/ разом зі storage.json (0.6.0) в різних підтеках — 0.6.0 перевіряється першим і виграє' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-vs-legacy')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/storage.json') -Value '{}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $repo 'Other/DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*0.6.0*'
    }

    # Рев'ю Task 2, п. 4 — виміряні силуети парку покривають лише глибину 0 (корінь) і 1
    # (root/X/DT-INF); другий рівень пошуку (root/X/Y/DT-INF) — навмисна страховка з мізерною
    # вартістю (Get-ChildItem -Directory на кожен level1, не рекурсія у вміст), і досі не мав
    # ЖОДНОГО тесту. Не зрізати цикл — закріпити його тестом.
    It 'Task 2а: DT-INF/ на ГЛИБИНІ 2 (root/Продукт/Підтека/DT-INF) — страховий рівень пошуку, підказка та сама' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-depth2')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/cfe/DT-INF') -Force | Out-Null
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw '*DT-INF*v8storagekit:onboarding*'
    }

    # Рев'ю Task 2, п. 7 — усі тести вище кличуть префлайт БЕЗ -Lenient (шлях throw — це шлях
    # sync/verify). Крок задачі зветься «check називає форму репозиторію», а check іде саме
    # через -Lenient, де знахідка має дійти до Findings, а не кинутись винятком.
    It 'Task 2а: -Lenient (шлях check) — DT-INF-знахідка йде у Findings, а не кидається як виняток' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dtinf-lenient')
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        New-Item -ItemType Directory -Path (Join-Path $repo 'DT-INF') -Force | Out-Null
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 1
        $ctx.Findings[0].Message | Should -BeLike '*DT-INF*v8storagekit:onboarding*'
    }

    It 'воркспейс із маніфесту без теки — зупинка з його ім''ям' {
        $text = "version: 1`nkitVersion: 1.0.1`nproduct: Fake`nworkspaces:`n  - path: Ghost`n    sources:`n      g: { truth: git }"
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
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            "      Alpha_SMB_typo: { truth: storage, storage: { path: 'x' } }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-key') -ManifestText $text
        { Invoke-KitPreflight -RepoRoot $repo } | Should -Throw "*'Alpha_SMB_typo'*base, Alpha_SMB*"
    }

    It '-Lenient збирає ВСІ проблеми, а не першу' {
        $text = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:', "      nope: { truth: git }",
            '  - path: Ghost',     '    sources:', "      g: { truth: git }"
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'lenient') -ManifestText $text
        $ctx = Invoke-KitPreflight -RepoRoot $repo -Lenient
        $ctx.Ok | Should -BeFalse
        @($ctx.Findings | Where-Object Level -eq 'error').Count | Should -Be 2
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
