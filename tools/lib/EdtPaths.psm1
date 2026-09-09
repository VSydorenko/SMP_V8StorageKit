#Requires -Version 7
Set-StrictMode -Version Latest

<#
Чисті функції відповідності EDT-шлях → Designer-шлях (B6 Task 3, §9.2).

Джерела таблиці — .superpowers/sdd/2026-09-03-B6-migrate/task-3-context.md:
- Designer-сторона: довідники Unica 0.12.3 (references/specs/1c-configuration-spec.md,
  1c-config-objects-spec.md §1.2 "Структура каталогу объекта метаданных",
  1c-extension-spec.md §7 "Модули в расширениях" — та сама таблиця Ext/-шляхів діє й
  для повної конфігурації, 1c-form-spec.md).
- EDT-сторона: в Unica її немає (format-index.md: "Это не EDT/MDO-формат") — береться з
  виміряних даних парку: park-edt-shapes.txt (283 форми шляхів) і park-edt-inventory.md
  (41 вид метаданих у восьми gitsync-репозиторіях).

Жодних звернень до git і жодних побічних ефектів — увесь модуль читає лише те, що йому
передали (Convert-KitEdtPath) чи що лежить на диску під SourceRoot (Get-KitEdtRenamePlan,
звичайний Get-ChildItem). Команда commands/rename-edt.psm1 відповідає за git mv, git rm і
коміт.
#>

# П'ять літеральних імен файлів модулів EDT — вони вже є Designer-іменами файлів під Ext/,
# лише без префіксу "Ext/" (park-edt-shapes.txt, розділ "Імена .bsl-файлів (EDT) за
# глибиною — це і є ключ відповідності модулів"). "Module.bsl" навмисно ВІДСУТНІЙ у цьому
# списку: та сама літеральна назва означає різні Designer-цілі залежно від виду
# (CommonForms → Ext/Form/Module.bsl, CommonModules/WebServices/HTTPServices → Ext/Module.bsl) —
# розбирається окремо, за видом.
$script:FixedRoleModuleFiles = @('ObjectModule.bsl', 'ManagerModule.bsl', 'RecordSetModule.bsl', 'ValueManagerModule.bsl', 'CommandModule.bsl')

# Службові файли gitsync/EDT, які НЕ є вихідниками метаданих — захисно перевіряються на
# будь-якій глибині сегмента 0 (навіть якщо викликач помилково передав -SourceRelPath, що
# включає сусідні службові теки поряд із src). ConfigDumpInfo.xml і DumpFilesIndex.txt
# трапляються буквально ВСЕРЕДИНІ src/ (виміряно, park-edt-shapes.txt: "1 ConfigDumpInfo.xml",
# "1 DumpFilesIndex.txt" без префіксу теки) — решта штатно лежить ПОРУЧ із src/, не під ним.
$script:UnmappedTopLevel = @{
    'DT-INF'             = "DT-INF/ — метадані сховища gitsync (не Designer-вихідник, не Unica-формат)."
    '.project'           = 'Службовий файл проєкту EDT — не об''єкт метаданих.'
    '.settings'          = 'Службова тека налаштувань EDT — не об''єкт метаданих.'
    'AUTHORS'            = 'Мапа авторів сховища gitsync — переноситься окремо кроком онбордингу, не в дерево вихідників.'
    'VERSION'            = 'Остання синхронізована версія сховища gitsync — переноситься окремо кроком онбордингу, не в дерево вихідників.'
    'ConfigDumpInfo.xml' = 'Службовий per-IB дамп-інфо файл платформи — не Git-вихідник (1c-configuration-spec.md §3).'
    'DumpFilesIndex.txt' = 'Службовий індекс вивантаження gitsync — не об''єкт метаданих.'
}

# 41 вид метаданих, виміряний у восьми gitsync-репозиторіях парку (park-edt-inventory.md),
# плюс три види з чеклиста Unica (format-index.md §2), яких у парку немає, але Designer-бік
# для них задокументований так само однозначно — Sequences, CalculationRegisters,
# IntegrationServices. Все, чого немає в цьому списку — Unmapped із поясненням "невідомий вид".
$script:KnownKinds = @(
    'AccountingRegisters', 'AccumulationRegisters', 'BusinessProcesses', 'Catalogs',
    'CalculationRegisters', 'ChartsOfAccounts', 'ChartsOfCalculationTypes', 'ChartsOfCharacteristicTypes',
    'CommandGroups', 'CommonAttributes', 'CommonCommands', 'CommonForms', 'CommonModules',
    'CommonPictures', 'CommonTemplates', 'Constants', 'DataProcessors', 'DefinedTypes',
    'DocumentJournals', 'DocumentNumerators', 'Documents', 'Enums', 'EventSubscriptions',
    'ExchangePlans', 'FilterCriteria', 'FunctionalOptions', 'FunctionalOptionsParameters',
    'HTTPServices', 'InformationRegisters', 'IntegrationServices', 'Reports', 'Roles',
    'ScheduledJobs', 'Sequences', 'SessionParameters', 'SettingsStorages', 'StyleItems',
    'Styles', 'Tasks', 'WebServices', 'WSReferences', 'XDTOPackages'
)

# Види, для яких depth-2 файл "Module.bsl" (Kind/Ім'я/Module.bsl) означає "Ext/Module.bsl" —
# на відміну від CommonForms, де та сама літеральна назва означає "Ext/Form/Module.bsl"
# (CommonForm — сама є формою, а не власником форми).
$script:PlainModuleKinds = @('CommonModules', 'WebServices', 'HTTPServices', 'IntegrationServices')

function Get-KitTailFrom {
    <#
    .SYNOPSIS
        Безпечний "хвіст" масиву сегментів від індексу $From (уключно) — порожній масив,
        якщо $From виходить за межі, замість винятку від рідного зрізу PowerShell
        $Segments[$From..($Segments.Count-1)] ("Index was outside the bounds of the array"),
        коли короткий, але цілком реальний EDT-шлях (стороннє сміття, обрізане дерево)
        закінчується раніше, ніж очікує конкретна гілка розбору.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Segments, [Parameter(Mandatory)][int]$From)
    if ($From -ge $Segments.Count) { return @() }
    @($Segments[$From..($Segments.Count - 1)])
}

function New-KitEdtMapped {
    param([Parameter(Mandatory)][string]$DesignerPath)
    [pscustomobject]@{ DesignerPath = $DesignerPath; Reason = $null }
}

function New-KitEdtUnmapped {
    param([Parameter(Mandatory)][string]$Reason)
    [pscustomobject]@{ DesignerPath = $null; Reason = $Reason }
}

function Convert-KitConfigurationTail {
    <# .SYNOPSIS Хвіст під "Configuration/" — корінний Ext/ конфігурації (§4 configuration-spec), не окремий об'єкт. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tail)

    if ($Tail.Count -eq 1) {
        $f = $Tail[0]
        if ($f -match '\.mdo$') { return New-KitEdtMapped -DesignerPath 'Configuration.xml' }
        if ($f -match '^(SessionModule|OrdinaryApplicationModule|ManagedApplicationModule|ExternalConnectionModule)\.bsl$') {
            return New-KitEdtMapped -DesignerPath "Ext/$f"
        }
        if ($f -eq 'CommandInterface.cmi') { return New-KitEdtMapped -DesignerPath 'Ext/CommandInterface.xml' }
        if ($f -eq 'MainSectionCommandInterface.cmi') { return New-KitEdtMapped -DesignerPath 'Ext/MainSectionCommandInterface.xml' }
        if ($f -match '\.hpwa$') { return New-KitEdtMapped -DesignerPath 'Ext/HomePageWorkArea.xml' }
        if ($f -match '\.cai$') { return New-KitEdtMapped -DesignerPath 'Ext/ClientApplicationInterface.xml' }
        return New-KitEdtUnmapped -Reason "невідомий корінний файл конфігурації 'Configuration/$f' — конвенція Designer для цього розширення не підтверджена жодним джерелом (park-edt-shapes.txt, довідники Unica); звірте вручну."
    }
    if ($Tail.Count -ge 2 -and $Tail[0] -eq 'Help') {
        return New-KitEdtMapped -DesignerPath ('Ext/' + ($Tail -join '/'))
    }
    return New-KitEdtUnmapped -Reason "неочікувана структура під 'Configuration/': '$($Tail -join '/')' — немає в жодному виміряному чи задокументованому шаблоні."
}

function Convert-KitSubsystemsTail {
    <# .SYNOPSIS Subsystems вкладаються самі в себе — рекурсія по вкладеності (park-edt-shapes.txt: глибина 3/5/7/9). #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tail)

    if ($Tail.Count -eq 0) { return New-KitEdtUnmapped -Reason "порожній хвіст під 'Subsystems/' — сама тека виду, не файл." }
    # Count -eq 1 навмисно окремо, ДО решти перевірок: усе нижче безпечно читає $Tail[1] лише
    # тому, що після цієї гілки Count гарантовано >= 2 (рідний зріз PowerShell $arr[1..($n-1)]
    # на однoелементному масиві кидає "Index was outside the bounds of the array", а не $null).
    if ($Tail.Count -eq 1) { return New-KitEdtUnmapped -Reason "файл 'Subsystems/$($Tail[0])' лежить прямо під видом, без теки підсистеми — не відповідає жодному відомому шаблону." }
    $name = $Tail[0]
    if ($Tail.Count -eq 2 -and $Tail[1] -eq "$name.mdo") { return New-KitEdtMapped -DesignerPath "Subsystems/$name.xml" }
    if ($Tail.Count -eq 2 -and $Tail[1] -eq 'CommandInterface.cmi') { return New-KitEdtMapped -DesignerPath "Subsystems/$name/Ext/CommandInterface.xml" }
    if ($Tail[1] -eq 'Help') {
        return New-KitEdtMapped -DesignerPath ("Subsystems/$name/Ext/" + ((Get-KitTailFrom -Segments $Tail -From 1) -join '/'))
    }
    if ($Tail[1] -eq 'Subsystems') {
        # Tail[1] — сам літеральний маркер вкладеності "Subsystems", не ім'я дочірньої
        # підсистеми: дочірній хвіст починається з Tail[2] (її ім'я). Рекурсія в
        # Convert-KitSubsystemsTail очікує саме такий хвіст (Tail[0] = ім'я) і сама
        # коректно повертає Unmapped, якщо дочірнього хвоста по факту немає (Get-KitTailFrom
        # дає порожній масив, а не виняток, коли Tail.Count -eq 2 — "Subsystems/A/Subsystems").
        # @(...) обов'язковий (F7 цього репозиторію): Get-KitTailFrom, повернувши масив з
        # РІВНО одним елементом чи порожній, "розгортається" на конвеєрі — без @(...) $childTail
        # став би $null (0 елементів) чи голим рядком (1 елемент), а Mandatory [string[]]$Tail
        # нижче кидає "argument is null" замість штатного порожнього/однoелементного хвоста.
        $childTail = @(Get-KitTailFrom -Segments $Tail -From 2)
        $child = Convert-KitSubsystemsTail -Tail $childTail
        if ($null -eq $child.DesignerPath) { return $child }
        return New-KitEdtMapped -DesignerPath "Subsystems/$name/$($child.DesignerPath)"
    }
    return New-KitEdtUnmapped -Reason "неочікувана структура під 'Subsystems/$name/': '$((Get-KitTailFrom -Segments $Tail -From 1) -join '/')'."
}

function Convert-KitFormTail {
    <# .SYNOPSIS Хвіст УСЕРЕДИНІ "Forms/<Ім'я>/…" одного об'єкта-власника (не CommonForms — той сам є формою). #>
    param([Parameter(Mandatory)][string]$KindObjectPrefix, [Parameter(Mandatory)][string]$FormName, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rest)

    if ($Rest.Count -eq 1 -and $Rest[0] -eq 'Form.form') { return New-KitEdtMapped -DesignerPath "$KindObjectPrefix/Forms/$FormName/Ext/Form.xml" }
    if ($Rest.Count -eq 1 -and $Rest[0] -eq 'Module.bsl') { return New-KitEdtMapped -DesignerPath "$KindObjectPrefix/Forms/$FormName/Ext/Form/Module.bsl" }
    if ($Rest.Count -ge 1 -and $Rest[0] -eq 'Help') { return New-KitEdtMapped -DesignerPath ("$KindObjectPrefix/Forms/$FormName/Ext/" + ($Rest -join '/')) }
    if ($Rest.Count -ge 1 -and $Rest[0] -eq 'Attributes') {
        return New-KitEdtUnmapped -Reason "розширене умовне оформлення/графік форми ('$($Rest -join '/')') вбудовується у Ext/Form.xml форми — окремого Designer-файлу немає."
    }
    return New-KitEdtUnmapped -Reason "файл усередині форми поза відомою розкладкою ('$($Rest -join '/')') — найімовірніше вбудовується у Ext/Form.xml, окремого Designer-відповідника не підтверджено."
}

function Convert-KitTemplateTail {
    <# .SYNOPSIS Хвіст усередині "Templates/<Ім'я>/…" одного об'єкта-власника. #>
    param([Parameter(Mandatory)][string]$KindObjectPrefix, [Parameter(Mandatory)][string]$TemplateName, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rest)

    if ($Rest.Count -eq 1 -and $Rest[0] -match '^Template\.[^/]+$') { return New-KitEdtMapped -DesignerPath "$KindObjectPrefix/Templates/$TemplateName/Ext/Template.xml" }
    if ($Rest.Count -ge 1 -and $Rest[0] -eq 'Help') { return New-KitEdtMapped -DesignerPath ("$KindObjectPrefix/Templates/$TemplateName/Ext/" + ($Rest -join '/')) }
    return New-KitEdtUnmapped -Reason "вкладений ресурс макета ('$($Rest -join '/')') — публікується разом із Ext/Template.xml, точного окремого шляху не підтверджено (HTMLDocument-сторінки, файли AddIn тощо)."
}

function Convert-KitCommandTail {
    <# .SYNOPSIS Хвіст усередині "Commands/<Ім'я>/…" одного об'єкта-власника. #>
    param([Parameter(Mandatory)][string]$KindObjectPrefix, [Parameter(Mandatory)][string]$CommandName, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rest)

    if ($Rest.Count -eq 1 -and $Rest[0] -eq 'CommandModule.bsl') { return New-KitEdtMapped -DesignerPath "$KindObjectPrefix/Commands/$CommandName/Ext/CommandModule.bsl" }
    return New-KitEdtUnmapped -Reason "файл усередині команди поза відомою розкладкою ('$($Rest -join '/')')."
}

function Convert-KitObjectTail {
    <#
    .SYNOPSIS
        Універсальний хвіст об'єкта одного виду метаданих: "<Вид>/<Ім'я>/…" (1c-config-objects-spec.md
        §1.2 — дескриптор, Ext/-модулі, Forms/, Templates/, Commands/, Help/ — застосовується
        однаково для всіх 41 виду; видо-специфічні розширення (CommonPictures, CommonTemplates,
        CommonForms, XDTOPackages, Roles, Styles, WSReferences) розбираються тут-таки за назвою виду.
    #>
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tail)

    if ($Tail.Count -eq 0) { return New-KitEdtUnmapped -Reason "порожній хвіст під '$Kind/' — сама тека виду, не файл." }
    # Count -eq 1 навмисно окремо, ДО решти перевірок — з цієї миті Count гарантовано >= 2, і
    # $Tail[1] нижче завжди безпечний (рідний зріз PowerShell на однoелементному масиві кидає
    # виняток, а не повертає $null — та сама причина, що й у Convert-KitSubsystemsTail).
    if ($Tail.Count -eq 1) { return New-KitEdtUnmapped -Reason "файл '$Kind/$($Tail[0])' лежить прямо під видом, без теки об'єкта — не відповідає жодному відомому шаблону." }
    $name = $Tail[0]
    $prefix = "$Kind/$name"

    # 1) Власний дескриптор об'єкта — однаково для КОЖНОГО виду (Каталог: X/. Файлы: <Имя>.xml).
    if ($Tail.Count -eq 2 -and $Tail[1] -eq "$name.mdo") { return New-KitEdtMapped -DesignerPath "$Kind/$name.xml" }

    # 2) Видо-специфічні розширення однофайлового вмісту (перевіряються ДО генеричних правил,
    #    бо міняють і назву, і розширення файла — не просто додають "Ext/").
    if ($Tail.Count -eq 2) {
        switch ($Kind) {
            'CommonPictures' { if ($Tail[1] -ne "$name.mdo") { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Picture/$($Tail[1])" } }
            'CommonTemplates' { if ($Tail[1] -ne "$name.mdo") { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Template.xml" } }
            'CommonForms' {
                if ($Tail[1] -eq 'Form.form') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Form.xml" }
                if ($Tail[1] -eq 'Module.bsl') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Form/Module.bsl" }
            }
            'XDTOPackages' { if ($Tail[1] -match '\.xdto$') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Package.bin" } }
            'Roles' { if ($Tail[1] -eq 'Rights.rights') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Rights.xml" } }
            'Styles' { if ($Tail[1] -eq 'Style.style') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Style.xml" } }
            'BusinessProcesses' { if ($Tail[1] -eq 'Flowchart.scheme') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Flowchart.xml" } }
            'WSReferences' {
                if ($Tail[1] -match '\.wsdl$') { return New-KitEdtMapped -DesignerPath "$prefix/Ext/WSDefinition.wsdl" }
                if ($Tail[1] -ne "$name.mdo") { return New-KitEdtUnmapped -Reason "нестандартний файл WS-посилання ('$($Tail[1])') — конвенція Designer для цього розширення (напр. вкладена XSD-схема) не підтверджена жодним джерелом." }
            }
            'ScheduledJobs' { if ($Tail[1] -eq 'Schedule.schedule') { return New-KitEdtUnmapped -Reason "розклад регламентного завдання вбудовується у властивість <Schedule> дескриптора '$name.xml' (1c-config-objects-spec.md §22) — окремого Designer-файлу немає." } }
        }
    }

    # 3) П'ять фіксованих імен модулів об'єкта — Kind/Ім'я/<Файл>.bsl → Kind/Ім'я/Ext/<Файл>.bsl.
    if ($Tail.Count -eq 2 -and $script:FixedRoleModuleFiles -contains $Tail[1]) {
        return New-KitEdtMapped -DesignerPath "$prefix/Ext/$($Tail[1])"
    }
    # 3а) "Module.bsl" — фіксоване ім'я, але Designer-ціль залежить від виду (CommonForms
    #     розібраний вище окремо; тут — лише прості випадки "Ext/Module.bsl").
    if ($Tail.Count -eq 2 -and $Tail[1] -eq 'Module.bsl') {
        if ($script:PlainModuleKinds -contains $Kind) { return New-KitEdtMapped -DesignerPath "$prefix/Ext/Module.bsl" }
        return New-KitEdtUnmapped -Reason "'Module.bsl' для виду '$Kind' не відповідає жодному відомому шаблону модуля."
    }

    # 4) Вкладені контейнери об'єкта. Get-KitTailFrom, не рідний зріз "$Tail[3..(Count-1)]" —
    #    при Count -eq 3 (наприклад стороння Kind/Ім'я/Forms/Файл без теки форми) такий зріз
    #    кидає "Index was outside the bounds of the array"; Get-KitTailFrom дає порожній Rest,
    #    і Convert-KitFormTail/TemplateTail/CommandTail самі коректно повертають Unmapped на ньому.
    #    @(...) обов'язковий (F7) — інакше порожній чи однoелементний Rest розгортається на
    #    конвеєрі, і Mandatory [string[]]$Rest далі кидає "argument is null".
    if ($Tail[1] -eq 'Forms' -and $Tail.Count -ge 3) {
        return Convert-KitFormTail -KindObjectPrefix $prefix -FormName $Tail[2] -Rest @(Get-KitTailFrom -Segments $Tail -From 3)
    }
    if ($Tail[1] -eq 'Templates' -and $Tail.Count -ge 3) {
        return Convert-KitTemplateTail -KindObjectPrefix $prefix -TemplateName $Tail[2] -Rest @(Get-KitTailFrom -Segments $Tail -From 3)
    }
    if ($Tail[1] -eq 'Commands' -and $Tail.Count -ge 3) {
        return Convert-KitCommandTail -KindObjectPrefix $prefix -CommandName $Tail[2] -Rest @(Get-KitTailFrom -Segments $Tail -From 3)
    }
    if ($Tail[1] -eq 'Help') {
        return New-KitEdtMapped -DesignerPath ("$prefix/Ext/" + ((Get-KitTailFrom -Segments $Tail -From 1) -join '/'))
    }

    return New-KitEdtUnmapped -Reason "неочікувана структура об'єкта '$prefix/': '$((Get-KitTailFrom -Segments $Tail -From 1) -join '/')' — немає в жодному виміряному чи задокументованому шаблоні."
}

function Convert-KitEdtPath {
    <#
    .SYNOPSIS
        EDT-шлях (відносно кореня EDT-дерева, "/"- чи "\"-роздільник) → Designer-шлях
        (відносно того самого кореня) або $null із поясненням (Reason).
    .DESCRIPTION
        Чиста функція — жодного диска, жодного git. Хвіст мапиться лише за структурою
        сегментів шляху; кириличні імена проходять як звичайні рядки .NET, без
        перекодування чи припущень про ASCII (Set-StrictMode + .NET string — байти не
        чіпаються).
    .EXAMPLE
        Convert-KitEdtPath -RelativePath 'Catalogs/Контрагенты/Контрагенты.mdo'
        # DesignerPath = 'Catalogs/Контрагенты.xml'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)

    $norm = ($RelativePath -replace '\\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($norm)) { return New-KitEdtUnmapped -Reason 'порожній шлях.' }
    $segments = @($norm -split '/')

    if ($script:UnmappedTopLevel.ContainsKey($segments[0])) {
        return New-KitEdtUnmapped -Reason $script:UnmappedTopLevel[$segments[0]]
    }

    $kind = $segments[0]
    # Get-KitTailFrom, не рідний зріз — коли $RelativePath це один-єдиний сегмент (стороннiй
    # файл прямо в корені EDT-дерева, що не потрапив у $script:UnmappedTopLevel), Count -eq 1,
    # і "$segments[1..0]" кинув би "Index was outside the bounds of the array" замість
    # порожнього хвоста, який Convert-Kit*Tail нижче й так коректно трактує як Unmapped.
    $tail = @(Get-KitTailFrom -Segments $segments -From 1)

    if ($kind -eq 'Configuration') { return Convert-KitConfigurationTail -Tail $tail }
    if ($kind -eq 'Subsystems') { return Convert-KitSubsystemsTail -Tail $tail }

    if ($script:KnownKinds -notcontains $kind) {
        return New-KitEdtUnmapped -Reason "невідомий вид метаданих '$kind' — немає ні в чеклисті format-index.md, ні у виміряному парку (park-edt-shapes.txt, park-edt-inventory.md)."
    }
    Convert-KitObjectTail -Kind $kind -Tail $tail
}

function Get-KitEdtRenamePlan {
    <#
    .SYNOPSIS
        Обхід EDT-дерева -SourceRelPath і план перейменування в -TargetRoot (§9.2 Task 3).
    .DESCRIPTION
        Читає лише диск (Get-ChildItem під RepoRoot/SourceRelPath) — жодного git. Кожен
        файл мапиться Convert-KitEdtPath за хвостом після кореня EDT-дерева; результат —
        три списки: Moves (однозначна ціль), Unmapped (без відповідника, з Reason),
        Collisions (кілька джерел на одну й ту саму ціль — з Moves ці джерела виключені,
        колізія показується окремо, щоб повторний прогін після ручного виправлення
        одразу відбив реальність).
    .EXAMPLE
        Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'cf/src' -TargetRoot 'Продукт/cf/src'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SourceRelPath,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $sourceFull = Join-Path $RepoRoot $SourceRelPath
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "EDT-дерево '$SourceRelPath' не знайдено під $RepoRoot."
    }
    $fullRoot = (Resolve-Path -LiteralPath $sourceFull).Path.TrimEnd('\', '/')
    $sourcePrefix = ($SourceRelPath -replace '\\', '/').Trim('/')
    $targetPrefix = ($TargetRoot -replace '\\', '/').Trim('/')

    $files = @(Get-ChildItem -LiteralPath $fullRoot -Recurse -File |
        ForEach-Object { $_.FullName.Substring($fullRoot.Length).TrimStart('\', '/') -replace '\\', '/' } |
        Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture))

    $moveCandidates = [System.Collections.Generic.List[object]]::new()
    $unmapped = [System.Collections.Generic.List[object]]::new()

    foreach ($tail in $files) {
        $result = Convert-KitEdtPath -RelativePath $tail
        $srcRel = "$sourcePrefix/$tail"
        if ($null -eq $result.DesignerPath) {
            $unmapped.Add([pscustomobject]@{ SourceRelPath = $srcRel; Reason = $result.Reason })
            continue
        }
        $targetRel = "$targetPrefix/$($result.DesignerPath)"
        $moveCandidates.Add([pscustomobject]@{ SourceRelPath = $srcRel; DesignerRelPath = $result.DesignerPath; TargetRelPath = $targetRel })
    }

    $byTarget = $moveCandidates | Group-Object TargetRelPath
    $collisions = [System.Collections.Generic.List[object]]::new()
    $moves = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $byTarget) {
        if ($group.Count -gt 1) {
            $collisions.Add([pscustomobject]@{
                TargetRelPath = $group.Name
                SourceRelPaths = @($group.Group | ForEach-Object SourceRelPath | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
            })
        } else {
            $moves.Add($group.Group[0])
        }
    }

    [pscustomobject]@{
        Moves      = @($moves | Sort-Object -Property SourceRelPath -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        Unmapped   = @($unmapped | Sort-Object -Property SourceRelPath -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        Collisions = @($collisions | Sort-Object -Property TargetRelPath -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
    }
}

Export-ModuleMember -Function Convert-KitEdtPath, Get-KitEdtRenamePlan
