#Requires -Version 7
# Фальшивий `gh.exe` для тестів команд процесу (track, pr-gate): крихітний exe, зібраний csc.exe з
# .NET Framework (є на кожній Windows). Чому exe, а не gh.cmd: cmd.exe читає `&` у
# `?state=all&per_page=100` як роздільник команд і ріже аргумент до того, як його побачить
# фальшивка. Invoke-KitGh шукає gh через Get-Command, тож підхоплює саме його, коли теку з ним
# поставлено на початок PATH.
#
# Поведінка — зі сценарію (JSON-файл, шлях у $env:FAKE_GH_SCENARIO): перелік правил, перше збіжне
# виграє; кожен виклик — рядок аргументів через пробіл у журналі $env:FAKE_GH_LOG.
#
#   { "default": { "exit": 0, "stdout": "", "stderr": "" },
#     "rules": [ { "prefix": ["pr","view"], "has": [...], "hasPart": [...], "not": [...],
#                  "after": ["pr","merge"], "times": 1,
#                  "stdout": "...", "stderr": "...", "exit": 0 } ] }
#
#   prefix   — виклик починається з цих аргументів (рівність);
#   has      — кожен із цих рядків є серед аргументів (рівність);
#   hasPart  — кожен із цих підрядків є в якомусь аргументі;
#   not      — жодного з цих рядків немає серед аргументів;
#   after    — раніше в журналі був виклик, що починається з цього префікса (стан між викликами:
#              `pr view` до злиття відповідає одне, після `pr merge` — інше);
#   times    — правило спрацьовує не більше стільки разів (лічильник у <сценарій>.state), далі
#              діє наступне збіжне;
#   stdout   — підстановки: {count[+K]} — скільки разів це правило вже спрацьовувало (+K), {pathnum[+K]}
#              — число в кінці першого аргументу, що починається з `repos/` (+K).
# Виклик без збіжного правила дає "default" (типово код 9 і «немає правила» в stderr: тест, що не
# описав виклик, червоніє, а не отримує мовчки порожню відповідь).

$script:Source = @'
using System; using System.Collections; using System.Collections.Generic; using System.IO;
using System.Linq; using System.Text; using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
class FakeGh {
    static List<string> L(object o) { var r = new List<string>(); var a = o as ArrayList; if (a != null) foreach (var x in a) r.Add(Convert.ToString(x)); return r; }
    static string S(Dictionary<string, object> d, string k, string def) { object v; return d.TryGetValue(k, out v) && v != null ? Convert.ToString(v) : def; }
    static int Main(string[] a) {
        var utf8 = new UTF8Encoding(false);
        var logPath = Environment.GetEnvironmentVariable("FAKE_GH_LOG");
        var scenPath = Environment.GetEnvironmentVariable("FAKE_GH_SCENARIO");
        var prior = new List<string>();
        if (!string.IsNullOrEmpty(logPath) && File.Exists(logPath)) prior.AddRange(File.ReadAllLines(logPath, utf8));
        var counts = new Dictionary<int, int>();
        var statePath = scenPath == null ? null : scenPath + ".state";
        if (statePath != null && File.Exists(statePath))
            foreach (var line in File.ReadAllLines(statePath)) { var p = line.Split('='); if (p.Length == 2) counts[int.Parse(p[0])] = int.Parse(p[1]); }
        if (!string.IsNullOrEmpty(logPath)) File.AppendAllText(logPath, string.Join(" ", a) + "\n", utf8);

        var scen = new Dictionary<string, object>();
        if (scenPath != null && File.Exists(scenPath))
            scen = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(scenPath, utf8));
        var rules = scen.ContainsKey("rules") ? (scen["rules"] as ArrayList) : null;
        Dictionary<string, object> hit = null; int hitIdx = -1;
        if (rules != null) for (int i = 0; i < rules.Count && hit == null; i++) {
            var r = (Dictionary<string, object>)rules[i];
            var prefix = r.ContainsKey("prefix") ? L(r["prefix"]) : new List<string>();
            if (a.Length < prefix.Count) continue;
            bool ok = true;
            for (int k = 0; k < prefix.Count; k++) if (a[k] != prefix[k]) ok = false;
            if (r.ContainsKey("has")) foreach (var x in L(r["has"])) if (!a.Contains(x)) ok = false;
            if (r.ContainsKey("hasPart")) foreach (var x in L(r["hasPart"])) if (!a.Any(y => y.Contains(x))) ok = false;
            if (r.ContainsKey("not")) foreach (var x in L(r["not"])) if (a.Contains(x)) ok = false;
            if (r.ContainsKey("after")) { var pre = string.Join(" ", L(r["after"])); if (!prior.Any(l => l == pre || l.StartsWith(pre + " "))) ok = false; }
            int used; counts.TryGetValue(i, out used);
            if (r.ContainsKey("times") && used >= Convert.ToInt32(r["times"])) ok = false;
            if (ok) { hit = r; hitIdx = i; }
        }
        int n = 0; if (hitIdx >= 0) counts.TryGetValue(hitIdx, out n);
        string stdout, stderr; int exit;
        if (hit != null) {
            stdout = S(hit, "stdout", ""); stderr = S(hit, "stderr", ""); exit = hit.ContainsKey("exit") ? Convert.ToInt32(hit["exit"]) : 0;
            counts[hitIdx] = n + 1;
        } else {
            var d = scen.ContainsKey("default") ? (Dictionary<string, object>)scen["default"] : new Dictionary<string, object>();
            exit = d.ContainsKey("exit") ? Convert.ToInt32(d["exit"]) : 9;
            stdout = S(d, "stdout", ""); stderr = S(d, "stderr", exit == 9 ? "fake gh: немає правила для: " + string.Join(" ", a) : "");
        }
        var path = a.FirstOrDefault(x => x.StartsWith("repos/")) ?? "";
        var pm = Regex.Match(path, @"(\d+)$"); int pathnum = pm.Success ? int.Parse(pm.Groups[1].Value) : 0;
        stdout = Regex.Replace(stdout, @"\{(count|pathnum)(?:\+(\d+))?\}", m => ((m.Groups[1].Value == "count" ? n : pathnum) + (m.Groups[2].Success ? int.Parse(m.Groups[2].Value) : 0)).ToString());
        if (statePath != null) File.WriteAllLines(statePath, counts.Select(kv => kv.Key + "=" + kv.Value));
        var o = Console.OpenStandardOutput(); var b = utf8.GetBytes(stdout); o.Write(b, 0, b.Length);
        var e = Console.OpenStandardError(); var eb = utf8.GetBytes(stderr); e.Write(eb, 0, eb.Length);
        return exit;
    }
}
'@

function New-KitFakeGh {
    <#
    .SYNOPSIS
        Збирає фальшивий gh.exe в -Dir і повертає -Dir (її ставлять на початок PATH).
    .DESCRIPTION
        Збирання — csc.exe з .NET Framework (~секунди): викликати раз на файл тестів (BeforeAll).
        Сценарій пише Write-KitFakeGhScenario, виклики читає Get-KitFakeGhCalls.
    #>
    param([Parameter(Mandatory)][string]$Dir)
    $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw "немає ${csc}: фальшивий gh не зібрати" }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $src = Join-Path $Dir 'fake-gh.cs'
    Set-Content -LiteralPath $src -Value $script:Source -Encoding UTF8
    $out = & $csc /nologo /r:System.Web.Extensions.dll "/out:$(Join-Path $Dir 'gh.exe')" $src 2>&1
    if ($LASTEXITCODE -ne 0) { throw "не зібрано фальшивий gh.exe: $($out -join ' ')" }
    $Dir
}

function Write-KitFakeGhScenario {
    <#
    .SYNOPSIS
        Пише сценарій у -Path (JSON) і скидає лічильники правил; повертає -Path.
    .PARAMETER Rules
        Масив хеш-таблиць: ключі prefix, has, hasPart, not, after, times, stdout, stderr, exit.
    .PARAMETER Default
        Хеш-таблиця відповіді, коли жодне правило не збіглося (типово — код 9).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Rules, [hashtable]$Default)
    $doc = [ordered]@{ rules = @($Rules) }
    if ($Default) { $doc['default'] = $Default }
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath "$Path.state" -ErrorAction SilentlyContinue
    $Path
}

function Get-KitFakeGhCalls {
    <# Журнал викликів gh: по рядку на виклик (аргументи через пробіл). Порожній, якщо gh не викликали. #>
    param([Parameter(Mandatory)][string]$Log)
    @(if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Encoding UTF8 })
}

Export-ModuleMember -Function New-KitFakeGh, Write-KitFakeGhScenario, Get-KitFakeGhCalls
