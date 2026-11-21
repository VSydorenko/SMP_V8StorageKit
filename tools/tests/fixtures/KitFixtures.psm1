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

    -NoSourceTrees: теки source-set'ів НЕ створюються і НЕ наповнюються, тож у першому коміті
    (і взагалі в HEAD) їх немає — git порожніх тек не зберігає. Це не примха, а ЖИВА форма, якої
    типова фікстура не описувала й через це маскувала дефект:
    команда, що створює дерево сама, не знаходить його в HEAD. Фікстура ж завжди клала
    туди Configuration.xml і тим маскувала дефекти відкоту. Тести, які мусять бачити живу
    форму, беруть саме цей варіант.
#>

function Invoke-KitFakeGit {
    <#
    .SYNOPSIS
        git для фікстури з перевіркою коду виходу.
    .DESCRIPTION
        Нативні команди перевіряються через $LASTEXITCODE явно —
        на цій машині $PSNativeCommandUseErrorActionPreference = $false, тож git, що впав,
        сам винятку не кине. Фікстура довгограюча (тести будують на ній коміти й
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

$script:KitFakeDefaultConfigTruth = 'vendor'

function Get-KitFakeSetTruth {
    # Внутрішній хелпер фікстури (не експортується): truth source-set'а. Ключ Truth перекриває
    # умовчання; без нього CONFIGURATION — vendor (як було), EXTENSION — storage.
    param([Parameter(Mandatory)]$Set)
    if ($Set.Contains('Truth')) { return [string]$Set.Truth }
    if ($Set.Type -eq 'CONFIGURATION') { $script:KitFakeDefaultConfigTruth } else { 'storage' }
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
        [switch]$NoSourceTrees,
        [switch]$NoCommit,
        [switch]$WithAgentBase,
        [switch]$WithSupply,
        # Truth CONFIGURATION-набору, коли в Sets його не задано. Умовчання vendor — як було; тести, яким
        # потрібна основа, що НЕ vendor (provision не створює базу для основи vendor), передають dump.
        [ValidateSet('vendor', 'dump', 'storage', 'git')][string]$DefaultConfigTruth = 'vendor'
    )
    $script:KitFakeDefaultConfigTruth = $DefaultConfigTruth

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
    # Файл Уніки гітігнорований у кожного споживача; без цього `git add -A` фікстури закомітив би його,
    # а злиття в main відмовило б на брудній копії.
    Add-Content -LiteralPath (Join-Path $Root '.git/info/exclude') -Value 'v8project.local.yaml' -Encoding UTF8
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
        $proj.Add('format: DESIGNER'); $proj.Add("workPath: 'build'")
        $proj.Add('providers:'); $proj.Add('  push: designer'); $proj.Add('  pull: designer'); $proj.Add('  download: designer')
        if ($ws.Contains('Infobase') -and $ws['Infobase']) {
            Set-Content -LiteralPath (Join-Path $wsDir 'v8project.local.yaml') -Encoding UTF8 -Value (
                @('infobases:', '  origin:', "    connection: '$($ws['Infobase'])'") -join "`n")
            if ($WithAgentBase) {
                # Той самий ідіом, що Provision.Tests.ps1 (1Cv8.1CD — ознака
                # наявної файлової бази для Resolve-KitAgentBase.Exists): sync тепер
                # резолвить базу агента з диска ще до звернення до платформи, і без цього файлу
                # тести, що кличуть Invoke-KitSync у процесі, отримають зупинку з рецептом
                # "kit provision" замість роботи мокованої платформи.
                $ibDir = Join-Path $wsDir 'build/ib'
                New-Item -ItemType Directory -Path $ibDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'stub' -Encoding UTF8
            }
        }
        $proj.Add('source-set:')

        $manifest.Add("  - path: $wsName")
        $manifest.Add('    sources:')
        foreach ($set in $ws['Sets']) {
            $proj.Add("  - name: $($set.Name)"); $proj.Add("    type: $($set.Type)"); $proj.Add("    path: '$($set.Path)'")
            $setDir = Join-Path $wsDir $set.Path
            if (-not $NoSourceTrees) { New-Item -ItemType Directory -Path $setDir -Force | Out-Null }
            $truth = Get-KitFakeSetTruth -Set $set
            switch ($set.Type) {
                { $_ -eq 'CONFIGURATION' -and $truth -in 'vendor', 'dump' } {
                    # vendor: дерево лишається порожнім і в git не потрапляє — як у споживача без дампу.
                    # dump: те саме порожнє дерево, але не гітігноровано (основа, що НЕ vendor).
                    $manifest.Add("      $($set.Name): { truth: $truth, dump: { from: dev } }")
                }
                # switch без break виконує ВСІ підходящі гілки — тому vendor/dump тут виключено явно.
                { $_ -in 'CONFIGURATION', 'EXTENSION' -and -not ($_ -eq 'CONFIGURATION' -and $truth -in 'vendor', 'dump') } {
                    if (-not $NoSourceTrees) {
                        Set-Content -LiteralPath (Join-Path $setDir 'Configuration.xml') -Encoding UTF8 -NoNewline `
                            -Value (New-KitFakeConfigurationXml -Name $set.Name)
                        if ($WithSupply -and $set.Type -eq 'CONFIGURATION') {
                            # Ознаки підтримки основної конфігурації (32 байти > 16 — «описує поставку»).
                            # Іде ДО коміту: .bin у git, .cf — після коміту (див. нижче).
                            New-Item -ItemType Directory -Path (Join-Path $setDir 'Ext') -Force | Out-Null
                            [System.IO.File]::WriteAllBytes((Join-Path $setDir 'Ext/ParentConfigurations.bin'), [byte[]](1..32))
                        }
                    }
                    # Сховище навмисно неіснуюче: ці тести до сховищ не звертаються, а перший
                    # же запуск sync упаде на «Каталог сховища не знайдено», не діставшись платформи.
                    $storage = Join-Path (Split-Path -Parent $Root) "no-such-storage-$($set.Name)"
                    $manifest.Add("      $($set.Name):")
                    $manifest.Add('        truth: storage')
                    $manifest.Add("        storage: { path: '$storage' }")
                }
                'EXTERNAL_DATA_PROCESSORS' {
                    if (-not $NoSourceTrees) {
                        Set-Content -LiteralPath (Join-Path $setDir 'README.md') -Value 'обробки' -Encoding UTF8
                    }
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

    if ($WithGitattributes) {
        Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitattributes') -Destination (Join-Path $Root '.gitattributes')
        # Шаблон знає лише маски **/cfe/src/** і **/epf/src/**; для решти дерев у git (CONFIGURATION
        # не-vendor, EXTENSION із іншим шляхом) onboarding (references/storage.md, 2.4) дописує рядок під фактичний шлях —
        # робимо те саме, інакше check дає error gitattributes на cf/src і cfe/<Ім'я>/src.
        $attrLines = [System.Collections.Generic.List[string]]::new()
        foreach ($wsName in @($Workspaces.Keys)) {
            foreach ($set in $Workspaces[$wsName]['Sets']) {
                if ($set.Type -notin 'CONFIGURATION', 'EXTENSION') { continue }
                if ((Get-KitFakeSetTruth -Set $set) -eq 'vendor') { continue }
                if ($set.Path -ne 'cfe/src') { $attrLines.Add("$wsName/$($set.Path)/** -text") }
            }
        }
        if ($attrLines.Count -gt 0) { Add-Content -LiteralPath (Join-Path $Root '.gitattributes') -Value $attrLines -Encoding UTF8 }
    }
    if ($WithGitignore) {
        Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/gitignore') -Destination (Join-Path $Root '.gitignore')
        # templates/gitignore не тримає загального **/cf/** — вендорські
        # дерева ігноруються ЯВНИМИ рядками під фактичні шляхи, які дописує v8storagekit:onboarding.
        # Тести розраховують, що vendor-дерево гітігноровано (у цій фікстурі — кожен
        # CONFIGURATION source-set, truth: vendor, див. switch у циклі побудови маніфесту вище) —
        # тут дописуємо той самий рядок, який дописав би onboarding, а не змінюємо сам шаблон.
        $vendorLines = [System.Collections.Generic.List[string]]::new()
        foreach ($wsName in @($Workspaces.Keys)) {
            foreach ($set in $Workspaces[$wsName]['Sets']) {
                if ($set.Type -eq 'CONFIGURATION' -and (Get-KitFakeSetTruth -Set $set) -eq 'vendor') { $vendorLines.Add("$wsName/$($set.Path)/**") }
            }
        }
        if ($vendorLines.Count -gt 0) {
            Add-Content -LiteralPath (Join-Path $Root '.gitignore') -Value $vendorLines -Encoding UTF8
        }
    }
    if ($WithHooks) {
        Import-Module (Join-Path $kitRoot 'tools/lib/Hooks.psm1')
        Install-KitGitHooks -RepoRoot $Root -TemplatesDir (Join-Path $kitRoot 'templates/githooks') | Out-Null
    }

    if (-not $NoCommit) {
        Invoke-KitFakeGit -C $Root add -A | Out-Null
        if ($WithHooks) {
            # Фікстура зображає стан ПІСЛЯ онбордингу, а не зламану інсталяцію: у
            # справжньому репозиторії-споживачі біт виконання виставляє сама команда
            # `kit install-hooks -Apply`. На цій машині core.filemode false,
            # тож звичайний `git add -A` вище запише .githooks/* як 100644 незалежно
            # від того, чи спрацював POSIX-chmod усередині Install-KitGitHooks —
            # без цього рядка кожен тест із -WithHooks ловив би зайву warn від
            # Test-KitGitHooks про хук без біта виконання. update-index діє лише на вже
            # проіндексований файл, тож рядок стоїть після add -A і до commit.
            Invoke-KitFakeGit -C $Root update-index --chmod=+x -- .githooks/pre-commit .githooks/pre-merge-commit | Out-Null
        }
        Invoke-KitFakeGit -C $Root commit -q -m 'фікстура: репозиторій-споживач' | Out-Null
    }
    if ($WithSupply -and -not $NoSourceTrees) {
        # ПІСЛЯ коміту, як на машині після canon: .cf і позначка лежать на диску, але поза git
        # (їх ігнорує рядок **/Ext/ParentConfigurations/ шаблону gitignore) — у коміт їх не було
        # б чого класти, навіть коли тест не бере -WithGitignore. Без Import-Module Supply.psm1:
        # пастка вкладеного імпорту описана вище (коментар про Preflight.psm1).
        foreach ($wsName in @($Workspaces.Keys)) {
            foreach ($set in $Workspaces[$wsName]['Sets']) {
                if ($set.Type -ne 'CONFIGURATION' -or (Get-KitFakeSetTruth -Set $set) -ne 'storage') { continue }
                $setDir = Join-Path (Join-Path $Root $wsName) $set.Path
                $supplyDir = Join-Path $setDir 'Ext/ParentConfigurations'
                New-Item -ItemType Directory -Path $supplyDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $supplyDir 'Vendor.cf') -Value 'cf' -Encoding ascii
                $sha = (Get-FileHash -LiteralPath (Join-Path $setDir 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
                [System.IO.File]::WriteAllText((Join-Path $supplyDir '.kit-bin-sha1'), $sha)
            }
        }
    }
    $Root
}

function Add-KitFakeStorageCommit {
    <#
    .SYNOPSIS
        Коміт на orphan-гілку storage/<X> тим самим механізмом, що й sync: worktree,
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
        $filePath = Join-Path $dir $FileName
        # -FileName може бути вкладеним (Ext/ParentConfigurations.bin) — тека файлу мусить існувати.
        New-Item -ItemType Directory -Path (Split-Path -Parent $filePath) -Force | Out-Null
        Set-Content -LiteralPath $filePath -Value $body -Encoding UTF8 -NoNewline
    }
    foreach ($rm in $RemoveFiles) { Remove-Item -LiteralPath (Join-Path $dir $rm) -Force -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $wt add -A | Out-Null
    $env:V8KIT_SYNC = '1'
    try { Invoke-KitFakeGit -C $wt commit -q -m ((@($Subject, '') + $Trailers) -join "`n") | Out-Null }
    finally { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $Repo worktree remove --force $wt | Out-Null
}

function New-KitClientWorkspaces {
    <#
    .SYNOPSIS
        Клієнтський воркспейс: основна конфігурація + ДВА розширення,
        усі під truth: storage. base навмисно ДРУГИМ — порядок sync мусить не залежати від
        порядку маніфесту. Друге розширення з кирилицею в імені — шляхи cfe/<Ім'я>/src.
    #>
    [ordered]@{
        'Client_UNF' = @{
            Infobase = 'File=build/ib'
            Sets     = @(
                @{ Name = 'ExtA';      Type = 'EXTENSION';     Path = 'cfe/ExtA/src' }
                @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
                @{ Name = 'Доработки'; Type = 'EXTENSION';     Path = 'cfe/Доработки/src' }
            )
        }
    }
}

function Invoke-KitCommand {
    <#
    .SYNOPSIS
        Спільний виклик kit.ps1 підпроцесом — та сама форма, що вже стояла в одинадцяти
        файлах тестів (Invoke-Check, Invoke-Sync, Invoke-Provision, ...).
    .DESCRIPTION
        Один спільний виклик прибирає дублювання
        локальних обгорток, але робить його ЄДИНОЮ точкою відмови всіх E2E-тестів набору —
        якби він тихо ковтав ненульовий код виходу, зелено-завжди стали б усі відразу. Тому
        функція має власний тест (KitFixtures.Tests.ps1), а не лише локальні обгортки, що
        делегують сюди.

        -Command і -Repo НЕОБОВ'ЯЗКОВІ: kit.ps1 без команди й без -RepoRoot теж треба вміти
        покликати (напр., перевірка невідомої команди диспетчера) — токен команди й пара
        '-RepoRoot <шлях>' додаються до аргументів лише тоді, коли відповідний параметр
        переданий і непорожній.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kit,
        [string]$Command,
        [string]$Repo,
        [string[]]$More = @()
    )
    $cmdArgs = [System.Collections.Generic.List[string]]::new()
    if ($Command) { $cmdArgs.Add($Command) }
    # Асиметрія свідома, не недогляд: обгортки, які перевели виклик сюди, додавали
    # '-RepoRoot $Repo' БЕЗУМОВНО, а тут — лише якщо $Repo непорожній. Сьогодні різниці
    # немає (жоден виклик не передає порожній -Repo), але контракт відрізняється, і хто
    # покличе цю функцію без -Repo, отримає kit.ps1 без -RepoRoot узагалі, а не з порожнім
    # значенням параметра.
    if ($Repo)    { $cmdArgs.Add('-RepoRoot'); $cmdArgs.Add($Repo) }
    foreach ($m in $More) { $cmdArgs.Add($m) }
    # check і session-check читають реєстр плагінів машини (версія Уніки — вимога):
    # без підстановки результат тесту залежав би від того, яка Уніка стоїть на машині. Тест, що
    # навмисно перевіряє реєстр машини, передає параметр сам.
    if ($Command -in @('check', 'session-check') -and (@($More) -notcontains '-InstalledPluginsPath')) {
        $cmdArgs.Add('-InstalledPluginsPath'); $cmdArgs.Add((New-KitFakeUnicaRegistry))
    }
    # Те саме для раннера: фальшивий реєстр раннера не несе, тож без явного
    # -RunnerPath кожен підпроцесний check дав би error runner-version — і саме тому kit не мусить мовчки йти
    # до справжньої Уніки машини. Підставляється фальшивий tools/tests/fixtures/runner/v8-runner.cmd; тест, що
    # перевіряє відсутність чи іншу версію раннера, передає -RunnerPath сам.
    if ($Command -in @('check', 'session-check') -and (@($More) -notcontains '-RunnerPath')) {
        $cmdArgs.Add('-RunnerPath'); $cmdArgs.Add((Join-Path $PSScriptRoot 'runner/v8-runner.cmd'))
    }
    $out = & pwsh -NoProfile -File $Kit @cmdArgs 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function New-KitFakeUnicaRegistry {
    <#
    .SYNOPSIS
        Фальшивий installed_plugins.json з Унікою заданої версії — для -InstalledPluginsPath kit check
        і session-check. Тести не залежать від того, яка Уніка стоїть на машині.
    #>
    [CmdletBinding()]
    param([string]$Version = '0.16.0')
    $dir = Join-Path $TestDrive "fake-unica-$Version-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'installed_plugins.json'
    Set-Content -LiteralPath $path -Encoding UTF8 -Value (
        @{ plugins = @{ 'unica@unica' = @(@{ version = $Version; installPath = $dir }) } } | ConvertTo-Json -Depth 5)
    $path
}
function Set-KitFakeAgentBase {
    <#
    .SYNOPSIS
        Пише <Workspace>/v8project.local.yaml у формі 0.13 (infobases.origin) — замість ручного Set-Content у тестах.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Workspace = 'Alpha_SMB',
        [Parameter(Mandatory)][string]$Connection,
        [string]$User,
        [string]$Password,
        [System.Collections.IDictionary]$Dbms
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('infobases:'); $lines.Add('  origin:'); $lines.Add("    connection: '$Connection'")
    if ($User)     { $lines.Add("    user: '$User'") }
    if ($Password) { $lines.Add("    password: '$Password'") }
    if ($Dbms) {
        $lines.Add('    dbms:')
        foreach ($k in @($Dbms.Keys)) { $lines.Add("      ${k}: '$($Dbms[$k])'") }
    }
    Set-Content -LiteralPath (Join-Path (Join-Path $Repo $Workspace) 'v8project.local.yaml') -Encoding UTF8 -Value ($lines -join "`n")
}

function Set-KitFakeBranchTree {
    <#
    .SYNOPSIS
        Коміт на гілку з деревом рівно з -Files — без робочої копії, через тимчасовий GIT_INDEX_FILE.
    .DESCRIPTION
        Робоча копія на NTFS не може тримати два шляхи, що різняться лише регістром, і git не
        переводить її через кириличне перейменування регістром. Тестам злиття,
        adopt, verify і check потрібні саме такі дерева — тому плумбінг: hash-object → update-index
        --cacheinfo → write-tree → commit-tree → update-ref. -c core.ignorecase=false на update-index —
        щоб git не зіставляв варіанти регістру й записав обидва, незалежно від налаштування машини.
        Якщо гілка вибрана в робочій копії, update-ref лишить індекс і диск застарілими — викликач
        це знає й бере для такого випадку окрему гілку.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [Parameter(Mandatory)][string]$Message,
        [string]$Parent
    )
    $idx = Join-Path ([System.IO.Path]::GetTempPath()) "kit-fake-index-$([guid]::NewGuid().ToString('N'))"
    $env:GIT_INDEX_FILE = $idx
    try {
        foreach ($path in @($Files.Keys)) {
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmp, [string]$Files[$path], [System.Text.UTF8Encoding]::new($false))
                $sha = ([string](@(Invoke-KitFakeGit -C $Repo hash-object -w --no-filters -- $tmp)[-1])).Trim()
            } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Invoke-KitFakeGit -C $Repo -c core.ignorecase=false update-index --add --cacheinfo "100644,$sha,$path" | Out-Null
        }
        $tree = ([string](@(Invoke-KitFakeGit -C $Repo write-tree)[-1])).Trim()
    } finally {
        Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue
    }
    $parentArgs = @()
    if ($Parent) { $parentArgs = @('-p', $Parent) }
    else {
        # Код 1 = гілки ще немає, не збій (той самий навмисно не загорнутий патерн, що Add-KitFakeStorageCommit).
        git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $parentArgs = @('-p', "refs/heads/$Branch") }
    }
    $msgFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($msgFile, $Message, [System.Text.UTF8Encoding]::new($false))
        $commit = ([string](@(Invoke-KitFakeGit -C $Repo commit-tree $tree @parentArgs -F $msgFile)[-1])).Trim()
    } finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
    Invoke-KitFakeGit -C $Repo update-ref "refs/heads/$Branch" $commit | Out-Null
    $commit
}

function Copy-KitTools {
    <#
    .SYNOPSIS
        Копія kit.ps1, lib/, commands/, assets/ і templates/githooks у тимчасову теку зі
        збереженням відносної розкладки — щоб тести запускали справжній диспетчер
        підпроцесом, не чіпаючи робочої копії плагіна (той самий прийом, що в групах
        Check.*.Tests.ps1, Kit.Tests.ps1 і Sync.*.Tests.ps1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $kitRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    # tools/assets: sync вантажить звідти стаб tools/assets/empty-extension у
    # тимчасову ІБ через New-ExtensionInfobase — без копії тут kit.ps1 sync у пісочниці
    # падає на "Cannot find path ...\tools\assets\empty-extension" ще до звернення до
    # сховища (живий Integration-прогін це й спіймав).
    # hooks, skills/storage-rules: хук старту сесії живе в самому плагіні (1.6.0,
    # hooks/session-start.ps1), бере корінь плагіна зі свого $PSScriptRoot і шукає
    # skills/storage-rules/SKILL.md у ньому — тож копія плагіна несе обидва.
    foreach ($rel in 'tools/lib', 'tools/commands', 'tools/assets', 'templates/githooks', 'hooks', 'skills/storage-rules') {
        $dst = Join-Path $Root $rel
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $kitRoot "$rel/*") -Destination $dst -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $kitRoot 'tools/kit.ps1') -Destination (Join-Path $Root 'tools/kit.ps1') -Force
    # Обгортки команд процесу: тести кличуть команди процесу тим самим шляхом, що й агент, —
    # bin/<команда> → tools/kit.ps1.
    New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
    Copy-Item -Path (Join-Path $kitRoot 'bin/*') -Destination (Join-Path $Root 'bin') -Force
    # templates/settings.json — раніше НЕ копіювали: тоді
    # Install-KitSettings у тестах завжди викликали напряму з явним -TemplatesDir на
    # справжній $kitRoot, і копія була мертва. kit install-hooks це зламало:
    # команда викликає Install-KitSettings БЕЗ -TemplatesDir (типове значення відносне
    # від $PSScriptRoot Hooks.psm1), а InstallHooks.Tests.ps1 запускає install-hooks
    # ПІДПРОЦЕСОМ проти саме цієї копії kit.ps1 — типове значення тоді резолвиться в
    # $Root/templates/settings.json, якого без цього рядка тут нема (живий прогін задачі
    # спіймав: "Cannot find path ...\templates\settings.json").
    Copy-Item -LiteralPath (Join-Path $kitRoot 'templates/settings.json') -Destination (Join-Path $Root 'templates/settings.json') -Force
    # .claude-plugin/plugin.json: версію плагіна читають від кореня копії (KitVersion.psm1: kit-scan,
    # kit-setup) — у цій копії, не в робочій копії плагіна, бо саме копію запускає підпроцес kit.ps1.
    New-Item -ItemType Directory -Path (Join-Path $Root '.claude-plugin') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $kitRoot '.claude-plugin/plugin.json') -Destination (Join-Path $Root '.claude-plugin/plugin.json') -Force
    # CHANGELOG.md: журнал змін плагіна читають хук старту сесії (рядок оновлення), kit-setup і
    # kit-scan (KitVersion.psm1) — від кореня копії, як і plugin.json вище.
    Copy-Item -LiteralPath (Join-Path $kitRoot 'CHANGELOG.md') -Destination (Join-Path $Root 'CHANGELOG.md') -Force
    Join-Path $Root 'tools/kit.ps1'
}

function Get-KitBashPath {
    <#
    .SYNOPSIS
        Bash, яким тести кличуть обгортки bin/<команда> — той самий, що в агента (Git Bash).
    .DESCRIPTION
        На Windows голе `bash` у PATH процесу часто першим знаходить C:\Windows\System32\bash.exe
        (реле WSL) або заглушку WindowsApps: без дистрибутива WSL воно відповідає
        `execvpe(/bin/bash) failed` і кодом 1, і тест бачить «не той код виходу» замість
        поведінки команди. Тож беремо перший bash поза System32 і WindowsApps, а коли такого в
        PATH немає — bash.exe поруч із git (Git for Windows). Поза Windows — просто `bash`.
    #>
    if (-not $IsWindows) { return 'bash' }
    $skip = { param($p) $p -like "$env:SystemRoot\*" -or $p -like '*\WindowsApps\*' }
    $found = @(Get-Command bash -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { -not (& $skip $_.Source) } | Select-Object -First 1)
    if ($found.Count) { return $found[0].Source }
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $root = Split-Path (Split-Path $git -Parent) -Parent   # …\Git\cmd\git.exe або …\Git\mingw64\bin\git.exe
    foreach ($cand in (Join-Path $root 'bin\bash.exe'), (Join-Path (Split-Path $root -Parent) 'bin\bash.exe'), (Join-Path $root 'usr\bin\bash.exe')) {
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    throw "Git Bash не знайдено (git: $git) — тести обгорток bin/ потребують Git for Windows."
}

Export-ModuleMember -Function New-KitFakeUnicaRegistry, Set-KitFakeAgentBase, New-KitFakeRepo, New-KitFakeConfigurationXml, Add-KitFakeStorageCommit, Set-KitFakeBranchTree, Copy-KitTools, Invoke-KitCommand, New-KitClientWorkspaces, Get-KitBashPath
