#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module ризикував би перезавантаженням (docs/follow-ups.md §5).

function Invoke-KitInstallHooks {
    <#
    .SYNOPSIS
        Ставить у репозиторій-споживач хуки захисту storage/* (.githooks + core.hooksPath)
        (лише git-хуки). Файл .claude/settings.json команда не кладе й не чіпає (права не автоматизуються, рішення
        власника 2026-11-23): відхилення від шаблону показує звіт kit-setup. Хука старту сесії тут немає: його поставляє плагін. Ідемпотентно.
    .DESCRIPTION
        Скіл onboarding кладе те саме, але сам не імпортує lib-модулів (текст скіла цього не може) —
        ця команда існує рівно для того, щоб скіл викликав один kit install-hooks -Apply замість
        відтворення логіки Install-KitGitHooks у собі.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        # -Workspace/-Source не оголошено свідомо: git-хуки ставляться на ВЕСЬ
        # репозиторій. Диспетчер на переданий -Workspace/-Source зупиняється з поясненням.
        [bool]$Apply
    )
    $root = $Context.RepoRoot
    Write-Host 'Буде покладено:'
    Write-Host '  .githooks/pre-commit, .githooks/pre-merge-commit  + git config core.hooksPath .githooks'
    if (-not $Apply) {
        Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Installed = @() }
    }
    $installed = @(Install-KitGitHooks -RepoRoot $root)
    foreach ($p in $installed) { Write-Host "  + $p" }
    # Біт виконання живе в індексі git, не в ФС Windows (core.filemode=false). Install-KitGitHooks індексу не
    # чіпає навмисно; це робить крок онбордингу — тут.
    $hookPaths = @(Get-KitHookNames | ForEach-Object { ".githooks/$_" })
    $out = git -C $root add -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git add .githooks завершився з кодом ${LASTEXITCODE}: $out" }
    $out = git -C $root update-index --chmod=+x -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git update-index --chmod=+x завершився з кодом ${LASTEXITCODE}: $out" }
    Write-Host '  + .githooks/* застейджено з режимом 100755 (біт виконання для клонів на POSIX)'
    $left = @(Test-KitGitHooks -RepoRoot $root) + @(Test-KitLegacySessionHook -RepoRoot $root)
    $problems = @($left | Where-Object Level -ne 'info')
    foreach ($f in $problems) { Write-Host "  [$($f.Level)] $($f.Message)" -ForegroundColor Yellow }
    Write-Host 'Готово. .githooks уже в індексі.' -ForegroundColor Green
    # ExitCode рахує лише error (кодів 0/1, як у PowerShell-версії check; у kit.exe check є ще код 3 «не перевірено», сюди він не переноситься): warn — те, що команда за побудовою не могла
    # полагодити сама (старий хук старту сесії в settings.json: файл вона не чіпає), а не зупинка;
    # людина вже бачить його рядком вище.
    $errors = @($problems | Where-Object Level -eq 'error')
    [pscustomobject]@{ ExitCode = $(if ($errors.Count) { 1 } else { 0 }); Installed = $installed }
}

Export-ModuleMember -Function Invoke-KitInstallHooks
