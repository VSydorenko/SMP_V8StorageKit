<#
.SYNOPSIS
  Делегує задачу локальному OpenAI Codex CLI як headless-компаньйону, з вартовим старту, і
  повертає його фінальну відповідь у stdout. Реалізує гарантії ранбука codex-audit-runbook.

.DESCRIPTION
  Обгортка над `codex exec` для виклику з Claude Code:
    * НЮАНС 1 (локальне репо): резолвить -Repo в абсолютний шлях, за замовчуванням sandbox=read-only
      (read-only блокує мережу → Codex не може тягнути remote), друкує repo/sandbox для контролю.
    * НЮАНС 3 (реальний старт): вартовий чекає банер сесії Codex; якщо старту немає за
      -StartupTimeoutSec — це фантомний запуск, не чекаємо (exit 6). Загальний ліміт -OverallTimeoutSec
      (exit 7). Успіх друкує '✔ Codex стартував' + session id.
  Чисте фінальне повідомлення перехоплюється через `codex exec -o` і друкується після
  '----- CODEX RESULT -----'. Модель за замовчуванням gpt-5.6-sol (config-модель може бути API-only).

.EXAMPLE
  codex-delegate.ps1 -Task "Аудит безпеки src/transport" -Repo "<абсолютний корінь репо>" -Effort high
.EXAMPLE
  codex-delegate.ps1 -Review -Task "Знайди баги в останньому коміті" -Repo "<абсолютний корінь репо>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Task,

    [string]$Repo = (Get-Location).Path,

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'read-only',

    [string]$Model = 'gpt-5.6-sol',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort = 'medium',

    # Вбудований `codex exec review` (структурований код-рев'ю по репо)
    [switch]$Review,

    # Скільки секунд чекати банер сесії, перш ніж визнати запуск фантомним
    [int]$StartupTimeoutSec = 90,

    # Загальний ліміт на весь прогін
    [int]$OverallTimeoutSec = 900
)

$ErrorActionPreference = 'Stop'

# --- Знайти бінар codex (PATH у поточному процесі може бути застарілим) ---
$codex = (Get-Command codex -ErrorAction SilentlyContinue).Source
if (-not $codex) {
    $ps1 = Join-Path $env:APPDATA 'npm\codex.ps1'
    $cmd = Join-Path $env:APPDATA 'npm\codex.cmd'
    if (Test-Path $ps1) { $codex = $ps1 }
    elseif (Test-Path $cmd) { $codex = $cmd }
}
if (-not $codex -or -not (Test-Path $codex)) {
    Write-Error 'Codex CLI не знайдено. Встанови: npm install -g @openai/codex'
    exit 3
}

# --- НЮАНС 1: локальне репо ---
try { $Repo = (Resolve-Path -LiteralPath $Repo).Path }
catch { Write-Error "Шлях до репозиторію не існує: $Repo"; exit 4 }
$isGit = Test-Path (Join-Path $Repo '.git')

# --- Файл для чистого фінального повідомлення ---
$outFile = Join-Path ([IO.Path]::GetTempPath()) ('codex-' + [guid]::NewGuid().ToString('N') + '.txt')

$argv = @(
    'exec',
    '-s', $Sandbox,
    '-m', $Model,
    '-C', $Repo,
    '-c', "model_reasoning_effort=$Effort",
    '-o', $outFile
)
if ($Review) { $argv += 'review' }
$argv += $Task

Write-Host "▶ codex exec  (sandbox=$Sandbox, model=$Model, effort=$Effort)" -ForegroundColor Cyan
Write-Host "  repo: $Repo  (git: $isGit)" -ForegroundColor DarkGray
if ($Sandbox -eq 'read-only') {
    Write-Host "  sandbox=read-only → мережа заблокована, Codex працює лише з локальною копією" -ForegroundColor DarkGray
}
else {
    Write-Host "  !! sandbox=$Sandbox — Codex може ЗМІНЮВАТИ файли; переконайся, що це навмисно і дерево чисте" -ForegroundColor Yellow
}

# --- Запуск у фоновому job для вартового ---
$job = Start-Job -ScriptBlock { param($c, $a) & $c @a 2>&1 } -ArgumentList $codex, $argv

$acc = New-Object System.Collections.Generic.List[string]
function Drain {
    $out = Receive-Job $job -ErrorAction SilentlyContinue
    if ($out) { foreach ($l in $out) { $acc.Add([string]$l) } }
}

# --- НЮАНС 3: вартовий старту ---
$started = $false
$startDeadline = (Get-Date).AddSeconds($StartupTimeoutSec)
while ((Get-Date) -lt $startDeadline) {
    Start-Sleep -Milliseconds 500
    Drain
    $joined = ($acc -join "`n")
    if ($joined -match 'session id:' -or $joined -match 'workdir:') { $started = $true; break }
    if ($job.State -eq 'Completed') { $started = $true; break }
    if ($job.State -eq 'Failed') { break }
}
if (-not $started) {
    Write-Host "✘ Codex НЕ підтвердив старт за ${StartupTimeoutSec}s — ймовірно ФАНТОМНИЙ запуск. Зупиняю, не чекаю." -ForegroundColor Red
    Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $outFile -ErrorAction SilentlyContinue
    if ($acc.Count) { Write-Host '--- останній вивід ---'; $acc | Select-Object -Last 15 | ForEach-Object { Write-Output $_ } }
    exit 6
}
$sid = ($acc | Select-String -Pattern 'session id:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
Write-Host "✔ Codex стартував і працює$(if($sid){"  (session $sid)"})" -ForegroundColor Green

# --- Загальний ліміт: чекаємо завершення ---
$overallDeadline = (Get-Date).AddSeconds($OverallTimeoutSec)
while ($job.State -eq 'Running' -and (Get-Date) -lt $overallDeadline) {
    Start-Sleep -Milliseconds 750
    Drain
}
if ($job.State -eq 'Running') {
    Write-Host "✘ Перевищено загальний ліміт ${OverallTimeoutSec}s — зупиняю Codex." -ForegroundColor Red
    Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $outFile -ErrorAction SilentlyContinue
    Write-Host '--- хвіст виводу ---'; $acc | Select-Object -Last 20 | ForEach-Object { Write-Output $_ }
    exit 7
}
Drain
Remove-Job $job -Force -ErrorAction SilentlyContinue

# --- Результат ---
if (Test-Path $outFile) {
    $msg = Get-Content $outFile -Raw
    Remove-Item $outFile -ErrorAction SilentlyContinue
    Write-Output '----- CODEX RESULT -----'
    Write-Output $msg
    exit 0
}
else {
    Write-Host "Codex завершився без фінального повідомлення. Хвіст виводу:" -ForegroundColor Yellow
    $acc | Select-Object -Last 25 | ForEach-Object { Write-Output $_ }
    exit 5
}
