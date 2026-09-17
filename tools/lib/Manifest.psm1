#Requires -Version 7
Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/Yaml.psm1"

# Словник truth (спека §2.4) і типові значення. Це єдине місце, де вони оголошені.
$script:TruthValues         = @('storage', 'dump', 'vendor', 'git')
$script:DefaultStorageUser  = 'gitbot'
$script:DefaultMainBranch   = 'main'

function Assert-KitMapKeys {
    <#
    .SYNOPSIS
        Мапа має рівно дозволені ключі й усі обов'язкові. Невідомий ключ — зупинка з
        переліком дозволених: помилка в маніфесті не має проходити мовчки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Map,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string[]]$Required = @(),
        [Parameter(Mandatory)][string]$Where
    )

    if ($Map -isnot [System.Collections.IDictionary]) {
        throw "$Where має бути мапою (ключ: значення)."
    }
    foreach ($r in $Required) {
        if (-not $Map.Contains($r)) { throw "$Where — бракує обов'язкового ключа '$r'." }
    }
    foreach ($k in @($Map.Keys)) {
        if ($Allowed -notcontains [string]$k) {
            throw "$Where — невідомий ключ '$k'. Дозволені: $($Allowed -join ', ')."
        }
    }
}

function Read-KitManifest {
    <#
    .SYNOPSIS
        Читає й валідує v8storagekit.yaml (спека §2.4).
    .DESCRIPTION
        Маніфест не дублює структури — шляхи й типи описує v8project.yaml; тут лише truth
        кожного джерела й те, чого Unica не знає (сховище, дев-база). Звірка ключів sources
        з name: source-set-ів — робота Invoke-KitPreflight, не цього модуля.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $m = Read-KitYaml -Path $Path
    $where = "Маніфест $Path"
    Assert-KitMapKeys -Map $m -Allowed @('version', 'kitVersion', 'product', 'client', 'mainBranch', 'workspaces') `
        -Required @('version', 'kitVersion', 'workspaces') -Where $where

    if ([string]$m['version'] -ne '1') {
        throw "$where — version: $($m['version']) не підтримується; kit знає лише version: 1."
    }

    # version: — версія СХЕМИ цього файлу; kitVersion: — до якої версії плагіна доведено
    # СТРУКТУРУ репозиторію (спека 2026-09-17 §8). Різні величини: схема змінюється рідко,
    # структура — з кожним оновленням, яке щось вимагає від споживача. Фолбеку на відсутнє поле
    # немає навмисно (рішення власника 2026-09-17): наявні репозиторії власник позначає сам.
    $kitVersion = [string]$m['kitVersion']
    if ($kitVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw ("$where — kitVersion: '$kitVersion' не схожий на X.Y.Z. Це версія плагіна, до якої доведено " +
               'структуру репозиторію; довести її й записати число — скіл v8storagekit:onboarding.')
    }

    $hasProduct = $m.Contains('product')
    $hasClient  = $m.Contains('client')
    if ($hasProduct -eq $hasClient) {
        $state = if ($hasProduct) { 'вказано обидва' } else { 'не вказано жодного' }
        throw "$where — має бути рівно один із ключів product: або client: ($state)."
    }
    $label = if ($hasProduct) { [string]$m['product'] } else { [string]$m['client'] }
    if ([string]::IsNullOrWhiteSpace($label)) { throw "$where — значення product:/client: порожнє." }

    $mainBranch = $script:DefaultMainBranch
    if ($m.Contains('mainBranch')) {
        $mainBranch = [string]$m['mainBranch']
        if ([string]::IsNullOrWhiteSpace($mainBranch) -or $mainBranch -match '\s' -or $mainBranch.StartsWith('storage/')) {
            throw "$where — mainBranch: '$mainBranch' не схоже на ім'я гілки або лежить у просторі storage/, зарезервованому для дзеркал сховищ."
        }
    }

    $wsRaw = $m['workspaces']
    if ($wsRaw -isnot [System.Collections.IList] -or $wsRaw.Count -eq 0) {
        throw "$where — workspaces: має бути непорожнім списком."
    }

    $workspaces = [System.Collections.Generic.List[object]]::new()
    $seenPaths  = @{}
    foreach ($ws in $wsRaw) {
        Assert-KitMapKeys -Map $ws -Allowed @('path', 'sources') -Required @('path', 'sources') -Where "$where, елемент workspaces"
        $wsPath = ([string]$ws['path']).Trim()
        if (-not $wsPath -or $wsPath -match '[\\/]' -or $wsPath -eq '.' -or $wsPath -eq '..') {
            throw "$where — workspaces[].path '$wsPath' має бути ім'ям теки безпосередньо в корені репозиторію (без роздільників)."
        }
        if ($seenPaths.ContainsKey($wsPath)) { throw "$where — воркспейс '$wsPath' оголошено двічі." }
        $seenPaths[$wsPath] = $true

        $srcRaw = $ws['sources']
        if ($srcRaw -isnot [System.Collections.IDictionary] -or $srcRaw.Count -eq 0) {
            throw "$where, воркспейс '$wsPath' — sources: має бути непорожньою мапою «ключ джерела → опис»."
        }

        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($key in @($srcRaw.Keys)) {
            $src    = $srcRaw[$key]
            $swhere = "$where, воркспейс '$wsPath', джерело '$key'"
            Assert-KitMapKeys -Map $src -Allowed @('truth', 'storage', 'dump') -Required @('truth') -Where $swhere

            $truth = [string]$src['truth']
            if ($script:TruthValues -notcontains $truth) {
                throw "$swhere — truth: '$truth' невідомий. Дозволені: $($script:TruthValues -join ', ')."
            }

            $storagePath = $null; $storageUser = $null; $dumpFrom = $null
            switch ($truth) {
                'storage' {
                    if (-not $src.Contains('storage')) { throw "$swhere — truth: storage потребує блоку storage: { path: … }." }
                    if ($src.Contains('dump'))         { throw "$swhere — truth: storage не поєднується з dump:." }
                    Assert-KitMapKeys -Map $src['storage'] -Allowed @('path', 'user') -Required @('path') -Where "$swhere, storage"
                    $storagePath = [string]$src['storage']['path']
                    if ([string]::IsNullOrWhiteSpace($storagePath)) { throw "$swhere — storage.path порожній." }
                    $storageUser = $script:DefaultStorageUser
                    if ($src['storage'].Contains('user') -and -not [string]::IsNullOrWhiteSpace([string]$src['storage']['user'])) {
                        $storageUser = [string]$src['storage']['user']
                    }
                }
                { $_ -in @('dump', 'vendor') } {
                    if (-not $src.Contains('dump')) { throw "$swhere — truth: $truth потребує блоку dump: { from: <ключ у infobases: накладки> }." }
                    if ($src.Contains('storage'))   { throw "$swhere — truth: $truth не поєднується зі storage:." }
                    Assert-KitMapKeys -Map $src['dump'] -Allowed @('from') -Required @('from') -Where "$swhere, dump"
                    $dumpFrom = [string]$src['dump']['from']
                    if ([string]::IsNullOrWhiteSpace($dumpFrom)) { throw "$swhere — dump.from порожній." }
                }
                'git' {
                    if ($src.Contains('storage') -or $src.Contains('dump')) {
                        throw "$swhere — truth: git означає, що зовнішнього джерела немає: ні storage:, ні dump: тут не буває."
                    }
                }
            }

            $sources.Add([pscustomobject]@{
                Key         = [string]$key
                Truth       = $truth
                StoragePath = $storagePath
                StorageUser = $storageUser
                DumpFrom    = $dumpFrom
            })
        }
        $workspaces.Add([pscustomobject]@{ Path = $wsPath; Sources = $sources.ToArray() })
    }

    [pscustomobject]@{
        Path       = (Resolve-Path -LiteralPath $Path).Path
        Version    = 1
        KitVersion = $kitVersion
        Kind       = $(if ($hasProduct) { 'product' } else { 'client' })
        Label      = $label
        MainBranch = $mainBranch
        Workspaces = $workspaces.ToArray()
    }
}

function Read-KitLocalOverlay {
    <#
    .SYNOPSIS
        Читає v8storagekit.local.yaml (спека §2.5) — гітігноровану накладку цієї машини.
    .DESCRIPTION
        Тут живуть усі локальні сутності kit: дев-бази, з яких лише читаємо; перевизначення
        шляхів сховищ; шаблон .dt для бази агента. Файл порожній або відсутній — законно:
        повертаються порожні таблиці. Дубльований ключ (дві бази під одним ім'ям) відхиляє
        сам парсер — це наступник запобіжника Read-V8LocalConnection.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Infobases = @{}; Storages = @{}; Workspaces = @{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    $o = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $o) { return $result }
    $where = "Накладка $Path"
    Assert-KitMapKeys -Map $o -Allowed @('infobases', 'storages', 'workspaces') -Where $where

    if ($o.Contains('infobases')) {
        if ($o['infobases'] -isnot [System.Collections.IDictionary]) { throw "$where — infobases: має бути мапою «ім'я → { connection, user }»." }
        foreach ($name in @($o['infobases'].Keys)) {
            $ib = $o['infobases'][$name]
            Assert-KitMapKeys -Map $ib -Allowed @('connection', 'user') -Required @('connection') -Where "$where, infobases.$name"
            $conn = [string]$ib['connection']
            if ([string]::IsNullOrWhiteSpace($conn)) { throw "$where — infobases.$name.connection порожній." }
            $user = ''
            if ($ib.Contains('user')) { $user = [string]$ib['user'] }
            $result.Infobases[[string]$name] = [pscustomobject]@{ Name = [string]$name; Connection = $conn; User = $user }
        }
    }

    if ($o.Contains('storages')) {
        if ($o['storages'] -isnot [System.Collections.IDictionary]) { throw "$where — storages: має бути мапою «ключ джерела → шлях або { path, user, password }»." }
        foreach ($key in @($o['storages'].Keys)) {
            $v = $o['storages'][$key]
            $entry = [pscustomobject]@{ Path = $null; User = $null; Password = $null }
            if ($v -is [System.Collections.IDictionary]) {
                Assert-KitMapKeys -Map $v -Allowed @('path', 'user', 'password') -Where "$where, storages.$key"
                if ($v.Count -eq 0) { throw "$where — storages.$key порожній: вкажіть path, user або password." }
                foreach ($k in 'path', 'user', 'password') {
                    if ($v.Contains($k) -and -not [string]::IsNullOrWhiteSpace([string]$v[$k])) { $entry.($k.Substring(0,1).ToUpper() + $k.Substring(1)) = [string]$v[$k] }
                }
            } else {
                $p = [string]$v
                if ([string]::IsNullOrWhiteSpace($p)) { throw "$where — storages.$key порожній." }
                $entry.Path = $p
            }
            $result.Storages[[string]$key] = $entry
        }
    }

    if ($o.Contains('workspaces')) {
        if ($o['workspaces'] -isnot [System.Collections.IDictionary]) { throw "$where — workspaces: має бути мапою «тека воркспейсу → { agentBase }»." }
        foreach ($wsPath in @($o['workspaces'].Keys)) {
            $ws = $o['workspaces'][$wsPath]
            Assert-KitMapKeys -Map $ws -Allowed @('agentBase') -Where "$where, workspaces.$wsPath"
            $template = $null
            if ($ws.Contains('agentBase')) {
                Assert-KitMapKeys -Map $ws['agentBase'] -Allowed @('template') -Where "$where, workspaces.$wsPath.agentBase"
                if ($ws['agentBase'].Contains('template')) { $template = [string]$ws['agentBase']['template'] }
            }
            $result.Workspaces[[string]$wsPath] = [pscustomobject]@{ Path = [string]$wsPath; AgentBaseTemplate = $template }
        }
    }

    $result
}

function Save-KitOverlayAgentBase {
    <#
    .SYNOPSIS
        Записує workspaces.<ws>.agentBase.template у v8storagekit.local.yaml (створює файл, якщо його немає).
    .DESCRIPTION
        Коментарі накладки при перезаписі губляться — це файл машини, не спільний
        (той самий компроміс, що й у решти запису YAML у kit). Серіалізує через
        ConvertTo-KitYaml (Yaml.psm1), не голий ConvertTo-Yaml — див. коментар там:
        останній не гарантовано видимий із чужого модуля.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OverlayPath, [Parameter(Mandatory)][string]$WorkspacePath, [Parameter(Mandatory)][string]$Template)
    Import-KitYamlModule
    $doc = $null
    if (Test-Path -LiteralPath $OverlayPath -PathType Leaf) { $doc = Read-KitYaml -Path $OverlayPath -AllowEmpty }
    if ($null -eq $doc) { $doc = [ordered]@{} }
    if (-not $doc.Contains('workspaces') -or $doc['workspaces'] -isnot [System.Collections.IDictionary]) { $doc['workspaces'] = [ordered]@{} }
    if (-not $doc['workspaces'].Contains($WorkspacePath) -or $doc['workspaces'][$WorkspacePath] -isnot [System.Collections.IDictionary]) { $doc['workspaces'][$WorkspacePath] = [ordered]@{} }
    $ws = $doc['workspaces'][$WorkspacePath]
    if (-not $ws.Contains('agentBase') -or $ws['agentBase'] -isnot [System.Collections.IDictionary]) { $ws['agentBase'] = [ordered]@{} }
    $ws['agentBase']['template'] = $Template
    $yaml = ConvertTo-KitYaml -Data $doc
    Set-Content -LiteralPath $OverlayPath -Value $yaml -Encoding UTF8 -NoNewline
    Read-KitLocalOverlay -Path $OverlayPath | Out-Null   # перечитати — файл мусить проходити власну схему
}

function Resolve-KitInfobase {
    <#
    .SYNOPSIS
        Дев-база за ключем dump.from — з накладки, або зупинка з готовим блоком для вставки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Overlay,
        [Parameter(Mandatory)][string]$Name,
        [string]$OverlayPath = 'v8storagekit.local.yaml'
    )

    if ($null -eq $Overlay -or -not $Overlay.Infobases.ContainsKey($Name)) {
        throw ("Дев-базу '$Name' не описано в $OverlayPath під infobases: — додайте блок`n" +
               "infobases:`n  ${Name}:`n    connection: 'Srvr=`"<сервер>`";Ref=`"<база>`";'   # або File=`"<шлях>`"`n    user: '<користувач>'")
    }
    $Overlay.Infobases[$Name]
}

Export-ModuleMember -Function Assert-KitMapKeys, Read-KitManifest, Read-KitLocalOverlay, Resolve-KitInfobase, Save-KitOverlayAgentBase
