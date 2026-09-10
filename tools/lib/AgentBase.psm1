#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — той самий принцип, що й у решти вкладених імпортів lib-модулів
# (StorageReport.psm1, V8Project.psm1): не перезавантажувати вже наявний глобальний
# V8Project. AgentBase бере звідти Resolve-V8AgentInfobase і Resolve-KitAgentInfobasePath.
Import-Module "$PSScriptRoot/V8Project.psm1"

function Get-KitInfobaseCanonicalForm {
    <#
    .SYNOPSIS
        Приватний розбір одного підключення на канонічну форму — не експортується.
    .DESCRIPTION
        Допоміжна функція для Test-KitSameInfobase: розбирає File= чи Srvr=;Ref= на
        {Parsed; Kind; Identity; Reason}. Сама по собі fail-closed НЕ реалізує (не кидає) —
        це робить Test-KitSameInfobase, маючи обидва боки одразу (щоб назвати обидва
        підключення в одному повідомленні). Відносний File= тут ЗАВЖДИ Parsed=$false: ця
        функція не знає бази відліку (тека воркспейсу для бази агента, спека §2.5) — той,
        хто кличе Test-KitSameInfobase, мусить сам розв'язати відносний File= бази агента
        до абсолютного шляху ДО звірки (Resolve-KitAgentBase так і робить).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Connection)

    $value = $Connection.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = 'підключення порожнє' }
    }

    if ($value -match '(?i)\bsrvr\s*=\s*"?(?<srvr>[^";]+)"?') {
        $srvr = $Matches['srvr'].Trim()
        if ($value -match '(?i)\bref\s*=\s*"?(?<ref>[^";]+)"?') {
            $ref = $Matches['ref'].Trim()
            $identity = 'server:' + $srvr.ToLowerInvariant() + '/' + $ref.ToLowerInvariant()
            return [pscustomobject]@{ Parsed = $true; Kind = 'server'; Identity = $identity; Reason = '' }
        }
        return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = "серверне підключення без Ref=: $value" }
    }

    if ($value -match '(?i)\bfile\s*=\s*"?(?<p>[^";]+)"?') {
        $raw = $Matches['p'].Trim()
        if (-not [System.IO.Path]::IsPathRooted($raw)) {
            return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = "відносний File= '$raw' — kit звіряє лише абсолютні File=" }
        }
        $full = [System.IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
        return [pscustomobject]@{ Parsed = $true; Kind = 'file'; Identity = ('file:' + $full.ToLowerInvariant()); Reason = '' }
    }

    [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = "'$value' не розпізнано ні як File=, ні як Srvr=" }
}

function Test-KitSameInfobase {
    <#
    .SYNOPSIS
        Чи описують два підключення ТУ САМУ базу — а не той самий текст (принцип 3).
    .DESCRIPTION
        Текстова нормалізація (пробіли/лапки/регістр) не досить: 'File="D:\Bases\SMP_UNF\"'
        і 'File=D:\Bases\SMP_UNF' — та сама тека, текстово різні рядки; 'Srvr="VSDEV";Ref="SMP_UNF";'
        і 'Ref="SMP_UNF";Srvr="VSDEV";' — та сама база, різний порядок ключів. Ця функція
        порівнює РОЗІБРАНІ поля: для файлової — абсолютний шлях (GetFullPath), без кінцевого
        роздільника, без урахування регістру (файлова система Windows регістронезалежна); для
        серверної — сервер і Ref, кожен окремо знайдений незалежно від порядку в рядку, без
        урахування регістру.

        Fail-closed навмисно: коли ХОЧ ОДНЕ підключення не розбирається однозначно, функція
        КИДАЄ виняток (називаючи обидва підключення дослівно), а НЕ повертає $false.
        "Не розібрали" -> "не збігається" (типова "безпечна" відповідь на помилку) тут була б
        насправді мовчазним ДОЗВОЛОМ: викликач (Resolve-KitAgentBase) далі веде до
        kit provision -Apply -Force, а це Remove-Item -Recurse -Force над текою підключення.
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    $l = Get-KitInfobaseCanonicalForm -Connection $Left
    $r = Get-KitInfobaseCanonicalForm -Connection $Right

    if (-not $l.Parsed -or -not $r.Parsed) {
        $reason = if (-not $l.Parsed) { $l.Reason } else { $r.Reason }
        throw ("Kit не може однозначно розібрати й звірити два підключення до бази: '$Left' і '$Right'. " +
               "$reason. Очікується File=`"<абсолютний шлях>`" або Srvr=`"<сервер>`";Ref=`"<база>`";. " +
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
        v8project.local.yaml або v8project.yaml — Resolve-V8AgentInfobase) звіряється проти
        КОЖНОЇ дев-бази з infobases: накладки kit через Test-KitSameInfobase — порівняння за
        ідентичністю бази, не за текстом підключення (F1). Збіг або нерозбірне підключення
        (з будь-якого боку) — throw до будь-якої дії. $null — у воркспейсі бази немає
        (зовнішні обробки).

        Файлову базу агента звіряють уже РОЗВ'ЯЗАНОЮ до абсолютного шляху
        (Resolve-KitAgentInfobasePath, чиста функція — виклик до звірки нічого не змінює,
        аудит лишається "до будь-якої дії"): відносний File= бази агента законний (від теки
        воркспейсу, §2.5), а Test-KitSameInfobase кидає на відносному File= — те правило для
        підключень з накладки kit, де бази відліку немає, не для бази агента.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Workspace)

    $ib = Resolve-V8AgentInfobase -Project $Workspace.Project
    if ($null -eq $ib) { return $null }

    $resolved = Resolve-KitAgentInfobasePath -Project $Workspace.Project -Connection $ib.Connection

    if ($Context.Overlay) {
        $agentConn = if ($resolved.Kind -eq 'file') { 'File="{0}"' -f $resolved.Path } else { $ib.Connection }
        foreach ($human in $Context.Overlay.Infobases.Values) {
            if (Test-KitSameInfobase -Left $agentConn -Right $human.Connection) {
                throw ("База агента воркспейсу '$($Workspace.Path)' ($($ib.Origin)) збігається з дев-базою людини '$($human.Name)' із накладки kit. " +
                       'Kit ніколи не пише в базу людини (принцип 3): приберіть infobase: з v8project.local.yaml або дайте агентові окрему базу.')
            }
        }
    }

    [pscustomobject]@{
        Workspace = $Workspace.Path; Connection = $ib.Connection; User = $ib.User; Origin = $ib.Origin
        Kind = $resolved.Kind; Path = $resolved.Path; IbSwitch = $resolved.IbSwitch
        Exists = $(if ($resolved.Kind -eq 'file') { Test-Path -LiteralPath (Join-Path $resolved.Path '1Cv8.1CD') -PathType Leaf } else { $true })
    }
}

Export-ModuleMember -Function Resolve-KitAgentBase, Test-KitSameInfobase
