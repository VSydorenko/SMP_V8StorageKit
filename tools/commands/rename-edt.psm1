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

function Get-KitRenameEdtTreePaths {
    <#
    .SYNOPSIS
        Шляхи блобів, що існують у коміті -Sha під -RelPath. Порожній результат означає, що
        такого шляху в тому коміті НЕМАЄ (git не зберігає порожніх тек, тож "жодного блоба"
        і "теки не існує" — те саме).
    .DESCRIPTION
        Знахідка A (рев'ю раунду 4): відкіт мусить знати це ДО того, як покличе
        `git checkout <sha> -- <pathspec>`, бо checkout звіряє pathspec з деревом коміта і при
        неспівпадінні відмовляє АТОМАРНО — не відновивши нічого. Для дерева призначення, яке
        створює саме ця команда, неспівпадіння — норма першої міграції, а не виняток.

        `git ls-tree` (на відміну від checkout) на pathspec, який нічого не знайшов, не помиляється:
        порожній вивід, код 0 — перевірено. Другий ужиток того самого виклику — перелік цілей,
        які в коміті ВЖЕ БУЛИ: їх відкіт щойно відновив, і прибирати їх не можна.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$RelPath
    )
    # -z обов'язкове: імена в деревах 1С кириличні, а записи ділимо самі; -c core.quotepath=false —
    # правило репозиторію на кожен git-виклик, що друкує шляхи.
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-tree', '-r', '--name-only', '-z', $Sha, '--', $RelPath)
    if ($r.ExitCode -ne 0) {
        throw "git ls-tree $Sha -- '$RelPath' завершився з кодом $($r.ExitCode): $($r.Stderr)"
    }
    @($r.Stdout -split "`0" | Where-Object { $_ -ne '' })
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
        рев'ю раунду 1): будь-яка помилка посеред циклу — автоматичне відновлення на SHA,
        записаний ДО першої мутації. Це безпечно саме тому, що жоден коміт іще не додався (лише
        індекс/робоче дерево), і саме тому це ПРАВИЛЬНА відповідь на напівстан — на відміну від
        поради "git stash"/"закомітьте" запобіжника брудної копії вище (та порада для
        ЧУЖОГО безладу, що існував ДО виклику команди; тут безлад — наслідок власного збою
        команди, і команда прибирає за собою сама).

        Відновлення — АДРЕСНЕ (знахідка 1, рев'ю раунду 3), не `git reset --hard` на весь
        репозиторій: перша версія мала обсяг усього робочого каталогу, і відстежений файл,
        змінений людиною поза -SourceRelPath/-TargetRoot ПІД ЧАС проходу (вікно — весь прохід,
        до ~18 700 підпроцесів, 22 хвилини на живому дереві), зникав безслідно.

        Порядок відкоту (переписаний за знахідками A, B, E, F раунду 4 і знахідками 1, 3, 4
        раунду 5):
        1. `git ls-tree` питає, які з двох керованих шляхів узагалі є в $preHeadSha. Це не
           перестраховка: `git checkout <tree-ish> -- <pathspec>` при неспівпадінні pathspec із
           деревом коміта відмовляє АТОМАРНО, а -TargetRoot у $preHeadSha НЕ ІСНУЄ — його
           створює саме ця команда. Безумовний виклик з обома шляхами (як було до раунду 4) у
           живій формі першої міграції не відновлював НІЧОГО.
        2. `git checkout $preHeadSha -- <лише наявні шляхи>` повертає вміст того, що існувало.
        3. Прибираються цілі ФАКТИЧНО ВИКОНАНИХ перейменувань ($executedMoveTargets), а не весь
           $plan.Moves і не "все, чого не було в SHA" через `git diff --diff-filter=A`. Обидві
           ширші форми стирали чуже: під `--diff-filter=A` потрапляв файл, який ЛЮДИНА встигла
           `git add` у піддерево призначення під час проходу (знахідка B раунду 4), а під
           $plan.Moves — файл за адресою перейменування, до якого цикл НЕ ДІЙШОВ, тобто саме той,
           через який `git mv` і впав на "destination exists" (знахідка 1 раунду 5).
        4. `git diff --quiet` звіряє, що різниці між $preHeadSha і піддеревами більше немає.
           Код 0/1 — відповідь; будь-який інший означає, що перевірка не виконалась, і це збій
           відкоту, а не мовчазний успіх (знахідка 4 раунду 5).
        Косметичне прибирання порожніх тек — ЛИШЕ після успішного кроку 4 (знахідка E): інакше
        зламаний відкіт додатково прибирав скелет src/, і дерево виглядало мігрованим.
        Уся ця послідовність — у власному try/catch (знахідка F): Invoke-KitGitProcess стартує
        процес і може кинути (немає git у PATH, вичерпані дескриптори), а тоді оригінальна
        причина падіння — єдине свідчення того, що сталось на 22-хвилинному проході, — губилась
        би за вторинною помилкою.
    .PARAMETER Workspace
        M-6 (фінальне рев'ю блоку): приймається лише заради спільного контракту диспетчера
        (kit.ps1 передає -Workspace/-Source кожній команді) і НІЧОГО тут не робить — на відміну
        від sync/dump/verify, де ними відбирають джерела маніфесту. Ця команда джерел не
        відбирає взагалі: що перейменовувати й куди, повністю задають -SourceRelPath і
        -TargetRoot, які викликач уже розв'язав з v8project.yaml (онбординг, розділ 5.1).
    .PARAMETER Source
        Те саме, що -Workspace: приймається за контрактом диспетчера, не використовується.
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
    $targetFullRoot = Join-Path $root ($TargetRoot -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    # Знахідка 3 (рев'ю раунду 3): PathSafety.psm1 — «спільний запобіжник перед КОЖНИМ
    # рекурсивним видаленням у tools/», і його кличуть усі інші такі місця (GitMerge,
    # StorageBranch, StorageImprint, StoragePlatform, TreeCompare, V8, canon, dump, provision,
    # sync, verify). Remove-KitEmptyDirectory нижче теж рекурсивно видаляє в ЧУЖОМУ репозиторії —
    # без цієї перевірки -SourceRelPath виду '.' чи '../..' вивів би обхід за межі репозиторію.
    # Перевіряється ОБОХ коренів одразу, ще до першого git-виклику.
    Assert-SafeWorkPath -Path $sourceFull -MustBeUnder $root -Description "EDT-дерево джерела (-SourceRelPath '$SourceRelPath')"
    Assert-SafeWorkPath -Path $targetFullRoot -MustBeUnder $root -Description "дерево призначення (-TargetRoot '$TargetRoot')"
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
    # відкочується сюди, а не лишає репозиторій у напівстані з порадою, яка для цього випадку
    # хибна ("git stash" тут нічого не рятує — рухати нема чого, HEAD не зрушив; правильна дія —
    # відкіт, і команда робить його сама). Знахідка 6 (рев'ю раунду 3): код виходу перевіряється
    # явно — це вхід ЄДИНОЇ руйнівної команди нижче, і саме тут дешевше зупинитись, ніж пояснювати
    # плутанину пізніше (порожній/неправильний SHA у відновленні).
    $preHeadShaResult = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', 'HEAD')
    if ($preHeadShaResult.ExitCode -ne 0) {
        throw "git rev-parse HEAD (перед мутацією) завершився з кодом $($preHeadShaResult.ExitCode): $($preHeadShaResult.Stderr) — без SHA відновлення неможливе, зупиняюсь до будь-якої мутації."
    }
    $preHeadSha = $preHeadShaResult.Stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($preHeadSha)) {
        throw 'git rev-parse HEAD (перед мутацією) повернув порожній результат при коді виходу 0 — без SHA відновлення неможливе, зупиняюсь до будь-якої мутації.'
    }

    # Знахідка 1 (рев'ю раунду 5): перелік ФАКТИЧНО ВИКОНАНИХ перейменувань — саме його, а не
    # $plan.Moves, прибирає відкіт. Різниця не теоретична: для перейменування, до якого цикл нижче
    # не дійшов, файл за адресою $move.To створив НЕ kit, і `git rm -f` знищив би застейджений
    # чужий файл із диска й індексу. Найгірше, що це рівно та форма, яка ВИКЛИКАЄ відкіт: `git mv`
    # падає на "destination exists" саме тоді, коли хтось зайняв цільовий шлях. Оголошено ДО try,
    # щоб catch бачив список незалежно від того, на якому кроці стався збій.
    $executedMoveTargets = [System.Collections.Generic.List[string]]::new()

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
            $executedMoveTargets.Add($move.To)
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
            # I-5 (фінальне рев'ю блоку): коміт ОБМЕЖЕНИЙ двома керованими піддеревами. Global
            # Constraints (уроки B1, п. 2) вимагають дослівно «git add <явний перелік> + git commit
            # --only -- <ті самі шляхи>; ніяких -a/-A», а голий `git commit -F` брав ВЕСЬ індекс:
            # чужий файл, застейджений ПІД ЧАС проходу, мовчки їхав у коміт перейменування, і
            # рядок «Готово: N перейменовано… Коміт …» про нього не казав нічого. Вікно не
            # гіпотетичне — увесь ешелон відкоту цієї команди побудований саме на тому, що людина
            # діє під час 22-хвилинного проходу; успішний шлях лишався без цього захисту.
            # ":(literal)" — те саме правило, що на git rm вище: git-метасимволи в імені (легальні
            # на NTFS) інакше розкрились би як глоб.
            # -TargetRoot додається, ЛИШЕ коли туди справді щось перенесено: pathspec, що не збігся
            # з жодним відомим git шляхом, валить сам `git commit` («did not match any file(s)
            # known to git» — перевірено окремим прогоном git), а прохід із самими лише видаленнями
            # Unmapped дерева призначення не створює взагалі. -SourceRelPath збігається завжди:
            # видалені й перейменовані звідти шляхи git бачить через накладання HEAD на індекс.
            # Свідома плата за `--only`: для НАЗВАНИХ шляхів git бере вміст РОБОЧОГО ДЕРЕВА, тож
            # незастейджена правка файлу ВСЕРЕДИНІ цих двох піддерев тепер поїде в коміт (раніше
            # лишалась би незакоміченою) — перевірено окремим прогоном git. Це узгоджено з рештою
            # команди, а не виняток: відкіт нижче так само чекаутить обидва піддерева з $preHeadSha,
            # тобто команда й до цього володіла ними цілком, а вміст усе одно заміщає крок 5
            # (коміт конверсії). Розширення обсягу — лише на ці два шляхи; будь-що поза ними
            # (застейджене чи ні) коміт більше не бачить, і саме це й було метою.
            $commitPaths = @(":(literal)$SourceRelPath")
            if ($executedMoveTargets.Count -gt 0) { $commitPaths += ":(literal)$TargetRoot" }
            $commitArgs = @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-F', $msgFile, '--only', '--') + $commitPaths
            $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments $commitArgs
            if ($commit.ExitCode -ne 0) { throw "git commit завершився з кодом $($commit.ExitCode): $($commit.Stderr)" }
        } finally {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Знахідка 1 (рев'ю раунду 3): ЦЕ БУВ `git reset --hard $preHeadSha` — обсяг усього
        # РЕПОЗИТОРІЮ. Відстежений файл, змінений людиною поза -SourceRelPath/-TargetRoot ПІД
        # ЧАС проходу (вікно — весь прохід, до ~18 700 підпроцесів, 22 хвилини на живому дереві),
        # зникав безслідно. Властивість тепер інша: відкіт торкається ЛИШЕ цих двох піддерев.
        #
        # Знахідка A (рев'ю раунду 4): checkout більше не викликається безумовно з обома шляхами.
        # `git checkout <tree-ish> -- <pathspec>` звіряє pathspec із деревом коміта і при
        # неспівпадінні відмовляє АТОМАРНО, не відновивши НІЧОГО, — а -TargetRoot у $preHeadSha
        # не існує, бо його створює саме ця команда. Тобто в живій формі ПЕРШОЇ міграції старий
        # відкіт не спрацьовував узагалі, і на SMB_ukr_vendor репозиторій лишався б із 17 366
        # застейдженими перейменуваннями. Тести цього не бачили, бо фікстура завжди створювала
        # дерево призначення в HEAD (виправлено: New-KitFakeRepo -NoSourceTrees).
        #
        # Знахідка B (рев'ю раунду 4) і знахідка 1 (раунду 5): прибираються цілі ФАКТИЧНО
        # ВИКОНАНИХ перейменувань, а не "все, чого не було в SHA" (git diff --diff-filter=A) і не
        # весь $plan.Moves. Перша форма стирала файл, який ЛЮДИНА встигла git add у піддерево
        # призначення під час проходу; друга — файл за адресою перейменування, до якого цикл НЕ
        # ДІЙШОВ, тобто рівно той, через який `git mv` і впав ("destination exists"). Обидва рази
        # команда рапортувала "решта репозиторію не зачеплена". Команда знає, що зробила —
        # виводити це з плану не треба.
        #
        # Знахідка F (рев'ю раунду 4): весь відкіт — у власному try/catch. Invoke-KitGitProcess
        # СТАРТУЄ процес і може кинути (немає git у PATH, вичерпані дескриптори); без цього
        # обгортання оригінальна причина падіння ($failureMessage) губилась би за вторинною
        # помилкою — на 22-хвилинному проході це втрата єдиного свідчення, що саме пішло не так.
        $failureMessage = $_.Exception.Message
        $pruneErrors = [System.Collections.Generic.List[string]]::new()
        $restorePaths = @()
        $targetInSha = @()
        $shaProbed = $false
        $verifyExitCode = $null
        try {
            $sourceInSha = @(Get-KitRenameEdtTreePaths -RepoRoot $root -Sha $preHeadSha -RelPath $SourceRelPath)
            $targetInSha = @(Get-KitRenameEdtTreePaths -RepoRoot $root -Sha $preHeadSha -RelPath $TargetRoot)
            $shaProbed = $true
            if ($sourceInSha.Count -gt 0) { $restorePaths += $SourceRelPath }
            if ($targetInSha.Count -gt 0) { $restorePaths += $TargetRoot }

            if ($restorePaths.Count -gt 0) {
                $restore = Invoke-KitGitProcess -RepoRoot $root -Arguments (@('-c', 'core.quotepath=false', 'checkout', $preHeadSha, '--') + $restorePaths)
                if ($restore.ExitCode -ne 0) {
                    $pruneErrors.Add("git checkout $preHeadSha -- $($restorePaths -join ' ') завершився з кодом $($restore.ExitCode): $($restore.Stderr)")
                }
            }

            # checkout ніколи не видаляє (задокументована поведінка git), тож цілі, які створила
            # САМА команда, прибираємо самі — і рівно їх: $executedMoveTargets, а не $plan.Moves
            # (знахідка 1, рев'ю раунду 5). ":(literal)" — C-A (рев'ю раунду 1): шлях іде як
            # PATHSPEC, і без цього '[', ']', '*', '?' в імені розкрились би глобом.
            #
            # Фільтр $targetInShaSet — ЖИВИЙ запобіжник, а не страховка на майбутнє (виправлено за
            # пере-рев'ю раунду 5; попередня редакція цього коментаря стверджувала, що спрацювати
            # він не може, і це було ХИБНО в небезпечний бік — прочитавши таке, наступний читач
            # має підставу його прибрати).
            #
            # Він спрацьовує так: ціль БУЛА в HEAD, але щось звільнило шлях У ВІКНІ ПРОХОДУ —
            # людина видалила закомічений файл під час 22 хвилин роботи. Тоді `git mv` у цей шлях
            # УДАЄТЬСЯ, ціль потрапляє і в $executedMoveTargets, і в $targetInSha, і без фільтра
            # відкіт зніс би файл, що був у комміті. Відтворено сценарієм у пере-рев'ю раунду 5.
            #
            # Хибність попередньої редакції показова: обидві її посилки (`git mv` не перезаписує
            # наявний b; запобіжник 1/4 не пускає на брудній копії) стосуються стану ДО запуску,
            # тоді як увесь ешелон раундів 4-5 будується на тому, що людина діє ПІД ЧАС проходу.
            # Тесту саме на цю гілку немає — вона тримається на цьому фільтрі й на цьому поясненні.
            # Ціна помилки тут (видалити файл, що був у комміті) — найвища в усій команді.
            $targetInShaSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$targetInSha, [System.StringComparer]::Ordinal)
            foreach ($movedTo in $executedMoveTargets) {
                if ($targetInShaSet.Contains($movedTo)) { continue }
                $rmBack = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'rm', '-f', '-q', '--ignore-unmatch', '--', ":(literal)$movedTo")
                if ($rmBack.ExitCode -ne 0) { $pruneErrors.Add("git rm -- '$movedTo': код $($rmBack.ExitCode): $($rmBack.Stderr)") }
            }

            # Приймальна перевірка: обидва піддерева справді повернулись до стану $preHeadSha —
            # "звірити, що ці два піддерева справді чисті, і доповісти, якщо ні" (вимога координатора).
            # Код 0 — різниці немає, 1 — є; будь-що інше означає, що сама перевірка не виконалась
            # (знахідка 4, рев'ю раунду 5: ця гілка була без тесту й мовчки трактувалась як успіх).
            $verify = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'diff', '--quiet', $preHeadSha, '--', $SourceRelPath, $TargetRoot)
            $verifyExitCode = $verify.ExitCode
            if ($verifyExitCode -notin 0, 1) {
                $pruneErrors.Add("git diff --quiet $preHeadSha -- завершився з кодом ${verifyExitCode}: $($verify.Stderr) — приймальну перевірку відкоту виконати не вдалося, стан піддерев не підтверджено")
            }
        } catch {
            $pruneErrors.Add("сам відкіт кинув виняток: $($_.Exception.Message)")
        }

        # Знахідка A.2 (рев'ю раунду 4): у повідомленні про невдалий відкіт мусить бути ТОЧНА
        # команда відновлення, а не лише діагностичні git diff/git status. HEAD не рухався —
        # саме тому ручне відновлення можливе, і саме тому його треба підказати.
        #
        # Знахідка 3 (рев'ю раунду 5): рецепт мусить ВІДНОВЛЮВАТИ стан в ОБОХ формах. Попередній
        # у формі "ціль у SHA була" складався з самого лише checkout — а checkout нічого не
        # видаляє, тож цілі, створені проходом і відсутні в SHA, лишались 'A' в індексі й на
        # диску: підказана команда стан НЕ відновлювала, а попередження для цієї форми ще й не
        # друкувалось. Тепер рецепт однаковий для обох форм і читається як одне правило: СПЕРШУ
        # прибрати дерево призначення цілком, ТОДІ відновити з коміта те, що в ньому було.
        # Порядок обов'язковий — checkout ПІСЛЯ rm, не навпаки.
        $manual = [System.Collections.Generic.List[string]]::new()
        $manual.Add("  git rm -r -f --ignore-unmatch -- ':(literal)$TargetRoot'")
        if ($shaProbed) {
            if ($restorePaths.Count -gt 0) { $manual.Add("  git checkout $preHeadSha -- $($restorePaths -join ' ')") }
        } else {
            $manual.Add("  git ls-tree -d $preHeadSha -- '$SourceRelPath' '$TargetRoot'")
            $manual.Add("  git checkout $preHeadSha -- <лише ті з двох шляхів, що вивелись вище>")
        }
        $manual.Add('  git status')
        # M-5 (фінальне рев'ю блоку): попередження стоїть ПЕРЕД рецептом, а не після нього. Обидва
        # throw'и нижче стверджують «команда прибирає лише власні цілі й чужого не чіпає» — і це
        # правда про АВТОМАТИЧНИЙ відкіт, але рецепт нижче поводиться інакше: його перша команда
        # знищує дерево '$TargetRoot' цілком. Попередження, надруковане ПІСЛЯ команд, читач бачить,
        # коли вже виконав першу з них.
        $manualText = "HEAD не рухався ($preHeadSha), коміту не створено — стан відновлюється вручну.`n" +
                      "УВАГА: рецепт нижче ширший за автоматичний відкіт — його ПЕРША команда прибирає ВСЕ дерево '$TargetRoot' " +
                      '(друга поверне з коміту те, що в ньому було, але доданого вами під час проходу в коміті немає); ' +
                      "якщо ви додали туди власні файли, спершу подивіться git status.`n" +
                      "Команди по порядку:`n" +
                      ($manual -join "`n")

        if ($pruneErrors.Count -gt 0 -or $null -eq $verifyExitCode) {
            throw ("Перейменування впало ($failureMessage), і адресний відкіт '$SourceRelPath'/'$TargetRoot' до " +
                   "$preHeadSha ТЕЖ не вдався повністю ($($pruneErrors -join '; ')).`n$manualText")
        }
        if ($verifyExitCode -eq 1) {
            throw ("Перейменування впало ($failureMessage), і після відкату '$SourceRelPath'/'$TargetRoot' до " +
                   "$preHeadSha досі є розбіжність (git diff $preHeadSha -- $SourceRelPath $TargetRoot показав би, яка; " +
                   "типова причина — файл, доданий у ці піддерева ззовні під час проходу: команда прибирає лише власні " +
                   "цілі й чужого не чіпає).`n$manualText")
        }

        # Знахідка 7 (рев'ю раунду 3): checkout не прибирає НЕВІДСТЕЖУВАНІ порожні теки — New-Item
        # вище міг створити частину дерева -TargetRoot, яку відкіт лишає порожнім скелетом.
        # Знахідка E (рев'ю раунду 4): це прибирання стоїть ПІСЛЯ приймальної перевірки і
        # виконується ЛИШЕ коли відкіт вдався. Раніше воно йшло перед перевіркою і в зламаному
        # сценарії прибирало скелет src/ — саме це й робило напівмігроване дерево схожим на
        # успішно мігроване, а враження "щось уже зроблено" штовхає людину на неправильну дію.
        try { Remove-KitEmptyDirectory -Path $sourceFull } catch {}
        try { Remove-KitEmptyDirectory -Path $targetFullRoot } catch {}

        # Знахідка H (рев'ю раунду 4): формулювання звужене до фактичної гарантії. `reset --hard`
        # умів повернути й HEAD; `checkout -- <шляхи>` — ні. Практично коміт — остання операція в
        # try, тож HEAD і не рухається, але обіцяти "стан перед запуском" ширше за те, що робиться.
        throw ("Перейменування впало та відкочено: вміст '$SourceRelPath' і '$TargetRoot' повернуто до стану коміту " +
               "$preHeadSha (індекс і робоче дерево цих двох піддерев; HEAD не рухався — коміту не створювалось), " +
               "решта репозиторію не зачеплена: $failureMessage")
    }

    # Знахідка 2 (рев'ю раунду 3): прибирання порожніх тек — ПОЗА try/catch мутації і ПІСЛЯ
    # успішного коміту. Раніше стояло ВСЕРЕДИНІ того самого try, і виняток у суто косметичному
    # прибиранні (напр. антивірус тримає щойно звільнену теку) відкотив би вже УСПІШНИЙ,
    # уже закомічений результат — на 17 тисячах файлів це ще один 22-хвилинний прохід
    # заради помилки, що не мала жодного стосунку до самого перейменування. Збій тут —
    # повідомлення, не відкіт: коміт уже відбувся, дерево вже правильне за вмістом git.
    try {
        Remove-KitEmptyDirectory -Path $sourceFull
    } catch {
        Write-Host "  Попередження: не вдалось прибрати порожні теки під '$SourceRelPath' ($($_.Exception.Message)) — косметика, коміт уже завершено успішно." -ForegroundColor Yellow
    }

    # I-6 (фінальне рев'ю блоку): тут стояв власний `rev-parse` без перевірки коду виходу — друга,
    # слабша реалізація правила, яке рядок 301 вище дотримує, а Get-KitCommitSha (StorageBranch.psm1)
    # існує саме під нього: «rev-parse з перевіркою коду виходу — правило Global Constraints без
    # винятків, навіть одразу після успішного коміту». Ціна розбіжності: після ~18 700 підпроцесів
    # git на Windows ненульовий код давав порожній $sha, команда друкувала «Коміт .» і повертала
    # Sha = '' — коміт є, а SHA втрачено, хоч він потрібен скілу для абзацу в CLAUDE.md репозиторію
    # і для `git blame <коміт-перейменування>`. Це ж закриває M-8: .Trim() на можливому $null
    # перетворив би вдалий 22-хвилинний прохід на видимий збій.
    try {
        $sha = Get-KitCommitSha -RepoRoot $root -Ref HEAD
    } catch {
        throw ("Коміт перейменування СТВОРЕНО, але прочитати його SHA не вдалося: $($_.Exception.Message) — " +
               'дерево вже перейменоване, повторний запуск не потрібен (він побачить порожнє дерево і нічого не зробить); ' +
               'SHA коміту візьміть окремо: git -C <репозиторій> rev-parse HEAD.')
    }
    $summary = "  Готово: $($plan.Moves.Count) перейменовано, $($plan.Unmapped.Count) видалено без відповідника"
    if ($plan.Unresolved.Count -gt 0) { $summary += ", $($plan.Unresolved.Count) не з'ясовано (лишено на місці)" }
    Write-Host "$summary. Коміт $sha." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Sha = $sha; BoundaryTag = $boundaryTag }
}

Export-ModuleMember -Function Invoke-KitRenameEdt
