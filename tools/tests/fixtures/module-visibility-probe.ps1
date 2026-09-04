#Requires -Version 7
<#
.SYNOPSIS
    Допоміжний скрипт для ModuleImportOrder.Tests.ps1. Імпортує lib-модулі у переданому
    порядку і для кожної переданої команди друкує "Ім'я=True" або "Ім'я=False" залежно
    від того, чи видно її в глобальній області після всіх імпортів.

    Список команд і модулів передає ModuleImportOrder.Tests.ps1 — для kit.ps1 модулі
    бере з tools/lib/module-order.txt.

    Навмисно окремий файл, а не інлайн-рядок у тесті: так probe можна прогнати й
    вручну (наприклад, щоб побачити дефект наживо, а не лише в PesterAssertion).
.NOTES
    $ModulesCsv — рядок через кому, а не [string[]]$Modules: масив, переданий у команду
    рядка через оператор `&` зовнішньому процесу pwsh, PowerShell розбиває на окремі
    токени командного рядка, і -File-байндер дочірнього pwsh прив'язує до параметра-масиву
    лише перший токен, а решту трактує як зайві позиційні аргументи — "A positional
    parameter cannot be found that accepts argument '<друге значення>'". Той самий прийом,
    що вже був у $CommandsCsv, тепер і тут.
#>
param(
    [Parameter(Mandatory)][string]$LibDir,
    [Parameter(Mandatory)][string]$CommandsCsv,
    [Parameter(Mandatory)][string]$ModulesCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in ($ModulesCsv -split ',')) {
    Import-Module (Join-Path $LibDir "$m.psm1") -Force
}

foreach ($name in ($CommandsCsv -split ',')) {
    $found = [bool](Get-Command -Name $name -ErrorAction SilentlyContinue)
    "$name=$found"
}
