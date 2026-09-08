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

Describe 'product-onboarding — шаблон v8project.yaml' {
    BeforeAll {
        $script:Skill = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Resolve-Path "$PSScriptRoot/../../skills/product-onboarding/SKILL.md").Path
    }

    It 'шаблон оголошує власну базу воркспейсу' {
        # Без цього блоку infobase.connection приходить з v8project.local.yaml і
        # вказує на серверну дев-базу - тобто Уніка мутує базу, де людина працює
        # Конфігуратором. Це і була першопричина всього розбору.
        $script:Skill | Should -Match "(?m)^\s*infobase:\s*$"
        $script:Skill | Should -Match "connection:\s*'File=build/ib'"
    }

    It 'імʼя EXTENSION-джерела береться з extensionName, а не з імені теки' {
        # v8-runner виводить імʼя розширення з імені source-set. Якщо там імʼя теки
        # продукту, operation=make падає на валідації:
        #   source-set 'X' resolves to extension 'X', expected 'SMP_X'
        $script:Skill | Should -Not -Match "(?m)^\s*-\s*name:\s*<Продукт>\s*$"
        $script:Skill | Should -Match "(?m)^\s*-\s*name:\s*<extensionName зі storage\.json>\s*$"
    }
}

Describe 'templates/settings.json і using-v8storagekit — хук прив''язаний до репозиторію, не до плагіна (§7)' {
    BeforeAll { $script:Root = (Resolve-Path "$PSScriptRoot/../..").Path }

    It 'settings.json споживача має hooks.SessionStart на .claude/hooks/session-start.ps1 з matcher startup|clear|compact' {
        $s = Get-Content -LiteralPath (Join-Path $script:Root 'templates/settings.json') -Raw | ConvertFrom-Json
        $hook = $s.hooks.SessionStart[0]
        $hook.matcher | Should -Be 'startup|clear|compact'
        $hook.hooks[0].command | Should -BeLike '*pwsh -NoProfile -File .claude/hooks/session-start.ps1*'
        $hook.hooks[0].async | Should -BeFalse
    }
    It 'плагін не оголошує власних хуків' {
        Join-Path $script:Root 'hooks/hooks.json' | Should -Not -Exist
    }
    It 'шим не містить CLAUDE_PLUGIN_ROOT і не імпортує модулів kit' {
        $shim = Get-Content -LiteralPath (Join-Path $script:Root 'templates/hooks/session-start.ps1') -Raw
        $shim | Should -Not -Match 'CLAUDE_PLUGIN_ROOT'
        $shim | Should -Not -Match 'Import-Module'
        $shim | Should -Match 'installed_plugins\.json'
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
}
