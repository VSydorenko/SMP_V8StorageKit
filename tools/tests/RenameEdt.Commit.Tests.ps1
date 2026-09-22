#Requires -Version 7
<#
Тести Step 3 і Step 3а (B6 Task 3, §9.2) — мали впасти ДО commands/rename-edt.psm1: команди
не існувало, kit.ps1 відповідав "Невідома команда 'rename-edt'". Ризик задачі — `властивість
безпеки` (task-3-brief.md): команда переписує чуже дерево через git mv. Дві властивості, які
рев'ю перевіряє окремо:
  1. Жоден файл не видаляється без показу людині (Unmapped — повний перелік, видалення лише
     під -Apply).
  2. Колізія двох EDT-файлів в один Designer-шлях ЗУПИНЯЄ до першого git mv — дерево
     лишається незміненим (перевіряється через git status/rev-parse HEAD, а не лише текст
     винятку).

Раунд 1 рев'ю (task-3-findings-round1.md) додав: C-A (git rm як pathspec), C-B (ігноровані/
невідстежувані файли в дереві джерела), I-E (rollback через try/catch + git reset --hard),
S-I/S-J (команда більше не створює тег і не пише файл усередині репозиторію), M-7 (Unmapped
друкується ДО зупинки на колізіях), I-H (тести раніше доводили текст коду, не властивість —
переписані нижче, з поясненням у кожному місці, що саме змінилось і чому).

Мутаційна перевірка — лише на КОПІЇ дерева в $TestDrive (New-KitFakeRepo щоразу створює нову
ізольовану теку); жоден живий репозиторій `R:\github` не читається й не пишеться.

Task 8 ("Швидкість набору тестів"): цей файл — перша половина колишнього
RenameEdt.Tests.ps1 (перший Describe, 16 It поза Context'ом Step 3а; сам Context —
RenameEdt.Rollback.Tests.ps1). Спільний BeforeAll винесено в fixtures/RenameEdtSetup.ps1.
#>
Describe 'kit rename-edt — коміт перейменування EDT -> Designer (§9.2, властивість безпеки)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/RenameEdtSetup.ps1') }

    It 'позитивний шлях: git mv (R, не D+A) на КОЖНОМУ рядку diff-tree, git log --follow безперервний, байти вмісту не чіпаються' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'positive') -WithGitattributes
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $oldPath = 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl'
        $newPath = 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения/Ext/Module.bsl'
        (Join-Path $repo $newPath) | Should -Exist
        (Join-Path $repo $oldPath) | Should -Not -Exist
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения.xml') | Should -Exist

        # Знахідка 4 (рев'ю раунду 3): мутант "вирізати виклик Remove-KitEmptyDirectory"
        # виживав на базовому наборі — обидва файли переїхали з
        # 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/', тека мала стати ПОРОЖНЬОЮ і бути
        # прибраною; без цієї перевірки жоден тест не бачив різниці.
        (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения') | Should -Not -Exist -Because 'Remove-KitEmptyDirectory мала прибрати тепер-порожню теку після успішного коміту'

        # I-H.1: перевірка статусу — R на КОЖНОМУ рядку (?m), не лише в першому рядку
        # багаторядкового виводу. Раніше `-Not -Match '^[AD]\t'` без (?m) перевіряв фактично
        # тільки перший рядок склеєного багаторядкового $diffTree.
        $sha = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()
        $diffTree = (Invoke-TestGit -Repo $repo -GitArgs @('-c', 'core.quotepath=false', 'diff-tree', '--no-commit-id', '--name-status', '-r', '-M', $sha)) -join "`n"
        $diffTree | Should -Match ([regex]::Escape("R100`t$oldPath`t$newPath"))
        $diffTree | Should -Not -Match '(?m)^[AD]\t'

        # git log --follow бачить історію через межу перейменування (спайк 2026-09-09).
        $follow = @(Invoke-TestGit -Repo $repo -GitArgs @('log', '--follow', '--oneline', '--', $newPath))
        $follow.Count | Should -BeGreaterThan 1 -Because 'має включати і коміт перейменування, і попередній gitsync-коміт'

        # I-H.1: байти вмісту побайтово ті самі — властивість, яку diff-tree/--follow НЕ доводять
        # (git рівно так само показав би R100 і для git mv, і для "прочитати+переписати", доки
        # байти лишаються тими самими; discriminating-властивість — саме побайтова точність:
        # текстовий конвеєр PowerShell спотворив би невалідний UTF-8 вище, чиста файлова
        # операція git mv — ні).
        [System.IO.File]::ReadAllBytes((Join-Path $repo $newPath)) | Should -Be $originalBytes

        # S-I (рев'ю раунду 1): команда БІЛЬШЕ НЕ створює тег межі сама — це крок 2 онбордингу.
        (Invoke-TestGit -Repo $repo -GitArgs @('tag', '--list', 'legacy/gitsync-*')) | Should -BeNullOrEmpty

        # S-J: файл повідомлення коміту йде через System.IO.Path]::GetTempFileName(), а не
        # build/... усередині репозиторію. Знахідка 4 (рев'ю раунду 3): ЦЯ асерція нижче НЕ
        # може впасти в принципі — `finally` прибирає файл незалежно від того, де його
        # створено, тож перевірка "чи лишився файл із такою назвою" зелена і при старій, і
        # при новій поведінці. Лишаю її як зручний smoke-check (файлу справді нема), а
        # властивість "створюється ПОЗА репозиторієм" (а не просто "прибирається після")
        # доводить окремий мутаційно-чутливий мок-тест нижче ("S-J: шлях файла повідомлення").
        @(Get-ChildItem -LiteralPath $repo -Recurse -File -Filter 'rename-edt-commit-message.txt' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'I-H.2: Unmapped друкує ПОВНИЙ перелік (два файли, не лише перший) без -Apply' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmapped-preview') -WithGitattributes
        $dir = Join-Path $repo 'Alpha_SMB/src'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'ConfigDumpInfo.xml') -Value 'x' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'DumpFilesIndex.txt') -Value 'y' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: два службові файли') | Out-Null

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*ConfigDumpInfo.xml*'
        $r.Output | Should -BeLike '*DumpFilesIndex.txt*'
        $r.Output | Should -BeLike '*попередній перегляд*'
        (Join-Path $dir 'ConfigDumpInfo.xml') | Should -Exist
        (Join-Path $dir 'DumpFilesIndex.txt') | Should -Exist
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'колізія (два EDT-шляхи в один Designer-шлях) — зупинка ДО будь-якого git mv; НІЧОГО не змінюється, включно з неколізійним файлом (I-H.3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'collision') -WithGitattributes
        $collisionDir = Join-Path $repo 'Alpha_SMB/src/CommonTemplates/Мак1'
        New-Item -ItemType Directory -Force -Path $collisionDir | Out-Null
        Set-Content -LiteralPath (Join-Path $collisionDir 'Template.mxlx') -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $collisionDir 'Template.dcs') -Value 'b' -Encoding UTF8
        # I-H.3: третій, НЕколізійний файл у ТІЙ САМІЙ фікстурі — без нього Moves був би
        # порожній (в колізії обидва джерела виключені з Moves), і запобіжник, перенесений у
        # кінець команди, однаково нічого не встиг би зіпсувати: тест зелений навіть на
        # мутанті "перевіряти колізії ПІСЛЯ циклу git mv". З цим файлом такий мутант рухав би
        # РЕАЛЬНИЙ файл ДО того, як дійде до перевірки колізій, і тест нижче це зловить.
        $okDir = Join-Path $repo 'Alpha_SMB/src/Catalogs/ОК'
        New-Item -ItemType Directory -Force -Path $okDir | Out-Null
        Set-Content -LiteralPath (Join-Path $okDir 'ОК.mdo') -Value 'd' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: колізія макета + звичайний об''єкт') | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*олізі*'

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before -Because 'жодного коміту не мало створитись'
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty -Because 'жодного git mv не мало відбутись — і для колізійних, і для звичайних файлів'
        (Join-Path $collisionDir 'Template.mxlx') | Should -Exist
        (Join-Path $collisionDir 'Template.dcs') | Should -Exist
        (Join-Path $okDir 'ОК.mdo') | Should -Exist -Because 'неколізійний файл теж не мав зрушити з місця'
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs/ОК.xml') | Should -Not -Exist
    }

    It 'M-7: Unmapped друкується ПОВНИМ переліком навіть коли є колізії (не лише лічильник, не після throw)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmapped-plus-collision') -WithGitattributes
        $collisionDir = Join-Path $repo 'Alpha_SMB/src/CommonTemplates/Мак1'
        New-Item -ItemType Directory -Force -Path $collisionDir | Out-Null
        Set-Content -LiteralPath (Join-Path $collisionDir 'Template.mxlx') -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $collisionDir 'Template.dcs') -Value 'b' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/src/ConfigDumpInfo.xml') -Value 'x' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: колізія + службовий файл') | Out-Null

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*ConfigDumpInfo.xml*' -Because 'Unmapped друкується ДО зупинки на колізіях, не приховується нею'
    }

    It 'брудна робоча копія — зупинка до будь-якої зміни (успадковано з repo-migration, §9.2)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dirty') -WithGitattributes
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
        Add-Content -LiteralPath (Join-Path $repo 'AUTHORS') -Value 'ще один рядок' -Encoding UTF8

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*не чиста*'
        (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist
    }

    It 'знахідка 3 (рев''ю раунду 3): -SourceRelPath ''.'' — Assert-SafeWorkPath зупиняє ДО будь-якого git-виклику' {
        # PathSafety.psm1 — "спільний запобіжник перед КОЖНИМ рекурсивним видаленням у tools/",
        # і його кличуть усі інші такі місця (GitMerge, StorageBranch, StorageImprint,
        # StoragePlatform, TreeCompare, V8, canon, dump, provision, sync, verify).
        # Remove-KitEmptyDirectory теж рекурсивно видаляє в ЧУЖОМУ репозиторії — без цього
        # запобіжника -SourceRelPath '.' вивів би обхід у корінь репозиторію.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsafe-path') -WithGitattributes
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', '.', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*підтекою*'

        # Перевірка стану, не лише тексту помилки: зупинка мала статись ДО першого git-виклику
        # запобіжників — HEAD і статус репозиторію лишились точно такими, як були.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'M-9 (рев''ю раунду 3, мутаційно): прихований файл усередині дерева джерела не випадає з переліку мовчки' {
        # Мутант "вирізати -Force з обходу" виживав на базовому наборі — жоден тест не мав
        # прихованого файлу. Мета -Force саме в тому, щоб перелік Unmapped/Unresolved/Moves
        # лишався ПОВНИМ описом дерева (властивість "показане = видалене" спирається на повноту
        # переліку так само, як на сам факт непоказаного видалення).
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'hidden-file') -WithGitattributes
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
        $hiddenDir = Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения'
        $hiddenFile = Join-Path $hiddenDir 'Прихований.невідоме'
        Set-Content -LiteralPath $hiddenFile -Value 'x' -Encoding UTF8
        (Get-Item -LiteralPath $hiddenFile -Force).Attributes = [System.IO.FileAttributes]::Hidden
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: доданий прихований файл') | Out-Null

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*Прихований.невідоме*' -Because 'прихований файл мав з''явитись у переліку (Unresolved — невідоме розширення), а не випасти мовчки'
    }

    It 'C-B: ігнорований файл усередині дерева джерела — зупинка ДО git rm/mv, а не збій посеред циклу' {
        # Живий сценарій (task-3-findings-round1.md, C-B): SMB_ukr_vendor і сам templates/gitignore
        # kit ігнорують саме ConfigDumpInfo.xml/DumpFilesIndex.txt всередині src/. git status
        # (запобіжник 1) "чистий" — ігнороване НЕ входить у status; план (Get-ChildItem, диск)
        # усе одно бачить файл; git rm/mv працюють лише з відстеженим. Різниця між git-баченням
        # і диском мала падати ПОСЕРЕД циклу — тепер має зупинити ДО нього.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ignored') -WithGitattributes
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'Alpha_SMB/src/ConfigDumpInfo.xml' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '.gitignore') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', '.gitignore для ConfigDumpInfo.xml') | Out-Null
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
        # Ігнорований файл лишається НЕВІДСТЕЖУВАНИМ навмисно — не git add.
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/src/ConfigDumpInfo.xml') -Value 'ignored' -Encoding UTF8
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty -Because 'ігнороване не входить у git status — саме тому дефект був невидимий запобіжнику 1'
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*не відстежує*'
        $r.Output | Should -BeLike '*ConfigDumpInfo.xml*'

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
        (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist -Because 'жоден git mv не мав відбутись'
    }

    It 'I-E: git mv на наявний файл посеред циклу — автоматичний адресний відкіт, а не напівстан' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rollback') -WithGitattributes
        # Два звичайні об'єкти, що сортуються як A1 (раніше) < A2 (пізніше) — цикл git mv
        # обробляє їх у такому порядку. Ціль A2 навмисно вже існує ЗАЗДАЛЕГІДЬ як інший
        # відстежений файл — git mv на наявний файл провалюється (fatal: destination
        # already exists) ПІСЛЯ того, як A1 уже переїхав.
        $dir = Join-Path $repo 'Alpha_SMB/src/Catalogs'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'A1') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'A2') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'A1/A1.mdo') -Value 'один' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'A2/A2.mdo') -Value 'два' -Encoding UTF8
        $conflictDir = Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs'
        New-Item -ItemType Directory -Force -Path $conflictDir | Out-Null
        Set-Content -LiteralPath (Join-Path $conflictDir 'A2.xml') -Value 'вже є' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: A1/A2 + конфліктна ціль A2.xml') | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*відкочено*'

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before -Because 'коміту не було — відкіт повертає рівно стартовий стан'
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty -Because 'адресний відкіт мав прибрати навіть УЖЕ виконаний git mv A1'
        (Join-Path $dir 'A1/A1.mdo') | Should -Exist -Because 'A1 переїхав першим, а відкіт мав повернути його назад'
        (Join-Path $conflictDir 'A1.xml') | Should -Not -Exist
        (Join-Path $conflictDir 'A2.xml') | Should -Exist -Because 'початковий (конфліктний) вміст A2.xml має лишитись як був'
    }

    # Знахідка 1 (рев'ю раунду 3) — окрема перевірка ОБСЯГУ відновлення, доповнена нижче в
    # окремому Describe (мок git-шару): наскрізний тест вище (I-E) доводить, що в межах
    # -SourceRelPath/-TargetRoot реальний git відновлює все правильно; те, що САМЕ ЖОДЕН
    # git-виклик команди не є "reset --hard" на весь репозиторій і що виклики відновлення
    # адресовані лише двом цим шляхам — доводить мок-тест нижче (потребує перехоплення
    # АРГУМЕНТІВ git-викликів, чого наскрізний прогін через підпроцес kit.ps1 не дає).
    #
    # Раунд 4, пункт C: тут раніше стояв коментар, що тест на СТАН ДИСКУ під час "правки
    # людини під час проходу" написати не вдається — правка файлом упирається в запобіжник
    # чистоти. Це СПРОСТОВАНО й прибрано: правку робить .git/hooks/pre-commit ВСЕРЕДИНІ вікна
    # мутації (Add-KitDuringPassPreCommitHook вище), і той самий хук форсує падіння коміту.
    # Два тести нижче написані саме так.

    It 'знахідка A (рев''ю раунду 4): ЖИВА форма першої міграції — дерева призначення в HEAD НЕМАЄ; падіння коміту відкочується, правка людини поза піддеревами ціла' {
        # Фікстура БЕЗ дерев джерела (-NoSourceTrees, знахідка D): рівно та форма, у якій
        # rename-edt працює на парку — -TargetRoot створює сама команда, тож у $preHeadSha
        # його немає. Старий безумовний `git checkout <sha> -- <src> <target>` тут відмовляв
        # АТОМАРНО ("pathspec did not match any file(s) known to git") і не відновлював нічого,
        # лишаючи репозиторій із застейдженими перейменуваннями (на SMB_ukr_vendor — 17 366).
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live-rollback') -WithGitattributes -NoSourceTrees
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'початковий рядок' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', 'README.md') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'README поза обома піддеревами') | Out-Null
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'

        # Передумова тесту, а не декорація: дерева призначення в HEAD справді немає.
        @(Invoke-TestGit -Repo $repo -GitArgs @('ls-tree', '-r', '--name-only', 'HEAD', '--', 'Alpha_SMB/cfe/src')).Count |
            Should -Be 0 -Because 'саме цю форму стара фікстура ніколи не створювала'

        Add-KitDuringPassPreCommitHook -Repo $repo -DuringPassScript @("printf '%s\n' 'правка людини під час проходу' >> README.md") | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*відкочено*' -Because "відкіт мусить ВІДБУТИСЬ, а не повідомити 'не вдався повністю': $($r.Output)"

        # СТАН ДИСКУ, не текст повідомлення.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        $status = @(Get-TestGitStatus -Repo $repo)
        $status.Count | Should -Be 1 -Because "після відкоту в статусі мусить лишитись РІВНО правка людини: $($status -join ' | ')"
        $status[0] | Should -Be ' M README.md' -Because 'жодного застейдженого перейменування (R) чи видалення (D) лишитись не мало'

        (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/ОбщегоНазначения.mdo') | Should -Exist
        [System.IO.File]::ReadAllBytes((Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl')) | Should -Be $originalBytes
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules') | Should -Not -Exist -Because 'дерево призначення, якого до запуску не було, відкіт мусить ПРИБРАТИ, а не відновлювати'
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw) | Should -BeLike '*правка людини під час проходу*' -Because 'правка поза обома піддеревами — не справа цієї команди'
    }

    It 'знахідка B (рев''ю раунду 4): файл, який людина git add-нула в піддерево призначення під час проходу, відкіт НЕ видаляє' {
        # Тут дерево призначення в HEAD Є (типова фікстура) — саме в цій формі старий відкіт
        # доходив до прибирання й видаляв "усе, чого не було в SHA" через git diff
        # --diff-filter=A. Під той опис потрапляв і чужий застейджений файл: git rm -f стирав
        # його з диска Й з індексу, поки команда рапортувала "решта репозиторію не зачеплена".
        #
        # I-5 (фінальне рев'ю блоку) переписав механіку стенду, не властивість: чужий файл
        # СТЕЙДЖИТЬСЯ хуком post-index-change, тобто в СПРАВЖНІЙ індекс (як його справді
        # застейджила б людина), а pre-commit лишився рівно тим, чим він тут і був, — способом
        # завалити коміт і викликати відкіт. Робити обидві справи одним pre-commit більше не
        # можна: після переходу коміту на `--only` git дає pre-commit ТИМЧАСОВИЙ індекс
        # (GIT_INDEX_FILE), тож `git add` усередині нього не стейджить нічого в основний індекс —
        # файл лишався б невідстежуваним, і приймальна перевірка відкоту чесно не бачила б
        # розбіжності, якої в індексі й немає. Стенд моделював би не той стан, що описано вище.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-file-in-target') -WithGitattributes
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
        $humanRel = 'Alpha_SMB/cfe/src/МійВласнийФайл.txt'
        Add-KitOccupyTargetHook -Repo $repo -OccupyRel $humanRel -Content 'це файл людини, не kit'
        Add-KitDuringPassPreCommitHook -Repo $repo -DuringPassScript @('true') | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0

        (Join-Path $repo $humanRel) | Should -Exist -Because 'команда прибирає рівно власні ВИКОНАНІ цілі, а чужого файлу не знає й не чіпає'
        (Get-Content -LiteralPath (Join-Path $repo $humanRel) -Raw) | Should -BeLike '*це файл людини*'
        $r.Output | Should -BeLike '*розбіжність*' -Because 'чужий файл у піддереві — саме та розбіжність, про яку треба ЧЕСНО доповісти, а не прибрати її видаленням'

        # Власне перейменування все одно відкочено: джерело на місці, цілі kit прибрані.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        [System.IO.File]::ReadAllBytes((Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl')) | Should -Be $originalBytes
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения.xml') | Should -Not -Exist
    }

    It 'знахідка 1 (рев''ю раунду 5): чужий файл за адресою НЕВИКОНАНОГО перейменування переживає відкіт, виконані цілі — прибрані' {
        # Найважливіша форма, бо вона ж і ВИКЛИКАЄ відкіт: `git mv` падає на "destination exists"
        # рівно тоді, коли хтось зайняв цільовий шлях. Прибирання по ВСЬОМУ $plan.Moves знищувало
        # б цей чужий застейджений файл із диска й індексу — тобто відкіт руйнував би саме те,
        # через що його й покликали.
        #
        # Чужий файл з'являється ПІД ЧАС проходу (хук post-index-change на першому ж git mv):
        # якби він існував до запуску, команда не почалась би — запобіжник 1/4 бачить і
        # застейджене, і невідстежуване.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'occupied-target') -WithGitattributes -NoSourceTrees
        $catalogs = Join-Path $repo 'Alpha_SMB/src/Catalogs'
        foreach ($objectName in 'A1', 'A2', 'A3') {
            New-Item -ItemType Directory -Force -Path (Join-Path $catalogs $objectName) | Out-Null
            Set-Content -LiteralPath (Join-Path $catalogs "$objectName/$objectName.mdo") -Value $objectName -Encoding UTF8
        }
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: три об''єкти') | Out-Null
        $occupiedRel = 'Alpha_SMB/cfe/src/Catalogs/A3.xml'
        Add-KitOccupyTargetHook -Repo $repo -OccupyRel $occupiedRel -Content 'це файл людини, не kit'
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*destination exists*' -Because "падіння мало статись саме на зайнятій цілі: $($r.Output)"

        # ГОЛОВНЕ: файл, якого команда не створювала, лишається і на диску, і в індексі.
        (Join-Path $repo $occupiedRel) | Should -Exist -Because 'до перейменування A3 цикл НЕ ДІЙШОВ — цей файл створила не команда'
        (Get-Content -LiteralPath (Join-Path $repo $occupiedRel) -Raw) | Should -BeLike '*це файл людини*'
        @(Invoke-TestGit -Repo $repo -GitArgs @('ls-files', '--', $occupiedRel)).Count | Should -Be 1 -Because 'застейджений чужий файл не мав зникнути з індексу'

        # Виконані перейменування (A1, A2) — навпаки, прибрані, а джерело повернуто.
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs/A1.xml') | Should -Not -Exist
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs/A2.xml') | Should -Not -Exist
        foreach ($objectName in 'A1', 'A2', 'A3') {
            (Join-Path $catalogs "$objectName/$objectName.mdo") | Should -Exist -Because 'джерело мало повернутись цілком'
        }
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
    }

    It 'знахідка 2 (рев''ю раунду 5): рецепт виконано зі стану, де АВТОМАТИЧНИЙ відкіт джерело НЕ відновив — і саме рецепт його повертає' {
        # Попередній тест рецепту виконував його там, де автоматичний відкіт уже все відновив:
        # будь-який checkout, що не падає, давав той самий стан, і підміна рядка рецепту на
        # завідомо неправильний лишала 114/114 зелених. Тут автоматичний відкіт ЗЛАМАНО
        # (обов'язковий smudge-фільтр, поставлений усередині вікна мутації), джерело лишається
        # переміщеним — тож рецепт має що робити, і неправильний рецепт цього не зробить.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'recipe-from-broken') -WithGitattributes -NoSourceTrees
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
        Add-KitBreakRestoreHook -Repo $repo -SourceRelPath 'Alpha_SMB/src'
        Add-KitDuringPassPreCommitHook -Repo $repo -DuringPassScript @('true')
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()
        $moduleRel = 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*не вдався повністю*' -Because "автоматичний відкіт мав упасти на smudge-фільтрі: $($r.Output)"

        # ПЕРЕДУМОВА тесту: джерело справді НЕ відновлене — інакше рецепт нічого не доводить.
        (Join-Path $repo $moduleRel) | Should -Not -Exist -Because 'git checkout відкоту впав, тож джерело лишилось переміщеним'

        Repair-KitBrokenRestore -Repo $repo
        $recipe = @(Invoke-KitRecipeFromOutput -Output $r.Output -Repo $repo)

        # Асерція, прив'язана до РЯДКА РЕЦЕПТУ (а не до будь-якого тексту у виводі): підміна
        # шляху в рецепті ламає і цей рядок, і стан нижче.
        $recipe.Count | Should -Be 3 -Because "рецепт — рівно три команди по порядку: $($recipe -join ' | ')"
        $recipe[0] | Should -Be "git rm -r -f --ignore-unmatch -- ':(literal)Alpha_SMB/cfe/src'"
        $recipe[1] | Should -Be "git checkout $before -- Alpha_SMB/src"
        $recipe[2] | Should -Be 'git status'

        # Стан після рецепту — рівно той, що був до запуску.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        @(Get-TestGitStatus -Repo $repo).Count | Should -Be 0 -Because 'рецепт мусить закрити ВСІ застейджені зміни, а не лише показати їх'
        [System.IO.File]::ReadAllBytes((Join-Path $repo $moduleRel)) | Should -Be $originalBytes
        @(Get-ChildItem -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe') -Recurse -File -Force -ErrorAction SilentlyContinue).Count |
            Should -Be 0 -Because 'дерева призначення до запуску не існувало — після рецепту в ньому не має лишитись жодного файлу'
    }

    It 'знахідка 3 (рев''ю раунду 5): у формі «ціль у SHA БУЛА» рецепт теж відновлює стан — і прибирання в ньому обов''язкове' {
        # Форма повторного прогону й міграції в наперед закомічене дерево. Старий рецепт для неї
        # складався з самого checkout — а checkout нічого не видаляє, тож усе, що з'явилось у
        # піддереві призначення й чого немає в SHA, лишалось 'A' в індексі й на диску: підказана
        # команда стан НЕ відновлювала. Тут це відтворено чужим файлом за адресою невиконаного
        # перейменування — після самого лише checkout він лишився б застейдженим.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'recipe-target-in-sha') -WithGitattributes
        $catalogs = Join-Path $repo 'Alpha_SMB/src/Catalogs'
        foreach ($objectName in 'A1', 'A2') {
            New-Item -ItemType Directory -Force -Path (Join-Path $catalogs $objectName) | Out-Null
            Set-Content -LiteralPath (Join-Path $catalogs "$objectName/$objectName.mdo") -Value $objectName -Encoding UTF8
        }
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: два об''єкти') | Out-Null
        $occupiedRel = 'Alpha_SMB/cfe/src/Catalogs/A2.xml'
        Add-KitOccupyTargetHook -Repo $repo -OccupyRel $occupiedRel -Content 'це файл людини, не kit'
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()
        $configRel = 'Alpha_SMB/cfe/src/Configuration.xml'
        (Join-Path $repo $configRel) | Should -Exist -Because 'передумова форми: дерево призначення в HEAD Є'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*розбіжність*'
        (Join-Path $repo $occupiedRel) | Should -Exist -Because 'чужий файл переживає автоматичний відкіт (знахідка 1) — і саме він робить стан невідновленим'

        $recipe = @(Invoke-KitRecipeFromOutput -Output $r.Output -Repo $repo)
        $recipe.Count | Should -Be 3
        $recipe[0] | Should -Be "git rm -r -f --ignore-unmatch -- ':(literal)Alpha_SMB/cfe/src'" -Because 'без прибирання рецепт у цій формі стан НЕ відновлює — checkout нічого не видаляє'
        $recipe[1] | Should -Be "git checkout $before -- Alpha_SMB/src Alpha_SMB/cfe/src" -Because 'обидва шляхи є в SHA, тож обидва відновлюються'
        $r.Output | Should -BeLike '*спершу подивіться git status*' -Because 'попередження про прибирання чужого мусить друкуватись і в цій формі'

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        @(Get-TestGitStatus -Repo $repo).Count | Should -Be 0 -Because 'рецепт мусить повернути стан, а не лише показати діагностику'
        (Join-Path $repo $configRel) | Should -Exist -Because 'файл, що БУВ у SHA, рецепт прибрав першою командою й повернув другою'
        foreach ($objectName in 'A1', 'A2') {
            (Join-Path $catalogs "$objectName/$objectName.mdo") | Should -Exist
        }
    }

    It 'знахідка D (рев''ю раунду 4): у ЖИВІЙ формі (дерева призначення в HEAD немає) успішний прохід теж працює' {
        # Дзеркало тесту вище на щасливому шляху: без нього "-NoSourceTrees" перевіряло б лише
        # аварійну гілку, і мутант "команда взагалі не вміє цілитись у неіснуюче дерево"
        # лишився б непоміченим.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live-positive') -WithGitattributes -NoSourceTrees
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения.xml') | Should -Exist
        [System.IO.File]::ReadAllBytes((Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения/Ext/Module.bsl')) | Should -Be $originalBytes
        @(Get-TestGitStatus -Repo $repo).Count | Should -Be 0
    }

    It 'I-5 (фінальне рев''ю): УСПІШНИЙ прохід не втягує в коміт чужу ЗАСТЕЙДЖЕНУ правку' {
        # Властивість: коміт перейменування містить РІВНО два керовані піддерева, і чужа робота,
        # застейджена людиною ПІД ЧАС 22-хвилинного проходу, лишається незакоміченою.
        #
        # Попередня версія цього тесту (знахідка стенду раунду 4) брала правку НЕЗАСТЕЙДЖЕНУ — і
        # тому доводила документовану поведінку самого `git commit` без -a, а не поведінку kit:
        # вирізання pathspec із коміту її не валило. Тепер правка ЗАСТЕЙДЖЕНА в справжній індекс
        # (Add-KitDuringPassStagedEditHook, post-index-change — там же пояснено, чому не pre-commit),
        # тож без `--only -- <два піддерева>` увесь індекс разом із нею їде в коміт перейменування.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'foreign-edit-not-swept') -WithGitattributes
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'початковий рядок' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', 'README.md') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'README поза обома піддеревами') | Out-Null
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
        Add-KitDuringPassStagedEditHook -Repo $repo -Rel 'README.md' -Content 'чужа правка під час проходу'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $committed = @(Invoke-TestGit -Repo $repo -GitArgs @('-c', 'core.quotepath=false', 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD') | ForEach-Object { "$_" })
        $committed | Should -Not -Contain 'README.md' -Because 'коміт мусить містити РІВНО два керовані піддерева — це дає лише git commit --only -- <ті самі шляхи>'
        $committed | Should -Contain 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl' -Because 'власні шляхи проходу в коміті бути МУСЯТЬ (інакше "нічого не закомічено" теж проходило б цей тест)'
        $committed | Should -Contain 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения/Ext/Module.bsl'

        $status = @(Get-TestGitStatus -Repo $repo)
        $status.Count | Should -Be 1 -Because "чужа правка мусить лишитись ЗАСТЕЙДЖЕНОЮ й НЕЗАКОМІЧЕНОЮ: $($status -join ' | ')"
        $status[0] | Should -Be 'M  README.md' -Because 'саме "M " (застейджено, робоче дерево чисте) — правка нікуди не поділась і не поїхала в коміт'
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw) | Should -BeLike '*чужа правка під час проходу*'
    }
}
