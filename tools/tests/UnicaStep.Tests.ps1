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

Describe 'Критерій вирівнювання на справжньому git (§10 П3, П4; Review Focus 3, 5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'crit') -WithHooks -WithGitignore
        Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
    }
    It 'дерево набору в HEAD і в дзеркалі однакове — рівні' {
        Test-KitSetTreeEqual -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' -Left 'HEAD' -Right 'storage/Alpha_SMB' | Should -BeTrue
    }
    It 'шляху немає на одному боці — не рівні, не виняток' {
        Test-KitSetTreeEqual -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/nope' -Left 'HEAD' -Right 'storage/Alpha_SMB' | Should -BeFalse
    }
    It 'невідстежуваний файл під шляхом набору — дерево НЕ чисте (Review Focus 3)' {
        $f = Join-Path $script:Repo 'Alpha_SMB/cfe/src/Новая.xml'
        Set-Content -LiteralPath $f -Value 'нова форма' -Encoding UTF8
        try { Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeFalse }
        finally { Remove-Item -LiteralPath $f -Force }
        Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue
    }
    It 'гітігнорований файл під шляхом набору — дерево чисте' {
        $d = Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext/ParentConfigurations'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Vendor.cf') -Value 'cf' -Encoding ascii
        try { Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue }
        finally { Remove-KitDirectory -Path (Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext') }
    }
    It 'Test-KitRefIsHead: ім''я гілки, sha і від''єднаний HEAD — через ^{commit} (Review Focus 5)' {
        $sha = (git -C $script:Repo rev-parse HEAD).Trim()
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'main' | Should -BeTrue
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref $sha | Should -BeTrue
        Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'storage/Alpha_SMB' | Should -BeFalse
        git -C $script:Repo checkout -q --detach $sha
        try { Test-KitRefIsHead -RepoRoot $script:Repo -Ref 'main' | Should -BeTrue }
        finally { git -C $script:Repo checkout -q main }
    }
}

Describe 'Get-KitAlignStep — таблиця §10 П5' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        function script:New-Set { param([string]$Type, [string]$Supply)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null
            if ($Supply -ne 'none') {
                [System.IO.File]::WriteAllBytes((Join-Path $root 'Ext/ParentConfigurations.bin'), [byte[]](1..32))
                $sha = (Get-FileHash -LiteralPath (Join-Path $root 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
                if ($Supply -in 'current', 'stale') { Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations/V.cf') -Value 'cf' -Encoding ascii }
                if ($Supply -eq 'current') { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), $sha) }
                if ($Supply -eq 'stale')   { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), 'deadbeef') }
            }
            [pscustomobject]@{ Key = 'base'; Type = $Type; FullPath = $root; RepoPath = 'Ws/cf/src'; Workspace = 'Ws' }
        }
    }
    It '<Kind>: <Type>/<Supply>, критерій <C> → <Op>, MarkerOnly <M>' -ForEach @(
        @{ Kind = 'file';   Type = 'EXTENSION';     Supply = 'none';    C = $true;  Op = 'pull';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'missing'; C = $true;  Op = 'pull';    M = $true }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'current'; C = $true;  Op = 'pull';    M = $true }
        @{ Kind = 'file';   Type = 'EXTENSION';     Supply = 'none';    C = $false; Op = 'push';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'current'; C = $false; Op = 'push';    M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'missing'; C = $false; Op = 'blocked'; M = $false }
        @{ Kind = 'file';   Type = 'CONFIGURATION'; Supply = 'stale';   C = $false; Op = 'blocked'; M = $false }
        @{ Kind = 'server'; Type = 'EXTENSION';     Supply = 'none';    C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'current'; C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'missing'; C = $true;  Op = 'push';    M = $false }
        @{ Kind = 'server'; Type = 'CONFIGURATION'; Supply = 'missing'; C = $false; Op = 'blocked'; M = $false }
    ) {
        $s = Get-KitAlignStep -Source (New-Set -Type $Type -Supply $Supply) -Criterion $C -BaseKind $Kind
        $s.Op | Should -Be $Op
        $s.MarkerOnly | Should -Be $M
    }
    It 'файлова pull CONFIGURATION: точний виклик і позначка з -Workspace другим кроком' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $true -BaseKind 'file'
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"base","force":true},"dryRun":true}'
        $s.Steps[1] | Should -BeExactly 'kit canon -Workspace Ws -Source base -MarkerOnly -Apply'
    }
    It 'файлова pull EXTENSION: extension = ім''я набору (схема pull Уніки 0.13)' {
        $set = New-Set -Type 'EXTENSION' -Supply 'none'; $set.Key = 'Alpha_SMB'
        $s = Get-KitAlignStep -Source $set -Criterion $true -BaseKind 'file'
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"pull","args":{"sourceSet":"Alpha_SMB","extension":"Alpha_SMB","force":true},"dryRun":true}'
    }
    It 'серверна, критерій є, поставка без .cf: спершу kit canon (не MarkerOnly), потім push force' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $true -BaseKind 'server'
        $s.Steps[0] | Should -BeExactly 'kit canon -Workspace Ws -Source base -Apply'
        $s.Steps[1] | Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
        ($s.Steps -join "`n") | Should -Not -BeLike '*"op":"pull"*'
    }
    It 'push: force:true, без позначки' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
        @($s.Steps) | Should -HaveCount 1
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"base","force":true},"dryRun":true}'
    }
    It 'blocked: кроків немає, рецепт називає verify з -Workspace і MarkerOnly' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $false -BaseKind 'file'
        @($s.Steps) | Should -HaveCount 0
        $s.Recipe | Should -BeLike '*kit verify -Workspace Ws -Source base*-MarkerOnly*'
    }
    It 'Write-KitAlignStep мовчить про blocked; Write-KitAlignStops друкує ЗУПИНКА лише для blocked' {
        $b = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $false -BaseKind 'file'
        $p = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
        (& { Write-KitAlignStep -Step $b } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
        $out = & { Write-KitAlignStops -Steps @($p, $b) } 6>&1 | Out-String
        @($out -split "`r?`n" | Where-Object { $_ -like '*ЗУПИНКА:*' }).Count | Should -Be 1
    }
}
