#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitMerge.psm1").Path -Force
        # Task 8: StorageImprint.psm1 — записуємо відбиток напряму в тестах (без реального kit
        # sync), щоб перевірити ГІЛКУ ВІДБИТКА session-check ізольовано від платформи.
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageImprint.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Фейкове сховище: 1cv8ddb.1CD + data/objects/* (типово) і опційно data/pack/* (-PackWrite).
        # -NoObjectFile — сховище, де всю історію вже запаковано: data/objects лишається без
        # жодного файла (Task 8, спека 9f6ad5e §5, «Запаковане сховище»). Шлях підставляється
        # накладкою (storages:).
        function script:New-FakeStorage {
            param([string]$Name, [datetime]$ObjectsWrite, [datetime]$DbWrite, [datetime]$PackWrite, [switch]$NoObjectFile)
            $s = Join-Path $TestDrive "storage-$Name"
            if (-not $NoObjectFile) {
                New-Item -ItemType Directory -Path (Join-Path $s 'data/objects/ab') -Force | Out-Null
                $obj = Join-Path $s 'data/objects/ab/cdef.bin'; Set-Content -LiteralPath $obj -Value 'obj'
                (Get-Item $obj).LastWriteTimeUtc = $ObjectsWrite.ToUniversalTime()
            } else {
                New-Item -ItemType Directory -Path $s -Force | Out-Null
            }
            $db  = Join-Path $s '1cv8ddb.1CD'; Set-Content -LiteralPath $db -Value 'db'
            (Get-Item $db).LastWriteTimeUtc = $DbWrite.ToUniversalTime()
            # $PSBoundParameters.ContainsKey, не "$PackWrite -ne $null": [datetime] непорожній за
            # замовчуванням (DateTime.MinValue, не $null), а Nullable[datetime]-параметр, який
            # реально отримав значення, боксується як гола System.DateTime (правило CLR для
            # Nullable<T>), тож .Value на ньому впав би "cannot call a method on a null-valued
            # expression" — той самий зразок, що New-KitFakeRepo (-ManifestText) у KitFixtures.psm1.
            if ($PSBoundParameters.ContainsKey('PackWrite')) {
                New-Item -ItemType Directory -Path (Join-Path $s 'data/pack') -Force | Out-Null
                $pack = Join-Path $s 'data/pack/1.pack'; Set-Content -LiteralPath $pack -Value 'pack'
                (Get-Item $pack).LastWriteTimeUtc = $PackWrite.ToUniversalTime()
            }
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

    # Рев'ю раунд 2, I1: недоступність сховища раніше "з'їдала" сигнал незлитих комітів — текст
    # згадував ЛИШЕ недоступність, хоч $unmerged рахувався незалежно від Accessible і код виходу
    # вже на нього дивився. Сценарій: ноутбук поза мережею, а на дзеркалі є незлитий коміт —
    # звичайний стан після kit sync -Apply без -MergeMain.
    It 'I1: сховище недоступне, а на дзеркалі є незлиті коміти — текст називає ОБИДВІ причини' {
        $repo = New-Repo -Name 'i1-inaccessible-unmerged' -StoragePath (Join-Path $TestDrive 'nope-i1') -MirrorDate $script:Old
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*недоступн*'
        $r.Output | Should -BeLike '*- Alpha_SMB:*не злит*main*kit verify*'
    }

    # Рев'ю раунд 2, I2 (сценарій A): шлях у storages: доступний (тека є), але не схожий на
    # сховище 1С (немає data/objects) — і дзеркало вже є (шлях переплутано ПІСЛЯ першого sync,
    # напр. на батьківську теку). Раніше це мовчки давало "синхронне", код 0 — хибний all-clear
    # на завідомо неправильному шляху гірший за будь-який шум.
    It 'I2 (сценарій A): шлях доступний, але без data/objects, дзеркало вже є — НЕ "синхронне", код 3' {
        $wrong = Join-Path $TestDrive 'i2-wrong-a'
        New-Item -ItemType Directory -Path $wrong -Force | Out-Null
        $repo = New-Repo -Name 'i2-wrong-a' -StoragePath $wrong -MirrorDate $script:Old -Merge
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*не схож*сховищ*'
        $r.Output | Should -Not -BeLike '*синхронне*'
    }

    # Рев'ю раунд 2, I2 (сценарій B): те саме, але дзеркала ще й немає — раніше текст казав
    # "дзеркала ще немає — kit sync" (дієво), а код був 0 (тиша): контракт "дзеркала немає при
    # доступному сховищі → 3" порушувався саме тут.
    It 'I2 (сценарій B): дзеркала немає, шлях доступний, але без data/objects — код і текст узгоджені (3)' {
        $wrong = Join-Path $TestDrive 'i2-wrong-b'
        New-Item -ItemType Directory -Path $wrong -Force | Out-Null
        $repo = New-Repo -Name 'i2-wrong-b' -StoragePath $wrong -MirrorDate $script:Old -NoMirror
        $r = Invoke-SessionCheck -Repo $repo
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*- Alpha_SMB:*не схож*сховищ*'
        $r.Output | Should -BeLike '*- Alpha_SMB:*дзеркала*немає*kit sync*'
    }

    # Рев'ю раунд 2, I3: без допуску mtime сховища (частка секунди) проти дати коміту дзеркала
    # (цілі секунди, GIT_AUTHOR_DATE) сигналило б вічно навіть на записі, зробленому тим самим
    # sync. Межа: 2с у межах допуску (5с, StorageMirrorTolerance) — тихо; 10с — сигнал.
    It 'I3: допуск на порівняння mtime з датою коміту — у межах 5с тихо, за межею — сигнал' {
        $mirrorDate = [datetime]'2026-03-01T12:00:00'
        $sNear = New-FakeStorage -Name 'tol-near' -ObjectsWrite $mirrorDate.AddSeconds(2) -DbWrite $mirrorDate.AddSeconds(2)
        $rNear = Invoke-SessionCheck -Repo (New-Repo -Name 'tol-near' -StoragePath $sNear -MirrorDate $mirrorDate -Merge)
        $rNear.Output | Should -Not -BeLike '*нові версії*'

        $sFar = New-FakeStorage -Name 'tol-far' -ObjectsWrite $mirrorDate.AddSeconds(10) -DbWrite $mirrorDate.AddSeconds(10)
        $rFar = Invoke-SessionCheck -Repo (New-Repo -Name 'tol-far' -StoragePath $sFar -MirrorDate $mirrorDate -Merge)
        $rFar.Output | Should -BeLike '*нові версії*'
    }

    # Рев'ю раунд 2, I4: -AsJson мав дві несумісні форми верхнього рівня — масив на щасливому
    # шляху, об'єкт {CheckErrors;Signals} на шляху помилки check. Тепер обидві — масив (порожній
    # на шляху помилки): споживач завжди робить ConvertFrom-Json | ForEach-Object без розбору форми.
    It 'I4: -AsJson дає ОДНУ форму верхнього рівня і на щасливому шляху, і при помилці check' {
        $s = New-FakeStorage -Name 'i4-err' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'i4-err' -StoragePath $s -MirrorDate $script:Old -Merge
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "build/`n" -Encoding UTF8   # без v8storagekit.local.yaml → error overlay-ignored
        git -C $repo commit -qam 'gitignore без накладки'
        $r = Invoke-SessionCheck -Repo $repo -More @('-AsJson')
        $r.ExitCode | Should -Be 1
        { $r.Output | ConvertFrom-Json } | Should -Not -Throw
        @($r.Output | ConvertFrom-Json).Count | Should -Be 0
    }

    # Дрібна правка рев'ю раунд 2 (рядок 71 старої версії): NewInStorage=$true виставлявся й
    # тоді, коли порівнювати нема з чим (дзеркала немає) — у JSON це читалось як "є нові версії",
    # хоча споживач, що будує текст із полів, а не з Text, мав би сказати щось інше.
    # NewInStorageReason розрізняє: 'no-mirror'/'unclear' — нема з чим порівняти; 'newer' —
    # справжнє порівняння дат.
    It 'NewInStorageReason у JSON розрізняє "нема з чим порівняти" від справжнього порівняння дат' {
        $s = New-FakeStorage -Name 'reason-nomirror' -ObjectsWrite $script:Old -DbWrite $script:Old
        $r = Invoke-SessionCheck -Repo (New-Repo -Name 'reason-nomirror' -StoragePath $s -MirrorDate $script:Old -NoMirror) -More @('-AsJson')
        $json = $r.Output | ConvertFrom-Json
        @($json)[0].NewInStorage | Should -BeTrue
        @($json)[0].NewInStorageReason | Should -Be 'no-mirror'
    }

    It 'session-check нічого не змінює й не створює тек' {
        $s = New-FakeStorage -Name 'ro' -ObjectsWrite $script:New -DbWrite $script:New
        $repo = New-Repo -Name 'ro' -StoragePath $s -MirrorDate $script:Old -Merge
        Invoke-SessionCheck -Repo $repo | Out-Null
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
        Join-Path $repo 'build' | Should -Not -Exist
    }

    # Task 8 — інваріант «session-check нічого не мутує» (task-8-brief.md): на ньому стоїть
    # законність примусового вбивання процесу за стелею часу в шимі B4. Найслабша форма («build/
    # не з'явилась») не ловить мутацію файла, який УЖЕ існував (наприклад — «оновимо кеш, раз ми
    # його вже прочитали»), тому тут — знімок усього дерева репозиторію (включно з build/, БЕЗ
    # .git/ — там і без нашого коду постійно щось міняється: пакування, commit-graph тощо, і це
    # не те, що обіцяє інваріант) байт у байт і mtime у mtime, ДО і ПІСЛЯ прогону, з наявним
    # відбитком (щоб гілка Read-KitStorageImprint + Test-KitStorageImprintCurrent справді
    # виконалась, а не пропустилась через відсутність файла).
    It 'доказ інваріанта: з наявним відбитком — жодного байта, жодного mtime не змінено ніде в дереві репозиторію' {
        $s = New-FakeStorage -Name 'invariant' -ObjectsWrite $script:Old -DbWrite $script:Old
        $repo = New-Repo -Name 'invariant' -StoragePath $s -MirrorDate $script:Old -Merge
        Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath $s -Version 1 | Out-Null

        function script:Get-KitTestTreeSnapshot {
            param([string]$Root)
            $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
                Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
            $map = [ordered]@{}
            foreach ($f in ($files | Sort-Object FullName)) {
                $rel = $f.FullName.Substring($Root.Length).Replace('\', '/')
                $map[$rel] = [pscustomobject]@{
                    Length = $f.Length
                    LastWriteTimeUtc = $f.LastWriteTimeUtc
                    Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                }
            }
            $map
        }

        $before = Get-KitTestTreeSnapshot -Root $repo
        # Гілка відбитка МАЄ насправді виконатись тут — інакше цей прогін нічим не відрізняється
        # від тесту вище і не доводить нічого нового про саме цю гілку коду.
        $r = Invoke-SessionCheck -Repo $repo
        $r.Output | Should -Not -BeLike '*ймовірно*'
        $after = Get-KitTestTreeSnapshot -Root $repo

        @($after.Keys).Count | Should -Be @($before.Keys).Count -Because 'кількість файлів у дереві не мала змінитися'
        foreach ($rel in $before.Keys) {
            $after.Contains($rel) | Should -BeTrue -Because "файл '$rel' зник після session-check"
            $after[$rel].Length           | Should -Be $before[$rel].Length           -Because "розмір '$rel' змінився"
            $after[$rel].Hash             | Should -Be $before[$rel].Hash             -Because "вміст '$rel' змінився"
            $after[$rel].LastWriteTimeUtc | Should -Be $before[$rel].LastWriteTimeUtc -Because "mtime '$rel' змінився"
        }
    }

    # Task 6 (batch-5-6-brief.md) — відставання локальної гілки від origin: session-check лише
    # ЧИТАЄ вже наявні remote-tracking refs (Get-KitOriginGap, Task 5), мережі не чіпає взагалі.
    Context 'origin: відставання без мережі (Task 6)' {
        It 'дзеркало позаду origin — рядок із порадою git fetch' {
            # Дзеркало, яке в origin пішло вперед, а локально лишилось позаду — рівно стан із ішузу #4.
            # Перший коміт — через Add-KitFakeStorageCommit (той самий механізм, що New-Repo вище): орфанна
            # гілка з коректними трейлерами, інакше kit check спіткнеться на власних інваріантах
            # storage/* (Storage-Source/Storage-Version, дерево лише під шляхом джерела) РАНІШЕ, ніж
            # дійде до сигналу origin, і "Сигнали не обчислювались" замаскує саме те, що тест перевіряє.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-behind') -WithHooks -WithGitattributes -WithGitignore
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'A.xml' -Content 'v1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')

            $up = Join-Path $TestDrive 'sc-upstream'
            git clone -q --bare $repo $up 2>&1 | Out-Null
            git -C $repo remote add origin $up 2>&1 | Out-Null

            # Коміт, який зробила «інша машина»: у bare-репозиторій через окрему робочу копію,
            # ПРОДОВЖЕННЯМ уже існуючої (орфанної) гілки — не новий orphan, звичайний лінійний
            # коміт, з тим самим набором трейлерів, який дав би реальний kit sync.
            $work = Join-Path $TestDrive 'sc-work'
            git clone -q $up $work 2>&1 | Out-Null
            git -C $work checkout -q 'storage/Alpha_SMB' 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $work 'Alpha_SMB/cfe/src/A.xml') -Value 'v2' -Encoding UTF8
            git -C $work add -A 2>&1 | Out-Null
            $msg2 = @('sync: версія 2', '', 'Storage-Source: Alpha_SMB', 'Storage-Version: 2') -join "`n"
            git -C $work -c user.email=t@e.invalid -c user.name=T commit -q -m $msg2 2>&1 | Out-Null
            git -C $work push -q origin 'storage/Alpha_SMB' 2>&1 | Out-Null

            # Локальний репозиторій дізнається про це лише фетчем — саме те, чого агент не робив.
            git -C $repo fetch -q origin 2>&1 | Out-Null

            $r = Invoke-SessionCheck -Repo $repo
            $r.Output | Should -BeLike '*позаду origin*'
            $r.Output | Should -BeLike '*git fetch*'
        }

        It 'session-check не викликає git fetch' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-nofetch') -WithHooks -WithGitignore
            # GIT_TRACE пише кожен запуск git у файл рядком виду
            #   trace: built-in: git fetch origin
            # — БЕЗ лапок навколо підкоманди (перевірено на git 2.53). Асерція на "*'fetch'*"
            # (у лапках) була б зелена завжди й не стверджувала б нічого — рівно той клас
            # тавтологічного guard'а, що docs/follow-ups.md §4 називає дефектом культури тестів.
            $trace = Join-Path $TestDrive 'git-trace.log'
            $env:GIT_TRACE = $trace
            Invoke-SessionCheck -Repo $repo | Out-Null
            Remove-Item Env:\GIT_TRACE
            $trace | Should -Exist -Because 'без трасування тест не стверджує нічого'
            (Get-Content -LiteralPath $trace -Raw) | Should -Not -BeLike '*built-in: git fetch*'
        }
    }
}
