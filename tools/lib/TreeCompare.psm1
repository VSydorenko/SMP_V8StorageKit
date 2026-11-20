#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/Supply.psm1"

$script:PlatformJunk = @('ConfigDumpInfo.xml', 'DumpFilesIndex.txt')

function Read-KitStreamLine {
    # Рядок до \n із байтового потоку (заголовок cat-file --batch: "<sha> blob <size>").
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while (($b = $Stream.ReadByte()) -ge 0) {
        if ($b -eq 10) { break }
        $bytes.Add([byte]$b)
    }
    [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Copy-KitStreamBytes {
    param([Parameter(Mandatory)][System.IO.Stream]$From, [Parameter(Mandatory)][System.IO.Stream]$To, [Parameter(Mandatory)][int64]$Count)
    $buffer = New-Object byte[] 65536
    $left = $Count
    while ($left -gt 0) {
        $n = $From.Read($buffer, 0, [int][Math]::Min($buffer.Length, $left))
        if ($n -le 0) { throw 'Потік git cat-file обірвався до кінця блоба.' }
        $To.Write($buffer, 0, $n)
        $left -= $n
    }
}

function Invoke-KitGitProcess {
    <#
    .SYNOPSIS
        git як .NET Process: NUL-роздільники на вході (для -z --stdin), UTF-8 без перекодування PowerShell на
        виході, stderr окремо, код виходу — у результаті. Для потокових байтів (cat-file --batch) є Export-KitTree.
    .DESCRIPTION
        ОБИДВА вихідні потоки читаються асинхронно ДО запису stdin: форма «записати весь stdin, потім
        ReadToEnd()» на сотнях шляхів зависає назавжди — буфер stdout заповнюється, git блокується на
        записі й перестає читати stdin, а наш Write блокується назустріч. Юніт-тест на двох шляхах
        цього не бачить. Не «спрощувати» назад.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [AllowEmptyCollection()][string[]]$StdinRecords = @()
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in (@('-C', $RepoRoot) + $Arguments)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()   # ДО запису stdin — інакше дедлок на великому виводі
        foreach ($rec in $StdinRecords) { $proc.StandardInput.Write($rec); $proc.StandardInput.Write([char]0) }
        $proc.StandardInput.Close()
        $stdout = $outTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $errTask.Result }
    } finally {
        # Process.Dispose() НЕ закриває стандартні потоки: якщо запис у stdin перервано (Ctrl+C),
        # git лишається заблокованим на читанні НАЗАВЖДИ. Close() ідемпотентний; таймаут і
        # Kill($true) — якщо процес однаково завис.
        try { $proc.StandardInput.Close() } catch {}
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill($true) } catch {}
            $proc.WaitForExit()
        }
        $proc.Dispose()
    }
}

function Get-KitCurrentBranch {
    <#
    .SYNOPSIS
        Ім'я поточної гілки (git branch --show-current) — одна копія на kit. На від'єднаному HEAD
        git дає порожній рядок, і викликачі трактують його як «не головна гілка».
    .DESCRIPTION
        Через Invoke-KitGitProcess: stderr окремо, тож попередження git (safe.directory тощо) на
        stderr при коді виходу 0 не потрапляють в ім'я гілки.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('branch', '--show-current')
    if ($r.ExitCode -ne 0) { throw "git branch --show-current у $RepoRoot завершився з кодом $($r.ExitCode)." }
    $r.Stdout.Trim()
}

function Test-KitOnMainBranch {
    <#
    .SYNOPSIS
        Чи поточна гілка — головна: єдина копія умови для sync, verify і check (вибір варіанта рецепту поставки).
    .DESCRIPTION
        Порівняння ЧУТЛИВЕ до регістру (-ceq): гілки git розрізняють регістр, і `Main` на гілці задачі не мусить
        показати рецепт головної (з pull). Від'єднаний HEAD (порожнє ім'я) і збій git дають $false — консервативний
        варіант «спершу поставка на головній гілці».
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$MainBranch)
    try { $current = Get-KitCurrentBranch -RepoRoot $RepoRoot } catch { return $false }
    ($current -ne '') -and ($current -ceq $MainBranch)
}

function Export-KitTree {
    <#
    .SYNOPSIS
        Дерево <Ref>:<RepoPath> у теку Destination — байт-у-байт із блобів git.
    .DESCRIPTION
        git archive і checkout застосовують eol-конверсію з .gitattributes (перевірено), а нам
        треба те, що ЛЕЖИТЬ у git: інакше «лише CR» діагностував би налаштування машини, а не
        стан репозиторію. Один процес cat-file --batch, запит-відповідь по блобу, stdout читаємо
        як байти через .NET Process — PowerShell-конвейєр перекодовував би вміст.
        Дедлоку, який ловить Invoke-KitGitProcess, тут НЕМАЄ і переробляти на асинхронне читання не
        треба: запис і читання чергуються по одному блобу — git не приймає наступного запиту, доки
        попередню відповідь не вичитано. stderr — асинхронно, бо його обсяг невідомий.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-KitBuildPath -Path $Destination -MustBeUnder (Join-Path $RepoRoot 'build') -RepoRoot $RepoRoot -Description 'тека вивантаження дерева git'
    Remove-KitDirectory -Path $Destination
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    # ls-tree — через Invoke-KitGitProcess, не голим `git ... | ...`: той декодує за кодуванням консолі,
    # і на cp866 кириличний шлях став би сміттям (і в OnlyInDump, і в OnlyInTree). -z: шляхи сирі,
    # незалежно від core.quotepath машини.
    $ls = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'ls-tree', '-r', '-z', $Ref, '--', $prefix)
    if ($ls.ExitCode -ne 0) { throw "git ls-tree $Ref -- $prefix завершився з кодом $($ls.ExitCode): $($ls.Stderr)" }
    $entries = @($ls.Stdout -split "`0" | Where-Object { $_ })
    if ($entries.Count -eq 0) { return 0 }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in @('-C', $RepoRoot, 'cat-file', '--batch')) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [System.Text.Encoding]::ASCII
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()   # читати асинхронно, інакше повний буфер stderr заблокує git
    $stdin = $proc.StandardInput
    $out   = $proc.StandardOutput.BaseStream
    $exit  = -1; $stderr = ''

    $count = 0
    try {
        foreach ($entry in $entries) {
            if ($entry -notmatch '^(?<mode>\d+) (?<type>\w+) (?<sha>[0-9a-f]{40})\t(?<path>.+)$') {
                throw "Нерозпізнаний рядок git ls-tree: '$entry'"
            }
            if ($Matches['type'] -ne 'blob') { continue }
            $sha = $Matches['sha']
            $rel = $Matches['path'].Substring($prefix.Length).TrimStart('/')

            $stdin.WriteLine($sha)
            $stdin.Flush()
            $header = Read-KitStreamLine -Stream $out
            if ($header -notmatch '^[0-9a-f]{40} blob (?<size>\d+)$') { throw "git cat-file --batch: неочікуваний заголовок '$header' для $rel" }
            $size = [int64]$Matches['size']

            $file = Join-Path $Destination $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            $fs = [System.IO.File]::Create($file)
            try { Copy-KitStreamBytes -From $out -To $fs -Count $size } finally { $fs.Dispose() }
            $out.ReadByte() | Out-Null   # завершальний \n після вмісту блоба
            $count++
        }
    } finally {
        $stdin.Close()
        # Виняток усередині циклу лишає git cat-file --batch посеред запису блоба в stdout, який
        # ніхто не читає (буфер каналу малий — зависає практично кожен реальний Form.xml):
        # WaitForExit() без таймауту не повернеться НІКОЛИ. Тому — таймаут і примусове завершення.
        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill($true) } catch {}
            $proc.WaitForExit()
        }
        $exit = $proc.ExitCode
        # $errTask.Result кидає AggregateException, якщо читання stderr впало, — це замінило б
        # справжню причину збою. finally не кидає власних винятків.
        try { $stderr = $errTask.Result } catch { $stderr = '' }
        $proc.Dispose()
    }
    # .NET Process — теж нативний виклик: код виходу перевіряється, як і в кожного git.
    if ($exit -ne 0) { throw "git cat-file --batch завершився з кодом ${exit}: $stderr" }
    $count
}

function Test-KitComparableRelativePath {
    <#
    .SYNOPSIS
        Чи бере відносний шлях участь у звірці дерев: не службовий файл платформи й не поставка вендора.
    .DESCRIPTION
        Одне джерело фільтра для Get-KitRelativeFiles (диск) і CaseGuard (індекс, перелік git) —
        два фільтри з різною логікою розходилися б тихо.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)
    $leaf = ($RelativePath -split '/')[-1]
    ($script:PlatformJunk -notcontains $leaf) -and -not (Test-KitSupplyRelativePath -RelativePath $RelativePath)
}

function Get-KitRelativeFiles {
    <# Відносні шляхи файлів під Root з '/', без службових файлів платформи. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    # Без коми: усі викликачі загортають результат у @(…).
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $full = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    # Поставка вендора — стан машини, не зміст дерева (§6.3.3); .bin порівнюється,
    # як решта. Відносний шлях обчислюється до фільтра, тож фільтр — після ForEach-Object;
    # фільтр — Test-KitComparableRelativePath.
    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File |
        ForEach-Object { $_.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/' } |
        Where-Object { Test-KitComparableRelativePath -RelativePath $_ })
    $files
}

function Get-KitBinaryPaths {
    <#
    .SYNOPSIS
        Які з відносних шляхів git вважає binary (макрос -text -diff -merge). Питає check-attr,
        а не читає .gitattributes — та сама логіка пріоритетів, що й у checkout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePaths
    )
    # HashSet — IEnumerable, pipeline розгорнув би його в рядки; кома тримає об'єкт цілим.
    # Викликачі беруть результат присвоєнням: $binary = Get-KitBinaryPaths …
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($RelativePaths.Count -eq 0) { return , $set }   # кома навмисно (HashSet)
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $records = @($RelativePaths | ForEach-Object { "$prefix/$_" })
    # -z перемикає і ВХІД на NUL-роздільник: подані через конвеєр рядки з \n git читає як ОДИН шлях, і набір
    # завжди порожній. Тому stdin — через Process із NUL між записами; -z лишається,
    # бо без нього відповідь була б екранована за core.quotepath.
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'check-attr', '-z', 'binary', '--stdin') -StdinRecords $records
    if ($r.ExitCode -ne 0) { throw "git check-attr завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    $fields = @($r.Stdout -split "`0")
    # трійки: <шлях> \0 binary \0 <значення> \0
    for ($i = 0; $i + 2 -lt $fields.Count; $i += 3) {
        if ($fields[$i + 2] -eq 'set') { $set.Add($fields[$i].Substring($prefix.Length).TrimStart('/')) | Out-Null }
    }
    , $set   # кома навмисно: HashSet не має розгортатись pipeline; викликач бере присвоєнням
}

function Compare-KitTrees {
    <#
    .SYNOPSIS
        Класифікація розбіжностей дамп ↔ дерево (спека §3.5): рівні / лише CR / змістовна /
        тільки в дампі / тільки в дереві. binary — лише побайтово.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DumpDir,
        [Parameter(Mandatory)][string]$TreeDir,
        # AllowEmptyCollection обов'язковий: Mandatory на колекції вимагає НЕПОРОЖНЬОЇ, а порожній
        # HashSet — типовий випадок (дерево лише з XML/BSL). Без атрибута verify падав би на прив'язці
        # параметра вже після дампу — після всієї дорогої роботи.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$BinaryPaths,
        # Групи шляхів, що різняться лише регістром (Get-KitCaseCollisions, CaseGuard.psm1), — відносні
        # до TreeDir. На NTFS члени групи вже злились в один файл при експорті, тож порівнювати їх як
        # звичайні шляхи безглуздо: вони звітуються окремим класом (§4.3).
        [AllowEmptyCollection()][object[]]$CaseCollisions = @(),
        # Клас «лише регістр шляху» — лише на явний запит verify. adopt кличе без нього: пара мусить
        # лишатись в OnlyInDump/OnlyInTree, інакше прев'ю adopt сказало б «вже збігається».
        [switch]$ClassifyCase
    )

    # Ordinal, не IgnoreCase: git регістрочутливий. Це НЕ гарантія проти колізії регістру — на NTFS
    # такі шляхи злились ще при експорті (для того є -CaseCollisions). Ordinal ще й детермінований,
    # не залежить від локалі машини.
    $dump = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $DumpDir), [System.StringComparer]::Ordinal)
    $tree = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $TreeDir), [System.StringComparer]::Ordinal)
    $all = [System.Collections.Generic.HashSet[string]]::new($dump, [System.StringComparer]::Ordinal)
    $all.UnionWith($tree)

    $collided = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $groupsOut = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $CaseCollisions) {
        foreach ($p in $g) { [void]$collided.Add($p) }
        $real = @($g | Where-Object { $dump.Contains($_) })
        $groupsOut.Add([pscustomobject]@{ Paths = [string[]]$g; InDump = $(if ($real.Count -gt 0) { $real[0] } else { $null }) })
    }

    $equal = 0
    # Шляхи з Total, які пішли в групи регістру, — щоб звіт сходився арифметично (на NTFS група в
    # дереві — один файл, тож це не сума розмірів груп).
    $caseSkipped = 0
    $crOnly = [System.Collections.Generic.List[string]]::new()
    $content = [System.Collections.Generic.List[string]]::new()
    $onlyDump = [System.Collections.Generic.List[string]]::new()
    $onlyTree = [System.Collections.Generic.List[string]]::new()

    # Сортування — тим самим Ordinal, що й вище (детермінований порядок незалежно від локалі машини).
    $ordered = [System.Linq.Enumerable]::OrderBy([string[]]$all, [Func[string, string]] { param($x) $x }, [System.StringComparer]::Ordinal)
    foreach ($rel in $ordered) {
        if ($collided.Contains($rel)) { $caseSkipped++; continue }
        $inDump = $dump.Contains($rel); $inTree = $tree.Contains($rel)
        if ($inDump -and -not $inTree) { $onlyDump.Add($rel); continue }
        if ($inTree -and -not $inDump) { $onlyTree.Add($rel); continue }
        $a = [System.IO.File]::ReadAllBytes((Join-Path $DumpDir $rel))
        $b = [System.IO.File]::ReadAllBytes((Join-Path $TreeDir $rel))
        if ([System.Linq.Enumerable]::SequenceEqual($a, $b)) { $equal++; continue }
        if ($BinaryPaths.Contains($rel)) { $content.Add($rel); continue }
        $a2 = [byte[]]($a | Where-Object { $_ -ne 13 })
        $b2 = [byte[]]($b | Where-Object { $_ -ne 13 })
        if ([System.Linq.Enumerable]::SequenceEqual($a2, $b2)) { $crOnly.Add($rel) } else { $content.Add($rel) }
    }

    $caseOnlyOut = [System.Collections.Generic.List[object]]::new()
    if ($ClassifyCase -and $onlyDump.Count -gt 0 -and $onlyTree.Count -gt 0) {
        $treeByFold = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $onlyTree) {
            if (-not $treeByFold.ContainsKey($t)) { $treeByFold[$t] = [System.Collections.Generic.List[string]]::new() }
            $treeByFold[$t].Add($t)
        }
        foreach ($d in @($onlyDump)) {
            if (-not $treeByFold.ContainsKey($d) -or $treeByFold[$d].Count -ne 1) { continue }
            $t = $treeByFold[$d][0]
            $same = [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes((Join-Path $DumpDir $d)), [System.IO.File]::ReadAllBytes((Join-Path $TreeDir $t)))
            $caseOnlyOut.Add([pscustomobject]@{ Dump = $d; Tree = $t; ContentEqual = $same })
            [void]$onlyDump.Remove($d); [void]$onlyTree.Remove($t)
        }
    }

    [pscustomobject]@{
        CaseCollisions = $groupsOut.ToArray()
        CaseOnly   = $caseOnlyOut.ToArray()
        CaseCollidedPaths = $caseSkipped
        Equal      = $equal
        CrOnly     = $crOnly.ToArray()
        Content    = $content.ToArray()
        OnlyInDump = $onlyDump.ToArray()
        OnlyInTree = $onlyTree.ToArray()
        Total      = $all.Count
    }
}

Export-ModuleMember -Function Invoke-KitGitProcess, Get-KitCurrentBranch, Test-KitOnMainBranch, Export-KitTree, Test-KitComparableRelativePath, Get-KitRelativeFiles, Get-KitBinaryPaths, Compare-KitTrees
