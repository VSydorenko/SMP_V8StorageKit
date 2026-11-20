#Requires -Version 7
# Ported from agent-kit 0.9.1 lib/wait.mjs (і startLine з lib/gh-run.mjs), modified.
#
# Спільний цикл очікування з вбудованим таймаутом: одна реалізація замість рукописних циклів
# `sleep` у сесіях (в оригіналі з 828 таких циклів 119 були зламані: лапки, без таймауту, не той
# код виходу). Проба каже лише «що бачу зараз»; цикл вирішує, коли друкувати, коли зупинитись і
# з яким кодом. Кличуть `wait-for` і `pr-gate wait`.
#
# Контракт проби: scriptblock, що отримує залишок часу в мілісекундах (щоб одна спроба не
# пережила загальний таймаут) і повертає об'єкт із полями:
#   Done  — 'ok' (умову виконано) | 'failed' (остаточно не виконається, напр. CI впав) |
#           'unavailable' (перевірити неможливо, чекати марно) | $null (ще ні, чекати далі);
#   State — короткий опис побаченого; друкується лише при зміні;
#   Cut   — $true, коли спробу обірвав сам таймаут: вона почалась за мить до межі й нічого не
#           каже про умову, тож причиною таймауту лишається попередній стан.
# Коди виходу — контракт команд процесу: 0 так, 1 провал, 3 не перевірено (таймаут теж: умову
# не перевірено до кінця, це ніколи не зелене).
Set-StrictMode -Version Latest

function Get-KitWaitStartLine {
    <#
    .SYNOPSIS
        Перший рядок очікування: межа вбудована, зовнішній таймаут зайвий.
    .DESCRIPTION
        В оригіналі 13 з 14 очікувань агенти загортали в зовнішній timeout і обрізали вивід —
        стартовий рядок каже, що межа вже є.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$TimeoutSec,
        [Parameter(Mandatory)][double]$IntervalSec
    )
    "чекаю до $TimeoutSec с, перевірка кожні $IntervalSec с (таймаут вбудований: зовнішній не потрібен)"
}

function Get-KitProbeField {
    param($Answer, [string]$Name)
    if ($null -eq $Answer) { return $null }
    if ($Answer -is [System.Collections.IDictionary]) { return $Answer[$Name] }
    $prop = $Answer.PSObject.Properties[$Name]
    if ($prop) { $prop.Value } else { $null }
}

function Invoke-KitWaitUntil {
    <#
    .SYNOPSIS
        Опитує пробу до виконання умови або таймауту.
    .DESCRIPTION
        Друкує новий стан лише при зміні й один фінальний рядок:
        `OK через <n> с` | `FAILED через <n> с: <стан>` | `TIMEOUT через <n> с: <останній стан>` |
        `NOT CHECKED: <стан>`. Маркери на початку рядка — англійські й сталі: їх шукають скіли
        й `next:`-підказки викликачів.
        Повертає [pscustomobject]@{ Code; Line; Result }: Result — остання відповідь проби, щоб
        викликач бачив її поля (напр. Reason), а не вгадував причину з тексту рядка.
    .PARAMETER Probe
        Scriptblock: param([double]$RemainingMs) → @{ Done; State; Cut }.
    .PARAMETER Write
        Куди друкувати рядки; типово Write-Host (конвенція команд kit).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [Parameter(Mandatory)][double]$TimeoutSec,
        [Parameter(Mandatory)][double]$IntervalSec,
        [scriptblock]$Write = { param([string]$Line) Write-Host $Line }
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $TimeoutSec * 1000
    $elapsed = { "$([math]::Round($clock.Elapsed.TotalSeconds)) с" }
    $last = $null
    $hasLast = $false
    $result = $null
    $finish = {
        param([int]$Code, [string]$Line)
        & $Write $Line
        [pscustomobject]@{ Code = $Code; Line = $Line; Result = $result }
    }

    while ($true) {
        $answer = & $Probe ([math]::Max($budgetMs - $clock.Elapsed.TotalMilliseconds, 0))
        if ((Get-KitProbeField $answer 'Cut') -and $hasLast -and $clock.Elapsed.TotalMilliseconds -ge $budgetMs) {
            return (& $finish 3 "TIMEOUT через $(& $elapsed): $last")
        }
        $result = $answer
        $done = Get-KitProbeField $answer 'Done'
        $state = [string](Get-KitProbeField $answer 'State')
        if (-not $hasLast -or $state -cne $last) {
            & $Write $state
            $last = $state
            $hasLast = $true
        }
        switch ($done) {
            'ok' { return (& $finish 0 "OK через $(& $elapsed)") }
            'failed' { return (& $finish 1 "FAILED через $(& $elapsed): $state") }
            'unavailable' { return (& $finish 3 "NOT CHECKED: $state") }
        }
        $leftMs = $budgetMs - $clock.Elapsed.TotalMilliseconds
        if ($leftMs -le 0) { return (& $finish 3 "TIMEOUT через $(& $elapsed): $state") }
        Start-Sleep -Milliseconds ([int][math]::Ceiling([math]::Min($IntervalSec * 1000, $leftMs)))
    }
}

Export-ModuleMember -Function Get-KitWaitStartLine, Invoke-KitWaitUntil
