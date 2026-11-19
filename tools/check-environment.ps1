#Requires -Version 7
<#
.SYNOPSIS
    Перевіряє середовище, потрібне для роботи конвеєра й для розробки самого kit.
.DESCRIPTION
    Читання й нічого більше: платформу не запускає, git-команд, що змінюють стан, не
    виконує, нічого не встановлює.

    Дві категорії у виводі відповідають реальним залежностям, а не оформленню:

      Конвеєр       — без цього конвеєр не працює: PowerShell 7, git, платформа 8.3.27.x,
                      модуль powershell-yaml і, з 1.6.0, Уніка 0.16 з її раннером v8-runner 0.18
                      (sync, verify і provision запускають платформу раннером із встановлення
                      Уніки; без неї вони зупиняються). Виняток — kit dump: він бере платформу
                      напряму й без Уніки працює.
      Розробка kit  — без цього не прогнати тести цього репозиторію.

    Код виходу 1 — тільки коли провалилась перевірка категорії «Конвеєр». Решта
    виводиться як попередження й коду виходу не змінює: відсутність Pester — це неповне
    робоче місце, а не зламаний конвеєр, і зливати ці стани в один означало б приховати
    різницю, заради якої категорії й заведені.
.PARAMETER InstalledPluginsPath
    Реєстр плагінів, де шукається Уніка (і раннер). Параметр існує для тестів.
.PARAMETER RunnerPath
    Шлях до раннера; порожній — із встановлення Уніки за реєстром вище. Параметр існує для тестів.
.EXAMPLE
    pwsh -NoProfile -File tools/check-environment.ps1
.EXAMPLE
    pwsh -NoProfile -File tools/check-environment.ps1 -InstalledPluginsPath <шлях до реєстру>
#>
[CmdletBinding()]
param(
    [string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json'),
    [string]$RunnerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/Environment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Runner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/V8.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Yaml.psm1') -Force

$checks = [System.Collections.Generic.List[object]]::new()

# --- Конвеєр -----------------------------------------------------------------

$checks.Add((New-EnvironmentCheck -Name 'PowerShell 7+' -Category 'Конвеєр' -Ok $true `
    -Detail "$($PSVersionTable.PSVersion) — скрипти оголошують #Requires -Version 7"))

$git = Get-GitAvailability
$checks.Add((New-EnvironmentCheck -Name "git ≥ $($git.Minimum)" -Category 'Конвеєр' -Ok ($git.Available -and $git.Supported) `
    -Detail $(if (-not $git.Available) { $git.Reason } elseif (-not $git.Supported) { "$($git.Version) — замало: злиття дзеркала потребує git ≥ $($git.Minimum) (merge-tree --write-tree)" } else { $git.Version })))

try {
    $v8 = Get-V8Path
    $checks.Add((New-EnvironmentCheck -Name 'Платформа 1С 8.3.27.x' -Category 'Конвеєр' -Ok $true -Detail $v8))
} catch {
    $checks.Add((New-EnvironmentCheck -Name 'Платформа 1С 8.3.27.x' -Category 'Конвеєр' -Ok $false `
        -Detail $_.Exception.Message))
}

$yaml = Test-KitYamlModule
$checks.Add((New-EnvironmentCheck -Name 'Модуль powershell-yaml' -Category 'Конвеєр' -Ok $yaml.Available `
    -Detail $(if ($yaml.Available) { "версія $($yaml.Version) — читає v8storagekit.yaml і v8project.yaml" } else { $yaml.Reason })))

# --- Розробка kit ------------------------------------------------------------

$pester = Get-PesterAvailability
$checks.Add((New-EnvironmentCheck -Name 'Pester 5+' -Category 'Розробка kit' -Ok $pester.Available `
    -Detail $(if ($pester.Available) { "версія $($pester.Version)" } else { $pester.Reason })))

# Уніка й раннер — частина конвеєра (спека 2026-11-19 §4.2 п.4, п.19), а не «вихідники»: без них sync, verify
# і provision не працюють. Версія 0.16.x — ok; нижча — помилка; вища — попередження (проходить як Ok).

$unica = Get-UnicaInstallation -InstalledPluginsPath $InstalledPluginsPath
$unicaVerdict = Get-KitUnicaVersionVerdict -Installation $unica
$unicaOk = $unicaVerdict.Level -ne 'error'
$unicaDetail = if ($unica.Installed -and $unica.PathExists) {
    "версія $($unica.Version), $($unica.InstallPath)" + $(if ($unicaVerdict.Level -in 'error', 'warn') { " — $($unicaVerdict.Message)" } else { '' })
} else {
    $unicaVerdict.Message
}
$checks.Add((New-EnvironmentCheck -Name 'Плагін unica 0.16' -Category 'Конвеєр' -Ok $unicaOk -Detail $unicaDetail))

$runnerVerdict = Get-KitRunnerVerdict -RunnerPath $RunnerPath -InstalledPluginsPath $InstalledPluginsPath
$checks.Add((New-EnvironmentCheck -Name 'Раннер v8-runner 0.18' -Category 'Конвеєр' -Ok ($runnerVerdict.Level -ne 'error') -Detail $runnerVerdict.Message))
# --- Вивід -------------------------------------------------------------------

Write-Host ''
Write-Host 'Середовище v8storagekit'
Write-Host '======================='

foreach ($category in @('Конвеєр', 'Розробка kit')) {
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

    if (-not $yaml.Available) {
        Write-Host ''
        Write-Host '  Встановити powershell-yaml (PSGallery):'
        Write-Host '    Install-Module powershell-yaml -Scope CurrentUser'
    }

    if (-not $unicaOk -or $runnerVerdict.Level -eq 'error') {
        # Адреси не вгадані: repository взято з маніфесту самого плагіна
        # (.claude-plugin/plugin.json у його кеші), ім'я маркетплейсу — з
        # ~/.claude/plugins/known_marketplaces.json, а форма 'unica@unica' — це той
        # самий ключ, яким плагін значиться в installed_plugins.json.
        Write-Host ''
        if ($unica.Installed -and $unica.PathExists) {
            # Уніка стоїть, але старша за 0.16 чи без раннера: потрібне оновлення, не встановлення.
            Write-Host '  Оновити unica (і почати нову сесію):'
            Write-Host '    claude plugin marketplace update unica'
            Write-Host '    claude plugin update unica@unica'
        } else {
            Write-Host '  Встановити unica — https://github.com/IngvarConsulting/unica'
            Write-Host '    claude plugin marketplace add IngvarConsulting/unica-marketplace'
            Write-Host '    claude plugin install unica@unica'
        }
    }
} else {
    Write-Host 'Конвеєр запуститься: усі обов''язкові умови виконано.'
}

if ($warnings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Попередження (коду виходу не змінюють):'
    foreach ($w in $warnings) {
        $what = switch ($w.Category) {
            'Розробка kit' { 'не прогнати тести цього репозиторію' }
            default        { 'неповне робоче місце' }
        }
        Write-Host ("  {0}: {1}" -f $w.Name, $what)
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
