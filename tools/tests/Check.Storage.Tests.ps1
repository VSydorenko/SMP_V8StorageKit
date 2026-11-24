#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It 'dump.from без накладки на машині — попередження, не помилка' {
        # Обидва рядки: 'no-overlay' — це ще й New-GoodRepo, а фікстура навмисно ставить
        # неіснуючий шлях сховища, тож warn storage-path теж посилається на
        # v8storagekit.local.yaml і теж проходить під '*[!]*v8storagekit.local.yaml*' —
        # цей шаблон сам собою не діагностичний, ловить дві РІЗНІ знахідки. '*dump.from*'
        # звужує саме до warn dump-from.
        $r = Invoke-Check -Repo (New-GoodRepo 'no-overlay')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[!]*v8storagekit.local.yaml*'
        $r.Output | Should -BeLike '*dump.from*'
        # Повідомлення мусить називати зразок накладки (він є в templates/).
        $r.Output | Should -BeLike '*templates/v8storagekit.local.yaml.example*'
    }

    # Warn лишається warn, але текст має розвилку — інакше
    # людина бачить лише "перевизначте шлях" і не здогадується, що причина може бути в
    # самому маніфесті (живий приклад: маніфест указував …_ACC, а сховище лежало під …_BP).
    It 'правка 4: warn storage-path називає обидві розвилки — накладку і сам маніфест' {
        $r = Invoke-Check -Repo (New-GoodRepo 'storage-path-branches')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*якщо диск є, а шлях помилковий — виправте v8storagekit.yaml*'
        # Головна половина правки — не сама розвилка (вище), а те, що шлях підписаний саме
        # як маніфестний: реалізація, яка дописала б розвилку, але викинула б другий пошук
        # у $Context.Manifest, цей рядок уже не пройде.
        $r.Output | Should -BeLike '*no-such-storage-Alpha_SMB*як записано в v8storagekit.yaml*'
    }

    It 'правка 4: шлях сховища перевизначено накладкою, але й вона недоступна — видно ОБИДВА шляхи' {
        # На відміну від попереднього тесту (без накладки — v8storagekit.local.yaml дорівнює
        # маніфесту), тут накладка Є і перевизначає шлях на інший, теж неіснуючий: повідомлення
        # мусить показати і те, що записано в v8storagekit.yaml, і те, на що перевизначено.
        $overlay = "storages:`n  Alpha_SMB: 'D:\also-missing\alpha'"
        $repo = New-GoodRepo 'storage-path-overridden' @{ OverlayText = $overlay }
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*перевизначено в v8storagekit.local.yaml на*D:\also-missing\alpha*'
        $r.Output | Should -BeLike '*у самому v8storagekit.yaml записано*'
    }

    # Ім'я воркспейсу, якого немає в МАНІФЕСТІ, — помилка виклику (рішення 3 плану B3): код 2, один рядок
    # `check: ERROR …` з переліком імен маніфесту, без шапки, знахідок і підсумку. Раніше (PowerShell) це був
    # код 1. Воркспейс, який Є в маніфесті, але не розв'язався (помилка конфігу), — звичайний звіт із error
    # префлайту, код 1 (тест нижче).
    It '-Workspace звужує перевірку; невідомий — код 2, охайний рядок без "Exception", без звіту' {
        $repo = New-GoodRepo 'ws-filter'
        (Invoke-Check -Repo $repo -More @('-Workspace', 'Alpha_SMB')).ExitCode | Should -Be 0
        $r = Invoke-Check -Repo $repo -More @('-Workspace', 'Nope')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -BeLike "check: ERROR*'Nope'*Alpha_SMB*"
        $r.Output | Should -Not -BeLike '*Exception*'
        $r.Output | Should -Not -BeLike '*kit check —*'
        $r.Output | Should -Not -BeLike '*Попереджень*'
    }

    # Друга діра з тієї самої знахідки рев'ю: Test-KitGitHooks
    # кидає на збої git (Hooks.psm1: git ls-files -s), і без try/catch навколо нього це
    # зносило б УСІ вже зібрані findings (напр. info manifest) разом із самим звітом —
    # найгірший спосіб впасти для команди, чий сенс "показати все, що не так". Пошкоджений
    # .git/index — перевірений у цьому репозиторії прийом (StorageSync.Tests.ps1, сценарій
    # "git status fails"), який ламає САМЕ git-виклики, що читають індекс (тут — git
    # ls-files -s усередині Test-KitGitHooks), і не займає команд, що індекс не читають.
    #
    # Рішення 2, 5, 6, 8 плану B3: збій git — «не перевірено» з дослівним stderr git, а не «немає». Код 1 дають
    # стражі файла з паролем (`overlay-ignored`, `local-ignored`, vendor-`gitignore`): вони лишаються fail-closed
    # і на збої git — error «не перевірено: …». Неохоронні перевірки (`hooks`, `gitattributes`, `build-artifacts`)
    # стають [!] «не перевірено: …». Рядка «Аудит хуків впав» більше немає.
    It 'збій git усередині аудиту хуків не губить решти зібраних знахідок' {
        $repo = New-GoodRepo 'hooks-git-fails'
        Set-Content -LiteralPath (Join-Path $repo '.git/index') -Encoding UTF8 -Value 'зумисно пошкоджений індекс'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Маніфест:*'
        $r.Output | Should -Not -BeLike '*Аудит хуків впав*'
        $r.Output | Should -Match '(?m)^\[-\] не перевірено: гітігнорування v8storagekit\.local\.yaml'
        $r.Output | Should -Match '(?m)^\[-\] не перевірено: гітігнорування Alpha_SMB/v8project\.local\.yaml'
        $r.Output | Should -Match '(?m)^\[-\] не перевірено: Alpha_SMB/base: відстеження дерева'
        # Неохоронні — [!], не [-]: hooks (режим хука в індексі), gitattributes, build-artifacts.
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: режим хука \.githooks/pre-commit в індексі'
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: Alpha_SMB/Alpha_SMB: політика кінців рядків'
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: Alpha_SMB: артефакти збірки в git'
        $r.Output | Should -BeLike '*index file corrupt*'
        $r.Output | Should -Match 'з них не перевірено: \d+'
    }

    # Той самий зразок, що вище для git-хуків, тепер для
    # Test-KitLegacySessionHook: Get-Content усередині кидає на БУДЬ-ЯКІЙ IO-помилці. Блокуємо
    # settings.json на читання з ЦЬОГО процесу (FileShare.None) — дочірній `pwsh check`, як
    # окремий процес, зіткнеться з тим самим збоєм, що й гонка з записом чужого процесу.
    # Збій читання аудит перетворює на warn «не читається» (kit не може перевірити, чи немає в
    # файлі старого хука), а решта знахідок — на місці.
    It 'Заблокований settings.json (IO-збій усередині аудиту старого хука сесії) не губить решти зібраних знахідок' {
        $repo = New-GoodRepo 'session-hook-locked'
        New-Item -ItemType Directory -Path (Join-Path $repo '.claude') -Force | Out-Null
        $settingsPath = Join-Path $repo '.claude/settings.json'
        Set-Content -LiteralPath $settingsPath -Value '{ "permissions": { "allow": [] } }' -Encoding UTF8
        $fs = [System.IO.File]::Open($settingsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $r = Invoke-Check -Repo $repo
            # Рішення 2, 8, 12: файл не прочитано — «не перевірено» (код 3, не зелений), а не «не читається як JSON».
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*Маніфест:*'
            $r.Output | Should -Match '(?m)^\[!\] не перевірено:.*settings\.json'
            $r.Output | Should -Not -BeLike '*не читається як JSON*'
            $r.Output | Should -Not -Match '(?m)^\[-\]'
        } finally { $fs.Close() }
    }
    # Той самий зразок, що вище для хуків, — тепер для другого захищеного виклику
    # (rust/src/check/: помилка git-виклику інваріантів гілок storage/* не валить check). Дешевий, детермінований
    # спосіб зламати саме git-виклики StorageBranch.psm1 (не крихке пошкодження бази об'єктів):
    # `git update-ref` відмовляється писати НЕ-коміт у гілку ("trying to write non-commit
    # object … to branch"), але ref-файл можна створити повз нього. Пишемо в
    # refs/heads/storage/Alpha_SMB хеш звичайного blob-об'єкта: `git rev-parse --verify`
    # бачить об'єкт → Test-KitBranchExists = $true → виконання доходить до захищеного виклику.
    # Усередині `git log <blob>` (Get-KitBranchCommits) виходить кодом 0 і порожнім
    # виводом — цим прийомом ламається не він. А `git ls-tree -r <blob>` падає з кодом 128
    # ("fatal: not a tree object") — саме цей виклик і кидає виняток, який перетворюється
    # на знахідку error, а не зносить решту звіту.
    It 'збій git усередині аудиту інваріантів гілки storage/X не губить решти зібраних знахідок' {
        # Рішення 2, 5: точковий збій неохоронної перевірки — «не перевірено» (код 3), не error (код 1).
        $repo = New-GoodRepo 'branch-invariants-git-fails'
        $blob = (git -C $repo hash-object -w -- (Join-Path $repo 'v8storagekit.yaml') | Out-String).Trim()
        $refDir = Join-Path $repo '.git/refs/heads/storage'
        New-Item -ItemType Directory -Force -Path $refDir | Out-Null
        Set-Content -LiteralPath (Join-Path $refDir 'Alpha_SMB') -Value "$blob`n" -Encoding ascii -NoNewline
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*Маніфест:*'
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: Alpha_SMB/Alpha_SMB: інваріанти гілки storage/Alpha_SMB'
        $r.Output | Should -BeLike '*not a tree object*'
        $r.Output | Should -BeLike '*Помилок немає*'
        $r.Output | Should -Not -Match '(?m)^\[-\]'
    }

    It 'HEAD з кириличною парою регістру під шляхом джерела — error case-collision, код 1' {
        $repo = New-GoodRepo 'head-case'
        # Ordinal-словник: хештеблиця PowerShell злила б пару регістру в один ключ (див. StorageBranch.Tests).
        $files = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($p in @(git -c core.quotepath=false -C $repo ls-tree -r --name-only HEAD)) {
            $files[$p] = [string](git -C $repo show "HEAD:$p" | Out-String)
        }
        $files['Alpha_SMB/cfe/src/T/Образецанализ.xml'] = 'x'
        $files['Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'] = 'x'
        $sha = Set-KitFakeBranchTree -Repo $repo -Branch 'case-branch' -Parent (git -C $repo rev-parse HEAD) -Message 'пара регістру' -Files $files
        @(git -c core.quotepath=false -C $repo ls-tree -r --name-only 'case-branch' -- 'Alpha_SMB/cfe/src/T') |
            Should -BeExactly @('Alpha_SMB/cfe/src/T/ОбразецАнализ.xml', 'Alpha_SMB/cfe/src/T/Образецанализ.xml')
        # HEAD → нова гілка без checkout робочої копії: check читає лише дерево HEAD.
        git -C $repo symbolic-ref HEAD refs/heads/case-branch
        git -C $repo read-tree $sha
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*у HEAD*різняться лише регістром*'
    }

    It 'check нічого не змінює: статус робочої копії й HEAD ті самі' {
        $repo = New-GoodRepo 'readonly'
        $head = git -C $repo rev-parse HEAD
        Invoke-Check -Repo $repo | Out-Null
        git -C $repo rev-parse HEAD | Should -Be $head
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }
}
