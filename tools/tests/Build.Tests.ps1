#Requires -Version 7
Describe 'kit build — виявлення й збір артефактів без платформи (§12)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Build { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:Ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'tools'     = @{ Sets = @(@{ Name = 'processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
        }
        # Два самостійних EXTENSION-воркспейси — для теста на розділення (-Workspace не
        # мусить чіпати артефакти сусіднього воркспейсу, Q1 звіту задачі 3).
        $script:WsTwo = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base_beta'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB';  Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
    }

    It 'знаходить обробки за типом source-set, а не за ім''ям теки epf' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'discover') -Workspaces $script:Ws -WithHooks
        foreach ($n in 'Обробка_А', 'Обробка_Б') {
            Set-Content -LiteralPath (Join-Path $repo "tools/src/$n.xml") -Value '<x/>' -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $repo "tools/src/$n") -Force | Out-Null
        }
        $r = Invoke-Build -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Обробка_А.epf*Обробка_Б.epf*'
        $r.Output | Should -BeLike '*Alpha_SMB*operation=make*'
        $r.Output | Should -BeLike '*-Apply*'
        # C3 (фікс-раунд рев'ю): сам фільтр типу — не лише пошук за іменем теки 'epf'. Без
        # 'Where-Object Type -eq EXTERNAL_DATA_PROCESSORS' у $epfSources потрапило б EXTENSION-
        # джерело Alpha_SMB (Configuration.xml лежить у його cfe/src, покладений фікстурою), і в
        # плані з'явилась би фіктивна Configuration.epf — тест вище цього не ловив.
        $r.Output | Should -Not -BeLike '*Configuration.epf*'
    }

    It 'truth: vendor у EXTENSION не радить operation=make — чужу конфігурацію build не збирає (C4 фікс-раунду)' {
        $manifest = @('version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: Alpha_SMB', '    sources:',
            '      Alpha_SMB: { truth: vendor, dump: { from: dev } }') -join "`n"
        $ws = [ordered]@{ 'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'vendor-ext') -Workspaces $ws -ManifestText $manifest -WithHooks
        $r = Invoke-Build -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -BeLike '*operation=make*'
        $r.Output | Should -BeLike '*Джерел для збірки в цьому виборі немає*'
    }

    It '-Apply без платформи: артефакти з <воркспейс>/build/artifacts збираються в build/artifacts кореня' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'collect') -Workspaces ([ordered]@{ 'Alpha_SMB' = $script:Ws['Alpha_SMB'] }) -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/artifacts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/artifacts/Alpha_SMB.cfe') -Value 'cfe' -Encoding ascii
        $r = Invoke-Build -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'build/artifacts/Alpha_SMB.cfe' | Should -Exist
        $r.Output | Should -BeLike '*Alpha_SMB.cfe*'
    }

    It 'без жодних обробок і без артефактів — код 0 і пояснення, як зібрати .cfe' {
        $r = Invoke-Build -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'nothing') -WithHooks) -More @('-Apply')
        $r.ExitCode | Should -Be 0
        # 'build*artifacts', не 'build/artifacts': Join-Path у production-коді нормалізує
        # внутрішній роздільник на '\' (перевірено на pwsh 7.5.4, Join-Path 'C:\foo' 'build/artifacts'
        # дає 'C:\foo\build\artifacts', на відміну від [System.IO.Path]::Combine) — літеральний
        # прямий слеш у виводі команди не з'являється.
        $r.Output | Should -BeLike '*operation=make*build*artifacts*'
    }

    It 'підказка про .cfe друкує output, який Unica приймає — відносний до воркспейсу' {
        # Прев'ю (без -Apply) платформи не торкається.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'build-hint') -WithHooks
        $r = Invoke-Build -Repo $repo
        $r.Output | Should -BeLike '*output=build/artifacts/Alpha_SMB.cfe*'
        $r.Output | Should -Not -BeLike "*output=$repo*"
        $r.Output | Should -BeLike '*kit build*забере*'
    }

    It '-Workspace обмежує збір артефактів лише вибраним воркспейсом (Q1 звіту задачі 3 — Copy-KitWorkspaceArtifacts не мусить чіпати сусідні воркспейси)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'scope') -Workspaces $script:WsTwo -WithHooks
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') {
            New-Item -ItemType Directory -Path (Join-Path $repo "$n/build/artifacts") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo "$n/build/artifacts/$n.cfe") -Value 'cfe' -Encoding ascii
        }
        $r = Invoke-Build -Repo $repo -More @('-Workspace', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'build/artifacts/Alpha_SMB.cfe' | Should -Exist
        Join-Path $repo 'build/artifacts/Beta_SMB.cfe' | Should -Not -Exist
        # Джерело в сусідньому воркспейсі лишається на місці — build його не чіпає, лише не копіює.
        Join-Path $repo 'Beta_SMB/build/artifacts/Beta_SMB.cfe' | Should -Exist
    }
}

Describe 'kit build — мок платформного шару: .epf через платформу (C1/C2 фікс-раунду)' {
    # build лишалась єдиною платформною командою блоку без Describe "мок платформного шару" —
    # Dump.Tests.ps1 і Canon.Tests.ps1 уже мають такий для dump/canon (рев'ю фікс-раунду, C2).
    # Той самий прийом: lib-модулі в порядку module-order.txt, потім САМЕ commands/build.psm1 у
    # ЦЬОМУ процесі (не підпроцесом kit.ps1) — лише так Mock -ModuleName бачить приватний стіл
    # команд саме build (межа модуля з module-order.txt: Mock -ModuleName діє лише в межах
    # названого модуля, і виклики платформи тепер живуть саме в build, не в StoragePlatform).
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/build.psm1").Path -Force

        $script:WsEpf = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
    }

    It 'будує .epf через платформу: порядок аргументів LoadExternalDataProcessorOrReportFromFiles, межа тимчасової ІБ, накопичення Artifacts (C2)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-epf-happy') -Workspaces $script:WsEpf -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'epf/src/Обробка.xml') -Value '<x/>' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $repo 'epf/src/Обробка') -Force | Out-Null

        Mock -ModuleName build New-V8FileInfobase { param($Path, $MustBeUnder, $TemplatePath, $V8Path) $Path }
        Mock -ModuleName build Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitBuild -Context $ctx -Apply $true

        $result.ExitCode | Should -Be 0
        $expected = Join-Path $repo 'build/artifacts/Обробка.epf'
        $result.Artifacts | Should -Contain $expected

        # -MustBeUnder — build/, не build/artifacts і не корінь репозиторію: доводить, що
        # тимчасова ІБ будується під тією самою межею, що описана у task-3-report.md (питання 2).
        Should -Invoke -ModuleName build New-V8FileInfobase -Times 1 -ParameterFilter {
            $Path -like '*\build\build-ib' -and $MustBeUnder -like '*\build'
        }
        # Порядок "дескриптор" — "ціль" у самому рядку аргументів: переставлені місцями
        # платформа прийняла б мовчки (і намагалась би прочитати build/artifacts/Обробка.epf
        # як вихідник, а записати поверх epf/src/Обробка.xml) — лише цей ParameterFilter це ловить.
        Should -Invoke -ModuleName build Invoke-V8Designer -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -like '*epf\src\Обробка.xml" "*build\artifacts\Обробка.epf*'
        }
    }

    It 'ExitCode ≠ 0 від платформи — throw з іменем обробки, а не тихий "успіх" (C2)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-epf-fail') -Workspaces $script:WsEpf -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'epf/src/Обробка.xml') -Value '<x/>' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $repo 'epf/src/Обробка') -Force | Out-Null

        Mock -ModuleName build New-V8FileInfobase { param($Path, $MustBeUnder, $TemplatePath, $V8Path) $Path }
        Mock -ModuleName build Invoke-V8Designer { [pscustomobject]@{ ExitCode = 1; Output = 'помилка платформи' } }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Invoke-KitBuild -Context $ctx -Apply $true } | Should -Throw '*Обробка*'
    }

    It '.epf, зібраний платформою цього прогону, не перезаписується старим із <воркспейс>/build/artifacts (C1)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'mock-epf-stale') -Workspaces $script:WsEpf -WithHooks
        Set-Content -LiteralPath (Join-Path $repo 'epf/src/Обробка.xml') -Value '<x/>' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $repo 'epf/src/Обробка') -Force | Out-Null

        # Стара версія — залишок попереднього build чи чужого operation=make — лежить у
        # запасному шляху Q6 воркспейсу під ТИМ САМИМ ім'ям, яке цей прогін от-от збудує свіжим.
        New-Item -ItemType Directory -Path (Join-Path $repo 'epf/build/artifacts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'epf/build/artifacts/Обробка.epf') -Value 'stale-from-workspace' -Encoding ascii

        Mock -ModuleName build New-V8FileInfobase { param($Path, $MustBeUnder, $TemplatePath, $V8Path) $Path }
        Mock -ModuleName build Invoke-V8Designer {
            param($IbSwitch, $Arguments, $User, $Password, $V8Path)
            if (($Arguments -join ' ') -match '/LoadExternalDataProcessorOrReportFromFiles "[^"]+" "(?<t>[^"]+)"') {
                Set-Content -LiteralPath $Matches.t -Value 'fresh-from-build' -Encoding ascii
            }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $result = Invoke-KitBuild -Context $ctx -Apply $true

        $result.ExitCode | Should -Be 0
        $target = Join-Path $repo 'build/artifacts/Обробка.epf'
        (Get-Content -LiteralPath $target -Raw) | Should -Match 'fresh-from-build'
        @($result.Artifacts | Where-Object { $_ -eq $target }).Count | Should -Be 1
        # Стара лишається на місці у воркспейсі — build її звідти не видаляє, лише більше не
        # копіює поверх свіжозібраної (запасний шлях Q6 — для .cf/.cfe, не для .epf/.erf, які
        # build збирає сам).
        (Get-Content -LiteralPath (Join-Path $repo 'epf/build/artifacts/Обробка.epf') -Raw) | Should -Match 'stale-from-workspace'
    }
}

Describe 'kit build — .epf через платформу' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Джерело обробки — з живого репозиторію (перший .xml у epf/src), лише читання.
        $script:Live = 'R:\github\SMP_BankExchange\epf\src'
    }
    It 'збирає .epf із живих вихідників у build/artifacts' {
        $desc = Get-ChildItem -LiteralPath $script:Live -Filter '*.xml' -File | Select-Object -First 1
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'bank_formats'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks
        Copy-Item -LiteralPath $desc.FullName -Destination (Join-Path $repo 'epf/src')
        Copy-Item -LiteralPath (Join-Path $script:Live $desc.BaseName) -Destination (Join-Path $repo 'epf/src' $desc.BaseName) -Recurse
        $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo "build/artifacts/$($desc.BaseName).epf" | Should -Exist
    }
}
