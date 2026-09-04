#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force: те саме застереження, що й довкола вкладеного імпорту V8.psm1 у
# StorageReport.psm1 (див. коментар там) — не перезавантажувати вже наявний глобальний
# PathSafety і не ховати його експорти від глобальної області.
Import-Module "$PSScriptRoot/PathSafety.psm1"

function Get-V8Path {
    [CmdletBinding()]
    param([string]$Version = '8.3.27.1644')

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

function ConvertTo-V8IbSwitch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Connection)

    if ([string]::IsNullOrWhiteSpace($Connection)) {
        throw 'Рядок підключення до інформаційної бази порожній'
    }

    $value = $Connection.Trim()

    if ($value -match '(?i)\bsrvr\s*=\s*"([^"]+)"') {
        $server = $Matches[1]
        if ($value -match '(?i)\bref\s*=\s*"([^"]+)"') {
            return '/S "{0}\{1}"' -f $server, $Matches[1]
        }
        throw "У серверному рядку підключення відсутній Ref: $Connection"
    }

    if ($value -match '(?i)\bfile\s*=\s*"([^"]+)"') {
        return '/F "{0}"' -f $Matches[1]
    }

    if ($value -notmatch '[=;"]') {
        return '/F "{0}"' -f $value
    }

    throw "Не вдалося розпізнати рядок підключення: $Connection"
}

function Read-V8LocalConnection {
    <#
    .SYNOPSIS
        Підключення до дев-бази з v8project.local.yaml.
    .DESCRIPTION
        Файл спільний з Унікою, і це джерело неоднозначності, яку функція мусить
        ловити, а не переживати мовчки.

        Уніка автоматично підхоплює v8project.local.yaml поруч із головним конфігом і
        ПЕРЕКРИВАЄ ним блок infobase: (`references/tooling/v8project.md` у плагіні
        unica: «may override local-only workPath, infobase, tools, tests, and mcp
        settings»). Тому дев-база, оголошена тут під `infobase:`, скасовує машинну базу
        воркспейсу з закоміченого v8project.yaml — і зміна, заради якої той блок туди
        додали, стає інертною.

        Тому конвенція kit: у v8project.local.yaml дев-база живе під `devInfobase:`,
        якого Уніка не читає, а `infobase:` там не з'являється взагалі.

        Друга частина ризику — наша власна. Регекс нижче не прив'язаний до
        батьківського ключа й ловить будь-який рядок `connection:`, а `-match`
        повертає ПЕРШИЙ збіг. Файл із двома підключеннями дав би dump-config.ps1
        помітне падіння, а load-ext.ps1 — тихе розкочування розширення не в ту базу.
        Обидві форми неоднозначності зупиняють роботу тут, з поясненням.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Не знайдено $Path — у ньому має бути підключення до дев-бази."
    }

    $local = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    $connectionCount = ([regex]::Matches($local, "(?m)^\s*connection:\s*'.+?'\s*$")).Count
    if ($connectionCount -gt 1) {
        throw "У $Path знайдено $connectionCount рядків connection: — неоднозначність. " +
              "Kit бере перший збіг, і це може виявитись не та база. Лишіть рівно одне " +
              "підключення, до дев-бази, під ключем devInfobase:."
    }

    if ($local -match "(?m)^\s*infobase:\s*$") {
        throw "У $Path є блок infobase: — приберіть його. Уніка перекриває ним машинну " +
              "базу воркспейсу з v8project.yaml, і та настройка стає інертною. " +
              "Підключення до дев-бази має жити під devInfobase:."
    }

    if ($local -notmatch "(?m)^\s*connection:\s*'(?<c>.+?)'\s*$") {
        throw "У $Path немає рядка connection: '...'"
    }
    # $Matches належить лише останньому виконаному -match: значення connection треба
    # забрати одразу, до того як наступний -match (для user) перепише $Matches.
    $connection = $Matches['c']

    $user = ''
    if ($local -match "(?m)^\s*user:\s*'(?<u>.+?)'\s*$") { $user = $Matches['u'] }

    [pscustomobject]@{
        Connection = $connection
        User       = $user
    }
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
        [string]$V8Path
    )

    # $Path стирається без перевірки, що там взагалі інфобаза, а не щось важливе —
    # -MustBeUnder змушує кожного викликача явно назвати межу, під якою $Path мусить
    # лежати (build/, build/sync/<продукт>, $TestDrive у тестах), а не довіряти
    # аргументу мовчки. Перевірка стоїть до Get-V8Path навмисно: небезпечний шлях має
    # впасти одразу, незалежно від того, чи знайдена платформа на цій машині.
    Assert-SafeWorkPath -Path $Path -MustBeUnder $MustBeUnder -Description 'Path інфобази'

    if (-not $V8Path) { $V8Path = Get-V8Path }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    $log = Join-Path $Path 'create.log'
    $argLine = 'CREATEINFOBASE File="{0}"; /DisableStartupDialogs /Out "{1}"' -f $Path, $log
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

Export-ModuleMember -Function Get-V8Path, ConvertTo-V8IbSwitch, Read-V8LocalConnection, Hide-V8Secrets, Invoke-V8Designer, New-V8FileInfobase, New-ExtensionInfobase, Test-V8InfobaseBusy, Assert-V8InfobaseNotBusy
