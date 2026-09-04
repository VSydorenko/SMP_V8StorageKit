#Requires -Version 7
<#
.SYNOPSIS
    Завантажує вихідники розширення з git у дев-базу продукту.
.DESCRIPTION
    Зворотний напрямок контуру: git -> база. Крок «база -> сховище» виконує
    людина в Конфігураторі; цей скрипт сховища не торкається.
.EXAMPLE
    pwsh tools/load-ext.ps1 -RepoRoot <шлях до репо-споживача> -Product <Продукт>
.EXAMPLE
    pwsh tools/load-ext.ps1 -RepoRoot . -Product <Продукт> -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Product,
    [switch]$Apply,
    [switch]$UpdateDbCfg,
    [string]$RepoRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/RepoRoot.psm1') -Force
$repoRoot = Resolve-V8RepoRoot -Path $RepoRoot
Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force

# Перехідна зупинка (B2 → B4): без неї скрипт падає незрозуміло на Import-Module
# lib/SyncState.psm1 (вилучено в B2) замість чіткого повідомлення.
throw "load-ext.ps1 непрацездатний з B2 (конвенцію storage.json вилучено) і не буде відновлений: розкатка в базу людини суперечить §1.3; вихідники в базу агента накочує operation=build Уніки. Вилучається в B4."

Import-Module (Join-Path $PSScriptRoot 'lib/SyncState.psm1') -Force

$productPath = Join-Path $repoRoot $Product
$state       = Read-SyncState -ProductPath $productPath
$sourceDir   = Join-Path $productPath $state.SourcePath
$localFile   = Join-Path $productPath 'v8project.local.yaml'

$local      = Read-V8LocalConnection -Path $localFile
$connection = $local.Connection
$user       = $local.User

$ibSwitch = ConvertTo-V8IbSwitch -Connection $connection

Write-Host "Продукт:    $Product"
Write-Host "Розширення: $($state.ExtensionName)"
Write-Host "Вихідники:  $sourceDir"
Write-Host "База:       $ibSwitch"

if (-not $Apply) {
    Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
    return
}

# Не називати змінну $args — це автоматична змінна PowerShell.
$designerArgs = @('/LoadConfigFromFiles "{0}" -Extension {1}' -f $sourceDir, $state.ExtensionName)
if ($UpdateDbCfg) { $designerArgs += '/UpdateDBCfg -Extension {0}' -f $state.ExtensionName }

$result = Invoke-V8Designer -IbSwitch $ibSwitch -User $user -Arguments $designerArgs
if ($result.ExitCode -ne 0) {
    throw "Завантаження розширення не вдалося: $($result.Output)"
}

Write-Host 'Готово. Зміни у сховище заносить людина в Конфігураторі.' -ForegroundColor Green
