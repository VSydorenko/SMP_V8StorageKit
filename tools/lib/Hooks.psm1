#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"

$script:HooksDirName = '.githooks'
$script:HookNames    = @('pre-commit', 'pre-merge-commit')
$script:DefaultTemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates/githooks'))

function Get-KitHookNames {
    [CmdletBinding()]
    param()
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $script:HookNames
}

function Install-KitGitHooks {
    <#
    .SYNOPSIS
        Кладе хуки захисту storage/* у <репо>/.githooks і вмикає їх через core.hooksPath.
    .DESCRIPTION
        Копіює байт-у-байт із templates/githooks плагіна — це роздаваний артефакт, і
        Test-KitGitHooks звіряє встановлене саме з ним. Ідемпотентно: повторний виклик
        оновлює файли до шаблону.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $target = Join-Path $RepoRoot $script:HooksDirName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:HookNames) {
        $src = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Шаблон хука не знайдено: $src" }
        $dst = Join-Path $target $name
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $installed.Add($dst)
    }
    $out = git -C $RepoRoot config core.hooksPath $script:HooksDirName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git config core.hooksPath завершився з кодом ${LASTEXITCODE}: $out" }
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $installed.ToArray()
}

function Test-KitGitHooks {
    <#
    .SYNOPSIS
        Аудит для check: core.hooksPath увімкнено, обидва файли є, вміст = шаблон плагіна.
        Порівняння після нормалізації CRLF→LF: CR тут — окрема біда, і про неї каже .gitattributes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    $configured = (git -C $RepoRoot config --get core.hooksPath 2>$null | Out-String).Trim()
    if (($configured -replace '\\', '/').TrimEnd('/') -ne $script:HooksDirName) {
        $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
            "core.hooksPath не вказує на $script:HooksDirName (зараз: '$configured') — хуки захисту storage/* не працюють. " +
            "Увімкнути: git config core.hooksPath $script:HooksDirName (скіл onboarding робить це сам).")))
    }

    foreach ($name in $script:HookNames) {
        $installedPath = Join-Path $RepoRoot $script:HooksDirName $name
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
                "Хука $script:HooksDirName/$name немає — гілки storage/* не захищені від ручного коміту.")))
            continue
        }
        $templatePath = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { continue }
        $a = (Get-Content -LiteralPath $installedPath -Raw) -replace "`r`n", "`n"
        $b = (Get-Content -LiteralPath $templatePath  -Raw) -replace "`r`n", "`n"
        if ($a -ne $b) {
            $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                "Хук $script:HooksDirName/$name відрізняється від шаблону плагіна ($templatePath). " +
                'Оновіть копію з templates/githooks плагіна, якщо це не свідома локальна правка.')))
        }
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitHookNames, Install-KitGitHooks, Test-KitGitHooks
