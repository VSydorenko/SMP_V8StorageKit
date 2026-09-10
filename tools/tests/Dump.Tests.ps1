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
        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=""C:\bases\demo"";'`n    user: 'Адмін'"
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
    # Sync.Tests.ps1 і Verify.Tests.ps1 уже мають такий Describe для sync/verify (мок
    # New-ExtensionInfobase/Invoke-V8Designer -ModuleName StoragePlatform чи verify). Тут той
    # самий прийом: lib-модулі в порядку module-order.txt, потім САМЕ commands/dump.psm1 у
    # ЦЬОМУ процесі (не підпроцесом kit.ps1) — лише так Mock -ModuleName бачить приватний
    # стіл команд саме dump (Mock -ModuleName діє лише в межах названого модуля — урок Task 1,
    # повторений і в Sync.Tests.ps1, і в Verify.Tests.ps1).
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/dump.psm1").Path -Force

        $script:Overlay = "infobases:`n  dev:`n    connection: 'File=""C:\bases\demo"";'`n    user: 'Адмін'"
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
        $overlay = "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF_sydorenko"";'`n    user: 'Администратор'"
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
