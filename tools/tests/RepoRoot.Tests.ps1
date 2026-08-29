#Requires -Version 7
BeforeAll {
    Import-Module "$PSScriptRoot/../lib/RepoRoot.psm1" -Force
}

Describe 'Resolve-V8RepoRoot' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("v8kit-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'повертає абсолютний шлях для кореня з текою .git' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') | Out-Null
        Resolve-V8RepoRoot -Path $script:tmp | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'приймає .git-файл (git worktree)' {
        Set-Content -LiteralPath (Join-Path $script:tmp '.git') -Value 'gitdir: ../somewhere'
        Resolve-V8RepoRoot -Path $script:tmp | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'розвʼязує відносний шлях відносно поточної теки' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') | Out-Null
        Push-Location $script:tmp
        try { Resolve-V8RepoRoot -Path '.' | Should -Be (Resolve-Path $script:tmp).Path }
        finally { Pop-Location }
    }

    It 'кидає виняток на теці без .git' {
        { Resolve-V8RepoRoot -Path $script:tmp } | Should -Throw '*не є коренем git-репозиторію*'
    }

    It 'кидає виняток із зрозумілим повідомленням на неіснуючому шляху' {
        { Resolve-V8RepoRoot -Path (Join-Path $script:tmp 'нема') } | Should -Throw '*не існує*'
    }

    It 'кидає виняток, коли шлях указує на файл, а не на теку' {
        $file = Join-Path $script:tmp 'file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        { Resolve-V8RepoRoot -Path $file } | Should -Throw '*не є коренем git-репозиторію*'
    }
}

Describe 'Скрипти відмовляють на не-git RepoRoot' {
    BeforeAll {
        # Дочірній скрипт запускається окремим процесом pwsh (той самий підхід, що й
        # у StorageSync.Tests.ps1/ModuleImportOrder.Tests.ps1), а виняток Resolve-V8RepoRoot
        # ловиться через $out -Match, а не напряму — тож текст мусить пережити межу
        # процесу побайтово. Дві незалежні пастки цієї машини псують його інакше:
        #
        # 1) Консольний кодпейдж тут — CP866 (DOS Cyrillic), у якому немає українських
        #    літер і/ї/є/ґ. Повідомлення містить "і" ("репозиторію"): без явного UTF-8
        #    по обидва боки межі дочірній pwsh губить її під час кодування свого стріму
        #    помилок ще ДО передачі (best-fit fallback у "?") — перевірено побайтовим
        #    дампом, це не лише відображення.
        # 2) Стандартний хост pwsh форматує неперехоплений виняток під ширину консолі й
        #    переносить рядок посередині повідомлення — у випробуваннях символи "коренем"
        #    і "git-репозиторію" опинялись на різних рядках, розділені "\n" замість
        #    пробілу, і -Match з пробілом між ними не спрацьовував. Це залежить від
        #    довжини шляху -RepoRoot (System temp + GUID), тож не завжди відтворюється.
        #
        # Обгортка нижче розв'язує обидва: примусово перемикає Console.OutputEncoding
        # дочірнього процесу на UTF-8 (сам цільовий скрипт лишається недоторканим) і сама
        # ловить виняток, друкуючи $_.Exception.Message одним сирим рядком через
        # Console.Error.WriteLine — в обхід форматування/переносу рядків хоста. Той самий
        # UTF-8 виставляємо і з боку батьківського процесу, що декодує $out. Run-Tests.ps1
        # прогонає весь набір в одній сесії pwsh, тож цю зміну кодування батьківського
        # процесу відновлюємо в AfterAll нижче — інакше вона просочилась би в наступні
        # *.Tests.ps1 того самого прогону.
        $script:PrevOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        $script:Utf8Wrapper = Join-Path $TestDrive 'utf8-wrapper.ps1'
        Set-Content -LiteralPath $script:Utf8Wrapper -Encoding UTF8 -Value @(
            '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'
            '$rest = $args[1..($args.Length-1)]'
            'try {'
            '    & $args[0] @rest'
            '    exit $LASTEXITCODE'
            '} catch {'
            '    [Console]::Error.WriteLine($_.Exception.Message)'
            '    exit 1'
            '}'
        )
    }

    AfterAll {
        [Console]::OutputEncoding = $script:PrevOutputEncoding
    }

    It '<name> зупиняється до будь-якої роботи' -ForEach @(
        @{ name = 'storage-sync.ps1'; extra = @('-Product', 'X') }
        @{ name = 'dump-config.ps1'; extra = @('-Product', 'X') }
        @{ name = 'load-ext.ps1';    extra = @('-Product', 'X') }
        @{ name = 'build.ps1';       extra = @() }
    ) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v8kit-norepo-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $script = Resolve-Path "$PSScriptRoot/../$name"
            $out = & pwsh -NoProfile -File $script:Utf8Wrapper $script @extra -RepoRoot $tmp 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0
            $out | Should -Match 'не є коренем git-репозиторію'
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
}
