#Requires -Version 7
Describe 'Hooks.psm1 і templates/githooks — захист storage/* (§3.3, шар 2)' {
    BeforeAll {
        # Знахідка рев'ю Task 1 B5, підтверджена й полагоджена в Task 6 (Step 6б): цей файл —
        # єдиний, де асерт покладається на кирилицю у виводі ДОЧІРНЬОГО процесу (git merge через
        # pre-merge-commit, рядок 74 нижче). UTF-8 для читання цього виводу виставляє лише
        # Run-Tests.ps1 (рядки 25-26) — голий Invoke-Pester успадковує кодову сторінку консолі
        # (866 на цій машині типово) і валить порівняння детерміновано, а не «час від часу»: не
        # плутати з флаком. Виставляємо тут само, а не лише покладаємось на раннер.
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Templates = (Resolve-Path "$PSScriptRoot/../../templates/githooks").Path

        # Гілка storage/X у ГОЛОВНІЙ робочій копії — саме там людина чи агент могли б
        # помилково закомітити. Створюємо orphan і повертаємось на main.
        function script:New-RepoWithStorageBranch {
            param([string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name)
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo checkout -q --orphan storage/Alpha_SMB
            git -C $repo rm -rq --cached . 2>$null
            git -C $repo clean -fdq -e .githooks
            New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/cfe/src') -Force | Out-Null
            # Файл НЕ Configuration.xml (дефект брифа, знайдений і виправлений тут): main з
            # New-KitFakeRepo уже має Alpha_SMB/cfe/src/Configuration.xml зі справжнім вмістом
            # (New-KitFakeConfigurationXml). Однакова назва в orphan-гілці дала б реальний
            # git-конфлікт add/add при злитті (несумісні історії, той самий шлях, різний
            # вміст) — а pre-merge-commit git НЕ викликає, коли злиття впало на конфлікті:
            # тест на «злиття відхилено ХУКОМ» не дістався б хука і падав би на повідомленні
            # git про конфлікт замість повідомлення хука. Інша назва файлу прибирає збіг шляху.
            Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/StorageMirror.xml') -Value '<x/>'
            git -C $repo add -A -- Alpha_SMB
            $env:V8KIT_SYNC = '1'
            try { git -C $repo commit -q -m "v1`n`nStorage-Source: Alpha_SMB`nStorage-Version: 1" }
            finally { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }
            git -C $repo checkout -q main
            $repo
        }
    }
    AfterEach { Remove-Item Env:V8KIT_SYNC -ErrorAction SilentlyContinue }

    It 'Install-KitGitHooks кладе обидва файли й ставить core.hooksPath' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'install')
        $installed = @(Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
        $installed.Count | Should -Be 2
        Join-Path $repo '.githooks/pre-commit' | Should -Exist
        Join-Path $repo '.githooks/pre-merge-commit' | Should -Exist
        (git -C $repo config --get core.hooksPath) | Should -Be '.githooks'
    }

    It 'коміт на storage/X без V8KIT_SYNC відхилено; HEAD не зрушив' {
        $repo = New-RepoWithStorageBranch -Name 'reject'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/stray.xml') -Value '<y/>'
        git -C $repo add -A -- Alpha_SMB
        $out = git -C $repo commit -q -m 'ручний коміт' 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -BeLike "*v8storagekit*storage/Alpha_SMB*"
        (git -C $repo rev-parse HEAD) | Should -Be $before
    }

    It 'з V8KIT_SYNC=1 той самий коміт проходить' {
        $repo = New-RepoWithStorageBranch -Name 'allow'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/v2.xml') -Value '<z/>'
        git -C $repo add -A -- Alpha_SMB
        $env:V8KIT_SYNC = '1'
        git -C $repo commit -q -m "v2`n`nStorage-Source: Alpha_SMB`nStorage-Version: 2" 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        (git -C $repo rev-parse HEAD) | Should -Not -Be $before
    }

    It 'pre-merge-commit відхиляє злиття в storage/X: merge-коміту немає, HEAD той самий' {
        $repo = New-RepoWithStorageBranch -Name 'merge'
        git -C $repo checkout -q storage/Alpha_SMB
        $before = git -C $repo rev-parse HEAD
        $out = git -C $repo merge --no-ff --allow-unrelated-histories --no-edit main 2>&1 | Out-String
        $out | Should -BeLike '*v8storagekit*дзеркало*'
        (git -C $repo rev-parse HEAD) | Should -Be $before
        git -C $repo merge --abort 2>$null
    }

    It 'у звичайній гілці хук мовчить' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'silent')
        Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'note.md') -Value 'робота'
        git -C $repo add -A
        git -C $repo commit -q -m 'звичайний коміт' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    Context 'Test-KitGitHooks — аудит для check' {
        It 'свіжий репозиторій без хуків — помилки про core.hooksPath і файли' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-none')
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            # Звужено до "*не вказує*" (правка H1): тепер "git config core.hooksPath" згадує
            # й повідомлення про відсутній файл хука (порада, куди його ввімкнути), тож
            # голий '*core.hooksPath*' ловив би вже три знахідки замість однієї — тест мав
            # на увазі саме "не налаштовано", а не будь-яку згадку рядка.
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*core.hooksPath не вказує*' }).Count | Should -Be 1
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*pre-commit*' }).Count | Should -BeGreaterOrEqual 1
        }

        # H1 (фінальне рев'ю, живий онбординг з нуля) — повідомлення казало ЧОГО бракує, і
        # не казало, ДЕ взяти файл. Тепер називає джерело (templates/githooks/ у теці
        # плагіна), як його знайти (H3 — claude plugin list) і другий крок (core.hooksPath).
        It 'H1: повідомлення про відсутній хук називає джерело, теку плагіна й git config core.hooksPath' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-hook-source')
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $missing = @($f | Where-Object { $_.Message -like '*pre-commit*немає*' })
            $missing.Count | Should -Be 1
            $missing[0].Message | Should -BeLike '*templates/githooks*'
            $missing[0].Message | Should -BeLike '*claude plugin list*'
            $missing[0].Message | Should -BeLike '*git config core.hooksPath*'
        }
        # S2 (живий прогін задачі 11): Install-KitGitHooks сам по собі кладе файли на диск,
        # але НЕ чіпає індекс споживача (навмисно — див. коментар над Test-KitGitHooks).
        # До задачі 11 це давало 0 знахідок — і саме так виглядав би репозиторій-споживач,
        # де хуки скопійовано, але не закомічено: наступний клон їх не отримає. Тепер це
        # `warn`, по одному на кожен файл — далі тест на «застейджено» і «закомічено»
        # доводить, що межа не поїхала в інший бік.
        It 'S2: після Install-KitGitHooks без git add — попередження, що хуки не закомічені' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-uncommitted-untracked')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $warns = @($f | Where-Object { $_.Level -eq 'warn' -and $_.Message -like '*не закомічений*' })
            $warns.Count | Should -Be 2
            ($warns.Message -join ' | ') | Should -BeLike '*pre-commit*'
            ($warns.Message -join ' | ') | Should -BeLike '*pre-merge-commit*'
        }
        It 'змінений хук — попередження про розбіжність із шаблоном плагіна' {
            # Закомічено (і з бітом виконання) — щоб S2 ("не закомічений") і перевірка біта
            # тут мовчали, і єдиною знахідкою лишалась саме розбіжність із шаблоном.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-drift')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo add .githooks
            git -C $repo update-index --chmod=+x .githooks/pre-commit
            git -C $repo update-index --chmod=+x .githooks/pre-merge-commit
            git -C $repo commit -q -m 'install hooks'
            Add-Content -LiteralPath (Join-Path $repo '.githooks/pre-commit') -Value '# локальна правка'
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $f.Count | Should -Be 1
            $f[0].Level | Should -Be 'warn'
            $f[0].Message | Should -BeLike '*pre-commit*шаблон*'
        }

        It 'закомічений хук без біта виконання — попередження саме про нього, не про пару' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-mode-warn')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo add .githooks
            # Форсуємо режим явно для обох файлів: на POSIX-раннері Install-KitGitHooks
            # уже сам виставив би 100755 (chmod), а на цій Windows-машині (core.filemode
            # false) git add дав би 100644 обом незалежно від нього — тест не покладається
            # на платформу прогону, а відтворює точний сценарій «один хук без біта».
            git -C $repo update-index --chmod=-x .githooks/pre-commit
            git -C $repo update-index --chmod=+x .githooks/pre-merge-commit
            git -C $repo commit -q -m 'хуки закомічено, pre-commit — без біта виконання'
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            $f.Count | Should -Be 1
            $f[0].Level | Should -Be 'warn'
            $f[0].Message | Should -BeLike '*pre-commit*'
            $f[0].Message | Should -Not -BeLike '*pre-merge-commit*'
        }

        It 'встановлені, але ще не закомічені хуки — про біт виконання знахідок немає' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-mode-untracked')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            @($f | Where-Object { $_.Message -like '*біта виконання*' }).Count | Should -Be 0
        }

        # Продовження S2: другий і третій стан з тих самих трьох (untracked — тест вище).
        It 'S2: хук застейджений (git add), ще не закомічений — попередження про коміт немає' {
            # git ls-files -s бачить ІНДЕКС, тож застейджений хук уже дає непорожній рядок —
            # це та межа, яку задача 11 просила явно перевірити тестом, не лише проговорити.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-uncommitted-staged')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo add .githooks
            # Форсуємо біт виконання явно (як і в тесті вище про 100644) — інакше на цій
            # Windows-машині git add дав би 100644 обом і додав би ЧУЖУ знахідку (про біт),
            # яка тут ні до чого: цей тест перевіряє лише «не закомічено», не «без біта».
            git -C $repo update-index --chmod=+x .githooks/pre-commit
            git -C $repo update-index --chmod=+x .githooks/pre-merge-commit
            $f = @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates)
            @($f | Where-Object { $_.Message -like '*не закомічений*' }).Count | Should -Be 0
        }

        It 'S2: хук встановлений, застейджений і закомічений — знахідок нуль' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-uncommitted-committed')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            git -C $repo add .githooks
            git -C $repo update-index --chmod=+x .githooks/pre-commit
            git -C $repo update-index --chmod=+x .githooks/pre-merge-commit
            git -C $repo commit -q -m 'install hooks'
            @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates).Count | Should -Be 0
        }
    }
}
