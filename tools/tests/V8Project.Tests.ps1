#Requires -Version 7
Describe 'V8Project.psm1 — читання v8project.yaml Уніки' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path

        # Копія фікстури в окрему теку — FullPath має рахуватись від теки САМОГО файлу,
        # а v8project.local.yaml поруч із нею — з'являтись і зникати між тестами.
        $script:Ws = Join-Path $TestDrive 'Alpha_SMB'
        New-Item -ItemType Directory -Path $script:Ws -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'v8project-extension.yaml') `
            -Destination (Join-Path $script:Ws 'v8project.yaml')
    }
    AfterEach {
        Remove-Item -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -ErrorAction SilentlyContinue
    }

    It 'розбирає воркспейс розширення: два source-set-и, providers, шляхи від теки конфіга' {
        $p = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
        $p.WorkPath | Should -Be 'build'
        $p.Providers['push'] | Should -Be 'designer'
        $p.SourceSets.Count | Should -Be 2
        $p.SourceSets[1].Name | Should -Be 'SMP_BankExchange_SMB'
        $p.SourceSets[1].Type | Should -Be 'EXTENSION'
        $p.SourceSets[1].Path | Should -Be 'cfe/src'
        $p.SourceSets[1].FullPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Ws 'cfe/src')))
    }

    It 'воркспейс зовнішніх обробок читається; без providers — Providers = $null, а не помилка' {
        $p = Read-V8Project -Path (Join-Path $script:Fixtures 'v8project-epf.yaml')
        $p.Providers['pull'] | Should -Be 'designer'
        $f2 = Join-Path $TestDrive 'no-providers.yaml'
        Set-Content -LiteralPath $f2 -Encoding UTF8 -Value @('source-set:', '  - name: x', '    type: EXTENSION', "    path: 'a'")
        (Read-V8Project -Path $f2).Providers | Should -BeNullOrEmpty
        $p.SourceSets[0].Type | Should -Be 'EXTERNAL_DATA_PROCESSORS'
        $p.SourceSets[0].Path | Should -Be 'src'
    }

    It 'зупиняється без розділу source-set' {
        $f = Join-Path $TestDrive 'no-sets.yaml'
        Set-Content -LiteralPath $f -Value "format: DESIGNER`n" -Encoding UTF8
        { Read-V8Project -Path $f } | Should -Throw '*source-set*'
    }

    It 'зупиняється на невідомому type source-set, називаючи його і відомі' {
        $f = Join-Path $TestDrive 'bad-type.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:', '  - name: x', '    type: REPORT', "    path: 'src'")
        { Read-V8Project -Path $f } | Should -Throw '*REPORT*EXTERNAL_DATA_PROCESSORS*'
    }

    It 'зупиняється, коли в елементі source-set бракує path' {
        $f = Join-Path $TestDrive 'no-path.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:', '  - name: x', '    type: EXTENSION')
        { Read-V8Project -Path $f } | Should -Throw "*'path'*"
    }

    It 'зупиняється на двох source-set-ах з однаковим name' {
        $f = Join-Path $TestDrive 'dup-name.yaml'
        Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
            'source-set:',
            '  - name: x', '    type: EXTENSION', "    path: 'a'",
            '  - name: x', '    type: EXTENSION', "    path: 'b'")
        { Read-V8Project -Path $f } | Should -Throw '*двічі*'
    }

    Context 'v8project.local.yaml — вказівник Уніки на базу агента (§2.5)' {
        It 'без файлу — $null' {
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'з devInfobase: (стара конвенція kit), але без infobases: — $null' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'devInfobase:', "  connection: 'Srvr=VSDEV;Ref=X;'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'стара форма infobase: не читається — $null (запасного читання немає, це знахідка конфігу)' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobase:', "  connection: 'Srvr=VSDEV;Ref=agent_ib;'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'з infobases.origin — повертає connection, user, password, dbms' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobases:', '  origin:', "    connection: 'Srvr=VSDEV;Ref=agent_ib;'", "    user: 'u'")
            $r = Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml')
            $r.Connection | Should -Be 'Srvr=VSDEV;Ref=agent_ib;'
            $r.User | Should -Be 'u'
            $r.Password | Should -Be ''
            $r.Dbms | Should -BeNullOrEmpty
        }

        It 'Resolve-V8AgentInfobase без v8project.local.yaml — $null (воркспейс epf)' {
            $p = Read-V8Project -Path (Join-Path $script:Fixtures 'v8project-epf.yaml')
            Resolve-V8AgentInfobase -Project $p | Should -BeNullOrEmpty
        }
    }
}

Describe 'V8Project.psm1 — шлях і ключ бази агента' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        $script:Ws = Join-Path $TestDrive 'Ws_SMB'
        New-Item -ItemType Directory -Path $script:Ws -Force | Out-Null
        Copy-Item (Resolve-Path "$PSScriptRoot/fixtures/v8project-extension.yaml").Path (Join-Path $script:Ws 'v8project.yaml')
        $script:Project = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
    }
    AfterEach { Remove-Item (Join-Path $script:Ws 'v8project.local.yaml') -ErrorAction SilentlyContinue }

    It 'File=build/ib розв''язується від теки воркспейсу; ключ /F абсолютний' {
        $r = Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'File=build/ib'
        $r.Kind | Should -Be 'file'
        $r.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Ws 'build/ib')))
        $r.IbSwitch | Should -Be ('/F "{0}"' -f $r.Path)
    }
    It 'абсолютний File= лишається як є' {
        (Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'File=D:\ib\agent;').Path | Should -Be 'D:\ib\agent'
    }
    It 'Srvr= — server, ключ /S' {
        $r = Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'Srvr=VSDEV;Ref=agent;'
        $r.Kind | Should -Be 'server'
        $r.IbSwitch | Should -Be '/S "VSDEV\agent"'
    }
    It 'Resolve-V8AgentInfobase повертає user із накладки Уніки, коли він є' {
        Set-Content (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @('infobases:', '  origin:', "    connection: 'Srvr=VSDEV;Ref=agent;'", "    user: 'Агент'")
        $r = Resolve-V8AgentInfobase -Project $script:Project
        $r.User | Should -Be 'Агент'
    }
}

Describe 'Get-V8ProjectConfigProblems (спека §4.3 п. 3, 5; §10 П9, П10)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
        function script:New-Ws { param([string]$Name, [string[]]$Project, [string[]]$Local)
            $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'v8project.yaml') -Encoding UTF8 -Value ($Project -join "`n")
            if ($Local) { Set-Content -LiteralPath (Join-Path $d 'v8project.local.yaml') -Encoding UTF8 -Value ($Local -join "`n") }
            $d }
        $script:Clean = @('format: DESIGNER', "workPath: 'build'", 'providers:', '  push: designer', '  pull: designer', '  download: designer',
            'source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
    }
    It 'чиста форма 0.13 — знахідок немає (вкладений tests.execution_timeout_seconds законний)' {
        $d = New-Ws -Name 'clean' -Project ($script:Clean + @('tests:', '  execution_timeout_seconds: 600')) -Local @('infobases:', '  origin:', "    connection: 'File=build/ib'")
        @(Get-V8ProjectConfigProblems -Directory $d) | Should -BeNullOrEmpty
    }
    It 'усі застарілі ключі — усі знахідки разом, кожна з рецептом' {
        $proj = @('builder: DESIGNER', 'execution_timeout: 600000', 'basePath: x', 'push:', '  partialLoadThreshold: 10',
                  'infobase:', "  connection: 'File=build/ib'") + $script:Clean
        $d = New-Ws -Name 'old' -Project $proj -Local @('infobase:', "  connection: 'File=build/ib'")
        $p = @(Get-V8ProjectConfigProblems -Directory $d)
        ($p -join "`n") | Should -BeLike "*'builder'*Видаліть рядок*"
        ($p -join "`n") | Should -BeLike "*'execution_timeout'*"
        ($p -join "`n") | Should -BeLike "*'basePath'*"
        ($p -join "`n") | Should -BeLike "*'push.partialLoadThreshold'*"
        @($p | Where-Object { $_ -like "*стара форма 'infobase:'*infobases.origin*" }).Count | Should -Be 2
    }
    It 'infobases у закоміченому v8project.yaml — знахідка з переносом у local' {
        $d = New-Ws -Name 'committed' -Project ($script:Clean + @('infobases:', '  origin:', "    connection: 'File=build/ib'"))
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike '*infobases*закомічен*v8project.local.yaml*'
    }
    It 'infobases з іменем, крім origin, — знахідка' {
        $d = New-Ws -Name 'other' -Project $script:Clean -Local @('infobases:', '  dev:', "    connection: 'File=D:\x'")
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike "*'dev'*лише origin*"
    }
    It 'origin без connection — знахідка, а не тиха відсутність бази (Review Focus 4)' {
        $d = New-Ws -Name 'noconn' -Project $script:Clean -Local @('infobases:', '  origin:', "    user: 'agent'")
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike '*infobases.origin*connection*'
    }
    It 'providers: <Case>' -ForEach @(
        @{ Case = 'відсутній';         Lines = @() ;                                                     Want = "*providers*push: designer*" }
        @{ Case = 'pull інший';        Lines = @('providers:', '  push: designer', '  pull: agent', '  download: designer'); Want = "*providers.pull*agent*designer*" }
        @{ Case = 'download відсутній'; Lines = @('providers:', '  push: designer', '  pull: designer');  Want = "*providers.download*" }
    ) {
        $proj = @('format: DESIGNER') + $Lines + @('source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
        $d = New-Ws -Name ("prov-" + [guid]::NewGuid().ToString('N')) -Project $proj
        (@(Get-V8ProjectConfigProblems -Directory $d) -join "`n") | Should -BeLike $Want
    }
    It 'інші ключі providers вільні' {
        $proj = @('format: DESIGNER', 'providers:', '  push: designer', '  pull: designer', '  download: designer', '  make: agent',
                  'source-set:', '  - name: base', '    type: CONFIGURATION', "    path: 'cf/src'")
        $d = New-Ws -Name 'prov-extra' -Project $proj
        @(Get-V8ProjectConfigProblems -Directory $d) | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-V8AgentInfobase — лише infobases.origin у v8project.local.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Yaml.psm1").Path
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8Project.psm1").Path -Force
    }
    It 'повертає connection, user, password, dbms і Origin = local' {
        $d = Join-Path $TestDrive 'ws'; New-Item -ItemType Directory -Path $d | Out-Null
        Set-Content (Join-Path $d 'v8project.local.yaml') -Encoding UTF8 -Value (@(
            'infobases:', '  origin:', "    connection: 'Srvr=VSDEV;Ref=agent;'", "    user: 'Агент'", "    password: 'p@ss'",
            '    dbms:', '      kind: PostgreSQL', '      server: pg1', '      name: agent_db', '      locale: uk') -join "`n")
        $ib = Resolve-V8AgentInfobase -Project ([pscustomobject]@{ Directory = $d; Path = (Join-Path $d 'v8project.yaml') })
        $ib.Connection | Should -Be 'Srvr=VSDEV;Ref=agent;'
        $ib.User | Should -Be 'Агент'
        $ib.Password | Should -Be 'p@ss'
        $ib.Dbms['name'] | Should -Be 'agent_db'
        $ib.Origin | Should -BeLike '*v8project.local.yaml'
    }
    It 'немає v8project.local.yaml — $null (бази не налаштовано)' {
        $d = Join-Path $TestDrive 'ws2'; New-Item -ItemType Directory -Path $d | Out-Null
        Resolve-V8AgentInfobase -Project ([pscustomobject]@{ Directory = $d; Path = (Join-Path $d 'v8project.yaml') }) | Should -BeNullOrEmpty
    }
}
