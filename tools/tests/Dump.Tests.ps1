#Requires -Version 7
Describe 'kit dump — прев''ю і штатні зупинки без платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Dump {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
    }

    It 'прев''ю: база, ціль і попередження про 20–40 хвилин; нічого не змінено' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'preview') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*/F "C:\bases\demo"*Alpha_SMB/cf/src*'
        $r.Output | Should -BeLike '*-Apply*'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'дев-бази з dump.from немає в накладці — зупинка з готовим блоком infobases:, ціль не чіпалась' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-ib') -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/marker.txt') -Value 'є'
        $r = Invoke-Dump -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'dev'*infobases:*connection:*"
        Join-Path $repo 'Alpha_SMB/cf/src/marker.txt' | Should -Exist
    }

    It 'Pwd у підключенні дев-бази — розбір падає до платформи: маркера немає, походження і рецепт є, ціль не чіпалась (П23)' {
        $overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;Usr=u;Pwd=СЕКРЕТ-Ж7SECRETZ7'"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dev-pwd') -OverlayText $overlay -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/marker.txt') -Value 'є'
        $r = Invoke-Dump -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
        $r.Output | Should -Not -BeLike '*SECRETZ7*'
        $r.Output | Should -BeLike "*Дев-база 'dev' у *v8storagekit.local.yaml*"
        $r.Output | Should -BeLike '*пароль дев-бази kit не підтримує*'
        # план розбирається до будь-якого запуску платформи: «Джерело:» (друк першого кроку циклу) немає
        $r.Output | Should -Not -BeLike '*Джерело:*'
        Join-Path $repo 'Alpha_SMB/cf/src/marker.txt' | Should -Exist
    }

    It 'без джерел truth: dump/vendor — код 0 і пояснення' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $r = Invoke-Dump -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws -WithHooks)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*dump*vendor*'
    }

    It '-Source на джерело з truth: storage — зупинка: дамп лише для dump/vendor' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wrong-truth') -OverlayText $script:Overlay -WithHooks
        $r = Invoke-Dump -Repo $repo -More @('-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Alpha_SMB*storage*'
    }
}

Describe 'kit dump — мок платформного шару: -Apply без реального 1cv8.exe (рев''ю Task 5, Important 2)' {
    # dump лишалась єдиною командою блоку без покриття Apply-гілки платформним моком —
    # Sync.Merge.Tests.ps1 і Verify.Tests.ps1 уже мають такий Describe для sync/verify (мок
    # New-ExtensionInfobase/Invoke-V8Designer -ModuleName StoragePlatform чи verify). Тут той
    # самий прийом: lib-модулі в порядку module-order.txt, потім САМЕ commands/dump.psm1 у
    # ЦЬОМУ процесі (не підпроцесом kit.ps1) — лише так Mock -ModuleName бачить приватний
    # стіл команд саме dump (Mock -ModuleName діє лише в межах названого модуля — урок Task 1,
    # повторений і в Sync.Merge.Tests.ps1, і в Verify.Tests.ps1).
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force

        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
    }

    It 'успіх із непорожньою текою — Dumped[0].Files рахує реально записані файли' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-happy') -OverlayText $script:Overlay -WithHooks
        # Мок навмисно пише РІВНО один файл: не лише "порожня тека" ламає голий .Count під
        # StrictMode (Important 2), а й тека РІВНО з одним елементом — Get-ChildItem тоді
        # віддає скалярний FileInfo, а не масив, і .Count так само кидає
        # PropertyNotFoundException (перевірено окремо, поза Pester). Цей тест ловить обидва
        # варіанти дефекту, а не лише порожню теку.
        Mock -ModuleName dump Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/DumpConfigToFiles "(?<p>[^"]+)"') {
                Set-Content -LiteralPath (Join-Path $Matches.p 'Configuration.xml') -Value 'x' -Encoding UTF8
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitDump -Context $ctx -Apply $true

        $result.ExitCode | Should -Be 0
        $result.Dumped.Count | Should -Be 1
        $result.Dumped[0].Files | Should -Be 1
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 1
    }

    It 'успіх (ExitCode 0) з порожньою текою — Files = 0 без винятку на .Count (Important 2)' {
        # Мок нічого не пише в ціль: платформа штатно повернула 0 файлів (наприклад,
        # -Extension, якого фактично немає в цій ІБ). Get-ChildItem на щойно створеній
        # порожній теці повертає $null, а не порожню колекцію — саме тут під
        # Set-StrictMode -Version Latest ловили сирий "The property 'Count' cannot be
        # found on this object" замість чесного "Готово. Файлів: 0". Цей тест — доказ
        # дефекту до правки і регресія на майбутнє.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-empty') -OverlayText $script:Overlay -WithHooks
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        $ctx = Invoke-KitPreflight -RepoRoot $repo

        $script:MockEmptyResult = $null
        { $script:MockEmptyResult = Invoke-KitDump -Context $ctx -Apply $true } | Should -Not -Throw
        $script:MockEmptyResult.ExitCode | Should -Be 0
        $script:MockEmptyResult.Dumped[0].Files | Should -Be 0
    }

    It 'ExitCode ≠ 0, «база зайнята» у виводі платформи — порада Assert-V8InfobaseNotBusy, не сирий вивід' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-busy') -OverlayText $script:Overlay -WithHooks
        Mock -ModuleName dump Invoke-V8Designer {
            [pscustomobject]@{ ExitCode = 1; Output = 'вже відкрита Конфігуратором' }
        }
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Invoke-KitDump -Context $ctx -Apply $true } | Should -Throw "*зайнята*Конфігуратором*"
    }

    It 'джерело типу EXTENSION — Arguments платформи несуть -Extension з ключем джерела' {
        $manifest = @('version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      Alpha_SMB: { truth: vendor, dump: { from: dev } }') -join "`n"
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-ext') -Workspaces $ws -ManifestText $manifest -OverlayText $script:Overlay -WithHooks
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        $ctx = Invoke-KitPreflight -RepoRoot $repo

        $null = Invoke-KitDump -Context $ctx -Apply $true

        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -match '-Extension Alpha_SMB'
        }
    }
}

Describe 'kit dump — жива дев-база (лише читання, 20–40 хв)' -Tag Integration -Skip:($env:V8KIT_LIVE_DUMP -ne '1') {
    # Запускається лише з V8KIT_LIVE_DUMP=1: це дорого й потребує доступу до бази людини.
    # -Skip: на Describe, а НЕ Set-ItResult у BeforeAll: Set-ItResult легальний лише всередині It,
    # а в BeforeAll кидає "a 'break' or 'continue' statement ... escaped from your code" і, без
    # захисту Pester, тихо обірвав би ВЕСЬ прогін без результату (живий прогін B3, pester#2669).
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $overlay = "infobases:`n  devUNF:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF_sydorenko;'`n    user: 'Администратор'"
        $manifest = @('version: 1', 'product: BankExchange', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }', "      Alpha_SMB: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -ManifestText $manifest -OverlayText $overlay -WithHooks -WithGitattributes -WithGitignore
    }
    It 'вивантажує конфігурацію в Alpha_SMB/cf/src; результат гітігнорований' {
        $out = & pwsh -NoProfile -File $script:Kit dump -RepoRoot $script:Repo -Source base -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $script:Repo 'Alpha_SMB/cf/src/Configuration.xml' | Should -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }
}

Describe 'kit dump -Apply — зупинка на невидимій і незакоміченій роботі під набором (§10.2 П24)' {
    # dump -Apply стирає теку набору цілком і копії незакоміченого не робить взагалі, тож зупинка
    # стоїть ДО Remove-KitDirectory і до платформи: на невидимій для git status роботі й на
    # будь-якому записі Get-KitDirtyRecords.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
        function script:New-DumpInvRepo { param([string]$Name)
            # Ціль дампу — розширення Alpha_SMB (truth: dump): його дерево відстежується git і не ігнорується,
            # тож є що губити й видно, що саме зупиняє. Вендорська конфігурація (дерево ціле гітігнороване)
            # окремо — контроль нижче.
            $manifest = @('version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
                '      Alpha_SMB: { truth: dump, dump: { from: dev } }') -join "`n"
            $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -ManifestText $manifest -OverlayText $script:Overlay -WithGitignore -WithHooks }
    }
    BeforeEach {
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    It 'файл під .git/info/exclude — зупинка з переліком і рецептом, тека ціла, платформа не запускалась' {
        $repo = New-DumpInvRepo 'dinv-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.git/info/exclude') -Value 'Alpha_SMB/cfe/src/mine.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/mine.txt') -Value 'робота' -Encoding UTF8
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*dump -Apply зупинено*невидима робота під набором*ignored*mine.txt*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/mine.txt' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }
    It '<Flag> на зміненому файлі — зупинка, тека ціла, платформа не запускалась' -ForEach @(
        @{ Flag = 'assume-unchanged' }
        @{ Flag = 'skip-worktree' }
    ) {
        $repo = New-DumpInvRepo "dinv-$Flag"
        $f = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
        Set-Content -LiteralPath $f -Value 'правка людини' -Encoding UTF8
        git -C $repo update-index "--$Flag" Alpha_SMB/cfe/src/Configuration.xml
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*flagged*Configuration.xml*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        (Get-Content -LiteralPath $f -Raw) | Should -BeLike '*правка людини*'
    }
    It 'gitlink під набором — зупинка, платформа не запускалась' {
        $repo = New-DumpInvRepo 'dinv-gitlink'
        $sha = (git -C $repo rev-parse HEAD).Trim()
        git -C $repo update-index --add --cacheinfo "160000,$sha,Alpha_SMB/cfe/src/sub"
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*gitlink*sub*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml' | Should -Exist
    }
    It 'вкладений git-репозиторій — зупинка (nested-repo), історія ціла, платформа не запускалась' {
        $repo = New-DumpInvRepo 'dinv-nested'
        $nest = Join-Path $repo 'Alpha_SMB/cfe/src/nest'
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        git -C $nest init -q
        Set-Content -LiteralPath (Join-Path $nest 'history.txt') -Value 'історія' -Encoding UTF8
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*nested-repo*Alpha_SMB/cfe/src/nest*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $nest '.git' | Should -Exist
        Join-Path $nest 'history.txt' | Should -Exist
    }
    It 'junction під набором — зупинка (link) з рецептом, ціль посилання ціла, платформа не запускалась' {
        $repo = New-DumpInvRepo 'dinv-junction'
        $target = Join-Path $TestDrive 'dinv-junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'ціль' -Encoding UTF8
        New-Item -ItemType Junction -Path (Join-Path $repo 'Alpha_SMB/cfe/src/lnk') -Target $target | Out-Null
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*link*Alpha_SMB/cfe/src/lnk*прибрати посилання з набору*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $target 'keep.txt' | Should -Exist
    }
    It 'звичайна незакомічена зміна (невідстежуваний файл) — зупинка, тека ціла, платформа не запускалась' {
        $repo = New-DumpInvRepo 'dinv-dirty-untracked'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/Нова.xml') -Value 'нова форма' -Encoding UTF8
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*dump -Apply зупинено*незакомічен*Alpha_SMB/cfe/src/Нова.xml*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/cfe/src/Нова.xml' | Should -Exist
    }
    It 'три незакомічені файли в новій теці — стоп-перелік містить рівно три записи (лічильник Get-KitDirtyRecords, не один згорнутий)' {
        # Get-KitDirtyRecords ділить вивід git status -z по NUL і кличе -uall: без цього нова тека давала б
        # ОДИН запис «?? Тека/», а вивід нативної команди без розбиття по NUL — один рядок на все.
        $repo = New-DumpInvRepo 'dinv-dirty-three'
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/НоваТека'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir "Ф$_.xml") -Value "файл $_" -Encoding UTF8 }
        $msg = try { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true; '' } catch { $_.Exception.Message }
        $msg | Should -BeLike '*dump -Apply зупинено*'
        ([regex]::Matches($msg, '\(набір Alpha_SMB\)')).Count | Should -Be 3
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
    }
    It 'звичайна незакомічена зміна (змінений відстежуваний файл) — зупинка, правка на місці' {
        $repo = New-DumpInvRepo 'dinv-dirty-tracked'
        $f = Join-Path $repo 'Alpha_SMB/cfe/src/Configuration.xml'
        Set-Content -LiteralPath $f -Value 'правка' -Encoding UTF8
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*незакомічен*Configuration.xml*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        (Get-Content -LiteralPath $f -Raw) | Should -BeLike '*правка*'
    }
    It 'контроль: чисте дерево з похідним (ConfigDumpInfo.xml, Ext/ParentConfigurations) — зупинки немає, платформа запущена' {
        $repo = New-DumpInvRepo 'dinv-derived'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/ConfigDumpInfo.xml') -Value '<x/>' -Encoding UTF8
        $d = Join-Path $repo 'Alpha_SMB/cfe/src/Ext/ParentConfigurations'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Vendor.cf') -Value 'cf' -Encoding ascii
        git -C $repo check-ignore -q 'Alpha_SMB/cfe/src/ConfigDumpInfo.xml'; $LASTEXITCODE | Should -Be 0 -Because 'контроль має спиратись на справді ігнорований файл'
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } | Should -Not -Throw
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 1
    }
    It 'контроль: чисте дерево без похідного — зупинки немає, платформа запущена' {
        $repo = New-DumpInvRepo 'dinv-clean'
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } | Should -Not -Throw
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 1
    }
}

Describe 'kit dump -Apply — вендорське дерево (гітігноровано цілком за задумом) не зупиняє на «ignored»' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
    }
    BeforeEach {
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    It 'truth: vendor, файли дампу в гітігнорованому дереві — зупинки немає, платформа запущена (інакше dump не пройшов би у штатному репозиторії)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dinv-vendor') -OverlayText $script:Overlay -WithGitignore -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Value 'кеш дампу' -Encoding UTF8
        git -C $repo check-ignore -q 'Alpha_SMB/cf/src/Configuration.xml'; $LASTEXITCODE | Should -Be 0 -Because 'контроль має спиратись на справді ігнорований файл'
        @(Get-KitInvisibleWork -RepoRoot $repo -RepoPath 'Alpha_SMB/cf/src' | Where-Object Kind -eq 'ignored') | Should -Not -HaveCount 0
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } | Should -Not -Throw
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 1
    }
    It 'truth: vendor, але всередині вкладений репозиторій — зупинка (виняток лише для «ignored»)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dinv-vendor-nested') -OverlayText $script:Overlay -WithGitignore -WithHooks
        $nest = Join-Path $repo 'Alpha_SMB/cf/src/nest'
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        git -C $nest init -q
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*nested-repo*Alpha_SMB/cf/src/nest*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
    }
}

Describe 'kit dump -Apply — vendor: решта видів невидимої роботи зупиняє; перевірка всіх джерел іде до першого видалення (фікс-раунд 1)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
    }
    BeforeEach {
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    It 'truth: vendor, гітігноровані файли дампу і junction у дереві — зупинка (link), ціль посилання ціла, платформа не запускалась' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dinv-vendor-junction') -OverlayText $script:Overlay -WithGitignore -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml') -Value 'кеш дампу' -Encoding UTF8
        $target = Join-Path $TestDrive 'dinv-vendor-junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'ціль' -Encoding UTF8
        New-Item -ItemType Junction -Path (Join-Path $repo 'Alpha_SMB/cf/src/lnk') -Target $target | Out-Null
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*link*Alpha_SMB/cf/src/lnk*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $target 'keep.txt' | Should -Exist
        Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml' | Should -Exist
    }
    It 'truth: vendor, відстежуваний (add -f) файл з assume-unchanged у гітігнорованому дереві — зупинка (flagged)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dinv-vendor-flagged') -OverlayText $script:Overlay -WithGitignore -WithHooks
        $f = Join-Path $repo 'Alpha_SMB/cf/src/Configuration.xml'
        Set-Content -LiteralPath $f -Value 'кеш дампу' -Encoding UTF8
        git -C $repo add -f -- Alpha_SMB/cf/src/Configuration.xml 2>&1 | Out-Null
        git -C $repo commit -q -m 'відстежується' 2>&1 | Out-Null
        Set-Content -LiteralPath $f -Value 'правка людини' -Encoding UTF8
        git -C $repo update-index --assume-unchanged Alpha_SMB/cf/src/Configuration.xml
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*невидима робота під набором*flagged*Configuration.xml*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        (Get-Content -LiteralPath $f -Raw) | Should -BeLike '*правка людини*'
    }
    It 'два джерела: друге брудне — перше лишається цілим (усі джерела перевіряються до першого видалення), платформа не запускалась' {
        $manifest = @('version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      Ext_One: { truth: dump, dump: { from: dev } }', '      Ext_Two: { truth: dump, dump: { from: dev } }') -join "`n"
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(
            @{ Name = 'Ext_One'; Type = 'EXTENSION'; Path = 'ext1/src' }
            @{ Name = 'Ext_Two'; Type = 'EXTENSION'; Path = 'ext2/src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dinv-order') -Workspaces $ws -ManifestText $manifest -OverlayText $script:Overlay -WithGitignore -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/ext2/src/Нова.xml') -Value 'нова форма' -Encoding UTF8
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw '*незакомічен*Alpha_SMB/ext2/src/Нова.xml*'
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Join-Path $repo 'Alpha_SMB/ext1/src/Configuration.xml' | Should -Exist -Because 'перше джерело чисте, але зупинка має настати до будь-якого видалення'
        Join-Path $repo 'Alpha_SMB/ext2/src/Нова.xml' | Should -Exist
    }
}

Describe 'kit dump -Apply — набір за junction (П25): kit нічого не видаляє крізь посилання' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=C:\bases\demo;'`n    user: 'Адмін'"
        # П25: переносить частину дерева за межі репозиторію й ставить на її місце junction. Mode e2 — junction на
        # компоненті ВИЩЕ кореня набору (Alpha_SMB/<Parent>), e1 — сам корінь набору (Alpha_SMB/<Parent>/<Leaf>).
        # Повертає ціль (поза репо) з контрольним файлом keep.txt.
        function script:Set-SetBehindLink { param([string]$Repo, [string]$Mode, [string]$Parent, [string]$Leaf, [string]$Tag)
            $linkPath = if ($Mode -eq 'e2') { Join-Path $Repo "Alpha_SMB/$Parent" } else { Join-Path $Repo "Alpha_SMB/$Parent/$Leaf" }
            $target = Join-Path $TestDrive "outside-$Tag-$Mode"
            Move-Item -LiteralPath $linkPath -Destination $target
            Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'чужа ціль' -Encoding UTF8
            New-Item -ItemType Junction -Path $linkPath -Target $target | Out-Null
            $target }
        function script:Get-LinkTargetState { param([string]$Target)
            (Get-ChildItem -LiteralPath $Target -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Target.Length))=$((Get-Content -LiteralPath $_.FullName -Raw))" }) -join '|' }
    }
    BeforeEach {
        Mock -ModuleName dump Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    It '<Mode>: junction назовні — зупинка (link), платформа не запускалась, вміст цілі цілий' -ForEach @(
        @{ Mode = 'e2' }
        @{ Mode = 'e1' }
    ) {
        $manifest = @('version: 1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      Alpha_SMB: { truth: dump, dump: { from: dev } }') -join "`n"
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive "dp25-$Mode") -Workspaces $ws -ManifestText $manifest -OverlayText $script:Overlay -WithGitignore -WithHooks
        $target = Set-SetBehindLink -Repo $repo -Mode $Mode -Parent 'cfe' -Leaf 'src' -Tag 'dump'
        $before = Get-LinkTargetState $target
        $expected = if ($Mode -eq 'e2') { 'Alpha_SMB/cfe' } else { 'Alpha_SMB/cfe/src' }
        { Invoke-KitDump -Context (Invoke-KitPreflight -RepoRoot $repo) -Apply $true } |
            Should -Throw "*невидима робота під набором*link*$expected*"
        Should -Invoke -ModuleName dump Invoke-V8Designer -Times 0
        Get-LinkTargetState $target | Should -Be $before
        $before | Should -BeLike '*keep.txt=чужа ціль*'
    }
}
