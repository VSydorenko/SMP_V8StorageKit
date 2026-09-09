#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Invoke-KitInstallHooks {
    <#
    .SYNOPSIS
        Ставить у репозиторій-споживач хуки захисту storage/* (.githooks + core.hooksPath) і хук старту
        сесії (.claude/hooks/session-start.ps1 + .claude/settings.json, якщо його ще немає). Ідемпотентно.
    .DESCRIPTION
        Скіл onboarding кладе те саме, але сам не імпортує lib-модулів (текст скіла цього не може) —
        ця команда існує рівно для того, щоб скіл викликав один kit.ps1 install-hooks -Apply замість
        відтворення логіки Install-KitGitHooks/Install-KitSessionHook у собі.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )
    $root = $Context.RepoRoot
    Write-Host 'Буде покладено:'
    Write-Host '  .githooks/pre-commit, .githooks/pre-merge-commit  + git config core.hooksPath .githooks'
    Write-Host '  .claude/hooks/session-start.ps1  (+ .claude/settings.json, якщо його немає)'
    if (-not $Apply) {
        Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Installed = @() }
    }
    $installed = @(Install-KitGitHooks -RepoRoot $root) + @(Install-KitSessionHook -RepoRoot $root)
    foreach ($p in $installed) { Write-Host "  + $p" }
    # F10: біт виконання живе в індексі git, не в ФС Windows (core.filemode=false). Install-KitGitHooks індексу не
    # чіпає навмисно; це робить крок онбордингу — тут. Стейджимо лише хуки: решту (шим, settings) стейджить людина
    # чи скіл у першому коміті.
    $hookPaths = @(Get-KitHookNames | ForEach-Object { ".githooks/$_" })
    $out = git -C $root add -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git add .githooks завершився з кодом ${LASTEXITCODE}: $out" }
    $out = git -C $root update-index --chmod=+x -- @hookPaths 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git update-index --chmod=+x завершився з кодом ${LASTEXITCODE}: $out" }
    Write-Host '  + .githooks/* застейджено з режимом 100755 (біт виконання для клонів на POSIX)'
    $left = @(Test-KitGitHooks -RepoRoot $root) + @(Test-KitSessionHook -RepoRoot $root)
    $problems = @($left | Where-Object Level -ne 'info')
    foreach ($f in $problems) { Write-Host "  [$($f.Level)] $($f.Message)" -ForegroundColor Yellow }
    Write-Host 'Готово. .githooks уже в індексі; додайте .claude у перший коміт.' -ForegroundColor Green
    # Рев'ю (фікс-раунд 1, I2): ExitCode рахує лише error, не будь-який $problems (warn туди теж
    # потрапляє). Прецедент — check.psm1:407, той самий контракт New-KitFinding: ExitCode =
    # $errors.Count -gt 0, warn лишає 0. warn тут — це те, що ця команда за побудовою не могла
    # полагодити сама (типовий приклад: наявний .claude/settings.json без hooks.SessionStart —
    # Install-KitSessionHook його свідомо не перезаписує, спека §7), а не зупинка (kit.ps1:48-53:
    # «1 — зупинка»); людина вже бачить її текстом рядком вище через $problems.
    $errors = @($problems | Where-Object Level -eq 'error')
    [pscustomobject]@{ ExitCode = $(if ($errors.Count) { 1 } else { 0 }); Installed = $installed }
}

Export-ModuleMember -Function Invoke-KitInstallHooks
