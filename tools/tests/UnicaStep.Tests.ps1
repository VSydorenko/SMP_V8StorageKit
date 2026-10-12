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
    It 'junction під шляхом набору — дерево НЕ чисте (П24, вид link)' {
        $target = Join-Path $TestDrive 'crit-junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $link = Join-Path $script:Repo 'Alpha_SMB/cfe/src/lnk'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try { Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeFalse }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
        Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue
    }
    It 'похідне гітігноване (.cf поставки, ConfigDumpInfo.xml) під шляхом набору — дерево чисте; власний гітігнорований файл — ні (П24)' {
        $d = Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext/ParentConfigurations'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Vendor.cf') -Value 'cf' -Encoding ascii
        $info = Join-Path $script:Repo 'Alpha_SMB/cfe/src/ConfigDumpInfo.xml'
        Set-Content -LiteralPath $info -Value '<x/>' -Encoding UTF8
        $own = Join-Path $script:Repo 'Alpha_SMB/cfe/src/build/own.txt'
        try {
            git -C $script:Repo check-ignore -q 'Alpha_SMB/cfe/src/ConfigDumpInfo.xml'; $LASTEXITCODE | Should -Be 0 -Because 'контроль має спиратись на справді ігнорований файл'
            Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeTrue
            New-Item -ItemType Directory -Path (Split-Path $own) -Force | Out-Null
            Set-Content -LiteralPath $own -Value 'робота агента' -Encoding UTF8
            git -C $script:Repo check-ignore -q 'Alpha_SMB/cfe/src/build/own.txt'; $LASTEXITCODE | Should -Be 0
            Test-KitSetClean -RepoRoot $script:Repo -RepoPath 'Alpha_SMB/cfe/src' | Should -BeFalse
        }
        finally {
            Remove-KitDirectory -Path (Join-Path $script:Repo 'Alpha_SMB/cfe/src/Ext')
            Remove-KitDirectory -Path (Join-Path $script:Repo 'Alpha_SMB/cfe/src/build')
            Remove-Item -LiteralPath $info -Force -ErrorAction SilentlyContinue
        }
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

Describe 'Критерій вирівнювання — фікс-раунд 1 (fail-closed, негативні випадки)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        function script:G { param([string]$R) & git -C $R @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $args -> $LASTEXITCODE" } }
        function script:New-Mini {
            $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $r -Force | Out-Null
            G $r init -q; G $r config user.email 't@example.invalid'; G $r config user.name T
            G $r config commit.gpgsign false; G $r config core.autocrlf false
            G $r symbolic-ref HEAD refs/heads/main
            foreach ($d in 'Ws/cf/src', 'Ws/cf2/src', 'Other') {
                New-Item -ItemType Directory -Path (Join-Path $r $d) -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $r "$d/a.txt") -Value "start $d" -Encoding UTF8
            }
            G $r add -A; G $r commit -q -m first
            $r
        }
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

    Context 'Test-KitSetTreeEqual' {
        It 'вміст набору різний (додатковий коміт у дзеркалі) — не рівні' {
            $r = New-Mini
            G $r branch storage/X
            G $r checkout -q storage/X
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'інакше' -Encoding UTF8
            G $r commit -q -a -m zmina
            G $r checkout -q main
            Test-KitSetTreeEqual -RepoRoot $r -RepoPath 'Ws/cf/src' -Left 'main' -Right 'storage/X' | Should -BeFalse
            Test-KitSetTreeEqual -RepoRoot $r -RepoPath 'Ws/cf2/src' -Left 'main' -Right 'storage/X' | Should -BeTrue
        }
        It 'шлях є лише в Left і лише в Right — не рівні в обидва боки' {
            $r = New-Mini
            G $r branch storage/X
            New-Item -ItemType Directory -Path (Join-Path $r 'Ws/lonly') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $r 'Ws/lonly/f.txt') -Value 'x' -Encoding UTF8
            G $r add -A; G $r commit -q -m lonly
            Test-KitSetTreeEqual -RepoRoot $r -RepoPath 'Ws/lonly' -Left 'main' -Right 'storage/X' | Should -BeFalse
            Test-KitSetTreeEqual -RepoRoot $r -RepoPath 'Ws/lonly' -Left 'storage/X' -Right 'main' | Should -BeFalse
        }
        It '<P>: порожній нормалізований шлях — виняток, не порівняння коренів' -ForEach @(@{ P = '/' }, @{ P = '\' }, @{ P = '' }) {
            $r = New-Mini
            { Test-KitSetTreeEqual -RepoRoot $r -RepoPath $P -Left 'main' -Right 'main' } | Should -Throw
        }
        It 'RepoRoot — підтека репозиторію: виняток' {
            $r = New-Mini
            { Test-KitSetTreeEqual -RepoRoot (Join-Path $r 'Ws') -RepoPath 'cf/src' -Left 'main' -Right 'main' } | Should -Throw '*не є коренем*'
        }
    }

    Context 'Test-KitRefIsHead' {
        It 'анотований тег на HEAD — true; анотований тег на іншому коміті — false' {
            $r = New-Mini
            G $r tag -a v1 -m x
            Set-Content -LiteralPath (Join-Path $r 'Other/a.txt') -Value 'ще' -Encoding UTF8
            G $r commit -q -a -m second
            G $r tag -a v2 -m y
            Test-KitRefIsHead -RepoRoot $r -Ref 'v2' | Should -BeTrue
            Test-KitRefIsHead -RepoRoot $r -Ref 'v1' | Should -BeFalse
        }
        It 'неіснуючий Ref — false' {
            Test-KitRefIsHead -RepoRoot (New-Mini) -Ref 'nema-takogo' | Should -BeFalse
        }
    }

    Context 'Test-KitSetClean' {
        It 'змінений відстежуваний — не чисто' {
            $r = New-Mini
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка' -Encoding UTF8
            Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeFalse
        }
        It 'застейджений — не чисто' {
            $r = New-Mini
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка' -Encoding UTF8
            G $r add Ws/cf/src/a.txt
            Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeFalse
        }
        It 'видалений — не чисто' {
            $r = New-Mini
            Remove-Item -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Force
            Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeFalse
        }
        It 'брудне поза RepoPath і в сусідньому наборі з префіксом (cf2) — не рахується' {
            $r = New-Mini
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf2/src/a.txt') -Value 'сусід' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $r 'Other/a.txt') -Value 'поза' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf2/src/new.txt') -Value 'нове' -Encoding UTF8
            Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeTrue
        }
        It '<P>: порожній нормалізований шлях — виняток, не перевірка всього репо' -ForEach @(@{ P = '/' }, @{ P = '\' }, @{ P = '' }) {
            { Test-KitSetClean -RepoRoot (New-Mini) -RepoPath $P } | Should -Throw
        }
        It 'RepoRoot — підтека репозиторію з брудним деревом: виняток, не «чисто»' {
            $r = New-Mini
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка' -Encoding UTF8
            { Test-KitSetClean -RepoRoot (Join-Path $r 'Ws') -RepoPath 'cf/src' } | Should -Throw '*не є коренем*'
        }
    }

    Context 'Get-KitAlignStep — комірки таблиці, яких бракувало' {
        It 'server/CONFIGURATION/stale, критерій є: Steps[0] = kit canon -Apply, Steps[1] = push force' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'stale') -Criterion $true -BaseKind 'server'
            $s.Op | Should -Be 'push'
            $s.Steps[0] | Should -BeExactly 'kit canon -Workspace Ws -Source base -Apply'
            $s.Steps[1] | Should -BeLike 'unica.run {"op":"push"*'
        }
        It 'server/CONFIGURATION/current, критерій є: рівно один крок, без canon' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'current') -Criterion $true -BaseKind 'server'
            @($s.Steps) | Should -HaveCount 1
            $s.Steps[0] | Should -BeLike 'unica.run {"op":"push"*'
        }
        It 'EXTENSION з Ext/ParentConfigurations на диску: pull без -MarkerOnly, один крок' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'current') -Criterion $true -BaseKind 'file'
            $s.Op | Should -Be 'pull'
            $s.Supply | Should -Be 'none'
            $s.MarkerOnly | Should -BeFalse
            @($s.Steps) | Should -HaveCount 1
        }
        It 'file/CONFIGURATION/stale, критерій є: pull + canon -MarkerOnly' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'stale') -Criterion $true -BaseKind 'file'
            $s.Op | Should -Be 'pull'
            $s.MarkerOnly | Should -BeTrue
            $s.Steps[1] | Should -BeExactly 'kit canon -Workspace Ws -Source base -MarkerOnly -Apply'
        }
        It 'file/CONFIGURATION/none, критерію немає: push з одним кроком' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'none') -Criterion $false -BaseKind 'file'
            $s.Op | Should -Be 'push'
            @($s.Steps) | Should -HaveCount 1
        }
    }

    Context 'Друк кроків' {
        It 'pull: кроки й рядок про перевірку після pull, шлях набору названо' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $true -BaseKind 'file'
            $out = & { Write-KitAlignStep -Step $s } 6>&1 | Out-String
            $out | Should -Match ([regex]::Escape('"op":"pull"'))
            $out | Should -Match ([regex]::Escape('kit canon -Workspace Ws -Source base -MarkerOnly -Apply'))
            $out | Should -Match 'Після pull: git status --porcelain -- Ws/cf/src'
        }
        It 'push: кроки є, рядка про перевірку після pull немає' {
            $s = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
            $out = & { Write-KitAlignStep -Step $s } 6>&1 | Out-String
            $out | Should -Match ([regex]::Escape('"op":"push"'))
            $out | Should -Not -Match 'Після pull'
        }
        It 'Write-KitAlignStops: без blocked — порожньо; кілька blocked — по рядку на кожен' {
            $p = Get-KitAlignStep -Source (New-Set -Type 'EXTENSION' -Supply 'none') -Criterion $false -BaseKind 'file'
            (& { Write-KitAlignStops -Steps @($p) } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
            (& { Write-KitAlignStops -Steps @() } 6>&1 | Out-String).Trim() | Should -BeNullOrEmpty
            $b1 = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'missing') -Criterion $false -BaseKind 'file'
            $b2 = Get-KitAlignStep -Source (New-Set -Type 'CONFIGURATION' -Supply 'stale') -Criterion $false -BaseKind 'server'
            $out = & { Write-KitAlignStops -Steps @($b1, $p, $b2) } 6>&1 | Out-String
            @($out -split "`r?`n" | Where-Object { $_ -like 'ЗУПИНКА:*' }) | Should -HaveCount 2
        }
    }
}

Describe 'Невидима робота під набором — фікс-раунд 2 (спека §10.2 П24)' {
    BeforeAll {
        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        function script:G { param([string]$R) & git -C $R @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $args -> $LASTEXITCODE" } }
        function script:New-Mini2 {
            $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $r 'Ws/cf/src') -Force | Out-Null
            G $r init -q; G $r config user.email 't@example.invalid'; G $r config user.name T
            G $r config commit.gpgsign false; G $r config core.autocrlf false
            G $r symbolic-ref HEAD refs/heads/main
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'start' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $r '.gitignore') -Value "ConfigDumpInfo.xml`nDumpFilesIndex.txt`n**/Ext/ParentConfigurations/`n" -Encoding UTF8
            G $r add -A; G $r commit -q -m first
            $r
        }
        function script:New-Set2 { param([string]$Type)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            [pscustomobject]@{ Key = 'base'; Type = $Type; FullPath = $root; RepoPath = 'Ws/cf/src'; Workspace = 'Ws' }
        }
        function script:Op-For { param([string]$R)
            $c = Test-KitSetClean -RepoRoot $R -RepoPath 'Ws/cf/src'
            (Get-KitAlignStep -Source (New-Set2 -Type 'EXTENSION') -Criterion $c -BaseKind 'file').Op
        }
    }

    It 'файл агента під .git/info/exclude (ignored) — не чисто, крок push' {
        $r = New-Mini2
        Add-Content -LiteralPath (Join-Path $r '.git/info/exclude') -Value 'Ws/cf/src/mine.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/mine.txt') -Value 'робота' -Encoding UTF8
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0 -Because 'status цього файлу не бачить'
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        $w | Should -HaveCount 1
        $w[0].Kind | Should -Be 'ignored'
        $w[0].Path | Should -Be 'Ws/cf/src/mine.txt'
        Op-For $r | Should -Be 'push'
    }
    It 'контроль: ConfigDumpInfo.xml, DumpFilesIndex.txt і .cf в Ext/ParentConfigurations ігноровані — невидимої роботи немає, pull можливий' {
        $r = New-Mini2
        New-Item -ItemType Directory -Path (Join-Path $r 'Ws/cf/src/Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/Ext/ParentConfigurations/V.cf') -Value 'cf' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/ConfigDumpInfo.xml') -Value '<x/>' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/DumpFilesIndex.txt') -Value 'i' -Encoding UTF8
        git -C $r ls-files --others --ignored --exclude-standard -- Ws/cf/src | Should -HaveCount 3 -Because 'контроль має спиратись на справді ігноровані файли'
        @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0
        Op-For $r | Should -Be 'pull'
    }
    It '<Flag> на зміненому файлі: status мовчить, критерій — не чисто, крок push' -ForEach @(
        @{ Flag = 'assume-unchanged'; Kind = 'flagged' }
        @{ Flag = 'skip-worktree'; Kind = 'flagged' }
    ) {
        $r = New-Mini2
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка агента' -Encoding UTF8
        G $r update-index "--$Flag" Ws/cf/src/a.txt
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0 -Because 'status цього не бачить'
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        $w | Should -HaveCount 1
        $w[0].Kind | Should -Be $Kind
        $w[0].Path | Should -Be 'Ws/cf/src/a.txt'
        Op-For $r | Should -Be 'push'
    }
    It 'gitlink (підмодуль) під набором — не чисто, крок push' {
        $r = New-Mini2
        $sha = (git -C $r rev-parse HEAD).Trim()
        G $r update-index --add --cacheinfo "160000,$sha,Ws/cf/src/sub"
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        @($w | Where-Object { $_.Kind -eq 'gitlink' -and $_.Path -eq 'Ws/cf/src/sub' }) | Should -HaveCount 1
        Op-For $r | Should -Be 'push'
    }
    It 'вкладений git-репозиторій (невідстежуваний) під набором — не чисто, крок push' {
        $r = New-Mini2
        $nest = Join-Path $r 'Ws/cf/src/nest'
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        & git -C $nest init -q
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        @($w | Where-Object { $_.Kind -eq 'nested-repo' -and $_.Path -eq 'Ws/cf/src/nest' }) | Should -HaveCount 1
        Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeFalse
        Op-For $r | Should -Be 'push'
    }
    It 'збій git — виняток, не «чисто»' {
        $notRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        { Get-KitInvisibleWork -RepoRoot $notRepo -RepoPath 'Ws/cf/src' } | Should -Throw
    }
    It 'контроль меж: конфлікт злиття (тег M у ls-files -v) — не прапорець, але status дає UU, тож не чисто' {
        $r = New-Mini2
        G $r checkout -q -b other
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'в other' -Encoding UTF8
        G $r commit -q -a -m o
        G $r checkout -q main
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'в main' -Encoding UTF8
        G $r commit -q -a -m m
        & git -C $r merge other 2>&1 | Out-Null
        (git -C $r status --porcelain -- Ws/cf/src) | Should -BeLike 'UU*'
        @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0
        Test-KitSetClean -RepoRoot $r -RepoPath 'Ws/cf/src' | Should -BeFalse
    }
}
