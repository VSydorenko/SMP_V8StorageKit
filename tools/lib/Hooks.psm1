#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"

$script:HooksDirName = '.githooks'
$script:HookNames    = @('pre-commit', 'pre-merge-commit')
$script:DefaultTemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates/githooks'))

function Get-KitHookNames {
    [CmdletBinding()]
    param()
    # Без coma-wrap: усі виклики загортають результат у @(...), а @() поверх коми бачить один
    # елемент — вкладений масив.
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
    # Без coma-wrap — як у Get-KitHookNames.
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
            # Повідомлення каже не лише ЧОГО бракує, а й ДЕ взяти файл і другий крок (core.hooksPath).
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
        # -c core.quotepath=false — правило kit на кожен git-виклик зі шляхами, навіть ASCII.
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
            # git commit --only <шляхи> НЕ бере індекс — перечитує файл із диска, і на Windows
            # (core.filemode=false) пише 100644, хоч в індексі лишається 100755. Індекс тоді бреше
            # про те, що отримає клон, — питаємо сам коміт.
            if ($Matches.mode -eq '100755') {
                $head = git -c core.quotepath=false -C $RepoRoot ls-tree HEAD -- "$script:HooksDirName/$name" 2>$null
                if ($LASTEXITCODE -eq 0 -and "$head" -match '^100644\s') {
                    $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                        "Хук $script:HooksDirName/$name у коміті HEAD без біта виконання (100644), хоч в індексі 100755 — так буває після " +
                        'git commit --only (перечитує файл з диска). Клон на Linux/macOS тихо проігнорує хук. Полагодити: закомітьте індекс ' +
                        'командою git commit без --only і без шляхів (індекс уже правильний).')))
                }
            }
        } else {
            # Порожній вивід git ls-files -s: хук є на диску, але не застейджений і не закомічений —
            # наступний клон його не отримає. «Застейджено, але не закомічено» сюди НЕ потрапляє:
            # ls-files -s бачить індекс (три стани хука тримає Hooks.Tests.ps1).
            $findings.Add((New-KitFinding -Level warn -Check 'hooks' -Message (
                "Хук $script:HooksDirName/$name лежить на диску, але не закомічений у git — " +
                'наступний клон його не отримає, і гілки storage/* лишаться без захисту. ' +
                "Закомітьте: git add $script:HooksDirName/$name і git commit. Або одним кроком (стейджить із " +
                'бітом виконання самостійно): kit install-hooks -RepoRoot . -Apply.')))
        }
    }

    # Без coma-wrap — як у Get-KitHookNames.
    $findings.ToArray()
}

$script:SessionHookRel = '.claude/hooks/session-start.ps1'
$script:SettingsRel    = '.claude/settings.json'

function Install-KitSettings {
    <#
    .SYNOPSIS
        Кладе шаблон .claude/settings.json (дозволи), якщо файла ще немає. Наявний не чіпає.
    .DESCRIPTION
        Хука старту сесії тут немає: його поставляє сам плагін (hooks/hooks.json),
        а споживач не несе ні шима, ні розділу hooks у settings.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../templates')))
    $settingsDst = Join-Path $RepoRoot $script:SettingsRel
    if (Test-Path -LiteralPath $settingsDst -PathType Leaf) { return @() }
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsDst) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $TemplatesDir 'settings.json') -Destination $settingsDst -Force
    # Без коми: викликачі (install-hooks) загортають у @(…).
    $settingsDst
}

function Test-KitLegacySessionHook {
    <#
    .SYNOPSIS
        Аудит для check: старий проєктний хук старту сесії (до 1.6.0) — розділ hooks.SessionStart
        з командою на session-start.ps1 у .claude/settings.json і/або файл-шим
        .claude/hooks/session-start.ps1 — знаходить і радить прибрати.
    .DESCRIPTION
        Хук тепер у плагіні (hooks/hooks.json). Старий проєктний хук лишався б другим
        екземпляром: «Стан сховищ» двічі. Одна знахідка warn називає все знайдене —
        і settings.json, і файл-шим, — з рецептом прибрати обидва. Нічого не знайдено — тиша.

        Битий settings.json — окрема warn: перевірити, чи є в ньому старий хук, неможливо, і
        мовчання читалося б як «старого хука немає». error тут зупиняв би session-check по
        сховищах через випадкову кому в чужому файлі, тому рівень warn.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $findings = [System.Collections.Generic.List[object]]::new()

    $found = [System.Collections.Generic.List[string]]::new()
    $settings = Join-Path $RepoRoot $script:SettingsRel
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'hooks' -and $json.hooks.PSObject.Properties.Name -contains 'SessionStart') {
                $legacy = @($json.hooks.SessionStart | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*session-start.ps1*' })
                if ($legacy.Count) { $found.Add("$script:SettingsRel (hooks.SessionStart з командою на session-start.ps1)") }
            }
        } catch {
            $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message "$script:SettingsRel не читається як JSON: $($_.Exception.Message) — виправте файл; доки він битий, kit не може перевірити, чи немає в ньому старого хука старту сесії."))
        }
    }
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $script:SessionHookRel) -PathType Leaf) { $found.Add($script:SessionHookRel) }

    if ($found.Count) {
        $findings.Add((New-KitFinding -Level warn -Check 'hook-shim' -Message (
            "Старий проєктний хук старту сесії: $($found -join '; '). Тепер цей хук поставляє сам плагін — «Стан сховищ» з'явиться двічі. " +
            "Прибрати обидва: розділ hooks.SessionStart з командою на session-start.ps1 у $script:SettingsRel і файл $script:SessionHookRel (git rm).")))
    }

    # Без коми: check і тести загортають у @(…).
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitHookNames, Install-KitGitHooks, Test-KitGitHooks, Install-KitSettings, Test-KitLegacySessionHook
