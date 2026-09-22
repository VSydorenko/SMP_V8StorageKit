# Спільна підготовка для розрізаних файлів RenameEdt.Commit.Tests.ps1 і
# RenameEdt.Rollback.Tests.ps1 (Task 8, "Швидкість набору тестів") — дослівний перенос тіла
# BeforeAll ПЕРШОГО Describe з колишнього RenameEdt.Tests.ps1:23-230 (усі 14 хелперів:
# Invoke-TestGit, Add-KitFakeEdtTree, Add-KitDuringPassPreCommitHook,
# Add-KitDuringPassStagedEditHook, Get-TestGitStatus, Add-KitOccupyTargetHook,
# Add-KitBreakRestoreHook, Repair-KitBrokenRestore, Invoke-KitRecipeFromOutput та ін. — ділити
# їх не треба, обидва файли користуються всім набором).
#
# Другий і третій Describe колишнього файлу (мок git-шару; межа Unmapped/Unresolved)
# перенесені в GitMock/Unresolved цілими, разом ІЗ ВЛАСНИМИ BeforeAll — цього файлу вони не
# потребують.
#
# Підключається DOT-SOURCE із BeforeAll кожного файлу, не Import-Module: перенесені хелпери
# користуються $TestDrive (Pester-змінна поточного тестового прогону) і function script:, а
# всередині модуля перше не видно, друге осідає в чужій області — та сама пастка вкладеного
# Import-Module, яку описує великий коментар у KitFixtures.psm1 і docs/follow-ups.md §5.
#
# $PSScriptRoot тут — власна тека ЦЬОГО файлу (tools/tests/fixtures/), А НЕ виклика (як і в
# CheckSetup.ps1 Task 6, SessionCheckSetup.ps1 Task 7): у PowerShell dot-source не переносить
# $PSScriptRoot файлу, що підключає, — файл, який підключають, бачить СВІЙ ВЛАСНИЙ
# $PSScriptRoot. Тому KitFixtures.psm1 тут — сусід по теці, без префікса 'fixtures/' (в
# оригіналі був "$PSScriptRoot/fixtures/KitFixtures.psm1", тут — "$PSScriptRoot/KitFixtures.psm1").
#
# Локальний Invoke-RenameEdt НЕ зведено до Invoke-KitCommand (на відміну від Invoke-Check/
# Invoke-SessionCheck у Task 6/7) — бриф цієї задачі не давав такого дозволу (на відміну від
# явного дозволу в task-5-6-brief.md для Check), тому тіло лишено дослівно як було.
Import-Module (Resolve-Path "$PSScriptRoot/KitFixtures.psm1").Path -Force
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

function script:Add-KitDuringPassStagedEditHook {
    <#
    .SYNOPSIS
        Правка людини ПІД ЧАС проходу, ЗАСТЕЙДЖЕНА в СПРАВЖНІЙ індекс: хук
        post-index-change один раз дописує рядок у -Rel і робить `git add`.
    .DESCRIPTION
        I-5 (фінальне рев'ю блоку). Чому не через pre-commit (Add-KitDuringPassPreCommitHook):
        для ЧАСТКОВОГО коміту (`git commit --only -- <шляхи>`) git виконує pre-commit із
        GIT_INDEX_FILE = ТИМЧАСОВИЙ індекс цього коміту, тож `git add` усередині pre-commit
        потрапляє в коміт навіть при --only. Перевірено справжнім git окремим прогоном:
        README.md опинявся в коміті попри `--only -- src tgt`. Такий тест був би червоним і
        з фіксом, і без нього — тобто не розрізняв би їх узагалі.

        post-index-change спрацьовує на першому ж записі індексу самого проходу (git rm /
        git mv), тобто правка стає застейдженою в основному індексі ДО коміту — рівно та
        форма, яку `git commit -F` без pathspec затягував у коміт перейменування, а
        `git commit --only -- <два піддерева>` лишає застейдженою й незакоміченою.

        Маркер `.git/kit-staged-edit-done` рятує від рекурсії: `git add` усередині хука сам
        пише індекс і викликав би хук знову.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)][string]$Content
    )
    $body = @(
        '#!/bin/sh'
        '[ -f .git/kit-staged-edit-done ] && exit 0'
        ': > .git/kit-staged-edit-done'
        "printf '%s\n' '$Content' >> '$Rel'"
        "git add -- '$Rel'"
        'exit 0'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $Repo '.git/hooks/post-index-change'), "$body`n", [System.Text.UTF8Encoding]::new($false))
}

function script:Get-TestGitStatus {
    param([Parameter(Mandatory)][string]$Repo)
    @(Invoke-TestGit -Repo $Repo -GitArgs @('-c', 'core.quotepath=false', 'status', '--porcelain') |
        ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

function script:Add-KitOccupyTargetHook {
    <#
    .SYNOPSIS
        Хук post-index-change, що ОДИН раз створює й СТЕЙДЖИТЬ чужий файл за адресою
        -OccupyRel — тобто "хтось зайняв цільовий шлях" ПІД ЧАС проходу.
    .DESCRIPTION
        post-index-change спрацьовує на кожен запис індексу, зокрема на першому ж
        `git mv` — тобто вже після запобіжників на старті (їх чужий файл не бентежить,
        бо на момент перевірки його ще не існує). Коли цикл `git mv` дійде до
        перейменування, ціль якого зайнято, git відмовиться ("destination exists") — і
        це рівно та форма, яка ВИКЛИКАЄ відкіт (знахідка 1, рев'ю раунду 5).

        Маркер `.git/kit-occupy-done` рятує від рекурсії: `git add` усередині хука сам
        пише індекс і викликав би хук знову.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$OccupyRel,
        [Parameter(Mandatory)][string]$Content
    )
    $dirRel = ($OccupyRel -replace '/[^/]+$', '')
    $body = @(
        '#!/bin/sh'
        '[ -f .git/kit-occupy-done ] && exit 0'
        ': > .git/kit-occupy-done'
        "mkdir -p '$dirRel'"
        "printf '%s\n' '$Content' > '$OccupyRel'"
        "git add -- '$OccupyRel'"
        'exit 0'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $Repo '.git/hooks/post-index-change'), "$body`n", [System.Text.UTF8Encoding]::new($false))
}

function script:Add-KitBreakRestoreHook {
    <#
    .SYNOPSIS
        Ламає АВТОМАТИЧНИЙ відкіт, не заважаючи запобіжникам на старті: хук
        post-index-change ставить обов'язковий smudge-фільтр на дерево джерела.
    .DESCRIPTION
        Потрібно для знахідки 2 (рев'ю раунду 5): наскрізний тест рецепту, що виконує його
        на репозиторії, де автоматичний відкіт УЖЕ все відновив, не розрізняє правильний
        рецепт від будь-якого іншого, що не падає — рев'юер підмінив рядок рецепту на
        завідомо неправильний і отримав 114/114 зелених. Щоб рецепт мав що робити,
        джерело мусить лишитись НЕвідновленим.

        Фільтр ставиться ВСЕРЕДИНІ вікна мутації (на першому ж записі індексу), тож
        `git status` запобіжника 1/4 його ще не бачить. `clean` — наскрізний `cat`, тож
        status/diff працюють; падає лише `smudge`, тобто рівно `git checkout` відкоту.
        Перевірено справжнім git: checkout завершується кодом 128
        ("smudge filter boom failed"), а джерело лишається переміщеним.
    #>
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$SourceRelPath)
    $body = @(
        '#!/bin/sh'
        '[ -f .git/kit-break-done ] && exit 0'
        ': > .git/kit-break-done'
        "printf '%s\n' '$SourceRelPath/** filter=boom' > .git/info/attributes"
        'git config filter.boom.clean cat'
        'git config filter.boom.smudge false'
        'git config filter.boom.required true'
        'exit 0'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $Repo '.git/hooks/post-index-change'), "$body`n", [System.Text.UTF8Encoding]::new($false))
}

function script:Repair-KitBrokenRestore {
    <# .SYNOPSIS Людина усунула причину, через яку автоматичний відкіт упав, і бере рецепт із виводу. #>
    param([Parameter(Mandatory)][string]$Repo)
    Remove-Item -LiteralPath (Join-Path $Repo '.git/info/attributes') -Force -ErrorAction SilentlyContinue
    Invoke-TestGit -Repo $Repo -GitArgs @('config', '--remove-section', 'filter.boom') | Out-Null
}

function script:Invoke-KitRecipeFromOutput {
    <#
    .SYNOPSIS
        Виконує рядки рецепту («  git …») з виводу команди ДОСЛІВНО й по порядку;
        повертає самі рядки, щоб тест міг звірити їх із очікуваним рецептом.
    .DESCRIPTION
        Знахідка 2 (рев'ю раунду 5) вимагає асерцію, прив'язану саме до РЯДКА РЕЦЕПТУ, а
        не до будь-якого тексту у виводі: попередня асерція збігалася з текстом помилки
        pruneErrors, тож упасти не могла. Відбір за «^пробіли + git » бере лише рецепт —
        текст помилки згадує git усередині речення, не з початку рядка.
    #>
    param([Parameter(Mandatory)][string]$Output, [Parameter(Mandatory)][string]$Repo)
    $recipe = @($Output -split "`r?`n" | Where-Object { $_ -match '^\s+git\s' } | ForEach-Object { $_.Trim() })
    foreach ($line in $recipe) {
        # Лапки навколо pathspec знімає оболонка; тут знімаємо їх самі, аргументи не склеюючи.
        $tokens = @($line -split '\s+' | Select-Object -Skip 1 | ForEach-Object { $_.Trim("'") })
        Invoke-TestGit -Repo $Repo -GitArgs $tokens | Out-Null
    }
    $recipe
}
