#Requires -Version 7
Describe 'Manifest.psm1 — схема v8storagekit.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path

        # Усередині BeforeAll — інакше не доживе до фази run (див. StorageSync.Tests.ps1).
        function script:Write-Yaml {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Lines)
            $p = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $p -Value ($Lines -join "`n") -Encoding UTF8
            $p
        }
    }

    Context 'приклади зі спеки' {
        It 'продуктовий: kind/label, три воркспейси, truth і типові значення' {
            $m = Read-KitManifest -Path (Join-Path $script:Fixtures 'manifest-product.yaml')
            $m.Kind | Should -Be 'product'
            $m.Label | Should -Be 'BankExchange'
            $m.MainBranch | Should -Be 'main'
            $m.Workspaces.Count | Should -Be 3

            $smb = $m.Workspaces[0].Sources | Where-Object Key -eq 'SMP_BankExchange_SMB'
            $smb.Truth | Should -Be 'storage'
            $smb.StoragePath | Should -Be 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'
            $smb.StorageUser | Should -Be 'gitbot'

            $base = $m.Workspaces[0].Sources | Where-Object Key -eq 'base'
            $base.Truth | Should -Be 'vendor'
            $base.DumpFrom | Should -Be 'devUNF'
            $base.StoragePath | Should -BeNullOrEmpty

            # user не вказано — типовий gitbot
            ($m.Workspaces[1].Sources | Where-Object Key -eq 'SMP_BankExchange_SMBru').StorageUser | Should -Be 'gitbot'
            ($m.Workspaces[2].Sources | Where-Object Key -eq 'external-processors').Truth | Should -Be 'git'
        }

        It 'клієнтський: base під сховищем, кириличний ключ, користувач сховища за іменем бази' {
            $m = Read-KitManifest -Path (Join-Path $script:Fixtures 'manifest-client.yaml')
            $m.Kind | Should -Be 'client'
            $m.Label | Should -Be 'Alpenpharma'
            $src = $m.Workspaces[0].Sources
            ($src | Where-Object Key -eq 'base').Truth | Should -Be 'storage'
            $src.Key | Should -Contain 'Адаптация'
            ($src | Where-Object Key -eq 'SMP_BankExchange_SMB').StorageUser | Should -Be 'Alpenpharma'
        }
    }

    Context 'відмови схеми — кожна називає місце і причину' {
        It 'невідомий truth' {
            $p = Write-Yaml 'bad-truth.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: mirror }')
            { Read-KitManifest -Path $p } | Should -Throw "*'mirror'*storage, dump, vendor, git*"
        }
        It 'truth: storage без storage.path' {
            $p = Write-Yaml 'no-storage-path.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: storage, storage: { user: u } }')
            { Read-KitManifest -Path $p } | Should -Throw "*'path'*"
        }
        It 'truth: storage без блоку storage:' {
            $p = Write-Yaml 'no-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: storage }')
            { Read-KitManifest -Path $p } | Should -Throw '*storage:*'
        }
        It 'truth: storage зі storage: і dump: одночасно — суперечність' {
            $p = Write-Yaml 'storage-with-dump.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: storage, storage: { path: 'x' }, dump: { from: 'y' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*storage*dump:*'
        }
        It 'truth: vendor без dump.from' {
            $p = Write-Yaml 'no-from.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: vendor }')
            { Read-KitManifest -Path $p } | Should -Throw '*dump:*from*'
        }
        It 'truth: vendor: dump.from порожній при наявному блоці dump: — зупинка' {
            $p = Write-Yaml 'empty-dump-from.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: vendor, dump: { from: '' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*dump.from*порожній*'
        }
        It 'truth: dump зі storage: одночасно — суперечність' {
            $p = Write-Yaml 'dump-with-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: dump, dump: { from: 'x' }, storage: { path: 'y' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*dump*storage:*'
        }
        It 'truth: git зі storage: — суперечність' {
            $p = Write-Yaml 'git-with-storage.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, storage: { path: 'x' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*git*storage*'
        }
        It 'truth: git з dump: — суперечність' {
            $p = Write-Yaml 'git-with-dump.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, dump: { from: 'x' } }")
            { Read-KitManifest -Path $p } | Should -Throw '*git*dump*'
        }
        It 'невідомий кореневий ключ' {
            $p = Write-Yaml 'unknown-root.yaml' @('version: 1', 'product: X', 'products: Y', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw "*'products'*version, product, client, mainBranch, workspaces*"
        }
        It 'невідомий ключ усередині джерела (структуру описує v8project.yaml, не маніфест)' {
            $p = Write-Yaml 'unknown-source-key.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', "      a: { truth: git, path: 'cfe/src' }")
            { Read-KitManifest -Path $p } | Should -Throw "*'path'*truth, storage, dump*"
        }
        It 'product і client разом — зупинка' {
            $p = Write-Yaml 'both.yaml' @('version: 1', 'product: X', 'client: Y', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*product*client*'
        }
        It 'ні product, ні client — зупинка' {
            $p = Write-Yaml 'neither.yaml' @('version: 1', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*product*client*'
        }
        It 'version: 2 — зупинка' {
            $p = Write-Yaml 'v2.yaml' @('version: 2', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*version*'
        }
        It 'workspaces[].path із роздільником — зупинка (воркспейс лише безпосередньо в корені)' {
            $p = Write-Yaml 'nested-ws.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: a/b', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw "*'a/b'*"
        }
        It 'той самий воркспейс двічі — зупинка' {
            $p = Write-Yaml 'dup-ws.yaml' @('version: 1', 'product: X', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }', '  - path: A', '    sources:', '      b: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*двічі*'
        }
    }

    Context 'mainBranch' {
        It 'типово main; явний master приймається' {
            $p = Write-Yaml 'master.yaml' @('version: 1', 'product: X', 'mainBranch: master', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            (Read-KitManifest -Path $p).MainBranch | Should -Be 'master'
        }
        It 'mainBranch у просторі storage/ — зупинка' {
            $p = Write-Yaml 'bad-main.yaml' @('version: 1', 'product: X', 'mainBranch: storage/x', 'workspaces:', '  - path: A', '    sources:', '      a: { truth: git }')
            { Read-KitManifest -Path $p } | Should -Throw '*mainBranch*'
        }
    }
}

Describe 'Manifest.psm1 — накладка v8storagekit.local.yaml' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Manifest.psm1").Path -Force
        $script:Fixtures = (Resolve-Path "$PSScriptRoot/fixtures").Path
        function script:Write-Yaml {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Lines)
            $p = Join-Path $TestDrive $Name
            Set-Content -LiteralPath $p -Value ($Lines -join "`n") -Encoding UTF8
            $p
        }
    }

    It 'читає приклад зі спеки: дві дев-бази, перевизначення сховища, шаблон бази агента' {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Fixtures 'overlay-sample.yaml')
        $o.Infobases.Count | Should -Be 2
        $o.Infobases['devUNFru'].Connection | Should -Be 'Srvr="VSDEV";Ref="SMP_ruUNF_sydorenko";'
        $o.Infobases['devUNFru'].User | Should -Be 'Абдулов (директор)'
        $o.Storages['SMP_BankExchange_SMB'].Path | Should -Be 'D:\mirror\СМП_BankExchange_SMB'
        $o.Workspaces['SMP_BankExchange_SMB'].AgentBaseTemplate | Should -Be 'D:\dumps\UNF_demo.dt'
    }

    It 'storages.<ключ>: рядок — лише шлях; мапа — path/user/password; невідомий ключ мапи — зупинка' {
        $p = Write-Yaml 'storages-forms.yaml' @(
            'storages:'
            "  A: 'D:\mirror\A'"
            '  B:'
            "    path: 'D:\mirror\B'"
            "    user: 'Сидоренко'"
            "    password: 'secret'"
            '  C: { user: gitbot }')
        $o = Read-KitLocalOverlay -Path $p
        $o.Storages['A'].Path | Should -Be 'D:\mirror\A';  $o.Storages['A'].User | Should -BeNullOrEmpty
        $o.Storages['B'].Path | Should -Be 'D:\mirror\B';  $o.Storages['B'].User | Should -Be 'Сидоренко'; $o.Storages['B'].Password | Should -Be 'secret'
        $o.Storages['C'].Path | Should -BeNullOrEmpty;     $o.Storages['C'].User | Should -Be 'gitbot'
        $bad = Write-Yaml 'storages-bad.yaml' @('storages:', '  A: { path: x, pwd: y }')
        { Read-KitLocalOverlay -Path $bad } | Should -Throw "*'pwd'*path, user, password*"
    }

    It 'порожня накладка — порожні таблиці, не помилка' {
        $p = Write-Yaml 'empty-overlay.yaml' @('# ще нічого')
        $o = Read-KitLocalOverlay -Path $p
        $o.Infobases.Count | Should -Be 0
        $o.Storages.Count | Should -Be 0
    }

    It 'невідомий кореневий ключ (наприклад, devInfobase зі старої конвенції) — зупинка' {
        $p = Write-Yaml 'old-overlay.yaml' @('devInfobase:', "  connection: 'File=x'")
        { Read-KitLocalOverlay -Path $p } | Should -Throw "*'devInfobase'*infobases, storages, workspaces*"
    }

    It 'дев-база без connection — зупинка' {
        $p = Write-Yaml 'no-conn.yaml' @('infobases:', '  dev:', "    user: 'u'")
        { Read-KitLocalOverlay -Path $p } | Should -Throw "*'connection'*"
    }

    It "Resolve-KitInfobase: знайдено — об’єкт; немає — зупинка з готовим блоком для вставки" {
        $o = Read-KitLocalOverlay -Path (Join-Path $script:Fixtures 'overlay-sample.yaml')
        (Resolve-KitInfobase -Overlay $o -Name 'devUNF').User | Should -Be 'Администратор'
        { Resolve-KitInfobase -Overlay $o -Name 'devBP' } | Should -Throw '*devBP*infobases:*connection:*'
        { Resolve-KitInfobase -Overlay $null -Name 'devBP' } | Should -Throw '*devBP*'
    }
}
