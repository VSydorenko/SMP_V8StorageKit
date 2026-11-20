#Requires -Version 7
Describe 'hooks/session-start.ps1 — хук SessionStart плагіна' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:KitRoot = Split-Path -Parent (Split-Path -Parent (Copy-KitTools -Root (Join-Path $TestDrive 'kit')))   # <TestDrive>/kit
        $script:Hook = Join-Path $script:KitRoot 'hooks/session-start.ps1'
        # Маркер, який у скрипті хука є РІВНО в гілці «маніфест лише в предку» (grep по hooks/session-start.ps1
        # знаходить його один раз): гілка «корінь репозиторію» його не друкує.
        $script:AncestorWarning = 'Уніка бачитиме лише цей воркспейс'

        # Хук запускає справжній kit session-check БЕЗ -InstalledPluginsPath і -RunnerPath (за дизайном),
        # тож версію Уніки kit читає з реєстру домашнього каталогу. Щоб тест не залежав від Уніки на машині,
        # підпроцесу підставляємо фальшивий дім (форма запису Уніки — з New-KitFakeUnicaRegistry).
        $script:FakeHome = Join-Path $TestDrive 'fake-home'
        New-Item -ItemType Directory -Path (Join-Path $script:FakeHome '.claude/plugins') -Force | Out-Null
        $homeRegistry = Get-Content -LiteralPath (New-KitFakeUnicaRegistry) -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $homeRegistry.plugins['v8storagekit@smp-v8storagekit'] = @(@{ version = 'test'; installPath = $script:KitRoot })
        $homeRegistry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude/plugins/installed_plugins.json') -Encoding UTF8

        function script:Invoke-Hook {
            # $ProjectDir = $null — змінна CLAUDE_PROJECT_DIR не виставлена. Cwd процесу навмисно НЕ тека
            # проєкту: хук мусить орієнтуватись на змінну, а не на поточну теку.
            param([AllowNull()][string]$ProjectDir, [string]$Hook = $script:Hook)
            $prevProject = $env:CLAUDE_PROJECT_DIR
            $prevHome = $env:HOME; $prevProfile = $env:USERPROFILE
            if ($ProjectDir) { $env:CLAUDE_PROJECT_DIR = $ProjectDir } else { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
            $env:HOME = $script:FakeHome; $env:USERPROFILE = $script:FakeHome
            try {
                Push-Location $TestDrive
                try { $out = & pwsh -NoProfile -File $Hook 2>&1 | Out-String } finally { Pop-Location }
            } finally {
                if ($null -eq $prevProject) { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevProject }
                $env:HOME = $prevHome; $env:USERPROFILE = $prevProfile
            }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
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
        $ctx | Should -BeLike '*using-v8storagekit*'
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
        $pointer = $ctx.IndexOf('v8storagekit:using-v8storagekit')
        $state | Should -BeGreaterOrEqual 0
        $pointer | Should -BeGreaterThan $state -Because 'прев''ю виводу обрізається з кінця: стан мусить стояти першим'
        # Рядок, що є лише в SKILL.md (перевірено пошуком по дереву поза docs/superpowers/): його присутність у виводі = вступ вклеєно.
        $skillText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/using-v8storagekit/SKILL.md') -Raw -Encoding UTF8
        $skillText | Should -BeLike '*Крок, надрукований командою kit, — виконати дослівно*' -Because 'контроль: маркер мусить існувати в SKILL.md'
        $ctx | Should -Not -BeLike '*Крок, надрукований командою kit, — виконати дослівно*'
    }

    It 'постійна частина виводу хука (без стану й попередження) вміщається у 2048 байт UTF-8' {
        $plugin = Join-Path $TestDrive 'fake-plugin-size'
        New-Item -ItemType Directory -Path (Join-Path $plugin 'tools'), (Join-Path $plugin 'hooks') -Force | Out-Null
        Copy-Item -LiteralPath $script:Hook -Destination (Join-Path $plugin 'hooks/session-start.ps1')
        Set-Content -LiteralPath (Join-Path $plugin 'tools/kit.ps1') -Encoding UTF8 -Value "'СТАН-ЗАГЛУШКА'"
        $repo = Join-Path $TestDrive 'repo-size'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
        $ctx = ((Invoke-Hook -ProjectDir $repo -Hook (Join-Path $plugin 'hooks/session-start.ps1')).Output | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $ctx | Should -BeLike '*СТАН-ЗАГЛУШКА*' -Because 'контроль: заглушку стану видно, тож віднімання нижче щось віднімає'
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

    Context 'стеля часу' {
        BeforeAll {
            # Окремий фейковий плагін: kit.ps1 підміняється в кожному It, скіл хукові не потрібен (вступ не вклеюється).
            $script:FakePlugin = Join-Path $TestDrive 'fake-plugin'
            New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'tools') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'hooks') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'skills/using-v8storagekit') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'skills/using-v8storagekit/SKILL.md') -Encoding UTF8 -Value '# вступ'
            Copy-Item -LiteralPath $script:Hook -Destination (Join-Path $script:FakePlugin 'hooks/session-start.ps1')
            $script:FakeHook = Join-Path $script:FakePlugin 'hooks/session-start.ps1'
            # Репо з маніфестом: без нього хук мовчить і session-check не кличе.
            $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
            New-Item -ItemType Directory -Path $script:FakeRepo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:FakeRepo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
        }

        It 'хук не чекає довше за стелю: повільний session-check дає рядок «не вклався», а не зависання' {
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'Start-Sleep -Seconds 30'
            $env:V8KIT_SESSION_CHECK_TIMEOUT = '1'
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-Hook -ProjectDir $script:FakeRepo -Hook $script:FakeHook
                $sw.Stop()
            } finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 20        # стеля 1 с + запас на старт pwsh
            $r.Output | Should -BeLike '*не вклався*'
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'   # JSON лишився валідним
        }

        It 'те, що kit устиг надрукувати до стелі, потрапляє у вивід із позначкою «частково»' {
            # Заглушка друкує знахідку check і зависає — як повільне джерело після вже виданих рядків check.
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 `
                -Value "'[!] хуків немає: kit install-hooks'", 'Start-Sleep -Seconds 30'
            # Стеля 6 с, не 2: заглушка мусить устигнути запустити pwsh, надрукувати рядок і скинути буфер
            # у файл — під паралельним прогоном 2 с інколи не вистачає. Заглушка все одно спить 30 с,
            # тож властивість (частковий вивід до стелі) не міняється, росте лише запас.
            $env:V8KIT_SESSION_CHECK_TIMEOUT = '6'
            try { $r = Invoke-Hook -ProjectDir $script:FakeRepo -Hook $script:FakeHook }
            finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
            $r.Output | Should -BeLike '*Частково*'
            $r.Output | Should -BeLike '*install-hooks*'
            $r.Output | Should -BeLike '*повнота НЕ гарантована*'
        }

        It 'хук ніколи не передає -Apply' {
            # Заглушка друкує власні аргументи — хук мусить дати рівно session-check -RepoRoot <шлях>.
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'param([Parameter(ValueFromRemainingArguments)]$Rest) $Rest -join " "'
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Hook $script:FakeHook
            $r.Output | Should -Not -BeLike '*-Apply*'
            $r.Output | Should -BeLike '*session-check*-RepoRoot*'
        }

        It 'I5: session-check завершується неочікуваним кодом (не 0, не 3) — «НЕВІДОМИЙ», не порожній сигнал' {
            # Процес, що завершився нормально з якимось ІНШИМ кодом (антивірус, OOM, неповний запуск pwsh),
            # без цієї гілки друкувався б як є: порожній вивід читався б як «нових версій немає».
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'exit 2'
            $r = Invoke-Hook -ProjectDir $script:FakeRepo -Hook $script:FakeHook
            $r.Output | Should -BeLike '*НЕВІДОМИЙ*'
            $r.Output | Should -BeLike '*кодом 2*'
            ($r.Output | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        }
    }
}

Describe 'hooks/hooks.json — оголошення хука плагіна' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'має обгортку hooks.SessionStart; команда веде на ${CLAUDE_PLUGIN_ROOT}/hooks/session-start.ps1 і не ламає сесію без pwsh' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Root 'hooks/hooks.json') -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json   # не розбирається — тест падає тут
        $json.PSObject.Properties.Name | Should -Contain 'hooks'
        $entry = @($json.hooks.SessionStart)
        $entry.Count | Should -Be 1
        $entry[0].matcher | Should -Be 'startup|clear|compact'
        $entry[0].hooks[0].type | Should -Be 'command'
        $cmd = $entry[0].hooks[0].command
        $cmd | Should -BeLike '*${CLAUDE_PLUGIN_ROOT}/hooks/session-start.ps1*'
        # Форма вживання токена (правило 1 CLAUDE.md): за токеном одразу «/».
        $cmd | Should -Not -MatchExactly 'CLAUDE_PLUGIN_ROOT\}(?!/)'
        # Без pwsh у PATH — код 0 без виводу: перевірка наявності перед запуском і безумовний exit 0.
        $cmd | Should -BeLike 'command -v pwsh*'
        $cmd | Should -BeLike '*; exit 0'
        Join-Path $script:Root 'hooks/session-start.ps1' | Should -Exist
    }
}

Describe 'Test-KitLegacySessionHook — старий проєктний хук (до 1.6.0)' {
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
