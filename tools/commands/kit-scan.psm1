#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-scan, modified.
Set-StrictMode -Version Latest

<#
    Механіка протоколу підключення (скіл kit-onboard): знайти в проєкті копії й прототипи частин kit,
    посилання на superpowers і файли пам'яті про процедури, які тепер робить kit. Лише читання: рішення
    по кожному рядку ухвалює агент разом із власником, команда лише дає таблицю-кандидатів.

    Змін проти оригіналу: параметри PowerShell-стилем (-Json, -MinSimilarity, -Memory); таблиці відомих
    залишків — під 1С (скіли v8storagekit замість agent-kit; пошук коду — Уніка й агент researcher);
    частину kit, якої ще немає в плагіні (немає теки skills/<ім'я>, agents/<ім'я>.md чи рядка в
    process-commands.txt), позначено «planned» за фактом наявності, а не за списком; плагін superpowers
    у налаштуваннях проєкту, теки docs/superpowers/ і журнали .superpowers/sdd, .agents/sdd; без графа
    коду, постачальника codebase-memory, перевірки ESLint/Prettier/tsc/vitest, CI path filters і
    перейменувань agent-kit (до v8storagekit вони не стосуються).
#>

$script:MaxFile = 512KB
$script:DefaultMinSimilarity = 0.3
$script:WalkCap = 100000
$script:TextExt = @('.md', '.json', '.jsonc', '.txt', '.yml', '.yaml', '.toml', '.ps1', '.psm1', '.sh', '.py', '.mjs', '.js')

$script:Usage = @"
kit-scan [-Json] [-MinSimilarity <0..1>] [-Memory <тека>]

Скан для підключення проєкту до процесу v8storagekit (скіл kit-onboard). Лише читання: друкує
рядки-кандидати, колонки class/action заповнює агент разом із власником.

  Kit version   kit.version у .agents/kit.profile.json (немає поля — 0.1.0) проти версії плагіна; коли
                проєкт відстав — кроки чеклістів CHANGELOG.md усіх версій після версії проєкту, найстаріша
                першою (рядки V1…Vn)
  Duplicates    .claude/commands|agents|skills і .agents/skills проєкту (та scripts, tools, bin), що
                копіюють чи прототипують частину kit: відомі шляхи, збіг назви або схожість вмісту (шингли)
  Superpowers   `superpowers:<скіл>` у CLAUDE.md, AGENTS.md, .claude/ і .agents/ із заміною з kit;
                увімкнений плагін superpowers у .claude/settings*.json; теки docs/superpowers/;
                журнали .superpowers/sdd/ і .agents/sdd/. «planned» — заміни ще немає в плагіні
  Memory        файли пам'яті проєкту про процедури, які тепер робить kit; прогалини MEMORY.md
  Places        теки <репо>-* і <репо>.* поруч із головним checkout: worktree цього репо, інший git-репо
                чи звичайна тека (її можна перенести в <репо>/.agents/private/)

  -Json            машинний вивід (той самий зміст)
  -MinSimilarity   поріг схожості вмісту, (0, 1], типово $script:DefaultMinSimilarity
  -Memory          тека пам'яті (типово <CLAUDE_CONFIG_DIR|~/.claude>/projects/<slug>/memory)

Вихід: 0 скан відбувся (навіть із рядками); 2 помилка виклику; 3 не git-репозиторій.
"@

# Відомі шляхи: шаблон → частина kit. Регістр значущий.
$script:Known = @(
    , @('^\.claude/commands/discuss\.md$', 'skill discuss')
    , @('^\.claude/commands/проведи-додаткове-дослідження\.md$', 'skill research')
    , @('^\.claude/commands/проаналізуй-кларіфай-питання\.md$', 'skill discuss')
    , @('^\.claude/commands/виконай-задачу\.md$', 'skill execute + sdd')
    , @('^\.claude/commands/перевір-роботу-агента-кодування\.md$', 'skill landed-review')
    , @('^\.claude/commands/архівуй-виконані-задачі\.md$', 'skill close-block')
    , @('^\.claude/commands/ревізія-пам[ʼ'’]?яті\.md$', 'skill kit-onboard (класи пам''яті)')
    , @('(^|/)code-review[\w-]*(/|\.md$)', 'skill landed-review + agent code-reviewer')
    , @('(^|/)codebase-research(/|\.md$)', 'Уніка (unica.search, unica.view) + agent researcher')
    , @('(^|/)map-search\.py$', 'Уніка (unica.search, unica.view) + agent researcher')
)

# Скіли superpowers → частини kit. Ref — що перевіряти на наявність у плагіні (skill:<ім'я>, agent:<ім'я>,
# cmd:<ім'я>); без Ref — не частина плагіна, а правило чи рішення.
$script:SuperpowersMap = @{
    'brainstorming'                  = @(@{ Label = 'v8storagekit:discuss'; Ref = 'skill:discuss' }, @{ Label = 'v8storagekit:spec'; Ref = 'skill:spec' })
    'writing-plans'                  = @(@{ Label = 'v8storagekit:plan'; Ref = 'skill:plan' })
    'executing-plans'                = @(@{ Label = 'v8storagekit:execute'; Ref = 'skill:execute' }, @{ Label = 'sdd'; Ref = 'cmd:sdd' })
    'subagent-driven-development'    = @(@{ Label = 'v8storagekit:execute'; Ref = 'skill:execute' }, @{ Label = 'sdd'; Ref = 'cmd:sdd' })
    'requesting-code-review'         = @(@{ Label = 'v8storagekit:landed-review'; Ref = 'skill:landed-review' }, @{ Label = 'агент v8storagekit:task-reviewer'; Ref = 'agent:task-reviewer' }, @{ Label = 'агент v8storagekit:code-reviewer'; Ref = 'agent:code-reviewer' })
    'receiving-code-review'          = @(@{ Label = 'v8storagekit:landed-review'; Ref = 'skill:landed-review' }, @{ Label = 'агент v8storagekit:task-reviewer'; Ref = 'agent:task-reviewer' }, @{ Label = 'агент v8storagekit:code-reviewer'; Ref = 'agent:code-reviewer' })
    'finishing-a-development-branch' = @(@{ Label = 'v8storagekit:finish (репо з v8storagekit.yaml)'; Ref = 'skill:finish' }, @{ Label = 'або pr-gate'; Ref = 'cmd:pr-gate' })
    'using-git-worktrees'            = @(@{ Label = 'workspace.mode профілю (у 1С shared, без worktree)' })
    'verification-before-completion' = @(@{ Label = 'правило kit: без «готово» без виводу команди, виконаної цього ходу' })
    'test-driven-development'        = @(@{ Label = 'тести — мінімум, форму називає бриф задачі (ADR-0004 відкладено); replace/remove за рішенням власника' })
    'systematic-debugging'           = @(@{ Label = 'частини kit немає (рішення власника) — remove' })
    'dispatching-parallel-agents'    = @(@{ Label = 'частини kit немає (рішення власника) — remove' })
    'using-superpowers'              = @(@{ Label = 'без заміни в проєкті — remove' })
    'writing-skills'                 = @(@{ Label = 'без заміни в проєкті — remove' })
}

# Пам'ять: ознака процедури → що kit робить сам. Лише форми процедур, а не згадки.
$script:MemoryRules = @(
    , @('без worktree|without worktree|без паралельних (виконавців|імплементаторів)|subagent-driven-development', 'v8storagekit:execute (режим shared)')
    , @('субагент\S*[^\n]{0,40}не комітя|subagents? (do not|don''t|never) commit|комітить (лише )?(оркестру|контролер)', 'v8storagekit:execute, агент implementer')
    , @('commit --only|точков\S* коміт|checkout --|git add <', 'правило shared у v8storagekit:execute')
    , @('progress\.md|HANDOFF\.md|\.superpowers/sdd|журнал виконання', 'sdd, .agents/sdd/<блок>/')
    , @('лише зачеплене|повний набір|повний прогін', 'форму тестів називає бриф задачі (ADR-0004 відкладено)')
    , @('архітектор|роль сесі|ролі сесій', 'v8storagekit:architect, track')
    , @('відповід\S* українськ|мова відповід|стиль відповід|respond in ukrainian', 'правила сесії з хука kit')
    , @('superpowers:[\w-]+', 'скіли v8storagekit (superpowers)')
)

# ---------- допоміжне ----------

function Read-ScanText {
    <# Текст файла; $null, коли великий, бінарний чи не читається. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if (-not $fi.Exists -or $fi.Length -gt $script:MaxFile) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes -contains 0) { return $null }
        [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { $null }
}

function Get-ScanFiles {
    <# Файли теки рекурсивно (до Depth рівнів), без node_modules, .git і reparse-точок. #>
    param([Parameter(Mandatory)][string]$Dir, [int]$Depth = 6, [string[]]$SkipDirs = @())
    if ($Depth -lt 0 -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    $entries = try { [System.IO.DirectoryInfo]::new($Dir).GetFileSystemInfos() } catch { @() }
    foreach ($e in ($entries | Sort-Object Name)) {
        if ($e.Name -in @('node_modules', '.git')) { continue }
        if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($SkipDirs -contains $e.Name) { continue }
            Get-ScanFiles -Dir $e.FullName -Depth ($Depth - 1) -SkipDirs $SkipDirs
        } else { $e.FullName }
    }
}

function Get-ScanRel {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    [System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
}

function Get-ScanShingles {
    <# Шингли з трьох слів: мова й форматування мало впливають, збіг тексту — сильно. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $words = @([regex]::Matches($Text.ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormKC), '[\p{L}\p{N}_]+') | ForEach-Object { $_.Value })
    for ($i = 0; $i + 2 -lt $words.Count; $i++) { [void]$set.Add("$($words[$i]) $($words[$i + 1]) $($words[$i + 2])") }
    , $set
}

function Get-ScanContainment {
    <# Частка меншого набору, що є в більшому: копія частини файла теж ловиться. #>
    param($A, $B)
    if ($A.Count -lt 20 -or $B.Count -lt 20) { return 0.0 }
    $small, $big = if ($A.Count -le $B.Count) { $A, $B } else { $B, $A }
    $hit = 0
    foreach ($s in $small) { if ($big.Contains($s)) { $hit++ } }
    $hit / $small.Count
}

function Test-ScanPartExists {
    <# Чи є в плагіні частина, на яку вказує заміна: skill:<ім'я>, agent:<ім'я>, cmd:<ім'я>. #>
    param([Parameter(Mandatory)][string]$Ref)
    $pr = Get-KitPluginRoot
    $kind, $name = $Ref.Split(':', 2)
    switch ($kind) {
        'skill' { Test-Path -LiteralPath (Join-Path $pr "skills/$name") -PathType Container }
        'agent' { Test-Path -LiteralPath (Join-Path $pr "agents/$name.md") -PathType Leaf }
        'cmd' { @(Get-KitProcessCommandNames -ToolsDir (Join-Path $pr 'tools')) -contains $name }
        default { $false }
    }
}

function Get-ScanKitParts {
    <# Частини плагіна: Parts (ім'я → мітка) і Corpus (файл, мітка, шингли) для порівняння вмісту. #>
    $pr = Get-KitPluginRoot
    $parts = @{}
    $corpus = [System.Collections.Generic.List[object]]::new()
    $add = { param($file, $label) $corpus.Add([pscustomobject]@{ File = (Get-ScanRel -Root $pr -Path $file); Part = $label; Sh = (Get-ScanShingles -Text ((Read-ScanText -Path $file) ?? '')) }) }
    $skills = Join-Path $pr 'skills'
    if (Test-Path -LiteralPath $skills -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $skills -Directory | Sort-Object Name)) {
            $parts[$d.Name] = "skill $($d.Name)"
            $f = Join-Path $d.FullName 'SKILL.md'
            if (Test-Path -LiteralPath $f -PathType Leaf) { & $add $f "skill $($d.Name)" }
        }
    }
    $agents = Join-Path $pr 'agents'
    if (Test-Path -LiteralPath $agents -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $agents -Filter '*.md' -File | Sort-Object Name)) {
            $n = $f.BaseName
            $parts[$n] = "agent $n"
            & $add $f.FullName "agent $n"
        }
    }
    foreach ($n in @(Get-KitProcessCommandNames -ToolsDir (Join-Path $pr 'tools'))) {
        $parts[$n] = "bin $n"
        $f = Join-Path $pr "tools/commands/$n.psm1"
        if (Test-Path -LiteralPath $f -PathType Leaf) { & $add $f "bin $n" }
    }
    @{ Parts = $parts; Corpus = $corpus.ToArray() }
}

# ---------- Kit version ----------

function Get-ScanVersion {
    param([Parameter(Mandatory)][string]$Root)
    $info = Get-KitPluginInfo
    $base = [ordered]@{ plugin = $info.Version; project = $null; source = $null; versions = @(); steps = 0; note = $null }
    $res = {
        param($status, $extra)
        $o = [ordered]@{ status = $status }
        foreach ($k in $base.Keys) { $o[$k] = $base[$k] }
        foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
        $o
    }
    if ($info.Problems.Count) {
        return & $res 'changelog-broken' @{ note = "CHANGELOG.md плагіна: $((@($info.Problems | ForEach-Object { "рядок $($_.Line): $($_.What)" })) -join '; ')" }
    }
    if (Test-KitPluginRepo -Root $Root) { return & $res 'kit-repo' @{} }
    $p = Get-KitProjectVersion -Root $Root
    $x = @{ project = $p.Version; source = $p.Source }
    switch ($p.Source) {
        'none' { return & $res 'no-profile' $x }
        'invalid' { $x['note'] = $p.Error; return & $res 'invalid' $x }
    }
    $cmp = Compare-KitVersion -A $p.Version -B $info.Version
    if ($cmp -eq 0) { return & $res 'current' $x }
    if ($cmp -gt 0) { return & $res 'ahead' $x }
    $versions = @(Get-KitPendingEntries -Entries $info.Entries -From $p.Version -To $info.Version | ForEach-Object {
            [ordered]@{ version = $_.Version; date = $_.Date; changes = @($_.Changes); steps = @($_.Steps); noAction = [bool]$_.NoAction }
        })
    $x['versions'] = $versions
    $x['steps'] = [int](($versions | ForEach-Object { $_.steps.Count } | Measure-Object -Sum).Sum)
    & $res 'behind' $x
}

function Get-ScanVersionLines {
    param([Parameter(Mandatory)]$V)
    $head = "проєкт $($V.project)$(if ($V.source -eq 'default') { ' (у профілі немає kit.version — підключено до появи версій)' }), плагін $($V.plugin)"
    switch ($V.status) {
        'kit-repo' { return @("це сам репозиторій плагіна (плагін $($V.plugin)) — версії проєкту немає") }
        'changelog-broken' { return @($V.note) }
        'no-profile' { return @("немає .agents/kit.profile.json — перше підключення; kit-setup запише kit.version $($V.plugin) у новий профіль") }
        'invalid' { return @("$($V.note) — виправ (версія, до якої проєкт востаннє підключено чи оновлено)") }
        'current' { return @("$head — up to date") }
        'ahead' { return @("$head — проєкт новіший за цей плагін: онови плагін (claude plugin update v8storagekit)") }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("${head}: версій $($V.versions.Count), кроків оновлення $($V.steps) — кожен крок є рядком звіту підключення")
    $n = 0
    foreach ($e in $V.versions) {
        $out.Add(''); $out.Add("### $($e.version) — $($e.date)"); $out.Add('')
        if (-not $e.steps.Count) { $out.Add('- дій у проєкті немає') }
        foreach ($s in $e.steps) { $n++; $out.Add("- [ ] V$n $s") }
    }
    $out.Add('')
    $out.Add("останній крок того ж PR: виставити `"kit`": { `"version`": `"$($V.plugin)`" } у .agents/kit.profile.json (що змінилось — CHANGELOG.md плагіна)")
    $out.ToArray()
}

# ---------- Duplicates ----------

function Get-ScanDuplicates {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Kit, [Parameter(Mandatory)][double]$MinSim, [bool]$IsKitRepo)
    $cands = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($dir, $depth, $pick)
        foreach ($f in (Get-ScanFiles -Dir (Join-Path $Root $dir) -Depth $depth)) {
            $rel = Get-ScanRel -Root $Root -Path $f
            if (& $pick $rel) { $cands.Add($rel) }
        }
    }
    $mdOnly = { param($r) $r.EndsWith('.md') }
    $all = { param($r) $true }
    & $add '.claude/commands' 3 $mdOnly
    & $add '.claude/agents' 2 $mdOnly
    & $add '.claude/skills' 4 $all
    & $add '.agents/skills' 4 $all
    & $add 'scripts' 3 $all
    & $add 'tools' 3 $all
    & $add 'bin' 1 $all

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($rel in $cands) {
        if ($IsKitRepo -and $rel -match '^(bin|skills|agents|tools)/') { continue }
        $reasons = [System.Collections.Generic.List[string]]::new()
        $part = $null
        foreach ($k in $script:Known) {
            if ($rel -cmatch $k[0]) { $part = $k[1]; $reasons.Add('відомий дублікат'); break }
        }
        $m = [regex]::Match($rel, '^\.(?:claude|agents)/(?:skills|commands|agents)/([^/]+)')
        $name = if ($m.Success) { $m.Groups[1].Value } else { [System.IO.Path]::GetFileName($rel) }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($name)
        if ($Kit.Parts.ContainsKey($name)) {
            if (-not $part) { $part = $Kit.Parts[$name] }
            $reasons.Add("та сама назва, що в $($Kit.Parts[$name])")
        }
        $text = Read-ScanText -Path (Join-Path $Root $rel)
        if ($text) {
            $sh = Get-ScanShingles -Text $text
            $best = $null
            foreach ($k in $Kit.Corpus) {
                $score = Get-ScanContainment -A $sh -B $k.Sh
                if ($score -ge $MinSim -and (-not $best -or $score -gt $best.Score)) { $best = @{ Score = $score; K = $k } }
            }
            if ($best) {
                if (-not $part) { $part = $best.K.Part }
                $reasons.Add("вміст на $([math]::Round($best.Score * 100))% схожий на $($best.K.File)")
            }
        }
        if (-not $reasons.Count) { continue }
        # Один рядок на каталог скіла, якщо всі його файли мають одну частину.
        $um = [regex]::Match($rel, '^(\.(?:claude|agents)/skills/[^/]+)/')
        $unit = if ($um.Success) { $um.Groups[1].Value } else { $rel }
        $key = "$unit|$part"
        if ($seen.ContainsKey($key) -and $unit -ne $rel) {
            $row = $seen[$key]
            $row.files++
            foreach ($r in $reasons) { if ($row.why -notcontains $r) { $row.why += $r } }
            continue
        }
        $row = [ordered]@{ item = $(if ($unit -eq $rel) { $rel } else { "$unit/" }); files = 1; why = @($reasons); part = $part }
        $seen[$key] = $row
        $rows.Add($row)
    }
    , $rows.ToArray()
}

# ---------- Superpowers ----------

function Get-ScanSuperpowersText {
    <# Тексти, де можуть бути посилання на скіли superpowers: кореневі правила, .claude/**, .agents/** (без вивід-тек). #>
    param([Parameter(Mandatory)][string]$Root)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($f in 'CLAUDE.md', 'AGENTS.md', 'CLAUDE.local.md') {
        if (Test-Path -LiteralPath (Join-Path $Root $f) -PathType Leaf) { $files.Add($f) }
    }
    foreach ($d in '.claude', '.agents') {
        # .claude/worktrees — повні копії репо; .agents/{out,sdd,private,briefs} — вивід і журнали, не правила.
        foreach ($f in (Get-ScanFiles -Dir (Join-Path $Root $d) -Depth 6 -SkipDirs @('worktrees', 'projects'))) {
            $rel = Get-ScanRel -Root $Root -Path $f
            if ($rel -match '^\.agents/(out|sdd|private|briefs)/') { continue }
            if ([System.IO.Path]::GetExtension($rel).ToLowerInvariant() -in $script:TextExt) { $files.Add($rel) }
        }
    }
    , $files.ToArray()
}

function Format-ScanReplacement {
    <# Заміна з kit для скіла superpowers; planned — частин, яких у плагіна ще немає. #>
    param([Parameter(Mandatory)][string]$Skill)
    if (-not $script:SuperpowersMap.ContainsKey($Skill)) { return [pscustomobject]@{ Text = '?'; Planned = @() } }
    $labels = [System.Collections.Generic.List[string]]::new()
    $planned = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $script:SuperpowersMap[$Skill]) {
        if ($p.ContainsKey('Ref') -and -not (Test-ScanPartExists -Ref $p.Ref)) { $planned.Add($p.Label); $labels.Add("$($p.Label) (planned)") }
        else { $labels.Add($p.Label) }
    }
    [pscustomobject]@{ Text = ($labels -join '; '); Planned = $planned.ToArray() }
}

function Get-ScanSuperpowers {
    param([Parameter(Mandatory)][string]$Root)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in (Get-ScanSuperpowersText -Root $Root)) {
        $text = Read-ScanText -Path (Join-Path $Root $rel)
        if (-not $text) { continue }
        $n = 0
        foreach ($line in ($text -split "\r?\n")) {
            $n++
            # Шляхи docs/superpowers/ і .superpowers/ — конвенція; ключ плагіна superpowers@… — окремий розділ.
            $stripped = [regex]::Replace($line, '[\w./-]*\.?superpowers/[\w./-]*', '', 'IgnoreCase')
            $stripped = [regex]::Replace($stripped, 'superpowers@[\w.-]+', '', 'IgnoreCase')
            if ($stripped -notmatch 'superpowers') { continue }
            $skills = @([regex]::Matches($stripped, 'superpowers:([\w-]+)', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Select-Object -Unique)
            $planned = @()
            $by = if ($skills.Count) {
                ($skills | ForEach-Object {
                        $r = Format-ScanReplacement -Skill $_
                        $planned += $r.Planned
                        "$_ → $($r.Text)"
                    }) -join '; '
            } else { 'superpowers (скіл не названо)' }
            $t = $line.Trim()
            $rows.Add([ordered]@{ item = "${rel}:$n"; text = $(if ($t.Length -gt 140) { $t.Substring(0, 140) } else { $t }); part = $by; planned = @($planned | Select-Object -Unique) })
        }
    }
    , $rows.ToArray()
}

function Get-ScanSuperpowersPlugin {
    <# Увімкнений плагін superpowers у налаштуваннях проєкту (enabledPlugins). #>
    param([Parameter(Mandatory)][string]$Root)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in '.claude/settings.json', '.claude/settings.local.json') {
        $text = Read-ScanText -Path (Join-Path $Root $rel)
        if (-not $text) { continue }
        try { $data = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { continue }
        if (-not ($data -is [System.Collections.IDictionary]) -or -not $data.Contains('enabledPlugins')) { continue }
        $ep = $data['enabledPlugins']
        if (-not ($ep -is [System.Collections.IDictionary])) { continue }
        foreach ($k in $ep.Keys) {
            if ($k -match '^superpowers(@|$)' -and $ep[$k] -eq $true) { $rows.Add([ordered]@{ item = $rel; plugin = [string]$k }) }
        }
    }
    , $rows.ToArray()
}

function Get-ScanDirStats {
    <# Файли, розмір і найновіший файл теки без переходу за reparse-точки; межа — WalkCap записів. #>
    param([Parameter(Mandatory)][string]$Dir)
    $bytes = 0L; $files = 0; $newest = [datetime]::MinValue; $seen = 0; $capped = $false
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Dir)
    while ($stack.Count -and -not $capped) {
        $d = $stack.Pop()
        $entries = try { [System.IO.DirectoryInfo]::new($d).GetFileSystemInfos() } catch { @() }
        foreach ($e in $entries) {
            if (++$seen -gt $script:WalkCap) { $capped = $true; break }
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e.FullName) }
            else {
                $bytes += $e.Length; $files++
                if ($e.LastWriteTimeUtc -gt $newest) { $newest = $e.LastWriteTimeUtc }
            }
        }
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Newest = $(if ($files) { $newest } else { $null }); Capped = $capped }
}

function Get-ScanSuperpowersDocs {
    <# Теки docs/superpowers/<specs|plans|handoff|…>: скільки файлів. Вони лишаються конвенцією проєкту. #>
    param([Parameter(Mandatory)][string]$Root)
    $base = Join-Path $Root 'docs/superpowers'
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return , @() }
    foreach ($d in (Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name)) {
        $st = Get-ScanDirStats -Dir $d.FullName
        $rows.Add([ordered]@{ item = "docs/superpowers/$($d.Name)/"; files = $st.Files; newest = $(if ($st.Newest) { $st.Newest.ToString('yyyy-MM-dd') } else { $null }) })
    }
    $loose = @(Get-ChildItem -LiteralPath $base -File)
    if ($loose.Count) { $rows.Add([ordered]@{ item = 'docs/superpowers/'; files = $loose.Count; newest = ($loose | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).LastWriteTimeUtc.ToString('yyyy-MM-dd') }) }
    , $rows.ToArray()
}

function Get-ScanJournals {
    <# Журнали виконання: .superpowers/sdd/<блок>/progress.md (старі) і .agents/sdd/ (нові); закрито — є рядок `# closed `. #>
    param([Parameter(Mandatory)][string[]]$Roots)
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($r in $Roots) {
        foreach ($dir in '.superpowers/sdd', '.agents/sdd') {
            $abs = Join-Path $r $dir
            if ($seen.ContainsKey($abs) -or -not (Test-Path -LiteralPath $abs -PathType Container)) { continue }
            $seen[$abs] = $true
            $closed = 0; $open = 0
            foreach ($b in (Get-ChildItem -LiteralPath $abs -Directory)) {
                $f = Join-Path $b.FullName 'progress.md'
                if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
                $t = Read-ScanText -Path $f
                if ($t -match '(?m)^# closed ') { $closed++ } else { $open++ }
            }
            if ($closed + $open) { $rows.Add([ordered]@{ dir = "$dir/"; closed = $closed; open = $open }) }
        }
    }
    , $rows.ToArray()
}

# ---------- Memory ----------

function Get-ScanMemoryDir {
    param([Parameter(Mandatory)][string[]]$Roots)
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $dirs = @($Roots | ForEach-Object { Join-Path (Join-Path (Join-Path $cfg 'projects') ($_ -replace '[^a-zA-Z0-9]', '-')) 'memory' })
    $found = $dirs | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if ($found) { $found } else { $dirs[0] }
}

function Get-ScanMemory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Dir)
    $res = [ordered]@{ dir = $Dir; missing = $false; total = 0; rows = @(); staleOnly = @(); index = @() }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { $res['missing'] = $true; return $res }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File | Where-Object { $_.Name -ne 'MEMORY.md' } | Sort-Object Name)
    $indexText = Read-ScanText -Path (Join-Path $Dir 'MEMORY.md')
    $rows = [System.Collections.Generic.List[object]]::new()
    $staleOnly = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        $text = (Read-ScanText -Path $f.FullName) ?? ''
        $tools = @($script:MemoryRules | Where-Object { $text -match $_[0] } | ForEach-Object { $_[1] } | Select-Object -Unique)
        # Шляхи репо в бектиках, яких уже немає: ознака застарілої пам'яті.
        $stale = @([regex]::Matches($text, '`([\w.-]+(?:/[\w.@-]+)+\.[a-z]{1,5})`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
                Where-Object { -not $_.StartsWith('~') -and -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
        if ($tools.Count) { $rows.Add([ordered]@{ item = $f.Name; part = ($tools -join ', '); stale = @($stale | Select-Object -First 3); staleCount = $stale.Count }) }
        elseif ($stale.Count) { $staleOnly.Add($f.Name) }
    }
    $index = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $indexText) { $index.Add('MEMORY.md відсутній') }
    else {
        foreach ($f in $files) { if (-not $indexText.Contains($f.Name)) { $index.Add("немає в MEMORY.md: $($f.Name)") } }
        foreach ($m in [regex]::Matches($indexText, '\]\(([^)]+\.md)\)')) {
            $link = $m.Groups[1].Value
            if ($link -notmatch '^[a-z]+://' -and -not (Test-Path -LiteralPath (Join-Path $Dir $link))) { $index.Add("MEMORY.md вказує на неіснуючий файл: $link") }
        }
    }
    $res['total'] = $files.Count
    $res['rows'] = $rows.ToArray()
    $res['staleOnly'] = $staleOnly.ToArray()
    $res['index'] = $index.ToArray()
    $res
}

# ---------- Places ----------

function Get-ScanNormPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = [System.IO.Path]::GetFullPath($Path) -replace '\\', '/'
    $p = $p.TrimEnd('/')
    if ($IsWindows) { $p.ToLowerInvariant() } else { $p }
}

function Get-ScanWorktrees {
    <# git worktree list --porcelain головного checkout → нормалізований шлях → гілка (або $null). #>
    param([Parameter(Mandatory)][string]$Main)
    $map = @{}
    $lines = & git -C $Main worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return $map }
    $cur = $null
    foreach ($l in $lines) {
        if ($l.StartsWith('worktree ')) { $cur = Get-ScanNormPath $l.Substring(9); $map[$cur] = $null }
        elseif ($l.StartsWith('branch ') -and $cur) { $map[$cur] = $l.Substring(7) -replace '^refs/heads/', '' }
    }
    $map
}

function Format-ScanSize {
    param([long]$Bytes)
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $n = [double]$Bytes; $i = 0
    while ($n -ge 1024 -and $i -lt $units.Count - 1) { $n /= 1024; $i++ }
    if ($i) { '{0:N1} {1}' -f $n, $units[$i] } else { "$Bytes B" }
}

function Get-ScanPlaces {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Main)
    $privateDir = '.agents/private'
    $outside = @()
    try {
        $prof = (Get-KitProfile -RepoRoot $Root).Data
        $pd = if ($prof.Contains('private') -and $prof['private'] -is [System.Collections.IDictionary]) { $prof['private'] } else { @{} }
        if ($pd.Contains('dir') -and $pd['dir']) { $privateDir = Resolve-KitInsidePath -Value ([string]$pd['dir']) -Field 'private.dir' }
        if ($pd.Contains('outside') -and $pd['outside'] -is [System.Collections.IEnumerable]) { $outside = @($pd['outside'] | Where-Object { $_ -is [string] }) }
    } catch { }
    $name = Split-Path -Leaf $Main
    $parent = Split-Path -Parent $Main
    $prefixes = @(@($name, $name.ToLowerInvariant()) | Select-Object -Unique | ForEach-Object { "$_-"; "$_." })
    $wts = Get-ScanWorktrees -Main $Main
    $mainN = Get-ScanNormPath $Main
    $mainGit = "$mainN/.git"
    $found = [ordered]@{}
    foreach ($e in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        foreach ($p in $prefixes) { if ($e.Name.StartsWith($p)) { $found[$e.FullName] = 'name'; break } }
    }
    foreach ($o in $outside) {
        $abs = [System.IO.Path]::GetFullPath((Join-Path $parent $o))
        if (Test-Path -LiteralPath $abs -PathType Container) { $found[$abs] = 'profile' }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($abs in $found.Keys) {
        $n = Get-ScanNormPath $abs
        if ($n -eq $mainN -or $n.StartsWith("$mainN/") -or $n -eq (Get-ScanNormPath $Root)) { continue }
        $branch = $null
        if ($wts.ContainsKey($n)) { $kind = 'worktree'; $branch = $wts[$n] }
        else {
            $dotGit = Join-Path $abs '.git'
            if (Test-Path -LiteralPath $dotGit -PathType Container) { $kind = 'repo' }
            elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
                $gt = (Read-ScanText -Path $dotGit) ?? ''
                $kind = if ((($gt -replace '\\', '/').ToLowerInvariant()).Contains("$mainGit/worktrees/".ToLowerInvariant())) { 'stale-worktree' } else { 'repo' }
            } else { $kind = 'plain' }
        }
        $st = Get-ScanDirStats -Dir $abs
        $stripped = Split-Path -Leaf $abs
        foreach ($p in $prefixes) { if ($stripped.StartsWith($p)) { $stripped = $stripped.Substring($p.Length); break } }
        $target = "$privateDir/$(if (-not $stripped -or $stripped -eq 'private') { Split-Path -Leaf $abs } else { $stripped })"
        $recent = $st.Newest -and (([datetime]::UtcNow - $st.Newest).TotalHours -lt 24)
        $rows.Add([ordered]@{
                path = ($abs -replace '\\', '/'); why = $found[$abs]; kind = $kind; branch = $branch
                bytes = $st.Bytes; capped = $st.Capped; newest = $(if ($st.Newest) { $st.Newest.ToString('yyyy-MM-dd') } else { $null })
                recent = [bool]$recent; target = $target
            })
    }
    [ordered]@{ main = ($Main -replace '\\', '/'); privateDir = $privateDir; rows = $rows.ToArray() }
}

function Format-ScanQuoted {
    param([string]$Path)
    if ($Path -match '\s') { "`"$Path`"" } else { $Path }
}

function Get-ScanPlaceAction {
    param($Row, [string]$Main)
    switch ($Row.kind) {
        'worktree' { "leave; зникне через pr-gate cleanup $(Format-ScanQuoted $Row.path), коли блок закінчиться" }
        'stale-worktree' { 'leave; запис його worktree зник (git worktree prune), перевір вручну' }
        'repo' { 'leave; окремий git-репозиторій: перевір вручну, kit його не переносить' }
        default {
            $dst = "$Main/$($Row.target)"
            $tail = if ($Row.recent) { '; змінено за останні 24 год: спитай, чи працює там сесія (session-board)' } else { '' }
            $dstDir = $dst.Substring(0, $dst.LastIndexOf('/'))
            "move після схвалення: mkdir -p $(Format-ScanQuoted $dstDir) && mv $(Format-ScanQuoted $Row.path) $(Format-ScanQuoted $dst)$tail"
        }
    }
}

# ---------- вивід ----------

function ConvertTo-ScanCell {
    param($Text)
    ([string]$Text) -replace '\|', '\|' -replace '\r?\n', ' '
}

function Write-ScanMarkdown {
    param($Root, $Version, $Dup, $Sp, $SpPlugin, $SpDocs, $Journals, $Mem, $Places)
    $o = [System.Collections.Generic.List[string]]::new()
    $o.Add("kit-scan: $Root")
    $o.Add("memory: $($Mem.dir)$(if ($Mem.missing) { ' (немає)' } else { " ($($Mem.total) файлів)" })")
    $o.Add('')
    $o.Add('## Kit version'); $o.Add('')
    foreach ($l in (Get-ScanVersionLines -V $Version)) { $o.Add($l) }
    $o.Add('')
    $o.Add("## Duplicates and prototypes ($($Dup.Count))"); $o.Add('')
    $o.Add('| # | item | why | kit part | class | action |'); $o.Add('| --- | --- | --- | --- | --- | --- |')
    for ($i = 0; $i -lt $Dup.Count; $i++) {
        $r = $Dup[$i]
        $o.Add("| D$($i + 1) | ``$(ConvertTo-ScanCell $r.item)``$(if ($r.files -gt 1) { " ($($r.files) файлів)" }) | $(ConvertTo-ScanCell ($r.why -join '; ')) | $(ConvertTo-ScanCell $r.part) | ? | ? |")
    }
    $o.Add('')
    $o.Add("## Superpowers references ($($Sp.Count))"); $o.Add('')
    $o.Add('| # | item | text | kit part | class | action |'); $o.Add('| --- | --- | --- | --- | --- | --- |')
    for ($i = 0; $i -lt $Sp.Count; $i++) {
        $r = $Sp[$i]
        $o.Add("| S$($i + 1) | ``$(ConvertTo-ScanCell $r.item)`` | $(ConvertTo-ScanCell $r.text) | $(ConvertTo-ScanCell $r.part) | ? | ? |")
    }
    if (@($Sp | Where-Object { $_.planned.Count }).Count) {
        $o.Add(''); $o.Add('planned — частини kit, на які вказує заміна, ще немає в плагіні: такий рядок — клас keep (познач issue, що її замінить).')
    }
    $o.Add('')
    $o.Add("## Superpowers plugin ($($SpPlugin.Count))"); $o.Add('')
    if ($SpPlugin.Count) { foreach ($r in $SpPlugin) { $o.Add("- ``$($r.item)``: enabledPlugins вмикає $($r.plugin) — вимкни після заміни посилань") } }
    else { $o.Add('- плагін superpowers у налаштуваннях проєкту не ввімкнено') }
    $o.Add('')
    $o.Add("## Superpowers files ($($SpDocs.Count))"); $o.Add('')
    if ($SpDocs.Count) { foreach ($r in $SpDocs) { $o.Add("- ``$($r.item)``: $($r.files) файлів$(if ($r.newest) { ", найновіший $($r.newest)" }) — живі лишаються (шлях у docs.specs / docs.plans), завершені — через close-block") } }
    else { $o.Add('- docs/superpowers/ немає') }
    if ($Journals.Count) {
        $o.Add(''); $o.Add('## Journals'); $o.Add('')
        foreach ($j in $Journals) { $o.Add("- журнали ($($j.dir)): $($j.closed) закритих, $($j.open) відкритих — старі читаються на місці, закриті прибирає close-block; нові плани пишуть у .agents/sdd/") }
    }
    $o.Add('')
    $o.Add("## Memory ($($Mem.rows.Count))"); $o.Add('')
    $o.Add('| # | file | covered by | stale paths | class | action |'); $o.Add('| --- | --- | --- | --- | --- | --- |')
    for ($i = 0; $i -lt $Mem.rows.Count; $i++) {
        $r = $Mem.rows[$i]
        $stale = if ($r.staleCount) { "$($r.stale -join ', ')$(if ($r.staleCount -gt 3) { " +$($r.staleCount - 3)" })" } else { '' }
        $o.Add("| M$($i + 1) | ``$(ConvertTo-ScanCell $r.item)`` | $(ConvertTo-ScanCell $r.part) | $(ConvertTo-ScanCell $stale) | ? | ? |")
    }
    if ($Mem.staleOnly.Count) {
        $names = ($Mem.staleOnly | ForEach-Object { '`' + $_ + '`' }) -join ', '
        $o.Add(''); $o.Add("Лише застарілі шляхи репо, процедури kit немає ($($Mem.staleOnly.Count); ймовірно історія): $names")
    }
    if ($Mem.index.Count) {
        $o.Add(''); $o.Add('## Memory index'); $o.Add('')
        foreach ($l in $Mem.index) { $o.Add("- $l") }
    }
    $o.Add('')
    $o.Add("## Places outside the repo ($($Places.rows.Count))"); $o.Add('')
    if ($Places.rows.Count) {
        $label = @{ worktree = 'git worktree цього репо'; 'stale-worktree' = 'застарілий worktree цього репо'; repo = 'інший git-репозиторій'; plain = 'звичайна тека' }
        $o.Add('| # | place | kind | size | newest file | action |'); $o.Add('| --- | --- | --- | --- | --- | --- |')
        for ($i = 0; $i -lt $Places.rows.Count; $i++) {
            $r = $Places.rows[$i]
            $kind = "$($label[$r.kind])$(if ($r.kind -eq 'worktree') { " ($(if ($r.branch) { $r.branch } else { 'detached' }))" })"
            $o.Add("| P$($i + 1) | ``$(ConvertTo-ScanCell $r.path)``$(if ($r.why -eq 'profile') { ' (profile)' }) | $kind | $(if ($r.capped) { '≥ ' })$(Format-ScanSize $r.bytes) | $(if ($r.newest) { $r.newest } else { '-' }) | $(ConvertTo-ScanCell (Get-ScanPlaceAction -Row $r -Main $Places.main)) |")
        }
    } else { $o.Add("- немає: жодної теки <$(Split-Path -Leaf $Places.main)>-… чи <$(Split-Path -Leaf $Places.main)>.… поруч із головним checkout, private.outside у профілі порожній") }
    $o.Add('')
    $o.Add('Classes — duplicates: remove | keep-knowledge (перенести в проєктний файл, який читає kit) | keep + kit issue (retro); superpowers: replace | remove | keep (planned); memory: pointer | delete | keep-as-history | move-to-profile; places: move | leave.')
    $o.ToArray()
}

# ---------- команда ----------

function Invoke-KitKitScan {
    param([AllowEmptyCollection()][string[]]$Arguments = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{ Json = 'switch'; MinSimilarity = 'string'; Memory = 'string' }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    if ($a.Positional.Count) { throw (New-KitUsageError "неочікуваний аргумент '$($a.Positional[0])'") }
    $minSim = $script:DefaultMinSimilarity
    if ($a.Named.ContainsKey('MinSimilarity')) {
        $parsed = 0.0
        if (-not [double]::TryParse([string]$a.Named['MinSimilarity'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or -not ($parsed -gt 0 -and $parsed -le 1)) {
            throw (New-KitUsageError '-MinSimilarity має бути числом з (0, 1]')
        }
        $minSim = $parsed
    }
    $root = Get-KitCheckoutRoot -Path $RepoRoot
    $main = Get-KitMainRoot -Path $root
    $isKitRepo = Test-KitPluginRepo -Root $root

    $kit = Get-ScanKitParts
    $version = Get-ScanVersion -Root $root
    $dup = Get-ScanDuplicates -Root $root -Kit $kit -MinSim $minSim -IsKitRepo $isKitRepo
    $sp = Get-ScanSuperpowers -Root $root
    $spPlugin = Get-ScanSuperpowersPlugin -Root $root
    $spDocs = Get-ScanSuperpowersDocs -Root $root
    $journals = Get-ScanJournals -Roots @(@($main, $root) | Select-Object -Unique)
    $memDir = if ($a.Named.ContainsKey('Memory')) { [System.IO.Path]::GetFullPath([string]$a.Named['Memory']) } else { Get-ScanMemoryDir -Roots @(@($root, $main) | Select-Object -Unique) }
    $mem = Get-ScanMemory -Root $root -Dir $memDir
    $places = Get-ScanPlaces -Root $root -Main $main

    if ($a.Named['Json']) {
        $doc = [ordered]@{
            root = ($root -replace '\\', '/'); kitVersion = $version; duplicates = $dup; superpowers = $sp
            superpowersPlugin = $spPlugin; superpowersDocs = $spDocs; journals = $journals; memory = $mem; places = $places
        }
        Write-KitLine (ConvertTo-Json -InputObject $doc -Depth 10)
    } else {
        foreach ($l in (Write-ScanMarkdown -Root ($root -replace '\\', '/') -Version $version -Dup $dup -Sp $sp -SpPlugin $spPlugin -SpDocs $spDocs -Journals $journals -Mem $mem -Places $places)) { Write-KitLine $l }
        Write-KitNext 'kit-setup -DryRun'
    }
    return 0
}

Export-ModuleMember -Function Invoke-KitKitScan
