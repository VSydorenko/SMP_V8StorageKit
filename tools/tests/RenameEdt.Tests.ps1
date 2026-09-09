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
#>
Describe 'kit rename-edt — коміт перейменування EDT -> Designer (§9.2, властивість безпеки)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        function script:Invoke-TestGit {
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
            $out = & git -C $Repo @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
            $out
        }

        function script:Invoke-RenameEdt {
            param([Parameter(Mandatory)][string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit rename-edt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }

        function script:Add-KitFakeEdtTree {
            <#
            .SYNOPSIS
                Найпростіше EDT-дерево (один CommonModule: дескриптор + Module.bsl) під
                <Repo>/<Rel> — окремим комітом, як штатний наступний коміт gitsync-репозиторію.
            #>
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Rel)
            $dir = Join-Path $Repo (Join-Path $Rel 'CommonModules/ОбщегоНазначения')
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'ОбщегоНазначения.mdo') -Value '<MetaDataObject/>' -Encoding UTF8 -NoNewline
            # I-H.1 (рев'ю раунду 1): 256 байтів 0x00..0xFF — свідомо НЕ валідний UTF-8 (містить
            # самотні продовжувальні байти, NUL). Мета — зробити тест чутливим до мутації "git mv
            # замінити на читання+перезапис через текстовий конвеєр PowerShell": Get-Content/
            # Set-Content з БУДЬ-Яким текстовим кодуванням спотворює такі байти (заміна на U+FFFD,
            # усічення на NUL тощо), а git mv (чиста файлова операція) — ні. Проста ASCII/кирилична
            # рядок пережила б обидві реалізації однаково і нічого не довела б.
            $bytes = [byte[]](0..255)
            [System.IO.File]::WriteAllBytes((Join-Path $dir 'Module.bsl'), $bytes)
            Invoke-TestGit -Repo $Repo -GitArgs @('add', '-A') | Out-Null
            Invoke-TestGit -Repo $Repo -GitArgs @('commit', '-q', '-m', 'gitsync: версія сховища (EDT-дерево)') | Out-Null
            , $bytes
        }

        function script:Add-KitDuringPassPreCommitHook {
            <#
            .SYNOPSIS
                Рецепт рев'ю раунду 4 (пункт C): .git/hooks/pre-commit, який виконує рядки
                -DuringPassScript — правку "рукою людини" ПІД ЧАС проходу — і завершується
                кодом -ExitCode (типово 1, тобто ще й валить коміт).
            .DESCRIPTION
                Вікно, у якому правка мусить статись, — САМЕ ПРОХІД. Правка, внесена ДО запуску,
                нічого не доводить: запобіжник 1/4 (брудна робоча копія) зупинить команду ще до
                першої мутації ("Робоча копія не чиста … Закомітьте або сховайте зміни"), відкіт
                не настане взагалі, а правка "вціліє" тривіально — тест був би хибно-зеленим.
                Саме через цю перешкоду раунд 3 вважав тест на стан диску неможливим.

                Хук виконується ВСЕРЕДИНІ вікна мутації (коміт — остання операція проходу), тож
                запобіжник його не бачить. -ExitCode 1 форсує падіння коміту (перевірка відкоту),
                -ExitCode 0 лишає прохід успішним (перевірка, що чужу правку не втягнуто в коміт).

                Хук пишеться байтами з LF і без BOM: його виконує sh (Git for Windows), і CRLF
                чи BOM у шебангу зламали б запуск. Біта виконання Git for Windows на
                .git/hooks/* не вимагає — перевірено пробою в цій задачі.
            #>
            param(
                [Parameter(Mandatory)][string]$Repo,
                [Parameter(Mandatory)][string[]]$DuringPassScript,
                [int]$ExitCode = 1
            )
            $hookPath = Join-Path $Repo '.git/hooks/pre-commit'
            $body = (@('#!/bin/sh') + $DuringPassScript + @("exit $ExitCode", '')) -join "`n"
            [System.IO.File]::WriteAllText($hookPath, $body, [System.Text.UTF8Encoding]::new($false))
            $hookPath
        }

        function script:Get-TestGitStatus {
            param([Parameter(Mandatory)][string]$Repo)
            @(Invoke-TestGit -Repo $Repo -GitArgs @('-c', 'core.quotepath=false', 'status', '--porcelain') |
                ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
        }
    }

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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-file-in-target') -WithGitattributes
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
        $humanRel = 'Alpha_SMB/cfe/src/МійВласнийФайл.txt'
        Add-KitDuringPassPreCommitHook -Repo $repo -DuringPassScript @(
            "mkdir -p 'Alpha_SMB/cfe/src'"
            "printf '%s\n' 'це файл людини, не kit' > '$humanRel'"
            "git add -- '$humanRel'"
        ) | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0

        (Join-Path $repo $humanRel) | Should -Exist -Because 'команда прибирає рівно власні цілі ($plan.Moves.To), а чужого файлу не знає й не чіпає'
        (Get-Content -LiteralPath (Join-Path $repo $humanRel) -Raw) | Should -BeLike '*це файл людини*'
        $r.Output | Should -BeLike '*розбіжність*' -Because 'чужий файл у піддереві — саме та розбіжність, про яку треба ЧЕСНО доповісти, а не прибрати її видаленням'

        # Власне перейменування все одно відкочено: джерело на місці, цілі kit прибрані.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        [System.IO.File]::ReadAllBytes((Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl')) | Should -Be $originalBytes
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения.xml') | Should -Not -Exist
    }

    It 'знахідка A.2 (рев''ю раунду 4): команда відновлення з повідомлення СПРАВДІ повертає цей стан — тест її ВИКОНУЄ, а не звіряє рядок' {
        # Вимога стенду: "воно мусить назвати команду, яка справді повертає ЦЕЙ конкретний стан,
        # і ця команда мусить бути перевірена тестом, а не просто написана в рядку". Тут — жива
        # форма (дерева призначення в HEAD немає) плюс чужий застейджений файл у піддереві
        # призначення: команда чужого не чіпає, тож приймальна перевірка чесно каже "розбіжність"
        # і друкує, чим її закрити. Тест бере ці рядки З ВИВОДУ, виконує їх і звіряє стан.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'manual-recovery') -WithGitattributes -NoSourceTrees
        $originalBytes = Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
        $humanRel = 'Alpha_SMB/cfe/src/МійВласнийФайл.txt'
        Add-KitDuringPassPreCommitHook -Repo $repo -DuringPassScript @(
            "mkdir -p 'Alpha_SMB/cfe/src'"
            "printf '%s\n' 'це файл людини, не kit' > '$humanRel'"
            "git add -- '$humanRel'"
        ) | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*HEAD не рухався*' -Because 'людина мусить дізнатись, ЧОМУ стан узагалі відновний'
        (Join-Path $repo $humanRel) | Should -Exist -Because 'до відновлення чужий файл ще на місці — його прибирає саме підказана команда, і повідомлення про це попереджає'

        # Рядки виду "  git …" з виводу — це і є підказаний рецепт. Виконуємо ДОСЛІВНО.
        $recipe = @($r.Output -split "`r?`n" |
            Where-Object { $_.Trim().StartsWith('git ') } |
            ForEach-Object { ($_ -split '\s+#')[0].Trim() })
        $recipe.Count | Should -BeGreaterThan 1 -Because "у повідомленні мусить бути рецепт, а не лише діагностика: $($r.Output)"
        ($recipe -join ' ') | Should -BeLike '*checkout*'
        ($recipe -join ' ') | Should -BeLike '*rm*'
        foreach ($line in $recipe) {
            # Лапки навколо pathspec знімає оболонка; тут знімаємо їх самі, аргументи не склеюючи.
            $tokens = @($line -split '\s+' | Select-Object -Skip 1 | ForEach-Object { $_.Trim("'") })
            Invoke-TestGit -Repo $repo -GitArgs $tokens | Out-Null
        }

        # Властивість: після рецепту репозиторій РІВНО такий, як був до запуску.
        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        @(Get-TestGitStatus -Repo $repo).Count | Should -Be 0 -Because 'рецепт мусить закрити всі 192 (на парку — 17 366) застейджені зміни, а не лише показати їх'
        [System.IO.File]::ReadAllBytes((Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl')) | Should -Be $originalBytes
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules') | Should -Not -Exist
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

    It 'знахідка стенду (раунд 4): УСПІШНИЙ прохід не втягує чужу паралельну правку у свій коміт' {
        # Властивість ніде не була заявлена й нічим не боронена, хоч ціна її втрати висока:
        # `git commit -a` (чи будь-яке ширше додавання в індекс) мовчки затягнув би у коміт
        # перейменування чужу НЕЗАВЕРШЕНУ роботу. Стенд перевірив це побічно на живому проході;
        # тут — прямо. Хук із -ExitCode 0 править README.md поза обома піддеревами САМЕ під час
        # проходу (перед самим комітом) і НЕ валить його: прохід лишається успішним.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'foreign-edit-not-swept') -WithGitattributes
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'початковий рядок' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', 'README.md') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'README поза обома піддеревами') | Out-Null
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
        Add-KitDuringPassPreCommitHook -Repo $repo -ExitCode 0 -DuringPassScript @("printf '%s\n' 'чужа правка під час проходу' >> README.md") | Out-Null

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $committed = @(Invoke-TestGit -Repo $repo -GitArgs @('-c', 'core.quotepath=false', 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD') | ForEach-Object { "$_" })
        $committed | Should -Not -Contain 'README.md' -Because 'коміт перейменування мусить містити РІВНО власні шляхи — git commit -F без -a саме це й дає'
        $committed.Count | Should -BeGreaterThan 0

        $status = @(Get-TestGitStatus -Repo $repo)
        $status.Count | Should -Be 1 -Because "чужа правка мусить лишитись НЕЗАКОМІЧЕНОЮ: $($status -join ' | ')"
        $status[0] | Should -Be ' M README.md'
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw) | Should -BeLike '*чужа правка під час проходу*'
    }

    Context 'Step 3а — запобіжник політики тексту (Test-GitTextPolicy на -TargetRoot)' {
        It 'застаріла gitsync .gitattributes (лише *.bin/*.axdt/*.addin binary) — зупинка ДО git mv, жоден файл не переміщено' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'stale-attrs')
            Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value @('*.bin binary', '*.axdt binary', '*.addin binary') -Encoding ascii
            Invoke-TestGit -Repo $repo -GitArgs @('add', '.gitattributes') | Out-Null
            Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'застаріла .gitattributes gitsync') | Out-Null
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
            $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*text*'

            (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
            (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist
        }

        It 'сучасна .gitattributes (-text на TargetRoot, templates/gitattributes) — проходить' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'modern-attrs') -WithGitattributes
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }
}

Describe 'kit rename-edt — мок git-шару в процесі: C-A, pathspec git rm (task-3-findings-round1.md)' {
    # Той самий прийом, що Canon.Tests.ps1 ("мок платформного шару"): лаб-модулі в порядку
    # module-order.txt, потім САМЕ commands/rename-edt.psm1 у ЦЬОМУ процесі (не підпроцесом
    # kit.ps1) — лише так Mock -ModuleName бачить приватний стіл команди. Тест перевіряє РІВНО
    # те, що йде в git rm, — не текст помилки й не побічний ефект глобу (той відтворено окремо,
    # Bash-пробою, задокументованою в task-3-report.md), а сам аргумент, який команда будує.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/rename-edt.psm1").Path -Force

        # Знахідка D (рев'ю раунду 4): попередні моки віддавали ExitCode = 0 на що завгодно,
        # тож мок-тести не бачили ЖОДНОГО збою git — а весь відкіт саме про збої. Спільне тіло
        # моку нижче вміє три речі, яких бракувало:
        #   $script:GitMockLsTree   — що САМЕ лежить у $preHeadSha під кожним із двох керованих
        #                             шляхів (порожньо = такого шляху в коміті немає, тобто
        #                             жива форма першої міграції);
        #   $script:GitMockFailWhen — ненульовий ExitCode на КОНКРЕТНИЙ виклик;
        #   $script:GitMockThrowWhen— виняток із самого шару запуску процесу (немає git у PATH,
        #                             вичерпані дескриптори) — знахідка F.
        # Тіло створюється тут ОДИН раз і передається в Mock як -MockWith: замикань немає,
        # усе налаштування — через $script:-змінні, які видно і в It, і всередині моку.
        $script:GitMockBody = {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            $argv = @($Arguments)
            $script:GitMockCalls.Add($argv)
            if ($null -ne $script:GitMockThrowWhen -and (& $script:GitMockThrowWhen $argv)) {
                throw "симуляція: git не запустився ($($argv -join ' '))"
            }
            if ($argv -contains 'rev-parse') {
                return [pscustomobject]@{ ExitCode = $script:GitMockHeadExit; Stdout = $script:GitMockHeadSha; Stderr = 'симуляція rev-parse' }
            }
            if ($null -ne $script:GitMockFailWhen -and (& $script:GitMockFailWhen $argv)) {
                return [pscustomobject]@{ ExitCode = 128; Stdout = ''; Stderr = 'симуляція збою git' }
            }
            if ($argv -contains 'ls-tree') {
                $rel = $argv[-1]
                $entries = @()
                if ($script:GitMockLsTree.ContainsKey($rel)) { $entries = @($script:GitMockLsTree[$rel]) }
                # git ls-tree -z ЗАВЕРШУЄ кожен запис NUL — відтворюємо саме це.
                $payload = ''
                foreach ($entry in $entries) { $payload += "$entry`0" }
                return [pscustomobject]@{ ExitCode = 0; Stdout = $payload; Stderr = '' }
            }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }

        function script:Reset-KitGitMockState {
            <# .SYNOPSIS Типовий стан спільного моку: усе успішне, дерево призначення в HEAD Є. #>
            param([hashtable]$LsTree)
            $script:GitMockCalls = [System.Collections.Generic.List[object]]::new()
            $script:GitMockHeadSha = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
            $script:GitMockHeadExit = 0
            $script:GitMockFailWhen = $null
            $script:GitMockThrowWhen = $null
            $script:GitMockLsTree = if ($PSBoundParameters.ContainsKey('LsTree')) { $LsTree } else { @{} }
        }

        function script:Add-KitMockEdtPair {
            <# .SYNOPSIS Два звичайні об'єкти A1/A2 під <Repo>/Alpha_SMB/src — два Moves поспіль. #>
            param([Parameter(Mandatory)][string]$Repo)
            $catalogsDir = Join-Path $Repo 'Alpha_SMB/src/Catalogs'
            foreach ($objectName in 'A1', 'A2') {
                New-Item -ItemType Directory -Force -Path (Join-Path $catalogsDir $objectName) | Out-Null
                Set-Content -LiteralPath (Join-Path $catalogsDir "$objectName/$objectName.mdo") -Value $objectName -Encoding UTF8
            }
        }
    }

    It 'git rm для Unmapped-файлу з дужками в імені йде через '':(literal)'' pathspec, не голий glob-шлях' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ca-mock') -WithGitattributes
        # Файл під Attributes/ — ПІДТВЕРДЖЕНО Unmapped (координатор: "2016 файлів Attributes/…
        # правильно віднесені до Unmapped"), а не Unresolved (як був би невідомий вид) — інакше
        # git rm для нього взагалі не викликається (Unresolved ніколи не видаляється), і тест
        # нічого не довів би про C-A.
        $dir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1/Forms/Ф1/Attributes'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a[bc].dcss') -Value 'x' -Encoding UTF8

        $script:CaRmArgs = $null
        Mock -ModuleName rename-edt Invoke-KitGitProcess {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            if ($Arguments -contains 'rm') { $script:CaRmArgs = $Arguments }
            # rev-parse HEAD мусить повернути щось (знахідка 6, рев'ю раунду 3: команда тепер
            # перевіряє, що SHA непорожній, ДО будь-якої мутації) — фальшивий, але непорожній SHA.
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Stdout = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'; Stderr = '' } }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null

        $script:CaRmArgs | Should -Not -BeNullOrEmpty -Because 'Attributes/a[bc].dcss мусить піти в Unmapped і викликати git rm'
        $literalArg = @($script:CaRmArgs | Where-Object { $_ -like ':(literal)*' })
        $literalArg.Count | Should -Be 1
        $literalArg[0] | Should -Be ':(literal)Alpha_SMB/src/Catalogs/Об1/Forms/Ф1/Attributes/a[bc].dcss'
    }

    It 'знахідка 1 (рев''ю раунду 3): жоден git-виклик відновлення не є "reset --hard" на весь репозиторій, і всі адресовані ЛИШЕ -SourceRelPath/-TargetRoot' {
        # Перехоплює АРГУМЕНТИ кожного git-виклику під час форсованого падіння — властивість,
        # яку не перевірити наскрізним прогоном через підпроцес (там видно лише stdout/файли,
        # не самі команди), і яку не можна відтворити "живою" гонитвою всередині одного
        # синхронного виклику команди без флакі-конкуренції (спроба через окремий файл поза
        # деревами щоразу впирається в запобіжник 1/4 "брудна копія" ще до старту мутації —
        # це вже перевірено окремо і свідомо відкинуто, коментар вище). Разом із наскрізним
        # I-E-тестом (реальний git, реальний стан диска в межах піддерев) це покриває
        # властивість: тут — що КОМАНДА НІКОЛИ НЕ ПРОСИТЬ git зробити щось поза двома
        # шляхами, там — що в межах цих шляхів реальний git справді відновлює коректно.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'scope-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        # Дерево призначення в $preHeadSha Є (типова фікстура) — тоді checkout адресується
        # обом шляхам, і саме цей обсяг перевіряє тест.
        Reset-KitGitMockState -LsTree @{
            'Alpha_SMB/src'     = @('Alpha_SMB/src/Catalogs/A1/A1.mdo', 'Alpha_SMB/src/Catalogs/A2/A2.mdo')
            'Alpha_SMB/cfe/src' = @('Alpha_SMB/cfe/src/Configuration.xml')
        }
        $script:GitMockFailWhen = { param($argv) $argv -contains 'mv' -and ($argv -join ' ') -like '*A2.mdo*' }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } | Should -Throw

        $allCalls = @($script:GitMockCalls)
        $allCalls.Count | Should -BeGreaterThan 0

        # Головна властивість: "reset" + "--hard" разом БІЛЬШЕ НІКОЛИ не з'являються — це й
        # був обсяг усього репозиторію, який зламала перша версія I-E.
        @($allCalls | Where-Object { $_ -contains 'reset' -and $_ -contains '--hard' }).Count | Should -Be 0 -Because '"reset --hard" на весь репозиторій прибрано остаточно'

        $checkoutCall = @($allCalls | Where-Object { $_ -contains 'checkout' })
        $checkoutCall.Count | Should -Be 1 -Because 'відновлення викликається рівно один раз'
        $checkoutCall[0][-2] | Should -Be 'Alpha_SMB/src' -Because 'checkout адресований -SourceRelPath, не корню репозиторію'
        $checkoutCall[0][-1] | Should -Be 'Alpha_SMB/cfe/src' -Because 'checkout адресований -TargetRoot, не корню репозиторію'

        $diffCalls = @($allCalls | Where-Object { $_ -contains 'diff' })
        $diffCalls.Count | Should -BeGreaterThan 0
        foreach ($diffCall in $diffCalls) {
            $diffCall[-2] | Should -Be 'Alpha_SMB/src' -Because 'кожен diff звірки відновлення адресований лише двом керованим шляхам'
            $diffCall[-1] | Should -Be 'Alpha_SMB/cfe/src'
        }

        # Знахідка A/B (рев'ю раунду 4): ls-tree питає про кожен керований шлях окремо, а
        # прибирання адресоване рівно цілям власного плану — жодного pathspec поза цими двома
        # коренями команда git не передає.
        $lsTreeCalls = @($allCalls | Where-Object { $_ -contains 'ls-tree' })
        $lsTreeCalls.Count | Should -Be 2 -Because 'про кожен із двох керованих шляхів питаємо окремо'
        $lsTreeCalls[0][-1] | Should -Be 'Alpha_SMB/src'
        $lsTreeCalls[1][-1] | Should -Be 'Alpha_SMB/cfe/src'
        foreach ($rmCall in @($allCalls | Where-Object { $_ -contains 'rm' })) {
            $rmCall[-1] | Should -BeLike ':(literal)Alpha_SMB/*'
        }
    }

    It 'знахідки A.2 і E (рев''ю раунду 4): невдалий checkout — повідомлення називає ТОЧНУ команду відновлення, і косметичне прибирання НЕ виконується' {
        # Мок віддає ненульовий ExitCode саме на checkout — форма, якої попередні моки не вміли
        # відтворити взагалі. Дві властивості одразу:
        #   A.2 — у тексті мусить бути команда, якою людина відновить стан руками (HEAD не
        #         рухався), а не лише діагностичні git diff/git status;
        #   E   — Remove-KitEmptyDirectory не мусить спрацювати після ПРОВАЛУ відновлення: саме
        #         прибраний скелет робив напівмігроване дерево схожим на успішно мігроване.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'restore-fail-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState -LsTree @{ 'Alpha_SMB/src' = @('Alpha_SMB/src/Catalogs/A1/A1.mdo', 'Alpha_SMB/src/Catalogs/A2/A2.mdo') }
        $script:GitMockFailWhen = { param($argv) ($argv -contains 'mv') -or ($argv -contains 'checkout') }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        $thrown = $null
        try { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null }
        catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -BeLike '*не вдався повністю*'
        $thrown | Should -BeLike "*git checkout deadbeefdeadbeefdeadbeefdeadbeefdeadbeef -- Alpha_SMB/src*" -Because 'A.2: точна команда відновлення, а не лише git diff/git status'
        $thrown | Should -BeLike "*git rm -r -f --ignore-unmatch -- ':(literal)Alpha_SMB/cfe/src'*" -Because 'A.2: дерева призначення в коміті не було — його треба ПРИБРАТИ, і команда це називає'
        $thrown | Should -BeLike '*HEAD не рухався*'

        # E: теку під -TargetRoot створив New-Item у циклі mv; після ПРОВАЛУ відновлення вона
        # мусить лишитись на місці — саме її зникнення й створювало хибне враження міграції.
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs') | Should -Exist -Because 'нічого не прибираємо, коли відновлення не вдалося'
    }

    It 'знахідка F (рев''ю раунду 4): виняток усередині самого відкоту не з''їдає оригінальну причину падіння' {
        # Invoke-KitGitProcess СТАРТУЄ процес і може кинути (немає git у PATH, вичерпані
        # дескриптори). До раунду 4 виклики у catch не були обгорнуті, тож людина бачила лише
        # вторинну помилку — а на 22-хвилинному проході оригінальна причина це єдине свідчення
        # того, що саме пішло не так.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'rollback-throw-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState -LsTree @{ 'Alpha_SMB/src' = @('Alpha_SMB/src/Catalogs/A1/A1.mdo') }
        $script:GitMockFailWhen = { param($argv) $argv -contains 'mv' -and ($argv -join ' ') -like '*A2.mdo*' }
        $script:GitMockThrowWhen = { param($argv) $argv -contains 'ls-tree' }
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        $thrown = $null
        try { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null }
        catch { $thrown = $_.Exception.Message }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown | Should -BeLike '*A2.mdo*' -Because 'оригінальна причина падіння мусить дожити до повідомлення'
        $thrown | Should -BeLike '*сам відкіт кинув виняток*' -Because 'вторинна помилка теж називається, але ПОРУЧ з оригінальною, а не замість неї'
        $thrown | Should -BeLike '*симуляція: git не запустився*'
    }

    It 'знахідка G (рев''ю раунду 4): ненульовий код git rev-parse HEAD зупиняє ДО будь-якої мутації' {
        # Мутант "вирізати перевірку ExitCode" виживав (15/0). Щоб він помер, мок віддає
        # НЕПОРОЖНІЙ Stdout при коді 1: інакше зупинку зробила б сусідня перевірка на порожній
        # SHA, і тест нічого не довів би саме про код виходу.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'revparse-code-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState
        $script:GitMockHeadExit = 1
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } |
            Should -Throw '*rev-parse HEAD*'

        @($script:GitMockCalls | Where-Object { ($_ -contains 'mv') -or ($_ -contains 'rm') -or ($_ -contains 'commit') }).Count |
            Should -Be 0 -Because 'зупинка ДО ЄДИНОЇ руйнівної команди, а не після неї'
    }

    It 'знахідка G (рев''ю раунду 4): порожній SHA при коді виходу 0 зупиняє ДО будь-якої мутації' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'revparse-empty-mock') -WithGitattributes
        Add-KitMockEdtPair -Repo $repo

        Reset-KitGitMockState
        $script:GitMockHeadSha = "   `n"
        Mock -ModuleName rename-edt Invoke-KitGitProcess $script:GitMockBody

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        { Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' } |
            Should -Throw '*порожній результат*'

        @($script:GitMockCalls | Where-Object { ($_ -contains 'mv') -or ($_ -contains 'rm') -or ($_ -contains 'commit') }).Count |
            Should -Be 0
    }

    It 'S-J (рев''ю раунду 3, мутаційно): шлях файла повідомлення коміту створюється ПОЗА робочою копією репозиторію' {
        # Знахідка 4 (рев'ю раунду 3): попередній тест на S-J шукав файл, який `finally`
        # однаково прибирає, тож асерція "чи лишився файл" не могла впасти в принципі —
        # виживала і при старій, і при новій поведінці. Тут перехоплюється САМ ШЛЯХ у момент
        # запису (Set-Content), ДО будь-якого прибирання — якщо хтось поверне
        # 'build/rename-edt-commit-message.txt' усередині репозиторію, цей тест впаде, бо
        # порівнює шлях, а не факт видалення файлу пізніше.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sj-mock') -WithGitattributes
        $dir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Об1.mdo') -Value 'x' -Encoding UTF8

        Mock -ModuleName rename-edt Invoke-KitGitProcess {
            param($RepoRoot, $Arguments, [string[]]$StdinRecords = @())
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Stdout = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'; Stderr = '' } }
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }
        $script:SjMsgPath = $null
        Mock -ModuleName rename-edt Set-Content {
            param($LiteralPath, $Value, $Encoding)
            $script:SjMsgPath = $LiteralPath
        }

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null

        $script:SjMsgPath | Should -Not -BeNullOrEmpty -Because 'команда мала дійти до запису повідомлення коміту'
        $repoFull = (Resolve-Path $repo).Path.TrimEnd('\', '/')
        $script:SjMsgPath | Should -Not -BeLike "$repoFull*" -Because 'файл повідомлення має створюватись ПОЗА робочою копією репозиторію (S-J), а не в build/ усередині неї'
    }
}

Describe 'kit rename-edt — межа Unmapped/Unresolved: Unresolved ніколи не видаляється (додаток координатора до раунду 1)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit2 = Copy-KitTools -Root (Join-Path $TestDrive 'kit2')

        function script:Invoke-TestGit2 {
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
            $out = & git -C $Repo @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
            $out
        }

        function script:Invoke-RenameEdt2 {
            param([Parameter(Mandatory)][string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit2 rename-edt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'Unresolved (розширення макета без доказу) НЕ видаляється й НЕ перейменовується під -Apply — лишається на диску як є' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unresolved-kept') -WithGitattributes
        # Один мапований файл (щоб команда мала що робити й дійшла до коміту) + один
        # Unresolved (Template.scheme — доказу немає в жоден бік, task-3-findings-round1.md
        # + пряме уточнення координатора).
        $mappedDir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1'
        New-Item -ItemType Directory -Force -Path $mappedDir | Out-Null
        Set-Content -LiteralPath (Join-Path $mappedDir 'Об1.mdo') -Value 'x' -Encoding UTF8
        $unresolvedDir = Join-Path $repo 'Alpha_SMB/src/Reports/Об2/Templates/Мак1'
        New-Item -ItemType Directory -Force -Path $unresolvedDir | Out-Null
        Set-Content -LiteralPath (Join-Path $unresolvedDir 'Template.scheme') -Value 'y' -Encoding UTF8
        Invoke-TestGit2 -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit2 -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: мапований об''єкт + нехарактеризований макет') | Out-Null

        $r = Invoke-RenameEdt2 -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike "*не з'ясовано*"
        $r.Output | Should -BeLike '*Template.scheme*'

        # Властивість, яку вимагав координатор: перевіряти НАЯВНІСТЬ ФАЙЛА НА ДИСКУ, не текст
        # повідомлення.
        (Join-Path $unresolvedDir 'Template.scheme') | Should -Exist -Because 'Unresolved НІКОЛИ не видаляється — лишається на місці'
        (Join-Path $repo 'Alpha_SMB/cfe/src/Reports/Об2/Templates/Мак1/Template.scheme') | Should -Not -Exist -Because 'Unresolved також НЕ перейменовується — не в Moves'
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs/Об1.xml') | Should -Exist -Because 'мапований файл поруч мав перейменуватись нормально'

        # git теж бачить Template.scheme як і раніше — не видалено з індексу.
        (Invoke-TestGit2 -Repo $repo -GitArgs @('ls-files', '--', 'Alpha_SMB/src/Reports/Об2/Templates/Мак1/Template.scheme')) | Should -Not -BeNullOrEmpty
    }
}
