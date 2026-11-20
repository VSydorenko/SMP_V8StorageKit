BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Environment.psm1" -Force
    $script:CheckScript = Join-Path $PSScriptRoot '../check-environment.ps1' | Convert-Path

    function script:New-Registry {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][hashtable]$Plugins
        )
        [pscustomobject]@{ version = 2; plugins = $Plugins } |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Describe 'Get-UnicaInstallation: реєстр недоступний' {
    It 'не кидає виняток, а називає шлях, якого немає' {
        # Діагностичний інструмент, який падає на відсутньому файлі, гірший за
        # відсутній інструмент: користувач дізнається лише те, що щось не так.
        $missing = Join-Path $TestDrive 'ніякого-реєстру.json'
        $result = Get-UnicaInstallation -InstalledPluginsPath $missing

        $result.Installed | Should -BeFalse
        $result.Reason    | Should -Match 'ніякого-реєстру\.json'
    }

    It 'пояснює зіпсований JSON замість того, щоб мовчки вважати плагін невстановленим' {
        # Зіпсований реєстр і відсутній плагін — різні стани з різними діями:
        # перший лагодять, другий встановлюють. Злиття їх в одне «не знайдено»
        # відправило б користувача не туди.
        $broken = Join-Path $TestDrive 'broken.json'
        '{ "plugins": { ' | Set-Content -LiteralPath $broken -Encoding UTF8

        $result = Get-UnicaInstallation -InstalledPluginsPath $broken

        $result.Installed | Should -BeFalse
        $result.Reason    | Should -Match 'JSON'
    }

    It 'повідомляє про реєстр без розділу plugins' {
        $noSection = Join-Path $TestDrive 'no-plugins.json'
        '{ "version": 2 }' | Set-Content -LiteralPath $noSection -Encoding UTF8

        $result = Get-UnicaInstallation -InstalledPluginsPath $noSection

        $result.Installed | Should -BeFalse
        $result.Reason    | Should -Match 'plugins'
    }
}

Describe 'Get-UnicaInstallation: пошук за іменем плагіна' {
    It 'знаходить плагін за частиною ключа до символу @, а не за ключем цілком' {
        # Ключі реєстру мають форму '<плагін>@<маркетплейс>' — пошук по рівності
        # цілому ключу не знайшов би нічого.
        $dir = Join-Path $TestDrive 'unica-0.12.3'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $TestDrive 'ok.json'
        script:New-Registry -Path $path -Plugins @{
            'unica@unica' = @( @{ scope = 'user'; installPath = $dir; version = '0.12.3' } )
        }

        $result = Get-UnicaInstallation -InstalledPluginsPath $path

        $result.Installed   | Should -BeTrue
        $result.PathExists  | Should -BeTrue
        $result.Version     | Should -Be '0.12.3'
        $result.InstallPath | Should -Be $dir
        $result.Reason      | Should -BeNullOrEmpty
    }

    It 'не приймає чужий плагін, чиє ім''я лише починається з шуканого' {
        # Захист саме від наївного -like 'unica*': плагін 'unica-extras' — не unica.
        $dir = Join-Path $TestDrive 'extras'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $TestDrive 'lookalike.json'
        script:New-Registry -Path $path -Plugins @{
            'unica-extras@somewhere' = @( @{ installPath = $dir; version = '1.0.0' } )
        }

        $result = Get-UnicaInstallation -InstalledPluginsPath $path

        $result.Installed | Should -BeFalse
        $result.Reason    | Should -Match "unica"
    }

    It 'повідомляє про ключ без жодного запису про встановлення' {
        $path = Join-Path $TestDrive 'empty-installs.json'
        script:New-Registry -Path $path -Plugins @{ 'unica@unica' = @() }

        $result = Get-UnicaInstallation -InstalledPluginsPath $path

        $result.Installed | Should -BeFalse
        $result.Reason    | Should -Match 'без жодного запису'
    }
}

Describe 'Get-UnicaInstallation: реєстр і диск розійшлись' {
    It 'відрізняє «є в реєстрі» від «тека на місці» замість того, щоб злити їх в одне' {
        # Найважчий для пояснення випадок: запис у реєстрі лишився, а теки немає
        # (вручну прибраний кеш, перенесений профіль). Якби функція повертала лише
        # один прапорець, цей стан був би не відрізнити від «не встановлено», і
        # користувач марно перевстановлював би те, що в реєстрі вже значиться.
        $gone = Join-Path $TestDrive 'видалена-тека'
        $path = Join-Path $TestDrive 'stale.json'
        script:New-Registry -Path $path -Plugins @{
            'unica@unica' = @( @{ installPath = $gone; version = '0.12.3' } )
        }

        $result = Get-UnicaInstallation -InstalledPluginsPath $path

        $result.Installed  | Should -BeTrue
        $result.PathExists | Should -BeFalse
        $result.Reason     | Should -Match 'видалена-тека'
    }

    It 'повідомляє про запис без installPath' {
        $path = Join-Path $TestDrive 'no-path.json'
        script:New-Registry -Path $path -Plugins @{
            'unica@unica' = @( @{ version = '0.12.3' } )
        }

        $result = Get-UnicaInstallation -InstalledPluginsPath $path

        $result.Installed  | Should -BeTrue
        $result.PathExists | Should -BeFalse
        $result.Reason     | Should -Match 'installPath'
    }
}

Describe 'Get-PesterAvailability' {
    It 'відхиляє наявний Pester, нижчий за межу, і називає обидві версії' {
        # Межа взята з Run-Tests.ps1 (-MinimumVersion 5.0). Тест піднімає її свідомо
        # недосяжно високо, щоб перевірити саме гілку «модуль є, але застарий» —
        # вона пояснює падіння Import-Module, якого інакше не відрізнити від
        # повної відсутності модуля.
        $result = Get-PesterAvailability -MinimumVersion '99.0'

        $result.Available | Should -BeFalse
        $result.Reason    | Should -Match '99\.0'
        $result.Version   | Should -Not -BeNullOrEmpty
    }

    It 'приймає Pester, яким саме зараз і виконується цей тест' {
        (Get-PesterAvailability).Available | Should -BeTrue
    }
}

Describe 'Get-GitAvailability' {
    It 'знаходить git і повертає рядок його версії' {
        $result = Get-GitAvailability

        $result.Available | Should -BeTrue
        $result.Version   | Should -Match 'git version'
    }
}

Describe 'Test-KitGitVersionSupported (злиття через merge-tree потребує git ≥ 2.38)' {
    It '<Text> → <Ok>' -ForEach @(
        @{ Text = 'git version 2.37.1';             Ok = $false }
        @{ Text = 'git version 2.38.0';             Ok = $true }
        @{ Text = 'git version 2.53.0.windows.1';   Ok = $true }
        @{ Text = 'щось інше';                      Ok = $false }
    ) {
        Test-KitGitVersionSupported -VersionText $Text | Should -Be $Ok
    }

    It 'Get-GitAvailability повідомляє Supported і Minimum' {
        $g = Get-GitAvailability
        $g.Minimum | Should -Be '2.38'
        $g.Supported | Should -BeTrue
    }
}

Describe 'check-environment.ps1: Уніка й раннер — обов''язкова частина конвеєра' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:FakeRunner = (Resolve-Path "$PSScriptRoot/fixtures/runner/v8-runner.cmd").Path
        function script:Invoke-EnvCheck {
            param([string]$Registry, [string]$Runner)
            $a = @('-NoProfile', '-File', $script:CheckScript, '-InstalledPluginsPath', $Registry)
            if ($Runner) { $a += @('-RunnerPath', $Runner) }
            # Кодування виводу дочірнього процесу — властивість консолі воркера, а не тесту (його виставляють сусідні файли
            # в тому ж воркері): без явного UTF-8 кирилиця могла прийти OEM-кодуванням, і -BeLike на ній мовчки не збігався.
            $prevEnc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                $out = & pwsh @a 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally { [Console]::OutputEncoding = $prevEnc }
            [pscustomobject]@{ ExitCode = $code; Output = $out }
        }
    }

    It 'Уніки немає — блокер: код 1, у категорії «Конвеєр», рецепт встановлення, kit dump згадано винятком' {
        $reg = Join-Path $TestDrive 'none.json'
        script:New-Registry -Path $reg -Plugins @{}
        $r = Invoke-EnvCheck -Registry $reg -Runner $script:FakeRunner
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike '*[[]-] Плагін unica 0.16*'
        $r.Output | Should -BeLike '*claude plugin install unica@unica*'
        $r.Output | Should -BeLike '*kit dump працює й без Уніки*'
        $r.Output | Should -Not -BeLike '*Попередження (коду виходу не змінюють)*Плагін unica*'
    }

    It 'Уніка 0.15.2 стоїть — блокер, радить оновити, а не встановлювати' {
        $reg = New-KitFakeUnicaRegistry -Version '0.15.2'
        $r = Invoke-EnvCheck -Registry $reg -Runner $script:FakeRunner
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike '*claude plugin update unica@unica*'
        $r.Output | Should -Not -BeLike '*claude plugin install unica@unica*'
    }

    It 'Уніка 0.16.0 і фальшивий раннер 0.18.1 — обидва рядки [+]; Уніка 0.17.0 лишається не блокером (warn)' {
        $r = Invoke-EnvCheck -Registry (New-KitFakeUnicaRegistry -Version '0.16.0') -Runner $script:FakeRunner
        $r.Output | Should -BeLike '*[[]+] Плагін unica 0.16*'
        $r.Output | Should -BeLike '*[[]+] Раннер v8-runner 0.18 — Раннер v8-runner 0.18.1.*'
        $r2 = Invoke-EnvCheck -Registry (New-KitFakeUnicaRegistry -Version '0.17.0') -Runner $script:FakeRunner
        $r2.Output | Should -BeLike '*[[]+] Плагін unica 0.16*0.17.0*новіший*'
    }

    It 'раннера немає (-RunnerPath на неіснуючий файл) — блокер [-] Раннер' {
        $r = Invoke-EnvCheck -Registry (New-KitFakeUnicaRegistry -Version '0.16.0') -Runner (Join-Path $TestDrive 'немає-раннера.exe')
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike '*[[]-] Раннер v8-runner 0.18*Раннер не знайдено*'
    }
}

Describe 'Get-KitUnicaVersionVerdict' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/Environment.psm1").Path -Force }
    It '<V> → <Level>' -ForEach @(
        @{ V = '0.15.2'; Level = 'error' }
        @{ V = '0.13.0'; Level = 'error' }
        @{ V = '0.16.0'; Level = 'ok' }
        @{ V = '0.16.9'; Level = 'ok' }
        @{ V = '0.17.0'; Level = 'warn' }
        @{ V = '1.0.0';  Level = 'warn' }
        @{ V = 'dev';    Level = 'warn' }
    ) {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = $V; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Level | Should -Be $Level
    }
    It 'error називає рецепт оновлення' {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = '0.15.2'; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Message | Should -BeLike '*0.15.2*claude plugin update unica@unica*нову сесію*'
    }
    It 'warn називає процедуру звірки контракту' {
        $i = [pscustomobject]@{ Installed = $true; PathExists = $true; Version = '0.17.0'; InstallPath = 'C:\u'; Reason = '' }
        (Get-KitUnicaVersionVerdict -Installation $i).Message | Should -BeLike '*процедур*unica-contract.md*'
    }
    It 'Уніки немає — error: sync, verify і provision без неї не працюють, але kit dump працює' {
        $i = [pscustomobject]@{ Installed = $false; PathExists = $false; Version = ''; InstallPath = ''; Reason = 'немає в реєстрі' }
        $v = Get-KitUnicaVersionVerdict -Installation $i
        $v.Level | Should -Be 'error'
        $v.Message | Should -BeLike '*немає в реєстрі*'
        $v.Message | Should -BeLike '*sync, verify і provision*kit dump працює й без Уніки*'
    }
}