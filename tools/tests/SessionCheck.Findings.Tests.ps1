#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-manifest') -ManifestText "version: 1`nkitVersion: 1.0.1`n"
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
}
