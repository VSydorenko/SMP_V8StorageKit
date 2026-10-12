#Requires -Version 7
Describe 'Format-KitUnicaRun (спека §10 П2)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
    }
    It 'точна форма {op, args, dryRun}, infobase не друкується' {
        Format-KitUnicaRun -Op 'push' -Arguments ([ordered]@{ sourceSet = 'base'; force = $true }) |
            Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
    }
    It 'dryRun:false на вимогу; порожні args — {}' {
        Format-KitUnicaRun -Op 'infobase.create' -Arguments ([ordered]@{}) -DryRun $false |
            Should -BeExactly 'unica.run {"op":"infobase.create","args":{},"dryRun":false}'
    }
    It 'кирилиця в імені набору — як є, без \u-екранування (Review Focus 1)' {
        $s = Format-KitUnicaRun -Op 'pull' -Arguments ([ordered]@{ sourceSet = 'Доработки'; force = $true })
        $s | Should -BeLike '*"sourceSet":"Доработки"*'
        $s | Should -Not -Match '\\u04'
    }
    It 'шлях Windows — валідний JSON (бекслеш подвоєно)' {
        $s = Format-KitUnicaRun -Op 'infobase.restore' -Arguments ([ordered]@{ input = 'D:\dumps\demo.dt'; mode = 'create' })
        # -BeLike тут не годиться: у шаблоні '\' — екранування, '\\' дорівнює одному '\'. Тому -Match з Escape.
        $s | Should -Match ([regex]::Escape('"input":"D:\\dumps\\demo.dt"'))
        ($s.Substring('unica.run '.Length) | ConvertFrom-Json).args.input | Should -Be 'D:\dumps\demo.dt'
    }
}

Describe 'Write-KitNextSteps' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
    }
    It 'порожній перелік — нічого не друкує' {
        (& { Write-KitNextSteps -Title 'Далі:' -Steps @() } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
    }
    It 'unica.run отримує нагадування про dryRun:false, крок kit — ні' {
        $out = & { Write-KitNextSteps -Title 'Далі:' -Steps @('unica.run {"op":"push","args":{},"dryRun":true}', 'kit verify -Source base') } 6>&1 | Out-String
        $lines = @($out -split "`r?`n" | Where-Object { $_ -match '^\s+\d\.' })
        $lines[0] | Should -BeLike '*"dryRun":false*'
        $lines[1] | Should -Not -BeLike '*dryRun*'
    }
}
