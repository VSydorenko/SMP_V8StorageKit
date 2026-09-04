#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Preflight.psm1"
Import-Module "$PSScriptRoot/PathSafety.psm1"

$script:BranchPrefix = 'storage/'

function Get-KitStorageBranchName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceKey)
    "$script:BranchPrefix$SourceKey"
}

function Test-KitBranchExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)
    git -C $RepoRoot rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

function Get-KitBranchCommits {
    <#
    .SYNOPSIS
        Коміти ref-а від кореня до вершини: Sha, Parents, Trailers — одним викликом git log.
    .DESCRIPTION
        Формат: запис на коміт через \x1e, поля через \x1f, трейлери — блок рядків
        «Ключ: значення» (%(trailers:only,unfold)). Розбирається тут, а не по одному
        interpret-trailers на коміт: на сотнях версій це різниця між секундою й хвилиною.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Ref)

    $raw = git -C $RepoRoot log --reverse --format='%x1e%H%x1f%P%x1f%(trailers:only,unfold)' $Ref 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git log $Ref завершився з кодом ${LASTEXITCODE}: $($raw -join "`n")" }

    $text    = (@($raw) -join "`n")
    $records = @($text -split [char]0x1e | Where-Object { $_.Trim() })
    $result  = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $records) {
        $parts    = $rec -split [char]0x1f, 3
        $trailers = [ordered]@{}
        if ($parts.Count -ge 3) {
            foreach ($line in ($parts[2] -split "`r?`n")) {
                if ($line -match '^(?<k>[A-Za-z][A-Za-z0-9-]*):\s*(?<v>.*)$') { $trailers[$Matches.k] = $Matches.v.Trim() }
            }
        }
        $parents = @()
        if ($parts.Count -ge 2 -and $parts[1].Trim()) { $parents = @($parts[1].Trim() -split '\s+') }
        $result.Add([pscustomobject]@{ Sha = $parts[0].Trim(); Parents = $parents; Trailers = $trailers })
    }
    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $result.ToArray()
}

function Get-KitStorageBranchLastVersion {
    <#
    .SYNOPSIS
        «Остання залита версія» джерела — трейлер Storage-Version: вершини storage/<ключ>.
        Гілки немає → $null (реплеїти всі версії зі звіту). Вершина без трейлера → зупинка:
        гілку писав не sync, вгадувати стан не можна.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)

    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return $null }
    $raw = git -C $RepoRoot log -1 --format='%(trailers:key=Storage-Version,valueonly)' $Branch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git log $Branch завершився з кодом ${LASTEXITCODE}: $($raw -join "`n")" }
    $value = (@($raw) -join "`n").Trim()
    if ($value -notmatch '^\d+$') {
        throw "Вершина гілки $Branch не має числового трейлера Storage-Version: — гілку писав не sync. Розбір: kit check."
    }
    [int]$value
}

function Test-KitStorageBranchInvariants {
    <#
    .SYNOPSIS
        Інваріанти гілки дзеркала (спека §3.2): кожен коміт має Storage-Version і
        Storage-Source = ключ; версії строго зростають; батьків не більше одного (корінь —
        нуль); дерево лише під RepoPath. Повертає знахідки; порожньо — усе гаразд.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][string]$RepoPath
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    # Без coma-wrap (`, @()`): викликачі загортають результат у @(...), і кома тут дала б
    # один елемент (порожній вкладений масив) замість справжніх нуля елементів.
    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return @() }

    $prev = $null
    foreach ($c in (Get-KitBranchCommits -RepoRoot $RepoRoot -Ref $Branch)) {
        $short = $c.Sha.Substring(0, 7)
        if ($c.Parents.Count -gt 1) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: коміт $short має $($c.Parents.Count) батьків — merge-коміт на гілці сховища. " +
                'Гілки storage/* лише дописує sync; зливають ЇХ у main/F, а не навпаки.')))
        }
        if (-not $c.Trailers.Contains('Storage-Source')) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message "$Branch`: коміт $short без трейлера Storage-Source:."))
        } elseif ($c.Trailers['Storage-Source'] -ne $SourceKey) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: коміт $short має Storage-Source: '$($c.Trailers['Storage-Source'])', а гілка належить джерелу '$SourceKey'.")))
        }
        if (-not $c.Trailers.Contains('Storage-Version') -or $c.Trailers['Storage-Version'] -notmatch '^\d+$') {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message "$Branch`: коміт $short без числового трейлера Storage-Version:."))
            continue
        }
        $v = [int]$c.Trailers['Storage-Version']
        if ($null -ne $prev -and $v -le $prev) {
            $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
                "$Branch`: версії не зростають строго — після $prev іде $v (коміт $short).")))
        }
        $prev = $v
    }

    $prefix = ($RepoPath -replace '\\', '/').TrimEnd('/') + '/'
    $tree = git -C $RepoRoot ls-tree -r --name-only $Branch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree $Branch завершився з кодом ${LASTEXITCODE}: $($tree -join "`n")" }
    $stray = @($tree | Where-Object { $_ -and -not $_.StartsWith($prefix) })
    foreach ($s in $stray) {
        $findings.Add((New-KitFinding -Level error -Check 'storage-branch' -Message (
            "$Branch`: у дереві файл поза шляхом джерела '$RepoPath': $s.")))
    }

    # Без coma-wrap (`, $x`): усі виклики цієї функції загортають результат у @(...),
    # а @() поверх coma-wrap бачить один елемент — вкладений масив, не його вміст.
    # Пор. StorageReport.psm1:98, де кома доречна: там результат присвоюють без @().
    $findings.ToArray()
}

function Get-KitPendingVersions {
    <#
    .SYNOPSIS
        Версії зі звіту, які ще не в дзеркалі: перелік із версіями > LastVersion (§3.2), не діапазон.
    .DESCRIPTION
        $null у LastVersion — гілки ще немає: реплеїти все. Два запобіжники успадковані від
        Get-PendingVersions (SyncState.psm1, вилучається): дзеркало попереду максимуму звіту, і
        порожній звіт при непорожньому дзеркалі — обидва зупинка, розбір за людиною.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllVersions,
        [Parameter(Mandatory)][AllowNull()][Nullable[int]]$LastVersion,
        [int]$MaxVersions = 0
    )

    $max = $null
    if ($AllVersions.Count -gt 0) { $max = ($AllVersions | Measure-Object -Property Version -Maximum).Maximum }

    if ($null -ne $LastVersion) {
        if ($AllVersions.Count -eq 0) {
            throw ("Звіт сховища порожній (жодної версії), а дзеркало вже тримає версію $LastVersion. Порожній звіт не " +
                   'підтверджує це — сховище могло стати недоступним чи звіт пошкодженим. Синхронізацію зупинено.')
        }
        if ($LastVersion -gt $max) {
            throw ("Дзеркало попереду сховища: у storage/* версія $LastVersion, а у сховищі максимум $max. " +
                   'Синхронізацію зупинено, розберіться з розбіжністю вручну.')
        }
    }

    $pending = @($AllVersions | Where-Object { $null -eq $LastVersion -or $_.Version -gt $LastVersion } | Sort-Object Version)
    if ($MaxVersions -gt 0) { $pending = @($pending | Select-Object -First $MaxVersions) }
    # Кома навмисно: викликачі (sync, тести) беруть результат присвоєнням або (…), НЕ @(…) — див. F7.
    , $pending
}

function Get-KitVersionGapNote {
    <#
    .SYNOPSIS
        Інформаційний рядок, коли мінімум серед нових версій > остання + 1 — сховище оптимізували
        до того, як ми забрали проміжні (§3.2). Не помилка.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pending,
        [Parameter(Mandatory)][AllowNull()][Nullable[int]]$LastVersion
    )
    if ($null -eq $LastVersion -or $Pending.Count -eq 0) { return $null }
    $min = ($Pending | Measure-Object -Property Version -Minimum).Minimum
    if ($min -gt $LastVersion + 1) {
        return "У звіті найменша нова версія $min, а дзеркало на $LastVersion — проміжних версій у сховищі вже немає (оптимізовано)."
    }
    $null
}

function New-KitStorageCommitMessage {
    <#
    .SYNOPSIS
        Повідомлення коміту версії сховища: коментар версії + трейлери (§3.1).
        Storage-User — сирий рядок зі звіту, окремо від git-автора (docs/storage-and-git.md, «Три трейлери»).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Version,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][ValidateSet('CONFIGURATION', 'EXTENSION')][string]$SourceType
    )

    $lines   = @(([string]$Version.Comment) -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $subject = ($lines | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $subject) { $subject = "Версія сховища $($Version.Version)" }
    $body = @($lines | Select-Object -Skip ([array]::IndexOf($lines, $subject) + 1))

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($subject)
    if ($body.Count -gt 0 -and ($body -join '').Trim()) {
        $out.Add('')
        foreach ($b in $body) { $out.Add($b) }
    }
    $out.Add('')
    $out.Add("Storage-Source: $SourceKey")
    $out.Add("Storage-Version: $($Version.Version)")
    if ($Version.ConfigVersion) {
        $key = if ($SourceType -eq 'EXTENSION') { 'Extension-Version' } else { 'Config-Version' }
        $out.Add("${key}: $($Version.ConfigVersion)")
    }
    $out.Add("Storage-User: $($Version.User)")
    $out -join "`n"
}

function New-KitStorageWorktree {
    <#
    .SYNOPSIS
        Worktree гілки дзеркала під build/sync: orphan, якщо гілки ще немає (§3.3, шар 1).
    .DESCRIPTION
        Робоча копія й поточна гілка людини не торкаються взагалі — тому запобіжник «чиста
        робоча копія перед -Apply» зі старого storage-sync.ps1 тут не потрібен. Залишок
        перерваного прогону (тека є, worktree зареєстрований) прибирається: у ньому немає
        нічого, чого не можна перевивантажити.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-SafeWorkPath -Path $Path -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'worktree гілки дзеркала'

    if (Test-Path -LiteralPath $Path) {
        git -C $RepoRoot worktree remove --force $Path 2>$null | Out-Null
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    }
    git -C $RepoRoot worktree prune 2>$null | Out-Null

    $exists = Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch
    if ($exists) {
        $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
        if ($current -eq $Branch) {
            throw "Гілка $Branch вибрана в основній робочій копії — kit пише в неї лише через worktree. Перейдіть на головну гілку чи гілку задачі й повторіть."
        }
        $out = git -C $RepoRoot worktree add -q $Path $Branch 2>&1
    } else {
        $out = git -C $RepoRoot worktree add -q --orphan -b $Branch $Path 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "git worktree add для $Branch завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }

    [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Branch = $Branch; Created = (-not $exists) }
}

function Remove-KitStorageWorktree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Path)
    $out = git -C $RepoRoot worktree remove --force $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git worktree remove $Path завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
    git -C $RepoRoot worktree prune 2>$null | Out-Null
}

function Clear-KitWorktreeSource {
    <#
    .SYNOPSIS
        Порожня тека <wt>/<RepoPath> під дамп версії: /DumpConfigToFiles не видаляє зниклих об'єктів.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorktreePath, [Parameter(Mandatory)][string]$RepoPath)
    $target = Join-Path $WorktreePath $RepoPath
    Assert-SafeWorkPath -Path $target -MustBeUnder $WorktreePath -Description 'тека джерела у worktree'
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    (Resolve-Path -LiteralPath $target).Path
}

function Write-KitStorageVersion {
    <#
    .SYNOPSIS
        Коміт уже вивантаженого дерева <wt>/<RepoPath> як однієї версії сховища.
    .DESCRIPTION
        У worktree гілки дзеркала немає .gitattributes (дерево — лише шлях джерела), тож git
        застосував би core.autocrlf машини. -c core.autocrlf=false тримає байти платформи як є —
        та сама гарантія, яку в main дає -text. ConfigDumpInfo.xml і DumpFilesIndex.txt —
        службові файли платформи, у дзеркалі їх немає (у споживача вони й так у .gitignore).
        V8KIT_SYNC=1 — контракт §3.3 (дозвіл для хука B1), не механізм: в orphan-worktree дзеркала хука
        немає (у дереві немає .githooks), але змінна виставляється завжди, щоб коміт був законним і там,
        де хук є. Дати автора й
        комітера — дата версії сховища. --allow-empty: сусідні версії можуть дати однаковий дамп,
        а коміт — єдиний носій автора, дати й коментаря версії.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$AuthorName,
        [Parameter(Mandatory)][string]$AuthorEmail,
        [Parameter(Mandatory)][datetime]$Timestamp
    )

    $target = Join-Path $WorktreePath $RepoPath
    foreach ($junk in 'ConfigDumpInfo.xml', 'DumpFilesIndex.txt') {
        $j = Join-Path $target $junk
        if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force }
    }

    # commit-message.txt лежить поруч із worktree (Split-Path -Parent $WorktreePath), не
    # всередині нього — `git worktree remove` чистить лише сам worktree, тож файл прибирає
    # цей finally; інакше він лишається як сироту в основному дереві репозиторію ($repo/build/…)
    # і git status --porcelain там бачить "?? build/".
    $msgFile = Join-Path (Split-Path -Parent $WorktreePath) 'commit-message.txt'
    Set-Content -LiteralPath $msgFile -Value $Message -Encoding UTF8 -NoNewline

    try {
        $addOut = git -C $WorktreePath -c core.autocrlf=false -c core.safecrlf=false add -A -- $RepoPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git add у worktree завершився з кодом ${LASTEXITCODE}: $($addOut -join "`n")" }

        git -C $WorktreePath diff --cached --quiet -- $RepoPath
        $empty = ($LASTEXITCODE -eq 0)

        $stamp = $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
        $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp; $env:V8KIT_SYNC = '1'
        try {
            $out = git -C $WorktreePath -c core.autocrlf=false commit --author="$AuthorName <$AuthorEmail>" -F $msgFile --quiet --allow-empty 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git commit у worktree завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
        } finally {
            Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE, Env:V8KIT_SYNC -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Sha = (Get-KitCommitSha -RepoRoot $WorktreePath -Ref HEAD); Empty = $empty }
}

function Get-KitCommitSha {
    <# rev-parse з перевіркою коду виходу — правило Global Constraints без винятків, навіть одразу після успішного коміту. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Ref)
    $out = git -C $RepoRoot rev-parse --verify "$Ref^{commit}" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse $Ref у $RepoRoot завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
    (@($out) -join '').Trim()
}

Export-ModuleMember -Function Get-KitStorageBranchName, Test-KitBranchExists, Get-KitBranchCommits, Get-KitStorageBranchLastVersion, Test-KitStorageBranchInvariants, Get-KitPendingVersions, Get-KitVersionGapNote, New-KitStorageCommitMessage, New-KitStorageWorktree, Remove-KitStorageWorktree, Clear-KitWorktreeSource, Write-KitStorageVersion, Get-KitCommitSha
