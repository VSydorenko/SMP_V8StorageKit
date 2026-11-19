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

    # Review Focus 3 (спека Unica 0.16 §3.4 п.3, §4.2 п.16): kit базу агента не видаляє ніколи. Тека за шляхом
    # бази — зупинка, що називає ОБИДВІ теки для людини (база й пам'ять раннера); маркери в обох лишаються.
    foreach ($case in @(
        @{ Name = 'порожня'; WithCd = $false }
        @{ Name = 'з 1Cv8.1CD';   WithCd = $true }
    )) {
        It "Review Focus 3: тека бази $($case.Name) — зупинка з двома теками, код 1, обидва маркери на місці" -TestCases @($case) {
            param($Name, $WithCd)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('exists-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) -WithHooks
            Add-KitOwnerTree -Repo $repo
            $base = Join-Path $repo 'Alpha_SMB/build/ib'
            $memory = Join-Path $repo 'Alpha_SMB/.local/infobases/origin'
            New-Item -ItemType Directory -Path $base, $memory -Force | Out-Null
            if ($WithCd) { Set-Content -LiteralPath (Join-Path $base 'marker-base.txt') -Value 'x' }
            Set-Content -LiteralPath (Join-Path $memory 'marker-memory.txt') -Value 'x'
            if ($WithCd) { Set-Content -LiteralPath (Join-Path $base '1Cv8.1CD') -Value 'x' }
            foreach ($more in @(@('-Apply'), @())) {
                $r = Invoke-Provision -Repo $repo -More $more
                $r.ExitCode | Should -Be 1 -Because $r.Output
                $r.Output | Should -BeLike '*видаліть*'
                $r.Output.Contains([System.IO.Path]::GetFullPath($base)) | Should -BeTrue -Because 'називає теку бази'
                $r.Output | Should -BeLike '*.local*infobases*origin*' -Because 'називає теку пам''яті раннера'
                $r.Output | Should -BeLike '*"op":"infobase.create"*' -Because 'і крок створення'
                if ($WithCd) { Join-Path $base 'marker-base.txt' | Should -Exist } else { $base | Should -Exist }
                Join-Path $memory 'marker-memory.txt' | Should -Exist
            }
            if ($WithCd) { Join-Path $base '1Cv8.1CD' | Should -Exist }
        }
    }
    It 'пілот §5 п.3: у pwsh -Command $LASTEXITCODE виставлено — 1 на зупинці, 0 на успіху (раніше порожній)' {
        # Без явного `exit 0` у кінці kit.ps1 скрипт, що відпрацював, не встановлює $LASTEXITCODE: у
        # `pwsh -Command "& kit.ps1 …; $LASTEXITCODE"` змінна порожня. Тест міряє саме цю форму виклику, не -File.
        $stop = New-KitFakeRepo -Root (Join-Path $TestDrive 'exit-stop') -WithHooks
        Add-KitOwnerTree -Repo $stop
        New-Item -ItemType Directory -Path (Join-Path $stop 'Alpha_SMB/build/ib') -Force | Out-Null
        $ok = New-KitFakeRepo -Root (Join-Path $TestDrive 'exit-ok') -WithHooks
        Add-KitOwnerTree -Repo $ok
        $codes = foreach ($repo in $stop, $ok) {
            $o = & pwsh -NoProfile -Command "& '$($script:Kit)' provision -RepoRoot '$repo' *> `$null; [string]`$LASTEXITCODE"
            ($o | Select-Object -Last 1)
        }
        $codes[0] | Should -Be '1' -Because 'зупинка: тека бази вже є'
        $codes[1] | Should -Be '0' -Because 'успіх: прев''ю'
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
                $r = Invoke-Provision -Repo $repo -More @('-Apply')
                $r.ExitCode | Should -Not -Be 0
                $r.Output | Should -BeLike '*workPath*збігається з деревом джерела*Рішення за людиною*'
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
    It 'файлова придатна, без .dt: -Apply не створює бази сам; після infobase.create — звичайний push без force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fit-apply') -WithHooks
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse -Because 'базу створює Уніка, kit за придатного дерева її не чіпає'
        $r.Output | Should -BeLike '*"op":"infobase.create"*"op":"push","args":{},"dryRun":true*'
        $r.Output | Should -Not -BeLike '*"force":true*'
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
    It 'серверна без -ServerBase — код 1: базу створює людина в кластері, далі -ServerBase Existing' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-Provision -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*створює людина в кластері*-ServerBase Existing*'
        $r.Output | Should -Not -BeLike '*-ServerBase New*'
    }
    It '-ServerBase New більше не існує — зупинка на прив''язці параметра, код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-new-gone') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'New')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Not -BeLike '*"op":"infobase.create"*'
    }
    It 'серверна Existing: ні прев''ю, ні -Apply нічого не видаляють (пам''ять раннера ціла); крок — push force:true' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-ex') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $mem = Join-Path $repo 'Alpha_SMB/.local/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'generation.json') -Value '{}'
        foreach ($more in @(@('-ServerBase', 'Existing'), @('-ServerBase', 'Existing', '-Apply'))) {
            $r = Invoke-Provision -Repo $repo -More $more
            $r.ExitCode | Should -Be 0 -Because $r.Output
            Join-Path $mem 'generation.json' | Should -Exist
            $r.Output | Should -BeLike '*"op":"push","args":{"force":true}*'
            $r.Output | Should -Not -BeLike '*"op":"infobase.create"*'
        }
    }
    It '-ServerBase на файловій базі — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file-sb') -WithHooks
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-ServerBase стосується лише серверної бази*'
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
    It 'крок наступного kit: (i) називає крок вирівнювання push force:true; (ii) — дослівно Get-KitSupplyRecipe, без власної копії' {
        # Get-KitProvisionNextKitStep не експортується — кличемо в області модуля.
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        $m = Import-Module (Resolve-Path "$PSScriptRoot/../commands/provision.psm1").Path -Force -PassThru
        $src = [pscustomobject]@{ Key = 'base' }
        $i = & $m { param($f) Get-KitProvisionNextKitStep -Fitness $f -MainBranch main -Workspace Alpha_SMB -OnMainBranch $true } `
            ([pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'i'; Supply = $null })
        $i | Should -BeLike '*kit sync -Source base -FromLatest -Apply*'
        $i | Should -BeLike '*push Уніки з "force":true для набору base*'
        foreach ($onMain in $true, $false) {
            $ii = & $m { param($f, $o) Get-KitProvisionNextKitStep -Fitness $f -MainBranch main -Workspace Alpha_SMB -OnMainBranch $o } `
                ([pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'ii'; Supply = 'stale' }) $onMain
            $ii | Should -Be (Get-KitSupplyRecipe -SourceKey base -Workspace Alpha_SMB -MainBranch main -State stale -Purpose check -OnMainBranch $onMain)
        }
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
    It 'серверна Existing: паролі dbms і cluster з v8project.local.yaml не потрапляють у вивід' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv-pwd') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;' -Dbms ([ordered]@{ kind = 'PostgreSQL'; server = 'pg1'; name = 'agent_db'; locale = 'uk'; password = 'SECRET-dbms' })
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value "`n    cluster:`n      user: 'adm'`n      password: 'SECRET-cluster'"
        $r = Invoke-Provision -Repo $repo -More @('-ServerBase', 'Existing')
        $r.ExitCode | Should -Be 0 -Because ($r.Output -replace 'SECRET', 'S*CRET')
        $r.Output | Should -Not -BeLike '*SECRET*'
    }
    It 'П26 п. 1: дев-база записана з префіксом \\?\ (та сама тека) — відмова, дев-база ціла' {
        $repoPath = Join-Path $TestDrive 'ov-long'
        $overlay = "infobases:`n  dev:`n    connection: 'File=\\?\$repoPath\Alpha_SMB\build\ib'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -WithAgentBase -OverlayText $overlay
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
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
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
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
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
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
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*дев-базою людини*dev*'
        (Get-Content -LiteralPath (Join-Path $devDir 'ib/1Cv8.1CD') -Raw).Trim() | Should -Be 'людська база'
    }
    It 'П26 п. 1, контроль: дев-база build\ib2 поруч з build\ib — не перетин, provision іде далі' {
        $repoPath = Join-Path $TestDrive 'ov-sibling'
        $overlay = "infobases:`n  dev:`n    connection: 'File=$repoPath\Alpha_SMB\build\ib2'"
        $repo = New-KitFakeRepo -Root $repoPath -WithHooks -OverlayText $overlay
        Add-Owner -Repo $repo
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'П26 п. 2а: connection = File=build/artifacts, у теці файл — інша зупинка без поради видаляти; тека й вміст цілі, код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'notbase-artifacts') -WithHooks
        Add-Owner -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/artifacts'
        $dir = Join-Path $repo 'Alpha_SMB/build/artifacts'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'precious.txt') -Value 'x'
        foreach ($more in @(@('-Apply'), @())) {
            $r = Invoke-Provision -Repo $repo -More $more
            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -BeLike '*лежить не база агента*перевірте infobases.origin.connection*'
            $r.Output | Should -Not -BeLike '*видаліть*'
            Join-Path $dir 'precious.txt' | Should -Exist
        }
    }
    It 'база не може лежати в .local воркспейсу (пам''ять раннера): workPath .local/infobases + File=.local/infobases/origin — відмова до створення' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'base-in-local') -WithHooks
        Add-Owner -Repo $repo
        $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
        ((Get-Content -LiteralPath $vp -Raw) -replace "workPath: 'build'", "workPath: '.local/infobases'") |
            Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=.local/infobases/origin'
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike "*збігається з '.local' воркспейсу*"
        Join-Path $repo 'Alpha_SMB/.local/infobases/origin' | Should -Not -Exist
    }
    It 'порожня наявна тека на місці бази — теж зупинка: kit не видаляє навіть порожню, тека лишається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty-dir') -WithHooks
        Add-Owner -Repo $repo
        $ib = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Path $ib -Force | Out-Null
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*видаліть*'
        $ib | Should -Exist
    }
    It 'два воркспейси, перший валідний, другий зупиняється — нічого не створено, код 1 з переліком' {
        # Перший воркспейс — рецепт (i) (kit створив би порожню базу), другий — тека за шляхом бази вже є.
        # Перевірки всіх воркспейсів передують будь-якій дії: інакше повторний запуск зупинявся б на базі першого.
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-all-first') -Workspaces $ws -WithHooks -NoSourceTrees
        $dir = Join-Path $repo 'Beta_SMB/cf/src'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Encoding UTF8 -NoNewline -Value (New-KitFakeConfigurationXml -Name 'base')
        $betaIb = Join-Path $repo 'Beta_SMB/build/ib'
        New-Item -ItemType Directory -Path $betaIb -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $betaIb 'marker.txt') -Value 'x'
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Перевірки перед змінами не пройдено*Beta_SMB*'
        Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
        Join-Path $betaIb 'marker.txt' | Should -Exist
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
    It 'непридатне дерево (рецепт (i)), файлова порожня: CreatedBy = kit; створення з -NoReplace на платформі раннера' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-kit') -Workspaces $script:StorageWs2 -NoSourceTrees -WithHooks
        Mock -ModuleName provision New-V8FileInfobase { }
        Mock -ModuleName provision Get-KitAgentPlatform { 'C:\fake\1cv8.exe' }
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -RunnerPath 'fake-runner.exe' 6>&1
        $res = @($r | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        @($res.Provisioned).Count | Should -Be 1
        $res.Provisioned[0].CreatedBy | Should -Be 'kit'
        Should -Invoke -ModuleName provision Get-KitAgentPlatform -Times 1 -ParameterFilter { $RunnerPath -eq 'fake-runner.exe' }
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 1 -ParameterFilter { $NoReplace -and $V8Path -eq 'C:\fake\1cv8.exe' }
    }
    It 'рецепт (ii): дерево є, поставка stale, бази немає — -Apply створює порожню базу (kit) і не друкує infobase.create' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-ii') -Workspaces $script:StorageWs2 -WithSupply -WithGitignore -WithHooks
        [System.IO.File]::WriteAllBytes((Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..77))
        Mock -ModuleName provision New-V8FileInfobase { }
        Mock -ModuleName provision Get-KitAgentPlatform { 'C:\fake\1cv8.exe' }
        $out = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -RunnerPath 'fake-runner.exe' 6>&1
        $text = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | Out-String)
        $res = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $res.Provisioned[0].CreatedBy | Should -Be 'kit'
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 1
        $text | Should -BeLike '*рецепт (ii)*'
        $text | Should -Not -BeLike '*infobase.create*'
    }
    It 'бази немає, пам''ять раннера є — зупинка до створення: kit не створив бази й не торкнувся пам''яті' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-stale-mem') -Workspaces $script:StorageWs2 -NoSourceTrees -WithHooks
        $mem = Join-Path $repo 'Alpha_SMB/.local/infobases/origin'
        New-Item -ItemType Directory -Path $mem -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mem 'generation.json') -Value '{}'
        Mock -ModuleName provision New-V8FileInfobase { }
        Mock -ModuleName provision Get-KitAgentPlatform { 'C:\fake\1cv8.exe' }
        { Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -RunnerPath 'fake-runner.exe' 6>&1 } |
            Should -Throw '*видаліть теку пам''яті раннера*'
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 0
        Join-Path $mem 'generation.json' | Should -Exist
        Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
    }
    It 'придатне дерево, файлова порожня: CreatedBy = unica, kit платформу не кличе й раннера не питає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-unica') -WithHooks
        Add-Owner2 -Repo $repo
        Mock -ModuleName provision New-V8FileInfobase { }
        Mock -ModuleName provision Get-KitAgentPlatform { 'C:\fake\1cv8.exe' }
        Mock -ModuleName provision Get-KitRunnerPath { 'fake-runner.exe' }
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true 6>&1
        @($r | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0].Provisioned[0].CreatedBy | Should -Be 'unica'
        Should -Invoke -ModuleName provision New-V8FileInfobase -Times 0
        Should -Invoke -ModuleName provision Get-KitAgentPlatform -Times 0
        Should -Invoke -ModuleName provision Get-KitRunnerPath -Times 0
    }
    It 'серверна Existing: CreatedBy = existing' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cb-existing') -WithHooks
        Add-Owner2 -Repo $repo
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $r = Invoke-KitProvision -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true -ServerBase Existing 6>&1
        @($r | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0].Provisioned[0].CreatedBy | Should -Be 'existing'
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
