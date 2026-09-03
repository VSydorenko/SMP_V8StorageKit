#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — те саме застереження, що й довкола вкладених імпортів у StorageReport.psm1:
# не перезавантажувати вже наявний глобальний Yaml.
Import-Module "$PSScriptRoot/Yaml.psm1"

# Типи source-set, які kit уміє співставити з маніфестом. Інші (якби Unica їх додала)
# зупиняють читання: невідомий тип означає невідомі правила git для цього дерева.
$script:KnownSourceSetTypes = @('CONFIGURATION', 'EXTENSION', 'EXTERNAL_DATA_PROCESSORS')

function Read-V8Project {
    <#
    .SYNOPSIS
        Читає v8project.yaml Уніки — рівно ті поля, від яких залежить kit.
    .DESCRIPTION
        Kit не припускає розкладки воркспейсу (спека §2.3): де лежить cfe/src, cf/src чи src,
        каже цей файл. Тому кожен source-set мусить мати name/type/path, а type — бути з
        відомого списку. Шляхи повертаються і відносними (для .gitignore/.gitattributes і
        RepoPath), і абсолютними (для файлових операцій), розв'язаними від теки самого
        конфіга — так їх розв'язує і Unica (docs/unica-contract.md, A7).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $data = Read-KitYaml -Path $Path
    $full = (Resolve-Path -LiteralPath $Path).Path
    $dir  = Split-Path -Parent $full

    if (-not $data.Contains('source-set')) {
        throw "У $Path немає розділу source-set: — без нього Unica не бачить воркспейсу, а kit не має чого звірити з маніфестом."
    }
    $rawSets = $data['source-set']
    if ($rawSets -isnot [System.Collections.IList] -or $rawSets.Count -eq 0) {
        throw "Розділ source-set: у $Path має бути непорожнім списком."
    }

    $sets = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($item in $rawSets) {
        if ($item -isnot [System.Collections.IDictionary]) {
            throw "Елемент source-set у $Path не є мапою з ключами name/type/path."
        }
        foreach ($key in 'name', 'type', 'path') {
            if (-not $item.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$item[$key])) {
                throw "У source-set файлу $Path бракує ключа '$key'."
            }
        }
        $name    = [string]$item['name']
        $type    = [string]$item['type']
        $relPath = [string]$item['path']

        if ($script:KnownSourceSetTypes -notcontains $type) {
            throw "source-set '$name' у $Path має невідомий type '$type'. Kit знає: $($script:KnownSourceSetTypes -join ', ')."
        }
        if ($seen.ContainsKey($name)) {
            throw "source-set '$name' оголошено в $Path двічі."
        }
        $seen[$name] = $true

        $sets.Add([pscustomobject]@{
            Name     = $name
            Type     = $type
            Path     = (($relPath -replace '\\', '/').TrimEnd('/'))
            FullPath = [System.IO.Path]::GetFullPath((Join-Path $dir $relPath))
        })
    }

    $connection = $null
    if ($data.Contains('infobase') -and $data['infobase'] -is [System.Collections.IDictionary] -and
        $data['infobase'].Contains('connection') -and
        -not [string]::IsNullOrWhiteSpace([string]$data['infobase']['connection'])) {
        $connection = [string]$data['infobase']['connection']
    }

    $workPath = 'build'
    if ($data.Contains('workPath') -and -not [string]::IsNullOrWhiteSpace([string]$data['workPath'])) {
        $workPath = [string]$data['workPath']
    }

    [pscustomobject]@{
        Path               = $full
        Directory          = $dir
        WorkPath           = $workPath
        InfobaseConnection = $connection
        SourceSets         = $sets.ToArray()
    }
}

function Read-V8ProjectLocalInfobase {
    <#
    .SYNOPSIS
        infobase.connection з v8project.local.yaml або $null.
    .DESCRIPTION
        Це файл Уніки, і kit читає з нього рівно один ключ, і рівно з двох причин (спека
        §2.5): (1) canon/provision мусять цілитись у ту саму базу агента, яку наповнює
        operation=build, тож ідуть за вказівником Уніки; (2) check аудитує, чи не лежить
        тут підключення до бази ЛЮДИНИ з накладки kit. Жодне інше значення звідси kit не
        бере — дев-бази, сховища й шаблони .dt живуть у v8storagekit.local.yaml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $data = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $data -or -not $data.Contains('infobase')) { return $null }
    $ib = $data['infobase']
    if ($ib -isnot [System.Collections.IDictionary] -or -not $ib.Contains('connection')) { return $null }
    $connection = [string]$ib['connection']
    if ([string]::IsNullOrWhiteSpace($connection)) { return $null }
    $connection
}

function Resolve-V8AgentInfobase {
    <#
    .SYNOPSIS
        База агента так, як її бачить Unica: v8project.local.yaml → v8project.yaml.
    .DESCRIPTION
        Повертає сирий рядок підключення і файл-джерело. Відносний File= (наприклад
        'File=build/ib') тут НЕ розв'язується — це робить викликач від Project.Directory,
        коли справді збирає ключ /F для платформи (B4). $null — у воркспейсі бази немає
        (зовнішні обробки).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)

    $localPath = Join-Path $Project.Directory 'v8project.local.yaml'
    $local = Read-V8ProjectLocalInfobase -Path $localPath
    if ($local) {
        return [pscustomobject]@{ Connection = $local; Origin = $localPath }
    }
    if ($Project.InfobaseConnection) {
        return [pscustomobject]@{ Connection = $Project.InfobaseConnection; Origin = $Project.Path }
    }
    $null
}

Export-ModuleMember -Function Read-V8Project, Read-V8ProjectLocalInfobase, Resolve-V8AgentInfobase
