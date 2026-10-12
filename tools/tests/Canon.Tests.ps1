#Requires -Version 7
Describe 'kit canon — прев''ю і зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Canon { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
    }

    It 'прев''ю: розширення канонізується, vendor пропускається з поясненням' {
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*'
        $r.Output | Should -BeLike '*base*vendor*пропущен*'
        $r.Output | Should -BeLike '*-Apply*'
    }

    It 'бази агента ще немає — -Apply зупиняється до платформи з підказкою provision; дерево ціле' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-base') -WithHooks
        $r = Invoke-Canon -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*provision*'
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }

    It 'база агента = база людини з накладки — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  dev:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'" -WithHooks
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=SMP_UNF;'
        $r = Invoke-Canon -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*людини*'
    }

    It 'воркспейс лише з зовнішніми обробками — нічого канонізувати, код 0' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Canon -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }
}

Describe 'kit canon — мок платформного шару: лічильник Changed, збій git, -Extension, страховка C4 (рев''ю P6/C1-C4)' {
    # Знахідка префлайту B4 (P6): `git status --porcelain -z` дає NUL-роздільник записів,
    # а PowerShell ділить вивід нативної команди по \n — увесь вивід приходить ОДНИМ рядком,
    # тож наївний @(... | Where-Object {...}).Count завжди дає 1 (чи 0) незалежно від
    # справжньої кількості змінених файлів. Тест — без платформи (Invoke-V8Designer
    # замокано; зміни у файлах робить сам мок через Set-Content, а не /DumpConfigToFiles) і
    # ловить САМЕ цей дефект: якщо вирізати правильне розбиття по "`0" і повернути наївний
    # підрахунок, тест впаде, бо коміт нижче лишає дерево З ОДНИМ уже відстеженим файлом
    # (Configuration.xml), а мок дописує до нього ще два — Changed мусить бути 3, не 1.
    #
    # Фікс-раунд рев'ю (C1-C4, той самий Describe — та сама ділянка canon.psm1 і той самий
    # git status, що P6): C1 — збій git status не читається як "нуль змін"; C2 — платформа
    # отримує -Extension лише для EXTENSION-цілі; C3 — нове піддерево (кілька файлів у
    # новій теці) не згортається в один запис; C4 — страховка перед Remove-Item копіює
    # незакомічене/невідстежуване дерево джерела в canon-backup/, перш ніж canon його
    # знищить.
    #
    # Прийом узятий з Dump.Tests.ps1 ("мок платформного шару"): лаб-модулі в порядку
    # module-order.txt, потім САМЕ commands/canon.psm1 у ЦЬОМУ процесі (не підпроцесом
    # kit.ps1) — лише так Mock -ModuleName бачить приватний стіл команд canon.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/canon.psm1").Path -Force
    }

    It 'три файли, змінені мокованим "DumpConfigToFiles" — Changed = 3, не 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-count') -WithHooks
        # Дерево EXTENSION уже в git (Configuration.xml, комітнутий фікстурою). "База
        # агента" мусить виглядати як наявна (Kind=file, Exists перевіряє 1Cv8.1CD) —
        # той самий прийом, що в Provision.Tests.ps1 ("база вже є").
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                $dir = $Matches.p
                # Configuration.xml замінює вже відстежений файл (M); Two.xml і Three.xml —
                # нові (??). Разом три записи в git status --porcelain -z.
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value 'нова версія' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Two.xml') -Value 'два' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Three.xml') -Value 'три' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true

        $result.ExitCode | Should -Be 0
        $result.Canonized.Count | Should -Be 1
        $result.Canonized[0].Files | Should -Be 3
        $result.Canonized[0].Changed | Should -Be 3
        $result.Canonized[0].Changed | Should -BeGreaterThan 1
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1
    }

    It 'CONFIGURATION з поставкою: після дампу — позначка з SHA-1 .bin; розширення — без позначки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'canon-supply') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"(?<ext> -Extension)?') {
                $dir = $Matches.p
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value '<x/>' -Encoding UTF8
                if (-not $Matches.ext) {
                    New-Item -ItemType Directory -Path (Join-Path $dir 'Ext/ParentConfigurations') -Force | Out-Null
                    [System.IO.File]::WriteAllBytes((Join-Path $dir 'Ext/ParentConfigurations.bin'), [byte[]](1..64))
                    Set-Content -LiteralPath (Join-Path $dir 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding ascii
                }
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $result = Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        $cfg = Join-Path $repo 'Client_UNF/cf/src'
        $expected = (Get-FileHash -LiteralPath (Join-Path $cfg 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText((Join-Path $cfg 'Ext/ParentConfigurations/.kit-bin-sha1')) | Should -BeExactly $expected
        ($result.Canonized | Where-Object Key -eq 'base').SupplyMarker | Should -Be $expected
        Join-Path $repo 'Client_UNF/cfe/ExtA/src/Ext/ParentConfigurations' | Should -Not -Exist
        ($result.Canonized | Where-Object Key -eq 'ExtA').SupplyMarker | Should -BeNullOrEmpty
    }

    It 'CONFIGURATION, знята з підтримки (.bin 16 байт) — позначки немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'canon-supply-16') -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitignore -WithAgentBase
        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"(?<ext> -Extension)?') {
                $dir = $Matches.p
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value '<x/>' -Encoding UTF8
                if (-not $Matches.ext) {
                    New-Item -ItemType Directory -Path (Join-Path $dir 'Ext/ParentConfigurations') -Force | Out-Null
                    [System.IO.File]::WriteAllBytes((Join-Path $dir 'Ext/ParentConfigurations.bin'), [byte[]](1..16))
                    Set-Content -LiteralPath (Join-Path $dir 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf' -Encoding ascii
                }
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $result = Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true
        Join-Path $repo 'Client_UNF/cf/src/Ext/ParentConfigurations/.kit-bin-sha1' | Should -Not -Exist
        ($result.Canonized | Where-Object Key -eq 'base').SupplyMarker | Should -BeNullOrEmpty
    }

    It 'git status упав ПІСЛЯ дампу (пошкоджений git-індекс) — canon кидає, а не звітує "змінено файлів: 0" (C1)' {
        # Той самий симптом, що дає конкурентний .git/index.lock (kit sync чи редактор
        # тримають індекс): git status завершується ненульовим кодом. Без явної перевірки
        # $LASTEXITCODE/ExitCode порожній stdout читався б як "нуль змін" — рівно той
        # сигнал успіху, який round-trip Integration-тест перевіряє як "дерево вже
        # канонічне", уже ПІСЛЯ того, як дерево переписано платформою.
        #
        # Псуємо індекс УСЕРЕДИНІ мока (не до виклику canon) — так передделеційна
        # перевірка страховки (C4) застає індекс ще чистим і валідним (нічого зайвого не
        # копіює, Remove-Item/дамп відбуваються штатно), а падає рівно ПІСЛЯ дампу — той
        # самий git-виклик, що рахує Changed. $script:-скоуп обов'язковий: Mock -ModuleName
        # виконує -MockWith у приватному столі названого модуля (canon), а не в лексичному
        # оточенні цього It-блоку (той самий прийом, що Verify.Tests.ps1: "script:-scoped,
        # не локальна $content").
        $script:GitFailRepo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-git-fail') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $script:GitFailRepo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $script:GitFailRepo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                Set-Content -LiteralPath (Join-Path $Matches.p 'Configuration.xml') -Value 'нова версія' -Encoding UTF8
            }
            Set-Content -LiteralPath (Join-Path $script:GitFailRepo '.git/index') -Value 'зіпсовано навмисно для тесту' -Encoding UTF8
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $script:GitFailRepo
        { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } | Should -Throw '*git status*'
    }

    It 'CONFIGURATION і EXTENSION в одному воркспейсі — платформа отримує -Extension лише для EXTENSION (C2)' {
        # Мок ловить лише сам /DumpConfigToFiles; без цього тесту вирізання виразу $ext
        # (canon.psm1) лишало б усі наявні тести зеленими, а canon на EXTENSION-джерелі
        # вивантажував би в cfe/src основну конфігурацію замість розширення.
        $manifest = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: dump, dump: { from: dev } }',
            "      Alpha_SMB: { truth: storage, storage: { path: '$(Join-Path $TestDrive 'no-such-storage')' } }"
        ) -join "`n"
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Infobase = 'File=build/ib'
                Sets     = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-ext-flag') -Workspaces $ws -ManifestText $manifest -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $null = Invoke-KitCanon -Context $ctx -Apply $true

        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -match '-Extension Alpha_SMB'
        }
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -notmatch '-Extension'
        }
    }

    It 'нове піддерево (кілька нових файлів у НОВІЙ теці) не згортається в один запис — Changed рахує кожен (C3)' {
        # git status --porcelain без -uall згортає повністю невідстежену теку в ОДИН запис
        # ("?? Forms/") — типовий випадок canon: агент додав новий об'єкт метаданих (нову
        # форму, новий макет) із власною підтекою. 4 нових файли під Forms/NewForm/ + 1
        # змінений Configuration.xml мають дати Changed = 5, а не 2.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-subtree') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                $dir = $Matches.p
                Set-Content -LiteralPath (Join-Path $dir 'Configuration.xml') -Value 'нова версія' -Encoding UTF8
                $formExtDir = Join-Path $dir 'Forms/NewForm/Ext/Form'
                New-Item -ItemType Directory -Path $formExtDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir 'Forms/NewForm/Form.xml') -Value 'f1' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Forms/NewForm/Template.xml') -Value 'f2' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $formExtDir 'Module.bsl') -Value 'f3' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $dir 'Forms/NewForm/Ext/ObjectModule.bsl') -Value 'f4' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true

        $result.Canonized[0].Files | Should -Be 5
        $result.Canonized[0].Changed | Should -Be 5
    }

    It 'C4: брудне дерево (змінений відстежуваний + невідстежуваний файл) — обидва в canon-backup зі структурою; шлях у виводі' {
        # Сценарій С4: агент правив cfe/src/... через Unica, забув operation=build, запускає
        # canon -Apply. Без страховки Remove-Item знищив би цю незакомічену роботу
        # безслідно ще до того, як платформа поклала свій (застарілий) дамп на її місце.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-backup-dirty') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        $srcDir = Join-Path $repo 'Alpha_SMB/cfe/src'
        Set-Content -LiteralPath (Join-Path $srcDir 'Configuration.xml') -Value 'агентська правка (незакомічена)' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'Forms/NewForm') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcDir 'Forms/NewForm/Form.xml') -Value 'нова форма агента (незакомічена)' -Encoding UTF8

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                Set-Content -LiteralPath (Join-Path $Matches.p 'Configuration.xml') -Value 'застарілий дамп платформи' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # 6>&1: Write-Host йде в потік Information (6) — зливаємо його в success stream,
        # щоб побачити і повернений об'єкт, і надрукований текст в одному захопленні.
        # InformationRecord сам проходить перевірку "-is [pscustomobject]" (перевірено
        # окремо), тому справжній результат відділяємо саме "-isnot InformationRecord",
        # а не навпаки.
        $captured = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true 6>&1
        $result = $captured | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -First 1
        $hostText = ($captured | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
            ForEach-Object { $_.MessageData.Message }) -join "`n"

        $backupDir = $result.Canonized[0].Backup
        $backupDir | Should -Not -BeNullOrEmpty
        (Join-Path $backupDir 'Configuration.xml') | Should -Exist
        (Get-Content -LiteralPath (Join-Path $backupDir 'Configuration.xml') -Raw) | Should -BeLike '*агентська правка*'
        (Join-Path $backupDir 'Forms/NewForm/Form.xml') | Should -Exist
        (Get-Content -LiteralPath (Join-Path $backupDir 'Forms/NewForm/Form.xml') -Raw) | Should -BeLike '*нова форма агента*'
        $hostText | Should -BeLike "*$backupDir*"
        # Дамп платформи (застарілий) справді переписав дерево джерела — незакомічена
        # правка звідти зникла, але вціліла в резервній копії (перевірено вище).
        (Get-Content -LiteralPath (Join-Path $srcDir 'Configuration.xml') -Raw) | Should -BeLike '*застарілий дамп*'
    }

    It 'C4: чисте дерево — тека canon-backup не створюється взагалі' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-backup-clean') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                Set-Content -LiteralPath (Join-Path $Matches.p 'Configuration.xml') -Value 'нова версія' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true

        $result.Canonized[0].Backup | Should -BeNullOrEmpty
        (Join-Path $repo 'Alpha_SMB/build/canon-backup') | Should -Not -Exist
    }

    It 'C4: запис перейменування (git mv) розбирається правильно — копія містить файл під НОВИМ іменем, лічильник не роздвоюється' {
        # Пастка, яку конкретно перевіряє цей тест: записи R/C у --porcelain -z несуть ДВА
        # NUL-роздільні поля (новий шлях, тоді старий), а не один. Наївний розбір "кожен
        # NUL-токен = один запис" або кидає виняток на .Substring другого поля (воно
        # коротше за очікуваний префікс статусу), або мовчки обрізає перші три символи
        # назви файла — перевірено живим прогоном рев'ю ("cfe/src/Old.xml" ставало
        # "/src/Old.xml"). Corrupted-шлях не проходить перевірку префіксу в
        # Backup-KitDirtyFiles і просто мовчки не копіюється — сам по собі факт
        # "Renamed.xml є в копії" НЕ ловить дефект (він однаково є і за наївного розбору,
        # бо перший токен запису парситься правильно за випадковим збігом зсуву).
        # Ловить дефект лише КІЛЬКІСТЬ записів: наївний розбір рахує старий шлях
        # перейменування ЯК ОКРЕМИЙ додатковий запис (перевірено мутаційним тестом
        # виконавця: 1 перейменування + 1 змінений файл дає "2 незакомічених" за
        # правильного розбору і "3 незакомічених" за наївного). Тому тест додає ДРУГИЙ,
        # незалежний брудний файл (Configuration.xml) і звіряє ТОЧНЕ число в друкованому
        # рядку через захоплення потоку Information (6>&1), а не лише факт існування
        # копії.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-rename') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        $srcDir = Join-Path $repo 'Alpha_SMB/cfe/src'
        Set-Content -LiteralPath (Join-Path $srcDir 'Extra.xml') -Value 'зайвий файл' -Encoding UTF8
        git -C $repo add -A | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'фікстура: git add Extra.xml не вдався' }
        git -C $repo commit -q -m 'фікстура: додано Extra.xml' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'фікстура: git commit Extra.xml не вдався' }
        git -C $repo -c core.quotepath=false mv 'Alpha_SMB/cfe/src/Extra.xml' 'Alpha_SMB/cfe/src/Renamed.xml' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'фікстура: git mv не вдався' }
        # Другий, незалежний брудний файл — щоб мати ЩО порахувати неправильно.
        Set-Content -LiteralPath (Join-Path $srcDir 'Configuration.xml') -Value 'агентська правка (незакомічена)' -Encoding UTF8

        Mock -ModuleName canon Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Виклик НЕ загорнутий у `{ } | Should -Not -Throw`: PowerShell виконує таку
        # скрипт-блок-функцію у ВЛАСНІЙ області видимості, тож `$result = ...` усередині
        # неї не витікає в зовнішній `$result` — той самий клас пастки, що вже
        # задокументований в цьому файлі про Mock -ModuleName (лексичне оточення не
        # успадковується автоматично). Якщо Invoke-KitCanon кине виняток, цей It впаде
        # сам, з повним текстом винятку — того самого ефекту, що й Should -Not -Throw.
        # 6>&1 — той самий прийом, що й у тесті "брудне дерево" вище: Write-Host іде в
        # потік Information (6), а InformationRecord сам проходить "-is [pscustomobject]",
        # тому справжній результат відділяємо "-isnot InformationRecord".
        $captured = Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true 6>&1
        $result = $captured | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -First 1
        $hostText = ($captured | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
            ForEach-Object { $_.MessageData.Message }) -join "`n"

        $backupDir = $result.Canonized[0].Backup
        $backupDir | Should -Not -BeNullOrEmpty
        (Join-Path $backupDir 'Renamed.xml') | Should -Exist
        (Get-Content -LiteralPath (Join-Path $backupDir 'Renamed.xml') -Raw) | Should -BeLike '*зайвий файл*'
        (Join-Path $backupDir 'Configuration.xml') | Should -Exist
        (Get-Content -LiteralPath (Join-Path $backupDir 'Configuration.xml') -Raw) | Should -BeLike '*агентська правка*'
        # Точна кількість — рівно 2 записи (перейменування + одна зміна), НЕ 3: третій
        # з'явився б, якби старий шлях перейменування рахувався окремим записом.
        $hostText | Should -BeLike '*2 незакомічених змін*'
    }

    It 'C4: git status упав ДО видалення — зупинка, дерево лишається цілим (не лише повідомлення)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-predelete-fail') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'

        Mock -ModuleName canon Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Псуємо git-індекс ДО виклику canon — перший же git-виклик (від Task 8 — перевірка невидимої роботи П24, раніше git status страховки C4; обидва ДО
        # Remove-Item) падає, і Remove-Item не виконується взагалі: платформу не кличуть
        # ні разу, закомічений файл лишається на місці.
        Set-Content -LiteralPath (Join-Path $repo '.git/index') -Value 'зіпсовано навмисно для тесту' -Encoding UTF8

        { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } | Should -Throw '*завершився з кодом 128*index file corrupt*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }

    It 'C4: Get-KitDirtyRecords (git status страховки) кидає ДО видалення — зупинка, дерево ціле, платформа не запускалась' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-dirty-fail') -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/ib') -Force | Out-Null
        Set-Content (Join-Path $repo 'Alpha_SMB/build/ib/1Cv8.1CD') -Value 'stub'
        Mock -ModuleName canon Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Перевірка невидимої роботи (П24) проходить, тож до страховки C4 доходить саме вона.
        Mock -ModuleName canon Get-KitInvisibleWork { @() }
        Mock -ModuleName canon Get-KitDirtyRecords { throw 'git status для страховки завершився з кодом 128' }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } | Should -Throw '*страховки завершився з кодом 128*'
        Should -Invoke -ModuleName canon Get-KitDirtyRecords -Times 1
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }
}

Describe 'kit canon — round-trip дає нуль розбіжностей на канонічному дереві' -Tag Integration {
    # Порожня база агента + стаб розширення: канонічне дерево — те, що платформа сама віддала.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rt') -WithHooks -WithGitattributes -WithGitignore
        # база агента зі стабом Alpha_SMB (як робив би operation=build)
        $ib = New-ExtensionInfobase -Path (Join-Path $script:Repo 'Alpha_SMB/build/ib') -ExtensionName 'Alpha_SMB' `
            -StubPath (Resolve-Path "$PSScriptRoot/../assets/empty-extension").Path -MustBeUnder (Join-Path $script:Repo 'Alpha_SMB')
    }
    It 'перший canon переписує дерево платформою; другий не змінює жодного файла' {
        $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'канонічне дерево'
        $out2 = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $script:Repo -Source Alpha_SMB -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out2
        (git -C $script:Repo status --porcelain -- Alpha_SMB/cfe/src) | Should -BeNullOrEmpty
        $out2 | Should -BeLike '*змінено файлів: 0*'
    }
}

Describe 'kit canon — пароль бази агента доходить до платформи й не потрапляє у вивід (#26, §10 П12)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/canon.psm1").Path -Force
    }
    It 'canon -Apply: /P "***" у Verbose, справжній пароль — лише в аргументах Start-Process' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'pwd') -WithHooks -WithAgentBase
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -User 'agent' -Password 'S3cr3t-Пароль'
        # Без моку Get-V8Path тест залежав би від установленої платформи 8.3.27.x (kit-dev (б)).
        Mock -ModuleName V8 Get-V8Path { 'C:\fake\1cv8.exe' }
        Mock -ModuleName V8 Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $old = $global:VerbosePreference; $global:VerbosePreference = 'Continue'
        try { $out = & { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } *>&1 | Out-String }
        finally { $global:VerbosePreference = $old }
        $out | Should -Not -BeLike '*S3cr3t*'
        $out | Should -BeLike '*/P "[*][*][*]"*'
        Should -Invoke -ModuleName V8 Start-Process -ParameterFilter { $ArgumentList -like '*/N "agent"*/P "S3cr3t-Пароль"*' }
    }
}

Describe 'kit canon -MarkerOnly (§10 П5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Run { param([string]$Repo, [string[]]$More)
            $out = & pwsh -NoProfile -File $script:Kit canon -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:StorageWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
    }
    It 'позначки немає, .cf на місці, дерево чисте — пише позначку без бази агента й без платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ok') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $want = (Get-FileHash -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText($marker) | Should -Be $want
        Test-Path -LiteralPath (Join-Path $repo 'Alpha_SMB/build/ib') | Should -BeFalse
    }
    It 'без -Source — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nosrc') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        (Run -Repo $repo -More @('-MarkerOnly', '-Apply')).Output | Should -BeLike '*-MarkerOnly потребує -Source*'
    }
    It 'набір EXTENSION — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-ext') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $r = Run -Repo $repo -More @('-Source', 'Alpha_SMB', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*позначка поставки буває лише в наборі CONFIGURATION*'
    }
    It 'немає .cf — код 1, рецепт pull' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nocf') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations') -Filter '*.cf' | Remove-Item -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*немає .cf*pull*'
    }
    It 'брудне дерево — код 1, позначку не записано (запасна гілка §4.1)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-dirty') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Value '<!-- pull дав інші байти -->'
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*брудне*доповідь*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'стара позначка на місці (stale) — код 1, позначку не переписано (§10.1 П22: .cf цим pull не перевивантажувався)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-stale') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        [System.IO.File]::WriteAllText($marker, 'deadbeef')
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*стара позначка*не перевивантажувався*'
        [System.IO.File]::ReadAllText($marker) | Should -Be 'deadbeef'
    }
    It '.bin не описує поставку (16 байт) — код 1, позначку не записано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-nodesc') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        [System.IO.File]::WriteAllBytes((Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations.bin'), [byte[]](1..16))
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не описує поставку вендора*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'прев''ю без -Apply — код 0, повідомлення про -Apply, позначку не записано' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-preview') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $marker = Join-Path $repo 'Alpha_SMB/cf/src/Ext/ParentConfigurations/.kit-bin-sha1'
        Remove-Item -LiteralPath $marker -Force
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*додайте -Apply*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'позначка вже актуальна (current) — код 0, нічого не пишеться' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mo-current') -Workspaces $script:StorageWs -WithSupply -WithGitignore -WithHooks
        $r = Run -Repo $repo -More @('-Source', 'base', '-MarkerOnly', '-Apply')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*вже відповідає .bin*'
    }
}

Describe 'kit canon -Apply — зупинка на невидимій роботі під набором (§10.2 П24)' {
    # Копія canon-backup покриває лише те, що бачить git status. Ігноровані файли, файли з
    # прапорцем і gitlink Remove-KitDirectory знищив би безслідно — тому зупинка стоїть ДО нього.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/canon.psm1").Path -Force
        $script:InvWs = [ordered]@{ 'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src'; Truth = 'storage' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        function script:New-InvRepo { param([string]$Name)
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $script:InvWs -WithSupply -WithGitignore -WithHooks -WithAgentBase }
        # П25: переносить частину дерева за межі репозиторію й ставить на її місце junction. Mode e2 — junction на
        # компоненті ВИЩЕ кореня набору (Alpha_SMB/<Parent>), e1 — сам корінь набору (Alpha_SMB/<Parent>/<Leaf>).
        # Повертає ціль (поза репо) з контрольним файлом keep.txt.
        function script:Set-SetBehindLink { param([string]$Repo, [string]$Mode, [string]$Parent, [string]$Leaf, [string]$Tag)
            $linkPath = if ($Mode -eq 'e2') { Join-Path $Repo "Alpha_SMB/$Parent" } else { Join-Path $Repo "Alpha_SMB/$Parent/$Leaf" }
            $target = Join-Path $TestDrive "outside-$Tag-$Mode"
            Move-Item -LiteralPath $linkPath -Destination $target
            Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'чужа ціль' -Encoding UTF8
            New-Item -ItemType Junction -Path $linkPath -Target $target | Out-Null
            $target }
        function script:Get-LinkTargetState { param([string]$Target)
            (Get-ChildItem -LiteralPath $Target -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Target.Length))=$((Get-Content -LiteralPath $_.FullName -Raw))" }) -join '|' }
    }
    BeforeEach {
        # Платформа мокована; лічильник викликів доводить, що наступний крок не відбувся.
        Mock -ModuleName canon Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    It 'файл під .git/info/exclude — зупинка з переліком і рецептом, тека ціла, платформа не запускалась' {
        $repo = New-InvRepo 'inv-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.git/info/exclude') -Value 'Alpha_SMB/cfe/src/mine.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/mine.txt') -Value 'робота' -Encoding UTF8
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw '*невидима робота під набором*ignored*mine.txt*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/mine.txt' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }
    It '<Flag> на зміненому файлі — зупинка, тека ціла, платформа не запускалась' -ForEach @(
        @{ Flag = 'assume-unchanged' }
        @{ Flag = 'skip-worktree' }
    ) {
        $repo = New-InvRepo "inv-$Flag"
        $f = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
        Set-Content -LiteralPath $f -Value 'правка агента' -Encoding UTF8
        git -C $repo update-index "--$Flag" Alpha_SMB/cfe/src/Configuration.xml
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw '*невидима робота під набором*flagged*Configuration.xml*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        (Get-Content -LiteralPath $f -Raw) | Should -BeLike '*правка агента*'
    }
    It 'gitlink під набором — зупинка, платформа не запускалась' {
        $repo = New-InvRepo 'inv-gitlink'
        $sha = (git -C $repo rev-parse HEAD).Trim()
        git -C $repo update-index --add --cacheinfo "160000,$sha,Alpha_SMB/cfe/src/sub"
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw '*невидима робота під набором*gitlink*sub*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }
    It 'вкладений git-репозиторій: <Case> — зупинка (nested-repo), тека ціла, платформа не запускалась' -ForEach @(
        @{ Case = 'невідстежуваний'; Rel = 'nest'; Ignore = $false }
        @{ Case = 'ігнорований під .git/info/exclude'; Rel = 'nest'; Ignore = $true }
        @{ Case = 'на глибині кількох тек'; Rel = 'a/b/c/nest'; Ignore = $false }
    ) {
        $repo = New-InvRepo ('inv-nested-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $nest = Join-Path $repo "Alpha_SMB/cfe/src/$Rel"
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        git -C $nest init -q
        Set-Content -LiteralPath (Join-Path $nest 'history.txt') -Value 'історія' -Encoding UTF8
        if ($Ignore) { Add-Content -LiteralPath (Join-Path $repo '.git/info/exclude') -Value "Alpha_SMB/cfe/src/$Rel/" -Encoding UTF8 }
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw "*невидима робота під набором*nested-repo*Alpha_SMB/cfe/src/$Rel*"
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $nest '.git' | Should -Exist
        Join-Path $nest 'history.txt' | Should -Exist
    }
    It 'junction під набором: зупинка (link) з рецептом, тека і ціль посилання цілі, платформа не запускалась' {
        $repo = New-InvRepo 'inv-junction'
        $target = Join-Path $TestDrive 'inv-junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'ціль' -Encoding UTF8
        $link = Join-Path $repo 'Alpha_SMB/cfe/src/lnk'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw '*невидима робота під набором*link*Alpha_SMB/cfe/src/lnk*прибрати посилання з набору*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
        Join-Path $target 'keep.txt' | Should -Exist
    }
    It 'symlink під набором: зупинка (link), платформа не запускалась' {
        $repo = New-InvRepo 'inv-symlink'
        $target = Join-Path $TestDrive 'inv-symlink-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $link = Join-Path $repo 'Alpha_SMB/cfe/src/slnk'
        try { New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because "symlink без прав адміністратора не створюється ($($_.Exception.Message)); вид link перевіряє junction вище (той самий атрибут ReparsePoint)"; return }
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw '*невидима робота під набором*link*Alpha_SMB/cfe/src/slnk*'
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
    }
    It 'контроль: набір без посилань — записів link немає' {
        $repo = New-InvRepo 'inv-nolink'
        @(Get-KitInvisibleWork -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' | Where-Object Kind -eq 'link') | Should -HaveCount 0
    }
    It 'П25 <Mode>: набір за junction назовні — зупинка (link), платформа не запускалась, вміст цілі цілий' -ForEach @(
        @{ Mode = 'e2' }
        @{ Mode = 'e1' }
    ) {
        $repo = New-InvRepo "inv-p25-$Mode"
        $target = Set-SetBehindLink -Repo $repo -Mode $Mode -Parent 'cfe' -Leaf 'src' -Tag 'canon'
        $before = Get-LinkTargetState $target
        $expected = if ($Mode -eq 'e2') { 'Alpha_SMB/cfe' } else { 'Alpha_SMB/cfe/src' }
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } |
            Should -Throw "*невидима робота під набором*link*$expected*"
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 0
        Get-LinkTargetState $target | Should -Be $before
        $before | Should -BeLike '*keep.txt=чужа ціль*'
    }
    It 'контроль: набір без .git усередині — зупинки немає' {
        $repo = New-InvRepo 'inv-nonested'
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/cfe/src/plain/dir') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/plain/dir/x.txt') -Value 'x' -Encoding UTF8
        @(Get-KitInvisibleWork -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' | Where-Object Kind -eq 'nested-repo') | Should -HaveCount 0
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'Alpha_SMB' -Apply $true } | Should -Not -Throw
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1
    }
    It 'контроль: ConfigDumpInfo.xml і .cf в Ext/ParentConfigurations — похідне, зупинки немає, платформа запущена' {
        $repo = New-InvRepo 'inv-derived'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/ConfigDumpInfo.xml') -Value '<x/>' -Encoding UTF8
        @(git -C $repo ls-files --others --ignored --exclude-standard -- Alpha_SMB/cf/src).Count | Should -BeGreaterOrEqual 3 -Because 'контроль має спиратись на справді ігноровані файли (.cf, позначка, ConfigDumpInfo.xml)'
        { Invoke-KitCanon -Context (Invoke-KitPreflight -RepoRoot $repo) -Source 'base' -Apply $true } | Should -Not -Throw
        Should -Invoke -ModuleName canon Invoke-V8Designer -Times 1
    }
}
