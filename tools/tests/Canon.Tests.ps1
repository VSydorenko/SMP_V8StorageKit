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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'" -WithHooks
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
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
        # Псуємо git-індекс ДО виклику canon — перший же git status (страховка C4, ще до
        # Remove-Item) падає, і Remove-Item не виконується взагалі: платформу не кличуть
        # ні разу, закомічений файл лишається на місці.
        Set-Content -LiteralPath (Join-Path $repo '.git/index') -Value 'зіпсовано навмисно для тесту' -Encoding UTF8

        { Invoke-KitCanon -Context $ctx -Source 'Alpha_SMB' -Apply $true } | Should -Throw '*git status*'
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
