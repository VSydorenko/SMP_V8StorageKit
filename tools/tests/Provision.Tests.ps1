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

    It 'серверна база агента — зупинка з поясненням (спайк §13), навіть із -Apply' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'srv') -WithHooks
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent"";'")
        $r = Invoke-Provision -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Srvr*кластер*'
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
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=cfe/src'")
            $cfg = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
            $cfg | Should -Exist
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            # Перевіряємо саме наявність файлів, а не лише текст винятку: текст пройшов би
            # й тоді, коли теку вже стерто (throw усередині New-V8FileInfobase теж називає
            # шлях). Тут перевірка відмовляє ДО New-V8FileInfobase, тож теки не торкались.
            $cfg | Should -Exist
        }

        It 'F5: infobase.connection = File="D:\" (за межами воркспейсу і репозиторію) — відмова, платформа не викликається' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'outside-drive') -WithHooks
            Add-KitOwnerTree -Repo $repo
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=""D:\""'")
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
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=out/ib'")
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

        It 'CONFIGURATION source-set truth: storage — повідомлення називає kit sync як дешевий варіант' {
            # Той самий маніфестний прийом, що й Sync.Tests.ps1 («сховище КОНФІГУРАЦІЇ»):
            # New-KitFakeRepo сам ставить CONFIGURATION на truth: vendor, тож truth: storage
            # тут задаємо явним -ManifestText. Шлях сховища навмисно неіснуючий — provision
            # (на відміну від sync) до сховища не звертається.
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
            $manifest = @(
                'version: 1', 'product: Fake', 'workspaces:',
                '  - path: Alpha_SMB', '    sources:',
                '      base:', '        truth: storage', "        storage: { path: 'R:\no-such-storage-base' }"
            ) -join "`n"
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'owner-storage-truth') -Workspaces $ws -ManifestText $manifest -WithHooks
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*власника*'
            $r.Output | Should -BeLike '*kit sync*'
            Join-Path $repo 'Alpha_SMB/build/ib' | Should -Not -Exist
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
        $ib = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $tmp 'ib') -MustBeUnder $tmp)
        $script:Dt = Join-Path $TestDrive 'empty.dt'
        (Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpIB "{0}"' -f $script:Dt)).ExitCode | Should -Be 0
    }
    It 'порожня база агента створюється під <ws>/build/ib' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty') -WithHooks
        # «Порожня» тут — про ІНФОБАЗУ (без даних/шаблону), не про власника на диску:
        # Задача 12 блокує саме відсутність власника, тому він тут є (Add-KitOwnerTree),
        # а сам тест і далі перевіряє механіку створення порожньої ІБ.
        Add-KitOwnerTree -Repo $repo
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
    }
    It 'база з .dt і -Remember: створена, шаблон записано в накладку; повторно — лише з -Force' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'from-dt') -WithHooks
        $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply -Template $script:Dt -Remember 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD' | Should -Exist
        (Get-Content (Join-Path $repo 'v8storagekit.local.yaml') -Raw) | Should -BeLike '*agentBase*empty.dt*'
        & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        & pwsh -NoProfile -File $script:Kit provision -RepoRoot $repo -Apply -Force 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

}
