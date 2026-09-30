#Requires -Version 7
Describe 'Supply.psm1 — поставка вендора основної конфігурації' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Supply.psm1").Path -Force

        # Дерево CONFIGURATION: $BinBytes — розмір .bin (0 — файла немає), $Cf — імена .cf у теці поставки.
        function script:New-SupplyTree {
            param([string]$Name, [int]$BinBytes = 32, [string[]]$Cf = @('Vendor.cf'), [string]$Marker)
            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $root 'Ext') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Configuration.xml') -Value '<x/>' -Encoding UTF8
            if ($BinBytes -gt 0) {
                [System.IO.File]::WriteAllBytes((Join-Path $root 'Ext/ParentConfigurations.bin'), [byte[]](1..$BinBytes | ForEach-Object { $_ % 250 }))
            }
            if ($Cf.Count -gt 0 -or $Marker) { New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null }
            foreach ($c in $Cf) { Set-Content -LiteralPath (Join-Path $root "Ext/ParentConfigurations/$c") -Value 'cf' -Encoding ascii }
            if ($Marker) { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), $Marker) }
            $root
        }
    }

    It 'шлях поставки — одне оголошення' {
        Get-KitSupplyRelativePath | Should -BeExactly 'Ext/ParentConfigurations'
    }

    It 'Test-KitSupplyRelativePath: тека, вкладений файл, обидва роздільники; .bin і сусіди — ні' {
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations/BASSmallBusiness.cf' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext\ParentConfigurations\X.cf' | Should -BeTrue
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurations.bin' | Should -BeFalse
        Test-KitSupplyRelativePath -RelativePath 'Ext/ParentConfigurationsX/a.cf' | Should -BeFalse
        Test-KitSupplyRelativePath -RelativePath 'Catalogs/Ext/ParentConfigurations/a.cf' | Should -BeFalse
    }

    It '.bin рівно 16 байт (знята з підтримки) — поставку не описує, стан none' {
        $t = New-SupplyTree -Name 'bin16' -BinBytes 16 -Cf @()
        Test-KitSupplyDescribed -TreeRoot $t | Should -BeFalse
        Get-KitSupplyState -TreeRoot $t | Should -Be 'none'
    }

    It '.bin немає взагалі — стан none' {
        $t = New-SupplyTree -Name 'nobin' -BinBytes 0 -Cf @()
        Get-KitSupplyState -TreeRoot $t | Should -Be 'none'
    }

    It '.bin 17 байт — поставку описує (межа не 16-включно)' {
        $t = New-SupplyTree -Name 'bin17' -BinBytes 17 -Cf @()
        Test-KitSupplyDescribed -TreeRoot $t | Should -BeTrue
    }

    It 'описує поставку, .cf немає — missing' {
        $t = New-SupplyTree -Name 'nocf' -Cf @()
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It 'є лише позначка, .cf немає — missing (позначка без .cf нічого не доводить)' {
        $t = New-SupplyTree -Name 'marker-only' -Cf @() -Marker 'abc'
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It '.cf є, позначки немає — missing' {
        $t = New-SupplyTree -Name 'nomarker'
        Get-KitSupplyState -TreeRoot $t | Should -Be 'missing'
    }

    It 'Write-KitSupplyMarker пише SHA-1 .bin; стан стає current; кілька .cf — не аномалія' {
        $t = New-SupplyTree -Name 'write' -Cf @('A.cf', 'B.cf')
        $sha = Write-KitSupplyMarker -TreeRoot $t
        $sha | Should -Match '^[0-9a-f]{40}$'
        $expected = (Get-FileHash -LiteralPath (Join-Path $t 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
        $sha | Should -Be $expected
        [System.IO.File]::ReadAllText((Join-Path $t 'Ext/ParentConfigurations/.kit-bin-sha1')) | Should -BeExactly $expected
        Get-KitSupplyState -TreeRoot $t | Should -Be 'current'
    }

    It 'підмінений .bin після позначки — stale' {
        $t = New-SupplyTree -Name 'stale'
        $null = Write-KitSupplyMarker -TreeRoot $t
        [System.IO.File]::WriteAllBytes((Join-Path $t 'Ext/ParentConfigurations.bin'), [byte[]](1..40))
        Get-KitSupplyState -TreeRoot $t | Should -Be 'stale'
    }

    It 'Write-KitSupplyMarker не пише нічого, коли .bin не описує поставку' {
        $t = New-SupplyTree -Name 'nowrite16' -BinBytes 16 -Cf @('A.cf')
        Write-KitSupplyMarker -TreeRoot $t | Should -BeNullOrEmpty
        Join-Path $t 'Ext/ParentConfigurations/.kit-bin-sha1' | Should -Not -Exist
    }

    It 'Remove-KitSupplyDir прибирає теку поставки, .bin лишає' {
        $t = New-SupplyTree -Name 'remove'
        Remove-KitSupplyDir -TreeRoot $t -MustBeUnder $TestDrive
        Join-Path $t 'Ext/ParentConfigurations' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations.bin' | Should -Exist
    }

    It 'Clear-KitTreeExceptSupply стирає все, крім теки поставки' {
        $t = New-SupplyTree -Name 'clear'
        Set-Content -LiteralPath (Join-Path $t 'Ext/Other.xml') -Value 'x' -Encoding UTF8
        Clear-KitTreeExceptSupply -TreeRoot $t -MustBeUnder $TestDrive
        Join-Path $t 'Configuration.xml' | Should -Not -Exist
        Join-Path $t 'Ext/Other.xml' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations.bin' | Should -Not -Exist
        Join-Path $t 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }

    It 'Clear-KitTreeExceptSupply поза межею — зупинка' {
        $t = New-SupplyTree -Name 'outside'
        { Clear-KitTreeExceptSupply -TreeRoot $t -MustBeUnder (Join-Path $TestDrive 'elsewhere') } | Should -Throw
        Join-Path $t 'Configuration.xml' | Should -Exist
    }

    It 'Remove-KitSupplyDir поза межею — зупинка, тека поставки лишається' {
        $t = New-SupplyTree -Name 'remove-outside'
        { Remove-KitSupplyDir -TreeRoot $t -MustBeUnder (Join-Path $TestDrive 'elsewhere') } | Should -Throw
        Join-Path $t 'Ext/ParentConfigurations/Vendor.cf' | Should -Exist
    }

    It 'рецепт (ii)/(iii) називає головну гілку, verify, canon і operation=build' {
        $r = Get-KitSupplyRecipe -SourceKey 'base' -MainBranch 'main' -State 'stale'
        $r | Should -BeLike '*main*'
        $r | Should -BeLike '*kit verify -Source base*'
        $r | Should -BeLike '*kit canon -Source base -Apply*'
        $r | Should -BeLike '*operation=build*'
    }

    It 'рецепт застерігає, що в (i) canon іде на гілці онбордингу без verify' {
        $r = Get-KitSupplyRecipe -SourceKey 'base' -MainBranch 'main' -State 'missing'
        $r | Should -BeLike '*У рецепті (i)*canon -Source base виконується на гілці онбордингу до PR*verify там не потрібен*'
    }
}
