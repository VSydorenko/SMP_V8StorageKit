#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/V8.psm1"

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

function New-KitStorageInfobase {
    <#
    .SYNOPSIS
        Тимчасова ІБ під <WorkDir>/ib для читання сховища: розширення — зі стабом під іменем
        джерела (без нього сховище розширень відповідає «расширение … не найдено»);
        конфігурація — порожня ІБ.
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

function Enter-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source)
    if ($Source.Type -ne 'CONFIGURATION' -or -not $script:ConfigurationStorageNeedsBind) { return $false }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
    if ($r.ExitCode -ne 0) { throw "Прив'язка тимчасової ІБ до сховища конфігурації не вдалася: $($r.Output)" }
    $true
}

function Exit-KitStorageBind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IbSwitch, [Parameter(Mandatory)]$Source, [Parameter(Mandatory)][bool]$Bound)
    if (-not $Bound) { return }
    $r = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) + @('/ConfigurationRepositoryUnbindCfg -force'))
    if ($r.ExitCode -ne 0) { Write-Host "УВАГА: не вдалося зняти прив'язку тимчасової ІБ до сховища ($($Source.StoragePath)): $($r.Output)" -ForegroundColor Red }
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
        [Parameter(Mandatory)][string]$MustBeUnder
    )
    $ext = Get-KitExtensionArgument -Source $Source
    $upd = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments ((Get-KitRepositoryArguments -Source $Source) +
        @(('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $Version, $ext)))
    if ($upd.ExitCode -ne 0) { throw "Оновлення до версії $Version не вдалося: $($upd.Output)" }

    # /DumpConfigToFiles не видаляє зниклих об'єктів — тека завжди порожня перед дампом.
    Assert-SafeWorkPath -Path $Target -MustBeUnder $MustBeUnder -Description "тека дампу версії $Version"
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $dump = Invoke-V8Designer -IbSwitch $IbSwitch -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $Target, $ext))
    if ($dump.ExitCode -ne 0) { throw "Вивантаження версії $Version не вдалося: $($dump.Output)" }

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

Export-ModuleMember -Function Get-KitRepositoryArguments, Get-KitExtensionArgument, New-KitStorageInfobase, Enter-KitStorageBind, Exit-KitStorageBind, Invoke-KitStorageCheckout
