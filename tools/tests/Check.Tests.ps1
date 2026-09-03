#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        function script:Invoke-Check {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Репозиторій, у якому все правильно: хуки, політика тексту, gitignore.
        function script:New-GoodRepo {
            param([string]$Name, [hashtable]$Extra = @{})
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore @Extra
        }
    }

    It 'усе гаразд — код 0, лише інформаційні рядки' {
        $r = Invoke-Check -Repo (New-GoodRepo 'good')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
        $r.Output | Should -Not -Match '\[-\]'
    }

    # S1 (живий прогін задачі 11): прибрали з маніфесту блок розширення, лишили base —
    # source-set 'Alpha_SMB' і далі оголошено в v8project.yaml, а check про це мовчав.
    # Тут — дзеркальний сценарій: source-set у v8project.yaml Є, а маніфест його НЕ знає.
    It 'S1: source-set у v8project.yaml без ключа в маніфесті — warn undeclared-source, код 0' {
        $repo = New-GoodRepo 'undeclared-source'
        $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
        $extra = @(
            '  - name: Extra'
            '    type: EXTERNAL_DATA_PROCESSORS'
            "    path: 'epf/src'"
        ) -join "`n"
        # Пишемо чистим LF (нормалізуємо вміст явно, а не Add-Content) — гігієна, узгоджена
        # з рештою фікстур. Саму знахідку git add за такого дописування все одно свідомо не
        # чіпаємо: git тут попереджає "LF will be replaced by CRLF" за замовчуванням
        # (core.safecrlf: warn), навіть коли в дописаному файлі жодного зайвого CR немає —
        # перевірено побайтово. -c core.safecrlf=false на цьому виклику — те саме
        # придушення, що New-KitFakeRepo вже дає на весь репозиторій через core.autocrlf
        # false, лише для другого дотику до вже закомiченого файлу.
        $normalized = ((Get-Content -LiteralPath $vp -Raw) -replace "`r`n", "`n").TrimEnd("`n")
        Set-Content -LiteralPath $vp -Encoding UTF8 -NoNewline -Value ($normalized + "`n" + $extra + "`n")
        git -c core.safecrlf=false -C $repo add -A -- Alpha_SMB
        git -C $repo commit -qm 'фікстура: source-set без ключа в маніфесті'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike "*[!]*Extra*EXTERNAL_DATA_PROCESSORS*немає в маніфесті*"
    }

    # S3 (живий прогін задачі 11): .gitignore реального репозиторію мав рядок
    # v8project.local.yaml (Уніки), але не мав v8storagekit.local.yaml (kit) — накладка
    # показувалась як ?? і застейджилась би першим же git add -A.
    It 'S3: v8storagekit.local.yaml не гітігноровано в корені — код 1, рівно ОДНА знахідка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-not-ignored') -WithHooks -WithGitattributes
        # Власний .gitignore: покриває vendor (§2.6 мовчить), але БЕЗ рядка
        # v8storagekit.local.yaml — точно той стан, що застав тестувальник наживо.
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value @(
            '**/cf/**'
            '!**/cf/README.md'
            'v8project.local.yaml'
        )
        git -C $repo add -A -- .gitignore
        git -C $repo commit -qm 'фікстура: .gitignore без v8storagekit.local.yaml'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не гітігноровано в корені репозиторію*'
        # Рівно одна знахідка на весь репозиторій — не по одній на джерело (3 sources у
        # цій фікстурі: base, Alpha_SMB — якби перевірка стояла в циклі, рядків було б 2+).
        $lines = @(($r.Output -split "`r?`n") | Where-Object { $_ -like '*не гітігноровано в корені репозиторію*' })
        $lines.Count | Should -Be 1
    }

    It 'без маніфесту — код 1 і підказка на onboarding' {
        $repo = New-GoodRepo 'no-manifest'
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
    }

    It '§2.2: <Name> у Configuration.xml не збігається з ключем джерела — код 1, названо обидва' {
        $repo = New-GoodRepo 'name-mismatch'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml') -Encoding UTF8 -NoNewline `
            -Value (New-KitFakeConfigurationXml -Name 'Alpha_OLD')
        git -C $repo commit -qam 'фікстура: інше ім''я в Configuration.xml'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*Alpha_OLD*Alpha_SMB*Configuration.xml*'
    }

    It '§2.5: infobase.connection у v8project.local.yaml збігається з дев-базою з накладки — код 1' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It '§2.5: той самий конекшн, інакше записаний (регістр, пробіл, без ";") — усе одно код 1' {
        # Тест на саму нормалізацію (check.psm1: $norm), не на порівняння рядків: тут
        # накладка й v8project.local.yaml НЕ побайтово однакові — інший регістр, зайвий
        # пробіл після ";" і без завершальної ";". Якби $norm замінили на тотожність
        # (видалили нормалізацію), цей тест мав би почервоніти — на відміну від
        # попереднього (побайтово однакового), який пройшов би і без неї.
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit-normalized' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'srvr=""vsdev""; ref=""smp_unf""'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It '§2.5: серверна база АГЕНТА у v8project.local.yaml, якої немає в накладці, — не помилка' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        $repo = New-GoodRepo 'local-agent' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'"
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0
    }

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
    }

    # Правка 4 (живий прогін задачі 11): warn лишається warn, але текст має розвилку — інакше
    # людина бачить лише "перевизначте шлях" і не здогадується, що причина може бути в
    # самому маніфесті (живий приклад: маніфест указував …_ACC, а сховище лежало під …_BP).
    It 'правка 4: warn storage-path називає обидві розвилки — накладку і сам маніфест' {
        $r = Invoke-Check -Repo (New-GoodRepo 'storage-path-branches')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*якщо диск є, а шлях помилковий — виправте v8storagekit.yaml*'
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

    It '-Workspace звужує перевірку; невідомий — код 1 з переліком' {
        $repo = New-GoodRepo 'ws-filter'
        (Invoke-Check -Repo $repo -More @('-Workspace', 'Alpha_SMB')).ExitCode | Should -Be 0
        $r = Invoke-Check -Repo $repo -More @('-Workspace', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*Alpha_SMB*"
    }

    It 'check нічого не змінює: статус робочої копії й HEAD ті самі' {
        $repo = New-GoodRepo 'readonly'
        $head = git -C $repo rev-parse HEAD
        Invoke-Check -Repo $repo | Out-Null
        git -C $repo rev-parse HEAD | Should -Be $head
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }
}
