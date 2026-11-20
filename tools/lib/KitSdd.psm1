#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/sdd, lib/sdd.mjs, modified.
<#
    Механіка виконання плану: робоча тека, бриф задачі, журнал. Формат журналу — як у портованого
    SDD 7.0.1 (`<plan>/progress.md`, `task-N-brief.md`), щоб журнали, початі під SDD (superpowers
    і стара тека .superpowers/sdd), читались і далі без міграції. Тому граматика журналу
    англійська й байт у байт та сама, що в оригіналі.

    Усі регулярні вирази тут ЧУТЛИВІ до регістру (`review` ≠ `Review`, `BASE` ≠ `base`): це
    .NET-регекси без IgnoreCase, а не `-match`, який у PowerShell нечутливий. Класи `\d`/`\w`
    замінено на ASCII-діапазони, а межі слова `\b` — на ASCII-lookaround (`(?<![A-Za-z0-9_])`,
    `(?![A-Za-z0-9_])`): у .NET `\w` і `\b` юнікодні, у JS ASCII, тож без цього «### Задача 2а» (кирилична
    літера після номера) в оригіналі дає задачу 2, а в переносі задача зникла б.
#>
Set-StrictMode -Version Latest

$script:LedgerName = 'progress.md'
$script:LedgerHead = '# SDD ledger — plan: '
$script:BindFile = 'checkout'
# Номер задачі — не лише число: плани й контролери додають підзадачі «1c», «5b», «3.2».
$script:TaskIdPattern = '[0-9]+(?:\.[0-9]+)*[a-z]?'
$script:IdExact = [regex]::new('^' + $script:TaskIdPattern + '\z')
# «## Задача 3», «### Task 1c: …», «### Tasks 7–13: …» (діапазон — одна секція на кілька задач).
# \b у .NET юнікодний, у JS — ASCII: «Задача 2а» мусить давати задачу 2, тож межа слова — явна ASCII-версія.
$script:WordBoundary = '(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))'
$script:DefaultTaskHeading = '^(#{2,4})\s+(?:Задачі|Задача|Tasks|Task)\s+(' + $script:TaskIdPattern + ')(?:\s*[–—-]\s*([0-9]+))?' + $script:WordBoundary
$script:DefaultBriefSections = @('Global Constraints', 'Глобальні обмеження', 'Рішення', 'Decisions', 'Інтерфейси', 'Interfaces')
$script:States = @('dispatched', 'code', 'review', 'fix', 'complete', 'parked', 'blocked', 'needs-context', 'fork', 'skipped')
$script:Terminal = @('complete', 'skipped')
$script:OpenStates = @('blocked', 'needs-context', 'fork', 'parked')
# Задача, над якою зараз працює implementer: від її BASE рахуються «її» зміни.
$script:InWork = @('dispatched', 'review', 'fix')

$script:Sha = '[0-9a-f]{7,40}'
$script:CommitsRe = [regex]::new('(?<![A-Za-z0-9_])commits (' + $script:Sha + '\.\.' + $script:Sha + '(?:,' + $script:Sha + '\.\.' + $script:Sha + ')*)')
$script:CodeRe = [regex]::new('(?<![A-Za-z0-9_])(' + $script:Sha + '\.\.' + $script:Sha + ')')
$script:WindowRow = [regex]::new('^Window \(task (' + $script:TaskIdPattern + ')\): (open|close) (' + $script:Sha + ') at (\S+?)(?:; report ([0-9]+))?(?: — .*)?$')
$script:RulingRow = [regex]::new('^Ruling \(task (' + $script:TaskIdPattern + ')\): (.*)$')
$script:SplitRow = [regex]::new('(?=(?<![A-Za-z0-9_])Task ' + $script:TaskIdPattern + ': )')
$script:StateRow = [regex]::new('^Task (' + $script:TaskIdPattern + '): ([a-z][a-z-]*)(?: (?:round )?([0-9]+)(?:\/[0-9]+)?)?' + $script:WordBoundary + '(.*)$')
$script:BaseRe = [regex]::new('(?<![A-Za-z0-9_])(?:base|BASE) (' + $script:Sha + ')(?![A-Za-z0-9_])')

# ---------- константи для команди ----------

function Get-KitSddLedgerName { $script:LedgerName }
function Get-KitSddLedgerHead { $script:LedgerHead }
function Get-KitSddStates { $script:States }
function Get-KitSddBindName { $script:BindFile }
function Get-KitSddDefaults { @{ TaskHeading = $script:DefaultTaskHeading; BriefSections = $script:DefaultBriefSections } }

# ---------- ідентифікатори задач ----------

function Test-KitSddTaskId {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    [bool]($Value -and $script:IdExact.IsMatch($Value))
}

function Test-KitSddInt {
    param([AllowNull()][string]$Value)
    [bool]($Value -and [regex]::IsMatch($Value, '^[0-9]+\z'))
}

function Compare-KitSddIds {
    <# Природний порядок: 1 < 1b < 1c < 2 < 3.2 < 10. Підзадача-літера ближча до батьківської, ніж «3.2». #>
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $pa = @([regex]::Matches($A, '[0-9]+|[a-z]+') | ForEach-Object { $_.Value })
    $pb = @([regex]::Matches($B, '[0-9]+|[a-z]+') | ForEach-Object { $_.Value })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -ge $pa.Count) { return -1 }
        if ($i -ge $pb.Count) { return 1 }
        $na = $pa[$i][0] -ge [char]'0' -and $pa[$i][0] -le [char]'9'
        $nb = $pb[$i][0] -ge [char]'0' -and $pb[$i][0] -le [char]'9'
        if ($na -and $nb) {
            $x = [System.Numerics.BigInteger]::Parse($pa[$i])
            $y = [System.Numerics.BigInteger]::Parse($pb[$i])
            if ($x -ne $y) { return $(if ($x -lt $y) { -1 } else { 1 }) }
        }
        if ($na -ne $nb) { return $(if ($na) { 1 } else { -1 }) }
        $c = [string]::CompareOrdinal($pa[$i], $pb[$i])
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    0
}

function Get-KitSddSortedIds {
    <# Сортує номери задач природним порядком. Викликач обгортає результат у @(). #>
    param([AllowEmptyCollection()][string[]]$Ids = @())
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($i in $Ids) { $list.Add($i) }
    $list.Sort([Comparison[string]] { param($a, $b) Compare-KitSddIds -A $a -B $b })
    $list.ToArray()
}

# ---------- шляхи: ідентичність плану, робоча тека ----------

function Test-KitSddSamePath {
    <# Порівняння шляхів без урахування регістру (Windows) і форми роздільників. #>
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $norm = { param($p) ([System.IO.Path]::GetFullPath($p) -replace '\\', '/').TrimEnd('/') }
    [string]::Equals((& $norm $A), (& $norm $B), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-KitSddOnDiskPath {
    <# Абсолютний шлях із регістром кожного наявного сегмента, як він записаний на диску; решта — як є. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $cur = $root
    foreach ($seg in ($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $hit = $null
        if ($seg.IndexOfAny([char[]]'*?') -lt 0 -and (Test-Path -LiteralPath $cur -PathType Container)) {
            $hit = [System.IO.Directory]::EnumerateFileSystemEntries($cur, $seg) | Select-Object -First 1
        }
        $cur = if ($hit) { $hit } else { Join-Path $cur $seg }
    }
    $cur
}

function Get-KitSddPlanInfo {
    <#
    .SYNOPSIS
        Ідентичність плану: Id — шлях відносно кореня його checkout з `/` (однаковий у worktree й у
        головному), Path — канонічний абсолютний шлях, Checkout — корінь checkout плану.
    .DESCRIPTION
        Префікс шляху бере сам git (`rev-parse --show-prefix`), а не віднімання рядків: тека може
        бути задана в короткій (8.3) або іншій формі, ніж повертає `--show-toplevel`.
    #>
    param([Parameter(Mandatory)][string]$Plan)
    # Регістр — з диска, а не з того, як шлях набрали: на Windows `DOCS\Plan.md` і `docs/plan.md` —
    # той самий файл, і інша ідентичність дала б йому другий, паралельний журнал (без «complete не
    # диспетчеризують» і зі свіжим BASE).
    $abs = Get-KitSddOnDiskPath -Path $Plan
    $dir = Split-Path -Parent $abs
    $checkout = Get-KitCheckoutRoot -Path $dir
    $prefix = (Invoke-KitGit -Root $dir -Arguments @('rev-parse', '--show-prefix')).Out.Trim()
    $id = $prefix + (Split-Path -Leaf $abs)
    [pscustomobject]@{
        Id       = $id
        Path     = [System.IO.Path]::GetFullPath((Join-Path $checkout $id))
        Checkout = $checkout
    }
}

function Get-KitSddJournalBases {
    <# Теки журналів головного checkout у порядку пріоритету: нова (.agents/sdd), потім стара (.superpowers/sdd). #>
    param([Parameter(Mandatory)][string]$MainRoot)
    @((Join-Path $MainRoot '.agents/sdd'), (Join-Path $MainRoot '.superpowers/sdd'))
}

function Get-KitSddWorkspace {
    <#
    .SYNOPSIS
        Робоча тека плану в ГОЛОВНОМУ checkout: переживає `git worktree remove`, і наступний план
        із будь-якої копії бачить борг попереднього.
    .DESCRIPTION
        Колізія імен — як у SDD: маркер `plan-path` з ідентичністю плану, потім ім'я батьківського
        каталогу. Нова тека має пріоритет; стара (.superpowers/sdd) — лише коли журнал плану вже
        там: нові плани туди не пишуть, перенесення немає.
        Повертає Dir (або $null, якщо теки ще немає й не -Create), Id, Base, Legacy, WouldBe.
    #>
    param([Parameter(Mandatory)][string]$Plan, [switch]$Create)
    $info = Get-KitSddPlanInfo -Plan $Plan
    $planDir = Split-Path -Parent $info.Path
    $main = Get-KitMainRoot -Path $planDir
    $base, $legacy = Get-KitSddJournalBases -MainRoot $main
    $leaf = Split-Path -Leaf $info.Path
    $slug = if ($leaf.EndsWith('.md', [System.StringComparison]::Ordinal)) { $leaf.Substring(0, $leaf.Length - 3) } else { $leaf }
    $parent = Split-Path -Leaf $planDir
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($slug)
    $candidates.Add("$slug-$parent")
    for ($n = 2; $n -lt 50; $n++) { $candidates.Add("$slug-$parent-$n") }

    # Тека цього плану в `b`: маркер з тим самим id, або стара тека SDD без маркера на першому
    # вільному місці (приймаємо, як і раніше).
    $find = {
        param([string]$b)
        foreach ($c in $candidates) {
            $dir = Join-Path $b $c
            $marker = Join-Path $dir 'plan-path'
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                # Без регістру: тека, заведена під іншим написанням того самого файлу, — його тека.
                $markerId = [System.IO.File]::ReadAllText($marker).Trim()
                if ([string]::Equals($markerId, $info.Id, [System.StringComparison]::OrdinalIgnoreCase)) { $script:SddMarkerId = $markerId; return $dir }
                continue
            }
            if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
            return $null
        }
        $null
    }
    # Id — як записано в наявному маркері: з ним збігається шапка журналу.
    $script:SddMarkerId = $null
    $own = & $find $base
    if ($own) { return [pscustomobject]@{ Dir = $own; Id = ($script:SddMarkerId ?? $info.Id); Base = $base; Legacy = $false; WouldBe = $null } }
    $old = & $find $legacy
    if ($old) { return [pscustomobject]@{ Dir = $old; Id = ($script:SddMarkerId ?? $info.Id); Base = $legacy; Legacy = $true; WouldBe = $null } }
    $free = $candidates | ForEach-Object { Join-Path $base $_ } | Where-Object { -not (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $free) { throw "немає вільного місця для робочої теки $($info.Id)" }
    if (-not $Create) { return [pscustomobject]@{ Dir = $null; Id = $info.Id; Base = $base; Legacy = $false; WouldBe = $free } }
    # Тека `.agents/sdd` із `.gitignore` на `*` — журнал не потрапить у коміт.
    $null = Get-KitAgentsDir -Name sdd -RepoRoot $planDir -Create
    New-Item -ItemType Directory -Path $free -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $free 'plan-path'), "$($info.Id)`n", [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Dir = $free; Id = $info.Id; Base = $base; Legacy = $false; WouldBe = $null }
}

function Get-KitSddLegacyJournals {
    <# Старі журнали для звіту сканування: скільки закрито, скільки ще відкрито. #>
    param([Parameter(Mandatory)][string]$MainRoot)
    $dir = (Get-KitSddJournalBases -MainRoot $MainRoot)[1]
    $res = [pscustomobject]@{ Dir = '.superpowers/sdd'; Closed = 0; Open = 0 }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $res }
    foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory)) {
        $file = Join-Path $d.FullName $script:LedgerName
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        if ((ConvertFrom-KitSddLedger -Text ([System.IO.File]::ReadAllText($file))).Closed) { $res.Closed++ } else { $res.Open++ }
    }
    $res
}

# ---------- план: заголовки, секції, задачі, бриф ----------

function Get-KitSddHeadings {
    <# Заголовки поза блоками коду: Level, Text, Line (індекс рядка). #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $out = [System.Collections.Generic.List[object]]::new()
    $fence = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $f = [regex]::Match($Lines[$i], '^\s*(`{3,}|~{3,})')
        if ($f.Success) {
            $ch = $f.Groups[1].Value[0]
            if ($null -eq $fence) { $fence = $ch } elseif ($ch -eq $fence) { $fence = $null }
            continue
        }
        if ($null -ne $fence) { continue }
        $h = [regex]::Match($Lines[$i], '^(#{1,6})\s+(.*?)\s*#*\s*$')
        if ($h.Success) { $out.Add([pscustomobject]@{ Level = $h.Groups[1].Length; Text = $h.Groups[2].Value; Line = $i }) }
    }
    $out.ToArray()
}

function Get-KitSddSection {
    <# Секція від заголовка до наступного заголовка того самого чи вищого рівня. #>
    param([string[]]$Lines, [object[]]$Headings, [int]$Index)
    $h = $Headings[$Index]
    $next = $null
    for ($j = $Index + 1; $j -lt $Headings.Count; $j++) { if ($Headings[$j].Level -le $h.Level) { $next = $Headings[$j]; break } }
    $end = if ($next) { $next.Line } else { $Lines.Count }
    ($Lines[$h.Line..($end - 1)] -join "`n").TrimEnd()
}

function Get-KitSddTasks {
    <# Задачі плану за шаблоном заголовка з профілю: List[From; To; Title; Idx] і Hs (усі заголовки). #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines, [string]$Pattern = $script:DefaultTaskHeading)
    try { $re = [regex]::new($Pattern) }
    catch { throw (New-KitNotChecked "plans.taskHeading — недійсний регулярний вираз: $($_.Exception.Message)") }
    $hs = @(Get-KitSddHeadings -Lines $Lines)
    $list = [System.Collections.Generic.List[object]]::new()
    for ($idx = 0; $idx -lt $hs.Count; $idx++) {
        $h = $hs[$idx]
        $m = $re.Match(('#' * $h.Level) + ' ' + $h.Text)
        if (-not $m.Success) { continue }
        # Шаблон із профілю може мати свої групи: беремо перші дві, схожі на номер.
        $ids = [System.Collections.Generic.List[string]]::new()
        for ($g = 1; $g -lt $m.Groups.Count; $g++) {
            if ($m.Groups[$g].Success -and (Test-KitSddTaskId $m.Groups[$g].Value)) { $ids.Add($m.Groups[$g].Value) }
        }
        if ($ids.Count -eq 0) { continue }
        $from = $ids[0]
        $to = if ($ids.Count -gt 1 -and (Test-KitSddInt $from) -and (Test-KitSddInt $ids[1])) { $ids[1] } else { $from }
        $list.Add([pscustomobject]@{ From = $from; To = $to; Title = $h.Text; Idx = $idx })
    }
    [pscustomobject]@{ List = $list.ToArray(); Hs = $hs }
}

function Test-KitSddInTask {
    <# Чи належить номер секції задачі: точний збіг або всередині діапазону «7–13». #>
    param($Task, [string]$Id)
    if ($Task.From -ceq $Id) { return $true }
    (Test-KitSddInt $Id) -and (Test-KitSddInt $Task.From) -and (Test-KitSddInt $Task.To) -and
    ([int64]$Id -ge [int64]$Task.From) -and ([int64]$Id -le [int64]$Task.To)
}

function Get-KitSddPlanTaskIds {
    <# Усі номери задач плану: діапазони розгорнуто, порядок природний. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PlanText, [string]$Pattern = $script:DefaultTaskHeading)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($t in (Get-KitSddTasks -Lines ($PlanText -split "`n") -Pattern $Pattern).List) {
        if ($t.From -ceq $t.To -or -not (Test-KitSddInt $t.From)) { if (-not $ids.Contains($t.From)) { $ids.Add($t.From) } }
        else { for ($n = [int64]$t.From; $n -le [int64]$t.To; $n++) { if (-not $ids.Contains([string]$n)) { $ids.Add([string]$n) } } }
    }
    Get-KitSddSortedIds -Ids $ids.ToArray()
}

function New-KitSddBrief {
    <#
    .SYNOPSIS
        Бриф задачі: її секція плану + секції плану, названі в профілі (plans.briefSections), + блок
        «Команди». Повертає Text, Title, Range, Found, Missing або $null, якщо задачі немає.
    #>
    param(
        [Parameter(Mandatory)][string]$PlanText,
        [Parameter(Mandatory)][string]$N,
        [string]$Pattern = $script:DefaultTaskHeading,
        [string[]]$Sections = $script:DefaultBriefSections,
        [Parameter(Mandatory)][string]$PlanPath,
        [string]$Commands
    )
    $lines = [string[]]($PlanText -split "`n")
    $tk = Get-KitSddTasks -Lines $lines -Pattern $Pattern
    $hs = $tk.Hs
    $t = $tk.List | Where-Object { Test-KitSddInTask -Task $_ -Id $N } | Select-Object -First 1
    if (-not $t) { return $null }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("# Бриф: задача $N — план $PlanPath")
    $parts.Add('')
    $parts.Add((Get-KitSddSection -Lines $lines -Headings $hs -Index $t.Idx))
    $taskIdx = @($tk.List | ForEach-Object { $_.Idx })
    $found = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Sections) {
        $idx = -1
        for ($i = 0; $i -lt $hs.Count; $i++) {
            if ($hs[$i].Text.ToLowerInvariant().Contains($name.ToLowerInvariant()) -and $taskIdx -notcontains $i) { $idx = $i; break }
        }
        if ($idx -lt 0) { $missing.Add($name); continue }
        if (@($found | Where-Object { $_.Idx -eq $idx }).Count) { continue }
        $found.Add([pscustomobject]@{ Name = $name; Idx = $idx })
        $parts.Add(''); $parts.Add('---'); $parts.Add('')
        $parts.Add((Get-KitSddSection -Lines $lines -Headings $hs -Index $idx))
    }
    if ($Commands) { $parts.Add(''); $parts.Add('---'); $parts.Add(''); $parts.Add($Commands) }
    [pscustomobject]@{
        Text    = ($parts -join "`n") + "`n"
        Title   = $t.Title
        Range   = if ($t.From -ceq $t.To) { $null } else { "$($t.From)–$($t.To)" }
        Found   = @($found | ForEach-Object { $hs[$_.Idx].Text })
        Missing = $missing.ToArray()
    }
}

# ---------- рядки журналу ----------

function Format-KitSddRow {
    <#
    .SYNOPSIS
        Рядок журналу: `Task 3: complete (commits ab12cd3..ef45ab6; model opus; review clean; round 1; weight risky) — нотатка`.
    .DESCRIPTION
        `base` — HEAD на момент dispatch: з нього sdd сам будує пакет рецензії й діапазон комітів.
    #>
    param(
        [Parameter(Mandatory)][string]$N,
        [Parameter(Mandatory)][string]$State,
        [string]$Base, [string]$Commits, [string]$Model, [string]$Review, [string]$Round,
        [string]$Weight, [string]$Type, [string]$Source, [string]$Approved, [string]$Note
    )
    $meta = [System.Collections.Generic.List[string]]::new()
    if ($Base) { $meta.Add("base $Base") }
    if ($Commits) { $meta.Add("commits $Commits") }
    if ($Model) { $meta.Add("model $Model") }
    if ($Review) { $meta.Add("review $Review") }
    if ($Round) { $meta.Add("round $Round") }
    if ($Weight) { $meta.Add("weight $Weight") }
    if ($Type) { $meta.Add("type $Type") }
    if ($Source) { $meta.Add("source $Source") }
    if ($Approved) { $meta.Add("approved $(([regex]::Replace($Approved, '[;()]', ' ')).Trim())") }
    $row = "Task ${N}: $State"
    if ($meta.Count) { $row += " ($($meta -join '; '))" }
    if ($Note) { $row += " — $([regex]::Replace($Note, '\s*\n\s*', ' '))" }
    $row
}

function Format-KitSddWindow {
    <#
    .SYNOPSIS
        Рядок вікна виконання: `Window (task N): open <sha> at <iso>; report <n> — <by>`.
    .DESCRIPTION
        Вікно — проміжок, коли над задачею працює implementer: від dispatch/fix/resume до
        review/done (watch вікна не закриває: між watch і review контролер комітить задачу, і цей
        коміт належить вікну). Коміти задачі — об'єднання її вікон; мердж бази контролером чи інша задача між
        вікнами їй не належать. Окремий рядок, як Ruling: стан задачі не змінює, старі розбори
        його пропускають. `report` — довжина звіту в БАЙТАХ на відкритті: watch шукає Status лише
        після неї.
    #>
    param(
        [Parameter(Mandatory)][string]$N,
        [Parameter(Mandatory)][ValidateSet('open', 'close')][string]$Kind,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$At,
        [int64]$Report = 0,
        [string]$By
    )
    $row = "Window (task $N): $Kind $Sha at $At"
    if ($Kind -eq 'open') { $row += "; report $Report" }
    if ($By) { $row += " — $By" }
    $row
}

function Format-KitSddRuling {
    <# Рядок рішення класу A: окремий від рядків стану, щоб не змінювати стан задачі. #>
    param([Parameter(Mandatory)][string]$N, [Parameter(Mandatory)][string]$Text)
    "Ruling (task $N): $([regex]::Replace($Text, '\s*\n\s*', ' '))"
}

function Get-KitSddNow {
    <# ISO UTC з мілісекундами й Z — як toISOString(). #>
    [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-KitSddRow {
    param([string]$N)
    [pscustomobject]@{
        N = $N; State = $null; Base = $null; BaseLine = $null; Commits = $null; Reviewed = $null
        ReviewLine = $null; Model = $null; Review = $null; Rounds = 0; Weight = $null
        Notes = [System.Collections.Generic.List[string]]::new()
        Fixes = [System.Collections.Generic.List[object]]::new()
        Windows = @()
    }
}

function ConvertFrom-KitSddLedger {
    <#
    .SYNOPSIS
        Журнал → стан кожної задачі (ключ — рядковий номер: «1», «1c», «3.2»).
    .DESCRIPTION
        Нерозпізнані рядки ігноруються (вільний текст SDD). Rulings — у порядку запису: рядки
        `Ruling (task N): …` і старі нотатки `— Ruling: …`. Повертає Head, Rows (впорядкований
        словник), Closed, Rulings, Windows.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $rows = [System.Collections.Specialized.OrderedDictionary]::new()
    $rulings = [System.Collections.Generic.List[object]]::new()
    $lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $head = $null
    if ($lines.Count -and $lines[0].StartsWith($script:LedgerHead, [System.StringComparison]::Ordinal)) {
        $head = $lines[0].Substring($script:LedgerHead.Length).Trim()
    }
    $closed = $null
    # Події вікон усіх задач у порядку журналу: незакрите вікно закінчується там, де відкрилось
    # наступне (будь-якої задачі).
    $windows = [System.Collections.Generic.List[object]]::new()
    for ($line = 0; $line -lt $lines.Count; $line++) {
        $l = $lines[$line]
        if ($l.StartsWith('# closed ', [System.StringComparison]::Ordinal)) { $closed = $l.Substring(9).Trim() }
        $wi = $script:WindowRow.Match($l)
        if ($wi.Success) {
            $windows.Add([pscustomobject]@{
                    N = $wi.Groups[1].Value; Kind = $wi.Groups[2].Value; Sha = $wi.Groups[3].Value; At = $wi.Groups[4].Value
                    Report = $(if ($wi.Groups[5].Success) { [int64]$wi.Groups[5].Value } else { [int64]0 })
                    Line = $line; Close = $null; Synthetic = $false
                })
            continue
        }
        $ru = $script:RulingRow.Match($l)
        if ($ru.Success) { $rulings.Add([pscustomobject]@{ N = $ru.Groups[1].Value; Text = $ru.Groups[2].Value.Trim() }); continue }
        # Кілька задач в одному рядку SDD («Task 1: … Task 2: dispatched …») — ділимо.
        $cuts = @($script:SplitRow.Matches($l) | ForEach-Object { $_.Index } | Where-Object { $_ -gt 0 })
        $segs = [System.Collections.Generic.List[string]]::new()
        $prev = 0
        foreach ($c in $cuts) { $segs.Add($l.Substring($prev, $c - $prev)); $prev = $c }
        $segs.Add($l.Substring($prev))
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $m = $script:StateRow.Match($segs[$i])
            if (-not $m.Success) { continue }
            # Посеред рядка «Task 5b: opus рев'ю…» — це нотатка, а не новий рядок SDD: окремий
            # сегмент приймаємо лише з відомим станом.
            if ($i -gt 0 -and $script:States -cnotcontains $m.Groups[2].Value) { continue }
            $n = $m.Groups[1].Value
            $r = $rows[$n]
            if ($null -eq $r) { $r = New-KitSddRow -N $n }
            $state = $m.Groups[2].Value
            $rest = $m.Groups[4].Value
            if ($state -ceq 'fix' -and $m.Groups[3].Success) { $r.Rounds = [Math]::Max($r.Rounds, [int]$m.Groups[3].Value) }
            $roundM = [regex]::Match($rest, '(?<![A-Za-z0-9_])round ([0-9]+)')
            if ($roundM.Success) { $r.Rounds = [Math]::Max($r.Rounds, [int]$roundM.Groups[1].Value) }
            $c = $script:CommitsRe.Match($rest)
            if ($c.Success) { $r.Commits = $c.Groups[1].Value }
            # Перший BASE задачі — початок усього її діапазону; новий dispatch тієї ж задачі
            # (пауза, свіжий implementer) його не зсуває. «BASE x» у вільному тексті — так його
            # писали руками до sdd dispatch; «FIX_BASE» — не він.
            $b = $script:BaseRe.Match($rest)
            if ($b.Success -and -not $r.Base) { $r.Base = $b.Groups[1].Value; $r.BaseLine = $line }
            # Голова, яку бачила остання рецензія: від неї будується пакет раунду виправлень.
            if ($state -ceq 'review' -and $c.Success) { $r.Reviewed = ($c.Groups[1].Value -split ',')[-1].Split('..')[-1] }
            if ($state -ceq 'review') { $r.ReviewLine = $line }
            if ($state -ceq 'code') {
                $code = $script:CodeRe.Match($rest)
                if ($code.Success) { $r.Commits = $code.Groups[1].Value }
            }
            # Модель, рецензію й вагу беремо лише з метаданих до « — »: у нотатках
            # «model test epochs…» чи «review major» — це текст, а не поле.
            $meta = ($rest -split ' — ', 2)[0]
            $mo = [regex]::Match($meta, '(?<![A-Za-z0-9_])model ([A-Za-z0-9_.-]+)|\((sonnet|opus|haiku|fable)\)')
            if ($mo.Success) { $r.Model = if ($mo.Groups[1].Success) { $mo.Groups[1].Value } else { $mo.Groups[2].Value } }
            # «review clean», а в SDD ще «review by controller clean».
            $rv = [regex]::Match($meta, '(?<![A-Za-z0-9_])review (?:by )?([A-Za-z0-9_-]+)')
            if ($rv.Success) { $r.Review = $rv.Groups[1].Value }
            $w = [regex]::Match($meta, '(?<![A-Za-z0-9_])weight (trivial|standard|risky)')
            if ($w.Success) { $r.Weight = $w.Groups[1].Value }
            $r.State = $state
            $note = [regex]::Match($rest, ' — (.*)$')
            if ($state -ceq 'fix') {
                $ty = [regex]::Match($meta, '(?<![A-Za-z0-9_])type (patch|redesign)(?![A-Za-z0-9_])')
                $so = [regex]::Match($meta, '(?<![A-Za-z0-9_])source ([A-Za-z0-9_]+)')
                $ap = [regex]::Match($meta, '(?<![A-Za-z0-9_])approved ([^;)]+)')
                $r.Fixes.Add([pscustomobject]@{
                        Round = $r.Rounds; Type = $(if ($ty.Success) { $ty.Groups[1].Value } else { 'patch' })
                        Source = $(if ($so.Success) { $so.Groups[1].Value } else { 'review' })
                        Approved = $(if ($ap.Success) { $ap.Groups[1].Value.Trim() } else { $null })
                        Note = $(if ($note.Success) { $note.Groups[1].Value } else { '' })
                    })
            }
            if ($note.Success) {
                $r.Notes.Add($note.Groups[1].Value)
                $legacy = [regex]::Match($note.Groups[1].Value, '(?<![A-Za-z0-9_])Ruling: (.*)$')
                if ($legacy.Success) { $rulings.Add([pscustomobject]@{ N = $n; Text = $legacy.Groups[1].Value.Trim() }) }
            }
            $rows[$n] = $r
        }
    }
    # close — останньому відкритому вікну своєї задачі.
    $opens = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $windows) {
        if ($w.Kind -ceq 'open') { $opens.Add($w); continue }
        $o = $null
        for ($j = $opens.Count - 1; $j -ge 0; $j--) { if ($opens[$j].N -ceq $w.N) { $o = $opens[$j]; break } }
        if ($o -and -not $o.Close) { $o.Close = $w.Sha }
    }
    foreach ($r in $rows.Values) {
        $mine = @($opens | Where-Object { $_.N -ceq $r.N })
        # Задачу почато старим sdd (dispatch без вікна), а раунд — новим: перше вікно відновлюємо
        # з BASE, інакше done загубив би коміти першого виконавця.
        if ($mine.Count -and $r.Base -and $null -ne $r.BaseLine -and -not @($mine | Where-Object { $_.Sha -ceq $r.Base }).Count) {
            $syn = [pscustomobject]@{ N = $r.N; Kind = 'open'; Sha = $r.Base; At = $null; Report = [int64]0; Line = $r.BaseLine; Close = $null; Synthetic = $true }
            $mine = @(@($syn) + $mine | Sort-Object { $_.Line })
            $opens.Add($syn)
        }
        $r.Windows = $mine
    }
    [pscustomobject]@{
        Head    = $head
        Rows    = $rows
        Closed  = $closed
        Rulings = $rulings.ToArray()
        Windows = @($opens | Sort-Object { $_.Line })
    }
}

function Get-KitSddTaskRanges {
    <#
    .SYNOPSIS
        Діапазони комітів задачі за її вікнами: список From/To, суміжні злиті, порожні відкинуті.
    .DESCRIPTION
        Кінець незакритого вікна — відкриття наступного вікна будь-якої задачі, інакше Head.
        -AfterLine — лише вікна, відкриті після цього рядка журналу (раунд виправлень рецензується
        своїм диффом). Задача без вікон → $null: діапазон рахують від BASE, як до вікон.
    #>
    param([Parameter(Mandatory)]$Parsed, [Parameter(Mandatory)][string]$N, [Parameter(Mandatory)][string]$Head, [int]$AfterLine = -1)
    $r = $Parsed.Rows[$N]
    if ($null -eq $r -or @($r.Windows).Count -eq 0) { return $null }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $r.Windows) {
        if ($w.Line -le $AfterLine) { continue }
        $to = $w.Close
        if (-not $to) {
            $nextW = @($Parsed.Windows | Where-Object { $_.Line -gt $w.Line }) | Select-Object -First 1
            $to = if ($nextW) { $nextW.Sha } else { $Head }
        }
        if ($to -ceq $w.Sha) { continue }
        $last = if ($out.Count) { $out[$out.Count - 1] } else { $null }
        if ($last -and $last.To -ceq $w.Sha) { $last.To = $to }
        else { $out.Add([pscustomobject]@{ From = $w.Sha; To = $to }) }
    }
    , $out
}

function Format-KitSddRanges {
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Ranges)
    (@($Ranges | ForEach-Object { "$($_.From)..$($_.To)" })) -join ','
}

function Test-KitSddOpen { param($Row) $script:OpenStates -ccontains $Row.State }
function Test-KitSddDone { param($Row) $script:Terminal -ccontains $Row.State }

# ---------- прив'язка плану до checkout ----------

function Get-KitSddBoundLedgers {
    <#
    .SYNOPSIS
        Журнали, прив'язані до checkout файлом `checkout` у робочій теці: Dir, Plan (канонічний
        шлях), Parsed. Старі теки без файлу не прив'язані — їх, як і раніше, називають шляхом плану.
    .DESCRIPTION
        Обидві теки: живий блок може ще писати в стару. Порядок — нова, потім стара. Порівняння
        шляху checkout нечутливе до регістру (Windows).
    #>
    param([Parameter(Mandatory)][string]$Checkout)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($base in (Get-KitSddJournalBases -MainRoot (Get-KitMainRoot -Path $Checkout))) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name)) {
            $bind = Join-Path $d.FullName $script:BindFile
            $file = Join-Path $d.FullName $script:LedgerName
            if (-not (Test-Path -LiteralPath $bind -PathType Leaf) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            if (-not (Test-KitSddSamePath ([System.IO.File]::ReadAllText($bind).Trim()) $Checkout)) { continue }
            $parsed = ConvertFrom-KitSddLedger -Text ([System.IO.File]::ReadAllText($file))
            $plan = if ($parsed.Head) { [System.IO.Path]::GetFullPath((Join-Path $Checkout $parsed.Head)) } else { $null }
            $found.Add([pscustomobject]@{ Dir = $d.FullName; Plan = $plan; Parsed = $parsed })
        }
    }
    $found.ToArray()
}

function Get-KitSddActiveTask {
    <#
    .SYNOPSIS
        Задача sdd, що зараз у роботі в цьому checkout: єдиний відкритий журнал, прив'язаний до
        checkout, і в ньому рівно одна задача dispatched/review/fix з BASE. Інакше $null — вгадувати,
        чия це зміна, не беремося. Зміни задачі — від її BASE, а не від base гілки.
    #>
    param([Parameter(Mandatory)][string]$Checkout)
    $open = @(Get-KitSddBoundLedgers -Checkout $Checkout | Where-Object { -not $_.Parsed.Closed -and $_.Parsed.Head })
    if ($open.Count -ne 1) { return $null }
    $active = @($open[0].Parsed.Rows.Values | Where-Object { $script:InWork -ccontains $_.State -and $_.Base })
    if ($active.Count -ne 1) { return $null }
    [pscustomobject]@{ N = $active[0].N; Base = $active[0].Base; Plan = $open[0].Parsed.Head }
}

Export-ModuleMember -Function Get-KitSddLedgerName, Get-KitSddLedgerHead, Get-KitSddStates, Get-KitSddBindName, Get-KitSddDefaults,
    Test-KitSddTaskId, Test-KitSddInt, Compare-KitSddIds, Get-KitSddSortedIds, Test-KitSddSamePath,
    Get-KitSddPlanInfo, Get-KitSddJournalBases, Get-KitSddWorkspace, Get-KitSddLegacyJournals,
    Get-KitSddHeadings, Get-KitSddTasks, Test-KitSddInTask, Get-KitSddPlanTaskIds, New-KitSddBrief,
    Format-KitSddRow, Format-KitSddWindow, Format-KitSddRuling, Get-KitSddNow,
    ConvertFrom-KitSddLedger, Get-KitSddTaskRanges, Format-KitSddRanges,
    Test-KitSddOpen, Test-KitSddDone, Get-KitSddBoundLedgers, Get-KitSddActiveTask
