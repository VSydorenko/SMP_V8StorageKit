#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/RepoRoot.psm1"
Import-Module "$PSScriptRoot/Manifest.psm1"
Import-Module "$PSScriptRoot/V8Project.psm1"
# Без -Force, як і вкладений імпорт V8 у V8Project: потрібна Assert-V8SecretQuoteFree для пароля сховища.
Import-Module "$PSScriptRoot/V8.psm1"

$script:ManifestFileName = 'v8storagekit.yaml'
$script:OverlayFileName  = 'v8storagekit.local.yaml'

function New-KitFinding {
    <#
    .SYNOPSIS
        Один рядок звіту check/preflight. error — команда не має права продовжувати;
        warn — працює, але людині варто знати; info — стан, не проблема.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn', 'info')][string]$Level,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Level = $Level; Check = $Check; Message = $Message }
}

function Invoke-KitPreflight {
    <#
    .SYNOPSIS
        Спільний префлайт усіх команд kit: маніфест, накладка, воркспейси,
        відповідність ключів джерел source-set-ам. Мілісекунди, без платформи й git-логу.
    .PARAMETER Mode
        Strict (типово) — кидає на першій проблемі. Lenient — не кидає, а збирає знахідки в Findings і
        виставляє Ok=$false (session-check); kitVersion у маніфесті там — зупинка на знахідці manifest.
        Check — як Lenient, але kitVersion у маніфесті — окрема знахідка error kit-version, решта розбирається.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [ValidateSet('Strict', 'Lenient', 'Check')][string]$Mode = 'Strict'
    )
    $Lenient = $Mode -ne 'Strict'

    $findings = [System.Collections.Generic.List[object]]::new()
    $ctx = [pscustomobject]@{
        RepoRoot = $null; ManifestPath = $null; OverlayPath = $null
        Manifest = $null; Overlay = $null
        Kind = $null; Label = $null; MainBranch = 'main'
        Workspaces = @(); Findings = $findings; Ok = $true
    }
    $fail = {
        param([string]$Check, [string]$Message)
        if (-not $Lenient) { throw $Message }
        $findings.Add((New-KitFinding -Level error -Check $Check -Message $Message))
        $ctx.Ok = $false
    }

    # Не git-репозиторій — нема з чим працювати навіть у check.
    $root = Resolve-V8RepoRoot -Path $RepoRoot
    $ctx.RepoRoot     = $root
    $ctx.ManifestPath = Join-Path $root $script:ManifestFileName

    if (-not (Test-Path -LiteralPath $ctx.ManifestPath -PathType Leaf)) {
        # Вихідники у форматі EDT (ознака — DT-INF/) kit не підтримує. Шукаємо в корені й на двох рівнях
        # підтек: глибина навмисно ОБМЕЖЕНА (дерево може бути величезним, а префлайт іде на КОЖНІЙ
        # команді kit); на кожному рівні — лише Test-Path одного імені.
        $dtInfSearchRoots = [System.Collections.Generic.List[string]]::new()
        $dtInfSearchRoots.Add($root)
        $level1Dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
        foreach ($d1 in $level1Dirs) { $dtInfSearchRoots.Add($d1.FullName) }
        foreach ($d1 in $level1Dirs) {
            foreach ($d2 in @(Get-ChildItem -LiteralPath $d1.FullName -Directory -ErrorAction SilentlyContinue)) {
                $dtInfSearchRoots.Add($d2.FullName)
            }
        }
        $dtInfFound = @($dtInfSearchRoots | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'DT-INF') -PathType Container } |
            ForEach-Object {
                $rel = ([System.IO.Path]::GetRelativePath($root, $_) -replace '\\', '/')
                if ($rel -eq '.') { 'DT-INF/ (у корені)' } else { "$rel/DT-INF" }
            } | Sort-Object)
        if ($dtInfFound.Count -gt 0) {
            & $fail 'manifest' (
                "Вихідники у форматі EDT kit не підтримує ($($dtInfFound -join ', ')): перетворіть їх операцією " +
                '`convert` раннера Уніки або вивантажте сховище наново.')
            return $ctx
        }
        # Це перше й часто ЄДИНЕ повідомлення, яке бачить новий споживач: пряма дія (і як знайти теку
        # плагіна) поруч зі скілом, не замість нього.
        & $fail 'manifest' ("Маніфест $script:ManifestFileName не знайдено в $root. Репозиторій не підключено до kit — " +
                            'скопіюйте templates/v8storagekit.yaml.example з теки плагіна (знайти теку: claude plugin list, ' +
                            "або /plugin у сесії Claude Code) у корінь репозиторію як $script:ManifestFileName, заповніть " +
                            'і запустіть kit check ще раз. Далі — скіл v8storagekit:onboarding.')
        return $ctx
    }
    try { $ctx.Manifest = Read-KitManifest -Path $ctx.ManifestPath -AllowKitVersion:($Mode -eq 'Check') }
    catch { & $fail 'manifest' $_.Exception.Message; return $ctx }
    if ($ctx.Manifest.HasKitVersion) {
        & $fail 'kit-version' ('У маніфесті є поле kitVersion — його прибрано: видаліть рядок kitVersion: з v8storagekit.yaml; ' +
                               'версію проєкту тримає .agents/kit.profile.json (v8storagekit.version).')
    }
    $ctx.Kind = $ctx.Manifest.Kind; $ctx.Label = $ctx.Manifest.Label; $ctx.MainBranch = $ctx.Manifest.MainBranch

    $overlayPath = Join-Path $root $script:OverlayFileName
    if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
        $ctx.OverlayPath = $overlayPath
        try { $ctx.Overlay = Read-KitLocalOverlay -Path $overlayPath }
        catch { & $fail 'overlay' $_.Exception.Message }
    }

    $workspaces = [System.Collections.Generic.List[object]]::new()
    foreach ($ws in $ctx.Manifest.Workspaces) {
        $wsFull = Join-Path $root $ws.Path
        if (-not (Test-Path -LiteralPath $wsFull -PathType Container)) {
            & $fail 'workspace' "Воркспейс '$($ws.Path)' з маніфесту не знайдено в $root."
            continue
        }
        $projectPath = Join-Path $wsFull 'v8project.yaml'
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            & $fail 'workspace' "У воркспейсі '$($ws.Path)' немає v8project.yaml — структуру джерел описує саме він."
            continue
        }
        $cfgProblems = @()
        try { $cfgProblems = @(Get-V8ProjectConfigProblems -Directory $wsFull) }
        catch { & $fail 'workspace' "Конфіг Уніки воркспейсу '$($ws.Path)' не читається: $($_.Exception.Message)"; continue }
        foreach ($problem in $cfgProblems) { & $fail 'workspace' $problem }
        if ($cfgProblems.Count -gt 0) { continue }
        $project = $null
        try { $project = Read-V8Project -Path $projectPath }
        catch { & $fail 'workspace' $_.Exception.Message; continue }

        # " у паролі бази агента — відмова тут (і в kit check), а не лише при запуску платформи.
        # Та сама Assert-V8SecretQuoteFree, що для пароля сховища; Invoke-V8Designer лишає свою перевірку.
        try {
            $agentIb = Read-V8ProjectLocalInfobase -Path (Join-Path $wsFull 'v8project.local.yaml')
            if ($agentIb) { Assert-V8SecretQuoteFree -Value $agentIb.Password -Origin "Пароль бази агента ($($ws.Path)/v8project.local.yaml, infobases.origin.password)" }
        }
        catch { & $fail 'workspace' $_.Exception.Message; continue }

        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($src in $ws.Sources) {
            $set = $project.SourceSets | Where-Object Name -eq $src.Key | Select-Object -First 1
            if (-not $set) {
                & $fail 'source' ("Ключ sources воркспейсу '$($ws.Path)' (ім'я не друкується) не відповідає жодному name: source-set у " +
                                  "$($ws.Path)/v8project.yaml (є: $($project.SourceSets.Name -join ', ')).")
                continue
            }
            $storagePath = $src.StoragePath; $storageUser = $src.StorageUser; $storagePassword = ''
            if ($src.Truth -eq 'storage' -and $ctx.Overlay -and $ctx.Overlay.Storages.ContainsKey($src.Key)) {
                $ov = $ctx.Overlay.Storages[$src.Key]
                if ($ov.Path)     { $storagePath = $ov.Path }
                if ($ov.User)     { $storageUser = $ov.User }
                if ($ov.Password) {
                    # " у паролі сховища — відмова ДО першого запуску платформи (та сама перевірка, що для пароля бази агента).
                    try { Assert-V8SecretQuoteFree -Value $ov.Password -Origin "Пароль сховища (накладка $script:OverlayFileName, storages.$($src.Key).password)" }
                    catch { & $fail 'overlay' $_.Exception.Message; continue }
                    $storagePassword = $ov.Password
                }
            }
            $sources.Add([pscustomobject]@{
                Key             = $src.Key
                Truth           = $src.Truth
                Type            = $set.Type
                Workspace       = $ws.Path
                Path            = $set.Path
                RepoPath        = "$($ws.Path)/$($set.Path)"
                FullPath        = $set.FullPath
                StoragePath     = $storagePath
                StorageUser     = $storageUser
                StoragePassword = $storagePassword
                DumpFrom        = $src.DumpFrom
                Branch          = $(if ($src.Truth -eq 'storage') { "storage/$($src.Key)" } else { $null })
            })
        }
        $workspaces.Add([pscustomobject]@{
            Path = $ws.Path; FullPath = $wsFull; Project = $project; Sources = $sources.ToArray()
        })
    }
    $ctx.Workspaces = $workspaces.ToArray()
    $ctx
}

function Select-KitSources {
    <#
    .SYNOPSIS
        Джерела за спільними параметрами -Workspace / -Source / -Truth.
    .DESCRIPTION
        -Source без -Workspace дозволений лише коли ключ унікальний у маніфесті;
        інакше зупинка з переліком воркспейсів. Повертає масив (може бути порожнім) —
        що робити з порожнім, вирішує команда.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [string[]]$Truth
    )

    $workspaces = @($Context.Workspaces)
    if ($Workspace) {
        $selected = @($workspaces | Where-Object Path -eq $Workspace)
        if ($selected.Count -eq 0) {
            throw "Воркспейсу '$Workspace' немає в маніфесті. Є: $($workspaces.Path -join ', ')."
        }
        $workspaces = $selected
    }

    $sources = @($workspaces | ForEach-Object { $_.Sources })
    if ($Source) {
        $matched = @($sources | Where-Object Key -eq $Source)
        if ($matched.Count -eq 0) {
            $scope = if ($Workspace) { "у воркспейсі '$Workspace'" } else { 'у маніфесті' }
            throw "Джерела '$Source' немає $scope. Є: $(($sources.Key | Sort-Object -Unique) -join ', ')."
        }
        if ($matched.Count -gt 1) {
            throw ("Ключ '$Source' є у кількох воркспейсах: $($matched.Workspace -join ', ') — " +
                   'уточніть -Workspace.')
        }
        $sources = $matched
    }
    if ($Truth) {
        $sources = @($sources | Where-Object { $Truth -contains $_.Truth })
    }
    # Без коми-обгортки: викликачі загортають у @(...) самі, і кома дала б .Count = 1.
    $sources
}

Export-ModuleMember -Function New-KitFinding, Invoke-KitPreflight, Select-KitSources
