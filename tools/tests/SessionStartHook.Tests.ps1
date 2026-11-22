#Requires -Version 7
# Хук SessionStart плагіна — прихована підкоманда `kit.exe session-start` (ADR-0014).
# Тести ходять у закомічений bin/kit.exe: копія плагіна Copy-KitTools несе його в bin/, фальшиві плагіни —
# копію поруч із заглушкою tools/kit.ps1 (корінь плагіна для kit.exe — тека над bin/).
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

        # Фальшивий плагін: kit.exe у bin/ і заглушка tools/kit.ps1, яку підміняє кожен It. Скіл хукові не
        # потрібен (вступ не вклеюється), правил спілкування немає — контекст закінчується вказівкою на скіл.
        $script:FakePlugin = Join-Path $TestDrive 'fake-plugin'
        New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'tools'), (Join-Path $script:FakePlugin 'bin') -Force | Out-Null
        Copy-Item -LiteralPath $script:Exe -Destination (Join-Path $script:FakePlugin 'bin/kit.exe')
        $script:FakeExe = Join-Path $script:FakePlugin 'bin/kit.exe'
        function script:Set-KitStub([string[]]$Lines) {
            # Заглушка диспетчера: вивід у UTF-8 (так робить і справжній tools/kit.ps1), далі — рядки тесту.
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 `
                -Value (@('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8') + $Lines)
        }
        # Репо з маніфестом: без нього хук мовчить і session-check не кличе.
        $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
        New-Item -ItemType Directory -Path $script:FakeRepo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'

        function script:Invoke-Hook {
            # $ProjectDir = $null — змінна CLAUDE_PROJECT_DIR не виставлена. Cwd процесу навмисно НЕ тека
            # проєкту: хук мусить орієнтуватись на змінну, а не на поточну теку. -Env — додаткові змінні.
            # Seconds — до кінця читання stdout і stderr хука (EOF), як читає Claude Code: нащадок, що успадкував
            # канал stdout хука, тримав би читання до власного завершення.
            param([AllowNull()][string]$ProjectDir, [string]$Exe = $script:Exe, [hashtable]$Env = @{})
            $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
            $psi.ArgumentList.Add('session-start')
            $psi.WorkingDirectory = $TestDrive
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
            foreach ($n in 'CLAUDE_PROJECT_DIR', 'V8KIT_SESSION_CHECK_TIMEOUT') { [void]$psi.Environment.Remove($n) }
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
        New-Item -ItemType Directory -Path (Join-Path $plugin 'tools'), (Join-Path $plugin 'hooks'), (Join-Path $plugin 'bin'), (Join-Path $plugin '.claude-plugin') -Force | Out-Null
        Copy-Item -LiteralPath $script:Exe -Destination (Join-Path $plugin 'bin/kit.exe')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../hooks/communication-rules.md') -Destination (Join-Path $plugin 'hooks/communication-rules.md')
        Set-Content -LiteralPath (Join-Path $plugin '.claude-plugin/plugin.json') -Encoding UTF8 -Value '{ "name": "v8storagekit", "version": "9.9.9" }'
        Set-Content -LiteralPath (Join-Path $plugin 'CHANGELOG.md') -Encoding UTF8 -Value @('# Журнал', '', '## 9.9.9 — 2026-11-20', '', '### Що змінилось', '', '- x', '', '### Чекліст оновлення проєкту', '', '- [ ] крок')
        Set-Content -LiteralPath (Join-Path $plugin 'tools/kit.ps1') -Encoding UTF8 -Value '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8', "'СТАН-ЗАГЛУШКА'"
        $repo = Join-Path $TestDrive 'repo-size'
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') -Force | Out-Null
        & git -C $repo init -q
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Encoding UTF8 -Value '{ "kit": { "version": "0.1.0" } }'
        $ctx = ((Invoke-Hook -ProjectDir $repo -Exe (Join-Path $plugin 'bin/kit.exe')).Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $ctx | Should -BeLike '*СТАН-ЗАГЛУШКА*' -Because 'контроль: заглушку стану видно, тож віднімання нижче щось віднімає'
        $ctx | Should -BeLike '*ASD-STE100*' -Because 'контроль: блок правил спілкування входить у виміряну частину'
        $ctx | Should -BeLike '*9.9.9*' -Because 'контроль: рядок оновлення входить у виміряну частину'
        $constant = $ctx.Replace('СТАН-ЗАГЛУШКА', '')
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
            $dir = New-ProfileProject -Name 'profile-only' -ProfileText '{ "kit": { "version": "0.1.0" } }'
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*ASD-STE100*'
            $ctx | Should -BeLike '*unica.search*'
            $ctx | Should -Not -BeLike '*Стан сховищ*'
        }

        It 'профіль <Name>, який читає ConvertFrom-Json, — профіль читається: правила в контексті' -ForEach @(
            @{ Name = 'порожній'; Text = '' }
            @{ Name = 'з коментарями'; Text = "// профіль`n{ `"kit`": /* версія */ { `"version`": `"0.1.0`" }, `"x`": `"a // b /* c */`" }" }
        ) {
            # Еталон — PowerShell-хук до переносу на Rust: він розбирав профіль ConvertFrom-Json (як і KitProfile.psm1).
            { $Text | ConvertFrom-Json } | Should -Not -Throw -Because 'еталон: ConvertFrom-Json приймає цей профіль'
            $dir = New-ProfileProject -Name "profile-lenient-$Name" -ProfileText $Text
            $r = Invoke-Hook -ProjectDir $dir
            $r.ExitCode | Should -Be 0
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike '*ASD-STE100*'
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

    Context 'тиша без pwsh (§7)' {
        BeforeAll {
            # Фальшивий pwsh.exe (саме .exe: заглушку-скрипт пошук pwsh за PATHEXT не знайде) пише маркер і
            # виходить з кодом 0; його тека — першою в PATH процесу хука.
            $bin = Join-Path $TestDrive 'fake-pwsh-bin'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            $src = Join-Path $bin 'fake-pwsh.cs'
            Set-Content -LiteralPath $src -Encoding UTF8 -Value @'
using System; using System.IO;
class FakePwsh { static int Main(string[] a) {
    var m = Environment.GetEnvironmentVariable("FAKE_PWSH_MARKER");
    if (!string.IsNullOrEmpty(m)) File.AppendAllText(m, string.Join(" ", a) + "\n");
    return 0;
} }
'@
            $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
            $out = & $csc /nologo "/out:$(Join-Path $bin 'pwsh.exe')" $src 2>&1
            if ($LASTEXITCODE -ne 0) { throw "не зібрано фальшивий pwsh.exe: $($out -join ' ')" }
            $script:PwshEnv = @{ PATH = "$bin;$env:PATH"; FAKE_PWSH_MARKER = (Join-Path $TestDrive 'pwsh-marker.txt') }
            Set-KitStub @("'не мав запуститись справжній pwsh'")
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

        It 'позитивний двійник: з маніфестом хук запускає саме pwsh з PATH (маркер є)' {
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe -Env $script:PwshEnv
            $r.ExitCode | Should -Be 0
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
            $script:PwshEnv.FAKE_PWSH_MARKER | Should -Exist
            Get-Content -LiteralPath $script:PwshEnv.FAKE_PWSH_MARKER -Raw | Should -BeLike '*-NoProfile -File *kit.ps1*'
        }
    }

    Context 'стеля часу й коди session-check' {
        BeforeAll {
            function script:Get-Grandchild([string]$PidFile, [int]$WaitSeconds = 0) {
                # Онук заглушки за PID з файлу: $null — не стартував; Alive — чи живий (з очікуванням до -WaitSeconds,
                # поки він зникне).
                if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
                $id = [int](Get-Content -LiteralPath $PidFile -Raw).Trim()
                $deadline = (Get-Date).AddSeconds($WaitSeconds)
                while ((Get-Process -Id $id -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
                [pscustomobject]@{ Id = $id; Alive = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
            }
        }

        It 'хук не чекає довше за стелю: повільний session-check дає рядок «не вклався», а не зависання' {
            Set-KitStub @('Start-Sleep -Seconds 30')
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe -Env @{ V8KIT_SESSION_CHECK_TIMEOUT = '1' }
            $r.Seconds | Should -BeLessThan 20        # стеля 1 с + запас на старт pwsh
            $r.Output | Should -BeLike '*не вклався в 1 с*'
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'   # JSON лишився валідним
        }

        It 'те, що kit устиг надрукувати до стелі, потрапляє у вивід із позначкою «частково»' {
            # Заглушка друкує знахідку check і зависає — як повільне джерело після вже виданих рядків check.
            # Стеля 6 с, не 2: заглушка мусить устигнути запустити pwsh, надрукувати рядок і скинути буфер
            # у файл — під паралельним прогоном 2 с інколи не вистачає. Заглушка все одно спить 30 с,
            # тож властивість (частковий вивід до стелі) не міняється, росте лише запас.
            Set-KitStub @("[Console]::Out.WriteLine('[!] хуків немає: kit install-hooks'); [Console]::Out.Flush()", 'Start-Sleep -Seconds 30')
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe -Env @{ V8KIT_SESSION_CHECK_TIMEOUT = '6' }
            $r.Output | Should -BeLike '*Частково*'
            $r.Output | Should -BeLike '*хуків немає: kit install-hooks*'
            $r.Output | Should -BeLike '*повнота НЕ гарантована*'
        }

        It 'на стелі хук убиває дерево: онук, що успадкував вивід, не переживає хука' {
            # Заглушка запускає онука (pwsh зі сном 30 с) з успадкованими stdout/stderr, пише його PID і чекає
            # його. Стеля 3 с, а не 1: заглушка мусить устигнути стартувати pwsh, запустити онука й записати
            # PID; межа часу — стеля + 5 с (мутація «стелю проігноровано» дає 15 с). Онука перевіряємо після
            # кінця читання виводу хука: канал stdout хука нащадки не успадковують (наступний тест), тож EOF
            # настає з виходом хука, а не з природним кінцем онука.
            $pidFile = Join-Path $TestDrive 'grandchild.pid'
            Set-KitStub @(
                '$g = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ''-NoProfile'', ''-c'', ''Start-Sleep 30'' -NoNewWindow -PassThru'
                'Set-Content -LiteralPath $env:GRANDCHILD_PID_FILE -Value $g.Id'
                "[Console]::Out.WriteLine('ОНУК-ЗАПУЩЕНО'); [Console]::Out.Flush()"
                '$g.WaitForExit()'
            )
            $g = $null
            try {
                $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe -Env @{ V8KIT_SESSION_CHECK_TIMEOUT = '3'; GRANDCHILD_PID_FILE = $pidFile }
                $g = Get-Grandchild $pidFile -WaitSeconds 3
                $r.Seconds | Should -BeLessThan 8
                $r.Output | Should -BeLike '*не вклався в 3 с*'
                $r.Output | Should -BeLike '*Частково*ОНУК-ЗАПУЩЕНО*'
                $g | Should -Not -BeNullOrEmpty -Because 'контроль: онук справді стартував до стелі, інакше перевірка нижче порожня'
                $g.Alive | Should -BeFalse -Because 'taskkill /T мав убити й онука'
            } finally {
                if ($g -and $g.Alive) { Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'нащадок, що пережив нормальний вихід session-check, не тримає читання виводу хука' {
            # Заглушка лишає онука (PING на 12 с) і виходить з кодом 0. Онук не в дереві, яке хук убиває: стелі
            # немає. Якби канал stdout хука (дескриптор kit.exe від батька) успадкувався в pwsh, а з ним в онука,
            # читання до EOF чекало б кінця PING (~11 с), як Claude Code чекав би старту сесії.
            $pidFile = Join-Path $TestDrive 'orphan.pid'
            Set-KitStub @(
                '$g = Start-Process -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList ''-n'', ''12'', ''127.0.0.1'' -NoNewWindow -PassThru'
                'Set-Content -LiteralPath $env:GRANDCHILD_PID_FILE -Value $g.Id'
                "[Console]::Out.WriteLine('СТАН-ГОТОВО')"
                'exit 0'
            )
            $g = $null
            try {
                $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe -Env @{ GRANDCHILD_PID_FILE = $pidFile }
                $g = Get-Grandchild $pidFile
                $g | Should -Not -BeNullOrEmpty -Because 'контроль: онук стартував'
                $r.Output | Should -BeLike '*СТАН-ГОТОВО*'
                $r.Seconds | Should -BeLessThan 6 -Because 'читання виводу хука не чекає онука, що успадкував би його канал stdout'
                $g.Alive | Should -BeTrue -Because 'контроль: онук пережив кінець читання — інакше швидкий EOF нічого не доводить'
            } finally {
                if ($g -and $g.Alive) { Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'хук ніколи не передає -Apply: токени в KIT_ARGV — рівно session-check, -RepoRoot і шлях репозиторію' {
            Set-KitStub @('$t = [System.Text.Json.JsonSerializer]::Deserialize[string[]]($env:KIT_ARGV)', "'ARGV ' + (`$t -join '|')")
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe
            $ctx = ($r.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike "*ARGV session-check|-RepoRoot|$script:FakeRepo`n*"
            $ctx | Should -Not -BeLike '*-Apply*'
        }

        It 'session-check завершується неочікуваним кодом (не 0, 1 чи 4) — «НЕВІДОМИЙ», не порожній сигнал' {
            # Процес, що завершився нормально з якимось ІНШИМ кодом (антивірус, OOM, неповний запуск pwsh),
            # без цієї гілки друкувався б як є: порожній вивід читався б як «нових версій немає».
            Set-KitStub @('exit 2')
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe
            $r.Output | Should -BeLike '*НЕВІДОМИЙ*'
            $r.Output | Should -BeLike '*кодом 2*'
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        }

        It 'код <Code> без жодного виводу — «НЕВІДОМИЙ» із кодом, а не порожній «Стан сховищ», що читався б як «без змін»' -ForEach @(
            @{ Code = 1 }
            @{ Code = 4 }
        ) {
            Set-KitStub @("exit $Code")
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe
            $r.Output | Should -BeLike '*НЕВІДОМИЙ*'
            $r.Output | Should -BeLike "*кодом $Code *"
            $r.Output | Should -Not -BeLike '*неочікуваним*' -Because "код $Code контрактний; маркер інший, ніж для сторонніх кодів"
        }

        It 'код 4 з виводом — вивід як є, без «НЕВІДОМИЙ»' {
            Set-KitStub @('[Console]::Out.Write("є нові версії: Alpha_SMB`nnext: kit sync`n")', 'exit 4')
            $ctx = ((Invoke-Hook -ProjectDir $script:FakeRepo -Exe $script:FakeExe).Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -BeLike "*## Стан сховищ (kit session-check)`n`nє нові версії: Alpha_SMB`nnext: kit sync`n`n*"
            $ctx | Should -Not -BeLike '*НЕВІДОМИЙ*'
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
