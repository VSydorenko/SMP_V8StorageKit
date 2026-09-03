#Requires -Version 7
Describe 'Yaml.psm1 — читання YAML через powershell-yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path
    }

    It 'модуль powershell-yaml доступний на цій машині (залежність категорії «Конвеєр»)' {
        (Test-KitYamlModule).Available | Should -BeTrue -Because (
            'без нього не читається ні маніфест, ні v8project.yaml: Install-Module powershell-yaml -Scope CurrentUser')
    }

    It 'читає продуктовий маніфест зі спеки: три воркспейси, flow-стиль і кириличні шляхи цілі' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
        $m['version'] | Should -Be 1
        $m['product'] | Should -Be 'BankExchange'
        @($m['workspaces']).Count | Should -Be 3
        $m['workspaces'][1]['sources']['base']['dump']['from'] | Should -Be 'devUNFru'
        $m['workspaces'][0]['sources']['SMP_BankExchange_SMB']['storage']['path'] |
            Should -Be 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
    }

    It 'читає клієнтський маніфест: кириличний ключ джерела на місці' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-client.yaml')
        $m['client'] | Should -Be 'Alpenpharma'
        @($m['workspaces'][0]['sources'].Keys) | Should -Contain 'Адаптация'
    }

    It 'зберігає порядок ключів — для звітів і майбутнього запису назад' {
        $m = Read-KitYaml -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
        @($m.Keys)[0] | Should -Be 'version'
        @($m.Keys)[-1] | Should -Be 'workspaces'
    }

    It 'зупиняється на відсутньому файлі, називаючи шлях' {
        { Read-KitYaml -Path (Join-Path $TestDrive 'nope.yaml') } | Should -Throw '*nope.yaml*'
    }

    It 'зупиняється на порожньому файлі без -AllowEmpty і повертає $null з ним' {
        $f = Join-Path $TestDrive 'empty.yaml'
        Set-Content -LiteralPath $f -Value "# лише коментар`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*порожній*'
        Read-KitYaml -Path $f -AllowEmpty | Should -BeNullOrEmpty
    }

    It 'зупиняється, коли верхній рівень — список, а не мапа' {
        $f = Join-Path $TestDrive 'list.yaml'
        Set-Content -LiteralPath $f -Value "- a`n- b`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*мапою*'
    }

    It 'зупиняється на дубльованому ключі — дві дев-бази під одним іменем не проходять мовчки' {
        # Наступник запобіжника Read-V8LocalConnection на «два connection: під одним ключем»:
        # тепер це робить сам парсер (YamlDotNet відхиляє дубльовані ключі мапи). Якщо цей
        # тест колись пройде без винятку — powershell-yaml почав приймати дублікати, і
        # перевірку треба додати в Read-KitYaml явно, а не знімати тест.
        $f = Join-Path $TestDrive 'dup.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'infobases:'
            '  dev:'
            "    connection: 'File=a'"
            '  dev:'
            "    connection: 'File=b'"
        )
        { Read-KitYaml -Path $f } | Should -Throw
    }

    It 'зупиняється на зламаному YAML, називаючи файл' {
        $f = Join-Path $TestDrive 'broken.yaml'
        Set-Content -LiteralPath $f -Value "a: [1, 2`n" -Encoding UTF8
        { Read-KitYaml -Path $f } | Should -Throw '*broken.yaml*'
    }
}
