#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

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
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
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
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'`n    user: 'Адмін'"
        $repo = New-GoodRepo 'local-audit-normalized' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'srvr=vsdev; ref=smp_unf'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It '§2.5/F1: infobase.connection у v8project.local.yaml нерозбірне (Srvr= без Ref=) — error, а не тиша' {
        # F1 (рев'ю B4 Task 1): fail-closed. Test-KitSameInfobase кидає на нерозбірному
        # підключенні (тут — навіть раніше, на Resolve-KitAgentInfobasePath: ConvertFrom-V8Connection
        # вимагає Ref= для Srvr=), а check МАЄ перетворити цей throw на знахідку error, не
        # впасти й не мовчати — суперечливий репозиторій має бути видимий у звіті check.
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
        $repo = New-GoodRepo 'local-audit-unparseable' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=VSDEV;'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*'
    }

    It '§2.5: серверна база АГЕНТА у v8project.local.yaml, якої немає в накладці, — не помилка' {
        $overlay = "infobases:`n  dev:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
        $repo = New-GoodRepo 'local-agent' @{ OverlayText = $overlay }
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=VSDEV;Ref=agent_alpha;'"
        (Invoke-Check -Repo $repo).ExitCode | Should -Be 0
    }

    It 'issue #9: infobase.connection = Srvr=SRV;Ref=BASE; (без лапок) — немає знахідки про нерозбірне підключення' {
        $repo = New-GoodRepo 'quotes-none'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=SRV;Ref=BASE;'"
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*лапк*'
        $r.Output | Should -Not -BeLike '*нерозбірне*'
    }

    It 'issue #9: infobase.connection = Srvr="SRV";Ref="BASE"; (у лапках) — знахідка error з текстом про лапки, не падіння check' {
        $repo = New-GoodRepo 'quotes-agent'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=""SRV"";Ref=""BASE"";'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*лапк*'
    }

    It 'issue #9: local-audit файлової бази агента без truth: storage (лише через v8project.local.yaml) — File= без лапок теж ловить збіг' {
        # Ізолює саме гілку local-audit (check.psm1) від труби Resolve-KitAgentBase (труба
        # truth: storage, вище в цьому файлі): жодне джерело тут не truth: storage, тож
        # Resolve-KitAgentBase (агент-base-required) не викликається взагалі — колізію
        # може зловити ЛИШЕ local-audit, що читає v8project.local.yaml напряму. Без цього
        # тесту повернення подвійної серіалізації в лапках ($localAuditConn у check.psm1,
        # AgentBase.psm1 має свій незалежний тест на той самий хак у Resolve-KitAgentBase)
        # лишилось би непоміченим.
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(
            @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) } }
        $manifest = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: dev } }',
            '      Alpha_SMB: { truth: git }'
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'local-audit-file-only') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        $ibDir = [System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib'))
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'File=build/ib'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*v8project.local.yaml*dev*'
    }

    It 'задача 3 (issue #9): дев-база з накладки в лапках без бази агента для звірки — warn overlay-connection, код не error-овий' {
        # До задачі 3 ConvertFrom-V8Connection на дев-базі з infobases: викликала лише
        # звірка з базою агента (Resolve-KitAgentBase, труба truth: storage) або local-audit
        # (v8project.local.yaml). Тут немає ні того, ні того — жодне джерело не truth:
        # storage (Resolve-KitAgentBase не викликається взагалі, той самий прийом ізоляції,
        # що й у тесті вище), і v8project.local.yaml у воркспейсі немає (Infobase у $ws не
        # задано) — жоден інший аудит на цій дев-базі спрацювати не може. Стара форма в
        # лапках (яку kit сам роздавав у templates/v8storagekit.local.yaml.example до цієї
        # гілки) до фіксу проходила б check кодом 0 без жодного рядка.
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(
            @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) } }
        $manifest = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: dev } }',
            '      Alpha_SMB: { truth: git }'
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-conn-quoted') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        $overlay = @('infobases:', '  dev: { connection: ''Srvr="SRV";Ref="BASE";'' }') -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Not -Be 1
        $r.Output | Should -BeLike '*[!]*Дев-база ''dev''*лапках*'
    }

    It 'задача 3 (issue #9): та сама дев-база без лапок — знахідки overlay-connection немає' {
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(
            @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) } }
        $manifest = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: dev } }',
            '      Alpha_SMB: { truth: git }'
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-conn-unquoted') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        $overlay = @('infobases:', "  dev: { connection: 'Srvr=SRV;Ref=BASE;' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -BeLike '*Дев-база*'
    }

    It 'задача 3 (issue #9): дев-база в лапках без бази агента для звірки — kit session-check не виходить кодом 1' {
        # session-check спершу кличе Invoke-KitCheck -Quiet (session-check.psm1): лише
        # error-знахідки піднімають його до коду 1 ("Сигнали не обчислювались"). Ця дев-база
        # дає щойно додану WARN 'overlay-connection' — код 1 тут означав би, що новий
        # запобіжник помилково піднятий на рівень error.
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(
            @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
            @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }) } }
        $manifest = @(
            'version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:',
            '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: dev } }',
            '      Alpha_SMB: { truth: git }'
        ) -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'overlay-conn-quoted-session') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        $overlay = @('infobases:', '  dev: { connection: ''Srvr="SRV";Ref="BASE";'' }') -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-KitCommand -Kit $script:Kit -Command 'session-check' -Repo $repo
        $r.ExitCode | Should -Not -Be 1
        $r.Output | Should -BeLike '*[!]*Дев-база ''dev''*лапках*'
    }

    It 'devInfobase: (стара конвенція) не мовчить — warn із порадою про infobases:' {
        # Знахідка живого прогону B4 на SMP_BankExchange: у живих репозиторіях цей файл несе
        # devInfobase:, а не infobase:. Read-V8ProjectLocalInfobase на ньому повертає $null,
        # тож ГІЛКА АУДИТУ ВИЩЕ ПРОПУСКАЄТЬСЯ БЕЗ ЖОДНОГО РЯДКА — саме це й треба зловити.
        # Вирізати elseif із check.psm1 → вивід більше не містить 'devInfobase' і тест червоніє.
        $repo = New-GoodRepo 'legacy-devinfobase' @{}
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "devInfobase:`n  connection: 'Srvr=VSDEV;Ref=SMP_UNF;'`n  user: 'Адмін'"
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*devInfobase*'
        $r.Output | Should -BeLike '*infobases:*'
        # Саме warn, не error: репозиторій робочий, sync і canon працюють. Якби рівень підняли
        # до error, код став би 1 — а разом із ним session-check перестав би рахувати сигнали.
        $r.Output | Should -BeLike '*[!]*devInfobase*'
        $r.ExitCode | Should -Be 0
    }

    It 'штатний infobase: цієї знахідки НЕ дає — правило не спрацьовує там, де все правильно' {
        # Другий бік того самого правила. Без цього тесту знахідка могла б з'являтись на
        # кожному правильному репозиторії, і ніхто б не помітив: перший тест від цього
        # лишається зеленим. Той самий урок, що двічі коштував блоку Critical — перевіряти
        # треба не лише те, що правило забороняє, а й те, що воно мусить пропускати.
        $repo = New-GoodRepo 'modern-infobase' @{}
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 `
            -Value "infobase:`n  connection: 'Srvr=VSDEV;Ref=agent_alpha;'"
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*devInfobase*'
        $r.ExitCode | Should -Be 0
    }
}
