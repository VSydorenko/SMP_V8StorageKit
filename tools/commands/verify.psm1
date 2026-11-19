#Requires -Version 7
Set-StrictMode -Version Latest

function Write-KitDiffList {
    param([string]$Title, [AllowEmptyCollection()][string[]]$Items, [int]$Limit = 20)
    if ($Items.Count -eq 0) { return }
    Write-Host "  $Title ($($Items.Count)):"
    foreach ($i in ($Items | Select-Object -First $Limit)) { Write-Host "    $i" }
    if ($Items.Count -gt $Limit) { Write-Host "    … ще $($Items.Count - $Limit)" }
}

function Invoke-KitVerify {
    <#
    .SYNOPSIS
        Інваріант «<ref> ≡ сховище» (спека §3.5): дерево <ref> за шляхом джерела проти
        канонічного дампу зі сховища на версії з merge-base. Без -Apply нічого не змінює.
    .PARAMETER Ref
        Що звіряти. Типово — головна гілка маніфесту. storage/X — канонічність самого дзеркала.
    .PARAMETER Version
        Явна версія сховища замість версії з трейлера — для розслідувань.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Ref,
        # ValidateRange ловить лише 0 і від'ємні. Забуте число ("-Version -Ref main") він НЕ ловить
        # ($true → 1) — це закрито в диспетчері kit.ps1: $true підставляється лише справжньому [switch].
        [ValidateRange(1, [int]::MaxValue)][Nullable[int]]$Version,
        # Шлях до раннера Уніки; порожній — із реєстру плагінів (Get-KitRunnerPath). Явний параметр, не
        # змінна оточення (§4.2 п.20).
        [string]$RunnerPath
    )

    $root = $Context.RepoRoot
    $ref  = if ($Ref) { $Ref } else { $Context.MainBranch }
    # Ім'я -Ref читається один раз у sha: усі читання дерева (Export-KitTree, Get-KitTreePaths) і версія
    # (Get-KitVerifyVersion) мають дивитись на ТОЙ САМИЙ коміт. Інакше коміт у main між читаннями зсунув би
    # гілку, і вердикт склався б з різних дерев. Людині показується ім'я.
    $refRes = Invoke-KitGitProcess -RepoRoot $root -Arguments @('rev-parse', '--verify', '--quiet', "$ref^{commit}")
    if ($refRes.ExitCode -ne 0) { throw "-Ref '$ref' не вказує на коміт цього репозиторію." }
    $refSha = $refRes.Stdout.Trim()

    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — звіряти нічого.'
        return [pscustomobject]@{ ExitCode = 0; Results = @(); AlignSteps = @() }
    }

    # Fetch нічого не змінює, а без нього дзеркало, що відстало від origin, читається як «сховище
    # попереду». Недоступна мережа чи відсутній remote — попередження: репозиторій без origin легальний.
    # Таймаути обов'язкові: Invoke-KitGitProcess чекає процес без ліміту, а ключ під passphrase без
    # агента підвісив би git НАЗАВЖДИ (чекав би вводу). BatchMode=yes робить це швидкою помилкою.
    $fetch = Invoke-KitGitProcess -RepoRoot $root -Arguments @(
        '-c', 'core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=5',
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
        'fetch', '--quiet', '--no-tags', 'origin')
    if ($fetch.ExitCode -ne 0) {
        Write-Host "  УВАГА: git fetch origin не вдався (код $($fetch.ExitCode)) — стан origin може бути застарілим." -ForegroundColor Yellow
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $anyAction = $false

    # Усі перевірки git — до першого звернення до платформи: зупинки дешеві, платформа — ні.
    $plan = @(foreach ($src in $sources) {
        # Порядок: спершу інваріанти git (дзеркало, merge-base, ref) — вони перевіряються без сховища й дають
        # точнішу зупинку; шлях сховища — другим.
        # Усередину йде sha (одна фіксація на весь прогін), тож його тексти називають лише sha; людина дала
        # ім'я -Ref — зупинка називає обидва.
        try { $vv = Get-KitVerifyVersion -RepoRoot $root -Ref $refSha -Branch $src.Branch }
        catch {
            # Бібліотека називає у своїх текстах sha (він і є -Ref усередині): префікс лише до тих, що його містять,
            # тобто стосуються -Ref («ніколи не зливав», merge-base). Тексти про дзеркало чи збій git лишаються як є.
            if ($_.Exception.Message.Contains($refSha)) { throw "-Ref '$ref' (коміт $refSha): $($_.Exception.Message)" }
            throw
        }
        if (-not (Test-Path -LiteralPath $src.StoragePath)) { throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)." }
        # Дамп — у базі агента, не в тимчасовій ІБ зі стабом: обидва боки порівняння мають один контекст
        # серіалізації, інакше GUID проти імен читається як різниця змісту. Get-KitSourceInfobase несе
        # запобіжник «це не дев-база людини» — критичний, бо UpdateCfg нижче ЗАМІНЮЄ конфігурацію в базі.
        $agent = Get-KitSourceInfobase -Context $Context -Source $src
        # $null -ne $Version, не голе if ($Version): «не передано» відрізняє перевірка на $null.
        [pscustomobject]@{ Source = $src; Info = $vv; Agent = $agent; Version = $(if ($null -ne $Version) { [int]$Version } else { $vv.Version }) }
    })

    # Раннер і платформа (§3.6 п.4, §4.2 п.14, п.20): усі перевірки git вище вже пройдено,
    # тож відсутній раннер зупиняє тут — до першого звернення до платформи. Платформу визначаємо один
    # раз на воркспейс і передаємо явним -V8Path.
    # Шлях раннера резолвиться ліниво — у циклі, після Get-KitSourceInfobase (він уже виконаний у плані вище).
    $runner = $RunnerPath
    $platformByWs = @{}

    # Кроки вирівнювання пам'яті раннера: по одному на набір, базу якого зрушив verify.
    $alignSteps = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($item in $plan) {
            $src = $item.Source; $vv = $item.Info; $ver = $item.Version; $agent = $item.Agent
            Write-Host ''
            Write-Host "Джерело:  $($src.Workspace)/$($src.Key)  ·  ref: $ref  ·  версія сховища: $ver (merge-base $($vv.Commit.Substring(0, 7)))"
            if ($vv.NewerVersions.Count -gt 0) {
                Write-Host "  На $($src.Branch) після злитої версії є: $($vv.NewerVersions -join ', ') — сховище попереду '$ref'." -ForegroundColor Yellow
            }

            $workDir = Join-Path $root 'build/verify' $src.Key
            Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/verify') -RepoRoot $root -OwnedRoot (Join-Path $root 'build') -Description "робоча тека verify $($src.Key)"
            Remove-KitDirectory -Path $workDir
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $ib = $agent.IbSwitch
            if (-not $runner) { $runner = Get-KitRunnerPath }
            if (-not $platformByWs.ContainsKey($agent.Workspace)) {
                $platformByWs[$agent.Workspace] = Get-KitAgentPlatform -Project $agent.Project -RunnerPath $runner
            }
            $v8Path = $platformByWs[$agent.Workspace]
            Write-Host "  Платформа:  $(Get-KitPlatformVersionFromPath -Path $v8Path) (обрав раннер)"
            # agent release — перед кожною пакетною операцією в базі агента (§3.6 п.1); released:false — норма.
            $null = Invoke-KitAgentRelease -Project $agent.Project -RunnerPath $runner
            Write-Host "  База агента ($ib), версія зі сховища, дамп..."
            $alignStep = $null
            $shifted = $false
            $merged = $false
            try {
                # $bound = $false ПЕРЕД try обов'язковий: під StrictMode неприсвоєна змінна у finally
                # кине й витіснить первинний виняток. Enter-KitStorageBind — УСЕРЕДИНІ try, Exit- з
                # Bound=$false нічого не знімає. BindCfg/UnbindCfg — єдиний запис kit у сховище, і межа
                # «сховище лише читання» тримається на симетрії цієї пари.
                $bound = $false
                try {
                    $bound = Enter-KitStorageBind -IbSwitch $ib -Source $src -V8Path $v8Path -User $agent.User
                    # Від цього місця база агента може тримати версію зі сховища (UpdateCfg усередині виклику): набір зсунутий.
                    $shifted = $true
                    $dumpCount = Invoke-KitStorageCheckout -IbSwitch $ib -Source $src -Version $ver -Target (Join-Path $workDir 'dump') -MustBeUnder $workDir -RepoRoot $root -V8Path $v8Path -User $agent.User -Password $agent.Password
                } catch {
                    # §6.1.1: власний текст verify на тому самому розпізнаваному винятку, що й
                    # sync, але БЕЗ порад sync (-DumpPlatform/-SkipVersion): verify нічого не переносить,
                    # а звірка на версії, яку основна платформа не вивантажує, неможлива.
                    if (Test-KitDumpFailure -ErrorRecord $_) {
                        $d = $_.Exception.Data
                        $pv = Get-KitPlatformVersionFromPath -Path ([string]$d['PlatformPath'])
                        throw ("Версію $ver основна платформа $pv не вивантажує — verify на ній неможливий. " +
                               'Звірте наступну версію (-Version) або вершину, вивантажену основною платформою. ' +
                               "Платформа відповіла: $($d['Output'])")
                    }
                    throw
                } finally {
                    Exit-KitStorageBind -IbSwitch $ib -Source $src -Bound $bound -V8Path $v8Path -User $agent.User
                }
                $treeDir = Join-Path $workDir 'tree'
                $treeCount = Export-KitTree -RepoRoot $root -Ref $refSha -RepoPath $src.RepoPath -Destination $treeDir
                Write-Host "  Файлів: у дампі $dumpCount, у дереві '$ref' $treeCount"
                # Групи регістру — з ПЕРЕЛІКУ git, не з диска (§4.3): на NTFS члени групи вже
                # злились в один файл при експорті. Запобіжник лічильника: інша розбіжність між переліком і
                # текою дерева — файлова система з'їла шляхи з невідомої причини, і вердикт був би неправдою.
                $prefix = ($src.RepoPath -replace '\\', '/').TrimEnd('/')
                $treeRel = @(Get-KitTreePaths -RepoRoot $root -Ref $refSha -Path $prefix |
                    ForEach-Object { $_.Substring($prefix.Length).TrimStart('/') } |
                    Where-Object { Test-KitComparableRelativePath -RelativePath $_ })
                $collisions = @(Get-KitCaseCollisions -Paths $treeRel)
                $collapsed = 0
                foreach ($g in $collisions) { $collapsed += $g.Count - 1 }
                $onDisk = @(Get-KitRelativeFiles -Root $treeDir).Count
                if ($onDisk -ne ($treeRel.Count - $collapsed)) {
                    throw ("Дерево '$ref' після експорту має $onDisk файл(ів), а з переліку git очікувалось $($treeRel.Count - $collapsed) " +
                           "(з поправкою на $($collisions.Count) груп(и) регістр-дублікатів) — файлова система втратила шляхи з невідомої причини; " +
                           'verify не ручається за звірку.')
                }
                Write-Host ("  База агента воркспейсу '{0}' тепер містить версію {1} зі сховища — це контракт verify, не збій." -f `
                    $agent.Workspace, $ver) -ForegroundColor Yellow

                # Ordinal HashSet, не Sort-Object -Unique: той культурозалежний і регістронечутливий,
                # а шляхи порівнюються Ordinal (як у Compare-KitTrees).
                $relSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($rel in (@(Get-KitRelativeFiles -Root (Join-Path $workDir 'dump')) + @(Get-KitRelativeFiles -Root $treeDir))) { $relSet.Add($rel) | Out-Null }
                $allRel = [string[]]$relSet
                $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths $allRel
                $diff   = Compare-KitTrees -DumpDir (Join-Path $workDir 'dump') -TreeDir $treeDir -BinaryPaths $binary -CaseCollisions $collisions -ClassifyCase

                $differs = ($diff.CrOnly.Count + $diff.Content.Count + $diff.OnlyInDump.Count + $diff.OnlyInTree.Count + $diff.CaseCollisions.Count + $diff.CaseOnly.Count) -gt 0
                $verdict = if (-not $differs -and $vv.NewerVersions.Count -eq 0) { 'equal' }
                           elseif (-not $differs) { 'storage-ahead' }
                           elseif ($vv.NewerVersions.Count -eq 0) { 'ref-ahead' }
                           else { 'mixed' }

                Write-Host ("  Побайтово рівних: $($diff.Equal) із $($diff.Total)" +
                    $(if ($diff.CaseCollidedPaths -gt 0) { " (ще $($diff.CaseCollidedPaths) шлях(ів) — у групах регістру, окремий клас нижче)" } else { '' }))
                Write-KitDiffList -Title 'лише CR (зіпсована політика тексту — docs/text-policy.md)' -Items $diff.CrOnly
                Write-KitDiffList -Title 'змістовні розбіжності' -Items $diff.Content
                Write-KitDiffList -Title 'тільки в дампі зі сховища' -Items $diff.OnlyInDump
                Write-KitDiffList -Title "тільки в дереві '$ref'" -Items $diff.OnlyInTree
                Write-KitDiffList -Title "регістр-дублікати в дереві '$ref' (на Windows — один файл)" -Items @($diff.CaseCollisions | ForEach-Object {
                    $real = $_.InDump
                    ($_.Paths | ForEach-Object { if ($_ -ceq $real) { "$_ (як у дампі)" } else { "$_ (фантом)" } }) -join ' | '
                })
                Write-KitDiffList -Title 'лише регістр шляху (дамп ↔ дерево)' -Items @($diff.CaseOnly | ForEach-Object {
                    "$($_.Dump) ↔ $($_.Tree)" + $(if ($_.ContentEqual) { '' } else { ' (вміст теж різниться)' })
                })
                if ($diff.CaseCollisions.Count -gt 0) {
                    Write-Host ("  Увага: регістр-дублікати — дефект дерева git, а не робота для сховища. Злиття такого дерева на Windows " +
                                "впаде з «would be overwritten». Джерело — запис дзеркала kit ≤ 1.3.1 або ручний git add -A після dump чи pull Уніки " +
                                "(docs/storage-and-git.md, «Перейменування регістром»).") -ForegroundColor Yellow
                }
                if ($diff.CaseOnly.Count -gt 0) {
                    Write-Host ("  Увага: у дереві git шлях має старий регістр імені порівняно зі сховищем — це розбіжність імені, а не вмісту; " +
                                "робота для сховища тут не потрібна (docs/storage-and-git.md, «Перейменування регістром»).") -ForegroundColor Yellow
                }
                if ($diff.OnlyInDump.Count -gt 0) {
                    # -f поза дужками PowerShell зв'язав би як -ForegroundColor — оператор формату всередині.
                    Write-Host (("  Увага: {0} файл(ів) є лише в дампі зі сховища — '{1}' їх ВТРАТИВ. Це не «робота, яку треба застосувати у сховищі», " +
                                 "а прогалина в '{1}': перевірте злиття {2} у '{1}' і канонізацію.") -f $diff.OnlyInDump.Count, $ref, $src.Branch) -ForegroundColor Yellow
                }

                switch ($verdict) {
                    'equal'         { Write-Host "  Вердикт: equal — '$ref' ≡ сховище (версія $ver)." -ForegroundColor Green }
                    'storage-ahead' { Write-Host "  Вердикт: storage-ahead — у сховищі є версії повз '$ref'. Звірочний коміт: kit verify -Ref $ref -Apply" -ForegroundColor Yellow; $anyAction = $true }
                    'ref-ahead'     { Write-Host "  Вердикт: ref-ahead — '$ref' розійшовся зі сховищем (версія $ver): змістовні/CR-розбіжності й «тільки в дереві» — робота, ще не застосована у сховищі (зберіть артефакт: unica.run op=make); «тільки в дампі» — див. «Увага» вище." -ForegroundColor Yellow; $anyAction = $true }
                    'mixed'         { Write-Host "  Вердикт: mixed — і '$ref' має незастосоване, і сховище пішло вперед. Спершу звірочний коміт (kit verify -Apply), потім розбір залишку." -ForegroundColor Yellow; $anyAction = $true }
                }

                $merged = $false
                if ($Apply -and $vv.NewerVersions.Count -gt 0) {
                    # Конфлікт звірочного коміту одного джерела не скасовує verify решти: дорога платформна
                    # робота й структурований Results важливіші за один необроблений виняток.
                    try {
                        $m = Merge-KitBranchInto -RepoRoot $root -Branch $src.Branch -Into $ref `
                            -Message "verify: звірочний коміт $($src.Branch) → $ref (версія $($vv.NewerVersions[-1]))"
                        Write-Host "  Звірочний коміт: $($m.Outcome) ($($m.Via)) $($m.Sha.Substring(0, 7))" -ForegroundColor Green
                        $merged = ($m.Outcome -eq 'merged')
                    } catch {
                        Write-Host "  Звірочний коміт не вдався: $($_.Exception.Message)" -ForegroundColor Red
                    }
                } elseif ($Apply) {
                    Write-Host '  -Apply: нових версій на дзеркалі немає — зливати нічого.' -ForegroundColor DarkGray
                }

        } finally {
            # Крок для зсунутого набору — і тоді, коли пізніша стадія (дамп, лічильник дерева, звірочний коміт)
            # кинула виняток: база агента вже тримає версію сховища, а git — іншу, і без кроку це тиха суміш
            # (§3.1). Крок не залежить від порівняння. Виняток летить далі
            # незмінним; крок — до фінального finally з рядками ЗУПИНКА. OnMainBranch — за ПОТОЧНОЮ гілкою, не за -Ref.
            if ($shifted) {
                try {
                    $onMain = Test-KitOnMainBranch -RepoRoot $root -MainBranch $Context.MainBranch
                    $alignStep = Get-KitAlignStep -Source $src -OnMainBranch $onMain -MainBranch $Context.MainBranch
                    Write-KitAlignStep -Step $alignStep
                    $alignSteps.Add($alignStep)
                } catch {
                    Write-Host "  Крок вирівнювання для '$($src.Key)' не обчислено: $($_.Exception.Message) — база агента зрушена; вирівняйте її вручну (push force:true цього набору)." -ForegroundColor Red
                }
            }
        }
            $results.Add([pscustomobject]@{ Key = $src.Key; Ref = $ref; Version = $ver; Verdict = $verdict; Diff = $diff; Merged = $merged; AlignStep = $alignStep })
        }
    } finally {
        # ЗУПИНКА — останніми, і в finally: виняток у пізнішому наборі (дамп, дерево, звірочний коміт) не мусить
        # губити крок, який агентові вже потрібен від попередніх наборів. Код виходу не змінюється —
        # виняток летить далі, змінюється лише те, що бачить агент.
        Write-KitAlignStops -Steps $alignSteps.ToArray()
    }

    [pscustomobject]@{ ExitCode = $(if ($anyAction) { 3 } else { 0 }); Results = $results.ToArray(); AlignSteps = $alignSteps.ToArray() }
}

Export-ModuleMember -Function Invoke-KitVerify
