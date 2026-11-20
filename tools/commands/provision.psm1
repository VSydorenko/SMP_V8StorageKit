#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module ризикував би перезавантаженням (docs/follow-ups.md §5).

function Test-KitConfigurationOwnerPresent {
    <#
    .SYNOPSIS
        Чи є на диску непорожнє дерево власника (CONFIGURATION source-set) воркспейсу.
    .DESCRIPTION
        «Порожня» база агента означає «порожня ІБ, наповнена push Уніки з джерел» (§4), а push
        вантажить власника з CONFIGURATION source-set (типово cf/src) і лише потім розширення. За
        truth: vendor це дерево гітігнороване й на щойно клонованій машині порожнє — без цієї
        перевірки мовчазний глухий кут.

        Перевірка безумовна: НЕ залежить від того, чи розширення позичає об'єкти
        (ObjectBelonging>Adopted, Get-KitAdoptedObjectCount нижче) — збірка .cfe й
        push без власника не проходять і для розширення без жодного
        запозичення, бо заглушка (tools/assets/empty-extension) не тримає типи власника
        (наприклад, УНФ). Adopted-лічильник нічого тут не вмикає — він лише пояснює
        людині причину зупинки конкретним числом.

        $true і тоді, коли у воркспейсі взагалі немає CONFIGURATION source-set (зовнішні
        обробки й подібне): вісь власника до такого воркспейсу не застосовна.

        Окремого Test-Path немає: Get-ChildItem -ErrorAction SilentlyContinue на неіснуючому
        шляху тихо повертає порожню колекцію, тож «теки немає» і «тека порожня» ловить той самий рядок.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)

    @(Get-KitMissingOwnerSources -Workspace $Workspace).Count -eq 0
}

function Get-KitMissingOwnerSources {
    <#
    .SYNOPSIS
        CONFIGURATION source-set'и воркспейсу з порожнім або відсутнім деревом на диску.
    .DESCRIPTION
        Єдине місце логіки «порожнє»: Test-KitConfigurationOwnerPresent — це «таких немає», а
        Invoke-KitProvision дивиться на самі джерела, щоб відрізнити законний старт рецепта (i)
        (усі порожні під truth: storage, §5.3) від зупинки.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)

    foreach ($src in @($Workspace.Sources | Where-Object Type -eq 'CONFIGURATION')) {
        if (@(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) { $src }
    }
}

function Get-KitAdoptedObjectCount {
    <#
    .SYNOPSIS
        Скільки об'єктів у EXTENSION source-set(ах) воркспейсу мають ObjectBelonging>Adopted.
    .DESCRIPTION
        Лише пояснює людині, чому відсутність власника — не питання смаку. Ні на що не впливає
        в Test-KitConfigurationOwnerPresent — та перевірка безумовна і без цього числа.

        Рахує пошуком по файлах дерева на диску, а не `git grep`: дерево, яке бачить
        provision, може мати ще не закомічені зміни (наприклад, щойно позичений об'єкт).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)

    $total = 0
    foreach ($src in @($Workspace.Sources | Where-Object Type -eq 'EXTENSION')) {
        if (-not (Test-Path -LiteralPath $src.FullPath -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue)) {
            $total += @(Select-String -LiteralPath $file.FullName -Pattern 'ObjectBelonging>Adopted' -SimpleMatch -ErrorAction SilentlyContinue).Count
        }
    }
    $total
}

function New-KitOwnerMissingMessage {
    <#
    .SYNOPSIS
        Текст зупинки Test-KitConfigurationOwnerPresent — куди звідки взяти власника, з ціною.
    .DESCRIPTION
        Приватний хелпер, винесений з Invoke-KitProvision лише заради читабельності виклику.
        Називає всі варіанти й ціну кожного: дамп (20–40 хв, 1–2 ГБ),
        .dt, серверна база від людини. Зупинка кидається лише для порожньої CONFIGURATION не під
        truth: storage (під storage порожня база законна — рецепт (i)), тож sync тут не пропонується.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)

    $configSet   = @($Workspace.Sources | Where-Object Type -eq 'CONFIGURATION') | Select-Object -First 1
    $configLabel = if ($configSet) { "дерево CONFIGURATION source-set '$($configSet.RepoPath)'" } else { 'дерево CONFIGURATION source-set' }
    $adopted     = Get-KitAdoptedObjectCount -Workspace $Workspace
    # Українська однина/двоїна/множина (n%10=1 і n%100≠11 → однина; n%10∈2..4 і n%100∉12..14 →
    # «об'єкти»; інакше — «об'єктів»).
    $objectWord = if ($adopted % 10 -eq 1 -and $adopted % 100 -ne 11) { "об'єкт" }
                  elseif ($adopted % 10 -in 2..4 -and $adopted % 100 -notin 12..14) { "об'єкти" }
                  else { "об'єктів" }
    $why = if ($adopted -gt 0) {
        "У розширенні цього воркспейсу $adopted $objectWord позначено ObjectBelonging>Adopted — без власника вони не типізуються (вимір задачі: 45 із 53 об'єктів розширення в SMP_BankExchange)."
    } else {
        "Розширення цього воркспейсу не позичає жодного об'єкта, але це не рятує: заглушка (tools/assets/empty-extension) не тримає типи власника (наприклад, УНФ), і push без нього так само не проходить."
    }
    "Воркспейсу '$($Workspace.Path)' бракує власника: $configLabel на диску порожнє або відсутнє. $why " +
    "«Порожня» база агента наповнюється push Уніки, а push спершу вантажить власника з цього дерева — без нього завантаження впаде на першому ж об'єкті. " +
    'Звідки взяти власника: дамп із дев-бази — kit dump -RepoRoot . -Apply (20–40 хв, 1–2 ГБ, за накладкою infobases:); ' +
    "файл .dt із конфігурацією власника — kit provision -RepoRoot . -Workspace $($Workspace.Path) -Apply -Template <шлях>.dt -Remember; " +
    "серверна база, яку дала людина (kit provision -ServerBase Existing). " +
    'Kit не пропонує порожню базу без власника — виберіть варіант і повторіть запуск.'
}


function Get-KitConfigurationFitness {
    <#
    .SYNOPSIS
        Чи придатне дерево основної конфігурації до повного завантаження в базу (спека §3 рішення 4).
    .DESCRIPTION
        «Базу створює той, хто першим її наповнює». Придатне → першою наповнює Уніка (infobase.create
        імпортує набір CONFIGURATION). Не придатне — truth: storage і (i) дерева ще немає або (ii)
        поставка вендора missing/stale, тобто .bin без .cf — повне завантаження впало б. Тоді першим
        наповнює kit зі сховища (sync чи verify), і порожню файлову базу створює теж kit. truth:
        vendor/dump сюди не входять: їхнє дерево приходить з kit dump разом із поставкою, а відсутність
        власника ловить New-KitOwnerMissingMessage раніше.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)
    foreach ($src in @($Workspace.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })) {
        if (@(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
            return [pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'i'; Supply = $null }
        }
        $state = Get-KitSupplyState -TreeRoot $src.FullPath
        if ($state -in 'missing', 'stale') {
            return [pscustomobject]@{ Fit = $false; Source = $src; Recipe = 'ii'; Supply = $state }
        }
    }
    [pscustomobject]@{ Fit = $true; Source = $null; Recipe = $null; Supply = $null }
}

function Get-KitProvisionNextKitStep {
    <#
    .SYNOPSIS
        Крок kit, яким першим наповнюється база за непридатного дерева: рецепт (i) — sync, (ii) — verify.
    .DESCRIPTION
        Рецепт (i) — дерева ще немає: kit sync наповнить базу й надрукує крок вирівнювання (Get-KitAlignStep):
        push Уніки з "force":true для набору. Рецепт (ii) — дерево є, поставка вендора missing/stale: текст
        бере Get-KitSupplyRecipe (-Purpose check) — той самий рецепт, що друкує kit check; поставку тут
        не переказуємо. Після verify база наповнена версією сховища, а його зупинка поставки (повний pull
        і kit supply-marker) — той самий рецепт з -Purpose stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Fitness,
        [Parameter(Mandatory)][string]$MainBranch,
        [string]$Workspace,
        [bool]$OnMainBranch
    )
    $k = $Fitness.Source.Key
    if ($Fitness.Recipe -eq 'i') {
        return ("kit sync -Source $k -FromLatest -Apply (або -FromVersion N) — на головній гілці чи гілці онбордингу; sync наповнить " +
                "базу й надрукує крок вирівнювання: push Уніки з `"force`":true для набору $k (а коли поставка вендора лишиться відсутньою чи застарілою — рецепт її відновлення замість кроку)")
    }
    Get-KitSupplyRecipe -SourceKey $k -Workspace $Workspace -MainBranch $MainBranch -State $Fitness.Supply -Purpose check -OnMainBranch $OnMainBranch
}

function Get-KitProvisionSteps {
    <#
    .SYNOPSIS
        Кроки після рішення provision (§4.2 п.17).
    .DESCRIPTION
        Придатне дерево: файлова без .dt — infobase.create і ЗВИЧАЙНИЙ push (база створюється з набором
        CONFIGURATION, раннер його пам'ятає); з .dt — infobase.restore і push force:true (restore пам'яті
        не пише); серверна наявна — push force:true (пам'яті про неї немає). Непридатне — крок kit
        ($NextKitStep) замість push: першим базу наповнює kit зі сховища.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('file-empty', 'file-dt', 'server-existing')][string]$Kind,
        [Parameter(Mandatory)]$Fitness,
        [string]$TemplatePath,
        [string]$NextKitStep,
        [AllowNull()][string[]]$PushSets = $null
    )
    $steps = [System.Collections.Generic.List[string]]::new()
    # Основа truth: vendor у базу не вантажиться ніколи (§4.2 п.23): push — лише з явним sourceSet розширень.
    $pushStep = {
        if ($null -ne $PushSets) {
            foreach ($set in $PushSets) { $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = $set; force = $true }))) }
        } else { $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ force = $true }))) }
    }
    if ($Kind -eq 'file-empty') {
        if ($Fitness.Fit) {
            $steps.Add((Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{})))
            $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{})))
        } else {
            $steps.Add($NextKitStep)
        }
        return , $steps.ToArray()
    }
    if ($Kind -eq 'file-dt') { $steps.Add((Format-KitUnicaRun -Op 'infobase.restore' -Arguments ([ordered]@{ input = $TemplatePath; mode = 'create' }))) }
    if ($Fitness.Fit) { & $pushStep }
    else              { $steps.Add($NextKitStep) }
    , $steps.ToArray()
}

function New-KitExistingBaseMessage {
    <#
    .SYNOPSIS
        Текст зупинки «тека за шляхом бази вже є»: називає ДВІ теки, які видаляє людина, і крок після цього.
    .DESCRIPTION
        Kit базу агента не видаляє ніколи (§3.4 п.3). Тека бази й тека пам'яті раннера
        (<воркспейс>/.local/infobases/origin) видаляються разом: без другої нова база лишилась би зі
        старою пам'яттю наборів, і push міг би пропустити набори як незмінені (§4.2 п.16). Тека без
        1Cv8.1CD — зовсім інша зупинка (New-KitNotBaseMessage), без поради видаляти; сюди потрапляє лише
        порожня тека чи тека з 1Cv8.1CD. Kit сам нічого не прибирає.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$MemoryPath,
        [Parameter(Mandatory)][bool]$HasBaseFile,
        [Parameter(Mandatory)][bool]$KitCreates,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Steps
    )
    $what = if ($HasBaseFile) { 'містить 1Cv8.1CD' } else { 'порожня' }
    $after = if ($KitCreates) {
        "повторіть kit provision -Workspace $WorkspacePath -Apply (kit створить порожню базу), далі: " + ($Steps -join ' → ')
    } else {
        'виконайте крок: ' + ($Steps -join ' → ')
    }
    ("Тека за шляхом бази агента воркспейсу '$WorkspacePath' уже є ($what): $BasePath. Kit базу агента не видаляє й не перезаписує ніколи — " +
     "ні цю теку, ні пам'ять раннера. Видаліть самі дві теки: '$BasePath' (база) і '$MemoryPath' (пам'ять раннера бази origin; без її видалення " +
     "нова база успадкує стару пам'ять наборів, і push міг би пропустити набори як незмінені; пам'ять раннера — його записник, не дані бази, " +
     "і після її видалення перший push буде повним) — і $after.")
}

function New-KitNotBaseMessage {
    <#
    .SYNOPSIS
        Зупинка «за шляхом бази лежить не база агента»: жодної поради видаляти (§4.2 п.16).
    .DESCRIPTION
        Описка в infobases.origin.connection (File=build/artifacts усередині workPath) інакше привела б до поради
        стерти артефакти чи іншу чужу теку. Про пам'ять раннера тут не йдеться. Reason: nonempty — непорожня тека
        без 1Cv8.1CD; file — за шляхом файл; unreadable — вміст теки не вдалося прочитати (невідоме не трактується
        як порожнє: інакше порада видалити теку з'явилась би для теки, яку kit не бачив).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath, [Parameter(Mandatory)][string]$BasePath,
          [Parameter(Mandatory)][ValidateSet('nonempty', 'file', 'unreadable')][string]$Reason)
    $what = switch ($Reason) {
        'file'       { "за шляхом $BasePath файл, а не тека бази" }
        'unreadable' { "тека $BasePath, вміст якої kit не зміг прочитати" }
        default      { "тека $BasePath непорожня й не містить 1Cv8.1CD" }
    }
    "За шляхом бази агента воркспейсу '$WorkspacePath' лежить не база агента ($what); " +
        'перевірте infobases.origin.connection у v8project.local.yaml. Kit нічого не створює й не прибирає.'
}

function New-KitStaleMemoryMessage {
    <#
    .SYNOPSIS
        Зупинка «бази немає, а пам'ять раннера лишилась» (§4.2 п.16): нова база стартує лише з чистою пам'яттю.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$MemoryPath,
        [Parameter(Mandatory)][bool]$KitCreates,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Steps
    )
    $after = if ($KitCreates) {
        "повторіть kit provision -Workspace $WorkspacePath -Apply (kit створить порожню базу), далі: " + ($Steps -join ' → ')
    } else {
        'виконайте крок: ' + ($Steps -join ' → ')
    }
    ("Бази агента воркспейсу '$WorkspacePath' ще немає, а пам'ять раннера від попередньої бази лишилась: видаліть теку пам'яті раннера '$MemoryPath' і $after. " +
     "Нова база з чужою пам'яттю наборів могла б пропустити набори як незмінені. Kit нічого не створює й не прибирає.")
}

function Get-KitProvisionPlan {
    <#
    .SYNOPSIS
        Перевірки provision для одного воркспейсу й план дій — без жодного побічного ефекту.
    .DESCRIPTION
        Кидає виняток на кожну відмову — Invoke-KitProvision збирає відмови всіх воркспейсів і зупиняє
        команду до першої дії: інакше відмова другого воркспейсу лишала б перший з уже створеною базою,
        а повторний запуск зупинявся б на ній як на наявній.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Workspace,
        [string]$Template,
        [string]$ServerBase,
        [bool]$Apply
    )
    $ws = $Workspace
    # Потребу в базі визначають ТИПИ наборів, не наявність infobases.origin: на свіжому клоні
    # файлу Уніки ще немає, і воркспейс з розширенням не можна приймати за воркспейс обробок.
    if (-not (Test-KitWorkspaceNeedsAgentBase -Workspace $ws)) { return [pscustomobject]@{ Ws = $ws; Skip = $true } }
    $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
    if ($null -eq $ab) { throw (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path) }

    # $wsTemplate — ОКРЕМА змінна від параметра -Template: імена змінних PowerShell реєстронечутливі,
    # і $template = $Template стало б однією змінною — шаблон з накладки першого воркспейсу
    # перезаписав би параметр і протік у наступний воркспейс циклу.
    $wsTemplate = $Template
    if (-not $wsTemplate -and $Context.Overlay -and $Context.Overlay.Workspaces.ContainsKey($ws.Path)) {
        $wsTemplate = $Context.Overlay.Workspaces[$ws.Path].AgentBaseTemplate
    }
    # Основа truth: vendor (§4.2 п.23): ні Уніка, ні kit не вантажать її в базу — вона приходить разом з базою
    # (.dt чи наявна серверна). Порожня база kit/infobase.create → push основи тут глухий кут: зупинка з рецептом.
    $vendorBases = @($ws.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'vendor' })
    $pushSets = $null
    if ($vendorBases.Count -gt 0) {
        $pushSets = @($ws.Sources | Where-Object Type -eq 'EXTENSION' | ForEach-Object { $_.Key })
        if (-not $wsTemplate -and $ab.Kind -eq 'file') {
            throw ("Воркспейс '$($ws.Path)': основа '$($vendorBases[0].Key)' має truth: vendor, а бази агента немає. " +
                   'База агента для воркспейсу з основою vendor — з .dt (kit provision -Template <шлях>.dt, крок infobase.restore) або наявна серверна (-ServerBase Existing); ' +
                   'kit і Уніка основу vendor у базу не вантажать (Уніка 0.16 відмовляє на гітігнорованому наборі), порожню базу kit тут не створює.')
        }
    }
    # Вісь власника — до вибору типу бази: порожнє дерево
    # під truth: storage — не зупинка, а рецепт (i) нижче (Get-KitConfigurationFitness).
    if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) {
        $missing = @(Get-KitMissingOwnerSources -Workspace $ws)
        if (@($missing | Where-Object Truth -ne 'storage').Count -gt 0) { throw (New-KitOwnerMissingMessage -Workspace $ws) }
    }
    $fitness = Get-KitConfigurationFitness -Workspace $ws
    $isFileBase = ($ab.Kind -eq 'file')
    $unfitNote = $null
    if (-not $fitness.Fit) {
        $why = if ($fitness.Recipe -eq 'i') { 'дерева ще немає — рецепт (i)' } else { "поставка вендора $($fitness.Supply) — рецепт (ii)" }
        $who = if (-not $isFileBase) { '; база серверна, її створила людина.' }
               elseif ($wsTemplate)  { '; створює її Уніка (restore).' }
               else                  { ', тож порожню файлову базу створює теж kit.' }
        $unfitNote = ("  Дерево основної конфігурації '{0}' не придатне до завантаження ({1}): першим базу наповнить kit зі сховища" -f $fitness.Source.Key, $why) + $who
    }
    $nextKit = $null
    if (-not $fitness.Fit) {
        $onMain = $false
        if ($fitness.Recipe -eq 'ii') { $onMain = Test-KitOnMainBranch -RepoRoot $Context.RepoRoot -MainBranch $Context.MainBranch }
        $nextKit = Get-KitProvisionNextKitStep -Fitness $fitness -MainBranch $Context.MainBranch -Workspace $ws.Path -OnMainBranch $onMain
    }

    # Межа: РОБОЧА тека воркспейсу (workPath, §2.5/§4), НЕ вся тека воркспейсу. Kit пише в теку
    # бази (New-V8FileInfobase), тож шлях бази мусить лежати під workPath: аудит Resolve-KitAgentBase
    # ловить базу людини під чужим ім'ям, ця межа — БУДЬ-ЯКУ теку поза робочою (описка
    # infobase.connection: 'File=cfe/src'). $ws.Project.WorkPath, не літерал 'build': workPath конфігурований.
    $agentWork = Join-Path $ws.FullPath $ws.Project.WorkPath
    # Корені власності: workPath стає коренем власності (може бути посиланням), а тека набору — ніколи.
    # Тож workPath, що дорівнює кореню набору, лежить у ньому чи містить його, відхиляється ДО будь-якої дії.
    # У повідомлення — лише шляхи відносно воркспейсу (значення конфігу поза ними не друкуємо).
    $agentWorkFull = [System.IO.Path]::GetFullPath($agentWork).TrimEnd('\', '/')
    foreach ($setSrc in @($ws.Sources)) {
        $setFull = [System.IO.Path]::GetFullPath($setSrc.FullPath).TrimEnd('\', '/')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        if (($agentWorkFull -eq $setFull) -or $agentWorkFull.StartsWith($setFull + $sep, [System.StringComparison]::OrdinalIgnoreCase) -or $setFull.StartsWith($agentWorkFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("workPath у v8project.yaml воркспейсу '$($ws.Path)' збігається з деревом джерела '$($setSrc.Key)', лежить у ньому чи над ним — " +
                   'робоча тека агента не може перетинатися з вихідниками. Рішення за людиною: workPath у v8project.yaml — окрема тека воркспейсу поза деревами джерел (типово build).')
        }
    }
    Assert-SafeWorkPath -Path $agentWork -MustBeUnder $ws.FullPath -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "робоча тека воркспейсу $($ws.Path) (workPath у v8project.yaml)"

    $plan = [pscustomobject]@{
        Ws = $ws; Skip = $false; Ab = $ab; WsTemplate = $wsTemplate; Fitness = $fitness; UnfitNote = $unfitNote
        AgentWork = $agentWork; Server = (-not $isFileBase)
        Kind = $null; Steps = @(); KitCreates = $false; CreatedBy = $null
    }

    if (-not $isFileBase) {
        if (-not $ServerBase) {
            throw ("База агента воркспейсу '$($ws.Path)' серверна ($($ab.Connection)). Серверну базу створює людина в кластері; kit її не створює й не видаляє. " +
                   'Коли база є — kit provision -ServerBase Existing: kit надрукує крок.')
        }
        if ($wsTemplate) { throw '-Template (.dt) для серверної бази агента не підтримується: розгортання .dt на сервері — поза обсягом. Приберіть -Template чи agentBase.template з накладки.' }
        $plan.Kind = 'server-existing'
        $plan.Steps = Get-KitProvisionSteps -Kind $plan.Kind -Fitness $fitness -NextKitStep $nextKit -PushSets $pushSets
        $plan.CreatedBy = 'existing'
        return $plan
    }
    if ($ServerBase) { throw "-ServerBase стосується лише серверної бази агента, а в $($ab.Origin) — файлова ($($ab.Connection))." }

    Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "база агента воркспейсу $($ws.Path)"
    # Шлях бази не перетинається з <тека v8project.yaml>/.local: там раннер веде пам'ять баз (hashes/,
    # dump-info/, generation.json) і свій .gitignore. Збіг, вкладення чи охоплення — відмова до будь-якого
    # створення; предикат перетину той самий, що в аудиті.
    $runnerLocal = Join-Path $ws.Project.Directory '.local'
    if ((Test-KitPathsOverlap -Left $ab.Path -Right $runnerLocal) -or (Test-KitPathsOverlap -Left $ab.Path -Right (Get-KitRunnerMemoryPath -Project $ws.Project))) {
        throw ("Шлях бази агента воркспейсу '$($ws.Path)' збігається з '.local' воркспейсу (тека пам'яті раннера), лежить у ній чи над нею — " +
               'kit базу туди не кладе. Рішення за людиною: infobases.origin.connection у v8project.local.yaml — окрема тека бази (типово build/ib).')
    }
    if ($Apply -and $wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }

    $plan.Kind = if ($wsTemplate) { 'file-dt' } else { 'file-empty' }
    $templateFull = if ($wsTemplate -and (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { (Resolve-Path -LiteralPath $wsTemplate).Path } else { $wsTemplate }
    $plan.Steps = Get-KitProvisionSteps -Kind $plan.Kind -Fitness $fitness -TemplatePath $templateFull -NextKitStep $nextKit -PushSets $pushSets
    $plan.KitCreates = ($plan.Kind -eq 'file-empty' -and -not $fitness.Fit)
    $plan.CreatedBy = if ($plan.KitCreates) { 'kit' } else { 'unica' }

    # Перетин з базою чи пам'яттю раннера ІНШОГО воркспейсу — до гілки «наявна тека»: через посилання
    # (junction B/build -> A/build) порада «видаліть дві теки» вказала б на базу воркспейсу A. Нової логіки
    # перетину тут немає — Find-KitAgentBaseCollisions; поради видаляти зупинка не містить.
    $collisions = @(Find-KitAgentBaseCollisions -Context $Context -Workspace $ws)
    if ($collisions.Count -gt 0) {
        $others = (@($collisions | ForEach-Object { "'$($_.Other)'" } | Select-Object -Unique)) -join ', '
        throw ("База агента чи пам'ять раннера воркспейсу '$($ws.Path)' перетинається з базою агента чи пам'яттю раннера воркспейсу $others " +
               "(одна тека, вкладена чи батьківська). Kit базу в такому місці не створює й нічого не прибирає; порад видаляти теки немає, поки перетин не усунено. " +
               'Рішення за людиною: окрема тека infobases.origin.connection кожного воркспейсу (v8project.local.yaml).')
    }

    # Будь-яка наявна тека (чи файл) за шляхом бази — зупинка, незалежно від -Apply: kit нічого не стирає
    # й не перезаписує. Людина видаляє дві теки сама (§3.4 п.3, п.4; §4.2 п.16).
    if (Test-Path -LiteralPath $ab.Path) {
        # Файл, непорожня тека без 1Cv8.1CD чи тека, вміст якої не вдалося прочитати, — не база агента:
        # окрема зупинка без поради видаляти. Помилка читання не трактується як «порожньо» (fail-closed).
        if (-not $ab.Exists) {
            if (Test-Path -LiteralPath $ab.Path -PathType Leaf) {
                throw (New-KitNotBaseMessage -WorkspacePath $ws.Path -BasePath $ab.Path -Reason 'file')
            }
            try { $entries = @(Get-ChildItem -LiteralPath $ab.Path -Force -ErrorAction Stop) }
            catch { throw (New-KitNotBaseMessage -WorkspacePath $ws.Path -BasePath $ab.Path -Reason 'unreadable') }
            if ($entries.Count -gt 0) {
                throw (New-KitNotBaseMessage -WorkspacePath $ws.Path -BasePath $ab.Path -Reason 'nonempty')
            }
        }
        throw (New-KitExistingBaseMessage -WorkspacePath $ws.Path -BasePath $ab.Path -MemoryPath (Get-KitRunnerMemoryPath -Project $ws.Project) `
            -HasBaseFile $ab.Exists -KitCreates $plan.KitCreates -Steps $plan.Steps)
    }
    # Бази немає, а пам'ять раннера лишилась: база створюється заново (infobase.create чи порожня база kit) лише з
    # чистою пам'яттю. Після infobase.restore крок — push force:true, пам'ять він перезаписує: зупинки немає.
    if ($plan.Kind -eq 'file-empty') {
        $mem = Get-KitRunnerMemoryPath -Project $ws.Project
        if (Test-Path -LiteralPath $mem) {
            throw (New-KitStaleMemoryMessage -WorkspacePath $ws.Path -MemoryPath $mem -KitCreates $plan.KitCreates -Steps $plan.Steps)
        }
    }
    $plan
}

function Invoke-KitProvision {
    <#
    .SYNOPSIS
        База агента (§3.4): kit перевіряє, записує вибір і друкує кроки; базу агента
        НЕ видаляє ніколи й серверних баз не створює.
    .DESCRIPTION
        Придатне дерево основної конфігурації — базу створює Уніка (infobase.create / infobase.restore), kit
        лише друкує кроки. Непридатне (truth: storage без дерева чи з поставкою missing/stale) — першим базу
        наповнює kit зі сховища, тож порожню файлову базу створює теж kit — єдина дія команди над базою,
        і лише коли шляху бази ще немає (New-V8FileInfobase -NoReplace). Наявна тека за шляхом бази — зупинка
        з двома теками, які видаляє людина (база й пам'ять раннера). Серверну базу створює людина в
        кластері: -ServerBase Existing лише друкує крок push force:true.

        Спершу перевіряються всі воркспейси (без побічних ефектів), потім виконуються дії: відмова
        другого воркспейсу не лишає першого з уже створеною базою.
    .PARAMETER Template
        Файл .dt; без нього береться workspaces.<ws>.agentBase.template з накладки; без обох — порожня база.
    .PARAMETER Remember
        Записати -Template у v8storagekit.local.yaml (те, що робить скіл provision після питання).
    .PARAMETER ServerBase
        Лише для серверної бази агента: Existing — базу створила людина в кластері.
    .PARAMETER RunnerPath
        Шлях до раннера Уніки; порожній — із реєстру плагінів (Get-KitRunnerPath), і лише коли kit сам створює
        порожню базу (платформу для неї обирає раннер). Явний параметр, не змінна оточення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Template,
        [switch]$Remember,
        [ValidateSet('Existing')][string]$ServerBase,
        [string]$RunnerPath
    )

    if ($Remember -and -not $Template) { throw 'Параметр -Remember потребує -Template <файл.dt>: нема що записувати в накладку.' }
    $workspaces = @($Context.Workspaces)
    if ($Workspace) {
        $workspaces = @($workspaces | Where-Object Path -eq $Workspace)
        if ($workspaces.Count -eq 0) { throw "Воркспейсу '$Workspace' немає в маніфесті. Є: $($Context.Workspaces.Path -join ', ')." }
    }
    # База агента належить ВОРКСПЕЙСУ, не джерелу, тож -Source тут означає «воркспейс, який
    # містить це джерело» — форма, якою його й кличуть: людина знає ім'я розширення, а не
    # ім'я теки воркспейсу. Звуження йде через наявну Select-KitSources, а не власним
    # пошуком: вона вже дає правильні зупинки на невідомому ключі й на ключі, що є в кількох
    # воркспейсах (друга перевірка з іншою логікою гірша за жодну).
    if ($Source) {
        $matched = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        $wsOfSource = @($matched.Workspace | Sort-Object -Unique)
        $workspaces = @($workspaces | Where-Object { $wsOfSource -contains $_.Path })
    }
    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $Context.RepoRoot 'v8storagekit.local.yaml' }
    $done = [System.Collections.Generic.List[object]]::new()

    # Перевірки всіх воркспейсів, без побічних ефектів. Відмови збираються, не кидаються по одній.
    $plans = [System.Collections.Generic.List[object]]::new()
    $refusals = [System.Collections.Generic.List[string]]::new()
    foreach ($ws in $workspaces) {
        try {
            $plans.Add((Get-KitProvisionPlan -Context $Context -Workspace $ws -Template $Template -ServerBase $ServerBase -Apply $Apply))
        } catch {
            $refusals.Add(("  - {0}: {1}" -f $ws.Path, $_.Exception.Message))
        }
    }
    if ($refusals.Count -gt 0) {
        throw ("Перевірки перед змінами не пройдено — нічого не створено й не видалено:`n" + ($refusals -join "`n"))
    }

    # Платформу для порожньої бази, яку створює kit, обирає раннер. Раннер питаємо лише коли kit справді
    # створюватиме базу, і для всіх воркспейсів ДО першого створення: збій раннера не лишає напівстану.
    $platformByWs = @{}
    if ($Apply) {
        $runner = $RunnerPath
        foreach ($plan in @($plans | Where-Object { -not $_.Skip -and $_.KitCreates })) {
            if (-not $runner) { $runner = Get-KitRunnerPath }
            $platformByWs[$plan.Ws.Path] = Get-KitAgentPlatform -Project $plan.Ws.Project -RunnerPath $runner
        }
    }

    foreach ($plan in $plans) {
        $ws = $plan.Ws
        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        if ($plan.Skip) {
            Write-Host '  У воркспейсі лише зовнішні обробки — бази агента тут не буває.'
            continue
        }
        $ab = $plan.Ab
        $steps = $plan.Steps
        Write-Host "База:$($ab.Connection)  ($($ab.Origin))"
        if ($plan.UnfitNote) { Write-Host $plan.UnfitNote -ForegroundColor Cyan }

        if ($plan.Server) {
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $null; Template = $null; CreatedBy = $plan.CreatedBy; Steps = $steps })
            continue
        }

        $wsTemplate = $plan.WsTemplate
        Write-Host ('Шлях:      ' + $ab.Path + '  (ще немає)')
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            if ($plan.KitCreates) { Write-Host '  З -Apply kit сам створить порожню файлову базу.' -ForegroundColor Cyan }
            elseif (-not $plan.Fitness.Fit) { Write-Host '  Першим базу наповнить kit; створює її Уніка (restore) — крок нижче.' -ForegroundColor Cyan }
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            # -Remember без -Apply не мовчить — шаблон ще не записано.
            if ($Remember) { Write-Host '  Шаблон буде записано в накладку разом із -Apply (-Remember саме по собі нічого не пише).' -ForegroundColor DarkGray }
            continue
        }

        if ($plan.KitCreates) {
            Write-Host '  Створюю порожню базу (першим її наповнить kit зі сховища)...'
            # -NoReplace: шлях перевірено в плані, але між перевіркою й створенням тека могла з'явитись
            # (паралельна сесія, людина) — тоді виняток, а не стирання.
            $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $plan.AgentWork -RepoRoot $Context.RepoRoot -OwnedRoot $plan.AgentWork `
                -V8Path $platformByWs[$ws.Path] -NoReplace
            Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        } else {
            Write-Host '  Базу створює Уніка — крок нижче.' -ForegroundColor Green
        }
        Write-KitNextSteps -Title 'Далі:' -Steps $steps

        if ($Remember) {
            Save-KitOverlayAgentBase -OverlayPath $overlayPath -WorkspacePath $ws.Path -Template $wsTemplate
            Write-Host "  Шаблон записано в $overlayPath (workspaces.$($ws.Path).agentBase.template)." -ForegroundColor DarkGray
        }
        $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $ab.Path; Template = $wsTemplate; CreatedBy = $plan.CreatedBy; Steps = $steps })
    }
    [pscustomobject]@{ ExitCode = 0; Provisioned = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitProvision
