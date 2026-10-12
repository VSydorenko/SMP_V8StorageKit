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
        { Assert-SafeWorkPath -Path $safe -MustBeUnder $script:Boundary -Description 'тест' } |
            Should -Not -Throw
    }

    It 'кидає виняток на порожньому рядку — I2: саме цей випадок сьогодні мовчки стирає весь каталог продукту' {
        # Join-Path $Boundary '' повертає сам $Boundary — той-таки сценарій із
        # "sourcePath": "" у storage.json, який реально видаляв весь каталог продукту
        # разом із негітованим v8project.local.yaml (I2 у фінальному ревʼю).
        $collapsedToBoundary = Join-Path $script:Boundary ''
        { Assert-SafeWorkPath -Path $collapsedToBoundary -MustBeUnder $script:Boundary -Description 'sourceDir' } |
            Should -Throw
    }

    It 'кидає виняток на самій лише пробільній стрічці' {
        { Assert-SafeWorkPath -Path '   ' -MustBeUnder $script:Boundary -Description 'sourceDir' } |
            Should -Throw
    }

    It 'кидає виняток, якщо шлях дорівнює самій межі (не власна підтека)' {
        { Assert-SafeWorkPath -Path $script:Boundary -MustBeUnder $script:Boundary -Description 'sourceDir' } |
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
        { Assert-SafeWorkPath -Path $escaping -MustBeUnder $script:Boundary -Description 'sourceDir' } |
            Should -Throw '*містить сегмент*'
    }

    It 'кидає виняток, якщо шлях лежить поза межею навіть без ".."' {
        $outside = Join-Path $TestDrive 'not-the-product'
        { Assert-SafeWorkPath -Path $outside -MustBeUnder $script:Boundary -Description 'sourceDir' } |
            Should -Throw '*не є підтекою*'
    }

    It 'повідомлення про помилку називає Description, щоб було видно, яке саме поле завинило' {
        { Assert-SafeWorkPath -Path '' -MustBeUnder $script:Boundary -Description 'sourcePath у storage.json продукту XYZ' } |
            Should -Throw '*sourcePath у storage.json продукту XYZ*'
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
        try { Assert-SafeWorkPath -Path (Join-Path $b 'mid/inner') -MustBeUnder $b -Description 'тест' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "*компонент шляху 'mid'*є посиланням*"
        $err | Should -Not -BeLike '*ps-outside-target*'
        (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'чужа ціль'
    }
    It 'сама ціль видалення — junction: виняток' {
        $b = Join-Path $TestDrive 'ps-boundary2'
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        $target = New-OutsideTarget 'ps-outside-target2'
        New-Item -ItemType Junction -Path (Join-Path $b 'lnk') -Target $target | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $b 'lnk') -MustBeUnder $b -Description 'тест' } | Should -Throw '*є посиланням*'
    }
    It 'контроль: корінь репозиторію сам за junction (межа — його корінь) — видалення під ним дозволене' {
        $real = Join-Path $TestDrive 'ps-real-repo'
        New-Item -ItemType Directory -Path (Join-Path $real 'build/x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $real 'build/x/f.txt') -Value 'x' -Encoding UTF8
        $viaLink = Join-Path $TestDrive 'ps-repo-link'
        New-Item -ItemType Junction -Path $viaLink -Target $real | Out-Null
        { Assert-SafeWorkPath -Path (Join-Path $viaLink 'build/x') -MustBeUnder $viaLink -Description 'тест' } | Should -Not -Throw
        Remove-KitDirectory -Path (Join-Path $viaLink 'build/x')
        Join-Path $real 'build/x' | Should -Not -Exist
        Join-Path $real 'build' | Should -Exist
    }
}
