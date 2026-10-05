#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/StorageBranch.psm1"
# Потрібен Invoke-KitGitProcess. module-order ставить GitMerge раніше за TreeCompare, тож імпорт вкладений (як у CaseGuard).
Import-Module "$PSScriptRoot/TreeCompare.psm1"
# Get-KitTreePaths, Get-KitCaseCollisions — перевірка груп регістру в дереві злиття (як у StorageBranch, вкладено).
Import-Module "$PSScriptRoot/CaseGuard.psm1"

function Test-KitBranchMergedInto {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch, [Parameter(Mandatory)][string]$Into)
    git -C $RepoRoot merge-base --is-ancestor $Branch $Into 2>$null
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw "git merge-base --is-ancestor $Branch $Into завершився з кодом $LASTEXITCODE." }
    }
}

function Merge-KitBranchInto {
    <#
    .SYNOPSIS
        Зливає гілку дзеркала в головну гілку чи гілку задачі (спека §3.4, рішення Q4) — без робочої копії.
    .DESCRIPTION
        Злиття рахує git merge-tree --write-tree (той самий ort, що git merge), коміт — commit-tree з
        двома батьками, гілку пересуває update-ref з перевіркою старого значення. Робочу копію
        оновлює лише одна команда — read-tree --reset -u HEAD — і лише коли <Into> вибрана тут.
        Причина (спека 2026-10-04 §2, §4.2): git на Windows не переводить робочу копію через
        перейменування лише регістром не-ASCII імені — merge/checkout/reset --keep/read-tree -m
        відмовляють з «untracked working tree files would be overwritten», навіть на чистому коміті.
        Проходять лише merge-tree і примусове read-tree --reset -u.
        Випадки: <Into> вибрана тут і чиста — злиття на місці (Via=in-place); вибрана тут і брудна
        (зокрема невідстежувані файли — read-tree --reset їх не захищає) — зупинка; вибрана в іншому
        worktree — зупинка (update-ref пересунув би гілку під чужою копією); не вибрана ніде —
        пересувається лише гілка (Via=ref). Конфлікт — зупинка, НІЧОГО не змінено, merge --abort не
        потрібен. Хуки pre-merge-commit/post-merge не викликаються: перший охороняв лише storage/* —
        тепер це перевірка нижче.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Into,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllowUnrelated
    )

    if ($Into -like 'storage/*') {
        throw "У гілку '$Into' нічого не зливають — це дзеркало сховища (гілки storage/* пише лише kit sync). Зливають storage/* у головну гілку чи гілку задачі."
    }
    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Into)) {
        throw "Гілки '$Into' немає — нема куди зливати $Branch. Створіть перший коміт у головній гілці (скіл onboarding робить це першим)."
    }
    if (Test-KitBranchMergedInto -RepoRoot $RepoRoot -Branch $Branch -Into $Into) {
        return [pscustomobject]@{ Outcome = 'already'; Sha = (Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into); Via = 'none' }
    }

    # Залишок тимчасового worktree kit ≤ 1.3.1 (build/sync/_main/wt) — прибрати, якщо є: нова схема його не створює.
    $legacy = Join-Path $RepoRoot 'build/sync/_main/wt'
    if (Test-Path -LiteralPath $legacy) {
        Assert-SafeWorkPath -Path $legacy -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'залишок worktree головної гілки'
        git -C $RepoRoot worktree remove --force $legacy 2>$null | Out-Null
        if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Recurse -Force }
        git -C $RepoRoot worktree prune 2>$null | Out-Null
    }

    # 2>$null, не 2>&1: $current читається як ім'я гілки (той самий принцип, що StorageBranch.psm1).
    $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git branch --show-current у $RepoRoot завершився з кодом ${LASTEXITCODE}." }
    $here = ($current -eq $Into)
    if ($here) {
        # -c core.quotepath=false і 2>$null — див. історію в коментарях попередньої редакції (B2):
        # перелік має бути шляхами, не попередженнями git.
        $dirty = git -c core.quotepath=false -C $RepoRoot status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git status завершився з кодом ${LASTEXITCODE}." }
        if ($dirty) {
            $lines = @($dirty)
            $shown = @($lines | Select-Object -First 5)
            $more  = $lines.Count - $shown.Count
            $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
            throw ("Гілка '$Into' вибрана, але робоча копія не чиста — у брудний '$Into' не зливаємо. Незакомічені шляхи:`n$detail`n" +
                   "Закомітьте або сховайте зміни (git stash) і повторіть, або перейдіть на гілку задачі — тоді злиття лише пересуне '$Into'.")
        }
    } else {
        $wl = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('worktree', 'list', '--porcelain')
        if ($wl.ExitCode -ne 0) { throw "git worktree list завершився з кодом $($wl.ExitCode): $($wl.Stderr)" }
        if (@($wl.Stdout -split "`n" | Where-Object { $_.Trim() -eq "branch refs/heads/$Into" }).Count -gt 0) {
            throw ("Гілка '$Into' вибрана в іншому worktree — kit не пересуває гілку під чужою робочою копією. " +
                   "Повторіть злиття там, де '$Into' вибрана, або приберіть той worktree.")
        }
    }

    $old = Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into
    # Гілку дзеркала фіксуємо в SHA один раз: merge-tree і commit-tree -p мусять бачити той самий коміт,
    # навіть якщо паралельний sync допише версію між ними.
    $branchSha = Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Branch
    $mtArgs = @('-c', 'core.quotepath=false', 'merge-tree', '--write-tree', '--name-only', '-z')
    if ($AllowUnrelated) { $mtArgs += '--allow-unrelated-histories' }
    $mtArgs += @($old, $branchSha)
    $mt = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments $mtArgs
    $fields = @($mt.Stdout -split "`0")
    switch ($mt.ExitCode) {
        0 { }
        1 {
            # -z --name-only: <дерево>\0<шлях>\0…\0\0<повідомлення> — конфліктні шляхи до першого порожнього поля.
            $conflicts = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $fields.Count -and $fields[$i]; $i++) { $conflicts.Add($fields[$i]) }
            $shown = @($conflicts | Select-Object -First 5)
            $more  = $conflicts.Count - $shown.Count
            $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
            throw ("Злиття $Branch → $Into не вдалося: конфлікт. Нічого не змінено — гілка '$Into' і робоча копія ті самі. " +
                   "Конфліктні шляхи:`n$detail`nРозв'яжіть вручну: git merge $Branch. Увага: якщо серед змін є перейменування " +
                   'лише регістром не-ASCII імен, ручний git merge на Windows сам відмовить з «would be overwritten» ' +
                   '(docs/storage-and-git.md, «Перейменування регістром»).')
        }
        129 { throw "git merge-tree не розпізнав --write-tree — потрібен git ≥ 2.38. Оновіть git і повторіть. git: $($mt.Stderr)" }
        default { throw "git merge-tree $Branch → $Into завершився з кодом $($mt.ExitCode): $($mt.Stderr)" }
    }
    $tree = $fields[0].Trim()

    # Групи регістру в дереві злиття (спека 2026-10-04 §4.2, крок 3, фінальне рев'ю H1): merge-tree віддає код 0 і
    # дерево з ОБОМА шляхами, коли перше злиття (--allow-unrelated-histories) приносить об'єкт з іншим регістром,
    # ніж у <Into>; після read-tree --reset -u копія була б брудною. Блокують лише групи, яких не було в <Into>
    # (порівняння за НАБОРОМ шляхів): стара зіпсована гілка не мусить блокувати злиття назавжди — її ловить check.
    # Перевірка до будь-якої зміни стану й для Via=ref, і для in-place.
    $oldGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($g in @(Get-KitCaseCollisions -Paths (Get-KitTreePaths -RepoRoot $RepoRoot -Ref $old))) { [void]$oldGroups.Add($g -join "`0") }
    $newGroups = @(Get-KitCaseCollisions -Paths (Get-KitTreePaths -RepoRoot $RepoRoot -Ref $tree) | Where-Object { -not $oldGroups.Contains($_ -join "`0") })
    if ($newGroups.Count -gt 0) {
        # Звідки група — від цього залежить рецепт. Уся група у вершині дзеркала — фантом несе саме дзеркало
        # (запис kit ≤ 1.3.1): лікує наступний sync, не ціль. Інакше члени розділені між ціллю й дзеркалом.
        $mirrorGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($g in @(Get-KitCaseCollisions -Paths (Get-KitTreePaths -RepoRoot $RepoRoot -Ref $branchSha))) { [void]$mirrorGroups.Add($g -join "`0") }
        $fromMirror = @($newGroups | Where-Object { $mirrorGroups.Contains($_ -join "`0") })
        $split      = @($newGroups | Where-Object { -not $mirrorGroups.Contains($_ -join "`0") })
        $fmt = {
            param($list)
            $shown = @($list | Select-Object -First 5 | ForEach-Object { $_ -join ' | ' })
            ($shown -join "`n") + $(if ($list.Count -gt 5) { "`n…і ще $($list.Count - 5)" } else { '' })
        }
        $parts = @("Злиття $Branch → $Into дало б у гілці '$Into' шляхи, що різняться лише регістром (на NTFS це один файл — виходить фантом). " +
                   "Нічого не змінено — гілка '$Into' і робоча копія ті самі.")
        if ($fromMirror.Count -gt 0) {
            $parts += ("Групи, які несе сама вершина ${Branch}:`n$(& $fmt $fromMirror)`n" +
                       "Фантом записав у дзеркало kit ≤ 1.3.1. Наступний kit sync нової версії сховища його прибере — тоді повторіть злиття; " +
                       'ремонту історії дзеркала kit не робить.')
        }
        if ($split.Count -gt 0) {
            $parts += ("Групи, члени яких розділені між '$Into' і ${Branch}:`n$(& $fmt $split)`n" +
                       "Рецепт: у гілці '$Into' зніміть старий регістр з індексу — git rm --cached -- <старий шлях> (диск не чіпається, " +
                       'на NTFS це той самий файл), закомітьте БЕЗ --only і повторіть команду.')
        }
        $parts += '(docs/storage-and-git.md, «Перейменування регістром»)'
        throw ($parts -join "`n")
    }

    if ($here) {
        # read-tree --reset -u мовчки перезаписує невідстежуваний ІГНОРОВАНИЙ файл, якщо злиття додає закомічений
        # файл за тим самим шляхом; status --porcelain такого файлу не показує. Перевіряємо до update-ref.
        $da = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'diff-tree', '-r', '-z', '--name-only', '--no-renames', '--diff-filter=A', $old, $tree)
        if ($da.ExitCode -ne 0) { throw "git diff-tree завершився з кодом $($da.ExitCode): $($da.Stderr)" }
        $added = @($da.Stdout -split "`0" | Where-Object { $_ })
        if ($added.Count -gt 0) {
            # Перетин — OrdinalIgnoreCase (спека 2026-10-04 §4.2, крок 3а): на NTFS ігнорований x.BIN і доданий
            # x.bin — один файл, і read-tree перезапише його. Хибної зупинки на кириличному перейменуванні
            # регістром це не дає: старий файл відстежуваний, у переліку ігнорованих його немає.
            # Верхні теки для pathspec — фактичні імена в корені, зіставлені OrdinalIgnoreCase: магія icase у
            # pathspec git складає лише ASCII (виміряно: ':(literal,icase)т' не знаходить теку 'Т').
            $topsAdded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($a in $added) { $slash = $a.IndexOf('/'); [void]$topsAdded.Add($(if ($slash -gt 0) { $a.Substring(0, $slash) } else { $a })) }
            $tops = @(Get-ChildItem -LiteralPath $RepoRoot -Force -Name | Where-Object { $topsAdded.Contains($_) })
            $ignored = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($tops.Count -gt 0) {
                $lsArgs = @('-c', 'core.quotepath=false', 'ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--') + @($tops | ForEach-Object { ":(literal)$_" })
                $ig = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments $lsArgs
                if ($ig.ExitCode -ne 0) { throw "git ls-files --others --ignored завершився з кодом $($ig.ExitCode): $($ig.Stderr)" }
                foreach ($p in ($ig.Stdout -split "`0")) { if ($p) { $ignored[$p] = $p } }
            }
            $clash = [System.Collections.Generic.List[string]]::new()
            foreach ($path in $added) {
                if (-not $ignored.ContainsKey($path)) { continue }
                # Вміст рахуємо з ФАКТИЧНОГО шляху ігнорованого файлу, порівнюємо з blob доданого шляху в дереві злиття.
                $actual = $ignored[$path]
                $theirs = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', "${tree}:$path")
                $mine   = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('hash-object', '--no-filters', '--', $actual)
                if ($theirs.ExitCode -eq 0 -and $mine.ExitCode -eq 0 -and $theirs.Stdout.Trim() -eq $mine.Stdout.Trim()) { continue }
                $clash.Add($(if ($actual -ceq $path) { $path } else { "$actual (дзеркало приносить $path)" }))
            }
            if ($clash.Count -gt 0) {
                $shown = @($clash | Select-Object -First 5)
                $more  = $clash.Count - $shown.Count
                $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
                throw ("Гілка '$Into' вибрана, але робоча копія не чиста: злиття $Branch → $Into перезаписало б ігноровані невідстежувані файли, " +
                       "які дзеркало приносить закоміченими. Нічого не змінено. Шляхи:`n$detail`n" +
                       "Перенесіть ці файли (або перейдіть на гілку задачі — тоді злиття лише пересуне '$Into') і повторіть.")
            }
        }
    }

    $msgFile = Join-Path $RepoRoot "build/sync/merge-message-$([guid]::NewGuid().ToString('N')).txt"
    New-Item -ItemType Directory -Path (Split-Path -Parent $msgFile) -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText($msgFile, $Message, [System.Text.UTF8Encoding]::new($false))
        $ct = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('commit-tree', $tree, '-p', $old, '-p', $branchSha, '-F', $msgFile)
        if ($ct.ExitCode -ne 0) { throw "git commit-tree завершився з кодом $($ct.ExitCode): $($ct.Stderr)" }
    } finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
    $new = $ct.Stdout.Trim()

    $ur = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('update-ref', '-m', "kit: $Message", "refs/heads/$Into", $new, $old)
    if ($ur.ExitCode -ne 0) {
        throw ("Гілку '$Into' пересунули, поки kit рахував злиття (update-ref з перевіркою старого значення відмовив) — " +
               "нічого не змінено. Повторіть команду. git: $($ur.Stderr)")
    }

    if ($here) {
        $rt = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('read-tree', '--reset', '-u', 'HEAD')
        if ($rt.ExitCode -ne 0) {
            throw ("Коміт злиття $($new.Substring(0, 7)) уже створено і гілку '$Into' пересунуто, але робоча копія не оновилась " +
                   "(git read-tree --reset -u HEAD, код $($rt.ExitCode): $($rt.Stderr)). Відновлення — та сама команда: " +
                   'git read-tree --reset -u HEAD (робоча копія була чистою до злиття, тож нічого не втрачається).')
        }
        return [pscustomobject]@{ Outcome = 'merged'; Sha = $new; Via = 'in-place' }
    }
    [pscustomobject]@{ Outcome = 'merged'; Sha = $new; Via = 'ref' }
}

Export-ModuleMember -Function Test-KitBranchMergedInto, Merge-KitBranchInto
