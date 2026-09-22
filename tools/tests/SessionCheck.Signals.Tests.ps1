#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

    It '(б) коміти на storage/X, не злиті в main → сигнал із кількістю і підказкою verify' {
        $s = New-FakeStorage -Name 'unmerged' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'b-unmerged' -StoragePath $s -MirrorDate $script:New)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*1 *не злит*main*kit verify*'
    }

    It 'дзеркала ще немає при доступному сховищі → «дзеркала немає — kit sync», код 3' {
        $s = New-FakeStorage -Name 'nomirror' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'no-mirror' -StoragePath $s -MirrorDate $script:Old -NoMirror)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*дзеркала*немає*kit sync*'
    }

    It 'сховище недоступне на цій машині → рядок «недоступне», код 0; без дзеркала — ще й «дзеркала немає»' {
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'inaccessible' -StoragePath (Join-Path $TestDrive 'nope') -MirrorDate $script:Old -Merge)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*- Alpha_SMB:*недоступн*'
        $r2 = Invoke-SessionCheck -Repo (New-Repo -Name 'inaccessible-nomirror' -StoragePath (Join-Path $TestDrive 'nope') -MirrorDate $script:Old -NoMirror)
        $r2.ExitCode | Should -Be 0
        $r2.Output | Should -BeLike '*недоступн*Дзеркала*немає*'
    }

    It 'git log на НАЯВНІЙ гілці не відповів → код 1; рядок — або від check (інваріанти storage/*), або від сигналу' {
        # Гілка є (ref розв'язується), а об'єкт вершини видалено: rev-parse проходить, log/rev-list падають.
        # check обходить лог storage/* першим і, найімовірніше, зупиниться раніше за сигнал — закріпити той рядок,
        # який реально з'являється; обидва називають гілку.
        $s = New-FakeStorage -Name 'gitbroken' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'git-broken' -StoragePath $s -MirrorDate $script:Old -Merge
        $sha = (git -C $repo rev-parse storage/Alpha_SMB).Trim()
        Remove-Item -LiteralPath (Join-Path $repo ".git/objects/$($sha.Substring(0,2))/$($sha.Substring(2))") -Force
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*storage/Alpha_SMB*'
    }

    It 'гілки mainBranch немає, HEAD деінде (описка) → [!] від check, код 3, «перевірте mainBranch:»' {
        $s = New-FakeStorage -Name 'nomain' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'no-main' -StoragePath $s -MirrorDate $script:Old -Merge
        git -C $repo branch -m main trunk
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match '\[!\].*main'
        $r.Output | Should -BeLike "*- Alpha_SMB:*коміт*гілки 'main'*немає*перевірте mainBranch*"
        $r.Output | Should -Not -BeLike '*зробіть перший коміт*'
    }

    It 'свіжий репозиторій: unborn main і готове дзеркало → [i] від check, код 3, «зробіть перший коміт … -MergeMain»' {
        $s = New-FakeStorage -Name 'unborn' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unborn') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithHooks -WithGitattributes -WithGitignore -NoCommit
        # Дзеркало без жодного коміту в main: якщо `worktree add --orphan` відмовить на репо без комітів —
        # створити через `git checkout --orphan storage/Alpha_SMB` у головній копії, закомітити з V8KIT_SYNC=1
        # і повернутись на unborn main: `git checkout --orphan main; git rm -rq --cached .`.
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        (git -C $repo symbolic-ref -q HEAD) | Should -Be 'refs/heads/main'
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match '\[i\].*main'
        $r.Output | Should -BeLike '*- Alpha_SMB:*зробіть перший коміт*-MergeMain*'
    }
}
