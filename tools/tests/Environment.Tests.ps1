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

Describe 'check-environment.ps1: unica не впливає на код виходу' {
    It 'дає той самий код виходу з плагіном unica і без нього' {
        # Це і є контракт, заради якого заведені категорії: unica лежить у категорії
        # «Вихідники», тож її відсутність — попередження, а не блокер. Порівняння двох
        # прогонів між собою робить перевірку незалежною від того, чи встановлена на
        # цій машині платформа 1С: якщо її немає, обидва прогони дадуть 1, і рівність
        # усе одно доведе, що різницю зробила не unica.
        $dir = Join-Path $TestDrive 'present'
        New-Item -ItemType Directory -Path $dir | Out-Null

        $withUnica = Join-Path $TestDrive 'with-unica.json'
        script:New-Registry -Path $withUnica -Plugins @{
            'unica@unica' = @( @{ installPath = $dir; version = '0.12.3' } )
        }

        $withoutUnica = Join-Path $TestDrive 'without-unica.json'
        script:New-Registry -Path $withoutUnica -Plugins @{}

        $outWith = & pwsh -NoProfile -File $script:CheckScript -InstalledPluginsPath $withUnica 2>&1 | Out-String
        $codeWith = $LASTEXITCODE

        $outWithout = & pwsh -NoProfile -File $script:CheckScript -InstalledPluginsPath $withoutUnica 2>&1 | Out-String
        $codeWithout = $LASTEXITCODE

        $codeWithout | Should -Be $codeWith
        $outWith     | Should -Match 'Плагін unica'
        $outWithout  | Should -Match 'Плагін unica'
    }

    It 'без unica друкує попередження про вихідники, а не про зламаний конвеєр' {
        $withoutUnica = Join-Path $TestDrive 'warn.json'
        script:New-Registry -Path $withoutUnica -Plugins @{}

        $out = & pwsh -NoProfile -File $script:CheckScript -InstalledPluginsPath $withoutUnica 2>&1 | Out-String

        $out | Should -Match 'Попередження'
        $out | Should -Match 'вихідники'
    }
}
