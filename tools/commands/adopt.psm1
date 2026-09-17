#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt (docs/follow-ups.md §5).

function Invoke-KitAdopt {
    <#
    .SYNOPSIS
        Гілка задачі приймає версію сховища ЗАМІНОЮ піддерева джерела, не злиттям
        (спека 2026-09-17 §5).
    .DESCRIPTION
        Сховище — істина в останній інстанції, і працює з ним лише людина: вона бере артефакт
        агента, перевіряє його в Конфігураторі, можливо бере ЧАСТИНУ механізмів і кладе у сховище
        свою версію. Тому агент не зливає своє зі сховищним — він замінює своє тим, що у сховищі.
        git merge лишив би в гілці те, що людина свідомо не взяла, і воно поїхало б у наступний
        артефакт.

        Прев'ю (без -Apply) — не формальність, а єдиний момент, коли видно ціну заміни: що прийде
        зі сховища і ЩО ЗНИКНЕ З ГІЛКИ. Друге важливіше: це робота агента, яку людина не взяла.
        Вона не втрачається (лишається в історії гілки до заміни), але рішення без неї
        ухвалювалося б наосліп.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [string]$Ref,
        [bool]$Apply
    )

    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — приймати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Adopted = @() }
    }

    $adopted = [System.Collections.Generic.List[object]]::new()

    foreach ($src in $sources) {
        $mirror = if ($Ref) { $Ref } else { $src.Branch }
        if (-not (Test-KitBranchExists -RepoRoot $root -Branch $mirror)) {
            throw "Гілки '$mirror' немає — дзеркало ще не створено. Спершу: kit sync -Source $($src.Key) -Apply."
        }

        Write-Host ''
        Write-Host "Джерело: $($src.Workspace)/$($src.Key)  ·  приймаємо з: $mirror"

        $workDir = Join-Path $root 'build/adopt' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/adopt') -Description "робоча тека adopt $($src.Key)"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $mirrorDir = Join-Path $workDir 'mirror'
        $null = Export-KitTree -RepoRoot $root -Ref $mirror -RepoPath $src.RepoPath -Destination $mirrorDir

        # TreeDir — РОБОЧА КОПІЯ, не експорт гілки: замінюється саме вона, і незакомічене в ній
        # зникне так само, як закомічене. Показати треба фактичний стан, а не стан HEAD.
        $relSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($rel in (@(Get-KitRelativeFiles -Root $mirrorDir) + @(Get-KitRelativeFiles -Root $src.FullPath))) { $relSet.Add($rel) | Out-Null }
        $binary = Get-KitBinaryPaths -RepoRoot $root -RepoPath $src.RepoPath -RelativePaths ([string[]]$relSet)
        $diff   = Compare-KitTrees -DumpDir $mirrorDir -TreeDir $src.FullPath -BinaryPaths $binary

        $incoming = @($diff.Content) + @($diff.OnlyInDump)
        Write-Host "  Побайтово рівних: $($diff.Equal) із $($diff.Total)"
        Write-KitAdoptList -Title "прийде зі сховища ($mirror)" -Items $incoming
        Write-KitAdoptList -Title 'ЗНИКНЕ з гілки — робота, яку людина у сховище не взяла' -Items $diff.OnlyInTree -Loud

        $adopted.Add([pscustomobject]@{ Key = $src.Key; Mirror = $mirror; Incoming = $incoming.Count; Dropped = $diff.OnlyInTree.Count; Applied = $false })

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Заміна — з -Apply (дерево джерела буде переписане вмістом дзеркала).' -ForegroundColor Cyan
            continue
        }

        if ($incoming.Count -eq 0 -and $diff.OnlyInTree.Count -eq 0) {
            Write-Host '  Дерево уже збігається з дзеркалом — заміняти нічого.' -ForegroundColor DarkGray
            continue
        }

        # Страховка перед знищенням: те саме, що робить canon (спека §5). Копія лягає у
        # гітігноровану build/-теку воркспейсу, тож робочої копії не забруднює.
        $dirty = @(Get-KitDirtyRecords -RepoRoot $root -RepoPath $src.RepoPath)
        if ($dirty.Count -gt 0) {
            $ws = @($Context.Workspaces | Where-Object Path -eq $src.Workspace) | Select-Object -First 1
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir = Join-Path $ws.FullPath (Join-Path $ws.Project.WorkPath (Join-Path 'adopt-backup' "$($src.Key)-$stamp"))
            $null = Backup-KitDirtyFiles -RepoRoot $root -RepoPath $src.RepoPath -Records $dirty -BackupRoot $backupDir -MustBeUnder $ws.FullPath
            Write-Host "  $($dirty.Count) незакомічених змін — копія перед заміною у $backupDir" -ForegroundColor Yellow
        }

        Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $root -Description "дерево джерела $($src.Key)"
        if (Test-Path -LiteralPath $src.FullPath) { Remove-Item -LiteralPath $src.FullPath -Recurse -Force }
        New-Item -ItemType Directory -Path $src.FullPath -Force | Out-Null
        Copy-Item -Path (Join-Path $mirrorDir '*') -Destination $src.FullPath -Recurse -Force

        # -A обов'язковий і саме на ШЛЯХУ джерела: він фіксує і нові файли, і ВИДАЛЕННЯ тих,
        # яких у дзеркалі немає. Обмеження pathspec-ом тримає межу «точковий коміт у спільній
        # робочій копії» — чужі зміни поза цим шляхом не потраплять.
        $add = Invoke-KitGitProcess -RepoRoot $root -Arguments @('add', '-A', '--', $src.RepoPath)
        if ($add.ExitCode -ne 0) { throw "git add для '$($src.RepoPath)' завершився з кодом $($add.ExitCode): $($add.Stderr)" }

        $version = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $mirror
        $message = "adopt: $($src.Key) ← $mirror (версія $version)"
        $commit  = Invoke-KitGitProcess -RepoRoot $root -Arguments @('commit', '--only', '-m', $message, '--', $src.RepoPath)
        if ($commit.ExitCode -ne 0) { throw "Коміт заміни не вдався (код $($commit.ExitCode)): $($commit.Stderr)" }

        Write-Host "  Замінено: прийшло $($incoming.Count), зникло $($diff.OnlyInTree.Count). Коміт: $message" -ForegroundColor Green
        $adopted[-1].Applied = $true
    }

    [pscustomobject]@{ ExitCode = 0; Adopted = $adopted.ToArray() }
}

function Write-KitAdoptList {
    param([string]$Title, [AllowEmptyCollection()][string[]]$Items, [switch]$Loud, [int]$Limit = 20)
    if ($Items.Count -eq 0) { return }
    $color = if ($Loud) { 'Yellow' } else { 'Gray' }
    Write-Host "  $Title ($($Items.Count)):" -ForegroundColor $color
    foreach ($i in ($Items | Select-Object -First $Limit)) { Write-Host "    $i" -ForegroundColor $color }
    if ($Items.Count -gt $Limit) { Write-Host "    … ще $($Items.Count - $Limit)" -ForegroundColor $color }
}

Export-ModuleMember -Function Invoke-KitAdopt
