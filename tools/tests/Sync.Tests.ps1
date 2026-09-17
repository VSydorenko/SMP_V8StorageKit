#Requires -Version 7
Describe 'kit sync — штатні зупинки до звернення до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'немає джерел truth: storage — код 0 і пояснення, платформа не потрібна' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-storage') -Workspaces $ws -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It 'каталог сховища недоступний — зупинка з його шляхом ДО створення build/sync/<ключ> і без гілки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-dir') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*no-such-storage-Alpha_SMB*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'AUTHORS відсутній — зупинка до платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-authors') -WithHooks
        Remove-Item -LiteralPath (Join-Path $repo 'AUTHORS')
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*AUTHORS*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It '-Source невідомий — зупинка з переліком' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-source') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Source', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*"
    }

    It 'джерело truth: storage на EXTERNAL_DATA_PROCESSORS — зупинка (сховища для обробок не буває)' {
        $text = @('version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: epf', '    sources:', "      tools: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-proc') -Workspaces $ws -ManifestText $text -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }

    It 'пароль сховища з накладки ніде не потрапляє у вивід зупинки (Task 2a)' {
        # Той самий сценарій, що "каталог сховища недоступний" вище, але з паролем у
        # v8storagekit.local.yaml під storages: Alpha_SMB — sync мусить дійти до тієї самої
        # зупинки ("Каталог сховища не знайдено"), і пароль з накладки ніде в її виводі не
        # з'явиться: ні в Write-Host, ні в тексті винятку, ні деінде.
        $overlay = @('storages:', "  Alpha_SMB: { password: 'secret' }") -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'with-password') -OverlayText $overlay -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Каталог сховища не знайдено*'
        $r.Output | Should -Not -BeLike '*secret*'
    }

    # Рев'ю Task 2, п. 8 — наскрізна перевірка прив'язки прапорця через СПРАВЖНІЙ kit.ps1 (не
    # напряму Invoke-KitSync): та сама пастка, що вже закріплена для kit verify -Version
    # (Verify.Tests.ps1) — без диспетчерської перевірки типу параметра '-Apply', що йде одразу
    # після '-FromVersion', мовчки прив'язався б як $true, а [Nullable[int]] звів би це до 1 —
    # sync тихо реплеїв би "з версії 1" замість штатної зупинки.
    It '-FromVersion без значення (далі інший прапорець) — зупинка "потребує значення", не мовчазна прив''язка як 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fromversion-novalue') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-FromVersion', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-FromVersion*значення*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It 'бази агента немає — зупинка з рецептом, дамп не починається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-agent-base') -WithHooks
        # Каталог сховища має існувати, інакше sync зупиниться раніше — на ньому.
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*kit provision*'
        $r.Output   | Should -BeLike '*operation=build*'
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It 'база агента збігається з дев-базою людини — зупинка до платформи (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-base') -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*дев-базою людини*'
    }

    It 'у v8project.yaml немає infobase: — зупинка з іменем воркспейсу' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-infobase') -Workspaces $ws -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*Alpha_SMB*'
        $r.Output   | Should -BeLike '*infobase*'
    }
}

Describe 'kit sync — злиття в головну гілку: гейт -Apply і провал злиття (мок платформи)' {
    # Рев'ю Task 4, Important #1 і #4: гілка "немає нових версій" (sync.psm1 ~140-146) і гілка
    # ExitCode=2 (провал Invoke-KitMainMerge) не мали жодного тесту — саме тому дефект підказки
    # ("Повторити злиття: kit sync -Source <key> -MergeMain" без -Apply, хоча без -Apply злиття
    # не спрацює: umovoju `$MergeMain -and $Apply -and $null -ne $last`) не спіймався. Тут
    # Invoke-KitSync викликається напряму (не через kit.ps1 підпроцесом), у ЦЬОМУ процесі: лише
    # так Pester Mock -ModuleName може підмінити функції, що торкаються платформи
    # (New-ExtensionInfobase, Invoke-V8Designer — нижче за -ModuleName StoragePlatform;
    # Get-StorageVersions — за -ModuleName sync) чи git-злиття (Merge-KitBranchInto /
    # Invoke-KitMainMerge, обидві -ModuleName sync), не запускаючи 1cv8.exe. Той самий прийом,
    # що StorageReport.Tests.ps1 уже застосовує для Invoke-V8Designer (Mock -ModuleName StorageReport).
    #
    # B3 Task 1: New-KitStorageInfobase (кличе New-ExtensionInfobase) і Invoke-KitStorageCheckout
    # (кличе Invoke-V8Designer) переїхали в StoragePlatform.psm1 — Mock -ModuleName діє лише в
    # приватному столі команд НАЗВАНОГО модуля, тож ці два виклики тепер мокаються за
    # -ModuleName StoragePlatform, не sync (мок -ModuleName sync на них нічого більше не
    # перехопить — sync.psm1 їх узагалі не кличе, рев'ю Task 1 round 3 прибрало такі мокі як
    # мертві). -ModuleName sync лишається для Get-StorageVersions/Invoke-KitMainMerge/
    # Merge-KitBranchInto — вони й далі кличуться прямо з sync.psm1. Без правильного шару мока
    # тест і далі "зелений", але мовчки викликає 1cv8.exe (це й сталось на живому прогоні Task 1
    # — знайдено лише за аномально довгим часом виконання) — тому нижче ще й
    # Should -Invoke -ModuleName StoragePlatform як доказ перехоплення, а не здогад із таймінгу.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        # Той самий порядок, що читає kit.ps1 (module-order.txt) — sync.psm1 сам нічого не
        # імпортує (лише оркеструє те, що вже видно з глобальної області), тож тут повторюємо
        # завантажувач диспетчера один-в-один, а не гадаємо транзитивні залежності.
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
    }

    It 'дзеркало вже синхронне, -MergeMain БЕЗ -Apply — злиття не викликається (лише -Apply дозволяє мутацію)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-pending-preview') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'no-pending-preview-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        # Task 3: sync тепер дампить у базі агента (Get-KitSourceInfobase), не в тимчасовій ІБ
        # зі стабом — New-ExtensionInfobase більше не кличеться. Мок Invoke-V8Designer лишається
        # ПАСТКОЮ на цьому шляху: дзеркало вже синхронне (pending.Count=0), і платформа тут
        # узагалі не потрібна — випадковий похід у реальний 1cv8.exe спіймається, а не пройде.
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Кома навмисно: Get-StorageVersions (StorageReport.psm1:195) сама повертає
        # comma-wrapped масив, а не голий @(...) — мок мусить давати ту саму форму, щоб не
        # проходити випадково лише тому, що в наборі один елемент (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -MergeMain
        $result.ExitCode | Should -Be 0
        $result.Synced[0].MergedIntoMain | Should -Be $false
        Should -Invoke -ModuleName sync Invoke-KitMainMerge -Times 0
        # Доказ, що платформа справді не викликана на цьому шляху, а не здогад із часу виконання.
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'дзеркало вже синхронне, -MergeMain РАЗОМ з -Apply — злиття викликається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-pending-apply') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'no-pending-apply-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        # Task 3: те саме, що в попередньому тесті — дзеркало вже синхронне, платформа на цьому
        # шляху не потрібна взагалі; мок Invoke-V8Designer лишається пасткою на регресію.
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Кома навмисно — та сама форма, що реальна Get-StorageVersions повертає (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -Apply $true -MergeMain
        $result.ExitCode | Should -Be 0
        $result.Synced[0].MergedIntoMain | Should -Be $true
        Should -Invoke -ModuleName sync Invoke-KitMainMerge -Times 1
        # Доказ, що платформа справді не викликана на цьому шляху (див. попередній тест).
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'провал злиття після успішного реплею — ExitCode 2, підказка на повтор із -Apply, дзеркало вже оновлене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-fails') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'merge-fails-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")

        $ctx = New-KitTestContext -Repo $repo
        # Кома навмисно — та сама форма, що реальна Get-StorageVersions повертає (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7 -Comment 'перша версія') }
        # B3 Task 1: реальний виклик /ConfigurationRepositoryUpdateCfg і /DumpConfigToFiles тепер
        # робить Invoke-KitStorageCheckout у StoragePlatform.psm1, не sync — Mock -ModuleName
        # діє лише в приватному столі команд названого модуля, тож саме тут.
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Merge-KitBranchInto { throw 'симульований збій злиття' }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 2
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Дзеркало оновлено. Повторити злиття: kit sync -Source Alpha_SMB -Apply -MergeMain*'
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 7
        # Доказ перехоплення, а не здогад із часу виконання: без цього виклик міг мовчки піти
        # у реальний 1cv8.exe (Invoke-KitStorageCheckout кличе Invoke-V8Designer двічі —
        # UpdateCfg і DumpConfigToFiles — на кожну версію; тут версія одна).
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2
    }

    # Task 8 (task-8-brief.md) — відбиток сховища (StorageImprint.psm1). Найважливіший тест
    # задачі: місце запису — ОДРАЗУ після Get-StorageVersions/$maxVersion, ДО розгалуження
    # "Нових версій немає". Якщо запис стоїть ПІСЛЯ цього розгалуження, фіча не працює рівно в
    # тому випадку, заради якого зроблена — неактивне (запаковане) сховище ніколи не отримає
    # відбитка, і session-check лишається з вічним "не визначається".
    It 'відбиток пишеться в гілці "Нових версій немає" — саме для неактивного сховища (Task 8)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'imprint-no-pending') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'imprint-no-pending-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        # Task 3: платформа на цьому шляху не потрібна взагалі (дзеркало вже синхронне) —
        # мок лишається пасткою на регресію, не доказом нормального виклику.
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Кома навмисно — та сама форма, що реальна Get-StorageVersions повертає (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }

        $result = Invoke-KitSync -Context $ctx
        $result.ExitCode | Should -Be 0
        $result.Synced[0].Versions.Count | Should -Be 0   # довести, що це саме гілка "нових версій немає"

        $imprintPath = Join-Path $repo 'build/session-check/Alpha_SMB.json'
        $imprintPath | Should -Exist
        $imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        $imprint | Should -Not -BeNullOrEmpty
        $imprint.Version | Should -Be 5
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'відбиток пишеться БЕЗ -Apply (прев''ю); version у ньому — максимум зі звіту, НЕ кількість версій' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'imprint-preview') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'imprint-preview-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")

        $ctx = New-KitTestContext -Repo $repo
        # Task 3: платформа на цьому шляху не потрібна взагалі — мок лишається пасткою на регресію.
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Дві версії з розривом (3, 9) — максимум 9, кількість 2: version у відбитку МАЄ бути 9.
        Mock -ModuleName sync Get-StorageVersions {
            , @(
                (New-KitFakeStorageVersion -Version 3 -Comment 'перша')
                (New-KitFakeStorageVersion -Version 9 -Comment 'друга')
            )
        }

        $result = Invoke-KitSync -Context $ctx
        $result.ExitCode | Should -Be 0
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty   # прев'ю нічого не комітить — контракт "-Apply лише за проханням" не порушено

        $imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        $imprint | Should -Not -BeNullOrEmpty
        $imprint.Version | Should -Be 9
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'відбиток пишеться З -Apply' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'imprint-apply') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'imprint-apply-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 7 -Comment 'перша версія') }
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -Apply $true
        $result.ExitCode | Should -Be 0
        Get-KitStorageBranchLastVersion -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -Be 7

        $imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        $imprint | Should -Not -BeNullOrEmpty
        $imprint.Version | Should -Be 7
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2
    }
}

Describe 'kit sync — глибина першого реплею: -FromVersion / -FromLatest (Task 2, §9.4)' {
    # Той самий прийом мокання, що в Describe вище (Task 4, Task 8) — Invoke-KitSync
    # кличеться напряму в цьому процесі, платформа НЕ запускається.
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
        function script:New-KitEmptyBranchRepo {
            param([Parameter(Mandatory)][string]$Root)
            # -WithAgentBase: Task 3 — sync резолвить базу агента з диска (Get-KitSourceInfobase)
            # ще до звернення до платформи, для КОЖНОГО джерела в циклі; без цього переключача
            # кожен тест цього Describe, що кличе Invoke-KitSync, отримав би зупинку з рецептом
            # "kit provision" замість роботи мокованої платформи.
            $repo = New-KitFakeRepo -Root $Root -WithHooks -WithAgentBase
            $storageDir = "$Root-storage"
            New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
                @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            $repo
        }
    }

    Context 'порожня гілка — куди веде -FromVersion/-FromLatest' {
        BeforeEach {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Invoke-KitMainMerge { $true }
            # 60/64/65: розрив (61-63 оптимізовано) — той самий силует, що живий прогін
            # компаньйона (сховище конфігурації, максимум 65) описаний у брифі задачі.
            Mock -ModuleName sync Get-StorageVersions {
                , @(
                    (New-KitFakeStorageVersion -Version 60 -Comment 'стара')
                    (New-KitFakeStorageVersion -Version 64 -Comment 'середня')
                    (New-KitFakeStorageVersion -Version 65 -Comment 'поточна')
                )
            }
        }

        It 'без параметрів — з найменшої версії звіту (наявна поведінка не змінилась)' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-none')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true
            $result.ExitCode | Should -Be 0
            (@(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB').Trailers.'Storage-Version') | Should -Be @('60', '64', '65')
        }

        It '-FromVersion 64 — реплеяться версії від 64 включно (64 і 65), трейлер вершини — максимум звіту' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-64')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 64
            $result.ExitCode | Should -Be 0
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 2
            $commits.Trailers.'Storage-Version' | Should -Be @('64', '65')
        }

        # Головний тест задачі (task-2-brief.md): -FromLatest на порожній гілці МАЄ дати рівно
        # один коміт із МАКСИМАЛЬНОЮ версією — саме це відрізняє його від наявної
        # -MaxVersions 1, яка (закріплено вище) бере НАЙРАНІШУ версію.
        It '-FromLatest на порожній гілці — рівно ОДИН коміт, трейлер — МАКСИМАЛЬНА версія звіту' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-latest')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromLatest
            $result.ExitCode | Should -Be 0
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 1
            $commits[0].Trailers['Storage-Version'] | Should -Be '65'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2   # одна версія: UpdateCfg + DumpConfigToFiles
        }

        It '-MaxVersions 1 БЕЗ -From* — найРАНІША версія (закріплення наявної поведінки, не "лише поточна")' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'maxversions-lock')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -MaxVersions 1
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 1
            $commits[0].Trailers['Storage-Version'] | Should -Be '60'
        }

        It '-FromVersion більший за максимум зі звіту — зупинка з переліком доступних версій, коміту немає' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-too-high')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 999 } |
                Should -Throw '*999*60, 64, 65*'
            Test-KitBranchExists -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeFalse
        }

        # Рев'ю Task 2, п. 5: сховище БЕЗ ЖОДНОЇ версії (не плутати з "порожня гілка" вище —
        # тут порожній сам ЗВІТ) + -From* — до фіксу sync казав "Нових версій немає — дзеркало
        # синхронне зі сховищем", хоча версії, яку просили, у сховищі взагалі не існує.
        It '-FromVersion/-FromLatest на СХОВИЩІ БЕЗ ЖОДНОЇ ВЕРСІЇ — окрема зупинка, не "дзеркало синхронне"' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'empty-storage-report')
            Mock -ModuleName sync Get-StorageVersions { , @() }
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 5 } | Should -Throw '*порожній*'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromLatest } | Should -Throw '*порожній*'
        }
    }

    Context 'параметри — валідація до звернення до платформи' {
        # Рев'ю Task 2, п. 3: без мока Get-StorageVersions регресія будь-якого з трьох гардів
        # пропускає виклик далі — СПРАВЖНЯ Get-StorageVersions піде через Invoke-V8Designer у
        # реальну платформу проти неіснуючої ІБ. Тест урешті впав би, але вже ПІСЛЯ запуску
        # 1cv8.exe — у безплатформному Describe. Мокаємо платформні виклики так само, як у
        # сусідньому Context вище.
        BeforeEach {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'версія') }
        }

        It '-FromVersion разом із -FromLatest — зупинка (взаємовиключні), платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'mutex')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 5 -FromLatest } |
                Should -Throw '*взаємовиключ*'
            # Task 3: sync цієї функції не кличе НІ ЗА ЯКИХ УМОВ — Should -Invoke на
            # New-ExtensionInfobase був би завжди-зеленим (тавтологічним), вирізання самої
            # валідації його не зачепить (docs/follow-ups.md §4). Замінено на живий доказ:
            # платформа взагалі не викликана.
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }

        It '-FromVersion 0 — зупинка, платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'zero')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 0 } | Should -Throw '*додатн*'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }

        It '-FromVersion від''ємний — зупинка, платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'negative')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion -3 } | Should -Throw '*додатн*'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }
    }

    Context 'непорожня гілка — -FromVersion/-FromLatest призначені лише для першого реплею' {
        BeforeEach {
            $script:Repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive "nonempty-$([guid]::NewGuid().ToString('N'))")
            Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
                -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
            # До реалізації Task 2 ця зупинка ще не існує — без мока платформа не мокана і
            # виконання пішло б у реальну платформу. Мокаємо тут теж, щоб тест до фікса падав
            # швидко й з ясної причини, а не зависав на платформі.
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 6 -Comment 'нова') }
        }

        It '-FromVersion на непорожній гілці — зупинка, що називає трейлер вершини; жодного коміту не додано' {
            $before = git -C $script:Repo rev-parse 'storage/Alpha_SMB'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $script:Repo) -Apply $true -FromVersion 5 } |
                Should -Throw '*Storage-Version*5*'
            (git -C $script:Repo rev-parse 'storage/Alpha_SMB') | Should -Be $before
        }

        It '-FromLatest на непорожній гілці — та сама зупинка; жодного коміту не додано' {
            $before = git -C $script:Repo rev-parse 'storage/Alpha_SMB'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $script:Repo) -Apply $true -FromLatest } |
                Should -Throw '*Storage-Version*5*'
            (git -C $script:Repo rev-parse 'storage/Alpha_SMB') | Should -Be $before
        }
    }
}

Describe 'kit sync — origin: fetch перед реплеєм і підказка про push (Task 5, спека 2026-09-17 §6)' {
    # Той самий прийом мокання, що в Describe вище — Invoke-KitSync кличеться напряму в цьому
    # процесі, платформа НЕ запускається. git fetch і Get-KitOriginGap тут НЕ мокані навмисно:
    # реальний локальний "origin" (bare-клон) — найдешевший спосіб довести, що sync справді читає
    # ЖИВИЙ стан remote-tracking гілки, а не мок, який був би зеленим і на регресії.
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
    }

    It 'дзеркало отримало новий коміт, а origin відстав — підказка "git push origin (гілка)" з точним числом' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        # origin — реальний bare-клон стану РЕПО ДО нового коміту: sync має fetch'нути його сам
        # (Task 5, Step 4), і лише тоді Get-KitOriginGap побачить різницю.
        $up = Join-Path $TestDrive 'push-hint-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 6 -Comment 'нова') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Дзеркало попереду origin на 1 — git push origin storage/Alpha_SMB*'
    }

    It 'дзеркало вже синхронне з origin (Ahead=0) — підказки про push немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint-none') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-none-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        # origin містить рівно той самий коміт (клоновано ПІСЛЯ запису версії 5) — Ahead=0.
        $up = Join-Path $TestDrive 'push-hint-none-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Той самий номер версії, що вже на вершині — pending порожній, реплею немає взагалі.
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Not -BeLike '*Дзеркало попереду origin*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    # Фінальне рев'ю C2 — знахідка §6: підказка друкувалась лише в гілці коду з новими версіями;
    # дзеркало, що лишилось попереду origin ЩЕ З ПОПЕРЕДНЬОГО прогону (git push тоді не зробили),
    # при sync БЕЗ нових версій мовчало. Тут версія 5 — локальний коміт, зроблений ДО клонування
    # origin (тобто "попередній прогін"), а цей прогін bачить ту саму версію 5 у звіті — pending
    # порожній, реплею не буде взагалі.
    It 'дзеркало попереду origin ще з попереднього прогону, а нових версій цього разу немає — підказка про push однаково друкується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint-stale') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-stale-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 4')

        # origin клонується ТУТ — бачить лише версію 4.
        $up = Join-Path $TestDrive 'push-hint-stale-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        # Версія 5 — попереднім прогоном sync, локально; origin про неї не знає (не запушили).
        # Контент версії 5 мусить ВІДРІЗНЯТИСЬ від версії 4 — інакше git commit побачить чисте
        # дерево ("nothing to commit") і сам коміт не відбудеться.
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content ((New-KitFakeConfigurationXml -Name 'Alpha_SMB') + "`r`n<!-- v5 -->") `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Той самий номер версії, що вже на вершині — pending порожній, реплею немає взагалі.
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Нових версій немає*'
        $text | Should -BeLike '*Дзеркало попереду origin на 1 — git push origin storage/Alpha_SMB*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }
}

Describe 'kit sync — реальне сховище (перший і повторний реплей)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'   # живе сховище розширення; лише читання
        $script:Authors = 'R:\github\SMP_BankExchange\AUTHORS'

        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Невідомих авторів (нові користувачі сховища після останнього оновлення AUTHORS) — у тестову мапу.
        function script:Complete-Authors {
            param([string]$Repo, [string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") {
                    Add-Content -LiteralPath (Join-Path $Repo 'AUTHORS') -Encoding UTF8 -Value "$($Matches.u)=Test Author <test@example.invalid>"
                    $added = $true
                }
            }
            $added
        }

        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'kitVersion: 1.0.1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item -LiteralPath $script:Authors -Destination (Join-Path $script:Repo 'AUTHORS') -Force
        # F9: фікстура кладе на main фейковий Configuration.xml за тим самим шляхом, куди дзеркало покладе
        # справжній — перше злиття дало б add/add-конфлікт. У реальному онбордингу дерева на main ще немає.
        git -C $script:Repo rm -rq -- SMP_BankExchange_SMB/cfe/src
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS з живого репо; дерево джерела порожнє до першого sync'
    }

    It 'сховище доступне (передумова)' {
        $script:Storage | Should -Exist
    }

    It 'прев''ю без -Apply нічого не міняє в git' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        if (Complete-Authors -Repo $script:Repo -Output $r.Output) {
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*попередній перегляд*'
        (git -C $script:Repo branch --list 'storage/*') | Should -BeNullOrEmpty
    }

    It 'перший реплей: дві версії в storage/X, трейлери, перше злиття в main, дерево під шляхом джерела' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '2')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $commits = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB')
        $commits.Count | Should -Be 2
        $commits[0].Parents.Count | Should -Be 0
        $commits[1].Trailers['Storage-Source'] | Should -Be 'SMP_BankExchange_SMB'
        [int]$commits[1].Trailers['Storage-Version'] | Should -BeGreaterThan ([int]$commits[0].Trailers['Storage-Version'])
        # -c core.quotepath=false — той самий дефект, що в StorageBranch.psm1: без прапорця
        # git ls-tree квотує кириличні імена (SMP_BankExchange_SMB тримає такі об'єкти), і
        # -notlike вище хибно вважав би їх "поза шляхом".
        @(git -c core.quotepath=false -C $script:Repo ls-tree -r --name-only storage/SMP_BankExchange_SMB | Where-Object { $_ -notlike 'SMP_BankExchange_SMB/cfe/src/*' }).Count | Should -Be 0
        git -C $script:Repo merge-base --is-ancestor storage/SMP_BankExchange_SMB main
        $LASTEXITCODE | Should -Be 0
        Join-Path $script:Repo 'SMP_BankExchange_SMB/cfe/src/Configuration.xml' | Should -Exist
        Join-Path $script:Repo 'build/sync/SMP_BankExchange_SMB/wt' | Should -Not -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'повторний реплей: ще одна версія, main не чіпається (звірочний коміт — verify, B3)' {
        $mainBefore = git -C $script:Repo rev-parse main
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '1')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB').Count | Should -Be 3
        (git -C $script:Repo rev-parse main) | Should -Be $mainBefore
    }

    It 'kit check після реплею — без помилок' {
        $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $script:Repo 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'kit sync — сховище КОНФІГУРАЦІЇ (без -Extension)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Найменше живе сховище конфігурації — знайдене спайком Task 1 (progress.md, «Спайк раунд 1»):
        # КормЦентр_DEV, 1cv8ddb.1CD = 1,27 МБ. Обхід змінною середовища — щоб підставити інше
        # сховище без правки тесту (рішення архітектора).
        $script:CfgStorage = if ($env:V8KIT_CFG_STORAGE) { $env:V8KIT_CFG_STORAGE } else { 'R:\СховищаКонфігурацій_1С\КормЦентр_DEV' }
        $ws = [ordered]@{ 'Client_UNF' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
        $manifest = @('version: 1', 'kitVersion: 1.0.1', 'client: Client', 'workspaces:', '  - path: Client_UNF', '    sources:',
            '      base:', '        truth: storage', "        storage: { path: '$script:CfgStorage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cfg') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes
        # Шаблонний templates/gitignore тут не годиться: його правило **/cf/** ігнорувало б
        # САМЕ дерево cf/src, яке цей тест перевіряє (тут truth: storage, не vendor). Але без
        # ЖОДНОГО .gitignore build/sync/<key>/ (worktree й робочі файли, які sync створює на
        # час реплею) лишається невідстеженим — робоча копія "брудна", і Merge-KitBranchInto
        # штатно відмовляється зливати в брудний main (саме це спіймав перший живий
        # Integration-прогін тут, а не CRLF-попередження git — core.autocrlf тут false,
        # KitFixtures.psm1:83). Тому свій мінімальний .gitignore, без **/cf/**, і одразу
        # закомічений — незакомічений .gitignore сам був би untracked-файлом і так само
        # забруднив би git status --porcelain.
        Set-Content -LiteralPath (Join-Path $script:Repo '.gitignore') -Encoding UTF8 -Value (
            @('build/', '.build/', 'v8storagekit.local.yaml', 'v8project.local.yaml') -join "`n")
        git -C $script:Repo add -A
        git -C $script:Repo commit -q -m 'мінімальний .gitignore без **/cf/** — cf/src тут truth: storage'
    }

    It 'перша версія конфігурації лягає в storage/base з Config-Version і деревом під Client_UNF/cf/src' {
        $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        if ($r -match "=Ім'я <пошта>") {
            foreach ($line in ($r -split "`r?`n")) { if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8 } }
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        }
        $LASTEXITCODE | Should -Be 0 -Because $r
        $c = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/base')
        $c.Count | Should -Be 1
        $c[0].Trailers.Contains('Extension-Version') | Should -BeFalse
        Join-Path $script:Repo 'Client_UNF/cf/src/Configuration.xml' | Should -Exist
    }
}
