#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

# Поставка вендора основної конфігурації на підтримці (§5.2, §6.3.1). ЄДИНЕ
# оголошення шляху: sync, verify, adopt, supply-marker, check і provision беруть його звідси. Шлях —
# відносно кореня дерева CONFIGURATION. У теці лежить <Ім'я>.cf поставки (0,5–1,1 ГБ — за межею
# 100 МБ на файл GitHub, тому поза git) і позначка .kit-bin-sha1 (стан машини, §5.1).
# Ext/ParentConfigurations.bin — ознаки підтримки (замки об'єктів) — ЛИШАЄТЬСЯ в git.
$script:SupplyRelativePath = 'Ext/ParentConfigurations'
$script:SupplyBinRelativePath = 'Ext/ParentConfigurations.bin'
$script:SupplyMarkerName = '.kit-bin-sha1'
# «.bin описує поставку» = файл більший за 16 байт (§6.3.2): у знятих з підтримки конфігураціях
# файл рівно 16 байт — {6,0,0,0,1,0} з BOM. Ім'я .cf усередині .bin не розбираємо: формат не наш.
$script:SupplyEmptyBinBytes = 16

function Get-KitSupplyRelativePath { $script:SupplyRelativePath }

function Test-KitSupplyRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath)
    $rel = ($RelativePath -replace '\\', '/').TrimStart('/')
    # OrdinalIgnoreCase: NTFS і git з core.ignorecase=true на Windows не розрізняють регістр
    # цього шляху, і правило ігнору в .gitignore спрацює на будь-якому регістрі.
    $rel.Equals($script:SupplyRelativePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $rel.StartsWith("$script:SupplyRelativePath/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-KitSupplyDescribed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    $bin = Join-Path $TreeRoot $script:SupplyBinRelativePath
    (Test-Path -LiteralPath $bin -PathType Leaf) -and ((Get-Item -LiteralPath $bin).Length -gt $script:SupplyEmptyBinBytes)
}

function Get-KitSupplyBinSha1 {
    param([Parameter(Mandatory)][string]$TreeRoot)
    (Get-FileHash -LiteralPath (Join-Path $TreeRoot $script:SupplyBinRelativePath) -Algorithm SHA1).Hash.ToLowerInvariant()
}

function Get-KitSupplyState {
    <#
    .SYNOPSIS
        Стан поставки на цій машині (спека §5.2): none — .bin поставки не описує, правило не
        діє; current — позначка = SHA-1 поточного .bin; stale — позначка ≠ SHA-1; missing — .bin
        описує поставку, а .cf чи позначки немає.
    .DESCRIPTION
        Хибна тривога stale можлива й прийнята свідомо (§5.2): .bin змінюється й тоді, коли
        людина лише перевела об'єкт у редаговані. Перевідновити дешевше, ніж пропустити пару
        «новий .bin + старий .cf», яку платформа завантажить без відмови.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    if (-not (Test-KitSupplyDescribed -TreeRoot $TreeRoot)) { return 'none' }
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    $cf = @(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue)
    $marker = Join-Path $dir $script:SupplyMarkerName
    if ($cf.Count -eq 0 -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) { return 'missing' }
    $recorded = ([System.IO.File]::ReadAllText($marker)).Trim()
    if ($recorded -eq (Get-KitSupplyBinSha1 -TreeRoot $TreeRoot)) { 'current' } else { 'stale' }
}

function Write-KitSupplyMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot)
    if (-not (Test-KitSupplyDescribed -TreeRoot $TreeRoot)) { return $null }
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    if (@(Get-ChildItem -LiteralPath $dir -Filter '*.cf' -File -ErrorAction SilentlyContinue).Count -eq 0) { return $null }
    $sha = Get-KitSupplyBinSha1 -TreeRoot $TreeRoot
    # Без BOM і без переводу рядка: читається порівнянням рядків, а не редактором.
    [System.IO.File]::WriteAllText((Join-Path $dir $script:SupplyMarkerName), $sha)
    $sha
}

function Remove-KitSupplyDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder, [Parameter(Mandatory)][string]$RepoRoot, [string]$OwnedRoot)
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Assert-SafeWorkPath -Path $dir -MustBeUnder $MustBeUnder -RepoRoot $RepoRoot -OwnedRoot $OwnedRoot -Description 'тека поставки вендора'
    Remove-KitDirectory -Path $dir
}

function Clear-KitTreeExceptSupply {
    <#
    .SYNOPSIS
        Стирає вміст дерева джерела, крім теки поставки (adopt, спека §5.2): у дзеркалі .cf
        немає, і повне стирання лишило б .bin без .cf — наступне повне завантаження впало б
        (спайк §4.2, варіант B).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder, [Parameter(Mandatory)][string]$RepoRoot, [string]$OwnedRoot)
    Assert-SafeWorkPath -Path $TreeRoot -MustBeUnder $MustBeUnder -RepoRoot $RepoRoot -OwnedRoot $OwnedRoot -Description 'дерево джерела'
    if (-not (Test-Path -LiteralPath $TreeRoot)) { New-Item -ItemType Directory -Path $TreeRoot -Force | Out-Null; return }
    $parts = $script:SupplyRelativePath -split '/'   # 'Ext', 'ParentConfigurations'
    foreach ($item in @(Get-ChildItem -LiteralPath $TreeRoot -Force)) {
        if ($item.PSIsContainer -and $item.Name -ieq $parts[0]) {
            # Останній рубіж «нічого крізь посилання»: у теку Ext функція ЗАХОДИТЬ (її не видаляють цілою), тож посилання на ній
            # повело б видалення дітей у ціль. Guard вище бачить лише TreeRoot.
            if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                throw "дерево джерела: компонент шляху '$($item.Name)' є посиланням (junction чи symlink) — kit нічого не видаляє крізь посилання; приберіть посилання з шляху."
            }
            foreach ($inner in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                if ($inner.PSIsContainer -and $inner.Name -ieq $parts[1]) { continue }
                if ($inner.PSIsContainer) { Remove-KitDirectory -Path $inner.FullName } else { Remove-Item -LiteralPath $inner.FullName -Force }
            }
            continue
        }
        if ($item.PSIsContainer) { Remove-KitDirectory -Path $item.FullName } else { Remove-Item -LiteralPath $item.FullName -Force }
    }
}

function Get-KitSupplyRecipe {
    <#
    .SYNOPSIS
        Єдине джерело тексту відновлення поставки вендора: його беруть і check (знахідка supply,
        -Purpose check), і Get-KitAlignStep (Recipe зупинки blocked, -Purpose stop).
    .DESCRIPTION
        Два виміри різняться. Purpose: check лише попереджає й веде до kit verify, а зупинка після
        sync/verify вже має базу агента зі версією сховища, тож веде одразу до повного pull Уніки і
        позначки kit supply-marker (спека 2026-11-19 §4.2 п.9, п.18). OnMainBranch: поставку
        відновлюють лише на головній гілці; на гілці задачі (і на від'єднаному HEAD) рецепт каже
        «спершу поставка на головній гілці» й не несе кроку pull. Після повного pull база, дерево й
        пам'ять Уніки узгоджені, тож push force після позначки не потрібен.
        Крок pull форматується так само, як Format-KitUnicaRun (UnicaStep), але тут окремо: UnicaStep
        імпортує Supply, зворотний імпорт дав би цикл; збіг форми тримає тест.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$MainBranch,
        [Parameter(Mandatory)][ValidateSet('stale', 'missing', 'unknown')][string]$State,
        [Parameter(Mandatory)][ValidateSet('check', 'stop')][string]$Purpose,
        [Parameter(Mandatory)][bool]$OnMainBranch
    )
    $what = switch ($State) {
        'stale'   { 'поставка вендора застаріла: позначка .kit-bin-sha1 не збігається з поточним Ext/ParentConfigurations.bin (оновився реліз вендора або об''єкти переведено в редаговані — друге дає зайве, але безпечне відновлення)' }
        'unknown' { 'стан поставки вендора не обчислено: помилка читання Ext/ParentConfigurations — невідоме трактується як відсутнє' }
        default   { 'поставка вендора відсутня: Ext/ParentConfigurations.bin описує поставку, а .cf чи позначки .kit-bin-sha1 на цій машині немає — повне завантаження в базу впаде' }
    }
    $head = "$what. Відновлення поставки вендора: "
    $onboarding = " У рецепті (i) (новий репозиторій, онбординг на гілці через sync -MergeInto) той самий крок друкує kit sync -Source $SourceKey."
    if (-not $OnMainBranch) {
        return $head + "спершу поставка на головній гілці ${MainBranch}, а не на гілці задачі (HEAD = ${MainBranch}, дерево чисте): " +
            "перейдіть на ${MainBranch} і виконайте там kit verify -Source $SourceKey, далі — надруковане ним; потім поверніться на гілку задачі." + $onboarding
    }
    if ($Purpose -eq 'check') {
        return $head + "на гілці ${MainBranch} (HEAD = ${MainBranch}, дерево чисте), база агента є (інакше v8storagekit:provision): " +
            "kit verify -Source $SourceKey (очікувано equal; verify наповнить базу версією зі сховища — merge-base) → виконати його зупинку поставки." + $onboarding
    }
    $pull = 'unica.run ' + ([ordered]@{ op = 'pull'; args = [ordered]@{ sourceSet = $SourceKey; force = $true }; dryRun = $true } | ConvertTo-Json -Compress -Depth 5)
    $head + "на гілці ${MainBranch} (HEAD = ${MainBranch}, дерево чисте) одразу повний pull цього набору: $pull (спершу так, потім той самий виклик з `"dryRun`":false; " +
        "Уніка спитає людину про перезапис бази origin — це очікувано) → kit supply-marker -Workspace $Workspace -Source $SourceKey -Apply. " +
        "Після повного pull база, дерево й пам'ять Уніки узгоджені — push force не потрібен. Після pull git status --porcelain -- <шлях набору $SourceKey> мусить бути порожнім; " +
        'непорожній — зупинка й доповідь людині. Без обходу.'
}

Export-ModuleMember -Function Get-KitSupplyRelativePath, Test-KitSupplyRelativePath, Test-KitSupplyDescribed, Get-KitSupplyState, Write-KitSupplyMarker, Remove-KitSupplyDir, Clear-KitTreeExceptSupply, Get-KitSupplyRecipe
