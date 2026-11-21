#Requires -Version 7
# Лише ВЛАСТИВОСТІ, що ловлять дорогу помилку (скіл не завантажиться, посилання веде в нікуди,
# скіл цитує неіснуючу зупинку чи команду). Наявність фраз у прозі скілів не перевіряється:
# така перевірка описує текст, а не контракт, і ламається від кожної редакції.
Describe 'skills/*/SKILL.md — правила, які легко порушити' {
    BeforeAll {
        $script:SkillsDir = (Resolve-Path "$PSScriptRoot/../../skills").Path
        # Перелік скілів — теки skills/ самого репозиторію, а не ручний список: правила нижче мусять
        # діяти на кожен скіл, зокрема на новий. Тека без SKILL.md сюди не потрапляє — її ловить окремий It.
        $script:Allowed = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') }).Name
        $script:AgentsDir = Join-Path $PSScriptRoot '../../agents'
        $script:Skills = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory |
            Where-Object { $_.Name -in $script:Allowed } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Text = (Get-Content -LiteralPath (Join-Path $_.FullName 'SKILL.md') -Raw -Encoding UTF8) } })
        function script:Skill([string]$Name) { ($script:Skills | Where-Object Name -eq $Name).Text }

        # Усі .md скіла, не лише SKILL.md: підтеку references/ агент читає тим самим Read, і
        # речення ПРО токен шкодить там не менше — воно так само проситься в копіювання.
        $script:SkillDocs = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory |
            Where-Object { $_.Name -in $script:Allowed } | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter '*.md' -File -Recurse | ForEach-Object {
                    [pscustomobject]@{
                        Rel  = [IO.Path]::GetRelativePath($script:SkillsDir, $_.FullName)
                        Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8)
                    }
                }
            })
    }

    It 'frontmatter: name = ім''я теки, description з тригерами' {
        foreach ($s in $script:Skills) {
            $s.Text | Should -Match "(?m)^name:\s*$([regex]::Escape($s.Name))\s*$"
            $s.Text | Should -Match '(?m)^description:.*Тригер'
        }
    }
    It '${CLAUDE_PLUGIN_ROOT} — лише всередині шляху (за токеном одразу /), у ВСІХ .md скіла' {
        # Guard на ВЛАСТИВІСТЬ («за токеном одразу /»), не на перелік тек: речення ПРО токен після
        # сліпої підстановки стає вказівкою вписати абсолютний шлях конкретної машини.
        $script:SkillDocs.Count | Should -BeGreaterThan 8 -Because 'набір мусить брати й references/, не лише SKILL.md'
        foreach ($d in $script:SkillDocs) {
            [regex]::Matches($d.Text, '\$\{CLAUDE_PLUGIN_ROOT\}(?!/)').Count | Should -Be 0 -Because "у $($d.Rel) токен вжито не як частину шляху"
        }
    }
    It '${CLAUDE_PLUGIN_ROOT} не вживається у skills/*/references/** — там токен НЕ підставляється, агент отримав би непридатну команду' {
        # Підстановка діє лише в тілі SKILL.md (пілот 1.6.0, 2026-11-20). Контроль, що перевірка бачить references/: набір не порожній.
        $refs = @($script:SkillDocs | Where-Object { $_.Rel -match '[\\/]references[\\/]' })
        $refs.Count | Should -BeGreaterThan 0 -Because 'контроль: references/ мусить потрапляти в набір'
        foreach ($d in $refs) {
            $d.Text | Should -Not -Match '\$\{CLAUDE_PLUGIN_ROOT\}' -Because "у $($d.Rel) токен не підставляється"
        }
    }

    It 'перехресні посилання v8storagekit:ІМ''Я ведуть на скіл skills/ІМ''Я/SKILL.md або агента agents/ІМ''Я.md' {
        # Джерела — усі .md тек скілів, усі agents/*.md і шаблони, що роздаються споживачам (templates/CLAUDE.md
        # називає скіли за префіксованим іменем): посилання, що веде в нікуди, ламає ту саму дію. Цей же тест
        # ловить посилання на вилучені чи перейменовані скіли — їхніх тек на диску немає.
        $sources = @($script:SkillDocs | ForEach-Object { [pscustomobject]@{ Rel = "skills/$($_.Rel)"; Text = $_.Text } })
        if (Test-Path -LiteralPath $script:AgentsDir) {
            $sources += @(Get-ChildItem -LiteralPath $script:AgentsDir -Filter '*.md' -File | ForEach-Object {
                    [pscustomobject]@{ Rel = "agents/$($_.Name)"; Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) } })
        }
        $templatesDir = (Resolve-Path "$PSScriptRoot/../../templates").Path
        $sources += @(Get-ChildItem -LiteralPath $templatesDir -Filter '*.md' -File | ForEach-Object {
                [pscustomobject]@{ Rel = "templates/$($_.Name)"; Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) } })
        foreach ($s in $sources) {
            foreach ($m in [regex]::Matches($s.Text, 'v8storagekit:([a-z0-9-]+)')) {
                $refName = $m.Groups[1].Value
                $isSkill = Test-Path -LiteralPath (Join-Path $script:SkillsDir "$refName/SKILL.md")
                $isAgent = Test-Path -LiteralPath (Join-Path $script:AgentsDir "$refName.md")
                ($isSkill -or $isAgent) | Should -BeTrue -Because "у $($s.Rel) посилання на v8storagekit:$refName, а ні skills/$refName/SKILL.md, ні agents/$refName.md немає"
            }
        }
    }

    It 'кожна тека skills/ має SKILL.md; вилучені скіли не воскресли' {
        # BeforeAll бере лише теки з SKILL.md — тека без нього випала б з усіх правил мовчки, а
        # плагін її не завантажить. Тека з ім'ям вилученого чи перейменованого скіла — помилка.
        $actualDirs = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory)
        foreach ($d in $actualDirs) {
            (Join-Path $d.FullName 'SKILL.md') | Should -Exist -Because "тека skills/$($d.Name) без SKILL.md — плагін її не завантажить"
        }
        foreach ($old in 'storage-pipeline', 'product-onboarding', 'repo-migration', 'using-v8storagekit', 'sync', 'verify', 'reconcile', 'dump', 'provision', 'finish', 'landed-review', 'retro', 'unica-1c', 'unica-folders') {
            $actualDirs.Name | Should -Not -Contain $old -Because "скіл $old вилучено чи перейменовано — тека не мала з'явитись знову"
        }
    }

    It 'жодних згадок вилучених скриптів' {
        foreach ($s in $script:Skills) {
            $s.Text | Should -Not -Match 'storage-sync\.ps1|dump-config\.ps1|load-ext\.ps1|build\.ps1' -Because "у $($s.Name)"
        }
    }

    It 'кожна команда `kit <команда>` у скілах і шаблонах існує в tools/commands' {
        # Скіл, що кличе неіснуючу команду, — дефект, який користувач побачить лише на «Unknown command» у живій сесії.
        $commandsDir = (Resolve-Path "$PSScriptRoot/../commands").Path
        $known = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.psm1' -File | ForEach-Object BaseName)
        $known.Count | Should -BeGreaterThan 5 -Because 'контроль: перелік команд не порожній'
        $templatesDir = (Resolve-Path "$PSScriptRoot/../../templates").Path
        $files = @($script:SkillDocs | ForEach-Object { [pscustomobject]@{ Rel = "skills/$($_.Rel)"; Text = $_.Text } }) +
            @(Get-ChildItem -LiteralPath $templatesDir -Recurse -File | ForEach-Object {
                [pscustomobject]@{ Rel = "templates/" + [IO.Path]::GetRelativePath($templatesDir, $_.FullName); Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) } })
        $seen = 0
        foreach ($f in $files) {
            # Документ про минулі версії називає прибрані команди свідомо.
            if ($f.Rel -like '*upgrades.md') { continue }
            foreach ($m in [regex]::Matches($f.Text, '(?m)(?:^\s*|`)kit\s+([a-z][a-z0-9-]+)')) {
                $seen++
                $known | Should -Contain $m.Groups[1].Value -Because "у $($f.Rel) викликано kit $($m.Groups[1].Value), а tools/commands/$($m.Groups[1].Value).psm1 немає"
            }
        }
        $seen | Should -BeGreaterThan 5 -Because 'контроль: пошук мусить знаходити виклики'
    }

    It 'onboarding посилається на upgrades.md, і той описує перехід на ПОТОЧНУ версію плагіна' {
        $skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/onboarding/SKILL.md') -Raw -Encoding UTF8
        $skill | Should -BeLike '*references/upgrades.md*'
        $up = Join-Path $PSScriptRoot '../../skills/onboarding/references/upgrades.md'
        $up | Should -Exist
        # Версія читається з plugin.json, а не вшита: вшите число старіє на першому ж бампі.
        $pluginVersion = [string]((Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.claude-plugin/plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
        $pluginVersion | Should -Not -BeNullOrEmpty
        # Заголовок розділу переходу, а не підрядок: голе число трапляється й у прозі.
        (Get-Content -LiteralPath $up -Raw -Encoding UTF8) | Should -Match ('(?m)^##\s+\d+\.\d+\.\d+\s+→\s+' + [regex]::Escape($pluginVersion) + '\s*$') `
            -Because "upgrades.md мусить мати розділ переходу на версію, яку плагін щойно оголосив ($pluginVersion)"
    }

    Context 'infobase-agent — цитати зупинок' {
        It 'кожна фраза зупинки, процитована в розділі «Штатні зупинки», існує дослівно в tools/commands чи tools/lib' {
            $t = Skill 'infobase-agent'
            $m = [regex]::Match($t, '(?ms)^## 4\. Штатні зупинки\s*$(.*?)(?=^## )')
            $m.Success | Should -BeTrue -Because 'розділ «## 4. Штатні зупинки» має бути у скілі infobase-agent'
            # Форма цитати в розділі: пункт списку починається з `…` (перший спан у бектиках), «…» — місце змінної частини.
            $quotes = foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
                $q = [regex]::Match($line, '^- `([^`]+)`')
                if ($q.Success) { $q.Groups[1].Value }
            }
            @($quotes).Count | Should -BeGreaterThan 10 -Because 'розділ має містити цитати зупинок у формі «- `текст`»'
            $toolsDir = (Resolve-Path "$PSScriptRoot/..").Path
            $code = (Get-ChildItem -LiteralPath $toolsDir -Recurse -Filter '*.psm1' |
                Where-Object { $_.DirectoryName -match '[\\/](commands|lib)$' } |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
            # Нормалізація коду до тексту, який побачить людина: склейка літералів через `+` у рядках, '' -> ', `$ -> $.
            $code = [regex]::Replace($code, '["'']\s*\+\s*\r?\n\s*["'']', '')
            $code = $code.Replace("''", "'").Replace('`$', '$')
            $missing = foreach ($q in $quotes) {
                foreach ($frag in ($q -split '…')) {
                    $f = $frag.Trim(' ')
                    if ($f.Length -lt 6) { continue }
                    if (-not $code.Contains($f)) { "«$f» (з цитати: $q)" }
                }
            }
            @($missing) | Should -BeNullOrEmpty -Because ("скіл цитує тексти зупинок, яких немає в коді (виправляти скіл, не код):`n" + (@($missing) -join "`n"))
        }
    }

    It 'task-finish: push force стоїть раніше за pull force, а той — раніше за adopt' {
        # pull на базі, не вирівняній push force, вивантажив би версію сховища замість гілки задачі й замінив би
        # закомічену роботу — тому порядок кроків канонізації є контрактом, а не стилем.
        $t = Skill 'task-finish'
        $posPush = $t.IndexOf('"op":"push"')
        $posPull = $t.IndexOf('"op":"pull"')
        $posAdopt = $t.IndexOf('kit adopt')
        $posPush | Should -BeGreaterThan -1
        $posPull | Should -BeGreaterThan $posPush
        $posAdopt | Should -BeGreaterThan $posPull
    }
}
