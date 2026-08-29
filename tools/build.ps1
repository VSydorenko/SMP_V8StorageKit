#Requires -Version 7
<#
.SYNOPSIS
    Збирає .cfe розширень і .epf обробок у build/artifacts.
.DESCRIPTION
    Збірка йде платформою напряму, а не через Unica: операція make в Unica на Windows
    падає на публікації артефакту ("Отказано в доступе, os error 5"), лишаючи файл
    у стейджі.
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
Import-Module (Join-Path $PSScriptRoot 'lib/SyncState.psm1') -Force

$stubPath  = Join-Path $PSScriptRoot 'assets/empty-extension'
$outDir    = Join-Path $repoRoot 'build/artifacts'
$buildIb   = Join-Path $repoRoot 'build/build-ib'

# Продукт — тека з storage.json у корені репо; epf — за наявності epf/src.
# Вшитого списку немає: kit обслуговує будь-який репозиторій цієї схеми.
# @(...) навколо ВСЬОГО if/else — інакше рівно один знайдений продукт (звичайний випадок
# для репо з одним розширенням) розгортається PowerShell у скаляр при присвоєнні з
# гілки if/else. @(...) лише навколо внутрішнього $found тут не рятує — розгортання
# відбувається саме на межі присвоєння $products.
$products = @(if ($Product) { @($Product) } else {
    $found = @(Get-ChildItem -LiteralPath $repoRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'storage.json') } |
        Sort-Object Name | Select-Object -ExpandProperty Name)
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'epf/src')) { $found += 'epf' }
    if (-not $found) {
        throw "У $repoRoot не знайдено жодного продукту: ні теки зі storage.json, ні epf/src."
    }
    $found
})

Write-Host "Збирати: $($products -join ', ')"
Write-Host "Куди:    $outDir"

if (-not $Apply) {
    Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
    return
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

foreach ($p in $products) {
    $productPath = Join-Path $repoRoot $p

    if ($p -eq 'epf') {
        # Кожна обробка — окремий корінь: <Name>.xml поруч із текою <Name>.
        $ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path $buildIb -MustBeUnder (Join-Path $repoRoot 'build'))
        foreach ($desc in Get-ChildItem -LiteralPath (Join-Path $productPath 'src') -Filter '*.xml' -File) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($desc.Name)
            $target = Join-Path $outDir "$name.epf"
            Write-Host "→ $name.epf"
            $r = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
                '/LoadExternalDataProcessorOrReportFromFiles "{0}" "{1}"' -f $desc.FullName, $target)
            if ($r.ExitCode -ne 0) { throw "Збірка $name не вдалася: $($r.Output)" }
        }
        continue
    }

    $state = Read-SyncState -ProductPath $productPath
    $src   = Join-Path $productPath $state.SourcePath
    $target = Join-Path $outDir "$($state.ExtensionName).cfe"
    Write-Host "→ $($state.ExtensionName).cfe"

    $ibSwitch = New-ExtensionInfobase -Path $buildIb -ExtensionName $state.ExtensionName `
        -StubPath $stubPath -MustBeUnder (Join-Path $repoRoot 'build')
    $load = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
        '/LoadConfigFromFiles "{0}" -Extension {1}' -f $src, $state.ExtensionName)
    if ($load.ExitCode -ne 0) { throw "Завантаження $($state.ExtensionName) не вдалося: $($load.Output)" }

    $dump = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
        '/DumpCfg "{0}" -Extension {1}' -f $target, $state.ExtensionName)
    if ($dump.ExitCode -ne 0) { throw "Збірка $($state.ExtensionName) не вдалася: $($dump.Output)" }
}

Get-ChildItem -LiteralPath $outDir | Select-Object Name, Length | Format-Table
Write-Host 'Готово.' -ForegroundColor Green
