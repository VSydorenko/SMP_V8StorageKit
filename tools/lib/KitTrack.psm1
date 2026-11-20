# Ported from agent-kit 0.9.1 bin/track, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Статус — лише в GitHub: віха = віха роадмапу, issue = спека / блок / баг / ідея, блоки спеки —
# підзадачі issue спеки, PR закриває issue блоку. Документи несуть лише зміст.
#
# Уся логіка підкоманд — тут, без `exit` і без читання профілю: функції отримують контекст
# (корінь репо, репозиторій GitHub, назви міток) і повертають @{ Lines; Next }. Друкує, читає
# профіль, розбирає аргументи й перекладає винятки gh в коди виходу тонка обгортка
# tools/commands/track.psm1. Виклик gh — лише через Invoke-KitGh (GhRun).
#
# Тіла issue (маркери <!-- track:… -->, «Depends on:», «Scope:», «Done when:») лишено як в оригіналі:
# це протокол, який читає сама команда (`status` шукає «Depends on:», ідемпотентність — за
# маркером і повним збігом тіла), тож переклад тексту тіла переписав би вже створені issue.

Import-Module "$PSScriptRoot/KitCli.psm1"
Import-Module "$PSScriptRoot/Markdown.psm1"
Import-Module "$PSScriptRoot/GhRun.psm1"

# ---------------------------------------------------------------------------------------------
# довідка

$script:Usage = @'
track status [-Milestone <назва>]
      віхи з відсотком виконання; відкриті issue з виконавцем, гілкою, PR і станом CI;
      «waits on» із залежностей блоків
track spec <спека.md> [-Milestone <назва>] [-Parent <#N>] [-DryRun]
      читає таблицю блоків спеки (колонки Block, Scope, Done when, Depends on, Віха), створює
      або оновлює issue спеки й по issue-підзадачі на блок (ідемпотентно: прихований маркер у
      тілі); закриті issue лишаються як є; -Parent: issue спеки стає підзадачею issue N
      (підпроєкту); друкує відповідність
      Колонка «Віха» (Milestone): відкрита віха блока за точною назвою, «—» = без віхи;
      відкриті issue блоків при повторному запуску йдуть за нею; -Milestone тоді ставить віху
      лише issue спеки
track milestone <назва> [-Due <РРРР-ММ-ДД>] [-Description <текст>] [-State open|closed] [-DryRun]
      створює віху або оновлює термін / опис / стан

Профіль (.agents/kit.profile.json), розділ "track" (усе необов'язкове):
  repo     власник/назва       (типово — GitHub-remote origin)
  labels   { spec, block, bug, idea }   назви міток (типово ті самі слова)
Коди виходу: 0 виконано; 1 збій (помилка gh, хибна таблиця спеки); 2 помилка виклику;
3 не перевірено (gh відсутній чи не залогінений, немає GitHub-репо).
'@

function Get-TrackUsage { $script:Usage.TrimEnd() }

# ---------------------------------------------------------------------------------------------
# розбір JSON і виклик gh (через Invoke-KitGh)

function ConvertFrom-TrackJson {
    # Дати лишаємо рядками: due_on інакше став би DateTime, і «починається з РРРР-ММ-ДД» зламалось би.
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return }
    ConvertFrom-Json -InputObject $Text -DateKind String
}

function Get-TrackGhJson {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$InputText)
    $params = @{ Arguments = $Arguments }
    if ($InputText) { $params.InputText = $InputText }
    ConvertFrom-TrackJson (Invoke-KitGh @params)
}

function Get-TrackGhGet {
    # GET, де 404 — відповідь («батька немає», «issue немає»), а не збій.
    param([Parameter(Mandatory)][string]$Path)
    try { ConvertFrom-TrackJson (Invoke-KitGh -Arguments @('api', $Path)) }
    catch [KitGhError] { if ($_.Exception.IsNotFound) { return $null }; throw }
}

function Get-TrackGhList {
    # Усі сторінки REST-списку (`gh api --paginate` склеює масиви по рядку).
    param([Parameter(Mandatory)][string]$Path)
    $raw = (Invoke-KitGh -Arguments @('api', '--paginate', $Path)).Trim()
    if (-not $raw) { return }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($chunk in [regex]::Split($raw, '\n(?=\[)')) {
        foreach ($i in (ConvertFrom-TrackJson $chunk)) { $items.Add($i) }
    }
    $items.ToArray()
}

function Format-TrackQuote {
    param([string]$Text)
    '"' + ($Text -replace '\\', '\\' -replace '"', '\"') + '"'
}

# ---------------------------------------------------------------------------------------------
# контекст: репозиторій і мітки

function New-TrackContext {
    <#
    .SYNOPSIS
        Контекст команди: Root, Repo, Labels. Профіль читає виклик і передає значення сюди.
    .DESCRIPTION
        Без -Repo репозиторій береться з GitHub-remote origin; немає — «не перевірено» (код 3).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Repo,
        [System.Collections.IDictionary]$Labels
    )
    if (-not $Repo) {
        $url = (& git -C $Root remote get-url origin 2>$null | Select-Object -First 1)
        $url = if ($null -eq $url) { '' } else { ([string]$url).Trim() }
        $m = [regex]::Match($url, 'github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$')
        if (-not $m.Success) {
            throw (New-KitNotChecked "немає GitHub-репозиторію: задай `"track.repo`" у .agents/kit.profile.json (origin: `"$(if ($url) { $url } else { 'відсутній' })`")")
        }
        $Repo = $m.Groups[1].Value
    }
    $names = [ordered]@{ spec = 'spec'; block = 'block'; bug = 'bug'; idea = 'idea' }
    if ($Labels) { foreach ($k in $Labels.Keys) { $names[[string]$k] = [string]$Labels[$k] } }
    [pscustomobject]@{ Root = $Root; Repo = $Repo; Labels = $names }
}

# ---------------------------------------------------------------------------------------------
# розбір спеки

# Назви колонок у спеках різних проєктів: шаблон скіла spec (англійською) і українські варіанти
# («Блок | Зміст | Готово, коли | Після», «Частина | Зміст | Готово, коли»).
$script:Ci = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:Head = [ordered]@{
    block     = [regex]::new('^(block|part|блок|частина)$', $script:Ci)
    scope     = [regex]::new('^(scope|обсяг|що будує|зміст)$', $script:Ci)
    done      = [regex]::new('^(done when|готово,? коли)$', $script:Ci)
    deps      = [regex]::new('^(depends on|залежить від|залежності|після)$', $script:Ci)
    # Віха блока: блоки однієї спеки потрапляють у різні віхи.
    milestone = [regex]::new('^(віха|milestone)$', $script:Ci)
}
# Id блока — токен на початку клітинки до першої `.`, `:`, пробілу чи тире: `B1a`, `B1b-1`, `B3-6`,
# `ПГ-2`, `D1`, `Права-3`. Регістр і кирилицю зберігаємо: маркер `track:block <спека>#<id>` і
# `doc <спека> <id>` мусять бачити те саме написання, що й спека.
$script:RxId = [regex]::new('^([^\s.:;,—–()]+)')
# Межа токена з Unicode; дефіс — частина id, тому `B3` не збігається всередині `B3-2`.
$script:Word = '[\p{L}\p{N}_-]'

function Split-TrackCells {
    param([string]$Line)
    $t = $Line.Trim() -replace '^\|', '' -replace '\|$', ''
    , @([regex]::Split($t, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}

function Remove-TrackBold { param([string]$Text) ($Text -replace '\*\*|__', '').Trim() }

function ConvertFrom-TrackSpec {
    <#
    .SYNOPSIS
        Таблиця блоків спеки — перша таблиця поза код-блоками з колонками Block, Scope, Done when
        (Depends on і Віха — необов'язкові). Повертає Title, Section, Blocks, MilestoneCol.
    .DESCRIPTION
        Шукаємо за колонками, не за заголовком розділу: у спеках заголовки різні («Blocks»,
        «Блоки виконання», «Поділ на плани»). Хибна таблиця — виняток «код 1» із причиною.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $heads = Get-MdHeadings -Text $Text
    $h1 = $heads | Where-Object { $_.Level -eq 1 } | Select-Object -First 1
    $title = if ($h1) { $h1.Text } else { 'Spec' }
    $scanned = Get-MdScannedLines -Text $Text
    $start = -1
    $col = $null
    for ($i = 0; $i + 1 -lt $scanned.Count; $i++) {
        $l = $scanned[$i]
        if ($l.Code -or -not $l.Line.Trim().StartsWith('|')) { continue }
        if ($i -gt 0 -and -not $scanned[$i - 1].Code -and $scanned[$i - 1].Line.Trim().StartsWith('|')) { continue }
        if ($scanned[$i + 1].Line -notmatch '^\s*\|?\s*:?-{3,}') { continue }
        $header = @((Split-TrackCells $l.Line) | ForEach-Object { Remove-TrackBold $_ })
        $c = @{}
        foreach ($k in $script:Head.Keys) {
            $c[$k] = -1
            for ($j = 0; $j -lt $header.Count; $j++) { if ($script:Head[$k].IsMatch($header[$j])) { $c[$k] = $j; break } }
        }
        if ($c.block -eq -1 -or $c.scope -eq -1 -or $c.done -eq -1) { continue }
        $start = $i
        $col = $c
        break
    }
    if ($start -eq -1) {
        throw (New-KitRefusal 'немає таблиці блоків: потрібна таблиця з колонками Block, Scope, Done when (шаблон скіла spec)')
    }
    $sec = $heads | Where-Object { $_.Line - 1 -lt $start } | Select-Object -Last 1
    $secText = if ($sec) { $sec.Text } else { 'blocks' }
    $cell = { param($cells, $idx) if ($idx -ge 0 -and $idx -lt $cells.Count) { [string]$cells[$idx] } else { '' } }

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    for ($i = $start + 2; $i -lt $scanned.Count; $i++) {
        $line = $scanned[$i].Line
        if ($scanned[$i].Code -or -not $line.Trim().StartsWith('|')) { break }
        $c = Split-TrackCells $line
        $blockCell = Remove-TrackBold (& $cell $c $col.block)
        $m = $script:RxId.Match($blockCell)
        $id = if ($m.Success) { $m.Groups[1].Value } else { $null }
        if (-not $id -or $id -notmatch '\p{N}') {
            throw (New-KitRefusal "рядок $($i + 1): клітинка блока має починатися з id на кшталт B1, B3-1, ПГ-2a: `"$(& $cell $c $col.block)`"")
        }
        if ($seen.ContainsKey($id)) {
            $dup = $seen[$id]
            throw (New-KitRefusal "дубль id блока `"$id`" у рядках $($dup.Line) і $($i + 1): `"$($dup.Cell)`" / `"$blockCell`"")
        }
        # Порожня клітинка віхи чи тире — «без віхи» (беклог).
        $ms = $null
        $hasMs = $col.milestone -ne -1
        if ($hasMs) {
            $raw = Remove-TrackBold (& $cell $c $col.milestone)
            $ms = if ($raw -match '^([—–-]|)$') { $null } else { $raw }
        }
        $row = [pscustomobject]@{
            Id = $id; Line = $i + 1; Cell = $blockCell
            Name = ($blockCell.Substring($id.Length) -replace '^\s*[.:;,—–-]?\s*', '').Trim()
            Scope = (& $cell $c $col.scope); Done = (& $cell $c $col.done)
            DepsText = if ($col.deps -eq -1) { '' } else { (& $cell $c $col.deps) }
            Milestone = $ms
        }
        $seen[$id] = $row
        $rows.Add($row)
    }
    if ($rows.Count -eq 0) { throw (New-KitRefusal "таблиця `"$secText`" без рядків") }

    # Залежності — лише id цієї ж таблиці, у порядку появи; решта тексту («П4-A (A5 …)», «спека
    # профілю postgres») лишається в DepsText. Клітинка, що починається з тире («— (незалежний;
    # паралельно з B3-2)»), — «залежностей немає» з приміткою: id у примітці не є залежністю.
    $blocks = foreach ($r in $rows) {
        $found = [System.Collections.Generic.List[object]]::new()
        if ($r.DepsText -notmatch '^[—–-](\s|\(|$)') {
            foreach ($other in $rows) {
                if ($other.Id -ceq $r.Id) { continue }
                $m = [regex]::Match($r.DepsText, "(?<!$($script:Word))$([regex]::Escape($other.Id))(?!$($script:Word))")
                if ($m.Success) { $found.Add([pscustomobject]@{ Index = $m.Index; Id = $other.Id }) }
            }
        }
        [pscustomobject]@{
            Id = $r.Id; Name = $r.Name; Scope = $r.Scope; Done = $r.Done; DepsText = $r.DepsText
            Milestone = $r.Milestone
            Deps = [string[]]@($found | Sort-Object Index -Stable | ForEach-Object { $_.Id })
        }
    }
    [pscustomobject]@{ Title = $title; Section = $secText; Blocks = @($blocks); MilestoneCol = ($col.milestone -ne -1) }
}

# ---------------------------------------------------------------------------------------------
# спека -> issue

# Назва в заголовку issue: GitHub не приймає заголовок понад 256 символів, а клітинка блока буває з
# цілим абзацом. Повна назва — у тілі issue спеки.
function Get-TrackShortName { param([string]$Name) if ($Name.Length -gt 80) { $Name.Substring(0, 77) + '...' } else { $Name } }

function Get-TrackSpecMarker { param([string]$Rel) "<!-- track:spec $Rel -->" }
function Get-TrackBlockMarker { param([string]$Rel, [string]$Id) "<!-- track:block $Rel#$Id -->" }

function Get-TrackSpecBody {
    param([string]$Rel, $Spec, $Numbers)
    $items = foreach ($b in $Spec.Blocks) { "- $($b.Id) $($b.Name)$(if ($Numbers[$b.Id]) { " — #$($Numbers[$b.Id])" })" }
    (@("Spec: ``$Rel``", '', "Blocks ($($Spec.Section)) — sub-issues of this issue:", '') + @($items) + @(
        '', 'Status lives in GitHub: sub-issue progress, PRs with `Closes #N`. The spec holds content only.', '', (Get-TrackSpecMarker $Rel))) -join "`n"
}

function Get-TrackBlockBody {
    param([string]$Rel, $B, $Numbers)
    $deps = (@($B.Deps | ForEach-Object { if ($Numbers[$_]) { "#$($Numbers[$_])" } else { $_ } })) -join ', '
    $tail = if ($B.DepsText -and $B.DepsText -ne '—') { " (spec: $($B.DepsText))" } else { '' }
    @(
        "Spec: ``$Rel`` — block $($B.Id). Read: ``doc $Rel $($B.Id)``", '',
        "**Scope:** $($B.Scope)", '',
        "**Done when:** $($B.Done)", '',
        "Depends on: $(if ($deps) { $deps } else { '—' })$tail", '',
        (Get-TrackBlockMarker $Rel $B.Id)
    ) -join "`n"
}

function Test-TrackHas { param($Obj, [string]$Name) $null -ne $Obj.PSObject.Properties[$Name] }
function Get-TrackIssueMilestone { param($Issue) if ($null -ne $Issue.milestone) { [string]$Issue.milestone.title } else { $null } }

function Confirm-TrackLabels {
    param($Ctx, [string[]]$Names, [bool]$Dry, $Lines)
    $have = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@(Get-TrackGhJson -Arguments @('label', 'list', '-R', $Ctx.Repo, '--limit', '500', '--json', 'name')) | ForEach-Object { $_.name }))
    foreach ($n in $Names) {
        if ($have.Contains($n)) { continue }
        $Lines.Add("$(if ($Dry) { 'буде створено' } else { 'створено' }) мітку $n")
        if (-not $Dry) { $null = Invoke-KitGh -Arguments @('label', 'create', $n, '-R', $Ctx.Repo, '--description', "agent-kit track: $n") }
    }
}

function Get-TrackExistingByMarker {
    param($Ctx, [string]$Label)
    $list = @(Get-TrackGhJson -Arguments @('issue', 'list', '-R', $Ctx.Repo, '--label', $Label, '--state', 'all', '--limit', '1000', '--json', 'number,title,body,state,milestone'))
    $map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($i in $list) {
        foreach ($m in [regex]::Matches([string]$i.body, '<!-- track:(?:spec|block) ([^>]+?) -->')) { $map[$m.Groups[1].Value] = $i }
    }
    , $map
}

function Update-TrackIssue {
    <#
        Створює або оновлює issue за ключем-маркером. Milestone — назва віхи (null — без віхи);
        SyncMilestone: віха відкритого issue має дорівнювати Milestone (лише для блоків із
        колонкою «Віха»; без колонки віху ставимо тільки при створенні).
    #>
    param($Ctx, [string]$Key, $Existing, [string]$Title, [string]$Body, [string]$Label, [string]$Milestone, [bool]$SyncMilestone, [bool]$Dry)
    $cur = $null
    if (-not $Existing.TryGetValue($Key, [ref]$cur)) {
        if ($Dry) { return @{ Number = $null; Action = 'create' } }
        $ghArgs = @('issue', 'create', '-R', $Ctx.Repo, '--title', $Title, '--body-file', '-', '--label', $Label)
        if ($Milestone) { $ghArgs += @('--milestone', $Milestone) }
        $url = Invoke-KitGh -Arguments $ghArgs -InputText $Body
        $m = [regex]::Match($url, '/issues/(\d+)')
        if (-not $m.Success) { throw (New-KitRefusal "gh issue create не надрукував URL issue: $url") }
        $n = [int]$m.Groups[1].Value
        $Existing[$Key] = [pscustomobject]@{ number = $n; title = $Title; body = $Body; state = 'OPEN'; milestone = if ($Milestone) { [pscustomobject]@{ title = $Milestone } } else { $null } }
        return @{ Number = $n; Action = 'created' }
    }
    # Закрите issue — запис того, що прийнято: не відкриваємо, не правимо ні стан, ні заголовок, ні
    # тіло, навіть якщо спека змінилась після закриття.
    if ($cur.state -eq 'CLOSED') { return @{ Number = [int]$cur.number; Action = 'closed' } }
    $want = if ($Milestone) { $Milestone } else { $null }
    $msChange = $SyncMilestone -and ((Get-TrackIssueMilestone $cur) -cne $want)
    if ($cur.title -ceq $Title -and $cur.body -ceq $Body -and -not $msChange) { return @{ Number = [int]$cur.number; Action = 'unchanged' } }
    $msArgs = if (-not $msChange) { @() } elseif ($want) { @('--milestone', $want) } else { @('--remove-milestone') }
    if (-not $Dry) {
        $null = Invoke-KitGh -Arguments (@('issue', 'edit', [string]$cur.number, '-R', $Ctx.Repo, '--title', $Title, '--body-file', '-') + $msArgs) -InputText $Body
    }
    $cur.title = $Title
    $cur.body = $Body
    if ($msChange) { $cur.milestone = if ($want) { [pscustomobject]@{ title = $want } } else { $null } }
    @{ Number = [int]$cur.number; Action = if ($Dry) { 'update' } else { 'updated' } }
}

function Resolve-TrackSpecPath {
    <# Шлях спеки від кореня репо, з `/`: у маркерах і виводі. Поза репо — абсолютний. #>
    param([string]$File, [string]$Root, [string]$WorkDir)
    $abs = [System.IO.Path]::GetFullPath($(if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $WorkDir $File }))
    $abs = $abs -replace '\\', '/'
    $rootN = ($Root -replace '\\', '/').TrimEnd('/')
    if ($abs.StartsWith("$rootN/", [System.StringComparison]::OrdinalIgnoreCase)) { return $abs.Substring($rootN.Length + 1) }
    # Корінь і шлях можуть бути записані по-різному (8.3, регістр): тоді вирішує git — префікс
    # поточної теки відносно кореня.
    if (-not [System.IO.Path]::IsPathRooted($File)) {
        $prefix = (& git -C $WorkDir rev-parse --show-prefix 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($p in (("$prefix$($File -replace '\\', '/')") -split '/')) {
                if ($p -eq '' -or $p -eq '.') { continue }
                if ($p -eq '..') { if ($parts.Count -eq 0) { return $abs }; $parts.RemoveAt($parts.Count - 1); continue }
                $parts.Add($p)
            }
            return ($parts -join '/')
        }
    }
    $abs
}

function Invoke-TrackSpec {
    <#
    .SYNOPSIS
        track spec: спека -> issue спеки й issue блоків. Усі рядки таблиці перевіряються ДО
        першого запису в GitHub.
    .PARAMETER Options
        @{ Milestone; Parent; DryRun } — ключ відсутній = параметр не задано.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$WorkDir,
        [hashtable]$Options = @{}
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $optMs = if ($Options.ContainsKey('Milestone')) { [string]$Options['Milestone'] } else { $null }
    $dry = [bool]($Options.ContainsKey('DryRun') -and $Options['DryRun'])
    $fullPath = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $WorkDir $File }
    try { $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false)) }
    catch { throw (New-KitUsageError "не читається ${File}: $($_.Exception.Message)") }
    $text = $text -replace "`r`n", "`n"
    try { $spec = ConvertFrom-TrackSpec -Text $text }
    catch { if ($_.Exception.Data.Contains('KitExitCode')) { throw (New-KitRefusal "${File}: $($_.Exception.Message)") }; throw }
    $rel = Resolve-TrackSpecPath -File $File -Root $Ctx.Root -WorkDir $WorkDir

    $parent = 0
    if ($Options.ContainsKey('Parent')) {
        $pm = [regex]::Match([string]$Options['Parent'], '^#?(\d+)$')
        if (-not $pm.Success) { throw (New-KitUsageError "-Parent приймає номер issue на кшталт #12, а не `"$($Options['Parent'])`"") }
        $parent = [int]$pm.Groups[1].Value
    }
    $msCol = $spec.MilestoneCol
    if ($optMs -or $msCol) {
        $ms = @(Get-TrackGhList "repos/$($Ctx.Repo)/milestones?state=all&per_page=100")
        if ($optMs -and -not ($ms | Where-Object { $_.title -ceq $optMs })) {
            throw (New-KitRefusal "немає віхи `"$optMs`" (створи: track milestone $(Format-TrackQuote $optMs))")
        }
        # Усі рядки — до будь-якого запису: одна хибна віха означає «нічого не записано», а не
        # половину блоків у GitHub.
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($b in $(if ($msCol) { $spec.Blocks } else { @() })) {
            if (-not $b.Milestone) { continue }
            $same = @($ms | Where-Object { $_.title -ceq $b.Milestone })
            if ($same | Where-Object { $_.state -eq 'open' }) { continue }
            $q = Format-TrackQuote $b.Milestone
            $bad.Add($(if ($same.Count) { "  $($b.Id): віха `"$($b.Milestone)`" закрита (відкрий: track milestone $q -State open)" }
                    else { "  $($b.Id): немає віхи `"$($b.Milestone)`" (створи: track milestone $q)" }))
        }
        if ($bad.Count) { throw (New-KitRefusal "${File}: колонка «Віха»: непридатних віх блоків: $($bad.Count); нічого не записано`n`n$($bad -join "`n")") }
    }
    # З колонкою віха блока — з неї, -Milestone — лише для issue спеки.
    $blockMs = { param($b) if ($msCol) { @{ Milestone = $b.Milestone; Sync = $true } } else { @{ Milestone = $optMs; Sync = $false } } }
    $existing = Get-TrackExistingByMarker $Ctx $Ctx.Labels.spec
    foreach ($kv in (Get-TrackExistingByMarker $Ctx $Ctx.Labels.block).GetEnumerator()) { $existing[$kv.Key] = $kv.Value }
    # Батько (issue підпроєкту) — перевірка до будь-якого запису: чужий батько означає помилку без
    # змін, а не тихе перевішування.
    $parentAction = $null
    if ($parent) {
        if (-not (Get-TrackGhGet "repos/$($Ctx.Repo)/issues/$parent")) { throw (New-KitRefusal "немає issue #$parent у $($Ctx.Repo) (-Parent)") }
        $cur = $null
        $null = $existing.TryGetValue($rel, [ref]$cur)
        if ($cur -and [int]$cur.number -eq $parent) { throw (New-KitUsageError "-Parent #$parent — це сама issue спеки") }
        $has = if ($cur) { Get-TrackGhGet "repos/$($Ctx.Repo)/issues/$($cur.number)/parent" } else { $null }
        if ($has -and [int]$has.number -ne $parent) {
            throw (New-KitRefusal "issue спеки #$($cur.number) уже має батька #$($has.number), а не #$parent; нічого не змінено (перенеси її в GitHub або запусти без -Parent)")
        }
        $parentAction = if ($has) { 'без змін' } elseif ($dry) { 'буде прикріплено' } else { 'прикріплено' }
    }
    Confirm-TrackLabels $Ctx @($Ctx.Labels.spec, $Ctx.Labels.block) $dry $lines
    $numbers = @{}
    foreach ($b in $spec.Blocks) {
        $e = $null
        $numbers[$b.Id] = if ($existing.TryGetValue("$rel#$($b.Id)", [ref]$e)) { [int]$e.number } else { $null }
    }
    $short = if ($spec.Title.Length -gt 60) { $spec.Title.Substring(0, 57) + '...' } else { $spec.Title }

    # Прохід 1: issue кожного блока (залежності на пізніші блоки ще без номерів).
    $results = @{}
    foreach ($b in $spec.Blocks) {
        $bm = & $blockMs $b
        $r = Update-TrackIssue -Ctx $Ctx -Key "$rel#$($b.Id)" -Existing $existing -Label $Ctx.Labels.block -Milestone $bm.Milestone -SyncMilestone $bm.Sync -Dry $dry `
            -Title "$($b.Id) $(Get-TrackShortName $b.Name) ($short)" -Body (Get-TrackBlockBody $rel $b $numbers)
        $results[$b.Id] = $r
        if ($r.Number) { $numbers[$b.Id] = $r.Number }
    }
    # Прохід 2: тепер усі номери відомі — дописати «Depends on: #N».
    foreach ($b in $spec.Blocks) {
        if (-not $b.Deps.Count -or -not $numbers[$b.Id]) { continue }
        $bm = if ($msCol) { & $blockMs $b } else { @{ Milestone = $null; Sync = $false } }
        $r = Update-TrackIssue -Ctx $Ctx -Key "$rel#$($b.Id)" -Existing $existing -Label $Ctx.Labels.block -Milestone $bm.Milestone -SyncMilestone $bm.Sync -Dry $dry `
            -Title "$($b.Id) $(Get-TrackShortName $b.Name) ($short)" -Body (Get-TrackBlockBody $rel $b $numbers)
        if ($results[$b.Id].Action -eq 'unchanged' -and $r.Action -ne 'unchanged') { $results[$b.Id] = $r }
    }
    $specRes = Update-TrackIssue -Ctx $Ctx -Key $rel -Existing $existing -Label $Ctx.Labels.spec -Milestone $optMs -SyncMilestone $false -Dry $dry `
        -Title "Spec: $($spec.Title)" -Body (Get-TrackSpecBody $rel $spec $numbers)

    # Підзадачі: додати лише відсутні.
    $added = 0
    if ($specRes.Number) {
        $subs = [System.Collections.Generic.HashSet[int]]::new([int[]]@(@(Get-TrackGhList "repos/$($Ctx.Repo)/issues/$($specRes.Number)/sub_issues?per_page=100") | ForEach-Object { [int]$_.number }))
        foreach ($b in $spec.Blocks) {
            $n = $numbers[$b.Id]
            if (-not $n -or $subs.Contains([int]$n)) { continue }
            $added++
            if (-not $dry) {
                $id = (Get-TrackGhJson -Arguments @('api', "repos/$($Ctx.Repo)/issues/$n")).id
                $null = Invoke-KitGh -Arguments @('api', '-X', 'POST', "repos/$($Ctx.Repo)/issues/$($specRes.Number)/sub_issues", '-F', "sub_issue_id=$id")
            }
        }
    } else { $added = $spec.Blocks.Count }
    # Спека — підзадача issue підпроєкту (віха -> підпроєкт -> спека -> блоки).
    if ($parentAction -eq 'прикріплено') {
        $id = (Get-TrackGhJson -Arguments @('api', "repos/$($Ctx.Repo)/issues/$($specRes.Number)")).id
        $null = Invoke-KitGh -Arguments @('api', '-X', 'POST', "repos/$($Ctx.Repo)/issues/$parent/sub_issues", '-F', "sub_issue_id=$id")
    }

    $actions = @{ create = 'створити'; created = 'створено'; update = 'оновити'; updated = 'оновлено'; unchanged = 'без змін'; closed = 'закрито' }
    $show = { param($r) if ($r.Number) { "#$($r.Number)" } else { 'нова' } }
    $w = [Math]::Max(6, ($spec.Blocks | ForEach-Object { $_.Id.Length } | Measure-Object -Maximum).Maximum)
    $lines.Add("$(if ($dry) { '[dry-run] ' })$($Ctx.Repo) · $rel")
    # З колонкою кожен рядок каже свою віху («—» — без віхи); без неї вивід простіший.
    $msTag = { param($m) if ($msCol) { "  · віха: $(if ($m) { $m } else { '—' })" } else { '' } }
    $lines.Add("$('spec'.PadRight($w)) $((& $show $specRes).PadRight(5)) $($actions[$specRes.Action].PadRight(9)) Spec: $($spec.Title)$(& $msTag $optMs)")
    foreach ($b in $spec.Blocks) {
        $r = $results[$b.Id]
        $deps = if ($b.Deps.Count) { "  ← $((@($b.Deps | ForEach-Object { if ($numbers[$_]) { "#$($numbers[$_])" } else { $_ } })) -join ', ')" } else { '' }
        $tagMs = if ($r.Action -eq 'closed') { $e = $null; if ($existing.TryGetValue("$rel#$($b.Id)", [ref]$e)) { Get-TrackIssueMilestone $e } } else { $b.Milestone }
        $lines.Add("$($b.Id.PadRight($w)) $((& $show $r).PadRight(5)) $($actions[$r.Action].PadRight(9)) $(Get-TrackShortName $b.Name)$deps$(& $msTag $tagMs)")
    }
    if ($parent) { $lines.Add("батько #${parent}: issue спеки — $parentAction") }
    $tail = if ($msCol) { ' · віхи блоків — з колонки «Віха»' } elseif ($optMs) { " · віха: $optMs" } else { '' }
    $lines.Add("підзадач: $added $(if ($dry) { 'буде додано' } else { 'додано' })$tail")
    $msPart = if ($optMs) { " -Milestone $(Format-TrackQuote $optMs)" } else { '' }
    $again = "track spec $rel$msPart$(if ($parent) { " -Parent $parent" })"
    @{ Lines = $lines.ToArray(); Next = $(if ($dry) { $again } else { "track status$msPart" }) }
}

# ---------------------------------------------------------------------------------------------
# віха

function Invoke-TrackMilestone {
    <# .PARAMETER Options  @{ Due; Description; State; DryRun } — ключ відсутній = параметр не задано. #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Title, [hashtable]$Options = @{})
    $lines = [System.Collections.Generic.List[string]]::new()
    $due = if ($Options.ContainsKey('Due')) { [string]$Options['Due'] } else { $null }
    $hasDesc = $Options.ContainsKey('Description')
    $desc = if ($hasDesc) { [string]$Options['Description'] } else { $null }
    $state = if ($Options.ContainsKey('State')) { [string]$Options['State'] } else { $null }
    $dry = [bool]($Options.ContainsKey('DryRun') -and $Options['DryRun'])
    if ($due -and $due -notmatch '^\d{4}-\d{2}-\d{2}$') { throw (New-KitUsageError '-Due має бути РРРР-ММ-ДД') }
    if ($null -ne $state -and $state -notin @('open', 'closed')) { throw (New-KitUsageError '-State має бути open або closed') }

    $cur = @(Get-TrackGhList "repos/$($Ctx.Repo)/milestones?state=all&per_page=100") | Where-Object { $_.title -ceq $Title } | Select-Object -First 1
    $fields = [System.Collections.Generic.List[object]]::new()
    $curDue = if ($cur -and $null -ne $cur.due_on) { [string]$cur.due_on } else { '' }
    if ($due -and (-not $cur -or -not $curDue.StartsWith($due, [System.StringComparison]::Ordinal))) { $fields.Add(@('due_on', "${due}T00:00:00Z")) }
    if ($hasDesc -and (-not $cur -or "$($cur.description)" -cne $desc)) { $fields.Add(@('description', $desc)) }
    if ($state -and ($(if ($cur) { $cur.state -ne $state } else { $state -ne 'open' }))) { $fields.Add(@('state', $state)) }
    $f = foreach ($kv in $fields) { '-f'; "$($kv[0])=$($kv[1])" }
    $names = ($fields | ForEach-Object { $_[0] }) -join ', '
    if (-not $cur) {
        if (-not $dry) { $null = Invoke-KitGh -Arguments (@('api', '-X', 'POST', "repos/$($Ctx.Repo)/milestones", '-f', "title=$Title") + @($f)) }
        $lines.Add("$(if ($dry) { 'буде створено' } else { 'створено' }) віху `"$Title`"$(if ($fields.Count) { " ($names)" })")
    } elseif ($fields.Count) {
        if (-not $dry) { $null = Invoke-KitGh -Arguments (@('api', '-X', 'PATCH', "repos/$($Ctx.Repo)/milestones/$($cur.number)") + @($f)) }
        $lines.Add("$(if ($dry) { 'буде оновлено' } else { 'оновлено' }) віху #$($cur.number) `"$Title`": $names")
    } else { $lines.Add("віха #$($cur.number) `"$Title`" без змін") }
    $q = Format-TrackQuote $Title
    $next = if ($dry) { "track milestone $q$(if ($due) { " -Due $due" })$(if ($state) { " -State $state" })" } else { "track spec <спека.md> -Milestone $q" }
    @{ Lines = $lines.ToArray(); Next = $next }
}

# ---------------------------------------------------------------------------------------------
# статус

function Get-TrackCiState {
    param($Rollup)
    $r = @($Rollup)
    if (-not $r.Count) { return 'без CI' }
    $states = @($r | ForEach-Object {
            $c = $_
            $v = ''
            foreach ($f in 'conclusion', 'state', 'status') { if ((Test-TrackHas $c $f) -and $c.$f) { $v = $c.$f; break } }
            ([string]$v).ToUpperInvariant()
        })
    if ($states | Where-Object { $_ -in @('FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED') }) { return 'CI червоний' }
    if ($states | Where-Object { $_ -in @('PENDING', 'QUEUED', 'IN_PROGRESS', 'EXPECTED', 'WAITING', '') }) { return 'CI іде' }
    'CI зелений'
}

function Invoke-TrackStatus {
    <# .PARAMETER Options  @{ Milestone } #>
    param([Parameter(Mandatory)]$Ctx, [hashtable]$Options = @{})
    $lines = [System.Collections.Generic.List[string]]::new()
    $optMs = if ($Options.ContainsKey('Milestone')) { [string]$Options['Milestone'] } else { $null }
    $milestones = @(Get-TrackGhList "repos/$($Ctx.Repo)/milestones?state=all&per_page=100" | Where-Object { -not $optMs -or $_.title -ceq $optMs } | Sort-Object { [int]$_.number })
    if ($optMs -and -not $milestones.Count) { throw (New-KitRefusal "немає віхи `"$optMs`"") }
    $issueArgs = @('issue', 'list', '-R', $Ctx.Repo, '--state', 'open', '--limit', '500', '--json', 'number,title,milestone,assignees,labels,body')
    if ($optMs) { $issueArgs += @('--milestone', $optMs) }
    $issues = @(Get-TrackGhJson -Arguments $issueArgs)
    $prs = @(Get-TrackGhJson -Arguments @('pr', 'list', '-R', $Ctx.Repo, '--state', 'open', '--limit', '200', '--json', 'number,headRefName,isDraft,closingIssuesReferences,statusCheckRollup'))
    $prOf = @{}
    foreach ($pr in $prs) { foreach ($ref in @($pr.closingIssuesReferences)) { if ($ref) { $prOf[[int]$ref.number] = $pr } } }
    $open = [System.Collections.Generic.HashSet[int]]::new([int[]]@($issues | ForEach-Object { [int]$_.number }))
    # Гілка без PR: локальний worktree за конвенцією `issue-<N>-<slug>`.
    $branchOf = @{}
    $wt = & git -C $Ctx.Root worktree list --porcelain 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($m in [regex]::Matches(($wt -join "`n"), '(?m)^branch refs/heads/(issue-(\d+)-\S*)\r?$')) { $branchOf[[int]$m.Groups[2].Value] = $m.Groups[1].Value }
    }

    $lines.Add("$($Ctx.Repo)$(if ($optMs) { " · $optMs" })")
    $lines.Add('')
    $lines.Add('Віхи')
    foreach ($m in $milestones) {
        $total = [int]$m.open_issues + [int]$m.closed_issues
        # «0% 0/0» читався як «нічого не зроблено»; закрита віха чи віха без issue кажуть про себе словом.
        if ($m.state -eq 'closed') { $head = 'закрита'.PadRight(24) }
        elseif (-not $total) { $head = 'без issue'.PadRight(24) }
        else {
            $pct = [int][Math]::Floor(100 * [int]$m.closed_issues / $total + 0.5)
            $fill = [int][Math]::Floor($pct / 10 + 0.5)
            $head = "$(([string]'█' * $fill).PadRight(10, '·')) $("$pct".PadLeft(3))%  $("$($m.closed_issues)".PadLeft(3))/$("$total".PadRight(3))"
        }
        $dueText = if ($m.due_on) { " · термін $(([string]$m.due_on).Substring(0, 10))" } else { '' }
        $count = if ($m.state -eq 'closed' -and $total) { " · закрито issue: $($m.closed_issues)/$total" } else { '' }
        $lines.Add("  $head $($m.title)$dueText$count")
    }
    $lines.Add('')
    $lines.Add("Відкриті issue ($($issues.Count))")
    $byMs = [ordered]@{}
    foreach ($i in $issues) {
        $k = if ($null -ne $i.milestone) { [string]$i.milestone.title } else { '(без віхи)' }
        if (-not $byMs.Contains($k)) { $byMs[$k] = [System.Collections.Generic.List[object]]::new() }
        $byMs[$k].Add($i)
    }
    $kinds = @($Ctx.Labels.Values)
    foreach ($ms in $byMs.Keys) {
        $lines.Add("  $ms")
        foreach ($i in ($byMs[$ms] | Sort-Object { [int]$_.number })) {
            $n = [int]$i.number
            $pr = $prOf[$n]
            $who = if (@($i.assignees).Count) { ' @' + ((@($i.assignees) | ForEach-Object { $_.login }) -join ',@') } else { '' }
            $kind = @($i.labels | ForEach-Object { $_.name } | Where-Object { $_ -in $kinds }) | Select-Object -First 1
            $work = if ($pr) { " · PR #$($pr.number)$(if ($pr.isDraft) { ' чернетка' }) ($($pr.headRefName)) $(Get-TrackCiState $pr.statusCheckRollup)" }
            elseif ($branchOf.ContainsKey($n)) { " · гілка $($branchOf[$n]), без PR" } else { '' }
            $dm = [regex]::Match([string]$i.body, '(?m)^Depends on: (.+)$')
            $waits = @(if ($dm.Success) { [regex]::Matches($dm.Groups[1].Value, '#\d+') | ForEach-Object { [int]$_.Value.Substring(1) } | Where-Object { $open.Contains($_) } })
            $wait = if ($waits.Count) { " · waits on $((@($waits | ForEach-Object { "#$_" })) -join ', ')" } else { '' }
            $t = [string]$i.title
            if ($t.Length -gt 70) { $t = $t.Substring(0, 67) + '...' }
            $lines.Add("    $("#$n".PadRight(5)) $(if ($kind) { "[$kind] " })$t$who$work$wait")
        }
    }
    $orphan = @($prs | Where-Object { -not @($_.closingIssuesReferences).Count })
    if ($orphan.Count) {
        $lines.Add('')
        $lines.Add("PR без `"Closes #N`" ($($orphan.Count)): $((@($orphan | ForEach-Object { "#$($_.number) ($($_.headRefName))" })) -join ', ')")
    }
    # Найчастіше після статусу — подивитись одну відкриту задачу.
    $next = if ($issues.Count) { "gh issue view $($issues[0].number) -R $($Ctx.Repo)" } else { 'track spec <спека.md> -Milestone "<назва>"' }
    @{ Lines = $lines.ToArray(); Next = $next }
}

Export-ModuleMember -Function Get-TrackUsage, New-TrackContext, ConvertFrom-TrackSpec, Invoke-TrackSpec, Invoke-TrackMilestone, Invoke-TrackStatus
