# Каталог випадків паритету ConfigParity.Tests.ps1 (крім корпусу config-bad) і збирач репозиторію випадку.
# Підключається DOT-SOURCE після ConfigParitySetup.ps1. Тексти можуть містити {repo} — корінь репозиторію випадку.
# Випадок: Name; Spec (Manifest, Overlay, Workspaces, Projects, Locals, Files, Dirs, NoManifest, Junction);
# Selects (перелік @{Workspace;Source;Truth} понад типовий вибір без параметрів); Expect (ModesDiffer, PsAgentBaseError).

$script:FxDir = $PSScriptRoot
$script:TemplatesDir = (Resolve-Path "$PSScriptRoot/../../../templates").Path

function script:Read-FxText([string]$Name) { [System.IO.File]::ReadAllText((Join-Path $script:FxDir $Name)) }

function script:New-ParityRepo {
    param([hashtable]$Spec, [string]$Root)
    $kw = @{ Root = $Root; NoCommit = $true }
    if ($Spec.Manifest) { $kw.ManifestText = $Spec.Manifest.Replace('{repo}', $Root) }
    if ($Spec.Workspaces) { $kw.Workspaces = $Spec.Workspaces }
    New-KitFakeRepo @kw | Out-Null
    if ($Spec.Overlay) { [System.IO.File]::WriteAllText((Join-Path $Root 'v8storagekit.local.yaml'), $Spec.Overlay.Replace('{repo}', $Root)) }
    if ($Spec.NoManifest) { Remove-Item -LiteralPath (Join-Path $Root 'v8storagekit.yaml') -Force }
    if ($Spec.Projects) { foreach ($ws in @($Spec.Projects.Keys)) { [System.IO.File]::WriteAllText((Join-Path $Root "$ws/v8project.yaml"), $Spec.Projects[$ws]) } }
    if ($Spec.Locals) { foreach ($ws in @($Spec.Locals.Keys)) { [System.IO.File]::WriteAllText((Join-Path $Root "$ws/v8project.local.yaml"), $Spec.Locals[$ws].Replace('{repo}', $Root)) } }
    if ($Spec.Files) { foreach ($rel in @($Spec.Files.Keys)) {
        $p = Join-Path $Root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        $v = $Spec.Files[$rel]
        if ($v -is [byte[]]) { [System.IO.File]::WriteAllBytes($p, $v) } else { [System.IO.File]::WriteAllText($p, $v.Replace('{repo}', $Root)) }
    } }
    foreach ($d in @($Spec.Dirs)) { if ($d) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null } }
    foreach ($h in @($Spec.Hidden)) { if ($h) { (Get-Item -LiteralPath (Join-Path $Root $h)).Attributes = "Hidden, Directory" } }
    foreach ($j in @($Spec.Junctions)) {
        # Теки-цілі створюються; посилання — справжній junction (mklink /J), не копія.
        if (-not $j) { continue }
        $target = Join-Path $Root $j.Target; $link = Join-Path $Root $j.Link
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $link) | Out-Null
        $out = & cmd /c mklink /J "`"$link`"" "`"$target`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "mklink /J не вдалося: $out" }
    }
    $Root
}

function script:Get-ConfigParityCases {
    $cases = [System.Collections.Generic.List[hashtable]]::new()
    function Add-Case($name, $spec, $selects = @(), $expect = @{}) { $cases.Add(@{ Name = $name; Spec = $spec; Selects = $selects; Expect = $expect }) }
    $ext = { param($n, $p) @{ Name = $n; Type = 'EXTENSION'; Path = $p } }

    # --- Фікстури маніфесту (tools/tests/fixtures/manifest-*.yaml) ---
    $prodWs = [ordered]@{
        'SMP_BankExchange_SMB'   = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, (& $ext 'SMP_BankExchange_SMB' 'cfe/src')) }
        'SMP_BankExchange_SMBru' = @{ Infobase = 'Srvr=SRV;Ref=ru;'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, (& $ext 'SMP_BankExchange_SMBru' 'cfe/src')) }
        'epf'                    = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
    }
    $prodProjects = @{ 'SMP_BankExchange_SMB' = (Read-FxText 'v8project-extension.yaml'); 'epf' = (Read-FxText 'v8project-epf.yaml') }
    $selects = @(
        @{ Workspace = 'epf' }, @{ Source = 'base' }, @{ Workspace = 'SMP_BankExchange_SMB'; Source = 'base' },
        @{ Source = 'SMP_BankExchange_SMB' }, @{ Truth = @('storage') }, @{ Truth = @('git', 'vendor') }, @{ Truth = @('Storage') },
        @{ Truth = @('bogus') }, @{ Workspace = 'nope' }, @{ Source = 'nope' }, @{ Workspace = 'epf'; Source = 'base' }
    )
    Add-Case 'manifest-product.yaml з v8project-fixtures, без накладки' @{ Manifest = (Read-FxText 'manifest-product.yaml'); Workspaces = $prodWs; Projects = $prodProjects } $selects
    Add-Case 'manifest-product.yaml + overlay-sample.yaml' @{ Manifest = (Read-FxText 'manifest-product.yaml'); Overlay = (Read-FxText 'overlay-sample.yaml'); Workspaces = $prodWs; Projects = $prodProjects } $selects
    $clientWs = [ordered]@{
        'Alpenpharma_UNF' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, (& $ext 'Адаптация' 'cfe/a'), (& $ext 'SMP_BankExchange_SMB' 'cfe/b')) }
    }
    Add-Case 'manifest-client.yaml (кириличні ключі джерел)' @{ Manifest = (Read-FxText 'manifest-client.yaml'); Workspaces = $clientWs } @(@{ Source = 'Адаптация' }, @{ Source = 'нема'; OrderInsensitive = $true }, @{ Truth = @('storage') })
    Add-Case 'manifest-client.yaml + накладка сховища з паролем' @{ Manifest = (Read-FxText 'manifest-client.yaml'); Workspaces = $clientWs; Overlay = "storages:`n  Адаптация: { user: 'Сидоренко', password: 'p1' }`n  base: 'D:\mirror\base'`n" } @()

    # --- Зразки templates/*.example ---
    $mEx = [System.IO.File]::ReadAllText((Join-Path $script:TemplatesDir 'v8storagekit.yaml.example'))
    $lEx = [System.IO.File]::ReadAllText((Join-Path $script:TemplatesDir 'v8storagekit.local.yaml.example'))
    $pEx = [System.IO.File]::ReadAllText((Join-Path $script:TemplatesDir 'v8project.yaml.example'))
    $simple = "version: 1`nproduct: Fake`nworkspaces:`n  - path: Alpha_SMB`n    sources:`n      base: { truth: vendor, dump: { from: devUNF } }`n      'ІмʼяРозширення': { truth: git }`n"
    Add-Case 'templates/v8storagekit.yaml.example як є (плейсхолдери — воркспейс не існує)' @{ Manifest = $mEx } @() @{ Good = $false }
    $mFilled = $mEx.Replace('<Воркспейс_UA>', 'Alpha_UA').Replace('<ІмʼяРозширення>', 'ExtName').Replace('<НазваПродукту>', 'Prod').Replace('<Сховище>', 'Stor')
    $exWs = [ordered]@{
        'Alpha_UA' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, (& $ext 'ExtName' 'cfe/src')) }
        'epf'      = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
    }
    Add-Case 'templates/v8storagekit.yaml.example з підставленими іменами' @{ Manifest = $mFilled; Workspaces = $exWs } @()
    Add-Case 'templates/v8storagekit.local.yaml.example як накладка' @{ Manifest = $simple; Overlay = $lEx; Projects = @{ Alpha_SMB = $pEx } } @()
    Add-Case 'templates/v8project.yaml.example як v8project.yaml' @{ Manifest = $simple; Projects = @{ Alpha_SMB = $pEx } } @()

    # --- Шлях сховища зі схемою: userinfo маскується (scheme://***@host/…) з обох боків паритету ---
    Add-Case 'накладка: шлях сховища «tcp://user:pass@host/x» — маска userinfo з обох боків' @{ Overlay = "storages:`n  Alpha_SMB: 'tcp://user:pass@host/x'`n" } @()

    # --- kitVersion у маніфесті: три режими — три різні результати ---
    Add-Case 'kitVersion у добре сформованому маніфесті' @{ Manifest = "kitVersion: 1`nversion: 1`nproduct: Fake`nworkspaces:`n  - path: Alpha_SMB`n    sources:`n      base: { truth: vendor, dump: { from: dev } }`n      Alpha_SMB: { truth: git }`n" } @() @{ ModesDiffer = $true; Good = $false }

    # --- Регістр ключів і truth ---
    Add-Case 'ключі й truth в іншому регістрі (маніфест, накладка, v8project)' @{
        Manifest = "VERSION: 1`nProduct: Fake`nMainBranch: develop`nWORKSPACES:`n  - PATH: Alpha_SMB`n    Sources:`n      base: { TRUTH: Vendor, Dump: { FROM: dev } }`n      Alpha_SMB: { truth: STORAGE, STORAGE: { Path: 'R:\x', USER: u } }`n"
        Overlay = "Infobases:`n  dev: { Connection: 'File=C:\h', USER: x }`nSTORAGES:`n  alpha_smb: { PASSWORD: p, Path: 'D:\m' }`nWorkspaces:`n  ALPHA_SMB: { AgentBase: { TEMPLATE: 'D:\t.dt' } }`n"
        Projects = @{ Alpha_SMB = "Providers: { PUSH: Designer, pull: DESIGNER, Download: designer }`nWorkPath: out`nSource-Set:`n  - { NAME: base, Type: CONFIGURATION, PATH: cf/src }`n  - { name: Alpha_SMB, TYPE: EXTENSION, path: cfe/src }`n" }
        Locals = @{ Alpha_SMB = "INFOBASES:`n  Origin: { CONNECTION: 'File=build/ib', User: u, Password: p }`n" }
    } @(@{ Source = 'ALPHA_SMB' }, @{ Truth = @('STORAGE') })
    Add-Case 'ключі накладки, що різняться лише регістром' @{ Overlay = "storages:`n  Alpha_SMB: { user: a }`n  ALPHA_SMB: { user: b }`n" } @()

    # --- Скаляри, формат файлів ---
    $m = "version: 1`nproduct: Fake`nworkspaces:`n  - path: Alpha_SMB`n    sources:`n      base: { truth: vendor, dump: { from: dev } }`n      Alpha_SMB: { truth: git }`n"
    $utf8bom = [byte[]](0xEF, 0xBB, 0xBF)
    Add-Case 'BOM і CRLF у маніфесті, накладці, v8project і local' @{ Files = @{
            'v8storagekit.yaml'               = [byte[]]($utf8bom + [System.Text.Encoding]::UTF8.GetBytes($m.Replace("`n", "`r`n")))
            'v8storagekit.local.yaml'         = [byte[]]($utf8bom + [System.Text.Encoding]::UTF8.GetBytes("infobases:`r`n  dev: { connection: 'File=C:\h' }`r`n"))
            'Alpha_SMB/v8project.local.yaml'  = [byte[]]($utf8bom + [System.Text.Encoding]::UTF8.GetBytes("infobases:`r`n  origin: { connection: 'File=build/ib' }`r`n"))
        } } @()
    Add-Case 'порожня й суто коментована накладка і local' @{ Overlay = "# лише коментар`n"; Locals = @{ Alpha_SMB = "# коментар`n" } } @()
    Add-Case 'devInfobase: у v8project.local.yaml (стара конвенція)' @{ Locals = @{ Alpha_SMB = "devInfobase: x`n" } } @()
    Add-Case 'dbms — мапа, рядок, список, порожня мапа' @{ Locals = @{ Alpha_SMB = "infobases:`n  origin:`n    connection: 'Srvr=a;Ref=b;'`n    dbms: { user: u, password: p }`n" } } @()
    Add-Case 'dbms рядком' @{ Locals = @{ Alpha_SMB = "infobases:`n  origin: { connection: 'Srvr=a;Ref=b;', dbms: text }`n" } } @()
    Add-Case 'dbms списком' @{ Locals = @{ Alpha_SMB = "infobases:`n  origin: { connection: 'Srvr=a;Ref=b;', dbms: [a, b] }`n" } } @()
    Add-Case 'dbms порожньою мапою' @{ Locals = @{ Alpha_SMB = "infobases:`n  origin: { connection: 'Srvr=a;Ref=b;', dbms: {} }`n" } } @()
    Add-Case 'база агента: user, password, лапки навколо значень' @{ Locals = @{ Alpha_SMB = "infobases:`n  origin: { connection: 'File=`"build/ib`"', user: 'Адмін', password: 'п@ss' }`n" } } @()
    Add-Case 'воркспейс без бази агента (лише EXTERNAL_DATA_PROCESSORS)' @{
        Manifest = "version: 1`nproduct: Fake`nworkspaces:`n  - path: epf`n    sources:`n      external-processors: { truth: git }`n"
        Workspaces = [ordered]@{ epf = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
    } @()

    # --- Корінь, DT-INF, відсутній маніфест ---
    Add-Case 'без маніфесту' @{ NoManifest = $true } @()
    Add-Case 'без маніфесту, DT-INF у корені' @{ NoManifest = $true; Dirs = @('DT-INF') } @()
    Add-Case 'без маніфесту, DT-INF на двох рівнях, змішані латинські імена (порядок — множина: правило Rust не залежить від культури)' @{
        NoManifest = $true; Dirs = @('zeta/DT-INF', 'Alpha/DT-INF', 'a_b/DT-INF', 'a-b/DT-INF', 'a b/DT-INF', 'a.b/DT-INF', 'B/DT-INF', 'b/DT-INF', '1x/DT-INF', 'q/w/DT-INF', 'a/b/c/DT-INF')
    } @() @{ OrderInsensitive = $true }
    Add-Case 'без маніфесту, DT-INF із кириличними іменами (множина: порядок PowerShell залежить від культури)' @{ NoManifest = $true; Dirs = @('Ядро/DT-INF', 'Адаптация/x/DT-INF', 'ёж/DT-INF', 'Ёж/DT-INF') } @() @{ OrderInsensitive = $true }
    Add-Case 'без маніфесту, DT-INF лише на третьому рівні' @{ NoManifest = $true; Dirs = @('a/b/c/DT-INF') } @()
    Add-Case 'без маніфесту, DT-INF у прихованій теці' @{ NoManifest = $true; Dirs = @('hid/DT-INF') ; Hidden = @('hid') } @()

    # --- Вибір джерел: порядок переліку «Є: …», ключі, що різняться регістром, у двох воркспейсах ---
    $twoWs = [ordered]@{
        'W1' = @{ Sets = @((& $ext 'Ключ' 'a'), (& $ext 'Яблуко' 'c'), (& $ext 'Alpha' 'd'), (& $ext 'a_b' 'e'), (& $ext 'a-b' 'f')) }
        'W2' = @{ Sets = @((& $ext 'КЛЮЧ' 'a'), (& $ext 'alpha' 'b'), (& $ext 'beta' 'c')) }
    }
    $twoMan = "version: 1`nproduct: Fake`nworkspaces:`n  - path: W1`n    sources:`n      'Ключ': { truth: git }`n      'Яблуко': { truth: git }`n      Alpha: { truth: git }`n      a_b: { truth: git }`n      a-b: { truth: git }`n  - path: W2`n    sources:`n      'КЛЮЧ': { truth: git }`n      alpha: { truth: git }`n      beta: { truth: git }`n"
    Add-Case 'два воркспейси: кириличні ключі й ключі, що різняться регістром' @{ Manifest = $twoMan; Workspaces = $twoWs } @(@{ Source = 'нема'; OrderInsensitive = $true }, @{ Source = 'нема'; Workspace = 'W1'; OrderInsensitive = $true }, @{ Source = 'ключ' }, @{ Source = 'alpha' }, @{ Source = 'beta' }, @{ Workspace = 'W3' })

    # --- База агента: перетини ---
    $abWs = [ordered]@{
        'A' = @{ Infobase = 'File=build/ib'; Sets = @((& $ext 'ea' 'src')) }
        'B' = @{ Infobase = 'File=build/ib'; Sets = @((& $ext 'eb' 'src')) }
    }
    $abMan = "version: 1`nproduct: Fake`nworkspaces:`n  - path: A`n    sources: { ea: { truth: git } }`n  - path: B`n    sources: { eb: { truth: git } }`n"
    Add-Case 'два воркспейси, різні бази агента — перетинів немає' @{ Manifest = $abMan; Workspaces = $abWs } @()
    Add-Case 'база B у теці бази A (kind base)' @{ Manifest = $abMan; Workspaces = $abWs; Locals = @{ B = "infobases:`n  origin: { connection: 'File={repo}\A\build\ib' }`n" } } @()
    Add-Case 'одна серверна база в двох воркспейсах' @{ Manifest = $abMan; Workspaces = $abWs; Locals = @{ A = "infobases:`n  origin: { connection: 'Srvr=s;Ref=r;' }`n"; B = "infobases:`n  origin: { connection: 'Srvr=S;Ref=R;' }`n" } } @()
    Add-Case 'база B у пам''яті раннера A (.local/infobases/origin)' @{ Manifest = $abMan; Workspaces = $abWs; Locals = @{ B = "infobases:`n  origin: { connection: 'File={repo}\A\.local\infobases\origin\x' }`n" } } @()
    Add-Case 'база B над пам''яттю раннера A' @{ Manifest = $abMan; Workspaces = $abWs; Locals = @{ B = "infobases:`n  origin: { connection: 'File={repo}\A\.local' }`n" } } @()
    Add-Case 'база агента збігається з дев-базою людини з накладки' @{ Manifest = $abMan; Workspaces = $abWs; Overlay = "infobases:`n  human: { connection: 'File={repo}\A\build\ib' }`n" } @()
    Add-Case 'база агента всередині теки дев-бази людини; серверна людини' @{ Manifest = $abMan; Workspaces = $abWs; Overlay = "infobases:`n  human: { connection: 'File={repo}\A\build' }`n  srv: { connection: 'Srvr=s;Ref=r;' }`n" } @()

    # --- Junction (ADR-0021 п. 7): перетин, якого лексичне порівняння не бачить ---
    Add-Case 'junction: база агента лягає в теку дев-бази людини' @{
        Overlay = "infobases:`n  human: { connection: 'File={repo}\human\ib' }`n"
        Dirs = @('human'); Junctions = @(@{ Link = 'Alpha_SMB/build'; Target = 'human' })
    } @() @{ PsAgentBaseError = 'збігається з дев-базою людини' }
    $jWs = [ordered]@{
        'A' = @{ Infobase = 'File=build/ib'; Sets = @((& $ext 'ea' 'src')) }
        'B' = @{ Infobase = 'File=build/ib'; Sets = @((& $ext 'eb' 'src')) }
    }
    Add-Case 'junction: база воркспейсу B лягає в .local/infobases воркспейсу A' @{
        Manifest = $abMan; Workspaces = $jWs
        Junctions = @(@{ Link = 'B/build'; Target = 'A/.local/infobases/origin' })
    } @() @{ PsCollisions = $true }

    # --- Скаляри-пастки в несекретних полях (див. ConfigParity.Tests.ps1: Get-TrapCases) ---
    $cases
}

# Значення-пастки: PowerShell (YamlDotNet) перетворює їх на число/булеве, Rust віддає текст з файла (відома відмінність 3).
$script:TrapValues = @('0123', '1e3', 'yes', 'on', '~', 'null', '1_000', '0x10', '1.10', 'true', '.5', '+1', '12e-1', '0.0', '-0', '1:30', '2024-01-01', 'No')
# Виміряно 2026-11-24: ці PowerShell змінює (0123 -> 123, true -> True, .5 -> 0.5 ...); решта збігається буквально.
$script:TrapMangledByPs = @('0123', '1e3', 'true', '.5', '+1', '12e-1', '0.0', '-0')

# Дві репозиторії на значення: A — у всіх несекретних полях, крім шляху воркспейсу; B — шлях воркспейсу.
function script:Get-TrapSpecs([string]$V) {
    $q = $V
    $manA = "version: 1`nproduct: $q`nmainBranch: $q`nworkspaces:`n  - path: ws`n    sources:`n      ${q}: { truth: storage, storage: { path: 'C:\st', user: $q } }`n      base: { truth: vendor, dump: { from: $q } }`n"
    $wsA = [ordered]@{ ws = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf' }, @{ Name = "'$q'"; Type = 'EXTENSION'; Path = 'e' }) } }
    $a = @{ Manifest = $manA; Workspaces = $wsA
        Overlay = "storages:`n  ${q}: { user: $q }`ninfobases:`n  ${q}: { connection: 'File=C:\h', user: $q }`n"
        Locals = @{ ws = "infobases:`n  origin: { connection: 'File=build/ib', user: $q }`n" } }
    $r = @{ A = $a }
    if ($V -notmatch '[:]') {
        $manB = "version: 1`nproduct: P`nworkspaces:`n  - path: $q`n    sources:`n      ext: { truth: git }`n"
        $wsB = [ordered]@{}; $wsB[$V] = @{ Sets = @(@{ Name = 'ext'; Type = 'EXTENSION'; Path = 'e' }) }
        $r.B = @{ Manifest = $manB; Workspaces = $wsB }
    }
    $r
}
