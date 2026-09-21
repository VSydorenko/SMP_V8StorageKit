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
}
