BeforeAll {
    Import-Module "$PSScriptRoot/../lib/PathSafety.psm1" -Force
}

Describe 'Assert-SafeWorkPath' {
    BeforeEach {
        $script:Boundary = Join-Path $TestDrive 'product'
        New-Item -ItemType Directory -Path $script:Boundary -Force | Out-Null
    }

    It 'пропускає власну підтеку межі, нічого не кидаючи' {
        $safe = Join-Path $script:Boundary 'cfe/src'
        { Assert-SafeWorkPath -Path $safe -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'тест' } |
            Should -Not -Throw
    }

    It 'кидає виняток на порожньому рядку — I2: саме цей випадок сьогодні мовчки стирає весь каталог продукту' {
        # Join-Path $Boundary '' повертає сам $Boundary — той-таки сценарій із
        # "sourcePath": "" у маніфесті, який реально видаляв весь каталог продукту
        # разом із негітованим v8project.local.yaml (I2 у фінальному ревʼю).
        $collapsedToBoundary = Join-Path $script:Boundary ''
        { Assert-SafeWorkPath -Path $collapsedToBoundary -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourceDir' } |
            Should -Throw
    }

    It 'кидає виняток на самій лише пробільній стрічці' {
        { Assert-SafeWorkPath -Path '   ' -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourceDir' } |
            Should -Throw
    }

    It 'кидає виняток, якщо шлях дорівнює самій межі (не власна підтека)' {
        { Assert-SafeWorkPath -Path $script:Boundary -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourceDir' } |
            Should -Throw '*не є підтекою*'
    }

    It 'кидає виняток саме через сегмент ".." — а не через збіг із перевіркою підтеки, яку цей самий вхід так само провалює' {
        # '*..*' тут не годиться: $escaping ОДНОЧАСНО провалює й перевірку підтеки (нормалізований
        # шлях виходить за $Boundary), і повідомлення про це теж містить '..' — воно ж
        # інтерпольоване з $Path. Тобто '*..*' збігся б, навіть якби перевірку сегмента ".."
        # узагалі прибрати з коду — тест не довів би, що спрацювала саме вона. '*містить
        # сегмент*' — фраза лише з повідомлення перевірки сегмента; повідомлення перевірки
        # підтеки ("не є підтекою") цього слова не несе, тож патерн дискримінує гілку.
        $escaping = Join-Path $script:Boundary '..\..\Windows'
        { Assert-SafeWorkPath -Path $escaping -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourceDir' } |
            Should -Throw '*містить сегмент*'
    }

    It 'кидає виняток, якщо шлях лежить поза межею навіть без ".."' {
        $outside = Join-Path $TestDrive 'not-the-product'
        { Assert-SafeWorkPath -Path $outside -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourceDir' } |
            Should -Throw '*не є підтекою*'
    }

    It 'повідомлення про помилку називає Description, щоб було видно, яке саме поле завинило' {
        { Assert-SafeWorkPath -Path '' -MustBeUnder $script:Boundary -RepoRoot $script:Boundary -Description 'sourcePath у маніфесті продукту XYZ' } |
            Should -Throw '*sourcePath у маніфесті продукту XYZ*'
    }
}

Describe 'Remove-KitDirectory (#34)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force }

    It 'видаляє дерево з read-only файлом у підтеці' {
        $d = Join-Path $TestDrive 'ro'
        New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
        $f = Join-Path $d 'sub/x.txt'
        Set-Content -LiteralPath $f -Value 'x'
        Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $true
        Remove-KitDirectory -Path $d
        Test-Path -LiteralPath $d | Should -BeFalse
    }
    It 'відсутня тека — тиша, не виняток' {
        { Remove-KitDirectory -Path (Join-Path $TestDrive 'nope') } | Should -Not -Throw
    }
    It 'шлях до файлу — виняток, файл цілий' {
        $f = Join-Path $TestDrive 'f.txt'; Set-Content -LiteralPath $f -Value 'x'
        { Remove-KitDirectory -Path $f } | Should -Throw '*не тека*'
        Test-Path -LiteralPath $f | Should -BeTrue
    }
    It 'тека з атрибутом ReadOnly (а не лише файл) — видаляється, як це робив Remove-Item -Force' {
        $d = Join-Path $TestDrive 'rodir'
        $sub = Join-Path $d 'sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'x.txt') -Value 'x'
        (Get-Item -LiteralPath $sub).Attributes = 'ReadOnly, Directory'
        Remove-KitDirectory -Path $d
        Test-Path -LiteralPath $d | Should -BeFalse
    }
    It 'зайнятий файл — рівно Attempts спроб (Attempts-1 повторів у Verbose) і виняток, тека ціла' {
        $d = Join-Path $TestDrive 'locked'; New-Item -ItemType Directory -Path $d | Out-Null
        $f = Join-Path $d 'x.txt'; Set-Content -LiteralPath $f -Value 'x'
        $h = [System.IO.File]::Open($f, 'Open', 'Read', 'None')
        $msgs = [System.Collections.Generic.List[string]]::new(); $threw = $false
        try {
            try { Remove-KitDirectory -Path $d -Attempts 3 -DelayMs 10 -Verbose 4>&1 | ForEach-Object { $msgs.Add([string]$_.Message) } }
            catch { $threw = $true }
        } finally { $h.Dispose() }
        $threw | Should -BeTrue
        @($msgs | Where-Object { $_ -like '*спроба*' }).Count | Should -Be 2
        Test-Path -LiteralPath $d | Should -BeTrue
    }
}

Describe 'Запобіжник #34: жодного Remove-Item -Recurse у коді kit' {
    # Межа виміру (не ширша за неї): ловиться Remove-Item і -Recurse в одному рядку. Рядок
    # продовження (бектік) і псевдоніми rm/ri/del тест не бачить — на момент написання таких
    # місць у tools/ немає (grep по 'Recurse').
    It 'tools/commands, tools/lib, tools/kit.ps1 — без Remove-Item з -Recurse поза коментарями' {
        $root = (Resolve-Path "$PSScriptRoot/..").Path
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'commands'), (Join-Path $root 'lib') -Filter '*.psm1' -File) +
                 @(Get-Item -LiteralPath (Join-Path $root 'kit.ps1'))
        $hits = foreach ($f in $files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
            $text = [regex]::Replace($text, '(?s)<#.*?#>', '')
            $n = 0
            foreach ($line in ($text -split "`n")) {
                $n++
                $code = $line.Trim()
                if ($code.StartsWith('#')) { continue }
                if ($code -match 'Remove-Item\b' -and $code -match '-Recurse\b') { "$($f.Name): $code" }
            }
        }
        @($hits) | Should -BeNullOrEmpty -Because 'рекурсивне видалення — лише Remove-KitDirectory (#34)'
    }
}

Describe 'Assert-SafeWorkPath — kit нічого не видаляє крізь посилання (П25)' {
    BeforeAll {
        # Ціль посилання лежить поза межею; у ній файл, вміст якого має пережити будь-який виклик.
        function script:New-OutsideTarget { param([string]$Name)
            $t = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $t 'keep.txt') -Value 'чужа ціль' -Encoding UTF8
            $t }
    }
    It 'junction на проміжному компоненті (під межею) — виняток, що називає компонент і не називає ціль' {
        $b = Join-Path $TestDrive 'ps-boundary'
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        $target = New-OutsideTarget 'ps-outside-target'
        New-Item -ItemType Junction -Path (Join-Path $b 'mid') -Target $target | Out-Null
        $err = $null
        try { Assert-SafeWorkPath -Path (Join-Path $b 'mid/inner') -MustBeUnder $b -RepoRoot $b -Description 'тест' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "*компонент шляху 'mid'*є посиланням*"
        $err | Should -Not -BeLike '*ps-outside-target*'
        (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'чужа ціль'
    }
    It 'сама ціль видалення — junction: виняток' {
        $b = Join-Path $TestDrive 'ps-boundary2'
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        $target = New-OutsideTarget 'ps-outside-target2'
        New-Item -ItemType Junction -Path (Join-Path $b 'lnk') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $b 'lnk') -MustBeUnder $b -RepoRoot $b -Description 'тест' } | Should -Throw '*є посиланням*'
    }
    It 'контроль: корінь репозиторію сам за junction (межа — його корінь) — видалення під ним дозволене' {
        $real = Join-Path $TestDrive 'ps-real-repo'
        New-Item -ItemType Directory -Path (Join-Path $real 'build/x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $real 'build/x/f.txt') -Value 'x' -Encoding UTF8
        $viaLink = Join-Path $TestDrive 'ps-repo-link'
        New-Item -ItemType Junction -Path $viaLink -Target $real | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $viaLink 'build/x') -MustBeUnder $viaLink -RepoRoot $viaLink -Description 'тест' } | Should -Not -Throw
        Remove-KitDirectory -Path (Join-Path $viaLink 'build/x')
        Join-Path $real 'build/x' | Should -Not -Exist
        Join-Path $real 'build' | Should -Exist
    }
}

Describe 'Assert-SafeWorkPath — корені власності: перевірка посилань іде від кореня репозиторію (П25)' {
    BeforeAll {
        function script:New-PsRepo { param([string]$Name)
            $r = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $r -Force | Out-Null
            $r }
        function script:New-PsTarget { param([string]$Name)
            $t = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $t 'keep.txt') -Value 'чужа ціль' -Encoding UTF8
            $t }
    }
    It 'контроль: repo\build — junction назовні (корінь власності) → видалення build/adopt/<ключ> дозволене, видалено лише вміст kit, сусіди в цілі цілі' {
        $repo = New-PsRepo 'own-ctl'
        $target = New-PsTarget 'own-ctl-target'
        New-Item -ItemType Directory -Path (Join-Path $target 'adopt/K') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'adopt/K/f.txt') -Value 'kit' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $target 'adopt/sibling.txt') -Value 'сусід' -Encoding UTF8
        New-Item -ItemType Junction -Path (Join-Path $repo 'build') -Target $target | Out-Null
        $wd = Join-Path $repo 'build/adopt/K'
        { Assert-SafeWorkPath -Path $wd -MustBeUnder (Join-Path $repo 'build/adopt') -RepoRoot $repo -OwnedRoot (Join-Path $repo 'build') -Description 'тест' } | Should -Not -Throw
        Remove-KitDirectory -Path $wd
        Join-Path $target 'adopt/K' | Should -Not -Exist
        Join-Path $target 'adopt/sibling.txt' | Should -Exist
        Join-Path $target 'keep.txt' | Should -Exist
    }
    It 'repo\build\adopt — junction (build справжній) → зупинка, ціль ціла' {
        $repo = New-PsRepo 'own-adopt'
        $target = New-PsTarget 'own-adopt-target'
        New-Item -ItemType Directory -Path (Join-Path $repo 'build') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $repo 'build/adopt') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $repo 'build/adopt/K') -MustBeUnder (Join-Path $repo 'build/adopt') -RepoRoot $repo -OwnedRoot (Join-Path $repo 'build') -Description 'тест' } |
            Should -Throw "*компонент шляху 'build?adopt' є посиланням*"
        (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'чужа ціль'
    }
    It 'компонент між коренем репо і build (теку воркспейсу) — junction → зупинка' {
        $repo = New-PsRepo 'own-ws'
        $target = New-PsTarget 'own-ws-target'
        New-Item -ItemType Directory -Path (Join-Path $target 'build') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $repo 'WS') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $repo 'WS/build/ib') -MustBeUnder (Join-Path $repo 'WS/build') -RepoRoot $repo -OwnedRoot (Join-Path $repo 'WS/build') -Description 'тест' } |
            Should -Throw "*компонент шляху 'WS' є посиланням*"
    }
    It 'виклик без -OwnedRoot: junction на repo\build → зупинка (посилань немає взагалі)' {
        $repo = New-PsRepo 'own-none'
        $target = New-PsTarget 'own-none-target'
        New-Item -ItemType Junction -Path (Join-Path $repo 'build') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $repo 'build/adopt/K') -MustBeUnder (Join-Path $repo 'build/adopt') -RepoRoot $repo -Description 'тест' } |
            Should -Throw "*компонент шляху 'build' є посиланням*"
    }
    It 'корінь власності <ws>\build — junction, база під ним (provision) → дозволено; junction теки набору без -OwnedRoot — зупинка' {
        $repo = New-PsRepo 'own-prov'
        $target = New-PsTarget 'own-prov-target'
        New-Item -ItemType Directory -Path (Join-Path $repo 'WS') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $repo 'WS/build') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $repo 'WS/build/ib') -MustBeUnder (Join-Path $repo 'WS/build') -RepoRoot $repo -OwnedRoot (Join-Path $repo 'WS/build') -Description 'тест' } | Should -Not -Throw
        New-Item -ItemType Junction -Path (Join-Path $repo 'WS/cfe') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $repo 'WS/cfe/src') -MustBeUnder (Join-Path $repo 'WS') -RepoRoot $repo -Description 'тест' } | Should -Throw '*є посиланням*'
    }
    It 'шлях поза репозиторієм перевіряється від -MustBeUnder: посилання на межі й вище — поза правилом, нижче межі — зупинка' {
        $repo = New-PsRepo 'own-out'
        $realExt = New-PsTarget 'own-out-real'
        New-Item -ItemType Directory -Path (Join-Path $realExt 'base') -Force | Out-Null
        $linkExt = Join-Path $TestDrive 'own-out-link'
        New-Item -ItemType Junction -Path $linkExt -Target $realExt | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $linkExt 'base/ib') -MustBeUnder (Join-Path $linkExt 'base') -RepoRoot $repo -Description 'тест' } | Should -Not -Throw
        $inner = New-PsTarget 'own-out-inner'
        New-Item -ItemType Junction -Path (Join-Path $realExt 'base/lnk') -Target $inner | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $linkExt 'base/lnk/ib') -MustBeUnder (Join-Path $linkExt 'base') -RepoRoot $repo -Description 'тест' } | Should -Throw "*компонент шляху 'lnk' є посиланням*"
    }
}

Describe 'Assert-SafeWorkPath — fail-closed: помилка читання атрибута компонента не дорівнює «посилання немає» (П25)' {
    It 'Get-KitComponentAttributes: ненаявний компонент — $null, а не виняток' {
        $r = & (Get-Module PathSafety) { Get-KitComponentAttributes -Path (Join-Path $args[0] 'нема') -Description 'тест' } $TestDrive
        $r | Should -BeNullOrEmpty
    }
    It 'Get-KitComponentAttributes: помилка читання (нульовий символ у шляху) — виняток, не $null' {
        { & (Get-Module PathSafety) { Get-KitComponentAttributes -Path ($args[0] + "\x`0y") -Description 'тест' } $TestDrive } |
            Should -Throw '*не вдалося перевірити компонент шляху*'
    }
    It 'Assert-SafeWorkPath не ковтає помилку перевірки: мок, що кидає, → виняток, а не «шлях безпечний»' {
        $b = Join-Path $TestDrive 'fc-boundary'
        New-Item -ItemType Directory -Path (Join-Path $b 'inner') -Force | Out-Null
        Mock -ModuleName PathSafety Get-KitComponentAttributes { throw 'збій читання' }
        { Assert-SafeWorkPath -Path (Join-Path $b 'inner/x') -MustBeUnder $b -RepoRoot $b -Description 'тест' } | Should -Throw '*збій читання*'
    }
}

Describe 'Remove-KitDirectory — знімається лише посилання, а не його ціль (П25, Minor)' {
    # Безпеку тут тримає поведінка .NET (Directory.Delete не заходить у reparse point), не код kit: тест її фіксує.
    It 'вкладений junction усередині видаленої теки: посилання зникає, файли в цілі цілі' {
        $d = Join-Path $TestDrive 'rm-nested'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $target = Join-Path $TestDrive 'rm-nested-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'чужа ціль' -Encoding UTF8
        New-Item -ItemType Junction -Path (Join-Path $d 'lnk') -Target $target | Out-Null
        Remove-KitDirectory -Path $d
        $d | Should -Not -Exist
        (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'чужа ціль'
    }
}

Describe 'Get-KitDirectoryEntriesNoLinks — перерахунок для зняття ReadOnly не заходить у посилання (П26, M-1)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force }

    It 'файл за junction не перелічено, саме посилання теж; звичайні вкладені файли — так' {
        $d = Join-Path $TestDrive 'enum-link'
        New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'sub/own.txt') -Value 'x'
        $target = Join-Path $TestDrive 'enum-link-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'beyond.txt') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $d 'lnk') -Target $target | Out-Null
        $names = @(Get-KitDirectoryEntriesNoLinks -Path $d | ForEach-Object { Split-Path $_ -Leaf })
        $names | Should -Contain 'own.txt'
        $names | Should -Not -Contain 'beyond.txt' -Because 'вміст цілі посилання не наш'
        $names | Should -Not -Contain 'lnk'
    }

    It 'прихований ReadOnly-файл перелічено (умовчання AttributesToSkip Hidden|System його б пропустило)' {
        $d = Join-Path $TestDrive 'enum-hidden'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'hidden-ro.txt'
        Set-Content -LiteralPath $f -Value 'x'
        [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::ReadOnly)
        try {
            @(Get-KitDirectoryEntriesNoLinks -Path $d | ForEach-Object { Split-Path $_ -Leaf }) | Should -Contain 'hidden-ro.txt'
        } finally { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal) }
    }
}
