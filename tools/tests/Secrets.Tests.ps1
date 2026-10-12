#Requires -Version 7
# §10.2 П23 — секрети не потрапляють у вивід kit. Справжній kit.ps1 підпроцесом на синтетичному
# репозиторії. Invoke-KitCommand зливає stderr у stdout (2>&1 | Out-String), тож перевірка
# маркера в .Output охоплює обидва потоки; окремий тест нижче доводить, що stderr справді
# потрапляє в цей текст (інакше «маркера немає» нічого б не доводило).
Describe 'секрети не у виводі (П23)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Kit {
            param([string]$Command, [string]$Repo, [string[]]$More = @())
            Invoke-KitCommand -Kit $script:Kit -Command $Command -Repo $Repo -More $More
        }
    }

    It 'фікстура: stderr підпроцесу потрапляє в перевірений текст' {
        $out = & pwsh -NoProfile -Command '[Console]::Error.WriteLine("ТІЛЬКИ-STDERR")' 2>&1 | Out-String
        $out | Should -BeLike '*ТІЛЬКИ-STDERR*'
        # а сама Invoke-KitCommand лишає цю форму (2>&1 | Out-String) — читаємо її код
        (Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Raw) |
            Should -BeLike '*2>&1 | Out-String*'
    }

    Context '(а) Usr/Pwd у рядку підключення бази агента' {
        BeforeAll {
            $script:RepoA = New-KitFakeRepo -Root (Join-Path $TestDrive 'a') -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $script:RepoA -Connection 'File=build/ib;Usr=agent;Pwd=СЕКРЕТ-Ж7'
        }
        It '<Cmd>: помилка, маркера немає, рецепт infobases.origin є' -TestCases @(
            @{ Cmd = 'check'; More = @() }
            @{ Cmd = 'provision'; More = @() }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoA -More $More
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
            $r.Output | Should -Not -BeLike '*Pwd=*'
            $r.Output | Should -BeLike '*задаються ключами user і password в infobases.origin*'
        }
    }

    Context '(б) пароль сховища з " у накладці' {
        BeforeAll {
            $overlay = @('storages:', "  Alpha_SMB: { password: 'ab""ХВІСТ-Ж7' }") -join "`n"
            $script:RepoB = New-KitFakeRepo -Root (Join-Path $TestDrive 'b') -WithHooks -WithGitattributes -WithGitignore -OverlayText $overlay
        }
        It '<Cmd>: помилка з Origin, маркера немає' -TestCases @(
            @{ Cmd = 'check' }
            @{ Cmd = 'sync' }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoB
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*ХВІСТ-Ж7*'
            $r.Output | Should -BeLike '*v8storagekit.local.yaml, storages.Alpha_SMB.password*'
        }
        It 'sync -Apply: платформа не запускалась — робочої теки синхронізації немає' {
            # Той самий спосіб, що в Sync.Guards.Tests.ps1: зупинка до платформи не лишає build/sync/<ключ>.
            $r = Invoke-Kit -Command 'sync' -Repo $script:RepoB -More @('-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*ХВІСТ-Ж7*'
            Join-Path $script:RepoB 'build/sync/Alpha_SMB' | Should -Not -Exist
            (git -C $script:RepoB branch --list 'storage/*') | Should -BeNullOrEmpty
        }
    }

    Context '(в) Usr/Pwd у підключенні дев-бази людини з накладки' {
        BeforeAll {
            $overlay = @('infobases:', "  dev: { connection: 'File=C:\other\dev;Usr=u;Pwd=СЕКРЕТ-Ж7' }") -join "`n"
            $script:RepoC = New-KitFakeRepo -Root (Join-Path $TestDrive 'c') -WithHooks -WithGitattributes -WithGitignore -OverlayText $overlay
        }
        It '<Cmd>: маркера немає ні в stdout, ні в stderr' -TestCases @(
            @{ Cmd = 'check' }
            @{ Cmd = 'provision' }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoC
            $r.Output | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
            $r.Output | Should -Not -BeLike '*Pwd=*'
            # вивід не порожній, називає походження (ім'я дев-бази й файл накладки) і несе рецепт —
            # тест не зеленіє від того, що команда змовчала
            $r.Output | Should -BeLike "*дев-база 'dev' у *v8storagekit.local.yaml*"
            $r.Output | Should -BeLike '*задаються ключами user і password в infobases.origin*'
        }
    }
}
