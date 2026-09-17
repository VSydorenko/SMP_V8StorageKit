#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Invoke-KitCanon {
    <#
    .SYNOPSIS
        Канонізація дерева агента (спека §3.6): /DumpConfigToFiles з бази агента назад у
        дерево кожного джерела. Передумова — operation=build Уніки вже наповнив базу; kit
        цього не робить і не перевіряє інакше, ніж за наявністю бази.
    .DESCRIPTION
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
        (Remove-Item -Recurse -Force) перед тим, як платформа запише туди свій дамп —
        інакше в дереві лишились би файли, яких платформа вже не віддає. Тому
        Assert-SafeWorkPath стоїть ДО видалення, а не після. Перед самим видаленням —
        страховка (Backup-KitDirtyFiles, C4): усе незакомічене чи невідстежуване в
        дереві копіюється в canon-backup/, інакше "агент забув operation=build" знищує
        його роботу безслідно.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

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
        if ($null -eq $ab) { Write-Host "  у v8project.yaml немає infobase: — бази агента немає, канонізувати нічим."; continue }
        Write-Host "  База агента: $($ab.IbSwitch)  ($($ab.Origin))"
        foreach ($t in $targets) { Write-Host "  - $($t.Key) → $($t.RepoPath)" }

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply (дерева джерел будуть переписані платформою).' -ForegroundColor Cyan
            continue
        }
        if ($ab.Kind -eq 'file' -and -not $ab.Exists) {
            throw "Бази агента ще немає: $($ab.Path). Спершу kit provision -Workspace $($ws.Path) -Apply, потім operation=build Уніки, тоді canon."
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

            if (Test-Path -LiteralPath $t.FullPath) { Remove-Item -LiteralPath $t.FullPath -Recurse -Force }
            New-Item -ItemType Directory -Path $t.FullPath -Force | Out-Null

            $ext = if ($t.Type -eq 'EXTENSION') { " -Extension $($t.Key)" } else { '' }
            $r = Invoke-V8Designer -IbSwitch $ab.IbSwitch -User $ab.User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $t.FullPath, $ext))
            if ($r.ExitCode -ne 0) {
                Assert-V8InfobaseNotBusy -Output $r.Output -Infobase "агента ($($ws.Path))"
                throw "Канонізація $($t.Key) не вдалася: $($r.Output)"
            }
            $files = @(Get-ChildItem -LiteralPath $t.FullPath -Recurse -File).Count
            $changed = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $t.RepoPath).Count
            $summary = "  $($t.Key): файлів $files, змінено файлів: $changed"
            if ($backupDir) { $summary += " (резервна копія до canon: $backupDir)" }
            Write-Host $summary -ForegroundColor Green
            $done.Add([pscustomobject]@{ Key = $t.Key; Files = $files; Changed = $changed; Backup = $backupDir })
        }
    }
    [pscustomobject]@{ ExitCode = 0; Canonized = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitCanon
