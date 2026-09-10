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

    # 2>$null, не 2>&1: $current нижче читається як ім'я гілки (і в булевій перевірці, і в
    # тексті зупинки нижче) — попередження git на stderr при коді виходу 0 (наприклад
    # safe.directory) інакше потрапило б у це ім'я. Той самий принцип, що й у $dirty нижче
    # (уже 2>$null, B2) і в StorageBranch.psm1:270 (той самий рядок, той самий фікс).
    $current = (git -C $RepoRoot branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git branch --show-current у $RepoRoot завершився з кодом ${LASTEXITCODE}." }
    if ($current -eq $Into) {
        # -c core.quotepath=false: без цього git status квотує non-ASCII шляхи (\320\221...)
        # у списку брудних файлів нижче — той самий дефект, що StorageBranch.psm1:
        # kit форсує прапорець за виклик, а не покладається на налаштування репозиторію.
        # 2>$null, не 2>&1: $dirty нижче читається як перелік брудних ШЛЯХІВ (і в булевій
        # перевірці, і в тексті зупинки) — попередження git на stderr при коді виходу 0
        # (наприклад про safe.directory чи локаль) інакше потрапило б у цей перелік як
        # нібито незакомічений шлях.
        $dirty = git -c core.quotepath=false -C $RepoRoot status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git status завершився з кодом ${LASTEXITCODE}." }
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
            # Аборт теж перевіряємо кодом виходу: без цього повідомлення нижче стверджувало б
            # «стан відкочено», навіть якщо сам git merge --abort не впорався — а це вже
            # твердження про стан репозиторію, якого код не перевірив.
            $abortOut = git -C $RepoRoot merge --abort 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), і відкіт (git merge --abort) ТЕЖ не " +
                       "вдався (код ${LASTEXITCODE}: $($abortOut -join "`n")) — репозиторій лишається в незавершеному " +
                       "стані злиття, розберіться вручну: git status`n$($out -join "`n")")
            }
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        return [pscustomobject]@{ Outcome = 'merged'; Sha = (Get-KitCommitSha -RepoRoot $RepoRoot -Ref $Into); Via = 'in-place' }
    }

    Assert-SafeWorkPath -Path $WorkDir -MustBeUnder (Join-Path $RepoRoot 'build/sync') -Description 'worktree головної гілки'
    if (Test-Path -LiteralPath $WorkDir) {
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "git worktree remove '$WorkDir' (прибирання залишку) завершився кодом ${LASTEXITCODE} — прибираю теку напряму." }
        if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    }
    git -C $RepoRoot worktree prune 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "git worktree prune (прибирання залишку) завершився кодом ${LASTEXITCODE} — застарілі реєстрації worktree могли не прибратись." }
    $add = git -C $RepoRoot worktree add -q $WorkDir $Into 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Не вдалося створити worktree для '$Into' (вибрана в іншому worktree?): $($add -join "`n")" }

    try {
        $out = git -C $WorkDir @mergeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Той самий запобіжник, що у гілці in-place вище: аборт перевіряємо кодом виходу,
            # інакше повідомлення стверджувало б відкіт, якого могло й не відбутись.
            $abortOut = git -C $WorkDir merge --abort 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), і відкіт (git merge --abort) ТЕЖ не " +
                       "вдався (код ${LASTEXITCODE}: $($abortOut -join "`n")) — worktree '$WorkDir' лишається в незавершеному " +
                       "стані злиття, розберіться вручну: git -C $WorkDir status`n$($out -join "`n")")
            }
            throw ("Злиття $Branch → $Into не вдалося (конфлікт або помилка git), стан відкочено. Розв'яжіть вручну: " +
                   "git merge $Branch`n$($out -join "`n")")
        }
        $sha = Get-KitCommitSha -RepoRoot $WorkDir -Ref HEAD
    } finally {
        # Симетрично до прибирання залишку перед створенням (вище і в New-KitStorageWorktree):
        # --force теж може не впоратись (заблокований файл — антивірус, індексатор на Windows),
        # тож перевіряємо Test-Path і, якщо тека все ще на місці, попереджаємо, а не мовчимо —
        # без цього виклик повернув би Outcome='merged' без жодного сліду незібраного worktree.
        # Обидва виклики нижче лишаються без throw навмисно (Blocker 1, StorageBranch.psm1
        # Remove-KitStorageWorktree): виняток із finally замінив би собою той, що вже в польоті.
        git -C $RepoRoot worktree remove --force $WorkDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "git worktree remove '$WorkDir' завершився кодом ${LASTEXITCODE} — перевіряю теку напряму." }
        if (Test-Path -LiteralPath $WorkDir) {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $WorkDir) {
                Write-Warning "Не вдалося прибрати тимчасовий worktree '$WorkDir' — приберіть вручну (git worktree remove --force) перед наступним злиттям."
            }
        }
        git -C $RepoRoot worktree prune 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "git worktree prune завершився кодом ${LASTEXITCODE} — застарілі реєстрації worktree могли не прибратись." }
    }
    [pscustomobject]@{ Outcome = 'merged'; Sha = $sha; Via = 'worktree' }
}

Export-ModuleMember -Function Test-KitBranchMergedInto, Merge-KitBranchInto
