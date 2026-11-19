# Раннер Уніки (v8-runner) як інструмент kit (спека 2026-11-19 §3.6, §4.2 п.4, п.5, п.20).
# Єдине місце, де kit запускає v8-runner: Start-KitRunnerProcess — єдиний запуск процесу, а
# Invoke-KitRunner — єдина точка моку для тестів. Фальшивий раннер у тестах-підпроцесах
# підміняється явним параметром -RunnerPath, не змінною оточення: production не читає нічого
# заради тестів, а типове значення беремо з реєстру плагінів.

Import-Module (Join-Path $PSScriptRoot 'Environment.psm1')

function Get-KitRunnerPath {
    <#
    .SYNOPSIS
        Шлях до v8-runner.exe із встановленої Уніки.
    .DESCRIPTION
        Раннер лежить у <installPath>/bin/win-x64/v8-runner-windows-x86_64/v8-runner.exe
        [вимір: кеш unica/0.16.0]. Запасного шляху (Get-V8Path, пошук по кешу) немає:
        кеш тримає кілька версій Уніки, і пошук знайшов би не ту.
    .PARAMETER InstalledPluginsPath
        Реєстр плагінів; за замовчуванням реєстр поточного користувача. Тести-підпроцеси
        віддають сюди фальшивий реєстр без раннера.
    #>
    [CmdletBinding()]
    param([string]$InstalledPluginsPath)

    $lookup = @{}
    if ($InstalledPluginsPath) { $lookup.InstalledPluginsPath = $InstalledPluginsPath }
    $unica = Get-UnicaInstallation @lookup

    if (-not $unica.Installed) {
        throw "Раннер не знайдено: Unica не встановлена. $($unica.Reason)"
    }
    if (-not $unica.PathExists) {
        throw "Раннер не знайдено: $($unica.Reason)"
    }

    $runner = [System.IO.Path]::Combine($unica.InstallPath, 'bin', 'win-x64', 'v8-runner-windows-x86_64', 'v8-runner.exe')
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "Раннер не знайдено: у встановленій Уніці ($($unica.InstallPath)) немає файла $runner"
    }
    $runner
}

function ConvertTo-KitRunnerArgLine {
    param([Parameter(Mandatory)][string[]]$Arguments)
    ($Arguments | ForEach-Object {
        # Правила CommandLineToArgvW: бекслеші перед лапкою подвоюються разом з екрануванням
        # лапки, а бекслеші наприкінці аргументу — перед закривальною лапкою.
        if ($_ -match '[\s"]' -or $_ -eq '') {
            $escaped = $_ -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"{0}"' -f $escaped
        } else { $_ }
    }) -join ' '
}

function Start-KitRunnerProcess {
    # Єдиний запуск процесу раннера. Вивід — у файли, а не в пайпи: синхронне читання пайпа
    # на великому виводі дає дедлок. Файл — що завгодно, що запускає CreateProcess (.exe, .cmd).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
        throw "Раннер не знайдено: $RunnerPath"
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "v8runner-$stamp.out")
    $errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "v8runner-$stamp.err")
    try {
        $proc = Start-Process -FilePath $RunnerPath `
            -ArgumentList (ConvertTo-KitRunnerArgLine -Arguments $Arguments) `
            -WorkingDirectory $WorkingDirectory `
            -Wait -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = if (Test-Path -LiteralPath $outFile) { (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) } else { '' }
        $stderr = if (Test-Path -LiteralPath $errFile) { (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8) } else { '' }
        [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = [string]$stdout
            Stderr   = [string]$stderr
        }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-KitRunnerVersion {
    <#
    .SYNOPSIS
        Версія раннера: з рядка 'v8-runner 0.18.1' від --version береться '0.18.1'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunnerPath)

    $run = Start-KitRunnerProcess -RunnerPath $RunnerPath -Arguments @('--version') `
        -WorkingDirectory ([System.IO.Directory]::GetCurrentDirectory())
    if ($run.Stdout -notmatch '(?m)^v8-runner\s+(?<v>\d+(?:\.\d+)+\S*)\s*$') {
        throw "Раннер $RunnerPath на --version відповів не рядком 'v8-runner <версія>': код виходу $($run.ExitCode), вивід: $($run.Stdout.Trim()) $($run.Stderr.Trim())"
    }
    $Matches.v
}

function Invoke-KitRunner {
    <#
    .SYNOPSIS
        Запускає раннер з --config воркспейсу й --json-message, повертає розібрану відповідь.
    .DESCRIPTION
        Єдина точка запуску раннера й точка моку для тестів. Успіх — поле ok відповіді, а не
        код виходу: на помилці конфігу раннер 0.18.1 відповідає ok:false (код виходу при
        цьому 0 чи 2 — на нього не покладаємось). Повертає об'єкт відповіді: ok, data,
        error, warnings. Не JSON на виході — виняток із сирим виводом.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $config = Join-Path $WorkingDirectory 'v8project.yaml'
    $all = @('--config', $config) + $Arguments + @('--json-message')
    $run = Start-KitRunnerProcess -RunnerPath $RunnerPath -Arguments $all -WorkingDirectory $WorkingDirectory

    try {
        $response = $run.Stdout | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Раннер на '$($Arguments -join ' ')' відповів не JSON-ом: код виходу $($run.ExitCode), вивід: $($run.Stdout.Trim()) $($run.Stderr.Trim())"
    }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['ok']) {
        throw "Відповідь раннера на '$($Arguments -join ' ')' без поля ok: $($run.Stdout.Trim())"
    }
    $response
}

function Get-KitRunnerFailureText {
    param([Parameter(Mandatory)]$Response)
    # Текст зупинки — data.message раннера дослівно; запасний — error.message.
    if ($Response.PSObject.Properties['data'] -and $Response.data -and $Response.data.PSObject.Properties['message'] -and $Response.data.message) {
        return [string]$Response.data.message
    }
    if ($Response.PSObject.Properties['error'] -and $Response.error -and $Response.error.PSObject.Properties['message']) {
        return [string]$Response.error.message
    }
    '(раннер не пояснив причини)'
}

function Get-KitAgentPlatform {
    <#
    .SYNOPSIS
        Шлях до платформи 1С, яку раннер вибрав для воркспейсу (data.selected.designer.path).
    .DESCRIPTION
        platforms вимагає infobases.origin у v8project.local.yaml; без нього раннер відповідає
        ok:false 'no infobase is selected' — цей текст іде у виняток дослівно, шляху не повертаємо.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [string]$RunnerPath
    )

    if (-not $RunnerPath) { $RunnerPath = Get-KitRunnerPath }
    $response = Invoke-KitRunner -RunnerPath $RunnerPath -Arguments @('platforms') -WorkingDirectory $Project.Directory
    if (-not $response.ok) {
        throw "Раннер не визначив платформу для воркспейсу $($Project.Directory): $(Get-KitRunnerFailureText -Response $response)"
    }
    $path = $null
    if ($response.data -and $response.data.selected -and $response.data.selected.designer) { $path = $response.data.selected.designer.path }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Раннер відповів ok, але без data.selected.designer.path: платформу для воркспейсу $($Project.Directory) не вибрано."
    }
    [string]$path
}

function Invoke-KitAgentRelease {
    <#
    .SYNOPSIS
        agent release: відпускає базу агента (released, disconnected). Нічого не запускає й не пише в базу.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [string]$RunnerPath
    )

    if (-not $RunnerPath) { $RunnerPath = Get-KitRunnerPath }
    $response = Invoke-KitRunner -RunnerPath $RunnerPath -Arguments @('agent', 'release') -WorkingDirectory $Project.Directory
    if (-not $response.ok) {
        throw "Раннер не виконав agent release для воркспейсу $($Project.Directory): $(Get-KitRunnerFailureText -Response $response)"
    }
    if (-not $response.data -or -not $response.data.PSObject.Properties['released']) {
        throw "Відповідь раннера на agent release ok, але без data.released: $($response | ConvertTo-Json -Depth 6 -Compress)"
    }
    [pscustomobject]@{
        released     = [bool]$response.data.released
        disconnected = [bool]$response.data.disconnected
    }
}

# Перевірена мінорна версія раннера (спека 2026-11-19 §4.2 п.4): Уніка 0.16 несе v8-runner 0.18.x.
$script:RunnerTestedMinor = [version]'0.18'

function Get-KitRunnerVerdict {
    <#
    .SYNOPSIS
        Висновок про раннер: ok | warn (мінор не 0.18 чи версію не розібрано) | error (раннера немає чи він не відповідає).
    .DESCRIPTION
        Шлях — явний -RunnerPath або, коли він порожній, Get-KitRunnerPath з того самого реєстру плагінів
        (-InstalledPluginsPath), що й пошук Уніки: тест, який забув -RunnerPath, не знайде раннера у
        фальшивому реєстрі й почервоніє (спека §4.2 п.20), а не піде до справжньої Уніки машини.
        Збірку форку від upstream не розрізняє: значущі лише мажор і мінор.
        Повертає {Level; Message; Version}; Version порожня, коли раннер не відповів.
    #>
    [CmdletBinding()]
    param([string]$RunnerPath, [string]$InstalledPluginsPath)

    $notice = 'sync, verify і provision без раннера не працюють (kit dump працює й без нього — він бере платформу напряму).'
    $runner = $RunnerPath
    try {
        if (-not $runner) {
            $lookup = @{}
            if ($InstalledPluginsPath) { $lookup.InstalledPluginsPath = $InstalledPluginsPath }
            $runner = Get-KitRunnerPath @lookup
        }
        $version = Get-KitRunnerVersion -RunnerPath $runner
    } catch {
        return [pscustomobject]@{ Level = 'error'; Version = ''; Message = "Раннер Уніки недоступний: $($_.Exception.Message) $notice" }
    }
    if ($version -notmatch '^(?<maj>\d+)\.(?<min>\d+)') {
        return [pscustomobject]@{ Level = 'warn'; Version = $version; Message = "Версію раннера '$version' не розібрано — kit перевірено на v8-runner 0.18.x." }
    }
    $minor = [version]('{0}.{1}' -f $Matches['maj'], $Matches['min'])
    if ($minor -ne $script:RunnerTestedMinor) {
        return [pscustomobject]@{ Level = 'warn'; Version = $version; Message = ("Раннер v8-runner $version — kit перевірено на 0.18.x: перед роботою звірте контракт " +
            'за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit).') }
    }
    [pscustomobject]@{ Level = 'ok'; Version = $version; Message = "Раннер v8-runner $version." }
}

Export-ModuleMember -Function Get-KitRunnerPath, Get-KitRunnerVersion, Get-KitRunnerVerdict, Invoke-KitRunner, Get-KitAgentPlatform, Invoke-KitAgentRelease
