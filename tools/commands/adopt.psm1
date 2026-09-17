#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt (docs/follow-ups.md §5).

function Invoke-KitAdopt {
    <#
    .SYNOPSIS
        Гілка задачі приймає версію сховища ЗАМІНОЮ ВМІСТУ піддерева джерела, не content-мерджем
        (спека 2026-09-17 §5) — але ЗІ ЗЛИТТЯМ ПОРОЖНЬОГО РЕЗУЛЬТАТУ (git merge -s ours) заради
        ancestry (фінальне рев'ю C2, Critical).
    .DESCRIPTION
        Сховище — істина в останній інстанції, і працює з ним лише людина: вона бере артефакт
        агента, перевіряє його в Конфігураторі, можливо бере ЧАСТИНУ механізмів і кладе у сховище
        свою версію. Тому агент не зливає своє зі сховищним ЗМІСТОВНО — він замінює своє тим, що у
        сховищі. Звичайний git merge (з реальним злиттям вмісту) лишив би в гілці те, що людина
        свідомо не взяла, і воно поїхало б у наступний артефакт.

        Але ЗАМІНА ЗВИЧАЙНИМ КОМІТОМ (в одного предка) не рухає git merge-base: verify визначає
        версію сховища саме через ancestry (Get-KitVerifyVersion, StorageBranch.psm1:556), і після
        такої заміни бачив би СТАРУ версію на новому дереві — «розбіжності», яких нема (дефект,
        закритий цим фіксом). Тому перед заміною вмісту команда зливає дзеркало стратегією "ours"
        (--no-commit, тоді дописує другого предка звичайним комітом): ours нічого не бере з дерева
        дзеркала — коміт лишається РІВНО тим замінним вмістом, що й раніше, а другий предок рухає
        ancestry, на якій тримається verify. Зі злиття НЕ протікає жодного вмісту за визначенням.

        Прев'ю (без -Apply) — не формальність, а єдиний момент, коли видно ціну заміни: що прийде
        зі сховища і ЩО ЗНИКНЕ З ГІЛКИ. Друге важливіше: це робота агента, яку людина не взяла.
        Вона не втрачається (лишається в історії гілки до заміни), але рішення без неї
        ухвалювалося б наосліп.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [string]$Ref,
        [bool]$Apply
    )

    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — приймати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Adopted = @() }
    }

    $adopted = [System.Collections.Generic.List[object]]::new()

    foreach ($src in $sources) {
        $mirror = if ($Ref) { $Ref } else { $src.Branch }
        if (-not (Test-KitBranchExists -RepoRoot $root -Branch $mirror)) {
            throw "Гілки '$mirror' немає — дзеркало ще не створено. Спершу: kit sync -Source $($src.Key) -Apply."
        }

        Write-Host ''
        Write-Host "Джерело: $($src.Workspace)/$($src.Key)  ·  приймаємо з: $mirror"

        $workDir = Join-Path $root 'build/adopt' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/adopt') -Description "робоча тека adopt $($src.Key)"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $mirrorDir = Join-Path $workDir 'mirror'
        $null = Export-KitTree -RepoRoot $root -Ref $mirror -RepoPath $src.RepoPath -Destination $mirrorDir

        # TreeDir — РОБОЧА КОПІЯ, не експорт гілки: замінюється саме вона, і незакомічене в ній
        # зникне так само, як закомічене. Показати треба фактичний стан, а не стан HEAD.
        $relSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($rel in (@(Get-KitRelativeFiles -Root $mirrorDir) + @(Get-KitRelativeFiles -Root $src.FullPath))) { $relSet.Add($rel) | Out-Null }
        $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths ([string[]]$relSet)
        $diff   = Compare-KitTrees -DumpDir $mirrorDir -TreeDir $src.FullPath -BinaryPaths $binary

        $incoming = @($diff.Content) + @($diff.OnlyInDump)
        Write-Host "  Побайтово рівних: $($diff.Equal) із $($diff.Total)"
        # CrOnly — окремим рядком, не всередині «прийде зі сховища»: причина інша, не чиясь
        # робота, а політика тексту (той самий підпис зламаної CRLF-політики, що verify.psm1
        # друкує для дампу проти дерева — docs/text-policy.md). Формулювання title навмисно
        # дослівно збігається з verify.psm1, щоб дві команди одного контуру називали одне й те
        # саме однаково (рев'ю фікс-раунду 1).
        Write-KitAdoptList -Title 'лише CR (зіпсована політика тексту — docs/text-policy.md)' -Items $diff.CrOnly
        Write-KitAdoptList -Title "прийде зі сховища ($mirror)" -Items $incoming
        Write-KitAdoptList -Title 'ЗНИКНЕ з гілки — робота, яку людина у сховище не взяла' -Items $diff.OnlyInTree -Loud

        $adopted.Add([pscustomobject]@{ Key = $src.Key; Mirror = $mirror; Incoming = $incoming.Count; Dropped = $diff.OnlyInTree.Count; Applied = $false })

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Заміна — з -Apply (дерево джерела буде переписане вмістом дзеркала).' -ForegroundColor Cyan
            continue
        }

        # CrOnly входить у перевірку no-op нарівні з Incoming/OnlyInTree (рев'ю фікс-раунду 1):
        # різниця лише в CR — не шум, а підпис зламаної політики тексту (docs/text-policy.md),
        # і -Apply має її виправити так само, як змістовну розбіжність.
        if ($incoming.Count -eq 0 -and $diff.OnlyInTree.Count -eq 0 -and $diff.CrOnly.Count -eq 0) {
            Write-Host '  Дерево вже збігається з дзеркалом — заміняти нічого.' -ForegroundColor DarkGray
            continue
        }

        # $ws — до страховки (рев'ю фікс-раунду 1, Minor): Assert-SafeWorkPath нижче тепер теж
        # бере його межею, тому обчислення не може лишатись усередині `if ($dirty.Count -gt 0)`.
        $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1

        # Версія трейлера — ДО Remove-Item/Copy-Item/git add -A нижче, не після (фінальне рев'ю,
        # Critical): дешевий git-виклик, і якщо вершина дзеркала без трейлера Storage-Version
        # (гілку писав не sync), команда мусить зупинитись, поки дерево джерела ще ЦІЛЕ — не
        # після того, як воно вже замінене й застейджене, а відкат вимагав би саме тих команд,
        # які CLAUDE.md забороняє в спільній робочій копії (git checkout --/restore/stash/clean).
        # Той самий принцип, що verify.psm1:69–71: усі git-перевірки — до першої руйнівної дії.
        $version = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $mirror

        # Guard критичного рев'ю C2 (Critical, спека §5 «Чотири умови», п.1) — ДО Remove-Item,
        # поки дерево ще ЦІЛЕ. Причина: нижче гілка задачі приймає версію сховища ЗЛИТТЯМ
        # (git merge -s ours), щоб зрушити ancestry, на якій тримається verify
        # (Get-KitVerifyVersion, StorageBranch.psm1:556) — а партійний коміт (--only) git під
        # час merge ЗАБОРОНЯЄ ("cannot do a partial commit during a merge", перевірено
        # емпірично), тож коміт піде БЕЗ pathspec і зафіксує ВЕСЬ індекс, яким він є. Спільна
        # робоча копія: якщо там паралельно застейджена чи просто незакомічена чужа зміна ПОЗА
        # шляхом джерела, вона поїде в наш коміт непомітно. Зміни ВСЕРЕДИНІ $src.RepoPath —
        # нормальні: підуть у резервну копію нижче й однаково будуть замінені дзеркалом.
        # @() навколо ВСЬОГО конвеєра, не лише навколо Get-KitDirtyRecords: рівно один запис
        # поза шляхом (типовий випадок у тесті на цей guard) інакше дає скалярний
        # pscustomobject без .Count, і StrictMode падає на наступному рядку.
        $srcPrefix = (($src.RepoPath -replace '\\', '/').TrimEnd('/')) + '/'
        $outside = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath '.' | Where-Object {
            (-not $_.Path.StartsWith($srcPrefix, [System.StringComparison]::Ordinal)) -or
            ($_.OldPath -and -not $_.OldPath.StartsWith($srcPrefix, [System.StringComparison]::Ordinal))
        })
        if ($outside.Count -gt 0) {
            $paths = (($outside | ForEach-Object { $_.Path } | Select-Object -Unique) -join "`n")
            throw ("У робочій копії є незакомічені зміни ПОЗА шляхом джерела '$($src.RepoPath)' — adopt зупиняється, " +
                   "не діставшись Remove-Item. Коміт заміни нижче йде через git merge (ancestry, спека §5), а " +
                   "партійний коміт під час злиття git забороняє — плаский коміт забрав би ці шляхи непомітно. " +
                   "Закомітьте їх або приберіть (НЕ git checkout --/restore/stash/clean — спільна робоча копія, " +
                   "CLAUDE.md) і повторіть adopt. Шляхи:`n$paths")
        }

        # Страховка перед знищенням: те саме, що робить canon (спека §5). Копія лягає у
        # гітігноровану build/-теку воркспейсу, тож робочої копії не забруднює.
        $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $src.RepoPath)
        $backupDir = $null
        if ($dirty.Count -gt 0) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'adopt-backup' "$($src.Key)-$stamp"))
            $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $src.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
            Write-Host "  $($dirty.Count) незакомічених змін — копія перед заміною у $backupDir" -ForegroundColor Yellow
        }

        # Гілка задачі ПРИЙМАЄ версію сховища злиттям із ПОРОЖНІМ РЕЗУЛЬТАТОМ (стратегія ours),
        # ПЕРЕД заміною піддерева (спека 2026-09-17 §5, фінальне рев'ю C2 Critical): це рухає
        # ancestry (git merge-base), на якій тримається verify — без цього кроку заміна
        # піддерева лишала merge-base на старій версії, і verify після adopt доповідав би про
        # версію сховища те, чого нема. Стратегія "ours" НЕ протікає жодного вмісту дзеркала:
        # вона за визначенням лишає робочу копію такою, якою вона була (перевірено емпірично —
        # working tree й індекс не зрушуються жодним байтом); дерево заміняємо вручну нижче, як
        # і раніше, — merge відповідає лише за другого предка коміту.
        #
        # git reset -- $src.RepoPath ПЕРЕД merge: емпірично `git merge -s ours` відмовляється
        # (код 2, "Merge with strategy ours failed", перевірено в тимчасовому репозиторії), якщо
        # в ІНДЕКСІ є БУДЬ-ЯКА застейджена зміна — навіть строго всередині шляху джерела, яку
        # захід нижче однаково замінить. git reset — не checkout/restore/stash/clean: він
        # повертає ІНДЕКС до HEAD, БАЙТИ на диску не чіпає, тож нічого не втрачається (усе
        # застейджене там уже або в резервній копії вище, або однаково піде під заміну нижче).
        # Guard вище вже гарантував, що застейджене може бути лише ВСЕРЕДИНІ $src.RepoPath —
        # reset звужений тим самим шляхом, не рештою дерева.
        $resetSrc = Invoke-KitGitProcess -RepoRoot $root -Arguments @('reset', '-q', '--', $src.RepoPath)
        if ($resetSrc.ExitCode -ne 0) { throw "git reset для '$($src.RepoPath)' завершився з кодом $($resetSrc.ExitCode): $($resetSrc.Stderr)" }

        # --no-ff: інакше git спробує fast-forward там, де це можливо, і другого предка не буде.
        # --allow-unrelated-histories: гілки storage/* — orphan (StorageBranch.psm1:422,
        # `worktree add --orphan`), спільного предка з гілкою задачі може не бути взагалі; sync
        # передає той самий прапорець для головної гілки (GitMerge.psm1) — той самий випадок.
        $merge = Invoke-KitGitProcess -RepoRoot $root -Arguments @('merge', '--no-commit', '--no-ff', '-s', 'ours', '--allow-unrelated-histories', $mirror)
        if ($merge.ExitCode -ne 0) {
            throw "git merge -s ours '$mirror' у '$($src.RepoPath)' не вдався (код $($merge.ExitCode)): $($merge.Stdout)$($merge.Stderr)"
        }

        # "Already up to date": якщо дзеркало вже предок HEAD (adopt повторюють без нової версії
        # сховища, а дерево розбіглося тільки локальними правками), git НЕ створює MERGE_HEAD і
        # виходить кодом 0 без жодної дії (перевірено емпірично) — ancestry вже правильна, і
        # йдемо ЗВИЧАЙНИМ шляхом (коміт --only, як і до цього фіксу), а не через merge-коміт.
        $mergeHead = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '-q', '--verify', 'MERGE_HEAD')
        $viaMerge = ($mergeHead.ExitCode -eq 0)

        try {
            # -MustBeUnder $ws.FullPath, не $root (рев'ю фікс-раунду 1, Minor): те саме звуження,
            # що canon.psm1:83 — коментар вище каже «те саме, що робить canon», і межа guard'а
            # перед Remove-Item -Recurse -Force на дереві людини мусить це підтверджувати буквально.
            Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $ws.FullPath -Description "дерево джерела $($src.Key)"
            if (Test-Path -LiteralPath $src.FullPath) { Remove-Item -LiteralPath $src.FullPath -Recurse -Force }
            New-Item -ItemType Directory -Path $src.FullPath -Force | Out-Null
            Copy-Item -Path (Join-Path $mirrorDir '*') -Destination $src.FullPath -Recurse -Force

            # -A обов'язковий і саме на ШЛЯХУ джерела: він фіксує і нові файли, і ВИДАЛЕННЯ тих,
            # яких у дзеркалі немає. Обмеження pathspec-ом тримає межу «точковий коміт у спільній
            # робочій копії» — чужі зміни поза цим шляхом не потраплять (а якщо йдемо через
            # merge — guard на початку кроку вже виключив їх до першого руйнівного кроку).
            $add = Invoke-KitGitProcess -RepoRoot $root -Arguments @('add', '-A', '--', $src.RepoPath)
            if ($add.ExitCode -ne 0) { throw "git add для '$($src.RepoPath)' завершився з кодом $($add.ExitCode): $($add.Stderr)" }

            $message = "adopt: $($src.Key) ← $mirror (версія $version)"
            if ($viaMerge) {
                # Партійний коміт (--only) під час merge git ЗАБОРОНЯЄ ("cannot do a partial
                # commit during a merge", перевірено емпірично) — тому саме тут, і тільки тут,
                # коміт БЕЗ pathspec. Guard на початку кроку вже гарантував, що в індексі немає
                # нічого поза $src.RepoPath, тож плаский коміт фіксує рівно те саме, що й раніше.
                $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '-m', $message)
            } else {
                $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '--only', '-m', $message, '--', $src.RepoPath)
            }
            if ($commit.ExitCode -ne 0) { throw "Коміт заміни не вдався (код $($commit.ExitCode)): $($commit.Stderr)" }
        } catch {
            if (-not $viaMerge) { throw }
            # Зрив ПІСЛЯ успішного `git merge --no-commit` (фінальне рев'ю C2, Critical): не
            # прибрати MERGE_HEAD — лишити репозиторій у незавершеному стані злиття, де хук
            # pre-commit і будь-яка наступна команда бачитимуть напівзамінене дерево. Код виходу
            # abort перевіряємо (той самий принцип, що GitMerge.psm1) — інакше повідомлення
            # стверджувало б відкіт, якого могло й не відбутись.
            $abort = Invoke-KitGitProcess -RepoRoot $root -Arguments @('merge', '--abort')
            $original = $_.Exception.Message
            if ($abort.ExitCode -ne 0) {
                throw ("Заміна дерева '$($src.RepoPath)' впала ПІСЛЯ успішного git merge -s ours, і відкіт " +
                       "(git merge --abort) ТЕЖ не вдався (код $($abort.ExitCode): $($abort.Stderr)) — репозиторій " +
                       "лишається в незавершеному стані злиття, розберіться вручну: git status. Початкова помилка: $original")
            }
            # git merge --abort повертає ІНДЕКС і HEAD до стану перед merge, але НЕ відновлює
            # файли, видалені напряму через Remove-Item (перевірено емпірично — це філософія
            # "ours" і самого --abort: скасовується ЗЛИТТЯ, не файлові операції поза git), тож
            # дерево джерела могло лишитись частково стертим. Не пробуємо відновити його самі
            # (git checkout --/restore тут теж під забороною CLAUDE.md) — називаємо людині обидва
            # шляхи, звідки відновити вручну: резервну копію незакомiченого й цілий mirrorDir.
            throw ("Заміна дерева '$($src.RepoPath)' впала ПІСЛЯ успішного git merge -s ours — злиття відкочено " +
                   "(git merge --abort), АЛЕ саме дерево джерела могло лишитись частково стертим: git merge --abort " +
                   "не відновлює файли, видалені напряму. Резервна копія незакомiченого: " +
                   $(if ($backupDir) { $backupDir } else { 'її не було — дерево було чисте' }) +
                   ". Повний зміст дзеркала цілий у: $mirrorDir. Відновіть дерево звідти вручну, тоді повторіть adopt. " +
                   "Початкова помилка: $original")
        }

        Write-Host "  Замінено: прийшло $($incoming.Count), зникло $($diff.OnlyInTree.Count). Коміт: $message" -ForegroundColor Green
        $adopted[-1].Applied = $true
    }

    [pscustomobject]@{ ExitCode = 0; Adopted = $adopted.ToArray() }
}

function Write-KitAdoptList {
    param([string]$Title, [AllowEmptyCollection()][string[]]$Items, [switch]$Loud, [int]$Limit = 20)
    if ($Items.Count -eq 0) { return }
    $color = if ($Loud) { 'Yellow' } else { 'Gray' }
    Write-Host "  $Title ($($Items.Count)):" -ForegroundColor $color
    foreach ($i in ($Items | Select-Object -First $Limit)) { Write-Host "    $i" -ForegroundColor $color }
    if ($Items.Count -gt $Limit) { Write-Host "    … ще $($Items.Count - $Limit)" -ForegroundColor $color }
}

Export-ModuleMember -Function Invoke-KitAdopt
