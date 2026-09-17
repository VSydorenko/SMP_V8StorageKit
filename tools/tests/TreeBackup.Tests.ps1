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
