# Спільна підготовка ConfigParity.Tests.ps1: PowerShell-бік паритету (префлайт + вибір джерел + база агента,
# серіалізовані узагальнено), Rust-бік (bin/kit.exe дерева, прихована підкоманда config-preflight), порівняння
# розібраних значень і розбір корпусу tools/tests/fixtures/config-bad.
# Підключається DOT-SOURCE із BeforeAll (і BeforeDiscovery) — як CheckSetup.ps1; $PSScriptRoot тут — тека фікстур.

Import-Module (Resolve-Path "$PSScriptRoot/KitFixtures.psm1").Path -Force
foreach ($m in 'RepoRoot', 'Manifest', 'V8Project', 'V8', 'Preflight', 'AgentBase') {
    Import-Module (Resolve-Path "$PSScriptRoot/../../lib/$m.psm1").Path -Force
}
$script:KitExe = (Resolve-Path "$PSScriptRoot/../../../bin/kit.exe").Path
$script:ConfigBadDir = Join-Path $PSScriptRoot 'config-bad'

# ---- PowerShell-бік -----------------------------------------------------------------------------------------

function script:ConvertTo-ParityKey([string]$Name) { $Name.Substring(0, 1).ToLowerInvariant() + $Name.Substring(1) }

# Маска рядка підключення — розібрана форма, як у Rust (сирим текстом рядок у вивід не йде).
function script:ConvertTo-ParityConnection([string]$Connection) {
    try {
        $p = ConvertFrom-V8Connection -Connection $Connection
        if ($p.Kind -eq 'file') { return [ordered]@{ parses = $true; kind = 'file'; file = $p.File } }
        return [ordered]@{ parses = $true; kind = 'server'; server = $p.Server; ref = $p.Ref }
    } catch {
        return [ordered]@{ parses = $false; credentials = [bool]$_.Exception.Data.Contains('KitCredentialsInConnection') }
    }
}

# Маска userinfo шляху сховища — те саме правило, що `config::mask_storage_path` у Rust: усе від `://` до ОСТАННЬОГО `@`
# замінюється на `***`. PowerShell-продукт друкує шлях сирим (відома відмінність, виправлений дефект Rust).
function script:ConvertTo-ParityStoragePath($Path) {
    if ($null -eq $Path) { return $null }
    $text = [string]$Path
    $i = $text.IndexOf('://', [System.StringComparison]::Ordinal)
    if ($i -lt 0) { return $text }
    $rest = $text.Substring($i + 3)
    $at = $rest.LastIndexOf('@')
    if ($at -lt 0) { return $text }
    $text.Substring(0, $i + 3) + '***@' + $rest.Substring($at + 1)
}

# Узагальнений обхід усіх властивостей: ім'я -> camelCase; секретні імена (за переліком) -> ознака «задано».
# Словник без правила проєкції — виняток (нове поле-словник з одного боку не мусить пройти непоміченим).
function script:ConvertTo-ParityTree {
    param($Value, [string]$Path = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
    if ($Value -is [System.Collections.IDictionary]) { throw "словник без правила проєкції: $Path" }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($i in $Value) { ConvertTo-ParityTree -Value $i -Path $Path }) }
    $out = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) {
        $name = $p.Name
        $full = if ($Path) { "$Path.$name" } else { $name }
        $v = $p.Value
        # Відомі структурні відмінності проєкції (Rust друкує не все дерево): ключ шляху -> правило.
        if ($full -eq 'Manifest.Path') { continue }   # шлях маніфесту вже є в context.manifestPath
        if ($full -eq 'Manifest.Workspaces') { $out[(ConvertTo-ParityKey $name)] = @($v | ForEach-Object { $_.Path }); continue }
        if ($full -in 'Overlay.Infobases', 'Overlay.Workspaces', 'Overlay.Storages') {
            $items = foreach ($k in @($v.Keys | Sort-Object { $_.ToLowerInvariant() })) {
                $item = ConvertTo-ParityTree -Value $v[$k] -Path $full
                if ($full -eq 'Overlay.Storages') { $item['key'] = [string]$k }
                $item
            }
            $out[(ConvertTo-ParityKey $name)] = @($items)
            continue
        }
        if ($name -eq 'StoragePath' -or $full -eq 'Overlay.Storages.Path') { $out[(ConvertTo-ParityKey $name)] = ConvertTo-ParityStoragePath $v; continue }
        if ($name -like '*Password') { $out[(ConvertTo-ParityKey $name) + 'Set'] = -not [string]::IsNullOrEmpty([string]$v); continue }
        if ($name -eq 'Dbms') { $out['dbmsSet'] = ($null -ne $v); continue }
        if ($name -eq 'Providers') { $out['providersSet'] = ($null -ne $v); continue }
        if ($name -eq 'Connection') { $out['connection'] = ConvertTo-ParityConnection ([string]$v); continue }
        $out[(ConvertTo-ParityKey $name)] = ConvertTo-ParityTree -Value $v -Path $full
    }
    $out
}

function script:Get-PsWorkspaceTree($Context, $Workspace) {
    $tree = ConvertTo-ParityTree -Value $Workspace -Path 'Workspaces'
    $tree['needsAgentBase'] = [bool](Test-KitWorkspaceNeedsAgentBase -Workspace $Workspace)
    $tree['agentBaseMissingMessage'] = New-KitAgentBaseMissingMessage -WorkspacePath $Workspace.Path
    $local = Join-Path $Workspace.FullPath 'v8project.local.yaml'
    $raw = ''
    if (Test-Path -LiteralPath $local -PathType Leaf) { try { $raw = Get-Content -LiteralPath $local -Raw -Encoding UTF8 } catch { $raw = '' } }
    $tree['localHasDevInfobaseLine'] = [bool]($raw -match '(?m)^\s*devInfobase\s*:')
    try {
        $b = Resolve-KitAgentBase -Context $Context -Workspace $Workspace
        $tree['agentBase'] = [ordered]@{ base = (ConvertTo-ParityTree -Value $b -Path 'AgentBase'); error = $null }
    } catch { $tree['agentBase'] = [ordered]@{ base = $null; error = $_.Exception.Message } }
    try {
        $items = @(Find-KitAgentBaseCollisions -Context $Context -Workspace $Workspace)
        $tree['collisions'] = [ordered]@{ items = @(foreach ($i in $items) { ConvertTo-ParityTree -Value $i -Path 'Collision' }); error = $null }
    } catch { $tree['collisions'] = [ordered]@{ items = @(); error = $_.Exception.Message } }
    $tree
}

# Результат PowerShell-боку: Strict — зупинка (stop.message) або контекст; решта режимів — контекст.
function script:Get-PsParityResult {
    param([string]$Repo, [string]$Mode, [string]$Workspace, [string]$Source, [string[]]$Truth = @())
    $ctx = $null
    try { $ctx = Invoke-KitPreflight -RepoRoot $Repo -Mode $Mode }
    catch { return [ordered]@{ stop = [ordered]@{ message = $_.Exception.Message } } }
    $selected = @(); $selectError = $null
    try {
        $selected = @(Select-KitSources -Context $ctx -Workspace $Workspace -Source $Source -Truth $Truth)
    } catch { $selectError = $_.Exception.Message }
    $c = ConvertTo-ParityTree -Value ($ctx | Select-Object -Property * -ExcludeProperty Findings, Workspaces, Overlay, Manifest) -Path ''
    $c['manifest'] = ConvertTo-ParityTree -Value $ctx.Manifest -Path 'Manifest'
    $c['overlay'] = ConvertTo-ParityTree -Value $ctx.Overlay -Path 'Overlay'
    $c['workspaces'] = @(foreach ($w in $ctx.Workspaces) { Get-PsWorkspaceTree -Context $ctx -Workspace $w })
    [ordered]@{
        stop        = $null
        context     = $c
        findings    = (ConvertTo-ParityTree -Value $ctx.Findings -Path 'Findings')
        selected    = (ConvertTo-ParityTree -Value $selected -Path 'Selected')
        selectError = $selectError
    }
}

# ---- Rust-бік ----------------------------------------------------------------------------------------------

function script:ConvertFrom-JsonElementTree($E) {
    switch ($E.ValueKind.ToString()) {
        'Object' { $h = [ordered]@{}; foreach ($p in $E.EnumerateObject()) { $h[$p.Name] = ConvertFrom-JsonElementTree $p.Value }; return $h }
        'Array' { return , @(foreach ($i in $E.EnumerateArray()) { ConvertFrom-JsonElementTree $i }) }
        'String' { return $E.GetString() }
        'Number' { return $E.GetInt64() }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function script:Invoke-RustPreflight {
    param([string]$Repo, [string]$Mode, [string]$Workspace, [string]$Source, [string[]]$Truth = @())
    $psi = [System.Diagnostics.ProcessStartInfo]::new($script:KitExe)
    foreach ($a in @('config-preflight', '-RepoRoot', $Repo, '-Mode', $Mode)) { $psi.ArgumentList.Add($a) }
    if ($Workspace) { $psi.ArgumentList.Add('-Workspace'); $psi.ArgumentList.Add($Workspace) }
    if ($Source) { $psi.ArgumentList.Add('-Source'); $psi.ArgumentList.Add($Source) }
    foreach ($t in $Truth) { $psi.ArgumentList.Add('-Truth'); $psi.ArgumentList.Add($t) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $tree = $null
    if ($out.Result.Trim()) { $doc = [System.Text.Json.JsonDocument]::Parse($out.Result); $tree = ConvertFrom-JsonElementTree $doc.RootElement }
    [pscustomobject]@{ Code = $p.ExitCode; Tree = $tree; Stdout = $out.Result; Stderr = $err.Result }
}

# ---- Порівняння --------------------------------------------------------------------------------------------

function script:Get-ParityKind($V) {
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { return 'bool' }
    if ($V -is [string]) { return 'string' }
    if ($V -is [System.Collections.IDictionary]) { return 'object' }
    if ($V -is [System.Collections.IList]) { return 'array' }
    'number'
}

# Розібрані значення; множина ключів кожного об'єкта рівна з обох боків. Повертає перелік розбіжностей.
function script:Compare-ParityTree {
    param($Ps, $Rust, [string]$Path = '$')
    $kp = Get-ParityKind $Ps; $kr = Get-ParityKind $Rust
    if ($kp -ne $kr) { return @("${Path}: PowerShell=$kp, Rust=$kr") }
    switch ($kp) {
        'null' { return @() }
        'object' {
            $diffs = [System.Collections.Generic.List[string]]::new()
            $extraPs = @($Ps.Keys | Where-Object { -not $Rust.Contains($_) }); $extraRs = @($Rust.Keys | Where-Object { -not $Ps.Contains($_) })
            if ($extraPs) { $diffs.Add("${Path}: ключі лише в PowerShell: $($extraPs -join ', ')") }
            if ($extraRs) { $diffs.Add("${Path}: ключі лише в Rust: $($extraRs -join ', ')") }
            foreach ($k in $Ps.Keys) { if ($Rust.Contains($k)) { foreach ($d in (Compare-ParityTree -Ps $Ps[$k] -Rust $Rust[$k] -Path "$Path.$k")) { $diffs.Add($d) } } }
            return $diffs.ToArray()
        }
        'array' {
            if ($Ps.Count -ne $Rust.Count) { return @("${Path}: довжина PowerShell=$($Ps.Count), Rust=$($Rust.Count)") }
            $diffs = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $Ps.Count; $i++) { foreach ($d in (Compare-ParityTree -Ps $Ps[$i] -Rust $Rust[$i] -Path "$Path[$i]")) { $diffs.Add($d) } }
            return $diffs.ToArray()
        }
        'string' { if ($Ps -ceq $Rust) { return @() } else { return @("${Path}: PowerShell='$Ps' / Rust='$Rust'") } }
        default { if ($Ps -eq $Rust) { return @() } else { return @("${Path}: PowerShell=$Ps / Rust=$Rust") } }
    }
}

# Перелік масивів накладки Rust упорядковується тим самим ключем, що й PowerShell-бік (Hashtable без порядку).
function script:Sort-RustOverlay($Tree) {
    $o = $Tree.context.overlay
    if ($o) {
        $o.infobases = @($o.infobases | Sort-Object { $_.name.ToLowerInvariant() })
        $o.workspaces = @($o.workspaces | Sort-Object { $_.path.ToLowerInvariant() })
        $o.storages = @($o.storages | Sort-Object { $_.key.ToLowerInvariant() })
    }
}

# Один прогін паритету: повертає перелік розбіжностей (порожній — зелено).
# Порядок перелічених імен (DT-INF, «Є: …») PowerShell бере з Sort-Object за культурою машини — для кириличних імен
# Rust сортує за точним правилом без культури (відома відмінність, ADR-0021 п. 1; порядок — Rust-тест):
# з -OrderInsensitive переліки порівнюються як множини без регістру.
function script:Edit-ParityStrings($Tree, [scriptblock]$Fn) {
    if ($Tree -is [string]) { return & $Fn $Tree }
    if ($Tree -is [System.Collections.IDictionary]) { foreach ($k in @($Tree.Keys)) { $Tree[$k] = Edit-ParityStrings $Tree[$k] $Fn }; return $Tree }
    if ($Tree -is [System.Collections.IList]) { for ($i = 0; $i -lt $Tree.Count; $i++) { $Tree[$i] = Edit-ParityStrings $Tree[$i] $Fn }; return , $Tree }
    $Tree
}
function script:ConvertTo-UnorderedLists([string]$Text) {
    $sort = { param($m) $a = [string[]]@($m.Groups[1].Value.ToLowerInvariant() -split ', '); [Array]::Sort($a, [StringComparer]::Ordinal); $a -join ', ' }
    $Text = [regex]::Replace($Text, '(?<=Є: )(.*)(?=\.$)', $sort)
    [regex]::Replace($Text, '(?<=не підтримує \()(.*?)(?=\): перетворіть)', $sort)
}

function script:Compare-ParityRun {
    param([string]$Repo, [string]$Mode, [string]$Workspace, [string]$Source, [string[]]$Truth = @(), [switch]$OrderInsensitive)
    $ps = Get-PsParityResult -Repo $Repo -Mode $Mode -Workspace $Workspace -Source $Source -Truth $Truth
    $rs = Invoke-RustPreflight -Repo $Repo -Mode $Mode -Workspace $Workspace -Source $Source -Truth $Truth
    if ($rs.Code -ne 0 -or $null -eq $rs.Tree) { return @("Rust: код $($rs.Code), stderr: $($rs.Stderr)") }
    $tree = $rs.Tree
    if ($tree.stop) { $tree.stop = [ordered]@{ message = $tree.stop.message } }
    else { Sort-RustOverlay $tree }
    if ($OrderInsensitive) {
        $ps = Edit-ParityStrings $ps { param($s) ConvertTo-UnorderedLists $s }
        $tree = Edit-ParityStrings $tree { param($s) ConvertTo-UnorderedLists $s }
    }
    Compare-ParityTree -Ps $ps -Rust $tree
}

# ---- Корпус неправильних файлів ----------------------------------------------------------------------------

# Закритий перелік відомих відмінностей Rust від PowerShell — ДЖЕРЕЛО ПРАВДИ гейта. Фікстура `parity: class` мусить мати `decision` з цього переліку; нова відмінність починається
# з рядка тут: що робить PowerShell, що робить Rust і чому, хто вирішив.
#   KD-1 текст помилки розбору YAML — лише файл і місце, без тексту парсера (ADR-0021 п. 4)
#   KD-2 кілька YAML-документів — відмова з місцем другого `---`
#   KD-3 рядкові поля — вихідний текст скаляра або відмова; `version: 1.0` відхиляється
#   KD-4 YAML-тег у значенні чи ключі — відмова з місцем, без цитування
#   KD-5 список чи мапа на місці скаляра — відмова без значення
#   KD-6 ім'я ключа рядка підключення — лише з відомого переліку (ADR-0021 п. 5; «непарні лапки» теж)
#   KD-7 `File=` з префіксом пристрою чи адмінським ресурсом, ціль посилання не абсолютна — відмова «kit не може довести…»
#   KD-8 порядок імен (DT-INF, «Є: …») не залежить від культури; дедуплікація за тим самим правилом
#   KD-9 запис `sources` без значення — ім'я не друкується
$script:KnownDifferences = 'KD-1', 'KD-2', 'KD-3', 'KD-4', 'KD-5', 'KD-6', 'KD-7', 'KD-8', 'KD-9'

# Заголовок фікстури: рядки `#@ ключ: значення` на початку файла. Ключі: target (manifest|overlay|project|local),
# check (знахідка PowerShell: manifest|overlay|workspace|source|agentBase|none), starts (початок її тексту; {path} —
# шлях файла-цілі, {ws} — тека воркспейсу), parity (text — типово, class — відома відмінність: Rust-бік свій),
# decision (для class: KD-n із $script:KnownDifferences), rust-check, rust-starts (для class), rust-also (для class:
# початок тексту ДРУГОЇ проблеми Rust — помилки бази агента чи перетинів, коли вона не збігається з rust-starts), note.
function script:Read-ConfigBadFixture([string]$File) {
    $meta = @{ file = $File; parity = 'text' }
    foreach ($line in (Get-Content -LiteralPath $File -Encoding UTF8)) {
        if ($line -notmatch '^#@ (?<k>[a-z-]+):\s?(?<v>.*)$') { break }
        $meta[$Matches['k']] = $Matches['v']
    }
    if (-not $meta.Contains('rust-check')) { $meta['rust-check'] = $meta['check'] }
    if (-not $meta.Contains('rust-starts')) { $meta['rust-starts'] = $meta['starts'] }
    $meta
}

$script:CorpusTargets = @{ manifest = 'v8storagekit.yaml'; overlay = 'v8storagekit.local.yaml'; project = 'Alpha_SMB/v8project.yaml'; local = 'Alpha_SMB/v8project.local.yaml' }

function script:Expand-ParityText([string]$Text, [string]$Repo, [string]$Target) {
    $root = Resolve-V8RepoRoot -Path $Repo
    $path = Join-Path $root $script:CorpusTargets[$Target]
    $ws = Join-Path $root 'Alpha_SMB'
    $Text.Replace('{path}', $path).Replace('{ws}', $ws)
}

# Базовий добрий репозиторій для корпусу (зібраний один раз) копіюється на кожен випадок.
function script:Copy-ParityBaseline([string]$Baseline, [string]$Dest) {
    Copy-Item -LiteralPath $Baseline -Destination $Dest -Recurse -Force
    $Dest
}

function script:Install-ConfigBadFixture([hashtable]$Meta, [string]$Repo) {
    $target = Join-Path $Repo $script:CorpusTargets[$Meta.target]
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $Meta.file -Destination $target -Force
}

# Перша проблема результату (PS чи Rust у спільній формі): зупинка, перша знахідка error, помилка бази агента або
# перетинів першого воркспейсу. Повертає @(перевірка; текст); 'none' — проблем немає.
function script:Get-FirstProblem($Tree) {
    if ($Tree.stop) { return @('stop', $Tree.stop.message) }
    $e = @($Tree.findings | Where-Object { $_.level -eq 'error' })[0]
    if ($e) { return @($e.check, $e.message) }
    $w = @($Tree.context.workspaces)[0]
    if ($w -and $w.agentBase.error) { return @('agentBase', $w.agentBase.error) }
    if ($w -and $w.collisions.error) { return @('agentBase', $w.collisions.error) }
    @('none', '')
}

# Усі проблеми результату Rust крім першої: друга знахідка error й помилки бази агента / перетинів першого воркспейсу
# з іншим текстом. Класова фікстура не може мати другої хибної проблеми (гейт інакше сліпий до всього, крім першої).
function script:Get-ExtraProblems($Tree) {
    $extra = [System.Collections.Generic.List[object]]::new()
    if ($Tree.stop) { return }
    $errors = @($Tree.findings | Where-Object { $_.level -eq 'error' })
    for ($i = 1; $i -lt $errors.Count; $i++) { $extra.Add(@('finding', $errors[$i].message)) }
    $first = (Get-FirstProblem $Tree)[1]
    $w = @($Tree.context.workspaces)[0]
    if ($w) {
        foreach ($pair in @(@('agentBase', $w.agentBase.error), @('collisions', $w.collisions.error))) {
            if ($pair[1] -and $pair[1] -cne $first) { $extra.Add($pair) }
        }
    }
    $extra.ToArray()
}

function script:Expand-ParityStarts([string]$Text, [string]$Repo, [string]$Target) {
    $root = Resolve-V8RepoRoot -Path $Repo
    $Text.Replace('{path}', (Join-Path $root $script:CorpusTargets[$Target])).Replace('{ws}', (Join-Path $root 'Alpha_SMB')).Replace('{root}', $root)
}
