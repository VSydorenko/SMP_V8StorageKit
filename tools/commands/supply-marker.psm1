#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module ризикував би перезавантаженням (docs/follow-ups.md §5).

function Invoke-KitSupplyMarker {
    <#
    .SYNOPSIS
        Записує позначку поставки вендора .kit-bin-sha1 для набору CONFIGURATION, .cf якого вже поклав
        повний pull Уніки (pull з force:true). Нічого не вивантажує.
    .DESCRIPTION
        Позначку пише її власник — kit — після того, як повний pull поклав .cf: pull стирає каталог набору
        разом з позначкою, тож свіжий pull лишає стан missing (.cf є, позначки немає). Рецепт, що веде сюди,
        друкує Get-KitSupplyRecipe (Supply.psm1): його кличуть check і крок вирівнювання після sync/verify.

        Передумови: набір CONFIGURATION; .bin описує поставку; .cf на місці; дерево набору чисте. Стан
        current — писати нічого; stale — відмова: стара позначка доводить, що .cf цим pull не
        перевивантажувався, і запис освятив би пару «новий .bin + старий .cf». Час зміни файлу тут не
        доказ — git ставить його .bin на кожному checkout. Брудне дерево після pull — запасна гілка: повний
        pull дав інші байти, ніж очікував kit, і позначка засвідчила б стан, якого kit не перевіряв.

        Бази агента команда не потребує й платформи не кличе. Теки набору вона не стирає, тож перевірки
        невидимої роботи тут не потрібно.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [string]$Workspace, [string]$Source, [bool]$Apply)

    if (-not $Source) { throw 'supply-marker потребує -Source <ключ основної конфігурації>: позначка поставки пишеться рівно одному набору.' }
    $src = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)[0]
    if ($src.Type -ne 'CONFIGURATION') {
        throw "supply-marker: '$($src.Key)' — $($src.Type), а позначка поставки буває лише в наборі CONFIGURATION."
    }
    if (-not (Test-KitSupplyDescribed -TreeRoot $src.FullPath)) {
        throw "supply-marker: Ext/ParentConfigurations.bin набору '$($src.Key)' не описує поставку вендора — позначка не потрібна."
    }
    $dir = Join-Path $src.FullPath (Get-KitSupplyRelativePath)
    if (@(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue).Count -eq 0) {
        throw "supply-marker: у $dir немає .cf — позначку нема чим підтвердити. Спершу повний pull цього набору (pull з force:true): його рецепт друкує kit sync чи kit verify на зупинці поставки."
    }
    $state = Get-KitSupplyState -TreeRoot $src.FullPath
    if ($state -eq 'current') {
        Write-Host "  $($src.Key): позначка .kit-bin-sha1 вже відповідає .bin — писати нічого." -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0; Marked = @() }
    }
    if ($state -eq 'stale') {
        throw ("supply-marker: стара позначка .kit-bin-sha1 на місці (не відповідає .bin) — .cf цим pull не перевивантажувався. " +
               "Позначку не записано. Спершу повний pull цього набору (pull з force:true) за рецептом зупинки поставки з kit sync чи kit verify, тоді повторіть.")
    }
    $dirty = @(Get-KitDirtyRecords -RepoRoot $Context.RepoRoot -RepoPath $src.RepoPath)
    if ($dirty.Count -gt 0) {
        throw ("supply-marker: дерево '$($src.RepoPath)' брудне ($($dirty.Count) змін після pull) — вивантаження раннера дало інші байти, " +
               'ніж kit, або в дереві чужа робота. Позначку не записано. Зупинка й доповідь людині: git status -- ' + $src.RepoPath)
    }
    if (-not $Apply) {
        Write-Host "  $($src.Key): буде записано позначку .kit-bin-sha1 без вивантаження. Для виконання додайте -Apply." -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Marked = @() }
    }
    $sha = Write-KitSupplyMarker -TreeRoot $src.FullPath
    Write-Host "  $($src.Key): позначку .kit-bin-sha1 записано ($sha); дерево не переписувалось." -ForegroundColor Green
    [pscustomobject]@{ ExitCode = 0; Marked = @([pscustomobject]@{ Key = $src.Key; SupplyMarker = $sha }) }
}

Export-ModuleMember -Function Invoke-KitSupplyMarker
