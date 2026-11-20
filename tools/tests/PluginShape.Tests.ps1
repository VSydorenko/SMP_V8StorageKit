#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-check, modified.
# Форма плагіна, яку можна перевірити скриптом, а не рецензією: обгортки команд процесу, описи,
# посилання, шапки походження, бамп версії. Помилку, яку знаходить скрипт, має знайти скрипт —
# інакше вона переживає рецензію (в оригіналі так пережив своє видалення агент у п'яти файлах).

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # Відомі порушники (порт WARN_ONLY оригіналу): пари (скіл, перевірка). Це скіли сховища в роботі блоку
    # 1.6.0, вони старші за межі описів і розміру. Запис прибирається разом зі скороченням скіла (інакше
    # тест падає: перелік не гниє); нові скіли й усе поза переліком — фейл.
    $script:KnownViolators = @(
        foreach ($s in 'dump', 'finish', 'onboarding', 'provision', 'reconcile', 'unica-folders', 'verify', 'using-v8storagekit') { @{ Skill = $s; Check = 'description' } }
        foreach ($s in 'onboarding', 'sync') { @{ Skill = $s; Check = 'skill-size' } }
    )

    # Класифікація знахідок перевірки $Check (рядки на кшталт «skills/ІМ'Я/SKILL.md — …») за переліком
    # відомих порушників: Unknown — поза переліком (фейл), Known — у переліку (не фейл), Stale — запис
    # переліку без порушення (фейл «прибери»).
    function script:Get-KitViolationClassification([string[]]$Problems, [string]$Check, [object[]]$Known) {
        $unknown = [System.Collections.Generic.List[string]]::new()
        $knownHit = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $names = @($Known | Where-Object { $_.Check -eq $Check } | ForEach-Object { $_.Skill })
        foreach ($p in $Problems) {
            $m = [regex]::Match($p, '^skills/([^/]+)/SKILL\.md')
            if ($m.Success -and $names -contains $m.Groups[1].Value) { $knownHit.Add($p); [void]$seen.Add($m.Groups[1].Value) }
            else { $unknown.Add($p) }
        }
        $stale = @($names | Where-Object { -not $seen.Contains($_) } |
                ForEach-Object { "($_, $Check) — прибери (скіл, перевірка) з переліку відомих порушників: скіл більше не порушує" })
        return @{ Unknown = $unknown.ToArray(); Known = $knownHit.ToArray(); Stale = $stale }
    }

    # Вердикт It: фейл (з усіма причинами) або Inconclusive із поіменним списком відомих, або зелений.
    function script:Assert-KitViolationVerdict($Class) {
        $bad = @($Class.Unknown) + @($Class.Stale)
        if ($bad.Count) { throw (($bad + @($Class.Known | ForEach-Object { "відомий порушник: $_" })) -join '; ') }
        if ($Class.Known.Count) { Set-ItResult -Inconclusive -Because ('відомі порушники: ' + ($Class.Known -join '; ')) }
    }

    # Знахідки обгорток для репозиторію $Root: перелік рядків «що не так», порожній — усе гаразд.
    # Функція, а не інлайн-перевірка: та сама логіка ганяється і на самому плагіні, і на синтетичному
    # репозиторії-контролі, який мусить її провалити.
    function script:Get-KitWrapperProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $listFile = Join-Path $Root 'tools/commands/process-commands.txt'
        $names = @(Get-Content -LiteralPath $listFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

        # Режим з індексу і з HEAD. Обидва: `git commit --only -- bin/<ім'я>` на Windows
        # (core.filemode=false) бере режим із робочого дерева й комітить 100644, навіть коли в
        # індексі після `update-index --chmod=+x` стояло 100755. Без цієї перевірки біт губиться
        # мовчки, і обгортка в Bash не запускається («Permission denied»).
        $modes = @{}
        foreach ($src in @(
                @{ Where = 'індексі'; Lines = @(git -C $Root ls-files -s -- bin/ 2>$null) },
                @{ Where = 'HEAD'; Lines = @(git -C $Root ls-tree HEAD -- bin/ 2>$null) })) {
            foreach ($l in $src.Lines) {
                if ($l -match '^(\d{6})\s.*?\t(.+)$') { $modes["$($src.Where)|$($Matches[2])"] = $Matches[1] }
            }
        }

        foreach ($n in $names) {
            foreach ($f in "bin/$n", "bin/$n.ps1") {
                if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) { $problems.Add("$f — немає обгортки команди процесу '$n'") }
            }
            if (-not $modes.ContainsKey("індексі|bin/$n")) { $problems.Add("bin/$n — не в індексі git") }
        }
        # Кожна bash-обгортка (файл bin/ без розширення), не лише з переліку: стара команда, яку
        # прибрали з переліку, але лишили обгортку, теж має запускатись або зникнути.
        foreach ($key in @($modes.Keys)) {
            $where, $path = $key -split '\|', 2
            if ([IO.Path]::GetExtension($path) -eq '' -and $modes[$key] -ne '100755') {
                $problems.Add("$path — режим $($modes[$key]) у $where, потрібен 100755 (git add → git update-index --chmod=+x → git commit без шляхів)")
            }
        }
        return , $problems.ToArray()
    }

    # Межі з kit-check оригіналу. Опис скіла/агента завжди в контексті сесії; довший обрізається в списку
    # скілів, і тригер у хвості губиться. SKILL.md після компакції обрізається до 20 000 символів — тонкий
    # скіл має бути значно меншим, тож межа з запасом.
    $script:DescriptionMax = 250
    $script:SkillMaxChars = 12000

    # Frontmatter: поля верхнього рівня; багаторядкове значення склеюється пробілом, провідні `>`/`|` і
    # обгортні лапки знімаються. Повертає $null, коли frontmatter немає.
    function script:Get-KitFrontmatter([string]$Text) {
        $m = [regex]::Match($Text, '^---\r?\n([\s\S]*?)\r?\n---')
        if (-not $m.Success) { return $null }
        $fields = [ordered]@{}
        $key = $null
        foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
            $kv = [regex]::Match($line, '^([A-Za-z][\w-]*):\s*(.*)$')
            if ($kv.Success) {
                $key = $kv.Groups[1].Value
                $fields[$key] = $kv.Groups[2].Value
            }
            elseif ($key -and $line -match '^\s+\S') { $fields[$key] += " $($line.Trim())" }
        }
        foreach ($k in @($fields.Keys)) {
            $v = $fields[$k] -replace '^[>|][-+]?\s*', ''
            $v = $v -replace '^([''"])([\s\S]*)\1$', '$2'
            $fields[$k] = $v.Trim()
        }
        return $fields
    }

    # Файли скілів і агентів плагіна $Root: @{ Rel; Path; Kind }. Теки agents/ може не бути.
    function script:Get-KitSkillAgentFiles([string]$Root) {
        $out = [System.Collections.Generic.List[object]]::new()
        $skills = Join-Path $Root 'skills'
        if (Test-Path -LiteralPath $skills) {
            foreach ($d in Get-ChildItem -LiteralPath $skills -Directory) {
                $f = Join-Path $d.FullName 'SKILL.md'
                if (Test-Path -LiteralPath $f) { $out.Add(@{ Rel = "skills/$($d.Name)/SKILL.md"; Path = $f; Kind = 'skill' }) }
            }
        }
        $agents = Join-Path $Root 'agents'
        if (Test-Path -LiteralPath $agents) {
            foreach ($f in Get-ChildItem -LiteralPath $agents -Filter '*.md' -File) {
                $out.Add(@{ Rel = "agents/$($f.Name)"; Path = $f.FullName; Kind = 'agent' })
            }
        }
        return $out.ToArray()
    }

    # 1. Опис ≤ 250 символів у скілів і агентів.
    function script:Get-KitDescriptionProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @(Get-KitSkillAgentFiles $Root)) {
            $fm = Get-KitFrontmatter (Get-Content -LiteralPath $f.Path -Raw -Encoding UTF8)
            if ($null -eq $fm -or -not $fm.Contains('description') -or -not $fm['description']) {
                # Відсутній опис у агента ловить перевірка агентів, у скіла — тут, бо інакше він мовчки проходить.
                if ($f.Kind -eq 'skill') { $problems.Add("$($f.Rel) — немає description") }
                continue
            }
            $len = $fm['description'].Length
            if ($len -gt $script:DescriptionMax) {
                $problems.Add("$($f.Rel) — description $len символів > $($script:DescriptionMax): залиште тригер, решту перенесіть у тіло")
            }
        }
        return , $problems.ToArray()
    }

    # 2. Агенти: description, model, tools. Без allowlist агент успадковує всі MCP-інструменти сесії.
    function script:Get-KitAgentProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @(Get-KitSkillAgentFiles $Root) | Where-Object { $_.Kind -eq 'agent' }) {
            $fm = Get-KitFrontmatter (Get-Content -LiteralPath $f.Path -Raw -Encoding UTF8)
            if ($null -eq $fm) { $problems.Add("$($f.Rel) — немає frontmatter (--- name/description/model/tools ---)"); continue }
            foreach ($field in 'description', 'model', 'tools') {
                if (-not $fm.Contains($field) -or -not $fm[$field]) {
                    $why = if ($field -eq 'tools') { ' (без allowlist агент успадковує всі MCP-інструменти сесії)' } else { '' }
                    $problems.Add("$($f.Rel) — немає $($field):$why")
                }
            }
        }
        return , $problems.ToArray()
    }

    # 3. Розмір SKILL.md.
    function script:Get-KitSkillSizeProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @(Get-KitSkillAgentFiles $Root) | Where-Object { $_.Kind -eq 'skill' }) {
            $len = (Get-Content -LiteralPath $f.Path -Raw -Encoding UTF8).Length
            if ($len -gt $script:SkillMaxChars) {
                $problems.Add("$($f.Rel) — $len символів > $($script:SkillMaxChars): деталі винесіть у references/")
            }
        }
        return , $problems.ToArray()
    }

    function script:Get-KitProcessCommandNames([string]$Root) {
        $listFile = Join-Path $Root 'tools/commands/process-commands.txt'
        return @(Get-Content -LiteralPath $listFile -Encoding UTF8 |
                ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    # Довідка команди — від самої команди (підпроцес), бо довідка і є контракт. Кеш на (корінь, команда):
    # один виклик на команду за прогін.
    $script:HelpCache = @{}
    function script:Get-KitCommandContract([string]$PluginRoot, [string]$Name) {
        $key = "$PluginRoot|$Name"
        if (-not $script:HelpCache.ContainsKey($key)) {
            $help = (& pwsh -NoProfile -File (Join-Path $PluginRoot 'tools/kit-process.ps1') $Name -Help 2>&1 | Out-String)
            $subs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($m in [regex]::Matches($help, "(?m)^\s*$([regex]::Escape($Name)) ([a-z][a-z0-9-]*)\b")) { [void]$subs.Add($m.Groups[1].Value) }
            $script:HelpCache[$key] = @{ Help = $help; Subs = $subs }
        }
        return $script:HelpCache[$key]
    }

    # 4. Команди процесу в зворотних лапках: підкоманда й прапорці мають бути в довідці команди.
    # $Root — де лежать скіли й агенти, $PluginRoot — де команди (за замовчуванням той самий).
    function script:Get-KitCommandUsageProblems([string]$Root, [string]$PluginRoot = $Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $names = Get-KitProcessCommandNames $PluginRoot
        if (-not $names) { return , @('немає жодної команди в process-commands.txt') }
        $cmdRe = '^(?:' + (($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?:\s|$)'
        $files = [System.Collections.Generic.List[object]]::new()
        $skills = Join-Path $Root 'skills'
        if (Test-Path -LiteralPath $skills) { foreach ($f in Get-ChildItem -LiteralPath $skills -Recurse -Filter '*.md' -File) { $files.Add($f) } }
        $agents = Join-Path $Root 'agents'
        if (Test-Path -LiteralPath $agents) { foreach ($f in Get-ChildItem -LiteralPath $agents -Filter '*.md' -File) { $files.Add($f) } }
        foreach ($file in $files) {
            $rel = $file.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
                $n++
                foreach ($m in [regex]::Matches($line, '`([^`]+)`')) {
                    $span = $m.Groups[1].Value.Trim()
                    if ($span -notmatch $cmdRe) { continue }
                    $parts = @($span -split '\s+')
                    $name = $parts[0]
                    $rest = @($parts | Select-Object -Skip 1)
                    $c = Get-KitCommandContract $PluginRoot $name
                    $at = "${rel}:$n"
                    if (-not $c.Help.Trim()) { $problems.Add("$at — довідка '$name -Help' порожня: перевірити команду нічим"); continue }
                    # Підкоманду перевіряємо, лише коли їх у команди щонайменше дві: інакше перше слово —
                    # аргумент, а не підкоманда. Плейсхолдери (<файл>, <N>) з літери не починаються.
                    if ($c.Subs.Count -ge 2 -and $rest.Count -and $rest[0] -cmatch '^[a-z][a-z0-9-]*$' -and -not $c.Subs.Contains($rest[0])) {
                        $problems.Add("$at — ``$name $($rest[0])``: у $name немає підкоманди '$($rest[0])'; відомі: $(($c.Subs | Sort-Object) -join ', ')")
                    }
                    foreach ($fm in [regex]::Matches(($rest -join ' '), '(?<![\w-])-[A-Za-z][A-Za-z0-9]*')) {
                        $flag = $fm.Value
                        if ($flag -ieq '-Help') { continue }
                        # PowerShell-аргументи нечутливі до регістру; межа слова: -Dead не збігається з -Deadline.
                        if ($c.Help -notmatch "(?i)(?<![\w-])$([regex]::Escape($flag))(?![\w-])") {
                            $problems.Add("$at — ``$name … $flag``: прапорця немає в довідці $name; виправте прапорець або текст")
                        }
                    }
                }
            }
        }
        return , $problems.ToArray()
    }

    # 5. Шапка походження: рядок з маркером має форму «<маркер> <шлях>, modified.» з непорожнім відносним шляхом.
    # Регулярний вираз маркера не збігається з власним текстом (екрановані крапки), тож цей файл не ловить сам себе.
    function script:Get-KitProvenanceProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $marker = 'Ported from agent-kit 0\.9\.1'
        foreach ($top in 'tools', 'skills', 'agents', 'hooks') {
            $dir = Join-Path $Root $top
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($file in Get-ChildItem -LiteralPath $dir -Recurse -File) {
                $bytes = [IO.File]::ReadAllBytes($file.FullName)
                if ($bytes.Length -eq 0) { continue }
                if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min($bytes.Length, 8000)) -ge 0) { continue }
                $rel = $file.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
                $n = 0
                foreach ($line in ([Text.Encoding]::UTF8.GetString($bytes) -split '\r?\n')) {
                    $n++
                    if ($line -notmatch $marker) { continue }
                    $m = [regex]::Match($line, "$marker\s+(\S.*?), modified\.")
                    if (-not $m.Success) { $problems.Add("${rel}:$n — шапка походження не має форми «" + 'Ported from agent-kit ' + '0.9.1 <шлях>, modified.»'); continue }
                    $path = ($m.Groups[1].Value -split '\s+')[0]
                    if ($path -match '^([/\\<]|[A-Za-z]:)') { $problems.Add("${rel}:$n — шлях у шапці походження має бути відносним і непорожнім, а там '$path'") }
                }
            }
        }
        return , $problems.ToArray()
    }

    # 6. Бамп версії. Повертає @{ Checked; Reason; Problems }: «не перевірено» — окремий стан, не порожній
    # список знахідок (зелений тест не має означати, що перевірку пропущено).
    function script:Get-KitVersionBumpState([string]$Root) {
        $git = {
            param([string[]]$GitArgs)
            $o = & git -c core.quotepath=off -C $Root @GitArgs 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return (@($o) -join "`n").Trim()
        }
        $skip = { param($why) @{ Checked = $false; Reason = $why; Problems = @() } }
        $planFile = Join-Path $Root '.claude-plugin/plugin.json'
        if (-not (Test-Path -LiteralPath $planFile)) { return @{ Checked = $true; Reason = ''; Problems = @('.claude-plugin/plugin.json — немає файлу') } }
        try { $version = (Get-Content -LiteralPath $planFile -Raw -Encoding UTF8 | ConvertFrom-Json).version }
        catch { return @{ Checked = $true; Reason = ''; Problems = @(".claude-plugin/plugin.json — не читається: $($_.Exception.Message)") } }
        if ("$version" -notmatch '^\d+\.\d+\.\d+$') { return @{ Checked = $true; Reason = ''; Problems = @(".claude-plugin/plugin.json — version '$version' не x.y.z") } }
        if ($null -eq (& $git @('rev-parse', '--git-dir'))) { return & $skip 'не git-репозиторій' }
        if (-not (& $git @('rev-parse', '--verify', '--quiet', 'origin/main'))) { return & $skip 'немає origin/main (git fetch origin)' }
        if ((& $git @('rev-parse', '--abbrev-ref', 'HEAD')) -eq 'main') { return & $skip 'HEAD на main: нема з чим порівнювати гілку' }
        $base = & $git @('merge-base', 'HEAD', 'origin/main')
        if (-not $base) { return & $skip 'немає merge-base з origin/main (у CI потрібен fetch-depth: 0)' }
        # Незакомічені й нові файли теж: перевірку кличуть до коміту.
        $changed = @(@(((& $git @('diff', '--name-only', $base)) -split '\n')) + @(((& $git @('ls-files', '--others', '--exclude-standard')) -split '\n')) |
                Where-Object { $_ } | Select-Object -Unique)
        $consumer = @($changed | Where-Object { $p = $_; @('skills/', 'agents/', 'hooks/', 'tools/', 'templates/', '.claude-plugin/', 'bin/') | Where-Object { $p.StartsWith($_) } })
        if (-not $consumer) { return @{ Checked = $true; Reason = ''; Problems = @() } }
        $mainVersion = '0.0.0'
        try {
            $mv = ((& $git @('show', 'origin/main:.claude-plugin/plugin.json')) | ConvertFrom-Json).version
            if ("$mv" -match '^\d+\.\d+\.\d+$') { $mainVersion = $mv }
        }
        catch { } # зламаний plugin.json у main — тоді будь-яка версія вища
        if ([version]$version -le [version]$mainVersion) {
            $shown = ($consumer | Select-Object -First 3) -join ', '
            if ($consumer.Count -gt 3) { $shown += " +$($consumer.Count - 3)" }
            return @{ Checked = $true; Reason = ''; Problems = @(".claude-plugin/plugin.json — version $version не вища за origin/main $mainVersion, а гілка змінює $shown`: підніміть версію") }
        }
        return @{ Checked = $true; Reason = ''; Problems = @() }
    }

    # Синтетичний скіл-контроль у теці $Root.
    function script:New-KitShapeSkill([string]$Root, [string]$Name, [string]$Frontmatter, [string]$Body = "# $Name`n") {
        $dir = Join-Path $Root "skills/$Name"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value "---`n$Frontmatter`n---`n$Body" -Encoding UTF8
    }

    # Репозиторій-контроль із bare-origin: main з версією 1.0.0, гілка feature змінює skills/x.
    function script:New-KitBumpRepo([string]$Base, [string]$BranchVersion) {
        $origin = Join-Path $Base 'origin.git'
        $work = Join-Path $Base 'work'
        New-Item -ItemType Directory -Path $Base -Force | Out-Null
        git init -q --bare -b main $origin 2>$null
        git init -q -b main $work 2>$null
        New-Item -ItemType Directory -Path (Join-Path $work '.claude-plugin'), (Join-Path $work 'skills/x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work '.claude-plugin/plugin.json') -Value '{ "name": "t", "version": "1.0.0" }' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $work 'skills/x/SKILL.md') -Value 'v1' -Encoding UTF8
        $id = '-c', 'user.name=t', '-c', 'user.email=t@t'
        git -C $work add -A 2>$null
        git -C $work @id commit -q -m base
        git -C $work remote add origin $origin
        git -C $work push -q origin main 2>$null
        git -C $work fetch -q origin 2>$null
        git -C $work checkout -q -b feature
        Set-Content -LiteralPath (Join-Path $work 'skills/x/SKILL.md') -Value 'v2' -Encoding UTF8
        if ($BranchVersion) { Set-Content -LiteralPath (Join-Path $work '.claude-plugin/plugin.json') -Value "{ `"name`": `"t`", `"version`": `"$BranchVersion`" }" -Encoding UTF8 }
        git -C $work add -A 2>$null
        git -C $work @id commit -q -m change
        return $work
    }
}

Describe 'Обгортки команд процесу в bin/' {
    # Без кутових дужок у назві: Pester читає <…> у назві It як шаблон підстановки.
    It 'кожна команда з process-commands.txt має bin/ІМ''Я і bin/ІМ''Я.ps1, bash-обгортки — 100755 в індексі й HEAD' {
        $p = Get-KitWrapperProblems $script:PluginRoot
        $p | Should -BeNullOrEmpty -Because ($p -join '; ')
    }

    It 'контроль: синтетичний репозиторій з обгорткою 100644 і без .ps1 — перевірка падає' {
        $root = Join-Path $TestDrive 'shape-wrappers'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin'), (Join-Path $root 'tools/commands') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'tools/commands/process-commands.txt') -Value "# коментар`nprobe" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'bin/probe') -Value '#!/usr/bin/env bash' -Encoding UTF8
        git -C $root init -q 2>$null
        git -C $root -c core.filemode=false add bin/probe
        $p = Get-KitWrapperProblems $root
        ($p -join "`n") | Should -Match 'bin/probe\.ps1 — немає обгортки'
        ($p -join "`n") | Should -Match 'bin/probe — режим 100644 у індексі'

        # Після правильного рецепта знахідка режиму зникає (а відсутня .ps1 лишається).
        git -C $root update-index --chmod=+x bin/probe
        $p2 = Get-KitWrapperProblems $root
        ($p2 -join "`n") | Should -Not -Match 'режим'
        ($p2 -join "`n") | Should -Match 'bin/probe\.ps1 — немає обгортки'
    }
}

Describe 'Описи скілів і агентів' {
    It 'description кожного скіла й агента не довший за 250 символів' {
        $c = Get-KitViolationClassification (Get-KitDescriptionProblems $script:PluginRoot) 'description' $script:KnownViolators
        Assert-KitViolationVerdict $c
    }

    It 'контроль класифікації: порушник поза переліком — фейл, у переліку — лише відомий, запис без порушення — «прибери»' {
        $problems = @('skills/bad/SKILL.md — description 300', 'skills/old/SKILL.md — description 400')
        $known = @(@{ Skill = 'old'; Check = 'description' }, @{ Skill = 'fixed'; Check = 'description' }, @{ Skill = 'bad'; Check = 'skill-size' })
        $c = Get-KitViolationClassification $problems 'description' $known
        # (а) поза переліком для цієї перевірки (запис bad є лише для skill-size) — Unknown, і вердикт — фейл
        $c.Unknown | Should -Be @('skills/bad/SKILL.md — description 300')
        { Assert-KitViolationVerdict $c } | Should -Throw '*skills/bad*'
        # (б) у переліку — лише Known
        $c.Known | Should -Be @('skills/old/SKILL.md — description 400')
        $only = Get-KitViolationClassification @($problems[1]) 'description' @($known[0])
        $only.Unknown.Count | Should -Be 0
        $only.Stale.Count | Should -Be 0
        $only.Known.Count | Should -Be 1
        # (в) запис без порушення — «прибери»
        $c.Stale | Should -Match 'fixed.*прибери'
        $stale = Get-KitViolationClassification @() 'description' @($known[1])
        { Assert-KitViolationVerdict $stale } | Should -Throw '*прибери*'
    }

    It 'контроль: опис 251 символ — знахідка, 250 — ні, багаторядковий склеюється' {
        $root = Join-Path $TestDrive 'shape-desc'
        New-KitShapeSkill $root 'long' ("name: long`ndescription: " + ('а' * 251))
        New-KitShapeSkill $root 'edge' ("name: edge`ndescription: `"" + ('б' * 250) + '"')
        New-KitShapeSkill $root 'folded' ("name: folded`ndescription: >`n  " + ('в' * 130) + "`n  " + ('в' * 130))
        $p = (Get-KitDescriptionProblems $root) -join "`n"
        $p | Should -Match 'skills/long/SKILL\.md — description 251'
        $p | Should -Not -Match 'skills/edge'
        $p | Should -Match 'skills/folded/SKILL\.md — description 261'
    }
}

Describe 'Агенти: description, model, tools' {
    It 'кожен agents/*.md має description, model і tools (теки може ще не бути)' {
        $p = Get-KitAgentProblems $script:PluginRoot
        $p | Should -BeNullOrEmpty -Because ($p -join '; ')
    }

    It 'контроль: агент без tools і без model — дві знахідки, повний — жодної' {
        $root = Join-Path $TestDrive 'shape-agents'
        New-Item -ItemType Directory -Path (Join-Path $root 'agents') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'agents/bad.md') -Value "---`nname: bad`ndescription: d`n---`nтіло" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'agents/good.md') -Value "---`nname: good`ndescription: d`nmodel: sonnet`ntools: Read, Grep`n---`nтіло" -Encoding UTF8
        $p = (Get-KitAgentProblems $root) -join "`n"
        $p | Should -Match 'agents/bad\.md — немає model:'
        $p | Should -Match 'agents/bad\.md — немає tools:'
        $p | Should -Not -Match 'agents/good'
    }
}

Describe 'Розмір SKILL.md' {
    It 'жоден SKILL.md не більший за 12000 символів' {
        $c = Get-KitViolationClassification (Get-KitSkillSizeProblems $script:PluginRoot) 'skill-size' $script:KnownViolators
        Assert-KitViolationVerdict $c
    }

    It 'контроль: SKILL.md на понад 12000 символів — знахідка' {
        $root = Join-Path $TestDrive 'shape-size'
        New-KitShapeSkill $root 'big' "name: big`ndescription: d" ('х' * 12100)
        New-KitShapeSkill $root 'small' "name: small`ndescription: d"
        $p = (Get-KitSkillSizeProblems $root) -join "`n"
        $p | Should -Match 'skills/big/SKILL\.md'
        $p | Should -Not -Match 'skills/small'
    }
}

Describe 'Команди процесу в зворотних лапках' {
    It 'підкоманди й прапорці з команд у лапках у skills/ і agents/ є в довідці команди' {
        $p = Get-KitCommandUsageProblems $script:PluginRoot
        $p | Should -BeNullOrEmpty -Because ($p -join '; ')
    }

    It 'контроль: неіснуюча підкоманда і неіснуючий прапорець — знахідки; справжні, регістр і плейсхолдери — ні' {
        $root = Join-Path $TestDrive 'shape-cmds'
        $body = 'Дивись `doc nosuchcmd` і `doc anchors -NoSuchFlag`. Справжні: `doc anchors`, `doc find <regex> -max 5`, `doc <файл> 3-9`.' + "`n" +
        'Префікс прапорця: `doc find x -Ma`.' + "`n"
        New-KitShapeSkill $root 'probe' "name: probe`ndescription: d" $body
        $p = Get-KitCommandUsageProblems $root $script:PluginRoot
        $joined = $p -join "`n"
        $joined | Should -Match 'doc nosuchcmd.*немає підкоманди'
        $joined | Should -Match 'doc … -NoSuchFlag'
        $joined | Should -Match 'doc … -Ma.:'
        $p.Count | Should -Be 3 -Because $joined
    }
}

Describe 'Шапка походження' {
    It 'кожен рядок з позначкою порту в tools/ skills/ agents/ hooks/ має форму з відносним шляхом' {
        $p = Get-KitProvenanceProblems $script:PluginRoot
        $p | Should -BeNullOrEmpty -Because ($p -join '; ')
    }

    It 'контроль: шапка без шляху, без «modified» і з абсолютним шляхом — знахідки; правильна — ні' {
        $root = Join-Path $TestDrive 'shape-prov'
        New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null
        $m = 'Ported from agent-kit ' + '0.9.1'
        Set-Content -LiteralPath (Join-Path $root 'tools/ok.ps1') -Value "# $m bin/doc, modified." -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'tools/nopath.ps1') -Value "# $m , modified." -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'tools/nomod.ps1') -Value "# $m bin/doc" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'tools/abs.ps1') -Value "# $m /home/x/bin/doc, modified." -Encoding UTF8
        $p = (Get-KitProvenanceProblems $root) -join "`n"
        $p | Should -Match 'tools/nopath\.ps1:1'
        $p | Should -Match 'tools/nomod\.ps1:1'
        $p | Should -Match 'tools/abs\.ps1:1'
        $p | Should -Not -Match 'tools/ok\.ps1'
    }
}

Describe 'Бамп версії плагіна' {
    It 'версія в plugin.json вища за origin/main, коли гілка змінює файли плагіна (інакше — не перевірено)' {
        $r = Get-KitVersionBumpState $script:PluginRoot
        if (-not $r.Checked) { Set-ItResult -Inconclusive -Because $r.Reason; return }
        $r.Problems | Should -BeNullOrEmpty -Because ($r.Problems -join '; ')
    }

    It 'контроль: та сама версія — знахідка, вища — ні, без origin — стан «не перевірено»' {
        $same = New-KitBumpRepo (Join-Path $TestDrive 'bump-same') ''
        $r = Get-KitVersionBumpState $same
        $r.Checked | Should -BeTrue
        ($r.Problems -join "`n") | Should -Match 'не вища за origin/main 1\.0\.0.*skills/x/SKILL\.md'

        $up = New-KitBumpRepo (Join-Path $TestDrive 'bump-up') '1.0.1'
        $r = Get-KitVersionBumpState $up
        $r.Checked | Should -BeTrue
        $r.Problems | Should -BeNullOrEmpty

        # 1.0.10 проти 1.0.9 у main: порівняння числове, не рядкове (тут main 1.0.0, тож гілка 1.0.10 вища).
        $ten = New-KitBumpRepo (Join-Path $TestDrive 'bump-ten') '1.0.10'
        (Get-KitVersionBumpState $ten).Problems | Should -BeNullOrEmpty

        git -C $up remote remove origin
        git -C $up update-ref -d refs/remotes/origin/main
        $r = Get-KitVersionBumpState $up
        $r.Checked | Should -BeFalse
        $r.Reason | Should -Match 'origin/main'
    }
}
