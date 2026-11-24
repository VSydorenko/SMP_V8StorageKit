#Requires -Version 7
# Хук SessionStart плагіна — прихована підкоманда `kit.exe session-start` (ADR-0014).
# Тести ходять у закомічений bin/kit.exe: копія плагіна Copy-KitTools несе його в bin/, фальшиві плагіни — лише
# копію bin/kit.exe без tools/ (корінь плагіна для kit.exe — тека над bin/). Хук запускає дочірнім процесом сам себе
# (`kit.exe session-check`), диспетчера й pwsh не кличе, тож заглушки tools/kit.ps1 немає: стан сховищ у контексті —
# вивід справжнього Rust session-check. Стелю часу й убивство дерева з повільним раннером перевіряє
# rust/tests/session_start_hook.rs (фальшивий раннер `fake-runner` збирає лише cargo test); відображення коду й
# виводу в текст — unit-тести kit::session_hook.
Describe 'kit.exe session-start — хук SessionStart плагіна' -Tag 'Docs' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:KitRoot = Split-Path -Parent (Split-Path -Parent (Copy-KitTools -Root (Join-Path $TestDrive 'kit')))   # <TestDrive>/kit
        $script:Exe = Join-Path $script:KitRoot 'bin/kit.exe'
        # Маркер, який хук друкує РІВНО в гілці «маніфест лише в предку»: гілка «корінь репозиторію» його не друкує.
        $script:AncestorWarning = 'Уніка бачитиме лише цей воркспейс'

        # Хук запускає справжній kit session-check БЕЗ -InstalledPluginsPath і -RunnerPath (за дизайном),
        # тож версію Уніки kit читає з реєстру домашнього каталогу. Щоб тест не залежав від Уніки на машині,
        # підпроцесу підставляємо фальшивий дім (форма запису Уніки — з New-KitFakeUnicaRegistry).
        $script:FakeHome = Join-Path $TestDrive 'fake-home'
        New-Item -ItemType Directory -Path (Join-Path $script:FakeHome '.claude/plugins') -Force | Out-Null
        $homeRegistry = Get-Content -LiteralPath (New-KitFakeUnicaRegistry) -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $homeRegistry.plugins['v8storagekit@smp-v8storagekit'] = @(@{ version = 'test'; installPath = $script:KitRoot })
        $homeRegistry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude/plugins/installed_plugins.json') -Encoding UTF8

        # Фальшивий плагін: лише kit.exe у bin/, без tools/ (диспетчера немає — хук мусить працювати й так). Скіл
        # хукові не потрібен (вступ не вклеюється), правил спілкування немає — контекст закінчується вказівкою на скіл.
        $script:FakePlugin = Join-Path $TestDrive 'fake-plugin'
        New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'bin') -Force | Out-Null
        Copy-Item -LiteralPath $script:Exe -Destination (Join-Path $script:FakePlugin 'bin/kit.exe')
        $script:FakeExe = Join-Path $script:FakePlugin 'bin/kit.exe'
        # Тека з маніфестом, але не git-репозиторій: session-check зупиняється з кодом 1, порожнім stdout і
        # «session-check: ERROR …» у stderr.
        $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
        New-Item -ItemType Directory -Path $script:FakeRepo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'

        function script:Invoke-Hook {
            # $ProjectDir = $null — змінна CLAUDE_PROJECT_DIR не виставлена. Cwd процесу навмисно НЕ тека
            # проєкту: хук мусить орієнтуватись на змінну, а не на поточну теку. -Env — додаткові змінні.
            # Seconds — до кінця читання stdout і stderr хука (EOF), як читає Claude Code: нащадок, що успадкував
            # канал stdout хука, тримав би читання до власного завершення.
            param([AllowNull()][string]$ProjectDir, [string]$Exe = $script:Exe, [hashtable]$Env = @{}, [string]$WorkDir = $TestDrive)
            $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
            $psi.ArgumentList.Add('session-start')
            $psi.WorkingDirectory = $WorkDir
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
            foreach ($n in 'CLAUDE_PROJECT_DIR', 'V8KIT_SESSION_CHECK_TIMEOUT', 'GIT_TRACE') { [void]$psi.Environment.Remove($n) }
            if ($ProjectDir) { $psi.Environment['CLAUDE_PROJECT_DIR'] = $ProjectDir }
            $psi.Environment['HOME'] = $script:FakeHome
            $psi.Environment['USERPROFILE'] = $script:FakeHome
            foreach ($k in $Env.Keys) { $psi.Environment[$k] = $Env[$k] }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $p.WaitForExit()
            $output = $out.Result
            $errors = $err.Result
            $sw.Stop()
            [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $output; Err = $errors; Seconds = $sw.Elapsed.TotalSeconds }
        }
    }

    It 'проєкт без маніфесту й без предка з ним, а також без змінної CLAUDE_PROJECT_DIR — код 0, вивід порожній' {
        # Хук спрацьовує в КОЖНІЙ сесії машини, і в не-1С проєктах теж: тиша тут — головна властивість.
        $plain = Join-Path $TestDrive 'plain/inner'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $r = Invoke-Hook -ProjectDir $plain
        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
        $r = Invoke-Hook -ProjectDir $null
        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
    }

    It 'корінь репозиторію: валідний JSON із вступом і станом сховищ, без попередження; дерево не змінене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Hook -ProjectDir $repo
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $ctx = $json.hookSpecificOutput.additionalContext
        $ctx | Should -BeLike '*storage-rules*'
        # Хук -RunnerPath не передає (за дизайном), а фальшивий дім не несе справжнього v8-runner.exe. runner-version —
        # знахідка про СТАН МАШИНИ й сигнали не блокує: у контексті є і перелік джерел, і рядок про недоступний раннер.
        $ctx | Should -BeLike '*session-check*- Alpha_SMB:*'
        $ctx | Should -BeLike '*Раннер Уніки недоступний*'
        $ctx | Should -Not -BeLike '*Сигнали не обчислювались*'
        $ctx | Should -Not -BeLike '*НЕВІДОМИЙ*' -Because 'знахідка про стан машини не змінює код session-check: код 1 хук читає як «стан невідомий»'
        $ctx | Should -Not -BeLike "*$script:AncestorWarning*"
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }

    It 'підтека репозиторію: той самий контекст плюс попередження «Уніка бачитиме лише цей воркспейс», яке називає обидві теки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo-sub') -WithHooks -WithGitattributes -WithGitignore
        $sub = Join-Path $repo 'Alpha'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $r = Invoke-Hook -ProjectDir $sub
        $r.ExitCode | Should -Be 0
        $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $ctx | Should -BeLike '*session-check*- Alpha_SMB:*'
        $ctx | Should -BeLike "*$script:AncestorWarning*"
        $ctx | Should -BeLike "*$sub*"
        $ctx | Should -BeLike "*$repo*"
    }

    It 'вступ не вклеюється: стан сховищ стоїть перед вказівкою на скіл, тексту SKILL.md у виводі немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo-order') -WithHooks -WithGitattributes -WithGitignore
        $ctx = ((Invoke-Hook -ProjectDir $repo).Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $state = $ctx.IndexOf('Стан сховищ')
        $pointer = $ctx.IndexOf('v8storagekit:storage-rules')
        $state | Should -BeGreaterOrEqual 0
        $pointer | Should -BeGreaterThan $state -Because 'прев''ю виводу обрізається з кінця: стан мусить стояти першим'
        # Рядок, що є лише в SKILL.md (перевірено пошуком по дереву): його присутність у виводі = вступ вклеєно.
        $skillText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/storage-rules/SKILL.md') -Raw -Encoding UTF8
        $skillText | Should -BeLike '*Крок, надрукований командою kit, — виконати дослівно*' -Because 'контроль: маркер мусить існувати в SKILL.md'
        $ctx | Should -Not -BeLike '*Крок, надрукований командою kit, — виконати дослівно*'
    }

    It 'постійна частина виводу хука (без стану й попередження) вміщається у 2048 байт UTF-8' {
        # Найгірший випадок постійної частини: маніфест І профіль процесу, що відстав від плагіна —
        # тоді до вказівки на скіл додаються правила спілкування й рядок оновлення. Фальшивий плагін
        # несе справжні hooks/communication-rules.md, plugin.json і журнал з кроком, інакше межа
        # міряла б вивід без блоку правил.
        $plugin = Join-Path $TestDrive 'fake-plugin-size'
        New-Item -ItemType Directory -Path (Join-Path $plugin 'hooks'), (Join-Path $plugin 'bin'), (Join-Path $plugin '.claude-plugin') -Force | Out-Null
        Copy-Item -LiteralPath $script:Exe -Destination (Join-Path $plugin 'bin/kit.exe')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../hooks/communication-rules.md') -Destination (Join-Path $plugin 'hooks/communication-rules.md')
        Set-Content -LiteralPath (Join-Path $plugin '.claude-plugin/plugin.json') -Encoding UTF8 -Value '{ "name": "v8storagekit", "version": "9.9.9" }'
        Set-Content -LiteralPath (Join-Path $plugin 'CHANGELOG.md') -Encoding UTF8 -Value @('# Журнал', '', '## 9.9.9 — 2026-11-20', '', '### Що змінилось', '', '- x', '', '### Чекліст оновлення проєкту', '', '- [ ] крок')
        $repo = Join-Path $TestDrive 'repo-size'
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') -Force | Out-Null
        & git -C $repo init -q
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Encoding UTF8 -Value '{ "kit": { "version": "0.1.0" } }'
        $ctx = ((Invoke-Hook -ProjectDir $repo -Exe (Join-Path $plugin 'bin/kit.exe')).Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        # Стан — текст справжнього session-check між заголовком розділу і вказівкою на скіл; його й віднімаємо.
        $head = "## Стан сховищ (kit session-check)`n`n"
        $ctx.IndexOf($head) | Should -BeGreaterOrEqual 0
        $from = $ctx.IndexOf($head) + $head.Length
        $to = $ctx.IndexOf("`n`nРепозиторій під kit.")
        $state = $ctx.Substring($from, $to - $from)
        $state.Trim() | Should -Not -BeNullOrEmpty -Because 'контроль: стан у контексті є, тож віднімання нижче щось віднімає'
        $ctx | Should -BeLike '*ASD-STE100*' -Because 'контроль: блок правил спілкування входить у виміряну частину'
        $ctx | Should -BeLike '*9.9.9*' -Because 'контроль: рядок оновлення входить у виміряну частину'
        $constant = $ctx.Remove($from, $to - $from)
        [System.Text.Encoding]::UTF8.GetByteCount($constant) | Should -BeLessOrEqual 2048
    }

    It 'репозиторій суперечливий (kit check має помилку, session-check код 1) — хук друкує вивід як є, без обгортки «неочікуваним кодом»' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'inconsistent') -WithHooks
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=build/ib'")   # стара форма: error у check
        $r = Invoke-Hook -ProjectDir $repo
        $r.ExitCode | Should -Be 0
        $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $ctx | Should -BeLike '*спершу kit check*'
        $ctx | Should -Not -BeLike '*неочікуваним*' -Because 'код 1 — контрактний код session-check, не збій'
    }

    Context 'блок правил спілкування' {
        BeforeAll {
            function script:New-ProfileProject {
                param([string]$Name, [string]$ProfileText)
                $dir = Join-Path $TestDrive $Name
                New-Item -ItemType Directory -Path (Join-Path $dir '.git') -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $dir '.agents') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir '.agents/kit.profile.json') -Value $ProfileText -Encoding UTF8
                $dir
            }
        }

        It 'лише профіль процесу: у контексті правила, «Стану сховищ» немає' {
            $dir = New-ProfileProject -Name 'profile-only' -ProfileText '{ "v8storagekit": { "version": "0.1.0" } }'
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*ASD-STE100*'
            $ctx | Should -BeLike '*unica.search*'
            $ctx | Should -Not -BeLike '*Стан сховищ*'
        }

        It 'профіль <Name>, який читає ConvertFrom-Json, — профіль читається: правила в контексті' -ForEach @(
            @{ Name = 'з коментарями'; Text = "// профіль`n{ `"v8storagekit`": /* версія */ { `"version`": `"0.1.0`" }, `"x`": `"a // b /* c */`" }" }
        ) {
            # Еталон — PowerShell-хук до переносу на Rust: він розбирав профіль ConvertFrom-Json (як і KitProfile.psm1).
            { $Text | ConvertFrom-Json } | Should -Not -Throw -Because 'еталон: ConvertFrom-Json приймає цей профіль'
            $dir = New-ProfileProject -Name "profile-lenient-$Name" -ProfileText $Text
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*ASD-STE100*'
        }

        It 'профіль agent-kit без версії v8storagekit і без маніфесту — тиша й код 0' {
            $dir = New-ProfileProject -Name 'profile-agentkit' -ProfileText '{ "kit": { "version": "0.11.5" } }'
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'профіль з v8storagekit.version без маніфесту — правила в контексті' {
            $dir = New-ProfileProject -Name 'profile-v8k' -ProfileText '{ "v8storagekit": { "version": "1.2.3" } }'
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext | Should -BeLike '*ASD-STE100*'
        }

        It 'лише профіль, але зламаний JSON — тиша й код 0' {
            $dir = New-ProfileProject -Name 'profile-broken' -ProfileText '{ broken'
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $r.Output.Trim() | Should -BeNullOrEmpty
        }

        It 'межа розміру: правила без коментаря-шапки — не довші за 780 символів' {
            $raw = Get-Content -LiteralPath (Join-Path $script:KitRoot 'hooks/communication-rules.md') -Raw -Encoding UTF8
            $body = [regex]::Replace($raw, '\A\s*<!--.*?-->', '', 'Singleline').Trim()
            $body.Length | Should -BeLessOrEqual 780
        }
    }

    Context 'без pwsh і без чужого kit.exe' {
        BeforeAll {
            # Фальшивий pwsh.exe (саме .exe: заглушку-скрипт пошук pwsh за PATHEXT не знайде) пише маркер і
            # виходить з кодом 0; його копія kit.exe — так само. Обидва — у теці першою в PATH процесу хука і в
            # окремій робочій теці хука.
            $bin = Join-Path $TestDrive 'fake-pwsh-bin'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            $src = Join-Path $bin 'fake-pwsh.cs'
            Set-Content -LiteralPath $src -Encoding UTF8 -Value @'
using System; using System.IO;
class FakePwsh { static int Main(string[] a) {
    var m = Environment.GetEnvironmentVariable("FAKE_PWSH_MARKER");
    if (!string.IsNullOrEmpty(m)) File.AppendAllText(m, Environment.CommandLine + "\n");
    return 0;
} }
'@
            $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
            $out = & $csc /nologo "/out:$(Join-Path $bin 'pwsh.exe')" $src 2>&1
            if ($LASTEXITCODE -ne 0) { throw "не зібрано фальшивий pwsh.exe: $($out -join ' ')" }
            Copy-Item -LiteralPath (Join-Path $bin 'pwsh.exe') -Destination (Join-Path $bin 'kit.exe')
            $script:FakeBin = $bin
            $script:FakeCwd = Join-Path $TestDrive 'fake-cwd'
            New-Item -ItemType Directory -Path $script:FakeCwd -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $bin 'pwsh.exe'), (Join-Path $bin 'kit.exe') -Destination $script:FakeCwd
            $script:PwshEnv = @{ PATH = "$bin;$env:PATH"; FAKE_PWSH_MARKER = (Join-Path $TestDrive 'pwsh-marker.txt') }
            # Репозиторій, де справжній session-check друкує рядок джерела.
            $script:SignalRepo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo-no-pwsh') -WithHooks -WithGitattributes -WithGitignore
        }
        BeforeEach { Remove-Item -LiteralPath $script:PwshEnv.FAKE_PWSH_MARKER -ErrorAction SilentlyContinue }

        It 'без маніфесту й профілю — тиша, код 0, pwsh не запускався' {
            $plain = Join-Path $TestDrive 'no-pwsh/inner'
            New-Item -ItemType Directory -Path (Join-Path $TestDrive 'no-pwsh/.git') -Force | Out-Null
            New-Item -ItemType Directory -Path $plain -Force | Out-Null
            $r = Invoke-Hook -ProjectDir $plain -Exe $script:FakeExe -Env $script:PwshEnv
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeNullOrEmpty
            $r.Err | Should -BeNullOrEmpty
            $script:PwshEnv.FAKE_PWSH_MARKER | Should -Not -Exist
        }

        It 'хук не запускає pwsh, але запускає session-check: маркера немає, у контексті — вивід справжнього Rust session-check' {
            # Плагін без tools/: диспетчера немає, тож стан у контексті дав би лише дочірній kit.exe session-check.
            $r = Invoke-Hook -ProjectDir $script:SignalRepo -Exe $script:FakeExe -Env $script:PwshEnv
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $script:PwshEnv.FAKE_PWSH_MARKER | Should -Not -Exist -Because (Get-Content -LiteralPath $script:PwshEnv.FAKE_PWSH_MARKER -Raw -ErrorAction SilentlyContinue)
            # Плагін без templates/githooks: check не перевіряє вміст хуків — код 3, «ЧАСТКОВО НЕВІДОМИЙ» і вивід як є.
            $ctx | Should -BeLike "*## Стан сховищ (kit session-check)`n`n*session-check — product Fake*`n- Alpha_SMB: *"
        }

        It 'фальшиві kit.exe і pwsh.exe у PATH і в робочій теці хука не запускаються: дочірній — сам kit.exe хука' {
            # Копія плагіна з tools/kit.ps1: хук, що знову пішов би в диспетчер, запустив би фальшивий pwsh (маркер).
            $r = Invoke-Hook -ProjectDir $script:SignalRepo -Env $script:PwshEnv -WorkDir $script:FakeCwd
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $script:PwshEnv.FAKE_PWSH_MARKER | Should -Not -Exist -Because (Get-Content -LiteralPath $script:PwshEnv.FAKE_PWSH_MARKER -Raw -ErrorAction SilentlyContinue)
            $ctx | Should -BeLike '*- Alpha_SMB: *' -Because 'тест не зеленіє на хуку, що нічого не запустив'
        }

        It 'контроль харнеса: фальшиві kit.exe і pwsh.exe справді лишають маркер, коли їх запускають' {
            foreach ($exe in (Join-Path $script:FakeBin 'kit.exe'), (Join-Path $script:FakeCwd 'pwsh.exe')) {
                Remove-Item -LiteralPath $script:PwshEnv.FAKE_PWSH_MARKER -ErrorAction SilentlyContinue
                $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
                $psi.UseShellExecute = $false
                $psi.Environment['FAKE_PWSH_MARKER'] = $script:PwshEnv.FAKE_PWSH_MARKER
                [System.Diagnostics.Process]::Start($psi).WaitForExit()
                $script:PwshEnv.FAKE_PWSH_MARKER | Should -Exist -Because $exe
            }
        }
    }

    Context 'коди session-check і межа довіри контексту' {
        It 'корінь не git: session-check — код 1 без stdout → «НЕВІДОМИЙ» із кодом; його stderr у контекст не потрапляє' {
            # Контроль: та сама дитина справді друкує помилку в stderr (інакше відсутність нижче нічого не доводить).
            $errFile = Join-Path $TestDrive 'code1-err.txt'
            $direct = & $script:Exe session-check -RepoRoot $script:FakeRepo 2>$errFile | Out-String
            $LASTEXITCODE | Should -Be 1
            $direct.Trim() | Should -BeNullOrEmpty
            Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 | Should -BeLike '*session-check: ERROR*'

            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*кодом 1 без жодного виводу — стан сховищ НЕВІДОМИЙ*'
            $ctx | Should -Not -BeLike '*неочікуваним*' -Because 'код 1 контрактний'
            $ctx | Should -Not -BeLike '*session-check: ERROR*' -Because 'stderr дочірнього процесу — не контекст'
        }

        It 'код 3 (сховище прочитано не повністю) — «стан сховищ ЧАСТКОВО НЕВІДОМИЙ» і вивід session-check' {
            $s = Join-Path $TestDrive 'storage-partial'
            New-Item -ItemType Directory -Path (Join-Path $s 'data/objects/ab') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $s 'data/objects/ab/cdef.bin') -Value 'obj'
            Set-Content -LiteralPath (Join-Path $s '1cv8ddb.1CD') -Value 'db'
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo-partial') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithHooks -WithGitattributes -WithGitignore
            $denied = Join-Path $s 'data/objects/ab'
            $who = "$env:USERDOMAIN\$env:USERNAME"
            & icacls $denied /deny "${who}:(OI)(CI)R" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls /deny не спрацював для $denied" }
            try {
                & $script:Exe session-check -RepoRoot $repo 2>$null | Out-Null
                $direct = $LASTEXITCODE
                $r = Invoke-Hook -ProjectDir $repo
            } finally { & icacls $denied /remove:d $who | Out-Null }
            $direct | Should -Be 3 -Because 'контроль: дочірній процес справді дає код 3'
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike "*## Стан сховищ (kit session-check)`n`nУВАГА: kit session-check завершився кодом 3 — стан сховищ ЧАСТКОВО НЕВІДОМИЙ*`n`nsession-check — *- Alpha_SMB: стан сховища прочитано не повністю (немає доступу)*"
            $ctx | Should -Not -BeLike '*неочікуваним*'
        }

        It 'пароль у userinfo шляху сховища (<Name>) не з''являється в контексті хука; маска є' -TestCases @(
            @{ Name = 'серверна адреса'; Path = 'tcp://user:MARKZ9МАРКЗ9@host/x'; Line = '- Alpha_SMB: серверне сховище:' ; Mask = $null }
            @{ Name = 'файловий шлях, гілка «недоступне»'; Path = 'C:\kit-no-such-dir\tcp://user:MARKZ9МАРКЗ9@host\x'; Line = '- Alpha_SMB: сховище недоступне'; Mask = 'C:\kit-no-such-dir\tcp://***@host\x' }
        ) {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive ('repo-secret-' + [guid]::NewGuid().ToString('N').Substring(0, 6))) -WithHooks -WithGitattributes -WithGitignore -OverlayText "storages:`n  Alpha_SMB: '$Path'"
            $r = Invoke-Hook -ProjectDir $repo
            $r.ExitCode | Should -Be 0
            foreach ($m in 'MARKZ9', 'МАРКЗ9') {
                $r.Output | Should -Not -BeLike "*$m*"
                $r.Err | Should -Not -BeLike "*$m*"
            }
            # Позитивна асерція: гілку джерела пройдено (без неї відсутність маркера нічого б не доводила).
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx.Contains($Line) | Should -BeTrue -Because $ctx
            if ($Mask) { $ctx.Contains($Mask) | Should -BeTrue -Because $ctx }
        }

        It 'Usr/Pwd у рядку підключення бази агента (клас (а)) не з''являються в контексті хука; рецепт є' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo-secret-a') -WithHooks -WithGitattributes -WithGitignore
            Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib;Usr=agent;Pwd=SECRETZ7СЕКРЕТ-Ж7'
            $r = Invoke-Hook -ProjectDir $repo
            $r.ExitCode | Should -Be 0
            foreach ($m in 'SECRETZ7', 'СЕКРЕТ-Ж7', 'Pwd=') {
                $r.Output | Should -Not -BeLike "*$m*"
                $r.Err | Should -Not -BeLike "*$m*"
            }
            # Позитивна асерція: помилку підключення дійшло до контексту (без неї відсутність маркера нічого б не доводила).
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*задаються ключами user і password в infobases.origin*' -Because $ctx
        }

        It 'контроль маркера: контекст, у який маркер потрапив, перевірку не проходить' {
            $leaked = '{"hookSpecificOutput":{"additionalContext":"- Alpha_SMB: сховище недоступне (каталог недоступний: tcp://user:MARKZ9МАРКЗ9@host/x)"}}'
            { $leaked | Should -Not -BeLike '*MARKZ9*' } | Should -Throw
            { $leaked | Should -Not -BeLike '*МАРКЗ9*' } | Should -Throw
        }
    }
}

Describe 'hooks/hooks.json — оголошення хука плагіна' -Tag 'Docs' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'має обгортку hooks.SessionStart; команда — ${CLAUDE_PLUGIN_ROOT}/bin/kit.exe session-start без pwsh; хука-скрипта немає' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Root 'hooks/hooks.json') -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json   # не розбирається — тест падає тут
        $json.PSObject.Properties.Name | Should -Contain 'hooks'
        $entry = @($json.hooks.SessionStart)
        $entry.Count | Should -Be 1
        $entry[0].matcher | Should -Be 'startup|clear|compact'
        $entry[0].hooks[0].type | Should -Be 'command'
        # Форма вживання токена (правило 1 CLAUDE.md): за токеном одразу «/»; безумовний exit 0.
        $entry[0].hooks[0].command | Should -BeExactly '"${CLAUDE_PLUGIN_ROOT}/bin/kit.exe" session-start; exit 0'
        Join-Path $script:Root 'hooks/session-start.ps1' | Should -Not -Exist
    }

    It 'стеля session-check не вища за timeout хука мінус 5 с: межа в коді = timeout − 5, умовчання не вище за межу' {
        # Claude Code убиває хук на його timeout — тоді контексту немає взагалі, навіть «не вклався». Межу в коді
        # (kit::session_hook) з hooks.json не виведено, тож змінене одне без другого мусить дати червоне тут.
        $json = Get-Content -LiteralPath (Join-Path $script:Root 'hooks/hooks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $timeout = [int]@($json.hooks.SessionStart)[0].hooks[0].timeout
        $timeout | Should -BeGreaterThan 5
        $code = Get-Content -LiteralPath (Join-Path $script:Root 'rust/src/session_hook.rs') -Raw -Encoding UTF8
        $max = [regex]::Matches($code, '(?m)^pub const MAX_TIMEOUT_SEC: u64 = (\d+);')
        $default = [regex]::Matches($code, '(?m)^pub const DEFAULT_TIMEOUT_SEC: u64 = (\d+);')
        $max.Count | Should -Be 1 -Because 'константа межі в коді мусить існувати рівно раз'
        $default.Count | Should -Be 1
        [int]$max[0].Groups[1].Value | Should -Be ($timeout - 5)
        [int]$default[0].Groups[1].Value | Should -Be 15
        [int]$default[0].Groups[1].Value | Should -BeLessOrEqual ($timeout - 5)
    }
}

Describe 'Test-KitLegacySessionHook — старий проєктний хук (до 1.6.0)' -Tag 'Docs' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        function script:New-LegacyHookRepo {
            param([string]$Name, [switch]$Settings, [switch]$Shim)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name)
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude/hooks') -Force | Out-Null
            if ($Settings) {
                Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Encoding UTF8 -Value (@{
                    hooks = @{ SessionStart = @(@{ matcher = 'startup'; hooks = @(@{ type = 'command'; command = 'pwsh -NoProfile -File .claude/hooks/session-start.ps1' }) }) } } | ConvertTo-Json -Depth 8)
            }
            if ($Shim) { Set-Content -LiteralPath (Join-Path $repo '.claude/hooks/session-start.ps1') -Value '# старий шим' }
            $repo
        }
    }

    It 'settings.json зі старим hooks.SessionStart І файл-шим — одна warn, що називає обидва шляхи' {
        $repo = New-LegacyHookRepo -Name 'both' -Settings -Shim
        $f = @(Test-KitLegacySessionHook -RepoRoot $repo)
        $f.Count | Should -Be 1
        $f[0].Level | Should -Be 'warn'
        # Перелік ЗНАЙДЕНОГО (до слова «Тепер»), а не рецепт: рецепт називає обидва шляхи завжди.
        $f[0].Message | Should -BeLike '*хук старту сесії: .claude/settings.json (hooks.SessionStart*); .claude/hooks/session-start.ps1. Тепер*'
    }

    It 'контроль: чистий репозиторій, settings.json без хука, чужий SessionStart — жодної знахідки' {
        @(Test-KitLegacySessionHook -RepoRoot (New-LegacyHookRepo -Name 'clean')).Count | Should -Be 0
        $repo = New-LegacyHookRepo -Name 'foreign'
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Encoding UTF8 -Value (@{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'echo hi' }) }) }; permissions = @{ allow = @() } } | ConvertTo-Json -Depth 8)
        @(Test-KitLegacySessionHook -RepoRoot $repo).Count | Should -Be 0
    }

    It 'лише файл-шим — warn про шим; лише settings.json — warn про hooks.SessionStart' {
        $f = @(Test-KitLegacySessionHook -RepoRoot (New-LegacyHookRepo -Name 'shim-only' -Shim))
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*хук старту сесії: .claude/hooks/session-start.ps1. Тепер*'
        $f = @(Test-KitLegacySessionHook -RepoRoot (New-LegacyHookRepo -Name 'settings-only' -Settings))
        $f.Count | Should -Be 1
        $f[0].Message | Should -BeLike '*hooks.SessionStart*'
    }

    It 'settings.json — битий JSON — рівно одна warn «не читається», не error' {
        $repo = New-LegacyHookRepo -Name 'broken'
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ broken' -Encoding UTF8
        $f = @(Test-KitLegacySessionHook -RepoRoot $repo)
        $f.Count | Should -Be 1
        $f[0].Level | Should -Be 'warn'
        $f[0].Message | Should -BeLike '*не читається як JSON*'
    }
}
