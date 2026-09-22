#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

    It '(а) файли data/objects новіші за дзеркало → сигнал «нові версії»' {
        $s = New-FakeStorage -Name 'newer' -ObjectsWrite $script:New -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-newer' -StoragePath $s -MirrorDate $script:Old -Merge)
        $r.ExitCode | Should -Be 3     # є що робити (спека §5: коди за змістом)
        $r.Output | Should -BeLike '*- Alpha_SMB:*нові версії*kit sync*'
    }

    It '(а) файли data/objects старіші за дзеркало → тиша' {
        $s = New-FakeStorage -Name 'older' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-older' -StoragePath $s -MirrorDate $script:New -Merge)
        $r.ExitCode | Should -Be 0     # тиша → 0
        $r.Output | Should -Not -BeLike '*нові версії*'
        $r.Output | Should -BeLike '*- Alpha_SMB:*синхронн*'
    }

    It '(а) 1cv8ddb.1CD новіший, а data/objects — ні → тиша (mtime бази не індикатор)' {
        $s = New-FakeStorage -Name 'db-only' -ObjectsWrite $script:Old -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'a-db' -StoragePath $s -MirrorDate ([datetime]'2026-01-15T10:00:00') -Merge)
        $r.Output | Should -Not -BeLike '*нові версії*'
    }

    # Task 8 (task-8-brief.md) — запаковане сховище, три результати евристики (спека 9f6ad5e §5).
    Context 'запаковане сховище (data/pack) — евристики без відбитка' {
        It 'objects новіші за дзеркало → «нові версії», НЕЗАЛЕЖНО від того, чи pack теж новіший' {
            $s = New-FakeStorage -Name 'pack-objects-newer' -ObjectsWrite $script:New -DbWrite $script:New -PackWrite $script:New
            $r = Invoke-SessionCheck -Repo (New-Repo -Name 'pack-objects-newer' -StoragePath $s -MirrorDate $script:Old -Merge)
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*- Alpha_SMB:*нові версії*'
            $r.Output | Should -Not -BeLike '*запаковані*'
        }

        It 'pack НЕ новіший за дзеркало → звичайна логіка по objects, pack у виводі не згадується' {
            $s = New-FakeStorage -Name 'pack-not-newer' -ObjectsWrite $script:Old -DbWrite $script:Old -PackWrite $script:Old
            $r = Invoke-SessionCheck -Repo (New-Repo -Name 'pack-not-newer' -StoragePath $s -MirrorDate $script:New -Merge)
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -BeLike '*нові версії*'
            $r.Output | Should -Not -BeLike '*запаковані*'
        }

        It 'усі об''єкти запаковано (objects сигналу не дає), pack новіший за дзеркало → код 3, порада kit sync БЕЗ -Apply' {
            $s = New-FakeStorage -Name 'pack-only-newer' -DbWrite $script:Old -NoObjectFile -PackWrite $script:New
            $r = Invoke-SessionCheck -Repo (New-Repo -Name 'pack-only-newer' -StoragePath $s -MirrorDate $script:Old -Merge)
            $r.ExitCode | Should -Be 3
            $r.Output | Should -BeLike '*- Alpha_SMB:*запаковані*kit sync*без -Apply*'
            $r.Output | Should -Not -BeLike '*ймовірно нові версії*'
        }
    }
}
