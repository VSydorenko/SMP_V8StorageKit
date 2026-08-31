#Requires -Version 7
# storage-sync.ps1 — сам скрипт, не модуль, тож тестуємо, запускаючи його файл. Він
# обчислює $repoRoot від власного $PSScriptRoot, тому запобіжник чистоти робочої копії
# (git status -- $Product) неможливо перевірити на модульних функціях окремо — потрібен
# справжній git-репозиторій навколо файлу продукту. Щоб не чіпати справжній репозиторій
# цієї сесії, копіюємо скрипт і всі lib/*.psm1 у повністю ізольований фейковий репозиторій
# під $TestDrive і ініціалізуємо там окремий git.
#
# Запускаємо скрипт саме окремим процесом pwsh (а не викликом "&" у поточній сесії):
# storage-sync.ps1 імпортує lib/*.psm1 під тими самими іменами модулів (V8,
# StorageReport, Authors, SyncState), що вже завантажені реальними копіями з інших
# *.Tests.ps1 у тому самому прогоні Run-Tests.ps1. Виклик "&" у процесі додав би другий
# екземпляр кожного модуля під тим самим іменем і ламав би InModuleScope в V8.Tests.ps1
# помилкою "Multiple script or manifest modules named 'V8' are currently loaded" —
# перевірено емпірично. Окремий процес повністю ізолює простір модулів.
#
# Робоча тека скрипта — <fake-repo>/build/sync/<Product>, а не <product>/build/sync:
# в обох сценаріях нижче скрипт падає до створення цієї теки (запобіжник чистоти або
# перевірка storagePath), тому сам факт релокації workDir не міняє жодного з очікувань
# нижче. Але саме тому кожен It додатково перевіряє, що ця тека не з'явилась: без цього
# тести проходили б, навіть якби порядок перевірок у скрипті зламали так, що workDir
# створюється до запобіжника — оскільки негативна перевірка "*не чиста*" сама по собі
# такого регресу не ловить.

Describe 'storage-sync.ps1 -Apply: запобіжник чистоти робочої копії' {
    BeforeAll {
        $script:FakeRepo = Join-Path $TestDrive 'fake-repo'
        $toolsDir = Join-Path $script:FakeRepo 'tools'
        $libDir   = Join-Path $toolsDir 'lib'
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null

        $realTools = Resolve-Path "$PSScriptRoot/.."
        Copy-Item -LiteralPath (Join-Path $realTools 'storage-sync.ps1') -Destination (Join-Path $toolsDir 'storage-sync.ps1')
        Copy-Item -Path (Join-Path $realTools 'lib/*.psm1') -Destination $libDir

        Set-Content -LiteralPath (Join-Path $script:FakeRepo 'AUTHORS') -Encoding UTF8 -Value @(
            'gitbot=Test Bot <test@example.invalid>'
        )

        git -C $script:FakeRepo init -q
        git -C $script:FakeRepo config user.email 'test@example.invalid'
        git -C $script:FakeRepo config user.name 'Test Bot'
        git -C $script:FakeRepo config commit.gpgsign false

        $script:ScriptPath = Join-Path $toolsDir 'storage-sync.ps1'

        # Функція визначена всередині BeforeAll (а не прямо в тілі Describe), бо Pester
        # виконує тіло Describe лише на фазі discovery — оголошення поза BeforeAll/It не
        # переживає перехід до фази run і в It було б недоступне.
        function script:New-FakeProduct {
            param([Parameter(Mandatory)][string]$Name)

            $productPath = Join-Path $script:FakeRepo $Name
            New-Item -ItemType Directory -Path $productPath -Force | Out-Null
            [ordered]@{
                # Навмисно неіснуючий шлях: після запобіжника скрипт впаде на наступній
                # перевірці ("Каталог сховища не знайдено") — саме цього ми й хочемо для
                # сценарію "чиста копія", щоб довести, що впала не перевірка чистоти.
                storagePath       = (Join-Path $TestDrive 'no-such-storage')
                extensionName     = 'FAKE_EXT'
                lastSyncedVersion = 0
                sourcePath        = 'cfe/src'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $productPath 'storage.json') -Encoding UTF8

            $productPath
        }

        function script:Invoke-StorageSync {
            param([Parameter(Mandatory)][string]$Name)

            # -RepoRoot явно на фейковий репозиторій: типове значення '.' розв'язується
            # від робочої теки процесу, що запускає Pester (справжній репозиторій цієї
            # сесії), а не від $PSScriptRoot копії скрипта, як було до Task 4.
            $output = & pwsh -NoProfile -File $script:ScriptPath -Product $Name -Apply `
                -RepoRoot $script:FakeRepo 2>&1 |
                Out-String
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = $output
            }
        }
    }

    It 'на чистій копії не спрацьовує — скрипт падає далі, з іншої причини' {
        $name = 'Product_Clean'
        New-FakeProduct -Name $name | Out-Null
        git -C $script:FakeRepo add -A
        git -C $script:FakeRepo commit -q -m 'фікстура: чистий продукт'

        $result = Invoke-StorageSync -Name $name

        # Запобіжник не мав спрацювати на щойно закомічених джерелах без жодних слідів.
        # Скрипт все одно впаде (ненульовий код) — на "Каталог сховища не знайдено"
        # (storagePath вигаданий) — і це очікувано: перевіряємо саме запобіжник, а не
        # кінцевий результат прогону.
        $result.ExitCode | Should -Not -Be 0
        $result.Output   | Should -Not -BeLike '*не чиста*'

        # Скрипт падає на перевірці storagePath раніше, ніж встигає створити нову робочу
        # теку в корені репозиторію — тож її не мало лишитись.
        Join-Path $script:FakeRepo 'build/sync' $name | Should -Not -Exist
    }

    It 'v8project.local.yaml перевизначає storagePath зі storage.json (I5)' {
        # Обидва шляхи навмисно вигадані (не існують) — скрипт однаково впаде на
        # "Каталог сховища не знайдено", але яка саме адреса потрапить у повідомлення,
        # прямо доводить, який storagePath скрипт насправді використав: зі storage.json
        # (не мало б перевизначитись) чи з v8project.local.yaml (мало б).
        $name = 'Product_LocalOverride'
        $productPath = New-FakeProduct -Name $name
        $overridePath = Join-Path $TestDrive 'local-override-storage'
        Set-Content -LiteralPath (Join-Path $productPath 'v8project.local.yaml') -Encoding UTF8 -Value @(
            'infobase:'
            "  connection: 'File=""C:\bases\demo"";'"
            "storagePath: '$overridePath'"
        )
        git -C $script:FakeRepo add -A
        git -C $script:FakeRepo commit -q -m 'фікстура: продукт із локальним перевизначенням storagePath'

        $result = Invoke-StorageSync -Name $name

        $result.ExitCode | Should -Not -Be 0
        $result.Output   | Should -BeLike "*Каталог сховища не знайдено: $overridePath*"
        # storage.json несе окремий, теж вигаданий шлях — повідомлення не повинно
        # згадувати саме його, інакше перевизначення не спрацювало.
        $result.Output   | Should -Not -BeLike '*no-such-storage*'
    }

    It 'на брудній копії кидає саме повідомлення запобіжника' {
        $name = 'Product_Dirty'
        $productPath = New-FakeProduct -Name $name
        git -C $script:FakeRepo add -A
        git -C $script:FakeRepo commit -q -m 'фікстура: продукт перед забрудненням'

        # Незакомічений слід під теці продукту — так само, як лишає перерваний прогін -Apply
        # (видалення $sourceDir без наступного коміту, або коміт, що не завершився).
        Set-Content -LiteralPath (Join-Path $productPath 'stray.txt') -Value 'залишок перерваного прогону'

        $result = Invoke-StorageSync -Name $name

        $result.ExitCode | Should -Not -Be 0
        $result.Output   | Should -BeLike '*не чиста*'

        # Запобіжник спрацював до створення робочої теки в корені репозиторію — її не
        # мало з'явитись.
        Join-Path $script:FakeRepo 'build/sync' $name | Should -Not -Exist
    }
}

Describe 'storage-sync.ps1 -Apply: запобіжник, коли "git status" не може виконатись' {
    # Окремий, повністю ізольований фейковий репозиторій (а не спільний $script:FakeRepo
    # Describe вище) — сценарій навмисно псує .git/index, і жоден інший It не повинен
    # успадкувати пошкоджений індекс через порядок виконання.
    #
    # Повідомлення винятку читаємо не з консольного виводу дочірнього pwsh (2>&1 |
    # Out-String, як в Invoke-StorageSync вище), а через маленьку обгортку, що ловить
    # виняток сама і пише $_.Exception.Message у файл з явним -Encoding UTF8. Причина —
    # емпірично підтверджена на цій машині: [Console]::OutputEncoding дочірнього pwsh —
    # CP866 (DOS-кирилиця), яка не має символу "і" (U+0456) і мовчки підмінює його на "?"
    # у БУДЬ-ЯКОМУ тексті, що йде через консольний хост (Write-Host, неперехоплений throw)
    # — байдуже, чи це канал, чи "*> файл": і "Не вдалося перевірити" перетворюється на
    # "Не вдалося перев?рити". Пряме читання $_.Exception.Message в pscore обходить
    # консольний хост і зберігає текст без втрат.
    BeforeAll {
        $script:FailRepo = Join-Path $TestDrive 'fake-repo-git-status-fails'
        $toolsDir = Join-Path $script:FailRepo 'tools'
        $libDir   = Join-Path $toolsDir 'lib'
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null

        $realTools = Resolve-Path "$PSScriptRoot/.."
        Copy-Item -LiteralPath (Join-Path $realTools 'storage-sync.ps1') -Destination (Join-Path $toolsDir 'storage-sync.ps1')
        Copy-Item -Path (Join-Path $realTools 'lib/*.psm1') -Destination $libDir

        Set-Content -LiteralPath (Join-Path $script:FailRepo 'AUTHORS') -Encoding UTF8 -Value @(
            'gitbot=Test Bot <test@example.invalid>'
        )

        git -C $script:FailRepo init -q
        git -C $script:FailRepo config user.email 'test@example.invalid'
        git -C $script:FailRepo config user.name 'Test Bot'
        git -C $script:FailRepo config commit.gpgsign false

        $script:FailScriptPath = Join-Path $toolsDir 'storage-sync.ps1'
        $script:FailProductName = 'Product_GitStatusFails'
        $productPath = Join-Path $script:FailRepo $script:FailProductName
        New-Item -ItemType Directory -Path $productPath -Force | Out-Null
        [ordered]@{
            storagePath       = (Join-Path $TestDrive 'no-such-storage-git-status-fails')
            extensionName     = 'FAKE_EXT'
            lastSyncedVersion = 0
            sourcePath        = 'cfe/src'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $productPath 'storage.json') -Encoding UTF8

        git -C $script:FailRepo add -A
        git -C $script:FailRepo commit -q -m 'фікстура: продукт перед пошкодженням індексу'

        # Пошкоджений .git/index — найнадійніший спосіб відтворити реальний провал
        # "git status" без залежності від платформи чи сховища (той самий прийом, яким
        # тест M4 нижче відтворює провал "git add" через index.lock).
        Set-Content -LiteralPath (Join-Path $script:FailRepo '.git/index') -Encoding UTF8 `
            -Value 'зумисно пошкоджений індекс, не насправжній git index'

        $script:FailWrapperPath = Join-Path $TestDrive 'invoke-catching-git-status-fails.ps1'
        Set-Content -LiteralPath $script:FailWrapperPath -Encoding UTF8 -Value @'
param([string]$ScriptPath, [string]$ProductName, [string]$RepoRoot, [string]$ResultFile)
try {
    & $ScriptPath -Product $ProductName -Apply -RepoRoot $RepoRoot | Out-Null
    Set-Content -LiteralPath $ResultFile -Encoding UTF8 -Value 'THREW=0'
} catch {
    Set-Content -LiteralPath $ResultFile -Encoding UTF8 -Value ("THREW=1`nMESSAGE=" + $_.Exception.Message)
}
'@
        $script:FailResultFile = Join-Path $TestDrive 'result-git-status-fails.txt'
    }

    It 'зупиняється з поясненням "не вдалося перевірити", а не мовчки минає запобіжник' {
        & pwsh -NoProfile -File $script:FailWrapperPath -ScriptPath $script:FailScriptPath `
            -ProductName $script:FailProductName -RepoRoot $script:FailRepo -ResultFile $script:FailResultFile | Out-Null
        $result = Get-Content -LiteralPath $script:FailResultFile -Raw -Encoding UTF8

        $result | Should -BeLike 'THREW=1*'
        $result | Should -BeLike '*Не вдалося перевірити чистоту робочої копії*'
        # Не мало впасти на дружній гілці "не чиста" — це геть інша причина (реальний
        # брудний git status, а не провал самої команди git status).
        $result | Should -Not -BeLike '*не чиста*'

        # Запобіжник — перший у $Apply-блоці, до створення робочої теки в build/sync.
        Join-Path $script:FailRepo 'build/sync' $script:FailProductName | Should -Not -Exist
    }
}

Describe 'storage-sync.ps1 -Apply: запобіжник чужих застейджених змін в індексі' {
    # Так само ізольований репозиторій і той самий прийом читання винятку через файл з
    # явним -Encoding UTF8 (див. коментар у Describe вище) — повідомлення цього
    # запобіжника теж рясніє літерою "і".
    BeforeAll {
        $script:ForeignRepo = Join-Path $TestDrive 'fake-repo-foreign-staged'
        $toolsDir = Join-Path $script:ForeignRepo 'tools'
        $libDir   = Join-Path $toolsDir 'lib'
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null

        $realTools = Resolve-Path "$PSScriptRoot/.."
        Copy-Item -LiteralPath (Join-Path $realTools 'storage-sync.ps1') -Destination (Join-Path $toolsDir 'storage-sync.ps1')
        Copy-Item -Path (Join-Path $realTools 'lib/*.psm1') -Destination $libDir

        Set-Content -LiteralPath (Join-Path $script:ForeignRepo 'AUTHORS') -Encoding UTF8 -Value @(
            'gitbot=Test Bot <test@example.invalid>'
        )

        git -C $script:ForeignRepo init -q
        git -C $script:ForeignRepo config user.email 'test@example.invalid'
        git -C $script:ForeignRepo config user.name 'Test Bot'
        git -C $script:ForeignRepo config commit.gpgsign false

        $script:ForeignScriptPath = Join-Path $toolsDir 'storage-sync.ps1'
        $script:ForeignProductName = 'Product_ForeignStaged'
        $productPath = Join-Path $script:ForeignRepo $script:ForeignProductName
        New-Item -ItemType Directory -Path $productPath -Force | Out-Null
        [ordered]@{
            storagePath       = (Join-Path $TestDrive 'no-such-storage-foreign-staged')
            extensionName     = 'FAKE_EXT'
            lastSyncedVersion = 0
            sourcePath        = 'cfe/src'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $productPath 'storage.json') -Encoding UTF8

        git -C $script:ForeignRepo add -A
        git -C $script:ForeignRepo commit -q -m 'фікстура: продукт до появи чужих застейджених змін'

        # Чужий, ще не закомічений слід поза текою продукту — те, що лишив би розробник,
        # який почав "git add" щось своє в іншій частині репозиторію до запуску -Apply.
        New-Item -ItemType Directory -Path (Join-Path $script:ForeignRepo 'OtherStuff') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ForeignRepo 'OtherStuff/foreign.txt') -Value 'чужа робота, ще не закомічена'
        git -C $script:ForeignRepo add -- OtherStuff/foreign.txt

        $script:ForeignWrapperPath = Join-Path $TestDrive 'invoke-catching-foreign-staged.ps1'
        Set-Content -LiteralPath $script:ForeignWrapperPath -Encoding UTF8 -Value @'
param([string]$ScriptPath, [string]$ProductName, [string]$RepoRoot, [string]$ResultFile)
try {
    & $ScriptPath -Product $ProductName -Apply -RepoRoot $RepoRoot | Out-Null
    Set-Content -LiteralPath $ResultFile -Encoding UTF8 -Value 'THREW=0'
} catch {
    Set-Content -LiteralPath $ResultFile -Encoding UTF8 -Value ("THREW=1`nMESSAGE=" + $_.Exception.Message)
}
'@
        $script:ForeignResultFile = Join-Path $TestDrive 'result-foreign-staged.txt'
    }

    It 'зупиняється, а не комітить чужі застейджені зміни разом із версією сховища' {
        & pwsh -NoProfile -File $script:ForeignWrapperPath -ScriptPath $script:ForeignScriptPath `
            -ProductName $script:ForeignProductName -RepoRoot $script:ForeignRepo -ResultFile $script:ForeignResultFile | Out-Null
        $result = Get-Content -LiteralPath $script:ForeignResultFile -Raw -Encoding UTF8

        $result | Should -BeLike 'THREW=1*'
        $result | Should -BeLike '*У індексі репозиторію є застейджені зміни*'
        # Перша перевірка чистоти ("-- $Product") сама по собі не бачить чужих файлів —
        # переконуємось, що впала саме друга (без pathspec), а не перша.
        $result | Should -Not -BeLike '*не чиста*'
        # І не мало дійти до перевірки storagePath — друга перевірка зупиняє прогін
        # раніше, до створення робочої теки.
        $result | Should -Not -BeLike '*Каталог сховища не знайдено*'

        Join-Path $script:ForeignRepo 'build/sync' $script:ForeignProductName | Should -Not -Exist
    }
}

Describe 'storage-sync.ps1 -Apply: M4 — "git add" перевіряється так само, як "git commit"' {
    # Цикл по версіях (storage-sync.ps1:107+) вимагає реальної платформи й реального
    # сховища задовго до "git add -A -- $Product" — тому цей рядок не можна дійти
    # наскрізним прогоном скрипту в ізольованій фікстурі (як два тести вище). Замість
    # цього тест доводить саму передумову фіксу: що провалений "git add" насправді
    # виставляє ненульовий $LASTEXITCODE — той самий сигнал, який storage-sync.ps1:189
    # тепер перевіряє одразу після виклику (дзеркалячи вже наявну перевірку "git commit"
    # трьома рядками нижче). До фіксу цей код ігнорувався: --allow-empty на "git commit"
    # означає, що провалений "git add" усе одно завершується успішним порожнім комітом,
    # який просуває lastSyncedVersion, лишаючи джерела цієї версії поза git.
    It '"git add -A" завершується ненульовим кодом, коли git реально не може виконати команду' {
        $repo = Join-Path $TestDrive 'git-add-fail-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'Test Bot'

        New-Item -ItemType Directory -Path (Join-Path $repo 'Product') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Product/file.txt') -Value 'початковий вміст'
        git -C $repo add -A | Out-Null
        git -C $repo commit -q -m 'початковий коміт'

        Set-Content -LiteralPath (Join-Path $repo 'Product/file.txt') -Value 'зміна, яку не вдасться заіндексувати'

        # index.lock, що лишився від "завислого" git-процесу, — найнадійніший спосіб
        # відтворити реальний провал "git add" без залежності від платформи чи сховища.
        $lockFile = Join-Path $repo '.git/index.lock'
        Set-Content -LiteralPath $lockFile -Value ''
        try {
            git -C $repo add -A -- Product 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
        finally {
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'storage-sync.ps1 -Apply: фільтр попереджень CRLF/LF на "git add"' {
    # Ці два тести старші за винесення регекса в окремий модуль. Раніше $crlfEolWarning
    # жив просто у storage-sync.ps1, і зразок дублювався тут, бо сам цикл по версіях
    # (де стояв фільтр) недосяжний без реальної платформи й сховища (той самий аргумент,
    # що й у Describe M4 вище). Тепер зразок живе в tools/lib/GitOutput.psm1
    # (Split-GitEolNoise), а tools/tests/GitOutput.Tests.ps1 виконує саме цю
    # production-функцію напряму — це і є тест, якого вимагає docs/follow-ups.md §4.
    # Копія нижче лишається свідомо, але вона більше не дзеркалить storage-sync.ps1 і
    # нічого не охороняє: якщо зразок у модулі зміниться, ці два тести й далі
    # проходитимуть проти застарілої копії. Це відомий і прийнятий борг, а не запобіжник.
    # Тест доводить дві речі порізно: перша It — що під реальною політикою
    # ".gitattributes" ("* text=auto eol=crlf", яка й лишає цю поведінку) "git add"
    # насправді видає попередження саме такої форми, а не вигаданої; друга It — що
    # фільтр (сам regex) прибирає лише цю форму й пропускає будь-що інше, не перевіряючи
    # його вміст.
    BeforeAll {
        # Regex-літерал — свідома локальна копія, не імпорт. Зразок, з яким вона мала б
        # звірятись, раніше жив у storage-sync.ps1, тепер живе в tools/lib/GitOutput.psm1
        # (Split-GitEolNoise). Копія не синхронізується автоматично: якщо зразок у
        # модулі зміниться, тест-намір (a) чи (b) нижче розійдеться з реальною
        # поведінкою Split-GitEolNoise, і жоден із цих тестів це не зловить.
        $script:CrlfEolWarning = "^warning: in the working copy of '.+', (LF will be replaced by CRLF|CRLF will be replaced by LF) the next time Git touches it$"
    }

    It 'реальний "git add" під політикою eol=crlf видає попередження саме цієї форми' {
        $repo = Join-Path $TestDrive 'git-add-crlf-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'Test Bot'

        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Encoding UTF8 -Value '* text=auto eol=crlf'
        # LF, без BOM — саме той стан робочої копії, на якому "* text=auto eol=crlf"
        # друкує попередження на "git add" (докладніше — templates/gitattributes і
        # docs/storage-and-git.md, сценарій "~900 файлів").
        [System.IO.File]::WriteAllText((Join-Path $repo 'f.xml'), "<a/>`n<b/>`n", [System.Text.UTF8Encoding]::new($false))

        $addOutput = git -C $repo add -A 2>&1
        $LASTEXITCODE | Should -Be 0

        $addOutput.Count | Should -BeGreaterThan 0
        foreach ($line in $addOutput) {
            $line.ToString() | Should -Match $script:CrlfEolWarning
        }
    }

    It 'фільтр прибирає лише відому форму eol-попередження й лишає будь-що інше видимим' {
        $repo = Join-Path $TestDrive 'git-add-crlf-repo-2'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'Test Bot'

        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Encoding UTF8 -Value '* text=auto eol=crlf'
        [System.IO.File]::WriteAllText((Join-Path $repo 'f.xml'), "<a/>`n<b/>`n", [System.Text.UTF8Encoding]::new($false))

        $addOutput = git -C $repo add -A 2>&1
        $LASTEXITCODE | Should -Be 0

        # Непередбачене попередження, дописане поруч із реальним виводом "git add" —
        # моделює те, чого сам regex не смів би прибрати.
        $unexpected = 'warning: something totally unrelated happened'
        $combined = @($addOutput) + @($unexpected)

        # @(...) навколо Where-Object — інакше рівно один елемент, що лишився після
        # фільтрації, розгортається PowerShell у скаляр (голий рядок), і "$kept[0]"
        # індексує символи цього рядка, а не елемент колекції (той самий гачок, від
        # якого storage-sync.ps1 захищається довкола "Select-Object -First" вище).
        $kept = @($combined | Where-Object { $_.ToString() -notmatch $script:CrlfEolWarning })

        $kept.Count | Should -Be 1
        $kept[0].ToString() | Should -Be $unexpected
    }
}
