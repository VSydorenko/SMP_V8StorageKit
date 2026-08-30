BeforeAll {
    Import-Module "$PSScriptRoot/../lib/Authors.psm1" -Force
    $script:MapFile = Join-Path $TestDrive 'AUTHORS'
    @(
        "Перший Тестовий=First Testovych <first.testovych@example.com>"
        "Другий Тестовий (nick2)=nick2 <nick2@example.com>"
        "# коментар, який треба пропустити"
        ""
    ) | Set-Content -LiteralPath $script:MapFile -Encoding UTF8
}

Describe 'Read-AuthorMap' {
    It 'читає записи у форматі Ім''я=Name <email>' {
        $map = Read-AuthorMap -Path $script:MapFile
        $map['Перший Тестовий'].Name  | Should -Be 'First Testovych'
        $map['Перший Тестовий'].Email | Should -Be 'first.testovych@example.com'
    }

    It 'витримує дужки в імені користувача сховища' {
        $map = Read-AuthorMap -Path $script:MapFile
        $map['Другий Тестовий (nick2)'].Name | Should -Be 'nick2'
    }

    It 'ігнорує коментарі й порожні рядки' {
        (Read-AuthorMap -Path $script:MapFile).Count | Should -Be 2
    }
}

Describe 'Read-AuthorMap: дублікат ключа' {
    It 'кидає виняток, коли той самий логін сховища має дві різні git-особи' {
        # Реалістичний сценарій — AUTHORS-файли двох продуктів, злиті вручну при
        # repo-migration (skills/repo-migration/SKILL.md, розділ 6): один і той самий
        # логін сховища міг у різних продуктах отримати різне ім'я/пошту. Мовчазне
        # $map[$key] = ... лишило б чинним лише останній рядок — версії цього
        # користувача комітились би під випадковим із двох авторів.
        $dupFile = Join-Path $TestDrive 'AUTHORS-conflict'
        @(
            'дубльований=Перша Особа <first@example.com>'
            'дубльований=Друга Особа <second@example.com>'
        ) | Set-Content -LiteralPath $dupFile -Encoding UTF8

        $err = { Read-AuthorMap -Path $dupFile } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'дубльований'
        $err.Exception.Message | Should -Match 'Перша Особа'
        $err.Exception.Message | Should -Match 'first@example\.com'
        $err.Exception.Message | Should -Match 'Друга Особа'
        $err.Exception.Message | Should -Match 'second@example\.com'
        $err.Exception.Message | Should -Match ([regex]::Escape($dupFile))
    }

    It 'не кидає виняток, коли дублікат рядка для ключа буквально той самий (злиття унікальних рядків)' {
        # repo-migration радить обʼєднувати AUTHORS "унікальними рядками" — якщо той
        # самий рядок трапився в обох файлах-джерелах, це не конфлікт, а звичайний
        # дубль після злиття.
        $sameFile = Join-Path $TestDrive 'AUTHORS-same'
        @(
            'однаковий=Та Сама Особа <same@example.com>'
            'однаковий=Та Сама Особа <same@example.com>'
        ) | Set-Content -LiteralPath $sameFile -Encoding UTF8

        { Read-AuthorMap -Path $sameFile } | Should -Not -Throw
        (Read-AuthorMap -Path $sameFile)['однаковий'].Email | Should -Be 'same@example.com'
    }
}

Describe 'Read-AuthorMap: злиті рядки без завершального порожнього рядка' {
    It 'кидає виняток, коли останній рядок одного AUTHORS зливається з першим рядком іншого' {
        # Реальний випадок: обидва AUTHORS, задіяні в пілотній міграції (SMP_BankExchange,
        # SMP_SimplyConnect), закінчуються без завершального порожнього рядка. Якщо їх
        # конкатенувати (repo-migration/SKILL.md, розділ 7, "обʼєднайте вручну"), останній
        # рядок першого файлу й перший рядок другого стають ОДНИМ рядком — рядок нижче
        # відтворює точні рядки з практики.
        $fusedFile = Join-Path $TestDrive 'AUTHORS-fused'
        Set-Content -LiteralPath $fusedFile -Encoding UTF8 -NoNewline -Value (
            'Володимир Прудніков=PrudnikovV <Prudnikovv@ukr.net>' +
            'AlpenPharma_UNF_work=PROBE PLACEHOLDER <probe@local>'
        )

        $err = { Read-AuthorMap -Path $fusedFile } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'Володимир Прудніков'
        $err.Exception.Message | Should -Match 'PrudnikovV <Prudnikovv@ukr\.net>AlpenPharma_UNF_work=PROBE PLACEHOLDER'
        $err.Exception.Message | Should -Match ([regex]::Escape($fusedFile))
        $err.Exception.Message | Should -Match 'AUTHORS'
        $err.Exception.Message | Should -Match 'порожн'
    }

    It 'далі читає звичайні записи — з дужками й кількома словами в імені — без хибних спрацювань' {
        # Guard не повинен чіплятись за легітимні записи. Перевірено фактично на
        # R:\github\SMP_BankExchange\AUTHORS і
        # R:\github\SMP_SimplyConnect\SimplyConnect_SMB\AUTHORS: жодне справжнє імʼя не
        # містить <, > чи =.
        $realisticFile = Join-Path $TestDrive 'AUTHORS-realistic'
        @(
            "Володимир Сидоренко=Volodymyr Sydorenko <v.m.sydorenko@gmail.com>"
            "Василь Прокоф'єв=evil beaver <va.prokophev@gmail.com>"
            "Олександр (alexsvlight)=alexsvlight <alexsv2012@gmail.com>"
        ) | Set-Content -LiteralPath $realisticFile -Encoding UTF8

        $map = Read-AuthorMap -Path $realisticFile
        $map.Count | Should -Be 3
        $map['Володимир Сидоренко'].Name | Should -Be 'Volodymyr Sydorenko'
        $map["Василь Прокоф'єв"].Name | Should -Be 'evil beaver'
        $map['Олександр (alexsvlight)'].Name | Should -Be 'alexsvlight'
    }
}

Describe 'Resolve-Author' {
    It 'повертає git-автора для відомого користувача' {
        $map = Read-AuthorMap -Path $script:MapFile
        (Resolve-Author -Map $map -StorageUser 'Перший Тестовий').Email |
            Should -Be 'first.testovych@example.com'
    }

    It 'кидає виняток на невідомому користувачі' {
        $map = Read-AuthorMap -Path $script:MapFile
        { Resolve-Author -Map $map -StorageUser 'Хтось Новий' } | Should -Throw '*AUTHORS*'
    }

    It 'кидає виняток з поясненням причини, а не звинувачує AUTHORS, коли автор порожній' {
        # Порожній User — ознака обрізаного/пошкодженого звіту сховища (Task 2), а не
        # "автора немає в AUTHORS". Це різні проблеми з різними виправленнями, тому
        # перевіряємо саме зміст повідомлення, а не сам факт винятку.
        $map = Read-AuthorMap -Path $script:MapFile
        $err = { Resolve-Author -Map $map -StorageUser '' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'пошкодж'
        $err.Exception.Message | Should -Not -Match 'AUTHORS'
    }
}

Describe 'Get-UnknownAuthors' {
    It 'повертає лише тих, кого немає в мапі, без повторів' {
        $map = Read-AuthorMap -Path $script:MapFile
        Get-UnknownAuthors -Map $map -StorageUsers @(
            'Перший Тестовий', 'Хтось Новий', 'Хтось Новий') |
            Should -Be @('Хтось Новий')
    }

    It 'повертає порожній масив, а не $null, коли всі автори відомі' {
        # Set-StrictMode тут відтворює умову виклику з боку Task 5 (storage-sync.ps1),
        # який працює під Set-StrictMode -Version Latest: під ним $null.Count кидає
        # виняток, тоді як без strict mode PowerShell тихо повертає 0. Тест ловить
        # регресію, якщо унарну кому перед @(...) у реалізації прибрати.
        Set-StrictMode -Version Latest
        $map = Read-AuthorMap -Path $script:MapFile
        $unknown = Get-UnknownAuthors -Map $map -StorageUsers @('Перший Тестовий')
        { $unknown.Count } | Should -Not -Throw
        $unknown.Count | Should -Be 0
    }

    It 'позначає порожній запис автора зрозумілим повідомленням замість порожнього рядка' {
        # Порожній StorageUser не повинен ні впасти на байндингу параметра, ні мовчки
        # зникнути в результаті як невидимий порожній рядок — оператор має побачити
        # причину прямо в прев'ю-виводі storage-sync.ps1.
        $map = Read-AuthorMap -Path $script:MapFile
        $unknown = Get-UnknownAuthors -Map $map -StorageUsers @('Перший Тестовий', '')
        $unknown.Count | Should -Be 1
        $unknown[0] | Should -Not -BeNullOrEmpty
        $unknown[0] | Should -Match 'пошкодж'
    }
}
