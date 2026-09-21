#Requires -Version 7
# Модуль повністю в процесі: без підпроцесів, без git, без реальних *.Tests.ps1 із дерева —
# синтетичні входи під $TestDrive. Має відпрацьовувати за десятки мілісекунд (не хвилини,
# як наскрізні Check.Tests.ps1/Sync.Tests.ps1).
BeforeAll {
    Import-Module "$PSScriptRoot/lib/TestRunner.psm1" -Force
}

Describe 'Resolve-KitTestFiles' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }

    function script:New-FakeTestFile {
        param([string]$Name)
        New-Item -ItemType File -Path (Join-Path $script:Dir $Name) -Force | Out-Null
    }

    It '-Only з точною назвою бере рівно один файл' {
        New-FakeTestFile 'Check.Tests.ps1'
        New-FakeTestFile 'Check.Extra.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only 'Check'

        $result.Count | Should -Be 1
        $result[0]    | Should -BeLike '*Check.Tests.ps1'
        # Дискримінуючий бік: файл групи не мав потрапити в результат разом із точним.
        $result       | Should -Not -Contain (Join-Path $script:Dir 'Check.Extra.Tests.ps1')
    }

    It '-Only з іменем групи бере всі файли групи (база.*.Tests.ps1)' {
        New-FakeTestFile 'Check.Extra.Tests.ps1'
        New-FakeTestFile 'Check.Other.Tests.ps1'
        New-FakeTestFile 'SessionCheck.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only 'Check'

        $result.Count | Should -Be 2
        $result | Should -Contain (Join-Path $script:Dir 'Check.Extra.Tests.ps1')
        $result | Should -Contain (Join-Path $script:Dir 'Check.Other.Tests.ps1')
        # Дискримінуючий бік: SessionCheck.Tests.ps1 закінчується на "Check.Tests.ps1", але не
        # є членом групи "Check" (не починається з "Check.") — не мав потрапити в результат.
        $result | Should -Not -Contain (Join-Path $script:Dir 'SessionCheck.Tests.ps1')
    }

    It 'точна назва перемагає групу, коли існують і файл, і група' {
        New-FakeTestFile 'Check.Tests.ps1'
        New-FakeTestFile 'Check.Extra.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only 'Check'

        # Дискримінуючий бік: якби перевага точної назви не діяла, результат був би переліком
        # з двох файлів, а не одним.
        $result.Count | Should -Be 1
        $result[0]    | Should -BeLike '*Check.Tests.ps1'
    }

    It 'описка зупиняє' {
        New-FakeTestFile 'AgentBase.Tests.ps1'

        $err = $null
        try {
            Resolve-KitTestFiles -Root $script:Dir -Only 'НемаєТакого' | Out-Null
        } catch {
            $err = $_
        }

        $err                   | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*НемаєТакого.Tests.ps1*'
        $err.Exception.Message | Should -BeLike '*Доступні:*'
    }

    It "-Only 'Ch*' зупиняє, а не вибирає групу" {
        New-FakeTestFile 'Check.Extra.Tests.ps1'

        # Дискримінуючий бік: без екранування ($base='Ch*') шаблон групи "Ch*.*.Tests.ps1"
        # підійшов би під "Check.Extra.Tests.ps1" (Ch + *=eck + . + *=Extra + .Tests.ps1) і
        # мовчки обрав би групу замість зупинки. Екранування робить перший "*" буквальним
        # символом — такого файлу немає, тож має бути throw.
        { Resolve-KitTestFiles -Root $script:Dir -Only 'Ch*' } | Should -Throw
    }

    It 'без -Only — усі файли, відсортовані за іменем (не за порядком створення)' {
        # Порядок створення навмисно НЕ алфавітний — щоб тест не пройшов випадково, якби
        # реалізація просто віддавала порядок Get-ChildItem "як є".
        New-FakeTestFile 'Zeta.Tests.ps1'
        New-FakeTestFile 'Alpha.Tests.ps1'
        New-FakeTestFile 'Middle.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir

        $result.Count | Should -Be 3
        # Дискримінуючий бік: перевіряється не лише склад, а й ПОРЯДОК — Alpha, Middle, Zeta,
        # не порядок створення (Zeta, Alpha, Middle) і не порядок файлової системи.
        $result[0] | Should -BeLike '*Alpha.Tests.ps1'
        $result[1] | Should -BeLike '*Middle.Tests.ps1'
        $result[2] | Should -BeLike '*Zeta.Tests.ps1'
    }

    It '-Only з переліком двох і більше імен — без дублікатів, у порядку вибору' {
        New-FakeTestFile 'Alpha.Tests.ps1'
        New-FakeTestFile 'Beta.Tests.ps1'
        New-FakeTestFile 'Gamma.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only @('Beta', 'Alpha')

        # Дискримінуючий бік: порядок — порядок ВИБОРУ (Beta, потім Alpha), а не алфавітний
        # (як у гілці без -Only вище) і не порядок на диску.
        $result.Count | Should -Be 2
        $result[0]    | Should -BeLike '*Beta.Tests.ps1'
        $result[1]    | Should -BeLike '*Alpha.Tests.ps1'
        $result       | Should -Not -Contain (Join-Path $script:Dir 'Gamma.Tests.ps1')
    }

    It '-Only з тим самим іменем двічі — без дублікатів у результаті' {
        New-FakeTestFile 'Alpha.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only @('Alpha', 'Alpha')

        # Дискримінуючий бік: без дедуплікації результат мав би два однакових шляхи.
        $result.Count | Should -Be 1
    }

    It "-Only з іменем разом із суфіксом '.Tests.ps1' — рівноцінно імені без нього" {
        New-FakeTestFile 'AgentBase.Tests.ps1'

        $result = Resolve-KitTestFiles -Root $script:Dir -Only 'AgentBase.Tests.ps1'

        $result.Count | Should -Be 1
        $result[0]    | Should -BeLike '*AgentBase.Tests.ps1'
    }
}

Describe 'Split-KitTestFiles' {
    It 'розклад детермінований — два виклики на тих самих входах дають однакові кошики' {
        $files = @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1', 'd.Tests.ps1', 'e.Tests.ps1')
        # Навмисно з рівними вагами (a=b, c=d), щоб детермінізм залежав саме від тайбрейку
        # за іменем і стабільності сортування, а не збігався випадково.
        $durations = @{
            'a.Tests.ps1' = 10
            'b.Tests.ps1' = 10
            'c.Tests.ps1' = 5
            'd.Tests.ps1' = 5
            'e.Tests.ps1' = 1
        }

        $first  = Split-KitTestFiles -Files $files -Durations $durations -Workers 2
        $second = Split-KitTestFiles -Files $files -Durations $durations -Workers 2

        ($first | ConvertTo-Json -Depth 5) | Should -Be ($second | ConvertTo-Json -Depth 5)
    }

    It 'розклад балансує — максимальне навантаження кошика менше за суму двох найважчих файлів' {
        $files = @('f1.Tests.ps1', 'f2.Tests.ps1', 'f3.Tests.ps1', 'f4.Tests.ps1', 'f5.Tests.ps1', 'f6.Tests.ps1')
        $durations = @{
            'f1.Tests.ps1' = 41
            'f2.Tests.ps1' = 88
            'f3.Tests.ps1' = 23
            'f4.Tests.ps1' = 80
            'f5.Tests.ps1' = 33
            'f6.Tests.ps1' = 36
        }

        $buckets = Split-KitTestFiles -Files $files -Durations $durations -Workers 3

        $maxLoad     = ($buckets | Measure-Object -Property Sec -Maximum).Maximum
        $twoHeaviest = 88 + 80

        # Дискримінуючий бік: наївний розклад (без сортування за вагою, напр. round-robin
        # у порядку вводу або жадібний вибір НАЙважчого кошика замість найлегшого) звалив би
        # два найважчі файли (88 і 80) в один кошик і дав би maxLoad >= 168.
        $maxLoad | Should -BeLessThan $twoHeaviest
    }

    It 'невідомий файл важить як максимум відомих — не осідає в кошик із найважчим' {
        $files = @('A.Tests.ps1', 'B.Tests.ps1', 'C.Tests.ps1', 'Unknown.Tests.ps1')
        $durations = @{
            'A.Tests.ps1' = 50
            'B.Tests.ps1' = 30
            'C.Tests.ps1' = 10
        }

        $buckets = Split-KitTestFiles -Files $files -Durations $durations -Workers 2

        $heavyBucket = $buckets | Where-Object { $_.Files -contains 'A.Tests.ps1' }

        # Дискримінуючий бік: Unknown важить як максимум відомих (50, як A), тож жадібний
        # розклад мав розвести їх у РІЗНІ кошики, а не покласти невідомий поверх найважчого.
        $heavyBucket.Files | Should -Not -Contain 'Unknown.Tests.ps1'
    }

    It '-Workers менше 1 кидає виняток' {
        { Split-KitTestFiles -Files @('a.Tests.ps1') -Durations @{} -Workers 0 } | Should -Throw
    }

    It 'порожня -Durations — усі файли важать 1,0 (рівномірний розподіл)' {
        $files = @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1', 'd.Tests.ps1')

        $buckets = Split-KitTestFiles -Files $files -Durations @{} -Workers 2

        # Дискримінуючий бік: якби невідомі файли важили 0 (чи якусь іншу довільну вагу),
        # сума 4 файлів по 1,0 на 2 воркери не дала б рівно по 2,0 у кожному кошику.
        ($buckets | Measure-Object -Property Sec -Sum).Sum | Should -Be 4.0
        foreach ($bucket in $buckets) {
            $bucket.Sec | Should -Be 2.0
        }
    }

    It 'порожні кошики відкидаються — воркерів більше, ніж файлів' {
        $files = @('a.Tests.ps1', 'b.Tests.ps1')

        $buckets = Split-KitTestFiles -Files $files -Durations @{} -Workers 5

        # Дискримінуючий бік: без відкидання порожніх кошиків результат мав би 5 елементів,
        # три з яких — з порожнім Files.
        $buckets.Count | Should -Be 2
        ($buckets | Where-Object { $_.Files.Count -eq 0 }) | Should -BeNullOrEmpty
    }
}

Describe 'Read-KitTestDurations' {
    It 'виміряне перекриває засівне' {
        $seedPath     = Join-Path $TestDrive 'seed.json'
        $measuredPath = Join-Path $TestDrive 'measured.json'

        Set-Content -LiteralPath $seedPath     -Value '{"A.Tests.ps1": 10, "B.Tests.ps1": 20}' -Encoding utf8NoBOM
        Set-Content -LiteralPath $measuredPath -Value '{"A.Tests.ps1": 99}'                     -Encoding utf8NoBOM

        $result = Read-KitTestDurations -MeasuredPath $measuredPath -SeedPath $seedPath

        $result['A.Tests.ps1'] | Should -Be 99
        # Дискримінуючий бік: ключ, якого немає у виміряному, мав лишитись зі значенням із
        # засівного, а не зникнути й не обнулитись.
        $result['B.Tests.ps1'] | Should -Be 20
    }

    It 'відсутній файл (виміряний, засівний або обидва) — не помилка' {
        $onlySeedPath        = Join-Path $TestDrive 'only-seed.json'
        $missingMeasuredPath = Join-Path $TestDrive 'missing-measured.json'
        Set-Content -LiteralPath $onlySeedPath -Value '{"A.Tests.ps1": 5}' -Encoding utf8NoBOM

        { Read-KitTestDurations -MeasuredPath $missingMeasuredPath -SeedPath $onlySeedPath } | Should -Not -Throw
        $withoutMeasured = Read-KitTestDurations -MeasuredPath $missingMeasuredPath -SeedPath $onlySeedPath
        # Дискримінуючий бік: відсутність виміряного не мала обнулити чи прибрати те, що є
        # в засівному.
        $withoutMeasured['A.Tests.ps1'] | Should -Be 5

        $onlyMeasuredPath = Join-Path $TestDrive 'only-measured.json'
        $missingSeedPath  = Join-Path $TestDrive 'missing-seed.json'
        Set-Content -LiteralPath $onlyMeasuredPath -Value '{"B.Tests.ps1": 7}' -Encoding utf8NoBOM

        { Read-KitTestDurations -MeasuredPath $onlyMeasuredPath -SeedPath $missingSeedPath } | Should -Not -Throw
        $withoutSeed = Read-KitTestDurations -MeasuredPath $onlyMeasuredPath -SeedPath $missingSeedPath
        $withoutSeed['B.Tests.ps1'] | Should -Be 7

        $missingBothMeasuredPath = Join-Path $TestDrive 'missing-both-measured.json'
        $missingBothSeedPath     = Join-Path $TestDrive 'missing-both-seed.json'

        { Read-KitTestDurations -MeasuredPath $missingBothMeasuredPath -SeedPath $missingBothSeedPath } | Should -Not -Throw
        $withoutEither = Read-KitTestDurations -MeasuredPath $missingBothMeasuredPath -SeedPath $missingBothSeedPath
        # Дискримінуючий бік: без жодного файлу результат — порожня, а не помилкова, таблиця.
        $withoutEither.Count | Should -Be 0
    }
}

Describe 'Write-KitTestDurations' {
    It 'округлює значення до 0,01 і пише ключі за алфавітом' {
        $path = Join-Path $TestDrive 'nested/durations-order.json'
        # Порядок вставки навмисно НЕ алфавітний (Zeta раніше Alpha).
        $durations = @{
            'Zeta.Tests.ps1'  = 1.006
            'Alpha.Tests.ps1' = 2.3333333
        }

        Write-KitTestDurations -Path $path -Durations $durations

        $raw    = Get-Content -LiteralPath $path -Raw
        $parsed = $raw | ConvertFrom-Json

        $parsed.'Alpha.Tests.ps1' | Should -Be 2.33
        $parsed.'Zeta.Tests.ps1'  | Should -Be 1.01
        # Дискримінуючий бік: ключі мають стояти за алфавітом у самому ТЕКСТІ файлу, а не
        # лише бути присутніми — інакше порядок вставки (Zeta раніше Alpha) просочився б.
        $raw.IndexOf('Alpha.Tests.ps1') | Should -BeLessThan $raw.IndexOf('Zeta.Tests.ps1')
    }

    It 'створює батьківську теку, якщо її ще немає' {
        $path   = Join-Path $TestDrive 'a/b/c/durations.json'
        $parent = Split-Path -Path $path -Parent

        Test-Path -LiteralPath $parent | Should -BeFalse

        Write-KitTestDurations -Path $path -Durations @{ 'A.Tests.ps1' = 1.0 }

        Test-Path -LiteralPath $parent -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $path   -PathType Leaf      | Should -BeTrue
    }
}

Describe 'Get-KitRunVerdict' {
    It 'усе гаразд — Green, Reasons порожній' {
        $summaries = @(
            [pscustomobject]@{ Containers = 2; TotalCount = 10; FailedCount = 0 }
            [pscustomobject]@{ Containers = 1; TotalCount = 5;  FailedCount = 0 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1') -WorkerExitCodes @(0, 0)

        $verdict.Green   | Should -BeTrue
        $verdict.Reasons | Should -BeNullOrEmpty
    }

    It 'мертвий воркер (код ≠ 0) — не Green, причина називає номер воркера' {
        $summaries = @(
            [pscustomobject]@{ Containers = 1; TotalCount = 5; FailedCount = 0 }
            [pscustomobject]@{ Containers = 1; TotalCount = 5; FailedCount = 0 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1', 'b.Tests.ps1') -WorkerExitCodes @(0, 1)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*воркер 2*'
    }

    It 'бракує підсумку — не Green, причина називає обидві кількості' {
        $summaries = @(
            [pscustomobject]@{ Containers = 2; TotalCount = 10; FailedCount = 0 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1', 'b.Tests.ps1') -WorkerExitCodes @(0, 0)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*підсумків: 1*воркерів: 2*'
    }

    It 'контейнерів менше за роздані файли — не Green, ловить файл, що не виконався непоміченим' {
        $summaries = @(
            [pscustomobject]@{ Containers = 1; TotalCount = 5; FailedCount = 0 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1', 'b.Tests.ps1') -WorkerExitCodes @(0)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*контейнерів: 1*роздано файлів: 2*'
    }

    It 'нуль тестів — не Green, ловить мовчазні «0 тестів»' {
        $summaries = @(
            [pscustomobject]@{ Containers = 1; TotalCount = 0; FailedCount = 0 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1') -WorkerExitCodes @(0)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*жодного тесту*'
    }

    It 'усі структурні умови справні, але тест впав — не Green, причина називає кількість' {
        $summaries = @(
            [pscustomobject]@{ Containers = 1; TotalCount = 5; FailedCount = 2 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1') -WorkerExitCodes @(0)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*впало тестів: 2*'
    }

    It 'порожній -Summaries — Measure-Object -Sum дає $null, вердикт не зелений, причина названа' {
        # DispatchedFiles і WorkerExitCodes теж порожні: реалістичний край "жоден воркер не
        # стартував" (0 файлів роздано, 0 воркерів запущено, 0 підсумків) — не штучний $null
        # заради $null. -Summaries лишається Mandatory без AllowEmptyCollection на решті
        # параметрів навмисно не чіпали; тут порожній масив, бо саме на ЦЬОМУ вході
        # Measure-Object -Sum усередині Get-KitRunVerdict повертає $null (не 0) для кожної
        # з трьох сум, і саме це має ловити нуль-безпека.
        $verdict = Get-KitRunVerdict -Summaries @() -DispatchedFiles @() -WorkerExitCodes @()

        $verdict.Green | Should -BeFalse
        # Дискримінуючий бік: без зведення totalSum до 0 явно порівняння "$null -eq 0" дає
        # False (не True!) — і причина "жодного тесту" мовчки НЕ з'явилася б, хоч насправді
        # виконано рівно нуль тестів. Просто "не Green" тут не дискримінує (інша, побічна
        # причина теж не-null-безпечна і однаково спрацювала б), тому перевіряємо саме текст.
        ($verdict.Reasons -join '; ') | Should -BeLike '*жодного тесту*'
    }
}
