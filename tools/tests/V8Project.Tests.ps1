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

    It 'розбирає воркспейс розширення: два source-set-и, підключення бази агента, шляхи від теки конфіга' {
        $p = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
        $p.WorkPath | Should -Be 'build'
        $p.InfobaseConnection | Should -Be 'File=build/ib'
        $p.SourceSets.Count | Should -Be 2
        $p.SourceSets[1].Name | Should -Be 'SMP_BankExchange_SMB'
        $p.SourceSets[1].Type | Should -Be 'EXTENSION'
        $p.SourceSets[1].Path | Should -Be 'cfe/src'
        $p.SourceSets[1].FullPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Ws 'cfe/src')))
    }

    It 'воркспейс без infobase: (зовнішні обробки) дає InfobaseConnection = $null, а не помилку' {
        $p = Read-V8Project -Path (Join-Path $script:Fixtures 'v8project-epf.yaml')
        $p.InfobaseConnection | Should -BeNullOrEmpty
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

        It 'з devInfobase: (стара конвенція kit), але без infobase: — $null' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'devInfobase:', "  connection: 'Srvr=""VSDEV"";Ref=""X"";'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') | Should -BeNullOrEmpty
        }

        It 'з infobase.connection — повертає рядок як є' {
            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_ib"";'")
            Read-V8ProjectLocalInfobase -Path (Join-Path $script:Ws 'v8project.local.yaml') |
                Should -Be 'Srvr="VSDEV";Ref="agent_ib";'
        }

        It 'Resolve-V8AgentInfobase: накладка Уніки виграє у закоміченого конфіга й називає джерело' {
            $p = Read-V8Project -Path (Join-Path $script:Ws 'v8project.yaml')
            (Resolve-V8AgentInfobase -Project $p).Connection | Should -Be 'File=build/ib'
            (Resolve-V8AgentInfobase -Project $p).Origin | Should -Be $p.Path

            Set-Content -LiteralPath (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @(
                'infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_ib"";'")
            $r = Resolve-V8AgentInfobase -Project $p
            $r.Connection | Should -Be 'Srvr="VSDEV";Ref="agent_ib";'
            $r.Origin | Should -BeLike '*v8project.local.yaml'
        }

        It 'Resolve-V8AgentInfobase без жодного підключення — $null (воркспейс epf)' {
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
        (Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'File="D:\ib\agent";').Path | Should -Be 'D:\ib\agent'
    }
    It 'Srvr= — server, ключ /S' {
        $r = Resolve-KitAgentInfobasePath -Project $script:Project -Connection 'Srvr="VSDEV";Ref="agent";'
        $r.Kind | Should -Be 'server'
        $r.IbSwitch | Should -Be '/S "VSDEV\agent"'
    }
    It 'Resolve-V8AgentInfobase повертає user із накладки Уніки, коли він є' {
        Set-Content (Join-Path $script:Ws 'v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent"";'", "  user: 'Агент'")
        $r = Resolve-V8AgentInfobase -Project $script:Project
        $r.User | Should -Be 'Агент'
    }
}
