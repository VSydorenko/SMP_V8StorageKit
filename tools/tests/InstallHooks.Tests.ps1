#Requires -Version 7
Describe 'kit install-hooks — хуки захисту й settings.json одним кроком' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-InstallHooks { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit install-hooks -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }
    It 'прев''ю перелічує, що буде покладено, і нічого не кладе' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview')
        $r = Invoke-InstallHooks -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*.githooks*settings.json*-Apply*'
        Join-Path $repo '.githooks' | Should -Not -Exist
    }
    It '-Apply кладе все; після цього kit check мовчить про hooks і hook-shim' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'apply') -WithGitattributes -WithGitignore
        $r = Invoke-InstallHooks -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        # З 1.6.0 хук старту сесії поставляє плагін: ні шима, ні розділу hooks у споживача.
        Join-Path $repo '.claude/hooks/session-start.ps1' | Should -Not -Exist
        Join-Path $repo '.claude/settings.json' | Should -Exist
        (Get-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'hooks'
        (git -C $repo config --get core.hooksPath) | Should -Be '.githooks'
        # Хуки застейджені з режимом 100755 — саме він дістанеться кожному клону (git ls-files -s питає індекс, не ФС).
        # -c core.quotepath=false — той самий інваріант, що в production-коді (Hooks.psm1, check.psm1): git ls-files друкує
        # шляхи, і kit форсує цю конфігурацію за виклик завжди, без винятку для свідомо ASCII-шляхів (правило CLAUDE.md).
        foreach ($h in 'pre-commit', 'pre-merge-commit') { (git -c core.quotepath=false -C $repo ls-files -s -- ".githooks/$h") | Should -Match '^100755 ' }
        $check = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) 2>&1 | Out-String
        $check | Should -Not -BeLike '*core.hooksPath*'
        $check | Should -Not -Match '100644'
        $check | Should -Not -Match 'session-start\.ps1'
    }
    It 'наявний .claude/settings.json не перезаписується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'keep')
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        # Старий проєктний хук (1.6.0 переніс хук у плагін): наявний settings.json install-hooks не чіпає, а warn лишає людині.
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ "permissions": { "allow": ["Bash(echo:*)"] }, "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File .claude/hooks/session-start.ps1" } ] } ] } }' -Encoding UTF8
        $r = Invoke-InstallHooks -Repo $repo -More @('-Apply')
        (Get-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Raw) | Should -BeLike '*Bash(echo:*)*'
        # Доказ, що команда справді відпрацювала, не лише що файл, який
        # тест сам поклав рядком вище, лишився недоторканим — без цього асерту тест зелений і на
        # вилученому tools/commands/install-hooks.psm1 (диспетчер друкує «Невідома команда» й
        # виходить кодом 1, settings.json теж лишається незмінним). Git-хуки кладуться навіть тоді,
        # коли settings.json не чіпають — це і є незалежний доказ роботи команди.
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        # warn (старий hooks.SessionStart у наявному settings.json) —
        # це не зупинка (install-hooks.psm1: ExitCode рахує лише error, прецедент check.psm1:407),
        # тож код виходу 0, а сам warn і далі видно людині текстом. Обидва факти — під тестом, щоб
        # наступна зміна формули впала тут, а не лишилась непоміченою.
        $r.ExitCode | Should -Be 0 -Because $r.Output
        # ASCII-only збіг (не кирилична підрядка тексту знахідки): дочірній pwsh тут запущено з-під
        # голого Invoke-Pester, де [Console]::OutputEncoding = UTF8 не виставлено (це робить лише
        # Run-Tests.ps1) — кирилиця у захопленому виводі мовчки перекодовується під кодовою
        # сторінкою консолі, і збіг на кириличному рядку падав би детерміновано незалежно від
        # виправлення формули (той самий механізм, що валить Hooks.Tests.ps1:74 поза Run-Tests.ps1).
        # 'hooks.SessionStart' у самому тексті знахідки — ASCII, тому й ідентифікатор перевірки тут.
        $r.Output | Should -Match '\[warn\].*hooks\.SessionStart'
    }
    It 'на репозиторії без хуків вивід kit check називає команду install-hooks' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-mentions-command')
        $check = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) 2>&1 | Out-String
        $check | Should -BeLike '*install-hooks*'
    }
}
