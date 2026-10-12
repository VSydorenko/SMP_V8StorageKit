#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — те саме застереження, що й довкола вкладених імпортів у StorageReport.psm1:
# не перезавантажувати вже наявний глобальний Yaml.
Import-Module "$PSScriptRoot/Yaml.psm1"
# Так само без -Force, і з тієї ж причини (коментар у StorageReport.psm1): ConvertFrom-V8Connection
# потрібен Resolve-KitAgentInfobasePath (B4, issue #9) для розбору рядка підключення бази агента.
Import-Module "$PSScriptRoot/V8.psm1"

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
        База агента тут не читається — лише infobases.origin у v8project.local.yaml
        (Resolve-V8AgentInfobase).
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

    $workPath = 'build'
    if ($data.Contains('workPath') -and -not [string]::IsNullOrWhiteSpace([string]$data['workPath'])) {
        $workPath = [string]$data['workPath']
    }

    [pscustomobject]@{
        Path       = $full
        Directory  = $dir
        WorkPath   = $workPath
        Providers  = $(if ($data.Contains('providers') -and $data['providers'] -is [System.Collections.IDictionary]) { $data['providers'] } else { $null })
        SourceSets = $sets.ToArray()
    }
}

function Read-V8ProjectLocalInfobase {
    <#
    .SYNOPSIS
        infobases.origin з v8project.local.yaml → {Connection; User; Password; Dbms} або $null.
    .DESCRIPTION
        Єдина форма бази агента в kit 1.5.0 (спека 2026-10-11 §4.3 п. 2–3, рішення 9): та сама, з
        якої базу бере Уніка 0.13. Старої infobase: kit не читає зовсім — вона знахідка
        Get-V8ProjectConfigProblems, а не запасне читання. $null — бази не налаштовано на цій
        машині (свіжий клон): що це означає, вирішує викликач за типами наборів воркспейсу
        (Test-KitWorkspaceNeedsAgentBase, AgentBase.psm1). Пароль іде лише в Invoke-V8Designer
        і ніколи у вивід.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $data = Read-KitYaml -Path $Path -AllowEmpty
    if ($null -eq $data -or -not $data.Contains('infobases')) { return $null }
    $ibs = $data['infobases']
    if ($ibs -isnot [System.Collections.IDictionary] -or -not $ibs.Contains('origin')) { return $null }
    $o = $ibs['origin']
    if ($o -isnot [System.Collections.IDictionary]) { return $null }
    $connection = if ($o.Contains('connection')) { [string]$o['connection'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($connection)) { return $null }
    [pscustomobject]@{
        Connection = $connection
        User       = $(if ($o.Contains('user')) { [string]$o['user'] } else { '' })
        Password   = $(if ($o.Contains('password')) { [string]$o['password'] } else { '' })
        Dbms       = $(if ($o.Contains('dbms') -and $o['dbms'] -is [System.Collections.IDictionary]) { $o['dbms'] } else { $null })
    }
}

function Resolve-V8AgentInfobase {
    <#
    .SYNOPSIS
        База агента так, як її бачить Unica 0.13: infobases.origin у v8project.local.yaml, і лише там.
    .DESCRIPTION
        Повертає сирий рядок підключення, файл-джерело (Origin), user, password і dbms. Відносний
        File= (наприклад 'File=build/ib') тут НЕ розв'язується — це робить викликач від
        Project.Directory, коли справді збирає ключ /F для платформи (Resolve-KitAgentInfobasePath).
        $null — бази не налаштовано (зовнішні обробки або свіжий клон).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)

    $localPath = Join-Path $Project.Directory 'v8project.local.yaml'
    $o = Read-V8ProjectLocalInfobase -Path $localPath
    if ($null -eq $o) { return $null }
    [pscustomobject]@{ Connection = $o.Connection; Origin = $localPath; User = $o.User; Password = $o.Password; Dbms = $o.Dbms }
}

function Get-V8ProjectConfigProblems {
    <#
    .SYNOPSIS
        Знахідки конфігу воркспейсу, з яким Уніка 0.13 чи kit 1.5.0 не працюють, — кожна з рецептом.
    .DESCRIPTION
        Одне місце правил (спека 2026-10-11 §4.3 п. 3, 5; §10 П9, П10): префлайт перетворює кожен
        рядок на fail 'workspace', тож на застарілому конфігу зупиняється БУДЬ-ЯКА команда kit, а
        kit check показує всі рядки разом. Сумісних читань немає (рішення 9): стара форма — це
        знахідка, не другий шлях.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    $problems = [System.Collections.Generic.List[string]]::new()
    $localPath = Join-Path $Directory 'v8project.local.yaml'
    $files = @(
        [pscustomobject]@{ Path = (Join-Path $Directory 'v8project.yaml'); Committed = $true }
        [pscustomobject]@{ Path = $localPath; Committed = $false }
    )
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) { continue }
        $data = Read-KitYaml -Path $file.Path -AllowEmpty
        if ($null -eq $data) { continue }
        $p = $file.Path

        # Лише верхній рівень: вкладений tests.execution_timeout_seconds Уніка 0.13 приймає
        # (runner_014.rs, validate_layer); builder відхиляє сам раннер 0.14.
        foreach ($key in 'builder', 'execution_timeout', 'execution_timeout_seconds', 'basePath') {
            if ($data.Contains($key)) { $problems.Add("${p}: ключ '$key' Уніка 0.13 / v8-runner 0.14 не приймають — з ним вони відмовляються працювати. Видаліть рядок.") }
        }
        foreach ($section in 'push', 'build') {
            if ($data.Contains($section) -and $data[$section] -is [System.Collections.IDictionary] -and $data[$section].Contains('partialLoadThreshold')) {
                $problems.Add("${p}: ключ '$section.partialLoadThreshold' Уніка 0.13 не приймає. Видаліть рядок.")
            }
        }
        if ($data.Contains('source-set') -and $data['source-set'] -is [System.Collections.IList]) {
            foreach ($set in $data['source-set']) {
                if ($set -is [System.Collections.IDictionary] -and $set.Contains('basePath')) {
                    $problems.Add("${p}: ключ 'basePath' у source-set '$($set['name'])' Уніка 0.13 не приймає. Видаліть рядок.")
                }
            }
        }
        if ($data.Contains('infobase')) {
            # Політика kit (рішення 9 спеки), не відмова Уніки: Уніка 0.13 стару форму ще приймає
            # проєкцією — тому в тексті не писати, що її «відхиляє Уніка».
            $problems.Add("${p}: стара форма 'infobase:' — kit 1.5.0 читає базу агента лише з infobases.origin " +
                "у $localPath (одна форма на kit і Уніку, без сумісного читання). Перенесіть: infobases: { origin: { connection: …, user: …, password: … } } у $localPath і " +
                'приберіть infobase: (перехід — skills/onboarding/references/upgrades.md, «1.4.0 → 1.5.0»).')
        }
        if ($data.Contains('infobases')) {
            if ($file.Committed) {
                $problems.Add("${p}: infobases у закоміченому v8project.yaml — база агента машинна й може нести пароль. Перенесіть блок у $localPath (гітігнорований).")
            } elseif ($data['infobases'] -is [System.Collections.IDictionary]) {
                foreach ($name in @($data['infobases'].Keys)) {
                    if ($name -ne 'origin') {
                        $problems.Add("${p}: infobases.'$name' — Уніка обслуговує лише origin, і kit читає лише origin; інша назва означала б, що аудит перевіряє не ту базу. Перейменуйте на origin або приберіть.")
                    }
                }
                if ($data['infobases'].Contains('origin')) {
                    $o = $data['infobases']['origin']
                    if ($o -isnot [System.Collections.IDictionary] -or -not $o.Contains('connection') -or [string]::IsNullOrWhiteSpace([string]$o['connection'])) {
                        $problems.Add("${p}: infobases.origin без connection — база агента оголошена, але не описана. Допишіть connection: 'File=build/ib' (файлова) або 'Srvr=…;Ref=…;' (серверна) — скіл v8storagekit:provision.")
                    }
                }
            }
        }
        if ($file.Committed) {
            $providers = if ($data.Contains('providers')) { $data['providers'] } else { $null }
            if ($providers -isnot [System.Collections.IDictionary]) {
                $problems.Add("${p}: немає providers — запис і завантаження бази агента мусить робити один виконавець (інваріант C1; дефект раннера #459). Додайте: providers: { push: designer, pull: designer, download: designer }.")
            } else {
                foreach ($op in 'push', 'pull', 'download') {
                    $v = if ($providers.Contains($op)) { [string]$providers[$op] } else { '' }
                    if ($v -ne 'designer') {
                        $shown = if ($v) { "'$v'" } else { 'відсутній' }
                        $problems.Add("${p}: providers.$op — $shown, потрібно designer (інваріант C1; агентський режим раннера на Windows не заміряний, #429).")
                    }
                }
            }
        }
    }
    # БЕЗ коми-обгортки: викликачі загортають у @(...), і `, $arr` дав би масив з ОДНОГО
    # елемента навіть без знахідок (аудит плану: @(f).Count = 1) — префлайт тоді пропускав би
    # кожен воркспейс. Той самий урок, що в Select-KitSources.
    $problems.ToArray()
}

function Resolve-KitAgentInfobasePath {
    <#
    .SYNOPSIS
        Підключення бази агента → тип, абсолютний шлях (для файлової), ключ платформи.
    .DESCRIPTION
        Розбір рядка — через ConvertFrom-V8Connection (V8.psm1, issue #9): парні лапки навколо
        значення вона знімає, непарні — помилка; голий шлях без File= більше не приймається. Відносний File=
        розв'язується від теки конфіга (Project.Directory) — так само, як це робить Unica
        (docs/unica-contract.md, A7); абсолютний лишається як є.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$Connection)

    $parsed = ConvertFrom-V8Connection -Connection $Connection
    if ($parsed.Kind -eq 'server') {
        return [pscustomobject]@{ Kind = 'server'; Path = $null; IbSwitch = ('/S "{0}\{1}"' -f $parsed.Server, $parsed.Ref) }
    }
    $path = if ([System.IO.Path]::IsPathRooted($parsed.File)) { $parsed.File } else { Join-Path $Project.Directory $parsed.File }
    $path = [System.IO.Path]::GetFullPath($path)
    [pscustomobject]@{ Kind = 'file'; Path = $path; IbSwitch = ('/F "{0}"' -f $path) }
}

Export-ModuleMember -Function Read-V8Project, Read-V8ProjectLocalInfobase, Resolve-V8AgentInfobase, Resolve-KitAgentInfobasePath, Get-V8ProjectConfigProblems
