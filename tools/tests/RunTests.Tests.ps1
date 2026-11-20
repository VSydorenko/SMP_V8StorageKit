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

Describe 'Run-Tests.ps1 — контракт паралельного раннера під машинною охороною' {
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
                Ім'я файлу → вміст. Синтетичні файли групи "Проба"
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

        # Синтетичний файл із синтаксичною помилкою (незакрита дужка в '{' після 'if') —
        # ФІНАЛЬНЕ РЕВ'Ю ГІЛКИ, п.1: Pester не запускає жодного It з цього файлу, дискавері
        # провалюється цілим контейнером (перевірено емпірично на Pester 6.1.0:
        # FailedContainersCount = 1, FailedCount = 0, TotalCount = 0 — і те саме для throw у
        # BeforeDiscovery, тож форма помилки тут неважлива, важливий сам факт провалу
        # дискавері). Describe/It зверху навмисно присутні й валідні — щоб довести, що
        # причина провалу саме в дискавері всього ФАЙЛУ (парситься одним цілим), а не в
        # тому, що в файлі взагалі нема тестів.
        $script:ProbaZlamana = @'
Describe 'Проба.Злам — синтетичний файл із синтаксичною помилкою (ФІНАЛЬНЕ РЕВ''Ю ГІЛКИ, п.1)' {
    It 'ніколи не виконається — файл не парситься цілим' {
        $true | Should -Be $true
    }
}

function Проба-ЗламанаФункція {
    param([string]$X)
    if ($X -eq 'a' {
        return 1
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

    It 'файл із синтаксичною помилкою (провал контейнера дискавері) не дає ЗЕЛЕНО — причина названа з іменем файлу (ФІНАЛЬНЕ РЕВ''Ю ГІЛКИ, п.1)' {
        # Без мутації воркера чи раннера: файл сам по собі не парситься, Invoke-Pester
        # повертає TotalCount = 0, FailedCount = 0, FailedContainersCount = 1 — до фіксу це
        # НЕ ловила жодна з п'яти причин Get-KitRunVerdict (containers++ рахував контейнер
        # виконаним незалежно від того, чи він дійшов до кінця), і прогін ішов би ЗЕЛЕНИМ.
        $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive 'broken-discovery') -ExtraTestFiles @{
            'Проба.Злам.Tests.ps1' = $script:ProbaZlamana
        }

        $r = Invoke-KitRunnerSandbox -Lab $lab -Extra @('-Workers', '2')

        # Дискримінуючий бік брифу прямо: до фіксу ExitCode тут був 0, а вивід містив
        # ЗЕЛЕНО — жоден з трьох рядків нижче не пройшов би без зміни в Invoke-TestWorker.ps1
        # (FailedContainersCount) і TestRunner.psm1 (шоста причина Get-KitRunVerdict).
        $r.ExitCode | Should -Not -Be 0 -Because $r.Output
        $r.Output   | Should -Not -BeLike '*ЗЕЛЕНО*'
        # Причина названа: і слово "дискавері" (не загальна фраза), і саме ім'я файлу, що
        # провалився, — не просто лічильник без адреси.
        $r.Output   | Should -BeLike '*дискавері*'
        $r.Output   | Should -BeLike '*Проба.Злам.Tests.ps1*'
    }
}
