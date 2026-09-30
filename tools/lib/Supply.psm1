#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/PathSafety.psm1"

# Поставка вендора основної конфігурації на підтримці (спека 2026-09-30 §5.2, §6.3.1). ЄДИНЕ
# оголошення шляху: sync, verify, adopt, canon, check і provision беруть його звідси. Шлях —
# відносно кореня дерева CONFIGURATION. У теці лежить <Ім'я>.cf поставки (0,5–1,1 ГБ — за межею
# 100 МБ на файл GitHub, тому поза git) і позначка .kit-bin-sha1 (стан машини, §5.1).
# Ext/ParentConfigurations.bin — ознаки підтримки (замки об'єктів) — ЛИШАЄТЬСЯ в git.
$script:SupplyRelativePath = 'Ext/ParentConfigurations'
$script:SupplyBinRelativePath = 'Ext/ParentConfigurations.bin'
$script:SupplyMarkerName = '.kit-bin-sha1'
# «.bin описує поставку» = файл більший за 16 байт (спека §6.3.2). Умова виміру: у знятих з
# підтримки конфігураціях (SMP_SMB_ukr_DEV, SMP_SMB_rus_DEV, 2026-09-30) файл рівно 16 байт —
# {6,0,0,0,1,0} з BOM. Ім'я .cf усередині .bin не розбираємо: формат не наш.
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
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder)
    $dir = Join-Path $TreeRoot $script:SupplyRelativePath
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Assert-SafeWorkPath -Path $dir -MustBeUnder $MustBeUnder -Description 'тека поставки вендора'
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Clear-KitTreeExceptSupply {
    <#
    .SYNOPSIS
        Стирає вміст дерева джерела, крім теки поставки (adopt, спека §5.2): у дзеркалі .cf
        немає, і повне стирання лишило б .bin без .cf — наступне повне завантаження впало б
        (спайк §4.2, варіант B).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreeRoot, [Parameter(Mandatory)][string]$MustBeUnder)
    Assert-SafeWorkPath -Path $TreeRoot -MustBeUnder $MustBeUnder -Description 'дерево джерела'
    if (-not (Test-Path -LiteralPath $TreeRoot)) { New-Item -ItemType Directory -Path $TreeRoot -Force | Out-Null; return }
    $parts = $script:SupplyRelativePath -split '/'   # 'Ext', 'ParentConfigurations'
    foreach ($item in @(Get-ChildItem -LiteralPath $TreeRoot -Force)) {
        if ($item.PSIsContainer -and $item.Name -ieq $parts[0]) {
            foreach ($inner in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                if ($inner.PSIsContainer -and $inner.Name -ieq $parts[1]) { continue }
                Remove-Item -LiteralPath $inner.FullName -Recurse -Force
            }
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function Get-KitSupplyRecipe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceKey, [Parameter(Mandatory)][string]$MainBranch, [Parameter(Mandatory)][string]$State)
    $what = if ($State -eq 'stale') {
        'поставка вендора застаріла: позначка .kit-bin-sha1 не збігається з поточним Ext/ParentConfigurations.bin (оновився реліз вендора або об''єкти переведено в редаговані — друге дає зайве, але безпечне відновлення)'
    } else {
        'поставка вендора відсутня: Ext/ParentConfigurations.bin описує поставку, а .cf чи позначки .kit-bin-sha1 на цій машині немає — повне завантаження в базу впаде'
    }
    "$what. Відновлення — лише на гілці ${MainBranch}, не на гілці задачі (canon переписує все дерево): " +
    "база агента є (інакше kit provision) → kit verify -Source $SourceKey (очікувано equal — він наповнює базу версією з дерева) → " +
    "kit canon -Source $SourceKey -Apply (вивантажує .cf і пише позначку) → operation=build Уніки. Ніколи canon на порожній базі: порожній дамп стирає дерево."
}

Export-ModuleMember -Function Get-KitSupplyRelativePath, Test-KitSupplyRelativePath, Test-KitSupplyDescribed, Get-KitSupplyState, Write-KitSupplyMarker, Remove-KitSupplyDir, Clear-KitTreeExceptSupply, Get-KitSupplyRecipe
