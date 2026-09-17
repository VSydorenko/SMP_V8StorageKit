#Requires -Version 7
Describe 'kit verify — штатні зупинки до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Verify {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit verify -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'дзеркала ще немає — зупинка «sync», build/verify не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-mirror') -WithHooks
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*storage/Alpha_SMB*sync*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'дзеркало є, але main його не зливав — зупинка «sync» до платформи' {
        # Дискримінуюча перевірка (рев'ю B3 раунд 2, Important 2): проба на видаленому
        # commands/verify.psm1 показала, що '*sync*' збігається і з диспетчерською відмовою
        # «Невідома команда 'verify'. Доступні: check, sync.» — тест лишався зеленим навіть
        # коли команди в дереві не існувало взагалі. '*ніколи не зливав*storage/Alpha_SMB*' —
        # точний підрядок штатної зупинки Get-KitVerifyVersion, диспетчерська відмова його не має.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmerged') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*ніколи не зливав*storage/Alpha_SMB*'
        Join-Path $repo 'build/verify' | Should -Not -Exist
    }

    It 'без джерел truth: storage — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Verify -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It '-Ref невідомий — зупинка з його ім''ям' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-ref') -WithHooks
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        $r = Invoke-Verify -Repo $repo -More @('-Ref', 'nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'nope'*"
    }

    It 'бази агента немає — verify зупиняється з рецептом, не створивши build/verify' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-no-base') -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        # Get-KitVerifyVersion (git-інваріанти дзеркала) звіряється РАНІШЕ за резолв бази
        # агента — щоб дійти до нього, спільний предок 'main' і 'storage/Alpha_SMB' має нести
        # валідний трейлер Storage-Version, інакше verify зупиниться на "Розбір: kit check"
        # ще до Get-KitSourceInfobase. Голий 'git branch' (без цього коміту) робив би merge-base
        # рівно вершиною main без трейлера — не той шлях, що ця перевірка має покрити.
        git -C $repo commit -q --allow-empty -m 'версія' -m "Storage-Source: Alpha_SMB`nStorage-Version: 1" 2>&1 | Out-Null
        git -C $repo branch 'storage/Alpha_SMB' 2>&1 | Out-Null
        $r = Invoke-Verify -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*kit provision*'
        Join-Path $repo 'build/verify/Alpha_SMB' | Should -Not -Exist
    }

    It '-Version без числа — зупинка з поясненням, а не тиха звірка проти версії 1 (рев''ю B3 раунд 3, M6 → Step 5а)' {
        # CommandArgs = @('-Version', '-Ref', 'main'): наступний токен після '-Version' — інший
        # прапорець ('-Ref'), тож без захисту диспетчер підставив би $splat.Version = $true.
        # [Nullable[int]]$Version у verify.psm1 зв'язав би $true як 1 (bool->int), і
        # [ValidateRange(1, [int]::MaxValue)] пройшов би МОВЧКИ — це й був сценарій знахідки
        # M6 ("kit verify -Version -Ref main", забули число, тихо звіряє проти версії 1).
        # Правку зробили ЦЕНТРАЛЬНО в диспетчері (tools/kit.ps1, Step 5а), не в самому verify:
        # $true підставляється лише справжньому [switch]-параметру команди; Version —
        # [Nullable[int]], тож диспетчер сам зупиняє виклик, ще ДО Invoke-KitVerify.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-version') -WithHooks
        $r = Invoke-Verify -Repo $repo -More @('-Version', '-Ref', 'main')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-Version*значення*'
    }
}

Describe 'kit verify — мок платформного шару: щасливий шлях без жодного binary-файла (рев''ю B3 раунд 2, Critical 1)' {
    # Жоден з чотирьох тестів вище не виконує жодного рядка Invoke-KitVerify ПІСЛЯ
    # Get-KitVerifyVersion — усі зупиняються до платформи. Саме в цій сліпій зоні сидів
    # Critical 1: Compare-KitTrees приймав $BinaryPaths лише як Mandatory без
    # AllowEmptyCollection, а Get-KitBinaryPaths штатно повертає порожній HashSet, коли
    # жоден файл дерева не позначений binary в .gitattributes — саме так виглядає
    # найтиповіше дерево 1С (лише XML/BSL). Мокається лише платформний шар —
    # Enter-/Exit-KitStorageBind, Invoke-KitStorageCheckout — усі викликаються ПРЯМО з
    # verify.psm1, тому -ModuleName verify (урок Task 1: Mock -ModuleName діє лише в
    # приватному столі команд НАЗВАНОГО модуля). Export-KitTree, Get-KitBinaryPaths і
    # Compare-KitTrees лишаються СПРАВЖНІМИ — саме в них сидів дефект. verify тепер дампить
    # у базі агента (Get-KitSourceInfobase, Task 4) — звідси -WithAgentBase нижче.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/verify.psm1").Path -Force
    }

    It 'жоден файл не позначений binary — verify не падає на прив''язці параметра, доходить до вердикту equal' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-happy') -WithHooks -WithGitattributes -WithGitignore -WithAgentBase
        # script:-scoped, не локальна $content: Mock -ModuleName виконує -MockWith у
        # приватному столі НАЗВАНОГО модуля (verify), а не в лексичному оточенні It-блоку —
        # той самий прийом, що Sync.Tests.ps1 уже застосовує через script:-функції
        # (New-KitFakeStorageVersion), тут просто дані, а не команда.
        $script:MockContent = New-KitFakeConfigurationXml -Name 'Alpha_SMB'
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content $script:MockContent -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')

        # Storage-шлях фіктурного джерела навмисно неіснуючий (KitFixtures.psm1) — Test-Path
        # у verify.psm1 упав би раніше, ніж дійшло б до мокованого платформного шару. Тому,
        # як і в Sync.Tests.ps1 (мок платформи), підміняємо шлях накладкою на порожню, але
        # реальну теку.
        $storageDir = Join-Path $TestDrive 'mock-happy-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")

        Mock -ModuleName verify Enter-KitStorageBind { $false }
        Mock -ModuleName verify Exit-KitStorageBind { }
        Mock -ModuleName verify Invoke-KitStorageCheckout {
            param($IbSwitch, $Source, $Version, $Target, $MustBeUnder)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target 'Configuration.xml') -Value $script:MockContent -Encoding UTF8 -NoNewline
            1
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Ref = сама гілка дзеркала (SYNOPSIS Invoke-KitVerify: «storage/X — канонічність
        # самого дзеркала») — merge-base гілки із собою є вершина, без потреби зливати в
        # main і без ризику add/add-конфлікту фейкового Configuration.xml фікстури (F9).
        $result = Invoke-KitVerify -Context $ctx -Ref 'storage/Alpha_SMB'

        $result.ExitCode | Should -Be 0
        $result.Results.Count | Should -Be 1
        $result.Results[0].Verdict | Should -Be 'equal'
        # Доказ, що платформа справді перехоплена, а не здогад із часу виконання (той самий
        # прийом, що Sync.Tests.ps1): без цього тест міг би мовчки піти в реальний 1cv8.exe.
        # Це єдиний виклик у шляху verify, що справді пішов би в платформу — Enter-/Exit-
        # KitStorageBind теж моковані.
        Should -Invoke -ModuleName verify Invoke-KitStorageCheckout -Times 1
        # Позитивний доказ самої зміни: тимчасова ІБ більше не створюється — verify.psm1
        # дампить у базі агента (build/ib воркспейсу, не build/verify/<ключ>/ib).
        Join-Path $repo 'build/verify/Alpha_SMB/ib' | Should -Not -Exist
    }
}

Describe 'kit verify — живе сховище: рівні → сховище попереду → звірочний коміт → рівні' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item 'R:\github\SMP_BankExchange\AUTHORS' (Join-Path $script:Repo 'AUTHORS') -Force
        # F9: прибрати фейковий Configuration.xml з main — інакше перше злиття дзеркала дасть add/add-конфлікт.
        git -C $script:Repo rm -rq -- SMP_BankExchange_SMB/cfe/src
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS; дерево джерела порожнє до першого sync'
        function script:Run { param([string[]]$Arguments) $out = & pwsh -NoProfile -File $script:Kit @Arguments -RepoRoot $script:Repo 2>&1 | Out-String; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        function script:Complete-Authors {
            param([string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8; $added = $true }
            }
            if ($added) { git -C $script:Repo commit -qam 'AUTHORS: тестові автори' }
            $added
        }
    }

    It 'після першого sync main ≡ сховище (нуль змістовних розбіжностей — знахідка BankExchange)' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 0 -Because $v.Output
        $v.Output | Should -BeLike '*equal*'
        $v.Output | Should -Not -Match '\[-\]'      # -BeLike трактує [-] як клас символів; -Match — літерально
    }

    It 'ще одна версія в дзеркалі — «сховище попереду»; -Apply робить звірочний коміт; далі знову рівні' {
        $s = Run @('sync', '-Apply', '-MaxVersions', '1')
        if (Complete-Authors -Output $s.Output) { $s = Run @('sync', '-Apply', '-MaxVersions', '1') }
        $s.ExitCode | Should -Be 0 -Because $s.Output
        $v = Run @('verify')
        $v.ExitCode | Should -Be 3 -Because $v.Output
        $v.Output | Should -BeLike '*storage-ahead*'
        $mainBefore = git -C $script:Repo rev-parse main
        $a = Run @('verify', '-Apply')
        $a.ExitCode | Should -Be 3 -Because $a.Output     # звірка йшла проти старої версії; коміт зроблено
        (git -C $script:Repo rev-parse main) | Should -Not -Be $mainBefore
        $v2 = Run @('verify')
        $v2.ExitCode | Should -Be 0 -Because $v2.Output
    }
}
