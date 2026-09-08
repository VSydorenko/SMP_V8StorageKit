#Requires -Version 7
Describe 'kit provision — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Provision { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit provision -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }

    It 'прев''ю: порожня файлова база під воркспейсом, без шаблону' {
        $r = Invoke-Provision -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks)
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
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=""D:\""'")
            $r = Invoke-Provision -Repo $repo -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
        }

        It 'F7: infobase.connection = File=build/ib (типовий, під workPath) — не відмовляє на межі' {
            $r = Invoke-Provision -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'normal-path') -WithHooks)
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -BeLike '*лежить поза робочою текою*'
        }

        It 'F7: workPath: ''out'' + File=out/ib — конфігурований workPath проходить (не відмовляє на межі)' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'workpath-out') -WithHooks
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
            $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
            ((Get-Content -LiteralPath $vp -Raw) -replace "workPath: 'build'", "workPath: '.'") |
                Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline
            $r = Invoke-Provision -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*workPath*'
            $r.Output | Should -Not -BeLike '*База агента*'
        }
    }
}

Describe 'kit provision — платформа: порожня база й база з .dt' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # .dt робимо самі: порожня ІБ → /DumpIB. Так тест не залежить від чужих файлів.
        $tmp = Join-Path $TestDrive 'dt-src'
        $ib = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $tmp 'ib') -MustBeUnder $tmp)
        $script:Dt = Join-Path $TestDrive 'empty.dt'
        (Invoke-V8Designer -IbSwitch $ib -Arguments @('/DumpIB "{0}"' -f $script:Dt)).ExitCode | Should -Be 0
    }
    It 'порожня база агента створюється під <ws>/build/ib' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty') -WithHooks
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
