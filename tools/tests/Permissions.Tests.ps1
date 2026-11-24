#Requires -Version 7
# Знімок дозволів (рішення 17 плану B3): повний масив `allow` обох settings.json — `.claude/settings.json`
# (розробка kit) і `templates/settings.json` (роздається споживачам). Тест тримає очікуваний масив кожного з двох
# файлів і звіряє його з файлом як множину дослівних рядків: будь-яке нове чи змінене правило — червоне, доки його
# не внесено сюди. Причина: три раунди аудиту поспіль знаходили форми, які пропускали і пошук шаблонів, і білий
# список за токеном (`pwsh -File tools/kit.ps1 …:*`, `kit:*`, лапки, `Bash(bin/* check *)`, `k''it`, `KIT.EXE`).
# Ціна — кожна зміна дозволів правиться у двох місцях; зміну дозволів погоджує власник.
Describe 'знімок дозволів allow — .claude/settings.json і templates/settings.json' -Tag 'Docs' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Expected = @{
            '.claude/settings.json' = @(
        'Bash(git status:*)'
        'Bash(git log:*)'
        'Bash(git diff:*)'
        'Bash(git show:*)'
        'Bash(git branch --list:*)'
        'Bash(git branch --show-current)'
        'Bash(git ls-files:*)'
        'Bash(git ls-remote:*)'
        'Bash(git rev-parse:*)'
        'Bash(git rev-list:*)'
        'Bash(git check-ignore:*)'
        'Bash(git bundle verify:*)'
        'Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration)'
        'Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only:*)'
        'Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Serial:*)'
        'Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Workers:*)'
        'Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -FullLog:*)'
        'Bash(pwsh -NoProfile -File tools/check-environment.ps1)'
        'Bash(bin/kit.exe check)'
        'Bash(sdd:*)'
        'PowerShell(sdd:*)'
        'Bash(review-pack:*)'
        'PowerShell(review-pack:*)'
        'Bash(doc:*)'
        'PowerShell(doc:*)'
        'Bash(session-board:*)'
        'PowerShell(session-board:*)'
        'Bash(session-cost:*)'
        'PowerShell(session-cost:*)'
        'Bash(kit-scan:*)'
        'PowerShell(kit-scan:*)'
        'Bash(track status:*)'
        'PowerShell(track status:*)'
        'Bash(pr-gate start:*)'
        'PowerShell(pr-gate start:*)'
        'Bash(pr-gate cleanup:*)'
        'PowerShell(pr-gate cleanup:*)'
        'Bash(pr-gate scratch:*)'
        'PowerShell(pr-gate scratch:*)'
            )
            'templates/settings.json' = @(
        'Bash(git status:*)'
        'Bash(git log:*)'
        'Bash(git diff:*)'
        'Bash(git show:*)'
        'Bash(git branch --list:*)'
        'Bash(git branch --show-current)'
        'Bash(git ls-files:*)'
        'Bash(git rev-list:*)'
        'Bash(git check-ignore:*)'
        'Bash(git bundle verify:*)'
        'Bash(sdd:*)'
        'PowerShell(sdd:*)'
        'Bash(review-pack:*)'
        'PowerShell(review-pack:*)'
        'Bash(doc:*)'
        'PowerShell(doc:*)'
        'Bash(session-board:*)'
        'PowerShell(session-board:*)'
        'Bash(session-cost:*)'
        'PowerShell(session-cost:*)'
        'Bash(kit-scan:*)'
        'PowerShell(kit-scan:*)'
        'Bash(track status:*)'
        'PowerShell(track status:*)'
        'Bash(pr-gate start:*)'
        'PowerShell(pr-gate start:*)'
        'Bash(pr-gate cleanup:*)'
        'PowerShell(pr-gate cleanup:*)'
        'Bash(pr-gate scratch:*)'
        'PowerShell(pr-gate scratch:*)'
        'Bash(pr-gate open:*)'
        'PowerShell(pr-gate open:*)'
        'Bash(pr-gate ready:*)'
        'PowerShell(pr-gate ready:*)'
        'Bash(pr-gate land:*)'
        'PowerShell(pr-gate land:*)'
        'mcp__plugin_unica_unica__unica_view'
        'mcp__plugin_unica_unica__unica_search'
        'mcp__plugin_unica_unica__unica_resolve'
        'mcp__plugin_unica_unica__unica_docs'
        'mcp__plugin_unica_unica__unica_check'
        'mcp__plugin_unica_unica__unica_diff'
        'mcp__plugin_unica_unica__unica_run'
            )
        }

        function script:Get-AllowDiff {
            <# Різниця множин дослівних рядків (порівняння ординальне, з регістром): додані й прибрані. #>
            param([string[]]$Expected, [string[]]$Actual)
            $e = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Expected), [StringComparer]::Ordinal)
            $a = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Actual), [StringComparer]::Ordinal)
            [pscustomobject]@{
                Added   = @($Actual | Where-Object { -not $e.Contains($_) })
                Removed = @($Expected | Where-Object { -not $a.Contains($_) })
                Dups    = @($Actual).Count - $a.Count
            }
        }
        function script:Get-AllowFailure {
            param([string]$Name, $Diff)
            "змінено дозволи в ${Name}: оновіть знімок у тому самому PR; зміну дозволів погоджує власник.`n" +
            "додано: $(@($Diff.Added) -join ' | ')`nприбрано: $(@($Diff.Removed) -join ' | ')"
        }
        function script:Read-Allow([string]$Path) {
            @((Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).permissions.allow)
        }
    }

    It 'масив allow файла <Name> дорівнює знімку (множина дослівних рядків)' -ForEach @(
        @{ Name = '.claude/settings.json' }
        @{ Name = 'templates/settings.json' }
    ) {
        $actual = Read-Allow (Join-Path $script:Root $Name)
        $d = Get-AllowDiff -Expected $script:Expected[$Name] -Actual $actual
        ($d.Added.Count + $d.Removed.Count + $d.Dups) | Should -Be 0 -Because (Get-AllowFailure $Name $d)
    }

    It 'у розробницькому файлі команда check — дослівний рядок без шаблонів' {
        $dev = Read-Allow (Join-Path $script:Root '.claude/settings.json')
        @($dev | Where-Object { $_ -ceq 'Bash(bin/kit.exe check)' }).Count | Should -Be 1
    }

    # Контролі: кожна мутація копії файла мусить дати червоне (різниця непорожня) — інакше знімок нічого не ловить.
    It 'контроль: мутація копії файла — <Case> — відхиляється' -ForEach @(
        @{ Case = 'додано Bash(kit:*)'; Mutate = { param($a) @($a) + 'Bash(kit:*)' } }
        @{ Case = 'додано Bash(bin/* check *)'; Mutate = { param($a) @($a) + 'Bash(bin/* check *)' } }
        @{ Case = 'check замінено на check:*'; Mutate = { param($a) @($a | ForEach-Object { if ($_ -ceq 'Bash(bin/kit.exe check)') { 'Bash(bin/kit.exe check:*)' } else { $_ } }) } }
        @{ Case = 'правило check прибрано'; Mutate = { param($a) @($a | Where-Object { $_ -cne 'Bash(bin/kit.exe check)' }) } }
    ) {
        $src = Join-Path $script:Root '.claude/settings.json'
        $copy = Join-Path $TestDrive 'settings-copy.json'
        $doc = Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.permissions.allow = @(& $Mutate @($doc.permissions.allow))
        ($doc | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $copy -Encoding UTF8
        $d = Get-AllowDiff -Expected $script:Expected['.claude/settings.json'] -Actual (Read-Allow $copy)
        ($d.Added.Count + $d.Removed.Count) | Should -BeGreaterThan 0 -Because 'знімок не помітив мутації'
    }
}
