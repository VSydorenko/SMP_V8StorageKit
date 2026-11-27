#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt (docs/follow-ups.md §5).

function Invoke-KitAdopt {
    <#
    .SYNOPSIS
        Гілка задачі приймає версію сховища ЗАМІНОЮ ВМІСТУ піддерева джерела, не content-мерджем
        — але ЗІ ЗЛИТТЯМ ПОРОЖНЬОГО РЕЗУЛЬТАТУ (git merge -s ours) заради ancestry.
    .DESCRIPTION
        Сховище — істина в останній інстанції, і працює з ним лише людина: вона бере артефакт
        агента, перевіряє його в Конфігураторі, можливо бере ЧАСТИНУ механізмів і кладе у сховище
        свою версію. Тому агент не зливає своє зі сховищним ЗМІСТОВНО — він замінює своє тим, що у
        сховищі. Звичайний git merge (з реальним злиттям вмісту) лишив би в гілці те, що людина
        свідомо не взяла, і воно поїхало б у наступний артефакт.

        Але ЗАМІНА ЗВИЧАЙНИМ КОМІТОМ (в одного предка) не рухає git merge-base: verify визначає
        версію сховища саме через ancestry (Get-KitVerifyVersion), і після такої заміни бачив би
        СТАРУ версію на новому дереві. Тому перед заміною вмісту команда зливає дзеркало стратегією "ours"
        (--no-commit, тоді дописує другого предка звичайним комітом): ours нічого не бере з дерева
        дзеркала — коміт лишається РІВНО тим замінним вмістом, що й раніше, а другий предок рухає
        ancestry, на якій тримається verify. Зі злиття НЕ протікає жодного вмісту за визначенням.

        Джерела перевіряються й приймаються ПО ОДНОМУ: кожне — окремий узгоджений коміт (злиття + заміна піддерева),
        зупинка на другому джерелі лишає перше вже прийнятим, а повтор adopt для нього — no-op («вже збігається»).
        Це свідомо не вирівняно з dump, який перевіряє всі джерела до першого видалення.

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
            if (Test-KitRemoteOnlyMirror -RepoRoot $root -Branch $mirror) {
                throw "Локальної гілки '$mirror' немає, але є origin/$mirror. Відновіть дзеркало: $(Get-KitRestoreMirrorStep -Branch $mirror), і повторіть adopt."
            }
            throw "Гілки '$mirror' немає — дзеркало ще не створено. Спершу: kit sync -Source $($src.Key) -Apply."
        }

        Write-Host ''
        Write-Host "Джерело: $($src.Workspace)/$($src.Key)  ·  приймаємо з: $mirror"

        $workDir = Join-Path $root 'build/adopt' $src.Key
        Assert-KitBuildPath -Path $workDir -MustBeUnder (Join-Path $root 'build/adopt') -RepoRoot $root -Description "робоча тека adopt $($src.Key)"
        Remove-KitDirectory -Path $workDir
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
        # CrOnly — окремим рядком: це не чиясь робота, а зламана політика тексту
        # (docs/text-policy.md). Заголовок дослівно як у verify.psm1 — одне явище, одна назва.
        Write-KitAdoptList -Title 'лише CR (зіпсована політика тексту — docs/text-policy.md)' -Items $diff.CrOnly
        Write-KitAdoptList -Title "прийде зі сховища ($mirror)" -Items $incoming
        Write-KitAdoptList -Title 'ЗНИКНЕ з гілки — робота, яку людина у сховище не взяла' -Items $diff.OnlyInTree -Loud

        $adopted.Add([pscustomobject]@{ Key = $src.Key; Mirror = $mirror; Incoming = $incoming.Count; Dropped = $diff.OnlyInTree.Count; Applied = $false })

        # CrOnly входить у перевірку «збігається» нарівні з Incoming/OnlyInTree: різниця лише в CR — підпис
        # зламаної політики тексту, і -Apply має її виправити, як змістовну розбіжність.
        $equalToMirror = ($incoming.Count -eq 0 -and $diff.OnlyInTree.Count -eq 0 -and $diff.CrOnly.Count -eq 0)

        # Вміст уже дорівнює дзеркалу (закомічене + незакомічене, #41): знищувати й копіювати нічого — файли
        # і так ті самі. Лишається те, що вміст дати не може: ancestry (дзеркало — предок HEAD) і, якщо
        # незакомічене рівне дзеркалу, його коміт (інваріант «гілка ≡ дзеркало» після adopt — той самий,
        # що в звичайному шляху: коміт фіксує індекс, зібраний із диска). Тож резервна копія зайва.
        $ancestryOnly = $false
        if ($equalToMirror) {
            $isAnc = Invoke-KitGitProcess -RepoRoot $root -Arguments @('merge-base', '--is-ancestor', $mirror, 'HEAD')
            $dirtyEq = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $src.RepoPath)
            if ($isAnc.ExitCode -eq 0 -and $dirtyEq.Count -eq 0) {
                if ($Apply) { Write-Host '  Дерево вже збігається з дзеркалом — заміняти нічого.' -ForegroundColor DarkGray }
                else { Write-Host '  Дерево вже збігається з дзеркалом.' -ForegroundColor DarkGray }
                continue
            }
            $ancestryOnly = $true
            Write-Host '  Вміст уже дорівнює дзеркалу — буде лише злиття ancestry (файли не чіпаються, резервної копії немає).' -ForegroundColor Cyan
        }

        if (-not $Apply) {
            if (-not $ancestryOnly) {
                Write-Host '  Це попередній перегляд. Заміна — з -Apply (дерево джерела буде переписане вмістом дзеркала).' -ForegroundColor Cyan
            } else {
                Write-Host '  Це попередній перегляд. Запис ancestry — з -Apply.' -ForegroundColor Cyan
            }
            continue
        }

        # $ws — поза `if ($dirty...)`: Assert-SafeWorkPath нижче бере його межею завжди.
        $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1

        # Інваріант команди: усі git-перевірки — до першої руйнівної дії, поки дерево ЦІЛЕ (відкат
        # потребував би git checkout --/restore, заборонених у спільній робочій копії). Перша —
        # трейлер Storage-Version на вершині дзеркала.
        $version = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $mirror

        # -text на шляху джерела. Без нього git застосує core.autocrlf/safecrlf машини: з
        # safecrlf=true add відмовить уже ПІСЛЯ стирання дерева, з warn — мовчки нормалізує кінці рядків.
        if (-not (Test-GitTextPolicy -RepoRoot $root -Path $src.RepoPath)) {
            throw ("Дерево '$($src.RepoPath)' не виведено з-під конверсії кінців рядків — adopt зупиняється до стирання дерева. " +
                   "Додайте в .gitattributes рядок '$($src.RepoPath)/** -text' окремим комітом (docs/text-policy.md) і повторіть adopt.")
        }

        # Поставка вендора не має відстежуватись git: `add -A` застейджив би .cf, і коміт
        # забрав би його в історію. ls-files заодно перевіряє, що git читає індекс. Проби
        # check-ignore свідомо немає: на зламаних ігнор-правилах вона коду >1 не дає, а після
        # `add -A -f` нижче ігнор на відмову не впливає.
        $supplyRel = '{0}/{1}' -f (($src.RepoPath -replace '\\', '/').TrimEnd('/')), (Get-KitSupplyRelativePath)
        $tracked = Invoke-KitGitProcess -RepoRoot $root -Arguments @('ls-files', '--', $supplyRel)
        if ($tracked.ExitCode -ne 0) { throw "git ls-files для '$supplyRel' завершився з кодом $($tracked.ExitCode): $($tracked.Stderr)" }
        # Поставка в індексі АБО в HEAD — зупинка. adopt видалення поставки не комітить взагалі:
        # Remove-KitSupplyFromIndex знімає поставку з індексу перед комітом, а на гілці з merge
        # застейджене видалення скасовує ще й reset перед злиттям — тож зняття з відстеження
        # мусить бути окремим комітом людини.
        $inHeadOut = ''
        if ((Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '-q', '--verify', 'HEAD')).ExitCode -eq 0) {
            $inHead = Invoke-KitGitProcess -RepoRoot $root -Arguments @('ls-tree', '-r', '--name-only', 'HEAD', '--', $supplyRel)
            if ($inHead.ExitCode -ne 0) { throw "git ls-tree HEAD для '$supplyRel' завершився з кодом $($inHead.ExitCode): $($inHead.Stderr)" }
            $inHeadOut = $inHead.Stdout
        }
        if ($tracked.Stdout.Trim() -or $inHeadOut.Trim()) {
            throw ("Поставка вендора відстежується git ('$supplyRel') — adopt зупиняється до стирання дерева: " +
                   "її .cf не має потрапляти в коміт, а видалення поставки adopt не комітить. Зніміть її з відстеження " +
                   "ОКРЕМИМ комітом до adopt (файли на диску лишаться): git rm -r --cached -- '$supplyRel' , потім " +
                   "git commit -m <повідомлення> (без шляхів; якщо в індексі застейджено ще щось — спершу розберіться з цим), і повторіть adopt.")
        }
        # Невидима для git status робота під набором. Копія нижче її не покриває, а Clear-KitTreeExceptSupply
        # стер би її безслідно. Зупинка — ДО першого руйнівного кроку (git reset, потім merge -s ours): після
        # початого злиття зупинка лишила б репозиторій у стані MERGE_HEAD. Збій git — виняток, не «чисто».
        $invisible = @(Get-KitInvisibleWork -RepoRoot $root -RepoPath $src.RepoPath | ForEach-Object {
            [pscustomobject]@{ Key = $src.Key; Kind = $_.Kind; Path = $_.Path }
        })
        if ($invisible.Count -gt 0) {
            throw (Format-KitInvisibleWorkStop -Command 'adopt' -Records $invisible -Backup 'adopt-backup' -Untouched 'Теку набору не чіпано, злиття не почато.')
        }

        # Незакомічене ПОЗА шляхом джерела — зупинка. Коміт нижче йде БЕЗ
        # pathspec і фіксує ВЕСЬ індекс: під час merge партійний коміт git забороняє ("cannot do a
        # partial commit during a merge"), а без merge `--only` воскрешає фантом перейменування
        # регістром. Чужа зміна поза шляхом поїхала б у наш коміт непомітно. Зміни ВСЕРЕДИНІ
        # $src.RepoPath нормальні: підуть у резервну копію й однаково замінюються дзеркалом.
        # @() навколо ВСЬОГО конвеєра: один запис інакше дає скаляр без .Count (StrictMode).
        $srcPrefix = (($src.RepoPath -replace '\\', '/').TrimEnd('/')) + '/'
        $outside = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath '.' | Where-Object {
            (-not $_.Path.StartsWith($srcPrefix, [System.StringComparison]::Ordinal)) -or
            ($_.OldPath -and -not $_.OldPath.StartsWith($srcPrefix, [System.StringComparison]::Ordinal))
        })
        if ($outside.Count -gt 0) {
            $paths = (($outside | ForEach-Object { $_.Path } | Select-Object -Unique) -join "`n")
            throw ("У робочій копії є незакомічені зміни ПОЗА шляхом джерела '$($src.RepoPath)' — adopt зупиняється, " +
                   "не діставшись Remove-Item. Коміт заміни нижче йде через git merge (ancestry), а " +
                   "партійний коміт під час злиття git забороняє — плаский коміт забрав би ці шляхи непомітно. " +
                   "Закомітьте їх або приберіть (НЕ git checkout --/restore/stash/clean — спільна робоча копія, " +
                   "CLAUDE.md) і повторіть adopt. Шляхи:`n$paths")
        }

        # Страховка перед знищенням: копія лягає у гітігноровану build/-теку воркспейсу.
        $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $src.RepoPath)
        $backupDir = $null
        if ($dirty.Count -gt 0 -and -not $ancestryOnly) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'adopt-backup' "$($src.Key)-$stamp"))
            $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $src.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath -OwnedRoot (Join-Path $ws.FullPath $ws.Project.WorkPath)
            Write-Host "  $($dirty.Count) незакомічених змін — копія перед заміною у $backupDir" -ForegroundColor Yellow
        }

        # Злиття з ПОРОЖНІМ РЕЗУЛЬТАТОМ (ours) ПЕРЕД заміною піддерева — лише заради другого предка
        # (ancestry для verify): ours не зрушує ні робочої копії, ні індексу, вміст дзеркала не протікає.
        #
        # git reset -- $src.RepoPath ПЕРЕД merge: `git merge -s ours` відмовляє ("Merge with strategy
        # ours failed"), якщо в індексі є будь-яка застейджена зміна. reset повертає лише ІНДЕКС до
        # HEAD, диск не чіпає; звужений шляхом джерела (поза ним застейдженого вже немає — guard вище).
        $resetSrc = Invoke-KitGitProcess -RepoRoot $root -Arguments @('reset', '-q', '--', $src.RepoPath)
        if ($resetSrc.ExitCode -ne 0) { throw "git reset для '$($src.RepoPath)' завершився з кодом $($resetSrc.ExitCode): $($resetSrc.Stderr)" }

        # --no-ff: інакше git спробує fast-forward там, де це можливо, і другого предка не буде.
        # --allow-unrelated-histories: гілки storage/* — orphan, спільного предка з гілкою задачі
        # може не бути взагалі.
        $merge = Invoke-KitGitProcess -RepoRoot $root -Arguments @('merge', '--no-commit', '--no-ff', '-s', 'ours', '--allow-unrelated-histories', $mirror)
        if ($merge.ExitCode -ne 0) {
            throw "git merge -s ours '$mirror' у '$($src.RepoPath)' не вдався (код $($merge.ExitCode)): $($merge.Stdout)$($merge.Stderr)"
        }

        # "Already up to date" (дзеркало вже предок HEAD): git не створює MERGE_HEAD і виходить
        # кодом 0 — ancestry вже правильна, йдемо звичайним комітом без злиття.
        $mergeHead = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '-q', '--verify', 'MERGE_HEAD')
        $viaMerge = ($mergeHead.ExitCode -eq 0)

        try {
            # Межа перед стиранням дерева людини — воркспейс, не весь репозиторій (як у dump).
            Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $ws.FullPath -RepoRoot $root -Description "дерево джерела $($src.Key)"
            # Поставка вендора: у дзеркалі .cf немає — повне стирання
            # лишило б .bin без .cf, і наступне повне завантаження впало б.
            if (-not $ancestryOnly) { Clear-KitTreeExceptSupply -TreeRoot $src.FullPath -MustBeUnder $ws.FullPath -RepoRoot $root }
            # Пофайлово, не Copy-Item <mirror>\* -Recurse: тека Ext тепер може вже існувати (у ній
            # поставка), а рекурсивна копія теки в наявну теку кладе її ВСЕРЕДИНУ (Ext/Ext/…).
            $mirrorFull = (Resolve-Path -LiteralPath $mirrorDir).Path
            $filesToCopy = if ($ancestryOnly) { @() } else { @(Get-ChildItem -LiteralPath $mirrorFull -Recurse -File -Force) }
            foreach ($f in $filesToCopy) {
                $relInMirror = $f.FullName.Substring($mirrorFull.Length).TrimStart('\', '/')
                # Дзеркало, записане версією ≤1.2.0, може нести .cf поставки в історії: локальну
                # поставку воно перезаписати не має.
                if (Test-KitSupplyRelativePath -RelativePath $relInMirror) { continue }
                $dest = Join-Path $src.FullPath $relInMirror
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            }

            # Індекс піддерева — наново з дерева дзеркала: rm --cached, тоді add. Без цього
            # `add -A` при core.ignorecase=true лишає запис старого регістру (lstat старого шляху на
            # NTFS успішний).
            # add -A на ШЛЯХУ джерела фіксує і нові файли, і видалення; pathspec тримає точковість.
            # -f: кожен файл дзеркала мусить потрапити в індекс незалежно від ігнору машини, інакше
            # rm --cached мовчки зняв би його з відстеження. :(exclude) поставки — ЗАВЖДИ: .cf не
            # стейджиться ніколи (з -f git на виключенні ігнорованої теки не відмовляє).
            $rm = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rm', '-r', '-q', '--cached', '--ignore-unmatch', '--', $src.RepoPath)
            if ($rm.ExitCode -ne 0) { throw "git rm --cached для '$($src.RepoPath)' завершився з кодом $($rm.ExitCode): $($rm.Stderr)" }
            $addArgs = @('-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', 'add', '-A', '-f', '--', $src.RepoPath, ":(exclude)$supplyRel")
            $add = Invoke-KitGitProcess -RepoRoot $root -Arguments $addArgs
            if ($add.ExitCode -ne 0) { throw "git add для '$($src.RepoPath)' завершився з кодом $($add.ExitCode): $($add.Stderr)" }
            # Властивість не залежить від форми .gitignore (негація !*.cf може обійти і пробу, і
            # exclude): після add поставки в індексі бути не може. НЕ throw: виняток веде в catch із
            # git merge --abort, а той СТИРАЄ застейджений .cf з диска. Тому поставку знімаємо з
            # індексу (диск не чіпається) і йдемо далі.
            Remove-KitSupplyFromIndex -RepoRoot $root -SupplyPath $supplyRel
            Assert-KitIndexMatchesDisk -RepoRoot $root -RepoPath $src.RepoPath

            $message = "adopt: $($src.Key) ← $mirror (версія $version)"
            # Обидві гілки комітять індекс як є. Під час злиття партійний коміт (--only) git забороняє
            # взагалі; а без злиття `commit --only -- <шлях>` накладає записи HEAD під pathspec і
            # перечитує їх із диска: старий регістр на NTFS «існує», тож фантом воскресає.
            # Межу «точковий коміт» тримає guard «немає незакомічених змін поза шляхом джерела» вище.
            $commit = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '-m', $message)
            if ($commit.ExitCode -ne 0) { throw "Коміт заміни не вдався (код $($commit.ExitCode)): $($commit.Stderr)" }
        } catch {
            if (-not $viaMerge) { throw }
            # Зрив ПІСЛЯ `git merge --no-commit`: MERGE_HEAD треба прибрати, інакше репозиторій
            # лишається в незавершеному злитті. Код виходу abort перевіряється — інакше текст
            # стверджував би відкіт, якого могло не бути.
            $abort = Invoke-KitGitProcess -RepoRoot $root -Arguments @('merge', '--abort')
            $original = $_.Exception.Message
            if ($abort.ExitCode -ne 0) {
                throw ("Заміна дерева '$($src.RepoPath)' впала ПІСЛЯ успішного git merge -s ours, і відкіт " +
                       "(git merge --abort) ТЕЖ не вдався (код $($abort.ExitCode): $($abort.Stderr)) — репозиторій " +
                       "лишається в незавершеному стані злиття, розберіться вручну: git status. Початкова помилка: $original")
            }
            # merge --abort повертає індекс і HEAD, але НЕ файли, стерті напряму, — дерево могло
            # лишитись частково стертим. Самі не відновлюємо (checkout --/restore заборонені в
            # спільній копії) — називаємо резервну копію й цілий mirrorDir.
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

function Remove-KitSupplyFromIndex {
    <#
    .SYNOPSIS
        Знімає з індексу ДОДАНЕ/ЗМІНЕНЕ (--diff-filter=AM) в теці поставки вендора (файли на диску не чіпає) і друкує попередження.
        Працює і в стані злиття (MERGE_HEAD), і без нього. Якщо після зняття поставка все ж в
        індексі — виняток.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$SupplyPath)
    $names = {
        $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('diff', '--cached', '--name-only', '--diff-filter=AM', '--', $SupplyPath)
        if ($r.ExitCode -ne 0) { throw "git diff --cached для '$SupplyPath' завершився з кодом $($r.ExitCode): $($r.Stderr)" }
        @($r.Stdout -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $staged = @(& $names)
    if ($staged.Count -eq 0) { return @() }
    $reset = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('reset', '-q', '--', $SupplyPath)
    if ($reset.ExitCode -ne 0) { throw "git reset для '$SupplyPath' завершився з кодом $($reset.ExitCode): $($reset.Stderr)" }
    $left = @(& $names)
    if ($left.Count -gt 0) { throw "Поставка вендора лишилась в індексі після git reset: $($left -join ', ')." }
    Write-Warning ("Поставка вендора потрапила в індекс (правило .gitignore з негацією?) — знято з індексу, файли на диску цілі: " + ($staged -join ', '))
    $staged
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
