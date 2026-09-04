#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"
Import-Module "$PSScriptRoot/StorageBranch.psm1"

function Test-KitBranchMergedInto {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch, [Parameter(Mandatory)][string]$Into)
    git -C $RepoRoot merge-base --is-ancestor $Branch $Into 2>$null
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw "git merge-base --is-ancestor $Branch $Into завершився з кодом $LASTEXITCODE." }
    }
}

function Merge-KitBranchInto {
    <#
    .SYNOPSIS
        Зливає гілку дзеркала в головну (спека §3.4, рішення Q4).
    .DESCRIPTION
        Три випадки: HEAD = Into і чисто — на місці; HEAD = Into і брудно — зупинка (у брудний
        main не зливаємо); HEAD — інша гілка — тимчасовий worktree під build/sync/_main. Завжди
        --no-ff: main ніколи не є предком storage/X, але fast-forward тут перетворив би main
        на дзеркало, і краще, щоб git це навіть не розглядав. Конфлікт — abort і зупинка з
        командою для ручного розбору; стан гілки не змінюється.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Into,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllowUnrelated,
        [string]$WorkDir = (Join-Path $RepoRoot 'build/sync/_main/wt')
    )

    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Into)) {
        throw "Гілки '$Into' немає — нема куди зливати $Branch. Створіть перший коміт у головній гілці (скіл onboarding робить це першим)."
    }
    if (Test-KitBranchMergedInto -RepoRoot $RepoRoot -Branch $Branch -Into $Into) {
        return [pscustomobject]@{ Outcome = 'already'; Sha = (Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into); Via = 'none' }
    }

    $mergeArgs = @('merge', '--no-ff', '--no-edit', '-m', $Message)
    if ($AllowUnrelated) { $mergeArgs += '--allow-unrelated-histories' }
    $mergeArgs += $Branch

    $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
    if ($current -eq $Into) {
        $dirty = git -C $RepoRoot status --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git status завершився з кодом ${LASTEXITCODE}: $dirty" }
        if ($dirty) {
            # Повідомлення зупинки має бути діагностовним само по собі (той самий принцип, що
            # ASCII-якір у решті блоку) — раніше воно називало лише ФАКТ "не чиста", і розбір
            # причини (яка саме тека забруднена) вимагав окремого git status руками. Перелік —
            # до п'яти шляхів; решта — рахунком, не текстом.
            $lines = @($dirty)
            $shown = @($lines | Select-Object -First 5)
            $more  = $lines.Count - $shown.Count
            $detail = ($shown -join "`n") + $(if ($more -gt 0) { "`n…і ще $more" } else { '' })
            throw ("Гілка '$Into' вибрана, але робоча копія не чиста — у брудний '$Into' не зливаємо. Незакомічені шляхи:`n$detail`n" +
                   "Закомітьте або сховайте зміни (git stash) і повторіть, або перейдіть на гілку задачі — тоді злиття піде через тимчасовий worktree.")
        }
        $out = git -C $RepoRoot @mergeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $RepoRoot merge --abort 2>$null | Out-Null
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        return [pscustomobject]@{ Outcome = 'merged'; Sha = (Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into); Via = 'in-place' }
    }

    Assert-SafeWorkPath -Path $WorkDir -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'worktree головної гілки'
    if (Test-Path -LiteralPath $WorkDir) {
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    }
    git -C $RepoRoot worktree prune 2>$null | Out-Null
    $add = git -C $RepoRoot worktree add -q $WorkDir $Into 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Не вдалося створити worktree для '$Into' (вибрана в іншому worktree?): $($add -join "`n")" }

    try {
        $out = git -C $WorkDir @mergeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $WorkDir merge --abort 2>$null | Out-Null
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        $sha = Get-KitCommitSha -RepoRoot $WorkDir -Ref HEAD
    } finally {
        # Симетрично до прибирання залишку перед створенням (вище і в New-KitStorageWorktree):
        # --force теж може не впоратись (заблокований файл — антивірус, індексатор на Windows),
        # тож перевіряємо Test-Path і, якщо тека все ще на місці, попереджаємо, а не мовчимо —
        # без цього виклик повернув би Outcome='merged' без жодного сліду незібраного worktree.
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        if (Test-Path -LiteralPath $WorkDir) {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $WorkDir) {
                Write-Warning "Не вдалося прибрати тимчасовий worktree '$WorkDir' — приберіть вручну (git worktree remove --force) перед наступним злиттям."
            }
        }
        git -C $RepoRoot worktree prune 2>$null | Out-Null
    }
    [pscustomobject]@{ Outcome = 'merged'; Sha = $sha; Via = 'worktree' }
}

Export-ModuleMember -Function Test-KitBranchMergedInto, Merge-KitBranchInto
