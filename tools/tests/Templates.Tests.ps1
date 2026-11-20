#Requires -Version 7
Describe 'templates/gitattributes — політика тексту' {
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

Describe 'templates/githooks — хуки захисту storage/*' {
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

Describe 'templates/settings.json — дозволи споживача' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'settings.json споживача не має розділу hooks: хук старту сесії поставляє плагін' {
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $s.PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }
    It 'дозволи Уніки 0.16: у allow рівно читальні інструменти й run; apply — явно в ask' {
        # run — в allow: перезапис бази агента Уніка однаково питає людину своїм питанням, а дозвіл
        # Claude Code перед ним лише дублює запит. Інструментів задач (unica_task_*) у живому
        # tools/list Уніки 0.16 немає — у переліку їх бути не може.
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        # Усі записи allow, що стосуються Уніки чи будь-якого MCP, — з урахуванням регістру і без фільтра за
        # префіксом інструмента: маска сервера (`mcp__plugin_unica_unica` чи `…__*`) мовчки дозволила б
        # run/apply і нові інструменти наступних версій, а регістронечутливий збіг пропустив би «двійника».
        $unica = @($s.permissions.allow | Where-Object { $_ -match '(?i)unica|^mcp__' } | Sort-Object { $_ } -CaseSensitive)
        $want = @('view', 'search', 'resolve', 'docs', 'check', 'diff', 'run') |
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
        $full = 'mcp__plugin_unica_unica__unica_apply'
        @($s.permissions.allow) -ccontains $full | Should -BeFalse
        # Головна причина — режим auto: класифікатор не питає, коли запису немає в ask; acceptEdits/bypass — додаткові.
        @($s.permissions.ask) -ccontains $full | Should -BeTrue -Because 'відсутність в allow не гарантує запиту в режимах auto/acceptEdits/bypass'
        @($s.permissions.ask | Where-Object { $_ -match '(?i)unica|^mcp__' }) | Should -Be @($full) -Because 'в ask з інструментів Уніки — лише apply'
    }
    It 'дозволи команд процесу в шаблоні — рівно ті, що пише kit-setup; зовнішніх немає' {
        # Одне джерело переліку — kit-setup (його правила дописуються в уже наявні налаштування проєкту);
        # шаблон — статичний JSON, який роздає install-hooks, тож він не може взяти перелік під час
        # роботи. Тест запускає справжній kit-setup на порожньому репо й звіряє множини з урахуванням
        # регістру: нова команда в kit-setup без рядка в шаблоні (чи навпаки) — червоне.
        $repo = Join-Path $TestDrive 'kit-setup-perms'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        Push-Location $repo
        try {
            $null = & pwsh -NoProfile -File (Join-Path $script:Root 'tools/kit-process.ps1') kit-setup -NoGitignore -NoProfile -NoWorktreeInclude 2>&1
            $LASTEXITCODE | Should -Be 0
        } finally { Pop-Location }
        $fromSetup = @((Get-Content -LiteralPath (Join-Path $repo '.claude/settings.json') -Raw | ConvertFrom-Json).permissions.allow | Sort-Object { $_ } -CaseSensitive)
        $fromSetup.Count | Should -BeGreaterThan 0 -Because 'kit-setup мусить дописати правила команд процесу'
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $process = '^(Bash|PowerShell)\((sdd|review-pack|doc|session-board|session-cost|kit-scan|kit-setup|track|pr-gate)[ :]'
        $inTemplate = @($s.permissions.allow | Where-Object { $_ -cmatch $process } | Sort-Object { $_ } -CaseSensitive)
        ($inTemplate -join "`n") | Should -BeExactly ($fromSetup -join "`n") -Because 'шаблон і kit-setup дозволяють той самий перелік команд процесу'
        foreach ($e in @($s.permissions.allow)) {
            $e | Should -Not -Match '^(Bash|PowerShell)\((pr-gate (open|ready|land)|track (spec|milestone)|kit-setup|pr-gate:|track:)' -Because 'зовнішні дії й широкі маски — лише з запитом'
        }
    }
}

Describe 'templates/v8storagekit*.example — зразки проходять власну схему' {
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

