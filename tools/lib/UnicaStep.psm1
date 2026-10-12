#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в AgentBase.psm1 (не перезавантажувати глобальні модулі):
# Supply дає Get-KitSupplyState, TreeCompare — Invoke-KitGitProcess, TreeBackup — Get-KitDirtyRecords (критерій вирівнювання нижче).
Import-Module "$PSScriptRoot/Supply.psm1"
Import-Module "$PSScriptRoot/TreeCompare.psm1"
Import-Module "$PSScriptRoot/TreeBackup.psm1"

function Format-KitUnicaRun {
    <#
    .SYNOPSIS
        Виклик unica.run у формі Уніки 0.13 — рядок, який агент виконує дослівно (спека §4.1, §10 П2).
    .DESCRIPTION
        Одна функція форматування на весь kit: скіли не переказують виклик, а кажуть «виконай крок,
        надрукований командою» (§4.4 п. 1). infobase не друкується — він за замовчуванням origin, а
        іншої бази Уніка не обслуговує. ConvertTo-Json у PowerShell 7 екранує лише керівні символи,
        тож кирилиця імені набору лишається читабельною й копіюється дослівно. dryRun:true першим —
        конвенція kit, не вимога Уніки (вона вимагає лише явний булів dryRun): превью показує
        попередження infobase_overwritten до виконання (спека §4.1).
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
    }
}

function Assert-KitCriterionInput {
    <#
    .SYNOPSIS
        Fail-closed запобіжник критерію вирівнювання: порожній шлях набору й RepoRoot, що не є коренем
        репозиторію, — виняток, а не мовчазне «чисто/рівно».
    .DESCRIPTION
        Порожній нормалізований шлях (/, \, '') зробив би Test-KitSetTreeEqual порівнянням кореневих
        дерев, а Test-KitSetClean — перевіркою всього репо. RepoRoot-підтека дає git status тільки
        для підтеки, тож брудна робоча копія виглядала б чистою. Критерій — властивість безпеки:
        хибне «чисто» призвело б до pull force, що стер би незакомічену роботу.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][AllowEmptyString()][string]$RepoPath)
    $p = ($RepoPath -replace '\\', '/').Trim('/')
    if ($p -eq '') { throw "Шлях набору порожній після нормалізації ('$RepoPath') — критерій вирівнювання не обчислюється для всього репозиторію." }
    $top = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--show-toplevel')
    if ($top.ExitCode -ne 0) { throw "git rev-parse --show-toplevel для '$RepoRoot' завершився з кодом $($top.ExitCode): $($top.Stderr)" }
    $norm = { param($x) ([System.IO.Path]::GetFullPath($x.Trim()) -replace '\\', '/').TrimEnd('/') }
    if (-not (& $norm $top.Stdout).Equals((& $norm $RepoRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "RepoRoot '$RepoRoot' не є коренем репозиторію (корінь: '$($top.Stdout.Trim())') — критерій вирівнювання не обчислюється."
    }
}

function Test-KitSetTreeEqual {
    <#
    .SYNOPSIS
        Чи однакове git-дерево набору у двох ревізіях — ідентифікатор дерева, не вміст файлів (§4.1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    Assert-KitCriterionInput -RepoRoot $RepoRoot -RepoPath $RepoPath
    $p = ($RepoPath -replace '\\', '/').Trim('/')
    $l =Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "${Left}:$p")
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "${Right}:$p")
    if ($l.ExitCode -ne 0 -or $r.ExitCode -ne 0) { return $false }
    $l.Stdout.Trim() -eq $r.Stdout.Trim()
}

function Test-KitSetClean {
    <#
    .SYNOPSIS
        Чи чисте робоче дерево набору (§4.1) — та сама семантика, що в страховці canon (Get-KitDirtyRecords).
    .DESCRIPTION
        Невідстежувані файли рахуються: pull force переписує дерево з бази, і невідстежувана нова
        форма агента зникла б безслідно (Review Focus 3) — тому не git diff. Невидиме для status
        (Get-KitInvisibleWork: ігноровані файли, крім похідних, прапорці assume-unchanged/skip-worktree,
        підмодулі) теж робить дерево «не чистим»; похідне (поставка вендора, ConfigDumpInfo.xml,
        DumpFilesIndex.txt) не рахується. Одна функція «брудне дерево» на kit (kit-dev: друга
        перевірка з іншою логікою гірша за жодну).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$RepoPath)
    Assert-KitCriterionInput -RepoRoot $RepoRoot -RepoPath $RepoPath
    # Дві частини однієї відповіді: видима (status) і невидима для status (ігноровані, прапорці, підмодулі;
    # §10.2 П24) — pull --force знищує обидві. Невидима робота є → «не чисто» → push force.
    (@(Get-KitDirtyRecords -RepoRoot $RepoRoot -RepoPath $RepoPath).Count -eq 0) -and
        (@(Get-KitInvisibleWork -RepoRoot $RepoRoot -RepoPath $RepoPath).Count -eq 0)
}

function Test-KitRefIsHead {
    <#
    .SYNOPSIS
        Чи вказує -Ref на той самий коміт, що й HEAD (§10 П4) — через ^{commit}, тож працює для
        імені гілки, тегу, sha і від'єднаного HEAD.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Ref)
    $h = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    $x = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($h.ExitCode -ne 0 -or $x.ExitCode -ne 0) { return $false }
    $h.Stdout.Trim() -eq $x.Stdout.Trim()
}

function Get-KitAlignStep {
    <#
    .SYNOPSIS
        Один точний крок вирівнювання пам'яті раннера для набору, базу якого зрушив kit (§4.1, §10 П3–П5).
    .DESCRIPTION
        Критерій (обчислює викликач) — kit довів, що дерево набору в робочій копії дорівнює тому, що
        він щойно вивантажив з бази, і дерево чисте. Тоді pull force: одне вивантаження, файли не
        змінюються, пам'ять раннера стає правильною. Інакше push force — повне завантаження з git,
        для бази агента безпечне за побудовою (рішення 1 спеки).

        Поставка вендора (CONFIGURATION, стан ≠ none), файлова база: pull --force стирає каталог
        набору разом з ігнорованими, але повне вивантаження платформи кладе .cf поставки заново (на
        цьому стоїть canon 1.4.0); знищується лише позначка .kit-bin-sha1, і її пише власник —
        canon у режимі -MarkerOnly, без вивантаження (§10 П5 на 8d94204).
        Серверна база — pull немає ніколи (§4.1: з providers: designer у кластері покоління не
        звіряється, #184); поставку без .cf там дає повний canon (дерево не змінюється — воно
        дорівнює базі), а тоді push force.
        Без критерію push force можливий лише з .cf на місці (current); missing/stale дають
        'blocked' з рецептом — push без .cf упав би на повному завантаженні. Це й є запасна гілка
        спеки §6: пілот вирішує, чи вона колись спрацює, але не прибирає її.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][bool]$Criterion,
        [Parameter(Mandatory)][ValidateSet('file', 'server')][string]$BaseKind
    )

    $set = $Source.Key
    $ws = $Source.Workspace
    $supply = if ($Source.Type -eq 'CONFIGURATION') { Get-KitSupplyState -TreeRoot $Source.FullPath } else { 'none' }
    $step = [pscustomobject]@{ SourceSet = $set; Workspace = $ws; RepoPath = $Source.RepoPath; BaseKind = $BaseKind
        Op = $null; Supply = $supply; MarkerOnly = $false; Steps = @(); Recipe = $null }
    $pushForce = Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = $set; force = $true })

    if ($Criterion -and $BaseKind -eq 'file') {
        $step.Op = 'pull'
        $pullArgs = [ordered]@{ sourceSet = $set }
        # Схема pull Уніки 0.13: extension «required for an extension source set and must match it»;
        # ім'я набору = ім'я розширення (обхід B5-B6).
        if ($Source.Type -eq 'EXTENSION') { $pullArgs['extension'] = $set }
        $pullArgs['force'] = $true
        $steps = @(Format-KitUnicaRun -Op 'pull' -Arguments $pullArgs)
        if ($supply -ne 'none') {
            $step.MarkerOnly = $true
            $steps += "kit canon -Workspace $ws -Source $set -MarkerOnly -Apply"
        }
        $step.Steps = $steps
        return $step
    }
    if ($Criterion -and $BaseKind -eq 'server') {
        $step.Op = 'push'
        # @(…) довкола if: вираз-if розгортає масив з одного елемента в рядок, і Steps[0] стало б першим символом.
        $step.Steps = @(if ($supply -in 'missing', 'stale') { "kit canon -Workspace $ws -Source $set -Apply"; $pushForce } else { $pushForce })
        return $step
    }
    if ($supply -in 'none', 'current') {
        $step.Op = 'push'
        $step.Steps = @($pushForce)
        return $step
    }
    $step.Op = 'blocked'
    $step.Recipe = ("Вирівняти пам'ять раннера для '$set' (воркспейс $ws) зараз неможливо: дерево набору не збігається з тим, що kit вивантажив, " +
        "а поставка вендора $supply — push force без .cf упав би на повному завантаженні. Рецепт — на головній гілці (HEAD = головна, " +
        "дерево чисте): kit verify -Workspace $ws -Source $set → крок, який він надрукує (файлова: pull Уніки й kit canon -Workspace $ws -Source $set -MarkerOnly -Apply; " +
        'серверна: kit canon і push force). Зупинка й доповідь людині, без обходу.')
    $step
}

function Write-KitAlignStep {
    <#
    .SYNOPSIS
        Друк кроку pull/push одразу після набору. Для 'blocked' — нічого: зупинки друкує
        Write-KitAlignStops ОСТАННІМИ, після підсумку команди (умова архітектора до Op 'blocked').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step)
    if ($Step.Op -eq 'blocked') { return }
    $why = if ($Step.Op -eq 'pull') { 'дерево набору дорівнює вивантаженому kit' } else { 'повне завантаження набору з git' }
    Write-KitNextSteps -Title "Далі — вирівняти пам'ять раннера для '$($Step.SourceSet)' (воркспейс $($Step.Workspace); $($Step.Op): $why), без питання людині:" -Steps $Step.Steps
    if ($Step.Op -eq 'pull') {
        Write-Host "    Після pull: git status --porcelain -- $($Step.RepoPath) мусить бути порожнім. Непорожній — вивантаження раннера дало інші байти, ніж kit: зупинка й доповідь людині, не робота для агента." -ForegroundColor Cyan
    }
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
    }
}

Export-ModuleMember -Function Format-KitUnicaRun, Write-KitNextSteps, Test-KitSetTreeEqual, Test-KitSetClean, Test-KitRefIsHead, Get-KitAlignStep, Write-KitAlignStep, Write-KitAlignStops
