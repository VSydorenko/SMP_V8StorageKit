#Requires -Version 7
Describe 'StoragePlatform.psm1 — аргументи платформи для сховища' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StoragePlatform.psm1").Path -Force
        $script:Ext = [pscustomobject]@{ Key = 'SMP_X'; Type = 'EXTENSION';     StoragePath = 'R:\S\X'; StorageUser = 'gitbot'; StoragePassword = '' }
        $script:Cfg = [pscustomobject]@{ Key = 'base';  Type = 'CONFIGURATION'; StoragePath = 'R:\S\C'; StorageUser = 'Alpen'; StoragePassword = 'secret' }
        $script:Epf = [pscustomobject]@{ Key = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; StoragePath = ''; StorageUser = ''; StoragePassword = '' }
    }

    It 'три аргументи підключення до сховища; користувач і пароль — із джерела (пароль лише з накладки, B2 Task 2a)' {
        $a = Get-KitRepositoryArguments -Source $script:Cfg
        $a | Should -Be @('/ConfigurationRepositoryF "R:\S\C"', '/ConfigurationRepositoryN "Alpen"', '/ConfigurationRepositoryP "secret"')
        (Get-KitRepositoryArguments -Source $script:Ext)[2] | Should -Be '/ConfigurationRepositoryP ""'
    }

    It '-Extension лише для EXTENSION, і з іменем джерела' {
        Get-KitExtensionArgument -Source $script:Ext | Should -Be ' -Extension SMP_X'
        Get-KitExtensionArgument -Source $script:Cfg | Should -Be ''
    }

    It 'New-KitStorageInfobase відмовляє зовнішнім обробкам до звернення до платформи' {
        { New-KitStorageInfobase -Source $script:Epf -WorkDir $TestDrive } | Should -Throw '*EXTERNAL_DATA_PROCESSORS*'
        Join-Path $TestDrive 'ib' | Should -Not -Exist
    }

    It 'Enter-KitStorageBind для розширення — завжди $false і без платформи' {
        Enter-KitStorageBind -IbSwitch '/F "x"' -Source $script:Ext | Should -BeFalse
    }
}
