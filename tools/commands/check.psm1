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

        # Правка 3 (фінальне рев'ю) — mainBranch друкується рядком вище, але досі не
        # перевірявся: маніфест міг називати гілку, якої в репозиторії ще немає (описка,
        # або репозиторій, де trunk ще не перейменували на main), а B2 зіллє storage/* саме
        # в неї — внутрішня суперечність, видима з будь-якої машини (спека §5). warn, не
        # error: свіжий репозиторій до першого коміту головної гілки — законний стан, і
        # check не має права завалювати онбординг рівно за це.
        if (-not (Test-KitBranchExists -RepoRoot $root -Branch $Context.MainBranch)) {
            & $add warn main-branch (
                "Головної гілки '$($Context.MainBranch)' (mainBranch: у v8storagekit.yaml) немає в репозиторії. " +
                'Якщо це описка — виправте mainBranch: у маніфесті; якщо репозиторій ще зовсім новий — зробіть ' +
                'у неї перший коміт до першого kit sync.')
        }

        # §2.3 — ключі truth: storage унікальні в межах репозиторію (гілка storage/<ключ> одна).
        $dups = @($Context.Workspaces | ForEach-Object { $_.Sources } | Where-Object Truth -eq 'storage' |
            Group-Object Key | Where-Object Count -gt 1)
        foreach ($d in $dups) {
            & $add error unique-keys ("Ключ '$($d.Name)' з truth: storage повторюється у воркспейсах $($d.Group.Workspace -join ', ') — " +
                "гілка storage/$($d.Name) була б спільною. Перейменуйте source-set в одному з них (§2.3).")
        }

        # S3 (живий прогін задачі 11) — v8storagekit.local.yaml (накладка з рядками
        # підключення й користувачами сховищ) мусить бути гітігнорована в корені: справжній
        # репозиторій мав .gitignore з v8project.local.yaml (Уніки), але БЕЗ *.local.yaml і
        # без окремого рядка v8storagekit.local.yaml — накладка показувалась як ?? і
        # застейджилась би першим же git add -A у публічному репозиторії. Рівно ОДНА
        # знахідка на весь репозиторій (файл один на корінь) — тому перевірка стоїть ПОЗА
        # циклом foreach ($src in $all) нижче: усередині нього дала б стільки самих помилок,
        # скільки джерел. --no-index — питаємо про ПРАВИЛА .gitignore, а не про індекс
        # (та сама причина, що й у решти check-ignore нижче).
        git -C $root check-ignore --no-index -q -- 'v8storagekit.local.yaml' 2>$null | Out-Null
        $overlayIgnoredCode = $LASTEXITCODE
        if ($overlayIgnoredCode -eq 1) {
            & $add error overlay-ignored (
                'v8storagekit.local.yaml не гітігноровано в корені репозиторію — це накладка з рядками ' +
                'підключення й користувачами сховищ, і перший же git add -A застейджить її в публічний ' +
                "репозиторій. Додайте рядок 'v8storagekit.local.yaml' у .gitignore (зразок: templates/gitignore).")
        } elseif ($overlayIgnoredCode -gt 1) {
            & $add error overlay-ignored "git check-ignore для v8storagekit.local.yaml завершився з кодом $overlayIgnoredCode."
        }

        # Правка 1 (фінальне рев'ю) — те саме друге питання, що вже стоїть нижче для
        # truth: vendor: ПРАВИЛА (вище) і ФАКТ — окремі питання. Правило в .gitignore може
        # бути на місці, а файл уже закомічено (git add -f, або з часів до появи правила) —
        # check-ignore --no-index свідомо ігнорує індекс і такого не покаже; питаємо індекс
        # напряму. Порада самого check ("додайте рядок у .gitignore") гасила б тривогу, не
        # прибираючи файл з історії, — це і є діра, яку рев'ю знайшло тут: правило Є, файл
        # закомічено, а check раніше давав код 0 і одне попередження.
        $overlayTracked = @(git -C $root ls-files -- 'v8storagekit.local.yaml' 2>$null)
        if ($LASTEXITCODE -ne 0) {
            & $add error overlay-ignored "git ls-files для v8storagekit.local.yaml завершився з кодом $LASTEXITCODE."
        } elseif ($overlayTracked.Count -gt 0) {
            & $add error overlay-ignored (
                'v8storagekit.local.yaml вже закомічено в git — у ньому рядки підключення й користувачі ' +
                'сховищ, а репозиторій публічний. Приберіть з індексу: git rm --cached -- v8storagekit.local.yaml. ' +
                'Це не прибирає файл із ІСТОРІЇ попередніх комітів — лише зупиняє подальше витікання.')
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
                    # Vendor — два РІЗНІ питання, не одне. До --no-index вони випадково
                    # збігалися в одному виклику check-ignore (без прапорця check-ignore
                    # звіряється з індексом, і тому "не ігнорований" фактично означало
                    # "закомічений" — той самий побічний ефект, що ламав F5 у дзеркальній
                    # перевірці вище, тут випадково ловив правильну тривогу). --no-index це
                    # розвів, тож питання тепер задаються явно, кожне своєю перевіркою:

                    # (1) ПРАВИЛА: чи .gitignore справді ігнорує дерево. --no-index — та сама
                    # причина, що й у дзеркальній перевірці: питаємо про правила, а не про
                    # те, що вже випадково потрапило в індекс.
                    git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 1) {
                        & $add error gitignore ("$tag`: '$($src.RepoPath)' не гітігноровано (truth: vendor) — чужа конфігурація потрапила б у git. " +
                            "Додайте в .gitignore рядок '$($src.RepoPath)/**' (перевірка: git check-ignore).")
                    } elseif ($code -gt 1) {
                        & $add error gitignore "$tag`: git check-ignore завершився з кодом $code."
                    }

                    # (2) ФАКТ: чи дерево справді не в git — незалежно від правил. Правило
                    # може бути на місці, а файли вже закомічені силою (git add -f) або з
                    # часів до появи правила: check-ignore цього не покаже (--no-index
                    # свідомо ігнорує індекс), тому запитуємо індекс напряму. Код виходу
                    # git ls-files — 0 в обох випадках (протеклого й здорового дерева),
                    # розрізняє лише порожність виводу.
                    $tracked = @(git -C $root ls-files -- $src.RepoPath 2>$null)
                    if ($LASTEXITCODE -ne 0) {
                        & $add error gitignore "$tag`: git ls-files завершився з кодом $LASTEXITCODE."
                    } elseif ($tracked.Count -gt 0) {
                        & $add error gitignore ("$tag`: дерево '$($src.RepoPath)' (truth: vendor) відстежується git — у ньому $($tracked.Count) файл(ів), " +
                            'хоч чужа конфігурація не має потрапляти в репозиторій. Приберіть з індексу: ' +
                            "git rm -r --cached -- '$($src.RepoPath)'.")
                    }
                }
                'storage' {
                    if (-not (Test-Path -LiteralPath $src.StoragePath)) {
                        # Правка 4 (живий прогін задачі 11) — рівень лишається warn: check не
                        # відрізнить "немає доступу до диска" (законний сценарій рев'ю без
                        # сховищ) від "помилка в маніфесті" (типо в шляху). Але текст мусить
                        # показати людині обидві розвилки, а не тільки одну: живий приклад —
                        # маніфест вказував …СМП_BankExchange_ACC, а реальне сховище лежало під
                        # …СМП_BankExchange_BP, і попереднє формулювання радило б перевизначити
                        # шлях, хоча насправді треба було виправити маніфест.
                        $manifestWs  = @($Context.Manifest.Workspaces | Where-Object Path -eq $src.Workspace)[0]
                        $manifestSrc = @($manifestWs.Sources | Where-Object Key -eq $src.Key)[0]
                        $manifestPath = if ($manifestSrc) { $manifestSrc.StoragePath } else { $src.StoragePath }
                        $pathNote = if ($manifestPath -ne $src.StoragePath) {
                            "перевизначено в v8storagekit.local.yaml на '$($src.StoragePath)'; у самому v8storagekit.yaml записано: '$manifestPath'"
                        } else {
                            "'$manifestPath', як записано в v8storagekit.yaml"
                        }
                        & $add warn storage-path ("$tag`: каталог сховища недоступний на цій машині: $pathNote. " +
                            "Якщо шлях правильний, а диска зараз немає — перевизначте його в накладці storages: $($src.Key): { path: … }; " +
                            'якщо диск є, а шлях помилковий — виправте v8storagekit.yaml.')
                    }
                    if (Test-KitBranchExists -RepoRoot $root -Branch $src.Branch) {
                        # Правка 8 (фінальне рев'ю) — Test-KitStorageBranchInvariants кидає на
                        # збої git (StorageBranch.psm1: git log/git ls-tree). Без цього try/catch
                        # (на відміну від Test-GitTextPolicy й Read-V8ProjectLocalInfobase поруч,
                        # уже загорнутих) збій git тут зносив би ввесь звіт check разом з усіма
                        # findings, уже зібраними до цього рядка — найгірший спосіб впасти для
                        # команди, чий сенс «показати все, що не так».
                        try {
                            foreach ($f in @(Test-KitStorageBranchInvariants -RepoRoot $root -Branch $src.Branch -SourceKey $src.Key -RepoPath $src.RepoPath)) {
                                $findings.Add($f)
                            }
                        } catch {
                            & $add error storage-branch "$tag`: аудит інваріантів гілки $($src.Branch) впав: $($_.Exception.Message)"
                        }
                    } else {
                        & $add info storage-branch "$tag`: гілки $($src.Branch) ще немає — її створить перший sync."
                    }
                }
            }

            if ($src.Truth -in @('dump', 'vendor')) {
                if (-not $Context.Overlay) {
                    & $add warn dump-from ("$tag`: dump.from '$($src.DumpFrom)', але накладки v8storagekit.local.yaml на цій машині немає — " +
                        'dump тут не запрацює, поки її не створити (зразок: templates/v8storagekit.local.yaml.example).')
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

            # S1 (живий прогін задачі 11) — source-set існує у v8project.yaml, але маніфест
            # його не оголошує: sync про таке джерело не знає й ніколи не дзеркалить його в
            # git. Перевірка йде лише в напрямку "маніфест → v8project.yaml" (щойно вище і в
            # Preflight.psm1); зворотної не було — прибрали з маніфесту блок розширення,
            # лишили base, а check мовчав "Помилок немає". warn, не error: чи це справді
            # незаявлене джерело, вирішує людина, і check не має права ні вигадати його, ні
            # завалити роботу з решти джерел. Звіряємо з КЛЮЧАМИ, оголошеними в маніфесті
            # ($Context.Manifest.Workspaces) — не з розв'язаними $ws.Sources: "оголошене" —
            # це те, що написала людина, а не те, що встигло розв'язатись.
            $manifestWs = @($Context.Manifest.Workspaces | Where-Object Path -eq $ws.Path)[0]
            $declaredKeys = @($(if ($manifestWs) { $manifestWs.Sources.Key } else { @() }))
            foreach ($set in $ws.Project.SourceSets) {
                if ($declaredKeys -notcontains $set.Name) {
                    & $add warn undeclared-source (
                        "$($ws.Path): source-set '$($set.Name)' ($($set.Type)) оголошено у $($ws.Path)/v8project.yaml, " +
                        'але його немає в маніфесті — kit про це джерело не знає, і sync його не дзеркалить. ' +
                        'Додайте його в v8storagekit.yaml (зразок: templates/v8storagekit.yaml.example) або приберіть source-set.')
                }
            }

            $localPath = Join-Path $ws.FullPath 'v8project.local.yaml'
            $relLocalPath = "$($ws.Path)/v8project.local.yaml"

            # Правка 1 (фінальне рев'ю) — v8project.local.yaml (файл Уніки) теж гітігнорований,
            # теж із підключенням до бази, і check його досі не перевіряв узагалі. Той самий
            # зразок «два питання», що вище для kit-накладки й нижче для truth: vendor: ПРАВИЛА
            # (check-ignore --no-index) і ФАКТ (ls-files), окремо. На відміну від накладки kit —
            # вона одна на репозиторій, v8project.local.yaml живе В КОЖНОМУ воркспейсі поруч зі
            # своїм v8project.yaml, тому перевірка тут, усередині цього циклу, а не поза ним.
            git -C $root check-ignore --no-index -q -- $relLocalPath 2>$null | Out-Null
            $localIgnoredCode = $LASTEXITCODE
            if ($localIgnoredCode -eq 1) {
                & $add error local-ignored (
                    "$relLocalPath не гітігноровано — це файл Уніки з підключенням до бази, і перший же " +
                    "git add -A застейджить його в публічний репозиторій. Додайте рядок 'v8project.local.yaml' " +
                    'у .gitignore (зразок: templates/gitignore).')
            } elseif ($localIgnoredCode -gt 1) {
                & $add error local-ignored "$relLocalPath`: git check-ignore завершився з кодом $localIgnoredCode."
            }

            $localTracked = @(git -C $root ls-files -- $relLocalPath 2>$null)
            if ($LASTEXITCODE -ne 0) {
                & $add error local-ignored "$relLocalPath`: git ls-files завершився з кодом $LASTEXITCODE."
            } elseif ($localTracked.Count -gt 0) {
                & $add error local-ignored (
                    "$relLocalPath вже закомічено в git — це файл Уніки з підключенням до бази. Приберіть з " +
                    "індексу: git rm --cached -- $relLocalPath. Це не прибирає файл із ІСТОРІЇ попередніх " +
                    'комітів — лише зупиняє подальше витікання.')
            }

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

        # §3.3, шар 2 — хуки. Той самий захист, що вище для інваріантів гілки: Test-KitGitHooks
        # кидає на збої git (Hooks.psm1: git ls-files -s), і без try/catch це так само зносило б
        # усі findings, зібрані до цього рядка.
        try {
            foreach ($f in @(Test-KitGitHooks -RepoRoot $root)) { $findings.Add($f) }
        } catch {
            & $add error hooks "Аудит хуків впав: $($_.Exception.Message)"
        }
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
