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

    It 'Test-KitExtensionNotFound: російський і український тексти платформи — так, інші помилки — ні' {
        Test-KitExtensionNotFound -Output 'Расширение конфигурации с указанным именем не найдено' | Should -BeTrue
        Test-KitExtensionNotFound -Output 'Не вдалося побудувати звіт сховища R:\x : Расширение конфигурации ExtA не найдено' | Should -BeTrue
        Test-KitExtensionNotFound -Output 'Розширення конфігурації з вказаним ім''ям не знайдено' | Should -BeTrue
        Test-KitExtensionNotFound -Output 'Ошибка аутентификации в хранилище конфигурации' | Should -BeFalse
        Test-KitExtensionNotFound -Output 'Информационная база используется другим пользователем' | Should -BeFalse
        Test-KitExtensionNotFound -Output '' | Should -BeFalse
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

    Context 'збій вивантаження після успішного UpdateCfg — розпізнаваний виняток (спека 1.3.1 §6.1.1)' {
        It 'UpdateCfg 0, DumpConfigToFiles 1 — виняток із Data: версія, платформа, вивід; Test-KitDumpFailure = $true' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                if (($Arguments -join ' ') -match 'DumpConfigToFiles') { return [pscustomobject]@{ ExitCode = 1; Output = 'Неправильный путь к файлу. Схема не зарегистрирована' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            Mock -ModuleName StoragePlatform Get-V8Path { 'C:\pf\8.3.27.1644\bin\1cv8.exe' }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34') -MustBeUnder $TestDrive }
            catch { $rec = $_ }
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeTrue
            $rec.Exception.Message | Should -BeLike '*Вивантаження версії 34 не вдалося*Схема не зарегистрирована*'
            $rec.Exception.Data['Version'] | Should -Be 34
            $rec.Exception.Data['PlatformPath'] | Should -BeLike '*8.3.27.1644*'
            $rec.Exception.Data['Output'] | Should -BeLike '*Схема не зарегистрирована*'
        }

        It 'збій UpdateCfg — НЕ розпізнаваний виняток вивантаження' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 1; Output = 'Внутренняя ошибка' } }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34u') -MustBeUnder $TestDrive } catch { $rec = $_ }
            $rec | Should -Not -BeNullOrEmpty
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeFalse
        }

        It 'дамп упав, бо база зайнята — зупинка «зайнята», не розпізнаваний виняток' {
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments)
                if (($Arguments -join ' ') -match 'DumpConfigToFiles') { return [pscustomobject]@{ ExitCode = 1; Output = 'Ошибка блокировки информационной базы для конфигурирования' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $rec = $null
            try { Invoke-KitStorageCheckout -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 -Target (Join-Path $TestDrive 'd34b') -MustBeUnder $TestDrive } catch { $rec = $_ }
            $rec.Exception.Message | Should -BeLike '*зайнята*'
            Test-KitDumpFailure -ErrorRecord $rec | Should -BeFalse
        }
    }

    Context 'Invoke-KitStorageCheckoutViaPlatform — вивантаження обраною платформою (спека 1.3.1 §4.3)' {
        It 'послідовність: основна UpdateCfg і DumpCfg у базі агента → обрана CREATEINFOBASE, LoadCfg, DumpConfigToFiles у тимчасовій ІБ' {
            $script:Calls = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName StoragePlatform Get-V8Path { 'MAIN' }
            Mock -ModuleName StoragePlatform New-V8FileInfobase {
                param($Path, $MustBeUnder, $TemplatePath, $V8Path)
                $script:Calls.Add("CREATEINFOBASE|$V8Path|$Path"); New-Item -ItemType Directory -Path $Path -Force | Out-Null; $Path
            }
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $a = $Arguments -join ' '
                $verb = if ($a -match 'UpdateCfg') { 'UpdateCfg' } elseif ($a -match '/DumpCfg') { 'DumpCfg' } elseif ($a -match '/LoadCfg') { 'LoadCfg' } elseif ($a -match 'DumpConfigToFiles') { 'DumpConfigToFiles' } else { $a }
                $who = if ($V8Path) { $V8Path } else { 'MAIN' }
                $script:Calls.Add("$verb|$who|$IbSwitch")
                if ($a -match '/DumpCfg "(?<f>[^"]+)"') { Set-Content -LiteralPath $Matches.f -Value 'cf' -Encoding ascii }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $work = Join-Path $TestDrive 'via'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch '/S "srv\agent"' -Source $script:Cfg -Version 34 `
                -Target (Join-Path $work 'tree') -MustBeUnder $work -WorkDir $work -AltV8Path 'ALT'
            $altIb = '/F "{0}"' -f (Join-Path $work 'alt-ib')
            @($script:Calls) | Should -Be @(
                'UpdateCfg|MAIN|/S "srv\agent"'
                'DumpCfg|MAIN|/S "srv\agent"'
                "CREATEINFOBASE|ALT|$(Join-Path $work 'alt-ib')"
                "LoadCfg|ALT|$altIb"
                "DumpConfigToFiles|ALT|$altIb")
            # Обрана платформа ніколи не бачить ні бази агента, ні аргументів сховища.
            @($script:Calls | Where-Object { $_ -like '*|ALT|*srv*' }).Count | Should -Be 0
        }

        It 'обрана платформа впала на LoadCfg — зупинка з назвою кроку й платформи' {
            Mock -ModuleName StoragePlatform Get-V8Path { 'MAIN' }
            Mock -ModuleName StoragePlatform New-V8FileInfobase { param($Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; $Path }
            Mock -ModuleName StoragePlatform Invoke-V8Designer {
                param($IbSwitch, $Arguments, $User, $Password, $V8Path)
                $a = $Arguments -join ' '
                if ($a -match '/DumpCfg "(?<f>[^"]+)"') { Set-Content -LiteralPath $Matches.f -Value 'cf' -Encoding ascii }
                if ($a -match '/LoadCfg') { return [pscustomobject]@{ ExitCode = 1; Output = 'файл пошкоджено' } }
                [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            $work = Join-Path $TestDrive 'via-fail'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            { Invoke-KitStorageCheckoutViaPlatform -IbSwitch '/F "x"' -Source $script:Cfg -Version 34 `
                -Target (Join-Path $work 'tree') -MustBeUnder $work -WorkDir $work -AltV8Path 'ALT' } | Should -Throw '*LoadCfg*ALT*файл пошкоджено*'
        }
    }
}
