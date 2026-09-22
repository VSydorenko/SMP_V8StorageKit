#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It '§2.6: truth: vendor без правила в .gitignore — код 1 (git check-ignore)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ignore') -WithHooks -WithGitattributes
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cf/src*.gitignore*'
    }

    It '§2.6: дерево платформи без -text — код 1 (git check-attr)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-text') -WithHooks -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*-text*'
    }

    It '§2.6: дерево, яке має бути в git, помилково гітігноровано — код 1' {
        $repo = New-GoodRepo 'over-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value 'Alpha_SMB/cfe/src/**'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_SMB/cfe/src*.gitignore*'
    }

    It '§2.6: vendor-дерево закомічене всупереч .gitignore (git add -f) — код 1, факт відстеження' {
        # Правило в .gitignore є (WithGitignore), тому питання "правил" мовчить — тут
        # інша перевірка: факт. Файл додано силою (git add -f), так само, як хтось міг би
        # це зробити руками попри правило.
        $repo = New-GoodRepo 'vendor-tracked'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'base')
        git -C $repo add -f -- Alpha_SMB/cf/src/Configuration.xml
        git -C $repo commit -qm 'фікстура: vendor закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        # '*Alpha_SMB/cf/src*' сам собою не діагностичний: цей шлях є і в повідомленні
        # перевірки "правил" (не гітігноровано), і в повідомленні перевірки "факту"
        # (відстежується). '*git rm -r --cached*' звужує саме до другої — тієї, яку цей
        # тест і має перевіряти.
        $r.Output | Should -BeLike '*git rm -r --cached*'
    }

    # Task 1 (B8): артефакти збірки (*.epf/*.erf/*.cfe/*.cf) у git не лежать — рішення
    # користувача 2026-09-10. Живий приклад, який фіксує цей інваріант: SMP_BankExchange мав
    # epf/dist/*.epf ЗАКОМІЧЕНИМ під воркспейсом, а templates/gitignore слова dist не знав.
    It 'Task 1: закомічений .epf під воркспейсом (поза workPath) — warn build-artifacts, код 0' {
        $repo = New-GoodRepo 'build-artifacts-committed'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'Alpha_SMB/epf/dist') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/epf/dist/Foo.epf') -Value 'fake epf' -Encoding UTF8
        # -f: Task 1 щойно додав dist/ у templates/gitignore (Step 1) саме тому, що в СТАРІЙ формі
        # цього правила не було — фікстура тут відтворює вже закомічений спадок, а не нове
        # порушення; без -f git мовчки пропустив би файл, і тест нічого не перевіряв би.
        git -C $repo add -f -- Alpha_SMB/epf/dist/Foo.epf
        git -C $repo commit -qm 'фікстура: .epf закомічено поза workPath (спадок форми до 1.0)'
        $r = Invoke-Check -Repo $repo
        # warn, НЕ error (спека рівня): error завалив би перехід репозиторію за законний стан
        # форми 0.6.0 — код лишається 0.
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[!]*артефакти збірки*Foo.epf*'
        $r.Output | Should -BeLike '*git rm --cached*'
    }

    # Другий тест не декоративний (брифа задачі): він відрізняє інваріант «артефакт НЕ В GIT» від
    # «файла з таким розширенням НІДЕ немає» — це різні речі. Файл тут ТАКОЖ закомічений (git
    # ls-files його бачить), просто лежить під workPath/artifacts, куди пише kit build.
    It 'Task 1: той самий файл, закомічений УСЕРЕДИНІ build/artifacts/ — check мовчить про build-artifacts' {
        $repo = New-GoodRepo 'build-artifacts-in-place'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'Alpha_SMB/build/artifacts') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/artifacts/Foo.epf') -Value 'fake epf' -Encoding UTF8
        # -f: build/ гітігноровано шаблоном (templates/gitignore) — тут навмисно закомічений
        # виняток, щоб довести, що саме ФАКТ перебування під workPath/artifacts, а не сама
        # відсутність файлу, гасить попередження.
        git -C $repo add -f -- Alpha_SMB/build/artifacts/Foo.epf
        git -C $repo commit -qm 'фікстура: .epf закомічено під workPath/artifacts'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        # '*артефакти збірки*' — текст самого повідомлення (людський вивід); тег знахідки
        # 'build-artifacts' у Write-Host не друкується (лише Message), і збігся б із назвою
        # теки фікстури нижче — тому саме ця фраза, а не тег.
        $r.Output | Should -Not -BeLike '*артефакти збірки*'
    }

    It '§3.2: немонотонна гілка storage/X — код 1; лінійна з кореневим комітом — 0' {
        $repo = New-GoodRepo 'branch'
        foreach ($v in 5, 9) {
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName "v$v.xml" `
                -Trailers @('Storage-Source: Alpha_SMB', "Storage-Version: $v")
        }
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0

        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'v7.xml' `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 7')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*storage/Alpha_SMB*9*7*'
    }

    It '§3.3: core.hooksPath не встановлено — код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-hooks') -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*core.hooksPath*'
    }

    It 'хук старту сесії: без шима — [i] із session-start.ps1, код 0; зі зміненим шимом — [!] із session-start.ps1' {
        $repo = New-GoodRepo 'session-hook'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[i]*session-start.ps1*'

        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Hooks.psm1").Path -Force
        Install-KitSessionHook -RepoRoot $repo -TemplatesDir (Resolve-Path "$PSScriptRoot/../../templates").Path | Out-Null
        Add-Content -LiteralPath (Join-Path $repo '.claude/hooks/session-start.ps1') -Value '# локальна правка'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*[!]*session-start.ps1*'
    }

    It '§2.3: той самий ключ truth: storage у двох воркспейсах — код 1' {
        $two = [ordered]@{
            'A' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'B' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'Shared'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dup-keys') -Workspaces $two -WithHooks -WithGitattributes -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Shared*A*B*'
    }
}
