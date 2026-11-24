#Requires -Version 7
# Секрети не потрапляють у вивід kit. Справжній kit.ps1 підпроцесом на синтетичному
# репозиторії. Invoke-KitCommand зливає stderr у stdout (2>&1 | Out-String), тож перевірка
# маркера в .Output охоплює обидва потоки; окремий тест нижче доводить, що stderr справді
# потрапляє в цей текст (інакше «маркера немає» нічого б не доводило).
Describe 'секрети не у виводі' {
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
            Set-KitFakeAgentBase -Repo $script:RepoA -Connection 'File=build/ib;Usr=agent;Pwd=SECRETZ7СЕКРЕТ-Ж7'
        }
        It '<Cmd>: помилка, маркера немає, рецепт infobases.origin є' -TestCases @(
            @{ Cmd = 'check'; More = @() }
            @{ Cmd = 'provision'; More = @() }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoA -More $More
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
            $r.Output | Should -Not -BeLike '*SECRETZ7*'
            $r.Output | Should -Not -BeLike '*Pwd=*'
            $r.Output | Should -BeLike '*задаються ключами user і password в infobases.origin*'
        }
    }

    Context '(б) пароль сховища з " у накладці' {
        BeforeAll {
            $overlay = @('storages:', "  Alpha_SMB: { password: 'ab""TAILZ7ХВІСТ-Ж7' }") -join "`n"
            $script:RepoB = New-KitFakeRepo -Root (Join-Path $TestDrive 'b') -WithHooks -WithGitattributes -WithGitignore -OverlayText $overlay
        }
        It '<Cmd>: помилка з Origin, маркера немає' -TestCases @(
            @{ Cmd = 'check' }
            @{ Cmd = 'sync' }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoB
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -Not -BeLike '*ХВІСТ-Ж7*'
            $r.Output | Should -Not -BeLike '*TAILZ7*'
            $r.Output | Should -BeLike '*v8storagekit.local.yaml, storages.Alpha_SMB.password*'
        }
    }

    Context '(д) "=" у значенні рядка підключення' {
        It '<Cmd>: помилка без значення, маркера немає' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'provision' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "d-$Cmd") -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=C:\x,Pwd=SECRETI1МАРКЕР-И1'
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike "*містить '=' у значенні ключа 'File'*"
            $r.Output | Should -Not -BeLike '*МАРКЕР-И1*'
            $r.Output | Should -Not -BeLike '*SECRETI1*'
        }
    }

    # Не тест на маркер: пароль із " у префлайті не потрапив би у вивід і без відмови (його не друкує жоден текст),
    # тож перевіряється лише відмова і рецепт — маркерної асерції навмисно немає.
    Context '(е) пароль бази агента з " — відмова в префлайті й рецепт' {
        It '<Cmd>: відмова з Origin і причиною' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "e-$Cmd") -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -Password 'ab"pwd'
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*infobases.origin.password*подвійну лапку*'
        }
    }

    # Ім'я невідомого ключа не друкується ніколи: у flow-мапі запис без ': ' стає ключем цілком,
    # тож секрет сидить саме в імені ключа. Кожен тест — з парою маркерів: ASCII поруч із кириличним
    # (кириличний без UTF-8 у сесії дає хибну зелень поза Run-Tests.ps1).
    Context '(г) ім''я невідомого ключа не друкується' {
        BeforeAll {
            function script:Assert-NoMarkers { param([string]$Text)
                $Text | Should -Not -BeLike '*MARKZ9*'
                $Text | Should -Not -BeLike '*МАРКЗ9*'
            }
            function script:New-GRepo { param([string]$Name, [string]$Overlay)
                New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitignore -OverlayText $Overlay
            }
        }
        It 'storages.<ключ>, об''єктна форма: ключ «<K>» (check) — виняток є, імені немає, підказка є' -TestCases @(
            @{ K = 'password=MARKZ9МАРКЗ9' }, @{ K = 'password MARKZ9МАРКЗ9' }, @{ K = 'MARKZ9МАРКЗ9' },
            @{ K = 'MARKZ9МАРКЗ9:' }, @{ K = "MARKZ9МАРКЗ9$([char]0xFF1A)" }
        ) {
            $repo = New-GRepo -Name ('g1-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Overlay ("storages:`n  Alpha_SMB: { path: 'C:\x', $K }")
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike "*невідомий ключ (ім'я не друкується)*Перевірте пробіл після ':' і форму 'ключ: значення'*"
            Assert-NoMarkers -Text $r.Output
        }
        It 'storages.<ключ>, об''єктна форма (<Cmd>): імені немає' -TestCases @(
            @{ Cmd = 'sync' }, @{ Cmd = 'session-check' }
        ) {
            $repo = New-GRepo -Name "g1b-$Cmd" -Overlay "storages:`n  Alpha_SMB: { path: 'C:\x', password=MARKZ9МАРКЗ9 }"
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.Output | Should -BeLike "*ім'я не друкується*"
            Assert-NoMarkers -Text $r.Output
        }
        It '<Place>: імені ключа немає (check)' -TestCases @(
            @{ Place = 'infobases.<ім''я>'; Overlay = "infobases:`n  dev: { connection: 'File=C:\a', password=MARKZ9МАРКЗ9 }" }
            @{ Place = 'workspaces.<шлях>'; Overlay = "workspaces:`n  Alpha_SMB: { password=MARKZ9МАРКЗ9 }" }
            @{ Place = 'workspaces.<шлях>.agentBase'; Overlay = "workspaces:`n  Alpha_SMB: { agentBase: { password=MARKZ9МАРКЗ9 } }" }
            @{ Place = 'запис storages (ім''я запису з секретом)'; Overlay = "storages: { Alpha_SMB: 'C:\x', password=MARKZ9МАРКЗ9 }" }
        ) {
            $repo = New-GRepo -Name ('g2-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Overlay $Overlay
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*Накладка*'
            Assert-NoMarkers -Text $r.Output
        }
        It 'v8project.local.yaml: інший за origin ключ під infobases (<Cmd>): імені немає' -TestCases @(
            @{ Cmd = 'check' }, @{ Cmd = 'sync' }, @{ Cmd = 'session-check' }
        ) {
            $repo = New-GRepo -Name "g3-$Cmd" -Overlay $null
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value "infobases: { origin: { connection: 'File=build/ib' }, password=MARKZ9МАРКЗ9 }"
            $r = Invoke-Kit -Command $Cmd -Repo $repo
            $r.Output | Should -BeLike '*відмінний від origin*'
            Assert-NoMarkers -Text $r.Output
        }
        It 'маніфест v8storagekit.yaml: невідомий ключ джерела — імені немає' {
            $text = @('version: 1', 'product: Fake', 'workspaces:', '  - path: epf', '    sources:', '      tools: { truth: git, password=MARKZ9МАРКЗ9 }') -join "`n"
            $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'g4') -Workspaces $ws -ManifestText $text -WithHooks
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike "*ім'я не друкується*"
            Assert-NoMarkers -Text $r.Output
        }
    }

    # Ім'я запису мапи накладки: друкується, якщо запис має значення; запис без значення (null) —
    # сигнатура тієї самої помилки (YAML зробив ключем текст, який ключем не був) — називається номером, без імені.
    Context '(г3) ім''я запису мапи без значення не друкується' {
        BeforeAll {
            function script:Assert-NoMarkers3 { param([string]$Text)
                $Text | Should -Not -BeLike '*MARKZ9*'
                $Text | Should -Not -BeLike '*МАРКЗ9*'
            }
            function script:New-G3Repo { param([string]$Name, [string]$Overlay)
                New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitignore -OverlayText $Overlay
            }
        }
        It '<Map>, <Form> (<Cmd>): запис без значення — номер і підказка, маркера немає' -TestCases @(
            foreach ($cmd in @(@{ C = 'check'; M = @() }, @{ C = 'sync'; M = @() }, @{ C = 'session-check'; M = @() }, @{ C = 'session-check'; M = @('-AsJson') })) {
                foreach ($c in @(
                    @{ Map = 'infobases';  Form = 'блочна'; Overlay = "infobases:`n  dev: { connection: 'File=C:\a' }`n  MARKZ9МАРКЗ9:" }
                    @{ Map = 'infobases';  Form = 'flow';   Overlay = "infobases: { dev: { connection: 'File=C:\a' }, MARKZ9МАРКЗ9 }" }
                    @{ Map = 'infobases';  Form = 'flow, password=X'; Overlay = "infobases: { dev: { connection: 'File=C:\a' }, password=MARKZ9МАРКЗ9 }" }
                    @{ Map = 'storages';   Form = 'блочна'; Overlay = "storages:`n  Alpha_SMB: 'C:\x'`n  MARKZ9МАРКЗ9:" }
                    @{ Map = 'storages';   Form = 'flow';   Overlay = "storages: { Alpha_SMB: 'C:\x', MARKZ9МАРКЗ9 }" }
                    @{ Map = 'workspaces'; Form = 'блочна'; Overlay = "workspaces:`n  Alpha_SMB: { agentBase: { template: 'x.dt' } }`n  MARKZ9МАРКЗ9:" }
                    @{ Map = 'workspaces'; Form = 'flow';   Overlay = "workspaces: { Alpha_SMB: { agentBase: { template: 'x.dt' } }, MARKZ9МАРКЗ9 }" }
                )) { @{ Cmd = $cmd.C; More = $cmd.M; Map = $c.Map; Form = $c.Form; Overlay = $c.Overlay } }
            }
        ) {
            $repo = New-G3Repo -Name ('g5-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Overlay $Overlay
            $r = Invoke-Kit -Command $Cmd -Repo $repo -More $More
            # session-check -AsJson при відмові check друкує порожній масив сигналів (текст відмови — не в JSON): там перевіряється лише маркер.
            if ($More -notcontains '-AsJson') {
                $r.Output | Should -BeLike "*запис №*без значення (ім'я не друкується)*Перевірте пробіл після ':' і форму 'ключ: значення'*"
            }
            Assert-NoMarkers3 -Text $r.Output
        }
        It 'контроль: законний запис «dev» зі значенням і помилкою всередині друкує ім''я' {
            $repo = New-G3Repo -Name 'g5-ctl' -Overlay "infobases:`n  dev: { connection: '' }"
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike "*infobases.dev.connection порожній*"
            $r.Output | Should -Not -BeLike '*без значення (ім''я не друкується)*'
        }
    }

    # Шлях сховища має форму шляху сховища.
    Context '(г2) шлях сховища — лише форма шляху сховища' {
        It 'скаляр «<V>» (check): відмова без значення, форми перелічено' -TestCases @(
            @{ V = 'password :MARKZ9МАРКЗ9' }, @{ V = 'password=MARKZ9МАРКЗ9' }, @{ V = 'password MARKZ9МАРКЗ9' }, @{ V = 'MARKZ9МАРКЗ9' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('h1-' + [guid]::NewGuid().ToString('N').Substring(0, 6))) -WithHooks -WithGitignore -OverlayText "storages:`n  Alpha_SMB: '$V'"
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*шлях сховища має форму*X:*UNC*tcp://*http://*https://*'
            $r.Output | Should -Not -BeLike '*MARKZ9*'
            $r.Output | Should -Not -BeLike '*МАРКЗ9*'
        }
        It 'об''єктна форма path: «password:…» (check): відмова без значення' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'h2') -WithHooks -WithGitignore -OverlayText "storages:`n  Alpha_SMB: { path: 'password:MARKZ9МАРКЗ9' }"
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*шлях сховища має форму*'
            $r.Output | Should -Not -BeLike '*MARKZ9*'
            $r.Output | Should -Not -BeLike '*МАРКЗ9*'
        }
        It 'маніфест storage.path «password:…» (check): відмова без значення' {
            $text = @('version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:', "      Alpha_SMB: { truth: storage, storage: { path: 'password:MARKZ9МАРКЗ9' } }") -join "`n"
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'h3') -ManifestText $text -WithHooks
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*шлях сховища має форму*'
            $r.Output | Should -Not -BeLike '*MARKZ9*'
            $r.Output | Should -Not -BeLike '*МАРКЗ9*'
        }
        It 'контроль: законний шлях «<V>» не дає цієї відмови' -TestCases @(
            @{ V = 'C:\repo' }, @{ V = 'R:\СховищаРозширень_1С\X' }, @{ V = '\\srv\share\repo' }, @{ V = 'tcp://srv/repo' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('h4-' + [guid]::NewGuid().ToString('N').Substring(0, 6))) -WithHooks -WithGitignore -OverlayText "storages:`n  Alpha_SMB: '$V'"
            $r = Invoke-Kit -Command 'check' -Repo $repo
            $r.Output | Should -Not -BeLike '*шлях сховища має форму*'
            if ($V -eq 'tcp://srv/repo') {
                # Рішення 4 плану B3: адреса сервера файлово не пробується — info, а не вічний warn «каталог недоступний».
                $r.Output | Should -Match '(?m)^\[i\] Alpha_SMB/Alpha_SMB: .*серверне сховище — доступність check не перевіряє'
                $r.Output | Should -Not -Match '(?m)^\[!\].*каталог сховища недоступний'
            }
        }
        It 'пароль у userinfo шляху сховища «tcp://user:МАРКЕР@host/x» — ні в stdout, ні в stderr kit.exe check; двійник ***@host є' {
            # Прямий виклик бінарника: stdout і stderr — окремо (Invoke-KitCommand зливає їх), маркер шукається в обох.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'h5-userinfo') -WithHooks -WithGitignore -OverlayText "storages:`n  Alpha_SMB: 'tcp://user:MARKZ9МАРКЗ9@host/x'"
            $errFile = Join-Path $TestDrive 'h5-err.txt'
            $out = & (Get-KitExe -Kit $script:Kit) check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) -RunnerPath (Join-Path $PSScriptRoot 'fixtures/runner/v8-runner.cmd') 2>$errFile | Out-String
            $err = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8
            foreach ($m in 'MARKZ9', 'МАРКЗ9') {
                $out | Should -Not -BeLike "*$m*"
                $err | Should -Not -BeLike "*$m*"
            }
            # Contains, не -BeLike: `*` у шаблоні збіглась би з будь-чим, і маска лишилась би неперевіреною.
            $out.Contains('tcp://***@host/x') | Should -BeTrue -Because $out
        }
        It 'пароль у userinfo шляху сховища «<Scheme>://user:МАРКЕР@host/x» — ні в stdout, ні в stderr kit.exe session-check (текст і -AsJson); рядок джерела друкується' -TestCases @(
            foreach ($scheme in 'tcp', 'http') { foreach ($more in @(@{ M = @() }, @{ M = @('-AsJson') })) { @{ Scheme = $scheme; More = $more.M } } }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ("h6-$Scheme-" + [guid]::NewGuid().ToString('N').Substring(0, 6))) -WithHooks -WithGitattributes -WithGitignore -OverlayText "storages:`n  Alpha_SMB: '${Scheme}://user:MARKZ9МАРКЗ9@host/x'"
            $errFile = Join-Path $TestDrive ("h6-err-$Scheme.txt")
            $out = & (Get-KitExe -Kit $script:Kit) session-check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) -RunnerPath (Join-Path $PSScriptRoot 'fixtures/runner/v8-runner.cmd') @More 2>$errFile | Out-String
            $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 } else { '' }
            foreach ($m in 'MARKZ9', 'МАРКЗ9') {
                $out | Should -Not -BeLike "*$m*"
                $err | Should -Not -BeLike "*$m*"
            }
            # Тест не зеленіє від мовчання: сигнал джерела надруковано (для tcp/http — «серверне сховище»).
            if ($More -contains '-AsJson') { @($out | ConvertFrom-Json)[0].NewInStorageReason | Should -Be 'server' }
            else { $out | Should -BeLike '*- Alpha_SMB: серверне сховище:*' }
        }
        It 'пароль у userinfo шляху, що йде гілкою «сховище недоступне» (файловий шлях із «tcp://user:МАРКЕР@») — ні в stdout, ні в stderr session-check (текст і -AsJson); маска є' -TestCases @(
            @{ More = @() }, @{ More = @('-AsJson') }
        ) {
            $leakPath = 'C:\kit-no-such-dir\tcp://user:MARKZ9МАРКЗ9@host\x'
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ("h7-" + [guid]::NewGuid().ToString('N').Substring(0, 6))) -WithHooks -WithGitattributes -WithGitignore -OverlayText "storages:`n  Alpha_SMB: '$leakPath'"
            $errFile = Join-Path $TestDrive ("h7-err-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
            $out = & (Get-KitExe -Kit $script:Kit) session-check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) -RunnerPath (Join-Path $PSScriptRoot 'fixtures/runner/v8-runner.cmd') @More 2>$errFile | Out-String
            $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 } else { '' }
            foreach ($m in 'MARKZ9', 'МАРКЗ9') {
                $out | Should -Not -BeLike "*$m*"
                $err | Should -Not -BeLike "*$m*"
            }
            # Позитивна асерція: гілку «недоступне» пройдено (без неї відсутність маркера нічого б не доводила).
            if ($More -contains '-AsJson') { $out.Contains('сховище недоступне') | Should -BeTrue -Because $out }
            else {
                $out.Contains('- Alpha_SMB: сховище недоступне') | Should -BeTrue -Because $out
                $out.Contains('C:\kit-no-such-dir\tcp://***@host\x') | Should -BeTrue -Because $out
            }
        }
        It 'контроль харнеса: помилка kit.exe session-check іде в stderr, а не в stdout; обидва потоки прочитано' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'h8-stderr') -WithHooks -WithGitattributes -WithGitignore
            $errFile = Join-Path $TestDrive 'h8-err.txt'
            $out = & (Get-KitExe -Kit $script:Kit) session-check -RepoRoot $repo -Apply 2>$errFile | Out-String
            $err = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8
            $err | Should -BeLike '*session-check: ERROR*'
            $out | Should -Not -BeLike '*session-check: ERROR*'
        }
        It 'контроль маркера: вивід, у який маркер потрапив, перевірку не проходить' {
            $leaked = "- Alpha_SMB: сховище недоступне (каталог недоступний: tcp://user:MARKZ9МАРКЗ9@host/x)"
            { $leaked | Should -Not -BeLike '*MARKZ9*' } | Should -Throw
        }
    }

    Context '(в) Usr/Pwd у підключенні дев-бази людини з накладки' {
        BeforeAll {
            $overlay = @('infobases:', "  dev: { connection: 'File=C:\other\dev;Usr=u;Pwd=SECRETZ7СЕКРЕТ-Ж7' }") -join "`n"
            $script:RepoC = New-KitFakeRepo -Root (Join-Path $TestDrive 'c') -WithHooks -WithGitattributes -WithGitignore -OverlayText $overlay
        }
        It '<Cmd>: маркера немає ні в stdout, ні в stderr' -TestCases @(
            @{ Cmd = 'check' }
            @{ Cmd = 'provision' }
        ) {
            $r = Invoke-Kit -Command $Cmd -Repo $script:RepoC
            $r.Output | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
            $r.Output | Should -Not -BeLike '*SECRETZ7*'
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

Describe 'пароль сховища з " — платформа не запускається (у цьому процесі)' {
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
        # Раннер Уніки — не справжній: платформу воркспейсу і agent release командою sync/verify беруть із цих моків
        # (Get-KitRunnerPath шукав би Уніку на машині, Get-KitAgentPlatform/Invoke-KitAgentRelease запускали б справжній v8-runner).
        Mock -ModuleName sync Get-KitRunnerPath { 'C:\fake\v8-runner.exe' }
        Mock -ModuleName sync Get-KitAgentPlatform { 'C:\fake\8.3.27.9999\bin\1cv8.exe' }
        Mock -ModuleName sync Invoke-KitAgentRelease { [pscustomobject]@{ released = $false; disconnected = $false } }
    }

    It 'sync -Apply: відмова префлайту з Origin, Invoke-V8Designer не викликано, маркера немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'plat') -WithHooks -WithGitignore -WithAgentBase
        $storageDir = Join-Path $TestDrive 'plat-storage'; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        $overlay = @('storages:', "  Alpha_SMB: { path: '$storageDir', password: 'ab""TAILZ7ХВІСТ-Ж7' }") -join "`n"
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
        "$err$text" | Should -Not -BeLike '*TAILZ7*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
        Should -Invoke -ModuleName StoragePlatform New-ExtensionInfobase -Times 0
        Should -Invoke -ModuleName StoragePlatform New-V8FileInfobase -Times 0
    }
}
