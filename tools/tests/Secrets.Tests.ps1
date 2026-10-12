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
            $r.Output | Should -BeLike '*пароль дев-бази kit не підтримує*'
            # рецепт бази агента (infobases.origin) для дев-бази хибний — його тут бути не може
            $r.Output | Should -Not -BeLike '*задаються ключами user і password*'
        }
    }
}

Describe 'пароль сховища з " — платформа не запускається (П23, у цьому процесі)' {
    # Підпроцес не дає побачити, чи кликали платформу: тут Invoke-KitPreflight/Invoke-KitSync викликаються
    # напряму, а Invoke-V8Designer підмінено (той самий прийом, що в Sync.Authors.Tests.ps1) і лічиться.
    # Каталог сховища існує, версії підмінено — без відмови префлайту sync дійшов би до платформи.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force
    }

    It 'sync -Apply: відмова префлайту з Origin, Invoke-V8Designer не викликано, маркера немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'plat') -WithHooks -WithGitignore -WithAgentBase
        $storageDir = Join-Path $TestDrive 'plat-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        $overlay = @('storages:', "  Alpha_SMB: { path: '$storageDir', password: 'ab""ХВІСТ-Ж7' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value $overlay
        Mock -ModuleName StoragePlatform Invoke-V8Designer { throw 'платформа не мала викликатись' }
        Mock -ModuleName StoragePlatform New-ExtensionInfobase { throw 'платформа не мала викликатись' }
        Mock -ModuleName StoragePlatform New-V8FileInfobase { throw 'платформа не мала викликатись' }
        Mock -ModuleName sync Get-StorageVersions { , @([pscustomobject]@{
            Version = 1; User = 'gitbot'; Date = '01.01.2026'; Time = '09:00:00'; ConfigVersion = ''; Comment = 'v'
            Added = @(); Modified = @(); Deleted = @(); Timestamp = [datetime]'2026-01-01T09:00:00' }) }
        $err = $null
        $text = & {
            try { $ctx = Invoke-KitPreflight -RepoRoot $repo; Invoke-KitSync -Context $ctx -Apply $true }
            catch { $script:Err = $_.Exception.Message }
        } 6>&1 | Out-String
        $err = $script:Err
        $err | Should -BeLike '*storages.Alpha_SMB.password*'
        "$err$text" | Should -Not -BeLike '*ХВІСТ-Ж7*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
        Should -Invoke -ModuleName StoragePlatform New-ExtensionInfobase -Times 0
        Should -Invoke -ModuleName StoragePlatform New-V8FileInfobase -Times 0
    }
}