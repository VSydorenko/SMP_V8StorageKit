#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в решті lib-модулів: не перезавантажувати вже наявний
# глобальний PathSafety і не ховати його експорти від глобальної області.
Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Get-KitDirtyRecords {
    <#
    .SYNOPSIS
        git status --porcelain -z -uall для дерева одного джерела, розібраний на записи:
        один запис — одна логічна зміна (M/D/??/R/C тощо), а не один NUL-токен.
    .DESCRIPTION
        Приватна (не експортована) — спільна для двох застосувань усередині викликача:
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
    # єдиний викликач (викликач) сам загортає в @(...).
    $records.ToArray()
}

function Backup-KitDirtyFiles {
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

        Для запису R/C (Get-KitDirtyRecords) копіюється КОЖЕН із двох шляхів, який
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

Export-ModuleMember -Function Get-KitDirtyRecords, Backup-KitDirtyFiles
