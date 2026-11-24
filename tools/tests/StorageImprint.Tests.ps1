#Requires -Version 7
Describe 'StorageImprint.psm1 — запис відбитка' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageImprint.psm1").Path -Force

        # Фейкове сховище: 1cv8ddb.1CD + опційно файли в data/objects і/або data/pack, з явним
        # LastWriteTimeUtc. Той самий зразок, що StorageBranch.Tests.ps1 (New-FakeStorageDir) і
        # tools/tests/fixtures/SessionCheckSetup.ps1 (New-FakeStorage) — тут окремо, бо цей файл
        # модулів тестів не ділить між собою.
        function script:New-FakeStorageDir {
            param(
                [Parameter(Mandatory)][string]$Path,
                [hashtable[]]$ObjectFiles = @(),
                [hashtable[]]$PackFiles = @()
            )
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path '1cv8ddb.1CD') -Value 'db'
            foreach ($f in $ObjectFiles) {
                $dir = Join-Path $Path 'data/objects/ab'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $p = Join-Path $dir $f.Name
                Set-Content -LiteralPath $p -Value $f.Content
                (Get-Item $p).LastWriteTimeUtc = $f.Stamp.ToUniversalTime()
            }
            foreach ($f in $PackFiles) {
                $dir = Join-Path $Path 'data/pack'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $p = Join-Path $dir $f.Name
                Set-Content -LiteralPath $p -Value $f.Content
                (Get-Item $p).LastWriteTimeUtc = $f.Stamp.ToUniversalTime()
            }
        }
    }

    It 'запис: ключі й значення в файлі, файл лежить у build/session-check/<Key>.json' {
        $repo = Join-Path $TestDrive 'write-read'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        $storage = Join-Path $TestDrive 'write-read-storage'
        New-FakeStorageDir -Path $storage -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-10T09:00:00' })

        $path = Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $storage -Version 42
        $path | Should -Be (Join-Path $repo 'build/session-check/Alpha_SMB.json')
        $path | Should -Exist

        $imprint = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $imprint | Should -Not -BeNullOrEmpty
        $imprint.schema | Should -Be 1
        $imprint.key | Should -Be 'Alpha_SMB'
        $imprint.storagePath | Should -Be $storage
        $imprint.version | Should -Be 42
        $imprint.latestObjectWriteUtc | Should -BeNullOrEmpty
        @($imprint.packFiles).Count | Should -Be 1
        $imprint.packFiles[0].name | Should -Be '1.pack'
        $imprint.packFiles[0].length | Should -Be (Get-Item (Join-Path $storage 'data/pack/1.pack')).Length
    }
}

Describe 'StorageImprint.psm1 — ключ джерела не виводить відбиток за межі build/session-check' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageImprint.psm1").Path -Force
    }

    It 'ключ із сегментом ".." відхиляється ДО звернення до сховища, і нічого не створено' {
        # Ключ джерела приходить із v8storagekit.yaml без перевірки на шляхоподібність
        # (Manifest.psm1 звіряє лише шлях воркспейсу), а сусідній запис у sync.psm1 той самий ключ
        # через Assert-SafeWorkPath проганяє. -StoragePath навмисно неіснуючий: якщо зупинка
        # спрацювала до Get-KitStorageActivity, його відсутність ролі не грає — а якщо перевірку
        # колись пересунуть після звернення до сховища, цей тест це й покаже.
        $repo = Join-Path $TestDrive 'imprint-escape'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null

        { Write-KitStorageImprint -RepoRoot $repo -Key '../../evil' -StoragePath (Join-Path $TestDrive 'nope') -Version 1 } |
            Should -Throw '*build*session-check*'

        Join-Path $repo 'build' | Should -Not -Exist
        Join-Path (Split-Path -Parent $repo) 'evil.json' | Should -Not -Exist
    }

    It 'звичайний ключ пишеться туди, куди й обіцяно' {
        $repo = Join-Path $TestDrive 'imprint-ok'
        $storage = Join-Path $TestDrive 'imprint-ok-storage'
        New-Item -ItemType Directory -Path (Join-Path $storage 'data/objects/ab') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $storage '1cv8ddb.1CD') -Value 'db'
        Set-Content -LiteralPath (Join-Path $storage 'data/objects/ab/cd.bin') -Value 'obj'

        Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $storage -Version 7
        Join-Path $repo 'build/session-check/Alpha_SMB.json' | Should -Exist
    }
}
