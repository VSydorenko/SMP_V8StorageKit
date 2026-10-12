#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — той самий принцип, що й у решти вкладених імпортів lib-модулів
# (StorageReport.psm1, V8Project.psm1): не перезавантажувати вже наявний глобальний
# V8Project. AgentBase бере звідти Resolve-V8AgentInfobase і Resolve-KitAgentInfobasePath.
Import-Module "$PSScriptRoot/V8Project.psm1"
# Так само без -Force (та сама конвенція, що в StoragePlatform.psm1): AgentBase напряму
# кличе ConvertFrom-V8Connection (Get-KitInfobaseCanonicalForm, issue #9) — V8Project.psm1
# уже вкладено імпортує V8.psm1, але явний імпорт тут потрібен для тестів, які вантажать
# цей модуль окремо від диспетчера.
Import-Module "$PSScriptRoot/V8.psm1"

function Get-KitInfobaseCanonicalForm {
    <#
    .SYNOPSIS
        Приватний розбір одного підключення на канонічну форму — не експортується.
    .DESCRIPTION
        Допоміжна функція для Test-KitSameInfobase: розбирає File= чи Srvr=;Ref= на
        {Parsed; Kind; Identity; Reason}. Сирий розбір — ConvertFrom-V8Connection
        (V8.psm1, issue #9): непарна лапка, голий шлях, Srvr= без Ref=, невідомий
        ключ і решта — виняток ConvertFrom-V8Connection, тут лише перехоплений і
        перетворений на Parsed=$false з текстом винятку в Reason.

        Сама по собі fail-closed НЕ реалізує (не кидає) — це робить Test-KitSameInfobase,
        маючи обидва боки одразу (щоб назвати обидва підключення в одному повідомленні).
        Відносний File= тут ЗАВЖДИ Parsed=$false: ця функція не знає бази відліку (тека
        воркспейсу для бази агента, спека §2.5) — той, хто кличе Test-KitSameInfobase,
        мусить сам розв'язати відносний File= бази агента до абсолютного шляху ДО звірки
        (Resolve-KitAgentBase так і робить).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Connection)

    $parsed = $null
    try {
        $parsed = ConvertFrom-V8Connection -Connection $Connection
    } catch {
        return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = $_.Exception.Message; Exception = $_.Exception }
    }

    if ($parsed.Kind -eq 'server') {
        $identity = 'server:' + $parsed.Server.ToLowerInvariant() + '/' + $parsed.Ref.ToLowerInvariant()
        return [pscustomobject]@{ Parsed = $true; Kind = 'server'; Identity = $identity; Reason = ''; Exception = $null }
    }

    $raw = $parsed.File
    if (-not [System.IO.Path]::IsPathRooted($raw)) {
        return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = 'відносний File= — kit звіряє лише абсолютні File=.'; Exception = $null }
    }
    $full = [System.IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
    [pscustomobject]@{ Parsed = $true; Kind = 'file'; Identity = ('file:' + $full.ToLowerInvariant()); Reason = ''; Exception = $null }
}

function Test-KitSameInfobase {
    <#
    .SYNOPSIS
        Чи описують два підключення ТУ САМУ базу — а не той самий текст (принцип 3).
    .DESCRIPTION
        Текстова нормалізація (пробіли/регістр) не досить: 'File=D:\Bases\SMP_UNF\'
        і 'File=D:\Bases\SMP_UNF' — та сама тека, текстово різні рядки; 'Srvr=VSDEV;Ref=SMP_UNF;'
        і 'Ref=SMP_UNF;Srvr=VSDEV;' — та сама база, різний порядок ключів. Ця функція
        порівнює РОЗІБРАНІ поля: для файлової — абсолютний шлях (GetFullPath), без кінцевого
        роздільника, без урахування регістру (файлова система Windows регістронезалежна); для
        серверної — сервер і Ref, кожен окремо знайдений незалежно від порядку в рядку, без
        урахування регістру.

        Парні лапки навколо значення (Srvr="VSDEV";Ref="SMP_UNF";) ConvertFrom-V8Connection
        (V8.psm1) знімає ще до цього порівняння — тож це та сама база, що й
        Srvr=VSDEV;Ref=SMP_UNF; (без цього аудит «база агента ≠ база людини» порахував би
        їх двома базами). Непарна лапка — виняток, і fail-closed діє на неї, як на будь-який
        інший нерозбірний ввід.

        Fail-closed навмисно: коли ХОЧ ОДНЕ підключення не розбирається однозначно, функція
        КИДАЄ виняток, а НЕ повертає $false. Текст винятку називає нерозбірну сторону ЗА ПОХОДЖЕННЯМ (-LeftOrigin/-RightOrigin: воркспейс і infobases.origin, або дев-база в накладці), а не дослівним рядком — у рядку підключення може бути пароль, а сирий рядок, який ще не розібрано успішно, не друкується.
        "Не розібрали" -> "не збігається" (типова "безпечна" відповідь на помилку) тут була б
        насправді мовчазним ДОЗВОЛОМ: викликач (Resolve-KitAgentBase) далі веде до
        kit provision -Apply -Force, а це Remove-KitDirectory над текою підключення.
        Різні Kind ('file' проти 'server') повертають $false безпечно — це ВІДОМА різниця
        (ми ЗНАЄМО, що бази різні); нерозбірне підключення — це НЕВІДОМІСТЬ, і мовчазний дозвіл
        тут коштує дев-базу людини, тоді як зайва зупинка коштує одного уточнення підключення в
        накладці v8storagekit.local.yaml.

        Відносний File= ЗАВЖДИ кидає — ця функція не знає жодної бази відліку. Підключення
        бази агента (яке законно буває відносним, від теки воркспейсу, §2.5) МАЄ прийти сюди
        вже розв'язаним у абсолютний шлях — це робить викликач (Resolve-KitAgentInfobasePath),
        ДО виклику цієї функції; підключення дев-бази з infobases: накладки kit подається як є
        — дев-база лежить поза репозиторієм за визначенням, тож відносний File= там майже
        напевно описка, а не легальний випадок, і резолвити його від кореня репозиторію
        заборонено окремо: це дало б два різних початки відліку для відносного File= в одному
        файлі накладки (тека воркспейсу — для бази агента, корінь репо — для дев-бази), і це
        пастка, яку ніхто не запам'ятає.

        Межа, яку ця функція свідомо НЕ лікує (задокументовано, не недогляд): коротке ім'я
        сервера проти повного (FQDN) — 'VSDEV' проти 'vsdev.corp.local' — і явний порт
        ('VSDEV:1541') порівнюються ЛІТЕРАЛЬНО, без DNS-резолву чи нормалізації порту. Різні
        написання того самого сервера дадуть $false там, де це насправді той самий сервер —
        ціна прийнятна, бо цей бік помилки (хибний "не збігається") не веде до видалення чужої
        бази, на відміну від протилежного.
    .PARAMETER Left
        Перше підключення (сирий рядок File=... або Srvr=...;Ref=...;).
    .PARAMETER Right
        Друге підключення, тієї самої форми.
    .PARAMETER LeftOrigin
        Де лежить перше підключення — для тексту винятку (воркспейс і ключ конфігу). Без значення рядка.
    .PARAMETER RightOrigin
        Те саме для другого підключення.
    .PARAMETER LeftCredentialsKind
        Чий це рядок, для рецепта на Usr/Pwd (Get-V8CredentialsRecipe): 'agent' — база агента, 'overlay' — дев-база накладки.
    .PARAMETER RightCredentialsKind
        Те саме для другого підключення.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right,
        [string]$LeftOrigin = 'ліве підключення',
        [string]$RightOrigin = 'праве підключення',
        [ValidateSet('agent', 'overlay')][string]$LeftCredentialsKind = 'agent',
        [ValidateSet('agent', 'overlay')][string]$RightCredentialsKind = 'overlay'
    )

    $l = Get-KitInfobaseCanonicalForm -Connection $Left
    $r = Get-KitInfobaseCanonicalForm -Connection $Right

    if (-not $l.Parsed -or -not $r.Parsed) {
        $badOrigin = if (-not $l.Parsed) { $LeftOrigin } else { $RightOrigin }
        $bad = if (-not $l.Parsed) { $l } else { $r }
        $reason = $bad.Reason
        if ($bad.Exception) {
            $kind = if (-not $l.Parsed) { $LeftCredentialsKind } else { $RightCredentialsKind }
            $recipe = Get-V8CredentialsRecipe -Exception $bad.Exception -Kind $kind
            if ($recipe) { $reason += ' ' + $recipe }
        }
        throw ("Kit не може однозначно розібрати й звірити два підключення до бази: нерозбірне — $badOrigin. " +
               "$reason Очікується File=<абсолютний шлях> або Srvr=<сервер>;Ref=<база>;. " +
               'Доки kit не впевнений, що бази РІЗНІ, він зупиняється, а не продовжує мовчки (принцип 3).')
    }
    if ($l.Kind -ne $r.Kind) { return $false }
    $l.Identity -eq $r.Identity
}

function Resolve-KitAgentBase {
    <#
    .SYNOPSIS
        База агента воркспейсу — так, як її бачить Unica (§2.5) — плюс аудит: це не база людини.
    .DESCRIPTION
        Принцип 3: kit ніколи не пише в базу людини. Підключення бази агента (з
        `infobases.origin` у v8project.local.yaml — Resolve-V8AgentInfobase) звіряється проти
        КОЖНОЇ дев-бази з infobases: накладки kit через Test-KitSameInfobase — порівняння за
        ідентичністю бази, не за текстом підключення (F1). Збіг або нерозбірне підключення
        (з будь-якого боку) — throw до будь-якої дії. $null — «бази не налаштовано на цій
        машині»: що це означає, вирішує викликач через Test-KitWorkspaceNeedsAgentBase
        (воркспейс зовнішніх обробок бази не потребує, воркспейс з конфігурацією чи розширенням — потребує).

        Файлову базу агента звіряють уже РОЗВ'ЯЗАНОЮ до абсолютного шляху
        (Resolve-KitAgentInfobasePath, чиста функція — виклик до звірки нічого не змінює,
        аудит лишається "до будь-якої дії"): відносний File= бази агента законний (від теки
        воркспейсу, §2.5), а Test-KitSameInfobase кидає на відносному File= — те правило для
        підключень з накладки kit, де бази відліку немає, не для бази агента. Розв'язаний
        шлях повторно серіалізується в 'File=<шлях>' без лапок (парні лапки розбір однаково
        зняв би; потрібні вони лише для читабельності).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Workspace)

    $ib = Resolve-V8AgentInfobase -Project $Workspace.Project
    if ($null -eq $ib) { return $null }

    $resolved = Resolve-KitAgentInfobasePath -Project $Workspace.Project -Connection $ib.Connection

    if ($Context.Overlay) {
        $agentConn = if ($resolved.Kind -eq 'file') { 'File={0}' -f $resolved.Path } else { $ib.Connection }
        foreach ($human in $Context.Overlay.Infobases.Values) {
            if (Test-KitSameInfobase -Left $agentConn -Right $human.Connection `
                    -LeftOrigin "база агента воркспейсу '$($Workspace.Path)' (infobases.origin у v8project.local.yaml)" `
                    -RightOrigin "дев-база '$($human.Name)' у v8storagekit.local.yaml") {
                throw ("База агента воркспейсу '$($Workspace.Path)' ($($ib.Origin)) збігається з дев-базою людини '$($human.Name)' із накладки kit. " +
                       'Kit ніколи не пише в базу людини (принцип 3): приберіть infobases.origin з v8project.local.yaml або дайте агентові окрему базу.')
            }
        }
    }

    [pscustomobject]@{
        Workspace = $Workspace.Path; Connection = $ib.Connection; User = $ib.User; Password = $ib.Password; Dbms = $ib.Dbms
        Origin = $ib.Origin
        Kind = $resolved.Kind; Path = $resolved.Path; IbSwitch = $resolved.IbSwitch
        Exists = $(if ($resolved.Kind -eq 'file') { Test-Path -LiteralPath (Join-Path $resolved.Path '1Cv8.1CD') -PathType Leaf } else { $true })
    }
}

function Test-KitWorkspaceNeedsAgentBase {
    <#
    .SYNOPSIS
        Чи потребує воркспейс бази агента — за ТИПАМИ наборів, не за наявністю бази (спека §10 П16).
    .DESCRIPTION
        До 1.5.0 «у v8project.yaml немає infobase:» означало «зовнішні обробки». Тепер база живе
        лише в гітігнорованому v8project.local.yaml, і на свіжому клоні її немає ніде — без цієї
        функції свіжий клон воркспейсу з розширенням виглядав би як воркспейс обробок, і kit
        мовчав би там, де мусить зупинити з рецептом.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Workspace)
    @($Workspace.Project.SourceSets | Where-Object { $_.Type -in 'CONFIGURATION', 'EXTENSION' }).Count -gt 0
}

function New-KitAgentBaseMissingMessage {
    <#
    .SYNOPSIS
        Єдиний текст «бази агента воркспейсу не налаштовано» — для зупинок і знахідок check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)
    ("База агента воркспейсу '$WorkspacePath' не налаштована: у $WorkspacePath/v8project.local.yaml немає infobases.origin " +
     '(файл гітігнорований — на свіжому клоні його ще немає). Налаштувати й розгорнути базу — скіл v8storagekit:provision, тоді повторіть команду.')
}

Export-ModuleMember -Function Resolve-KitAgentBase, Test-KitSameInfobase, Test-KitWorkspaceNeedsAgentBase, New-KitAgentBaseMissingMessage
