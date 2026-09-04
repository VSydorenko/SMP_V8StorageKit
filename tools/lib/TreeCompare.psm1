#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

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
        ОБИДВА вихідні потоки читаються асинхронно ДО запису stdin — це не стиль, а причина (проба рев'ю B3):
        наївна форма «записати весь stdin, потім ReadToEnd()» на 800 шляхах зависає назавжди — буфер stdout
        заповнюється, git блокується на записі й перестає читати stdin, а наш Write блокується назустріч.
        На двох шляхах у юніт-тесті цього не видно; вилазить на живому verify. Не «спрощувати» назад.
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
        # Process.Dispose() НЕ закриває стандартні потоки, на які тримає посилання викликач
        # (рев'ю B3, Important 4): якщо запис у stdin перервано (Ctrl+C посеред ~10 тис. шляхів)
        # чи інакше не дійшов до Close() вище, git лишається заблокованим на читанні недописаного
        # stdin НАЗАВЖДИ — осиротілий процес на кожне переривання. Close() тут ідемпотентний (на
        # щасливому шляху stdin уже закрито рядком вище), таймаут і Kill($true) — про всяк випадок,
        # якщо процес однаково завис.
        try { $proc.StandardInput.Close() } catch {}
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill($true) } catch {}
            $proc.WaitForExit()
        }
        $proc.Dispose()
    }
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
        попередню відповідь не вичитано (проба рев'ю B3). stderr — асинхронно, бо його обсяг невідомий.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-SafeWorkPath -Path $Destination -MustBeUnder (Join-Path $RepoRoot 'build') -Description 'тека вивантаження дерева git'
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    # ls-tree йде через Invoke-KitGitProcess, а не голим нативним викликом (рев'ю B3, Important 3):
    # голий `git ... | ...` PowerShell декодує за АМБІЄНТНИМ [Console]::OutputEncoding процесу —
    # на cp866 кириличний шлях перетворюється на сміття (перевірено: "Forms/Форма/Ext/Form.xml" на
    # виході стає непізнаваним, Test-Path очікуваного шляху -> False), і Compare-KitTrees зарахував
    # би такий шлях і в OnlyInDump, і в OnlyInTree. Invoke-KitGitProcess читає stdout з явним UTF-8
    # незалежно від консолі (той самий запобіжник, що вже рятує Get-KitBinaryPaths) і віддає Stderr
    # окремо замість `2>$null`, який ковтав діагностику git. -z: шляхи сирі, NUL-роздільник —
    # незалежно від core.quotepath машини (без -z кирилиця прийшла б екранованою в лапках).
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
        # Виняток усередині циклу (диск під build/ заповнився, антивірус тримає щойно створений
        # файл, мережевий диск моргнув) лишає git cat-file --batch посеред запису вмісту блоба в
        # stdout, який більше ніхто не читає — WaitForExit() без таймауту не повернеться НІКОЛИ
        # (рев'ю B3, Important 1: виміряно на блобі 1 МБ, виняток одразу після заголовка ->
        # WaitForExit(15000) дав False через 15352 мс; буфер каналу — 16 КБ, тобто зависає
        # практично кожен реальний Form.xml). Тому — таймаут і примусове завершення.
        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill($true) } catch {}
            $proc.WaitForExit()
        }
        $exit = $proc.ExitCode
        # $errTask.Result кидає AggregateException, якщо саме асинхронне читання stderr впало
        # (рев'ю B3, Important 5) — це замінило б справжню причину збою (той виняток, що й привів
        # нас у цей finally) чужою. Той самий клас дефекту, що вже правили в коміті c6743a8
        # («finally без throw»). Тому читаємо безпечно, не даючи finally кинути власний виняток.
        try { $stderr = $errTask.Result } catch { $stderr = '' }
        $proc.Dispose()
    }
    # .NET Process — теж нативний виклик: код виходу перевіряється, як і в кожного git.
    if ($exit -ne 0) { throw "git cat-file --batch завершився з кодом ${exit}: $stderr" }
    $count
}

function Get-KitRelativeFiles {
    <# Відносні шляхи файлів під Root з '/', без службових файлів платформи. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    # Без коми: усі викликачі загортають результат у @(…) — див. F7.
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $full = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File |
        Where-Object { $script:PlatformJunk -notcontains $_.Name } |
        ForEach-Object { $_.FullName.Substring($full.Length).TrimStart('\', '/') -replace '\\', '/' })
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
    # HashSet — IEnumerable, pipeline розгорнув би його в рядки; кома тримає об'єкт цілим (F7).
    # Викликачі беруть результат присвоєнням: $binary = Get-KitBinaryPaths …
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($RelativePaths.Count -eq 0) { return , $set }   # кома навмисно (HashSet, F7)
    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/')
    $records = @($RelativePaths | ForEach-Object { "$prefix/$_" })
    # -z перемикає і ВХІД на NUL-роздільник: подані через конвеєр рядки з \n git читає як ОДИН шлях, і набір
    # завжди порожній (рев'ю B3, доведено пробою). Тому stdin — через Process із NUL між записами; -z лишається,
    # бо без нього відповідь була б екранована за core.quotepath.
    $r = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('-c', 'core.quotepath=false', 'check-attr', '-z', 'binary', '--stdin') -StdinRecords $records
    if ($r.ExitCode -ne 0) { throw "git check-attr завершився з кодом $($r.ExitCode): $($r.Stderr)" }
    $fields = @($r.Stdout -split "`0")
    # трійки: <шлях> \0 binary \0 <значення> \0
    for ($i = 0; $i + 2 -lt $fields.Count; $i += 3) {
        if ($fields[$i + 2] -eq 'set') { $set.Add($fields[$i].Substring($prefix.Length).TrimStart('/')) | Out-Null }
    }
    , $set   # кома навмисно: HashSet не має розгортатись pipeline; викликач бере присвоєнням (F7)
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
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$BinaryPaths
    )

    # Ordinal, не IgnoreCase: git регістрочутливий, і Ordinal — саме та семантика порівняння шляхів,
    # яку він використовує. УВАГА (рев'ю B3, пом'якшено): це НЕ універсальна гарантія проти колізії
    # двох шляхів, що різняться лише регістром, — якщо Export-KitTree писав дерево на файлову
    # систему, нечутливу до регістру (NTFS), такі два шляхи зіллються в один файл раніше, ще на
    # етапі експорту, і жодне порівняння тут цього вже не побачить. Ordinal лишається правильним
    # вибором незалежно: детермінований, не залежить від локалі машини (Sort-Object дав би
    # 'content' < 'Ext' і кирилицю першою).
    $dump = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $DumpDir), [System.StringComparer]::Ordinal)
    $tree = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-KitRelativeFiles -Root $TreeDir), [System.StringComparer]::Ordinal)
    $all = [System.Collections.Generic.HashSet[string]]::new($dump, [System.StringComparer]::Ordinal)
    $all.UnionWith($tree)

    $equal = 0
    $crOnly = [System.Collections.Generic.List[string]]::new()
    $content = [System.Collections.Generic.List[string]]::new()
    $onlyDump = [System.Collections.Generic.List[string]]::new()
    $onlyTree = [System.Collections.Generic.List[string]]::new()

    # Сортування — тим самим Ordinal, що й вище (детермінований порядок незалежно від локалі машини).
    $ordered = [System.Linq.Enumerable]::OrderBy([string[]]$all, [Func[string, string]] { param($x) $x }, [System.StringComparer]::Ordinal)
    foreach ($rel in $ordered) {
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

    [pscustomobject]@{
        Equal      = $equal
        CrOnly     = $crOnly.ToArray()
        Content    = $content.ToArray()
        OnlyInDump = $onlyDump.ToArray()
        OnlyInTree = $onlyTree.ToArray()
        Total      = $all.Count
    }
}

Export-ModuleMember -Function Invoke-KitGitProcess, Export-KitTree, Get-KitRelativeFiles, Get-KitBinaryPaths, Compare-KitTrees
