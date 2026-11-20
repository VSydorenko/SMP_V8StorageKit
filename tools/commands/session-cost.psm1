#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/session-cost + lib/session-cost.mjs, modified.
Set-StrictMode -Version Latest

<#
    Вартість сесій Claude Code з транскриптів `<CLAUDE_CONFIG_DIR|~/.claude>/projects/<slug>/`: головні
    сесії та їхні субагенти. Профіль не потрібен: проєкт типово — -RepoRoot.

    Змін проти оригіналу: параметри PowerShell-стилем (-Project, -Since, …), `next:` наприкінці успіху,
    розбір транскриптів через System.Text.Json (потоково, рядок за рядком), а не readline + JSON.parse.
#>

# $/MTok: @(input, output, cache read). Запис у кеш: 5m = 1.25×input, 1h = 2×input. Джерело — прейскурант
# Anthropic API, кеш від PRICES_DATE. Невідома модель не оцінюється навмання: її токени лишаються без ціни,
# а команда друкує попередження.
$script:PricesDate = '2026-11-03'
$script:Prices = @{
    'claude-fable-5-2'   = @(8, 40, 0.2)
    'claude-fable-5-1'   = @(10, 50, 0.25)
    'claude-fable-5'     = @(10, 50, 0.25)
    'claude-opus-5-5'    = @(4, 20, 0.2)
    'claude-opus-5'      = @(5, 25, 0.5)
    'claude-opus-4-8'    = @(5, 25, 0.5)
    'claude-opus-4-7'    = @(5, 25, 0.5)
    'claude-opus-4-6'    = @(5, 25, 0.5)
    'claude-sonnet-5-5'  = @(2, 10, 0.1)
    'claude-sonnet-5'    = @(2, 10, 0.2)
    'claude-sonnet-4-6'  = @(3, 15, 0.3)
    'claude-haiku-5-5'   = @(0.1, 0.5, 0.01)
    'claude-haiku-4-5'   = @(1, 5, 0.1)
}

$script:Usage = @"
session-cost [-Project <dir>] [-Session <id>] [-Since <date>] [-Until <date>]
             [-By model|agent|day] [-Compare <since>..<until>]

Reads <CLAUDE_CONFIG_DIR|~/.claude>/projects/<slug>/ of the project (default: current directory):
main sessions and their subagents.
Attribution: a session belongs to the range by its first record (UTC days, both ends
inclusive) and counts with its whole cost-state; sessions running past -Until are
flagged "spans" — cost-state has no timestamps and cannot be split by day.
Cost = last cost-state of the session (includes subagents). Without cost-state the
session is estimated from tokens and flagged "est". Per-agent and per-day-of-work
splits are token estimates at the price table ($script:PricesDate) — for proportions only.
  -By model   cost-state cost and tokens per model
  -By agent   main vs subagents by type/model: count, est. cost, tokens, max context
  -By day     sessions grouped by start day
  -Compare    second range; prints both summaries side by side with deltas
-Session takes an id or its prefix. Unknown model: warning, its tokens are not priced.
No sessions found: exit 3.
"@

# ---------- форматування ----------

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Format-Usd { param([double]$N) '$' + $N.ToString('F2', $script:Inv) }

function Format-Tok {
    param([double]$N)
    if ($N -ge 1e9) { return ($N / 1e9).ToString('F2', $script:Inv) + 'G' }
    if ($N -ge 1e6) { return ($N / 1e6).ToString('F1', $script:Inv) + 'M' }
    if ($N -ge 1e3) { return ($N / 1e3).ToString('F0', $script:Inv) + 'k' }
    return ([long]$N).ToString($script:Inv)
}

function Format-Pct {
    param([double]$A, [double]$B)
    if ($B -eq 0) { return '-' }
    return ([math]::Round($A / $B * 100, [MidpointRounding]::AwayFromZero)).ToString('F0', $script:Inv) + '%'
}

function Format-ShortModel { param([string]$M) ($M -replace '^claude-', '') -replace '-\d{8}$', '' }

function Format-Table {
    <# Перша колонка — вліво, решта — вправо; кінцеві пробіли рядка зрізаються. #>
    param([object[]]$Rows)
    $cols = $Rows[0].Count
    $w = @(for ($i = 0; $i -lt $cols; $i++) { ($Rows | ForEach-Object { ([string]$_[$i]).Length } | Measure-Object -Maximum).Maximum })
    $out = foreach ($r in $Rows) {
        $cells = for ($i = 0; $i -lt $cols; $i++) {
            if ($i -eq 0) { ([string]$r[$i]).PadRight($w[$i]) } else { ([string]$r[$i]).PadLeft($w[$i]) }
        }
        ($cells -join '  ').TrimEnd()
    }
    $out -join "`n"
}

# ---------- ціни ----------

function Get-ModelPrice {
    <# Ціна моделі; датований суфікс (`claude-haiku-4-5-20251001`) зводиться до базового id. #>
    param([string]$Model)
    if ($script:Prices.ContainsKey($Model)) { return , $script:Prices[$Model] }
    $base = $Model -replace '-\d{8}$', ''
    if ($script:Prices.ContainsKey($base)) { return , $script:Prices[$base] }
    return $null
}

function Get-ProjectTranscriptDir {
    <# Claude Code замінює в шляху проєкту все, крім літер і цифр, на `-`. #>
    param([Parameter(Mandatory)][string]$Project)
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    Join-Path (Join-Path $root 'projects') ($Project -replace '[^a-zA-Z0-9]', '-')
}

# ---------- JSON ----------

function Get-JProp {
    param($El, [string]$Name)
    if ($null -eq $El -or $El.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    $v = [System.Text.Json.JsonElement]::new()
    if ($El.TryGetProperty($Name, [ref]$v)) { return $v }
    return $null
}

function Get-JStr {
    param($El)
    if ($null -ne $El -and $El.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { return $El.GetString() }
    return $null
}

function Get-JNum {
    param($El)
    if ($null -eq $El -or $El.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { return [double]0 }
    $l = [long]0
    if ($El.TryGetInt64([ref]$l)) { return [double]$l }
    return $El.GetDouble()
}

function New-Tokens { @{ input = [double]0; output = [double]0; cacheRead = [double]0; cacheWrite = [double]0 } }

function Add-Tokens {
    param($Into, $From)
    foreach ($k in @('input', 'output', 'cacheRead', 'cacheWrite')) { $Into[$k] += $From[$k] }
}

function New-ByModel { @{ msgs = 0; tokens = (New-Tokens); est = [double]0 } }

function Merge-ByModel {
    param($Into, $From)
    foreach ($m in $From.Keys) {
        if (-not $Into.Contains($m)) { $Into[$m] = New-ByModel }
        $x = $Into[$m]; $b = $From[$m]
        $x.msgs += $b.msgs
        $x.est += $b.est
        Add-Tokens $x.tokens $b.tokens
    }
}

function Add-Count {
    param($Dict, [string]$Key, [int]$By = 1)
    if ($Dict.Contains($Key)) { $Dict[$Key] += $By } else { $Dict[$Key] = $By }
}

# ---------- читання транскриптів ----------

function Read-Transcript {
    <#
    Один транскрипт (головний або субагента) → лічильники. Блоки одного повідомлення API пишуться окремими
    рядками з тим самим `message.id` — usage рахується один раз. Читання потоком: транскрипти великі.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $s = @{
        tokens = (New-Tokens); models = [ordered]@{}; byModel = [ordered]@{}; estCost = [double]0
        unpriced = [ordered]@{}; maxCtx = [double]0; turns = 0; toolCalls = 0
        first = $null; last = $null; costState = $null; title = $null
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $doc = $null
        try { $doc = [System.Text.Json.JsonDocument]::Parse($line) } catch { continue }
        try {
            $d = $doc.RootElement
            if ($d.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }
            $ts = Get-JStr (Get-JProp $d 'timestamp')
            if ($ts) {
                if (-not $s.first) { $s.first = $ts }
                $s.last = $ts
            }
            $type = Get-JStr (Get-JProp $d 'type')
            if ($type -eq 'cost-state') {
                # останній запис перемагає: зберігаємо лише потрібне, а не сам JsonElement (документ звільняється)
                $cm = [ordered]@{}
                $mu = Get-JProp $d 'modelUsage'
                if ($null -ne $mu -and $mu.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                    foreach ($p in $mu.EnumerateObject()) { $cm[$p.Name] = Get-JNum (Get-JProp $p.Value 'costUSD') }
                }
                $s.costState = @{ total = (Get-JNum (Get-JProp $d 'totalCostUSD')); byModel = $cm }
            }
            elseif ($type -eq 'custom-title') {
                $t = Get-JStr (Get-JProp $d 'customTitle')
                if ($t) { $s.title = $t }
            }
            elseif ($type -eq 'ai-title') {
                if (-not $s.title) {
                    $t = Get-JStr (Get-JProp $d 'aiTitle')
                    if (-not $t) { $t = Get-JStr (Get-JProp $d 'title') }
                    if ($t) { $s.title = $t }
                }
            }
            elseif ($type -eq 'assistant') {
                $m = Get-JProp $d 'message'
                if ($null -eq $m -or $m.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }
                $content = Get-JProp $m 'content'
                if ($null -ne $content -and $content.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                    foreach ($c in $content.EnumerateArray()) {
                        if ((Get-JStr (Get-JProp $c 'type')) -eq 'tool_use') { $s.toolCalls++ }
                    }
                }
                $id = Get-JStr (Get-JProp $m 'id')
                if (-not $seen.Add([string]$id)) { continue }
                $u = Get-JProp $m 'usage'
                $model = Get-JStr (Get-JProp $m 'model')
                if ($null -eq $u -or $u.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or $model -eq '<synthetic>') { continue }
                if (-not $model) { $model = 'unknown' }
                $t = @{
                    input      = Get-JNum (Get-JProp $u 'input_tokens')
                    output     = Get-JNum (Get-JProp $u 'output_tokens')
                    cacheRead  = Get-JNum (Get-JProp $u 'cache_read_input_tokens')
                    cacheWrite = Get-JNum (Get-JProp $u 'cache_creation_input_tokens')
                }
                Add-Tokens $s.tokens $t
                $s.turns++
                if (-not $s.byModel.Contains($model)) { $s.byModel[$model] = New-ByModel }
                $bm = $s.byModel[$model]
                $bm.msgs++
                Add-Tokens $bm.tokens $t
                Add-Count $s.models $model
                $s.maxCtx = [math]::Max($s.maxCtx, $t.input + $t.cacheRead + $t.cacheWrite)
                $p = Get-ModelPrice $model
                if ($null -eq $p) { Add-Count $s.unpriced $model; continue }
                $h1 = Get-JNum (Get-JProp (Get-JProp $u 'cache_creation') 'ephemeral_1h_input_tokens')
                $est = ($t.input * $p[0] + $t.output * $p[1] + $t.cacheRead * $p[2] + $h1 * $p[0] * 2 + ($t.cacheWrite - $h1) * $p[0] * 1.25) / 1e6
                $s.estCost += $est
                $bm.est += $est
            }
        }
        finally { $doc.Dispose() }
    }
    $s
}

function Get-TopModel {
    param($Models)
    $best = $null; $n = -1
    foreach ($k in $Models.Keys) { if ($Models[$k] -gt $n) { $best = $k; $n = $Models[$k] } }
    $best
}

function Read-Session {
    <# Сесія: головний транскрипт + субагенти з `<id>/subagents/**`. Вартість — останній cost-state. #>
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Id)
    $main = Read-Transcript (Join-Path $Dir "$Id.jsonl")
    $subDir = Join-Path (Join-Path $Dir $Id) 'subagents'
    $subagents = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $subDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $subDir -Recurse -File -Filter '*.jsonl' | Sort-Object FullName)) {
            $s = Read-Transcript $f.FullName
            $meta = $null
            $metaPath = $f.FullName -replace '\.jsonl$', '.meta.json'
            if (Test-Path -LiteralPath $metaPath) {
                try { $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $meta = $null }
            }
            $s.type = if ($meta -and $meta.PSObject.Properties['agentType'] -and $meta.agentType) { [string]$meta.agentType } else { 'general-purpose' }
            $s.model = Get-TopModel $s.models
            $subagents.Add($s)
        }
    }
    $tokens = New-Tokens
    $models = [ordered]@{}; foreach ($k in $main.models.Keys) { $models[$k] = $main.models[$k] }
    $unpriced = [ordered]@{}; foreach ($k in $main.unpriced.Keys) { $unpriced[$k] = $main.unpriced[$k] }
    $byModel = [ordered]@{}; Merge-ByModel $byModel $main.byModel
    $toolCalls = $main.toolCalls
    $estCost = $main.estCost
    foreach ($s in $subagents) {
        Add-Tokens $tokens $s.tokens
        $toolCalls += $s.toolCalls
        $estCost += $s.estCost
        Merge-ByModel $byModel $s.byModel
        foreach ($k in $s.models.Keys) { Add-Count $models $k $s.models[$k] }
        foreach ($k in $s.unpriced.Keys) { Add-Count $unpriced $k $s.unpriced[$k] }
    }
    Add-Tokens $tokens $main.tokens
    $cs = $main.costState
    $costByModel = [ordered]@{}
    if ($cs) { foreach ($k in $cs.byModel.Keys) { $costByModel[$k] = $cs.byModel[$k] } }
    @{
        id = $Id; title = $main.title; first = $main.first; last = $main.last
        cost = $(if ($cs) { [double]$cs.total } else { [double]$estCost })
        estimated = (-not $cs); estCost = $estCost; costByModel = $costByModel
        tokens = $tokens; models = $models; byModel = $byModel; unpriced = $unpriced
        maxCtx = $main.maxCtx; turns = $main.turns; toolCalls = $toolCalls; subagents = $subagents.ToArray()
        spans = $false
    }
}

function Test-InRange {
    <# Межі дат — UTC, обидві включно; сесія належить діапазону за першим записом. #>
    param($Ts, $Since, $Until)
    if (-not $Ts) { return $false }
    $day = $Ts.Substring(0, [math]::Min(10, $Ts.Length))
    return ((-not $Since) -or [string]::CompareOrdinal($day, $Since) -ge 0) -and ((-not $Until) -or [string]::CompareOrdinal($day, $Until) -le 0)
}

function Read-Project {
    param([Parameter(Mandatory)][string]$Dir, [string]$Session, [string]$Since, [string]$Until)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return , @() }
    $ids = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.jsonl' | ForEach-Object { $_.BaseName } |
        Where-Object { -not $Session -or $_ -eq $Session -or $_.StartsWith($Session, [StringComparison]::Ordinal) } | Sort-Object { $_ } )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $s = Read-Session -Dir $Dir -Id $id
        if (-not (Test-InRange $s.first $Since $Until)) { continue }
        # Довга сесія, що тягнеться за -Until: її cost-state не ділиться за днями, тож позначаємо, щоб не
        # читати її як витрати лише дня старту.
        $s.spans = [bool]($Until -and $s.last -and ([string]::CompareOrdinal($s.last.Substring(0, 10), $Until) -gt 0))
        $out.Add($s)
    }
    , $out.ToArray()
}

function Get-SessionSummary {
    <# Підсумок набору сесій — те, що порівнює -Compare. #>
    param([object[]]$Sessions)
    $t = @{
        sessions = $Sessions.Count; spans = 0; byModel = [ordered]@{}; cost = [double]0; estimated = 0; tokens = (New-Tokens)
        costByModel = [ordered]@{}; subagents = 0; subagentEst = [double]0; mainEst = [double]0; toolCalls = 0
        maxCtx = [double]0; turns = 0; unpriced = [ordered]@{}
    }
    foreach ($s in $Sessions) {
        $t.cost += $s.cost
        if ($s.estimated) { $t.estimated++ }
        if ($s.spans) { $t.spans++ }
        Merge-ByModel $t.byModel $s.byModel
        Add-Tokens $t.tokens $s.tokens
        foreach ($m in $s.costByModel.Keys) {
            if ($t.costByModel.Contains($m)) { $t.costByModel[$m] += $s.costByModel[$m] } else { $t.costByModel[$m] = $s.costByModel[$m] }
        }
        $subEst = [double]0
        foreach ($a in $s.subagents) { $subEst += $a.estCost }
        $t.subagents += $s.subagents.Count
        $t.subagentEst += $subEst
        $t.mainEst += $s.estCost - $subEst
        $t.toolCalls += $s.toolCalls
        $t.turns += $s.turns
        $t.maxCtx = [math]::Max($t.maxCtx, $s.maxCtx)
        foreach ($m in $s.unpriced.Keys) { Add-Count $t.unpriced $m $s.unpriced[$m] }
    }
    $t
}

# ---------- розрізи ----------

function Get-Flags {
    param($S)
    (@(if ($S.estimated) { 'est' }; if ($S.spans) { 'spans' })) -join ','
}

function Format-BySessions {
    param([object[]]$Sessions)
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add(@('session', 'start', 'cost', 'input', 'output', 'cache_r', 'cache_w', 'max_ctx', 'tools', 'subs', 'models', 'flags'))
    foreach ($s in ($Sessions | Sort-Object { $_.cost } -Descending)) {
        $label = if ($s.title) { $s.title } else { $s.id }
        $names = if ($s.costByModel.Count) { $s.costByModel.Keys } else { $s.models.Keys }
        $rows.Add(@(
                $label.Substring(0, [math]::Min(32, $label.Length)),
                ($s.first.Substring(0, [math]::Min(16, $s.first.Length)) -replace 'T', ' '),
                (Format-Usd $s.cost), (Format-Tok $s.tokens.input), (Format-Tok $s.tokens.output),
                (Format-Tok $s.tokens.cacheRead), (Format-Tok $s.tokens.cacheWrite), (Format-Tok $s.maxCtx),
                $s.toolCalls, $s.subagents.Count, (@($names | ForEach-Object { Format-ShortModel $_ }) -join '+'), (Get-Flags $s)
            ))
    }
    Format-Table $rows.ToArray()
}

function Format-ByModel {
    param($Sum)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Sum.costByModel.Keys) { $names.Add($k) }
    foreach ($k in $Sum.byModel.Keys) { if (-not $names.Contains($k)) { $names.Add($k) } }
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add(@('model', 'cost', 'share', 'msgs', 'input', 'output', 'cache_r', 'cache_w', 'est'))
    $cost = { param($m) if ($Sum.costByModel.Contains($m)) { $Sum.costByModel[$m] } else { [double]0 } }
    foreach ($m in ($names | Sort-Object { & $cost $_ } -Descending)) {
        $b = if ($Sum.byModel.Contains($m)) { $Sum.byModel[$m] } else { New-ByModel }
        $c = & $cost $m
        $rows.Add(@($m, (Format-Usd $c), (Format-Pct $c $Sum.cost), $b.msgs, (Format-Tok $b.tokens.input), (Format-Tok $b.tokens.output),
                (Format-Tok $b.tokens.cacheRead), (Format-Tok $b.tokens.cacheWrite), (Format-Usd $b.est)))
    }
    Format-Table $rows.ToArray()
}

function Format-ByAgent {
    param([object[]]$Sessions)
    $groups = [ordered]@{}
    $add = {
        param($key, $est, $out, $ctx, $tools)
        if (-not $groups.Contains($key)) { $groups[$key] = @{ n = 0; est = [double]0; out = [double]0; ctx = [double]0; maxCtx = [double]0; tools = 0 } }
        $g = $groups[$key]
        $g.n++; $g.est += $est; $g.out += $out; $g.ctx += $ctx; $g.maxCtx = [math]::Max($g.maxCtx, $ctx); $g.tools += $tools
    }
    foreach ($s in $Sessions) {
        $subEst = [double]0; $subTools = 0; $subOut = [double]0
        foreach ($a in $s.subagents) { $subEst += $a.estCost; $subTools += $a.toolCalls; $subOut += $a.tokens.output }
        & $add 'main' ($s.estCost - $subEst) ($s.tokens.output - $subOut) $s.maxCtx ($s.toolCalls - $subTools)
        foreach ($a in $s.subagents) { & $add "$($a.type) / $(Format-ShortModel ([string]$a.model))" $a.estCost $a.tokens.output $a.maxCtx $a.toolCalls }
    }
    $total = [double]0
    foreach ($g in $groups.Values) { $total += $g.est }
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add(@('agent / model', 'count', 'est', 'share', 'est/agent', 'output', 'avg_max_ctx', 'max_ctx', 'tools/agent'))
    foreach ($k in ($groups.Keys | Sort-Object { $groups[$_].est } -Descending)) {
        $g = $groups[$k]
        $rows.Add(@($k, $g.n, (Format-Usd $g.est), (Format-Pct $g.est $total), (Format-Usd ($g.est / $g.n)), (Format-Tok $g.out),
                (Format-Tok ([math]::Round($g.ctx / $g.n, [MidpointRounding]::AwayFromZero))), (Format-Tok $g.maxCtx),
                [math]::Round($g.tools / $g.n, [MidpointRounding]::AwayFromZero)))
    }
    Format-Table $rows.ToArray()
}

function Format-ByDay {
    param([object[]]$Sessions)
    $days = [ordered]@{}
    foreach ($s in $Sessions) {
        $d = $s.first.Substring(0, 10)
        if (-not $days.Contains($d)) { $days[$d] = @{ n = 0; cost = [double]0; subs = 0; tools = 0; spans = 0 } }
        $g = $days[$d]
        $g.n++; $g.cost += $s.cost; $g.subs += $s.subagents.Count; $g.tools += $s.toolCalls
        if ($s.last -and [string]::CompareOrdinal($s.last.Substring(0, 10), $d) -gt 0) { $g.spans++ }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add(@('day', 'sessions', 'cost', 'subs', 'tools', 'run_past_day'))
    foreach ($d in ($days.Keys | Sort-Object { $_ })) {
        $g = $days[$d]
        $rows.Add(@($d, $g.n, (Format-Usd $g.cost), $g.subs, $g.tools, $g.spans))
    }
    Format-Table $rows.ToArray()
}

function Format-Compare {
    param($A, $B, [string]$LabelA, [string]$LabelB)
    $str = { param($v) ([double]$v).ToString('0.####', $script:Inv) }
    $line = {
        param($name, $x, $y, $fmt)
        $delta = $y - $x
        $sign = if ($delta -ge 0) { '+' } else { '-' }
        $pctText = if ($x) { $(if ($y -ge $x) { '+' } else { '' }) + ([math]::Round(($y - $x) / $x * 100, [MidpointRounding]::AwayFromZero)).ToString('F0', $script:Inv) + '%' } else { '-' }
        , @($name, (& $fmt $x), (& $fmt $y), ($sign + (& $fmt ([math]::Abs($delta)))), $pctText)
    }
    $usd = { param($v) Format-Usd $v }
    $tok = { param($v) Format-Tok $v }
    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add(@('metric', $LabelA, $LabelB, 'delta', 'delta%'))
    $rows.Add((& $line 'sessions' $A.sessions $B.sessions $str))
    $rows.Add((& $line 'cost' $A.cost $B.cost $usd))
    $rows.Add((& $line 'cost/session' ($A.cost / [math]::Max(1, $A.sessions)) ($B.cost / [math]::Max(1, $B.sessions)) $usd))
    foreach ($k in @('input', 'output', 'cacheRead', 'cacheWrite')) { $rows.Add((& $line "tokens.$k" $A.tokens[$k] $B.tokens[$k] $tok)) }
    $rows.Add((& $line 'subagents' $A.subagents $B.subagents $str))
    $rows.Add(@('subagent share (est)', (Format-Pct $A.subagentEst ($A.subagentEst + $A.mainEst)), (Format-Pct $B.subagentEst ($B.subagentEst + $B.mainEst)), '', ''))
    $rows.Add((& $line 'tool calls' $A.toolCalls $B.toolCalls $str))
    $rows.Add((& $line 'main turns' $A.turns $B.turns $str))
    $rows.Add((& $line 'max context' $A.maxCtx $B.maxCtx $tok))
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $A.costByModel.Keys) { $names.Add($k) }
    foreach ($k in $B.costByModel.Keys) { if (-not $names.Contains($k)) { $names.Add($k) } }
    foreach ($m in $names) {
        $x = if ($A.costByModel.Contains($m)) { $A.costByModel[$m] } else { [double]0 }
        $y = if ($B.costByModel.Contains($m)) { $B.costByModel[$m] } else { [double]0 }
        $rows.Add((& $line "cost $(Format-ShortModel $m)" $x $y $usd))
    }
    Format-Table $rows.ToArray()
}

function Format-Footer {
    param($Sum)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("TOTAL $($Sum.sessions) session(s), $(Format-Usd $Sum.cost); subagents $($Sum.subagents), est. share $(Format-Pct $Sum.subagentEst ($Sum.subagentEst + $Sum.mainEst))")
    if ($Sum.estimated) { $lines.Add("$($Sum.estimated) session(s) without cost-state: estimated from tokens (est)") }
    if ($Sum.spans) { $lines.Add("$($Sum.spans) session(s) run past the range (spans): whole cost counted at start day") }
    foreach ($m in $Sum.unpriced.Keys) { $lines.Add("warn: no price for model $m ($($Sum.unpriced[$m]) message(s)); not priced in estimates") }
    $lines -join "`n"
}

# ---------- вхід ----------

function Invoke-KitSessionCost {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        Project = 'string'; Session = 'string'; Since = 'string'; Until = 'string'; By = 'string'; Compare = 'string'
    }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    if ($a.Positional.Count) { throw (New-KitUsageError "зайвий позиційний аргумент '$($a.Positional[0])'") }
    $n = $a.Named
    $get = { param($k) if ($n.ContainsKey($k)) { [string]$n[$k] } else { $null } }
    $since = & $get 'Since'; $until = & $get 'Until'; $by = & $get 'By'
    $session = & $get 'Session'; $compare = & $get 'Compare'
    foreach ($pair in @(@('Since', $since), @('Until', $until))) {
        if ($pair[1] -and $pair[1] -notmatch '^\d{4}-\d{2}-\d{2}$') { throw (New-KitUsageError "-$($pair[0]): очікується YYYY-MM-DD, отримано `"$($pair[1])`"") }
    }
    if ($by -and $by -notin @('model', 'agent', 'day')) { throw (New-KitUsageError "-By: model, agent або day, отримано `"$by`"") }
    $range = $null
    if ($compare) {
        if ($compare -notmatch '^(\d{4}-\d{2}-\d{2})?\.\.(\d{4}-\d{2}-\d{2})?$') { throw (New-KitUsageError "-Compare: очікується <since>..<until> (YYYY-MM-DD), отримано `"$compare`"") }
        $range = @{ since = $Matches[1]; until = $Matches[2] }
    }

    $proj = & $get 'Project'
    if (-not $proj) { $proj = $RepoRoot }
    elseif (-not [System.IO.Path]::IsPathRooted($proj)) { $proj = Join-Path $RepoRoot $proj }
    $proj = [System.IO.Path]::GetFullPath($proj).TrimEnd('\', '/')
    $dir = Get-ProjectTranscriptDir -Project $proj

    $sessions = Read-Project -Dir $dir -Session $session -Since $since -Until $until
    $rangeText = "$(if ($since) { $since } else { '…' })..$(if ($until) { $until } else { '…' })"
    Write-KitLine "session-cost $dir $(if ($session) { "session $session" } else { $rangeText }); prices $script:PricesDate"

    if ($compare) {
        $before = Read-Project -Dir $dir -Session $session -Since $range.since -Until $range.until
        if (-not $sessions.Count -and -not $before.Count) {
            Write-KitLine 'NOT CHECKED: no sessions in either range'
            return 3
        }
        $sb = Get-SessionSummary $before; $sa = Get-SessionSummary $sessions
        Write-KitLine (Format-Compare $sb $sa $compare $rangeText)
        $spans = $sb.spans + $sa.spans
        if ($spans) { Write-KitLine "$spans session(s) run past their range (spans)" }
        Write-KitNext 'session-cost -By agent'
        return 0
    }
    if (-not $sessions.Count) {
        Write-KitLine "NOT CHECKED: no sessions found in $dir$(if ($session) { " for $session" })"
        return 3
    }
    $sum = Get-SessionSummary $sessions
    $body = switch ($by) {
        'model' { Format-ByModel $sum }
        'agent' { Format-ByAgent $sessions }
        'day'   { Format-ByDay $sessions }
        default { Format-BySessions $sessions }
    }
    Write-KitLine $body
    Write-KitLine (Format-Footer $sum)
    Write-KitNext $(if ($by) { 'session-cost' } else { 'session-cost -By agent' })
    return 0
}

Export-ModuleMember -Function Invoke-KitSessionCost
