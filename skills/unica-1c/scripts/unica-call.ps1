#Requires -Version 7
<#
Виклик MCP-сервера `unica` поза сесією Claude Code (діагностика, перевірка після оновлення).

  pwsh -NoProfile -File unica-call.ps1 --tools                  # імена всіх інструментів
  pwsh -NoProfile -File unica-call.ps1 --schema unica.view      # опис, required і властивості
  pwsh -NoProfile -File unica-call.ps1 <tool> '<json-args>'     # виклик (потребує контексту хоста)

Плагін шукає сам: найбільша версія в кеші `<тека конфігурації Claude>/plugins/cache/unica/unica`.
Сервер запускається командою з `.mcp.json` плагіна. Перевизначення: CLAUDE_PLUGIN_ROOT=<кеш>/<версія>,
UNICA_PLUGIN_CACHE. Коди виходу: 0 — успіх, 1 — помилка сервера/інструмента, 64 — невірне
використання, 66 — не знайдено каталог плагіна чи команду сервера.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$cacheRoot = if ($env:UNICA_PLUGIN_CACHE) { $env:UNICA_PLUGIN_CACHE } else { Join-Path $configDir 'plugins/cache/unica/unica' }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) {
    # Найбільша версія за номером, а не за mtime: оновлення плагіна торкається теки старої версії.
    $cands = @()
    if (Test-Path -LiteralPath $cacheRoot) {
        foreach ($d in Get-ChildItem -LiteralPath $cacheRoot -Directory) {
            if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.mcp.json') -PathType Leaf)) { continue }
            $v = $null
            if ([version]::TryParse(($d.Name -replace '[-+].*$', ''), [ref]$v)) { $cands += [pscustomobject]@{ V = $v; P = $d.FullName } }
        }
    }
    if ($cands) { $pluginRoot = ($cands | Sort-Object V | Select-Object -Last 1).P }
}
if (-not $pluginRoot -or -not (Test-Path -LiteralPath $pluginRoot -PathType Container)) {
    [Console]::Error.WriteLine("Не знайдено каталог плагіна unica у $cacheRoot"); exit 66
}

$first = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$second = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
switch ($first) {
    { $_ -in '--tools', '--schema' } { $method = 'tools/list'; $payload = '{}' }
    '' { [Console]::Error.WriteLine('usage: unica-call.ps1 [--tools|--schema <tool>|<tool> <json-args>]'); exit 64 }
    default {
        $method = 'tools/call'
        $argsJson = if ($second) { $second } else { '{}' }
        $payload = '{"name":' + (ConvertTo-Json $first -Compress) + ',"arguments":' + $argsJson + '}'
    }
}
$want = if ($first -eq '--schema') { $second } else { '' }

$lines = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"unica-call","version":"1.0"}}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"' + $method + '","params":' + $payload + '}'
)

# Команда, аргументи й env сервера — з `.mcp.json` плагіна; токен кореня хост підставляє сам.
$tok = '$' + '{CLAUDE_PLUGIN' + '_ROOT}'
$cmd = $null; $cmdArgs = @()
try {
    $mcp = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $pluginRoot '.mcp.json') | ConvertFrom-Json
    $srv = $mcp.mcpServers.unica
    $cmd = ([string]$srv.command).Replace($tok, $pluginRoot)
    $cmdArgs = @($srv.args | ForEach-Object { ([string]$_).Replace($tok, $pluginRoot) })
    if ($srv.env) {
        foreach ($p in $srv.env.PSObject.Properties) {
            $val = ([string]$p.Value).Replace($tok, $pluginRoot)
            if ($val -notmatch '\$\{') { Set-Item -LiteralPath "Env:$($p.Name)" -Value $val }
        }
    }
}
catch { $cmd = $null }
if (-not $cmd -or -not (Test-Path -LiteralPath $cmd)) {
    [Console]::Error.WriteLine("Не знайдено команду сервера з .mcp.json у $pluginRoot"); exit 66
}
$raw = ($lines -join "`n") + "`n" | & $cmd @cmdArgs 2>$null

# -AsHashtable: схеми інструментів можуть мати ключі, що різняться лише регістром.
foreach ($line in @($raw) -split "\r?\n") {
    if (-not $line.Trim()) { continue }
    try { $m = $line | ConvertFrom-Json -AsHashtable -Depth 100 } catch { continue }
    if ($m['id'] -ne 2) { continue }
    if ($m.ContainsKey('error')) { Write-Output ('ERROR: ' + ($m['error'] | ConvertTo-Json -Compress -Depth 20)); exit 1 }
    $r = $m['result']
    if ($r.ContainsKey('tools')) {
        $tools = @($r['tools'])
        if ($want) {
            $t = $tools | Where-Object { $_['name'] -eq $want } | Select-Object -First 1
            if (-not $t) { Write-Output "Немає інструмента $want"; exit 1 }
            Write-Output "$($t['name']) — $($t['description'])"
            $req = @($t['inputSchema']['required'])
            Write-Output ('required: ' + $(if ($req.Count) { ConvertTo-Json $req -Compress } else { '[]' }))
            $props = if ($t['inputSchema']['properties']) { @($t['inputSchema']['properties'].Keys) -join ', ' } else { '' }
            Write-Output "props: $props"
        }
        else {
            Write-Output "TOOLS: $($tools.Count)"
            Write-Output (([string[]]($tools | ForEach-Object { $_['name'] }) | Sort-Object { $_ } -CaseSensitive:$false) -join "`n")
        }
    }
    else {
        foreach ($c in @($r['content'])) { Write-Output ([string]$c['text']) }
        if ($r['isError']) { Write-Output '[isError=true]' }
    }
}
