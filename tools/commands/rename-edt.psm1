#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Write-KitRenameEdtList {
    <# .SYNOPSIS Повний перелік — Unmapped/Unresolved/Collisions друкуються ЦІЛКОМ, не лічильником (§9.2, властивість безпеки). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][scriptblock]$Format)
    foreach ($item in $Items) { Write-Host "    $(& $Format $item)" }
}

function Remove-KitEmptyDirectory {
    <#
    .SYNOPSIS
        Знищує тепер-порожні теки під -SourceRelPath після успішного git mv/rm (додаток
        координатора до раунду 1, пункт "в"). Git не відстежує порожні теки — коміт цього не
        покаже, але скелет лишається на диску й потрапив би в НАСТУПНИЙ Get-ChildItem, якби
        цей самий SourceRelPath колись обходили повторно.
    .DESCRIPTION
        Файли, залишені навмисно (Unresolved — "не видаляти НІКОЛИ"), тримають свої теки
        непорожніми — цю функцію це не зачіпає: вона видаляє лише теки, що СПРАВДІ порожні
        (рекурсивно, знизу вгору), і ніколи не видаляє файл.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-KitRenameEdtBoundaryTag {
    <#
    .SYNOPSIS
        Тег межі EDT-епохи, що вже стоїть на поточному HEAD — лише ЧИТАННЯ (S-I, рев'ю раунду 1).
    .DESCRIPTION
        Раніше команда сама СТВОРЮВАЛА тег `legacy/gitsync-<YYYY-MM>` на HEAD — рев'ю показало
        дві проблеми: (1) це робота кроку 2 онбордингу (skills/onboarding/SKILL.md §5.1), один
        раз на репозиторій, а не один раз на джерело; команда, що пише git-реф у чуже репо
        понад свій прямий обов'язок (git mv/rm), робить зайве; (2) ім'я за ПОТОЧНИМ місяцем на
        ПОТОЧНОМУ HEAD хибне для другого продукту того самого репозиторію іншого місяця — HEAD
        на той момент уже містить чужі коміти перейменування/конверсії, тег «межі» вказував би
        не на межу. Команда лише ЧИТАЄ, чи такий тег уже стоїть на HEAD (для рядка в повідомленні
        коміту) — не рухає й не створює нічого.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('tag', '--points-at', 'HEAD', '-l', 'legacy/gitsync-*')
    if ($r.ExitCode -ne 0) { throw "git tag --points-at HEAD завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    @($r.Stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture) | Select-Object -First 1)
}

function Invoke-KitRenameEdt {
    <#
    .SYNOPSIS
        Коміт перейменування EDT-шляхів у Designer-шляхи (B6 Task 3, §9.2): git mv кожного
        файлу EDT-дерева на його точний Designer-шлях, вміст лишається EDT-ним — його замінить
        наступний коміт конверсії (kit sync). Мета — безперервний git log --follow і git blame.
    .DESCRIPTION
        `властивість безпеки` (task-3-brief.md): команда переписує чуже дерево. Дві гарантії,
        які рев'ю перевіряє окремо:
        1. Жоден файл не видаляється без показу людині — Unmapped і Unresolved друкуються
           повним переліком завжди (і в прев'ю, і під -Apply, і навіть коли є колізії — M-7,
           рев'ю раунду 1), видалення (git rm) — лише для Unmapped і лише під -Apply.
           Unresolved НІКОЛИ не видаляється — Get-KitEdtRenamePlan (EdtPaths.psm1) розрізняє
           "ЗНАЄМО, що не потрібне" (Unmapped) від "НЕ ЗНАЄМО, що це" (Unresolved); плутати
           ці два — саме та помилка, яку задача мусить не допустити (додаток координатора до
           раунду 1: макети з нехарактеризованим розширенням — реальний вміст, не сміття).
        2. Колізія (кілька EDT-шляхів в один Designer-шлях) ЗУПИНЯЄ до першого git mv — дерево
           лишається незміненим. Перевіряється до виконання будь-якої мутації.

        Префлайт строгий (kit.ps1 не додає rename-edt у -Lenient): маніфест і воркспейс уже
        існують на момент виклику, бо -TargetRoot розв'язує саме звідти викликач (онбординг,
        розділ 5.1) — ця команда сама по собі маніфесту не читає, приймає готові -SourceRelPath
        і -TargetRoot.

        Запобіжники перед мутацією, у порядку виконання (рев'ю раунду 1 додав C-B до пари з
        context.md §1, §9):
        - брудна робоча копія в РЕПОЗИТОРІЇ (git status --porcelain) — успадковано з
          repo-migration, §9.2;
        - невідстежувані чи ігноровані файли У ДЕРЕВІ ДЖЕРЕЛА (git ls-files --others) —
          C-B: план будується з диска (Get-ChildItem), а git mv/rm працюють лише з
          відстеженими шляхами; розбіжність між ними раніше падала посеред циклу видалення,
          без відкату (типовий випадок — .gitignore, що ховає ConfigDumpInfo.xml/
          DumpFilesIndex.txt, які самі лежать усередині src/);
        - Test-GitTextPolicy на -TargetRoot: якщо ефективний атрибут text НЕ unset, git
          конвертує кінці рядків при наступному git add (git-конверсія CRLF↔LF), і крок 5
          §9.2 (побайтова рівність зі сховищем) мовчки не виконається — спайк 2026-09-09 це
          відтворив. Коміт самого .gitattributes — відповідальність скіла (onboarding), не цієї
          команди; команда лише перевіряє ефективний результат.

        Мутація (git rm циклом, тоді git mv циклом, тоді коміт) обгорнута в try/catch (I-E,
        рев'ю раунду 1): будь-яка помилка посеред циклу — git reset --hard на SHA, записаний
        ДО першої мутації. Це безпечно саме тому, що жоден коміт іще не додався (лише
        індекс/робоче дерево), і саме тому це ПРАВИЛЬНА відповідь на напівстан — на відміну від
        поради "git stash"/"закомітьте" запобіжника брудної копії вище (та порада для
        ЧУЖОГО безладу, що існував ДО виклику команди; тут безлад — наслідок власного збою
        команди, і команда прибирає за собою сама).
    .PARAMETER SourceRelPath
        Корінь EDT-дерева відносно кореня репозиторію (напр. 'cf/src', 'cfe/src',
        'SMP_OnlineExchange/src') — корінь EDT-дерева не завжди 'src/' у корені репозиторію.
    .PARAMETER TargetRoot
        УЖЕ розв'язаний корінь дерева-призначення відносно кореня репозиторію (напр.
        'SMP_BankExchange_SMB/cfe/src') — викликач бере його з v8project.yaml. Команда мапить
        лише хвіст після кореня EDT-дерева і приклеює його сюди; сама нічого не припускає про
        розкладку (буває 'cfe/src', 'cfe/<Ім'я>/src', 'cf/src').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [Parameter(Mandatory)][string]$SourceRelPath,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $root = $Context.RepoRoot
    $sourceFull = Join-Path $root ($SourceRelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "EDT-дерево '$SourceRelPath' не знайдено під $root."
    }

    # Запобіжник 1/4: брудна робоча копія (успадковано з repo-migration, §9.2, task-3-brief.md
    # Step 3). Весь репозиторій, а не лише SourceRelPath/TargetRoot — той самий обсяг перевірки,
    # що docs/migration/legacy-gitsync-repo.md крок 1 і Merge-KitBranchInto (GitMerge.psm1).
    $status = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'status', '--porcelain')
    if ($status.ExitCode -ne 0) { throw "git status завершився з кодом $($status.ExitCode): $($status.Stderr)" }
    $dirty = @($status.Stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($dirty.Count -gt 0) {
        $shown = @($dirty | Select-Object -First 5)
        $more = $dirty.Count - $shown.Count
        $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
        throw ("Робоча копія не чиста — rename-edt переписує дерево через git mv і не запускається на " +
               "незакомічених змінах (успадковано з repo-migration, §9.2). Незакомічені шляхи:`n$detail`n" +
               'Закомітьте або сховайте зміни (git stash) і повторіть.')
    }

    # Запобіжник 2/4 (C-B, рев'ю раунду 1): невідстежувані чи ігноровані файли В ДЕРЕВІ ДЖЕРЕЛА.
    # git ls-files --others (БЕЗ --exclude-standard) показує І звичайні untracked, І ігноровані —
    # саме такий, ширший за git status, погляд потрібен тут: план будується з диска
    # (Get-ChildItem), а git mv/rm працюють лише з тим, що git РЕАЛЬНО відстежує. Файл, невидимий
    # цій перевірці, але видимий обходу диска — це і є дірка, яку C-B відтворив: "чисто" за
    # запобіжником 1/4 (бо ігнороване НЕ входить у git status), але падає посеред git rm.
    $others = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'ls-files', '--others', '-z', '--', $SourceRelPath)
    if ($others.ExitCode -ne 0) { throw "git ls-files --others завершився з кодом $($others.ExitCode): $($others.Stderr)" }
    $untracked = @($others.Stdout -split "`0" | Where-Object { $_ -ne '' })
    if ($untracked.Count -gt 0) {
        $shown = @($untracked | Select-Object -First 10)
        $more = $untracked.Count - $shown.Count
        $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
        throw ("У '$SourceRelPath' є $($untracked.Count) файл(ів), яких git НЕ відстежує (невідстежувані або " +
               "ігноровані .gitattributes/.gitignore) — git mv/rm працюють лише з відстеженими шляхами, і план, " +
               "побудований з диска, розійшовся б із тим, що git реально може перейменувати чи видалити:`n$detail`n" +
               'Або зробіть ці файли частиною дерева (приберіть з .gitignore і git add), або видаліть їх із диска ' +
               'вручну (наприклад, службові артефакти платформи), і повторіть.')
    }

    # Запобіжник 3/4: політика тексту на ЦІЛІ (Test-GitTextPolicy — GitOutput.psm1, вже написана,
    # context.md §1). Перевіряє ЕФЕКТИВНИЙ атрибут через git check-attr, не текст .gitattributes.
    if (-not (Test-GitTextPolicy -RepoRoot $root -Path $TargetRoot)) {
        throw ("Політика тексту не діє на '$TargetRoot' (git check-attr text дає щось інше за 'unset') — " +
               'наступний git add конвертує кінці рядків, і побайтова рівність зі сховищем (§9.2 крок 5) ' +
               'мовчки не досягнеться (спайк 2026-09-09, docs/migration/2026-09-09-history-spike.md). ' +
               'Політику пише крок онбордингу (templates/gitattributes, docs/text-policy.md) — виконайте ' +
               'його спершу і повторіть; rename-edt свідомо не пише .gitattributes сама.')
    }

    $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath $SourceRelPath -TargetRoot $TargetRoot

    Write-Host "Перейменування EDT -> Designer: $SourceRelPath -> $TargetRoot"
    Write-Host "  Перейменувань: $($plan.Moves.Count)   Без відповідника: $($plan.Unmapped.Count)   Не з'ясовано: $($plan.Unresolved.Count)   Колізій: $($plan.Collisions.Count)"

    # M-7 (рев'ю раунду 1, посилено додатком координатора): друкувати ВСЕ (Unmapped, тоді
    # Unresolved, тоді Moves), тоді вже зупинятись на колізіях — раніше throw на колізіях стояв
    # ПЕРЕД друком Unmapped, і оператор, що робить прев'ю на дереві з колізіями (виміряно на
    # SMB_ukr_vendor: 17344 перейменувань, 1377 без відповідника, 2 колізії), не бачив ЖОДНОГО
    # з 1377 файлів, які підуть на видалення.
    if ($plan.Unmapped.Count -gt 0) {
        Write-Host '  Без відповідника (без -Apply лишаються на місці; під -Apply будуть видалені):' -ForegroundColor Yellow
        Write-KitRenameEdtList -Items $plan.Unmapped -Format { param($u) "$($u.From) — $($u.Reason)" }
    }
    if ($plan.Unresolved.Count -gt 0) {
        Write-Host '  Не з''ясовано (НІКОЛИ не видаляється — лишається на місці для окремого рішення):' -ForegroundColor Magenta
        Write-KitRenameEdtList -Items $plan.Unresolved -Format { param($u) "$($u.From) — $($u.Reason)" }
    }
    if ($plan.Moves.Count -gt 0) {
        Write-Host '  Перейменування:'
        Write-KitRenameEdtList -Items $plan.Moves -Format { param($m) "$($m.From) -> $($m.To)" }
    }

    # Властивість безпеки 2: непорожній Collisions зупиняє ДО будь-якого git mv — сам виклик
    # Get-KitEdtRenamePlan вище нічого на диску не змінив (чиста функція), тож зупинка тут
    # лишає дерево незмінним незалежно від того, скільки вже надруковано.
    if ($plan.Collisions.Count -gt 0) {
        Write-Host '  Колізії (кілька EDT-шляхів в один Designer-шлях) — перейменування НЕ виконується:' -ForegroundColor Red
        Write-KitRenameEdtList -Items $plan.Collisions -Format { param($c) "$($c.To)  <-  $(($c.From) -join ', ')" }
        throw ("$($plan.Collisions.Count) колізія(й) шляхів — виправте таблицю відповідності (EdtPaths.psm1) " +
               'і повторіть; чуже EDT-дерево перейменовувати не потрібно. Жоден git mv не виконано.')
    }

    if (-not $Apply) {
        Write-Host '  Це попередній перегляд. Для виконання додайте -Apply (git mv + видалення файлів без відповідника + коміт).' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0 }
    }

    if ($plan.Moves.Count -eq 0 -and $plan.Unmapped.Count -eq 0) {
        Write-Host '  Дерево порожнє або вже перейменоване — робити нема чого, коміт не створюється.' -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0 }
    }

    $boundaryTag = Get-KitRenameEdtBoundaryTag -RepoRoot $root
    if ($boundaryTag) {
        Write-Host "  Тег межі на HEAD: $boundaryTag" -ForegroundColor DarkGray
    } else {
        Write-Host '  На HEAD немає тега межі legacy/gitsync-* — це крок 2 онбордингу (skills/onboarding/SKILL.md §5.1), rename-edt його не створює.' -ForegroundColor DarkGray
    }

    # I-E (рев'ю раунду 1): SHA ДО будь-якої мутації — на будь-яку помилку нижче команда сама
    # відкочується сюди (git reset --hard), а не лишає репозиторій у напівстані з порадою,
    # яка для цього випадку хибна ("git stash" тут нічого не рятує — рухати нема чого, HEAD
    # не зрушив; правильна дія — відкіт, і команда робить його сама).
    $preHeadSha = (Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', 'HEAD')).Stdout.Trim()

    try {
        foreach ($item in $plan.Unmapped) {
            # C-A (рев'ю раунду 1): ":(literal)" — шлях іде як PATHSPEC, і без цього
            # git-метасимволи в імені файла ('[', ']', '*', '?' — легальні на NTFS) розкриваються:
            # `git rm -- 'a[bc].txt'` видаляє ВСІ файли, що збігаються з ГЛОБОМ "a[bc].txt"
            # (тобто ab.txt І ac.txt теж), а не лише файл із таким буквальним іменем.
            # Перевірено особисто (див. task-3-report.md): без ":(literal)" індекс спорожнів
            # увесь, з ним — лишились рівно ті два файли, яких глоб не мав чіпати.
            $rm = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'rm', '-f', '-q', '--', ":(literal)$($item.From)")
            if ($rm.ExitCode -ne 0) { throw "git rm -- '$($item.From)' завершився з кодом $($rm.ExitCode): $($rm.Stderr)" }
        }

        foreach ($move in $plan.Moves) {
            # git mv бере шлях ЛІТЕРАЛЬНО (не pathspec) — перевірено окремо (task-3-report.md),
            # ":(literal)" тут не потрібен.
            $targetFull = Join-Path $root ($move.To -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetFull) -Force | Out-Null
            $mv = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'mv', '--', $move.From, $move.To)
            if ($mv.ExitCode -ne 0) { throw "git mv '$($move.From)' -> '$($move.To)' завершився з кодом $($mv.ExitCode): $($mv.Stderr)" }
        }

        $dateStr = Get-Date -Format 'yyyy-MM-dd'
        $msgLines = [System.Collections.Generic.List[string]]::new()
        $msgLines.Add("Перейменування EDT-шляхів у Designer-шляхи ($SourceRelPath -> $TargetRoot)")
        $msgLines.Add('')
        $msgLines.Add('Вміст файлів лишається EDT-ним — байти замінить наступний коміт конверсії (kit sync).')
        if ($boundaryTag) { $msgLines.Add("Межа EDT-епохи (тег): $boundaryTag") }
        $msgLines.Add("Дата перейменування: $dateStr")
        if ($plan.Unmapped.Count -gt 0) { $msgLines.Add("Видалено без відповідника: $($plan.Unmapped.Count) файл(ів) — перелік у виводі команди.") }
        if ($plan.Unresolved.Count -gt 0) { $msgLines.Add("Не з'ясовано, лишено на місці: $($plan.Unresolved.Count) файл(ів) — потребують окремого рішення, перелік у виводі команди.") }

        # S-J (рев'ю раунду 1): файл повідомлення коміту — ПОЗА робочою копією репозиторію-споживача
        # (System.IO.Path]::GetTempFileName(), гарантовано поза будь-яким репо), а не в build/
        # усередині нього — той самий принцип, що StorageBranch.psm1:501-505 (worktree-коміти
        # sync кладуть commit-message.txt поруч із worktree, теж не всередині робочої копії).
        $msgFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $msgFile -Value ($msgLines -join "`n") -Encoding UTF8
            $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-F', $msgFile)
            if ($commit.ExitCode -ne 0) { throw "git commit завершився з кодом $($commit.ExitCode): $($commit.Stderr)" }
        } finally {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }

        # Додаток координатора до раунду 1, пункт "в": прибрати скелет тепер-порожніх тек після
        # успішного git mv/rm — ПІСЛЯ коміту (не впливає на git: git не відстежує порожні теки,
        # це прибирання диска, а не git-операція; Unresolved-файли лишають свої теки непорожніми,
        # їх це не зачіпає).
        Remove-KitEmptyDirectory -Path $sourceFull
    } catch {
        # I-E: відкіт до стану ДО мутації. Безпечно — HEAD іще не рухався (коміту не було, доки
        # не дійшли до рядка вище), тож reset --hard повертає рівно той самий комітований стан,
        # у якому команда стартувала; git mv/rm цієї спроби скасовуються повністю.
        $resetOut = Invoke-KitGitProcess -RepoRoot $root -Arguments @('reset', '--hard', $preHeadSha)
        if ($resetOut.ExitCode -ne 0) {
            throw ("Перейменування впало ($($_.Exception.Message)), і автоматичний відкіт (git reset --hard $preHeadSha) " +
                   "ТЕЖ не вдався (код $($resetOut.ExitCode): $($resetOut.Stderr)) — репозиторій лишається в напівстані, " +
                   "розберіться вручну: git status, git reset --hard $preHeadSha")
        }
        throw ("Перейменування впало та автоматично відкочено до стану перед запуском (git reset --hard $preHeadSha): " +
               "$($_.Exception.Message)")
    }

    $sha = (Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', 'HEAD')).Stdout.Trim()
    $summary = "  Готово: $($plan.Moves.Count) перейменовано, $($plan.Unmapped.Count) видалено без відповідника"
    if ($plan.Unresolved.Count -gt 0) { $summary += ", $($plan.Unresolved.Count) не з'ясовано (лишено на місці)" }
    Write-Host "$summary. Коміт $sha." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Sha = $sha; BoundaryTag = $boundaryTag }
}

Export-ModuleMember -Function Invoke-KitRenameEdt
