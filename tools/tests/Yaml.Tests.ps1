#Requires -Version 7
Describe 'Yaml.psm1 — читання YAML через powershell-yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path -Force
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

    It 'F3: обгортка лишається потрібною й з вимкненим автозавантаженням модулів — Save-KitOverlayAgentBase усе одно працює' {
        # У звичайному процесі автозавантаження
        # з PSModulePath УВІМКНЕНЕ — регресія "Manifest.psm1 знову кличе
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
