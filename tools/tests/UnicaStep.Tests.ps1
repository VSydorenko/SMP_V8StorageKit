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

Describe 'Get-KitCurrentBranch — поточна гілка на справжньому git (спека 2026-11-19 §4.2 п.9)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'branch') -WithHooks -WithGitignore
    }
    It 'ім''я гілки, зокрема з похилою рискою' {
        Get-KitCurrentBranch -RepoRoot $script:Repo | Should -BeExactly 'main'
        git -C $script:Repo checkout -q -b feature/x
        try { Get-KitCurrentBranch -RepoRoot $script:Repo | Should -BeExactly 'feature/x' }
        finally { git -C $script:Repo checkout -q main }
    }
    It 'від''єднаний HEAD — порожній рядок, а не виняток і не sha' {
        git -C $script:Repo checkout -q --detach
        try { Get-KitCurrentBranch -RepoRoot $script:Repo | Should -BeExactly '' }
        finally { git -C $script:Repo checkout -q main }
    }
    It 'Test-KitOnMainBranch: регістр має значення (Main ≠ main), гілка задачі, від''єднаний HEAD і не репозиторій — $false' {
        Test-KitOnMainBranch -RepoRoot $script:Repo -MainBranch 'main' | Should -BeTrue -Because 'контроль: збіг імені дає $true'
        Test-KitOnMainBranch -RepoRoot $script:Repo -MainBranch 'Main' | Should -BeFalse -Because 'git розрізняє регістр гілок; -eq дав би $true'
        git -C $script:Repo checkout -q -b feature/y
        try { Test-KitOnMainBranch -RepoRoot $script:Repo -MainBranch 'main' | Should -BeFalse }
        finally { git -C $script:Repo checkout -q main }
        git -C $script:Repo checkout -q --detach
        try { Test-KitOnMainBranch -RepoRoot $script:Repo -MainBranch 'main' | Should -BeFalse }
        finally { git -C $script:Repo checkout -q main }
        $notRepo = Join-Path $TestDrive 'not-a-repo2'
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        Test-KitOnMainBranch -RepoRoot $notRepo -MainBranch 'main' | Should -BeFalse
    }
    It 'не репозиторій — виняток, а не порожній рядок (його б прочитали як «не головна»)' {
        $notRepo = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        { Get-KitCurrentBranch -RepoRoot $notRepo } | Should -Throw '*git branch --show-current*'
    }
}

Describe 'Get-KitAlignStep — завжди push force, крім блокування поставки (спека 2026-11-19 §3.1, §4.2 п.7, п.9)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        function script:New-Set { param([string]$Type, [string]$Supply, [string]$Key = 'base')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'Ext/ParentConfigurations') -Force | Out-Null
            if ($Supply -ne 'none') {
                [System.IO.File]::WriteAllBytes((Join-Path $root 'Ext/ParentConfigurations.bin'), [byte[]](1..32))
                $sha = (Get-FileHash -LiteralPath (Join-Path $root 'Ext/ParentConfigurations.bin') -Algorithm SHA1).Hash.ToLowerInvariant()
                if ($Supply -in 'current', 'stale') { Set-Content -LiteralPath (Join-Path $root 'Ext/ParentConfigurations/V.cf') -Value 'cf' -Encoding ascii }
                if ($Supply -eq 'current') { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), $sha) }
                if ($Supply -eq 'stale')   { [System.IO.File]::WriteAllText((Join-Path $root 'Ext/ParentConfigurations/.kit-bin-sha1'), 'deadbeef') }
            }
            [pscustomobject]@{ Key = $Key; Type = $Type; FullPath = $root; RepoPath = 'Ws/cf/src'; Workspace = 'Ws' }
        }
    }
    It '<Type>/<Supply>, OnMainBranch <Main> → <Op>' -ForEach @(
        @{ Type = 'EXTENSION';     Supply = 'none';    Main = $true;  Op = 'push' }
        @{ Type = 'EXTENSION';     Supply = 'none';    Main = $false; Op = 'push' }
        @{ Type = 'EXTENSION';     Supply = 'current'; Main = $true;  Op = 'push' }
        @{ Type = 'CONFIGURATION'; Supply = 'none';    Main = $true;  Op = 'push' }
        @{ Type = 'CONFIGURATION'; Supply = 'none';    Main = $false; Op = 'push' }
        @{ Type = 'CONFIGURATION'; Supply = 'current'; Main = $false; Op = 'push' }
        @{ Type = 'CONFIGURATION'; Supply = 'missing'; Main = $true;  Op = 'blocked' }
        @{ Type = 'CONFIGURATION'; Supply = 'missing'; Main = $false; Op = 'blocked' }
        @{ Type = 'CONFIGURATION'; Supply = 'stale';   Main = $true;  Op = 'blocked' }
        @{ Type = 'CONFIGURATION'; Supply = 'stale';   Main = $false; Op = 'blocked' }
    ) {
        $s = Get-KitAlignStep -Source (New-Set -Type $Type -Supply $Supply) -OnMainBranch $Main -MainBranch 'main'
        $s.Op | Should -Be $Op
        $s.PSObject.Properties.Name | Should -Not -Contain 'BaseKind'
        $s.PSObject.Properties.Name | Should -Not -Contain 'MarkerOnly'
    }
    It 'push: рівно один крок, force:true, без extension навіть для розширення (Уніка не приймає його в push)' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none' -Key 'Alpha_SMB') -OnMainBranch $true -MainBranch 'main'
        @($s.Steps) | Should -HaveCount 1
        $s.Steps[0] | Should -BeExactly 'unica.run {"op":"push","args":{"sourceSet":"Alpha_SMB","force":true},"dryRun":true}'
        $s.Recipe | Should -BeNullOrEmpty
    }
    It 'blocked, головна гілка: кроків немає, рецепт — повний pull і supply-marker, без push' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'stale') -OnMainBranch $true -MainBranch 'main'
        @($s.Steps) | Should -HaveCount 0
        $s.Recipe | Should -BeLike '*"op":"pull"*"sourceSet":"base"*"force":true*kit supply-marker -Workspace Ws -Source base -Apply*'
        $s.Recipe | Should -Not -BeLike '*"op":"push"*'
        # Після повного pull push force не потрібен (§4.2 п.18).
        $s.Recipe | Should -BeLike '*supply-marker*push force не потрібен*' -Because 'після позначки поставки рецепт прямо каже, що push force не потрібен'
    }
    It 'blocked, гілка задачі: «спершу поставка на головній гілці», без pull і supply-marker' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -OnMainBranch $false -MainBranch 'main'
        $s.Recipe | Should -BeLike '*спершу поставка на головній гілці*'
        $s.Recipe | Should -Not -BeLike '*"op":"pull"*'
        $s.Recipe | Should -Not -BeLike '*supply-marker*'
    }
    It 'ім''я головної гілки в рецепті — з параметра, а не вписане' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -OnMainBranch $true -MainBranch 'trunk'
        $s.Recipe | Should -BeLike '*на гілці trunk*'
    }
    It 'єдине джерело тексту: Recipe зупинки і знахідка check діляться розрізняльною фразою з Get-KitSupplyRecipe' {
        $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -OnMainBranch $true -MainBranch 'main'
        $c = Get-KitSupplyRecipe -SourceKey 'base' -Workspace 'Ws' -MainBranch 'main' -State 'missing' -Purpose check -OnMainBranch $true
        $s.Recipe | Should -BeLike '*Відновлення поставки вендора: на гілці main*'
        $c | Should -BeLike '*Відновлення поставки вендора: на гілці main*'
        # Крок pull у рецепті — рівно те, що друкує Format-KitUnicaRun (Supply не може його імпортувати — цикл).
        $pull = Format-KitUnicaRun -Op 'pull' -Arguments ([ordered]@{ sourceSet = 'base'; force = $true })
        $s.Recipe.Contains($pull) | Should -BeTrue
    }
    It 'стан поставки не обчислився — blocked (не push), рядок причини, Supply = unknown' {
        Mock -ModuleName UnicaStep Get-KitSupplyState { throw 'збій читання поставки' }
        $out = & { $script:S = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'none') -OnMainBranch $true -MainBranch 'main' } 6>&1 | Out-String
        $script:S.Op | Should -Be 'blocked'
        $script:S.Supply | Should -Be 'unknown'
        $out | Should -BeLike '*стан поставки не обчислено: збій читання поставки*'
        $script:S.Recipe | Should -BeLike '*стан поставки вендора не обчислено*supply-marker*'
    }
    It 'Write-KitAlignStep мовчить про blocked; Write-KitAlignStops друкує ЗУПИНКА лише для blocked' {
        $b = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -OnMainBranch $true -MainBranch 'main'
        $p = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -OnMainBranch $true -MainBranch 'main'
        (& { Write-KitAlignStep -Step $b } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
        $out = & { Write-KitAlignStops -Steps @($p, $b) } 6>&1 | Out-String
        @($out -split "`r?`n" | Where-Object { $_ -like '*ЗУПИНКА:*' }) | Should -HaveCount 1
        (& { Write-KitAlignStops -Steps @($p) } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
        (& { Write-KitAlignStops -Steps @() } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
    }
    It 'Write-KitAlignStep друкує push і застереження: питання Уніки очікуване, лише інтерактивна сесія, cancelled — зупинка' {
        $p = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'current') -OnMainBranch $true -MainBranch 'main'
        $out = & { Write-KitAlignStep -Step $p } 6>&1 | Out-String
        $out | Should -Match ([regex]::Escape('"op":"push"'))
        $out | Should -BeLike '*Уніка спитає людину про перезапис бази origin*'
        $out | Should -BeLike '*claude -p*'
        $out | Should -BeLike '*cancelled*база агента не вирівняна; наступний push відмовить*'
        $out | Should -Not -BeLike '*без питання людині*' -Because 'фраза з тексту 1.5.0 хибна: Уніка питає'
        $out | Should -Not -Match 'Після pull'
    }
}
