#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    # Прибрали з маніфесту блок розширення, лишили base —
    # source-set 'Alpha_SMB' і далі оголошено в v8project.yaml, а check про це мовчав.
    # Тут — дзеркальний сценарій: source-set у v8project.yaml Є, а маніфест його НЕ знає.
    It 'source-set у v8project.yaml без ключа в маніфесті — warn undeclared-source, код 0' {
        $repo = New-GoodRepo 'undeclared-source'
        # Ані git add, ані commit тут не потрібні: Invoke-KitCheck читає v8project.yaml з
        # ДИСКА через Read-V8Project, а не з git, і жодної перевірки чистоти робочої копії
        # в check.psm1 немає (стейджити тут нічого, а git add на щойно
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

    # .gitignore реального репозиторію мав рядок
    # v8project.local.yaml (Уніки), але не мав v8storagekit.local.yaml (kit) — накладка
    # показувалась як ?? і застейджилась би першим же git add -A.
    It 'v8storagekit.local.yaml не гітігноровано в корені — код 1, рівно ОДНА знахідка' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-not-ignored') -WithHooks -WithGitattributes
        # Власний .gitignore: покриває vendor, але БЕЗ рядка
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

    # Асиметрія, яку рев'ю знайшло наживо: check питав лише
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
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/agent_ib'
        git -C $repo add -f -- Alpha_SMB/v8project.local.yaml
        git -C $repo commit -qm 'фікстура: v8project.local.yaml закомічено силою попри .gitignore'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*git rm --cached*Alpha_SMB/v8project.local.yaml*'
        $r.Output | Should -BeLike '*ІСТОРІЇ*'
    }

    It 'v8project.local.yaml не гітігноровано правилом репозиторію — error local-ignored (exclude фікстури прибрано)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'local-not-ignored') -WithHooks
        $ex = Join-Path $repo '.git/info/exclude'
        Set-Content -LiteralPath $ex -Value (@(Get-Content -LiteralPath $ex | Where-Object { $_ -ne 'v8project.local.yaml' })) -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*v8project.local.yaml не гітігноровано*'
    }

    It 'без маніфесту — код 1 і підказка на onboarding' {
        $repo = New-GoodRepo 'no-manifest'
        Remove-Item -LiteralPath (Join-Path $repo 'v8storagekit.yaml')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8storagekit.yaml*onboarding*'
        # "З теки плагіна" саме собою не каже, де та тека.
        $r.Output | Should -BeLike '*claude plugin list*'
    }

    # mainBranch друкувався (рядок info manifest), але не
    # перевірявся: репозиторій із маніфестом mainBranch: trunk, де є лише main, давав код 0
    # без жодного натяку — внутрішня суперечність, видима з будь-якої машини, і саме в цю
    # гілку sync зіллє storage/*. warn (не error): код усе одно 0, бо свіжий репозиторій до
    # першого коміту головної гілки — законний стан.
    # Це половина дворівневого розрізнювача Test-KitBranchUnborn —
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

Describe 'kit check і решта команд — застарілий конфіг Уніки зупиняє все' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It 'check: стара форма infobase: у v8project.yaml — код 1; підсумок рахує воркспейси й джерела маніфесту, а не 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-cfg') -WithHooks -WithGitignore
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=build/ib'")
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*стара форма 'infobase:'*"
        # Воркспейс із помилкою конфігу до розв'язаного контексту не потрапляє, але в маніфесті він є.
        $r.Output | Should -BeLike '*Маніфест:*воркспейсів 1, джерел у перевірці 2 (*'
        $r.Output | Should -Not -BeLike '*воркспейсів 0*'
        $r.Output | Should -Not -BeLike '*джерел у перевірці 0*'
        $r.Output | Should -BeLike "*розв'язано 0*"
    }
    It 'check: ключі, які відхиляє сам раннер (builder, execution_timeout, basePath, partialLoadThreshold), — не знахідки kit' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'runner-keys') -WithHooks -WithGitignore -WithGitattributes
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value @('builder: DESIGNER', 'execution_timeout: 600000', 'execution_timeout_seconds: 600', 'basePath: x', 'push:', '  partialLoadThreshold: 10')
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike "*'builder'*"
        $r.Output | Should -Not -BeLike '*execution_timeout*'
        $r.Output | Should -Not -BeLike '*partialLoadThreshold*'
    }
    It 'sync на застарілому конфігу — зупинка на префлайті, build/sync не створено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-sync') -WithHooks -WithGitignore
        Add-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=build/ib'")
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'sync' -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*стара форма 'infobase:'*"
        Test-Path -LiteralPath (Join-Path $repo 'build/sync') | Should -BeFalse
    }
    # Закріплення контракту з Унікою, НЕ червоний-спершу тест: у check немає жодної
    # перевірки ключа tools, тож він зелений від початку. Він стереже від майбутньої суворої
    # перевірки невідомих ключів: Уніка дописує tools.platform.version у v8project.local.yaml сама.
    It 'контракт: tools.platform.version поруч з infobases.origin у v8project.local.yaml — не знахідка, база агента читається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'tools-platform') -WithHooks -WithGitignore -WithGitattributes
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @(
            'infobases:', '  origin:', "    connection: 'File=build/ib'", 'tools:', '  platform:', "    version: '8.3.27.1644'")
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*tools.platform*'
        # База агента прочитана: warn називає її теку «ще немає на диску», а не «не налаштована».
        $r.Output | Should -BeLike '*бази агента воркспейсу*ще немає на диску*'
        $r.Output | Should -Not -BeLike '*не налаштована*'
    }
}

Describe 'kit check — версія Уніки й раннера' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:FixDir = (Resolve-Path "$PSScriptRoot/fixtures/runner").Path
        function script:New-VersionedRunner([string]$Line) {
            $dir = Join-Path $TestDrive ('runner-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item -Path (Join-Path $script:FixDir '*') -Destination $dir -Recurse
            Set-Content -LiteralPath (Join-Path $dir 'version.txt') -Value $Line -Encoding ASCII
            Join-Path $dir 'v8-runner.cmd'
        }
    }
    It 'Уніка 0.15.2 — error unica-version, код 1, рецепт оновлення' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'old-unica') -WithHooks -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.15.2'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*[[]-]*0.15.2*claude plugin update unica@unica*'
    }
    It 'Уніка 0.17.0 — warn з процедурою звірки, код 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'newer-unica') -WithHooks -WithGitignore -WithGitattributes
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.17.0'))
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*[[]!]*0.17.0*unica-contract.md*'
    }
    It 'Уніка 0.16.0 — знахідок unica-version і runner-version немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'good-unica') -WithHooks -WithGitignore -WithGitattributes
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.16.0'))
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*плагін unica*'
        $r.Output | Should -Not -BeLike '*Раннер*'
    }
    It 'раннера немає (-RunnerPath на неіснуючий файл) — error runner-version, код 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-runner') -WithHooks -WithGitignore -WithGitattributes
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-RunnerPath', (Join-Path $TestDrive 'нема\v8-runner.exe'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*[[]-] Раннер Уніки недоступний: Раннер не знайдено*нема\v8-runner.exe*'
    }
    It 'властивість: без -RunnerPath і з фальшивим реєстром без раннера — теж error (kit не йде до справжньої Уніки)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'forgot-runner') -WithHooks -WithGitignore -WithGitattributes
        # Прямий запуск, без Invoke-KitCommand: фікстура сама підставила б фальшивий раннер.
        $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry -Version '0.16.0') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1 -Because $out
        $out | Should -BeLike '*[[]-] Раннер Уніки недоступний*'
    }
    It 'Уніки в реєстрі немає — error через runner-version (без окремого unica-version), текст каже, що dump працює' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-unica') -WithHooks -WithGitignore -WithGitattributes
        $reg = Join-Path $TestDrive 'no-unica.json'
        Set-Content -LiteralPath $reg -Encoding UTF8 -Value '{"version":2,"plugins":{}}'
        $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $repo -InstalledPluginsPath $reg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1 -Because $out
        $out | Should -BeLike '*[[]-] Раннер Уніки недоступний: Раннер не знайдено: Unica не встановлена*kit dump працює*'
        ([regex]::Matches($out, '\[-\]')).Count | Should -Be 1 -Because 'два error про одну причину — шум'
    }
    It 'фальшивий раннер 0.19.0 — warn runner-version з процедурою звірки, код 0' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'runner-019') -WithHooks -WithGitignore -WithGitattributes
        $r = Invoke-KitCommand -Kit $script:Kit -Command check -Repo $repo -More @('-RunnerPath', (New-VersionedRunner 'v8-runner 0.19.0'))
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*[[]!] Раннер v8-runner 0.19.0*0.18.x*unica-contract.md*'
    }
    It 'session-check прокидає -InstalledPluginsPath і -RunnerPath у check' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-unica') -WithHooks -WithGitignore
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'session-check' -Repo $repo -More @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry -Version '0.15.2'), '-RunnerPath', (Join-Path $TestDrive 'нема\v8-runner.exe'))
        # Обидві помилки (кожна з свого параметра) — у виводі session-check, що друкує лише errors, коли вони є.
        $r.Output | Should -BeLike '*0.15.2*'
        $r.Output | Should -BeLike '*Раннер Уніки недоступний*нема\v8-runner.exe*'
    }
}
