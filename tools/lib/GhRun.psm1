#Requires -Version 7
# Ported from agent-kit 0.9.1 lib/gh-run.mjs, modified.
<#
    Межа виклику `gh` і стан PR (голова, злиття з base, конфлікт). Стану CI-прогонів тут немає:
    workflow немає в жодному репозиторії власника, тож `listRuns`, `summarizeRuns`, проб очікування
    CI і `resolveSha` з оригіналу не переносились.

    Контракт (кличуть pr-gate, track, session-board):
      Invoke-KitGh -Arguments <string[]> [-TimeoutSec 120] [-Json] [-Repo] [-InputText] [-Cwd]
        -> stdout (trim); з -Json — розібраний об'єкт (порожній stdout -> $null).
      gh відсутній або не залогінений       -> виняток KitGhUnavailable (викликач дає код 3);
      ненульовий вихід або таймаут          -> виняток KitGhError (Stderr — увесь stderr,
                                               IsNotFound — HTTP 404, TimedOut — таймаут).
      Таймаут вбиває все ДЕРЕВО процесів gh (Kill($true)): gh породжує git, браузер, pager.

    Типи винятків — .NET-класи (Add-Type), а не класи PowerShell: клас PowerShell, оголошений у
    модулі, ззовні модуля невидимий (Import-Module його не експортує, потрібен `using module`), і
    `catch [KitGhUnavailable]` в іншому модулі не спрацював би. Add-Type реєструє тип у домені
    застосунку, тож він видимий усім модулям і скриптам сесії.
#>
Set-StrictMode -Version Latest

if (-not ('KitGhUnavailable' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public class KitGhUnavailable : Exception {
    public KitGhUnavailable(string message) : base(message) { }
}
public class KitGhError : Exception {
    public string Stderr { get; private set; }
    public int ExitCode { get; private set; }
    public bool TimedOut { get; private set; }
    // HTTP 404 у stderr: `gh api` пише «HTTP 404», `gh pr view` для неіснуючого PR — «Could not resolve».
    public bool IsNotFound { get { return Stderr != null && Stderr.IndexOf("HTTP 404", StringComparison.Ordinal) >= 0; } }
    public KitGhError(string message, string stderr, int exitCode, bool timedOut) : base(message) {
        Stderr = stderr ?? ""; ExitCode = exitCode; TimedOut = timedOut;
    }
}
'@
}

# Ім'я виконуваного файла; змінна модуля, щоб вручну перевірити гілку «gh відсутній».
$script:GhExe = 'gh'

function Invoke-KitGh {
    <#
    .SYNOPSIS
        Викликає `gh` і повертає stdout (trim); з -Json — розібраний об'єкт.
    .DESCRIPTION
        -Repo іде в GH_REPO: так спрацьовують плейсхолдери {owner}/{repo} у `gh api`.
        -InputText — stdin (тіло issue); без нього stdin закривається одразу, щоб gh не чекав.
        Межа виклику — -TimeoutSec: завислий мережевий виклик інакше пережив би таймаут очікування
        викликача. Обидва вихідні потоки читаються асинхронно ДО очікування завершення (повний
        буфер stdout інакше блокує gh назавжди).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 120,
        [switch]$Json,
        [string]$Repo,
        [string]$InputText,
        [string]$Cwd
    )
    # Шлях — через пошук команд PowerShell (PATHEXT: .exe, .cmd, .bat), а не голим ім'ям:
    # Process.Start з голим 'gh' на Windows знаходить лише gh.exe, і фальшивий gh.cmd у тестах
    # мовчки обходився б справжнім gh.
    $exe = Get-Command -Name $script:GhExe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw [KitGhUnavailable]::new("gh CLI не знайдено в PATH") }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe.Source
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    if ($Repo) { $psi.Environment['GH_REPO'] = $Repo }
    $psi.Environment['GH_PROMPT_DISABLED'] = '1'   # gh не питає людину: без цього завис би до таймауту
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }

    $label = 'gh ' + (@($Arguments | Select-Object -First 2) -join ' ')
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch [System.ComponentModel.Win32Exception] { throw [KitGhUnavailable]::new("gh CLI не знайдено в PATH ($($_.Exception.Message))") }

    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        try {
            if ($InputText) { $proc.StandardInput.Write($InputText) }
            $proc.StandardInput.Close()
        } catch [System.IO.IOException] { }   # gh завершився, не дочекавшись stdin: причина — у stderr
        if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
            try { $proc.Kill($true) } catch {}   # $true — все дерево, не лише gh
            $proc.WaitForExit()
            throw [KitGhError]::new("${label}: немає відповіді за $TimeoutSec с", '', -1, $true)
        }
        $proc.WaitForExit()   # дочекатись дренажу асинхронних потоків
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $code = $proc.ExitCode
    } finally {
        try { $proc.StandardInput.Close() } catch {}
        if (-not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
        $proc.Dispose()
    }

    if ($code -ne 0) {
        if ($stderr -match '(?i)auth login|not logged') {
            throw [KitGhUnavailable]::new("gh не залогінений (gh auth login): $(($stderr.Trim() -split "\r?\n")[0])")
        }
        $first = ($stderr.Trim() -split "\r?\n")[0]
        if (-not $first) { $first = "код виходу $code" }
        throw [KitGhError]::new("${label}: $first", $stderr, $code, $false)
    }
    $text = $stdout.Trim()
    if ($Json) {
        if (-not $text) { return $null }
        return ($text | ConvertFrom-Json)
    }
    $text
}

function Get-KitPrState {
    <#
    .SYNOPSIS
        Стан PR для гейту: `gh pr view --json` плюс обчислене Conflict.
    .DESCRIPTION
        -Pr — номер, гілка або URL. Conflict = mergeable CONFLICTING або mergeStateStatus DIRTY.
        Чому окреме поле: конфліктний PR — не очікування, а провал. UNKNOWN означає, що GitHub ще
        рахує злиття: Conflict лишається $false, викликач чекає далі. mergeable і mergeStateStatus
        додаються до -Fields завжди — без них Conflict було б неправдою.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pr,
        [string]$Repo,
        [string[]]$Fields = @('number', 'state', 'isDraft', 'mergeable', 'mergeStateStatus', 'headRefOid', 'headRefName', 'baseRefName', 'isCrossRepository', 'url'),
        [int]$TimeoutSec = 120
    )
    $all = @($Fields + @('mergeable', 'mergeStateStatus') | Select-Object -Unique)
    $gh = @('pr', 'view', $Pr)
    if ($Repo) { $gh += @('-R', $Repo) }
    $gh += @('--json', ($all -join ','))
    $p = Invoke-KitGh -Arguments $gh -Repo $Repo -TimeoutSec $TimeoutSec -Json
    if ($null -eq $p) { throw [KitGhError]::new("gh pr view ${Pr}: порожня відповідь", '', 0, $false) }
    $conflict = ($p.mergeable -eq 'CONFLICTING') -or ($p.mergeStateStatus -eq 'DIRTY')
    $p | Add-Member -NotePropertyName Conflict -NotePropertyValue $conflict -Force
    $p
}

Export-ModuleMember -Function Invoke-KitGh, Get-KitPrState
