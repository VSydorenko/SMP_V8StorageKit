#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/session-board + lib/session-board.mjs, modified.
Set-StrictMode -Version Latest

<#
    Статус паралельних сесій для архітектора одним екраном. Джерела — git і gh, не список агентів:
    таблицю може зібрати будь-яка сесія.

    Змін проти оригіналу: колонки CI немає (workflow немає в жодному репо власника), тож колонка PR —
    `#N`, `#N draft`, `#N merged`, `—` (немає PR), `?` (gh не перевірено), а підказка «ready for
    acceptance» зникла. Режим робочої копії береться з профілю (`workspace.mode`): `worktree` — рядки
    є worktree, як в оригіналі; `shared` — робоча копія одна, рядки є гілки (з файлу сесій або всі
    локальні, крім базової і `storage/*`), колонки `path` немає. Параметри PowerShell-стилем.
#>

$script:Usage = @"
session-board [-Sessions <file>] [-Fetch] [-All]

One-screen table of parallel sessions: session, role, branch, HEAD, age of the last commit,
uncommitted files, ahead/behind origin/<base>, PR, next step.

Profile workspace.mode (default "shared"):
  worktree  rows are the repo's worktrees (git worktree list), with the full path column;
            sessions of the file without a worktree are listed too
  shared    one working copy: rows are branches (from -Sessions, otherwise local branches except
            the base and storage/*); the tree column is filled only for the checked-out branch

  -Sessions <file>  JSON { "<session>": "<branch>" | { "branch", "role" } } kept by the architect
  -Fetch            git fetch origin first (otherwise ahead/behind uses the local origin/<base>)
  -All              worktree mode: also show detached worktrees (scratch copies)

Base branch: profile pr.base, default "main".
A merged PR counts for a branch only when the branch has no new work after it.
Exit: 0 table complete; 3 PR not checked (gh missing or failed) or bad profile field — the table
is still printed without PRs.
"@

# ---------- git ----------

function Invoke-SbGit {
    <# stdout git у теці або $null, коли git відмовив. #>
    param([Parameter(Mandatory)][string]$Cwd, [Parameter(Mandatory)][string[]]$GitArgs)
    $out = & git -C $Cwd @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($null -eq $out) { return '' }
    (@($out) -join "`n").Trim()
}

function ConvertFrom-SbWorktrees {
    <# `git worktree list --porcelain` -> [{ Path, Head, Branch, Detached, Prunable }]. #>
    param([AllowEmptyString()][string]$Text)
    $out = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line.StartsWith('worktree ')) {
            $cur = [pscustomobject]@{ Path = $line.Substring(9); Head = ''; Branch = $null; Detached = $false; Prunable = $false }
            $out.Add($cur)
        } elseif ($null -eq $cur) { continue }
        elseif ($line.StartsWith('HEAD ')) { $cur.Head = $line.Substring(5) }
        elseif ($line.StartsWith('branch ')) { $cur.Branch = $line.Substring(7) -replace '^refs/heads/', '' }
        elseif ($line -eq 'detached') { $cur.Detached = $true }
        elseif ($line.StartsWith('prunable')) { $cur.Prunable = $true }
    }
    , $out.ToArray()
}

# ---------- чисті функції таблиці ----------

function Format-SbAge {
    param($Seconds)
    if ($null -eq $Seconds) { return '?' }
    if ($Seconds -lt 3600) { return "$([math]::Max(0, [math]::Round($Seconds / 60, [MidpointRounding]::AwayFromZero)))m" }
    if ($Seconds -lt 86400) { return "$([math]::Round($Seconds / 3600, [MidpointRounding]::AwayFromZero))h" }
    "$([math]::Round($Seconds / 86400, [MidpointRounding]::AwayFromZero))d"
}

function Get-SbNextStep {
    <# Перша підказка, яка вимагає дії архітектора; порожньо — нічого робити. #>
    param($Row, [string]$Base, [string]$Mode)
    if ($Row.Merged) {
        if ($Mode -eq 'worktree' -and $Row.Path) { return "merged #$($Row.Merged): pr-gate cleanup $($Row.Path)" }
        return "merged #$($Row.Merged)"
    }
    if ($Mode -eq 'worktree') {
        if (-not $Row.Path) { return 'no worktree' }
        if ($Row.Prunable) { return 'prunable: git worktree prune' }
    }
    if ($Row.Pr) {
        if ($Row.Unpushed) { return 'local HEAD not pushed' }
        if ($null -ne $Row.Behind -and $Row.Behind -gt 0) { return "behind $Base $($Row.Behind): merge origin/$Base" }
    }
    ''
}

function Format-SbTable {
    <# Рядки -> вирівняна таблиця; ширина колонки — за найдовшим значенням. #>
    param([string[]]$Headers, [object[]]$Rows)
    $w = @(for ($i = 0; $i -lt $Headers.Count; $i++) {
            $m = $Headers[$i].Length
            foreach ($r in $Rows) { $m = [math]::Max($m, ([string]$r[$i]).Length) }
            $m
        })
    $line = { param($cells) (@(for ($i = 0; $i -lt $cells.Count; $i++) { ([string]$cells[$i]).PadRight($w[$i]) }) -join '  ').TrimEnd() }
    (@(& $line $Headers) + @($Rows | ForEach-Object { & $line $_ })) -join "`n"
}

function Read-SbSessions {
    <# Файл сесій -> впорядкований список { Name, Branch, Role }. #>
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw (New-KitUsageError "файл сесій не знайдено: $File") }
    try { $obj = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw (New-KitRefusal "файл сесій не розібрано як JSON: $($_.Exception.Message)") }
    $shape = 'sessions file must be a JSON object { "<session>": "<branch>" | { "branch", "role" } }'
    if ($obj -isnot [pscustomobject]) { throw (New-KitRefusal $shape) }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $obj.PSObject.Properties) {
        $v = $p.Value
        $branch = $null; $role = ''
        if ($v -is [string]) { $branch = $v }
        elseif ($v -is [pscustomobject]) {
            if ($v.PSObject.Properties['branch']) { $branch = $v.branch }
            if ($v.PSObject.Properties['role'] -and $null -ne $v.role) { $role = [string]$v.role }
        }
        if ($branch -isnot [string]) { throw (New-KitRefusal "session `"$($p.Name)`": branch missing") }
        $list.Add([pscustomobject]@{ Name = $p.Name; Branch = $branch; Role = $role })
    }
    $list.ToArray()
}

# ---------- стан гілки / worktree ----------

function Get-SbState {
    <# Вік, ahead/behind проти origin/<base> для ref у теці. Tree — окремо. #>
    param([string]$Cwd, [string]$Ref, [string]$Base)
    $s = @{ AgeSec = $null; Ahead = $null; Behind = $null }
    $ct = Invoke-SbGit -Cwd $Cwd -GitArgs @('log', '-1', '--format=%ct', $Ref)
    if ($ct -match '^\d+$') { $s.AgeSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$ct }
    $counts = Invoke-SbGit -Cwd $Cwd -GitArgs @('rev-list', '--left-right', '--count', "origin/$Base...$Ref")
    if ($counts -match '^(\d+)\s+(\d+)$') { $s.Behind = [int]$Matches[1]; $s.Ahead = [int]$Matches[2] }
    $s
}

function Get-SbTree {
    param([string]$Cwd)
    $st = Invoke-SbGit -Cwd $Cwd -GitArgs @('status', '--porcelain')
    if ($null -eq $st) { return '-' }
    if (-not $st) { return 'clean' }
    "$(@($st -split "\r?\n").Count) changed"
}

function Get-SbPrMap {
    <# branch -> @{ Open; Merged }; відкритий PR важливіший за старий злитий з тією ж назвою гілки. #>
    param([string]$Cwd)
    $open = @(Invoke-KitGh -Arguments @('pr', 'list', '--state', 'open', '--limit', '100', '--json', 'number,headRefName,headRefOid,isDraft') -Json -Cwd $Cwd)
    $merged = @(Invoke-KitGh -Arguments @('pr', 'list', '--state', 'merged', '--limit', '50', '--json', 'number,headRefName,headRefOid') -Json -Cwd $Cwd)
    $map = @{}
    foreach ($p in $merged) { if ($null -ne $p -and -not $map.ContainsKey($p.headRefName)) { $map[$p.headRefName] = @{ Open = $null; Merged = $p } } }
    foreach ($p in $open) { if ($null -ne $p) { $map[$p.headRefName] = @{ Open = $p; Merged = $null } } }
    $map
}

function Invoke-KitSessionBoard {
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{ Sessions = 'string'; Fetch = 'switch'; All = 'switch' }
    if ($a.Help) { Write-KitLine $script:Usage.TrimEnd(); return 0 }
    if ($a.Positional.Count) { throw (New-KitUsageError "зайвий позиційний аргумент '$($a.Positional[0])'") }

    $profile = Get-KitProfile -RepoRoot $RepoRoot
    $base = [string](Get-KitProfileValue -Profile $profile -Path 'pr.base' -Default 'main')
    $mode = [string](Get-KitProfileValue -Profile $profile -Path 'workspace.mode' -Default 'shared')
    if ($mode -notin @('shared', 'worktree')) { throw (New-KitNotChecked "поле профілю `"workspace.mode`": `"$mode`" — допустимо shared або worktree") }

    if ($null -eq (Invoke-SbGit -Cwd $RepoRoot -GitArgs @('rev-parse', '--git-dir'))) { throw (New-KitRefusal "$RepoRoot не є git-репозиторієм") }
    $sessions = @(if ($a.Named.ContainsKey('Sessions')) { Read-SbSessions -File $a.Named['Sessions'] })
    $sessionOf = @{}
    foreach ($s in $sessions) { $sessionOf[$s.Branch] = $s }
    if ($a.Named.ContainsKey('Fetch')) { $null = Invoke-SbGit -Cwd $RepoRoot -GitArgs @('fetch', '-q', 'origin') }

    # --- рядки з локальним станом ---
    $rows = [System.Collections.Generic.List[object]]::new()
    $newRow = { param($b) [ordered]@{ Branch = $b; Path = $null; Head = ''; Detached = $false; Prunable = $false; Tree = '-'; AgeSec = $null; Ahead = $null; Behind = $null } }
    if ($mode -eq 'worktree') {
        $wts = ConvertFrom-SbWorktrees -Text (Invoke-SbGit -Cwd $RepoRoot -GitArgs @('worktree', 'list', '--porcelain'))
        foreach ($w in $wts) {
            if (-not $a.Named.ContainsKey('All') -and -not $w.Branch) { continue }
            $r = & $newRow $w.Branch
            $r.Path = $w.Path; $r.Head = $w.Head; $r.Detached = $w.Detached; $r.Prunable = $w.Prunable
            if (-not $w.Prunable) {
                $r.Tree = Get-SbTree -Cwd $w.Path
                $st = Get-SbState -Cwd $w.Path -Ref 'HEAD' -Base $base
                $r.AgeSec = $st.AgeSec; $r.Ahead = $st.Ahead; $r.Behind = $st.Behind
            }
            $rows.Add($r)
        }
        # Сесії з файлу, для яких worktree вже немає: показати, чим закінчились.
        $seen = @($rows | ForEach-Object { $_.Branch })
        foreach ($s in $sessions) { if ($seen -notcontains $s.Branch) { $rows.Add((& $newRow $s.Branch)) } }
    } else {
        $branches = @(if ($sessions.Count) { @($sessions | ForEach-Object { $_.Branch }) } else {
            $all = Invoke-SbGit -Cwd $RepoRoot -GitArgs @('for-each-ref', '--format=%(refname:short)', 'refs/heads')
            @($all -split "\r?\n" | Where-Object { $_ -and $_ -ne $base -and -not $_.StartsWith('storage/') })
        })
        $current = Invoke-SbGit -Cwd $RepoRoot -GitArgs @('symbolic-ref', '--short', '-q', 'HEAD')
        foreach ($b in $branches) {
            $r = & $newRow $b
            $head = Invoke-SbGit -Cwd $RepoRoot -GitArgs @('rev-parse', '--verify', '-q', "refs/heads/$b")
            if ($head) {
                $r.Head = $head
                $st = Get-SbState -Cwd $RepoRoot -Ref "refs/heads/$b" -Base $base
                $r.AgeSec = $st.AgeSec; $r.Ahead = $st.Ahead; $r.Behind = $st.Behind
                if ($b -eq $current) { $r.Tree = Get-SbTree -Cwd $RepoRoot }
            }
            $rows.Add($r)
        }
    }

    # --- PR ---
    $prs = $null
    $ghProblem = $null
    try { $prs = Get-SbPrMap -Cwd $RepoRoot }
    catch [KitGhUnavailable] { $ghProblem = $_.Exception.Message }
    catch [KitGhError] { $ghProblem = "gh failed: $($_.Exception.Message)" }

    $headers = @('session', 'role', 'branch', 'HEAD', 'age', 'tree', "vs $base", 'PR', 'next') + $(if ($mode -eq 'worktree') { 'path' })
    # @(): один рядок інакше розгортається у плоский масив клітинок, і $c[$_] бере символ рядка.
    $out = @(foreach ($r in $rows) {
        $s = $sessionOf[$r.Branch]
        $p = if ($prs -and $r.Branch -and $prs.ContainsKey($r.Branch)) { $prs[$r.Branch] } else { $null }
        $row = [pscustomobject]@{ Path = $r.Path; Prunable = $r.Prunable; Behind = $r.Behind; Pr = $null; Merged = $null; Unpushed = $false }
        if ($p -and $p.Open) {
            $row.Pr = $p.Open.number
            $row.Unpushed = [bool]$r.Head -and $r.Head -ne $p.Open.headRefOid
        } elseif ($p -and $p.Merged -and $r.Branch -ne $base -and (-not $r.Head -or $r.Head -eq $p.Merged.headRefOid -or $r.Ahead -eq 0)) {
            # Злитий PR зараховується, лише коли в гілці немає нової роботи після нього:
            # інакше це старий PR тієї ж назви гілки.
            $row.Merged = $p.Merged.number
        }
        $prCell = if ($row.Pr) { "#$($row.Pr)$(if ($p.Open.isDraft) { ' draft' })" } elseif ($row.Merged) { "#$($row.Merged) merged" } elseif ($prs) { '—' } else { '?' }
        $cells = @(
            $(if ($s) { $s.Name } else { '-' }),
            $(if ($s) { $s.Role } else { '' }),
            $(if ($r.Detached) { '(detached)' } else { $r.Branch }),
            $(if ($r.Head) { $r.Head.Substring(0, 7) } else { '-' }),
            $(if ($r.Head -and ($mode -eq 'shared' -or $r.Path)) { Format-SbAge $r.AgeSec } else { '-' }),
            $r.Tree,
            $(if ($null -eq $r.Ahead) { '-' } else { "+$($r.Ahead) -$($r.Behind)" }),
            $prCell,
            (Get-SbNextStep -Row $row -Base $base -Mode $mode)
        )
        if ($mode -eq 'worktree') { $cells += $(if ($r.Path) { $r.Path } else { '' }) }
        , $cells
    })

    # Без файлу сесій колонки session/role порожні — не займати ними екран.
    $keep = if ($sessions.Count) { 0..($headers.Count - 1) } else { 2..($headers.Count - 1) }
    $outRows = @(foreach ($c in $out) { , @($keep | ForEach-Object { $c[$_] }) })
    Write-KitLine (Format-SbTable -Headers @($keep | ForEach-Object { $headers[$_] }) -Rows $outRows)
    if ($ghProblem) {
        Write-KitLine "PR not checked: $ghProblem"
        return 3
    }
    Write-KitNext 'session-board -Fetch'
    return 0
}

Export-ModuleMember -Function Invoke-KitSessionBoard
