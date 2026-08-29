#Requires -Version 7
<#
.SYNOPSIS
    Вивантажує базову конфігурацію з дев-бази продукту в <продукт>/cf/src.
.DESCRIPTION
    Потрібно для операцій Unica, яким треба знати склад конфігурації-власника:
    cfe.borrow, cfe.diff, cfe.validate. Займає 20-40 хвилин і 1-2 ГБ на диску.
.EXAMPLE
    pwsh tools/dump-config.ps1 -RepoRoot <шлях до репо-споживача> -Product <Продукт>
.EXAMPLE
    pwsh tools/dump-config.ps1 -RepoRoot . -Product <Продукт> -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Product,
    [switch]$Apply,
    [string]$RepoRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/RepoRoot.psm1') -Force
$repoRoot = Resolve-V8RepoRoot -Path $RepoRoot
Import-Module (Join-Path $PSScriptRoot 'lib/PathSafety.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force

$productPath = Join-Path $repoRoot $Product
$localFile   = Join-Path $productPath 'v8project.local.yaml'
$local       = Read-V8LocalConnection -Path $localFile
$connection  = $local.Connection
$user        = $local.User

$ibSwitch = ConvertTo-V8IbSwitch -Connection $connection
$target   = Join-Path $productPath 'cf/src'

Write-Host "Продукт: $Product"
Write-Host "База:    $ibSwitch"
Write-Host "Куди:    $target"

if (-not $Apply) {
    Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
    Write-Host 'Вивантаження триває 20-40 хвилин і займає 1-2 ГБ.' -ForegroundColor Cyan
    return
}

Assert-SafeWorkPath -Path $target -MustBeUnder $productPath -Description "target вивантаження продукту $Product"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null

$result = Invoke-V8Designer -IbSwitch $ibSwitch -User $user -Arguments @(
    '/DumpConfigToFiles "{0}"' -f $target)

if ($result.ExitCode -ne 0) {
    throw "Вивантаження конфігурації не вдалося: $($result.Output)"
}

$count = (Get-ChildItem -LiteralPath $target -Recurse -File).Count
Write-Host "Готово. Файлів: $count" -ForegroundColor Green
