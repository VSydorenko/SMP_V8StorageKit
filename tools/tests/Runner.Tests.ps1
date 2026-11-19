#Requires -Version 7
# Runner.psm1: раннер Уніки як інструмент kit. Знімки відповідей — справжні, зняті з
# v8-runner 0.18.1 на синтетичному воркспейсі (tools/tests/fixtures/runner/).
BeforeAll {
    Import-Module "$PSScriptRoot/../lib/V8.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/Runner.psm1" -Force

    $script:FixDir = (Resolve-Path "$PSScriptRoot/fixtures/runner").Path
    $script:FakeRunner = Join-Path $script:FixDir 'v8-runner.cmd'

    function script:Read-Snapshot([string]$Name) {
        Get-Content -LiteralPath (Join-Path $script:FixDir $Name) -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    function script:New-Workspace([switch]$WithLocal) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'v8project.yaml') -Value 'format: DESIGNER'
        if ($WithLocal) { Set-Content -LiteralPath (Join-Path $dir 'v8project.local.yaml') -Value 'infobases: {}' }
        [pscustomobject]@{ Directory = $dir }
    }
}

Describe 'Get-KitAgentPlatform: відповідь раннера (мок Invoke-KitRunner)' {
    It 'на знімку ok:true повертає data.selected.designer.path зі знімка' {
        $snap = Read-Snapshot 'platforms-ok.json'
        Mock Invoke-KitRunner { $snap } -ModuleName Runner

        $path = Get-KitAgentPlatform -Project (New-Workspace) -RunnerPath 'будь-який'

        $path | Should -BeExactly $snap.data.selected.designer.path
        $path | Should -Not -BeNullOrEmpty
    }

    It 'на знімку ok:false кидає виняток із data.message раннера й шляху не повертає' {
        $snap = Read-Snapshot 'platforms-no-infobase.json'
        $snap.ok | Should -BeFalse
        Mock Invoke-KitRunner { $snap } -ModuleName Runner

        $result = $null
        { $script:result = Get-KitAgentPlatform -Project (New-Workspace) -RunnerPath 'будь-який' } |
            Should -Throw -ExpectedMessage '*no infobase is selected*'
        $script:result | Should -BeNullOrEmpty
    }
}

Describe 'Get-KitRunnerPath: немає Уніки чи раннера' {
    It 'на реєстрі без плагіна кидає виняток і не звертається до Get-V8Path' {
        Mock Get-V8Path { 'C:\не\має\викликатись\1cv8.exe' } -ModuleName Runner
        $reg = Join-Path $TestDrive 'installed_plugins.json'
        '{"version":2,"plugins":{}}' | Set-Content -LiteralPath $reg -Encoding UTF8

        { Get-KitRunnerPath -InstalledPluginsPath $reg } | Should -Throw -ExpectedMessage '*Раннер не знайдено*'
        Should -Invoke Get-V8Path -ModuleName Runner -Times 0 -Exactly
    }

    It 'на встановленій Уніці без файла раннера називає шлях, якого бракує' {
        $install = Join-Path $TestDrive 'unica-install'
        New-Item -ItemType Directory -Path $install | Out-Null
        $reg = Join-Path $TestDrive 'installed_plugins2.json'
        @{ version = 2; plugins = @{ 'unica@unica' = @(@{ version = '0.16.0'; installPath = $install }) } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reg -Encoding UTF8

        { Get-KitRunnerPath -InstalledPluginsPath $reg } | Should -Throw -ExpectedMessage '*v8-runner.exe*'
    }

    It 'знаходить раннер у розкладці bin/win-x64/v8-runner-windows-x86_64' {
        $install = Join-Path $TestDrive 'unica-ok'
        $dir = Join-Path $install 'bin/win-x64/v8-runner-windows-x86_64'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'v8-runner.exe') -Value 'x'
        $reg = Join-Path $TestDrive 'installed_plugins3.json'
        @{ version = 2; plugins = @{ 'unica@unica' = @(@{ version = '0.16.0'; installPath = $install }) } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reg -Encoding UTF8

        (Get-KitRunnerPath -InstalledPluginsPath $reg) | Should -BeLike '*v8-runner-windows-x86_64*v8-runner.exe'
    }
}

Describe 'Фальшивий раннер v8-runner.cmd: справжній запуск без моку Invoke-KitRunner' {
    It 'Get-KitRunnerVersion повертає версію з рядка --version' {
        Get-KitRunnerVersion -RunnerPath $script:FakeRunner | Should -BeExactly '0.18.1'
    }

    It 'Get-KitAgentPlatform повертає шлях зі знімка ok:true' {
        $expected = (Read-Snapshot 'platforms-ok.json').data.selected.designer.path
        Get-KitAgentPlatform -Project (New-Workspace -WithLocal) -RunnerPath $script:FakeRunner |
            Should -BeExactly $expected
    }

    It 'без v8project.local.yaml раннер дає ok:false з кодом виходу 2, і kit зупиняється за ok, а не за кодом' {
        { Get-KitAgentPlatform -Project (New-Workspace) -RunnerPath $script:FakeRunner } |
            Should -Throw -ExpectedMessage '*no infobase is selected*'
    }

    It 'Invoke-KitAgentRelease віддає released і disconnected зі знімка' {
        $r = Invoke-KitAgentRelease -Project (New-Workspace -WithLocal) -RunnerPath $script:FakeRunner
        $r.released | Should -BeFalse
        $r.disconnected | Should -BeFalse
    }

    It 'невідомий файл раннера — виняток із шляхом' {
        { Invoke-KitRunner -RunnerPath (Join-Path $TestDrive 'нема.exe') -Arguments @('platforms') -WorkingDirectory $TestDrive } |
            Should -Throw -ExpectedMessage '*нема.exe*'
    }
}
