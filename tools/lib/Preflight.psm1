#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/RepoRoot.psm1"
Import-Module "$PSScriptRoot/Manifest.psm1"
Import-Module "$PSScriptRoot/V8Project.psm1"

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
        Спільний префлайт усіх команд kit (спека §5): маніфест, накладка, воркспейси,
        відповідність ключів джерел source-set-ам. Мілісекунди, без платформи й git-логу.
    .PARAMETER Lenient
        Не кидати, а збирати знахідки в Findings і виставити Ok=$false. Режим check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Lenient
    )

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
        # Правка H5 (фінальне рев'ю) — до 0.6.0 конвенція клала storage.json у кожну підтеку
        # продукту в корені репозиторію; такий репозиторій уже має все, що потрібно
        # маніфесту (шляхи сховищ, імена розширень, дев-бази), просто не в тому файлі. check
        # мусить розрізняти два стани, не давати одну й ту саму пораду обом. Пошук навмисно
        # неглибокий (Get-ChildItem -Directory по самому кореню, тоді перевірка файлу) — не
        # рекурсія по всьому дереву, воно може бути великим.
        #
        # Правка (рев'ю, 2026-09-04; знято в Task 6 B5) — маршрут на v8storagekit:migrate сам по
        # собі вів у глухий кут, бо ні скіла, ні команди kit migrate не було — вони мали прийти в
        # B6. За чинною спекою (2026-09-03, §9) окремого migrate не буде НІКОЛИ: усі вхідні форми,
        # включно з напівмігрованим 0.6.0, веде v8storagekit:onboarding (розділ 5.2 читає підказки
        # саме зі storage.json). Порада тепер називає скіл, який справді існує, без обіцянки
        # "з'явиться пізніше".
        $legacyDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'storage.json') -PathType Leaf })
        if ($legacyDirs.Count -gt 0) {
            & $fail 'manifest' (
                "Маніфест $script:ManifestFileName не знайдено в $root, але в підтеках є storage.json " +
                "($(($legacyDirs.Name | Sort-Object) -join ', ')) — це репозиторій старої конвенції 0.6.0. " +
                'Правильний шлях — скіл v8storagekit:onboarding: розділ 5.2 сам прочитає шляхи ' +
                'сховищ, імена розширень і дев-бази з наявних storage.json і заповнить маніфест.')
            return $ctx
        }

        # Task 2а (task-2-brief.md, знахідка прогону B5) — інша вхідна форма: gitsync-вивантаження
        # (skills/onboarding/SKILL.md §5, §5.1) МОЖЕ ховатись за ознакою DT-INF/, БЕЗ storage.json
        # (інакше вище вже спрацював би гілка 0.6.0). Вимір по живому парку (10 репозиторіїв)
        # показав DT-INF/ на РІЗНИХ глибинах — у корені репозиторію, на глибині 1 (усередині
        # підпродукту), і навіть ДВІЧІ в одному репозиторії окремо для конфігурації й розширення
        # (cf/DT-INF і cfe/DT-INF) — тому шукаємо в корені й на двох рівнях підтек, а не лише
        # "корінь" чи лише "підтеки", як $legacyDirs вище. Глибина навмисно ОБМЕЖЕНА (корінь + 2
        # рівні), а не рекурсія по всьому дереву: тека вихідників поруч із DT-INF/ може тримати
        # десятки тисяч файлів .mdo, а префлайт іде на КОЖНІЙ команді kit — Get-ChildItem без
        # обмеження глибини зробив би check/sync/verify помітно повільнішими саме на тих
        # репозиторіях, заради яких ця ознака існує. На кожному з трьох рівнів перевіряємо лише
        # Test-Path одного імені (DT-INF) — не читаємо вміст жодної знайденої теки.
        #
        # Рев'ю Task 2, п. 6 — ДВА шви в первинному тексті повідомлення, обидва зайва впевненість:
        # (1) перевірка не доводить "поруч із текою вихідників" — лише сам факт DT-INF/, тож
        # текст цього більше не стверджує; (2) "EDT-вивантаження сховища (gitsync)" ховало
        # ПОХОДЖЕННЯ всередині назви ФОРМАТУ — рівно те, від чого застерігає наступне ж речення.
        # check каже лише, ЩО ВИДНО (EDT-формат із DT-INF/); походження встановлює й підтверджує
        # проба доступу до сховища всередині v8storagekit:onboarding, не ця перевірка.
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
                "Маніфест $script:ManifestFileName не знайдено в $root, але знайдено DT-INF/ без storage.json " +
                "($($dtInfFound -join ', ')) — дерево у EDT-форматі з DT-INF/, маніфесту немає. DT-INF/ доводить " +
                'лише ФОРМАТ дерева, не походження — яке сховище за ним стоїть, якщо взагалі стоїть, ' +
                "з'ясовує сам скіл v8storagekit:onboarding (розділ 5.1): він показує знайдене й питає.")
            return $ctx
        }
        # Правка 5а (живий прогін задачі 11) — "шлях уперед: скіл v8storagekit:onboarding"
        # сам по собі вів у глухий кут: цього скіла ще немає (з'явиться в B5), а це перше й
        # часто ЄДИНЕ повідомлення, яке бачить новий споживач. Пряма дія поруч зі скілом —
        # не замість нього. Правка H3 (фінальне рев'ю) — "з теки плагіна" саме собою не
        # каже, де та тека: додано, як її знайти.
        & $fail 'manifest' ("Маніфест $script:ManifestFileName не знайдено в $root. Репозиторій не підключено до kit — " +
                            'скопіюйте templates/v8storagekit.yaml.example з теки плагіна (знайти теку: claude plugin list, ' +
                            "або /plugin у сесії Claude Code) у корінь репозиторію як $script:ManifestFileName, заповніть " +
                            'і запустіть kit check ще раз. Далі — скіл v8storagekit:onboarding.')
        return $ctx
    }
    try { $ctx.Manifest = Read-KitManifest -Path $ctx.ManifestPath }
    catch { & $fail 'manifest' $_.Exception.Message; return $ctx }
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
            & $fail 'workspace' "У воркспейсі '$($ws.Path)' немає v8project.yaml — структуру джерел описує саме він (спека §2.1)."
            continue
        }
        $project = $null
        try { $project = Read-V8Project -Path $projectPath }
        catch { & $fail 'workspace' $_.Exception.Message; continue }

        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($src in $ws.Sources) {
            $set = $project.SourceSets | Where-Object Name -eq $src.Key | Select-Object -First 1
            if (-not $set) {
                & $fail 'source' ("Джерело '$($src.Key)' воркспейсу '$($ws.Path)' не відповідає жодному name: source-set у " +
                                  "$($ws.Path)/v8project.yaml (є: $($project.SourceSets.Name -join ', ')).")
                continue
            }
            $storagePath = $src.StoragePath; $storageUser = $src.StorageUser; $storagePassword = ''
            if ($src.Truth -eq 'storage' -and $ctx.Overlay -and $ctx.Overlay.Storages.ContainsKey($src.Key)) {
                $ov = $ctx.Overlay.Storages[$src.Key]
                if ($ov.Path)     { $storagePath = $ov.Path }
                if ($ov.User)     { $storageUser = $ov.User }
                if ($ov.Password) { $storagePassword = $ov.Password }
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
        Джерела за спільними параметрами -Workspace / -Source / -Truth (спека §5).
    .DESCRIPTION
        -Source без -Workspace дозволений лише коли ключ унікальний у маніфесті (Q9);
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
    # Без коми-обгортки: виклики в кожному тесті обгортають @(...) самі (як і скрізь
    # у цьому репозиторії, напр. @($ctx.Findings | …)), а `, $sources` тут ламав саме
    # це — @(Select-KitSources …) додає ще один рівень масиву поверх уже "захищеного"
    # $sources, і .Count бачить розмір 1 замість справжньої кількості джерел.
    $sources
}

Export-ModuleMember -Function New-KitFinding, Invoke-KitPreflight, Select-KitSources
