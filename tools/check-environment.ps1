#Requires -Version 7
<#
.SYNOPSIS
    Перевіряє середовище, потрібне для роботи конвеєра й для розробки самого kit.
.DESCRIPTION
    Читання й нічого більше: платформу не запускає, git-команд, що змінюють стан, не
    виконує, нічого не встановлює.

    Три категорії у виводі відповідають реальним залежностям, а не оформленню:

      Конвеєр       — без цього скрипти tools/ не запустяться взагалі.
      Розробка kit  — без цього не прогнати тести цього репозиторію.
      Вихідники     — конвеєр працюватиме повністю, але працювати з тим, що він
                      синхронізував, буде нічим. Сюди потрапляє плагін unica: у tools/
                      немає жодного його виклику (перевірено), тож він не потрібен для
                      синхронізації — він потрібен для редагування, валідації й
                      аналізу вихідників, які синхронізація кладе в git.

    Код виходу 1 — тільки коли провалилась перевірка категорії «Конвеєр». Решта
    виводиться як попередження й коду виходу не змінює: відсутність Pester чи unica —
    це неповне робоче місце, а не зламаний конвеєр, і зливати ці стани в один означало б
    приховати різницю, заради якої категорії й заведені.
.EXAMPLE
    pwsh -NoProfile -File tools/check-environment.ps1
.EXAMPLE
    pwsh -NoProfile -File tools/check-environment.ps1 -InstalledPluginsPath <шлях до реєстру>
#>
[CmdletBinding()]
param(
    [string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/Environment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force

$checks = [System.Collections.Generic.List[object]]::new()

# --- Конвеєр -----------------------------------------------------------------

$checks.Add((New-EnvironmentCheck -Name 'PowerShell 7+' -Category 'Конвеєр' -Ok $true `
    -Detail "$($PSVersionTable.PSVersion) — скрипти оголошують #Requires -Version 7"))

$git = Get-GitAvailability
$checks.Add((New-EnvironmentCheck -Name 'git' -Category 'Конвеєр' -Ok $git.Available `
    -Detail $(if ($git.Available) { $git.Version } else { $git.Reason })))

try {
    $v8 = Get-V8Path
    $checks.Add((New-EnvironmentCheck -Name 'Платформа 1С 8.3.27.x' -Category 'Конвеєр' -Ok $true -Detail $v8))
} catch {
    $checks.Add((New-EnvironmentCheck -Name 'Платформа 1С 8.3.27.x' -Category 'Конвеєр' -Ok $false `
        -Detail $_.Exception.Message))
}

# --- Розробка kit ------------------------------------------------------------

$pester = Get-PesterAvailability
$checks.Add((New-EnvironmentCheck -Name 'Pester 5+' -Category 'Розробка kit' -Ok $pester.Available `
    -Detail $(if ($pester.Available) { "версія $($pester.Version)" } else { $pester.Reason })))

# --- Вихідники ---------------------------------------------------------------

$unica = Get-UnicaInstallation -InstalledPluginsPath $InstalledPluginsPath
$unicaOk = $unica.Installed -and $unica.PathExists
$unicaDetail = if ($unicaOk) {
    "версія $($unica.Version), $($unica.InstallPath)"
} else {
    $unica.Reason
}
$checks.Add((New-EnvironmentCheck -Name 'Плагін unica' -Category 'Вихідники' -Ok $unicaOk -Detail $unicaDetail))

# --- Вивід -------------------------------------------------------------------

Write-Host ''
Write-Host 'Середовище v8storagekit'
Write-Host '======================='

foreach ($category in @('Конвеєр', 'Розробка kit', 'Вихідники')) {
    $inCategory = @($checks | Where-Object { $_.Category -eq $category })
    if ($inCategory.Count -eq 0) { continue }

    Write-Host ''
    Write-Host "$category`:"
    foreach ($check in $inCategory) {
        $mark = if ($check.Ok) { '[+]' } else { '[-]' }
        Write-Host ("  {0} {1} — {2}" -f $mark, $check.Name, $check.Detail)
    }
}

$blocking = @($checks | Where-Object { -not $_.Ok -and $_.Category -eq 'Конвеєр' })
$warnings = @($checks | Where-Object { -not $_.Ok -and $_.Category -ne 'Конвеєр' })

Write-Host ''
if ($blocking.Count -gt 0) {
    Write-Host "Конвеєр запустити не вийде: не виконано $($blocking.Count) обов'язкових умов(и)."
} else {
    Write-Host 'Конвеєр запуститься: усі обов''язкові умови виконано.'
}

if ($warnings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Попередження (коду виходу не змінюють):'
    foreach ($w in $warnings) {
        $what = switch ($w.Category) {
            'Розробка kit' { 'не прогнати тести цього репозиторію' }
            'Вихідники'    { 'синхронізація працюватиме, але редагувати й валідовувати вихідники буде нічим' }
            default        { 'неповне робоче місце' }
        }
        Write-Host ("  {0}: {1}" -f $w.Name, $what)
    }

    if (-not $unicaOk) {
        # Адреси не вгадані: repository взято з маніфесту самого плагіна
        # (.claude-plugin/plugin.json у його кеші), ім'я маркетплейсу — з
        # ~/.claude/plugins/known_marketplaces.json, а форма 'unica@unica' — це той
        # самий ключ, яким плагін значиться в installed_plugins.json.
        Write-Host ''
        Write-Host '  Встановити unica — https://github.com/IngvarConsulting/unica'
        Write-Host '    claude plugin marketplace add IngvarConsulting/unica-marketplace'
        Write-Host '    claude plugin install unica@unica'
    }

    if (-not $pester.Available) {
        Write-Host ''
        Write-Host '  Встановити Pester:'
        Write-Host '    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser'
    }
}

Write-Host ''

if ($blocking.Count -gt 0) { exit 1 }
exit 0
