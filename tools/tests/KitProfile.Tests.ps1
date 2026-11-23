#Requires -Version 7
# Простір імен v8storagekit у профілі (ADR-0018): спершу зливаються шари, потім наявна секція першого рівня
# `v8storagekit.<секція>` заміняє верхню ЦІЛКОМ. Контракт, який тримає бриф виконавця 1С від рівнів тестів іншої
# зони (agent-kit у тому самому репозиторії). Контроль — без простору імен верхня секція як була.
Describe 'Профіль: простір імен v8storagekit' {
    BeforeAll {
        $lib = Resolve-Path "$PSScriptRoot/../lib"
        Import-Module (Join-Path $lib 'KitCli.psm1') -Force
        Import-Module (Join-Path $lib 'KitProfile.psm1') -Force
        $script:EmptyConfig = Join-Path $TestDrive 'xdg'   # машинний шар не підмішується
        New-Item -ItemType Directory -Path $script:EmptyConfig | Out-Null
        function script:New-ProfileRepo {
            param([string]$Name, [string]$Shared, [string]$Local)
            $dir = Join-Path $TestDrive $Name
            git init -q -b main $dir
            New-Item -ItemType Directory -Path (Join-Path $dir '.agents') | Out-Null
            if ($Shared) { [System.IO.File]::WriteAllText((Join-Path $dir '.agents/kit.profile.json'), $Shared, [System.Text.UTF8Encoding]::new($false)) }
            if ($Local) { [System.IO.File]::WriteAllText((Join-Path $dir '.agents/kit.profile.local.json'), $Local, [System.Text.UTF8Encoding]::new($false)) }
            $dir
        }
        function script:Get-Profile([string]$Dir) {
            $saved = $env:XDG_CONFIG_HOME
            $env:XDG_CONFIG_HOME = $script:EmptyConfig
            try { Get-KitProfile -RepoRoot $Dir } finally { $env:XDG_CONFIG_HOME = $saved }
        }
    }

    It 'v8storagekit.tests без levels заміняє tests цілком — рівні Linux не просочуються, навіть з локального шару; контроль: без простору імен рівні є' {
        $shared = '{ "tests": { "default": "gateway", "levels": { "gateway": { "command": ["npx", "vitest"] } } }, "V8StorageKit": { "tests": { "default": "yaxunit" }, "version": "1.6.14" }, "pr": { "base": "main" } }'
        $local = '{ "tests": { "levels": { "site": { "command": ["npx", "vitest", "run"] } } } }'
        $p = Get-Profile (New-ProfileRepo -Name 'ns' -Shared $shared -Local $local)
        Get-KitProfileValue $p 'tests.default' | Should -Be 'yaxunit'
        Get-KitProfileValue $p 'tests.levels' -Default 'none' | Should -Be 'none'
        Get-KitProfileValue $p 'pr.base' | Should -Be 'main' -Because 'секція без перекриття лишається'
        Get-KitProfileValue $p 'version' -Default 'none' | Should -Be 'none' -Because 'version простору імен — не секція'

        $plain = Get-Profile (New-ProfileRepo -Name 'plain' -Shared '{ "tests": { "levels": { "gateway": { "command": ["npx"] } } } }')
        (Get-KitProfileValue $plain 'tests.levels').Contains('gateway') | Should -BeTrue
    }
}
