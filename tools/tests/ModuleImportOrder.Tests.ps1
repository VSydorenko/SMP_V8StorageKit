#Requires -Version 7
Describe 'Порядок імпорту модулів у kit.ps1 (module-order.txt)' {
    BeforeAll {
        $script:LibDir    = (Resolve-Path "$PSScriptRoot/../lib").Path
        $script:ProbeFile = (Resolve-Path "$PSScriptRoot/fixtures/module-visibility-probe.ps1").Path
        $script:Modules   = @(Get-Content -LiteralPath (Join-Path $script:LibDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    It 'module-order.txt містить кожен lib/*.psm1 і не називає неіснуючих' {
        # Пропущений модуль — «команда не розпізнана» у живій сесії; перелік функцій для цього не потрібен.
        $onDisk = @(Get-ChildItem -LiteralPath $script:LibDir -Filter '*.psm1' | ForEach-Object BaseName)
        foreach ($m in $onDisk) { $script:Modules | Should -Contain $m -Because "модуль $m є в lib/, але не в module-order.txt" }
        foreach ($m in $script:Modules) { $onDisk | Should -Contain $m -Because "module-order.txt називає $m, а lib/$m.psm1 немає" }
    }

    It 'усі модулі імпортуються без помилок у порядку module-order.txt' {
        $out = & pwsh -NoProfile -File $script:ProbeFile -LibDir $script:LibDir -ModulesCsv ($script:Modules -join ',') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "імпорт мав відпрацювати без винятку; вивід:`n$out"
    }
}
