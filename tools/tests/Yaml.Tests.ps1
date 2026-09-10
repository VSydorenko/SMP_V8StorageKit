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

    It 'ConvertTo-KitYaml: серіалізує і читається назад тим самим Read-KitYaml (симетрія читання/запису)' {
        $doc = [ordered]@{ workspaces = [ordered]@{ 'Alpha_SMB' = [ordered]@{ agentBase = [ordered]@{ template = 'D:\dumps\demo.dt' } } } }
        $yaml = ConvertTo-KitYaml -Data $doc
        $yaml | Should -Not -BeNullOrEmpty
        $f = Join-Path $TestDrive 'roundtrip.yaml'
        Set-Content -LiteralPath $f -Value $yaml -Encoding UTF8 -NoNewline
        (Read-KitYaml -Path $f)['workspaces']['Alpha_SMB']['agentBase']['template'] | Should -Be 'D:\dumps\demo.dt'
    }

    It 'ConvertTo-KitYaml працює у свіжому дочірньому процесі, де powershell-yaml ще не завантажено' {
        # У ЦЬОМУ процесі Pester powershell-yaml майже напевно вже завантажений (десятки
        # It вище кличуть Read-KitYaml) — звичайний It тут перевірив би не ту властивість:
        # видимість команди ConvertTo-Yaml з чужого модуля лишається неперевіреною, бо вона
        # вже могла осісти глобально задовго до цього тесту. Дочірній pwsh імпортує лише
        # Yaml.psm1 (не powershell-yaml напряму) і одразу кличе ConvertTo-KitYaml — так
        # перевіряється саме те, що обгортка сама тягне за собою Import-KitYamlModule, а не
        # покладається на те, що хтось інший це вже зробив.
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $out = & pwsh -NoProfile -Command "Import-Module '$libDir/Yaml.psm1' -Force; ConvertTo-KitYaml -Data ([ordered]@{ a = 1 })" 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out.Trim() | Should -Not -BeNullOrEmpty
        $out | Should -BeLike '*a*1*'
    }

    It 'F3: обгортка лишається потрібною й з вимкненим автозавантаженням модулів — Save-KitOverlayAgentBase усе одно працює' {
        # Попередній тест доводить самодостатність ConvertTo-KitYaml у свіжому процесі, але
        # автозавантаження з PSModulePath там УВІМКНЕНЕ — регресія "Manifest.psm1 знову кличе
        # голий ConvertTo-Yaml замість ConvertTo-KitYaml" лишилась би зеленою і там, бо
        # автозавантаження все одно "врятувало" б голий виклик. $PSModuleAutoLoadingPreference
        # = 'None' вимикає САМЕ цей побічний канал (пошук модуля за іменем нерозпізнаної
        # команди) — перевірено емпірично: голий ConvertTo-Yaml у цьому режимі падає з "term
        # ... is not recognized", а Save-KitOverlayAgentBase (яка йде через ConvertTo-KitYaml,
        # тобто через явний Import-Module) працює. Явний Import-Module (і тут, і всередині
        # ConvertTo-KitYaml/Import-KitYamlModule) від автозавантаження не залежить.
        #
        # Microsoft.PowerShell.Utility/.Management імпортуємо ЯВНО ДО вимкнення
        # автозавантаження: інакше під -NoProfile ще не підвантажені лениво вбудовані
        # команди на кшталt Sort-Object (Test-KitYamlModule їх використовує) також не
        # резолвляться — і тест падав би з причини, що не має стосунку до предмета
        # перевірки (перевірено емпірично на pwsh 7.5.4).
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $target = Join-Path $TestDrive 'auto-off-overlay.yaml'
        $cmd = "`$ErrorActionPreference = 'Stop'; " +
               "Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop; " +
               "Import-Module Microsoft.PowerShell.Management -ErrorAction Stop; " +
               "`$PSModuleAutoLoadingPreference = 'None'; " +
               "Import-Module '$libDir/Manifest.psm1' -Force; " +
               "Save-KitOverlayAgentBase -OverlayPath '$target' -WorkspacePath 'Alpha_SMB' -Template 'D:\dumps\demo.dt'"
        $out = & pwsh -NoProfile -Command $cmd 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Test-Path -LiteralPath $target -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $target -Raw) | Should -BeLike '*demo.dt*'
    }
}
