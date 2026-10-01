#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force: те саме застереження, що й довкола вкладеного імпорту V8.psm1 у
# StorageReport.psm1 (див. коментар там) — не перезавантажувати вже наявний глобальний
# PathSafety і не ховати його експорти від глобальної області.
Import-Module "$PSScriptRoot/PathSafety.psm1"

$script:DefaultPlatformRoots = [ordered]@{ x64 = 'C:\Program Files\1cv8'; x86 = 'C:\Program Files (x86)\1cv8' }

function Get-KitInstalledPlatforms {
    <#
    .SYNOPSIS
        Платформи 1С, фактично встановлені в оточенні (спека 1.3.1 §4.2): теки-версії під x64- і
        x86-коренем, у яких існує bin\1cv8.exe. Тека без exe — залишок деінсталяції, не платформа.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Roots = $script:DefaultPlatformRoots)
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($arch in @($Roots.Keys)) {
        $root = $Roots[$arch]
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            $exe = Join-Path $d.FullName 'bin\1cv8.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $found.Add([pscustomobject]@{ Version = $d.Name; Arch = $arch; Path = $exe })
            }
        }
    }
    $archRank = @{ x64 = 0; x86 = 1 }
    @($found | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { $archRank[$_.Arch] } })
}

function Get-KitPlatformVersionFromPath {
    <#
    .SYNOPSIS
        <корінь>\<версія>\bin\1cv8.exe → <версія>. Єдине місце цієї формули (sync і verify).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $Path))
}

function Get-V8Path {
    [CmdletBinding()]
    param(
        [string]$Version = '8.3.27.1644',
        [System.Collections.IDictionary]$Roots = $script:DefaultPlatformRoots
    )

    if ($PSBoundParameters.ContainsKey('Version')) {
        # Явна версія (спека 1.3.1 §6.1.6) — точний збіг у будь-якому корені, x64 першим. Типовий
        # пошук нижче (без -Version) лишається як був: лише x64, гілка 8.3.27.
        $installed = @(Get-KitInstalledPlatforms -Roots $Roots)
        $exact = @($installed | Where-Object Version -eq $Version) | Select-Object -First 1
        if ($exact) { return $exact.Path }
        $have = @($installed | ForEach-Object { "$($_.Version) ($($_.Arch))" })
        throw "Платформи $Version в оточенні немає. Встановлено: $(if ($have) { $have -join ', ' } else { 'жодної' })."
    }

    $candidate = "C:\Program Files\1cv8\$Version\bin\1cv8.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    $root = 'C:\Program Files\1cv8'
    if (Test-Path -LiteralPath $root) {
        $found = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '8.3.27.*' } |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\1cv8.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($found) { return $found }
    }

    throw "Платформу 1С гілки 8.3.27.x не знайдено. Очікувався $candidate"
}

function ConvertFrom-V8Connection {
    <#
    .SYNOPSIS
        Єдиний розбір рядка підключення до інформаційної бази 1С (issue #9).
    .DESCRIPTION
        Одна форма на весь контур — без подвійного режиму: послідовність ключ=значення,
        розділених ';', значення БЕЗ лапок (Srvr=SRV;Ref=BASE;, File=build/ib,
        File=D:\Bases\X). Ключі не залежать від регістру, пробіли довкола ключа й
        значення обрізаються, кінцева ';' необов'язкова, порядок ключів довільний.

        Значення в лапках — не інший запис тієї самої форми, а помилка: Уніка
        (v8-runner) на серверній базі з формою в лапках (Srvr="SRV";Ref="BASE";) не
        підключається («Сервер 1С:Предприятия не обнаружен», спроба на порт 1542;
        виміряно 2026-09-22, 8.3.27.1644) — і та сама база без лапок підключається.
        Власна документація Уніки показує форму в лапках, вона хибна щодо поведінки.
        Тому лапки тут — fail-closed: не знімаються мовчки (це й був би подвійний
        режим), а зупиняють розбір із готовою виправленою формою в тексті.

        Голий шлях без File= більше не приймається — так само зупинка.

        Відома межа (документується, не лікується): без лапок шлях у File= не може
        містити ';'.
    .PARAMETER Connection
        Сирий рядок підключення, як він записаний у v8project(.local).yaml чи
        v8storagekit.local.yaml.
    .OUTPUTS
        [pscustomobject]@{ Kind = 'server'|'file'; Server; Ref; File }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Connection)

    if ([string]::IsNullOrWhiteSpace($Connection)) {
        throw 'Рядок підключення до інформаційної бази порожній.'
    }

    $value = $Connection.Trim()

    if ($value.Contains('"')) {
        $fixed = ($value -replace '"', '').Trim()
        throw ("Рядок підключення '$Connection' записано в лапках — Уніка (v8-runner) на серверній базі з " +
               'такою формою не підключається (issue #9: «Сервер 1С:Предприятия не обнаружен»), хоча ' +
               'документація Уніки саме її й показує. Kit не знімає лапки мовчки (це був би подвійний ' +
               "режим) — запишіть без лапок: $fixed")
    }

    if ($value -notmatch '=') {
        throw ("Рядок підключення '$Connection' — голий шлях без ключа. Голий шлях більше не приймається: " +
               "вкажіть File=$value")
    }

    $fields = @{}
    foreach ($part in ($value -split ';')) {
        $piece = $part.Trim()
        if (-not $piece) { continue }
        if ($piece -notmatch '^(?<key>[^=]+)=(?<val>.*)$') {
            throw "Рядок підключення '$Connection' містить елемент без '=': '$piece'."
        }
        $key = $Matches['key'].Trim()
        $val = $Matches['val'].Trim()
        if ([string]::IsNullOrWhiteSpace($val)) {
            throw "Рядок підключення '$Connection' містить порожнє значення для ключа '$key'."
        }
        $lkey = $key.ToLowerInvariant()
        if ($lkey -notin @('srvr', 'ref', 'file')) {
            throw "Рядок підключення '$Connection' містить невідомий ключ '$key'. Дозволені ключі: Srvr, Ref, File."
        }
        if ($fields.ContainsKey($lkey)) {
            throw "Рядок підключення '$Connection' містить ключ '$key' двічі."
        }
        $fields[$lkey] = $val
    }

    $hasSrvr = $fields.ContainsKey('srvr')
    $hasRef  = $fields.ContainsKey('ref')
    $hasFile = $fields.ContainsKey('file')

    if ($hasSrvr -and $hasFile) {
        throw "Рядок підключення '$Connection' містить одночасно Srvr= і File= — це два різні способи описати базу, разом вони суперечливі."
    }
    if ($hasSrvr -or $hasRef) {
        if (-not ($hasSrvr -and $hasRef)) {
            $missing = if ($hasSrvr) { 'Ref=' } else { 'Srvr=' }
            throw "Рядок підключення '$Connection' — серверна база потребує і Srvr=, і Ref= разом; бракує $missing."
        }
        return [pscustomobject]@{ Kind = 'server'; Server = $fields['srvr']; Ref = $fields['ref']; File = $null }
    }
    if ($hasFile) {
        return [pscustomobject]@{ Kind = 'file'; Server = $null; Ref = $null; File = $fields['file'] }
    }

    throw "Рядок підключення '$Connection' не описує базу: очікується Srvr=<сервер>;Ref=<база>; або File=<шлях>."
}

function ConvertTo-V8IbSwitch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Connection)

    $parsed = ConvertFrom-V8Connection -Connection $Connection
    if ($parsed.Kind -eq 'server') {
        return '/S "{0}\{1}"' -f $parsed.Server, $parsed.Ref
    }
    '/F "{0}"' -f $parsed.File
}

function Assert-NoLicenseProblem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)

    if ($Output -match '(?i)лиценз|ліценз|license|HASP') {
        throw "Платформа повідомила про проблему з ліцензією, робота зупинена:`n$Output"
    }
}

# Тексти з ресурсів платформи про монопольне захоплення ІБ (дослідження, п. 4 спеки). Список
# розширюваний: якщо платформа відповіла іншим формулюванням — додайте його сюди, і тест
# «база зайнята» отримає новий рядок. Файли .cfl індикатором не є — лишаються після закриття.
$script:InfobaseBusyPatterns = @(
    'Ошибка блокировки информационной базы для конфигурирования'
    'уже открыта Конфигуратором'
    'Не удалось монопольно заблокировать информационную базу'
    'Помилка блокування інформаційної бази для конфігурування'
    'вже відкрита Конфігуратором'
    'Не вдалося монопольно заблокувати інформаційну базу'
    'Error locking infobase for configuration'
    'already opened by Designer'
    'Failed to lock the infobase exclusively'
    'Cannot lock the infobase exclusively'
)

function Test-V8InfobaseBusy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    foreach ($p in $script:InfobaseBusyPatterns) {
        if ($Output.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    $false
}

function Assert-V8InfobaseNotBusy {
    <#
    .SYNOPSIS
        Зупинка з порадою, а не сирим повідомленням, коли базу тримає Конфігуратор чи інший
        монопольний сеанс (спека §5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$Infobase
    )
    if (-not (Test-V8InfobaseBusy -Output $Output)) { return }
    throw ("База '$Infobase' зайнята — її відкрито Конфігуратором або іншим монопольним сеансом. Закрийте Конфігуратор " +
           "(для серверної бази — перевірте сеанси: rac session list, якщо піднято ras) і повторіть. Файли .cfl " +
           "індикатором не є — вони лишаються після закриття.`nПлатформа відповіла: $Output")
}

function Hide-V8Secrets {
    <#
    .SYNOPSIS
        Маскує паролі в рядку аргументів платформи — для Write-Verbose і текстів зупинок.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ArgLine)
    $ArgLine -replace '(/P|/ConfigurationRepositoryP)\s+"[^"]*"', '$1 "***"'
}

function Invoke-V8Designer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IbSwitch,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$User,
        [string]$Password,
        [string]$V8Path
    )

    if (-not $V8Path) { $V8Path = Get-V8Path }

    $log = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        "v8-$([guid]::NewGuid().ToString('N')).log")

    $parts = @('DESIGNER', $IbSwitch)
    if ($User)     { $parts += '/N "{0}"' -f $User }
    if ($Password) { $parts += '/P "{0}"' -f $Password }
    $parts += '/DisableStartupDialogs'
    $parts += $Arguments
    $parts += '/Out "{0}"' -f $log

    $argLine = $parts -join ' '
    Write-Verbose "1cv8 $(Hide-V8Secrets -ArgLine $argLine)"

    $proc = Start-Process -FilePath $V8Path -ArgumentList $argLine `
        -Wait -NoNewWindow -PassThru

    $output = ''
    if (Test-Path -LiteralPath $log) {
        $raw = Get-Content -LiteralPath $log -Raw -Encoding UTF8
        if ($raw) { $output = $raw.Trim() }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }

    Assert-NoLicenseProblem -Output $output

    [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output }
}

function New-V8FileInfobase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [string]$TemplatePath,
        [string]$V8Path
    )

    # $Path стирається без перевірки, що там взагалі інфобаза, а не щось важливе —
    # -MustBeUnder змушує кожного викликача явно назвати межу, під якою $Path мусить
    # лежати (build/, build/sync/<продукт>, $TestDrive у тестах), а не довіряти
    # аргументу мовчки. Перевірка стоїть до Get-V8Path навмисно: небезпечний шлях має
    # впасти одразу, незалежно від того, чи знайдена платформа на цій машині.
    Assert-SafeWorkPath -Path $Path -MustBeUnder $MustBeUnder -Description 'Path інфобази'

    # Той самий принцип — до Get-V8Path: неіснуючий шаблон має впасти одразу, незалежно
    # від того, чи знайдена платформа на цій машині.
    $template = ''
    if ($TemplatePath) {
        if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $TemplatePath" }
        $template = ' /UseTemplate "{0}"' -f (Resolve-Path -LiteralPath $TemplatePath).Path
    }

    if (-not $V8Path) { $V8Path = Get-V8Path }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    $log = Join-Path $Path 'create.log'
    $argLine = 'CREATEINFOBASE File="{0}";{1} /DisableStartupDialogs /Out "{2}"' -f $Path, $template, $log
    $proc = Start-Process -FilePath $V8Path -ArgumentList $argLine -Wait -NoNewWindow -PassThru

    $msg = ''
    if (Test-Path -LiteralPath $log) {
        $raw = Get-Content -LiteralPath $log -Raw -Encoding UTF8
        if ($raw) { $msg = $raw.Trim() }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }

    Assert-NoLicenseProblem -Output $msg

    if ($proc.ExitCode -ne 0) {
        throw "Не вдалося створити файлову ІБ у $Path : $msg"
    }

    $Path
}

function New-ExtensionInfobase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExtensionName,
        [Parameter(Mandatory)][string]$StubPath,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [string]$V8Path
    )

    if (-not $V8Path) { $V8Path = Get-V8Path }

    New-V8FileInfobase -Path $Path -MustBeUnder $MustBeUnder -V8Path $V8Path | Out-Null
    $ibSwitch = '/F "{0}"' -f $Path

    $result = Invoke-V8Designer -IbSwitch $ibSwitch -V8Path $V8Path -Arguments @(
        '/LoadConfigFromFiles "{0}" -Extension {1}' -f (Resolve-Path -LiteralPath $StubPath), $ExtensionName)

    if ($result.ExitCode -ne 0) {
        throw "Не вдалося створити розширення $ExtensionName у тимчасовій ІБ: $($result.Output)"
    }

    $ibSwitch
}

Export-ModuleMember -Function Get-V8Path, Get-KitInstalledPlatforms, Get-KitPlatformVersionFromPath, ConvertFrom-V8Connection, ConvertTo-V8IbSwitch, Hide-V8Secrets, Invoke-V8Designer, New-V8FileInfobase, New-ExtensionInfobase, Test-V8InfobaseBusy, Assert-V8InfobaseNotBusy
