#Requires -Version 7
# track (перенесено з agent-kit 0.9.1): один запобіжник, чия поломка мовчки дає хибний результат —
# усі рядки таблиці блоків перевіряються ДО першого запису в GitHub. Хибна віха в другому рядку не
# має лишити в GitHub ні мітки, ні issue першого. Справжня команда `track` — підпроцесом, проти
# фальшивого `gh.exe` на початку PATH (Invoke-KitGh шукає gh через Get-Command, тож підхоплює саме
# його). Контроль, що вміє впасти: валідна таблиця дає в журналі `issue create` — отже фальшивий gh
# справді викликається й пишучі виклики журнал бачить.
Describe 'track — перевірка таблиці блоків до першого запису' {
    BeforeAll {
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Bin = Join-Path $TestDrive 'fakebin'
        New-Item -ItemType Directory -Path $script:Bin | Out-Null
        $script:Journal = Join-Path $TestDrive 'gh-calls.log'
        # gh.exe, а не gh.cmd: cmd.exe читає `&` у `?state=all&per_page=100` як роздільник команд і
        # ріже аргумент до того, як його побачить фальшивка. Тож фальшивка — крихітний exe, зібраний
        # csc.exe з .NET Framework (є на кожній Windows). Без стану: порожні списки міток і issue,
        # одна відкрита віха M1; кожен виклик — рядок у журналі $env:FAKE_GH_LOG.
        $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if (-not (Test-Path -LiteralPath $csc)) { throw "немає ${csc}: фальшивий gh не зібрати" }
        Set-Content -LiteralPath (Join-Path $script:Bin 'fake-gh.cs') -Encoding UTF8 -Value @'
using System; using System.IO; using System.Linq; using System.Text;
class FakeGh {
    static int Main(string[] a) {
        var log = Environment.GetEnvironmentVariable("FAKE_GH_LOG");
        var n = File.Exists(log) ? File.ReadAllLines(log, Encoding.UTF8).Count(l => l.StartsWith("issue create")) : 0;
        File.AppendAllText(log, string.Join(" ", a) + "\n", new UTF8Encoding(false));
        var o = Console.OpenStandardOutput();
        Action<string> say = s => { var b = new UTF8Encoding(false).GetBytes(s); o.Write(b, 0, b.Length); };
        var path = a.FirstOrDefault(x => x.StartsWith("repos/")) ?? "";
        if (a.Length > 1 && a[0] == "label" && a[1] == "list") say("[]");
        else if (a.Length > 1 && a[0] == "issue" && a[1] == "list") say("[]");
        else if (a.Length > 1 && a[0] == "issue" && a[1] == "create") { Console.In.ReadToEnd(); say("https://github.com/acme/app/issues/" + (10 + n)); }
        else if (a.Length > 0 && a[0] == "api" && path.Contains("/milestones")) say("[{\"number\":1,\"title\":\"M1\",\"state\":\"open\",\"due_on\":null,\"description\":\"\"}]");
        else if (a.Length > 0 && a[0] == "api" && path.Contains("/sub_issues")) { if (!a.Contains("POST")) say("[]"); }
        else if (a.Length > 0 && a[0] == "api" && path.Contains("/issues/")) say("{\"id\":" + (1000 + int.Parse(path.Substring(path.LastIndexOf('/') + 1))) + "}");
        return 0;
    }
}
'@
        & $csc /nologo "/out:$(Join-Path $script:Bin 'gh.exe')" (Join-Path $script:Bin 'fake-gh.cs') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'не зібрано фальшивий gh.exe' }

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
            Remove-Item -LiteralPath $script:Journal -ErrorAction SilentlyContinue
            $err = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            $savedPath = $env:PATH
            $env:PATH = "$script:Bin$([System.IO.Path]::PathSeparator)$savedPath"
            $env:FAKE_GH_LOG = $script:Journal
            Push-Location $script:Repo
            try { $out = & pwsh -NoProfile -File (Join-Path $script:KitRoot 'tools/kit-process.ps1') track @Arguments 2>$err }
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
