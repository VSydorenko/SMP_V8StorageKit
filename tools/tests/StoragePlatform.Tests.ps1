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

    Context 'Get-KitSourceInfobase — база джерела' {
        BeforeAll {
            $script:Ctx = [pscustomobject]@{
                RepoRoot   = 'R:\repo'
                Workspaces = @([pscustomobject]@{ Path = 'Alpha_SMB'; FullPath = 'R:\repo\Alpha_SMB'; Project = 'проєкт' })
            }
            $script:Src = [pscustomobject]@{ Key = 'Alpha_SMB'; Type = 'EXTENSION'; Workspace = 'Alpha_SMB' }
        }

        It 'бази немає в v8project.yaml — зупинка з рецептом provision і build' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase { $null }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src } |
                Should -Throw '*kit provision*operation=build*'
        }

        It 'база оголошена, але файлу немає — та сама зупинка, з іменем воркспейсу' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/F "R:\repo\Alpha_SMB\build\ib"'; User = ''; Kind = 'file'; Exists = $false }
            }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src } | Should -Throw '*Alpha_SMB*'
        }

        It 'база на місці — повертає підключення й користувача' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/F "R:\repo\Alpha_SMB\build\ib"'; User = 'agent'; Kind = 'file'; Exists = $true }
            }
            $r = Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src
            $r.IbSwitch  | Should -Be '/F "R:\repo\Alpha_SMB\build\ib"'
            $r.User      | Should -Be 'agent'
            $r.Workspace | Should -Be 'Alpha_SMB'
        }

        It 'серверна база — Exists не перевіряється, підключення віддається як є' {
            Mock -ModuleName StoragePlatform Resolve-KitAgentBase {
                [pscustomobject]@{ IbSwitch = '/S "VSDEV\Alpha"'; User = 'agent'; Kind = 'server'; Exists = $true }
            }
            (Get-KitSourceInfobase -Context $script:Ctx -Source $script:Src).IbSwitch | Should -Be '/S "VSDEV\Alpha"'
        }

        It 'воркспейсу джерела немає в контексті — зупинка, а не мовчазний $null' {
            $bad = [pscustomobject]@{ Key = 'X'; Type = 'EXTENSION'; Workspace = 'Beta' }
            { Get-KitSourceInfobase -Context $script:Ctx -Source $bad } | Should -Throw '*Beta*'
        }
    }

    Context 'користувач бази доходить до платформи' {
        It 'Invoke-KitStorageCheckout передає -User у Invoke-V8Designer' {
            $script:seen = @()
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $script:seen += $User
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $target = Join-Path $TestDrive 'dump'
            Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                -Target $target -MustBeUnder $TestDrive -User 'agent' | Out-Null
            $script:seen | Should -Contain 'agent'
        }

        It 'без -User викликає платформу без користувача — стара поведінка не змінилась' {
            $script:seen = @()
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $script:seen += [string]$User
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $target = Join-Path $TestDrive 'dump2'
            Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                -Target $target -MustBeUnder $TestDrive | Out-Null
            $script:seen | Should -Not -Contain 'agent'
        }
    }

    Context '«розширення не знайдено» — переклад у рецепт operation=build (Task 3, Step 6)' {
        # UpdateCfg падає до Target/MustBeUnder — шлях сюди не доходить, тож тека $TestDrive
        # нижче ніколи не читається й не пишеться, лише формально задовольняє Mandatory-параметри.
        It 'EXTENSION, платформа каже «расширение … не найдено» — виняток називає operation=build' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                [pscustomobject]@{ ExitCode = 1; Output = 'Расширение "SMP_X" не найдено в конфигурации.' }
            }
            { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                -Target (Join-Path $TestDrive 'dump-ext-notfound') -MustBeUnder $TestDrive } |
                Should -Throw '*operation=build*'
        }

        It 'EXTENSION, інший текст платформи — звичайна зупинка, БЕЗ operation=build (регекс не збігається з будь-чим)' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                [pscustomobject]@{ ExitCode = 1; Output = 'Внутренняя ошибка платформы.' }
            }
            $err = $null
            try {
                Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Ext -Version 7 `
                    -Target (Join-Path $TestDrive 'dump-ext-othererror') -MustBeUnder $TestDrive
            } catch { $err = $_.Exception.Message }
            $err | Should -BeLike '*Оновлення до версії 7 не вдалося*'
            $err | Should -Not -BeLike '*operation=build*'
        }

        It 'CONFIGURATION, той самий текст «не найдено» — звичайна зупинка, гілка обмежена типом EXTENSION' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                [pscustomobject]@{ ExitCode = 1; Output = 'Расширение "SMP_X" не найдено в конфигурации.' }
            }
            $err = $null
            try {
                Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 7 `
                    -Target (Join-Path $TestDrive 'dump-cfg-notfound') -MustBeUnder $TestDrive
            } catch { $err = $_.Exception.Message }
            $err | Should -BeLike '*Оновлення до версії 7 не вдалося*'
            $err | Should -Not -BeLike '*operation=build*'
        }
    }
}
