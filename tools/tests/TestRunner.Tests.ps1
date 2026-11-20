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
    It 'кожен розданий файл потрапляє в кошики рівно один раз — без дублів і пропусків' {
        # Пропущений файл — тихо втрачені тести; лічильник контейнерів у вердикті не ловить дубль разом
        # з пропуском, коли вони скасовують один одного, а перелік імен ловить.
        $files = @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1', 'd.Tests.ps1', 'e.Tests.ps1')
        $buckets = Split-KitTestFiles -Files $files -Durations @{ 'a.Tests.ps1' = 9; 'b.Tests.ps1' = 3 } -Workers 3
        (@($buckets | ForEach-Object { $_.Files }) | Sort-Object) | Should -Be $files
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

    It 'провал контейнера дискавері поруч зі справними тестами — не Green, навіть якщо TotalCount > 0 (ФІНАЛЬНЕ РЕВ''Ю, п.1)' {
        # Відтворює точно той відбиток, який дає Pester 6.1.0 на файлі із синтаксичною
        # помилкою чи throw у BeforeDiscovery: FailedContainersCount = 1, але FailedCount = 0
        # і TotalCount > 0 (СУСІДНІ файли того самого воркера виконались нормально). Без фіксу
        # ЖОДНА з наявних причин цього не ловить: Containers (2) = DispatchedFiles (2), TotalCount
        # (5) > 0, FailedCount (0) — вердикт був би Green. Це і є дірка, яку знайшло фінальне
        # рев'ю гілки.
        $summaries = @(
            [pscustomobject]@{ Containers = 2; TotalCount = 5; FailedCount = 0; FailedContainersCount = 1;
                Failures = @([pscustomobject]@{ File = 'Зламаний.Tests.ps1'; Name = '(дискавері)'; Message = 'ParseException' }) }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1', 'b.Tests.ps1') -WorkerExitCodes @(0)

        $verdict.Green | Should -BeFalse
        # Дискримінуючий бік: причина називає і кількість, і файл — не загальне "щось не так".
        ($verdict.Reasons -join '; ') | Should -BeLike '*дискавері*'
        ($verdict.Reasons -join '; ') | Should -BeLike '*Зламаний.Tests.ps1*'
    }


    It 'весь набір відфільтровано тегом (TotalCount = NotRunCount > 0) — не Green, «нуль тестів», а не мовчазне ЗЕЛЕНО' {
        # Дискримінуючий бік прямо: до фіксу перевірка дивилась лише на TotalCount (5, > 0) і
        # FailedCount (0) — жодна причина не спрацьовувала б, хоча виконано рівно нуль тестів.
        $summaries = @(
            [pscustomobject]@{ Containers = 1; TotalCount = 5; FailedCount = 0; NotRunCount = 5 }
        )

        $verdict = Get-KitRunVerdict -Summaries $summaries -DispatchedFiles @('a.Tests.ps1') -WorkerExitCodes @(0)

        $verdict.Green | Should -BeFalse
        ($verdict.Reasons -join '; ') | Should -BeLike '*жодного тесту*'
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
