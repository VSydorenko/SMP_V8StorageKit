#Requires -Version 7
# kit-setup: ідемпотентність, звіт про settings.json (лише читання; рішення власника 2026-11-23: права не
# автоматизуються), -DryRun без запису (оригінал — agent-kit 0.9.1 tests/kit-setup.test.mjs). Справжній
# kit.ps1 підпроцесом на синтетичному git-репо в TestDrive: — за зразком SessionBoard.Tests.ps1.
Describe 'kit-setup — підключення проєкту' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitProcess = Join-Path (Split-Path $script:Kit -Parent) 'kit.ps1'
        $script:Files = @('.gitignore', '.agents/kit.profile.json', '.worktreeinclude')
        $script:NoFiles = @('-NoGitignore', '-NoProfile', '-NoWorktreeInclude')

        function script:New-Repo {
            param([string]$Name)
            $repo = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $repo | Out-Null
            & git -C $repo init -q -b main 2>&1 | Out-Null
            $repo
        }
        function script:Invoke-Setup {
            param([string]$Repo, [string[]]$Arguments = @())
            Push-Location $Repo
            try { $out = & pwsh -NoProfile -File $script:KitProcess kit-setup @Arguments 2>&1 | Out-String; $code = $LASTEXITCODE }
            finally { Pop-Location }
            [pscustomobject]@{ Code = $code; Out = $out }
        }
        function script:Get-Hashes {
            param([string]$Repo)
            $script:Files | ForEach-Object {
                $p = Join-Path $Repo $_
                if (Test-Path -LiteralPath $p) { "$_=$((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash)" } else { "$_=<немає>" }
            }
        }
        function script:Write-Settings {
            param([string]$Repo, $Data)
            New-Item -ItemType Directory -Path (Join-Path $Repo '.claude') -Force | Out-Null
            $f = Join-Path $Repo '.claude/settings.json'
            [System.IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $Data -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
            $f
        }
        function script:Get-Sha { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
        function script:Get-ReportLine {
            <# Рядки звіту, що містять підрядок. #>
            param([string]$Out, [string]$Part)
            @($Out -split '\r?\n' | Where-Object { $_.Contains($Part) })
        }
    }

    It 'повторний запуск нічого не змінює: байти файлів однакові; settings.json не з''являється' {
        $repo = New-Repo 'idem'
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'node_modules' -Encoding utf8NoBOM
        $r1 = Invoke-Setup $repo
        $r1.Code | Should -Be 0 -Because $r1.Out
        $first = Get-Hashes $repo
        $first | Should -Not -Contain '.agents/kit.profile.json=<немає>'
        $r2 = Invoke-Setup $repo
        $r2.Code | Should -Be 0 -Because $r2.Out
        (Get-Hashes $repo) | Should -Be $first -Because $r2.Out
        $r2.Out | Should -Match '(?m)^next: kit-scan\r?$' -Because $r2.Out
        # Контроль, що вміє впасти: «kit-setup пише settings.json» створило б файл (і на звичайному запуску, і на -DryRun).
        Test-Path -LiteralPath (Join-Path $repo '.claude/settings.json') | Should -BeFalse -Because $r1.Out
        $r3 = Invoke-Setup (New-Repo 'idem-dry') -Arguments @('-DryRun')
        Test-Path -LiteralPath (Join-Path $TestDrive 'idem-dry/.claude/settings.json') | Should -BeFalse -Because $r3.Out
        $r1.Out | Should -Match 'файла немає' -Because 'звіт називає відсутній файл'
    }

    It 'settings.json байт-у-байт той самий після kit-setup (і з -DryRun, і без); широкі правила й чуже — лише в звіті' {
        $repo = New-Repo 'keep'
        $settings = Write-Settings $repo ([ordered]@{
                attribution = @{ commit = '' }
                permissions = [ordered]@{ deny = @('Bash(rm:*)'); allow = @('Bash(git status*)', 'Bash(pr-gate:*)', 'Bash(git branch:*)', 'PowerShell(git branch:*)') }
                env         = @{ A = '1' }
            })
        $hash = Get-Sha $settings
        foreach ($mode in @(@('-DryRun'), @())) {
            $r = Invoke-Setup $repo -Arguments (@($mode) + $script:NoFiles)
            $r.Code | Should -Be 0 -Because $r.Out
            Get-Sha $settings | Should -Be $hash -Because "kit-setup $($mode -join ' ') не пише settings.json"
            # Широкі правила названо рядками-попередженнями (§5.3, D14).
            $r.Out | Should -Match 'Bash\(pr-gate:\*\) ширше за потрібне — дозволяє й майбутні підкоманди pr-gate без рішення; заміни на [^\r\n]*Bash\(pr-gate open:\*\), Bash\(pr-gate ready:\*\), Bash\(pr-gate land:\*\)'
            $r.Out | Should -Match 'Bash\(git branch:\*\) ширше за потрібне — пропускає й git branch -D/-f[^\r\n]*заміни на Bash\(git branch --list:\*\), Bash\(git branch --show-current\)'
            # PowerShell-форма: вузької заміни шаблон не має — порада не обіцяє PowerShell(git branch --list:*).
            $r.Out | Should -Match 'PowerShell\(git branch:\*\) ширше за потрібне — [^\r\n]*Вузької PowerShell-форми шаблон не має'
            $r.Out | Should -Not -Match 'PowerShell\(git branch --list'
            $r.Out | Should -Match 'kit цього файла не змінює'
        }
        Test-Path -LiteralPath (Join-Path $repo '.gitignore') | Should -BeFalse
    }

    Context 'звіт про settings.json (тест (3), фікстура плану §6; репозиторій без ознак 1С)' {
        BeforeAll {
            $script:Obsolete = @{
                Allow = 'mcp__plugin_unica_unica__unica_project_map'
                Ask   = 'mcp__plugin_unica_unica__unica_code_search'
                Deny  = 'mcp__plugin_unica_unica__unica_source_read'
            }
            # Шість форм шима kit (уся команда — дослівно шим): перша — у групі з власним хуком, решта — окрема група.
            $script:ShimCmd = 'pwsh -NoProfile -File .claude\hooks\session-start.ps1'
            $script:ShimForms = @(
                'pwsh -NoProfile -File .claude/hooks/session-start.ps1',
                'pwsh -NoProfile -File ./.claude/hooks/session-start.ps1',
                'pwsh -NoProfile -File "$CLAUDE_PROJECT_DIR"/.claude/hooks/session-start.ps1',
                'pwsh -NoProfile -File "${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.ps1"',
                "pwsh -NoProfile -File '.claude/hooks/session-start.ps1'")
            $script:OwnHook = @{ type = 'command'; command = 'pwsh -NoProfile -File tools/own-start.ps1' }
            # Команди зі шляхом шима, що не є шимом kit (інша програма, інші прапорці, хук рівня користувача,
            # складена, .custom) — у звіті про шим їх немає.
            $script:OtherCommands = @('echo own-group',
                "python '`$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.ps1'",
                'Write-Output .claude/hooks/session-start.ps1',
                'pwsh -File .claude/hooks/session-start.ps1',
                'pwsh -NoProfile -File .claude/hooks/session-start.ps1.custom',
                'pwsh -NoProfile -File ~/.claude/hooks/session-start.ps1',
                'pwsh -NoProfile -File .claude/hooks/session-start.ps1 && pwsh -File tools/own.ps1')
            # ask (D13, перетин за першим токеном): Bash(pr-gate land:*) закриває всі правила pr-gate обох форм;
            # PowerShell(git push:*) — всі читальні git; Bash(session-cost *) — session-cost.
            $script:InputPerms = [ordered]@{
                allow = @($script:Obsolete.Allow, 'mcp__plugin_unica_unica__unica_view', 'Bash(make test:*)',
                    'mcp__plugin_unica_unica__unica_apply', 'Bash(git push:*)')
                ask   = @($script:Obsolete.Ask, 'mcp__plugin_unica_unica__unica_run', 'Bash(pr-gate land:*)', 'PowerShell(git push:*)',
                    'Bash(session-cost *)')
                deny  = @($script:Obsolete.Deny, 'Bash(rm -rf:*)', 'Bash(gitsync:*)', 'Bash(oscript:*)')
            }
            $script:MergeRepo = New-Repo 'merge'
            $script:MergeSettings = Write-Settings $script:MergeRepo ([ordered]@{
                    permissions = $script:InputPerms
                    hooks       = [ordered]@{ SessionStart = @(
                            [ordered]@{ matcher = 'startup'; hooks = @([ordered]@{ type = 'command'; command = $script:ShimCmd }, $script:OwnHook) },
                            [ordered]@{ matcher = 'resume'; hooks = @($script:ShimForms | ForEach-Object { [ordered]@{ type = 'command'; command = $_ } }) },
                            [ordered]@{ hooks = @($script:OtherCommands | ForEach-Object { [ordered]@{ type = 'command'; command = $_ } }) }
                        ) }
                })
            $script:InputHash = Get-Sha $script:MergeSettings

            $script:NoPerm = Invoke-Setup $script:MergeRepo -Arguments @('-DryRun', '-NoPermissions')
            $script:Dry = Invoke-Setup $script:MergeRepo -Arguments (@('-DryRun') + $script:NoFiles)
            $script:DryHash = Get-Sha $script:MergeSettings
            $script:Real = Invoke-Setup $script:MergeRepo -Arguments $script:NoFiles
            $script:RealHash = Get-Sha $script:MergeSettings
            $script:Json = Invoke-Setup $script:MergeRepo -Arguments (@('-Json') + $script:NoFiles)
            $script:JsonNoPerm = Invoke-Setup $script:MergeRepo -Arguments @('-Json', '-NoPermissions')
            # Ще входи того самого тесту. Проби рецензента безпеки: кожна форма на pr-gate (маска, вужче, інша
            # форма, точне) закриває pr-gate open/ready/land; контроль — Bash(pr:*) (інший перший токен); ціле
            # ім'я інструмента в deny; git push в ask при git status, що вже є в allow.
            $script:PrGateProbes = [ordered]@{
                'p-glob'   = [ordered]@{ ask = @('Bash(pr-gate*)') }
                'p-open'   = [ordered]@{ ask = @('Bash(pr-gate open*)') }
                'p-mid'    = [ordered]@{ ask = @('Bash(pr-gate * land)') }
                'p-star'   = [ordered]@{ ask = @('Bash(* land)') }
                'p-exact'  = [ordered]@{ ask = @('Bash(pr-gate land)') }
                'p-admin'  = [ordered]@{ ask = @('Bash(pr-gate land --admin:*)') }
                'p-psdeny' = [ordered]@{ deny = @('PowerShell(pr-gate land:*)') }
                'p-broad'  = [ordered]@{ ask = @('Bash(pr-gate:*)') }
            }
            $cases = @(foreach ($k in $script:PrGateProbes.Keys) { @{ Name = $k; Perms = $script:PrGateProbes[$k] } }) + @(
                @{ Name = 'ctl-pr'; Perms = [ordered]@{ ask = @('Bash(pr:*)') } },
                @{ Name = 'merge-whole'; Perms = [ordered]@{ deny = @('PowerShell') } },
                @{ Name = 'merge-git'; Perms = [ordered]@{ allow = @('Bash(git status:*)'); ask = @('Bash(git push:*)') } })
            $script:Covered = foreach ($case in $cases) {
                $repo = New-Repo $case.Name
                $f = Write-Settings $repo ([ordered]@{ permissions = $case.Perms })
                $h = Get-Sha $f
                $r = Invoke-Setup $repo -Arguments $script:NoFiles
                [pscustomobject]@{ Name = $case.Name; Run = $r; Same = ((Get-Sha $f) -eq $h) }
            }
            $script:HeldPrefix = 'у проєкті є ask/deny на `pr-gate`'
        }

        It 'контроль: -DryRun і запис не міняють settings.json ні в одній з форм (байт-у-байт); -NoPermissions — без звіту' {
            $script:Dry.Code | Should -Be 0 -Because $script:Dry.Out
            $script:Real.Code | Should -Be 0 -Because $script:Real.Out
            $script:DryHash | Should -Be $script:InputHash -Because '-DryRun не пише'
            $script:RealHash | Should -Be $script:InputHash -Because 'kit-setup не пише settings.json ніколи'
            $script:Dry.Out | Should -Not -Match 'b/\.claude/settings\.json' -Because 'diff settings.json більше немає'
            $script:NoPerm.Code | Should -Be 0 -Because $script:NoPerm.Out
            $script:NoPerm.Out | Should -Not -Match 'settings\.json' -Because $script:NoPerm.Out
            $script:JsonNoPerm.Code | Should -Be 0 -Because $script:JsonNoPerm.Out
            ($script:JsonNoPerm.Out | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'permissions'
        }

        It 'звіт показує кожен клас: відсутні правила, застарілі імена, unica_apply, шим, перетин за токеном' {
            $out = $script:Dry.Out
            # відсутні правила шаблону — окремо allow і ask (deny проєкту має gitsync/oscript — для нього відсутнього немає)
            (Get-ReportLine $out 'немає в allow проєкту, є в шаблоні') | Should -Match 'Bash\(sdd:\*\)' -Because $out
            (Get-ReportLine $out 'немає в ask проєкту, є в шаблоні') | Should -Match 'Bash\(gh pr create:\*\)' -Because $out
            (Get-ReportLine $out 'немає в deny проєкту') | Should -BeNullOrEmpty -Because 'deny проєкту вже має обидва правила шаблону'
            # D9: без ознак 1С правил Уніки з allow шаблону у звіті немає
            $out | Should -Not -Match 'mcp__plugin_unica_unica__unica_search' -Because $out
            # застарілі: лише allow і ask, точний збіг; deny — ніколи; unica_view і власне правило — ні
            $o = Get-ReportLine $out 'застарілі імена Уніки в allow:'
            $o | Should -Match ([regex]::Escape($script:Obsolete.Allow))
            $o | Should -Not -Match 'unica_view|make test'
            Get-ReportLine $out 'застарілі імена Уніки в ask:' | Should -Match ([regex]::Escape($script:Obsolete.Ask))
            $out | Should -Not -Match ([regex]::Escape($script:Obsolete.Deny)) -Because 'deny проєкту не обговорюється'
            # unica_apply
            Get-ReportLine $out 'в allow, а шаблон тримає його в ask' | Should -Match 'unica_apply'
            # перетин за першим токеном: ask проєкту закриває pr-gate (обидві форми) і session-cost
            $pg = @(Get-ReportLine $out $script:HeldPrefix)
            $pg.Count | Should -Be 1 -Because $out
            foreach ($rule in 'Bash(pr-gate land:*)', 'PowerShell(pr-gate land:*)', 'Bash(pr-gate open:*)', 'PowerShell(pr-gate ready:*)') { $pg[0] | Should -Match ([regex]::Escape($rule)) }
            $pg[0] | Should -Match 'додавати лише свідомо'
            Get-ReportLine $out 'на `session-cost`' | Should -Match 'Bash\(session-cost:\*\)'
            # закриті токеном правила pr-gate — не в загальному рядку й не в окремому рядку pr-gate (ADR-0017)
            (Get-ReportLine $out 'немає в allow проєкту, є в шаблоні') | Should -Not -Match 'pr-gate' -Because $out
            Get-ReportLine $out 'відсутні в allow' | Should -BeNullOrEmpty -Because 'pr-gate закрито ask проєкту, окремого рядка немає'
        }

        It 'шим: усі шість форм названо дослівно; команди, що не є шимом kit, у звіті відсутні' {
            $line = @(Get-ReportLine $script:Dry.Out 'старий шим у hooks.SessionStart')
            $line.Count | Should -Be 1 -Because $script:Dry.Out
            $line[0] | Should -Match '\(6\)'
            foreach ($s in @($script:ShimCmd) + $script:ShimForms) { $line[0].Contains($s) | Should -BeTrue -Because $s }
            foreach ($o in $script:OtherCommands) { $script:Dry.Out.Contains($o) | Should -BeFalse -Because "не шим: $o" }
            $script:Dry.Out.Contains('tools/own-start.ps1') | Should -BeFalse
        }

        It '-Json: розділ permissions з тими самими класами; файл не змінено' {
            $script:Json.Code | Should -Be 0 -Because $script:Json.Out
            $j = $script:Json.Out | ConvertFrom-Json
            $j.permissions.clean | Should -BeFalse
            $j.permissions.applyInAllow | Should -BeTrue
            @($j.permissions.shim).Count | Should -Be 6
            $j.permissions.obsolete.allow | Should -Contain $script:Obsolete.Allow
            @($j.permissions.heldByAskDeny.'pr-gate').Count | Should -BeGreaterThan 0
            (Get-Sha $script:MergeSettings) | Should -Be $script:InputHash
        }

        It 'перетин за першим токеном: контроль Bash(pr:*) не закриває pr-gate (рядок про pr-gate open|ready|land); проби — закривають' {
            $ctl = $script:Covered | Where-Object Name -eq 'ctl-pr'
            $ctl.Run.Code | Should -Be 0 -Because $ctl.Run.Out
            $ctl.Run.Out | Should -Not -Match ([regex]::Escape($script:HeldPrefix)) -Because $ctl.Run.Out
            $pr = Get-ReportLine $ctl.Run.Out 'правила pr-gate open|ready|land (ADR-0017) відсутні в allow'
            foreach ($sub in 'open', 'ready', 'land') { foreach ($f in 'Bash', 'PowerShell') { $pr | Should -Match ([regex]::Escape("$f(pr-gate ${sub}:*)")) } }
            foreach ($k in $script:PrGateProbes.Keys) {
                $c = $script:Covered | Where-Object Name -eq $k
                $c.Run.Code | Should -Be 0 -Because "${k}: $($c.Run.Out)"
                $c.Same | Should -BeTrue -Because "${k}: файл не змінено"
                $c.Run.Out | Should -Match ([regex]::Escape($script:HeldPrefix)) -Because "${k}: $($c.Run.Out)"
                $c.Run.Out | Should -Not -Match 'відсутні в allow: ' -Because "${k}: правила pr-gate закриті токеном, окремого рядка немає"
            }
            # контроль: правило іншого токена не закрите — є в загальному рядку
            (Get-ReportLine ($script:Covered | Where-Object Name -eq 'p-broad').Run.Out 'немає в allow проєкту, є в шаблоні') | Should -Match 'Bash\(sdd:\*\)'
        }

        It 'ціле ім''я інструмента в deny закриває всі правила оболонки: жодного правила оболонки в рядку «немає в allow»' {
            $whole = $script:Covered | Where-Object Name -eq 'merge-whole'
            $whole.Run.Code | Should -Be 0 -Because $whole.Run.Out
            $whole.Same | Should -BeTrue
            @(Get-ReportLine $whole.Run.Out 'немає в allow проєкту, є в шаблоні' | Where-Object { $_ -match '(Bash|PowerShell)\(' }) | Should -BeNullOrEmpty -Because $whole.Run.Out
        }

        It 'закрите токеном — одним рядком на токен і лише те, чого в allow ще немає: git push в ask, git status уже в allow' {
            $g = $script:Covered | Where-Object Name -eq 'merge-git'
            $g.Run.Code | Should -Be 0 -Because $g.Run.Out
            $lines = @(Get-ReportLine $g.Run.Out 'у проєкті є ask/deny на `git`')
            $lines.Count | Should -Be 1 -Because $g.Run.Out
            $lines[0] | Should -Match ([regex]::Escape('Bash(git log:*)'))
            $lines[0] | Should -Match ([regex]::Escape('Bash(git branch --show-current)'))
            $lines[0] | Should -Not -Match ([regex]::Escape('git status')) -Because 'правило вже в allow проєкту'
        }
    }

    It 'порожній звіт, коли проєкт збігається з шаблоном (без 1С — без Уніки в allow): «відхилень від шаблону немає»' {
        $repo = New-Repo 'clean'
        $tpl = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../templates/settings.json') -Raw | ConvertFrom-Json -AsHashtable
        $allow = @($tpl.permissions.allow | Where-Object { -not $_.StartsWith('mcp__plugin_unica_unica__', [System.StringComparison]::Ordinal) })
        $f = Write-Settings $repo ([ordered]@{ permissions = [ordered]@{ allow = $allow; ask = $tpl.permissions.ask; deny = $tpl.permissions.deny } })
        $r = Invoke-Setup $repo -Arguments $script:NoFiles
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'відхилень від шаблону немає'
        # Контроль, що вміє впасти: прибрали одне правило — звіт перестає бути порожнім.
        $f2 = Write-Settings (New-Repo 'clean-minus') ([ordered]@{ permissions = [ordered]@{ allow = @($allow | Where-Object { $_ -cne 'Bash(sdd:*)' }); ask = $tpl.permissions.ask; deny = $tpl.permissions.deny } })
        $r2 = Invoke-Setup (Split-Path (Split-Path $f2 -Parent) -Parent) -Arguments $script:NoFiles
        $r2.Out | Should -Not -Match 'відхилень від шаблону немає' -Because $r2.Out
        $r2.Out | Should -Match 'немає в allow проєкту, є в шаблоні \(1\)'
    }

    It 'невалідний JSON на вході — код 3, «звіт не перевірено», settings.json байт-у-байт той самий, нічого не записано (тест (4))' {
        $repo = New-Repo 'broken'
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') | Out-Null
        $settings = Join-Path $repo '.claude/settings.json'
        [System.IO.File]::WriteAllText($settings, "{ `"permissions`": { `"allow`": [ `"Bash(make:*)`",`n", [System.Text.UTF8Encoding]::new($false))
        $hash = Get-Sha $settings
        $r = Invoke-Setup $repo
        $r.Code | Should -Be 3 -Because $r.Out
        $r.Out | Should -Match 'звіт дозволів не перевірено: не читається \.claude/settings\.json'
        Get-Sha $settings | Should -Be $hash
        Test-Path -LiteralPath (Join-Path $repo '.gitignore') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo '.agents/kit.profile.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo '.worktreeinclude') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $repo '.claude') -Force).Count | Should -Be 1 -Because 'тимчасових файлів не лишилось'
    }

    It '-DryRun нічого не пише й друкує diff' {
        $repo = New-Repo 'dry'
        $r = Invoke-Setup $repo -Arguments @('-DryRun')
        $r.Code | Should -Be 0 -Because $r.Out
        foreach ($f in $script:Files) { Test-Path -LiteralPath (Join-Path $repo $f) | Should -BeFalse -Because $f }
        $r.Out | Should -Match '(?m)^--- /dev/null\r?$'
        $r.Out | Should -Match '(?m)^\+\+\+ b/\.gitignore\r?$'
        $r.Out | Should -Match '(?m)^\+\.agents/out/\r?$'
    }
}
