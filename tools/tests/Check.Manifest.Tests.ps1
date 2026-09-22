#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    # S1 (живий прогін задачі 11): прибрали з маніфесту блок розширення, лишили base —
    # source-set 'Alpha_SMB' і далі оголошено в v8project.yaml, а check про це мовчав.
    # Тут — дзеркальний сценарій: source-set у v8project.yaml Є, а маніфест його НЕ знає.
    It 'S1: source-set у v8project.yaml без ключа в маніфесті — warn undeclared-source, код 0' {
        $repo = New-GoodRepo 'undeclared-source'
        # Ані git add, ані commit тут не потрібні: Invoke-KitCheck читає v8project.yaml з
        # ДИСКА через Read-V8Project, а не з git, і жодної перевірки чистоти робочої копії
        # в check.psm1 немає (рев'ю задачі 11 — стейджити тут нічого, а git add на щойно
        # народженому LF-файлі фікстури лише додавав зайве попередження "LF will be
        # replaced by CRLF" без жодної користі для самого тесту).
        $vp = Join-Path $repo 'Alpha_SMB/v8project.yaml'
        $extra = @(
            '  - name: Extra'
            '    type: EXTERNAL_DATA_PROCESSORS'
            "    path: 'epf/src'"
        ) -join "`n"
        Add-Content -LiteralPath $vp -Encoding UTF8 -Value $extra
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
        # Рівно одна знахідка на весь репозиторій — не по одній на джерело (2 sources у
        # цій фікстурі: base, Alpha_SMB — якби перевірка стояла в циклі, рядків було б 2).
        $lines = @(($r.Output -split "`r?`n") | Where-Object { $_ -like '*не гітігноровано в корені репозиторію*' })
        $lines.Count | Should -Be 1
    }

    # Правка 1 (фінальне рев'ю) — асиметрія, яку рев'ю знайшло наживо: check питав лише
    # "чи є ПРАВИЛО в .gitignore", і мовчав, коли правило Є, а файл уже ЗАКОМІЧЕНО (git add
    # -f, або з часів до появи правила) — код 0, одне попередження, а рядки підключення й
    # користувачі сховищ уже в історії публічного репозиторію. Другий, незалежний, запит:
    # факт відстеження (той самий зразок, що вже стоїть для truth: vendor).
    It 'S3-факт: v8storagekit.local.yaml гітігноровано ПРАВИЛОМ, але вже закомічено (git add -f) — код 1, факт відстеження, рівно ОДНА знахідка' {
        $repo = New-GoodRepo 'overlay-tracked'
        # CRLF, не LF (`r`n, не `n): .gitattributes фікстури — text=auto, і на цій машині
        # (core.autocrlf false, core.eol типово native=CRLF) checkout дав би саме CRLF.
        # LF-вміст тут спричинив би зайве "LF will be replaced by CRLF" при git add — той
        # самий прийом, що вже застосовано в New-KitFakeConfigurationXml.
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value "storages:`r`n  dummy: 'x'"
        git -C $repo add -f -- v8storagekit.local.yaml
        git -C $repo commit -qm 'фікстура: v8storagekit.local.yaml закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*git rm --cached*v8storagekit.local.yaml*'
        # Порада самого check ("додайте рядок у .gitignore") сама по собі не прибирає файл
        # з ІСТОРІЇ — це головне, чого людина сама не здогадається, і повідомлення мусить
        # про це сказати прямо.
        $r.Output | Should -BeLike '*ІСТОРІЇ*'
        # Рівно одна знахідка на весь репозиторій — той самий доказ, що й у S3 вище: файл
        # один на корінь, перевірка стоїть ПОЗА циклом foreach ($src in $all).
        $lines = @(($r.Output -split "`r?`n") | Where-Object { $_ -like '*вже закомічено в git*' })
        $lines.Count | Should -Be 1
    }

    # Той самий дефект, той самий зразок фіксу — для v8project.local.yaml (файл Уніки),
    # якого check раніше не перевіряв УЗАГАЛІ. На відміну від kit-накладки (одна на
    # корінь), цей файл живе В КОЖНОМУ воркспейсі поруч зі своїм v8project.yaml.
    It 'v8project.local.yaml (файл Уніки) гітігноровано ПРАВИЛОМ, але вже закомічено — код 1, факт відстеження' {
        $repo = New-GoodRepo 'local-tracked'
        # CRLF — та сама причина, що в тесті вище про v8storagekit.local.yaml.
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`r`n  connection: 'File=build/agent_ib'"
        git -C $repo add -f -- Alpha_SMB/v8project.local.yaml
        git -C $repo commit -qm 'фікстура: v8project.local.yaml закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*git rm --cached*Alpha_SMB/v8project.local.yaml*'
        $r.Output | Should -BeLike '*ІСТОРІЇ*'
    }

    It 'без маніфесту — код 1 і підказка на onboarding' {
        $repo = New-GoodRepo 'no-manifest'
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
        # H3 — "з теки плагіна" саме собою не каже, де та тека.
        $r.Output | Should -BeLike '*claude plugin list*'
    }

    # Правка 3 (фінальне рев'ю) — mainBranch друкувався (рядок info manifest), але не
    # перевірявся: репозиторій із маніфестом mainBranch: trunk, де є лише main, давав код 0
    # без жодного натяку — внутрішня суперечність, видима з будь-якої машини, і саме в цю
    # гілку B2 зіллє storage/*. warn (не error): код усе одно 0, бо свіжий репозиторій до
    # першого коміту головної гілки — законний стан.
    # Задача 6 (спека a7a5d45): це половина дворівневого розрізнювача Test-KitBranchUnborn —
    # HEAD тут стоїть на 'main' (яка Є в репозиторії), а маніфест називає 'trunk' (якої немає) —
    # HEAD "деінде", не на самій відсутній гілці, тож це warn, не info. Другу половину
    # (unborn: HEAD саме на відсутній гілці, свіжий репозиторій) перевіряє тест нижче.
    It 'правка 3 / розрізнювач (HEAD деінде): mainBranch указує на гілку, якої немає, — warn, а не error, код 0' {
        $repo = New-GoodRepo 'main-branch-missing'
        $manifestPath = Join-Path $repo 'v8storagekit.yaml'
        $lines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
        Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value (@($lines[0], 'mainBranch: trunk') + $lines[1..($lines.Count - 1)])
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[!\].*trunk'
        $r.Output | Should -BeLike "*'trunk'*немає в репозиторії*перевірте mainBranch*"
        $r.Output | Should -Not -BeLike '*Свіжий репозиторій*'
    }

    # Друга половина розрізнювача: HEAD ще symbolic-ref на саму (відсутню) головну гілку —
    # свіжий репозиторій до першого коміту (Test-KitBranchUnborn = $true). info, не warn:
    # це законний стан онбордингу, а не описка чи розбіжність.
    It 'розрізнювач (unborn): HEAD ще на відсутній головній гілці — info, а не warn, код 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'main-branch-unborn') -WithHooks -WithGitattributes -WithGitignore -NoCommit
        (git -C $repo symbolic-ref -q HEAD) | Should -Be 'refs/heads/main'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\].*main'
        $r.Output | Should -BeLike "*Свіжий репозиторій*'main'*ще немає*перший коміт*"
        $r.Output | Should -Not -BeLike '*перевірте mainBranch*'
    }
}
