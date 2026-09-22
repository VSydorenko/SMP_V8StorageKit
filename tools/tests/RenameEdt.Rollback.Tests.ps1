#Requires -Version 7
<#
Task 8 ("Швидкість набору тестів"): цей файл — друга половина колишнього
RenameEdt.Tests.ps1 — лише Context 'Step 3а — запобіжник політики тексту' (запобіжник
Test-GitTextPolicy на -TargetRoot, відкіт до git mv при застарілій .gitattributes gitsync).
Основна маса першого Describe (16 It, коміт перейменування) лишилась у
RenameEdt.Commit.Tests.ps1 — бриф задачі дозволяє цей безпечний поділ замість поділу за
темою "відкіт/запобіжники" на рівні кожного It, коли межа за темою не читається однозначно.
Спільний BeforeAll — той самий fixtures/RenameEdtSetup.ps1, що й у RenameEdt.Commit.Tests.ps1.
#>
Describe 'kit rename-edt — коміт перейменування EDT -> Designer (§9.2, властивість безпеки)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/RenameEdtSetup.ps1') }

    Context 'Step 3а — запобіжник політики тексту (Test-GitTextPolicy на -TargetRoot)' {
        It 'застаріла gitsync .gitattributes (лише *.bin/*.axdt/*.addin binary) — зупинка ДО git mv, жоден файл не переміщено' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'stale-attrs')
            Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value @('*.bin binary', '*.axdt binary', '*.addin binary') -Encoding ascii
            Invoke-TestGit -Repo $repo -GitArgs @('add', '.gitattributes') | Out-Null
            Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'застаріла .gitattributes gitsync') | Out-Null
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null
            $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*text*'

            (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
            (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist
        }

        It 'сучасна .gitattributes (-text на TargetRoot, templates/gitattributes) — проходить' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'modern-attrs') -WithGitattributes
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src' | Out-Null

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }
}
