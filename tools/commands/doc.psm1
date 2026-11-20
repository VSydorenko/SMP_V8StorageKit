# Ported from agent-kit 0.9.1 bin/doc, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Тонка обгортка команди `doc`: розбір аргументів (KitCli), читання профілю (KitProfile), виклик
# логіки з tools/lib/KitDoc.psm1 і друк. Уся логіка й тексти — у KitDoc: так вона перевіряється
# прямим Import-Module без запуску команди.
Import-Module "$PSScriptRoot/../lib/KitDoc.psm1"

# Ключ хеш-таблиці профілю для KitDoc -> шлях поля в .agents/kit.profile.json.
$script:DocProfileFields = [ordered]@{
    Specs = 'docs.specs'; Plans = 'docs.plans'; Docs = 'docs.docs'; Skills = 'docs.skills'
    AnchorsInclude = 'docs.anchors.include'; AnchorsExclude = 'docs.anchors.exclude'
    AnchorsRoots = 'docs.anchors.roots'; AnchorsExternal = 'docs.anchors.external'
    HistoryIgnore = 'docs.history.ignore'
    LintInclude = 'docs.lint.include'; LintExclude = 'docs.lint.exclude'
    LintDuplicateBlock = 'docs.lint.duplicateBlock'; LintSkillMaxLines = 'docs.lint.skillMaxLines'
    LintReferenceMaxLines = 'docs.lint.referenceMaxLines'; LintContentsHeadLines = 'docs.lint.contentsHeadLines'
}

function Invoke-KitDoc {
    <#
    .SYNOPSIS
        doc: зміст, розділ, пошук, якорі, lint, refs, debt, history. Форми — `doc -Help`.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        Level = 'string'; Depth = 'string'   # Depth — старе ім'я -Level, приховане
        In = 'string'; CaseSensitive = 'switch'; Max = 'string'
        Dead = 'switch'; Code = 'switch'; Docs = 'switch'
        Ignore = 'string'; Only = 'string'; Path = 'list'; List = 'switch'
    }
    if ($a.Help) {
        # `doc find -Help` / `doc -Help find`: довідка за підкомандою; без відомої теми — повний usage.
        $topic = $a.Positional | Where-Object { $null -ne (Get-DocHelp -Topic $_) } | Select-Object -First 1
        Write-KitLine $(if ($topic) { Get-DocHelp -Topic $topic } else { Get-DocUsage })
        return 0
    }
    # Профіль читається завжди: корінь checkout потрібен усім підкомандам; поля — лише наявні.
    $p = Get-KitProfile -RepoRoot $RepoRoot
    $profile = @{}
    foreach ($key in $script:DocProfileFields.Keys) {
        $profile[$key] = Get-KitProfileValue $p $script:DocProfileFields[$key] -Default $null
    }
    $opts = @{}
    foreach ($k in $a.Named.Keys) { $opts[$k] = $a.Named[$k] }
    if ($opts.ContainsKey('Depth') -and -not $opts.ContainsKey('Level')) { $opts['Level'] = $opts['Depth'] }
    if ($opts.ContainsKey('Path')) { $opts['Path'] = [string[]]$opts['Path'].ToArray() }

    $res = Invoke-DocCommand -Positional $a.Positional -Options $opts -RepoRoot $p.Root -Profile $profile -WorkDir (Get-Location).Path
    foreach ($line in $res.Lines) { Write-KitLine $line }
    if ($res.ErrLines.Count -gt 0) {
        # Код 2 доповнює вказівкою `usage: doc -Help` сам Write-KitError — свою вказівку не передаємо.
        $msg = (@($res.ErrLines | Where-Object { $_ -notlike 'usage: doc*' }) -join "`n")
        Write-KitError -Command 'doc' -Message $msg -ExitCode $res.Code
    }
    return [int]$res.Code
}

Export-ModuleMember -Function Invoke-KitDoc
