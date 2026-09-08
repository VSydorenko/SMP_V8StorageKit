#Requires -Version 7
Describe 'AgentBase.psm1 — база агента з вказівника Уніки, аудит проти бази людини' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/AgentBase.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'файлова база з v8project.yaml: шлях під воркспейсом, ще не існує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'file'
        $ab.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib')))
        $ab.Exists | Should -BeFalse
        $ab.Origin | Should -BeLike '*v8project.yaml'
    }

    It 'v8project.local.yaml перекриває на серверну; Origin — накладка Уніки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'server')
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'server'
        $ab.IbSwitch | Should -Be '/S "VSDEV\agent_alpha"'
        $ab.Origin | Should -BeLike '*v8project.local.yaml'
    }

    It 'підключення бази агента збігається з дев-базою людини з накладки kit — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Правка виконавця (обов'язкова, ухвалена заздалегідь): у брифі тест мав патерн
        # '*devUNF*людини*', але саме повідомлення функції несе зворотний порядок —
        # «...збігається з дев-базою людини 'devUNF' із накладки kit» (межа принципу 3
        # читається людиною, і саме повідомлення не змінюється; змінюється тест).
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*людини*devUNF*'
    }

    It 'воркспейс без infobase: — $null' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws)
        Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] | Should -BeNullOrEmpty
    }
}
