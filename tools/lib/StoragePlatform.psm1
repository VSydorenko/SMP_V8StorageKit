#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/V8.psm1"
# Без -Force — та сама конвенція, що для PathSafety і V8 вище. AgentBase у module-order.txt
# стоїть раніше за StoragePlatform, тож у kit.ps1 функція вже є глобально; явний імпорт тут
# потрібен для тестів, які вантажать цей модуль окремо від диспетчера.
Import-Module "$PSScriptRoot/AgentBase.psm1"

# Результат спайку B2 (спека §14, «Результат спайку»): чи потребує UpdateCfg для ОСНОВНОЇ
# конфігурації прив'язки ІБ до сховища. $true — kit робить ConfigurationRepositoryBindCfg під
# користувачем сховища на час роботи й знімає її UnbindCfg -force у finally: єдиний запис у
# сховище, який kit виконує. Значення перенесено з tools/commands/sync.psm1 (B2).
$script:ConfigurationStorageNeedsBind = $false
$script:DefaultStubPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/empty-extension'))
$script:PlatformJunk = @('ConfigDumpInfo.xml', 'DumpFilesIndex.txt')

function Get-KitRepositoryArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    # Кома навмисно: викликачі роблять (Get-KitRepositoryArguments …) + @(…), НЕ @(…) — див. F7.
    , @(
        '/ConfigurationRepositoryF "{0}"' -f $Source.StoragePath
        '/ConfigurationRepositoryN "{0}"' -f $Source.StorageUser
        '/ConfigurationRepositoryP "{0}"' -f $Source.StoragePassword   # пароль лише з накладки (B2 Task 2a); ніколи не друкувати
    )
}

function Get-KitExtensionArgument {
    <# -Extension належить команді-дії (ранбук, п. 1); для конфігурації — порожньо. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    if ($Source.Type -eq 'EXTENSION') { return " -Extension $($Source.Key)" }
    ''
}

function Test-KitExtensionNotFound {
    <#
    .SYNOPSIS
        Відповідь платформи «розширення з таким іменем не знайдено» (рос./укр.) — ЄДИНЕ місце
        розпізнавання: Invoke-KitStorageCheckout (рецепт «спершу operation=build») і запасний шлях
        sync (спека 2026-09-30 §6.9). Друга копія регулярки розійшлась би з першою тихо (kit-dev, case 5).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    $Output -match '(?i)расширени\w+ .*не найдено|розширенн\w+ .*не знайдено'
}

function New-KitStorageInfobase {
    <#
    .SYNOPSIS
        Тимчасова ІБ під <WorkDir>/ib для читання сховища: розширення — зі стабом під іменем
        джерела (без нього сховище розширень відповідає «расширение … не найдено»);
        конфігурація — порожня ІБ.
    .DESCRIPTION
        Кличе лише запасний шлях sync для розширення, якого ще немає в базі агента (спека
        2026-09-30 §6.9). Штатний шлях — Get-KitSourceInfobase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$StubPath = $script:DefaultStubPath
    )
    $ibPath = Join-Path $WorkDir 'ib'
    switch ($Source.Type) {
        'EXTENSION'     { return (New-ExtensionInfobase -Path $ibPath -ExtensionName $Source.Key -StubPath $StubPath -MustBeUnder $WorkDir) }
        'CONFIGURATION' { return ('/F "{0}"' -f (New-V8FileInfobase -Path $ibPath -MustBeUnder $WorkDir)) }
        default         { throw "Джерело '$($Source.Key)' має тип $($Source.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION." }
    }
}

function Get-KitSourceInfobase {
    <#
    .SYNOPSIS
        База, в якій виконуються всі платформні операції джерела: база агента воркспейсу
        (спека 2026-09-17, §2, §3). Штатний шлях замість тимчасової ІБ зі стабом
        (New-KitStorageInfobase), яка лишилась лише запасним шляхом sync (спека 2026-09-30 §6.9).
    .DESCRIPTION
        Серіалізація розширення залежить від того, чи є в базі конфігурація-власник: дамп у
        ІБ зі стабом дає GUID у DesignTimeRef і явні дефолти форм, дамп у базі з власником —
        імена й опущені дефолти. Доки sync/verify дампили зі стаба, а canon — з бази агента,
        verify показував формат як зміст (ішузи #3 і #6).

        Фолбеку на порожню ІБ ТУТ немає навмисно: бази немає — зупинка з рецептом. Єдиний
        виняток — розширення, якого ще немає в самій базі агента: це рішення приймає sync за
        відповіддю платформи (спека 2026-09-30 §6.9), а не ця функція.

        Запобіжник «це не дев-база людини» лежить у Resolve-KitAgentBase (принцип 3) і
        спрацьовує саме тут: після цієї зміни викликач робить ConfigurationRepositoryUpdateCfg,
        який ЗАМІНЮЄ конфігурацію в базі, — помилкове потрапляння в базу людини коштувало б
        її роботи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Source
    )

    $ws = @($Context.Workspaces | Where-Object Path -eq $Source.Workspace) | Select-Object -First 1
    if ($null -eq $ws) {
        throw "Воркспейсу '$($Source.Workspace)' немає в контексті маніфесту — джерело '$($Source.Key)' нікуди не прив'язане."
    }

    $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
    $recipe = ("Джерело '$($Source.Key)' (truth: storage) вивантажується в контексті базової конфігурації — " +
               "потрібна база агента воркспейсу '$($ws.Path)'. Спершу: kit provision -Workspace $($ws.Path) -Apply, " +
               'потім operation=build Уніки, тоді повторіть команду.')
    if ($null -eq $ab) { throw "У v8project.yaml воркспейсу '$($ws.Path)' немає infobase:. $recipe" }
    if ($ab.Kind -eq 'file' -and -not $ab.Exists) { throw "Бази агента ще немає на диску. $recipe" }

    [pscustomobject]@{ IbSwitch = $ab.IbSwitch; User = $ab.User; Workspace = $ws.Path }
}

function Enter-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source, [string]$User = '')
    if ($Source.Type -ne 'CONFIGURATION' -or -not $script:ConfigurationStorageNeedsBind) { return $false }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
    if ($r.ExitCode -ne 0) { throw "Прив'язка тимчасової ІБ до сховища конфігурації не вдалася: $($r.Output)" }
    $true
}

function Exit-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source, [Parameter(Mandatory)][bool]$Bound, [string]$User = '')
    if (-not $Bound) { return }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments ((Get-KitRepositoryArguments -Source $Source) + @('/ConfigurationRepositoryUnbindCfg -force'))
    if ($r.ExitCode -ne 0) { Write-Host "УВАГА: не вдалося зняти прив'язку тимчасової ІБ до сховища ($($Source.StoragePath)): $($r.Output)" -ForegroundColor Red }
}

function Invoke-KitStorageUpdate {
    <#
    .SYNOPSIS
        ConfigurationRepositoryUpdateCfg -v N [-Extension] в базі агента — спільний крок
        Invoke-KitStorageCheckout і Invoke-KitStorageCheckoutViaPlatform (одна копія, не дві).
        Приватна: не експортується.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IbSwitch,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][int]$Version,
        [string]$User = ''
    )
    $ext = Get-KitExtensionArgument -Source $Source
    $upd = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @(('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $Version, $ext)))
    if ($upd.ExitCode -ne 0) {
        Assert-V8InfobaseNotBusy -Output $upd.Output -Infobase 'агента'
        # База агента є, але порожня: operation=build у неї ще не вантажив розширення, і сховище
        # відповідає «расширение … не найдено». Сирий текст платформи тут читається як проблема
        # сховища, хоча проблема в базі — той самий прийом перекладу, що в Assert-V8InfobaseNotBusy.
        if ($Source.Type -eq 'EXTENSION' -and (Test-KitExtensionNotFound -Output $upd.Output)) {
            throw ("У базі немає розширення '$($Source.Key)' — вона ще не наповнена з дерева. " +
                   "Спершу operation=build Уніки (cwd — воркспейс), тоді повторіть.`nПлатформа відповіла: $($upd.Output)")
        }
        throw "Оновлення до версії $Version не вдалося: $($upd.Output)"
    }
}

function Test-KitDumpFailure {
    <#
    .SYNOPSIS
        Чи це розпізнаваний виняток збою вивантаження з Invoke-KitStorageCheckout (UpdateCfg
        пройшов, /DumpConfigToFiles — ні). ЄДИНЕ місце розпізнавання для sync і verify.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $null -ne $ErrorRecord -and $ErrorRecord.Exception.Data.Contains('KitDumpFailure') -and [bool]$ErrorRecord.Exception.Data['KitDumpFailure']
}

function Invoke-KitStorageCheckout {
    <#
    .SYNOPSIS
        Версія сховища → порожня тека: UpdateCfg -v N [-Extension], DumpConfigToFiles, без службових файлів платформи.
        Повертає кількість файлів у дампі.
    .DESCRIPTION
        ПАСТКА ПЛАТФОРМИ (спайк B2, 8.3.27.1644): /ConfigurationRepositoryUpdateCfg -v НЕ валідує аргумент —
        `-v 1 2 3 … 65` (список замість числа) платформа приймає, повертає 0 і «успешно завершено». Тому
        -Version тут типізований [int] (скаляр, масив у нього не пролізе), а викликачі передають рівно
        $v.Version з циклу. Інваріант «одна версія — один коміт» тримає verify, не sync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IbSwitch,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][int]$Version,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [string]$User = ''
    )
    $ext = Get-KitExtensionArgument -Source $Source
    Invoke-KitStorageUpdate -IbSwitch $IbSwitch -Source $Source -Version $Version -User $User

    # /DumpConfigToFiles не видаляє зниклих об'єктів — тека завжди порожня перед дампом.
    Assert-SafeWorkPath -Path $Target -MustBeUnder $MustBeUnder -Description "тека дампу версії $Version"
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $dump = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $Target, $ext))
    if ($dump.ExitCode -ne 0) {
        Assert-V8InfobaseNotBusy -Output $dump.Output -Infobase 'агента'
        # Спека 1.3.1 §4.1, §6.1.1: збій вивантаження ПІСЛЯ успішного UpdateCfg — розпізнаваний
        # виняток; текст для людини будує викликач (sync — з командами -DumpPlatform/-SkipVersion,
        # verify — без них). Повідомлення лишається тим самим, що й до 1.3.1.
        $ex = [System.InvalidOperationException]::new("Вивантаження версії $Version не вдалося: $($dump.Output)")
        $ex.Data['KitDumpFailure'] = $true
        $ex.Data['Version'] = $Version
        $ex.Data['PlatformPath'] = (Get-V8Path)
        $ex.Data['Output'] = $dump.Output
        throw $ex
    }

    foreach ($junk in $script:PlatformJunk) {
        $j = Join-Path $Target $junk
        if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force }
    }
    # @(...) навмисно: на нулі файлів (порожній дамп — саме такий дає мокована платформа в
    # тестах sync) Get-ChildItem повертає $null, а не порожній масив, і .Count на $null під
    # Set-StrictMode -Version Latest падає "The property 'Count' cannot be found on this
    # object" — той самий клас дефекту, від якого в цьому репозиторії скрізь загортають у
    # @(...) (StorageBranch.psm1, Read-StorageReport тощо). Виявлено лише зараз (B3 Task 1,
    # раунд правок Sync.Tests.ps1): доти виконання не доходило сюди — падало раніше на
    # немокованому виклику платформи.
    @(Get-ChildItem -LiteralPath $Target -Recurse -File).Count
}

function Invoke-KitStorageCheckoutViaPlatform {
    <#
    .SYNOPSIS
        Версія сховища → порожня тека іншою (обраною) платформою: основна платформа робить
        UpdateCfg і /DumpCfg у базі агента, обрана — /LoadCfg того .cf у тимчасову файлову ІБ і
        /DumpConfigToFiles. Повертає кількість файлів у дампі (як Invoke-KitStorageCheckout).
    .DESCRIPTION
        Чому .cf, а не сховище обраною платформою: клієнт іншої версії не підключиться до
        кластера основної, а сховище читає лише основна платформа. Тому обрана платформа
        отримує лише готовий .cf і власну тимчасову ІБ (<WorkDir>\alt-ib) — ніколи ні базу
        агента (IbSwitch), ні аргументи сховища, ні користувача.

        Службові файли платформи (PlatformJunk) прибираються тут; поставку прибирає далі
        Write-KitStorageVersion — тут це не дублюється. Лише CONFIGURATION: для розширення
        кидає виняток (спека 1.3.1 §4.3; захист другого рівня, перший — у sync).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IbSwitch,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][int]$Version,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$AltV8Path,
        [string]$User = ''
    )
    if ($Source.Type -eq 'EXTENSION') {
        throw "Вивантаження іншою платформою для EXTENSION не підтримується в 1.3.1 (джерело '$($Source.Key)')."
    }

    # Крок 1: основна платформа, той самий UpdateCfg.
    Invoke-KitStorageUpdate -IbSwitch $IbSwitch -Source $Source -Version $Version -User $User

    # Крок 2: основна платформа, та сама база — /DumpCfg у .cf під WorkDir.
    $cf = Join-Path $WorkDir ('v{0}.cf' -f $Version)
    Assert-SafeWorkPath -Path $cf -MustBeUnder $WorkDir -Description "файл .cf версії $Version"
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    if (Test-Path -LiteralPath $cf) { Remove-Item -LiteralPath $cf -Force }
    $mainPath = Get-V8Path
    $dumpCf = Invoke-V8Designer -IbSwitch $IbSwitch -User $User -Arguments @(('/DumpCfg "{0}"' -f $cf))
    if ($dumpCf.ExitCode -ne 0) {
        Assert-V8InfobaseNotBusy -Output $dumpCf.Output -Infobase 'агента'
        throw "Крок DumpCfg основної платформи ($mainPath) для версії $Version не вдався: $($dumpCf.Output)"
    }
    if (-not (Test-Path -LiteralPath $cf -PathType Leaf)) {
        throw "Крок DumpCfg основної платформи ($mainPath) для версії $Version не створив файл $cf, хоча повернув код 0: $($dumpCf.Output)"
    }

    # Крок 3: обрана платформа створює тимчасову ІБ.
    $altIbPath = Join-Path $WorkDir 'alt-ib'
    Assert-SafeWorkPath -Path $altIbPath -MustBeUnder $WorkDir -Description 'тимчасова ІБ обраної платформи'
    $null = New-V8FileInfobase -Path $altIbPath -MustBeUnder $WorkDir -V8Path $AltV8Path
    $altSwitch = '/F "{0}"' -f $altIbPath

    # Крок 4: обрана платформа, без користувача: LoadCfg, потім DumpConfigToFiles у спорожнену теку.
    $load = Invoke-V8Designer -IbSwitch $altSwitch -Arguments @(('/LoadCfg "{0}"' -f $cf)) -V8Path $AltV8Path
    if ($load.ExitCode -ne 0) {
        throw "Крок LoadCfg платформи $AltV8Path для версії $Version не вдався: $($load.Output)"
    }

    Assert-SafeWorkPath -Path $Target -MustBeUnder $MustBeUnder -Description "тека дампу версії $Version"
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $dump = Invoke-V8Designer -IbSwitch $altSwitch -Arguments @(('/DumpConfigToFiles "{0}"' -f $Target)) -V8Path $AltV8Path
    if ($dump.ExitCode -ne 0) {
        throw "Крок DumpConfigToFiles платформи $AltV8Path для версії $Version не вдався: $($dump.Output)"
    }

    # Крок 5: службові файли платформи.
    foreach ($junk in $script:PlatformJunk) {
        $j = Join-Path $Target $junk
        if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force }
    }
    @(Get-ChildItem -LiteralPath $Target -Recurse -File).Count
}

Export-ModuleMember -Function Get-KitRepositoryArguments, Get-KitExtensionArgument, Test-KitExtensionNotFound, New-KitStorageInfobase, Get-KitSourceInfobase, Enter-KitStorageBind, Exit-KitStorageBind, Invoke-KitStorageCheckout, Test-KitDumpFailure, Invoke-KitStorageCheckoutViaPlatform
