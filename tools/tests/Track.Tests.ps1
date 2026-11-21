#Requires -Version 7
# track (перенесено з agent-kit 0.9.1): один запобіжник, чия поломка мовчки дає хибний результат —
# усі рядки таблиці блоків перевіряються ДО першого запису в GitHub. Хибна віха в другому рядку не
# має лишити в GitHub ні мітки, ні issue першого. Справжня команда `track` — підпроцесом, проти
# фальшивого `gh.exe` на початку PATH (спільна фікстура fixtures/FakeGh.psm1; Invoke-KitGh шукає gh
# через Get-Command, тож підхоплює саме його). Контроль, що вміє впасти: валідна таблиця дає в
# журналі `issue create` — отже фальшивий gh справді викликається й пишучі виклики журнал бачить.
Describe 'track — перевірка таблиці блоків до першого запису' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/FakeGh.psm1").Path -Force
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Bin = New-KitFakeGh -Dir (Join-Path $TestDrive 'fakebin')
        $script:Journal = Join-Path $TestDrive 'gh-calls.log'
        # Без стану між командами, окрім лічильника issue: порожні списки міток і issue, одна відкрита
        # віха M1; кожен виклик — рядок у журналі. Невідомий виклик — код 0 і порожньо, як у gh,
        # якому нема що сказати (track пише label/issue edit, не читаючи відповіді).
        $script:Scenario = Write-KitFakeGhScenario -Path (Join-Path $TestDrive 'scenario.json') -Default @{ exit = 0 } -Rules @(
            @{ prefix = @('label', 'list'); stdout = '[]' }
            @{ prefix = @('issue', 'list'); stdout = '[]' }
            @{ prefix = @('issue', 'create'); stdout = 'https://github.com/acme/app/issues/{count+10}' }
            @{ prefix = @('api'); hasPart = @('/milestones'); stdout = '[{"number":1,"title":"M1","state":"open","due_on":null,"description":""}]' }
            @{ prefix = @('api'); hasPart = @('/sub_issues'); not = @('POST'); stdout = '[]' }
            @{ prefix = @('api'); hasPart = @('/sub_issues') }
            @{ prefix = @('api'); hasPart = @('/issues/'); stdout = '{"id":{pathnum+1000}}' }
        )

        $script:Repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.agents') -Force | Out-Null
        git -C $script:Repo init -q 2>$null
        Set-Content -LiteralPath (Join-Path $script:Repo '.agents/kit.profile.json') -Value '{ "track": { "repo": "acme/app" } }' -Encoding UTF8

        function script:Write-Spec {
            param([string]$Name, [string]$SecondMilestone)
            $text = "# Test spec`n`n## Blocks`n`n| Block | Scope | Done when | Віха |`n| --- | --- | --- | --- |`n| B1 One | a | a | M1 |`n| B2 Two | b | b | $SecondMilestone |`n"
            [System.IO.File]::WriteAllText((Join-Path $script:Repo $Name), $text, [System.Text.UTF8Encoding]::new($false))
        }
        function script:Invoke-Track {
            param([string[]]$Arguments)
            Remove-Item -LiteralPath $script:Journal, "$script:Scenario.state" -ErrorAction SilentlyContinue
            $err = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            $savedPath = $env:PATH
            $env:PATH = "$script:Bin$([System.IO.Path]::PathSeparator)$savedPath"
            $env:FAKE_GH_LOG = $script:Journal; $env:FAKE_GH_SCENARIO = $script:Scenario
            Push-Location $script:Repo
            try { $out = & pwsh -NoProfile -File (Join-Path $script:KitRoot 'tools/kit.ps1') track @Arguments 2>$err }
            finally { Pop-Location; $env:PATH = $savedPath }
            [pscustomobject]@{
                Code = $LASTEXITCODE; Out = ($out -join "`n"); Err = (Get-Content -LiteralPath $err -Raw -Encoding UTF8)
                Calls = @(if (Test-Path -LiteralPath $script:Journal) { Get-Content -LiteralPath $script:Journal -Encoding UTF8 })
            }
        }
        $script:Writes = '^(issue (create|edit)|label create|api -X (POST|PATCH))'
    }

    It 'хибна віха в другому рядку — код 1, причина називає блок, жодного пишучого виклику gh' {
        # Контроль: усі віхи існують — фальшивий gh підхоплено, issue створюються.
        Write-Spec -Name 'ok.md' -SecondMilestone 'M1'
        $ok = Invoke-Track -Arguments @('spec', 'ok.md')
        $ok.Code | Should -Be 0 -Because $ok.Err
        @($ok.Calls | Where-Object { $_ -match '^issue create' }).Count | Should -Be 3 -Because 'спека й два блоки; порожній журнал означав би, що фальшивий gh не підхоплено'

        # Хибна таблиця: M9 не існує, а перший рядок валідний — без перевірки до запису B1 уже був би створений.
        Write-Spec -Name 'bad.md' -SecondMilestone 'M9'
        $bad = Invoke-Track -Arguments @('spec', 'bad.md')
        $bad.Code | Should -Be 1
        $bad.Err | Should -Match 'B2: немає віхи "M9"'
        $bad.Calls.Count | Should -BeGreaterThan 0 -Because 'читання віх мало дійти до gh'
        @($bad.Calls | Where-Object { $_ -match $script:Writes }) | Should -BeNullOrEmpty
    }
}
