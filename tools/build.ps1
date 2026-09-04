#Requires -Version 7
<#
.SYNOPSIS
    Збирає .epf обробок з epf/src у build/artifacts.
.DESCRIPTION
    Перехідний скрипт до появи kit build (B4); .cfe збирає operation=make Unica.
.EXAMPLE
    pwsh tools/build.ps1 -RepoRoot <шлях до репо-споживача> -Product <Продукт> -Apply
.EXAMPLE
    pwsh tools/build.ps1 -RepoRoot . -Product epf -Apply
#>
[CmdletBinding()]
param(
    [string]$Product,
    [switch]$Apply,
    [string]$RepoRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/RepoRoot.psm1') -Force
$repoRoot = Resolve-V8RepoRoot -Path $RepoRoot
Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force

$outDir  = Join-Path $repoRoot 'build/artifacts'
$buildIb = Join-Path $repoRoot 'build/build-ib'

# Перехідний стан (B2 → B4): збірка .cfe вилучена — це operation=make Уніки (спека §5), а
# storage.json, за яким цей скрипт знаходив розширення, більше не існує. Лишається .epf.
if ($Product -and $Product -ne 'epf') {
    throw "build.ps1 збирає лише .epf (тека epf/src). Збірка .cfe — operation=make Unica у базі агента; збирання артефактів — kit build (B4)."
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'epf/src'))) {
    throw "У $repoRoot немає epf/src — зовнішніх обробок для збірки не знайдено."
}

Write-Host 'Збирати: epf'
Write-Host "Куди:    $outDir"
if (-not $Apply) {
    Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
    return
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path $buildIb -MustBeUnder (Join-Path $repoRoot 'build'))
foreach ($desc in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'epf/src') -Filter '*.xml' -File) {
    $name   = [System.IO.Path]::GetFileNameWithoutExtension($desc.Name)
    $target = Join-Path $outDir "$name.epf"
    Write-Host "→ $name.epf"
    $r = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
        '/LoadExternalDataProcessorOrReportFromFiles "{0}" "{1}"' -f $desc.FullName, $target)
    if ($r.ExitCode -ne 0) { throw "Збірка $name не вдалася: $($r.Output)" }
}
Get-ChildItem -LiteralPath $outDir | Select-Object Name, Length | Format-Table
Write-Host 'Готово.' -ForegroundColor Green
