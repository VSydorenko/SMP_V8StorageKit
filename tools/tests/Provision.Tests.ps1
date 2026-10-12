#Requires -Version 7

Describe 'kit provision — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Provision { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }

        function script:Add-KitOwnerTree {
            <#
            .SYNOPSIS
                Задача 12: кладе стаб Configuration.xml у кожне CONFIGURATION-дерево репозиторію
                — «власник є на диску».
            .DESCRIPTION
                New-KitFakeRepo навмисно лишає CONFIGURATION source-set порожнім (коментар у
                KitFixtures.psm1: «vendor — як у споживача без дампу») — і саме це тепер ловить
                Test-KitConfigurationOwnerPresent (provision.psm1). Тести цього файлу, які
                досліджують ІНШУ вісь (шаблон, -Force, межа шляху F5/F7 тощо), кличуть цей
                хелпер одразу після New-KitFakeRepo, щоб нова перевірка не зупиняла їх на
                кроці, який вони не перевіряють, і не ховала справжню причину під іншим
                повідомленням. -Workspaces — та сама мапа, що передавалась у New-KitFakeRepo
                (типова, якщо не передано).
            #>
            param(
                [Parameter(Mandatory)][string]$Repo,
                [System.Collections.IDictionary]$Workspaces
            )
            if (-not $Workspaces) {
                $Workspaces = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
            }
            foreach ($wsName in @($Workspaces.Keys)) {
                foreach ($set in $Workspaces[$wsName]['Sets']) {
                    if ($set.Type -ne 'CONFIGURATION') { continue }
                    $dir = Join-Path $Repo "$wsName/$($set.Path)"
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline `
                        -Value (New-KitFakeConfigurationXml -Name $set.Name)
                }
            }
        }
    }

    It 'прев''ю: порожня файлова база під воркспейсом, без шаблону' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks
        Add-KitOwnerTree -Repo $repo
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*build*ib*порожн*-Apply*'
        # F2/P4-регресія: '*-Apply*' саме по собі проходить і на зламаній конкатенації —
        # `Write-Host 'x' + $(if...) -Fg y` друкує аргументи "x", "+", "." окремо через
        # пробіл ("x + ."), і підрядок "-Apply" усе одно там є. Цей патерн ловить лише
        # СКЛЕЄНий рядок: крапка одразу за -Apply, без пробілу й без "+" між ними.
        $r.Output | Should -BeLike '*додайте -Apply.*'
    }

    It 'шаблон із накладки показується в прев''ю; -Template перекриває його' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl') -OverlayText "workspaces:`n  Alpha_SMB:`n    agentBase:`n      template: 'D:\dumps\demo.dt'" -WithHooks
        (Invoke-Provision -Repo $repo).Output | Should -BeLike '*D:\dumps\demo.dt*'
        (Invoke-Provision -Repo $repo -More @('-Template', 'E:\other.dt')).Output | Should -BeLike '*E:\other.dt*'
    }

    It 'F2/P2-регресія: шаблон одного воркспейсу з накладки НЕ протікає в наступний воркспейс того самого прогону' {
        # До правки P2 локальна змінна циклу звалася $template — та сама змінна, що й
        # параметр -Template (PowerShell реєстронечутливий): шаблон, узятий із накладки
        # для Alpha_SMB, лишався б у $template і "просочувався" б у Beta_SMB, у якого
        # накладка шаблону не задає. Обидва воркспейси — файлові бази (File=build/ib), щоб
        # дійти до цього рядка прев'ю для кожного.
        $workspaces = [ordered]@{
            'Alpha_SMB' = @{
                Infobase = 'File=build/ib'
                Sets     = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
            'Beta_SMB' = @{
                Infobase = 'File=build/ib'
                Sets     = @(
                    @{ Name = 'base';     Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Beta_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $overlay = "workspaces:`n  Alpha_SMB:`n    agentBase:`n      template: 'D:\dumps\alpha-only.dt'"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'leak') -Workspaces $workspaces -OverlayText $overlay -WithHooks
        # Beta_SMB тут БЕЗ шаблону (саме так тест ловить P2) — без власника на диску Задача 12
        # зупинила б Beta_SMB раніше, ніж дійде до рядка прев'ю, який цей тест перевіряє.
        Add-KitOwnerTree -Repo $repo -Workspaces $workspaces
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*alpha-only.dt*'

        $betaIdx = $r.Output.IndexOf('Beta_SMB')
        $betaIdx | Should -BeGreaterThan 0
        $betaSection = $r.Output.Substring($betaIdx)
        $betaSection | Should -BeLike '*порожн*'
        $betaSection | Should -Not -BeLike '*alpha-only.dt*'
    }

    It '-Apply з неіснуючим .dt — зупинка до платформи; бази не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-dt') -WithHooks
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Template', (Join-Path $TestDrive 'missing.dt'))
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*missing.dt*'
        Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
    }

    It 'база вже є, без -Force — зупинка з підказкою; з -Force без -Apply — лише прев''ю' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'exists') -WithHooks
        Add-KitOwnerTree -Repo $repo
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'x'
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*-Force*'
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist

        # F4-регресія: друга половина назви тесту не мала виклику в тілі — -Force БЕЗ
        # -Apply мусить лишитись лише прев'ю (гілка -Apply у provision.psm1 стоїть ДО
        # перевірки -Force, тож -Force сам по собі нічого не мутує).
        $r2 = Invoke-Provision -Repo $repo -More @('-Force')
        $r2.ExitCode | Should -Be 0
        # Патерн повний, а не лише '*перестворена).*' — останній сам по собі проходить і
        # на зламаній конкатенації (Write-Host друкує "-Apply +  -Force (...)." окремими
        # аргументами, і "перестворена)." там теж є). Цей патерн вимагає, щоб "-Apply" і
        # "-Force" стояли РАЗОМ через один пробіл — так, як дає лише правильна конкатенація.
        $r2.Output | Should -BeLike '*додайте -Apply -Force (база існує й буде перестворена).*'
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
    }

    It '-Remember без -Template — зупинка: нема що запам''ятовувати' {
        $r = Invoke-Provision -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'remember') -WithHooks) -More @('-Remember')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*-Template*'
    }

    It 'F6-регресія: -Remember без -Apply — прев''ю каже, що шаблон іще не записано' {
        # -Remember сам по собі вимагає -Template (перша ж перевірка Invoke-KitProvision) —
        # тут він переданий явно, щоб дійти до гілки прев'ю, а не впасти на цій вимозі.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'remember-preview') -WithHooks
        $r = Invoke-Provision -Repo $repo -More @('-Remember', '-Template', 'D:\dumps\demo.dt')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*разом із -Apply*'
        Join-Path $repo 'v8storagekit.local.yaml' | Should -Not -Exist
    }

    Context 'F5/F7 — межа видалення/створення бази агента (безпека принципу 3, другий незалежний запобіжник)' {
        It 'F7: infobase.connection = File=cfe/src (сусідня тека всередині воркспейсу, поза workPath) — відмова, тека вихідників на місці' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sibling-dir') -WithHooks
            # Власника кладемо, щоб перевіряти саме межу шляху (F7), а не Задачу 12 —
            # інакше перша ж зупинка (власник) заступила б собою ту, що досліджує цей тест.
            Add-KitOwnerTree -Repo $repo
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=cfe/src'
            $cfg = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
            $cfg | Should -Exist
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            # Перевіряємо саме наявність файлів, а не лише текст винятку: текст пройшов би
            # й тоді, коли теку вже стерто (throw усередині New-V8FileInfobase теж називає
            # шлях). Тут перевірка відмовляє ДО New-V8FileInfobase, тож теки не торкались.
            $cfg | Should -Exist
        }

        It 'F5: infobase.connection = File=D:\ (за межами воркспейсу і репозиторію) — відмова, платформа не викликається' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'outside-drive') -WithHooks
            Add-KitOwnerTree -Repo $repo
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=D:\'
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
        }

        It 'F7: infobase.connection = File=build/ib (типовий, під workPath) — не відмовляє на межі' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'normal-path') -WithHooks
            Add-KitOwnerTree -Repo $repo
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -BeLike '*лежить поза робочою текою*'
        }

        It 'F7: workPath: ''out'' + File=out/ib — конфігурований workPath проходить (не відмовляє на межі)' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'workpath-out') -WithHooks
            Add-KitOwnerTree -Repo $repo
            $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
            ((Get-Content -LiteralPath $vp -Raw) -replace "workPath: 'build'", "workPath: 'out'") |
                Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=out/ib'
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeLike '*out*ib*'
            $r.Output | Should -Not -BeLike '*лежить поза робочою текою*'
        }

        It 'F7: workPath: ''.'' — відмова називає workPath, не базу (доводить, що спрацював саме запобіжник межі)' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'workpath-dot') -WithHooks
            Add-KitOwnerTree -Repo $repo
            $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
            ((Get-Content -LiteralPath $vp -Raw) -replace "workPath: 'build'", "workPath: '.'") |
                Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*workPath*'
            $r.Output | Should -Not -BeLike '*База агента*'
        }

        # П25 «Корені власності»: workPath не може бути коренем набору, лежати в ньому чи над ним (тека набору
        # коренем власності не стає ніколи). Відмова ДО видалення: файли набору цілі, текст — рецепт без значень поза репо.
        foreach ($case in @(
            @{ Name = 'дорівнює теці набору'; WorkPath = 'cfe/src' }
            @{ Name = 'лежить у теці набору';  WorkPath = 'cfe/src/work' }
            @{ Name = 'лежить над текою набору (містить її)'; WorkPath = 'cfe' }
        )) {
            It "П25: workPath $($case.Name) — відмова з рецептом, нічого не видалено" -TestCases @($case) {
                param($Name, $WorkPath)
                $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('workpath-set-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -WithHooks
                Add-KitOwnerTree -Repo $repo
                $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
                ((Get-Content -LiteralPath $vp -Raw) -replace "workPath: 'build'", "workPath: '$WorkPath'") |
                    Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline
                $cfg = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
                $cfg | Should -Exist
                $before = Get-Content -LiteralPath $cfg -Raw
                $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
                $r.ExitCode | Should -Not -Be 0
                $r.Output | Should -BeLike '*workPath*збігається з деревом джерела*Виправлення*'
                $cfg | Should -Exist
                (Get-Content -LiteralPath $cfg -Raw) | Should -Be $before
            }
        }
    }

    Context 'Задача 12 — власник конфігурації перевіряється до вибору типу бази' {
        It 'порожній cf/src, розширення без запозичених об''єктів (Adopted=0) — перевірка все одно спрацьовує, і в прев''ю, і з -Apply' {
            # Дефолтну фікстуру НЕ чіпаємо: KitFixtures навмисно лишає cf/src порожнім
            # (truth: vendor, як на щойно клонованій машині), а New-KitFakeConfigurationXml
            # розширення не додає жодного ObjectBelonging>Adopted. Це якраз випадок, де
            # перевірка МОВЧКИ пропустила б «порожню», якби залежала від Adopted — вона
            # безумовна (брифінг задачі), тож зупиняє і тут.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-owner-clean') -WithHooks

            $preview = Invoke-Provision -Repo $repo
            $preview.ExitCode | Should -Not -Be 0
            $preview.Output | Should -BeLike '*власника*'
            $preview.Output | Should -BeLike '*не позичає*'

            $applied = Invoke-Provision -Repo $repo -More @('-Apply')
            $applied.ExitCode | Should -Not -Be 0
            $applied.Output | Should -BeLike '*власника*'
            # Ключова вимога задачі («до» — не деталь, а вимога): платформа не викликалась
            # узагалі — New-V8FileInfobase (CREATEINFOBASE) не дійшло виконання.
            Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
        }

        It 'порожній cf/src + розширення з ObjectBelonging>Adopted — зупинка з числом і ціною варіантів, до платформи' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-owner-adopted') -WithHooks
            # Відтворюємо вимір задачі (SMP_BankExchange): у розширенні є запозичений об'єкт.
            $cfgPath = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
            Add-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '<ObjectBelonging>Adopted</ObjectBelonging>'

            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*власника*'
            $r.Output | Should -BeLike '*ObjectBelonging*Adopted*'
            # Вимір разом з умовами (Крок 4 брифа) — не як загальна статистика.
            $r.Output | Should -BeLike '*45 із 53*SMP_BankExchange*'
            $r.Output | Should -BeLike '*kit dump*20*40*1*2 ГБ*'
            $r.Output | Should -BeLike '*-Template*.dt*'
            $r.Output | Should -BeLike '*серверна*'
            Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
        }

        It '-Template заданий — вісь власника пропускається навіть при порожньому cf/src (шаблон несе власника інакше)' {
            # Той самий фікс, що й у тесті «-Apply з неіснуючим .dt» вище — тут явно
            # називаємо намір Задачі 12: якби перевірка не пропускала шаблонний шлях,
            # повідомлення було б про власника, а не про відсутній файл .dt.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-owner-template') -WithHooks
            $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Template', (Join-Path $TestDrive 'no-owner-template-missing.dt'))
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*власника*'
            $r.Output | Should -BeLike '*no-owner-template-missing.dt*'
        }

        It 'дерева CONFIGURATION взагалі немає на диску (-NoSourceTrees) — теж зупинка, не лише на порожній теці' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-owner-missing-dir') -WithHooks -NoSourceTrees
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*власника*'
            Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
        }

        It 'змішаний воркспейс: порожня CONFIGURATION під vendor — зупинка лишається' {
            # Типова фікстура: base — truth: vendor, дерево порожнє. Зупинка — до будь-якого
            # виклику платформи (throw у Invoke-KitProvision стоїть до гілки -Apply).
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'owner-vendor-still') -WithHooks
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*бракує власника*'
            Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
        }

        It 'клієнтський воркспейс, поставка застаріла — дерево не придатне, рецепт (ii), не зупинка' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'prov-stale') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithSupply
            [System.IO.File]::WriteAllBytes((Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..77))
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -BeLike '*поставка вендора stale*рецепт (ii)*'
        }

        It 'непорожній cf/src (власник є) — «порожня» проходить як і раніше, попри Adopted-об''єкти в розширенні' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'owner-present-adopted') -WithHooks
            Add-KitOwnerTree -Repo $repo
            $cfgPath = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
            Add-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '<ObjectBelonging>Adopted</ObjectBelonging>'

            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeLike '*порожн*'
            $r.Output | Should -Not -BeLike '*бракує власника*'
        }
    }
    It '-Source звужує до воркспейсу, який містить це джерело' {
        # Живий прогін (SimplyConnect, 2026-09-15): provision -Source <розширення> створив
        # бази агента для ОБОХ воркспейсів репозиторію — зайва порожня файлова база на диску
        # й зайвий запуск Конфігуратора (а отже зайнята ліцензія) на кожен нецільовий
        # воркспейс, без жодного попередження.
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
                @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(
                @{ Name = 'baseBeta'; Type = 'CONFIGURATION'; Path = 'cf/src' }
                @{ Name = 'Beta_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'provision-source') -Workspaces $ws
        Add-KitOwnerTree -Repo $repo -Workspaces $ws

        $r = Invoke-Provision -Repo $repo -More @('-Source', 'Beta_SMB')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Beta_SMB*'
        $r.Output | Should -Not -BeLike '*Alpha_SMB*'
    }

    It '-Source, якого немає в маніфесті, зупиняє з переліком наявних' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'provision-source-missing')
        Add-KitOwnerTree -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Source', 'НемаТакого')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB*'
    }
}

Describe 'kit provision 1.5.0 — хто створює базу (спека §4.2, §10)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Provision { param([string]$Repo, [string[]]$More = @())
            Invoke-KitCommand -Kit $script:Kit -Command 'provision' -Repo $Repo -More $More }
        function script:Add-Owner { param([string]$Repo)
            $dir = Join-Path $Repo 'Alpha_SMB/cf/src'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base') }
        $script:StorageWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        function script:Test-AdminShare { Test-Path -LiteralPath ('\\localhost\' + ((Split-Path -Qualifier $TestDrive) -replace ':', '$') + '\') }
        function script:Get-UncAlias { param([string]$Path) '\\localhost\' + ($Path -replace '^([A-Za-z]):', '$1$') }
        function script:New-TwoWsRepo { param([string]$Name, [switch]$NoBBuild, [string]$OverlayText)
            $ws = [ordered]@{
                'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
                'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -WithHooks -WithAgentBase -OverlayText $OverlayText
            foreach ($n in 'Alpha_SMB', 'Beta_SMB') {
                $dir = Join-Path $repo "$n/cf/src"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base')
            }
            if ($NoBBuild) { Remove-Item -LiteralPath (Join-Path $repo 'Beta_SMB/build') -Recurse -Force }
            $repo }
    }

    It 'файлова, дерево придатне: прев''ю друкує infobase.create і push, без CREATEINFOBASE' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fit') -WithHooks
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*unica.run {"op":"infobase.create","args":{},"dryRun":true}*'
        $r.Output | Should -BeLike '*unica.run {"op":"push","args":{},"dryRun":true}*'
    }
    It 'файлова придатна, -Apply -Force: прибрано теку бази й пам''ять раннера, бази kit не створював (П7)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fit-force') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path (Join-Path $mem 'hashes') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'generation.json') -Value '{}' -Encoding UTF8
        $owner = Join-Path $repo 'Alpha_SMB/build/infobases/owner.json'
        Set-Content -LiteralPath $owner -Value '{}' -Encoding UTF8
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
        Test-Path -LiteralPath $mem | Should -BeFalse
        Test-Path -LiteralPath $owner | Should -BeTrue -Because 'мітку власника й замок поруч не чіпати (§10 П7)'
        $r.Output | Should -BeLike '*"op":"infobase.create"*'
    }
    It 'без -Apply нічого не прибирає: ні базу, ні пам''ять раннера' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview-keeps') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        Test-Path -LiteralPath $mem | Should -BeTrue
    }
    It 'база існує, -Apply без -Force — зупинка, нічого не прибрано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'exists') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*База агента вже є*-Force*'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        Test-Path -LiteralPath $mem | Should -BeTrue
    }
    It 'пам''ять раннера — посилання (junction) назовні: відмова до будь-якого видалення, ціль ціла (П25)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mem-link') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $outside = Join-Path $TestDrive 'mem-link-target'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'x'
        $infobases = Join-Path $repo 'Alpha_SMB/build/infobases'
        New-Item -ItemType Directory -Path $infobases -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $infobases 'origin') -Target $outside | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*посиланням*'
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue -Because 'база не прибрана, бо відмова передує видаленню'
    }
    It 'рецепт (i): truth: storage, дерева немає — прев''ю: kit створить порожню, далі kit sync' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'r1') -Workspaces $script:StorageWs -NoSourceTrees -WithHooks
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*не придатне*рецепт (i)*'
        $r.Output | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $r.Output | Should -Not -BeLike '*"op":"infobase.create"*'
    }
    It 'рецепт (ii): поставка без .cf — прев''ю: далі kit verify, не push' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'r2') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Remove-Item -Force
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*рецепт (ii)*'
        $r.Output | Should -BeLike '*kit verify -Source base*'
        $r.Output | Should -Not -BeLike '*"op":"push"*'
    }
    It 'з .dt: infobase.restore з абсолютним шляхом, потім push force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dt') -WithHooks
        Add-Owner -Repo $repo
        $dt = Join-Path $TestDrive 'demo.dt'; Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Template', $dt)
        $r.Output | Should -BeLike '*"op":"infobase.restore","args":{"input":"*demo.dt","mode":"create"}*'
        $r.Output | Should -BeLike '*"op":"push","args":{"force":true}*'
    }
    It 'серверна без -ServerBase — код 1, рецепт з обома варіантами' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-ServerBase New*-ServerBase Existing*'
    }
    It 'серверна New без dbms — код 1, називає відсутні ключі' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-nodbms') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL' })
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*server, name, locale*'
    }
    It 'серверна New: прев''ю — застереження CrSQLDB з іменем бази даних, infobase.create, push force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-new') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk' })
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike "*CrSQLDB=Y*'agent_db'*'pg1'*"
        $r.Output | Should -BeLike '*infobases.origin.cluster { user, password }*'
        $r.Output | Should -BeLike '*"op":"infobase.create"*"op":"push","args":{"force":true}*'
    }
    It 'серверна Existing: прев''ю не прибирає пам''ять раннера, -Apply прибирає (П7)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-ex') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $p = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing')
        $p.ExitCode | Should -Be 0 -Because $p.Output
        Test-Path -LiteralPath $mem | Should -BeTrue
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath $mem | Should -BeFalse
        $r.Output | Should -BeLike '*"op":"push","args":{"force":true}*'
    }
    It '-ServerBase на файловій базі — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file-sb') -WithHooks
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-ServerBase стосується лише серверної бази*'
    }
    It 'шаблон .dt усередині теки бази — відмова до видалення, файл цілий (файл людини)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl-in-base') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $dt = Join-Path $repo 'Alpha_SMB/build/ib/my.dt'
        Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force', '-Template', $dt)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Шаблон бази (.dt) лежить у теці, яку kit прибирає*'
        Test-Path -LiteralPath $dt | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'шаблон .dt усередині пам''яті раннера — відмова до видалення, файл цілий' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl-in-mem') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $dt = Join-Path $mem 'my.dt'
        Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force', '-Template', $dt)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Шаблон бази (.dt) лежить у теці, яку kit прибирає*'
        Test-Path -LiteralPath $dt | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'серверна -ServerBase New, дерево непридатне: крок kit sync, без push' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-new-unfit') -Workspaces $script:StorageWs -NoSourceTrees -WithHooks
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk' })
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*"op":"infobase.create"*'
        $r.Output | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $r.Output | Should -Not -BeLike '*"op":"push"*'
        $r.Output | Should -BeLike '*створює її Уніка*'
        $r.Output | Should -Not -BeLike '*створює теж kit*'
    }
    It 'серверна -ServerBase Existing, дерево непридатне: крок kit sync, без push' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-ex-unfit') -Workspaces $script:StorageWs -NoSourceTrees -WithHooks
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $r.Output | Should -Not -BeLike '*"op":"push"*'
        $r.Output | Should -Not -BeLike '*"op":"infobase.create"*'
    }
    It 'файлова з .dt, дерево непридатне: restore і крок kit, без push; базу створює Уніка, не kit' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dt-unfit') -Workspaces $script:StorageWs -NoSourceTrees -WithHooks
        $dt = Join-Path $TestDrive 'unfit.dt'; Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Template', $dt)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*"op":"infobase.restore"*'
        $r.Output | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $r.Output | Should -Not -BeLike '*"op":"push"*'
        $r.Output | Should -BeLike '*створює її Уніка*'
        $r.Output | Should -Not -BeLike '*створює теж kit*'
        $r.Output | Should -Not -BeLike '*kit сам створить*'
    }
    It 'серверна + -Template — відмова' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-tpl') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $dt = Join-Path $TestDrive 'srv.dt'; Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing', '-Template', $dt)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*для серверної бази агента не підтримується*'
    }
    It 'серверна New: паролі dbms і cluster не потрапляють у вивід' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-pwd') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk'; password = 'SECRET-dbms' })
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value "`n    cluster:`n      user: 'adm'`n      password: 'SECRET-cluster'"
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 0 -Because ($r.Output -replace 'SECRET', 'S*CRET')
        $r.Output | Should -Not -BeLike '*SECRET*'
    }
    It 'П26 п. 1: дев-база записана з префіксом \\?\ (та сама тека) — відмова, дев-база ціла' {
        $repoPath = Join-Path $TestDrive 'ov-long'
        $overlay = "infobases:`n  dev:`n    connection: 'File=\\?\$repoPath\Alpha_SMB\build\ib'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*дев-базою людини*dev*'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 1: дев-база вкладена в теку агента — відмова, дев-база ціла' {
        $repoPath = Join-Path $TestDrive 'ov-nested'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$repoPath\Alpha_SMB\build\ib\dev'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $dev = Join-Path $repo 'Alpha_SMB/build/ib/dev'
        New-Item -ItemType Directory -Path $dev -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Value 'людська база'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*дев-базою людини*dev*'
        (Get-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 1: дев-база є батьком теки агента — відмова, дев-база ціла' {
        $repoPath = Join-Path $TestDrive 'ov-parent'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$repoPath\Alpha_SMB\build'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/dev-data.txt') -Value 'людська база'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*дев-базою людини*dev*'
        (Get-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/dev-data.txt') -Raw).Trim() | Should -Be 'людська база'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 1: build — junction на теку з дев-базою — відмова, дев-база ціла' {
        $devDir = Join-Path $TestDrive 'ov-junction-dev'
        New-Item -ItemType Directory -Path (Join-Path $devDir 'ib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $devDir 'ib/1Cv8.1CD') -Value 'людська база'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$devDir'"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ov-junction') -WithHooks -OverlayText $overlay
        Add-Owner -Repo $repo
        New-Item -ItemType Junction -Path (Join-Path $repo 'Alpha_SMB/build') -Target $devDir | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*дев-базою людини*dev*'
        (Get-Content -LiteralPath (Join-Path $devDir 'ib/1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
    }
    It 'П26 п. 1, контроль: дев-база build\ib2 поруч з build\ib — не перетин, provision іде далі' {
        $repoPath = Join-Path $TestDrive 'ov-sibling'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$repoPath\Alpha_SMB\build\ib2'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    foreach ($case in @(
        @{ Name = 'build/artifacts'; Rel = 'build/artifacts'; Phrase = '*це не база агента*' }
        @{ Name = 'build/adopt'; Rel = 'build/adopt'; Phrase = '*це не база агента*' }
        @{ Name = 'build/infobases'; Rel = 'build/infobases'; Phrase = '*перетинається з*infobases*' }
    )) {
        It "П26 п. 2: connection = File=$($case.Name) — відмова навіть з -Force, вміст і owner.mark/lock цілi" -TestCases @($case) {
            param($Name, $Rel, $Phrase)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('notbase-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -WithHooks
            Add-Owner -Repo $repo
            Set-KitFakeAgentBase -Repo $repo -Connection "File=$Rel"
            $dir = Join-Path $repo "Alpha_SMB/$Rel"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'precious.txt') -Value 'x'
            $infobases = Join-Path $repo 'Alpha_SMB/build/infobases'
            New-Item -ItemType Directory -Path $infobases -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $infobases 'owner.mark') -Value 'x'
            Set-Content -LiteralPath (Join-Path $infobases 'lock') -Value 'x'
            $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -BeLike $Phrase
            Test-Path -LiteralPath (Join-Path $dir 'precious.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $infobases 'owner.mark') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $infobases 'lock') | Should -BeTrue
        }
    }
    It 'П26 п. 2, контроль: порожня наявна тека на місці бази — дозволено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty-dir') -WithHooks
        Add-Owner -Repo $repo
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'П26 п. 6 (G3): дев-база записана як \\localhost\C$\… (та сама тека) — відмова до видалення, дев-база ціла, маркера не лишилось' {
        $repoPath = Join-Path $TestDrive 'alias-unc'
        $agent = Join-Path $repoPath 'Alpha_SMB\build\ib'
        $unc = '\\localhost\' + ($agent -replace '^([A-Za-z]):', '$1$')
        if (-not (Test-Path -LiteralPath ('\\localhost\' + ((Split-Path -Qualifier $TestDrive) -replace ':', '$') + '\'))) {
            Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return
        }
        $overlay = "infobases:`n  dev:`n    connection: 'File=$unc'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*дев-база 'dev' — та сама тека чи одна в одній (через псевдонім шляху*"
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 6: дев-база всередині теки агента через псевдонім \\localhost\C$\… — відмова (перевірка предків), дев-база ціла' {
        $repoPath = Join-Path $TestDrive 'alias-unc-nested'
        $agent = Join-Path $repoPath 'Alpha_SMB\build\ib'
        $unc = '\\localhost\' + ($agent -replace '^([A-Za-z]):', '$1$')
        if (-not (Test-Path -LiteralPath ('\\localhost\' + ((Split-Path -Qualifier $TestDrive) -replace ':', '$') + '\'))) {
            Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return
        }
        $overlay = "infobases:`n  dev:`n    connection: 'File=$unc\dev\base'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $dev = Join-Path $repo 'Alpha_SMB/build/ib/dev/base'
        New-Item -ItemType Directory -Path $dev -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Value 'людська база'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*дев-база 'dev' — та сама тека чи одна в одній*"
        (Get-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 6: дев-база через subst-диск — відмова, дев-база ціла' {
        $letter = @('Z', 'Y', 'X', 'W', 'V', 'U') | Where-Object { -not (Test-Path -LiteralPath "${_}:\") } | Select-Object -First 1
        $repoPath = Join-Path $TestDrive 'alias-subst'
        $overlay = "infobases:`n  dev:`n    connection: 'File=${letter}:\ib'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $null = & subst "${letter}:" (Join-Path $repo 'Alpha_SMB\build') 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "${letter}:\ib")) {
            Set-ItResult -Skipped -Because 'subst недоступний на цій машині'; return
        }
        try {
            $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        } finally { $null = & subst "${letter}:" /d 2>&1 }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*дев-база 'dev' — та сама тека чи одна в одній*"
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 6, контроль: дев-база на іншому шляху без перетину — видалення дозволене, маркера не лишилось' {
        $dev = Join-Path $TestDrive 'alias-control-dev'
        New-Item -ItemType Directory -Path $dev -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Value 'людська база'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$dev'"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'alias-control') -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
        Test-Path -LiteralPath $mem | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 5: база A збігається з базою B (абсолютний File= на ту саму теку) — відмова, -Workspace B' {
        $repo = New-TwoWsRepo -Name 'x-same'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection ('File=' + (Join-Path $repo 'Beta_SMB/build/ib'))
        $r = Invoke-Provision -Repo $repo -More @('-Workspace', 'Beta_SMB', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*перетинається з базою агента воркспейсу 'Alpha_SMB'*"
        Test-Path -LiteralPath (Join-Path $repo 'Beta_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 5 (головний): -Workspace B при базі A, вкладеній у теку B — відмова, база A ціла за вмістом' {
        $repo = New-TwoWsRepo -Name 'x-nested'
        $a = Join-Path $repo 'Beta_SMB/build/ib/a'
        New-Item -ItemType Directory -Path $a -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $a '1Cv8.1CD') -Value 'база A'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection "File=$a"
        $r = Invoke-Provision -Repo $repo -More @('-Workspace', 'Beta_SMB', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*перетинається з базою агента воркспейсу 'Alpha_SMB'*"
        (Get-Content -LiteralPath (Join-Path $a '1Cv8.1CD') -Raw).Trim() | Should -Be 'база A'
    }
    It 'П26 п. 5: база A — батько бази B — відмова, база A ціла' {
        $repo = New-TwoWsRepo -Name 'x-parent'
        $keep = Join-Path $repo 'Beta_SMB/build/keep.txt'
        Set-Content -LiteralPath $keep -Value 'база A'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection ('File=' + (Join-Path $repo 'Beta_SMB/build'))
        $r = Invoke-Provision -Repo $repo -More @('-Workspace', 'Beta_SMB', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*перетинається з базою агента воркспейсу 'Alpha_SMB'*"
        Test-Path -LiteralPath $keep | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'Beta_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 5: база B перетинається з infobases воркспейсу A (build B — junction на build A) — відмова' {
        $repo = New-TwoWsRepo -Name 'x-mem-theirs' -NoBBuild
        New-Item -ItemType Junction -Path (Join-Path $repo 'Beta_SMB/build') -Target (Join-Path $repo 'Alpha_SMB/build') | Out-Null
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection 'File=build/infobases/x'
        $r = Invoke-Provision -Repo $repo -More @('-Workspace', 'Beta_SMB', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*лежить у '<workPath>/infobases' воркспейсу 'Alpha_SMB'*"
    }
    It 'П26 п. 5: база A лежить в infobases воркспейсу B (пам''ять раннера B) — відмова, -Workspace B' {
        $repo = New-TwoWsRepo -Name 'x-mem-mine'
        $a = Join-Path $repo 'Beta_SMB/build/infobases/a'
        New-Item -ItemType Directory -Path $a -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $a '1Cv8.1CD') -Value 'база A'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection "File=$a"
        $r = Invoke-Provision -Repo $repo -More @('-Workspace', 'Beta_SMB', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*база агента воркспейсу 'Alpha_SMB' лежить у 'build/infobases' цього воркспейсу*"
        (Get-Content -LiteralPath (Join-Path $a '1Cv8.1CD') -Raw).Trim() | Should -Be 'база A'
    }
    It 'П26 п. 5, контроль: build/ibA і build/ibB — дозволено для обох воркспейсів' {
        $repo = New-TwoWsRepo -Name 'x-control'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection 'File=build/ibA'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection 'File=build/ibB'
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'П26 п. 4: два воркспейси, перший валідний, другий відмовляє — перший цілий (база й пам''ять раннера), код 1 з переліком' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/artifacts'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'two-pass') -Workspaces $ws -WithHooks -WithAgentBase
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') {
            $dir = Join-Path $repo "$n/cf/src"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base')
        }
        $art = Join-Path $repo 'Beta_SMB/build/artifacts'
        New-Item -ItemType Directory -Path $art -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $art 'precious.txt') -Value 'x'
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Перевірки перед змінами не пройдено*Beta_SMB*'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        Test-Path -LiteralPath $mem | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $art 'precious.txt') | Should -BeTrue
    }
    It 'П26 п. 6 (Step 12): два воркспейси, відмова другого на маркер-рівні (псевдонім) — перший цілий: база й пам''ять раннера, маркерів немає' {
        if (-not (Test-AdminShare)) { Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return }
        $name = 'mk-two-ws'
        $unc = Get-UncAlias (Join-Path (Join-Path $TestDrive $name) 'Beta_SMB\build\ib')
        $repo = New-TwoWsRepo -Name $name -OverlayText "infobases:`n  dev:`n    connection: 'File=$unc'"
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'hash.txt') -Value 'пам''ять'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*Перевірка псевдонімів шляху не пройдена*база агента воркспейсу Beta_SMB і дев-база 'dev' — та сама тека чи одна в одній*"
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $mem 'hash.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'Beta_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 6 (Step 12): відмова на пам''яті раннера того самого воркспейсу — база агента теж ціла (раніше її вже було видалено)' {
        if (-not (Test-AdminShare)) { Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return }
        $repoPath = Join-Path $TestDrive 'mk-memory'
        $unc = Get-UncAlias (Join-Path $repoPath 'Alpha_SMB\build\infobases\origin\dev')
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText "infobases:`n  dev:`n    connection: 'File=$unc'"
        Add-Owner -Repo $repo
        $dev = Join-Path $repo 'Alpha_SMB/build/infobases/origin/dev'
        New-Item -ItemType Directory -Path $dev -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Value 'людська база'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*пам'ять раннера бази origin воркспейсу Alpha_SMB і дев-база 'dev' — та сама тека чи одна в одній*"
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $dev '1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 7 (N-1): шаблон записано як \\localhost\C$\…\build\ib\my.dt — відмова до видалення, my.dt і база цілі' {
        if (-not (Test-AdminShare)) { Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl-alias') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $dt = Join-Path $repo 'Alpha_SMB/build/ib/my.dt'
        Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force', '-Template', (Get-UncAlias $dt))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*шаблон бази (.dt) — та сама тека чи одна в одній (через псевдонім шляху*'
        (Get-Content -LiteralPath $dt -Raw).Trim() | Should -Be 'dt'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 7 (N-1, регресія I-3): той самий шаблон звичайним шляхом — відмова, my.dt цілий' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl-plain') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $dt = Join-Path $repo 'Alpha_SMB/build/ib/my.dt'
        Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force', '-Template', $dt)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Шаблон бази (.dt) лежить у теці, яку kit прибирає*'
        (Get-Content -LiteralPath $dt -Raw).Trim() | Should -Be 'dt'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
    }
    It 'П26 п. 7 (N-1, контроль): шаблон поза теками видалення — дозволено, база прибрана, my.dt цілий, маркерів немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tpl-out') -WithHooks -WithAgentBase
        Add-Owner -Repo $repo
        $dt = Join-Path $TestDrive 'tpl-out-files/my.dt'
        New-Item -ItemType Directory -Path (Split-Path $dt) -Force | Out-Null
        Set-Content -LiteralPath $dt -Value 'dt'
        $r = Invoke-Provision -Repo $repo -More @('-Apply', '-Force', '-Template', $dt)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (Get-Content -LiteralPath $dt -Raw).Trim() | Should -Be 'dt'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
    }
    It 'П26 п. 5: серверні бази двох воркспейсів з тим самим сервером і Ref — відмова до видалення, пам''ять раннера ціла' {
        $repo = New-TwoWsRepo -Name 'srv-same-ref'
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') { Set-KitFakeAgentBase -Repo $repo -Workspace $n -Connection 'Srvr=VSDEV;Ref=agent_shared;' }
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'hash.txt') -Value 'пам''ять'
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing', '-Apply', '-Force')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*перетинається з базою агента воркспейсу 'Beta_SMB'*"
        Test-Path -LiteralPath (Join-Path $mem 'hash.txt') | Should -BeTrue
    }
    It 'П26 п. 5, контроль: серверні бази з різним Ref — дозволено' {
        $repo = New-TwoWsRepo -Name 'srv-diff-ref'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection 'Srvr=VSDEV;Ref=agent_a;'
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection 'Srvr=VSDEV;Ref=agent_b;'
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing', '-Apply', '-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'П16: немає infobases.origin — код 1, рецепт v8storagekit:provision' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-origin') -WithHooks -Workspaces ([ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } })
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не налаштована*v8storagekit:provision*'
        $r.Output | Should -Not -BeLike '*у v8project.yaml немає infobase:*'
    }
    It 'П16: лише зовнішні обробки — код 0, «бази тут не буває»' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -WithHooks -Workspaces ([ordered]@{
            'Epf' = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } })
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*бази агента тут не буває*'
    }
}

Describe 'kit provision — CreatedBy у результаті (хто створив базу), у процесі' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/provision.psm1").Path -Force
        $script:StorageWs2 = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        function script:Add-Owner2 { param([string]$Repo)
            $dir = Join-Path $Repo 'Alpha_SMB/cf/src'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base') }
    }
    It 'непридатне дерево, файлова порожня: CreatedBy = kit (платформу замокано)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-kit') -Workspaces $script:StorageWs2 -NoSourceTrees -WithHooks
        Mock -ModuleName provision New-V8FileInfobase { }
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        @($r.Provisioned).Count | Should -Be 1
        $r.Provisioned[0].CreatedBy | Should -Be 'kit'
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 1
    }
    It 'придатне дерево, файлова порожня: CreatedBy = unica, kit платформу не кличе' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-unica') -WithHooks
        Add-Owner2 -Repo $repo
        Mock -ModuleName provision New-V8FileInfobase { }
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $r.Provisioned[0].CreatedBy | Should -Be 'unica'
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 0
    }
    It 'серверна Existing: CreatedBy = existing' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-existing') -WithHooks
        Add-Owner2 -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -ServerBase Existing
        $r.Provisioned[0].CreatedBy | Should -Be 'existing'
    }
    It 'серверна New: CreatedBy = unica' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-srvnew') -WithHooks
        Add-Owner2 -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk' })
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -ServerBase New
        $r.Provisioned[0].CreatedBy | Should -Be 'unica'
    }
}

Describe 'kit provision — маркер-фаза й єдиний перелік захищених шляхів (П26 п. 6–7), у процесі' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/provision.psm1").Path -Force
        function script:Add-Owner3 { param([string]$Repo)
            $dir = Join-Path $Repo 'Alpha_SMB/cf/src'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base') }
        function script:Test-AdminShare3 { Test-Path -LiteralPath ('\\localhost\' + ((Split-Path -Qualifier $TestDrive) -replace ':', '$') + '\') }
    }

    It 'збій запису маркера — відмова (fail-closed), нічого не видалено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mk-fail') -WithHooks -WithAgentBase
        Add-Owner3 -Repo $repo
        $mem = Join-Path $repo 'Alpha_SMB/build/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'hash.txt') -Value 'пам''ять'
        Mock -ModuleName provision Set-Content { throw 'диск заповнений' } -ParameterFilter { "$LiteralPath" -like '*.kit-alias-probe-*' }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Invoke-KitProvision -Context $ctx -Apply $true -Force } | Should -Throw '*не вдалося покласти маркер перевірки псевдонімів шляху*'
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $mem 'hash.txt') | Should -BeTrue
    }

    It 'порядок: для кожної теки спершу Assert-SafeWorkPath, потім маркер; теці, якої немає, маркер не потрібен' {
        $work = Join-Path $TestDrive 'mk-order/work'
        $abDir = Join-Path $work 'ib'; $memDir = Join-Path $work 'infobases/origin'
        New-Item -ItemType Directory -Path $abDir -Force | Out-Null   # пам'яті раннера немає
        # Замикання (GetNewClosure) ховає параметри мока від його тіла, тож журнал подій — глобальна змінна.
        $global:KitMarkerEvents = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName provision Assert-SafeWorkPath { $global:KitMarkerEvents.Add('assert:' + (Split-Path "$Path" -Leaf)) }
        Mock -ModuleName provision Set-Content { $global:KitMarkerEvents.Add('marker:' + (Split-Path (Split-Path "$LiteralPath" -Parent) -Leaf)) } -ParameterFilter { "$LiteralPath" -like '*.kit-alias-probe-*' }
        $plan = [pscustomobject]@{ Skip = $false; Server = $false; Ws = [pscustomobject]@{ Path = 'W' }; Ab = [pscustomobject]@{ Path = $abDir }
            AgentWork = $work; MemoryDir = $memDir; Protected = @() }
        $ctx = [pscustomobject]@{ RepoRoot = $TestDrive }
        InModuleScope provision -Parameters @{ Ctx = $ctx; Plan = $plan } { param($Ctx, $Plan) Invoke-KitProtectedPathsMarkerPhase -Context $Ctx -Plans @($Plan) }
        try { $global:KitMarkerEvents -join ',' | Should -Be 'assert:ib,marker:ib,assert:origin' } finally { Remove-Variable -Name KitMarkerEvents -Scope Global -ErrorAction SilentlyContinue }
    }

    Context 'структурна вимога: перелік будує одна функція, і обидва рівні беруть його звідти' {
        It 'фіктивний елемент у переліку: текстовий рівень першого проходу його бачить' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fake-text') -WithHooks -WithAgentBase
            Add-Owner3 -Repo $repo
            $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
            $fake = [pscustomobject]@{ Kind = 'fake'; Other = $null; Label = 'ФІКТИВНИЙ-ЕЛЕМЕНТ'; Path = $ibDir; Connection = $null; Candidates = @(); Against = @('base') }
            Mock -ModuleName provision Get-KitProtectedPaths ({ @($fake) }.GetNewClosure())
            $ctx = Invoke-KitPreflight -RepoRoot $repo
            { Invoke-KitProvision -Context $ctx -Apply $true -Force } | Should -Throw '*ФІКТИВНИЙ-ЕЛЕМЕНТ перетинається з текою, яку kit прибирає*'
            Test-Path -LiteralPath (Join-Path $ibDir '1Cv8.1CD') | Should -BeTrue
        }
        It 'фіктивний елемент-псевдонім: текст його пропускає, маркер-фаза бачить — база ціла, маркера немає' {
            if (-not (Test-AdminShare3)) { Set-ItResult -Skipped -Because 'адмін-шар \\localhost\C$ недоступний на цій машині'; return }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fake-alias') -WithHooks -WithAgentBase
            Add-Owner3 -Repo $repo
            $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
            $unc = '\\localhost\' + ($ibDir -replace '^([A-Za-z]):', '$1$')
            $fake = [pscustomobject]@{ Kind = 'fake'; Other = $null; Label = 'ФІКТИВНИЙ-ПСЕВДОНІМ'; Path = (Join-Path $TestDrive 'fake-alias-elsewhere'); Connection = $null; Candidates = @($unc); Against = @('base') }
            Mock -ModuleName provision Get-KitProtectedPaths ({ @($fake) }.GetNewClosure())
            $ctx = Invoke-KitPreflight -RepoRoot $repo
            { Invoke-KitProvision -Context $ctx -Apply $true -Force } | Should -Throw '*Перевірка псевдонімів шляху не пройдена*ФІКТИВНИЙ-ПСЕВДОНІМ — та сама тека*'
            Test-Path -LiteralPath (Join-Path $ibDir '1Cv8.1CD') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $repo -Recurse -Force -Filter '.kit-alias-probe-*').Count | Should -Be 0
        }
    }
}

Describe 'kit provision — платформа: порожня база й база з .dt' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Задача 12: власник має бути на диску, інакше -Apply без -Template тепер
        # зупиняється до платформи (Test-KitConfigurationOwnerPresent) — та сама функція,
        # що й у першому Describe цього файлу; окремий BeforeAll в Integration-блоці
        # свій, тож дублюємо, а не покладаємось на видимість між Describe.
        function script:Add-KitOwnerTree {
            param(
                [Parameter(Mandatory)][string]$Repo,
                [System.Collections.IDictionary]$Workspaces
            )
            if (-not $Workspaces) {
                $Workspaces = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
            }
            foreach ($wsName in @($Workspaces.Keys)) {
                foreach ($set in $Workspaces[$wsName]['Sets']) {
                    if ($set.Type -ne 'CONFIGURATION') { continue }
                    $dir = Join-Path $Repo "$wsName/$($set.Path)"
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline `
                        -Value (New-KitFakeConfigurationXml -Name $set.Name)
                }
            }
        }
        # .dt робимо самі: порожня ІБ → /DumpIB. Так тест не залежить від чужих файлів.
        $tmp = Join-Path $TestDrive 'dt-src'
        $ib = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $tmp 'ib') -MustBeUnder $tmp -RepoRoot $tmp)
        $script:Dt = Join-Path $TestDrive 'empty.dt'
        (Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpIB "{0}"' -f $script:Dt)).ExitCode | Should -Be 0
    }
    It 'непридатне дерево (рецепт (i)): kit сам створює порожню базу під <ws>/build/ib' {
        # Придатне дерево базу не створює kit (її створює Уніка), тож «kit створив порожню
        # базу» перевіряється на truth: storage без дерева — єдиному випадку, де першим
        # наповнює kit (спека §3 рішення 4).
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty') -Workspaces $ws -NoSourceTrees -WithHooks
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
    }
    It 'з .dt і -Remember: шаблон записано в накладку, кроки надруковано, базу kit не створював' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'from-dt') -WithHooks
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply -Template $script:Dt -Remember 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -BeLike '*"op":"infobase.restore"*'
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Not -Exist
        (Get-Content (Join-Path $repo 'v8storagekit.local.yaml') -Raw) | Should -BeLike '*agentBase*empty.dt*'
    }

}
