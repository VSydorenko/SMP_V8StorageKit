#Requires -Version 7
<#
.SYNOPSIS
    Вхід команд процесу для обгорток bin/: pwsh -NoProfile -File tools/kit-process.ps1 <команда> [аргументи].
.DESCRIPTION
    Навмисно БЕЗ param-блоку: усі токени доходять до команди сирими в $args. Через tools/kit.ps1 так
    не вийде — його параметри -RepoRoot/-Workspace/-Source/-Apply і загальні параметри PowerShell
    перехоплюють токени команд процесу ще на прив'язці (`sdd fix 3 -Source controller` віддав би
    -Source диспетчеру, `review-pack -Out x` — неоднозначний префікс -OutVariable/-OutBuffer), а
    `--` у `pwsh -File` для скрипта з [CmdletBinding()] дає помилку прив'язки (вимір 2026-11-19).

    Корінь репозиторію — поточна тека (як process.cwd() в agent-kit). Імпортуються лише модулі
    розділу «процес» з tools/lib/module-order.txt: без модулів сховища старт коротший.
    Контракт кодів виходу й помилок — tools/lib/KitCli.psm1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = Join-Path $PSScriptRoot 'lib'
$inSection = $false
foreach ($line in Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -match '^#\s*==\s*процес\s*==') { $inSection = $true; continue }
    if (-not $inSection -or -not $t -or $t.StartsWith('#')) { continue }
    Import-Module (Join-Path $libDir "$t.psm1") -Force
}
if (-not (Get-Command -Name Invoke-KitProcessEntry -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('kit-process: ERROR у tools/lib/module-order.txt немає розділу «# == процес ==» з KitCli')
    exit 1
}

$command = if ($args.Count) { [string]$args[0] } else { '' }
$rest = [string[]]@($args | Select-Object -Skip 1 | ForEach-Object { [string]$_ })
exit (Invoke-KitProcessEntry -Command $command -Arguments $rest -RepoRoot (Get-Location).Path -ToolsDir $PSScriptRoot)
