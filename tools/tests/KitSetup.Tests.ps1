#Requires -Version 7
# kit-setup: ідемпотентність, збереження чужого в settings.json, -DryRun без запису
# (оригінал — agent-kit 0.9.1 tests/kit-setup.test.mjs). Справжній kit.ps1 підпроцесом на
# синтетичному git-репо в TestDrive: — за зразком SessionBoard.Tests.ps1.
Describe 'kit-setup — підключення проєкту' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitProcess = Join-Path (Split-Path $script:Kit -Parent) 'kit.ps1'
        $script:Files = @('.claude/settings.json', '.gitignore', '.agents/kit.profile.json', '.worktreeinclude')

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
    }

    It 'повторний запуск нічого не змінює: байти всіх чотирьох файлів однакові' {
        $repo = New-Repo 'idem'
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'node_modules' -Encoding utf8NoBOM
        $r1 = Invoke-Setup $repo
        $r1.Code | Should -Be 0 -Because $r1.Out
        $first = Get-Hashes $repo
        $first | Should -Not -Contain '.claude/settings.json=<немає>'
        $first | Should -Not -Contain '.agents/kit.profile.json=<немає>'
        $r2 = Invoke-Setup $repo
        $r2.Code | Should -Be 0 -Because $r2.Out
        (Get-Hashes $repo) | Should -Be $first -Because $r2.Out
        $r2.Out | Should -Match '(?m)^next: kit-scan\r?$' -Because $r2.Out
    }

    It 'чуже правило й наявні широкі pr-gate:*, git branch:* лишаються на місці; нове дописується в кінець, у двох формах' {
        $repo = New-Repo 'keep'
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') | Out-Null
        $settings = Join-Path $repo '.claude/settings.json'
        Set-Content -LiteralPath $settings -Encoding utf8NoBOM -Value ([ordered]@{
                attribution = @{ commit = '' }
                permissions = [ordered]@{ deny = @('Bash(rm:*)'); allow = @('Bash(git status*)', 'Bash(pr-gate:*)', 'Bash(git branch:*)', 'PowerShell(git branch:*)') }
                env         = @{ A = '1' }
            } | ConvertTo-Json -Depth 5)
        $r = Invoke-Setup $repo -Arguments @('-NoGitignore', '-NoProfile', '-NoWorktreeInclude')
        $r.Code | Should -Be 0 -Because $r.Out
        $s = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -AsHashtable
        @($s.Keys) | Should -Be @('attribution', 'permissions', 'env')
        @($s.permissions.Keys) | Should -Be @('deny', 'allow', 'ask')
        @($s.permissions.allow)[0..3] | Should -Be @('Bash(git status*)', 'Bash(pr-gate:*)', 'Bash(git branch:*)', 'PowerShell(git branch:*)')
        $s.permissions.allow | Should -Contain 'PowerShell(session-cost:*)'
        $s.permissions.allow | Should -Contain 'Bash(session-cost:*)'
        $s.permissions.allow | Should -Contain 'Bash(pr-gate open:*)'
        $s.permissions.deny[0] | Should -Be 'Bash(rm:*)'
        # Широкі правила названо рядками-попередженнями (§5.3, D14), а не прибрано.
        $r.Out | Should -Match 'Bash\(pr-gate:\*\) ширше за потрібне — дозволяє й майбутні підкоманди pr-gate без рішення; заміни на [^\r\n]*Bash\(pr-gate open:\*\), Bash\(pr-gate ready:\*\), Bash\(pr-gate land:\*\)'
        $r.Out | Should -Match 'Bash\(git branch:\*\) ширше за потрібне — пропускає й git branch -D/-f[^\r\n]*заміни на Bash\(git branch --list:\*\), Bash\(git branch --show-current\)'
        # PowerShell-форма: вузької заміни шаблон не має — порада не обіцяє PowerShell(git branch --list:*).
        $r.Out | Should -Match 'PowerShell\(git branch:\*\) ширше за потрібне — [^\r\n]*Вузької PowerShell-форми шаблон не має'
        $r.Out | Should -Not -Match 'PowerShell\(git branch --list'
        Test-Path -LiteralPath (Join-Path $repo '.gitignore') | Should -BeFalse
    }

    Context 'злиття settings.json з шаблоном (тест (3), фікстура плану §6; репозиторій без ознак 1С)' {
        BeforeAll {
            $script:Obsolete = @{
                Allow = 'mcp__plugin_unica_unica__unica_project_map'
                Ask   = 'mcp__plugin_unica_unica__unica_code_search'
                Deny  = 'mcp__plugin_unica_unica__unica_source_read'
            }
            $script:ShimCmd = 'pwsh -NoProfile -File .claude\hooks\session-start.ps1'
            $script:OwnHook = @{ type = 'command'; command = 'pwsh -NoProfile -File tools/own-start.ps1' }
            # Окрема група: власні хуки, .custom, хук рівня користувача й складена команда зі шимом — не шим kit.
            $script:OtherGroup = [ordered]@{ hooks = @(
                    [ordered]@{ type = 'command'; command = 'echo own-group' },
                    [ordered]@{ type = 'command'; command = 'pwsh -NoProfile -File .claude/hooks/session-start.ps1.custom' },
                    [ordered]@{ type = 'command'; command = 'pwsh -NoProfile -File ~/.claude/hooks/session-start.ps1' },
                    [ordered]@{ type = 'command'; command = 'pwsh -NoProfile -File .claude/hooks/session-start.ps1 && pwsh -File tools/own.ps1' }
                ) }
            # unica_view і власне правило — не останні в allow: інакше зміна коми дала б рядок «-» і без дефекту.
            # ask (D13 за рев'ю безпеки): Bash(pr-gate land:*) — форма-близнюк закриває й PowerShell-форму;
            # Bash(pr:*) — контроль межі слова (pr-gate open/ready лишаються в allow); Bash(session-cost *) —
            # суфікс « *» ≡ «:*».
            $script:InputPerms = [ordered]@{
                allow = @($script:Obsolete.Allow, 'mcp__plugin_unica_unica__unica_view', 'Bash(make test:*)',
                    'mcp__plugin_unica_unica__unica_apply', 'Bash(git push:*)')
                ask   = @($script:Obsolete.Ask, 'mcp__plugin_unica_unica__unica_run', 'Bash(pr-gate land:*)', 'PowerShell(git push:*)',
                    'Bash(pr:*)', 'Bash(session-cost *)')
                deny  = @($script:Obsolete.Deny, 'Bash(rm -rf:*)', 'Bash(gitsync:*)', 'Bash(oscript:*)')
            }
            $script:MergeRepo = New-Repo 'merge'
            New-Item -ItemType Directory -Path (Join-Path $script:MergeRepo '.claude') | Out-Null
            $script:MergeSettings = Join-Path $script:MergeRepo '.claude/settings.json'
            [System.IO.File]::WriteAllText($script:MergeSettings, ([ordered]@{
                        permissions = $script:InputPerms
                        hooks       = [ordered]@{ SessionStart = @(
                                [ordered]@{ matcher = 'startup'; hooks = @([ordered]@{ type = 'command'; command = $script:ShimCmd }, $script:OwnHook) },
                                $script:OtherGroup
                            ) }
                    } | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
            $script:InputHash = (Get-FileHash -LiteralPath $script:MergeSettings -Algorithm SHA256).Hash

            $script:NoPerm = Invoke-Setup $script:MergeRepo -Arguments @('-DryRun', '-NoPermissions')
            $script:Dry = Invoke-Setup $script:MergeRepo -Arguments @('-DryRun', '-NoGitignore', '-NoProfile', '-NoWorktreeInclude')
            $script:DryHash = (Get-FileHash -LiteralPath $script:MergeSettings -Algorithm SHA256).Hash
            $script:Real = Invoke-Setup $script:MergeRepo -Arguments @('-NoGitignore', '-NoProfile', '-NoWorktreeInclude')
            $script:After = Get-Content -LiteralPath $script:MergeSettings -Raw | ConvertFrom-Json -AsHashtable
            $script:Diff = @($script:Dry.Out -split '\r?\n')
            # Ще два входи того самого тесту: широке ask Bash(pr-gate:*) і ціле ім'я інструмента в deny.
            $script:Covered = foreach ($case in @(
                    @{ Name = 'merge-broad'; Perms = [ordered]@{ ask = @('Bash(pr-gate:*)') } },
                    @{ Name = 'merge-whole'; Perms = [ordered]@{ deny = @('PowerShell') } })) {
                $repo = New-Repo $case.Name
                New-Item -ItemType Directory -Path (Join-Path $repo '.claude') | Out-Null
                $f = Join-Path $repo '.claude/settings.json'
                [System.IO.File]::WriteAllText($f, ([ordered]@{ permissions = $case.Perms } | ConvertTo-Json -Depth 5) + "`n", [System.Text.UTF8Encoding]::new($false))
                $r = Invoke-Setup $repo -Arguments @('-NoGitignore', '-NoProfile', '-NoWorktreeInclude')
                [pscustomobject]@{ Name = $case.Name; Run = $r; Allow = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable).permissions.allow) }
            }
            function script:Get-Count {
                param($List, [string]$Rule)
                @(@($List) | Where-Object { $_ -ceq $Rule }).Count
            }
            function script:Test-DiffLine {
                <# Рядок diff «-»/«+» з правилом-рядком масиву (відступ і кома — будь-які). #>
                param([string]$Sign, [string]$Rule)
                [bool]@($script:Diff | Where-Object { $_ -cmatch ('^' + [regex]::Escape($Sign) + '\s+"' + [regex]::Escape($Rule) + '",?$') })
            }
        }

        It '-DryRun показує diff і нічого не пише; з -NoPermissions diff settings.json порожній' {
            $script:Dry.Code | Should -Be 0 -Because $script:Dry.Out
            $script:DryHash | Should -Be $script:InputHash -Because '-DryRun не пише'
            $script:Dry.Out | Should -Match '(?m)^\+\+\+ b/\.claude/settings\.json\r?$'
            $script:NoPerm.Code | Should -Be 0 -Because $script:NoPerm.Out
            $script:NoPerm.Out | Should -Not -Match 'b/\.claude/settings\.json' -Because $script:NoPerm.Out
        }

        It 'deny проєкту після злиття дорівнює вхідному поелементно — навіть застаріле ім''я в ньому' {
            $script:Real.Code | Should -Be 0 -Because $script:Real.Out
            @($script:After.permissions.deny) | Should -Be @($script:InputPerms.deny)
        }

        It 'застаріле прибрано з allow і ask; лише точний збіг — unica_view і власне правило без рядка «-»' {
            Test-DiffLine '-' $script:Obsolete.Allow | Should -BeTrue
            Test-DiffLine '-' $script:Obsolete.Ask | Should -BeTrue
            Get-Count $script:After.permissions.allow $script:Obsolete.Allow | Should -Be 0
            Get-Count $script:After.permissions.ask $script:Obsolete.Ask | Should -Be 0
            @($script:Diff | Where-Object { $_ -like '-*unica_view*' }) | Should -BeNullOrEmpty -Because ($script:Diff -join "`n")
            @($script:Diff | Where-Object { $_ -like '-*make test*' }) | Should -BeNullOrEmpty -Because ($script:Diff -join "`n")
            Get-Count $script:After.permissions.allow 'mcp__plugin_unica_unica__unica_view' | Should -Be 1
            Get-Count $script:After.permissions.allow 'Bash(make test:*)' | Should -Be 1
        }

        It 'ask лишається й покриває обидві форми: Bash(pr-gate land:*) в ask — жодної форми pr-gate land в allow' {
            Get-Count $script:After.permissions.ask 'mcp__plugin_unica_unica__unica_run' | Should -Be 1
            Get-Count $script:After.permissions.ask 'Bash(pr-gate land:*)' | Should -Be 1
            Get-Count $script:After.permissions.allow 'mcp__plugin_unica_unica__unica_run' | Should -Be 0
            foreach ($rule in 'Bash(pr-gate land:*)', 'PowerShell(pr-gate land:*)') {
                Get-Count $script:After.permissions.allow $rule | Should -Be 0 -Because "$rule — форма-близнюк правила ask проєкту"
                Test-DiffLine '+' $rule | Should -BeFalse -Because $rule
            }
        }

        It 'покриття — префікс на межі слова й « *» ≡ «:*»: Bash(pr:*) не закриває pr-gate open/ready, Bash(session-cost *) закриває session-cost' {
            foreach ($rule in 'Bash(pr-gate open:*)', 'PowerShell(pr-gate open:*)', 'Bash(pr-gate ready:*)', 'PowerShell(pr-gate ready:*)') {
                Get-Count $script:After.permissions.allow $rule | Should -Be 1 -Because "${rule}: pr:* не покриває pr-gate (межа слова)"
                Test-DiffLine '+' $rule | Should -BeTrue -Because $rule
            }
            foreach ($rule in 'Bash(session-cost:*)', 'PowerShell(session-cost:*)') {
                Get-Count $script:After.permissions.allow $rule | Should -Be 0 -Because "${rule}: Bash(session-cost *) в ask проєкту"
            }
            Get-Count $script:After.permissions.allow 'PowerShell(sdd:*)' | Should -Be 1 -Because 'контроль: непокрите правило шаблону додано'
        }

        It 'покриття ширшим правилом: ask Bash(pr-gate:*) — жодної форми pr-gate в allow; deny PowerShell — жодного правила оболонки' {
            foreach ($c in $script:Covered) { $c.Run.Code | Should -Be 0 -Because "$($c.Name): $($c.Run.Out)" }
            $broad = $script:Covered | Where-Object Name -eq 'merge-broad'
            @($broad.Allow | Where-Object { $_ -cmatch '^(Bash|PowerShell)\(pr-gate ' }) | Should -BeNullOrEmpty -Because ($broad.Allow -join ', ')
            $broad.Allow | Should -Contain 'Bash(sdd:*)' -Because 'контроль: решта правил шаблону додана'
            $whole = $script:Covered | Where-Object Name -eq 'merge-whole'
            @($whole.Allow | Where-Object { $_ -cmatch '^(Bash|PowerShell)\b' }) | Should -BeNullOrEmpty -Because ($whole.Allow -join ', ')
        }

        It 'unica_apply лише в ask; без ознак 1С правил Уніки з allow шаблону немає' {
            Get-Count $script:After.permissions.allow 'mcp__plugin_unica_unica__unica_apply' | Should -Be 0
            Get-Count $script:After.permissions.ask 'mcp__plugin_unica_unica__unica_apply' | Should -Be 1
            # Без ознак 1С правила Уніки з allow шаблону не додаються (D9).
            Get-Count $script:After.permissions.allow 'mcp__plugin_unica_unica__unica_search' | Should -Be 0
        }

        It 'наявність перевіряється в тому самому списку: Bash(git push:*) і в allow, і в ask; PowerShell(git push:*) в ask один' {
            Get-Count $script:After.permissions.allow 'Bash(git push:*)' | Should -Be 1
            Get-Count $script:After.permissions.ask 'Bash(git push:*)' | Should -Be 1
            Get-Count $script:After.permissions.ask 'PowerShell(git push:*)' | Should -Be 1
            Get-Count $script:After.permissions.ask 'Bash(gh pr merge:*)' | Should -Be 1
        }

        It 'шим прибрано елементом: власний хук у його групі, окрема група й .custom — на місці' {
            @($script:Diff | Where-Object { $_ -like '-*session-start.ps1"*' }).Count | Should -Be 1 -Because ($script:Diff -join "`n")
            $groups = @($script:After.hooks.SessionStart)
            $groups.Count | Should -Be 2
            $groups[0].matcher | Should -Be 'startup'
            @($groups[0].hooks).Count | Should -Be 1
            $groups[0].hooks[0].command | Should -BeExactly $script:OwnHook.command
            @($groups[1].hooks | ForEach-Object { $_.command }) | Should -Be @($script:OtherGroup.hooks | ForEach-Object { $_.command })
        }
    }

    It 'невалідний JSON на вході — код 3, settings.json байт-у-байт той самий, .gitignore і профіль не створено (тест (4))' {
        $repo = New-Repo 'broken'
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') | Out-Null
        $settings = Join-Path $repo '.claude/settings.json'
        [System.IO.File]::WriteAllText($settings, "{ `"permissions`": { `"allow`": [ `"Bash(make:*)`",`n", [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
        $r = Invoke-Setup $repo
        $r.Code | Should -Be 3 -Because $r.Out
        $r.Out | Should -Match 'не читається \.claude/settings\.json'
        (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash | Should -Be $hash
        Test-Path -LiteralPath (Join-Path $repo '.gitignore') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo '.agents/kit.profile.json') | Should -BeFalse
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
