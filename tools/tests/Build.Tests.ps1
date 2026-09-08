#Requires -Version 7
Describe 'kit build — виявлення й збір артефактів без платформи (§12)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Build { param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out } }
        $script:Ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'tools'     = @{ Sets = @(@{ Name = 'processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) }
        }
        # Два самостійних EXTENSION-воркспейси — для теста на розділення (-Workspace не
        # мусить чіпати артефакти сусіднього воркспейсу, Q1 звіту задачі 3).
        $script:WsTwo = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base_beta'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB';  Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
    }

    It 'знаходить обробки за типом source-set, а не за ім''ям теки epf' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'discover') -Workspaces $script:Ws -WithHooks
        foreach ($n in 'Обробка_А', 'Обробка_Б') {
            Set-Content -LiteralPath (Join-Path $repo "tools/src/$n.xml") -Value '<x/>' -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $repo "tools/src/$n") -Force | Out-Null
        }
        $r = Invoke-Build -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*Обробка_А.epf*Обробка_Б.epf*'
        $r.Output | Should -BeLike '*Alpha_SMB*operation=make*'
        $r.Output | Should -BeLike '*-Apply*'
    }

    It '-Apply без платформи: артефакти з <воркспейс>/build/artifacts збираються в build/artifacts кореня' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'collect') -Workspaces ([ordered]@{ 'Alpha_SMB' = $script:Ws['Alpha_SMB'] }) -WithHooks
        New-Item -ItemType Directory -Path (Join-Path $repo 'Alpha_SMB/build/artifacts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/build/artifacts/Alpha_SMB.cfe') -Value 'cfe' -Encoding ascii
        $r = Invoke-Build -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'build/artifacts/Alpha_SMB.cfe' | Should -Exist
        $r.Output | Should -BeLike '*Alpha_SMB.cfe*'
    }

    It 'без жодних обробок і без артефактів — код 0 і пояснення, як зібрати .cfe' {
        $r = Invoke-Build -Repo (New-KitFakeRepo -Root (Join-Path $TestDrive 'nothing') -WithHooks) -More @('-Apply')
        $r.ExitCode | Should -Be 0
        # 'build*artifacts', не 'build/artifacts': Join-Path у production-коді нормалізує
        # внутрішній роздільник на '\' (перевірено на pwsh 7.5.4, Join-Path 'C:\foo' 'build/artifacts'
        # дає 'C:\foo\build\artifacts', на відміну від [System.IO.Path]::Combine) — літеральний
        # прямий слеш у виводі команди не з'являється.
        $r.Output | Should -BeLike '*operation=make*build*artifacts*'
    }

    It '-Workspace обмежує збір артефактів лише вибраним воркспейсом (Q1 звіту задачі 3 — Copy-KitWorkspaceArtifacts не мусить чіпати сусідні воркспейси)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'scope') -Workspaces $script:WsTwo -WithHooks
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') {
            New-Item -ItemType Directory -Path (Join-Path $repo "$n/build/artifacts") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo "$n/build/artifacts/$n.cfe") -Value 'cfe' -Encoding ascii
        }
        $r = Invoke-Build -Repo $repo -More @('-Workspace', 'Alpha_SMB', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $repo 'build/artifacts/Alpha_SMB.cfe' | Should -Exist
        Join-Path $repo 'build/artifacts/Beta_SMB.cfe' | Should -Not -Exist
        # Джерело в сусідньому воркспейсі лишається на місці — build його не чіпає, лише не копіює.
        Join-Path $repo 'Beta_SMB/build/artifacts/Beta_SMB.cfe' | Should -Exist
    }
}

Describe 'kit build — .epf через платформу' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Джерело обробки — з живого репозиторію (перший .xml у epf/src), лише читання.
        $script:Live = 'R:\github\SMP_BankExchange\epf\src'
    }
    It 'збирає .epf із живих вихідників у build/artifacts' {
        $desc = Get-ChildItem -LiteralPath $script:Live -Filter '*.xml' -File | Select-Object -First 1
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'bank_formats'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces $ws -WithHooks
        Copy-Item -LiteralPath $desc.FullName -Destination (Join-Path $repo 'epf/src')
        Copy-Item -LiteralPath (Join-Path $script:Live $desc.BaseName) -Destination (Join-Path $repo 'epf/src' $desc.BaseName) -Recurse
        $out = & pwsh -NoProfile -File $script:Kit build -RepoRoot $repo -Apply 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        Join-Path $repo "build/artifacts/$($desc.BaseName).epf" | Should -Exist
    }
}
