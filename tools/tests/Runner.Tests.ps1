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
        @{ version = 2; plugins = @{ 'unica@unica' = @(@{ scope = 'user'; version = '0.16.0'; installPath = $install }) } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reg -Encoding UTF8

        { Get-KitRunnerPath -InstalledPluginsPath $reg } | Should -Throw -ExpectedMessage '*v8-runner.exe*'
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

    It 'ok:false з кодом виходу 0 — усе одно виняток із data.message (вирішує ok, не код)' {
        $ws = New-Workspace
        Set-Content -LiteralPath (Join-Path $ws.Directory 'fake-exit.txt') -Value '0'
        { Get-KitAgentPlatform -Project $ws -RunnerPath $script:FakeRunner } |
            Should -Throw -ExpectedMessage '*no infobase is selected*'
    }

    It 'ok:true з ненульовим кодом виходу — шлях платформи повертається (вирішує ok, не код)' {
        $ws = New-Workspace -WithLocal
        Set-Content -LiteralPath (Join-Path $ws.Directory 'fake-exit.txt') -Value '3'
        $expected = (Read-Snapshot 'platforms-ok.json').data.selected.designer.path
        Get-KitAgentPlatform -Project $ws -RunnerPath $script:FakeRunner | Should -BeExactly $expected
    }
}

Describe 'Get-KitRunnerVerdict: версія раннера' {
    BeforeAll {
        # Копія фальшивого раннера з іншим version.txt: .cmd читає версію з файла поруч із собою.
        function script:New-VersionedRunner([string]$Line) {
            $dir = Join-Path $TestDrive ('runner-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item -Path (Join-Path $script:FixDir '*') -Destination $dir -Recurse
            Set-Content -LiteralPath (Join-Path $dir 'version.txt') -Value $Line -Encoding ASCII
            Join-Path $dir 'v8-runner.cmd'
        }
    }
    It '<Line> → <Level>' -ForEach @(
        @{ Line = 'v8-runner 0.18.1'; Level = 'ok' }
        @{ Line = 'v8-runner 0.18.9-fork.3'; Level = 'ok' }
        @{ Line = 'v8-runner 0.19.0'; Level = 'warn' }
        @{ Line = 'v8-runner 0.17.4'; Level = 'warn' }
    ) {
        (Get-KitRunnerVerdict -RunnerPath (New-VersionedRunner $Line)).Level | Should -Be $Level
    }
    It 'warn називає версію й процедуру звірки' {
        $v = Get-KitRunnerVerdict -RunnerPath (New-VersionedRunner 'v8-runner 0.19.0')
        $v.Message | Should -BeLike '*0.19.0*0.18.x*unica-contract.md*'
        $v.Version | Should -Be '0.19.0'
    }
    It 'файла раннера немає — error, що називає шлях і те, що kit dump працює без раннера' {
        $v = Get-KitRunnerVerdict -RunnerPath (Join-Path $TestDrive 'немає\v8-runner.exe')
        $v.Level | Should -Be 'error'
        $v.Message | Should -BeLike '*Раннер не знайдено*немає*kit dump працює*'
    }
    It 'без -RunnerPath раннер береться з реєстру: реєстр без плагіна — error' {
        $reg = Join-Path $TestDrive 'verdict-empty.json'
        '{"version":2,"plugins":{}}' | Set-Content -LiteralPath $reg -Encoding UTF8
        (Get-KitRunnerVerdict -InstalledPluginsPath $reg).Level | Should -Be 'error'
    }
}

Describe 'Start-KitRunnerProcess: аргументи доходять до раннера дослівно (через bin/kit.exe runner-exec)' {
    BeforeAll {
        # Раннером слугує сам kit.exe: source-fingerprint <токен> повертає токен у тексті помилки
        # «відбиток <токен> не обчислено» (stderr), тож вивід показує, що саме отримав процес.
        $script:KitExe = (Resolve-Path "$PSScriptRoot/../../bin/kit.exe").Path
    }
    It 'токен <Token> у виводі дослівно' -ForEach @(
        @{ Token = 'a b' }
        @{ Token = 'q"uote' }
        @{ Token = 'trailing\' }
        @{ Token = 'back\"slash' }
        @{ Token = 'кирилиця з пробілом' }
    ) {
        $kit = $script:KitExe; $cwd = "$TestDrive"; $tok = $Token
        $run = InModuleScope Runner -Parameters @{ Kit = $kit; Cwd = $cwd; Tok = $tok } {
            param($Kit, $Cwd, $Tok)
            Start-KitRunnerProcess -RunnerPath $Kit -WorkingDirectory $Cwd -Arguments @('source-fingerprint', $Tok)
        }
        $run.ExitCode | Should -Be 1
        $run.Stderr | Should -BeLike "*відбиток $Token не обчислено*"
    }
    It 'фальшивий .cmd у теці з пробілом і кирилицею запускається' {
        $dir = Join-Path $TestDrive 'тека з пробілом'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -Path (Join-Path $script:FixDir '*') -Destination $dir -Recurse
        Get-KitRunnerVersion -RunnerPath (Join-Path $dir 'v8-runner.cmd') | Should -BeExactly '0.18.1'
    }
}
