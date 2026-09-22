#Requires -Version 7
<#
Task 8 ("Швидкість набору тестів"): другий Describe колишнього RenameEdt.Tests.ps1,
перенесений СЮДИ ЦІЛКОМ разом із власним BeforeAll (не потребує fixtures/RenameEdtSetup.ps1 —
підготовка тут своя: лаб-модулі в порядку module-order.txt, потім
commands/rename-edt.psm1 у ЦЬОМУ процесі, не підпроцесом kit.ps1, — лише так
Mock -ModuleName бачить приватний стіл команди).
#>
Describe 'kit rename-edt — мок git-шару в процесі: C-A, pathspec git rm (task-3-findings-round1.md)' {
    # Той самий прийом, що Canon.Tests.ps1 ("мок платформного шару"): лаб-модулі в порядку
    # module-order.txt, потім САМЕ commands/rename-edt.psm1 у ЦЬОМУ процесі (не підпроцесом
    # kit.ps1) — лише так Mock -ModuleName бачить приватний стіл команди. Тест перевіряє РІВНО
    # те, що йде в git rm, — не текст помилки й не побічний ефект глобу (той відтворено окремо,
    # Bash-пробою, задокументованою в task-3-report.md), а сам аргумент, який команда будує.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/rename-edt.psm1").Path -Force

        # Знахідка D (рев'ю раунду 4): попередні моки віддавали ExitCode = 0 на що завгодно,
        # тож мок-тести не бачили ЖОДНОГО збою git — а весь відкіт саме про збої. Спільне тіло
        # моку нижче вміє три речі, яких бракувало:
        #   $script:GitMockLsTree   — що САМЕ лежить у $preHeadSha під кожним із двох керованих
        #                             шляхів (порожньо = такого шляху в коміті немає, тобто
        #                             жива форма першої міграції);
        #   $script:GitMockFailWhen — ненульовий ExitCode на КОНКРЕТНИЙ виклик;
        #   $script:GitMockThrowWhen— виняток із самого шару запуску процесу (немає git у PATH,
        #                             вичерпані дескриптори) — знахідка F.
        # Тіло створюється тут ОДИН раз і передається в Mock як -MockWith: замикань немає,
        # усе налаштування — через $script:-змінні, які видно і в It, і всередині моку.
        $script:GitMockBody = {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            $argv = @($Arguments)
            $script:GitMockCalls.Add($argv)
            if ($null -ne $script:GitMockThrowWhen -and (& $script:GitMockThrowWhen $argv)) {
                throw "симуляція: git не запустився ($($argv -join ' '))"
            }
            if ($argv -contains 'rev-parse') {
                return [pscustomobject]@{ ExitCode = $script:GitMockHeadExit; Stdout = $script:GitMockHeadSha; Stderr = 'симуляція rev-parse' }
            }
            if ($null -ne $script:GitMockFailWhen -and (& $script:GitMockFailWhen $argv)) {
                return [pscustomobject]@{ ExitCode = 128; Stdout = ''; Stderr = 'симуляція збою git' }
            }
            if ($argv -contains 'ls-tree') {
                $rel = $argv[-1]
                $entries = @()
                if ($script:GitMockLsTree.ContainsKey($rel)) { $entries = @($script:GitMockLsTree[$rel]) }
                # git ls-tree -z ЗАВЕРШУЄ кожен запис NUL — відтворюємо саме це.
                $payload = ''
                foreach ($entry in $entries) { $payload += "$entry`0" }
                return [pscustomobject]@{ ExitCode = 0; Stdout = $payload; Stderr = '' }
            }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }

        function script:Reset-KitGitMockState {
            <# .SYNOPSIS Типовий стан спільного моку: усе успішне, дерево призначення в HEAD Є. #>
            param([hashtable]$LsTree)
            $script:GitMockCalls = [System.Collections.Generic.List[object]]::new()
            $script:GitMockHeadSha = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            $script:GitMockHeadExit = 0
            $script:GitMockFailWhen = $null
            $script:GitMockThrowWhen = $null
            $script:GitMockLsTree = if ($PSBoundParameters.ContainsKey('LsTree')) { $LsTree } else { @{} }
        }

        function script:Add-KitMockEdtPair {
            <# .SYNOPSIS Два звичайні об'єкти A1/A2 під <Repo>/Alpha_SMB/src — два Moves поспіль. #>
            param([Parameter(Mandatory)][string]$Repo)
            $catalogsDir = Join-Path $Repo 'Alpha_SMB/src/Catalogs'
            foreach ($objectName in 'A1', 'A2') {
                New-Item -ItemType Directory -Force -Path (Join-Path $catalogsDir $objectName) | Out-Null
                Set-Content -LiteralPath (Join-Path $catalogsDir "$objectName/$objectName.mdo") -Value $objectName -Encoding UTF8
            }
        }
    }

    It 'git rm для Unmapped-файлу з дужками в імені йде через '':(literal)'' pathspec, не голий glob-шлях' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ca-mock') -WithGitattributes
        # Файл під Attributes/ — ПІДТВЕРДЖЕНО Unmapped (координатор: "2016 файлів Attributes/…
        # правильно віднесені до Unmapped"), а не Unresolved (як був би невідомий вид) — інакше
        # git rm для нього взагалі не викликається (Unresolved ніколи не видаляється), і тест
        # нічого не довів би про C-A.
        $dir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1/Forms/Ф1/Attributes'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a[bc].dcss') -Value 'x' -Encoding UTF8

        $script:CaRmArgs = $null
        Mock -ModuleName rename-edt Invoke-KitGitProcess {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            if ($Arguments -contains 'rm') { $script:CaRmArgs = $Arguments }
            # rev-parse HEAD мусить повернути щось (знахідка 6, рев'ю раунду 3: команда тепер
            # перевіряє, що SHA непорожній, ДО будь-якої мутації) — фальшивий, але непорожній SHA.
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Stdout = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'; Stderr = '' } }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null

        $script:CaRmArgs | Should -Not -BeNullOrEmpty -Because 'Attributes/a[bc].dcss мусить піти в Unmapped і викликати git rm'
        $literalArg = @($script:CaRmArgs | Where-Object { $_ -like ':(literal)*' })
        $literalArg.Count | Should -Be 1
        $literalArg[0] | Should -Be ':(literal)Alpha_SMB/src/Catalogs/Об1/Forms/Ф1/Attributes/a[bc].dcss'
    }

    It 'знахідка 1 (рев''ю раунду 3): жоден git-виклик відновлення не є "reset --hard" на весь репозиторій, і всі адресовані ЛИШЕ -SourceRelPath/-TargetRoot' {
        # Перехоплює АРГУМЕНТИ кожного git-виклику під час форсованого падіння — властивість,
        # яку не перевірити наскрізним прогоном через підпроцес (там видно лише stdout/файли,
        # не самі команди), і яку не можна відтворити "живою" гонитвою всередині одного
        # синхронного виклику команди без флакі-конкуренції (спроба через окремий файл поза
        # деревами щоразу впирається в запобіжник 1/4 "брудна копія" ще до старту мутації —
        # це вже перевірено окремо і свідомо відкинуто, коментар вище). Разом із наскрізним
        # I-E-тестом (реальний git, реальний стан диска в межах піддерев) це покриває
        # властивість: тут — що КОМАНДА НІКОЛИ НЕ ПРОСИТЬ git зробити щось поза двома
        # шляхами, там — що в межах цих шляхів реальний git справді відновлює коректно.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'scope-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        # Дерево призначення в $preHeadSha Є (типова фікстура) — тоді checkout адресується
        # обом шляхам, і саме цей обсяг перевіряє тест.
        Reset-KitGitMockState -LsTree @{
            'Alpha_SMB/src'     = @('Alpha_SMB/src/Catalogs/A1/A1.mdo', 'Alpha_SMB/src/Catalogs/A2/A2.mdo')
            'Alpha_SMB/cfe/src' = @('Alpha_SMB/cfe/src/Configuration.xml')
        }
        $script:GitMockFailWhen = { param($argv) $argv -contains 'mv' -and ($argv -join ' ') -like '*A2.mdo*' }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } | Should -Throw

        $allCalls = @($script:GitMockCalls)
        $allCalls.Count | Should -BeGreaterThan 0

        # Головна властивість: "reset" + "--hard" разом БІЛЬШЕ НІКОЛИ не з'являються — це й
        # був обсяг усього репозиторію, який зламала перша версія I-E.
        @($allCalls | Where-Object { $_ -contains 'reset' -and $_ -contains '--hard' }).Count | Should -Be 0 -Because '"reset --hard" на весь репозиторій прибрано остаточно'

        $checkoutCall = @($allCalls | Where-Object { $_ -contains 'checkout' })
        $checkoutCall.Count | Should -Be 1 -Because 'відновлення викликається рівно один раз'
        $checkoutCall[0][-2] | Should -Be 'Alpha_SMB/src' -Because 'checkout адресований -SourceRelPath, не корню репозиторію'
        $checkoutCall[0][-1] | Should -Be 'Alpha_SMB/cfe/src' -Because 'checkout адресований -TargetRoot, не корню репозиторію'

        $diffCalls = @($allCalls | Where-Object { $_ -contains 'diff' })
        $diffCalls.Count | Should -BeGreaterThan 0
        foreach ($diffCall in $diffCalls) {
            $diffCall[-2] | Should -Be 'Alpha_SMB/src' -Because 'кожен diff звірки відновлення адресований лише двом керованим шляхам'
            $diffCall[-1] | Should -Be 'Alpha_SMB/cfe/src'
        }

        # Знахідка A/B (рев'ю раунду 4): ls-tree питає про кожен керований шлях окремо, а
        # прибирання адресоване рівно цілям власного плану — жодного pathspec поза цими двома
        # коренями команда git не передає.
        $lsTreeCalls = @($allCalls | Where-Object { $_ -contains 'ls-tree' })
        $lsTreeCalls.Count | Should -Be 2 -Because 'про кожен із двох керованих шляхів питаємо окремо'
        $lsTreeCalls[0][-1] | Should -Be 'Alpha_SMB/src'
        $lsTreeCalls[1][-1] | Should -Be 'Alpha_SMB/cfe/src'
        foreach ($rmCall in @($allCalls | Where-Object { $_ -contains 'rm' })) {
            $rmCall[-1] | Should -BeLike ':(literal)Alpha_SMB/*'
        }
    }

    It 'знахідки A.2 і E (рев''ю раунду 4): невдалий checkout — повідомлення називає ТОЧНУ команду відновлення, і косметичне прибирання НЕ виконується' {
        # Мок віддає ненульовий ExitCode саме на checkout — форма, якої попередні моки не вміли
        # відтворити взагалі. Дві властивості одразу:
        #   A.2 — у тексті мусить бути команда, якою людина відновить стан руками (HEAD не
        #         рухався), а не лише діагностичні git diff/git status;
        #   E   — Remove-KitEmptyDirectory не мусить спрацювати після ПРОВАЛУ відновлення: саме
        #         прибраний скелет робив напівмігроване дерево схожим на успішно мігроване.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'restore-fail-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState -LsTree @{ 'Alpha_SMB/src' = @('Alpha_SMB/src/Catalogs/A1/A1.mdo', 'Alpha_SMB/src/Catalogs/A2/A2.mdo') }
        $script:GitMockFailWhen = { param($argv) ($argv -contains 'mv') -or ($argv -contains 'checkout') }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        $thrown = $null
        try { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null }
        catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -BeLike '*не вдався повністю*'
        $thrown | Should -BeLike '*HEAD не рухався*'

        # Знахідка 2 (рев'ю раунду 5): асерція прив'язана до РЯДКІВ РЕЦЕПТУ, а не до будь-якого
        # тексту в повідомленні. Попередня форма (`-BeLike '*git checkout <sha> -- <шлях>*'`)
        # збігалася з текстом помилки pruneErrors, який містить ту саму підстроку, — тобто
        # впасти не могла: підміна самого рецепту лишала тест зеленим.
        $recipe = @($thrown -split "`r?`n" | Where-Object { $_ -match '^\s+git\s' } | ForEach-Object { $_.Trim() })
        $recipe.Count | Should -Be 3 -Because "рецепт — рівно три команди по порядку: $($recipe -join ' | ')"
        $recipe[0] | Should -Be "git rm -r -f --ignore-unmatch -- ':(literal)Alpha_SMB/cfe/src'"
        $recipe[1] | Should -Be 'git checkout deadbeefdeadbeefdeadbeefdeadbeefdeadbeef -- Alpha_SMB/src'
        $recipe[2] | Should -Be 'git status'

        # E: теку під -TargetRoot створив New-Item у циклі mv; після ПРОВАЛУ відновлення вона
        # мусить лишитись на місці — саме її зникнення й створювало хибне враження міграції.
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs') | Should -Exist -Because 'нічого не прибираємо, коли відновлення не вдалося'
    }

    It 'знахідка 4 (рев''ю раунду 5): зламана приймальна перевірка (git diff з кодом, відмінним від 0/1) — це ЗБІЙ відкоту, а не мовчазний успіх' {
        # Мутація "ігнорувати $verifyExitCode, лишити тільки pruneErrors" давала 114/114 зелених:
        # гілка "сам git diff зламався" не була покрита нічим. Мок віддає 128 саме на diff, коли
        # решта відкоту пройшла успішно — тоді команда мусить сказати, що стан піддерев НЕ
        # підтверджено, а не відрапортувати "відкочено".
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'verify-broken-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState -LsTree @{ 'Alpha_SMB/src' = @('Alpha_SMB/src/Catalogs/A1/A1.mdo', 'Alpha_SMB/src/Catalogs/A2/A2.mdo') }
        $script:GitMockFailWhen = {
            param($argv)
            ($argv -contains 'diff') -or (($argv -contains 'mv') -and (($argv -join ' ') -like '*A2.mdo*'))
        }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        $thrown = $null
        try { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null }
        catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -BeLike '*не вдався повністю*' -Because 'непідтверджений стан — це збій відкоту'
        $thrown | Should -BeLike '*приймальну перевірку відкоту виконати не вдалося*'
        $thrown | Should -BeLike '*завершився з кодом 128*'
        $thrown | Should -Not -BeLike '*Перейменування впало та відкочено*' -Because 'рапортувати успішний відкіт, не перевіривши його, не можна'
    }

    It 'знахідка F (рев''ю раунду 4): виняток усередині самого відкоту не з''їдає оригінальну причину падіння' {
        # Invoke-KitGitProcess СТАРТУЄ процес і може кинути (немає git у PATH, вичерпані
        # дескриптори). До раунду 4 виклики у catch не були обгорнуті, тож людина бачила лише
        # вторинну помилку — а на 22-хвилинному проході оригінальна причина це єдине свідчення
        # того, що саме пішло не так.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rollback-throw-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState -LsTree @{ 'Alpha_SMB/src' = @('Alpha_SMB/src/Catalogs/A1/A1.mdo') }
        $script:GitMockFailWhen = { param($argv) $argv -contains 'mv' -and ($argv -join ' ') -like '*A2.mdo*' }
        $script:GitMockThrowWhen = { param($argv) $argv -contains 'ls-tree' }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        $thrown = $null
        try { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null }
        catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -BeLike '*A2.mdo*' -Because 'оригінальна причина падіння мусить дожити до повідомлення'
        $thrown | Should -BeLike '*сам відкіт кинув виняток*' -Because 'вторинна помилка теж називається, але ПОРУЧ з оригінальною, а не замість неї'
        $thrown | Should -BeLike '*симуляція: git не запустився*'
    }

    It 'знахідка G (рев''ю раунду 4): ненульовий код git rev-parse HEAD зупиняє ДО будь-якої мутації' {
        # Мутант "вирізати перевірку ExitCode" виживав (15/0). Щоб він помер, мок віддає
        # НЕПОРОЖНІЙ Stdout при коді 1: інакше зупинку зробила б сусідня перевірка на порожній
        # SHA, і тест нічого не довів би саме про код виходу.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'revparse-code-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState
        $script:GitMockHeadExit = 1
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } |
            Should -Throw '*rev-parse HEAD*'

        @($script:GitMockCalls | Where-Object { ($_ -contains 'mv') -or ($_ -contains 'rm') -or ($_ -contains 'commit') }).Count |
            Should -Be 0 -Because 'зупинка ДО ЄДИНОЇ руйнівної команди, а не після неї'
    }

    It 'знахідка G (рев''ю раунду 4): порожній SHA при коді виходу 0 зупиняє ДО будь-якої мутації' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'revparse-empty-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState
        $script:GitMockHeadSha = "   `n"
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } |
            Should -Throw '*порожній результат*'

        @($script:GitMockCalls | Where-Object { ($_ -contains 'mv') -or ($_ -contains 'rm') -or ($_ -contains 'commit') }).Count |
            Should -Be 0
    }

    It 'S-J (рев''ю раунду 3, мутаційно): шлях файла повідомлення коміту створюється ПОЗА робочою копією репозиторію' {
        # Знахідка 4 (рев'ю раунду 3): попередній тест на S-J шукав файл, який `finally`
        # однаково прибирає, тож асерція "чи лишився файл" не могла впасти в принципі —
        # виживала і при старій, і при новій поведінці. Тут перехоплюється САМ ШЛЯХ у момент
        # запису (Set-Content), ДО будь-якого прибирання — якщо хтось поверне
        # 'build/rename-edt-commit-message.txt' усередині репозиторію, цей тест впаде, бо
        # порівнює шлях, а не факт видалення файлу пізніше.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sj-mock') -WithGitattributes
        $dir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Об1.mdo') -Value 'x' -Encoding UTF8

        Mock -ModuleName rename-edt Invoke-KitGitProcess {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Stdout = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'; Stderr = '' } }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }
        $script:SjMsgPath = $null
        Mock -ModuleName rename-edt Set-Content {
            param($LiteralPath, $Value, $Encoding)
            $script:SjMsgPath = $LiteralPath
        }

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null

        $script:SjMsgPath | Should -Not -BeNullOrEmpty -Because 'команда мала дійти до запису повідомлення коміту'
        $repoFull = (Resolve-Path $repo).Path.TrimEnd('\', '/')
        $script:SjMsgPath | Should -Not -BeLike "$repoFull*" -Because 'файл повідомлення має створюватись ПОЗА робочою копією репозиторію (S-J), а не в build/ усередині неї'
    }
}
