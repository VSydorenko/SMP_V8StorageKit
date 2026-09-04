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
        $text = @('version: 1', 'product: Fake', 'workspaces:', '  - path: epf', '    sources:', "      tools: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-pending-preview') -WithHooks
        $storageDir = Join-Path $TestDrive 'no-pending-preview-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        # B3 Task 1: New-KitStorageInfobase (кличе New-ExtensionInfobase) живе в
        # StoragePlatform.psm1, не в sync — Mock -ModuleName діє лише в приватному столі
        # команд названого модуля, тож саме StoragePlatform, а не sync (той нічого б не перехопив).
        Mock -ModuleName StoragePlatform New-ExtensionInfobase { '/F "fake-ib"' }
        # Кома навмисно: Get-StorageVersions (StorageReport.psm1:195) сама повертає
        # comma-wrapped масив, а не голий @(...) — мок мусить давати ту саму форму, щоб не
        # проходити випадково лише тому, що в наборі один елемент (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -MergeMain
        $result.ExitCode | Should -Be 0
        $result.Synced[0].MergedIntoMain | Should -Be $false
        Should -Invoke -ModuleName sync Invoke-KitMainMerge -Times 0
        # Доказ перехоплення, а не здогад із часу виконання: без цього мок може мовчки не
        # спрацювати (межа модуля), і тест лишиться зеленим, реально покликавши 1cv8.exe.
        Should -Invoke -ModuleName StoragePlatform New-ExtensionInfobase -Times 1
    }

    It 'дзеркало вже синхронне, -MergeMain РАЗОМ з -Apply — злиття викликається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-pending-apply') -WithHooks
        $storageDir = Join-Path $TestDrive 'no-pending-apply-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        # B3 Task 1: те саме, що в попередньому тесті — New-KitStorageInfobase кличе
        # New-ExtensionInfobase зі StoragePlatform.psm1, а не з sync.
        Mock -ModuleName StoragePlatform New-ExtensionInfobase { '/F "fake-ib"' }
        # Кома навмисно — та сама форма, що реальна Get-StorageVersions повертає (F7).
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -Apply $true -MergeMain
        $result.ExitCode | Should -Be 0
        $result.Synced[0].MergedIntoMain | Should -Be $true
        Should -Invoke -ModuleName sync Invoke-KitMainMerge -Times 1
        # Доказ перехоплення, а не здогад із часу виконання (див. попередній тест).
        Should -Invoke -ModuleName StoragePlatform New-ExtensionInfobase -Times 1
    }

    It 'провал злиття після успішного реплею — ExitCode 2, підказка на повтор із -Apply, дзеркало вже оновлене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'merge-fails') -WithHooks
        $storageDir = Join-Path $TestDrive 'merge-fails-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")

        $ctx = New-KitTestContext -Repo $repo
        # B3 Task 1: New-KitStorageInfobase кличе New-ExtensionInfobase зі StoragePlatform.psm1.
        Mock -ModuleName StoragePlatform New-ExtensionInfobase { '/F "fake-ib"' }
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
        Should -Invoke -ModuleName StoragePlatform New-ExtensionInfobase -Times 1
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2
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
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
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
        $manifest = @('version: 1', 'client: Client', 'workspaces:', '  - path: Client_UNF', '    sources:',
            '      base:', '        truth: storage', "        storage: { path: '$script:CfgStorage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cfg') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes
        # Шаблонний templates/gitignore тут не годиться: його правило **/cf/** ігнорувало б
        # САМЕ дерево cf/src, яке цей тест перевіряє (тут truth: storage, не vendor). Але без
        # ЖОДНОГО .gitignore build/sync/<key>/ (тимчасова ІБ і worktree, які sync створює на
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
