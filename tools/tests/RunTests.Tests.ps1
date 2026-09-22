#Requires -Version 7
Describe 'Run-Tests.ps1 -Only — звуження прогону до названих файлів' {
    # Runner запускається ПІДПРОЦЕСОМ, як решта наскрізних тестів набору (Check/Sync/Verify):
    # вкладений Invoke-Pester у тій самій сесії Pester поводиться непередбачувано. Для звуження
    # взято AgentBase — один із найдешевших файлів: тест, що коштує хвилини, відтворював би саме
    # ту проблему, заради якої -Only і з'явився.
    BeforeAll {
        $script:Runner = (Resolve-Path "$PSScriptRoot/Run-Tests.ps1").Path
        function script:Invoke-Runner {
            param([string[]]$Extra)
            $out = & pwsh -NoProfile -File $script:Runner -ExcludeTag Integration @Extra 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'звужує до названого файлу — сусідні Describe не виконуються' {
        $r = Invoke-Runner -Extra @('-Only', 'AgentBase')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*AgentBase.psm1*'
        # Дискримінуючий бік: якби -Only мовчки ігнорувався, прогін був би повним і цей рядок
        # у виводі з'явився б. Перевірка саме на ВІДСУТНІСТЬ чужого — сама лише наявність
        # AgentBase нічого не доводить, вона є й у повному прогоні.
        $r.Output   | Should -Not -BeLike '*SKILL.md*'
    }

    It 'приймає ім''я з розширенням і без — рівноцінно' {
        (Invoke-Runner -Extra @('-Only', 'AgentBase.Tests.ps1')).Output | Should -BeLike '*AgentBase.psm1*'
    }

    It 'перелік через кому працює саме через -File — форма, яку називає дозволеною CLAUDE.md' {
        # Регресія, що жила непоміченою: через `pwsh -File` аргументи приходять розібраними
        # оболонкою, тож 'AgentBase,PathSafety' доходить ОДНИМ елементом масиву, і скрипт
        # шукав файл 'AgentBase,PathSafety.Tests.ps1'. Запобіжник спрацьовував і падав із
        # переліком — тобто дефект був гучний, але сприймався як описка користувача, а не як
        # непрацездатність задокументованої форми. Invoke-Runner тут не випадково: він теж
        # кличе через -File, тобто тест відтворює саме той шлях, на якому було зламано.
        $r = Invoke-Runner -Extra @('-Only', 'AgentBase,PathSafety')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*AgentBase.psm1*'
        $r.Output   | Should -BeLike '*PathSafety*'
        # Дискримінуючий бік: звуження лишилось звуженням, а не перетворилось на повний прогін.
        $r.Output   | Should -Not -BeLike '*SKILL.md*'
    }

    It 'описка в імені — зупинка з переліком доступних, а не мовчазні «0 тестів»' {
        # Найважливіший тест файлу. Прогін нуля тестів завершується кодом 0 і рядком
        # "Tests Passed: 0, Failed: 0", який читається як успіх — саме тому неіснуючий файл
        # мусить зупиняти, а не звужувати до порожнечі.
        $r = Invoke-Runner -Extra @('-Only', 'НемаєТакого')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*НемаєТакого.Tests.ps1*'
        $r.Output   | Should -BeLike '*Доступні:*AgentBase*'
        $r.Output   | Should -Not -BeLike '*Tests Passed: 0*'
    }
}

Describe 'Run-Tests.ps1 — контракт паралельного раннера під машинною охороною (Task 4)' {
    # П'ять властивостей нижче на справжньому дереві перевірити неможливо (бриф task-4):
    # зіпсований воркер зіпсував би прогін усім, а груп "<база>.*" до Block B ще не існує.
    # Тому тест будує ВЛАСНУ міні-пісочницю під $TestDrive — окрему копію мінімального
    # набору tools/tests, а не справжній набір. Copy-KitTools (fixtures/KitFixtures.psm1)
    # сюди не годиться: він копіює tools/lib, tools/commands, tools/assets, templates/ і
    # skills/, але не tools/tests/ — тому копіювання власне тут, у самому файлі тесту.
    #
    # Розкладка пісочниці навмисно повторює справжнє дерево від tools/tests угору: Run-Tests.ps1
    # (рядок 112) імпортує "$PSScriptRoot/../lib/PathSafety.psm1" — СУСІДНЮ теку tools/lib, не
    # tools/tests/lib, а корінь для build/ (рядок 114) рахується як ДВА рівні вгору від
    # tools/tests. Без tools/lib/PathSafety.psm1 поруч пісочниця падає на імпорті; без
    # правильної глибини build/ прогону поїде у справжній репозиторій.
    BeforeAll {
        $script:RealTestsDir = $PSScriptRoot
        $script:RealLibDir   = (Resolve-Path "$PSScriptRoot/../lib").Path

        function script:New-KitRunnerSandbox {
            <#
            .SYNOPSIS
                Мінімальна розкладка Run-Tests.ps1 під -Root: сусідня tools/lib (лише файли,
                від яких залежить сам раннер) і tools/tests з копіями раннера, tools/tests/lib
                та двох найдешевших справжніх тестів (PathSafety, RepoRoot).
            .PARAMETER ExtraTestFiles
                Ім'я файлу → вміст. Синтетичні файли групи "Проба" з таблиці брифу Task 4
                додаються сюди — по одному тривіальному It на файл.
            #>
            param(
                [Parameter(Mandatory)][string]$Root,
                [hashtable]$ExtraTestFiles = @{}
            )

            $testsDir = Join-Path $Root 'tools/tests'
            $libDir   = Join-Path $testsDir 'lib'
            $toolsLib = Join-Path $Root 'tools/lib'
            New-Item -ItemType Directory -Path $libDir   -Force | Out-Null
            New-Item -ItemType Directory -Path $toolsLib -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'Run-Tests.ps1')            -Destination (Join-Path $testsDir 'Run-Tests.ps1')
            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'lib/TestRunner.psm1')       -Destination (Join-Path $libDir 'TestRunner.psm1')
            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'lib/Invoke-TestWorker.ps1') -Destination (Join-Path $libDir 'Invoke-TestWorker.ps1')
            Copy-Item -LiteralPath (Join-Path $script:RealLibDir 'PathSafety.psm1')             -Destination (Join-Path $toolsLib 'PathSafety.psm1')
            Copy-Item -LiteralPath (Join-Path $script:RealLibDir 'RepoRoot.psm1')               -Destination (Join-Path $toolsLib 'RepoRoot.psm1')
            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'PathSafety.Tests.ps1')      -Destination (Join-Path $testsDir 'PathSafety.Tests.ps1')
            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'RepoRoot.Tests.ps1')        -Destination (Join-Path $testsDir 'RepoRoot.Tests.ps1')

            foreach ($name in $ExtraTestFiles.Keys) {
                Set-Content -LiteralPath (Join-Path $testsDir $name) -Value $ExtraTestFiles[$name] -Encoding utf8NoBOM
            }

            [pscustomobject]@{
                Root       = $Root
                TestsDir   = $testsDir
                RunnerPath = Join-Path $testsDir 'Run-Tests.ps1'
                WorkerPath = Join-Path $libDir 'Invoke-TestWorker.ps1'
            }
        }

        function script:Invoke-KitRunnerSandbox {
            param([Parameter(Mandatory)]$Lab, [string[]]$Extra = @())
            $out = & pwsh -NoProfile -File $Lab.RunnerPath -ExcludeTag Integration @Extra 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }

        function script:Invoke-KitRunnerSandboxIsolated {
            <#
            .SYNOPSIS
                Той самий підпроцес Run-Tests.ps1, але в ІЗОЛЬОВАНІЙ консолі (Start-Process
                БЕЗ -NoNewWindow) — на відміну від Invoke-KitRunnerSandbox, який ділить
                консоль із батьківським тестовим процесом через голий `&`.
            .DESCRIPTION
                Фікс-раунд 1 (рев'ю Task 4): [Console]::OutputEncoding — властивість самої
                консолі, спільної для батька й дитини під -NoNewWindow (і під голим `&`, який
                теж не створює нового вікна). Якщо предок (реальний Run-Tests.ps1, що виконує
                -Only RunTests) уже виставив UTF-8 на спільній консолі своїми власними рядками
                78-79, дитина успадкує вже виправлену консоль незалежно від того, що робить
                мутація всередині пісочниці — тест тоді нічого не доводить. Нове (приховане)
                вікно дає процесу типову кодову сторінку системи, не успадковану від предка.
            #>
            param([Parameter(Mandatory)]$Lab, [string[]]$Extra = @())
            $outFile = Join-Path $Lab.Root 'isolated-stdout.log'
            $errFile = Join-Path $Lab.Root 'isolated-stderr.log'
            $argList = @('-NoProfile', '-File', $Lab.RunnerPath, '-ExcludeTag', 'Integration') + $Extra
            $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $p.WaitForExit()
            $out = ''
            if (Test-Path -LiteralPath $outFile) { $out += (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
            if (Test-Path -LiteralPath $errFile) { $out += (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
            [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out }
        }

        # Синтетичний кириличний файл для гілки одного процесу (-Only) — captures вивід
        # дочірнього git-процесу у власному тимчасовому репозиторії.
        $script:ProbaKir = @'
Describe 'ПробаКир — синтетична перевірка кирилиці з дочірнього git-процесу (Task 4)' {
    It 'git log повертає кириличний підрядок коміту без спотворення' {
        $repo = Join-Path $TestDrive 'cyr-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'a@b.c'
        git -C $repo config user.name 'Тест'
        Set-Content -LiteralPath (Join-Path $repo 'f.txt') -Value 'x'
        git -C $repo add -A
        git -C $repo commit -q -m 'перевірка кирилиці'
        $out = & git -C $repo log -1 --format=%s 2>&1 | Out-String
        $out | Should -Match 'перевірка кирилиці'
    }
}
'@

        # Синтетичні файли групи "Проба" з таблиці брифу — по одному тривіальному It.
        $script:ProbaA = @'
Describe 'Проба.А — синтетичний файл лабораторної пісочниці Task 4' {
    It 'тривіальна перевірка А' {
        1 | Should -Be 1
    }
}
'@
        $script:ProbaB = @'
Describe 'Проба.Б — синтетичний файл лабораторної пісочниці Task 4' {
    It 'тривіальна перевірка Б' {
        1 | Should -Be 1
    }
}
'@
        $script:ProbaExact = @'
Describe 'Проба (точна назва) — синтетичний файл лабораторної пісочниці Task 4' {
    It 'тривіальна перевірка — точна назва' {
        1 | Should -Be 1
    }
}
'@
    }

    It 'мертвий воркер (throw у копії Invoke-TestWorker.ps1) не дає ЗЕЛЕНО — ненульовий код, причина названа' {
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'dead-worker')

        # Мутація лише копії у $TestDrive: throw одразу після Import-Module Pester — воркер
        # вмирає, не встигнувши виконати жодного файлу й не лишивши підсумку. Мітка нижче
        # підтверджена grep'ом (tools/tests/lib/Invoke-TestWorker.ps1) — трапляється рівно раз.
        $original = Get-Content -LiteralPath $lab.WorkerPath -Raw
        $marker   = 'Import-Module Pester -MinimumVersion 5.0'
        if (([regex]::Matches($original, [regex]::Escape($marker))).Count -ne 1) {
            throw "мітка мутації '$marker' має траплятись у Invoke-TestWorker.ps1 рівно раз — перевір актуальність тесту"
        }
        $mutated = $original.Replace($marker, "throw 'Task4: навмисно зіпсований воркер (лабораторна мутація)'`r`n$marker")
        Set-Content -LiteralPath $lab.WorkerPath -Value $mutated -Encoding utf8NoBOM -NoNewline

        $r = Invoke-KitRunnerSandbox -Lab $lab -Extra @('-Workers', '2')

        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -Match 'воркер \d+ вийшов з кодом \d+'
        # Дискримінуючий бік брифу прямо: відсутність ЗЕЛЕНО, а не лише присутність ЧЕРВОНО —
        # мертвий воркер не сміє дати зелений вердикт навіть частково.
        $r.Output   | Should -Not -BeLike '*ЗЕЛЕНО*'
    }

    It '-Only "Проба" у пісочниці бере ОБИДВА Проба.*, PathSafety.Tests.ps1 відсутній' {
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'only-group') -ExtraTestFiles @{
            'Проба.А.Tests.ps1' = $script:ProbaA
            'Проба.Б.Tests.ps1' = $script:ProbaB
        }
        $r = Invoke-KitRunnerSandbox -Lab $lab -Extra @('-Only', 'Проба')

        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*Проба.А.Tests.ps1*'
        $r.Output   | Should -BeLike '*Проба.Б.Tests.ps1*'
        # Дискримінуючий бік: група не розширилась мовчки до повного набору пісочниці.
        $r.Output   | Should -Not -BeLike '*PathSafety.Tests.ps1*'
        $r.Output   | Should -Not -BeLike '*RepoRoot.Tests.ps1*'
    }

    It 'точна назва "Проба.Tests.ps1" перемагає групу — вибирає лише її' {
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'only-exact') -ExtraTestFiles @{
            'Проба.А.Tests.ps1' = $script:ProbaA
            'Проба.Б.Tests.ps1' = $script:ProbaB
            'Проба.Tests.ps1'   = $script:ProbaExact
        }
        $r = Invoke-KitRunnerSandbox -Lab $lab -Extra @('-Only', 'Проба')

        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeLike '*Проба.Tests.ps1*'
        # Дискримінуючий бік: за наявності точної назви група взагалі не бере участі в прогоні.
        $r.Output   | Should -Not -BeLike '*Проба.А.Tests.ps1*'
        $r.Output   | Should -Not -BeLike '*Проба.Б.Tests.ps1*'
    }

    It 'шапка розкладу — кожен розданий файл рівно один раз, без дублів і пропусків (5 файлів, 3 воркери)' {
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'dispatch-roster') -ExtraTestFiles @{
            'Проба.А.Tests.ps1' = $script:ProbaA
            'Проба.Б.Tests.ps1' = $script:ProbaB
            'Проба.Tests.ps1'   = $script:ProbaExact
        }
        # Незалежний оракул — фактичний перелік файлів на диску, а не структура кошиків
        # усередині Run-Tests.ps1: лік контейнерів (Get-KitRunVerdict) не ловить дубль+пропуск,
        # коли вони скасовують один одного в сумі (5=5), а перелік ІМЕН із шапки ловить.
        $expected = @(Get-ChildItem -LiteralPath $lab.TestsDir -Filter '*.Tests.ps1' -File |
            Select-Object -ExpandProperty Name | Sort-Object)
        $expected.Count | Should -Be 5

        $r = Invoke-KitRunnerSandbox -Lab $lab -Extra @('-Workers', '3')
        $r.ExitCode | Should -Be 0

        $dispatched = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($r.Output -split "`r?`n")) {
            if ($line -match '^воркер \d+: (.+)$') {
                foreach ($name in ($Matches[1] -split ',\s*')) {
                    if ($name) { $dispatched.Add($name.Trim()) }
                }
            }
        }
        (@($dispatched) | Sort-Object) | Should -Be $expected
    }

    It 'кириличний вивід дочірнього процесу з-під воркера читається правильно (Invoke-TestWorker.ps1, ізольована консоль)' {
        # Hooks.Tests.ps1 (кандидат із брифу) для цієї властивості НЕ годиться: він сам
        # виставляє [Console]::OutputEncoding у власному BeforeAll (docs/follow-ups.md §18,
        # фікс саме туди) і тому самозахищений незалежно від воркера. InstallHooks.Tests.ps1
        # теж не годиться: його власний коментар (рядки 51-56) прямо каже, що асерт навмисно
        # ASCII-only, щоб НЕ залежати від кирилиці поза Run-Tests.ps1. Тому тут — власний
        # мінімальний файл, що captures кириличний вивід ДОЧІРНЬОГО git-процесу.
        #
        # Запуск НАПРЯМУ через Invoke-TestWorker.ps1 (не крізь сандбоксовий Run-Tests.ps1) —
        # навмисно, і ось чому: вимір показав, що [Console]::OutputEncoding — властивість
        # КОНСОЛІ, спільної для батька й дитини, коли Start-Process викликано з -NoNewWindow
        # (саме так Run-Tests.ps1 запускає воркерів). Реальний Run-Tests.ps1 виставляє UTF-8
        # ПЕРШИМ (рядки 78-79) ще ДО спавну воркерів, тому нащадок успадковує вже виправлену
        # консоль незалежно від власних рядків воркера — видалення цих рядків лишається
        # непоміченим крізь повну оркестрацію (перевірено окремо: прогін через сандбоксовий
        # Run-Tests.ps1 після видалення рядків із Invoke-TestWorker.ps1 лишався ЗЕЛЕНИМ, бо
        # предок уже виправив спільну консоль). Щоб дійсно перевірити
        # ВЛАСНИЙ захист воркера, він мусить отримати НЕзафіксовану консоль — Start-Process
        # БЕЗ -NoNewWindow (нове, приховане вікно) дає нащадку типову кодову сторінку системи
        # (866 на цій машині), а не успадковану від будь-якого предка. Це відтворює єдиний
        # реалістичний сценарій, де рядки воркера самі по собі мають значення (наприклад,
        # відлагоджувальний запуск ОДНОГО воркера напряму — так само, як у EXAMPLE самого
        # Invoke-TestWorker.ps1).
        $root = Join-Path $TestDrive 'cyrillic-worker'
        $libDir = Join-Path $root 'lib'
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'lib/Invoke-TestWorker.ps1') -Destination (Join-Path $libDir 'Invoke-TestWorker.ps1')

        $probaFile = Join-Path $root 'ПробаКир.Tests.ps1'
        Set-Content -LiteralPath $probaFile -Encoding utf8NoBOM -Value $script:ProbaKir

        $fileListPath = Join-Path $root 'files.txt'
        Set-Content -LiteralPath $fileListPath -Value $probaFile -Encoding utf8NoBOM
        $summaryPath = Join-Path $root 'summary.json'

        $p = Start-Process -FilePath 'pwsh' -ArgumentList @(
                '-NoProfile', '-File', (Join-Path $libDir 'Invoke-TestWorker.ps1'),
                '-FileListPath', $fileListPath, '-SummaryPath', $summaryPath, '-ExcludeTag', 'Integration'
            ) -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $root 'stdout.log') -RedirectStandardError (Join-Path $root 'stderr.log')
        $p.WaitForExit()

        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $summary.Error | Should -BeNullOrEmpty -Because ($summary | ConvertTo-Json -Depth 6)
        $summary.FailedCount | Should -Be 0 -Because (@($summary.Failures) | ConvertTo-Json -Depth 6)
        $summary.TotalCount | Should -Be 1
    }

    It 'гілка одного процесу — кирилиця з дочірнього git-процесу читається правильно (Run-Tests.ps1, ізольована консоль)' {
        # Фікс-раунд 1 (рев'ю Task 4): [Console]::OutputEncoding/$OutputEncoding у
        # Run-Tests.ps1:78-79 несучі САМЕ для гілки одного процесу (-Only/-Serial) — там
        # Pester виконується УСЕРЕДИНІ самого процесу Run-Tests.ps1, воркер не спавниться
        # взагалі, тож рядки воркера (тест вище) на цю гілку не впливають.
        #
        # Виміряно окремо (три сценарії, в ізольованій консолі кожен):
        #   (a) прибрати лише рядки РАННЕРА, гілка одного процесу — ЧЕРВОНО (Pester:
        #       "Expected regular expression '...' to match 'перевірка кирилиці', but it
        #       did not match" — шаблон зі скрипту читається спотвореним під кодовою
        #       сторінкою хоста).
        #   (b) прибрати лише рядки ВОРКЕРА, та сама гілка — ЗЕЛЕНО (контроль: воркер тут
        #       узагалі не бере участі, тож його рядки не можуть щось тримати).
        #   (c) прибрати ОБИДВА набори, паралельна гілка — теж ЧЕРВОНО.
        # Разом це доводить: у паралельному шляху рядки раннера й воркера ВЗАЄМНО
        # НАДЛИШКОВІ (кожен окремо покриває бойовий шлях, ловить лише видалення обох —
        # тест вище це підтверджує зеленим на неушкодженому раннері), а в гілці одного
        # процесу єдиний захист — САМЕ рядки раннера. Цей тест охороняє їх.
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'single-process-cyr') -ExtraTestFiles @{
            'ПробаКир.Tests.ps1' = $script:ProbaKir
        }
        $r = Invoke-KitRunnerSandboxIsolated -Lab $lab -Extra @('-Only', 'ПробаКир')

        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output   | Should -BeLike '*Tests Passed: 1*' -Because $r.Output
    }
}
