#Requires -Version 7
Describe 'kit sync — глибина першого реплею: -FromVersion / -FromLatest (Task 2, §9.4)' {
    # Той самий прийом мокання, що в Describe вище (Task 4, Task 8) — Invoke-KitSync
    # кличеться напряму в цьому процесі, платформа НЕ запускається.
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
        function script:New-KitEmptyBranchRepo {
            param([Parameter(Mandatory)][string]$Root)
            # -WithAgentBase: Task 3 — sync резолвить базу агента з диска (Get-KitSourceInfobase)
            # ще до звернення до платформи, для КОЖНОГО джерела в циклі; без цього переключача
            # кожен тест цього Describe, що кличе Invoke-KitSync, отримав би зупинку з рецептом
            # "kit provision" замість роботи мокованої платформи.
            $repo = New-KitFakeRepo -Root $Root -WithHooks -WithAgentBase
            $storageDir = "$Root-storage"
            New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
                @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            $repo
        }
    }

    Context 'порожня гілка — куди веде -FromVersion/-FromLatest' {
        BeforeEach {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Invoke-KitMainMerge { $true }
            # 60/64/65: розрив (61-63 оптимізовано) — той самий силует, що живий прогін
            # компаньйона (сховище конфігурації, максимум 65) описаний у брифі задачі.
            Mock -ModuleName sync Get-StorageVersions {
                , @(
                    (New-KitFakeStorageVersion -Version 60 -Comment 'стара')
                    (New-KitFakeStorageVersion -Version 64 -Comment 'середня')
                    (New-KitFakeStorageVersion -Version 65 -Comment 'поточна')
                )
            }
        }

        It 'без параметрів — з найменшої версії звіту (наявна поведінка не змінилась)' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-none')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true
            $result.ExitCode | Should -Be 0
            (@(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB').Trailers.'Storage-Version') | Should -Be @('60', '64', '65')
        }

        It '-FromVersion 64 — реплеяться версії від 64 включно (64 і 65), трейлер вершини — максимум звіту' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-64')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 64
            $result.ExitCode | Should -Be 0
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 2
            $commits.Trailers.'Storage-Version' | Should -Be @('64', '65')
        }

        # Головний тест задачі (task-2-brief.md): -FromLatest на порожній гілці МАЄ дати рівно
        # один коміт із МАКСИМАЛЬНОЮ версією — саме це відрізняє його від наявної
        # -MaxVersions 1, яка (закріплено вище) бере НАЙРАНІШУ версію.
        It '-FromLatest на порожній гілці — рівно ОДИН коміт, трейлер — МАКСИМАЛЬНА версія звіту' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-latest')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromLatest
            $result.ExitCode | Should -Be 0
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 1
            $commits[0].Trailers['Storage-Version'] | Should -Be '65'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 2   # одна версія: UpdateCfg + DumpConfigToFiles
        }

        It '-MaxVersions 1 БЕЗ -From* — найРАНІША версія (закріплення наявної поведінки, не "лише поточна")' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'maxversions-lock')
            $result = Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -MaxVersions 1
            $commits = @(Get-KitBranchCommits -RepoRoot $repo -Ref 'storage/Alpha_SMB')
            $commits.Count | Should -Be 1
            $commits[0].Trailers['Storage-Version'] | Should -Be '60'
        }

        It '-FromVersion більший за максимум зі звіту — зупинка з переліком доступних версій, коміту немає' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'from-too-high')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 999 } |
                Should -Throw '*999*60, 64, 65*'
            Test-KitBranchExists -RepoRoot $repo -Branch 'storage/Alpha_SMB' | Should -BeFalse
        }

        # Рев'ю Task 2, п. 5: сховище БЕЗ ЖОДНОЇ версії (не плутати з "порожня гілка" вище —
        # тут порожній сам ЗВІТ) + -From* — до фіксу sync казав "Нових версій немає — дзеркало
        # синхронне зі сховищем", хоча версії, яку просили, у сховищі взагалі не існує.
        It '-FromVersion/-FromLatest на СХОВИЩІ БЕЗ ЖОДНОЇ ВЕРСІЇ — окрема зупинка, не "дзеркало синхронне"' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'empty-storage-report')
            Mock -ModuleName sync Get-StorageVersions { , @() }
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 5 } | Should -Throw '*порожній*'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromLatest } | Should -Throw '*порожній*'
        }
    }

    Context 'параметри — валідація до звернення до платформи' {
        # Рев'ю Task 2, п. 3: без мока Get-StorageVersions регресія будь-якого з трьох гардів
        # пропускає виклик далі — СПРАВЖНЯ Get-StorageVersions піде через Invoke-V8Designer у
        # реальну платформу проти неіснуючої ІБ. Тест урешті впав би, але вже ПІСЛЯ запуску
        # 1cv8.exe — у безплатформному Describe. Мокаємо платформні виклики так само, як у
        # сусідньому Context вище.
        BeforeEach {
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'версія') }
        }

        It '-FromVersion разом із -FromLatest — зупинка (взаємовиключні), платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'mutex')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 5 -FromLatest } |
                Should -Throw '*взаємовиключ*'
            # Task 3: sync цієї функції не кличе НІ ЗА ЯКИХ УМОВ — Should -Invoke на
            # New-ExtensionInfobase був би завжди-зеленим (тавтологічним), вирізання самої
            # валідації його не зачепить (docs/follow-ups.md §4). Замінено на живий доказ:
            # платформа взагалі не викликана.
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }

        It '-FromVersion 0 — зупинка, платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'zero')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion 0 } | Should -Throw '*додатн*'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }

        It '-FromVersion від''ємний — зупинка, платформа не викликається' {
            $repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive 'negative')
            { Invoke-KitSync -Context (New-KitTestContext -Repo $repo) -Apply $true -FromVersion -3 } | Should -Throw '*додатн*'
            Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
            Should -Invoke -ModuleName sync Get-StorageVersions -Times 0
        }
    }

    Context 'непорожня гілка — -FromVersion/-FromLatest призначені лише для першого реплею' {
        BeforeEach {
            $script:Repo = New-KitEmptyBranchRepo -Root (Join-Path $TestDrive "nonempty-$([guid]::NewGuid().ToString('N'))")
            Add-KitFakeStorageCommit -Repo $script:Repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
                -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
            # До реалізації Task 2 ця зупинка ще не існує — без мока платформа не мокана і
            # виконання пішло б у реальну платформу. Мокаємо тут теж, щоб тест до фікса падав
            # швидко й з ясної причини, а не зависав на платформі.
            Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 6 -Comment 'нова') }
        }

        It '-FromVersion на непорожній гілці — зупинка, що називає трейлер вершини; жодного коміту не додано' {
            $before = git -C $script:Repo rev-parse 'storage/Alpha_SMB'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $script:Repo) -Apply $true -FromVersion 5 } |
                Should -Throw '*Storage-Version*5*'
            (git -C $script:Repo rev-parse 'storage/Alpha_SMB') | Should -Be $before
        }

        It '-FromLatest на непорожній гілці — та сама зупинка; жодного коміту не додано' {
            $before = git -C $script:Repo rev-parse 'storage/Alpha_SMB'
            { Invoke-KitSync -Context (New-KitTestContext -Repo $script:Repo) -Apply $true -FromLatest } |
                Should -Throw '*Storage-Version*5*'
            (git -C $script:Repo rev-parse 'storage/Alpha_SMB') | Should -Be $before
        }
    }
}
