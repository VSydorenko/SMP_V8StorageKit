#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Get-KitCanonStatusRecords {
    <#
    .SYNOPSIS
        git status --porcelain -z -uall для дерева одного джерела, розібраний на записи:
        один запис — одна логічна зміна (M/D/??/R/C тощо), а не один NUL-токен.
    .DESCRIPTION
        Приватна (не експортована) — спільна для двох застосувань усередині Invoke-KitCanon:
        (1) лічильник Changed ПІСЛЯ дампу платформи (рев'ю B4, P6/C3) і (2) знімок
        незакомічених/невідстежуваних файлів дерева ДО Remove-Item (рев'ю B4, C4 —
        страховка від безслідного знищення роботи, яку агент ще не закомітив: дерево на
        момент canon штатно брудне, Unica щойно в нього писала, коміт іде ПІСЛЯ canon).

        -uall (--untracked-files=all): без нього нова піддерева (нова форма, новий
        макет — типовий об'єкт метаданих) згортаються в ОДИН запис "?? Тека/" замість
        переліку файлів (C3, перевірено живим git: 4 нових файли в новій теці без -uall
        дають один запис, з -uall — чотири).

        Через Invoke-KitGitProcess (tools/lib/TreeCompare.psm1), а не голий `git | Out-String`
        (C1): явний код виходу перевіряється тут же — збій git інакше читався б як "нуль
        змін" (рівно той сигнал успіху, який round-trip Integration-тест перевіряє як
        "дерево вже канонічне"); stdout і stderr окремо, а не 2>$null, який ковтав би
        діагностику збою; явний UTF-8 незалежно від амбієнтної консолі процесу. Побічний
        наслідок переходу на Invoke-KitGitProcess: немає артефакту Out-String (свій
        "`r`n" ПІСЛЯ останнього NUL, знахідка живого прогону P6) — але фільтр
        Where-Object { $_.Trim() -ne '' }, а не голий { $_ }, лишається як єдина
        конвенція розбиття по "`0" на весь файл, а не лише страховка від конкретного
        артефакту одного інструмента.

        Записи зі статусом R (перейменування) чи C (копія) несуть ДВА NUL-роздільні
        поля замість одного — спершу НОВИЙ шлях, тоді СТАРИЙ (git-status(1), формат -z).
        Наївне «кожен NUL-токен = один запис» з'їжджає на першому ж такому записі: або
        кидає виняток на .Substring, коли бере старий шлях (він КОРОТШИЙ за очікувану
        довжину префіксу статусу) за новий запис, або мовчки псує шлях (обрізає перші 3
        символи назви файла — перевірено живим прогоном рев'ю: "src/Old.xml" ставало
        "/src/Old.xml"). Тому розбір — послідовний, зі станом: побачивши статус, що
        містить R чи C, наступний NUL-токен свідомо споживається як OldPath ЦЬОГО
        самого запису, а не як початок наступного.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$RepoPath)

    $gitResult = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'status', '--porcelain', '-z', '-uall', '--', $RepoPath)
    if ($gitResult.ExitCode -ne 0) {
        throw "git status для '$RepoPath' завершився з кодом $($gitResult.ExitCode): $($gitResult.Stderr)"
    }
    $tokens = @($gitResult.Stdout -split "`0" | Where-Object { $_.Trim() -ne '' })

    $records = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $tokens.Count) {
        $tok = $tokens[$i]
        # "XY <шлях>" — статус (2 символи) + пробіл + принаймні один символ шляху.
        if ($tok.Length -lt 4) { throw "git status: незрозумілий запис '$tok' — задовгий/закороткий для формату 'XY <шлях>'." }
        $status = $tok.Substring(0, 2)
        $path = $tok.Substring(3)
        $i++
        $oldPath = $null
        if ($status -match '[RC]') {
            if ($i -ge $tokens.Count) { throw "git status: запис перейменування/копії '$tok' без другого (старого) шляху." }
            $oldPath = $tokens[$i]
            $i++
        }
        $records.Add([pscustomobject]@{ Status = $status; Path = $path; OldPath = $oldPath })
    }
    # Без коми-обгортки — та сама конвенція, що й Select-KitSources (Preflight.psm1):
    # єдиний викликач (Invoke-KitCanon) сам загортає в @(...).
    $records.ToArray()
}

function Backup-KitCanonDirtyFiles {
    <#
    .SYNOPSIS
        Страховка перед Remove-Item (спека §3.6, рев'ю B4 C4): копіює те, що canon ось-ось
        знищить безслідно, якщо воно ще не закомічене.
    .DESCRIPTION
        Заборону "не canon-syньте на брудному дереві" архітектор відкинув свідомо: дерево на
        момент canon ЗАВЖДИ потенційно брудне за задумом циклу (Unica щойно писала в
        нього, коміт іде ПІСЛЯ canon, не до) — гард, що спрацьовує на кожному штатному
        прогоні, вимикають першим. Лікуємо не перезапис (це робота canon), а безслідність:
        той самий патерн, що вже є в kit — migrate перед переписуванням історії не
        забороняє нічого, він робить git bundle.

        Копіюються ЛИШЕ перелічені git-ом шляхи (не все дерево — типово кілька файлів
        проти тисяч), зі збереженням структури відносно кореня джерела, у
        <воркспейс>/<workPath>/canon-backup/<ключ джерела>-<yyyyMMdd-HHmmss>/. Тека під
        workPath гітігнорована (те саме дерево, що вже несе build/ib бази агента) — робочу
        копію не забруднює. Порожній перелік $Records — $null без жодного звернення до
        диска (штатний випадок: дерево вже канонічне з попереднього прогону).

        Для запису R/C (Get-KitCanonStatusRecords) копіюється КОЖЕН із двох шляхів, який
        існує на диску просто зараз: після звичайного `git mv` існує лише новий (старий
        Remove-Item уже прибрав з диска сам git mv, до canon), але код цього не
        припускає — перевіряє Test-Path для обох незалежно.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$MustBeUnder
    )

    if ($Records.Count -eq 0) { return $null }

    Assert-SafeWorkPath -Path $BackupRoot -MustBeUnder $MustBeUnder -Description 'резервна копія canon перед видаленням'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    foreach ($rec in $Records) {
        foreach ($p in @($rec.Path, $rec.OldPath) | Where-Object { $_ }) {
            # Захист, а не очікуваний шлях виконання: пейсспек git status уже обмежив
            # відповідь до RepoPath, тому щось поза префіксом тут — ознака, що якесь
            # інше припущення про формат зламане, а не легальний випадок.
            if (-not $p.StartsWith("$prefix/", [System.StringComparison]::Ordinal)) { continue }
            $rel = $p.Substring($prefix.Length + 1)
            $srcPath = Join-Path $RepoRoot $p
            if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) { continue }
            $dstPath = Join-Path $BackupRoot $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dstPath) -Force | Out-Null
            Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
        }
    }
    $BackupRoot
}

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
        страховка (Backup-KitCanonDirtyFiles, C4): усе незакомічене чи невідстежуване в
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
            $dirty = @(Get-KitCanonStatusRecords -RepoRoot $root -RepoPath $t.RepoPath)
            $backupDir = $null
            if ($dirty.Count -gt 0) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'canon-backup' "$($t.Key)-$stamp"))
                $null = Backup-KitCanonDirtyFiles -RepoRoot $root -RepoPath $t.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
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
            $changed = @(Get-KitCanonStatusRecords -RepoRoot $root -RepoPath $t.RepoPath).Count
            $summary = "  $($t.Key): файлів $files, змінено файлів: $changed"
            if ($backupDir) { $summary += " (резервна копія до canon: $backupDir)" }
            Write-Host $summary -ForegroundColor Green
            $done.Add([pscustomobject]@{ Key = $t.Key; Files = $files; Changed = $changed; Backup = $backupDir })
        }
    }
    [pscustomobject]@{ ExitCode = 0; Canonized = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitCanon
