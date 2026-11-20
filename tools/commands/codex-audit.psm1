#Requires -Version 7
# Ported from agent-kit bin/codex-audit + lib/codex-reads.mjs (VSydorenko/agent-kit main), modified.
Set-StrictMode -Version Latest

<#
    Незалежний аудит Codex штатним режимом CLI: без конфігу користувача, без збереження сесії, звіт —
    JSON за схемою, а справжність запуску — за подіями JSONL, не за прозою. Причина: `codex exec`
    виходить кодом 0 і тоді, коли модель недоступна, і тоді, коли пісочниця не дала прочитати жодного
    файла, — звіт у цьому разі має форму «знахідки», але Codex репозиторію не бачив.

    Змін проти оригіналу: Windows. Пісочницю Windows задає ключ `windows.sandbox` конфігу Codex; з
    `--ignore-user-config` він губиться, і read-only пісочниця відмовляє кожному читанню («blocked by
    policy», exit 0) — тож команда передає його явно (поле профілю codex.windowsSandbox). Команди
    читання в подіях обгорнуто в pwsh/cmd (`"pwsh.exe" -Command 'Get-Content …'`). Codex береться як
    справжній codex.exe з пакета npm, а не codex.cmd: cmd.exe ламає лапки аргументів. Фонового режиму
    немає (у Claude Code фон дає сама оболонка), перевірки вільної пам'яті немає.
#>

$script:Usage = @"
codex-audit -Prompt <file> [-Embed <file>]… [-NoRepo] [-Freeze] [-Out <file>]
codex-audit review (-Commit <sha> | -Base <branch> | -Uncommitted) [-Prompt <file>] [-Out <file>]

One independent Codex run in the normal CLI mode (codex exec --ignore-user-config --ephemeral
--json) and a check from the JSONL events that it really happened. Verify every finding yourself;
never hand the raw report to the owner. Long run (5–15 min on high): start it in the background.

audit (default)  report is JSON {files_read: [...], findings: [{severity, location, defect, evidence}]}
  -Prompt <file> a few narrow questions, facts from the repository only
  -Embed <file>  append a document to the prompt (repeatable): uncommitted changes, a diff
  -NoRepo        the prompt is self-contained (needs -Embed): reading the repo is not required
  -Freeze        audit a frozen copy of HEAD (other sessions change the shared tree); uncommitted
                 work is not in it — pass it with -Embed
review           native code review of a commit, of the branch against a base, or of uncommitted changes
  -Out <file>    report path (default: the run folder)

Read proof (audit without -NoRepo): a completed command with exit 0 that reads a path in the tree
(Get-Content, type, Select-String, rg, git, …, also wrapped in pwsh/cmd), and every files_read
entry exists in the tree.

Profile section "codex" (machine profile, once per machine; a project may override it locally):
  model            required, e.g. "gpt-5.6-sol"
  reasoningEffort  required, e.g. "high" (model defaults can be "low")
  sandbox          default "read-only"
  windowsSandbox   default "unelevated" (without it the read-only sandbox refuses every read)
  bin              default: codex.exe of the npm package, then codex.exe on PATH
  extraArgs        default []; passed to both modes
  timeoutMinutes   default 30; a hung run is killed with its process tree
  maxPromptBytes   default 200000

Run folder: <main checkout>/<private.dir>/codex/<stamp>-<name>/ with prompt.md, events.jsonl,
codex.log, report.json|report.md, status.json. One Codex per machine (lock in TEMP).
Exit: 0 run checked; 2 bad arguments; 3 not checked (profile field, lock held, prompt too big,
error event, no turn.completed, Codex read no file, files_read names a missing file, report missing
or not by the schema, timeout).
"@

# Дописується до промпту аудиту: без нього Codex шукав у вебі й висів чверть години.
$script:Guard = @'


## Audit rules (added by codex-audit)

- NEVER use web search. If a question needs facts that are not in this prompt or the repository, answer OUT OF SCOPE for that question.
- Read only the files you need; do not survey the whole repository.
- List in files_read every repository file you actually read.
- One finding per defect: severity BLOCKER, MAJOR or MINOR; location is the place in the audited document or code; evidence is path:line in the repository. No defects — an empty findings list.
'@

$script:Severities = @('BLOCKER', 'MAJOR', 'MINOR')

# Команди, що читають файли або дерево. Інші (echo, Write-Output) — ні: успішний `echo` не доказ.
$script:Readers = @('get-content', 'gc', 'cat', 'type', 'more', 'select-string', 'sls', 'findstr', 'get-childitem',
    'gci', 'ls', 'dir', 'rg', 'grep', 'git', 'head', 'tail', 'sed', 'awk', 'wc', 'find', 'tree', 'test-path', 'resolve-path',
    'get-item', 'gi', 'measure-object')
# Без шляху ці читають поточну теку (-C) — теж читання.
$script:CwdReaders = @('get-childitem', 'gci', 'ls', 'dir', 'rg', 'git', 'tree', 'find')

# ---------- перевірка читання ----------

function ConvertFrom-CodexShellCommand {
    <# Розгортає обгортку pwsh/powershell/cmd/bash, якою Codex запускає кожну команду. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    $c = $Command.Trim()
    $m = [regex]::Match($c, '(?is)^"?[^"]*?(?:pwsh|powershell)(?:\.exe)?"?\s+(?:-\w+\s+)*?-(?:Command|c)\s+(.*)$')
    if (-not $m.Success) { $m = [regex]::Match($c, '(?is)^"?[^"]*?cmd(?:\.exe)?"?\s+/[cs]\s+(.*)$') }
    if (-not $m.Success) { $m = [regex]::Match($c, '(?is)^(?:\S*/)?(?:ba|z)?sh\s+-l?c\s+(.*)$') }
    if (-not $m.Success) { return $c }
    $inner = $m.Groups[1].Value.Trim()
    if ($inner.Length -ge 2 -and (($inner[0] -eq "'" -and $inner[-1] -eq "'") -or ($inner[0] -eq '"' -and $inner[-1] -eq '"'))) {
        $inner = $inner.Substring(1, $inner.Length - 2)
    }
    $inner
}

function Test-CodexPathInTree {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Cwd)
    if (-not $Token -or $Token.StartsWith('-')) { return $false }
    $plain = ($Token -split '[*?\[]')[0]
    if (-not $plain) { return $false }
    try { $abs = [System.IO.Path]::GetFullPath($plain, $Cwd) } catch { return $false }
    $rel = [System.IO.Path]::GetRelativePath($Cwd, $abs)
    if ($rel.StartsWith('..') -or [System.IO.Path]::IsPathRooted($rel)) { return $false }
    if ($plain -ne $Token) { return Test-Path -LiteralPath (Split-Path -Parent ($abs + 'x')) }
    Test-Path -LiteralPath $abs
}

function Test-CodexCommandReadsTree {
    <# Чи читає команда з події command_execution щось у дереві $Cwd. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command, [Parameter(Mandatory)][string]$Cwd)
    foreach ($cmd in ((ConvertFrom-CodexShellCommand $Command) -split '&&|\|\||;|\r?\n')) {
        $stages = $cmd -split '\|'
        for ($i = 0; $i -lt $stages.Count; $i++) {
            $toks = @([regex]::Matches($stages[$i], "'([^']*)'|`"([^`"]*)`"|(\S+)") | ForEach-Object {
                    if ($_.Groups[1].Success) { $_.Groups[1].Value } elseif ($_.Groups[2].Success) { $_.Groups[2].Value } else { $_.Groups[3].Value } })
            if (-not $toks.Count) { continue }
            $verb = [System.IO.Path]::GetFileNameWithoutExtension($toks[0]).ToLowerInvariant()
            if ($verb -notin $script:Readers) { continue }
            $operands = @($toks | Select-Object -Skip 1 | Where-Object { -not $_.StartsWith('-') -and $_ -notmatch '^\d*[<>]' })
            if (@($operands | Where-Object { Test-CodexPathInTree -Token $_ -Cwd $Cwd }).Count) { return $true }
            if ($i -eq 0 -and $verb -in $script:CwdReaders -and -not @($operands | Where-Object { $_ -match '[\\/]' }).Count) { return $true }
        }
    }
    $false
}

# ---------- вердикти ----------

function New-CodexVerdict { param([int]$Exit, [string]$Text) [pscustomobject]@{ Exit = $Exit; Verdict = $Text } }
function New-CodexFail { param([string]$Reason) New-CodexVerdict -Exit 3 -Text "not checked — $Reason" }

function Get-CodexEventsVerdict {
    <# Помилка моделі приходить подією, а код виходу лишається 0 — тож дивимося події. #>
    param($Run, [object[]]$Events)
    if ($Run.TimedOut) { return New-CodexFail 'codex timed out and was killed' }
    foreach ($e in $Events) {
        $itemType = if ($e.Contains('item') -and $e['item'] -is [System.Collections.IDictionary]) { $e['item']['type'] } else { $null }
        if ($e['type'] -in @('error', 'turn.failed') -or $itemType -eq 'error') {
            $msg = ($e | ConvertTo-Json -Depth 5 -Compress)
            return New-CodexFail "codex error event ($($e['type'])): $($msg.Substring(0, [Math]::Min(200, $msg.Length)))"
        }
    }
    if ($Run.ExitCode -ne 0) { return New-CodexFail "codex exited $($Run.ExitCode)" }
    if (-not @($Events | Where-Object { $_['type'] -eq 'turn.completed' }).Count) { return New-CodexFail 'no turn.completed event: the run did not finish' }
    $null
}

function Test-CodexReport {
    <# Звіт за схемою без бібліотек: схема мала й закрита. Повертає причину або $null. #>
    param($Data)
    if ($Data -isnot [System.Collections.IDictionary]) { return 'report is not a JSON object' }
    $keys = (@($Data.Keys) | Sort-Object) -join ','
    if ($keys -ne 'files_read,findings') { return "report keys must be files_read, findings (got $keys)" }
    if ($Data['files_read'] -isnot [System.Collections.IList] -or @($Data['files_read'] | Where-Object { $_ -isnot [string] }).Count) { return 'files_read must be an array of strings' }
    if ($Data['findings'] -isnot [System.Collections.IList]) { return 'findings must be an array' }
    $i = 0
    foreach ($f in $Data['findings']) {
        if ($f -isnot [System.Collections.IDictionary] -or ((@($f.Keys) | Sort-Object) -join ',') -ne 'defect,evidence,location,severity') { return "findings[$i] must have exactly severity, location, defect, evidence" }
        if ($f['severity'] -notin $script:Severities) { return "findings[$i].severity must be one of $($script:Severities -join ', ')" }
        foreach ($k in 'location', 'defect', 'evidence') { if ($f[$k] -isnot [string]) { return "findings[$i].$k must be a string" } }
        $i++
    }
    $null
}

function Get-CodexAuditVerdict {
    param($Run, [object[]]$Events, [AllowEmptyString()][string]$Report, [bool]$Repo, [string]$Cwd)
    $bad = Get-CodexEventsVerdict -Run $Run -Events $Events
    if ($bad) { return $bad }
    $reads = @($Events | Where-Object {
            $_['type'] -eq 'item.completed' -and $_['item'] -is [System.Collections.IDictionary] -and $_['item']['type'] -eq 'command_execution' -and
            $_['item']['exit_code'] -eq 0 -and (Test-CodexCommandReadsTree -Command ([string]$_['item']['command']) -Cwd $Cwd) })
    if ($Repo -and -not $reads.Count) { return New-CodexFail "no completed command_execution with exit code 0 that reads a path under ${Cwd}: Codex did not read the repository (sandbox? -Embed with -NoRepo for a self-contained prompt)" }
    if (-not $Report.Trim()) { return New-CodexFail 'report is missing or empty' }
    try { $data = $Report | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return New-CodexFail "report is not JSON: $($_.Exception.Message)" }
    $schemaErr = Test-CodexReport $data
    if ($schemaErr) { return New-CodexFail "report does not match the schema: $schemaErr" }
    $files = @($data['files_read'])
    if ($Repo -and -not $files.Count) { return New-CodexFail 'files_read is empty: Codex reports no repository file read' }
    if ($Repo) {
        $ghosts = @($files | Where-Object { -not (Test-CodexPathInTree -Token $_ -Cwd $Cwd) -or -not (Test-Path -LiteralPath ([System.IO.Path]::GetFullPath($_, $Cwd)) -PathType Leaf) })
        if ($ghosts.Count) { return New-CodexFail "files_read names file(s) not in the tree: $(($ghosts | Select-Object -First 5) -join ', ')" }
    }
    $f = @($data['findings'])
    $count = { param($s) @($f | Where-Object { $_['severity'] -eq $s }).Count }
    New-CodexVerdict -Exit 0 -Text "$($f.Count) finding(s) ($(& $count 'BLOCKER') blocker(s), $(& $count 'MAJOR') major(s), $(& $count 'MINOR') minor(s)), $($files.Count) file(s) read"
}

function Get-CodexReviewVerdict {
    param($Run, [object[]]$Events, [AllowEmptyString()][string]$Report)
    $bad = Get-CodexEventsVerdict -Run $Run -Events $Events
    if ($bad) { return $bad }
    if (-not $Report.Trim()) { return New-CodexFail 'review report is missing or empty' }
    $tags = @([regex]::Matches($Report, '\[(P\d)\]') | ForEach-Object { $_.Groups[1].Value })
    $by = (@($tags | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Count)" })) -join ', '
    New-CodexVerdict -Exit 0 -Text "review done — $(if ($tags.Count) { $by } else { 'no [P] comments' })"
}

# ---------- запуск ----------

function Resolve-CodexBin {
    param([AllowEmptyString()][string]$Bin)
    if ($Bin) { return $Bin }
    $npm = Join-Path ($env:APPDATA ?? '') 'npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe'
    if ($env:APPDATA -and (Test-Path -LiteralPath $npm)) { return $npm }
    $exe = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*.exe' } | Select-Object -First 1
    if ($exe) { return $exe.Source }
    throw (New-KitNotChecked 'codex.exe не знайдено: встановіть Codex CLI (npm i -g @openai/codex) або вкажіть codex.bin у машинному профілі')
}

function Get-CodexArgs {
    param($Cfg, $Run)
    $common = @('--ignore-user-config', '--ephemeral', '-m', $Cfg.Model, '-c', "model_reasoning_effort=`"$($Cfg.Effort)`"",
        '-c', "windows.sandbox=`"$($Cfg.WindowsSandbox)`"")
    if ($Run.Mode -eq 'review') {
        # У `exec review` немає -s і -C: пісочниця — через конфіг, каталог — робоча тека процесу.
        return @('exec', 'review') + $common + @('-c', "sandbox_mode=`"$($Cfg.Sandbox)`"") + $Cfg.ExtraArgs + $Run.Target +
            @('--json', '-o', $Run.Report) + $(if ($Run.HasPrompt) { @('-') } else { @() })
    }
    @('exec') + $common + @('-s', $Cfg.Sandbox) + $Cfg.ExtraArgs + @('--output-schema', $script:SchemaPath, '--json', '-C', $Run.Cwd, '-o', $Run.Report) +
        $(if ($Run.Frozen) { @('--skip-git-repo-check') } else { @() }) + @('-')
}

function Invoke-CodexProcess {
    <# Запускає Codex: stdin — промпт, stdout — events.jsonl, stderr — codex.log; тайм-аут вбиває все дерево процесів. #>
    param($Cfg, $Run)
    $argv = Get-CodexArgs -Cfg $Cfg -Run $Run
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($Cfg.Bin -like '*.ps1') { $psi.FileName = 'pwsh'; foreach ($a in @('-NoProfile', '-File', $Cfg.Bin)) { $psi.ArgumentList.Add($a) } }
    else { $psi.FileName = $Cfg.Bin }
    foreach ($a in $argv) { $psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $Run.Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Run.Log, "$ $($Cfg.Bin) $($argv -join ' ')`n")
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ SpawnError = $_.Exception.Message; ExitCode = $null; TimedOut = $false } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $stdin = [System.IO.StreamWriter]::new($p.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
    if ($Run.HasPrompt) { $stdin.Write([System.IO.File]::ReadAllText($Run.PromptFile)) }
    $stdin.Close()
    $timedOut = -not $p.WaitForExit([int]($Cfg.TimeoutMinutes * 60000))
    if ($timedOut) { try { $p.Kill($true) } catch { } ; $p.WaitForExit() }
    [System.IO.File]::WriteAllText($Run.Events, $outTask.GetAwaiter().GetResult())
    [System.IO.File]::AppendAllText($Run.Log, $errTask.GetAwaiter().GetResult())
    [pscustomobject]@{ SpawnError = $null; ExitCode = $p.ExitCode; TimedOut = $timedOut }
}

# ---------- замок: один Codex на машину ----------

function Get-CodexProcessStart { param([int]$ProcessId) try { (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToFileTimeUtc() } catch { $null } }

function Enter-CodexLock {
    <# Атомарне створення файла замка; мертвого власника (pid зник чи перевикористаний) замок не тримає. #>
    param([Parameter(Mandatory)][string]$LockFile)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $bytes = [System.Text.Encoding]::ASCII.GetBytes("$PID $(Get-CodexProcessStart $PID)")
            $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
            return $null
        } catch [System.IO.IOException] { }
        $owner = (Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue) -split '\s+'
        $ownerPid = 0
        if ($owner -and [int]::TryParse($owner[0], [ref]$ownerPid)) {
            $start = Get-CodexProcessStart $ownerPid
            if ($start -and (-not $owner[1] -or [string]$start -eq $owner[1])) { return "another codex-audit is running (pid $ownerPid, lock $LockFile)" }
        }
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
    "cannot take lock $LockFile"
}

function Exit-CodexLock {
    param([Parameter(Mandatory)][string]$LockFile)
    $owner = (Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue)
    if ($owner -and ($owner -split '\s+')[0] -eq [string]$PID) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }
}

# ---------- команда ----------

function Get-CodexFence { param([string]$Text) $n = 2; foreach ($m in [regex]::Matches($Text, '`+')) { $n = [Math]::Max($n, $m.Length) }; '`' * ($n + 1) }

function Invoke-KitCodexAudit {
    param([AllowEmptyCollection()][string[]]$Arguments = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{ Prompt = 'string'; Embed = 'list'; NoRepo = 'switch'; Freeze = 'switch'; Out = 'string'; Commit = 'string'; Base = 'string'; Uncommitted = 'switch' }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    $mode = if ($a.Positional.Count) { $a.Positional[0] } else { 'audit' }
    if ($a.Positional.Count -gt 1 -or $mode -notin @('audit', 'review')) { throw (New-KitUsageError "невідомий режим: $($a.Positional -join ' ') (audit або review)") }
    $target = @()
    if ($a.Named.ContainsKey('Commit')) { $target += @('--commit', $a.Named['Commit']) }
    if ($a.Named.ContainsKey('Base')) { $target += @('--base', $a.Named['Base']) }
    if ($a.Named['Uncommitted']) { $target += '--uncommitted' }
    $embeds = if ($a.Named.ContainsKey('Embed')) { @($a.Named['Embed']) } else { @() }
    if ($mode -eq 'review') {
        if (@($target | Where-Object { $_.StartsWith('--') }).Count -ne 1) { throw (New-KitUsageError 'review потребує рівно одного з -Commit <sha>, -Base <гілка>, -Uncommitted') }
        if ($embeds.Count -or $a.Named['NoRepo'] -or $a.Named['Freeze']) { throw (New-KitUsageError '-Embed, -NoRepo і -Freeze — параметри аудиту, не review') }
    } else {
        if (-not $a.Named.ContainsKey('Prompt')) { throw (New-KitUsageError '-Prompt <файл> обов''язковий') }
        if ($target.Count) { throw (New-KitUsageError '-Commit, -Base, -Uncommitted — параметри review') }
        if ($a.Named['NoRepo'] -and -not $embeds.Count) { throw (New-KitUsageError '-NoRepo потребує хоча б одного -Embed: самодостатній промпт несе свої документи') }
    }
    foreach ($f in @($a.Named['Prompt']) + $embeds | Where-Object { $_ }) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw (New-KitUsageError "не файл: $f") }
    }

    $profile = Get-KitProfile -RepoRoot $RepoRoot
    $cfg = [pscustomobject]@{
        Model          = [string](Get-KitProfileValue $profile 'codex.model')
        Effort         = [string](Get-KitProfileValue $profile 'codex.reasoningEffort')
        Sandbox        = [string](Get-KitProfileValue $profile 'codex.sandbox' -Default 'read-only')
        WindowsSandbox = [string](Get-KitProfileValue $profile 'codex.windowsSandbox' -Default 'unelevated')
        Bin            = Resolve-CodexBin ([string](Get-KitProfileValue $profile 'codex.bin' -Default ''))
        # Get-KitProfileValue повертає масив, загорнутий у масив: без розгортання порожній
        # extraArgs став би аргументом «System.Object[]».
        ExtraArgs      = [string[]]@(foreach ($x in @(Get-KitProfileValue $profile 'codex.extraArgs' -Default @())) { foreach ($y in @($x)) { [string]$y } })
        TimeoutMinutes = [double](Get-KitProfileValue $profile 'codex.timeoutMinutes' -Default 30)
        MaxPromptBytes = [int](Get-KitProfileValue $profile 'codex.maxPromptBytes' -Default 200000)
    }

    $name = if ($mode -eq 'review') { 'review' } else { [System.IO.Path]::GetFileNameWithoutExtension($a.Named['Prompt']) -replace '[^\w.-]+', '_' }
    $runDir = Join-Path (Join-Path (Get-KitAgentsDir -Name private -RepoRoot $RepoRoot -Create) 'codex') "$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$name"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $run = [pscustomobject]@{
        Mode       = $mode
        Target     = $target
        HasPrompt  = $a.Named.ContainsKey('Prompt')
        PromptFile = Join-Path $runDir 'prompt.md'
        Events     = Join-Path $runDir 'events.jsonl'
        Log        = Join-Path $runDir 'codex.log'
        Status     = Join-Path $runDir 'status.json'
        Report     = [System.IO.Path]::GetFullPath($(if ($a.Named.ContainsKey('Out')) { $a.Named['Out'] } else { Join-Path $runDir $(if ($mode -eq 'review') { 'report.md' } else { 'report.json' }) }))
        Frozen     = [bool]$a.Named['Freeze']
        Cwd        = $profile.Root
    }
    $finish = {
        param($v)
        [ordered]@{ mode = $run.Mode; exit = $v.Exit; verdict = $v.Verdict; report = $run.Report; events = $run.Events; log = $run.Log } |
            ConvertTo-Json | Set-Content -LiteralPath $run.Status -Encoding utf8NoBOM
        Write-KitLine "codex-audit: $($v.Verdict)"
        Write-KitLine "report: $($run.Report)"
        if ($v.Exit -ne 0) {
            Write-KitLine "log: $($run.Log)"; Write-KitLine "events: $($run.Events)"
            throw (New-KitNotChecked $v.Verdict)
        }
        Write-KitNext 'звір кожну знахідку з кодом сам; власнику — лише звірений вердикт'
        0
    }

    if ($run.HasPrompt) {
        $text = ([System.IO.File]::ReadAllText($a.Named['Prompt'])).TrimEnd()
        if ($mode -eq 'audit') {
            foreach ($e in $embeds) {
                $body = [System.IO.File]::ReadAllText($e); $fence = Get-CodexFence $body
                $text += "`n`n## Embedded document: $e`n`n$fence`n$($body.TrimEnd())`n$fence"
            }
            $text += "`n$script:Guard"
        }
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($text)
        if ($bytes -gt $cfg.MaxPromptBytes) { return (& $finish (New-CodexFail "prompt is $bytes bytes > codex.maxPromptBytes $($cfg.MaxPromptBytes); narrow it or split into slices")) }
        [System.IO.File]::WriteAllText($run.PromptFile, $text, [System.Text.UTF8Encoding]::new($false))
    }
    $lockFile = Join-Path ([System.IO.Path]::GetTempPath()) 'v8storagekit-codex-audit.lock'
    $lockErr = Enter-CodexLock -LockFile $lockFile
    if ($lockErr) { return (& $finish (New-CodexFail $lockErr)) }
    $tree = Join-Path $runDir 'tree'
    try {
        if ($run.Frozen) {
            $zip = Join-Path $runDir 'head.zip'
            & git -C $profile.Root archive --format=zip -o $zip HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { return (& $finish (New-CodexFail 'git archive HEAD failed')) }
            Expand-Archive -LiteralPath $zip -DestinationPath $tree -Force
            Remove-Item -LiteralPath $zip -Force
            $run.Cwd = $tree
        }
        if (Test-Path -LiteralPath $run.Report) { Remove-Item -LiteralPath $run.Report -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $run.Report) -Force | Out-Null
        $r = Invoke-CodexProcess -Cfg $cfg -Run $run
        if ($r.SpawnError) { return (& $finish (New-CodexFail "cannot start $($cfg.Bin): $($r.SpawnError)")) }
        $events = @(foreach ($line in ([System.IO.File]::ReadAllText($run.Events) -split "\r?\n")) {
                if ($line.Trim()) { try { $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { } } })
        $report = if (Test-Path -LiteralPath $run.Report) { [System.IO.File]::ReadAllText($run.Report) } else { '' }
        $v = if ($mode -eq 'review') { Get-CodexReviewVerdict -Run $r -Events $events -Report $report }
        else { Get-CodexAuditVerdict -Run $r -Events $events -Report $report -Repo (-not $a.Named['NoRepo']) -Cwd $run.Cwd }
        & $finish $v
    } finally {
        # Рекурсивне видалення — лише Remove-KitDirectory (#34) і лише всередині теки запуску (П25).
        if ($run.Frozen -and (Test-Path -LiteralPath $tree)) {
            Assert-SafeWorkPath -Path $tree -MustBeUnder $runDir -RepoRoot $profile.MainRoot -OwnedRoot $runDir -Description 'заморожене дерево аудиту'
            Remove-KitDirectory -Path $tree
        }
        Exit-CodexLock -LockFile $lockFile
    }
}

$script:SchemaPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/codex-findings.schema.json'))

Export-ModuleMember -Function Invoke-KitCodexAudit
