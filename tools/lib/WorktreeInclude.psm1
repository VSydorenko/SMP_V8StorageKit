# Ported from agent-kit 0.9.1 lib/worktree-include.mjs, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Копія гітігнорованих файлів з `.worktreeinclude` у новий worktree.
#
# Claude Code сам копіює ці файли лише у власні worktree (`claude --worktree`, субагенти з
# `isolation: worktree`), а на звичайний `git worktree add` — ні. `pr-gate start` і `scratch add`
# створюють worktree саме так, тож без цієї копії сесія в worktree лишалась би без
# `.claude/settings.local.json` (дозволи, `claudeMdExcludes`) і `.agents/kit.profile.local.json`.

$script:IncludeFile = '.worktreeinclude'

function Invoke-WiGit {
    # git як .NET Process: stdin потрібен для `check-ignore --stdin`, а -z віддає байти без
    # перекодування PowerShell. Повертає $null при збої запуску або коді поза 0/1: `check-ignore`
    # виходить з 1, коли жоден шлях не ігнорований, — це не помилка.
    param([Parameter(Mandatory)][string[]]$GitArgs, [Parameter(Mandatory)][string]$Cwd, [string]$InputText)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in (@('-C', $Cwd) + $GitArgs)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        try {
            if ($InputText) { $proc.StandardInput.Write($InputText) }
            $proc.StandardInput.Close()
        } catch [System.IO.IOException] { }
        $proc.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $null = $errTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1) { return $null }
        return , @($stdout -split "`0" | Where-Object { $_ })
    } finally { $proc.Dispose() }
}

function Copy-KitWorktreeInclude {
    <#
    .SYNOPSIS
        Копіює з -Root у -Dest файли, які водночас: не трековані, збігаються з шаблонами
        `.worktreeinclude` (синтаксис .gitignore) і ігноровані git. Повертає відносні шляхи.
    .DESCRIPTION
        Трековані файли й файли поза .gitignore не копіюються (так само робить Claude Code); наявні
        файли в -Dest не перезаписуються. -Skip — відносні префікси, які не беремо (корінь worktree
        у самому репо). Немає `.worktreeinclude` — порожній результат.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Dest,
        [string[]]$Skip = @()
    )
    $spec = Join-Path $Root $script:IncludeFile
    if (-not (Test-Path -LiteralPath $spec)) { return , @() }
    $listed = Invoke-WiGit -Cwd $Root -GitArgs @('ls-files', '-z', '--others', '--ignored', "--exclude-from=$spec")
    if (-not $listed -or $listed.Count -eq 0) { return , @() }
    $ignoredList = Invoke-WiGit -Cwd $Root -GitArgs @('check-ignore', '-z', '--stdin') -InputText (($listed -join "`0") + "`0")
    $ignored = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ignoredList), [System.StringComparer]::Ordinal)
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $listed) {
        if (-not $ignored.Contains($rel)) { continue }
        $skipped = $false
        foreach ($s in $Skip) { if ($rel -eq $s -or $rel.StartsWith($s.TrimEnd('/') + '/', [System.StringComparison]::Ordinal)) { $skipped = $true; break } }
        if ($skipped) { continue }
        $to = Join-Path $Dest $rel
        if (Test-Path -LiteralPath $to) { continue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root $rel) -Destination $to
        $copied.Add($rel)
    }
    , $copied.ToArray()
}

function Format-KitCopiedLine {
    <# Рядок звіту: перші кілька шляхів і загальна кількість; порожньо, коли нічого не скопійовано. #>
    param([AllowEmptyCollection()][string[]]$Copied = @())
    if (-not $Copied -or $Copied.Count -eq 0) { return '' }
    $shown = ($Copied | Select-Object -First 5) -join ', '
    "скопійовано з $script:IncludeFile`: $shown$(if ($Copied.Count -gt 5) { " (ще $($Copied.Count - 5))" })"
}

Export-ModuleMember -Function Copy-KitWorktreeInclude, Format-KitCopiedLine
