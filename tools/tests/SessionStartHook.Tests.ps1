#Requires -Version 7
Describe 'templates/hooks/session-start.ps1 — шим хука SessionStart (§7)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:KitRoot = Split-Path -Parent (Split-Path -Parent (Copy-KitTools -Root (Join-Path $TestDrive 'kit')))   # <TestDrive>/kit
        $script:Shim = Join-Path $script:KitRoot 'templates/hooks/session-start.ps1'

        # Реєстр плагінів: у тесті — власний файл, шлях передається змінною середовища.
        $script:Registry = Join-Path $TestDrive 'installed_plugins.json'
        @{ plugins = @{ 'v8storagekit@smp-v8storagekit' = @(@{ version = 'test'; installPath = $script:KitRoot }) } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Registry -Encoding UTF8
        $script:EmptyRegistry = Join-Path $TestDrive 'no-kit.json'
        @{ plugins = @{ 'unica@unica' = @(@{ version = '0.12.3'; installPath = 'C:\nope' }) } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:EmptyRegistry -Encoding UTF8

        function script:Invoke-Shim {
            param([string]$Cwd, [string]$Registry)
            $env:V8KIT_PLUGINS_REGISTRY = $Registry
            try {
                Push-Location $Cwd
                try { $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String } finally { Pop-Location }
            } finally { Remove-Item Env:V8KIT_PLUGINS_REGISTRY -ErrorAction SilentlyContinue }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'у репозиторії з маніфестом друкує валідний JSON: hookEventName = SessionStart, вступ і стан сховищ; дерево не змінене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo') -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Shim -Cwd $repo -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*using-v8storagekit*'
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*session-check*- Alpha_SMB:*'
        $json.hookSpecificOutput.additionalContext | Should -Not -BeLike '*<корінь плагіна>*'
        $json.hookSpecificOutput.additionalContext | Should -BeLike "*$script:KitRoot*"   # без -replace: у -BeLike екран — бектик, не бекслеш (P8)
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }

    It 'плагіна в реєстрі немає — нічого не друкує, код 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-plugin') -WithHooks
        $r = Invoke-Shim -Cwd $repo -Registry $script:EmptyRegistry
        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
    }

    It 'kit session-check упав (код 1) — шим не мовчить: позначка «стан невідомий» і текст зупинки, код шима 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken') -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Value 'version: 1' -Encoding UTF8   # маніфест без workspaces → префлайт кидає
        $r = Invoke-Shim -Cwd $repo -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*НЕВІДОМИЙ*workspaces*'
    }

    It 'без маніфесту в cwd — лише вступ і підказка onboarding' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        git -C $dir init -q
        $r = Invoke-Shim -Cwd $dir -Registry $script:Registry
        $r.ExitCode | Should -Be 0
        $json = $r.Output | ConvertFrom-Json
        $json.hookSpecificOutput.additionalContext | Should -BeLike '*onboarding*'
        $json.hookSpecificOutput.additionalContext | Should -Not -BeLike '*- Alpha_SMB:*'
    }

    Context 'стеля часу' {
        BeforeAll {
            # Окремий фейковий плагін: kit.ps1 підміняється в кожному It, скіл потрібен шиму для вступу.
            $script:FakePlugin = Join-Path $TestDrive 'fake-plugin'
            New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'tools') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:FakePlugin 'skills/using-v8storagekit') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'skills/using-v8storagekit/SKILL.md') -Encoding UTF8 -Value '# вступ'
            $script:FakeRegistry = Join-Path $TestDrive 'fake-registry.json'
            @{ plugins = @{ 'v8storagekit@smp-v8storagekit' = @(@{ version = 'test'; installPath = $script:FakePlugin }) } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:FakeRegistry -Encoding UTF8
            # Репо з маніфестом: без нього шим іде гілкою «немає v8storagekit.yaml» і session-check не кличе.
            $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
            New-Item -ItemType Directory -Path $script:FakeRepo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:FakeRepo 'v8storagekit.yaml') -Encoding UTF8 -Value 'version: 1'
            $script:PrevRegistry = $env:V8KIT_PLUGINS_REGISTRY
            $env:V8KIT_PLUGINS_REGISTRY = $script:FakeRegistry
            Push-Location $script:FakeRepo
        }
        AfterAll {
            Pop-Location
            if ($null -eq $script:PrevRegistry) { Remove-Item Env:\V8KIT_PLUGINS_REGISTRY -ErrorAction SilentlyContinue }
            else { $env:V8KIT_PLUGINS_REGISTRY = $script:PrevRegistry }
        }

        It 'шим не чекає довше за стелю: повільний session-check дає рядок «не вклався», а не зависання' {
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'Start-Sleep -Seconds 30'
            $env:V8KIT_SESSION_CHECK_TIMEOUT = '1'
            try {
                $sw  = [System.Diagnostics.Stopwatch]::StartNew()
                $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String
                $sw.Stop()
            } finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 20        # стеля 1 с + запас на старт pwsh
            $out | Should -BeLike '*не вклався*'
            ($out | ConvertFrom-Json).hookSpecificOutput.hookEventName | Should -Be 'SessionStart'   # JSON лишився валідним
        }

        It 'те, що kit устиг надрукувати до стелі, потрапляє у вивід із позначкою «частково»' {
            # Заглушка друкує знахідку check і зависає — як повільне джерело після вже виданих рядків check.
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 `
                -Value "'[!] хуків немає: kit install-hooks'", 'Start-Sleep -Seconds 30'
            $env:V8KIT_SESSION_CHECK_TIMEOUT = '2'   # 2 с: заглушка встигає надрукувати рядок і скинути буфер у файл
            try { $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String }
            finally { Remove-Item Env:\V8KIT_SESSION_CHECK_TIMEOUT -ErrorAction SilentlyContinue }
            $out | Should -BeLike '*Частково*'
            $out | Should -BeLike '*install-hooks*'
            $out | Should -BeLike '*повнота НЕ гарантована*'
        }

        It 'шим ніколи не передає -Apply' {
            # Заглушка друкує власні аргументи — шим мусить дати рівно session-check -RepoRoot <шлях>.
            Set-Content -LiteralPath (Join-Path $script:FakePlugin 'tools/kit.ps1') -Encoding UTF8 -Value 'param([Parameter(ValueFromRemainingArguments)]$Rest) $Rest -join " "'
            $out = & pwsh -NoProfile -File $script:Shim 2>&1 | Out-String
            $out | Should -Not -BeLike '*-Apply*'
            $out | Should -BeLike '*session-check*-RepoRoot*'
        }
    }
}

Describe 'Hooks.psm1 — встановлення й аудит шима' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates").Path
    }
    It 'Install-KitSessionHook кладе шим і settings.json; Test-KitSessionHook мовчить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'install')
        Install-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Join-Path $repo '.claude/hooks/session-start.ps1' | Should -Exist
        Join-Path $repo '.claude/settings.json' | Should -Exist
        @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates).Count | Should -Be 0
    }
    It 'без шима — info; змінений шим — warn із назвою файлу; settings.json без хука — warn' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit')
        $f = @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates)
        @($f | Where-Object { $_.Level -eq 'info' -and $_.Message -like '*session-start.ps1*' }).Count | Should -Be 1

        Install-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Add-Content -LiteralPath (Join-Path $repo '.claude/hooks/session-start.ps1') -Value '# локальна правка'
        Set-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Value '{ "permissions": { "allow": [] } }' -Encoding UTF8
        $f = @(Test-KitSessionHook -RepoRoot $repo -TemplatesDir $script:Templates)
        @($f | Where-Object { $_.Level -eq 'warn' -and $_.Message -like '*session-start.ps1*шаблон*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Level -eq 'warn' -and $_.Message -like '*settings.json*SessionStart*' }).Count | Should -Be 1
    }
}
