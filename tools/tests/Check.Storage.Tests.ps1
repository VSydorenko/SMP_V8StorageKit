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
        # H2 — повідомлення не називало зразка накладки (тепер він є в templates/).
        $r.Output | Should -BeLike '*templates/v8storagekit.local.yaml.example*'
    }

    # Правка 4 (живий прогін задачі 11): warn лишається warn, але текст має розвилку — інакше
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

    # Правка 8 (фінальне рев'ю) — раніше невідомий -Workspace давав сирий "Exception: ..."
    # і жоден зі стовпців [-]/[!]/[i] узагалі не друкувався (throw усередині Select-KitSources
    # ще ДО того, як Invoke-KitCheck дійшов до Write-Host). kit.ps1 ловить це на диспетчерському
    # рівні (той самий зразок, що вже стояв для невідомої команди) — код 1 (рев'ю B3 раунд 3,
    # Step 5а: був код 2, конфліктував зі штатним частковим успіхом sync — той самий код
    # означав і "диспетчер відмовив", і "sync: злиття не виконано"), охайний рядок, без слова
    # "Exception".
    It '-Workspace звужує перевірку; невідомий — код 1, охайний рядок без "Exception"' {
        $repo = New-GoodRepo 'ws-filter'
        (Invoke-Check -Repo $repo -More @('-Workspace', 'Alpha_SMB')).ExitCode | Should -Be 0
        $r = Invoke-Check -Repo $repo -More @('-Workspace', 'Nope')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*'Nope'*Alpha_SMB*"
        $r.Output | Should -Not -BeLike '*Exception*'
    }

    # Правка 8 (фінальне рев'ю), друга діра з тієї самої знахідки рев'ю: Test-KitGitHooks
    # кидає на збої git (Hooks.psm1: git ls-files -s), і без try/catch навколо нього це
    # зносило б УСІ вже зібрані findings (напр. info manifest) разом із самим звітом —
    # найгірший спосіб впасти для команди, чий сенс "показати все, що не так". Пошкоджений
    # .git/index — перевірений у цьому репозиторії прийом (StorageSync.Tests.ps1, сценарій
    # "git status fails"), який ламає САМЕ git-виклики, що читають індекс (тут — git
    # ls-files -s усередині Test-KitGitHooks), і не займає команд, що індекс не читають.
    It 'збій git усередині аудиту хуків не губить решти зібраних знахідок' {
        $repo = New-GoodRepo 'hooks-git-fails'
        Set-Content -LiteralPath (Join-Path $repo '.git/index') -Encoding UTF8 -Value 'зумисно пошкоджений індекс'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Маніфест:*'
        $r.Output | Should -BeLike '*Аудит хуків впав*'
    }

    # I3 (рев'ю B4 Task 4, Important) — той самий зразок, що вище для git-хуків, тепер для
    # Test-KitSessionHook: попереднє обґрунтування «не викликає зовнішніх команд, тож
    # try/catch не потрібен» було хибним — Get-Content усередині кидає на БУДЬ-ЯКІЙ
    # IO-помилці, не лише на збої зовнішньої команди. Блокуємо файл шима на читання з ЦЬОГО
    # процесу (FileShare.None) — дочірній `pwsh check`, як окремий процес, зіткнеться з тим
    # самим збоєм, що й гонка з `claude plugin update`, яка перезаписує кеш плагіна
    # під час прогону.
    It 'I3: заблокований шим (IO-збій усередині аудиту хука сесії) не губить решти зібраних знахідок' {
        $repo = New-GoodRepo 'session-hook-locked'
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Install-KitSessionHook -RepoRoot $repo -TemplatesDir (Resolve-Path "$PSScriptRoot/../../templates").Path | Out-Null
        $shimPath = Join-Path $repo '.claude/hooks/session-start.ps1'
        $fs = [System.IO.File]::Open($shimPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $r = Invoke-Check -Repo $repo
            $r.ExitCode | Should -Be 1
            $r.Output | Should -BeLike '*Маніфест:*'
            $r.Output | Should -BeLike '*Аудит хука старту сесії впав*'
        } finally { $fs.Close() }
    }

    # Той самий зразок, що вище для хуків, — тепер для другого захищеного виклику
    # (check.psm1: try/catch навколо Test-KitStorageBranchInvariants). Дешевий, детермінований
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
        $repo = New-GoodRepo 'branch-invariants-git-fails'
        $blob = (git -C $repo hash-object -w -- (Join-Path $repo 'v8storagekit.yaml') | Out-String).Trim()
        $refDir = Join-Path $repo '.git/refs/heads/storage'
        New-Item -ItemType Directory -Force -Path $refDir | Out-Null
        Set-Content -LiteralPath (Join-Path $refDir 'Alpha_SMB') -Value "$blob`n" -Encoding ascii -NoNewline
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Маніфест:*'
        $r.Output | Should -BeLike '*аудит інваріантів гілки*впав*'
    }

    It 'check нічого не змінює: статус робочої копії й HEAD ті самі' {
        $repo = New-GoodRepo 'readonly'
        $head = git -C $repo rev-parse HEAD
        Invoke-Check -Repo $repo | Out-Null
        git -C $repo rev-parse HEAD | Should -Be $head
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }
}
