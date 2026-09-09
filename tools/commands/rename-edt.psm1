#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Write-KitRenameEdtList {
    <# .SYNOPSIS Повний перелік — Unmapped і Collisions друкуються ЦІЛКОМ, не лічильником (§9.2, властивість безпеки). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][scriptblock]$Format)
    foreach ($item in $Items) { Write-Host "    $(& $Format $item)" }
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
        1. Жоден файл не видаляється без показу людині — Unmapped друкується повним переліком
           завжди (і в прев'ю, і під -Apply), видалення (git rm) — лише під -Apply.
        2. Колізія (кілька EDT-шляхів в один Designer-шлях) ЗУПИНЯЄ до першого git mv — дерево
           лишається незміненим. Перевіряється до виконання будь-якої мутації.

        Префлайт строгий (kit.ps1 не додає rename-edt у -Lenient): маніфест і воркспейс уже
        існують на момент виклику, бо -TargetRoot розв'язує саме звідти викликач (онбординг,
        розділ 5.1) — ця команда сама по собі маніфесту не читає, приймає готові -SourceRelPath
        і -TargetRoot.

        Два запобіжники перед мутацією (context.md §1, §9):
        - брудна робоча копія (git status --porcelain) — успадковано з repo-migration, §9.2;
        - Test-GitTextPolicy на -TargetRoot: якщо ефективний атрибут text НЕ unset, git
          конвертує кінці рядків при наступному git add (git-конверсія CRLF↔LF), і крок 5
          §9.2 (побайтова рівність зі сховищем) мовчки не виконається — спайк 2026-09-09 це
          відтворив. Коміт самого .gitattributes — відповідальність скіла (onboarding), не цієї
          команди; команда лише перевіряє ефективний результат.
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

    # Запобіжник 1/3: брудна робоча копія (успадковано з repo-migration, §9.2, task-3-brief.md
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

    # Запобіжник 2/3: політика тексту на ЦІЛІ (Test-GitTextPolicy — GitOutput.psm1, вже написана,
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
    Write-Host "  Перейменувань: $($plan.Moves.Count)   Без відповідника: $($plan.Unmapped.Count)   Колізій: $($plan.Collisions.Count)"

    # Запобіжник 3/3 (властивість безпеки 2): непорожній Collisions зупиняє ДО будь-якого
    # git mv — сам виклик Get-KitEdtRenamePlan вище нічого на диску не змінив (чиста функція).
    if ($plan.Collisions.Count -gt 0) {
        Write-Host '  Колізії (кілька EDT-шляхів в один Designer-шлях) — перейменування НЕ виконується:' -ForegroundColor Red
        Write-KitRenameEdtList -Items $plan.Collisions -Format { param($c) "$($c.TargetRelPath)  <-  $(($c.SourceRelPaths) -join ', ')" }
        throw ("$($plan.Collisions.Count) колізія(й) шляхів — виправте вручну (перейменуйте один із джерел на " +
               'EDT-стороні або доповніть таблицю відповідності) і повторіть. Жоден git mv не виконано.')
    }

    # Властивість безпеки 1: Unmapped друкується ПОВНИМ переліком завжди, не лічильником —
    # незалежно від -Apply.
    if ($plan.Unmapped.Count -gt 0) {
        Write-Host '  Без відповідника (без -Apply лишаються на місці; під -Apply будуть видалені):' -ForegroundColor Yellow
        Write-KitRenameEdtList -Items $plan.Unmapped -Format { param($u) "$($u.SourceRelPath) — $($u.Reason)" }
    }

    if ($plan.Moves.Count -gt 0) {
        Write-Host '  Перейменування:'
        Write-KitRenameEdtList -Items $plan.Moves -Format { param($m) "$($m.SourceRelPath) -> $($m.TargetRelPath)" }
    }

    if (-not $Apply) {
        Write-Host '  Це попередній перегляд. Для виконання додайте -Apply (git mv + видалення файлів без відповідника + коміт).' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0 }
    }

    if ($plan.Moves.Count -eq 0 -and $plan.Unmapped.Count -eq 0) {
        Write-Host '  Дерево порожнє або вже перейменоване — робити нема чого, коміт не створюється.' -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0 }
    }

    # Тег межі EDT-епохи — СТВОРЮЄТЬСЯ ДО будь-якого git mv, поки HEAD ще є останнім
    # gitsync-комітом (docs/migration/2026-09-09-history-spike.md, "Рядок для CLAUDE.md").
    # Ідемпотентно: повторний виклик rename-edt того самого місяця (інший продукт того самого
    # репозиторію) бачить тег уже існуючим і не рухає його — межа лишається першою застуканою
    # точкою, а не останньою.
    $boundaryTag = 'legacy/gitsync-{0}' -f (Get-Date -Format 'yyyy-MM')
    $tagCheck = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '--verify', '--quiet', "refs/tags/$boundaryTag")
    if ($tagCheck.ExitCode -eq 0) {
        Write-Host "  Тег межі вже існує: $boundaryTag (лишається на першій зафіксованій межі)" -ForegroundColor DarkGray
    } else {
        $tagResult = Invoke-KitGitProcess -RepoRoot $root -Arguments @('tag', '-a', $boundaryTag, '-m', 'Межа EDT-епохи (gitsync) перед перейменуванням у Designer-шляхи.')
        if ($tagResult.ExitCode -ne 0) { throw "git tag $boundaryTag завершився з кодом $($tagResult.ExitCode): $($tagResult.Stderr)" }
        Write-Host "  Тег межі створено: $boundaryTag" -ForegroundColor DarkGray
    }

    foreach ($item in $plan.Unmapped) {
        $rm = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'rm', '-f', '-q', '--', $item.SourceRelPath)
        if ($rm.ExitCode -ne 0) { throw "git rm -- '$($item.SourceRelPath)' завершився з кодом $($rm.ExitCode): $($rm.Stderr)" }
    }

    foreach ($move in $plan.Moves) {
        $targetFull = Join-Path $root ($move.TargetRelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetFull) -Force | Out-Null
        $mv = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.quotepath=false', 'mv', '--', $move.SourceRelPath, $move.TargetRelPath)
        if ($mv.ExitCode -ne 0) { throw "git mv '$($move.SourceRelPath)' -> '$($move.TargetRelPath)' завершився з кодом $($mv.ExitCode): $($mv.Stderr)" }
    }

    $dateStr = Get-Date -Format 'yyyy-MM-dd'
    $msgLines = [System.Collections.Generic.List[string]]::new()
    $msgLines.Add("Перейменування EDT-шляхів у Designer-шляхи ($SourceRelPath -> $TargetRoot)")
    $msgLines.Add('')
    $msgLines.Add('Вміст файлів лишається EDT-ним — байти замінить наступний коміт конверсії (kit sync).')
    $msgLines.Add("Межа EDT-епохи (тег): $boundaryTag")
    $msgLines.Add("Дата перейменування: $dateStr")
    if ($plan.Unmapped.Count -gt 0) { $msgLines.Add("Видалено без відповідника: $($plan.Unmapped.Count) файл(ів) — перелік у виводі команди.") }

    $msgFile = Join-Path $root 'build/rename-edt-commit-message.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $msgFile) -Force | Out-Null
    Set-Content -LiteralPath $msgFile -Value ($msgLines -join "`n") -Encoding UTF8
    try {
        $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('-c', 'core.autocrlf=false', 'commit', '--quiet', '-F', $msgFile)
        if ($commit.ExitCode -ne 0) { throw "git commit завершився з кодом $($commit.ExitCode): $($commit.Stderr)" }
    } finally {
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    }
    $sha = (Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', 'HEAD')).Stdout.Trim()

    Write-Host "  Готово: $($plan.Moves.Count) перейменовано, $($plan.Unmapped.Count) видалено без відповідника. Коміт $sha." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Sha = $sha; BoundaryTag = $boundaryTag }
}

Export-ModuleMember -Function Invoke-KitRenameEdt
