#Requires -Version 7
Set-StrictMode -Version Latest

<#
    Прогін за зміною для Run-Tests.ps1 (#88): що змінено від origin/main і чи це код.
    Ідея й класифікатор — agent-kit 0.11 (`bin/run-tests`, `isCode`, `--changed`): зміна лише в
    документах тестів коду не потребує, лише тестів, що читають документи (тег Pester `Docs`).
    Окремо від TestRunner.psm1, бо той навмисно без git і тестується в процесі за мілісекунди.
#>

# Не код (agent-kit 0.11, isCode): зміна лише в таких файлах — не пропуск перевірки коду.
$script:NonCodeExt = @('md', 'mdx', 'markdown', 'txt', 'rst', 'adoc', 'json', 'jsonc', 'yaml', 'yml', 'toml', 'ini', 'lock', 'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'ico', 'pdf')
$script:NonCodeNames = @('LICENSE', 'COPYING', 'NOTICE', 'CODEOWNERS')
# Теки kit, де будь-який файл — код, хай яке розширення: фікстури тестів (.txt, .json), Cargo.toml,
# ресурси збірки, зібраний kit.exe. Відмінність від agent-kit: там такі файли лежать у пакетах.
$script:CodeRoots = @('tools/', 'rust/', 'bin/')

function Test-KitCodePath {
    <#
    .SYNOPSIS
        Чи файл (шлях від кореня репозиторію, роздільник будь-який) — код kit.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Replace('\', '/')
    foreach ($root in $script:CodeRoots) {
        if ($p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $name = ($p -split '/')[-1]
    if ($script:NonCodeNames -contains $name) { return $false }
    # dot-файл без розширення (.gitignore, .gitattributes) — конфіг, не код.
    if ($name -match '^\.[^.]+$') { return $false }
    $ext = if ($name.Contains('.')) { ($name -split '\.')[-1].ToLowerInvariant() } else { '' }
    return -not ($script:NonCodeExt -contains $ext)
}

function Get-KitChangedFiles {
    <#
    .SYNOPSIS
        Файли, змінені від merge-base HEAD з -Base: закомічені, застейджені, незакомічені й нові
        (не ігноровані). Перейменування — обидва шляхи (`--no-renames`): перейменований код лишається
        кодом, навіть коли новий файл — документ. $null — змін не визначити (немає -Base, не git).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Base = 'origin/main'
    )
    $mb = & git -C $RepoRoot merge-base HEAD $Base 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $mb) { return $null }
    $tracked = @(& git -C $RepoRoot -c core.quotepath=false diff --name-only --no-renames ([string]$mb).Trim() 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $untracked = @(& git -C $RepoRoot -c core.quotepath=false ls-files --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    return , @(@($tracked + $untracked) | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-KitDocsTestFiles {
    <#
    .SYNOPSIS
        Файли тестів, що читають документи: хоч один `Describe` має тег `Docs`. Файл іде цілком —
        новий Describe без тегу в такому файлі теж прогониться.
    #>
    param([Parameter(Mandatory)][string]$Root)
    # Без коми: викликач обгортає @(…), а `return ,@(…)` дав би масив у масиві.
    return @(Get-ChildItem -LiteralPath $Root -Filter '*.Tests.ps1' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '(?m)^\s*Describe\b[^\r\n]*-Tag\b[^\r\n]*\bDocs\b' } |
            ForEach-Object { $_.Name } | Sort-Object)
}

function Get-KitAffectedTestNames {
    <#
    .SYNOPSIS
        Кандидати для -Only: змінений файл тестів — сам; змінений модуль чи скрипт — файли тестів, що
        згадують його ім'я (як `grep -l <ім'я> tools/tests`). Підказка, не доказ повноти: викликачів
        через інші модулі перелік не бачить.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$CodeFiles = @()
    )
    $tests = @(Get-ChildItem -LiteralPath $Root -Filter '*.Tests.ps1' -File)
    $names = foreach ($f in $CodeFiles) {
        $leaf = ($f.Replace('\', '/') -split '/')[-1]
        if ($leaf -like '*.Tests.ps1') { $leaf -replace '\.Tests\.ps1$', ''; continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        if (-not $base) { continue }
        foreach ($t in $tests) {
            if ((Get-Content -LiteralPath $t.FullName -Raw -Encoding UTF8).Contains($base)) { $t.Name -replace '\.Tests\.ps1$', '' }
        }
    }
    return @($names | Sort-Object -Unique)
}

Export-ModuleMember -Function Test-KitCodePath, Get-KitChangedFiles, Get-KitDocsTestFiles, Get-KitAffectedTestNames
