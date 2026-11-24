#Requires -Version 7
Describe 'kit session-check — сигнал без платформи' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

    It '(б) коміти на storage/X, не злиті в main → сигнал із кількістю і підказкою verify' {
        $s = New-FakeStorage -Name 'unmerged' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'b-unmerged' -StoragePath $s -MirrorDate $script:New)
        $r.ExitCode | Should -Be 4
        $r.Output | Should -BeLike '*- Alpha_SMB:*1 *не злит*main*kit verify*'
    }

    It 'next: — є крок: останній рядок next: дорівнює першому надрукованому кроку' {
        $s = New-FakeStorage -Name 'next-step' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'next-step' -StoragePath $s -MirrorDate $script:New)
        $r.ExitCode | Should -Be 4
        $lines = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() })
        $r.Output | Should -BeLike '*звірочний коміт: kit verify -Apply*'
        $lines[-1] | Should -BeExactly 'next: kit verify -Apply'
    }

    It 'next: — код 0 без кроку: рядка next: немає' {
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'next-none' -StoragePath (Join-Path $TestDrive 'nope-next') -MirrorDate $script:Old -Merge)
        $r.ExitCode | Should -Be 0
        @($r.Output -split "`r?`n" | Where-Object { $_ -like 'next:*' }) | Should -HaveCount 0
    }

    It 'дзеркала ще немає при доступному сховищі → «дзеркала немає — kit sync», код 4' {
        $s = New-FakeStorage -Name 'nomirror' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'no-mirror' -StoragePath $s -MirrorDate $script:Old -NoMirror)
        $r.ExitCode | Should -Be 4
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

    It 'git log на НАЯВНІЙ гілці не відповів → код 1: [!] «не перевірено» від check І рядок сигналу GitProblem, без «Сигнали не обчислювались»' {
        # Гілка є (ref розв'язується), а об'єкт вершини видалено: rev-parse проходить, log/rev-list падають.
        # check (B3) на збої git дає warn «не перевірено», а не error, тож сигнали ОБЧИСЛЮЮТЬСЯ (раніше: error check і
        # «Сигнали не обчислювались»); збій git джерела — GitProblem, код 1 (пріоритет 1 > 3). Крок — kit check.
        $s = New-FakeStorage -Name 'gitbroken' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'git-broken' -StoragePath $s -MirrorDate $script:Old -Merge
        $sha = (git -C $repo rev-parse storage/Alpha_SMB).Trim()
        Remove-Item -LiteralPath (Join-Path $repo ".git/objects/$($sha.Substring(0,2))/$($sha.Substring(2))") -Force
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike '*[[]!] не перевірено:*storage/Alpha_SMB*'
        $r.Output | Should -BeLike '*- Alpha_SMB: стан git не прочитано (*bad object*) — сигнал недоступний; розбір: kit check.*'
        $r.Output | Should -Not -BeLike '*Сигнали не обчислювались*'
        @($r.Output -split "`r?`n" | Where-Object { $_.Trim() })[-1] | Should -BeExactly 'next: kit check'
        $j = Invoke-SessionCheck -Repo $repo -More @('-AsJson')
        $j.ExitCode | Should -Be 1
        $signals = @($j.Output | ConvertFrom-Json)
        $signals.Count | Should -Be 1
        $signals[0].GitProblem | Should -Not -BeNullOrEmpty
        $signals[0].Accessible | Should -BeTrue
        $signals[0].MirrorExists | Should -BeTrue
    }

    It 'гілки mainBranch немає, HEAD деінде (описка) → [!] від check, код 4, «перевірте mainBranch:»' {
        $s = New-FakeStorage -Name 'nomain' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'no-main' -StoragePath $s -MirrorDate $script:Old -Merge
        git -C $repo branch -m main trunk
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 4
        $r.Output | Should -Match '\[!\].*main'
        $r.Output | Should -BeLike "*- Alpha_SMB:*коміт*гілки 'main'*немає*перевірте mainBranch*"
        $r.Output | Should -Not -BeLike '*зробіть перший коміт*'
    }

    It 'свіжий репозиторій: unborn main і готове дзеркало → [i] від check, код 4, «зробіть перший коміт … -MergeMain»' {
        $s = New-FakeStorage -Name 'unborn' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unborn') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithHooks -WithGitattributes -WithGitignore -NoCommit
        # Дзеркало без жодного коміту в main: якщо `worktree add --orphan` відмовить на репо без комітів —
        # створити через `git checkout --orphan storage/Alpha_SMB` у головній копії, закомітити з V8KIT_SYNC=1
        # і повернутись на unborn main: `git checkout --orphan main; git rm -rq --cached .`.
        Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')
        (git -C $repo symbolic-ref -q HEAD) | Should -Be 'refs/heads/main'
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 4
        $r.Output | Should -Match '\[i\].*main'
        $r.Output | Should -BeLike '*- Alpha_SMB:*зробіть перший коміт*-MergeMain*'
    }
}
