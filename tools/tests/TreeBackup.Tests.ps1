#Requires -Version 7
Describe 'TreeBackup.psm1 — знімок незакоміченого перед перезаписом дерева' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeBackup.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'невідстежувані файли потрапляють у перелік поштучно, а не однією текою' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dirty')
        $dir  = Join-Path $repo 'Alpha_SMB/cfe/src/Nova'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir "f$_.xml") -Value "x$_" -Encoding UTF8 }
        $rec = @(Get-KitDirtyRecords -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src')
        $rec.Count | Should -Be 3
    }

    It 'копія зберігає структуру відносно кореня джерела' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'copy')
        $dir  = Join-Path $repo 'Alpha_SMB/cfe/src/Nova'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'f.xml') -Value 'x' -Encoding UTF8
        $rec = @(Get-KitDirtyRecords -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src')
        $dst = Join-Path $TestDrive 'backup'
        Backup-KitDirtyFiles -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -Records $rec -BackupRoot $dst -MustBeUnder $TestDrive | Out-Null
        Join-Path $dst 'Nova/f.xml' | Should -Exist
    }

    It 'порожній перелік — $null і жодного звернення до диска' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'clean')
        $dst  = Join-Path $TestDrive 'backup-none'
        Backup-KitDirtyFiles -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -Records @() -BackupRoot $dst -MustBeUnder $TestDrive |
            Should -BeNullOrEmpty
        $dst | Should -Not -Exist
    }

    It 'застейджена правка, повернута на диску до HEAD (MM) — у копії є ОБИДВІ версії, і застейджена читається саме як застейджений вміст' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'staged-mm')
        $relFile = 'Alpha_SMB/cfe/src/Configuration.xml'
        $file = Join-Path $repo $relFile
        $headContent = Get-Content -LiteralPath $file -Raw

        # Дефект: git add застейджує правку, тоді робочу копію повертають НАПРЯМУ
        # (Set-Content, не checkout/restore — так само сталося б і випадково, редактором
        # чи скриптом ззовні) до HEAD-версії. git status тоді показує MM: на диску
        # HEAD-версія, застейджена правка живе лише в індексі (перевірено живим git:
        # git cat-file blob :$relFile віддає застейджений вміст, коли на диску вже
        # HEAD-версія).
        Set-Content -LiteralPath $file -Value 'СТЕЙДЖ: агентська правка, якої вже нема на диску' -Encoding UTF8 -NoNewline
        git -C $repo add -- $relFile | Out-Null
        Set-Content -LiteralPath $file -Value $headContent -Encoding UTF8 -NoNewline

        $rec = @(Get-KitDirtyRecords -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src')
        $rec.Count | Should -Be 1
        $rec[0].Status | Should -Be 'MM'

        $dst = Join-Path $TestDrive 'backup-staged-mm'
        Backup-KitDirtyFiles -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -Records $rec -BackupRoot $dst -MustBeUnder $TestDrive | Out-Null

        (Get-Content -LiteralPath (Join-Path $dst 'Configuration.xml') -Raw) |
            Should -Be $headContent -Because 'копія з диска — це та сама HEAD-версія, що й лежала на диску просто зараз'
        (Join-Path $dst 'index/Configuration.xml') |
            Should -Exist -Because 'застейджена версія існує ЛИШЕ в індексі — без окремої копії вона зникла б безслідно'
        (Get-Content -LiteralPath (Join-Path $dst 'index/Configuration.xml') -Raw) |
            Should -Be 'СТЕЙДЖ: агентська правка, якої вже нема на диску' -Because 'копія з index/ мусить бути застейдженим вмістом, а не тим самим, що й з диска'
    }
}

Describe 'Get-KitInvisibleWork -WholeTreeDerived — прямий юніт-тест (фікс-раунд 1, Minor)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeBackup.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }
    It 'без перемикача ігнорований файл дає ignored; з перемикачем ignored не обчислюється, а flagged, nested-repo і link — так' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'wtd') -WithHooks
        $src = Join-Path $repo 'Alpha_SMB/cfe/src'
        Add-Content -LiteralPath (Join-Path $repo '.git/info/exclude') -Value 'Alpha_SMB/cfe/src/mine.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $src 'mine.txt') -Value 'робота' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $src 'Configuration.xml') -Value 'правка' -Encoding UTF8
        git -C $repo update-index --assume-unchanged Alpha_SMB/cfe/src/Configuration.xml
        $nest = Join-Path $src 'nest'
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        git -C $nest init -q
        $target = Join-Path $TestDrive 'wtd-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $src 'lnk') -Target $target | Out-Null

        $kinds = { param($r) @($r | ForEach-Object { $_.Kind } | Sort-Object -Unique) -join ',' }
        & $kinds @(Get-KitInvisibleWork -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src') | Should -Be 'flagged,ignored,link,nested-repo'
        & $kinds @(Get-KitInvisibleWork -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -WholeTreeDerived) | Should -Be 'flagged,link,nested-repo'
    }
}

Describe 'Get-KitDirtyRecords і Get-KitInvisibleWork — межі набору й невидима робота (спека §10.2 П24)' {
    # Перенесено з UnicaStep.Tests.ps1, де їх тримав критерій вирівнювання (його знято, спека 2026-11-19 §3.1):
    # самі функції досі стережуть canon, adopt і dump від втрати роботи агента.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/PathSafety.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeBackup.psm1").Path -Force
        function script:G { param([string]$R) & git -C $R @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $args -> $LASTEXITCODE" } }
        function script:New-Mini2 {
            $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $r 'Ws/cf/src') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $r 'Ws/cf2/src') -Force | Out-Null
            G $r init -q; G $r config user.email 't@example.invalid'; G $r config user.name T
            G $r config commit.gpgsign false; G $r config core.autocrlf false
            G $r symbolic-ref HEAD refs/heads/main
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'start' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $r 'Ws/cf2/src/a.txt') -Value 'start' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $r '.gitignore') -Value "ConfigDumpInfo.xml`nDumpFilesIndex.txt`n**/Ext/ParentConfigurations/`n" -Encoding UTF8
            G $r add -A; G $r commit -q -m first
            $r
        }
    }
    It 'змінений, застейджений і видалений відстежуваний файл — у переліку; брудне в сусідньому наборі з префіксом (cf2) — ні' {
        $r = New-Mini2
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf2/src/a.txt') -Value 'сусід' -Encoding UTF8
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка' -Encoding UTF8
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 1
        G $r add Ws/cf/src/a.txt
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 1
        Remove-Item -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Force
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 1
    }
    It 'файл агента під .git/info/exclude — status його не бачить, Get-KitInvisibleWork дає ignored' {
        $r = New-Mini2
        Add-Content -LiteralPath (Join-Path $r '.git/info/exclude') -Value 'Ws/cf/src/mine.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/mine.txt') -Value 'робота' -Encoding UTF8
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0 -Because 'status цього файлу не бачить'
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        $w | Should -HaveCount 1
        $w[0].Kind | Should -Be 'ignored'
        $w[0].Path | Should -Be 'Ws/cf/src/mine.txt'
    }
    It 'контроль: ConfigDumpInfo.xml, DumpFilesIndex.txt і .cf в Ext/ParentConfigurations — похідне, невидимої роботи немає' {
        $r = New-Mini2
        New-Item -ItemType Directory -Path (Join-Path $r 'Ws/cf/src/Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/Ext/ParentConfigurations/V.cf') -Value 'cf' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/ConfigDumpInfo.xml') -Value '<x/>' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/DumpFilesIndex.txt') -Value 'i' -Encoding UTF8
        git -C $r ls-files --others --ignored --exclude-standard -- Ws/cf/src | Should -HaveCount 3 -Because 'контроль має спиратись на справді ігноровані файли'
        @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0
    }
    It '<Flag> на зміненому файлі: status мовчить, Get-KitInvisibleWork дає flagged' -ForEach @(
        @{ Flag = 'assume-unchanged' }
        @{ Flag = 'skip-worktree' }
    ) {
        $r = New-Mini2
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'правка агента' -Encoding UTF8
        G $r update-index "--$Flag" Ws/cf/src/a.txt
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0 -Because 'status цього не бачить'
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        $w | Should -HaveCount 1
        $w[0].Kind | Should -Be 'flagged'
        $w[0].Path | Should -Be 'Ws/cf/src/a.txt'
    }
    It 'gitlink (підмодуль) і вкладений git-репозиторій під набором — невидима робота' {
        $r = New-Mini2
        $sha = (git -C $r rev-parse HEAD).Trim()
        G $r update-index --add --cacheinfo "160000,$sha,Ws/cf/src/sub"
        $nest = Join-Path $r 'Ws/cf/src/nest'
        New-Item -ItemType Directory -Path $nest -Force | Out-Null
        & git -C $nest init -q
        $w = @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src')
        @($w | Where-Object { $_.Kind -eq 'gitlink' -and $_.Path -eq 'Ws/cf/src/sub' }) | Should -HaveCount 1
        @($w | Where-Object { $_.Kind -eq 'nested-repo' -and $_.Path -eq 'Ws/cf/src/nest' }) | Should -HaveCount 1
    }
    It 'збій git — виняток, не «чисто»' {
        $notRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        { Get-KitInvisibleWork -RepoRoot $notRepo -RepoPath 'Ws/cf/src' } | Should -Throw
    }
    It 'контроль меж: конфлікт злиття (тег M у ls-files -v) — не прапорець; status дає UU' {
        $r = New-Mini2
        G $r checkout -q -b other
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'в other' -Encoding UTF8
        G $r commit -q -a -m o
        G $r checkout -q main
        Set-Content -LiteralPath (Join-Path $r 'Ws/cf/src/a.txt') -Value 'в main' -Encoding UTF8
        G $r commit -q -a -m m
        & git -C $r merge other 2>&1 | Out-Null
        (git -C $r status --porcelain -- Ws/cf/src) | Should -BeLike 'UU*'
        @(Get-KitInvisibleWork -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -HaveCount 0
        @(Get-KitDirtyRecords -RepoRoot $r -RepoPath 'Ws/cf/src') | Should -Not -HaveCount 0
    }
}
