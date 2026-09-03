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
                "git config core.hooksPath $script:HooksDirName.")))
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
        $tracked = git -C $RepoRoot ls-files -s -- "$script:HooksDirName/$name" 2>&1
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
                "Закомітьте: git add $script:HooksDirName/$name і git commit.")))
        }
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

Export-ModuleMember -Function Get-KitHookNames, Install-KitGitHooks, Test-KitGitHooks
