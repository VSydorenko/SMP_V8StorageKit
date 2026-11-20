# Ported from superpowers 7.0.1 (MIT, (c) 2025 Jesse Vincent), modified for v8storagekit. See LICENSE-superpowers.
<#
.SYNOPSIS
  Зупиняє сервер visual companion. Теку сесії не видаляє, крім ефемерної visual-companion-* у temp.
.PARAMETER SessionDir
  Тека сесії (батьківська для screen_dir).
.NOTES
  Друкує {"status": "stopped"} | {"status": "stale_pid"} | {"status": "not_running"}.
  Процес зупиняється примусово (на Windows немає м'якого сигналу), тому server-stopped
  із reason пише цей скрипт.
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$SessionDir = '')

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Out-Json([string]$Text, [int]$Code = 0) {
    [Console]::Out.WriteLine($Text)
    exit $Code
}

if (-not $SessionDir) { Out-Json '{"error": "Usage: stop-server.ps1 <session_dir>"}' 1 }

$stateDir = Join-Path $SessionDir 'state'
$pidFile = Join-Path $stateDir 'server.pid'
$idFile = Join-Path $stateDir 'server-instance-id'

function Set-Stopped([string]$Reason) {
    Remove-Item -LiteralPath (Join-Path $stateDir 'server-info') -Force -ErrorAction SilentlyContinue
    $obj = '{"reason":"' + $Reason + '","timestamp":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '}'
    [IO.File]::WriteAllText((Join-Path $stateDir 'server-stopped'), "$obj`n", $utf8)
}

# Процес — наш сервер, лише якщо його командний рядок містить id цього запуску.
function Test-OurServer([int]$ProcId) {
    if (-not (Test-Path -LiteralPath $idFile)) { return $false }
    $id = (Get-Content -LiteralPath $idFile -Raw).Trim()
    if ($id -notmatch '^[A-Za-z0-9_-]{32,64}$') { return $false }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcId" -ErrorAction SilentlyContinue
    if (-not $proc -or -not $proc.CommandLine) { return $false }
    return $proc.CommandLine.Contains("--brainstorm-server-id=$id")
}

if (-not (Test-Path -LiteralPath $pidFile)) { Out-Json '{"status": "not_running"}' }

$serverPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()

if (-not (Test-OurServer $serverPid)) {
    Remove-Item -LiteralPath $pidFile, $idFile -Force -ErrorAction SilentlyContinue
    Set-Stopped 'stale_pid'
    Out-Json '{"status": "stale_pid"}'
}

Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
}
if (Get-Process -Id $serverPid -ErrorAction SilentlyContinue) {
    Out-Json '{"status": "failed", "error": "process still running"}' 1
}

Remove-Item -LiteralPath $pidFile, $idFile, (Join-Path $stateDir 'server.log'), (Join-Path $stateDir 'server.err.log') -Force -ErrorAction SilentlyContinue
Set-Stopped 'stop-server.ps1'

# Ефемерну сесію без проєкту прибираємо; тека проєкту лишається для перегляду макетів.
$tmpRoot = [IO.Path]::GetTempPath().TrimEnd('\', '/')
$full = [IO.Path]::GetFullPath($SessionDir)
$parent = (Split-Path -Parent $full).TrimEnd('\', '/')
if ((Split-Path -Leaf $full) -like 'visual-companion-*' -and $parent -eq $tmpRoot) {
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
}

Out-Json '{"status": "stopped"}'
