#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Invoke-KitCanon {
    <#
    .SYNOPSIS
        Канонізація дерева агента (спека §3.6): /DumpConfigToFiles з бази агента назад у
        дерево кожного джерела. Передумова — push Уніки (unica.run) вже наповнив базу; kit
        цього не робить і не перевіряє інакше, ніж за наявністю бази.
    .DESCRIPTION
        -MarkerOnly (спека §10 П5): позначку поставки пише її власник — canon — і після pull
        Уніки, який уже поклав .cf; тоді вивантажувати знову нема чого. Режим не потребує
        бази агента й платформи, працює з одним набором CONFIGURATION (-Source) і пише
        позначку лише в стані missing (див. Invoke-KitCanonMarkerOnly).

        Агент, що редагує через Unica, ніколи не має байт-канонічного дерева: Unica пише
        свій формат, а git має містити байти, які віддає сама платформа 1С. canon
        переписує дерево кожного джерела воркспейсу тим, що платформа справді віддає з
        бази агента — після цього будь-яке порівняння з чим завгодно (verify, git diff)
        стає семантичним, а не побайтовим шумом формату Уніки.

        Канонізуються джерела Type ∈ {CONFIGURATION, EXTENSION} з truth ∈ {storage, dump,
        git} (тобто все, крім truth: vendor — його канон дав би дамп бази ЛЮДИНИ, не
        агента, а це вже задача kit dump). Зовнішні обробки
        (EXTERNAL_DATA_PROCESSORS) платформа не вивантажує через DumpConfigToFiles —
        пропускаються з поясненням.

        Без -Apply — лише прев'ю: перелік цілей і причини пропуску, без жодного
        звернення до диска чи платформи. З -Apply дерево кожної цілі СТИРАЄТЬСЯ
        (Remove-KitDirectory) перед тим, як платформа запише туди свій дамп —
        інакше в дереві лишились би файли, яких платформа вже не віддає. Тому
        Assert-SafeWorkPath стоїть ДО видалення, а не після. Перед самим видаленням —
        страховка (Backup-KitDirtyFiles, C4): усе незакомічене чи невідстежуване в
        дереві копіюється в canon-backup/, інакше "агент забув push Уніки (unica.run)"
        знищує його роботу безслідно.

        Копія canon-backup покриває лише те, що бачить git status. Робота, якої він не бачить
        (ігноровані файли крім похідних, файли з прапорцем assume-unchanged/skip-worktree,
        підмодулі), була б знищена безслідно, тож -Apply зупиняється на ній ДО першого
        видалення й до запуску платформи (спека §10.2 П24, Get-KitInvisibleWork) — для всіх
        цілей одразу, щоб зупинка не настала після того, як перше дерево вже стерто.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$MarkerOnly
    )

    if ($MarkerOnly) { return (Invoke-KitCanonMarkerOnly -Context $Context -Workspace $Workspace -Source $Source -Apply $Apply) }

    $root = $Context.RepoRoot
    $selected = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
    $done = [System.Collections.Generic.List[object]]::new()
    $byWorkspace = $selected | Group-Object Workspace

    foreach ($group in $byWorkspace) {
        $ws = $Context.Workspaces | Where-Object Path -eq $group.Name | Select-Object -First 1
        $targets = @($group.Group | Where-Object { $_.Type -in @('CONFIGURATION', 'EXTENSION') -and $_.Truth -ne 'vendor' })
        $skipped = @($group.Group | Where-Object { $_ -notin $targets })

        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        foreach ($s in $skipped) {
            # Порядок реченнєвого шаблону НЕ довільний (правка виконавця, задокументована в
            # брифі задачі): тест Step 1 (Canon.Tests.ps1, "vendor пропускається з
            # поясненням") перевіряє підрядки '*base*vendor*пропущен*' саме в цьому порядку
            # зліва направо — тобто truth: vendor мусить зустрітись у виводі РАНІШЕ за слово
            # "пропущено", а не навпаки. Літеральний текст Step 2 брифа ("$($s.Key):
            # пропущено ($why).") друкує "пропущено" першим і цей тест провалював.
            $why = if ($s.Truth -eq 'vendor') { 'чужа конфігурація (truth: vendor) — її канон дав би дамп бази людини (kit dump), не бази агента' }
                   else { "$($s.Type) — зовнішні обробки платформа не вивантажує через DumpConfigToFiles" }
            Write-Host "  - $($s.Key): $why. Пропущено." -ForegroundColor DarkGray
        }
        if ($targets.Count -eq 0) { continue }

        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { throw (New-KitAgentBaseMissingMessage -WorkspacePath $ws.Path) }
        Write-Host "  База агента: $($ab.IbSwitch)  ($($ab.Origin))"
        foreach ($t in $targets) { Write-Host "  - $($t.Key) → $($t.RepoPath)" }

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply (дерева джерел будуть переписані платформою).' -ForegroundColor Cyan
            continue
        }
        if ($ab.Kind -eq 'file' -and -not $ab.Exists) {
            throw "Бази агента ще немає: $($ab.Path). Спершу v8storagekit:provision, тоді canon."
        }

        # П24: невидима для git status робота. Перевірка всіх цілей — до першого Remove-KitDirectory
        # і до платформи; збій git — виняток (не «чисто»), дерево лишається цілим.
        $invisible = foreach ($t in $targets) {
            foreach ($w in @(Get-KitInvisibleWork -RepoRoot $root -RepoPath $t.RepoPath)) {
                [pscustomobject]@{ Key = $t.Key; Kind = $w.Kind; Path = $w.Path }
            }
        }
        $invisible = @($invisible)
        if ($invisible.Count -gt 0) {
            $list = ($invisible | ForEach-Object { "  [$($_.Kind)] $($_.Path)  (набір $($_.Key))" }) -join "`n"
            throw ("canon -Apply зупинено: невидима робота під набором — git status її не бачить, а canon стер би теку набору разом з нею, " +
                   "і копія canon-backup її не покриває:`n$list`nТеки наборів не чіпано, платформу не запущено. Для кожного шляху: " +
                   'закомітити (ignored — зняти з ігнору й закомітити); зняти прапорець — git update-index --no-assume-unchanged / --no-skip-worktree <шлях>; ' +
                   'підмодуль (gitlink) — винести за межі набору; або перенести файл за межі набору. Потім повторіть canon.')
        }

        foreach ($t in $targets) {
            Assert-SafeWorkPath -Path $t.FullPath -MustBeUnder $ws.FullPath -Description "дерево джерела $($t.Key)"

            # C4: знімок незакомічених/невідстежуваних файлів ДО видалення — і збій git
            # тут (C1) зупиняє ДО Remove-Item, тож дерево лишається цілим.
            $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $t.RepoPath)
            $backupDir = $null
            if ($dirty.Count -gt 0) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'canon-backup' "$($t.Key)-$stamp"))
                $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $t.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
                Write-Host "  $($t.Key): $($dirty.Count) незакомічених змін — копія перед canon у $backupDir" -ForegroundColor Yellow
            }

            Remove-KitDirectory -Path $t.FullPath
            New-Item -ItemType Directory -Path $t.FullPath -Force | Out-Null

            $ext = if ($t.Type -eq 'EXTENSION') { " -Extension $($t.Key)" } else { '' }
            $r = Invoke-V8Designer -IbSwitch $ab.IbSwitch -User $ab.User -Password $ab.Password -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $t.FullPath, $ext))
            if ($r.ExitCode -ne 0) {
                Assert-V8InfobaseNotBusy -Output $r.Output -Infobase "агента ($($ws.Path))"
                throw "Канонізація $($t.Key) не вдалася: $($r.Output)"
            }
            # Позначка поставки (спека 2026-09-30 §5.2, §5.3): .cf кладе вивантаження з бази
            # агента — canon або pull Уніки; позначку пише лише canon, тож саме тут фіксуємо,
            # з яким .bin .cf вивантажено.
            $supplyMarker = $null
            if ($t.Type -eq 'CONFIGURATION') {
                $supplyMarker = Write-KitSupplyMarker -TreeRoot $t.FullPath
                if ($supplyMarker) { Write-Host "  $($t.Key): поставку вендора вивантажено, позначка .kit-bin-sha1 записана." -ForegroundColor DarkGray }
            }
            $files = @(Get-ChildItem -LiteralPath $t.FullPath -Recurse -File).Count
            $changed = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $t.RepoPath).Count
            $summary = "  $($t.Key): файлів $files, змінено файлів: $changed"
            if ($backupDir) { $summary += " (резервна копія до canon: $backupDir)" }
            Write-Host $summary -ForegroundColor Green
            $done.Add([pscustomobject]@{ Key = $t.Key; Files = $files; Changed = $changed; Backup = $backupDir; SupplyMarker = $supplyMarker })
        }
    }
    [pscustomobject]@{ ExitCode = 0; Canonized = $done.ToArray() }
}

function Invoke-KitCanonMarkerOnly {
    <#
    .SYNOPSIS
        canon без вивантаження: лише .kit-bin-sha1 для набору CONFIGURATION, .cf якого вже поклав pull Уніки.
    .DESCRIPTION
        Передумови спеки §10 П5 — набір CONFIGURATION, .bin описує поставку, .cf на місці, дерево
        набору чисте. Брудне дерево після pull — запасна гілка §4.1: вивантаження раннера дало інші
        байти, ніж kit, і позначка засвідчила б стан, якого kit не перевіряв. Бази агента цей режим
        не потребує й платформи не кличе. Теки набору режим не стирає, тож перевірки невидимої
        роботи (П24) тут не потрібно.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [string]$Workspace, [string]$Source, [bool]$Apply)

    if (-not $Source) { throw '-MarkerOnly потребує -Source <ключ основної конфігурації>: режим пише позначку поставки рівно одному набору.' }
    $src = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)[0]
    if ($src.Type -ne 'CONFIGURATION') {
        throw "-MarkerOnly: '$($src.Key)' — $($src.Type), а позначка поставки буває лише в наборі CONFIGURATION."
    }
    if (-not (Test-KitSupplyDescribed -TreeRoot $src.FullPath)) {
        throw "-MarkerOnly: Ext/ParentConfigurations.bin набору '$($src.Key)' не описує поставку вендора — позначка не потрібна."
    }
    $dir = Join-Path $src.FullPath (Get-KitSupplyRelativePath)
    if (@(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue).Count -eq 0) {
        throw "-MarkerOnly: у $dir немає .cf — позначку нема чим підтвердити. Спершу крок pull Уніки, надрукований kit sync чи kit verify."
    }
    # Спека §10.1 П22: pull --force стирає каталог набору РАЗОМ з позначкою (§2.2), тож свіжий pull
    # лишає стан missing (.cf є, позначки немає) — лише тоді режим пише позначку. Стара позначка на
    # місці (stale) доводить, що .cf цим pull не перевивантажувався: запис освятив би пару «новий .bin
    # + старий .cf». Час зміни файлу тут не доказ — git ставить його .bin на кожному checkout.
    $state = Get-KitSupplyState -TreeRoot $src.FullPath
    if ($state -eq 'current') {
        Write-Host "  $($src.Key): позначка .kit-bin-sha1 вже відповідає .bin — писати нічого." -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0; Canonized = @() }
    }
    if ($state -eq 'stale') {
        throw ("-MarkerOnly: стара позначка .kit-bin-sha1 на місці (не відповідає .bin) — .cf цим pull не перевивантажувався. " +
               "Позначку не записано. Спершу крок pull Уніки, надрукований kit sync чи kit verify, тоді повторіть.")
    }
    $dirty = @(Get-KitDirtyRecords -RepoRoot $Context.RepoRoot -RepoPath $src.RepoPath)
    if ($dirty.Count -gt 0) {
        throw ("-MarkerOnly: дерево '$($src.RepoPath)' брудне ($($dirty.Count) змін після pull) — вивантаження раннера дало інші байти, " +
               'ніж kit, або в дереві чужа робота. Позначку не записано. Зупинка й доповідь людині: git status -- ' + $src.RepoPath)
    }
    if (-not $Apply) {
        Write-Host "  $($src.Key): буде записано позначку .kit-bin-sha1 без вивантаження. Для виконання додайте -Apply." -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Canonized = @() }
    }
    $sha = Write-KitSupplyMarker -TreeRoot $src.FullPath
    Write-Host "  $($src.Key): позначку .kit-bin-sha1 записано ($sha); дерево не переписувалось." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Canonized = @([pscustomobject]@{ Key = $src.Key; Files = 0; Changed = 0; Backup = $null; SupplyMarker = $sha }) }
}

Export-ModuleMember -Function Invoke-KitCanon
