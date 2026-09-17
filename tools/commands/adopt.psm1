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
