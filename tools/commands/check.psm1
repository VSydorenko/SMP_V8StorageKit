#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Get-KitConfigurationName {
    <#
    .SYNOPSIS
        <Name> кореневого об'єкта з Configuration.xml — перше входження, як у Designer XML.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text -match '<Name>(?<n>[^<]+)</Name>') { return $Matches['n'].Trim() }
    $null
}

function Invoke-KitCheck {
    <#
    .SYNOPSIS
        Повний аудит репозиторію-споживача (спека §5): маніфест ↔ v8project.yaml ↔ .gitignore ↔
        .gitattributes ↔ Configuration.xml ↔ інваріанти storage/* ↔ накладки ↔ хуки.
        Нічого не змінює. Код 1 — є хоч одна помилка.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Quiet
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Context.Findings) { $findings.Add($f) }
    $add = { param([string]$Level, [string]$Check, [string]$Message) $findings.Add((New-KitFinding -Level $Level -Check $Check -Message $Message)) }
    $root = $Context.RepoRoot

    if ($Context.Manifest) {
        $all = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        $byTruth = (@($all | Group-Object Truth | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Count)" })) -join ', '
        & $add info manifest ("Маніфест: $($Context.Kind) $($Context.Label), головна гілка $($Context.MainBranch), " +
            "воркспейсів $($Context.Workspaces.Count), джерел у перевірці $($all.Count) ($byTruth).")

        # §2.3 — ключі truth: storage унікальні в межах репозиторію (гілка storage/<ключ> одна).
        $dups = @($Context.Workspaces | ForEach-Object { $_.Sources } | Where-Object Truth -eq 'storage' |
            Group-Object Key | Where-Object Count -gt 1)
        foreach ($d in $dups) {
            & $add error unique-keys ("Ключ '$($d.Name)' з truth: storage повторюється у воркспейсах $($d.Group.Workspace -join ', ') — " +
                "гілка storage/$($d.Name) була б спільною. Перейменуйте source-set в одному з них (§2.3).")
        }

        foreach ($src in $all) {
            $tag = "$($src.Workspace)/$($src.Key)"

            # §2.6 — усі дерева платформи, ЩО ПОТРАПЛЯЮТЬ У GIT, під -text. Питаємо git, не
            # читаємо .gitattributes. truth: vendor гітігноровано за визначенням, конверсія
            # на checkout йому не загрожує, і шаблон gitattributes навмисно не має для нього
            # правила — для vendor інваріант інший, нижче (check-ignore).
            if ($src.Truth -ne 'vendor') {
                try {
                    if (-not (Test-GitTextPolicy -RepoRoot $root -Path $src.RepoPath)) {
                        & $add error gitattributes ("$tag`: дерево '$($src.RepoPath)' не виведено з-під конверсії кінців рядків — " +
                            "додайте в .gitattributes рядок '$($src.RepoPath)/** -text' (docs/text-policy.md).")
                    }
                } catch {
                    & $add error gitattributes "$tag`: git check-attr не відповів: $($_.Exception.Message)"
                }

                # Дзеркальна перевірка до gitignore для vendor: дерево, яке МАЄ бути в git,
                # не повинно ловитись правилом .gitignore. Помилково широке правило викидає
                # вихідники з git мовчки — ні sync, ні canon цього не бачать.
                #
                # --no-index обов'язковий: без нього check-ignore звіряється з індексом і
                # НІКОЛИ не покаже вже трекований файл ігнорованим, хай яке правило
                # додай — це задокументована поведінка git (див. check-ignore -h), а не
                # артефакт. Перевірено емпірично на git 2.53.0.windows.1: без --no-index
                # цей інваріант не ловив жодного випадку, коли Configuration.xml уже
                # закомічено (справжній репозиторій-споживач — завжди саме такий стан).
                git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                $ignoredCode = $LASTEXITCODE
                if ($ignoredCode -eq 0) {
                    & $add error gitignore ("$tag`: дерево '$($src.RepoPath)' гітігноровано, хоч має потрапляти в git (truth: $($src.Truth)) — " +
                        'перевірте правила .gitignore.')
                } elseif ($ignoredCode -gt 1) {
                    & $add error gitignore "$tag`: git check-ignore завершився з кодом $ignoredCode."
                }
            }

            switch ($src.Truth) {
                'vendor' {
                    # --no-index із тієї самої причини, що й у дзеркальній перевірці вище:
                    # звірка має тестувати ПРАВИЛА .gitignore, а не те, чи файл уже випадково
                    # потрапив у індекс.
                    git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 1) {
                        & $add error gitignore ("$tag`: '$($src.RepoPath)' не гітігноровано (truth: vendor) — чужа конфігурація потрапила б у git. " +
                            "Додайте в .gitignore рядок '$($src.RepoPath)/**' (перевірка: git check-ignore).")
                    } elseif ($code -gt 1) {
                        & $add error gitignore "$tag`: git check-ignore завершився з кодом $code."
                    }
                }
                'storage' {
                    if (-not (Test-Path -LiteralPath $src.StoragePath)) {
                        & $add warn storage-path ("$tag`: каталог сховища недоступний на цій машині: $($src.StoragePath). " +
                            "Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key).")
                    }
                    if (Test-KitBranchExists -RepoRoot $root -Branch $src.Branch) {
                        foreach ($f in @(Test-KitStorageBranchInvariants -RepoRoot $root -Branch $src.Branch -SourceKey $src.Key -RepoPath $src.RepoPath)) {
                            $findings.Add($f)
                        }
                    } else {
                        & $add info storage-branch "$tag`: гілки $($src.Branch) ще немає — її створить перший sync."
                    }
                }
            }

            if ($src.Truth -in @('dump', 'vendor')) {
                if (-not $Context.Overlay) {
                    & $add warn dump-from ("$tag`: dump.from '$($src.DumpFrom)', але накладки v8storagekit.local.yaml на цій машині немає — " +
                        'dump тут не запрацює, поки її не створити.')
                } elseif (-not $Context.Overlay.Infobases.ContainsKey($src.DumpFrom)) {
                    & $add warn dump-from "$tag`: дев-бази '$($src.DumpFrom)' немає в infobases: накладки $($Context.OverlayPath)."
                }
            }

            # §2.2 — ім'я розширення однакове в трьох місцях. vendor не наш, його не звіряємо.
            if ($src.Type -eq 'EXTENSION' -and $src.Truth -ne 'vendor') {
                $cfg = Join-Path $src.FullPath 'Configuration.xml'
                if (Test-Path -LiteralPath $cfg -PathType Leaf) {
                    $xmlName = Get-KitConfigurationName -Path $cfg
                    if (-not $xmlName) {
                        & $add warn config-name "$tag`: у $($src.RepoPath)/Configuration.xml не знайдено <Name>."
                    } elseif ($xmlName -ne $src.Key) {
                        & $add error config-name ("$tag`: <Name>$xmlName</Name> у $($src.RepoPath)/Configuration.xml не збігається з ключем джерела '$($src.Key)' — " +
                            'ім''я розширення має бути однаковим у name: source-set, <Name> і ключі маніфесту (§2.2).')
                    }
                } else {
                    & $add info config-name "$tag`: $($src.RepoPath)/Configuration.xml ще немає — дерево порожнє до першого sync."
                }
            }
        }

        # §2.5 — аудит v8project.local.yaml: підключення до бази ЛЮДИНИ під ключем Unica.
        foreach ($ws in $Context.Workspaces) {
            if ($Workspace -and $ws.Path -ne $Workspace) { continue }
            $localPath = Join-Path $ws.FullPath 'v8project.local.yaml'
            $localConn = $null
            try { $localConn = Read-V8ProjectLocalInfobase -Path $localPath }
            catch { & $add error local-audit "$($ws.Path)/v8project.local.yaml не читається: $($_.Exception.Message)" }
            if ($localConn -and $Context.Overlay) {
                $norm = { param([string]$s) (($s -replace '\s', '') -replace '"', '').TrimEnd(';').ToLowerInvariant() }
                $hit = @($Context.Overlay.Infobases.Values | Where-Object { (& $norm $_.Connection) -eq (& $norm $localConn) }) | Select-Object -First 1
                if ($hit) {
                    & $add error local-audit ("$($ws.Path)/v8project.local.yaml: infobase.connection збігається з дев-базою '$($hit.Name)' із накладки kit — " +
                        'це база людини під ключем Unica, і operation=build писав би в неї. Приберіть infobase: звідти; ' +
                        'у цьому файлі може бути лише серверна база АГЕНТА (§2.5).')
                }
            }
        }

        # §3.3, шар 2 — хуки.
        foreach ($f in @(Test-KitGitHooks -RepoRoot $root)) { $findings.Add($f) }
    }

    $errors = @($findings | Where-Object Level -eq 'error')
    $warns  = @($findings | Where-Object Level -eq 'warn')
    if (-not $Quiet) {
        Write-Host "kit check — $root"
        foreach ($f in $findings) {
            $mark  = switch ($f.Level) { 'error' { '[-]' } 'warn' { '[!]' } default { '[i]' } }
            $color = switch ($f.Level) { 'error' { 'Red' }  'warn' { 'Yellow' } default { 'Gray' } }
            Write-Host "$mark $($f.Message)" -ForegroundColor $color
        }
        Write-Host ''
        if ($errors.Count -eq 0) {
            Write-Host "Помилок немає. Попереджень: $($warns.Count)." -ForegroundColor Green
        } else {
            Write-Host "Помилок: $($errors.Count), попереджень: $($warns.Count)." -ForegroundColor Red
        }
    }

    [pscustomobject]@{
        ExitCode = $(if ($errors.Count -gt 0) { 1 } else { 0 })
        Findings = $findings.ToArray()
    }
}

Export-ModuleMember -Function Invoke-KitCheck, Get-KitConfigurationName
