#Requires -Version 7
Describe 'StorageImprint.psm1 — запис, читання і звірка відбитка (Task 8, task-8-brief.md)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageImprint.psm1").Path -Force

        # Фейкове сховище: 1cv8ddb.1CD + опційно файли в data/objects і/або data/pack, з явним
        # LastWriteTimeUtc. Той самий зразок, що StorageBranch.Tests.ps1 (New-FakeStorageDir) і
        # SessionCheck.Tests.ps1 (New-FakeStorage) — тут окремо, бо цей файл модулів тестів не
        # ділить між собою.
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

    It 'запис → читання: те саме значення, файл лежить у build/session-check/<Key>.json' {
        $repo = Join-Path $TestDrive 'write-read'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        $storage = Join-Path $TestDrive 'write-read-storage'
        New-FakeStorageDir -Path $storage -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-10T09:00:00' })

        $path = Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $storage -Version 42
        $path | Should -Be (Join-Path $repo 'build/session-check/Alpha_SMB.json')
        $path | Should -Exist

        $imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        $imprint | Should -Not -BeNullOrEmpty
        $imprint.Schema | Should -Be 1
        $imprint.Key | Should -Be 'Alpha_SMB'
        $imprint.StoragePath | Should -Be $storage
        $imprint.Version | Should -Be 42
        $imprint.LatestObjectWriteUtc | Should -BeNullOrEmpty
        @($imprint.PackFiles).Count | Should -Be 1
        $imprint.PackFiles[0].Name | Should -Be '1.pack'
        $imprint.PackFiles[0].Length | Should -Be (Get-Item (Join-Path $storage 'data/pack/1.pack')).Length
    }

    It 'Read-KitStorageImprint: файла немає, битий JSON і schema: 2 — $null у всіх трьох випадках, без винятку' {
        $repo = Join-Path $TestDrive 'reads'
        New-Item -ItemType Directory -Path (Join-Path $repo 'build/session-check') -Force | Out-Null

        { Read-KitStorageImprint -RepoRoot $repo -Key 'NoFile' } | Should -Not -Throw
        Read-KitStorageImprint -RepoRoot $repo -Key 'NoFile' | Should -BeNullOrEmpty

        Set-Content -LiteralPath (Join-Path $repo 'build/session-check/Broken.json') -Value '{ це не валідний json'
        { Read-KitStorageImprint -RepoRoot $repo -Key 'Broken' } | Should -Not -Throw
        Read-KitStorageImprint -RepoRoot $repo -Key 'Broken' | Should -BeNullOrEmpty

        # Схема 2 — наступна зміна формату: читач мусить трактувати це як "відбитка немає"
        # (повернення до евристик), а не як хибну точну відповідь зі старими полями.
        Set-Content -LiteralPath (Join-Path $repo 'build/session-check/OtherSchema.json') -Encoding UTF8 -Value (
            '{"schema":2,"key":"OtherSchema","storagePath":"x","version":1,"readAtUtc":"2026-01-01T00:00:00.0000000Z","latestObjectWriteUtc":null,"packFiles":[]}')
        { Read-KitStorageImprint -RepoRoot $repo -Key 'OtherSchema' } | Should -Not -Throw
        Read-KitStorageImprint -RepoRoot $repo -Key 'OtherSchema' | Should -BeNullOrEmpty
    }

    Context 'Test-KitStorageImprintCurrent' {
        BeforeAll {
            # Базовий стан: один об'єктний файл і один pack-файл, фіксовані mtime.
            $script:Baseline = Join-Path $TestDrive 'imprint-baseline'
            New-FakeStorageDir -Path $script:Baseline `
                -ObjectFiles @(@{ Name = 'a.bin'; Content = 'x'; Stamp = [datetime]'2026-01-05T00:00:00' }) `
                -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-10T00:00:00' })

            $repo = Join-Path $TestDrive 'imprint-repo'
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $script:Baseline -Version 5 | Out-Null
            $script:Imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        }

        It 'збіг — $true' {
            $activity = Get-KitStorageActivity -StoragePath $script:Baseline
            Test-KitStorageImprintCurrent -Imprint $script:Imprint -Activity $activity | Should -BeTrue
        }

        It 'зміна лише Length одного pack-файла (той самий mtime) — $false' {
            $s = Join-Path $TestDrive 'imprint-len-changed'
            New-FakeStorageDir -Path $s `
                -ObjectFiles @(@{ Name = 'a.bin'; Content = 'x'; Stamp = [datetime]'2026-01-05T00:00:00' }) `
                -PackFiles @(@{ Name = '1.pack'; Content = 'довший вміст, інша довжина'; Stamp = [datetime]'2026-01-10T00:00:00' })
            $activity = Get-KitStorageActivity -StoragePath $s
            Test-KitStorageImprintCurrent -Imprint $script:Imprint -Activity $activity | Should -BeFalse
        }

        It 'новий файл в objects — $false' {
            $s = Join-Path $TestDrive 'imprint-new-object'
            New-FakeStorageDir -Path $s `
                -ObjectFiles @(
                    @{ Name = 'a.bin'; Content = 'x'; Stamp = [datetime]'2026-01-05T00:00:00' }
                    @{ Name = 'b.bin'; Content = 'y'; Stamp = [datetime]'2026-01-12T00:00:00' }
                ) `
                -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-10T00:00:00' })
            $activity = Get-KitStorageActivity -StoragePath $s
            Test-KitStorageImprintCurrent -Imprint $script:Imprint -Activity $activity | Should -BeFalse
        }

        It 'зміна mtime pack-файла (той самий вміст) — $false' {
            $s = Join-Path $TestDrive 'imprint-mtime-changed'
            New-FakeStorageDir -Path $s `
                -ObjectFiles @(@{ Name = 'a.bin'; Content = 'x'; Stamp = [datetime]'2026-01-05T00:00:00' }) `
                -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-11T00:00:00' })
            $activity = Get-KitStorageActivity -StoragePath $s
            Test-KitStorageImprintCurrent -Imprint $script:Imprint -Activity $activity | Should -BeFalse
        }
    }

    It 'відбиток, знятий і звірений БЕЗ жодної зміни диску між викликами — $true (перевірка "один годинник")' {
        # Не оголошення, а показ: два ОКРЕМІ читання того самого незміненого диска (одне —
        # усередині Write-KitStorageImprint, друге — тут явно) дають однаковий результат.
        $storage = Join-Path $TestDrive 'no-disk-change'
        New-FakeStorageDir -Path $storage -PackFiles @(@{ Name = '1.pack'; Content = 'p'; Stamp = [datetime]'2026-01-20T00:00:00' })
        $repo = Join-Path $TestDrive 'no-disk-change-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null

        Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $storage -Version 9 | Out-Null
        $imprint = Read-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB'
        $activityAgain = Get-KitStorageActivity -StoragePath $storage
        Test-KitStorageImprintCurrent -Imprint $imprint -Activity $activityAgain | Should -BeTrue
    }
}
