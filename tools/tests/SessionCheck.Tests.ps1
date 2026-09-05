#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Фейкове сховище: 1cv8ddb.1CD + data/objects/*. Шлях підставляється накладкою (storages:).
        function script:New-FakeStorage {
            param([string]$Name, [datetime]$ObjectsWrite, [datetime]$DbWrite)
            $s = Join-Path $TestDrive "storage-$Name"
            New-Item -ItemType Directory -Path (Join-Path $s 'data/objects/ab') -Force | Out-Null
            $obj = Join-Path $s 'data/objects/ab/cdef.bin'; Set-Content -LiteralPath $obj -Value 'obj'
            $db  = Join-Path $s '1cv8ddb.1CD';             Set-Content -LiteralPath $db  -Value 'db'
            (Get-Item $obj).LastWriteTimeUtc = $ObjectsWrite.ToUniversalTime()
            (Get-Item $db).LastWriteTimeUtc  = $DbWrite.ToUniversalTime()
            $s
        }
        function script:New-Repo {
            param([string]$Name, [string]$StoragePath, [datetime]$MirrorDate, [switch]$NoMirror, [switch]$Merge)
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -OverlayText "storages:`n  Alpha_SMB: '$StoragePath'" -WithHooks -WithGitattributes -WithGitignore
            if (-not $NoMirror) {
                $stamp = $MirrorDate.ToString('yyyy-MM-ddTHH:mm:ss')
                $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp
                try { Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1') }
                finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
                if ($Merge) { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null }
            }
            # Слід фікстури: worktree remove прибирає wt, а порожню build/sync лишає — щоб твердження
            # «session-check не створює тек» перевіряло команду, а не фікстуру (P2 префлайту B3).
            Remove-Item -LiteralPath (Join-Path $repo 'build') -Recurse -Force -ErrorAction SilentlyContinue
            $repo
        }
        function script:Invoke-SessionCheck {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit session-check -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Old = [datetime]'2026-01-10T10:00:00'
        $script:New = [datetime]'2026-02-20T10:00:00'
    }

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

    It 'error у check (наприклад, накладка не гітігнорована) → код 1, [-]-рядок і «сигнали не обчислювались»; сигналів немає' {
        $s = New-FakeStorage -Name 'cherr' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'check-error' -StoragePath $s -MirrorDate $script:Old -Merge
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "build/`n" -Encoding UTF8   # без v8storagekit.local.yaml → error overlay-ignored
        git -C $repo commit -qam 'gitignore без накладки'
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[-\].*v8storagekit\.local\.yaml'
        $r.Output | Should -BeLike '*не обчислювались*kit check*'
        $r.Output | Should -Not -BeLike '*нові версії*'     # хоч сховище й новіше — сигнал не рахувався
    }

    It 'error у check (хуки не встановлені) → код 1 без сигналів; лише warn (немає накладки) → [!] над сигналами, код від сигналів' {
        $s = New-FakeStorage -Name 'hooks' -ObjectsWrite $script:New -DbWrite $script:New
        $noHooks = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-hooks') -OverlayText "storages:`n  Alpha_SMB: '$s'" -WithGitattributes -WithGitignore
        $r = Invoke-SessionCheck -Repo $noHooks
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*[-]*core.hooksPath*не обчислювались*'

        $warnOnly = New-Repo -Name 'warn-only' -StoragePath $s -MirrorDate $script:Old -Merge   # дев-бази base у накладці немає → warn dump-from
        $r2 = Invoke-SessionCheck -Repo $warnOnly
        $r2.ExitCode | Should -Be 3
        $r2.Output | Should -Match '\[!\].*dump\.from|\[!\].*infobases'
        $r2.Output | Should -BeLike '*- Alpha_SMB:*нові версії*'
    }

    # Step 3а — префлайт `session-check` тепер поблажливий (-Lenient), як і `check`: помилка
    # РІВНЯ ПРЕФЛАЙТУ (тут — маніфест без обов'язкового workspaces:) має стати [-]-рядком і
    # «сигнали не обчислювались» через той самий шлях check.psm1, а не сирим текстом винятку
    # ДО виклику Invoke-KitCheck. Той самий сценарій, що й тест шима в B4.
    It 'префлайт лінивий для session-check: маніфест без workspaces → код 1, [-], «workspaces», «не обчислювались»' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-manifest') -ManifestText "version: 1`n"
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match '\[-\].*workspaces'
        $r.Output | Should -BeLike '*не обчислювались*'
    }

    It '-AsJson — валідний JSON з полями сигналу' {
        $s = New-FakeStorage -Name 'json' -ObjectsWrite $script:New -DbWrite $script:New
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'json' -StoragePath $s -MirrorDate $script:Old -Merge) -More @('-AsJson')
        $json = $r.Output | ConvertFrom-Json
        @($json).Count | Should -Be 1
        @($json)[0].Key | Should -Be 'Alpha_SMB'
        @($json)[0].NewInStorage | Should -BeTrue
    }

    It 'session-check нічого не змінює й не створює тек' {
        $s = New-FakeStorage -Name 'ro' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'ro' -StoragePath $s -MirrorDate $script:Old -Merge
        Invoke-SessionCheck -Repo $repo | Out-Null
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }
}
