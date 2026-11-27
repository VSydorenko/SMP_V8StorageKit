#Requires -Version 7
Describe 'templates/gitattributes — політика тексту' -Tag 'Docs' {
    # Тест читає справжній роздаваний артефакт, а не його переказ: саме цей файл
    # потрапляє в репозиторій-споживача, і саме в ньому жив дефект (конверсія
    # кінців рядків усередині текстових значень XML). Обґрунтування — docs/text-policy.md.
    BeforeAll {
        $script:Lines = @(Get-Content -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../templates/gitattributes").Path -Encoding UTF8)
    }

    It 'виводить дерева, які пише платформа, з-під конверсії git' {
        @($script:Lines | Where-Object { $_ -match '^\*\*/cfe/src/\*\*\s+-text\s*$' }).Count |
            Should -Be 1
        @($script:Lines | Where-Object { $_ -match '^\*\*/epf/src/\*\*\s+-text\s*$' }).Count |
            Should -Be 1
    }

    It 'не має жодного правила eol= на розширеннях, які пише платформа' {
        # Регресія: будь-яке eol= на .xml/.bsl/.html/.txt конвертує файл ЦІЛКОМ і
        # мовчки міняє текст усередині багаторядкових значень v8:content.
        $offenders = @($script:Lines |
            Where-Object { $_ -match '^\s*\*\.(xml|bsl|html|txt)\b.*\beol=' })
        $offenders | Should -BeNullOrEmpty -Because (
            "правило eol= на цих розширеннях псує вміст: " + ($offenders -join '; '))
    }

    It 'правила -text стоять після загального text=auto' {
        $catchAll = @($script:Lines | Select-String -Pattern '^\* text=auto')
        $catchAll.Count | Should -Be 1 -Because 'загальне правило має лишитись рівно одне'

        $textOff = @($script:Lines | Select-String -Pattern '^\*\*/(cfe|epf)/src/\*\*\s+-text')
        $textOff.Count | Should -Be 2

        foreach ($m in $textOff) {
            $m.LineNumber | Should -BeGreaterThan $catchAll[0].LineNumber -Because (
                'інакше загальне правило скасує -text: у git виграє останнє правило, що збіглося')
        }
    }

}

Describe 'templates/githooks — хуки захисту storage/*' -Tag 'Docs' {
    BeforeAll {
        $script:HooksDir = (Resolve-Path "$PSScriptRoot/../../templates/githooks").Path
    }

    It 'обидва хуки на місці, з shebang sh і без CR' {
        foreach ($name in 'pre-commit', 'pre-merge-commit') {
            $p = Join-Path $script:HooksDir $name
            $p | Should -Exist
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $bytes | Should -Not -Contain ([byte]13) -Because "sh падає на CR у $name"
            (Get-Content -LiteralPath $p -TotalCount 1) | Should -Be '#!/bin/sh'
            (Get-Content -LiteralPath $p -Raw) | Should -Match 'V8KIT_SYNC'
        }
    }

    It 'шаблон gitattributes споживача тримає .githooks/* у LF' {
        $lines = @(Get-Content -LiteralPath (Resolve-Path "$PSScriptRoot/../../templates/gitattributes").Path -Encoding UTF8)
        @($lines | Where-Object { $_ -match '^\.githooks/\*\s+text\s+eol=lf\s*$' }).Count | Should -Be 1
    }
}

Describe 'templates/settings.json — дозволи споживача' -Tag 'Docs' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'settings.json споживача не має розділу hooks: хук старту сесії поставляє плагін' {
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $s.PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }
    It 'дозволи Уніки 0.16: у allow рівно читальні інструменти, run і apply (рішення власника #120); в ask Уніки немає' {
        # run — в allow: перезапис бази агента Уніка однаково питає людину своїм питанням, а дозвіл
        # Claude Code перед ним лише дублює запит. Інструментів задач (unica_task_*) у живому
        # tools/list Уніки 0.16 немає — у переліку їх бути не може.
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        # Усі записи allow, що стосуються Уніки чи будь-якого MCP, — з урахуванням регістру і без фільтра за
        # префіксом інструмента: маска сервера (`mcp__plugin_unica_unica` чи `…__*`) мовчки дозволила б
        # run/apply і нові інструменти наступних версій, а регістронечутливий збіг пропустив би «двійника».
        $unica = @($s.permissions.allow | Where-Object { $_ -match '(?i)unica|^mcp__' } | Sort-Object { $_ } -CaseSensitive)
        $want = @('view', 'search', 'resolve', 'docs', 'check', 'diff', 'run', 'apply') |
            ForEach-Object { "mcp__plugin_unica_unica__unica_$_" } | Sort-Object { $_ } -CaseSensitive
        $unica.Count | Should -Be $want.Count -Because 'у allow рівно перелічені інструменти, жодної маски чи двійника'
        for ($i = 0; $i -lt $want.Count; $i++) {
            ($unica[$i] -ceq $want[$i]) | Should -BeTrue -Because "allow[$i] = '$($unica[$i])', очікувано точно '$($want[$i])'"
        }
        foreach ($e in @($s.permissions.allow) + @($s.permissions.ask)) {
            if ($e -match '(?i)^mcp__') {
                $e | Should -Not -Match '\*' -Because 'маска в allow/ask дозволила б чи затінила б інструменти поза переліком'
                $e | Should -Not -MatchExactly '^mcp__plugin_unica_unica$' -Because 'ім''я сервера без інструмента — маска всього сервера'
            }
        }
        # apply — в allow (рішення власника 2026-11-24/25, #120): обмеження — git diff і рев'ю; захист vendor — хук блоку #81.
        @($s.permissions.allow) -ccontains 'mcp__plugin_unica_unica__unica_apply' | Should -BeTrue
        @($s.permissions.ask | Where-Object { $_ -match '(?i)unica|^mcp__' }) | Should -BeNullOrEmpty -Because 'інструмент в allow й ask одночасно — суперечність'
    }
    It 'правила команд процесу в шаблоні — рівно перелік-орієнтир; кожна команда процесу має рішення про дозвіл (D8 (1))' {
        # Незалежний орієнтир: перелік — літерал тут, а не з kit-setup чи шаблону. Команди процесу —
        # обгортки bin/<команда> (вхід агента); кожна мусить мати рішення: або її правила нижче, або вона
        # свідомо з питанням. Нова команда без рішення, правило без рядка тут (чи навпаки) — червоне.
        $allowed = @('sdd', 'review-pack', 'doc', 'session-board', 'session-cost', 'kit-scan', 'track status',
            'pr-gate start', 'pr-gate cleanup', 'pr-gate scratch', 'pr-gate open', 'pr-gate ready', 'pr-gate land')
        $withAsk = @('codex-audit', 'kit-setup')   # дії назовні чи зміна налаштувань — з питанням
        $decided = @(@($allowed | ForEach-Object { $_.Split(' ')[0] }) + $withAsk | Sort-Object -Unique -CaseSensitive)
        $commands = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'bin') -File | ForEach-Object { $_.Name -replace '\.(ps1|exe)$', '' } |
            Where-Object { $_ -cne 'kit' } | Sort-Object -Unique -CaseSensitive)
        ($commands -join ', ') | Should -BeExactly ($decided -join ', ') -Because 'кожна команда процесу з bin/ має рішення про дозвіл у цьому тесті'

        $want = @($allowed | ForEach-Object { "Bash($_`:*)"; "PowerShell($_`:*)" } | Sort-Object -CaseSensitive)
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $process = '^(Bash|PowerShell)\((' + (($commands | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[ :)]'
        foreach ($l in 'allow', 'ask', 'deny') {
            $got = @($s.permissions.$l | Where-Object { $_ -cmatch $process } | Sort-Object -CaseSensitive)
            $exp = if ($l -eq 'allow') { $want } else { @() }
            ($got -join "`n") | Should -BeExactly ($exp -join "`n") -Because "правила команд процесу в $l шаблону — рівно орієнтир"
        }
    }

    It 'шаблон ↔ звіт kit-setup: проєкт = шаблон (з 1С — повний, без 1С — без правил Уніки в allow) — звіт порожній; файл не змінено (D8 (2), D9)' {
        $tplText = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw
        $s = $tplText | ConvertFrom-Json -AsHashtable
        foreach ($case in @(@{ Name = 'kit-setup-1c'; Is1C = $true }, @{ Name = 'kit-setup-plain'; Is1C = $false })) {
            $repo = Join-Path $TestDrive $case.Name
            New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
            git -C $repo init -q
            if ($case.Is1C) { Set-Content -LiteralPath (Join-Path $repo 'v8project.yaml') -Value 'name: x' -Encoding utf8NoBOM }
            $perms = $s.permissions
            if (-not $case.Is1C) {
                $perms = [ordered]@{ allow = @($s.permissions.allow | Where-Object { -not $_.StartsWith('mcp__plugin_unica_unica__', [System.StringComparison]::Ordinal) }); ask = $s.permissions.ask; deny = $s.permissions.deny }
            }
            $file = Join-Path $repo '.claude/settings.json'
            [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject ([ordered]@{ permissions = $perms }) -Depth 10), [System.Text.UTF8Encoding]::new($false))
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            Push-Location $repo
            try {
                $out = & pwsh -NoProfile -File (Join-Path $script:Root 'tools/kit.ps1') kit-setup -Json -NoGitignore -NoProfile -NoWorktreeInclude 2>&1 | Out-String
                $LASTEXITCODE | Should -Be 0 -Because $out
            } finally { Pop-Location }
            $rep = ($out | ConvertFrom-Json).permissions
            $rep.clean | Should -BeTrue -Because "$($case.Name): $out"
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash | Should -Be $hash -Because 'kit-setup не пише settings.json'
        }
    }
    It 'зміст шаблону за §5.3 і D10: 8 правил команд в ask, pr-gate open/ready/land в allow, без pr-gate:*, без застарілих імен Уніки (тест (7))' {
        Import-Module (Join-Path $script:Root 'tools/lib/KitCli.psm1') -Force
        Import-Module (Join-Path $script:Root 'tools/lib/KitVersion.psm1') -Force
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $ask = @($s.permissions.ask)
        $askCommands = @('git push', 'gh pr create', 'gh pr merge', 'gh release') | ForEach-Object { "Bash($_`:*)"; "PowerShell($_`:*)" }
        foreach ($r in $askCommands) { ($ask -ccontains $r) | Should -BeTrue -Because "$r — в ask" }
        $nonMcp = @($ask | Where-Object { $_ -notmatch '^mcp__' } | Sort-Object -CaseSensitive)
        ($nonMcp -join "`n") | Should -BeExactly ((@($askCommands) | Sort-Object -CaseSensitive) -join "`n") -Because 'в ask — рівно 8 правил команд (D10)'
        foreach ($sub in 'open', 'ready', 'land') {
            foreach ($f in 'Bash', 'PowerShell') {
                (@($s.permissions.allow) -ccontains "$f(pr-gate $sub`:*)") | Should -BeTrue -Because "$f(pr-gate $sub`:*) — в allow"
            }
        }
        $all = @($s.permissions.allow) + @($s.permissions.ask) + @($s.permissions.deny)
        @($all | Where-Object { $_ -match '^(Bash|PowerShell)\(pr-gate:' }) | Should -BeNullOrEmpty -Because 'широке pr-gate:* дозволило б майбутні підкоманди без рішення'
        $obsolete = @((Get-KitObsoleteNames -PluginRoot $script:Root).UnicaTools)
        $obsolete.Count | Should -BeGreaterThan 0
        @($all | Where-Object { $obsolete -ccontains $_ }) | Should -BeNullOrEmpty -Because 'застаріле ім''я в шаблоні kit-setup сам би прибрав'
    }
}

Describe 'templates/v8storagekit*.example — зразки проходять власну схему' -Tag 'Docs' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates").Path
    }

    It 'v8storagekit.yaml.example читається Read-KitManifest без зупинки' {
        $m = Read-KitManifest -Path (Join-Path $script:Templates 'v8storagekit.yaml.example')
        $m.Kind | Should -Be 'product'
        $m.Workspaces.Count | Should -BeGreaterOrEqual 2
    }

    It 'v8storagekit.local.yaml.example читається Read-KitLocalOverlay без зупинки' {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Templates 'v8storagekit.local.yaml.example')
        $o.Infobases.Count | Should -BeGreaterOrEqual 1
    }

    It 'шаблон gitignore ігнорує накладку kit і досі — накладку Уніки' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Encoding UTF8)
        $lines | Should -Contain 'v8storagekit.local.yaml'
        $lines | Should -Contain 'v8project.local.yaml'
    }


    It 'шаблон gitignore ігнорує поставку вендора, але не .bin ознак підтримки' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Encoding UTF8 | ForEach-Object { $_.Trim() })
        $lines | Should -Contain '**/Ext/ParentConfigurations/'
        # Форма «тека» (скісна риска в кінці) — контракт: правило без '/' ловило б і файл з тим
        # самим іменем, а форма з '*' — ще й Ext/ParentConfigurations.bin, який мусить бути в git.
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations'
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations*'
    }
}

