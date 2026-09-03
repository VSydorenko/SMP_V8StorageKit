#Requires -Version 7
Describe 'Hooks.psm1 і templates/githooks — захист storage/* (§3.3, шар 2)' {
    BeforeAll {
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
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*core.hooksPath*' }).Count | Should -Be 1
            @($f | Where-Object { $_.Level -eq 'error' -and $_.Message -like '*pre-commit*' }).Count | Should -BeGreaterOrEqual 1
        }
        It 'після встановлення — знахідок нуль' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-ok')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
            @(Test-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates).Count | Should -Be 0
        }
        It 'змінений хук — попередження про розбіжність із шаблоном плагіна' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'audit-drift')
            Install-KitGitHooks -RepoRoot $repo -TemplatesDir $script:Templates | Out-Null
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
    }
}
