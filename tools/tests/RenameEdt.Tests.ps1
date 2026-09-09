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
        # build/... усередині репозиторію — і не лишається по собі.
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

    It 'I-E: git mv на наявний файл посеред циклу — автоматичний відкіт (git reset --hard), а не напівстан' {
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

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before -Because 'коміту не було — reset --hard повертає рівно стартовий стан'
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty -Because 'git reset --hard мав прибрати навіть УЖЕ виконаний git mv A1'
        (Join-Path $dir 'A1/A1.mdo') | Should -Exist -Because 'A1 переїхав першим, а відкіт мав повернути його назад'
        (Join-Path $conflictDir 'A1.xml') | Should -Not -Exist
        (Join-Path $conflictDir 'A2.xml') | Should -Exist -Because 'початковий (конфліктний) вміст A2.xml має лишитись як був'
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
            [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' }
        }

        $ctx = [pscustomobject]@{ RepoRoot = $repo }
        Invoke-KitRenameEdt -Context $ctx -Apply $true -SourceRelPath 'Alpha_SMB/src' -TargetRoot 'Alpha_SMB/cfe/src' | Out-Null

        $script:CaRmArgs | Should -Not -BeNullOrEmpty -Because 'Attributes/a[bc].dcss мусить піти в Unmapped і викликати git rm'
        $literalArg = @($script:CaRmArgs | Where-Object { $_ -like ':(literal)*' })
        $literalArg.Count | Should -Be 1
        $literalArg[0] | Should -Be ':(literal)Alpha_SMB/src/Catalogs/Об1/Forms/Ф1/Attributes/a[bc].dcss'
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
