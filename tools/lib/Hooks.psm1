#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"

$script:HooksDirName = '.githooks'
$script:HookNames    = @('pre-commit', 'pre-merge-commit')
$script:DefaultTemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates/githooks'))

function Get-KitHookNames {
    [CmdletBinding()]
    param()
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $script:HookNames
}

function Install-KitGitHooks {
    <#
    .SYNOPSIS
        Кладе хуки захисту storage/* у <репо>/.githooks і вмикає їх через core.hooksPath.
    .DESCRIPTION
        Копіює байт-у-байт із templates/githooks плагіна — це роздаваний артефакт, і
        Test-KitGitHooks звіряє встановлене саме з ним. Ідемпотентно: повторний виклик
        оновлює файли до шаблону.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $target = Join-Path $RepoRoot $script:HooksDirName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:HookNames) {
        $src = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Шаблон хука не знайдено: $src" }
        $dst = Join-Path $target $name
        Copy-Item -LiteralPath $src -Destination $dst -Force
        # На POSIX git не запускає хук без права виконання, і робить це МОВЧКИ. Copy-Item
        # біта не переносить, тож виставляємо явно. На Windows core.filemode = false,
        # біт там не має значення й chmod відсутній — гілка просто не виконується.
        if ($IsLinux -or $IsMacOS) {
            & chmod '+x' $dst
            if ($LASTEXITCODE -ne 0) { throw "chmod +x $dst завершився з кодом $LASTEXITCODE" }
        }
        $installed.Add($dst)
    }
    $out = git -C $RepoRoot config core.hooksPath $script:HooksDirName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git config core.hooksPath завершився з кодом ${LASTEXITCODE}: $out" }
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $installed.ToArray()
}

function Test-KitGitHooks {
    <#
    .SYNOPSIS
        Аудит для check: core.hooksPath увімкнено, обидва файли є, вміст = шаблон плагіна.
        Порівняння після нормалізації CRLF→LF: CR тут — окрема біда, і про неї каже .gitattributes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TemplatesDir = $script:DefaultTemplatesDir
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    $configured = (git -C $RepoRoot config --get core.hooksPath 2>$null | Out-String).Trim()
    if (($configured -replace '\\', '/').TrimEnd('/') -ne $script:HooksDirName) {
        $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
            "core.hooksPath не вказує на $script:HooksDirName (зараз: '$configured') — хуки захисту storage/* не працюють. " +
            "Увімкнути: git config core.hooksPath $script:HooksDirName (скіл onboarding робить це сам).")))
    }

    foreach ($name in $script:HookNames) {
        $installedPath = Join-Path $RepoRoot $script:HooksDirName $name
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            # Правка H1 (фінальне рев'ю, живий онбординг з нуля) — старе повідомлення казало
            # ЧОГО бракує, і не казало, ДЕ взяти файл: контраст із сусідніми повідомленнями
            # check (маніфест — templates/v8storagekit.yaml.example, .gitignore —
            # templates/gitignore) різкий, і саме на це вперся живий прогін. Джерело — і
            # другий крок (core.hooksPath) — тепер названо явно.
            $findings.Add((New-KitFinding -Level error -Check 'hooks' -Message (
                "Хука $script:HooksDirName/$name немає — гілки storage/* не захищені від ручного коміту. " +
                "Скопіюйте його з templates/githooks/ у теці плагіна (знайти теку: claude plugin list, або " +
                "/plugin у сесії Claude Code) у $script:HooksDirName/$name і виконайте: " +
                "git config core.hooksPath $script:HooksDirName. Або одним кроком: kit install-hooks -RepoRoot . -Apply.")))
            continue
        }
        $templatePath = Join-Path $TemplatesDir $name
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { continue }
        $a = (Get-Content -LiteralPath $installedPath -Raw) -replace "`r`n", "`n"
        $b = (Get-Content -LiteralPath $templatePath  -Raw) -replace "`r`n", "`n"
        if ($a -ne $b) {
            $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                "Хук $script:HooksDirName/$name відрізняється від шаблону плагіна ($templatePath). " +
                'Оновіть копію з templates/githooks плагіна, якщо це не свідома локальна правка.')))
        }

        # Біт виконання — окрема знахідка від вмісту. На POSIX git не запускає хук без
        # нього і робить це мовчки: check при цьому доповів би "0 знахідок", хоча кожен
        # коміт у storage/* на такому клоні пройде повз захист. Питаємо саме git, а не
        # файлову систему: на Windows core.filemode = false, і те, що бачить ФС, не має
        # стосунку до режиму, який git запише в дерево майбутнього клону.
        # -c core.quotepath=false — уніфіковано з усіма git-викликами, що читають чи
        # друкують шляхи. Цей шлях ASCII за побудовою (.githooks/pre-commit тощо), але
        # правило — kit форсує конфігурацію git за виклик завжди, щоб ніхто надалі не
        # мусив розбиратись по кожному виклику окремо, чи шлях бува не non-ASCII.
        $tracked = git -c core.quotepath=false -C $RepoRoot ls-files -s -- "$script:HooksDirName/$name" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ls-files -s $script:HooksDirName/$name завершився з кодом ${LASTEXITCODE}: $tracked" }
        $trackedLine = (@($tracked) -join "`n").Trim()
        if ($trackedLine -match '^(?<mode>\d{6})\s') {
            if ($Matches.mode -eq '100644') {
                $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                    "Хук $script:HooksDirName/$name закомічено без біта виконання (режим 100644) — " +
                    "у клоні на Linux/macOS git тихо проігнорує хук, і storage/* лишиться незахищеним. " +
                    "Полагодити: git update-index --chmod=+x $script:HooksDirName/$name і закомітити.")))
            }
        } else {
            # S2 (живий прогін задачі 11) — порожній вивід git ls-files -s означає, що файл
            # не бачить ні ІНДЕКС, ні дерево: хук скопійовано на диск (Install-KitGitHooks
            # свідомо не чіпає індекс споживача), але ще не застейджено і не закомічено.
            # Наступний клон його не отримає, і storage/* лишиться без захисту — check про
            # це мовчав. «Застейджено, але не закомічено» сюди НЕ потрапляє: git ls-files -s
            # бачить індекс, і застейджений хук уже дає непорожній рядок вище (тест-доказ —
            # Hooks.Tests.ps1, три стани хука).
            $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                "Хук $script:HooksDirName/$name лежить на диску, але не закомічений у git — " +
                'наступний клон його не отримає, і гілки storage/* лишаться без захисту. ' +
                "Закомітьте: git add $script:HooksDirName/$name і git commit. Або одним кроком (стейджить із " +
                'бітом виконання самостійно): kit install-hooks -RepoRoot . -Apply.')))
        }
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

$script:SessionHookRel = '.claude/hooks/session-start.ps1'
$script:SettingsRel    = '.claude/settings.json'

function Install-KitSessionHook {
    <#
    .SYNOPSIS
        Кладе шим і, якщо settings.json немає, — шаблон settings.json (з хуком). Наявний settings.json не чіпає.
    .DESCRIPTION
        На відміну від Install-KitGitHooks (git-хуки, core.hooksPath), це хук Claude Code
        (спека §7): живе в .claude/settings.json репозиторію-споживача, а не в плагіні —
        hooks/hooks.json плагін навмисно не оголошує (інакше шим спрацьовував би в кожній
        сесії, де встановлено плагін, — і в не-1С проєктах теж).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates')))
    $shimDst = Join-Path $RepoRoot $script:SessionHookRel
    New-Item -ItemType Directory -Path (Split-Path -Parent $shimDst) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplatesDir 'hooks/session-start.ps1') -Destination $shimDst -Force
    $installed = @($shimDst)
    $settingsDst = Join-Path $RepoRoot $script:SettingsRel
    if (-not (Test-Path -LiteralPath $settingsDst -PathType Leaf)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsDst) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $TemplatesDir 'settings.json') -Destination $settingsDst -Force
        $installed += $settingsDst
    }
    # Без коми: викликачі (install-hooks) загортають у @(…) — див. F7.
    $installed
}

function Test-KitSessionHook {
    <#
    .SYNOPSIS
        Аудит для check (спека §7): шим на місці й = шаблон плагіна; settings.json оголошує hooks.SessionStart.
    .DESCRIPTION
        Порядок навмисний (рев'ю B4 Task 4, Critical C2): спершу читаємо settings.json і
        обчислюємо $hasHook, ПОТІМ перевіряємо сам шим — відсутність шима коштує по-різному
        залежно від того, чи хук уже оголошено. Якщо оголошено (hooks.SessionStart кличе
        .claude/hooks/session-start.ps1), а файла немає — це не «онбординг ще не дійшов сюди»
        (info), а зламаний репозиторій: pwsh -NoProfile -File на неіснуючий шлях завершується
        кодом 64 з банером usage на КОЖНОМУ старті сесії (перевірено запуском) — error. Якщо
        хук не оголошений — шима теж немає сенсу мати, і відсутність лишається info, як і було.

        Битий settings.json (I4) — warn, не error: це помилка конфігурації Claude Code, а не
        суперечність репозиторію в сенсі §5, і error тут зупиняв би session-check ПО СХОВИЩАХ
        (код 1, «Сигнали не обчислювались») через випадкову зайву кому в чужому файлі. Друга
        знахідка «немає hooks.SessionStart» на той самий факт (парсинг не вдався) навмисно не
        додається — інакше один битий файл давав би дві знахідки про одну причину.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates')))
    $findings = [System.Collections.Generic.List[object]]::new()

    $settings = Join-Path $RepoRoot $script:SettingsRel
    $hasHook = $false
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        $parseFailed = $false
        try {
            $json = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'hooks' -and $json.hooks.PSObject.Properties.Name -contains 'SessionStart') {
                $hasHook = [bool](@($json.hooks.SessionStart | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*session-start.ps1*' }).Count)
            }
        } catch {
            $parseFailed = $true
            $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "$script:SettingsRel не читається як JSON: $($_.Exception.Message) — виправте файл, щоб дозволи й хук старту сесії знову діяли."))
        }
        if (-not $hasHook -and -not $parseFailed) {
            $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "У $script:SettingsRel немає hooks.SessionStart з командою .claude/hooks/session-start.ps1 — шим не запускатиметься (зразок: templates/settings.json)."))
        }
    }

    $shim = Join-Path $RepoRoot $script:SessionHookRel
    $template = Join-Path $TemplatesDir 'hooks/session-start.ps1'
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
        if ($hasHook) {
            $findings.Add((New-KitFinding -Level error -Check 'hook-shim' -Message (
                "$script:SettingsRel оголошує hooks.SessionStart на $script:SessionHookRel, а файла немає — " +
                'кожен старт сесії в цьому репозиторії падає на pwsh -File неіснуючого шляху (код 64). ' +
                "Покладіть шим із templates/hooks/session-start.ps1 плагіна в $script:SessionHookRel. " +
                'Або одним кроком: kit install-hooks -RepoRoot . -Apply.')))
        } else {
            $findings.Add((New-KitFinding -Level info -Check 'hook-shim' -Message ("Хук старту сесії не встановлено ($script:SessionHookRel) — сесія не отримає стан сховищ; onboarding кладе його з templates/hooks/, або одним кроком: kit install-hooks -RepoRoot . -Apply.")))
        }
    } elseif (Test-Path -LiteralPath $template -PathType Leaf) {
        $a = (Get-Content -LiteralPath $shim -Raw) -replace "`r`n", "`n"
        $b = (Get-Content -LiteralPath $template -Raw) -replace "`r`n", "`n"
        if ($a -ne $b) { $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "Шим $script:SessionHookRel відрізняється від шаблону плагіна (templates/hooks/session-start.ps1) — оновіть копію.")) }
    }

    # Без коми: check і тести загортають у @(…) — див. F7.
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitHookNames, Install-KitGitHooks, Test-KitGitHooks, Install-KitSessionHook, Test-KitSessionHook
