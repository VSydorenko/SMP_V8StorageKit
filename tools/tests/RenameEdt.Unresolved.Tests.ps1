#Requires -Version 7
<#
Task 8 ("Швидкість набору тестів"): третій Describe колишнього RenameEdt.Tests.ps1,
перенесений СЮДИ ЦІЛКОМ разом із власним BeforeAll (не потребує fixtures/RenameEdtSetup.ps1 —
підготовка тут своя, окремі Invoke-TestGit2/Invoke-RenameEdt2/$script:Kit2, аби не
перетинатись зі станом інших файлів набору).
#>
Describe 'kit rename-edt — межа Unmapped/Unresolved: Unresolved ніколи не видаляється (додаток координатора до раунду 1)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit2 = Copy-KitTools -Root (Join-Path $TestDrive 'kit2')

        function script:Invoke-TestGit2 {
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
            $out = & git -C $Repo @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
            $out
        }

        function script:Invoke-RenameEdt2 {
            param([Parameter(Mandatory)][string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit2 rename-edt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'Unresolved (розширення макета без доказу) НЕ видаляється й НЕ перейменовується під -Apply — лишається на диску як є' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unresolved-kept') -WithGitattributes
        # Один мапований файл (щоб команда мала що робити й дійшла до коміту) + один
        # Unresolved (Template.scheme — доказу немає в жоден бік, task-3-findings-round1.md
        # + пряме уточнення координатора).
        $mappedDir = Join-Path $repo 'Alpha_SMB/src/Catalogs/Об1'
        New-Item -ItemType Directory -Force -Path $mappedDir | Out-Null
        Set-Content -LiteralPath (Join-Path $mappedDir 'Об1.mdo') -Value 'x' -Encoding UTF8
        $unresolvedDir = Join-Path $repo 'Alpha_SMB/src/Reports/Об2/Templates/Мак1'
        New-Item -ItemType Directory -Force -Path $unresolvedDir | Out-Null
        Set-Content -LiteralPath (Join-Path $unresolvedDir 'Template.scheme') -Value 'y' -Encoding UTF8
        Invoke-TestGit2 -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit2 -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: мапований об''єкт + нехарактеризований макет') | Out-Null

        $r = Invoke-RenameEdt2 -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike "*не з'ясовано*"
        $r.Output | Should -BeLike '*Template.scheme*'

        # Властивість, яку вимагав координатор: перевіряти НАЯВНІСТЬ ФАЙЛА НА ДИСКУ, не текст
        # повідомлення.
        (Join-Path $unresolvedDir 'Template.scheme') | Should -Exist -Because 'Unresolved НІКОЛИ не видаляється — лишається на місці'
        (Join-Path $repo 'Alpha_SMB/cfe/src/Reports/Об2/Templates/Мак1/Template.scheme') | Should -Not -Exist -Because 'Unresolved також НЕ перейменовується — не в Moves'
        (Join-Path $repo 'Alpha_SMB/cfe/src/Catalogs/Об1.xml') | Should -Exist -Because 'мапований файл поруч мав перейменуватись нормально'

        # git теж бачить Template.scheme як і раніше — не видалено з індексу.
        (Invoke-TestGit2 -Repo $repo -GitArgs @('ls-files', '--', 'Alpha_SMB/src/Reports/Об2/Templates/Мак1/Template.scheme')) | Should -Not -BeNullOrEmpty
    }
}
