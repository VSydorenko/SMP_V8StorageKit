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

    Context '(г) друкарська помилка «без пробілу після :» (П23 п. 3)' {
        BeforeAll {
            function script:Assert-NoMarker {
                param([string]$Repo, [string]$Marker, [string]$Text)
                $Text | Should -Not -BeLike "*$Marker*"
                # відбиток і решта файлів робочої копії (крім самого файлу накладки/конфігу, де маркер записали ми)
                $own = @('v8storagekit.local.yaml', 'v8project.local.yaml')
                $hits = @(Get-ChildItem -LiteralPath $Repo -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '[\/]\.git[\/]' -and $_.Name -notin $own } |
                    Select-String -SimpleMatch -Pattern $Marker -List)
                $hits.Count | Should -Be 0
            }
        }
        It 'невідомий ключ із двокрапкою в накладці (<Cmd>): маркера немає, підказка є' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }, @{ Cmd = 'session-check' }
        ) {
            $overlay = @('storages:', '  Alpha_SMB: { path: ''C:\x'', password:МАРКЕР-З9 }') -join "`n"
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "g1-$Cmd") -WithHooks -WithGitignore -OverlayText $overlay
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.Output | Should -BeLike "*пропущено пробіл після ':'?*"
            $r.Output | Should -BeLike "*'password'*"
            Assert-NoMarker -Repo $repo -Marker 'МАРКЕР-З9' -Text $r.Output
        }
        It 'невідомий ключ із двокрапкою у v8project.local.yaml (<Cmd>): маркера немає' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }, @{ Cmd = 'session-check' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "g2-$Cmd") -WithHooks -WithGitignore
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value "infobases: { origin: { connection: 'File=build/ib' }, password:МАРКЕР-З9 }"
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.Output | Should -BeLike "*пропущено пробіл після ':'?*"
            Assert-NoMarker -Repo $repo -Marker 'МАРКЕР-З9' -Text $r.Output
        }
        It 'скаляр у storages, що починається з імені ключа об''єктної форми (<Cmd>): маркера немає, підказка є' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }, @{ Cmd = 'session-check' }
        ) {
            $overlay = @('storages:', '  Alpha_SMB: password:МАРКЕР-З9') -join "`n"
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "g3-$Cmd") -WithHooks -WithGitignore -OverlayText $overlay
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.Output | Should -BeLike "*значення починається з 'password:'*пропущено пробіл після ':'?*"
            Assert-NoMarker -Repo $repo -Marker 'МАРКЕР-З9' -Text $r.Output
        }
        It 'контроль: законний шлях сховища (<Path>) не дає цієї помилки' -TestCases @(
            @{ Path = 'C:\repo' }, @{ Path = 'tcp://srv/repo' }
        ) {
            $overlay = @('storages:', "  Alpha_SMB: '$Path'") -join "`n"
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('g4-' + ($Path -replace '\W', '_'))) -WithHooks -WithGitignore -OverlayText $overlay
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.Output | Should -Not -BeLike "*пропущено пробіл після ':'?*"
        }
    }

    Context '(д) "=" у значенні рядка підключення (П23 п. 4)' {
        It '<Cmd>: помилка без значення, маркера немає' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'provision' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "d-$Cmd") -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=C:\x,Pwd=МАРКЕР-И1'
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike "*містить '=' у значенні ключа 'File'*"
            $r.Output | Should -Not -BeLike '*МАРКЕР-И1*'
        }
    }

    Context '(е) пароль бази агента з " (П23 п. 5)' {
        It '<Cmd>: відмова в префлайті з Origin, маркера немає' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "e-$Cmd") -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -Password 'ab"МАРКЕР-К2'
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*infobases.origin.password*подвійну лапку*'
            $r.Output | Should -Not -BeLike '*МАРКЕР-К2*'
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