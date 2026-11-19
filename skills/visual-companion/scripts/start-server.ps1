# Ported from superpowers 7.0.1 (MIT, (c) 2025 Jesse Vincent), modified for v8storagekit. See LICENSE-superpowers.
# Changes: PowerShell замість bash; файли сесії в <project>/.agents/out/companion/ замість .superpowers/brainstorm/.
<#
.SYNOPSIS
  Запускає сервер visual companion і друкує один рядок JSON server-started (url, screen_dir, state_dir).
.PARAMETER ProjectDir
  Корінь проєкту: файли сесії лежать у <ProjectDir>/.agents/out/companion/<id>/. Без нього — тимчасова тека.
.PARAMETER BindHost
  Інтерфейс для прив'язки (типово 127.0.0.1; 0.0.0.0 — для віддаленого середовища).
.PARAMETER UrlHost
  Ім'я хоста в URL, який повертається.
.PARAMETER IdleTimeoutMinutes
  Зупинка після n хвилин простою (типово 240 = 4 год).
.PARAMETER Open
  Відкрити браузер на першому екрані (лише після згоди власника).
.PARAMETER Foreground
  Запустити сервер у цьому ж виклику, не від'єднуючи.
.NOTES
  Середовище: VC_START_TIMEOUT — секунд очікування старту (типово 15).
  Помилка: один рядок {"error": "..."} і код виходу 1.
#>
[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$BindHost = '127.0.0.1',
    [string]$UrlHost = '',
    [string]$IdleTimeoutMinutes = '',
    [switch]$Open,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [Console]::Out.WriteLine((@{ error = $Message } | ConvertTo-Json -Compress))
    exit 1
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$scriptDir = $PSScriptRoot

if (-not $UrlHost) {
    $UrlHost = if ($BindHost -eq '127.0.0.1' -or $BindHost -eq 'localhost') { 'localhost' } else { $BindHost }
}

if ($IdleTimeoutMinutes -ne '') {
    if ($IdleTimeoutMinutes -notmatch '^[0-9]+$' -or [int64]$IdleTimeoutMinutes -lt 1) {
        Fail '-IdleTimeoutMinutes must be a positive integer'
    }
    $env:BRAINSTORM_IDLE_TIMEOUT_MS = [string]([int64]$IdleTimeoutMinutes * 60 * 1000)
}

# Ліміт старту: завантаженій машині треба більше за 5 с, типово 15, власник може збільшити.
$startTimeout = if ($env:VC_START_TIMEOUT) { $env:VC_START_TIMEOUT } else { '15' }
if ($startTimeout -notmatch '^[0-9]+$' -or [int64]$startTimeout -lt 1) {
    Fail "VC_START_TIMEOUT must be a whole number of seconds >= 1, got '$startTimeout'"
}
$startTimeout = [int]$startTimeout

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) { Fail 'node not found in PATH' }

if ($Open) { $env:BRAINSTORM_OPEN = '1' }

$sessionId = "$PID-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
if ($ProjectDir) {
    $outRoot = Join-Path $ProjectDir '.agents/out'
    $companionRoot = Join-Path $outRoot 'companion'
    $sessionDir = Join-Path $companionRoot $sessionId
    # Порт і ключ тримаємо на проєкт: перезапуск повертає той самий URL, відкрита вкладка перепідключається.
    $env:BRAINSTORM_PORT_FILE = Join-Path $companionRoot '.last-port'
    $env:BRAINSTORM_TOKEN_FILE = Join-Path $companionRoot '.last-token'
} else {
    $sessionDir = Join-Path ([IO.Path]::GetTempPath()) "visual-companion-$sessionId"
}
$stateDir = Join-Path $sessionDir 'state'
$contentDir = Join-Path $sessionDir 'content'
$pidFile = Join-Path $stateDir 'server.pid'
$logFile = Join-Path $stateDir 'server.log'
$errFile = Join-Path $stateDir 'server.err.log'

try {
    New-Item -ItemType Directory -Force -Path $contentDir, $stateDir | Out-Null
    if ($ProjectDir) {
        # Тека .agents/out не комітиться: усе, що в ній, ігнорується.
        $gi = Join-Path $outRoot '.gitignore'
        if (-not (Test-Path -LiteralPath $gi)) { [IO.File]::WriteAllText($gi, "*`n", $utf8) }
    }
} catch {
    Fail "cannot create session directory: $($_.Exception.Message)"
}

$bytes = [byte[]]::new(24)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$serverId = ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $stateDir 'server-instance-id'), "$serverId`n", $utf8)

# Сторож власника: PID не передаємо (порожньо), як в оригіналі на Windows. Сервер зупиняється
# за idle-таймаутом (4 год) або stop-server.ps1.
$env:BRAINSTORM_OWNER_PID = ''
$env:BRAINSTORM_DIR = $sessionDir
$env:BRAINSTORM_HOST = $BindHost
$env:BRAINSTORM_URL_HOST = $UrlHost

$serverJs = Join-Path $scriptDir 'server.cjs'
$nodeArgs = @("`"$serverJs`"", "--brainstorm-server-id=$serverId")

if ($Foreground) {
    $p = Start-Process -FilePath $node.Source -ArgumentList $nodeArgs -WorkingDirectory $scriptDir -NoNewWindow -PassThru
    [IO.File]::WriteAllText($pidFile, "$($p.Id)`n", $utf8)
    $p.WaitForExit()
    exit $p.ExitCode
}

# Від'єднаний запуск. Start-Process з перенаправленням успадковує канали виклику, і Bash/pwsh-виклик
# не повертає керування, доки живе сервер (виміряно). ShellExecute (UseShellExecute) канали не
# успадковує, тож запускаємо через прихований cmd із перенаправленням у лог. Змінні BRAINSTORM_* cmd
# бере з цього процесу.
$inner = "`"$($node.Source)`" `"$serverJs`" --brainstorm-server-id=$serverId > `"$logFile`" 2> `"$errFile`""
$psi = [System.Diagnostics.ProcessStartInfo]::new($env:ComSpec, "/d /s /c `"$inner`"")
$psi.UseShellExecute = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$psi.WorkingDirectory = $scriptDir
$cmdProc = [System.Diagnostics.Process]::Start($psi)

# PID сервера — вузол-нащадок cmd (шукаємо за id запуску в командному рядку).
$p = $null
$findDeadline = [DateTime]::UtcNow.AddSeconds($startTimeout)
while (-not $p -and [DateTime]::UtcNow -lt $findDeadline) {
    $found = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("--brainstorm-server-id=$serverId") } | Select-Object -First 1
    if ($found) { $p = Get-Process -Id $found.ProcessId -ErrorAction SilentlyContinue }
    elseif ($cmdProc.HasExited) { break }
    else { Start-Sleep -Milliseconds 100 }
}
if (-not $p) {
    $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
    Fail "Server exited during start: $("$err".Trim())"
}
[IO.File]::WriteAllText($pidFile, "$($p.Id)`n", $utf8)

$deadline = [DateTime]::UtcNow.AddSeconds($startTimeout)
while ([DateTime]::UtcNow -lt $deadline) {
    $line = $null
    if (Test-Path -LiteralPath $logFile) {
        $line = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue | Where-Object { $_ -like '*server-started*' } | Select-Object -First 1
    }
    if ($line) {
        # Сервер має лишитися живим ще ~2 с (ловить процеси, які щось прибирає).
        $until = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $until) {
            if ($p.HasExited) {
                Fail "Server started but was killed. Retry in a persistent terminal with: pwsh -NoProfile -File `"$PSCommandPath`" -ProjectDir `"$ProjectDir`" -Foreground"
            }
            Start-Sleep -Milliseconds 100
        }
        [Console]::Out.WriteLine($line)
        exit 0
    }
    if ($p.HasExited) { break }
    Start-Sleep -Milliseconds 100
}

if ($p.HasExited) {
    $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
    Fail "Server exited during start: $("$err".Trim())"
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Fail "Server failed to start within $startTimeout seconds (raise VC_START_TIMEOUT on a loaded machine)"
