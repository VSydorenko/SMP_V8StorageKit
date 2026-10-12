#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Test-KitConfigurationOwnerPresent {
    <#
    .SYNOPSIS
        Чи є на диску непорожнє дерево власника (CONFIGURATION source-set) воркспейсу.
    .DESCRIPTION
        Вісь задачі (рішення користувача 2026-09-10, спека §4, d3e539c): «порожня» база
        агента означає «порожня ІБ, наповнена push Уніки з джерел», а push вантажить
        власника з CONFIGURATION source-set (типово cf/src) і лише потім розширення. За
        truth: vendor це дерево гітігнороване (templates/gitignore) і на щойно клонованій
        машині порожнє — «порожня» тоді веде build у мовчазний глухий кут.

        Перевірка безумовна: НЕ залежить від того, чи розширення позичає об'єкти
        (ObjectBelonging>Adopted, Get-KitAdoptedObjectCount нижче) — збірка .cfe й
        push без власника не проходять і для розширення без жодного
        запозичення, бо заглушка (tools/assets/empty-extension) не тримає типи власника
        (наприклад, УНФ). Adopted-лічильник нічого тут не вмикає — він лише пояснює
        людині причину зупинки конкретним числом.

        $true і тоді, коли у воркспейсі взагалі немає CONFIGURATION source-set (зовнішні
        обробки й подібне): вісь власника до такого воркспейсу не застосовна.

        Немає окремого Test-Path на існування теки: Get-ChildItem -ErrorAction
        SilentlyContinue на неіснуючому шляху так само тихо повертає порожню колекцію
        (перевірено), тож "теки немає" і "тека є, але порожня" ловить один і той самий
        рядок нижче — окрема перевірка існування була б мертвим кодом, який ніколи не
        виконує саме ту роль, для якої писався (рев'ю B8 Task 12, Minor 2).
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
        (усі порожні під truth: storage, спека 2026-09-30 §5.3) від зупинки.
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
        Лише пояснює людині, чому відсутність власника — не питання смаку (вимір задачі:
        45 із 53 об'єктів розширення в SMP_BankExchange — Adopted; текст-джерело виміру —
        skills/provision/SKILL.md). Ні на що не впливає в
        Test-KitConfigurationOwnerPresent — та перевірка безумовна і без цього числа.

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
        Називає всі варіанти й ціну кожного (Крок 1 брифа задачі): дамп (20–40 хв, 1–2 ГБ),
        .dt, серверна база від людини. Зупинка кидається лише для порожньої CONFIGURATION не під
        truth: storage (під storage порожня база законна — рецепт (i)), тож sync тут не пропонується.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)

    $configSet   = @($Workspace.Sources | Where-Object Type -eq 'CONFIGURATION') | Select-Object -First 1
    $configLabel = if ($configSet) { "дерево CONFIGURATION source-set '$($configSet.RepoPath)'" } else { 'дерево CONFIGURATION source-set' }
    $adopted     = Get-KitAdoptedObjectCount -Workspace $Workspace
    # Українська однина/двоїна/множина (n%10=1 і n%100≠11 → однина; n%10∈2..4 і n%100∉12..14 →
    # «об'єкти»; інакше — «об'єктів»). Без цього "1 об'єктів" звучить як помилка граматики
    # (рев'ю B8 Task 12, Minor 3), а $adopted тут завжди реальне число, не заглушка.
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
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Fitness, [Parameter(Mandatory)][string]$MainBranch)
    $k = $Fitness.Source.Key
    if ($Fitness.Recipe -eq 'i') {
        return ("kit sync -Source $k -FromLatest -Apply (або -FromVersion N) — на головній гілці чи гілці онбордингу; sync наповнить " +
                'базу й надрукує крок вирівнювання Уніки (pull і позначку поставки)')
    }
    "kit verify -Source $k — на гілці $MainBranch (HEAD = $MainBranch, дерево чисте); очікувано equal, verify наповнить базу й надрукує pull Уніки та kit canon -Source $k -MarkerOnly -Apply"
}

function Get-KitProvisionSteps {
    <#
    .SYNOPSIS
        Кроки після рішення provision — одна таблиця спеки §4.2 (на 8d94204) замість розгалужень по тексту.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('file-empty', 'file-dt', 'server-new', 'server-existing')][string]$Kind,
        [Parameter(Mandatory)]$Fitness,
        [string]$TemplatePath,
        [Parameter(Mandatory)][string]$MainBranch
    )
    $steps = [System.Collections.Generic.List[string]]::new()
    if ($Kind -eq 'file-empty') {
        if ($Fitness.Fit) {
            $steps.Add((Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{})))
            $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{})))
        } else {
            $steps.Add((Get-KitProvisionNextKitStep -Fitness $Fitness -MainBranch $MainBranch))
        }
        return , $steps.ToArray()
    }
    if ($Kind -eq 'file-dt')    { $steps.Add((Format-KitUnicaRun -Op 'infobase.restore' -Arguments ([ordered]@{ input = $TemplatePath; mode = 'create' }))) }
    if ($Kind -eq 'server-new') { $steps.Add((Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{}))) }
    if ($Fitness.Fit) { $steps.Add((Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ force = $true }))) }
    else              { $steps.Add((Get-KitProvisionNextKitStep -Fitness $Fitness -MainBranch $MainBranch)) }
    , $steps.ToArray()
}

function Invoke-KitProtectedPathsMarkerPhase {
    <#
    .SYNOPSIS
        Маркер-фаза між проходами: чи не ховається захищений шлях за псевдонімом теки, яку видалятиме прогін (П26 п. 6–7).
    .DESCRIPTION
        Текстова канонізація не зводить псевдоніми шляху (\\localhost\C$\…, subst-диск, мережевий диск) до
        локального шляху, тож захищений шлях під псевдонімом невидимий для першого проходу. Другий рівень —
        ідентичність за дією, і він стоїть ПІСЛЯ першого проходу й ДО другого, для всіх воркспейсів разом:
        інакше відмова на другому воркспейсі лишала б перший уже видаленим (напівстан, який закриває п. 4).

        Порядок: (1) у КОЖНУ наявну теку, яку видалятиме прогін (база агента, пам'ять раннера origin, усіх
        воркспейсів), кладеться маркер з унікальним іменем — лише після Assert-SafeWorkPath для цієї самої
        теки, щоб маркер не ліг крізь посилання; теці, якої ще немає, маркер не потрібен; збій запису маркера
        — відмова (fail-closed), а не пропуск цілі; (2) для кожного елемента переліку захищених шляхів
        (Get-KitProtectedPaths, його зберіг перший прохід у плані) перевіряється Test-Path маркера за шляхом
        елемента й за кожним його предком у ВЛАСНОМУ написанні (для файла-шаблону — за наявними предками);
        (3) усі маркери знімаються у finally; (4) є відмова — виняток, і другий прохід (видалення) не
        починається. Пишеться лише в теки, які прогін і так видаляє, тож «перший прохід без побічних ефектів»
        лишається правдою: маркер живе лише всередині цієї функції.

        Межі, свідомі й безпечні (спека П26 п. 7):
        M-A. Недоступний кандидат-псевдонім (шара офлайн, немає прав) маркер-рівень пропускає: Test-Path дає
        «не видно». Маркер щойно записано під тим самим користувачем, тож недоступний йому шлях не веде в теку,
        куди kit пише; відмова тут зупиняла б provision у кожного, чия дев-база лежить на офлайн-шарі, а шкоди
        не запобігала б. Текстовий рівень для такого кандидата діє.
        J5/K3. Дев-базу, що є ПРЕДКОМ теки агента, текстовий рівень відхиляє, а маркер-рівень пропускає: маркер
        видно лише там, де кандидат веде В теку видалення чи в її середину, а предка вона не торкається.
        Видаляється лише підтека, база людини ціла. Обидва результати безпечні.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plans)

    $markers = [System.Collections.Generic.List[object]]::new()
    $refusals = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($plan in @($Plans | Where-Object { -not $_.Skip })) {
            $ws = $plan.Ws
            $doomed = [System.Collections.Generic.List[object]]::new()
            if (-not $plan.Server) { $doomed.Add(@($plan.Ab.Path, "база агента воркспейсу $($ws.Path)")) }
            $doomed.Add(@($plan.MemoryDir, "пам'ять раннера бази origin воркспейсу $($ws.Path)"))
            foreach ($d in $doomed) {
                $dir = $d[0]; $what = $d[1]
                try {
                    Assert-SafeWorkPath -Path $dir -MustBeUnder $plan.AgentWork -RepoRoot $Context.RepoRoot -OwnedRoot $plan.AgentWork -Description $what
                    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
                    $name = '.kit-alias-probe-' + [guid]::NewGuid().ToString('N')
                    $marker = Join-Path $dir $name
                    # Запис у $markers — ДО запису маркера: напівзаписаний файл теж мусить бути знятий у finally.
                    $markers.Add([pscustomobject]@{ Plan = $plan; What = $what; Name = $name; Marker = $marker })
                    Set-Content -LiteralPath $marker -Value 'kit' -Encoding UTF8 -ErrorAction Stop
                } catch {
                    $refusals.Add("  - ${what}: не вдалося покласти маркер перевірки псевдонімів шляху (kit не може довести, що чужого немає в цій теці).")
                }
            }
        }
        foreach ($m in $markers) {
            foreach ($el in @($m.Plan.Protected)) {
                foreach ($cand in @($el.Candidates)) {
                    if (Test-Path -LiteralPath (Join-Path $cand $m.Name) -ErrorAction SilentlyContinue) {
                        $refusals.Add("  - $($m.What) і $($el.Label) — та сама тека чи одна в одній (через псевдонім шляху, напр. \\localhost\C`$\… чи subst-диск). " +
                            'kit не прибирає теку, у якій може лежати чужа база чи файл людини. Виправлення: задайте шлях без псевдонімів.')
                        break
                    }
                }
            }
        }
    } finally {
        foreach ($m in $markers) { Remove-Item -LiteralPath $m.Marker -Force -ErrorAction SilentlyContinue }
    }
    if ($refusals.Count -gt 0) {
        throw ("Перевірка псевдонімів шляху не пройдена — нічого не прибрано й не створено:`n" + ($refusals -join "`n"))
    }
}

function Get-KitProvisionPlan {
    <#
    .SYNOPSIS
        Перший прохід provision для одного воркспейсу: усі перевірки, жодного побічного ефекту (П26 п. 4).
    .DESCRIPTION
        Кидає виняток на кожну відмову — Invoke-KitProvision збирає відмови всіх воркспейсів і зупиняє
        команду ДО першого видалення. Повертає план, за яким другий прохід друкує, прибирає й створює.
        Усе, що може відмовити за -Apply (база є без -Force, .dt не знайдено), перевіряється тут, а не
        посеред видалень.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Workspace,
        [string]$Template,
        [string]$ServerBase,
        [bool]$Apply,
        [bool]$Force
    )
    $ws = $Workspace
    # Потребу в базі визначають ТИПИ наборів, не наявність infobases.origin (П16): на свіжому клоні
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

    # Вісь власника — до вибору типу бази (рішення користувача 2026-09-10): порожнє дерево
    # під truth: storage — не зупинка, а рецепт (i) нижче (Get-KitConfigurationFitness).
    if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) {
        $missing = @(Get-KitMissingOwnerSources -Workspace $ws)
        if (@($missing | Where-Object Truth -ne 'storage').Count -gt 0) { throw (New-KitOwnerMissingMessage -Workspace $ws) }
    }
    $fitness = Get-KitConfigurationFitness -Workspace $ws
    $unfitNote = $null
    if (-not $fitness.Fit) {
        $why = if ($fitness.Recipe -eq 'i') { 'дерева ще немає — рецепт (i)' } else { "поставка вендора $($fitness.Supply) — рецепт (ii)" }
        $unfitNote = ("  Дерево основної конфігурації '{0}' не придатне до завантаження ({1}): першим базу наповнить kit зі сховища" + $(if ($ab.Kind -eq 'file' -and -not $wsTemplate) { ', тож порожню файлову базу створює теж kit.' } else { '; створює її Уніка (create/restore).' })) -f $fitness.Source.Key, $why
    }

    # F7 (рев'ю B4 Task 1) — межа видалення/створення: РОБОЧА тека воркспейсу (workPath, §2.5/§4),
    # НЕ вся тека воркспейсу. Другий, незалежний від аудиту принципу 3 (Resolve-KitAgentBase)
    # запобіжник: аудит ловить базу людини під чужим ім'ям, ця межа ловить БУДЬ-ЯКУ теку поза
    # робочою — навіть описку infobase.connection: 'File=cfe/src' (законну підтеку воркспейсу).
    # Той самий Assert-SafeWorkPath застосовано до самої межі: він відхиляє рівність із межею
    # (край workPath: '.'), сегмент ".." і ненормалізований шлях. $ws.Project.WorkPath, не літерал
    # 'build': workPath конфігурований у v8project.yaml, і решта kit його шанує.
    $agentWork = Join-Path $ws.FullPath $ws.Project.WorkPath
    # П25 «Корені власності»: workPath стає коренем власності (може бути посиланням), а тека набору — ніколи.
    # Тож workPath, що дорівнює кореню набору, лежить у ньому чи містить його, відхиляється ДО будь-якого
    # видалення. У повідомлення — лише шляхи відносно воркспейсу (значення конфігу поза ними не друкуємо).
    $agentWorkFull = [System.IO.Path]::GetFullPath($agentWork).TrimEnd('\', '/')
    foreach ($setSrc in @($ws.Sources)) {
        $setFull = [System.IO.Path]::GetFullPath($setSrc.FullPath).TrimEnd('\', '/')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        if (($agentWorkFull -eq $setFull) -or $agentWorkFull.StartsWith($setFull + $sep, [System.StringComparison]::OrdinalIgnoreCase) -or $setFull.StartsWith($agentWorkFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("workPath у v8project.yaml воркспейсу '$($ws.Path)' збігається з деревом джерела '$($setSrc.Key)', лежить у ньому чи над ним — " +
                   'робоча тека агента не може перетинатися з вихідниками. Виправлення: у v8project.yaml задайте workPath окремою текою воркспейсу поза деревами джерел (типово build).')
        }
    }
    Assert-SafeWorkPath -Path $agentWork -MustBeUnder $ws.FullPath -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "робоча тека воркспейсу $($ws.Path) (workPath у v8project.yaml)"
    # Спека §10 П7: пам'ять раннера знищеної чи чужої бази — інакше старі хеші розширень стали б
    # «своєю» пам'яттю нової бази, і push пропустив би їх (клас #25). Мітку власника й замок поруч
    # (інші файли <workPath>/infobases/) не чіпати. Межа та сама: корінь власності — workPath.
    $memoryDir = Join-Path $agentWork 'infobases/origin'
    Assert-SafeWorkPath -Path $memoryDir -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "пам'ять раннера бази origin воркспейсу $($ws.Path)"

    # П26 п. 7: ОДИН перелік захищених шляхів (дев-бази, бази й <workPath>/infobases інших воркспейсів, шаблон) —
    # його будує Get-KitProtectedPaths. Тут він іде на текстовий перетин з канонізацією (перший рівень), а
    # збережений у плані — на маркер-фазу між проходами (другий рівень). П26 п. 5: перевірка йде проти ВСІХ
    # воркспейсів маніфесту, не лише проти воркспейсів прогону (-Workspace B інакше не бачив би A, вкладену в B).
    $protected = @(Get-KitProtectedPaths -Context $Context -Workspace $ws -Template $wsTemplate)
    $targets = @{
        base      = [pscustomobject]@{ Path = $(if ($ab.Kind -eq 'file') { $ab.Path } else { $null }); Connection = $(if ($ab.Kind -eq 'file') { $null } else { $ab.Connection }) }
        infobases = [pscustomobject]@{ Path = (Join-Path $agentWork 'infobases'); Connection = $null }
        memory    = [pscustomobject]@{ Path = $memoryDir; Connection = $null }
    }
    $hits = @(Find-KitProtectedCollisions -Protected $protected -Targets $targets)
    $tplHit = @($hits | Where-Object { $_.Element.Kind -eq 'template' })
    if ($tplHit.Count -gt 0) {
        # Шаблон (.dt) — файл людини: у теці, яку -Apply зараз прибере (база чи пам'ять раннера), видалення знищило б
        # його, а крок restore посилався б на неіснуючий файл. Відмова до будь-якого видалення.
        throw ("Шаблон бази (.dt) лежить у теці, яку kit прибирає при перестворенні бази агента воркспейсу '$($ws.Path)' (тека бази чи пам'ять раннера під робочою текою). " +
               'Перенесіть .dt поза робочу теку воркспейсу і повторіть команду.')
    }
    if ($hits.Count -gt 0) {
        $what = foreach ($h in $hits) {
            $el = $h.Element
            if ($el.Kind -eq 'otherbase' -and $h.Target -eq 'base') { "її база перетинається з базою агента воркспейсу '$($el.Other)'" }
            elseif ($el.Kind -eq 'otherbase') { "база агента воркспейсу '$($el.Other)' лежить у '$($ws.Project.WorkPath)/infobases' цього воркспейсу" }
            elseif ($el.Kind -eq 'othermemory') { "її база лежить у '<workPath>/infobases' воркспейсу '$($el.Other)'" }
            else { "$($el.Label) перетинається з текою, яку kit прибирає" }
        }
        throw ("База агента воркспейсу '$($ws.Path)' перетинається із захищеним шляхом: " + ($what -join '; ') + '. ' +
               'kit не прибирає теку, у якій лежить чужа база. Виправлення: у v8project.local.yaml кожного воркспейсу задайте infobases.origin.connection окремою текою (типово build/ib).')
    }

    $plan = [pscustomobject]@{
        Ws = $ws; Skip = $false; Ab = $ab; WsTemplate = $wsTemplate; Fitness = $fitness; UnfitNote = $unfitNote
        AgentWork = $agentWork; MemoryDir = $memoryDir; Server = ($ab.Kind -eq 'server'); CrWarn = $null; Protected = $protected
        Kind = $null; Steps = @(); KitCreates = $false; CreatedBy = $null
    }

    if ($ab.Kind -eq 'server') {
        if (-not $ServerBase) {
            throw ("База агента воркспейсу '$($ws.Path)' серверна ($($ab.Connection)). Вкажіть -ServerBase New — Уніка створить її в " +
                   'кластері з infobases.origin.dbms, або -ServerBase Existing — базу дала людина, kit лише прибере пам''ять раннера й надрукує крок.')
        }
        if ($wsTemplate) { throw '-Template (.dt) для серверної бази агента не підтримується: розгортання .dt на сервері — поза обсягом. Приберіть -Template чи agentBase.template з накладки.' }
        if ($ServerBase -eq 'New') {
            $missingDbms = @('kind', 'server', 'name', 'locale' | Where-Object {
                $null -eq $ab.Dbms -or -not $ab.Dbms.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$ab.Dbms[$_]) })
            if ($missingDbms.Count -gt 0) {
                throw ("Для -ServerBase New у $($ab.Origin) під infobases.origin.dbms бракує: $($missingDbms -join ', '). " +
                       'Їх і реквізити адміністратора кластера питає в людини скіл v8storagekit:provision.')
            }
            $plan.CrWarn = ("  УВАГА: раннер створює базу з CrSQLDB=Y — він МОВЧКИ бере наявну базу даних СУБД з тим самим іменем ('{0}' на '{1}'). " +
                            "Ім'я бази даних підтверджує людина до кроку. Регламентні завдання в новій базі вимкнено (SchJobDn=Y). " +
                            'Адміністратор кластера — infobases.origin.cluster {{ user, password }} (SUsr/SPwd).') -f $ab.Dbms['name'], $ab.Dbms['server']
        }
        $plan.Kind = if ($ServerBase -eq 'New') { 'server-new' } else { 'server-existing' }
        $plan.Steps = Get-KitProvisionSteps -Kind $plan.Kind -Fitness $fitness -MainBranch $Context.MainBranch
        $plan.CreatedBy = if ($ServerBase -eq 'New') { 'unica' } else { 'existing' }
        return $plan
    }
    if ($ServerBase) { throw "-ServerBase стосується лише серверної бази агента, а в $($ab.Origin) — файлова ($($ab.Connection))." }

    Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "база агента воркспейсу $($ws.Path)"
    # П26 п. 2 (б): шлях бази не перетинається з <workPath>/infobases (пам'ять раннера, owner.mark, lock) —
    # тим самим предикатом перетину, що й аудит бази людини, а не другою копією. Описка в connection
    # (File=build/infobases) не має стирати теку, яка бази не містить.
    if (Test-KitPathsOverlap -Left $ab.Path -Right (Join-Path $agentWork 'infobases')) {
        throw ("Шлях бази агента воркспейсу '$($ws.Path)' перетинається з '$($ws.Project.WorkPath)/infobases' (пам'ять раннера, мітка власника, замок) — " +
               'kit цього не прибирає. Виправлення: у v8project.local.yaml задайте infobases.origin.connection окремою текою бази (типово build/ib).')
    }
    # П26 п. 2 (а): видаляється лише те, що є базою. Наявна непорожня тека без 1Cv8.1CD — не база агента,
    # навіть із -Force (File=build/artifacts не має стирати артефакти).
    if (-not $ab.Exists -and (Test-Path -LiteralPath $ab.Path -PathType Container) -and
            @(Get-ChildItem -LiteralPath $ab.Path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw ("Тека за шляхом бази агента воркспейсу '$($ws.Path)' наявна, непорожня й не містить 1Cv8.1CD — це не база агента, kit її не прибирає, навіть із -Force. " +
               'Виправлення: у v8project.local.yaml задайте infobases.origin.connection шляхом, де лежить база агента або де нічого немає (типово build/ib).')
    }
    if ($Apply) {
        if ($ab.Exists -and -not $Force) {
            throw "База агента вже є: $($ab.Path). Перестворити з нуля — kit provision -Workspace $($ws.Path) -Apply -Force."
        }
        if ($wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }
    }

    $plan.Kind = if ($wsTemplate) { 'file-dt' } else { 'file-empty' }
    $templateFull = if ($wsTemplate -and (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { (Resolve-Path -LiteralPath $wsTemplate).Path } else { $wsTemplate }
    $plan.Steps = Get-KitProvisionSteps -Kind $plan.Kind -Fitness $fitness -TemplatePath $templateFull -MainBranch $Context.MainBranch
    $plan.KitCreates = ($plan.Kind -eq 'file-empty' -and -not $fitness.Fit)
    $plan.CreatedBy = if ($plan.KitCreates) { 'kit' } else { 'unica' }
    $plan
}

function Invoke-KitProvision {
    <#
    .SYNOPSIS
        База агента (спека 2026-10-11 §4.2): kit вирішує, перевіряє, прибирає стару базу й пам'ять
        раннера; створює той, хто першим наповнює (§3 рішення 4).
    .DESCRIPTION
        Придатне дерево основної конфігурації — базу створює Уніка (infobase.create / infobase.restore),
        kit лише прибирає стару теку бази й <workPath>/infobases/origin і друкує кроки. Непридатне
        (truth: storage без дерева чи з поставкою missing/stale) — першим базу наповнює kit зі сховища,
        тож порожню файлову базу створює теж kit. Серверну базу kit не створює ніколи: -ServerBase New —
        створює Уніка, -ServerBase Existing — базу дала людина.

        Два проходи (П26 п. 4): перший — усі перевірки всіх воркспейсів без побічних ефектів; відмова
        будь-якого зупиняє команду до першого видалення, з переліком воркспейсів і причин. Між проходами
        з -Apply — маркер-фаза (Invoke-KitProtectedPathsMarkerPhase): псевдоніми шляху для всіх воркспейсів
        разом, теж до першого видалення. Другий — друк, видалення й створення. Інакше відмова другого воркспейсу лишала б напівстан: база першого
        вже знесена, нова не створена.
    .PARAMETER Template
        Файл .dt; без нього береться workspaces.<ws>.agentBase.template з накладки; без обох — порожня база.
    .PARAMETER Remember
        Записати -Template у v8storagekit.local.yaml (те, що робить скіл provision після питання).
    .PARAMETER ServerBase
        Лише для серверної бази агента: New — створює Уніка з infobases.origin.dbms; Existing — базу дала людина.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Force,
        [string]$Template,
        [switch]$Remember,
        [ValidateSet('New', 'Existing')][string]$ServerBase
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
    # воркспейсах (kit-dev, випадок 5: друга перевірка з іншою логікою гірша за жодну).
    if ($Source) {
        $matched = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        $wsOfSource = @($matched.Workspace | Sort-Object -Unique)
        $workspaces = @($workspaces | Where-Object { $wsOfSource -contains $_.Path })
    }
    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $Context.RepoRoot 'v8storagekit.local.yaml' }
    $done = [System.Collections.Generic.List[object]]::new()

    # Перший прохід: перевірки всіх воркспейсів, без побічних ефектів. Відмови збираються, не кидаються по одній.
    $plans = [System.Collections.Generic.List[object]]::new()
    $refusals = [System.Collections.Generic.List[string]]::new()
    foreach ($ws in $workspaces) {
        try {
            $plans.Add((Get-KitProvisionPlan -Context $Context -Workspace $ws -Template $Template -ServerBase $ServerBase -Apply $Apply -Force ([bool]$Force)))
        } catch {
            $refusals.Add(("  - {0}: {1}" -f $ws.Path, $_.Exception.Message))
        }
    }
    if ($refusals.Count -gt 0) {
        throw ("Перевірки перед змінами не пройдено — нічого не прибрано й не створено:`n" + ($refusals -join "`n"))
    }

    # Між проходами (П26 п. 6): маркер-фаза для ВСІХ воркспейсів разом. Лише з -Apply: без нього нічого не
    # видаляється, і прев'ю не має побічних ефектів. Відмова будь-якого воркспейсу — до першого видалення.
    if ($Apply) { Invoke-KitProtectedPathsMarkerPhase -Context $Context -Plans $plans.ToArray() }

    # Другий прохід: друк, видалення, створення.
    foreach ($plan in $plans) {
        $ws = $plan.Ws
        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        if ($plan.Skip) {
            Write-Host '  У воркспейсі лише зовнішні обробки — бази агента тут не буває.'
            continue
        }
        $ab = $plan.Ab
        $agentWork = $plan.AgentWork
        $memoryDir = $plan.MemoryDir
        $steps = $plan.Steps
        Write-Host "База:$($ab.Connection)  ($($ab.Origin))"
        if ($plan.UnfitNote) { Write-Host $plan.UnfitNote -ForegroundColor Cyan }

        if ($plan.Server) {
            if ($plan.CrWarn) { Write-Host $plan.CrWarn -ForegroundColor Yellow }
            if (-not $Apply) {
                Write-Host "  Це попередній перегляд. Для виконання додайте -Apply (kit прибере пам'ять раннера $memoryDir)." -ForegroundColor Cyan
                Write-KitNextSteps -Title 'Далі:' -Steps $steps
                continue
            }
            Assert-SafeWorkPath -Path $memoryDir -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "пам'ять раннера бази origin воркспейсу $($ws.Path)"
            Remove-KitDirectory -Path $memoryDir
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $null; Template = $null; CreatedBy = $plan.CreatedBy; Steps = $steps })
            continue
        }

        $wsTemplate = $plan.WsTemplate
        Write-Host ('Шлях:      ' + $ab.Path + $(if ($ab.Exists) { '  (існує)' } else { '  (ще немає)' }))
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        if (-not $Apply) {
            # '+' після виклику команди — окремий позиційний аргумент, не конкатенація (F2/P4): рядок збирається в змінну ДО виклику.
            $previewNote = '  Це попередній перегляд. Для виконання додайте -Apply' + $(if ($ab.Exists) { ' -Force (база існує й буде перестворена).' } else { '.' })
            Write-Host $previewNote -ForegroundColor Cyan
            if ($plan.KitCreates) { Write-Host '  З -Apply kit сам створить порожню файлову базу.' -ForegroundColor Cyan }
            elseif (-not $plan.Fitness.Fit) { Write-Host '  Першим базу наповнить kit; створює її Уніка (create/restore) — крок нижче.' -ForegroundColor Cyan }
            Write-KitNextSteps -Title 'Далі:' -Steps $steps
            # F6 (рев'ю B4 Task 1): -Remember без -Apply не мовчить — шаблон ще не записано.
            if ($Remember) { Write-Host '  Шаблон буде записано в накладку разом із -Apply (-Remember саме по собі нічого не пише).' -ForegroundColor DarkGray }
            continue
        }

        # Перевірки зроблено в першому проході; тут — повторний запобіжник безпосередньо перед видаленням.
        Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "база агента воркспейсу $($ws.Path)"
        Assert-SafeWorkPath -Path $memoryDir -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork -Description "пам'ять раннера бази origin воркспейсу $($ws.Path)"
        Remove-KitDirectory -Path $ab.Path
        Remove-KitDirectory -Path $memoryDir
        if ($plan.KitCreates) {
            Write-Host '  Створюю порожню базу (першим її наповнить kit зі сховища)...'
            $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $agentWork -RepoRoot $Context.RepoRoot -OwnedRoot $agentWork
            Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        } else {
            Write-Host "  Стару базу й пам'ять раннера прибрано; базу створює Уніка — крок нижче." -ForegroundColor Green
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
