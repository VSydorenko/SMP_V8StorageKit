#Requires -Version 7
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Синтетичний репозиторій-споживач для тестів kit.
.DESCRIPTION
    Створює під -Root ізольований git-репозиторій з маніфестом, накладкою (за бажанням),
    воркспейсами з v8project.yaml і мінімальними деревами джерел, AUTHORS і першим комітом
    на гілці main. Тести НЕ чіпають справжніх репозиторіїв цієї машини — лише це дерево.

    Типовий воркспейс — один, 'Alpha_SMB': base (CONFIGURATION, cf/src, truth: vendor)
    і Alpha_SMB (EXTENSION, cfe/src, truth: storage, шлях до сховища навмисно неіснуючий).
    -Workspaces переозначує набір; -ManifestText — пише маніфест дослівно замість
    згенерованого (для тестів схеми й розбіжностей).
#>

function Invoke-KitFakeGit {
    <#
    .SYNOPSIS
        git для фікстури з перевіркою коду виходу.
    .DESCRIPTION
        Global Constraints B1: нативні команди перевіряються через $LASTEXITCODE явно —
        на цій машині $PSNativeCommandUseErrorActionPreference = $false, тож git, що впав,
        сам винятку не кине. Фікстура довгограюча (задачі 6 і 8 будують на ній коміти й
        гілки storage/*), і мовчазний збій тут дав би провал далеко від причини.

        Навмисно проста функція — без [CmdletBinding()] і без param(): $args приймає усі
        токени позиційно, і PowerShell не намагається зіставити жоден з них з іменем
        оголошеного параметра. Перший варіант — [CmdletBinding()] з
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments — ламав саме
        `git add -A`: "-A" PowerShell розпізнавав як скорочену форму -Arguments (унікальний
        префікс імені параметра серед оголошених), а не як аргумент git, і кидав "Missing an
        argument for parameter 'Arguments'". Внутрішній хелпер фікстури — не Export-ModuleMember.
    #>
    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($args -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")"
    }
    $out
}

function New-KitFakeConfigurationXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Мінімальний Designer XML: check читає перший <Name> — саме так лежить у справжньому
    # Configuration.xml (Properties → Name, рядок 44 у SMP_BankExchange_SMB).
    @(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" version="2.17">'
        '	<Configuration uuid="00000000-0000-0000-0000-000000000000">'
        '		<Properties>'
        "			<Name>$Name</Name>"
        '		</Properties>'
        '	</Configuration>'
        '</MetaDataObject>'
    ) -join "`r`n"
}

function New-KitFakeRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ManifestText,
        [string]$OverlayText,
        [System.Collections.IDictionary]$Workspaces,
        [switch]$WithGitattributes,
        [switch]$WithGitignore,
        [switch]$WithHooks,
        [switch]$WithSessionHook,
        [switch]$NoCommit
    )

    $kitRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-KitFakeGit -C $Root init -q | Out-Null
    Invoke-KitFakeGit -C $Root config user.email 'test@example.invalid' | Out-Null
    Invoke-KitFakeGit -C $Root config user.name 'Test Bot' | Out-Null
    Invoke-KitFakeGit -C $Root config commit.gpgsign false | Out-Null
    # Детермінованість, а не тиша: без цього фікстура успадковує core.autocrlf машини,
    # яка її запускає, і git add/commit нижче друкує "warning: CRLF will be replaced by
    # LF" щоразу, коли autocrlf глобально ввімкнено, — вивід тестів мав би залежати від
    # налаштувань чужого середовища.
    Invoke-KitFakeGit -C $Root config core.autocrlf false | Out-Null
    # Головна гілка — main незалежно від init.defaultBranch цієї машини.
    Invoke-KitFakeGit -C $Root symbolic-ref HEAD refs/heads/main | Out-Null

    if (-not $Workspaces) {
        $Workspaces = [ordered]@{
            'Alpha_SMB' = @{
                Infobase = 'File=build/ib'
                Sets     = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
    }

    $manifest = [System.Collections.Generic.List[string]]::new()
    $manifest.Add('version: 1')
    $manifest.Add('product: Fake')
    $manifest.Add('workspaces:')

    foreach ($wsName in @($Workspaces.Keys)) {
        $ws    = $Workspaces[$wsName]
        $wsDir = Join-Path $Root $wsName
        New-Item -ItemType Directory -Path $wsDir -Force | Out-Null

        $proj = [System.Collections.Generic.List[string]]::new()
        $proj.Add('format: DESIGNER'); $proj.Add('builder: DESIGNER'); $proj.Add("workPath: 'build'")
        if ($ws.Contains('Infobase') -and $ws['Infobase']) {
            $proj.Add('infobase:'); $proj.Add("  connection: '$($ws['Infobase'])'")
        }
        $proj.Add('source-set:')

        $manifest.Add("  - path: $wsName")
        $manifest.Add('    sources:')
        foreach ($set in $ws['Sets']) {
            $proj.Add("  - name: $($set.Name)"); $proj.Add("    type: $($set.Type)"); $proj.Add("    path: '$($set.Path)'")
            $setDir = Join-Path $wsDir $set.Path
            New-Item -ItemType Directory -Path $setDir -Force | Out-Null
            switch ($set.Type) {
                'CONFIGURATION' {
                    # vendor: дерево лишається порожнім і в git не потрапляє — як у споживача без дампу.
                    $manifest.Add("      $($set.Name): { truth: vendor, dump: { from: dev } }")
                }
                'EXTENSION' {
                    Set-Content -LiteralPath (Join-Path $setDir 'Configuration.xml') -Encoding UTF8 -NoNewline `
                        -Value (New-KitFakeConfigurationXml -Name $set.Name)
                    # Сховище навмисно неіснуюче: тести B1 до сховищ не звертаються, а перший
                    # же запуск sync упаде на «Каталог сховища не знайдено», не діставшись платформи.
                    $storage = Join-Path (Split-Path -Parent $Root) "no-such-storage-$($set.Name)"
                    $manifest.Add("      $($set.Name):")
                    $manifest.Add('        truth: storage')
                    $manifest.Add("        storage: { path: '$storage' }")
                }
                'EXTERNAL_DATA_PROCESSORS' {
                    Set-Content -LiteralPath (Join-Path $setDir 'README.md') -Value 'обробки' -Encoding UTF8
                    $manifest.Add("      $($set.Name): { truth: git }")
                }
            }
        }
        Set-Content -LiteralPath (Join-Path $wsDir 'v8project.yaml') -Value ($proj -join "`n") -Encoding UTF8
    }

    $manifestPath = Join-Path $Root 'v8storagekit.yaml'
    if ($PSBoundParameters.ContainsKey('ManifestText')) {
        Set-Content -LiteralPath $manifestPath -Value $ManifestText -Encoding UTF8
    } else {
        Set-Content -LiteralPath $manifestPath -Value ($manifest -join "`n") -Encoding UTF8
    }
    if ($OverlayText) {
        Set-Content -LiteralPath (Join-Path $Root 'v8storagekit.local.yaml') -Value $OverlayText -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $Root 'AUTHORS') -Value 'gitbot=Test Bot <test@example.invalid>' -Encoding UTF8

    if ($WithGitattributes) { Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitattributes') -Destination (Join-Path $Root '.gitattributes') }
    if ($WithGitignore)     { Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitignore')     -Destination (Join-Path $Root '.gitignore') }
    if ($WithHooks) {
        Import-Module (Join-Path $kitRoot 'tools/lib/Hooks.psm1')
        Install-KitGitHooks -RepoRoot $Root -TemplatesDir (Join-Path $kitRoot 'templates/githooks') | Out-Null
    }
    if ($WithSessionHook) {
        Import-Module (Join-Path $kitRoot 'tools/lib/Hooks.psm1')
        Install-KitSessionHook -RepoRoot $Root -TemplatesDir (Join-Path $kitRoot 'templates') | Out-Null
    }

    if (-not $NoCommit) {
        Invoke-KitFakeGit -C $Root add -A | Out-Null
        if ($WithHooks) {
            # Фікстура зображає стан ПІСЛЯ онбордингу, а не зламану інсталяцію: у
            # справжньому репозиторії-споживачі біт виконання виставляє сама команда
            # `kit install-hooks -Apply` (блок B5). На цій машині core.filemode false,
            # тож звичайний `git add -A` вище запише .githooks/* як 100644 незалежно
            # від того, чи спрацював POSIX-chmod усередині Install-KitGitHooks (Task 6) —
            # без цього рядка кожен тест із -WithHooks ловив би зайву warn від
            # Test-KitGitHooks про хук без біта виконання. update-index діє лише на вже
            # проіндексований файл, тож рядок стоїть після add -A і до commit.
            Invoke-KitFakeGit -C $Root update-index --chmod=+x -- .githooks/pre-commit .githooks/pre-merge-commit | Out-Null
        }
        Invoke-KitFakeGit -C $Root commit -q -m 'фікстура: репозиторій-споживач' | Out-Null
    }
    $Root
}

function Add-KitFakeStorageCommit {
    <#
    .SYNOPSIS
        Коміт на orphan-гілку storage/<X> тим самим механізмом, що й sync (B2): worktree,
        V8KIT_SYNC=1 на час коміту, worktree прибирається. Робоча копія не рухається.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$FileName = '',
        [string]$Content,
        [string[]]$RemoveFiles = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Trailers,
        [string]$Subject = 'версія'
    )
    $wt = Join-Path $Repo "build/sync/wt-$([guid]::NewGuid().ToString('N'))"
    # Пробний rev-parse — не через Invoke-KitFakeGit: код виходу 1 тут означає "гілки ще
    # немає", а не збій команди (той самий, навмисно не загорнутий, патерн, що в
    # production-коді — StorageBranch.psm1: Test-KitBranchExists). Загортання дало б
    # виняток на кожному ПЕРШОМУ коміті нової гілки storage/*, який якраз і легальний.
    git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Invoke-KitFakeGit -C $Repo worktree add -q $wt $Branch | Out-Null }
    else                     { Invoke-KitFakeGit -C $Repo worktree add -q --orphan -b $Branch $wt | Out-Null }
    $dir = Join-Path $wt $RepoPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($FileName) {
        $body = if ($PSBoundParameters.ContainsKey('Content')) { $Content } else { "вміст $FileName" }
        Set-Content -LiteralPath (Join-Path $dir $FileName) -Value $body -Encoding UTF8 -NoNewline
    }
    foreach ($rm in $RemoveFiles) { Remove-Item -LiteralPath (Join-Path $dir $rm) -Force -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $wt add -A | Out-Null
    $env:V8KIT_SYNC = '1'
    try { Invoke-KitFakeGit -C $wt commit -q -m ((@($Subject, '') + $Trailers) -join "`n") | Out-Null }
    finally { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $Repo worktree remove --force $wt | Out-Null
}

function Copy-KitTools {
    <#
    .SYNOPSIS
        Копія kit.ps1, lib/, commands/, assets/ і templates/githooks у тимчасову теку зі
        збереженням відносної розкладки — щоб тести запускали справжній диспетчер
        підпроцесом, не чіпаючи робочої копії плагіна (той самий прийом, що в
        Check.Tests.ps1, Kit.Tests.ps1 і Sync.Tests.ps1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $kitRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    # tools/assets: sync (Task 4) вантажить звідти стаб tools/assets/empty-extension у
    # тимчасову ІБ через New-ExtensionInfobase — без копії тут kit.ps1 sync у пісочниці
    # падає на "Cannot find path ...\tools\assets\empty-extension" ще до звернення до
    # сховища (живий Integration-прогін це й спіймав).
    # templates/hooks, templates/settings.json, skills/using-v8storagekit: хук старту сесії
    # (B4 Task 4) — Test-KitSessionHook у скопійованому Hooks.psm1 звіряє встановлений шим саме
    # з templates/hooks/session-start.ps1 ЦІЄЇ копії (TemplatesDir типово відносний від
    # $PSScriptRoot), а сам шим шукає skills/using-v8storagekit/SKILL.md у корені плагіна.
    foreach ($rel in 'tools/lib', 'tools/commands', 'tools/assets', 'templates/githooks', 'templates/hooks', 'skills/using-v8storagekit') {
        $dst = Join-Path $Root $rel
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $kitRoot "$rel/*") -Destination $dst -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $kitRoot 'tools/kit.ps1') -Destination (Join-Path $Root 'tools/kit.ps1') -Force
    # templates/settings.json — раніше НЕ копіювали (рев'ю B4 Task 4, Minor): тоді
    # Install-KitSessionHook у тестах завжди викликали напряму з явним -TemplatesDir на
    # справжній $kitRoot, і копія була мертва. B5 Task 1 (kit install-hooks) це зламало:
    # команда викликає Install-KitSessionHook БЕЗ -TemplatesDir (типове значення відносне
    # від $PSScriptRoot Hooks.psm1), а InstallHooks.Tests.ps1 запускає install-hooks
    # ПІДПРОЦЕСОМ проти саме цієї копії kit.ps1 — типове значення тоді резолвиться в
    # $Root/templates/settings.json, якого без цього рядка тут нема (живий прогін задачі
    # спіймав: "Cannot find path ...\templates\settings.json").
    Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/settings.json') -Destination (Join-Path $Root 'templates/settings.json') -Force
    Join-Path $Root 'tools/kit.ps1'
}

Export-ModuleMember -Function New-KitFakeRepo, New-KitFakeConfigurationXml, Add-KitFakeStorageCommit, Copy-KitTools
