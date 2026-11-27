#Requires -Version 7
Describe 'kit sync — origin: fetch перед реплеєм і підказка про push' {
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
        # Раннер Уніки — не справжній: платформу воркспейсу і agent release командою sync/verify беруть із цих моків
        # (Get-KitRunnerPath шукав би Уніку на машині, Get-KitAgentPlatform/Invoke-KitAgentRelease запускали б справжній v8-runner).
        Mock -ModuleName sync Get-KitRunnerPath { 'C:\fake\v8-runner.exe' }
        Mock -ModuleName sync Get-KitAgentPlatform { 'C:\fake\8.3.27.9999\bin\1cv8.exe' }
        Mock -ModuleName sync Invoke-KitAgentRelease { [pscustomobject]@{ released = $false; disconnected = $false } }

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

    It 'дзеркало отримало новий коміт, а origin відстав — sync -Apply сам пушить дзеркало fast-forward' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'push-hint') -WithHooks -WithAgentBase
        $storageDir = Join-Path $TestDrive 'push-hint-storage'
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
            @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
            -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
            -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')

        # origin — реальний bare-клон стану РЕПО ДО нового коміту: sync має fetch'нути його сам
        # і лише тоді Get-KitOriginGap побачить різницю.
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
        $text | Should -BeLike '*Дзеркало запушено в origin: storage/Alpha_SMB (було попереду origin на 1)*'
        # Доказ — стан самого origin, а не текст: вершина дзеркала там та сама, що локально.
        (git -C $up rev-parse 'refs/heads/storage/Alpha_SMB') | Should -Be (git -C $repo rev-parse 'refs/heads/storage/Alpha_SMB')
        $text | Should -Not -BeLike '*цей push робить людина*'
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

    # Дзеркало, що лишилось попереду origin ЩЕ З ПОПЕРЕДНЬОГО прогону, при sync БЕЗ нових версій теж
    # має дійти до origin. Тут версія 5 — локальний коміт, зроблений ПІСЛЯ клонування origin (тобто
    # "попередній прогін" без push), а цей прогін бачить ту саму версію 5 у звіті — pending порожній,
    # реплею не буде взагалі. Функція повертає репозиторій і bare-origin, що стоїть на версії 4.
    BeforeAll {
        function script:New-KitStaleMirrorRepo {
            param([Parameter(Mandatory)][string]$Name)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithAgentBase
            $storageDir = Join-Path $TestDrive "$Name-storage"
            New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value (
                @('storages:', "  Alpha_SMB: '$storageDir'") -join "`n")
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'Configuration.xml' -Content (New-KitFakeConfigurationXml -Name 'Alpha_SMB') `
                -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 4')

            # origin клонується ТУТ — бачить лише версію 4.
            $up = Join-Path $TestDrive "$Name-upstream"
            git clone -q --bare $repo $up 2>&1 | Out-Null
            git -C $repo remote add origin $up 2>&1 | Out-Null

            # Контент версії 5 мусить ВІДРІЗНЯТИСЬ від версії 4 — інакше git commit побачить чисте
            # дерево ("nothing to commit") і сам коміт не відбудеться.
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'Configuration.xml' -Content ((New-KitFakeConfigurationXml -Name 'Alpha_SMB') + "`r`n<!-- v5 -->") `
                -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 5')
            [pscustomobject]@{ Repo = $repo; Up = $up; UpBefore = (git -C $up rev-parse 'refs/heads/storage/Alpha_SMB') }
        }
    }

    BeforeEach {
        Mock -ModuleName StoragePlatform Invoke-V8Designer { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        # Той самий номер версії, що вже на вершині — pending порожній, реплею немає взагалі.
        Mock -ModuleName sync Get-StorageVersions { , @(New-KitFakeStorageVersion -Version 5 -Comment 'синхронна версія') }
    }

    It 'дзеркало попереду origin ще з попереднього прогону, нових версій немає — sync -Apply однаково пушить його' {
        $r = New-KitStaleMirrorRepo -Name 'push-stale'
        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $r.Repo) -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Нових версій немає*'
        $text | Should -BeLike '*Дзеркало запушено в origin: storage/Alpha_SMB (було попереду origin на 1)*'
        (git -C $r.Up rev-parse 'refs/heads/storage/Alpha_SMB') | Should -Be (git -C $r.Repo rev-parse 'refs/heads/storage/Alpha_SMB')
        Should -Invoke -ModuleName StoragePlatform Invoke-V8Designer -Times 0
    }

    It 'прев''ю без -Apply не пушить — лише каже, що запушить -Apply' {
        $r = New-KitStaleMirrorRepo -Name 'push-preview'
        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $r.Repo) -Apply $false -InformationVariable infoRecords
        $result.ExitCode | Should -Be 0
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*Дзеркало попереду origin на 1 — kit sync -Apply запушить його (лише fast-forward)*'
        (git -C $r.Up rev-parse 'refs/heads/storage/Alpha_SMB') | Should -Be $r.UpBefore
    }

    It 'дзеркало й origin розійшлися — ЗУПИНКА, код 1, push не пробується і origin не змінено' {
        $r = New-KitStaleMirrorRepo -Name 'push-diverged'
        # Інша машина записала у storage/Alpha_SMB на origin свій коміт поверх версії 4.
        $other = Join-Path $TestDrive 'push-diverged-other'
        git clone -q --branch 'storage/Alpha_SMB' $r.Up $other 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'other.txt') -Value 'інша машина'
        git -C $other add other.txt 2>&1 | Out-Null
        git -C $other -c user.name=other -c user.email=other@example.invalid commit -q -m 'інша машина' 2>&1 | Out-Null
        git -C $other push -q origin 'storage/Alpha_SMB' 2>&1 | Out-Null
        $upDiverged = git -C $r.Up rev-parse 'refs/heads/storage/Alpha_SMB'
        $upDiverged | Should -Not -Be $r.UpBefore

        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $r.Repo) -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 1
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*ЗУПИНКА: push storage/Alpha_SMB в origin не виконано: дзеркало й origin розійшлися (лише локально — 1, лише на origin — 1 комітів)*'
        $text | Should -Not -BeLike '*Готово.*'
        $text | Should -Not -BeLike '*next:*'
        (git -C $r.Up rev-parse 'refs/heads/storage/Alpha_SMB') | Should -Be $upDiverged
    }

    It 'origin відхилив push — ЗУПИНКА з сирим виводом git, код 1, без force' {
        $r = New-KitStaleMirrorRepo -Name 'push-rejected'
        # Хук сервера відхиляє будь-який push — так само поводиться захищена гілка чи брак прав.
        Set-Content -LiteralPath (Join-Path $r.Up 'hooks/pre-receive') -Encoding ascii -NoNewline -Value "#!/bin/sh`necho 'kit-test: push denied' >&2`nexit 1`n"

        $result = Invoke-KitSync -Context (New-KitTestContext -Repo $r.Repo) -Apply $true -InformationVariable infoRecords
        $result.ExitCode | Should -Be 1
        $text = ($infoRecords | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -BeLike '*ЗУПИНКА: git push origin storage/Alpha_SMB відхилено (код *kit-test: push denied*kit не робить force*'
        $text | Should -Not -BeLike '*next:*'
        (git -C $r.Up rev-parse 'refs/heads/storage/Alpha_SMB') | Should -Be $r.UpBefore
    }
}
