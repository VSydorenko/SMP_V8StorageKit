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
        агента означає «порожня ІБ, наповнена operation=build з джерел», а build вантажить
        власника з CONFIGURATION source-set (типово cf/src) і лише потім розширення. За
        truth: vendor це дерево гітігнороване (templates/gitignore) і на щойно клонованій
        машині порожнє — «порожня» тоді веде build у мовчазний глухий кут.

        Перевірка безумовна: НЕ залежить від того, чи розширення позичає об'єкти
        (ObjectBelonging>Adopted, Get-KitAdoptedObjectCount нижче) — збірка .cfe й
        operation=build без власника не проходять і для розширення без жодного
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

    $configSources = @($Workspace.Sources | Where-Object Type -eq 'CONFIGURATION')
    if ($configSources.Count -eq 0) { return $true }
    foreach ($src in $configSources) {
        if (@(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) { return $false }
    }
    $true
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
        .dt, серверна база від людини; sync — лише коли CONFIGURATION джерело під truth:
        storage (для vendor/dump sync нічого не дає — там немає сховища конфігурацій).
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
        "Розширення цього воркспейсу не позичає жодного об'єкта, але це не рятує: заглушка (tools/assets/empty-extension) не тримає типи власника (наприклад, УНФ), і operation=build без нього так само не проходить."
    }
    $syncHint = if (@($Workspace.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' }).Count -gt 0) {
        ' або kit sync -RepoRoot . — якщо конфігурація власника під сховищем (truth: storage).'
    } else {
        '.'
    }

    "Воркспейсу '$($Workspace.Path)' бракує власника: $configLabel на диску порожнє або відсутнє. $why " +
    "«Порожня» база агента наповнюється operation=build Уніки, а build спершу вантажить власника з цього дерева — без нього збірка впаде на першому ж об'єкті. " +
    'Звідки взяти власника: дамп із дев-бази — kit dump -RepoRoot . -Apply (20–40 хв, 1–2 ГБ, за накладкою infobases:); ' +
    "файл .dt із конфігурацією власника — kit provision -RepoRoot . -Workspace $($Workspace.Path) -Apply -Template <шлях>.dt -Remember; " +
    "серверна база, яку створює людина в кластері$syncHint " +
    'Kit не пропонує порожню базу без власника — виберіть варіант і повторіть запуск.'
}

function Invoke-KitProvision {
    <#
    .SYNOPSIS
        База агента (спека §4): порожня файлова або з .dt (CREATEINFOBASE /UseTemplate). Її можна
        знести й розгорнути знову будь-коли (-Force). Далі — operation=build Уніки.
    .PARAMETER Template
        Файл .dt; без нього береться workspaces.<ws>.agentBase.template з накладки; без обох — порожня база.
    .PARAMETER Remember
        Записати -Template у v8storagekit.local.yaml (те, що робить скіл provision після питання).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Force,
        [string]$Template,
        [switch]$Remember
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

    foreach ($ws in $workspaces) {
        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { Write-Host "- $($ws.Path): у v8project.yaml немає infobase: — бази агента тут не буває (зовнішні обробки)."; continue }

        # Правка виконавця (задокументована в брифі задачі): $template — ОКРЕМА локальна
        # змінна від параметра -Template, а не той самий $Template з іншим регістром.
        # PowerShell імена змінних реєстронечутливі: $template = $Template було б однією
        # й тією самою змінною, і шаблон, узятий із накладки для воркспейсу 1, перезаписав
        # би параметр -Template і протік у воркспейс 2 цього самого циклу.
        $wsTemplate = $Template
        if (-not $wsTemplate -and $Context.Overlay -and $Context.Overlay.Workspaces.ContainsKey($ws.Path)) {
            $wsTemplate = $Context.Overlay.Workspaces[$ws.Path].AgentBaseTemplate
        }

        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        Write-Host "База:      $($ab.Connection)  ($($ab.Origin))"
        if ($ab.Kind -eq 'server') {
            throw ("База агента воркспейсу '$($ws.Path)' серверна (Srvr=). Kit її не створює: серверну базу створює людина в кластері, а розгортання " +
                   'з .dt на сервері — окремий спайк (спека §13). Далі — operation=init/build Уніки.')
        }

        # Задача 12 (рішення користувача 2026-09-10): вісь «звідки власник» перевіряється
        # ДО вибору типу бази — і безумовно, до будь-якого запуску платформи (Assert-SafeWorkPath
        # нижче теж не звертається до платформи, але сенс той самий: спершу власник). $wsTemplate
        # відсутній означає саме "порожня" — це якраз шлях, який веде build у глухий кут, коли
        # CONFIGURATION source-set порожній. Шаблон (.dt) чи серверна база несуть власника
        # інакше, тож перевірка їх не стосується.
        if (-not $wsTemplate -and -not (Test-KitConfigurationOwnerPresent -Workspace $ws)) {
            throw (New-KitOwnerMissingMessage -Workspace $ws)
        }

        # F7 (рев'ю B4 Task 1) — межа видалення/створення: РОБОЧА тека воркспейсу
        # (workPath, §2.5/§4), НЕ вся тека воркспейсу. Другий, незалежний від аудиту
        # принципу 3 (Resolve-KitAgentBase) запобіжник: аудит ловить базу людини під
        # чужим ім'ям, ця межа ловить БУДЬ-ЯКУ теку поза робочою — навіть якщо аудит
        # помилився (наприклад, описку infobase.connection: 'File=cfe/src' — законну
        # підтеку воркспейсу, яку аудит не ловить, бо це не база жодної людини з
        # накладки). Без неї межа -MustBeUnder $ws.FullPath пропускає будь-яку підтеку
        # воркспейсу, і New-V8FileInfobase стирає вихідники розширення
        # (Remove-Item -Recurse -Force, V8.psm1) чи всю робочу теку з артефактами.
        #
        # Той самий Assert-SafeWorkPath, застосований до самої межі — не власна
        # перевірка "рівність/поза межею" третьою копією: Assert-SafeWorkPath уже
        # відхиляє рівність із межею (це і закриває край workPath: '.' — Read-V8Project
        # не пускає порожній workPath, але не боронить '.'), сегмент ".." і роботу на
        # ненормалізованому шляху. $ws.Project.WorkPath, не літерал 'build': workPath
        # конфігурований у v8project.yaml (типове значення 'build', Read-V8Project), і
        # решта kit його шанує (Task 3 будує build/artifacts саме від WorkPath) —
        # жорсткий 'build' відкидав би законну базу агента в репозиторії з workPath: 'out'.
        $agentWork = Join-Path $ws.FullPath $ws.Project.WorkPath
        Assert-SafeWorkPath -Path $agentWork -MustBeUnder $ws.FullPath -Description "робоча тека воркспейсу $($ws.Path) (workPath у v8project.yaml)"
        Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $agentWork -Description "база агента воркспейсу $($ws.Path)"

        Write-Host ('Шлях:      ' + $ab.Path + $(if ($ab.Exists) { '  (існує)' } else { '  (ще немає)' }))
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        if (-not $Apply) {
            # Правка виконавця (задокументована в брифі задачі): у PowerShell '+' після
            # виклику команди — окремий позиційний аргумент, не конкатенація рядків
            # (Write-Host не має параметра з таким позиційним іменем поруч, а '+' і
            # $(if...) надрукувались би літерально). Рядок збирається в змінну ДО виклику.
            $previewNote = '  Це попередній перегляд. Для виконання додайте -Apply' + $(if ($ab.Exists) { ' -Force (база існує й буде перестворена).' } else { '.' })
            Write-Host $previewNote -ForegroundColor Cyan
            # F6 (рев'ю B4 Task 1) — раніше -Remember без -Apply мовчав: continue стояв
            # до блоку -Remember, шаблон не запам'ятовувався, і про це ніде не було сказано.
            if ($Remember) {
                Write-Host '  Шаблон буде записано в накладку разом із -Apply (-Remember саме по собі нічого не пише).' -ForegroundColor DarkGray
            }
            continue
        }
        if ($ab.Exists -and -not $Force) {
            throw "База агента вже є: $($ab.Path). Перестворити з нуля — kit provision -Workspace $($ws.Path) -Apply -Force."
        }
        if ($wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }

        # Межу вже перевірено вище (Assert-SafeWorkPath, безумовно, до -Apply) — тут
        # $ab.Path не змінювався, повторна перевірка була б третьою копією тієї самої
        # логіки. New-V8FileInfobase все одно робить власну (V8.psm1) як останній
        # запобіжник безпосередньо перед Remove-Item.
        Write-Host '  Створюю базу...'
        $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $agentWork -TemplatePath $wsTemplate
        Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        Write-Host '  Далі: operation=build Уніки наповнює базу з джерел воркспейсу.' -ForegroundColor DarkGray

        if ($Remember) {
            Save-KitOverlayAgentBase -OverlayPath $overlayPath -WorkspacePath $ws.Path -Template $wsTemplate
            Write-Host "  Шаблон записано в $overlayPath (workspaces.$($ws.Path).agentBase.template)." -ForegroundColor DarkGray
        }
        $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $ab.Path; Template = $wsTemplate })
    }
    [pscustomobject]@{ ExitCode = 0; Provisioned = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitProvision
