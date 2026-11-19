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

    It 'бінарний список накриває gif' {
        # Його відсутність давала repositoryReady=false в unica.project.status.
        $script:Lines | Should -Contain '*.gif binary'
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

Describe 'onboarding — шаблон v8project.yaml (Task 6: колишній product-onboarding)' {
    BeforeAll {
        $script:Skill = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../skills/onboarding/SKILL.md").Path
    }

    It 'шаблон v8project.yaml не оголошує бази агента: вона машинна, у infobases.origin v8project.local.yaml (спека §4.3 п. 2–3)' {
        $script:Skill | Should -Not -Match "(?m)^\s*infobase:\s*$"
        $script:Skill | Should -Match "(?m)^\s*providers:\s*$"
        $script:Skill | Should -Match "connection:\s*'File=build/ib'"   # тепер — у блоці v8project.local.yaml розділу 3.2.1
    }

    It 'імʼя EXTENSION-джерела — реальне ім''я розширення, не ім''я теки продукту' {
        # v8-runner виводить імʼя розширення з імені source-set. Якщо там імʼя теки
        # продукту, operation=make падає на валідації:
        #   source-set 'X' resolves to extension 'X', expected 'SMP_X'
        $script:Skill | Should -Not -Match "(?m)^\s*-\s*name:\s*<Продукт>\s*$"
        $script:Skill | Should -Match "(?m)^\s*-\s*name:\s*<ІмʼяРозширення>\s*$"
        $script:Skill | Should -Match 'name:.*мусить дорівнювати імені розширення'
    }
}

Describe 'onboarding — каркас не кладе хука старту сесії у споживача (1.6.0: хук у плагіні)' {
    BeforeAll {
        $script:MigrationSkill = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../skills/onboarding/SKILL.md").Path
    }

    It 'жоден git add і жоден рядок каркаса не згадує .claude/hooks/session-start.ps1, settings.json лишається' {
        $script:MigrationSkill | Should -Not -Match 'hooks/session-start\.ps1'
        $script:MigrationSkill | Should -Match 'git add .*\.claude/settings\.json'
    }
}
Describe 'templates/settings.json, хук плагіна і using-v8storagekit' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'settings.json споживача не має розділу hooks: хук старту сесії поставляє плагін' {
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $s.PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }
    It 'дозволи Уніки 0.13: рівно читальні інструменти в allow; run/apply/task_cancel — явно в ask (спека §4.4 п. 3)' {
        # task_get/task_result/task_cancel існують лише в профілі Compatibility (клієнт без нативних
        # MCP Tasks); у профілі Native їх немає, і зайвий дозвіл нешкідливий.
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        # Усі записи allow, що стосуються Уніки чи будь-якого MCP, — з урахуванням регістру і без фільтра за
        # префіксом інструмента: маска сервера (`mcp__plugin_unica_unica` чи `…__*`) мовчки дозволила б
        # run/apply і нові інструменти наступних версій, а регістронечутливий збіг пропустив би «двійника».
        $unica = @($s.permissions.allow | Where-Object { $_ -match '(?i)unica|^mcp__' } | Sort-Object { $_ } -CaseSensitive)
        $want = @('view', 'search', 'resolve', 'docs', 'check', 'diff', 'task_get', 'task_result') |
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
        foreach ($name in 'unica_run', 'unica_apply', 'unica_task_cancel') {
            $full = "mcp__plugin_unica_unica__$name"
            @($s.permissions.allow) -ccontains $full | Should -BeFalse
            # Головна причина — режим auto: класифікатор не питає, коли запису немає в ask; acceptEdits/bypass — додаткові.
            @($s.permissions.ask) -ccontains $full | Should -BeTrue -Because 'відсутність в allow не гарантує запиту в режимах auto/acceptEdits/bypass'
        }
    }
    It 'хук плагіна не читає реєстру плагінів і не імпортує модулів kit' {
        # Корінь плагіна хук бере зі свого $PSScriptRoot; реєстр (installed_plugins.json) читав лише шим 1.5.0.
        $hook = Get-Content -LiteralPath (Join-Path $script:Root 'hooks/session-start.ps1') -Raw
        $hook | Should -Not -Match 'Import-Module'
        $hook | Should -Not -Match 'installed_plugins\.json'
        $hook | Should -Match 'PSScriptRoot'
        Join-Path $script:Root 'templates/hooks/session-start.ps1' | Should -Not -Exist
    }
    It 'using-v8storagekit без токена CLAUDE_PLUGIN_ROOT, з префіксованими іменами скілів' {
        $skill = Get-Content -LiteralPath (Join-Path $script:Root 'skills/using-v8storagekit/SKILL.md') -Raw
        $skill | Should -Not -Match 'CLAUDE_PLUGIN_ROOT'
        foreach ($n in 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify', 'onboarding') { $skill | Should -Match "v8storagekit:$n" }
        $skill | Should -Match '<корінь плагіна>'
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

    It 'шаблон gitignore без загального **/cf/** (Task 6, Step 2а): вендорські дерева — явними рядками onboarding' {
        # У клієнтському репозиторії cf/src під truth: storage мусить лежати в git (спека §2.3) —
        # загальне **/cf/** ігнорувало б і його. Гітігнорованість вендорських дерев тепер дає
        # лише явний рядок під фактичний шлях, який дописує v8storagekit:onboarding.
        $raw = Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Raw -Encoding UTF8
        $raw | Should -Not -Match '(?m)^\*\*/cf/\*\*\s*$'
        $raw | Should -Not -Match '(?m)^!\*\*/cf/README\.md\s*$'
    }

    It 'шаблон gitignore ігнорує поставку вендора, але не .bin ознак підтримки (спека 2026-09-30 §5.2)' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Templates 'gitignore') -Encoding UTF8 | ForEach-Object { $_.Trim() })
        $lines | Should -Contain '**/Ext/ParentConfigurations/'
        # Форма «тека» (скісна риска в кінці) — контракт: правило без '/' ловило б і файл з тим
        # самим іменем, а форма з '*' — ще й Ext/ParentConfigurations.bin, який мусить бути в git.
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations'
        $lines | Should -Not -Contain '**/Ext/ParentConfigurations*'
    }
}

Describe 'templates/CLAUDE.md — модель 1.0 (Task 6)' {
    BeforeAll {
        $script:TemplateClaudeMd = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../templates/CLAUDE.md").Path
    }

    It 'згадує v8storagekit.yaml, гілки storage/ і всі сім скілів життєвого циклу з префіксом' {
        $script:TemplateClaudeMd | Should -Match 'v8storagekit\.yaml'
        $script:TemplateClaudeMd | Should -Match 'storage/'
        foreach ($n in 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify') {
            $script:TemplateClaudeMd | Should -Match "v8storagekit:$n" -Because "шаблон не називає скіл $n"
        }
    }

    It 'не згадує спадок 0.6.0: storage.json, storage-sync, load-ext' {
        $script:TemplateClaudeMd | Should -Not -Match 'storage\.json'
        $script:TemplateClaudeMd | Should -Not -Match 'storage-sync'
        $script:TemplateClaudeMd | Should -Not -Match 'load-ext'
    }

    It 'C2 Task 7: абзац «Збірка .cfe» називає output відносним до воркспейсу, не абсолютним' {
        $script:TemplateClaudeMd | Should -Match 'Збірка `\.cfe`'
        $script:TemplateClaudeMd | Should -Match '"output":"build/artifacts/<Ім''я>\.cfe"'
        $script:TemplateClaudeMd | Should -Not -Match 'output=<корінь'
    }

    It 'templates/CLAUDE.md говорить мовою Уніки 0.13' {
        $c = $script:TemplateClaudeMd
        $c | Should -Not -Match 'operation='
        $c | Should -Match 'infobases\.origin'
        $c | Should -Match '"op":"make"'
        $c | Should -Match 'unica\.check'
    }
}
