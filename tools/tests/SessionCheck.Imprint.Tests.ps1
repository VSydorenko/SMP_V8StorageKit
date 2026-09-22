#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

    # Task 8 — відбиток (StorageImprint.psm1): точна відповідь замість вічної здогадки, коли диск
    # сховища не змінювався з моменту, коли sync його читав. New-Repo фіксує коміт дзеркала на
    # Storage-Version: 1 — відбиток пишемо тут напряму (Write-KitStorageImprint), без реального
    # kit sync, щоб перевірити гілку session-check ізольовано від платформи.
    Context 'відбиток сховища (build/session-check/<ключ>.json) — точна відповідь перед евристиками' {
        It 'відбиток є, диск не змінився, дзеркало на тій самій версії → код 0, текст називає версію й момент читання, БЕЗ «ймовірно»' {
            $s = New-FakeStorage -Name 'imprint-exact' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'imprint-exact' -StoragePath $s -MirrorDate $script:Old -Merge   # дзеркало: Storage-Version 1
            Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $s -Version 1 | Out-Null
            $r = Invoke-SessionCheck -Repo $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeLike '*- Alpha_SMB:*версії 1*'
            $r.Output | Should -Not -BeLike '*ймовірно*'
        }

        It 'відбиток є, дзеркало позаду (M < N) → код 3, текст називає ОБИДВІ версії' {
            $s = New-FakeStorage -Name 'imprint-ahead' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'imprint-ahead' -StoragePath $s -MirrorDate $script:Old -Merge   # дзеркало: Storage-Version 1
            Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $s -Version 2 | Out-Null
            $r = Invoke-SessionCheck -Repo $repo
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*- Alpha_SMB:*версії 2*версії 1*'
        }

        It 'відбиток є, але диск змінився (новий файл в objects) → евристики, текст знову «ймовірно»' {
            $s = New-FakeStorage -Name 'imprint-stale' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'imprint-stale' -StoragePath $s -MirrorDate $script:Old -Merge
            Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $s -Version 1 | Out-Null
            # Диск змінюємо ПІСЛЯ знімку відбитка — Test-KitStorageImprintCurrent мусить це виявити.
            $extra = Join-Path $s 'data/objects/ab/extra.bin'; Set-Content -LiteralPath $extra -Value 'new'
            (Get-Item $extra).LastWriteTimeUtc = $script:New.ToUniversalTime()
            $r = Invoke-SessionCheck -Repo $repo
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*ймовірно*'
        }

        It 'відбитка немає (свіжий клон) → евристики, як і раніше' {
            $s = New-FakeStorage -Name 'imprint-none' -ObjectsWrite $script:New -DbWrite $script:New
            $repo = New-Repo -Name 'imprint-none' -StoragePath $s -MirrorDate $script:Old -Merge
            # Жодного Write-KitStorageImprint — кешу build/session-check ще нема (свіжий клон).
            $r = Invoke-SessionCheck -Repo $repo
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*ймовірно*'
        }
    }
}
