#Requires -Version 7
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

    It '-MergeInto гілка без v8storagekit.yaml (gitsync-master) — злиття не виконується, код 2, гілка не зрушила' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-into-legacy') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'merge-into-legacy-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
        # Гілка без маніфесту — так виглядає master gitsync-репозиторію до переходу (#15).
        git -C $repo checkout -q --orphan legacy 2>&1 | Out-Null
        git -C $repo rm -rqf . 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'gitsync' -Encoding UTF8
        git -C $repo add README.md; git -C $repo commit -qm 'gitsync-стан' 2>&1 | Out-Null
        git -C $repo checkout -q main 2>&1 | Out-Null
        $legacyBefore = git -C $repo rev-parse legacy

        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5) }

        $ctx = New-KitTestContext -Repo $repo
        $result = Invoke-KitSync -Context $ctx -Apply $true -MergeMain -MergeInto 'legacy' -InformationVariable infoRecords
        $result.ExitCode | Should -Be 2
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*legacy*v8storagekit.yaml немає*'
        (git -C $repo rev-parse legacy) | Should -Be $legacyBefore
    }

    It '-MergeInto гілка онбордингу з маніфестом — злиття туди, main не зрушив' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-into-onb') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'merge-into-onb-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
        git -C $repo branch onboarding main
        $mainBefore = git -C $repo rev-parse main

        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5) }

        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -MergeMain -MergeInto 'onboarding'
        $result.ExitCode | Should -Be 0
        git -C $repo merge-base --is-ancestor storage/Alpha_SMB onboarding; $LASTEXITCODE | Should -Be 0
        (git -C $repo rev-parse main) | Should -Be $mainBefore
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
