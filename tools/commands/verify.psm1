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
        # [ValidateRange(1, [int]::MaxValue)] ловить лише -Version 0 і від'ємні значення —
        # реальний сценарій знахідки ("kit verify -Version -Ref main", забули число) він НЕ
        # ловить: диспетчер підставляє прапорцю без значення $true, PowerShell мовчки конвертує
        # bool → int (True → 1), і 1 проходить ValidateRange без жодної помилки (рев'ю B3 раунд
        # 2, помилковий коментар тут стверджував протилежне — виправлено раундом 3, M6). Цей
        # ширший сценарій закрито ЦЕНТРАЛЬНО в диспетчері (tools/kit.ps1, Step 5а): $true
        # підставляється прапорцю лише тоді, коли параметр команди — справжній [switch]; для
        # будь-якого іншого типу (як тут) диспетчер вимагає значення ще до виклику Invoke-KitVerify.
        [ValidateRange(1, [int]::MaxValue)][Nullable[int]]$Version
    )

    $root = $Context.RepoRoot
    $ref  = if ($Ref) { $Ref } else { $Context.MainBranch }

    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — звіряти нічого.'
        return [pscustomobject]@{ ExitCode = 0; Results = @() }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $anyAction = $false

    # Усі перевірки git — до першого звернення до платформи: зупинки дешеві, платформа — ні.
    $plan = @(foreach ($src in $sources) {
        # Порядок: спершу інваріанти git (дзеркало, merge-base, ref) — вони перевіряються без сховища й дають
        # точнішу зупинку; шлях сховища — другим (P1 префлайту B3).
        $vv = Get-KitVerifyVersion -RepoRoot $root -Ref $ref -Branch $src.Branch
        if (-not (Test-Path -LiteralPath $src.StoragePath)) { throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)." }
        # Дамп — у базі агента воркспейсу, а не в тимчасовій ІБ зі стабом (спека 2026-09-17
        # §2, той самий принцип, що sync.psm1): обидва боки порівняння verify мають бути
        # здобуті в одному контексті серіалізації, інакше різниця форматів (GUID проти імен)
        # читається як різниця змісту. Get-KitSourceInfobase несе запобіжник «це не дев-база
        # людини» — тут це критично, бо викликач нижче робить ConfigurationRepositoryUpdateCfg,
        # який ЗАМІНЮЄ конфігурацію в базі.
        $agent = Get-KitSourceInfobase -Context $Context -Source $src
        # $null -ne $Version, не голе if ($Version): "не передано" (Nullable[int] лишається
        # $null) — це не те саме, що "передано конкретну версію", і різницю має відрізняти
        # перевірка на $null, а не булеву усічення значення.
        [pscustomobject]@{ Source = $src; Info = $vv; Agent = $agent; Version = $(if ($null -ne $Version) { [int]$Version } else { $vv.Version }) }
    })

    foreach ($item in $plan) {
        $src = $item.Source; $vv = $item.Info; $ver = $item.Version; $agent = $item.Agent
        Write-Host ''
        Write-Host "Джерело:  $($src.Workspace)/$($src.Key)  ·  ref: $ref  ·  версія сховища: $ver (merge-base $($vv.Commit.Substring(0, 7)))"
        if ($vv.NewerVersions.Count -gt 0) {
            Write-Host "  На $($src.Branch) після злитої версії є: $($vv.NewerVersions -join ', ') — сховище попереду '$ref'." -ForegroundColor Yellow
        }

        $workDir = Join-Path $root 'build/verify' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/verify') -Description "робоча тека verify $($src.Key)"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $ib = $agent.IbSwitch
        Write-Host "  База агента ($ib), версія зі сховища, дамп..."
        # $bound = $false ПЕРЕД try обов'язковий (рев'ю B3 раунд 2, Important 4 — та сама
        # асиметрія, що вже виправлена в sync.psm1:150-155): під Set-StrictMode -Version Latest
        # звернення до неприсвоєної змінної у finally само кине й витіснить первинний виняток.
        # Enter-KitStorageBind — УСЕРЕДИНІ try: якщо прив'язка впаде, Exit- покличеться з
        # Bound=$false і нічого не спробує зняти — без цього невдала прив'язка лишила б
        # ConfigurationRepositoryBindCfg без пари Unbind, а це єдиний запис kit у сховище
        # конфігурації, і межа «сховище лише читання» тримається саме на симетрії цієї пари.
        $bound = $false
        try {
            $bound = Enter-KitStorageBind -IbSwitch $ib -Source $src -User $agent.User
            $dumpCount = Invoke-KitStorageCheckout -IbSwitch $ib -Source $src -Version $ver -Target (Join-Path $workDir 'dump') -MustBeUnder $workDir -User $agent.User
        } finally {
            Exit-KitStorageBind -IbSwitch $ib -Source $src -Bound $bound -User $agent.User
        }
        $treeDir = Join-Path $workDir 'tree'
        $treeCount = Export-KitTree -RepoRoot $root -Ref $ref -RepoPath $src.RepoPath -Destination $treeDir
        Write-Host "  Файлів: у дампі $dumpCount, у дереві '$ref' $treeCount"
        Write-Host ("  База агента воркспейсу '{0}' тепер містить версію {1} зі сховища. Перед роботою: operation=build Уніки." -f `
            $agent.Workspace, $ver) -ForegroundColor Yellow

        # Ordinal HashSet замість Sort-Object -Unique (рев'ю B3 раунд 2, дрібна правка 7):
        # Sort-Object -Unique за замовчуванням культурозалежний і регістронечутливий — та
        # сама політика порівняння шляхів, яку Compare-KitTrees (TreeCompare.psm1) явно
        # відкидає на користь Ordinal. Тут порядок елементів не важливий (масив іде лише як
        # вхід у Get-KitBinaryPaths), важлива тільки коректність дедуплікації.
        $relSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($rel in (@(Get-KitRelativeFiles -Root (Join-Path $workDir 'dump')) + @(Get-KitRelativeFiles -Root $treeDir))) { $relSet.Add($rel) | Out-Null }
        $allRel = [string[]]$relSet
        $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths $allRel
        $diff   = Compare-KitTrees -DumpDir (Join-Path $workDir 'dump') -TreeDir $treeDir -BinaryPaths $binary

        $differs = ($diff.CrOnly.Count + $diff.Content.Count + $diff.OnlyInDump.Count + $diff.OnlyInTree.Count) -gt 0
        $verdict = if (-not $differs -and $vv.NewerVersions.Count -eq 0) { 'equal' }
                   elseif (-not $differs) { 'storage-ahead' }
                   elseif ($vv.NewerVersions.Count -eq 0) { 'ref-ahead' }
                   else { 'mixed' }

        Write-Host "  Побайтово рівних: $($diff.Equal) із $($diff.Total)"
        Write-KitDiffList -Title 'лише CR (зіпсована політика тексту — docs/text-policy.md)' -Items $diff.CrOnly
        Write-KitDiffList -Title 'змістовні розбіжності' -Items $diff.Content
        Write-KitDiffList -Title 'тільки в дампі зі сховища' -Items $diff.OnlyInDump
        Write-KitDiffList -Title "тільки в дереві '$ref'" -Items $diff.OnlyInTree
        if ($diff.OnlyInDump.Count -gt 0) {
            # -f поза дужками PowerShell зв'язав би як -ForegroundColor (P4 префлайту B3) — оператор формату всередині.
            Write-Host (("  Увага: {0} файл(ів) є лише в дампі зі сховища — '{1}' їх ВТРАТИВ. Це не «робота, яку треба застосувати у сховищі», " +
                         "а прогалина в '{1}': перевірте злиття {2} у '{1}' і канонізацію.") -f $diff.OnlyInDump.Count, $ref, $src.Branch) -ForegroundColor Yellow
        }

        switch ($verdict) {
            'equal'         { Write-Host "  Вердикт: equal — '$ref' ≡ сховище (версія $ver)." -ForegroundColor Green }
            'storage-ahead' { Write-Host "  Вердикт: storage-ahead — у сховищі є версії повз '$ref'. Звірочний коміт: kit verify -Ref $ref -Apply" -ForegroundColor Yellow; $anyAction = $true }
            'ref-ahead'     { Write-Host "  Вердикт: ref-ahead — '$ref' розійшовся зі сховищем (версія $ver): змістовні/CR-розбіжності й «тільки в дереві» — робота, ще не застосована у сховищі (зберіть артефакт: kit build / operation=make); «тільки в дампі» — див. «Увага» вище." -ForegroundColor Yellow; $anyAction = $true }
            'mixed'         { Write-Host "  Вердикт: mixed — і '$ref' має незастосоване, і сховище пішло вперед. Спершу звірочний коміт (kit verify -Apply), потім розбір залишку." -ForegroundColor Yellow; $anyAction = $true }
        }

        $merged = $false
        if ($Apply -and $vv.NewerVersions.Count -gt 0) {
            # try/catch навколо звірочного коміту (рев'ю B3 раунд 2, Important 3) — той самий
            # принцип, що sync.psm1 документує для Invoke-KitMainMerge («невдача злиття не
            # скасовує реплею»): конфлікт злиття одного джерела не має скасовувати verify
            # решти джерел без try — виняток летів би назовні crash-ом усього прогону, ХОЧА
            # платформна робота (дамп зі сховища в базі агента, дерево) для вже перевірених і для решти
            # джерел лишається дорогою й корисною, а структурований Results — важливішим за
            # один необроблений виняток.
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

        $results.Add([pscustomobject]@{ Key = $src.Key; Ref = $ref; Version = $ver; Verdict = $verdict; Diff = $diff; Merged = $merged })
    }

    [pscustomobject]@{ ExitCode = $(if ($anyAction) { 3 } else { 0 }); Results = $results.ToArray() }
}

Export-ModuleMember -Function Invoke-KitVerify
