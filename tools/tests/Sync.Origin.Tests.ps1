#Requires -Version 7
Describe 'kit sync — origin: fetch перед реплеєм і підказка про push (Task 5, спека 2026-09-17 §6)' {
    # Той самий прийом мокання, що в Describe вище — Invoke-KitSync кличеться напряму в цьому
    # процесі, платформа НЕ запускається. git fetch і Get-KitOriginGap тут НЕ мокані навмисно:
    # реальний локальний "origin" (bare-клон) — найдешевший спосіб довести, що sync справді читає
    # ЖИВИЙ стан remote-tracking гілки, а не мок, який був би зеленим і на регресії.
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
    }

    It 'дзеркало отримало новий коміт, а origin відстав — підказка "git push origin (гілка)" з точним числом' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        # origin — реальний bare-клон стану РЕПО ДО нового коміту: sync має fetch'нути його сам
        # (Task 5, Step 4), і лише тоді Get-KitOriginGap побачить різницю.
        $up = Join-Path $TestDrive 'push-hint-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 6 -Comment 'нова') }
        Mock -ModuleName sync Invoke-KitMainMerge { $true }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Дзеркало попереду origin на 1 — git push origin storage/Alpha_SMB*'
    }

    It 'дзеркало вже синхронне з origin (Ahead=0) — підказки про push немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint-none') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-none-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        # origin містить рівно той самий коміт (клоновано ПІСЛЯ запису версії 5) — Ahead=0.
        $up = Join-Path $TestDrive 'push-hint-none-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Той самий номер версії, що вже на вершині — pending порожній, реплею немає взагалі.
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Not -BeLike '*Дзеркало попереду origin*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    # Фінальне рев'ю C2 — знахідка §6: підказка друкувалась лише в гілці коду з новими версіями;
    # дзеркало, що лишилось попереду origin ЩЕ З ПОПЕРЕДНЬОГО прогону (git push тоді не зробили),
    # при sync БЕЗ нових версій мовчало. Тут версія 5 — локальний коміт, зроблений ДО клонування
    # origin (тобто "попередній прогін"), а цей прогін bачить ту саму версію 5 у звіті — pending
    # порожній, реплею не буде взагалі.
    It 'дзеркало попереду origin ще з попереднього прогону, а нових версій цього разу немає — підказка про push однаково друкується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint-stale') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-stale-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 4')

        # origin клонується ТУТ — бачить лише версію 4.
        $up = Join-Path $TestDrive 'push-hint-stale-upstream'
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null

        # Версія 5 — попереднім прогоном sync, локально; origin про неї не знає (не запушили).
        # Контент версії 5 мусить ВІДРІЗНЯТИСЬ від версії 4 — інакше git commit побачить чисте
        # дерево ("nothing to commit") і сам коміт не відбудеться.
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content ((New-KitFakeConfigurationXml -Name 'Alpha_SMB') + "`r`n<!-- v5 -->") `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        $ctx = New-KitTestContext -Repo $repo
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Той самий номер версії, що вже на вершині — pending порожній, реплею немає взагалі.
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }

        $result = Invoke-KitSync -Context $ctx -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Нових версій немає*'
        $text | Should -BeLike '*Дзеркало попереду origin на 1 — git push origin storage/Alpha_SMB*'
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }
}
