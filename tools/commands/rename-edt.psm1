#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module ризикував би перезавантаженням (docs/follow-ups.md §5).

function Write-KitRenameEdtList {
    <# .SYNOPSIS Unmapped/Unresolved/Collisions друкуються ЦІЛКОМ, не лічильником — властивість безпеки (§9.2). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][scriptblock]$Format)
    foreach ($item in $Items) { Write-Host "    $(& $Format $item)" }
}

function Remove-KitEmptyDirectory {
    <#
    .SYNOPSIS
        Прибирає теки, що спорожніли після git mv/rm: git їх не відстежує, а скелет на диску
        потрапив би в наступний обхід Get-ChildItem того самого дерева.
    .DESCRIPTION
        Видаляє лише справді порожні теки (знизу вгору) і ніколи не видаляє файл — теки з
        лишеними Unresolved-файлами лишаються.
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
        Відкіт мусить знати це ДО `git checkout <sha> -- <pathspec>`: checkout при неспівпадінні
        pathspec з деревом коміта відмовляє АТОМАРНО, не відновивши нічого, а дерева призначення
        на першій міграції в коміті ще немає. `git ls-tree` на такий pathspec дає порожній вивід
        і код 0. Другий ужиток — перелік цілей, що в коміті вже були: відкіт їх відновив, і
        прибирати їх не можна.
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
        Тег межі EDT-епохи, що вже є в репозиторії — лише ЧИТАННЯ, для рядка в повідомленні коміту.
    .DESCRIPTION
        Тег ставить крок 2 переходу (skills/onboarding/references/gitsync-migration.md, «Тег межі»)
        один раз на репозиторій; команда, що рухає лише свої два піддерева, git-реф не пише.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    # Не `--points-at HEAD`: тег стоїть на останньому gitsync-коміті, а HEAD — коміт онбордингу
    # після нього. Тож питаємо «чи тег межі взагалі є в репозиторії».
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('tag', '-l', 'legacy/gitsync-*')
    if ($r.ExitCode -ne 0) { throw "git tag --points-at HEAD завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    @($r.Stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Sort-Object -Culture ([System.Globalization.CultureInfo]::InvariantCulture) | Select-Object -First 1)
}

function Invoke-KitRenameEdt {
    <#
    .SYNOPSIS
        Коміт перейменування EDT-шляхів у Designer-шляхи (§9.2): git mv кожного файлу на його
        Designer-шлях; вміст лишається EDT-ним — його замінить наступний коміт конверсії
        (kit sync). Мета — безперервний git log --follow і git blame.
    .DESCRIPTION
        Команда переписує чуже дерево. Дві гарантії безпеки:
        1. Жоден файл не видаляється без показу людині — Unmapped і Unresolved друкуються
           повним переліком завжди (і в прев'ю, і під -Apply, і за колізій); git rm — лише для
           Unmapped і лише під -Apply. Unresolved НІКОЛИ не видаляється: Get-KitEdtRenamePlan
           розрізняє «знаємо, що не потрібне» (Unmapped) і «не знаємо, що це» (Unresolved).
        2. Колізія (кілька EDT-шляхів в один Designer-шлях) зупиняє до першої мутації.

        Префлайт строгий: -SourceRelPath і -TargetRoot викликач уже розв'язав із маніфесту й
        воркспейсу (gitsync-migration.md, крок 1); сама команда маніфесту не читає.

        Запобіжники перед мутацією, по порядку:
        - брудна робоча копія репозиторію (git status --porcelain);
        - невідстежувані чи ігноровані файли в дереві джерела (git ls-files --others): план
          будується з диска, а git mv/rm працюють лише з відстеженим — без цього падіння
          посеред циклу видалення (типово .gitignore, що ховає ConfigDumpInfo.xml);
        - Test-GitTextPolicy на -TargetRoot: якщо text не unset, git add конвертує кінці
          рядків, і побайтова рівність зі сховищем (§9.2 крок 5) мовчки не досягнеться.
          .gitattributes пише онбординг, команда лише перевіряє ефективний атрибут.

        Обсяг коміту — два піддерева (`git commit --only -- <джерело> [<ціль>]`) плюс усе, що
        застейджить pre-commit-хук споживача (git кличе його з тимчасовим індексом, `--only`
        цього не відсіює; обхід — лише `--no-verify`, чого kit свідомо не робить). Закрито це
        налаштуванням: install-hooks ставить core.hooksPath .githooks, а роздаваний pre-commit
        нічого не стейджить.

        Мутація (git rm, git mv, коміт) — у try/catch: будь-яка помилка відкочує стан на SHA,
        записаний до першої мутації. Відкіт безпечний, бо коміту ще немає, і він АДРЕСНИЙ —
        лише два піддерева, не `git reset --hard`: людина може правити інші файли під час
        багатохвилинного проходу. Порядок відкоту:
        1. `git ls-tree` — які з двох шляхів є в $preHeadSha (checkout на відсутній pathspec
           відмовляє атомарно, не відновивши нічого).
        2. `git checkout $preHeadSha -- <лише наявні шляхи>`.
        3. Прибрати цілі ФАКТИЧНО виконаних перейменувань ($executedMoveTargets) — не весь
           $plan.Moves і не `git diff --diff-filter=A`: обидві ширші форми стирають чуже
           (файл, доданий людиною під час проходу, або той, через який git mv і впав).
        4. `git diff --quiet` — код 0/1 відповідь; інший код — збій відкоту, не успіх.
        Порожні теки прибираються лише після успішного кроку 4, інакше зламаний відкіт
        виглядав би мігрованим деревом. Сам відкіт — у власному try/catch, щоб вторинна
        помилка не сховала первинну причину.
    .PARAMETER Workspace
        Приймається лише за спільним контрактом диспетчера й не використовується: що й куди
        перейменовувати, задають -SourceRelPath і -TargetRoot.
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
        # -Workspace і -Source не оголошено: дерево адресують явні -SourceRelPath і -TargetRoot.
        # Диспетчер на переданий -Workspace/-Source зупиняється з поясненням.
        [bool]$Apply,
        [Parameter(Mandatory)][string]$SourceRelPath,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $root = $Context.RepoRoot
    $sourceFull = Join-Path $root ($SourceRelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $targetFullRoot = Join-Path $root ($TargetRoot -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    # Спільний запобіжник перед рекурсивним видаленням (PathSafety.psm1): Remove-KitEmptyDirectory
    # видаляє в чужому репозиторії, і -SourceRelPath виду '.' чи '../..' вивів би обхід за його
    # межі. Обидва корені — до першого git-виклику.
    Assert-SafeWorkPath -Path $sourceFull -MustBeUnder $root -RepoRoot $root -Description "EDT-дерево джерела (-SourceRelPath '$SourceRelPath')"
    Assert-SafeWorkPath -Path $targetFullRoot -MustBeUnder $root -RepoRoot $root -Description "дерево призначення (-TargetRoot '$TargetRoot')"
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "EDT-дерево '$SourceRelPath' не знайдено під $root."
    }

    # Запобіжник 1/4: брудна робоча копія (§9.2) — весь репозиторій, той самий обсяг, що в
    # Merge-KitBranchInto (GitMerge.psm1).
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

    # Запобіжник 2/4: невідстежувані чи ігноровані файли в дереві джерела. git ls-files --others
    # БЕЗ --exclude-standard бачить і ігноровані, яких немає в git status: план будується з диска,
    # а git mv/rm працюють лише з відстеженим — такий файл валив би прохід посеред git rm.
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

    # Запобіжник 3/4: політика тексту на цілі — ефективний атрибут (git check-attr), не текст .gitattributes.
    if (-not (Test-GitTextPolicy -RepoRoot $root -Path $TargetRoot)) {
        throw ("Політика тексту не діє на '$TargetRoot' (git check-attr text дає щось інше за 'unset') — " +
               'наступний git add конвертує кінці рядків, і побайтова рівність зі сховищем (§9.2 крок 5) ' +
               'мовчки не досягнеться (виміряно спайком безперервності історії, 2026-09-09). ' +
               'Політику пише крок онбордингу (templates/gitattributes, docs/text-policy.md) — виконайте ' +
               'його спершу і повторіть; rename-edt свідомо не пише .gitattributes сама.')
    }

    # Порада, не запобіжник: без -text на джерелі якість виявлення перейменування залежить від
    # core.autocrlf машини (R092..R100 — усе вище порогу 50 %, --follow працює), тож прохід не
    # зупиняється. Рематеріалізація в пораді обов'язкова: сам коміт -text робить CRLF-файли на
    # диску «зміненими», і наступний запуск упреться в запобіжник 1/4.
    if (-not (Test-GitTextPolicy -RepoRoot $root -Path $SourceRelPath)) {
        Write-Host ("  [!] На джерелі '$SourceRelPath' не діє -text. Прохід відбудеться, але якість виявлення " +
                    'перейменування залежатиме від core.autocrlf цієї машини (від R092 до R100). Щоб зробити її ' +
                    "детермінованою: додайте '$SourceRelPath/** -text' у .gitattributes, закомітьте, " +
                    "тоді рематеріалізуйте дерево (rm -rf '$SourceRelPath' && git checkout -- '$SourceRelPath') " +
                    'і повторіть. Без рематеріалізації наступний запуск зупиниться на брудній робочій копії.') -ForegroundColor Yellow
    }

    $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath $SourceRelPath -TargetRoot $TargetRoot

    Write-Host "Перейменування EDT -> Designer: $SourceRelPath -> $TargetRoot"
    Write-Host "  Перейменувань: $($plan.Moves.Count)   Без відповідника: $($plan.Unmapped.Count)   Не з'ясовано: $($plan.Unresolved.Count)   Колізій: $($plan.Collisions.Count)"

    # Спершу друкується ВСЕ (Unmapped, Unresolved, Moves), і лише тоді зупинка на колізіях —
    # інакше прев'ю дерева з колізіями не показало б файлів, що підуть на видалення.
    if ($plan.Unmapped.Count -gt 0) {
        Write-Host '  Без відповідника (без -Apply лишаються на місці; під -Apply будуть видалені):' -ForegroundColor Yellow
        Write-KitRenameEdtList -Items $plan.Unmapped -Format { param($u) "$($u.From) — $($u.Reason)" }
    }
    if ($plan.Unresolved.Count -gt 0) {
        Write-Host '  Не з''ясовано (НІКОЛИ не видаляється — лишається на місці для окремого рішення):' -ForegroundColor Magenta
        Write-KitRenameEdtList -Items $plan.Unresolved -Format { param($u) "$($u.From) — $($u.Reason)" }
        # Ручний git mv з цього переліку падає з "No such file or directory", коли теки
        # призначення ще немає, і читається як зникле джерело. Сама команда такі файли не
        # переносить: доведену відповідність від вгаданої вона не відрізнить.
        Write-Host '    Переносите щось із цього переліку вручну — спершу створіть теку призначення:' -ForegroundColor DarkGray
        Write-Host '    git mv падає з "No such file or directory" саме на відсутній ТЕЦІ, хоча читається як зникле джерело.' -ForegroundColor DarkGray
    }
    if ($plan.Moves.Count -gt 0) {
        Write-Host '  Перейменування:'
        Write-KitRenameEdtList -Items $plan.Moves -Format { param($m) "$($m.From) -> $($m.To)" }
    }

    # Властивість безпеки 2: колізія зупиняє до будь-якого git mv; Get-KitEdtRenamePlan — чиста
    # функція, тож дерево лишається незмінним.
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
        Write-Host "  Тег межі: $boundaryTag" -ForegroundColor DarkGray
    } else {
        Write-Host '  У репозиторії немає тега межі legacy/gitsync-* — це крок 2 переходу (skills/onboarding/references/gitsync-migration.md, крок 2 «Тег межі»), rename-edt його не створює.' -ForegroundColor DarkGray
    }

    # SHA до будь-якої мутації — точка, куди команда сама відкочується на будь-яку помилку нижче.
    # Код виходу й непорожність перевіряються явно: це вхід єдиної руйнівної операції (відкоту).
    $preHeadShaResult = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', 'HEAD')
    if ($preHeadShaResult.ExitCode -ne 0) {
        throw "git rev-parse HEAD (перед мутацією) завершився з кодом $($preHeadShaResult.ExitCode): $($preHeadShaResult.Stderr) — без SHA відновлення неможливе, зупиняюсь до будь-якої мутації."
    }
    $preHeadSha = $preHeadShaResult.Stdout.Trim()
    if ([string]::IsNullOrWhiteSpace($preHeadSha)) {
        throw 'git rev-parse HEAD (перед мутацією) повернув порожній результат при коді виходу 0 — без SHA відновлення неможливе, зупиняюсь до будь-якої мутації.'
    }

    # Відкіт прибирає ЛИШЕ фактично виконані перейменування, не $plan.Moves: файл за адресою
    # невиконаного перейменування створив не kit — саме через нього git mv і падає на
    # "destination exists". Оголошено до try, щоб catch бачив список на будь-якому кроці.
    $executedMoveTargets = [System.Collections.Generic.List[string]]::new()

    try {
        foreach ($item in $plan.Unmapped) {
            # ":(literal)": шлях іде як pathspec, і без цього '[', ']', '*', '?' (легальні на NTFS)
            # розкриваються глобом — `git rm -- 'a[bc].txt'` видалив би й ab.txt, і ac.txt.
            $rm = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'rm', '-f', '-q', '--', ":(literal)$($item.From)")
            if ($rm.ExitCode -ne 0) { throw "git rm -- '$($item.From)' завершився з кодом $($rm.ExitCode): $($rm.Stderr)" }
        }

        foreach ($move in $plan.Moves) {
            # git mv бере шлях літерально (не pathspec) — ":(literal)" не потрібен.
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

        # Файл повідомлення коміту — поза робочою копією споживача (тимчасовий файл системи).
        $msgFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $msgFile -Value ($msgLines -join "`n") -Encoding UTF8
            # Коміт обмежений двома керованими піддеревами (`--only`): чужий файл, застейджений
            # під час проходу, не має мовчки їхати в коміт перейменування. ":(literal)" — як на
            # git rm вище. -TargetRoot додається, лише коли туди щось перенесено: pathspec без
            # жодного відомого git шляху валить `git commit` («did not match any file(s)»).
            #
            # Плата за `--only`: для названих шляхів git бере вміст РОБОЧОГО ДЕРЕВА через фільтри
            # цільового шляху. Після gitsync на диску CRLF при LF в індексі, тож блоби коміту —
            # нові об'єкти; виявлення перейменування дає R098/R095, але --follow і blame -w
            # не слабшають.
            #
            # Чистоту цього коміту тримає запобіжник Test-GitTextPolicy на -TargetRoot: під
            # `text=auto` замість `-text` та сама форма дає R066 і LF-блоб, тобто послаблення
            # запобіжника тихо вбиває `--follow`, а не лише побайтову рівність.
            $commitPaths = @(":(literal)$SourceRelPath")
            if ($executedMoveTargets.Count -gt 0) { $commitPaths += ":(literal)$TargetRoot" }
            $commitArgs = @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-F', $msgFile, '--only', '--') + $commitPaths
            $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments $commitArgs
            if ($commit.ExitCode -ne 0) { throw "git commit завершився з кодом $($commit.ExitCode): $($commit.Stderr)" }
        } finally {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Адресний відкіт двох піддерев (порядок і причини — у .DESCRIPTION). Він у власному
        # try/catch: Invoke-KitGitProcess може кинути (немає git у PATH), і вторинна помилка
        # не має сховати первинну причину ($failureMessage).
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

            # checkout нічого не видаляє, тож цілі, створені самою командою, прибираємо самі —
            # рівно $executedMoveTargets. ":(literal)" — як на git rm вище.
            #
            # Фільтр $targetInShaSet — ЖИВИЙ запобіжник, не прибирати: якщо людина під час проходу
            # видалила закомічений файл, git mv у цей шлях вдається, і без фільтра відкіт зніс би
            # файл, що був у коміті. Тесту на цю гілку немає — вона тримається на цьому фільтрі.
            $targetInShaSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$targetInSha, [System.StringComparer]::Ordinal)
            foreach ($movedTo in $executedMoveTargets) {
                if ($targetInShaSet.Contains($movedTo)) { continue }
                $rmBack = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'rm', '-f', '-q', '--ignore-unmatch', '--', ":(literal)$movedTo")
                if ($rmBack.ExitCode -ne 0) { $pruneErrors.Add("git rm -- '$movedTo': код $($rmBack.ExitCode): $($rmBack.Stderr)") }
            }

            # Приймальна перевірка: обидва піддерева повернулись до $preHeadSha. Код 0 — різниці
            # немає, 1 — є; інший код — перевірка не виконалась, і це не успіх.
            $verify = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'diff', '--quiet', $preHeadSha, '--', $SourceRelPath, $TargetRoot)
            $verifyExitCode = $verify.ExitCode
            if ($verifyExitCode -notin 0, 1) {
                $pruneErrors.Add("git diff --quiet $preHeadSha -- завершився з кодом ${verifyExitCode}: $($verify.Stderr) — приймальну перевірку відкоту виконати не вдалося, стан піддерев не підтверджено")
            }
        } catch {
            $pruneErrors.Add("сам відкіт кинув виняток: $($_.Exception.Message)")
        }

        # Точний рецепт ручного відновлення (HEAD не рухався, тож воно можливе): СПЕРШУ прибрати
        # дерево призначення цілком, ТОДІ checkout з коміту того, що в ньому було. Порядок
        # обов'язковий — checkout нічого не видаляє, тож навпаки цілі проходу лишились би.
        $manual = [System.Collections.Generic.List[string]]::new()
        $manual.Add("  git rm -r -f --ignore-unmatch -- ':(literal)$TargetRoot'")
        if ($shaProbed) {
            if ($restorePaths.Count -gt 0) { $manual.Add("  git checkout $preHeadSha -- $($restorePaths -join ' ')") }
        } else {
            $manual.Add("  git ls-tree -d $preHeadSha -- '$SourceRelPath' '$TargetRoot'")
            $manual.Add("  git checkout $preHeadSha -- <лише ті з двох шляхів, що вивелись вище>")
        }
        $manual.Add('  git status')
        # Попередження стоїть ПЕРЕД рецептом: на відміну від автоматичного відкоту, перша команда
        # рецепта знищує дерево '$TargetRoot' цілком, а надруковане після — читають запізно.
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

        # Порожні теки, створені New-Item, checkout не прибирає. Лише ПІСЛЯ вдалого відкоту:
        # у зламаному сценарії прибраний скелет src/ робив би напівмігроване дерево схожим на
        # мігроване.
        try { Remove-KitEmptyDirectory -Path $sourceFull } catch {}
        try { Remove-KitEmptyDirectory -Path $targetFullRoot } catch {}

        # Текст обіцяє рівно гарантію відкоту: індекс і робоче дерево двох піддерев, не HEAD.
        throw ("Перейменування впало та відкочено: вміст '$SourceRelPath' і '$TargetRoot' повернуто до стану коміту " +
               "$preHeadSha (індекс і робоче дерево цих двох піддерев; HEAD не рухався — коміту не створювалось), " +
               "решта репозиторію не зачеплена: $failureMessage")
    }

    # Прибирання порожніх тек — ПОЗА try/catch мутації: косметичний збій (антивірус тримає
    # теку) не має відкотити вже закомічений результат. Збій тут — лише попередження.
    try {
        Remove-KitEmptyDirectory -Path $sourceFull
    } catch {
        Write-Host "  Попередження: не вдалось прибрати порожні теки під '$SourceRelPath' ($($_.Exception.Message)) — косметика, коміт уже завершено успішно." -ForegroundColor Yellow
    }

    # Після `--only` HEAD правильний, а індекс — ні: git mv переніс старі LF-блоби (`text=auto`),
    # а commit --only узяв CRLF-байти з диска, не оновивши записів індексу. Без цього кроку
    # `git status` одразу показує змінені файли: наступна команда kit упреться в «Робоча копія
    # не чиста», а `git add -A` закомітив би LF-версії (docs/text-policy.md). `git reset` без
    # `--hard` оновлює записи індексу з HEAD, робочої копії не чіпає; обсяг — ті самі два піддерева.
    $resetPaths = @(":(literal)$SourceRelPath")
    if ($executedMoveTargets.Count -gt 0) { $resetPaths += ":(literal)$TargetRoot" }
    $reset = Invoke-KitGitProcess -RepoRoot $root -Arguments (@('-c', 'core.quotepath=false', 'reset', '-q', '--') + $resetPaths)
    if ($reset.ExitCode -ne 0) {
        Write-Host ("  Попередження: не вдалось оновити записи індексу (git reset код $($reset.ExitCode)) — коміт УЖЕ правильний, " +
                    "але `git status` може показувати змінені файли з різницею лише в кінцях рядків. Виправляє: git -C <репозиторій> reset.") -ForegroundColor Yellow
    }

    # SHA — через Get-KitCommitSha (перевірка коду виходу навіть одразу після успішного коміту):
    # він потрібен скілу для CLAUDE.md споживача й `git blame`, а порожній SHA тут — тихий збій.
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
