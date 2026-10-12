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
        Допоміжна функція для Test-KitInfobasesOverlap: розбирає File= чи Srvr=;Ref= на
        {Parsed; Kind; Identity; Reason}. Сирий розбір — ConvertFrom-V8Connection
        (V8.psm1, issue #9): непарна лапка, голий шлях, Srvr= без Ref=, невідомий
        ключ і решта — виняток ConvertFrom-V8Connection, тут лише перехоплений і
        перетворений на Parsed=$false з текстом винятку в Reason.

        Сама по собі fail-closed НЕ реалізує (не кидає) — це робить Test-KitInfobasesOverlap,
        маючи обидва боки одразу (щоб назвати обидва підключення в одному повідомленні).
        Відносний File= тут ЗАВЖДИ Parsed=$false: ця функція не знає бази відліку (тека
        воркспейсу для бази агента, спека §2.5) — той, хто кличе Test-KitInfobasesOverlap,
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
    # Канонізація (П26): без \\?\, з розкритими посиланнями по наявних компонентах. Збій читання
    # атрибута — нерозбірне (fail-closed), текст без шляху.
    try { $full = Get-KitCanonicalPath -Path $raw }
    catch { return [pscustomobject]@{ Parsed = $false; Kind = $null; Identity = ''; Reason = $_.Exception.Message; Exception = $null } }
    [pscustomobject]@{ Parsed = $true; Kind = 'file'; Identity = ('file:' + $full.ToLowerInvariant()); Path = $full; Reason = ''; Exception = $null }
}

function Get-KitCanonicalPath {
    <#
    .SYNOPSIS
        Канонічний абсолютний шлях для порівняння баз і тек (П26): без префікса \\?\, з розкритими посиланнями.
    .DESCRIPTION
        Текстова нормалізація не бачить двох речей, через які аудит «база агента ≠ база людини»
        пропускав збіг: префікс \\?\ (інша форма запису тієї самої теки) і junction/symlink на
        проміжному компоненті (build за junction веде на теку, де лежить дев-база). Тут: зняти
        \\?\ (і \\?\UNC\), GetFullPath, далі йти компонентами від кореня; наявний компонент-посилання
        замінюється його ціллю (LinkTarget), решта шляху дописується як є — ненаявний компонент
        зупиняє розкриття (глибше нічого немає). Помилка читання атрибута наявного компонента —
        виняток (fail-closed), а не «посилання немає». Текст винятку не містить шляху (П23).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $p = $Path.Trim()
    if ($p.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $p = '\\' + $p.Substring(8) }
    elseif ($p.StartsWith('\\?\') -or $p.StartsWith('\??\')) { $p = $p.Substring(4) }
    $full = [System.IO.Path]::GetFullPath($p)

    for ($hop = 0; $hop -lt 40; $hop++) {
        $root = [System.IO.Path]::GetPathRoot($full)
        $segments = @($full.Substring($root.Length) -split '[\\/]+' | Where-Object { $_ })
        $current = $root.TrimEnd('\', '/')
        $restart = $null
        for ($i = 0; $i -lt $segments.Count; $i++) {
            $next = $current + '\' + $segments[$i]
            $attr = $null
            try { $attr = [System.IO.File]::GetAttributes($next) }
            catch [System.IO.FileNotFoundException] { $attr = $null }
            catch [System.IO.DirectoryNotFoundException] { $attr = $null }
            catch { throw 'не вдалося перевірити компонент шляху бази на посилання — kit не може довести, що бази різні.' }
            if ($null -eq $attr) {
                # Глибше нічого немає: решту дописуємо як є.
                $current = $next
                for ($j = $i + 1; $j -lt $segments.Count; $j++) { $current += '\' + $segments[$j] }
                return $current
            }
            if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                $target = $null
                try { $target = (Get-Item -LiteralPath $next -Force -ErrorAction Stop).LinkTarget } catch { throw 'не вдалося прочитати ціль посилання в шляху бази — kit не може довести, що бази різні.' }
                if ($target) {
                    if ($target.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $target = '\\' + $target.Substring(8) }
                    elseif ($target.StartsWith('\\?\') -or $target.StartsWith('\??\')) { $target = $target.Substring(4) }
                    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = [System.IO.Path]::GetFullPath($target, $current + '\') }
                    $tail = if ($i + 1 -lt $segments.Count) { '\' + (($segments[($i + 1)..($segments.Count - 1)]) -join '\') } else { '' }
                    $restart = [System.IO.Path]::GetFullPath($target.TrimEnd('\', '/') + $tail)
                    break
                }
            }
            $current = $next
        }
        if ($null -eq $restart) { return $current }
        $full = $restart
    }
    throw 'ланцюг посилань у шляху бази задовгий (або зациклений) — kit не може довести, що бази різні.'
}

function Test-KitPathsOverlap {
    <#
    .SYNOPSIS
        Чи перетинаються два шляхи: рівні, один під іншим чи над ним (П26) — після канонізації.
    .DESCRIPTION
        Єдиний предикат перетину на kit: аудит бази людини (Test-KitInfobasesOverlap) і межа
        <workPath>/infobases у provision кличуть саме його, а не власні копії. Порівняння — з
        роздільником (build\ib2 не лежить під build\ib), без урахування регістру.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    Test-KitCanonicalPathsOverlap -Left (Get-KitCanonicalPath -Path $Left) -Right (Get-KitCanonicalPath -Path $Right)
}

function Test-KitCanonicalPathsOverlap {
    # Єдина копія порівняння з роздільником — для вже канонізованих шляхів (не експортується).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $a = $Left.TrimEnd('\', '/') + '\'
    $b = $Right.TrimEnd('\', '/') + '\'
    $a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-KitPathAncestry {
    # Шлях і всі його предки у ВЛАСНОМУ написанні (\\localhost\C$\…, subst-диск — як записано), від глибокого до кореня.
    # Приватний: потрібен лише Get-KitProtectedPaths. Збій Split-Path обриває ланцюг, а не кидає.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $cands = [System.Collections.Generic.List[string]]::new()
    $cur = $Path.TrimEnd('\', '/')
    for ($i = 0; $i -lt 64 -and $cur; $i++) {
        $cands.Add($cur)
        $parent = $null
        try { $parent = Split-Path -Parent $cur } catch { $parent = $null }
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    , $cands.ToArray()
}

function Get-KitProtectedPaths {
    <#
    .SYNOPSIS
        ЄДИНИЙ перелік шляхів, яких provision не має права зачепити (П26 п. 7).
    .DESCRIPTION
        Перелік будує лише ця функція; з неї беруть і текстовий перетин першого проходу
        (Find-KitProtectedCollisions), і маркер-фазу між проходами (Invoke-KitProvision). Новий вид
        вхідного шляху додається СЮДИ, а не отримує власну перевірку. Елементи:
        - devbase — дев-бази накладки (Kit ніколи не пише в базу людини);
        - otherbase — бази агента ІНШИХ воркспейсів маніфесту;
        - othermemory — <workPath>/infobases інших воркспейсів (пам'ять раннера, мітка власника, замок);
        - template — файли .dt: -Template прогону й agentBase.template накладки КОЖНОГО воркспейсу
          (файл людини; шаблон іншого воркспейсу захищений так само).

        Елемент: {Kind; Other; Label; Path; Connection; Candidates}. Label — текст для повідомлення
        без значень конфігу (П23). Path — абсолютний шлях файлової бази чи файла (null для серверної);
        Connection — підключення серверної бази (для порівняння сервера й Ref). Candidates — Path і всі
        його предки у ВЛАСНОМУ написанні (так псевдонім шляху видно файловій системі, але не канонізації
        тексту): за ними маркер-фаза шукає маркер. Для файла (шаблону) маркер у самому файлі не з'явиться,
        тож фактично його шукають за наявними предками. Кожен елемент перевіряється проти КОЖНОЇ
        цілі (див. Find-KitProtectedCollisions): вибіркових пар немає.

        Дев-база з відносним File= у перелік не потрапляє: Resolve-KitAgentBase ще до плану зупиняє її
        fail-closed. Серверні бази не мають шляху, тож маркер-фаза їх пропускає.
    .PARAMETER Kinds
        Звузити перелік (check кличе лише з чужими воркспейсами; логіка побудови та сама).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Workspace,
        [string]$Template,
        [ValidateSet('devbase', 'otherbase', 'othermemory', 'template')][string[]]$Kinds = @('devbase', 'otherbase', 'othermemory', 'template')
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($kind, $other, $label, $path, $connection)
        $cands = if ($path) { Get-KitPathAncestry -Path $path } else { @() }
        $items.Add([pscustomobject]@{
            Kind = $kind; Other = $other; Label = $label; Path = $path; Connection = $connection
            Candidates = @($cands)
        })
    }
    if ('devbase' -in $Kinds -and $Context.Overlay) {
        foreach ($human in $Context.Overlay.Infobases.Values) {
            $label = "дев-база '$($human.Name)'"
            $parsed = $null
            try { $parsed = ConvertFrom-V8Connection -Connection $human.Connection }
            catch { throw "Не вдалося розібрати підключення ($label) для перевірки захищених шляхів — kit не може довести, що бази різні." }
            if ($parsed.Kind -ne 'file') { & $add 'devbase' $null $label $null $human.Connection; continue }
            $p = $parsed.File
            if ($p.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $p = '\\' + $p.Substring(8) }
            elseif ($p.StartsWith('\\?\') -or $p.StartsWith('\??\')) { $p = $p.Substring(4) }
            if (-not [System.IO.Path]::IsPathRooted($p)) { continue }
            & $add 'devbase' $null $label $p $null
        }
    }
    if ('otherbase' -in $Kinds -or 'othermemory' -in $Kinds) {
        foreach ($other in @($Context.Workspaces | Where-Object { $_.Path -ne $Workspace.Path })) {
            $ib = Resolve-V8AgentInfobase -Project $other.Project
            if ($null -eq $ib) { continue }
            if ('otherbase' -in $Kinds) {
                $resolved = Resolve-KitAgentInfobasePath -Project $other.Project -Connection $ib.Connection
                $label = "база агента воркспейсу '$($other.Path)'"
                if ($resolved.Kind -eq 'file') { & $add 'otherbase' $other.Path $label $resolved.Path $null }
                else { & $add 'otherbase' $other.Path $label $null $ib.Connection }
            }
            if ('othermemory' -in $Kinds) {
                $mem = Join-Path (Join-Path $other.FullPath $other.Project.WorkPath) 'infobases'
                & $add 'othermemory' $other.Path "пам'ять раннера воркспейсу '$($other.Path)' (<workPath>/infobases)" $mem $null
            }
        }
    }
    if ('template' -in $Kinds) {
        # Шаблон — файл людини: захищені -Template прогону й agentBase.template накладки КОЖНОГО воркспейсу (N1),
        # не лише цього: .dt іншого воркспейсу чи накладковий шаблон за іншого -Template теж лежить десь на диску людини.
        $templates = [System.Collections.Generic.List[string]]::new()
        if ($Template) { $templates.Add($Template) }
        if ($Context.Overlay) {
            foreach ($ow in $Context.Overlay.Workspaces.Values) { if ($ow.AgentBaseTemplate) { $templates.Add([string]$ow.AgentBaseTemplate) } }
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $templates) {
            $full = [System.IO.Path]::GetFullPath($t)
            if ($seen.Add($full)) { & $add 'template' $null 'шаблон бази (.dt)' $full $null }
        }
    }
    $items.ToArray()
}

function Find-KitProtectedCollisions {
    <#
    .SYNOPSIS
        Текстовий перетин (з канонізацією) елементів переліку захищених шляхів з текою, яку прибере provision (П26 п. 1, 7).
    .DESCRIPTION
        Перший рівень — дешевий, без побічних ефектів, діє в префлайті й аудиті. Для кожного елемента
        Get-KitProtectedPaths перевіряється проти КОЖНОЇ цілі з -Targets (base | infobases | memory —
        об'єкти {Path; Connection}) — подвійний цикл «перелік × цілі», без вибору пар. Файли — Test-KitPathsOverlap (канонізація, перетин);
        серверні — Test-KitInfobasesOverlap (сервер і Ref). Нерозбірне — виняток без значень шляху
        (fail-closed). Повертає {Element; Target}. Другий рівень (псевдоніми) — маркер-фаза provision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Protected,
        [Parameter(Mandatory)][hashtable]$Targets
    )
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($el in @($Protected)) {
        foreach ($name in @($Targets.Keys)) {
            $t = $Targets[$name]
            $overlap = $false
            if ($el.Path) {
                if ($t.Path) {
                    try { $overlap = Test-KitPathsOverlap -Left $el.Path -Right $t.Path }
                    catch { throw "Kit не може звірити захищений шлях ($($el.Label)) з текою, яку прибирає provision: $($_.Exception.Message)" }
                }
            } elseif ($t.Connection) {
                $overlap = Test-KitInfobasesOverlap -Left $el.Connection -Right $t.Connection -LeftOrigin $el.Label -RightOrigin 'база агента цього воркспейсу (infobases.origin)'
            }
            if ($overlap) { $hits.Add([pscustomobject]@{ Element = $el; Target = $name }) }
        }
    }
    $hits.ToArray()
}

function Find-KitAgentBaseCollisions {
    <#
    .SYNOPSIS
        Перетини бази агента воркспейсу з базами агента ІНШИХ воркспейсів маніфесту (П26 п. 5) — для аудиту check.
    .DESCRIPTION
        Дивиться за межі прогону: -Workspace B не бачить A, і без цього provision знищив би базу A, вкладену
        в теку B. Не має власної логіки перетину: бере чужі елементи з Get-KitProtectedPaths і порівнює їх
        через Find-KitProtectedCollisions — тією самою процедурою, що й перший прохід provision. Повертає
        {Other; Kind; Server}: Kind = base (база проти бази) | memory-mine (чужа база в <workPath>/infobases
        цього) | memory-theirs (ця база в <workPath>/infobases чужого); Server — збіг серверних баз за
        сервером і Ref (не «тека»). Без значень конфігу, тексти будують викликачі.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Workspace)

    $mine = Resolve-V8AgentInfobase -Project $Workspace.Project
    if ($null -eq $mine) { return @() }
    $myResolved = Resolve-KitAgentInfobasePath -Project $Workspace.Project -Connection $mine.Connection
    $targets = @{
        base      = [pscustomobject]@{ Path = $(if ($myResolved.Kind -eq 'file') { $myResolved.Path } else { $null }); Connection = $(if ($myResolved.Kind -eq 'file') { $null } else { $mine.Connection }) }
        infobases = [pscustomobject]@{ Path = (Join-Path (Join-Path $Workspace.FullPath $Workspace.Project.WorkPath) 'infobases'); Connection = $null }
    }
    $protected = @(Get-KitProtectedPaths -Context $Context -Workspace $Workspace -Kinds 'otherbase', 'othermemory')
    $found = foreach ($h in @(Find-KitProtectedCollisions -Protected $protected -Targets $targets)) {
        $kind = if ($h.Element.Kind -eq 'othermemory') { 'memory-theirs' } elseif ($h.Target -eq 'base') { 'base' } else { 'memory-mine' }
        [pscustomobject]@{ Other = $h.Element.Other; Kind = $kind; Server = (-not $h.Element.Path -and $kind -eq 'base') }
    }
    @($found)
}

function Test-KitInfobasesOverlap {
    <#
    .SYNOPSIS
        Чи ПЕРЕТИНАЮТЬСЯ два підключення: та сама база або одна лежить усередині/над іншою (принцип 3, П26).
    .DESCRIPTION
        Семантика (П26): не «та сама база», а ПЕРЕТИН. Файлові бази канонізуються (без \\?\, з
        розкритими посиланнями по наявних компонентах — Get-KitCanonicalPath) і вважаються
        перетином, коли шляхи рівні, один під іншим чи над ним: provision -Force знищує теку
        бази агента разом з усім, що в ній, тож дев-база всередині неї чи над нею гине так само,
        як збіг. Серверні — сервер і Ref, як і раніше. Єдина функція для provision, префлайту й
        аудиту check; ім'я каже про перетин, а не про рівність.

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
    if ($l.Kind -eq 'file') {
        # Перетин, не рівність (П26): база всередині теки іншої, чи над нею, знищується разом із нею.
        # Шляхи вже канонізовано (Get-KitInfobaseCanonicalForm) — предикат той самий, що в Test-KitPathsOverlap.
        return (Test-KitCanonicalPathsOverlap -Left $l.Path -Right $r.Path)
    }
    $l.Identity -eq $r.Identity
}

function Resolve-KitAgentBase {
    <#
    .SYNOPSIS
        База агента воркспейсу — так, як її бачить Unica (§2.5) — плюс аудит: це не база людини.
    .DESCRIPTION
        Принцип 3: kit ніколи не пише в базу людини. Підключення бази агента (з
        `infobases.origin` у v8project.local.yaml — Resolve-V8AgentInfobase) звіряється проти
        КОЖНОЇ дев-бази з infobases: накладки kit через Test-KitInfobasesOverlap — порівняння за
        ідентичністю бази, не за текстом підключення (F1). Збіг або нерозбірне підключення
        (з будь-якого боку) — throw до будь-якої дії. $null — «бази не налаштовано на цій
        машині»: що це означає, вирішує викликач через Test-KitWorkspaceNeedsAgentBase
        (воркспейс зовнішніх обробок бази не потребує, воркспейс з конфігурацією чи розширенням — потребує).

        Файлову базу агента звіряють уже РОЗВ'ЯЗАНОЮ до абсолютного шляху
        (Resolve-KitAgentInfobasePath, чиста функція — виклик до звірки нічого не змінює,
        аудит лишається "до будь-якої дії"): відносний File= бази агента законний (від теки
        воркспейсу, §2.5), а Test-KitInfobasesOverlap кидає на відносному File= — те правило для
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
            if (Test-KitInfobasesOverlap -Left $agentConn -Right $human.Connection `
                    -LeftOrigin "база агента воркспейсу '$($Workspace.Path)' (infobases.origin у v8project.local.yaml)" `
                    -RightOrigin "дев-база '$($human.Name)' у v8storagekit.local.yaml") {
                throw ("База агента воркспейсу '$($Workspace.Path)' ($($ib.Origin)) збігається з дев-базою людини '$($human.Name)' із накладки kit або перетинається з нею (та сама тека, вкладена чи батьківська). " +
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

Export-ModuleMember -Function Resolve-KitAgentBase, Test-KitInfobasesOverlap, Test-KitPathsOverlap, Find-KitAgentBaseCollisions, Get-KitProtectedPaths, Find-KitProtectedCollisions, Get-KitCanonicalPath, Test-KitWorkspaceNeedsAgentBase, New-KitAgentBaseMissingMessage
