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
}
