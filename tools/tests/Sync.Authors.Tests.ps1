#Requires -Version 7
Describe 'kit sync — автор на конкретну версію сховища (спека 2026-09-30 §6.8, мок платформи)' {
    # Invoke-KitSync викликається напряму, у цьому процесі (той самий прийом, що в Sync.Merge.Tests.ps1):
    # лише так Pester Mock -ModuleName підміняє Get-StorageVersions (-ModuleName sync) і платформу
    # (Invoke-V8Designer — -ModuleName StoragePlatform), не запускаючи 1cv8.exe.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force

        $libDir = (Resolve-Path "$PSScriptRoot/../lib").Path
        $order = Get-Content -LiteralPath (Join-Path $libDir 'module-order.txt') -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($name in $order) { Import-Module (Join-Path $libDir "$name.psm1") -Force }
        Import-Module (Resolve-Path "$PSScriptRoot/../commands/sync.psm1").Path -Force

        function script:New-KitTestContext {
            param([Parameter(Mandatory)][string]$Repo)
            Invoke-KitPreflight -RepoRoot $Repo
        }
        function script:New-KitFakeStorageVersion {
            param([int]$Version, [string]$User = 'gitbot', [string]$Comment = 'версія')
            [pscustomobject]@{
                Version = $Version; User = $User; Date = '01.01.2026'; Time = '09:00:00'
                ConfigVersion = ''; Comment = $Comment; Added = @(); Modified = @(); Deleted = @()
                Timestamp = [datetime]'2026-01-01T09:00:00'
            }
        }
        function script:New-AuthorsRepo {
            param([string]$Name, [string[]]$AuthorsLines)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitignore -WithAgentBase
            $storageDir = Join-Path $TestDrive "$Name-storage"; New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (@('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            Set-Content -LiteralPath (Join-Path $repo 'AUTHORS') -Encoding UTF8 -Value $AuthorsLines
            $repo
        }
    }

    It 'спільний логін без рядка — зупинка на прев''ю, перелік конкретних версій, платформа не викликана' {
        $repo = New-AuthorsRepo 'shared-stop' @('gitbot=Test Bot <test@example.invalid>', 'Alpha_SMB#2=Іван Петренко <ivan@example.invalid>')
        Mock -ModuleName StoragePlatform Invoke-V8Designer { throw 'платформа не мала викликатись' }
        Mock -ModuleName sync Get-StorageVersions { , @(
            (New-KitFakeStorageVersion -Version 1 -User 'Робоча база'),
            (New-KitFakeStorageVersion -Version 2 -User 'Робоча база'),
            (New-KitFakeStorageVersion -Version 3 -User 'Робоча база')) }
        # Виняток — у змінну, Write-Host — через 6>&1 (той самий прийом, що в Sync.Order.Tests.ps1).
        $script:SyncError = $null
        $text = & { try { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) } catch { $script:SyncError = $_.Exception.Message } } 6>&1 | Out-String
        $script:SyncError | Should -BeLike '*невідомих авторів*'
        $text | Should -BeLike '*Невідомі автори*'
        $text | Should -BeLike '*Alpha_SMB#1=*'
        $text | Should -BeLike '*Alpha_SMB#3=*'
        $text | Should -Not -BeLike '*Alpha_SMB#2=*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'перелік: рядок на логін — перед блоком версій, рядки версій підряд, жоден рядок-заготовка не має хвоста' {
        $repo = New-AuthorsRepo 'shared-order' @('gitbot=Test Bot <test@example.invalid>')
        Mock -ModuleName StoragePlatform Invoke-V8Designer { throw 'платформа не мала викликатись' }
        Mock -ModuleName sync Get-StorageVersions { , @(
            (New-KitFakeStorageVersion -Version 1 -User 'Робоча база' -Comment 'перша'),
            (New-KitFakeStorageVersion -Version 2 -User 'Робоча база' -Comment 'друга'),
            (New-KitFakeStorageVersion -Version 3 -User 'Робоча база' -Comment 'третя')) }
        $script:SyncError = $null
        $text = & { try { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) } catch { $script:SyncError = $_.Exception.Message } } 6>&1 | Out-String
        $lines = @($text -split "`r?`n")
        $templates = @($lines | Where-Object { $_ -match "^\s+.+?=Ім'я <пошта>\s*$" })
        # Порядок — той, який споживає Complete-Authors (Sync.Storage.Tests.ps1): спершу логін, далі версії.
        $templates.Count | Should -Be 4
        $templates[0].Trim() | Should -Be "Робоча база=Ім'я <пошта>"
        @($templates[1..3] | ForEach-Object { $_.Trim() }) | Should -Be @("Alpha_SMB#1=Ім'я <пошта>", "Alpha_SMB#2=Ім'я <пошта>", "Alpha_SMB#3=Ім'я <пошта>")
        # Рядки версій — підряд, між ними нічого не стоїть.
        $idx = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match "^\s+Alpha_SMB#\d+=Ім'я <пошта>\s*$" })
        ($idx[-1] - $idx[0]) | Should -Be 2
        # Коментар версії — окремий рядок, а не хвіст рядка-заготовки; і він є.
        $text | Should -BeLike '*третя*'
    }

    It '-Apply: версія з рядком на версію — під цією особою, решта — під логіном; Storage-User — сирий логін' {
        $repo = New-AuthorsRepo 'shared-apply' @('gitbot=Test Bot <test@example.invalid>', 'Робоча база=Спільна Особа <shared@example.invalid>', 'Alpha_SMB#2=Іван Петренко <ivan@example.invalid>')
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(
            (New-KitFakeStorageVersion -Version 1 -User 'Робоча база'),
            (New-KitFakeStorageVersion -Version 2 -User 'Робоча база')) }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }
        $r = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true
        $r.ExitCode | Should -Be 0
        $shas = @(git -C $repo log --reverse --format='%H' storage/Alpha_SMB)
        $shas.Count | Should -Be 2
        $info = foreach ($sha in $shas) {
            [pscustomobject]@{
                Author  = (git -C $repo log -1 --format='%an' $sha)
                Version = (git -C $repo log -1 --format='%(trailers:key=Storage-Version,valueonly)' $sha | Where-Object { $_ }) -join ''
                User    = (git -C $repo log -1 --format='%(trailers:key=Storage-User,valueonly)' $sha | Where-Object { $_ }) -join ''
            }
        }
        $info[0].Author | Should -Be 'Спільна Особа'
        $info[0].Version | Should -Be '1'
        $info[0].User | Should -Be 'Робоча база'
        $info[1].Author | Should -Be 'Іван Петренко'
        $info[1].Version | Should -Be '2'
        $info[1].User | Should -Be 'Робоча база'
    }
}
