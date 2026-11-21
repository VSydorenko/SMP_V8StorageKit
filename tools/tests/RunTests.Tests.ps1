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
            Copy-Item -LiteralPath (Join-Path $script:RealTestsDir 'lib/TestChanges.psm1')      -Destination (Join-Path $libDir 'TestChanges.psm1')
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
            # -Full: контракт паралельної гілки; голий виклик тепер іде за зміною (#88).
            $out = & pwsh -NoProfile -File $Lab.RunnerPath -ExcludeTag Integration -Full @Extra 2>&1 | Out-String
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

    # Прогін за зміною (#88): голий виклик без -Full. Пісочниця стає git-репозиторієм з
    # origin/main на базовому коміті; зміна — поверх нього.
    Context 'прогін за зміною від origin/main (#88)' {
        BeforeAll {
            $script:DocsProbe = @'
Describe 'Проба.Документи — тест, що читає документи' -Tag 'Docs' {
    It 'виконався' { $true | Should -BeTrue }
}
'@
            function script:New-KitChangeLab([string]$Name) {
                $lab = New-KitRunnerSandbox -Root (Join-Path $TestDrive $Name) -ExtraTestFiles @{ 'ПробаДоки.Tests.ps1' = $script:DocsProbe }
                $g = @('-C', $lab.Root, '-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'core.autocrlf=false')
                & git @g init -q -b main 2>&1 | Out-Null
                & git @g add -A 2>&1 | Out-Null
                & git @g commit -q -m base 2>&1 | Out-Null
                & git @g update-ref refs/remotes/origin/main HEAD 2>&1 | Out-Null
                $lab | Add-Member -NotePropertyName Git -NotePropertyValue $g -PassThru
            }
            function script:Invoke-KitChangeRun($Lab) {
                $out = & pwsh -NoProfile -File $Lab.RunnerPath -ExcludeTag Integration 2>&1 | Out-String
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
            }
        }

        It 'змінено лише документ — прогін лише тестів з тегом Docs, код 0' {
            $lab = New-KitChangeLab 'change-docs'
            New-Item -ItemType Directory -Force -Path (Join-Path $lab.Root 'docs') | Out-Null
            Set-Content -LiteralPath (Join-Path $lab.Root 'docs/a.md') -Value 'текст' -Encoding utf8NoBOM

            $r = Invoke-KitChangeRun $lab

            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output   | Should -BeLike '*Змінено лише документи*ПробаДоки*'
            $r.Output   | Should -BeLike '*Проба.Документи*'
            # Тести коду (PathSafety, RepoRoot у пісочниці) не запускались.
            $r.Output   | Should -Not -BeLike '*Файлів: *воркерів*'
            $r.Output   | Should -Not -BeLike '*PathSafety.Tests.ps1*'
        }

        It 'змінено код — нічого не запущено, код 3 і підказка -Only; повний набір лише з -Full' {
            $lab = New-KitChangeLab 'change-code'
            Add-Content -LiteralPath (Join-Path $lab.Root 'tools/lib/PathSafety.psm1') -Value '# зміна'

            $r = Invoke-KitChangeRun $lab

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output   | Should -BeLike '*НЕ ПЕРЕВІРЕНО: змінено код*tools/lib/PathSafety.psm1*'
            $r.Output   | Should -BeLike '*next: *-Only *PathSafety*'
            $r.Output   | Should -Not -BeLike '*Tests Passed*'
            $r.Output   | Should -Not -BeLike '*Файлів: *воркерів*'
        }

        It 'код, перейменований у документ, — усе ще код (перейменування за обома шляхами)' {
            $lab = New-KitChangeLab 'change-rename'
            & git @($lab.Git) mv tools/lib/RepoRoot.psm1 RepoRoot.md 2>&1 | Out-Null
            & git @($lab.Git) commit -q -m rename 2>&1 | Out-Null

            $r = Invoke-KitChangeRun $lab

            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output   | Should -BeLike '*змінено код*tools/lib/RepoRoot.psm1*'
        }
    }
}
