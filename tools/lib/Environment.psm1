#Requires -Version 7
<#
.SYNOPSIS
    Перевірки середовища, потрібного kit: git, Pester, встановлення плагіна unica.
.DESCRIPTION
    Модуль навмисно НЕ імпортує V8.psm1 і не шукає платформу сам. Причина — двояка.

    По-перше, пошук платформи вже живе в Get-V8Path (tools/lib/V8.psm1), і дублювати
    його тут означало б два місця, які треба тримати синхронними.

    По-друге, вкладений Import-Module -Force усередині модуля вже був джерелом дефекту
    (docs/follow-ups.md §5: вкладений імпорт скасовував попередній, і probe існує саме
    як регресія на це). Тому композиція звітів — робота скрипта check-environment.ps1,
    який імпортує обидва модулі на одному рівні, а тут лишаються лише незалежні,
    тестовані без платформи перевірки.
#>

Set-StrictMode -Version Latest

function Test-EnvHasProperty {
    <#
    .SYNOPSIS
        Чи має об'єкт названу властивість — без винятку під Set-StrictMode -Version Latest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    return [bool]($InputObject.PSObject.Properties.Name -contains $Name)
}

function New-EnvironmentCheck {
    <#
    .SYNOPSIS
        Один рядок звіту про середовище.
    .DESCRIPTION
        Category — не косметика: вона каже, що саме перестає працювати без цієї
        складової. 'Конвеєр' — скрипти не запустяться взагалі (з 1.6.0 сюди ж Уніка й її
        раннер: sync, verify і provision без них не працюють); 'Розробка kit' — не
        прогнати тести цього репозиторію.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Конвеєр', 'Розробка kit')][string]$Category,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail
    )

    return [pscustomobject]@{
        Name     = $Name
        Category = $Category
        Ok       = $Ok
        Detail   = $Detail
    }
}

function Get-UnicaInstallation {
    <#
    .SYNOPSIS
        Читає реєстр встановлених плагінів Claude Code і шукає в ньому плагін unica.
    .DESCRIPTION
        Реєстр — ~/.claude/plugins/installed_plugins.json. Ключі в ньому мають форму
        '<плагін>@<маркетплейс>' (наприклад 'unica@unica'), тож ім'я плагіна — частина
        до '@', а не ключ цілком.

        Функція нічого не кидає на відсутньому чи зіпсованому реєстрі: її робота —
        доповісти стан, а не зупинити прогін. Кожна причина невдачі повертається текстом
        у Reason, щоб діагностика не зводилась до «не знайдено».

        PathExists окремо від Installed навмисно: запис у реєстрі й наявність теки на
        диску розходяться (вручну видалений кеш, перенесений профіль), і мовчазне
        злиття двох станів в один сховало б саме той випадок, який найважче пояснити.
    .PARAMETER InstalledPluginsPath
        Шлях до реєстру. Параметр існує для тестів — за замовчуванням береться реєстр
        поточного користувача.
    .PARAMETER PluginName
        Ім'я плагіна до символу '@'.
    #>
    [CmdletBinding()]
    param(
        [string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json'),
        [string]$PluginName = 'unica'
    )

    $result = [pscustomobject]@{
        Installed   = $false
        Version     = ''
        InstallPath = ''
        PathExists  = $false
        Reason      = ''
    }

    if (-not (Test-Path -LiteralPath $InstalledPluginsPath)) {
        $result.Reason = "Реєстр плагінів не знайдено: $InstalledPluginsPath"
        return $result
    }

    try {
        $raw = Get-Content -LiteralPath $InstalledPluginsPath -Raw -Encoding utf8
        $json = $raw | ConvertFrom-Json
    } catch {
        $result.Reason = "Реєстр плагінів не читається як JSON ($InstalledPluginsPath): $($_.Exception.Message)"
        return $result
    }

    if (-not (Test-EnvHasProperty -InputObject $json -Name 'plugins')) {
        $result.Reason = "У реєстрі $InstalledPluginsPath немає розділу 'plugins'"
        return $result
    }

    $entry = $json.plugins.PSObject.Properties |
        Where-Object { ($_.Name -split '@', 2)[0] -eq $PluginName } |
        Select-Object -First 1

    if (-not $entry) {
        $result.Reason = "Плагін '$PluginName' не значиться в реєстрі $InstalledPluginsPath"
        return $result
    }

    $installs = @($entry.Value)
    if ($installs.Count -eq 0) {
        $result.Reason = "Плагін '$PluginName' є в реєстрі, але без жодного запису про встановлення"
        return $result
    }

    $install = $installs[0]
    $result.Installed = $true

    if (Test-EnvHasProperty -InputObject $install -Name 'version') {
        $result.Version = [string]$install.version
    }

    if (Test-EnvHasProperty -InputObject $install -Name 'installPath') {
        $result.InstallPath = [string]$install.installPath
    }

    if ([string]::IsNullOrWhiteSpace($result.InstallPath)) {
        $result.Reason = "Запис про '$PluginName' є, але без installPath"
        return $result
    }

    $result.PathExists = Test-Path -LiteralPath $result.InstallPath
    if (-not $result.PathExists) {
        $result.Reason = "Реєстр вказує на теку, якої немає на диску: $($result.InstallPath)"
    }

    return $result
}

function Test-KitGitVersionSupported {
    <#
    .SYNOPSIS
        Чи достатня версія git для kit: злиття дзеркала йде через merge-tree --write-tree (спека 2026-10-04 §4.2).
    .DESCRIPTION
        Мінімум 2.38.0: Documentation/git-merge-tree.txt у тегу v2.38.0 описує --write-tree, --name-only,
        -z і --allow-unrelated-histories, у v2.37.0 — жодного.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionText, [version]$Minimum = '2.38')
    if ($VersionText -notmatch 'git version (?<v>\d+\.\d+(\.\d+)?)') { return $false }
    [version]$Matches['v'] -ge $Minimum
}

function Get-GitAvailability {
    <#
    .SYNOPSIS
        Чи доступний git у PATH і якої він версії.
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{
        Available = $false
        Version   = ''
        Reason    = ''
        Supported = $false
        Minimum   = '2.38'
    }

    $cmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $result.Reason = 'git не знайдено в PATH'
        return $result
    }

    try {
        $result.Version = (& git --version 2>&1 | Select-Object -First 1).ToString().Trim()
        $result.Available = $true
        $result.Supported = Test-KitGitVersionSupported -VersionText $result.Version
    } catch {
        $result.Reason = "git знайдено ($($cmd.Source)), але 'git --version' не виконалась: $($_.Exception.Message)"
    }

    return $result
}

function Get-PesterAvailability {
    <#
    .SYNOPSIS
        Чи встановлений Pester потрібної мажорної версії.
    .DESCRIPTION
        Run-Tests.ps1 вимагає -MinimumVersion 5.0, тож перевірка тримає ту саму межу.
        Наявність старішого Pester — окремий випадок від повної відсутності: вона
        пояснює, чому Import-Module у Run-Tests.ps1 упаде, хоча модуль «є».
    #>
    [CmdletBinding()]
    param([version]$MinimumVersion = '5.0')

    $result = [pscustomobject]@{
        Available = $false
        Version   = ''
        Reason    = ''
    }

    $modules = @(Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue)
    if ($modules.Count -eq 0) {
        $result.Reason = 'Модуль Pester не встановлено'
        return $result
    }

    $newest = $modules | Sort-Object Version -Descending | Select-Object -First 1
    $result.Version = [string]$newest.Version

    if ($newest.Version -lt $MinimumVersion) {
        $result.Reason = "Знайдено Pester $($newest.Version), а Run-Tests.ps1 вимагає щонайменше $MinimumVersion"
        return $result
    }

    $result.Available = $true
    return $result
}

# Перевірена мінорна версія Уніки (спека 2026-11-19 §4.2 п.4): будь-який патч 0.16.x — норма.
$script:UnicaTestedMinor = [version]'0.16'

function Get-KitUnicaVersionVerdict {
    <#
    .SYNOPSIS
        Висновок про версію встановленої Уніки: ok | warn (новіша чи нерозбірна) | error (немає чи < 0.16).
    .DESCRIPTION
        Kit 1.6.0 говорить лише мовою Уніки 0.16 (спека 2026-11-19 §4.2 п.4): на старішій скіли й шаблони
        посилаються на інструменти й форми операцій, яких там немає, а Уніка, новіша за перевірену, могла
        знову змінити контракт — тоді спершу процедура звірки docs/unica-contract.md.

        Без Уніки sync, verify і provision не працюють: раннер, яким вони запускають платформу, береться
        з її встановлення (§3.6 п.2, §4.2 п.5). Тому відсутня Уніка — error, а не info, як було в 1.5.0.
        kit dump без неї працює (бере платформу напряму, Get-V8Path), але це виняток, а не правило.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Installation)

    if (-not $Installation.Installed -or -not $Installation.PathExists) {
        return [pscustomobject]@{ Level = 'error'; Message = ("Плагін unica не знайдено ($($Installation.Reason)): sync, verify і provision беруть раннер із його встановлення " +
            'й без нього не працюють (kit dump працює й без Уніки — він бере платформу напряму). ' +
            'Встановіть: claude plugin marketplace add IngvarConsulting/unica-marketplace; claude plugin install unica@unica.') }
    }
    $raw = [string]$Installation.Version
    if ($raw -notmatch '^(?<maj>\d+)\.(?<min>\d+)(\.\d+)?') {
        return [pscustomobject]@{ Level = 'warn'; Message = "Версію плагіна unica '$raw' не розібрано — kit перевірено на Уніці 0.16.x." }
    }
    $minor = [version]('{0}.{1}' -f $Matches['maj'], $Matches['min'])
    if ($minor -lt $script:UnicaTestedMinor) {
        return [pscustomobject]@{ Level = 'error'; Message = ("Плагін unica $raw старіший за 0.16: kit говорить лише мовою Уніки 0.16 (v8-runner 0.18), " +
            'старого словника в скілах і шаблонах більше немає. Оновіть Уніку — claude plugin marketplace update unica; ' +
            'claude plugin update unica@unica — і почніть нову сесію (оновлення перемикає всі репозиторії машини).') }
    }
    if ($minor -gt $script:UnicaTestedMinor) {
        return [pscustomobject]@{ Level = 'warn'; Message = ("Плагін unica $raw новіший за перевірену 0.16.x: перед роботою звірте контракт " +
            'за процедурою docs/unica-contract.md (у репозиторії плагіна v8storagekit).') }
    }
    [pscustomobject]@{ Level = 'ok'; Message = "Плагін unica $raw." }
}

Export-ModuleMember -Function Test-EnvHasProperty, New-EnvironmentCheck, Get-UnicaInstallation, Get-KitUnicaVersionVerdict, Test-KitGitVersionSupported, Get-GitAvailability, Get-PesterAvailability
