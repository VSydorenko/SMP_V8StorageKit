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
