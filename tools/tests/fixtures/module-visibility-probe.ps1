#Requires -Version 7
<#
.SYNOPSIS
    Допоміжний скрипт для ModuleImportOrder.Tests.ps1. Імпортує lib-модулі у переданому
    порядку (для kit.ps1 — з tools/lib/module-order.txt); будь-який виняток імпорту дає
    ненульовий код виходу.

    Навмисно окремий файл, а не інлайн-рядок у тесті: так probe можна прогнати й
    вручну.
.NOTES
    $ModulesCsv — рядок через кому, а не [string[]]$Modules: масив, переданий у команду
    рядка через оператор `&` зовнішньому процесу pwsh, PowerShell розбиває на окремі
    токени командного рядка, і -File-байндер дочірнього pwsh прив'язує до параметра-масиву
    лише перший токен.
#>
param(
    [Parameter(Mandatory)][string]$LibDir,
    [Parameter(Mandatory)][string]$ModulesCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in ($ModulesCsv -split ',')) {
    Import-Module (Join-Path $LibDir "$m.psm1") -Force
}
