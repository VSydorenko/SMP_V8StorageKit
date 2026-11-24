#Requires -Version 7
# Знімок дозволів і хуків (рішення 17 плану B3 і доповнення п. 9): для `.claude/settings.json` (розробка kit) і
# `templates/settings.json` (роздається споживачам) тест тримає очікуване вмісту ВСЬОГО об'єкта `permissions`
# (allow, ask, deny, defaultMode, additionalDirectories і будь-який інший ключ) та ключа `hooks` (його вмісту або
# відсутності). Вміст розгортається в рядки `шлях = значення` (елемент масиву — `шлях[] = значення`) і звіряється
# з файлом як множина дослівних рядків: будь-яке нове чи змінене правило — червоне, доки його не внесено сюди.
# Причина: три раунди аудиту поспіль знаходили форми, які пропускали і пошук шаблонів, і білий список за токеном
# (`pwsh -File tools/kit.ps1 …:*`, `kit:*`, лапки, `Bash(bin/* check *)`, регістр). Ціна — кожна зміна дозволів
# правиться у двох місцях; зміну погоджує власник.
Describe 'знімок permissions і hooks — .claude/settings.json і templates/settings.json' -Tag 'Docs' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Expected = @{
            '.claude/settings.json' = @(
            'permissions.allow[] = Bash(git status:*)'
            'permissions.allow[] = Bash(git log:*)'
            'permissions.allow[] = Bash(git diff:*)'
            'permissions.allow[] = Bash(git show:*)'
            'permissions.allow[] = Bash(git branch --list:*)'
            'permissions.allow[] = Bash(git branch --show-current)'
            'permissions.allow[] = Bash(git ls-files:*)'
            'permissions.allow[] = Bash(git ls-remote:*)'
            'permissions.allow[] = Bash(git rev-parse:*)'
            'permissions.allow[] = Bash(git rev-list:*)'
            'permissions.allow[] = Bash(git check-ignore:*)'
            'permissions.allow[] = Bash(git bundle verify:*)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only:*)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Serial:*)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Workers:*)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/tests/Run-Tests.ps1 -ExcludeTag Integration -FullLog:*)'
            'permissions.allow[] = Bash(pwsh -NoProfile -File tools/check-environment.ps1)'
            'permissions.allow[] = Bash(bin/kit.exe check)'
            'permissions.allow[] = Bash(sdd:*)'
            'permissions.allow[] = PowerShell(sdd:*)'
            'permissions.allow[] = Bash(review-pack:*)'
            'permissions.allow[] = PowerShell(review-pack:*)'
            'permissions.allow[] = Bash(doc:*)'
            'permissions.allow[] = PowerShell(doc:*)'
            'permissions.allow[] = Bash(session-board:*)'
            'permissions.allow[] = PowerShell(session-board:*)'
            'permissions.allow[] = Bash(session-cost:*)'
            'permissions.allow[] = PowerShell(session-cost:*)'
            'permissions.allow[] = Bash(kit-scan:*)'
            'permissions.allow[] = PowerShell(kit-scan:*)'
            'permissions.allow[] = Bash(track status:*)'
            'permissions.allow[] = PowerShell(track status:*)'
            'permissions.allow[] = Bash(pr-gate start:*)'
            'permissions.allow[] = PowerShell(pr-gate start:*)'
            'permissions.allow[] = Bash(pr-gate cleanup:*)'
            'permissions.allow[] = PowerShell(pr-gate cleanup:*)'
            'permissions.allow[] = Bash(pr-gate scratch:*)'
            'permissions.allow[] = PowerShell(pr-gate scratch:*)'
            'permissions.ask[] = Bash(gh release:*)'
            'permissions.deny[] = Bash(gitsync:*)'
            'permissions.deny[] = Bash(oscript:*)'
            )
            'templates/settings.json' = @(
            'permissions.allow[] = Bash(git status:*)'
            'permissions.allow[] = Bash(git log:*)'
            'permissions.allow[] = Bash(git diff:*)'
            'permissions.allow[] = Bash(git show:*)'
            'permissions.allow[] = Bash(git branch --list:*)'
            'permissions.allow[] = Bash(git branch --show-current)'
            'permissions.allow[] = Bash(git ls-files:*)'
            'permissions.allow[] = Bash(git rev-list:*)'
            'permissions.allow[] = Bash(git check-ignore:*)'
            'permissions.allow[] = Bash(git bundle verify:*)'
            'permissions.allow[] = Bash(sdd:*)'
            'permissions.allow[] = PowerShell(sdd:*)'
            'permissions.allow[] = Bash(review-pack:*)'
            'permissions.allow[] = PowerShell(review-pack:*)'
            'permissions.allow[] = Bash(doc:*)'
            'permissions.allow[] = PowerShell(doc:*)'
            'permissions.allow[] = Bash(session-board:*)'
            'permissions.allow[] = PowerShell(session-board:*)'
            'permissions.allow[] = Bash(session-cost:*)'
            'permissions.allow[] = PowerShell(session-cost:*)'
            'permissions.allow[] = Bash(kit-scan:*)'
            'permissions.allow[] = PowerShell(kit-scan:*)'
            'permissions.allow[] = Bash(track status:*)'
            'permissions.allow[] = PowerShell(track status:*)'
            'permissions.allow[] = Bash(pr-gate start:*)'
            'permissions.allow[] = PowerShell(pr-gate start:*)'
            'permissions.allow[] = Bash(pr-gate cleanup:*)'
            'permissions.allow[] = PowerShell(pr-gate cleanup:*)'
            'permissions.allow[] = Bash(pr-gate scratch:*)'
            'permissions.allow[] = PowerShell(pr-gate scratch:*)'
            'permissions.allow[] = Bash(pr-gate open:*)'
            'permissions.allow[] = PowerShell(pr-gate open:*)'
            'permissions.allow[] = Bash(pr-gate ready:*)'
            'permissions.allow[] = PowerShell(pr-gate ready:*)'
            'permissions.allow[] = Bash(pr-gate land:*)'
            'permissions.allow[] = PowerShell(pr-gate land:*)'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_view'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_search'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_resolve'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_docs'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_check'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_diff'
            'permissions.allow[] = mcp__plugin_unica_unica__unica_run'
            'permissions.ask[] = Bash(git push:*)'
            'permissions.ask[] = PowerShell(git push:*)'
            'permissions.ask[] = Bash(gh pr create:*)'
            'permissions.ask[] = PowerShell(gh pr create:*)'
            'permissions.ask[] = Bash(gh pr merge:*)'
            'permissions.ask[] = PowerShell(gh pr merge:*)'
            'permissions.ask[] = Bash(gh release:*)'
            'permissions.ask[] = PowerShell(gh release:*)'
            'permissions.ask[] = mcp__plugin_unica_unica__unica_apply'
            'permissions.deny[] = Bash(gitsync:*)'
            'permissions.deny[] = Bash(oscript:*)'
            )
        }

        function script:Add-Flat([System.Collections.Generic.List[string]]$Out, [string]$Path, $Value) {
            if ($null -eq $Value) { $Out.Add("$Path = null"); return }
            if ($Value -is [System.Management.Automation.PSCustomObject]) {
                $props = @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)
                if (-not $props.Count) { $Out.Add("$Path = {}") }
                foreach ($p in $props) { Add-Flat $Out "$Path.$($p.Name)" $p.Value }
            } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
                $items = @($Value)
                if (-not $items.Count) { $Out.Add("$Path = []") }
                # Масив об'єктів/масивів — з індексом елемента: без нього множина губить пари «matcher ↔ command».
                $i = 0
                foreach ($e in $items) {
                    if ($e -is [System.Management.Automation.PSCustomObject] -or ($e -is [System.Collections.IEnumerable] -and $e -isnot [string])) { Add-Flat $Out "$Path[$i]" $e }
                    else { $Out.Add("$Path[] = $(if ($e -is [string]) { $e } else { ConvertTo-Json $e -Compress })") }
                    $i++
                }
            } elseif ($Value -is [string]) { $Out.Add("$Path = $Value") }
            else { $Out.Add("$Path = $(ConvertTo-Json $Value -Compress)") }
        }
        function script:Read-Snapshot([string]$Path) {
            $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $out = [System.Collections.Generic.List[string]]::new()
            if ($doc.PSObject.Properties.Name -contains 'permissions') { Add-Flat $out 'permissions' $doc.permissions } else { $out.Add('permissions = <немає>') }
            if ($doc.PSObject.Properties.Name -contains 'hooks') { Add-Flat $out 'hooks' $doc.hooks }
            $out.ToArray()
        }
        function script:Get-SnapshotDiff {
            <# Різниця множин дослівних рядків (ординально, з регістром). #>
            param([string[]]$Expected, [string[]]$Actual)
            $e = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Expected), [StringComparer]::Ordinal)
            $a = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Actual), [StringComparer]::Ordinal)
            [pscustomobject]@{
                Added   = @($Actual | Where-Object { -not $e.Contains($_) })
                Removed = @($Expected | Where-Object { -not $a.Contains($_) })
                Dups    = @($Actual).Count - $a.Count
            }
        }
        function script:Get-SnapshotFailure {
            param([string]$Name, $Diff)
            "змінено дозволи чи хуки в ${Name}: оновіть знімок у тому самому PR; зміну погоджує власник.`n" +
            "додано: $(@($Diff.Added) -join ' | ')`nприбрано: $(@($Diff.Removed) -join ' | ')"
        }
    }

    It 'permissions і hooks файла <Name> дорівнюють знімку (множина дослівних рядків)' -ForEach @(
        @{ Name = '.claude/settings.json' }
        @{ Name = 'templates/settings.json' }
    ) {
        $d = Get-SnapshotDiff -Expected $script:Expected[$Name] -Actual (Read-Snapshot (Join-Path $script:Root $Name))
        ($d.Added.Count + $d.Removed.Count + $d.Dups) | Should -Be 0 -Because (Get-SnapshotFailure $Name $d)
    }

    It 'у розробницькому файлі команда check — дослівний рядок без шаблонів' {
        $dev = Read-Snapshot (Join-Path $script:Root '.claude/settings.json')
        @($dev | Where-Object { $_ -ceq 'permissions.allow[] = Bash(bin/kit.exe check)' }).Count | Should -Be 1
    }

    # Контролі: кожна мутація копії файла мусить дати червоне (різниця непорожня) — інакше знімок нічого не ловить.
    It 'контроль: мутація копії файла — <Case> — відхиляється' -ForEach @(
        @{ Case = 'додано Bash(kit:*)'; Mutate = { param($doc) $doc.permissions.allow = @($doc.permissions.allow) + 'Bash(kit:*)' } }
        @{ Case = 'додано Bash(bin/* check *)'; Mutate = { param($doc) $doc.permissions.allow = @($doc.permissions.allow) + 'Bash(bin/* check *)' } }
        @{ Case = 'check замінено на check:*'; Mutate = { param($doc) $doc.permissions.allow = @($doc.permissions.allow | ForEach-Object { if ($_ -ceq 'Bash(bin/kit.exe check)') { 'Bash(bin/kit.exe check:*)' } else { $_ } }) } }
        @{ Case = 'правило check прибрано'; Mutate = { param($doc) $doc.permissions.allow = @($doc.permissions.allow | Where-Object { $_ -cne 'Bash(bin/kit.exe check)' }) } }
        @{ Case = 'додано defaultMode: bypassPermissions'; Mutate = { param($doc) $doc.permissions | Add-Member -NotePropertyName defaultMode -NotePropertyValue 'bypassPermissions' } }
        @{ Case = 'прибрано рядок deny'; Mutate = { param($doc) $doc.permissions.deny = @($doc.permissions.deny | Select-Object -Skip 1) } }
        @{ Case = 'додано hooks.PreToolUse'; Mutate = { param($doc) $doc | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{ PreToolUse = @([pscustomobject]@{ matcher = 'Bash'; hooks = @([pscustomobject]@{ type = 'command'; command = 'echo x' }) }) }) } }
    ) {
        $src = Join-Path $script:Root '.claude/settings.json'
        $copy = Join-Path $TestDrive 'settings-copy.json'
        $doc = Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json
        & $Mutate $doc
        ($doc | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $copy -Encoding UTF8
        $d = Get-SnapshotDiff -Expected $script:Expected['.claude/settings.json'] -Actual (Read-Snapshot $copy)
        ($d.Added.Count + $d.Removed.Count) | Should -BeGreaterThan 0 -Because 'знімок не помітив мутації'
    }

    # Пари «matcher ↔ command» не губляться: той самий набір matcher-ів і команд, але обмін командами — інший знімок.
    It 'контроль: обмін командами між двома matcher-ами хуків — червоне' {
        function script:New-HooksDoc([string]$CmdA, [string]$CmdB) {
            $mk = { param($m, $c) [pscustomobject]@{ matcher = $m; hooks = @([pscustomobject]@{ type = 'command'; command = $c }) } }
            [pscustomobject]@{ hooks = [pscustomobject]@{ PreToolUse = @((& $mk 'Bash' $CmdA), (& $mk 'Edit' $CmdB)) } }
        }
        $one = Join-Path $TestDrive 'hooks-one.json'
        $two = Join-Path $TestDrive 'hooks-two.json'
        (New-HooksDoc 'cmd-1' 'cmd-2' | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $one -Encoding UTF8
        (New-HooksDoc 'cmd-2' 'cmd-1' | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $two -Encoding UTF8
        $d = Get-SnapshotDiff -Expected (Read-Snapshot $one) -Actual (Read-Snapshot $two)
        ($d.Added.Count + $d.Removed.Count) | Should -BeGreaterThan 0 -Because 'обмін команд між matcher-ами не помічено'
    }
}
