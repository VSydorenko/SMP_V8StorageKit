#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module ризикував би перезавантаженням (docs/follow-ups.md §5).

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
        # Реєстр плагінів машини, де шукається Уніка (тестовий шов — параметр, не змінна оточення).
        # Умовчання — реєстр поточного користувача.
        [string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json'),
        # Шлях до раннера Уніки; порожній — із ТОГО Ж реєстру (-InstalledPluginsPath), що й Уніка (§4.2 п.20):
        # тест-підпроцес без -RunnerPath має почервоніти на фальшивому реєстрі без раннера, а не піти до справжньої Уніки.
        [string]$RunnerPath,
        # -Apply не оголошено свідомо: команда нічого не мутує (§5). Диспетчер на переданий -Apply
        # зупиняється з поясненням.
        [switch]$Quiet
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Context.Findings) { $findings.Add($f) }
    $add = { param([string]$Level, [string]$Check, [string]$Message) $findings.Add((New-KitFinding -Level $Level -Check $Check -Message $Message)) }
    $root = $Context.RepoRoot

    # §4.2 п.4, п.19: версія Уніки й раннера — вимоги. Реєстр машинний (Уніка — плагін рівня
    # користувача); -InstalledPluginsPath — той самий інтерфейс, що в check-environment.ps1.
    # Поза if ($Context.Manifest): це стан машини.
    #
    # Відсутня Уніка — error через runner-version (п.19), а не окремий рядок unica-version: раннера без
    # неї не знайти, і текст runner-version уже називає причину. Два error про одне й те саме — шум.
    $unicaInstall = Get-UnicaInstallation -InstalledPluginsPath $InstalledPluginsPath
    if ($unicaInstall.Installed -and $unicaInstall.PathExists) {
        $unicaVerdict = Get-KitUnicaVersionVerdict -Installation $unicaInstall
        if ($unicaVerdict.Level -ne 'ok') { & $add $unicaVerdict.Level 'unica-version' $unicaVerdict.Message }
    }
    $runnerVerdict = Get-KitRunnerVerdict -RunnerPath $RunnerPath -InstalledPluginsPath $InstalledPluginsPath
    if ($runnerVerdict.Level -ne 'ok') { & $add $runnerVerdict.Level 'runner-version' $runnerVerdict.Message }

    if ($Context.Manifest) {
        $all = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        # Підсумок рахує за МАНІФЕСТОМ, а не за розв'язаним контекстом: воркспейс із помилкою конфігу (стара
        # форма v8project.yaml, немає папки) до $Context.Workspaces не потрапляє, і підсумок «воркспейсів 0,
        # джерел 0» (§5 п.2) читався б як «маніфест порожній», хоч порожній лише розв'язаний бік.
        $declared = @($Context.Manifest.Workspaces | Where-Object { -not $Workspace -or $_.Path -eq $Workspace })
        $declaredSources = @($declared | ForEach-Object { $_.Sources } | Where-Object { -not $Source -or $_.Key -eq $Source })
        $byTruth = (@($declaredSources | Group-Object Truth | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Count)" })) -join ', '
        $unresolved = if ($declared.Count -gt @($Context.Workspaces).Count) { " (розв'язано $(@($Context.Workspaces).Count) — решту див. у помилках конфігу нижче)" } else { '' }
        & $add info manifest ("Маніфест: $($Context.Kind) $($Context.Label), головна гілка $($Context.MainBranch), " +
            "воркспейсів $($declared.Count), джерел у перевірці $($declaredSources.Count) ($byTruth)$unresolved.")

        # Дамп версії сховища виконується в базі агента (§3), тож для
        # кожного truth: storage база — передумова, а не зручність. Сказати на старті сесії дешевше,
        # ніж зупинити sync, який людина вже запустила. warn, не error: репозиторій несуперечливий —
        # просто ще не готовий до sync на ЦІЙ машині.
        foreach ($src in @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)) {
            $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1
            if ($null -eq $ws) { continue }
            $ab = $null
            try { $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws }
            catch {
                # Ковтати не можна: local-audit звіряє ЛИШЕ v8project.local.yaml, а підключення законно
                # буває й у закоміченому v8project.yaml — тоді про колізію не сказав би ніхто.
                #
                # Підстав для винятку кілька, і звужувати перелік до однієї НЕ треба: (а) база агента
                # збіглася з дев-базою людини; (б) підключення нерозбірне (ConvertFrom-V8Connection кидає
                # на порожньому рядку, непарній лапці, голому шляху, Srvr= без Ref=, невідомому ключі);
                # (в) Test-KitInfobasesOverlap fail-closed на нерозбірній дев-базі накладки. Текст винятку
                # іде в повідомлення — людина бачить справжню причину, не наш здогад.
                & $add 'error' 'agent-base-required' "$($ws.Path): $($_.Exception.Message)"
                continue
            }
            if ($null -eq $ab) {
                & $add 'warn' 'agent-base-required' ("Джерело '$($src.Key)' (truth: storage) вивантажується в контексті базової конфігурації. " + (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path))
            } elseif ($ab.Kind -eq 'file' -and -not $ab.Exists) {
                & $add 'warn' 'agent-base-required' ("Джерело '$($src.Key)' (truth: storage) вивантажується в контексті базової конфігурації, а бази агента " +
                    "воркспейсу '$($ws.Path)' ще немає на диску: v8storagekit:infobase-agent.")
            }
        }

        # mainBranch маніфесту мусить існувати: sync зливає storage/* саме в неї (§5). Два рівні
        # (Test-KitBranchUnborn): HEAD уже на цій гілці, лише ref ще немає (свіжий репозиторій) —
        # законний стан, info; HEAD ДЕІНДЕ — найімовірніше описка в mainBranch:, warn.
        if (-not (Test-KitBranchExists -RepoRoot $root -Branch $Context.MainBranch)) {
            if (Test-KitBranchUnborn -RepoRoot $root -Branch $Context.MainBranch) {
                & $add info main-branch (
                    "Свіжий репозиторій: головної гілки '$($Context.MainBranch)' (mainBranch: у v8storagekit.yaml) " +
                    'ще немає — її створить перший коміт до першого kit sync.')
            } else {
                & $add warn main-branch (
                    "Головної гілки '$($Context.MainBranch)' (mainBranch: у v8storagekit.yaml) немає в репозиторії, " +
                    'а HEAD указує на іншу гілку — перевірте mainBranch: (описка?), або виправте маніфест, якщо ' +
                    'головну гілку перейменовано.')
            }
        }

        # §2.3 — ключі truth: storage унікальні в межах репозиторію (гілка storage/<ключ> одна).
        $dups = @($Context.Workspaces | ForEach-Object { $_.Sources } | Where-Object Truth -eq 'storage' |
            Group-Object Key | Where-Object Count -gt 1)
        foreach ($d in $dups) {
            & $add error unique-keys ("Ключ '$($d.Name)' з truth: storage повторюється у воркспейсах $($d.Group.Workspace -join ', ') — " +
                "гілка storage/$($d.Name) була б спільною. Перейменуйте source-set в одному з них (§2.3).")
        }

        # v8storagekit.local.yaml (накладка з рядками підключення й користувачами сховищ) мусить бути
        # гітігнорована в корені, інакше перший git add -A застейджить її в публічний репозиторій.
        # Файл один на корінь, тож перевірка ПОЗА циклом по джерелах. --no-index — питаємо про ПРАВИЛА
        # .gitignore, а не про індекс.
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

        # ПРАВИЛА (вище) і ФАКТ — окремі питання: правило може бути на місці, а файл уже закомічено
        # (git add -f чи до появи правила), і check-ignore --no-index цього не покаже — питаємо індекс.
        # -c core.quotepath=false — kit форсує це на кожному git-виклику, що читає чи друкує шляхи.
        $overlayTracked = @(git -c core.quotepath=false -C $root ls-files -- 'v8storagekit.local.yaml' 2>$null)
        if ($LASTEXITCODE -ne 0) {
            & $add error overlay-ignored "git ls-files для v8storagekit.local.yaml завершився з кодом $LASTEXITCODE."
        } elseif ($overlayTracked.Count -gt 0) {
            & $add error overlay-ignored (
                'v8storagekit.local.yaml вже закомічено в git — у ньому рядки підключення й користувачі ' +
                'сховищ, а репозиторій публічний. Приберіть з індексу: git rm --cached -- v8storagekit.local.yaml. ' +
                'Це не прибирає файл із ІСТОРІЇ попередніх комітів — лише зупиняє подальше витікання.')
        }

        # Підключення кожної дев-бази накладки розбирається й тоді, коли її ні з чим не звіряють
        # (воркспейси лише з truth: dump/vendor): інакше нерозбірне підключення (непарна лапка, голий
        # шлях, Srvr= без Ref= — форми старих накладок) проходило б check і падало лише на kit dump.
        # Раз на дев-базу — тому поза циклом по джерелах. warn, не error: error гасив би сигнали сховищ
        # у хуку старту сесії, а дев-база потрібна лише dump. Дубль із 'agent-base-required' вище законний.
        if ($Context.Overlay) {
            foreach ($human in $Context.Overlay.Infobases.Values) {
                try { ConvertFrom-V8Connection -Connection $human.Connection | Out-Null }
                catch {
                    $recipe = Get-V8CredentialsRecipe -Exception $_.Exception -Kind overlay
                    & $add warn overlay-connection ("Дев-база '$($human.Name)' у $($Context.OverlayPath): $($_.Exception.Message)" + $(if ($recipe) { " $recipe" }))
                }
            }
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

                # Групи регістру в HEAD під шляхом джерела (§4.4): фантом приходить і
                # ручним `git add -A` після dump чи pull Уніки, не лише з дзеркала.
                try {
                    if ((Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '-q', '--verify', 'HEAD')).ExitCode -eq 0) {
                        $groups = @(Get-KitCaseCollisions -Paths @(Get-KitTreePaths -RepoRoot $root -Ref 'HEAD' -Path $src.RepoPath))
                        if ($groups.Count -gt 0) {
                            $shown = @($groups | Select-Object -First 5 | ForEach-Object { $_ -join ' | ' })
                            & $add error case-collision ("$tag`: у HEAD $($groups.Count) груп(и) шляхів, що різняться лише регістром: " +
                                "$($shown -join '; ')$(if ($groups.Count -gt 5) { "; …і ще $($groups.Count - 5)" } else { '' }). " +
                                'Зніміть фантом з індексу (git rm --cached -- <шлях>) і закомітьте без --only; розбір — docs/storage-and-git.md, «Перейменування регістром».')
                        }
                    }
                } catch {
                    & $add error case-collision "$tag`: перевірка регістру в HEAD впала: $($_.Exception.Message)"
                }

                # Дзеркальна перевірка до gitignore для vendor: дерево, яке МАЄ бути в git,
                # не повинно ловитись правилом .gitignore. Помилково широке правило викидає
                # вихідники з git мовчки — ні sync, ні verify цього не бачать.
                #
                # --no-index обов'язковий: без нього check-ignore звіряється з індексом і НІКОЛИ не
                # покаже вже трекований файл ігнорованим (задокументована поведінка git) — а в
                # живому репозиторії Configuration.xml завжди закомічено.
                git -C $root check-ignore --no-index -q -- "$($src.RepoPath)/Configuration.xml" 2>$null | Out-Null
                $ignoredCode = $LASTEXITCODE
                if ($ignoredCode -eq 0) {
                    & $add error gitignore ("$tag`: дерево '$($src.RepoPath)' гітігноровано, хоч має потрапляти в git (truth: $($src.Truth)) — " +
                        'перевірте правила .gitignore.')
                } elseif ($ignoredCode -gt 1) {
                    & $add error gitignore "$tag`: git check-ignore завершився з кодом $ignoredCode."
                }
            }

            # Поставка вендора основної конфігурації (§5.2, §6.3.8–9). Для vendor
            # дерево ігнороване цілком — інваріант інший (нижче). Для розширень і конфігурацій без
            # підтримки .bin поставки не описує, і перевірки мовчать.
            # Проба ігнору теки — питанням про вигаданий файл у ній, НЕ про теку з кінцевою скісною
            # рискою: на git 2.53.0.windows.1 у .gitignore з CRLF порожній рядок ("\r") змушує
            # check-ignore відповідати 0 на будь-який шлях із кінцевою рискою, і відсутність правила
            # лишилась би непоміченою. Проба файлом перевірена: правило є → 0, немає → 1, з CRLF теж.
            if ($src.Type -eq 'CONFIGURATION' -and $src.Truth -ne 'vendor') {
                $supplyRel = "$($src.RepoPath)/$(Get-KitSupplyRelativePath)"
                $binRel    = "$supplyRel.bin"
                if (Test-Path -LiteralPath (Join-Path $root $binRel) -PathType Leaf) {
                    git -C $root check-ignore --no-index -q -- $binRel 2>$null | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 0) {
                        & $add error gitignore ("$tag`: ознаки підтримки (замки об'єктів) '$binRel' гітігноровано — вони мусять лежати в git. " +
                            'Приберіть правило, яке його ловить (перевірка: git check-ignore -v).')
                    } elseif ($code -gt 1) { & $add error gitignore "$tag`: git check-ignore завершився з кодом $code." }
                }
                if (Test-KitSupplyDescribed -TreeRoot $src.FullPath) {
                    # Дві проби: .cf і позначка .kit-bin-sha1 (стан машини, теж не для git) — правило
                    # лише на `*.cf` чи з винятком для позначки ловило б одну з двох.
                    $code = 0
                    foreach ($probe in @('probe.cf', '.kit-bin-sha1')) {
                        git -C $root check-ignore --no-index -q -- "$supplyRel/$probe" 2>$null | Out-Null
                        if ($LASTEXITCODE -ne 0) { $code = $LASTEXITCODE; break }
                    }
                    if ($code -eq 1) {
                        & $add error gitignore ("$tag`: тека поставки вендора '$supplyRel/' не гітігнорована — .cf на сотні МБ потрапив би в git " +
                            "(ліміт GitHub 100 МБ на файл). Додайте в .gitignore рядок '**/Ext/ParentConfigurations/'.")
                    } elseif ($code -gt 1) { & $add error gitignore "$tag`: git check-ignore завершився з кодом $code." }
                }
                $trackedSupply = @(git -c core.quotepath=false -C $root ls-files -- $supplyRel 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    & $add error gitignore "$tag`: git ls-files завершився з кодом $LASTEXITCODE."
                } elseif ($trackedSupply.Count -gt 0) {
                    & $add error gitignore ("$tag`: поставка вендора відстежується git ($($trackedSupply.Count) файл(ів) у '$supplyRel') — " +
                        "приберіть з індексу й закомітьте окремим комітом (файли на диску лишаться): git rm -r --cached -- '$supplyRel', потім git commit.")
                }
                if ($src.Truth -eq 'storage') {
                    $state = Get-KitSupplyState -TreeRoot $src.FullPath
                    if ($state -in 'missing', 'stale') {
                        # Варіант рецепту — за поточною гілкою.
                        $onMain = Test-KitOnMainBranch -RepoRoot $root -MainBranch $Context.MainBranch
                        & $add warn supply ("$tag`: " + (Get-KitSupplyRecipe -SourceKey $src.Key -Workspace $src.Workspace -MainBranch $Context.MainBranch `
                            -State $state -Purpose check -OnMainBranch $onMain))
                    }
                }
            }

            switch ($src.Truth) {
                'vendor' {
                    # Vendor — два РІЗНІ питання, кожне своєю перевіркою.

                    # (1) ПРАВИЛА: чи .gitignore справді ігнорує дерево (--no-index — про правила,
                    # не про індекс).
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
                    # -c core.quotepath=false — див. коментар біля overlayTracked вище.
                    $tracked = @(git -c core.quotepath=false -C $root ls-files -- $src.RepoPath 2>$null)
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
                        # warn: check не відрізнить «немає доступу до диска» (законно) від описки в
                        # маніфесті — тож текст показує обидві розвилки, а не одну.
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
                        # Test-KitStorageBranchInvariants кидає на збоях git; без try/catch це зносило б
                        # увесь звіт check з уже зібраними findings — найгірший спосіб впасти для
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

            # Зворотний напрямок «v8project.yaml → маніфест»: source-set без запису в маніфесті sync
            # ніколи не дзеркалить. warn, не error: чи це незаявлене джерело, вирішує людина. Звіряємо
            # з КЛЮЧАМИ маніфесту, не з розв'язаними $ws.Sources — «оголошене» те, що написала людина.
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

            # §2.6/§13 — артефакти збірки в git не лежать: бінарний блоб лишається в історії назавжди, а
            # закомічений артефакт поруч зі свіжим не відрізнити. Єдине їх місце — під
            # <воркспейс>/<workPath>/ (гітігнорована; аудит приймає весь $workPrefix), куди пише make Уніки.
            #
            # РІВЕНЬ warn, І САМЕ warn: у формі 0.6.0 артефакти в git були законною нормою, і error
            # завалив би перехід. Це «ще не ухвалене рішення»: прибрати пропонує onboarding, вирішує людина.
            #
            # .erf доданий понад три розширення §2.6 свідомо: зовнішній звіт збирає та сама команда
            # платформи, що й .epf, — поза переліком це була б відома дірка в інваріанті.
            $artifactExt = @('.epf', '.erf', '.cfe', '.cf')
            $wsWorkPath = if ($ws.Project.WorkPath) { $ws.Project.WorkPath } else { 'build' }
            $wsPrefix = ($ws.Path -replace '\\', '/').TrimEnd('/')
            $workPrefix = "$wsPrefix/$(($wsWorkPath -replace '\\', '/').TrimEnd('/'))/"
            $tracked = Invoke-KitGitProcess -RepoRoot $root -Arguments @(
                '-c', 'core.quotepath=false', 'ls-files', '-z', '--', $ws.Path)
            if ($tracked.ExitCode -ne 0) {
                & $add error build-artifacts "$($ws.Path): git ls-files завершився з кодом $($tracked.ExitCode): $($tracked.Stderr)"
            } else {
                $committedArtifacts = @($tracked.Stdout -split "`0" |
                    Where-Object { $_ -ne '' } |
                    Where-Object { $artifactExt -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() } |
                    Where-Object { -not $_.StartsWith($workPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
                if ($committedArtifacts.Count -gt 0) {
                    $shown = @($committedArtifacts | Select-Object -First 5) -join ', '
                    $tail = if ($committedArtifacts.Count -gt 5) { " та ще $($committedArtifacts.Count - 5)" } else { '' }
                    & $add warn build-artifacts (
                        "$($ws.Path): у git лежать артефакти збірки — $($committedArtifacts.Count) файл(ів): $shown$tail. " +
                        "Вони похідні, і закомічений артефакт застаріє непомітно: поруч зі свіжим його не відрізнити. " +
                        "Єдине їх місце — тека $workPrefix воркспейсу (робоча тека workPath, типово build/; гітігнорована), куди пише make Уніки (типово ${wsPrefix}/build/artifacts/). " +
                        'Прибрати з індексу зі збереженням історії: git rm --cached <шлях> — рішення за вами, kit сам нічого не змінює.')
                }
            }

            $localPath = Join-Path $ws.FullPath 'v8project.local.yaml'
            $relLocalPath = "$($ws.Path)/v8project.local.yaml"

            # v8project.local.yaml (файл Уніки з підключенням до бази) — ті самі два питання, що для
            # накладки kit: ПРАВИЛА (check-ignore --no-index) і ФАКТ (ls-files). Він живе в КОЖНОМУ
            # воркспейсі, тому перевірка всередині циклу.
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

            # -c core.quotepath=false — див. коментар біля overlayTracked вище.
            $localTracked = @(git -c core.quotepath=false -C $root ls-files -- $relLocalPath 2>$null)
            if ($LASTEXITCODE -ne 0) {
                & $add error local-ignored "$relLocalPath`: git ls-files завершився з кодом $LASTEXITCODE."
            } elseif ($localTracked.Count -gt 0) {
                & $add error local-ignored (
                    "$relLocalPath вже закомічено в git — це файл Уніки з підключенням до бази. Приберіть з " +
                    "індексу: git rm --cached -- $relLocalPath. Це не прибирає файл із ІСТОРІЇ попередніх " +
                    'комітів — лише зупиняє подальше витікання.')
            }

            $localConn = $null
            try { $localIb = Read-V8ProjectLocalInfobase -Path $localPath; if ($localIb) { $localConn = $localIb.Connection } }
            catch { & $add error local-audit "$($ws.Path)/v8project.local.yaml не читається: $($_.Exception.Message)" }
            if ($localConn) {
                # Бази агента різних воркспейсів не перетинаються (той самий перелік перетинів, що перевіряє provision).
                # Пара «база проти бази» симетрична — повідомляємо один раз (з воркспейсу, що йде першим за назвою).
                try {
                    foreach ($c in @(Find-KitAgentBaseCollisions -Context $Context -Workspace $ws)) {
                        if ($c.Kind -eq 'base' -and [string]::CompareOrdinal($ws.Path, $c.Other) -gt 0) { continue }
                        $detail = switch ($c.Kind) {
                            'base' { if ($c.Server) { "база агента воркспейсу '$($ws.Path)' і база агента воркспейсу '$($c.Other)' — та сама серверна база (збігаються сервер і Ref)" } else { "база агента воркспейсу '$($ws.Path)' перетинається з базою агента воркспейсу '$($c.Other)'" } }
                            'memory-mine' { "база агента воркспейсу '$($c.Other)' лежить у пам'яті раннера '.local/infobases/origin' воркспейсу '$($ws.Path)'" }
                            'memory-both' { "пам'ять раннера воркспейсу '$($ws.Path)' перетинається з пам'яттю раннера воркспейсу '$($c.Other)'" }
                            default { "база агента воркспейсу '$($ws.Path)' лежить у '.local/infobases' воркспейсу '$($c.Other)'" }
                        }
                        # Наслідок залежить від виду збігу. Kit нічого не видаляє: шкода — у тому, що створення чи
                        # завантаження бази одного воркспейсу пішло б у теку (базу) іншого, а рецепт «видаліть теку»,
                        # який друкує provision, зачепив би чуже: для memory-both це пам'ять раннера, для решти — база агента.
                        $consequence = if ($c.Kind -eq 'memory-both') { "раннер двох воркспейсів вів би пам'ять в одній теці, а порада provision видалити теку пам'яті зачепила б пам'ять іншого воркспейсу" }
                                       else { 'kit створив би чи завантажив базу агента в теку (базу) іншого воркспейсу, а порада provision видалити теку бази зачепила б чужу базу' }
                        & $add error local-audit ("$($ws.Path)/v8project.local.yaml: $detail$(if (-not $c.Server) { ' (одна тека, вкладена чи батьківська)' }) — $consequence. " +
                            'Задайте кожному воркспейсу окрему теку infobases.origin.connection (v8storagekit:infobase-agent).')
                    }
                } catch {
                    & $add error local-audit "$($ws.Path)/v8project.local.yaml: звірка бази агента з базами інших воркспейсів впала: $($_.Exception.Message)"
                }
            }
            if ($localConn -and $Context.Overlay) {
                # Та сама формула ідентичності бази, що в Resolve-KitAgentBase: текстова нормалізація
                # не бачить, що 'File=D:\x\' і 'File=D:\x' — та сама тека, а 'Srvr=A;Ref=B;' і
                # 'Ref=B;Srvr=A;' — та сама база. Test-KitInfobasesOverlap fail-closed кидає на
                # нерозбірному підключенні — check від цього не падає, а дає знахідку error.
                #
                # Бік воркспейсу розв'язується до звірки (Resolve-KitAgentInfobasePath, чиста
                # функція), тим самим прийомом, що в Resolve-KitAgentBase: відносний File=
                # бази агента законний (тека воркспейсу, §2.5) і Test-KitInfobasesOverlap на ньому
                # б кидав — без цього check давав би error на кожному штатному File=build/ib.
                try {
                    $localResolved = Resolve-KitAgentInfobasePath -Project $ws.Project -Connection $localConn
                    $localAuditConn = if ($localResolved.Kind -eq 'file') { 'File={0}' -f $localResolved.Path } else { $localConn }
                    foreach ($human in $Context.Overlay.Infobases.Values) {
                        if (Test-KitInfobasesOverlap -Left $localAuditConn -Right $human.Connection `
                            -LeftOrigin "база агента воркспейсу '$($ws.Path)' (infobases.origin у v8project.local.yaml)" `
                            -RightOrigin "дев-база '$($human.Name)' у v8storagekit.local.yaml") {
                            & $add error local-audit ("$($ws.Path)/v8project.local.yaml: infobases.origin.connection збігається з дев-базою '$($human.Name)' із накладки kit або перетинається з нею (та сама, вкладена чи батьківська тека) — " +
                                'це база людини під ключем Unica, і Уніка (push) писала б у неї. Приберіть infobases.origin звідти ' +
                                'й дайте агентові окрему базу (v8storagekit:infobase-agent).')
                            break
                        }
                    }
                } catch {
                    & $add error local-audit "$($ws.Path)/v8project.local.yaml: аудит infobases.origin.connection проти дев-баз накладки впав: $($_.Exception.Message)"
                }
            }
            elseif (Test-Path -LiteralPath $localPath -PathType Leaf) {
                # Стара конвенція devInfobase: (до 1.0) kit уже не читає: без цієї гілки аудит §2.5
                # пропускався б БЕЗ ЖОДНОГО РЯДКА, а «нічого не сказано» читається як «все гаразд».
                # warn, не error: sync і verify працюють — не працює лише dump і аудит бази людини.
                $localRaw = ''
                try { $localRaw = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 }
                catch { $localRaw = '' }
                if ($localRaw -match '(?m)^\s*devInfobase\s*:') {
                    & $add warn local-audit ("$($ws.Path)/v8project.local.yaml: ключ devInfobase: — стара конвенція, kit її більше не читає. " +
                        'Дев-база має переїхати в v8storagekit.local.yaml, infobases: (перекладе скіл v8storagekit:onboarding); ' +
                        'доти dump для цього воркспейсу не має звідки взяти базу.')
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

        # §3.12 9а — хук старту сесії живе в плагіні; тут шукаємо СТАРИЙ проєктний хук
        # (розділ hooks.SessionStart у .claude/settings.json і/або .claude/hooks/session-start.ps1),
        # що дав би «Стан сховищ» двічі. Той самий захист, що вище для Test-KitGitHooks: Get-Content
        # усередині кидає на будь-якій IO-помилці, і без try/catch виняток зносив би findings, зібрані до цього рядка.
        try {
            foreach ($f in @(Test-KitLegacySessionHook -RepoRoot $root)) { $findings.Add($f) }
        } catch {
            & $add error hook-shim "Аудит старого проєктного хука старту сесії впав: $($_.Exception.Message)"
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
