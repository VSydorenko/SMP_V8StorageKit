#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в AgentBase.psm1 (не перезавантажувати глобальні модулі):
# Supply дає Get-KitSupplyState і Get-KitSupplyRecipe.
Import-Module "$PSScriptRoot/Supply.psm1"

# Наступний крок команди для рядка `next:` (ADR-0014): перший надрукований крок у формі команди
# (`kit …` чи `unica.run …` з dryRun:true) і ознака «надруковано ЗУПИНКА». Стан одного виклику команди:
# sync, verify і session-check скидають його на старті й друкують рядок наприкінці.
$script:KitNextStep = @{ First = $null; Stopped = $false }

function Reset-KitNextStep {
    [CmdletBinding()]
    param()
    $script:KitNextStep = @{ First = $null; Stopped = $false }
}

function Register-KitNextStep {
    <# Запам'ятати крок, який команда щойно надрукувала; лишається перший. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Step)
    if ($null -eq $script:KitNextStep.First) { $script:KitNextStep.First = $Step }
}

function Write-KitNextStepLine {
    <#
    .SYNOPSIS
        Останній рядок `next: <перший надрукований крок>` — лише коли крок був і рядків ЗУПИНКА не було.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:KitNextStep.First -and -not $script:KitNextStep.Stopped) {
        Write-Host "next: $($script:KitNextStep.First)"
    }
}

function Format-KitUnicaRun {
    <#
    .SYNOPSIS
        Виклик unica.run у формі Уніки 0.16 — рядок, який агент виконує дослівно.
    .DESCRIPTION
        Одна функція форматування на весь kit: скіли не переказують виклик, а кажуть «виконай крок,
        надрукований командою». infobase не друкується — він за замовчуванням origin, а
        іншої бази Уніка не обслуговує. ConvertTo-Json у PowerShell 7 екранує лише керівні символи,
        тож кирилиця імені набору лишається читабельною й копіюється дослівно. dryRun:true першим —
        конвенція kit, не вимога Уніки (вона вимагає лише явний булів dryRun): превью показує
        попередження infobase_overwritten до виконання.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Op,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments,
        [bool]$DryRun = $true
    )
    $call = [ordered]@{ op = $Op; args = $Arguments; dryRun = $DryRun }
    'unica.run ' + ($call | ConvertTo-Json -Compress -Depth 5)
}

function Write-KitNextSteps {
    <#
    .SYNOPSIS
        Друк «Далі:» — нумеровані кроки; для unica.run нагадує про dryRun:true → false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Steps
    )
    if ($Steps.Count -eq 0) { return }
    Write-Host "  $Title" -ForegroundColor Cyan
    $i = 0
    foreach ($s in $Steps) {
        $i++
        $tail = if ($s.StartsWith('unica.run ')) { '   — спершу так, потім той самий виклик з "dryRun":false' } else { '' }
        Write-Host "    $i. $s$tail" -ForegroundColor Cyan
        Register-KitNextStep -Step $s
    }
}

function Get-KitAlignStep {
    <#
    .SYNOPSIS
        Один точний крок вирівнювання пам'яті раннера для набору, базу якого зрушив kit.
    .DESCRIPTION
        Критерію немає: після sync/verify крок завжди push force:true — повне завантаження набору з git.
        Для бази агента воно безпечне за побудовою, а без нього база тримала б версію сховища, а git —
        іншу (тиха суміш). push не несе extension: Уніка приймає в ньому лише
        sourceSet, full, force, noApply (extension — лише в pull).

        Виняток — CONFIGURATION із поставкою вендора missing/stale/unknown: push force без .cf упав би на
        повному завантаженні, тож це зупинка 'blocked' з Recipe від Get-KitSupplyRecipe (-Purpose stop).
        Стан поставки, що не обчислився, трактується як 'unknown' → blocked, а не push.
        OnMainBranch обчислює викликач (поточна гілка = головна); він лише обирає варіант рецепту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][bool]$OnMainBranch,
        # Ім'я головної гілки для тексту рецепту; викликач передає Context.MainBranch (без мовчазного типового).
        [Parameter(Mandatory)][string]$MainBranch
    )

    $set = $Source.Key
    $ws = $Source.Workspace
    # Виняток стану поставки — не зупинка команди: база вже зрушена, агентові потрібен
    # крок. Рядок друкує спільна Write-KitSupplyStateNotComputed.
    $supply = 'none'
    if ($Source.Type -eq 'CONFIGURATION') {
        try { $supply = Get-KitSupplyState -TreeRoot $Source.FullPath }
        catch { $supply = 'unknown'; Write-KitSupplyStateNotComputed -SourceSet $set -Reason $_.Exception.Message }
    }
    $step = [pscustomobject]@{ SourceSet = $set; Workspace = $ws; RepoPath = $Source.RepoPath
        Op = $null; Supply = $supply; Steps = @(); Recipe = $null }
    if ($supply -in 'none', 'current') {
        $step.Op = 'push'
        $step.Steps = @(Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = $set; force = $true }))
        return $step
    }
    $step.Op = 'blocked'
    $step.Recipe = ("Вирівняти пам'ять раннера для '$set' (воркспейс $ws) зараз неможливо: push force без .cf упав би на повному завантаженні. " +
        (Get-KitSupplyRecipe -SourceKey $set -Workspace $ws -MainBranch $MainBranch -State $supply -Purpose stop -OnMainBranch $OnMainBranch))
    $step
}

function Write-KitSupplyStateNotComputed {
    <#
    .SYNOPSIS
        Єдиний рядок «стан поставки не обчислено: <причина>».
        Друкує Get-KitAlignStep, коли Get-KitSupplyState кинула виняток; крок стає 'blocked'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceSet, [Parameter(Mandatory)][AllowEmptyString()][string]$Reason)
    $one = ($Reason -replace '\s+', ' ').Trim()
    Write-Host "  стан поставки не обчислено: $one (набір '$SourceSet')" -ForegroundColor Yellow
}

function Write-KitAlignStep {
    <#
    .SYNOPSIS
        Друк кроку push одразу після набору. Для 'blocked' — нічого: зупинки друкує
        Write-KitAlignStops ОСТАННІМИ, після підсумку команди (умова архітектора до Op 'blocked').
    .DESCRIPTION
        Тон: Уніка спитає людину про перезапис бази origin —
        це очікувано, не обходити й не повторювати без відповіді; крок виконується лише в інтерактивній
        сесії (основній чи в субагенті), не в claude -p; cancelled — зупинка з доповіддю, без повтору.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step)
    if ($Step.Op -eq 'blocked') { return }
    Write-KitNextSteps -Title "Далі — вирівняти пам'ять раннера для '$($Step.SourceSet)' (воркспейс $($Step.Workspace); $($Step.Op): повне завантаження набору з git):" -Steps $Step.Steps
    Write-Host "    Уніка спитає людину про перезапис бази origin — це очікувано: не обходити й не повторювати без відповіді. Крок — лише в інтерактивній сесії (основній чи в субагенті), не в claude -p. Відповідь cancelled — зупинка й доповідь «база агента не вирівняна; наступний push відмовить», без повтору." -ForegroundColor Cyan
}

function Write-KitAlignStops {
    <#
    .SYNOPSIS
        Рядки «ЗУПИНКА: …» для кроків 'blocked' — викликач друкує їх останніми, після підсумку.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps)
    foreach ($s in @($Steps | Where-Object { $_.Op -eq 'blocked' })) {
        Write-Host "ЗУПИНКА: $($s.Recipe)" -ForegroundColor Red
        $script:KitNextStep.Stopped = $true
    }
}

Export-ModuleMember -Function Reset-KitNextStep, Register-KitNextStep, Write-KitNextStepLine, Format-KitUnicaRun, Write-KitNextSteps, Get-KitAlignStep, Write-KitSupplyStateNotComputed, Write-KitAlignStep, Write-KitAlignStops
