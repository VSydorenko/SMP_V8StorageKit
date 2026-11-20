#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-setup, modified.
Set-StrictMode -Version Latest

<#
    Разове підключення проєкту до процесу v8storagekit. Плагін не може постачати правила дозволів
    (обмеження Claude Code), тож їх дописує ця команда в налаштування проєкту. Власник дозволяє
    локальні команди (читання, запис у .agents/, тимчасові дерева), а не зовнішні дії: pr-gate
    open|ready|merge|land|prune, track spec|milestone і сам kit-setup лишаються з питанням.

    Ідемпотентно: другий запуск нічого не змінює. Нічого не видаляє й не перезаписує. -DryRun друкує
    точний diff кожного файла (власним кодом, без зовнішнього diff) і нічого не пише.

    Змін проти оригіналу: параметри PowerShell-стилем; кожне правило дозволу у двох формах — Bash(…) і
    PowerShell(…) (виміряно 2026-11-20 у Claude Code 2.1.329: PowerShell(session-cost:*) пропускає виклик
    інструментом PowerShell, а Bash(session-cost:*) — ні); перелік команд — команди цього плагіна;
    без .cbmignore, без JS-детекції (package.json, ESLint), без лематизатора й без сторожа git
    (ADR-0007); корінь worktree в .gitignore і .worktreeinclude — лише в режимі worktree.
#>

# Локальні команди, які дозволяємо без питання. Кожна — у двох формах (Bash і PowerShell).
$script:KitCommands = @(
    'sdd', 'review-pack', 'doc', 'session-board', 'session-cost', 'kit-scan',
    'track status', 'pr-gate start', 'pr-gate cleanup', 'pr-gate scratch'
)
# Широкі правила старих налаштувань: дозволяють зовнішні дії без питання. Не видаляємо (команда
# нічого не видаляє) — кажемо власнику, чим замінити.
$script:BroadOld = [ordered]@{
    'Bash(pr-gate:*)'       = 'дозволяє й pr-gate open|ready|land без питання; заміни на Bash(pr-gate start:*), Bash(pr-gate cleanup:*), Bash(pr-gate scratch:*)'
    'PowerShell(pr-gate:*)' = 'дозволяє й pr-gate open|ready|land без питання; заміни на PowerShell(pr-gate start:*), PowerShell(pr-gate cleanup:*), PowerShell(pr-gate scratch:*)'
    'Bash(track:*)'         = 'дозволяє й track spec|milestone (GitHub) без питання; заміни на Bash(track status:*)'
    'PowerShell(track:*)'   = 'дозволяє й track spec|milestone (GitHub) без питання; заміни на PowerShell(track status:*)'
}
$script:SettingsFile = '.claude/settings.json'
$script:ProfileRel = '.agents/kit.profile.json'
$script:LocalProfileRel = '.agents/kit.profile.local.json'
$script:IncludeFile = '.worktreeinclude'
$script:IncludeLines = @('.claude/settings.local.json', '.agents/kit.profile.local.json')
$script:DefaultWorktreesRoot = '.worktrees'
$script:DefaultPrivateDir = '.agents/private'
# Згенеровані платформою файли вивантаження: без шуму в рев'ю (джерела — у звіті задачі).
$script:ReviewExclude1C = @('**/ConfigDumpInfo.xml', '**/DumpFilesIndex.txt')

$script:Usage = @"
kit-setup [-DryRun] [-NoPermissions] [-NoGitignore] [-NoProfile] [-NoWorktreeInclude]

Разове підключення поточного репозиторію до процесу v8storagekit. Ідемпотентно: другий запуск
нічого не змінює. Нічого не видаляє й не перезаписує.

  permissions  дописати в $script:SettingsFile (permissions.allow) локальні команди процесу, кожну
               у двох формах — Bash(<x>:*) і PowerShell(<x>:*): $($script:KitCommands -join ', ').
               Зовнішні дії (pr-gate open|ready|land, track spec|milestone, kit-setup)
               не дозволяються. Широкі правила Bash/PowerShell(pr-gate:*) і (track:*) не
               видаляються — команда називає, чим їх замінити
  gitignore    дописати .agents/out/, .agents/sdd/, <private.dir>/, .agents/briefs/,
               $script:LocalProfileRel; у режимі worktree ще й <worktrees.root>/
  profile      створити $script:ProfileRel зі знайденими значеннями й TODO-маркерами, лише якщо його
               немає; новий профіль отримує kit.version = версія плагіна. Наявний профіль не
               змінюється: нижчу kit.version команда називає (оновлення — /v8storagekit:onboarding)
  worktreeinclude  лише в режимі worktree: дописати $($script:IncludeLines -join ', ') до
               $script:IncludeFile (гітігноровані файли, що копіюються в кожен новий worktree)
  -DryRun      надрукувати точний diff кожного файла, нічого не писати

Режим workspace.mode: з наявного профілю; інакше shared, якщо в корені є v8storagekit.yaml або будь-де
v8project.yaml, інакше worktree.
Вихід: 0 готово (або нічого міняти); 2 помилка виклику; 3 не git-репозиторій або файл не читається.
"@

# ---------- допоміжне ----------

function Read-SetupText {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::ReadAllText($Path) } else { $null }
}

function Invoke-SetupGit {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$GitArgs)
    $out = & git -C $Root @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $out
}

function Get-SetupNewline {
    param([AllowNull()][string]$Text)
    if ($Text -and $Text.Contains("`r`n")) { "`r`n" } else { "`n" }
}

function Get-SetupTextLines {
    <# Рядки тексту без кінцевого порожнього. #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return ,[string[]]@() }
    $l = @($Text -split "\r?\n")
    if ($l[-1] -eq '') { $l = if ($l.Count -gt 1) { @($l[0..($l.Count - 2)]) } else { @() } }
    ,[string[]]$l
}

function Add-SetupLines {
    <# Дописує блок із коментарем у кінець тексту, зберігаючи його кінці рядків. #>
    param($Before, [Parameter(Mandatory)][string[]]$Lines, [Parameter(Mandatory)][string]$Comment)
    $nl = Get-SetupNewline $Before
    $head = if ($null -eq $Before) { '' } elseif ($Before -eq '' -or $Before.EndsWith("`n")) { $Before } else { $Before + $nl }
    $head + "# $Comment" + $nl + ($Lines -join $nl) + $nl
}

function Get-SetupJsonText {
    param([Parameter(Mandatory)]$Data, [AllowNull()][string]$Before)
    $text = (ConvertTo-Json -InputObject $Data -Depth 50 -EscapeHandling Default) + "`n"
    if ((Get-SetupNewline $Before) -eq "`r`n") { $text = $text -replace "`n", "`r`n" }
    $text
}

function ConvertFrom-SetupJson {
    <# JSON → впорядкована хеш-таблиця; рядки-дати лишаються рядками. Помилка — виняток. #>
    param([Parameter(Mandatory)][string]$Text)
    $p = @{ AsHashtable = $true; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $p['DateKind'] = 'String' }
    $Text | ConvertFrom-Json @p
}

# ---------- diff ----------

function Get-SetupUnifiedDiff {
    <# Unified diff власним кодом: спільні початок і кінець відкидаються, середина — LCS; контекст 3 рядки. #>
    param([Parameter(Mandatory)][string]$Rel, $Before, [Parameter(Mandatory)][string]$After)
    $a = Get-SetupTextLines $Before
    $b = Get-SetupTextLines $After
    $p = 0
    while ($p -lt $a.Count -and $p -lt $b.Count -and $a[$p] -ceq $b[$p]) { $p++ }
    $s = 0
    while ($s -lt $a.Count - $p -and $s -lt $b.Count - $p -and $a[$a.Count - 1 - $s] -ceq $b[$b.Count - 1 - $s]) { $s++ }
    $n = $a.Count - $p - $s
    $m = $b.Count - $p - $s
    $lcs = [int[, ]]::new($n + 1, $m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            $lcs[$i, $j] = if ($a[$p + $i] -ceq $b[$p + $j]) { $lcs[($i + 1), ($j + 1)] + 1 } else { [math]::Max($lcs[($i + 1), $j], $lcs[$i, ($j + 1)]) }
        }
    }
    $ops = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $p; $i++) { $ops.Add(@(' ', $a[$i])) }
    $i = 0; $j = 0
    while ($i -lt $n -or $j -lt $m) {
        if ($i -lt $n -and $j -lt $m -and $a[$p + $i] -ceq $b[$p + $j]) { $ops.Add(@(' ', $a[$p + $i])); $i++; $j++ }
        elseif ($j -lt $m -and ($i -ge $n -or $lcs[$i, ($j + 1)] -ge $lcs[($i + 1), $j])) { $ops.Add(@('+', $b[$p + $j])); $j++ }
        else { $ops.Add(@('-', $a[$p + $i])); $i++ }
    }
    for ($k = 0; $k -lt $s; $k++) { $ops.Add(@(' ', $a[$a.Count - $s + $k])) }

    $head = @(
        "--- $(if ($null -eq $Before) { '/dev/null' } else { "a/$Rel" })"
        "+++ b/$Rel"
    )
    $changed = @(for ($k = 0; $k -lt $ops.Count; $k++) { if ($ops[$k][0] -ne ' ') { $k } })
    if (-not $changed) { return '' }
    # Діапазони зі зливанням перекритих.
    $ranges = [System.Collections.Generic.List[int[]]]::new()
    foreach ($c in $changed) {
        $st = [math]::Max(0, $c - 3); $en = [math]::Min($ops.Count - 1, $c + 3)
        if ($ranges.Count -and $st -le $ranges[$ranges.Count - 1][1] + 1) { $ranges[$ranges.Count - 1][1] = $en } else { $ranges.Add(@($st, $en)) }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.AddRange([string[]]$head)
    foreach ($r in $ranges) {
        $oldBefore = 0; $newBefore = 0
        for ($k = 0; $k -lt $r[0]; $k++) { if ($ops[$k][0] -ne '+') { $oldBefore++ }; if ($ops[$k][0] -ne '-') { $newBefore++ } }
        $oldLen = 0; $newLen = 0
        for ($k = $r[0]; $k -le $r[1]; $k++) { if ($ops[$k][0] -ne '+') { $oldLen++ }; if ($ops[$k][0] -ne '-') { $newLen++ } }
        $oldStart = $oldBefore + $(if ($oldLen) { 1 } else { 0 })
        $newStart = $newBefore + $(if ($newLen) { 1 } else { 0 })
        $out.Add("@@ -$oldStart,$oldLen +$newStart,$newLen @@")
        for ($k = $r[0]; $k -le $r[1]; $k++) { $out.Add("$($ops[$k][0])$($ops[$k][1])") }
    }
    $out -join "`n"
}

# ---------- факти про проєкт ----------

function Get-SetupProfileData {
    <# Злитий профіль; зламаний профіль — порожні дані (зламане поле назве інструмент, що його читає). #>
    param([Parameter(Mandatory)][string]$Root)
    try { (Get-KitProfile -RepoRoot $Root).Data } catch { @{} }
}

function Get-SetupField {
    param($Data, [Parameter(Mandatory)][string]$Path)
    $cur = $Data
    foreach ($k in $Path.Split('.')) {
        if (-not ($cur -is [System.Collections.IDictionary]) -or -not $cur.Contains($k)) { return $null }
        $cur = $cur[$k]
    }
    $cur
}

function Test-SetupIs1C {
    <# 1С-репозиторій: v8storagekit.yaml у корені або v8project.yaml будь-де (відстежений чи ще ні). #>
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'v8storagekit.yaml') -PathType Leaf) { return $true }
    $files = Invoke-SetupGit -Root $Root -GitArgs @('ls-files', '--cached', '--others', '--exclude-standard', '--', '*v8project.yaml')
    [bool]@($files | Where-Object { $_ -and (($_ -replace '\\', '/').Split('/')[-1] -eq 'v8project.yaml') })
}

function Get-SetupMode {
    <# Режим робочої копії: з наявного профілю, інакше з факту (shared у 1С-репо з базою агента). #>
    param([Parameter(Mandatory)][string]$Root, $Data)
    $fromProfile = Get-SetupField $Data 'workspace.mode'
    if ($fromProfile -in @('shared', 'worktree')) { return $fromProfile }
    if (Test-SetupIs1C -Root $Root) { 'shared' } else { 'worktree' }
}

function Get-SetupDefaultBranch {
    param([Parameter(Mandatory)][string]$Root)
    $head = Invoke-SetupGit -Root $Root -GitArgs @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($head) { return ([string]($head | Select-Object -First 1)).Trim() -replace '^origin/', '' }
    foreach ($b in 'main', 'master') {
        if (Invoke-SetupGit -Root $Root -GitArgs @('rev-parse', '--verify', '--quiet', "refs/heads/$b")) { return $b }
    }
    $null
}

# ---------- плани файлів ----------

function Get-SetupSettingsPlan {
    <# Дописує відсутні правила; порядок ключів і чужі правила лишаються. #>
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root $script:SettingsFile
    $before = Read-SetupText $path
    $data = [ordered]@{}
    if ($null -ne $before) {
        try { $data = ConvertFrom-SetupJson $before } catch { return @{ Error = "не читається $($script:SettingsFile): $($_.Exception.Message)" } }
        if (-not ($data -is [System.Collections.IDictionary])) { return @{ Error = "$($script:SettingsFile) — не JSON-об'єкт" } }
    }
    if (-not $data.Contains('permissions') -or $null -eq $data['permissions']) { $data['permissions'] = [ordered]@{} }
    $perm = $data['permissions']
    if (-not ($perm -is [System.Collections.IDictionary])) { return @{ Error = "$($script:SettingsFile): permissions — не об'єкт" } }
    if (-not $perm.Contains('allow') -or $null -eq $perm['allow']) { $perm['allow'] = @() }
    if ($perm['allow'] -is [string] -or $perm['allow'] -isnot [System.Collections.IEnumerable]) { return @{ Error = "$($script:SettingsFile): permissions.allow — не масив" } }
    $allow = @($perm['allow'])
    $wanted = foreach ($c in $script:KitCommands) { "Bash($c`:*)"; "PowerShell($c`:*)" }
    $added = @($wanted | Where-Object { $allow -notcontains $_ })
    $warn = (@($script:BroadOld.Keys | Where-Object { $allow -contains $_ } | ForEach-Object {
                "`n  власнику: $_ ширше за потрібне — $($script:BroadOld[$_]); прибери вручну (вузькі правила покривають безпечні кроки)"
            }) -join '')
    $plan = @{ Path = $path; Rel = $script:SettingsFile; Before = $before; After = $before; Note = "правила для процесу вже дозволено$warn" }
    if ($added) {
        $perm['allow'] = [object[]]@($allow + $added)
        $plan.After = Get-SetupJsonText -Data $data -Before $before
        $plan.Note = "+$($added.Count) правил allow — власнику: перегляньте цей diff (агенти зможуть запускати ці команди без питання)$warn"
    }
    $plan
}

function Get-SetupGitignorePlan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode, $Data)
    $path = Join-Path $Root '.gitignore'
    $before = Read-SetupText $path
    $have = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($l in (Get-SetupTextLines $before)) { [void]$have.Add($l.Trim().TrimStart('/')) }
    $private = $script:DefaultPrivateDir
    $wtRoot = $script:DefaultWorktreesRoot
    try { $v = Get-SetupField $Data 'private.dir'; if ($v) { $private = Resolve-KitInsidePath -Value ([string]$v) -Field 'private.dir' } } catch { }
    try { $v = Get-SetupField $Data 'worktrees.root'; if ($v) { $wtRoot = Resolve-KitInsidePath -Value ([string]$v) -Field 'worktrees.root' } } catch { }
    $wanted = @('.agents/out/', '.agents/sdd/', "$private/", '.agents/briefs/', $script:LocalProfileRel)
    if ($Mode -eq 'worktree') { $wanted += "$wtRoot/" }
    $added = @($wanted | Where-Object { -not $have.Contains($_) -and -not $have.Contains($_.TrimEnd('/')) })
    if (-not $added) { return @{ Path = $path; Rel = '.gitignore'; Before = $before; After = $before; Note = 'уже ігнорується' } }
    @{ Path = $path; Rel = '.gitignore'; Before = $before; After = (Add-SetupLines -Before $before -Lines $added -Comment 'v8storagekit: процес'); Note = "+$($added.Count) рядків" }
}

function Get-SetupWorktreeIncludePlan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    $path = Join-Path $Root $script:IncludeFile
    $before = Read-SetupText $path
    if ($Mode -ne 'worktree') { return @{ Path = $path; Rel = $script:IncludeFile; Before = $before; After = $before; Note = 'не потрібен у режимі shared' } }
    $have = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($l in (Get-SetupTextLines $before)) { [void]$have.Add($l.Trim().TrimStart('/')) }
    $added = @($script:IncludeLines | Where-Object { -not $have.Contains($_) })
    if (-not $added) { return @{ Path = $path; Rel = $script:IncludeFile; Before = $before; After = $before; Note = 'уже містить локальні файли' } }
    @{ Path = $path; Rel = $script:IncludeFile; Before = $before; After = (Add-SetupLines -Before $before -Lines $added -Comment 'v8storagekit: гітігноровані файли, що копіюються в кожен новий worktree'); Note = "+$($added.Count) рядків" }
}

function Get-SetupProfileSkeleton {
    <# Каркас профілю: лише знайдені значення, решта — явні TODO. Повертає Text і Todo. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    $profile = [ordered]@{}
    # Новий профіль — перше підключення за поточним плагіном: оновлювати нічого. Сам плагін версії проєкту не має.
    if (-not (Test-KitPluginRepo -Root $Root)) { $profile['kit'] = [ordered]@{ version = (Get-KitPluginInfo).Version } }
    $base = Get-SetupDefaultBranch -Root $Root
    $profile['pr'] = [ordered]@{ base = $(if ($base) { $base } else { 'TODO: головна гілка' }); mergeMethod = 'TODO: squash або merge' }
    $profile['workspace'] = [ordered]@{ mode = $Mode }
    $docs = [ordered]@{}
    foreach ($kind in 'specs', 'plans') {
        $found = @("docs/superpowers/$kind", "docs/$kind") | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Container } | Select-Object -First 1
        $docs[$kind] = if ($found) { $found } else { "TODO: теку $kind не знайдено" }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'docs') -PathType Container) { $docs['docs'] = 'docs' }
    $profile['docs'] = $docs
    # Корпус документів: лише те, що є в репо.
    $corpus = @('AGENTS.md', 'CLAUDE.md', 'README.md') | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf }
    $corpus = @($corpus)
    if (Test-Path -LiteralPath (Join-Path $Root 'docs') -PathType Container) { $corpus += 'docs/**/*.md' }
    foreach ($d in '.agents/skills', '.claude/skills') { if (Test-Path -LiteralPath (Join-Path $Root $d) -PathType Container) { $corpus += "$d/*/SKILL.md" } }
    if ($corpus.Count) { $profile['research'] = [ordered]@{ corpus = [object[]]$corpus } }
    if (Test-SetupIs1C -Root $Root) { $profile['review'] = [ordered]@{ exclude = [object[]]$script:ReviewExclude1C } }
    $text = (ConvertTo-Json -InputObject $profile -Depth 20 -EscapeHandling Default) + "`n"
    @{ Text = $text; Todo = @(Get-SetupTodoFields $profile) }
}

function Get-SetupTodoFields {
    <# Поля профілю зі значенням «TODO…»: шляхи через крапку. #>
    param($Value, [string]$Path = '')
    if ($Value -is [string]) { if ($Value -match '^TODO\b') { $Path }; return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { Get-SetupTodoFields -Value $Value[$k] -Path $(if ($Path) { "$Path.$k" } else { [string]$k }) }
    }
}

function Get-SetupVersionNote {
    <# Наявний профіль із нижчою kit.version: команда його не міняє, версію виставляє скіл onboarding. #>
    param([Parameter(Mandatory)][string]$Root)
    if (Test-KitPluginRepo -Root $Root) { return '' }
    $p = Get-KitProjectVersion -Root $Root
    if ($p.Source -eq 'invalid') { return "; $($p.Error)" }
    $plugin = (Get-KitPluginInfo).Version
    if (-not $p.Version -or (Compare-KitVersion -A $p.Version -B $plugin) -ge 0) { return '' }
    "; kit.version $($p.Version)$(if ($p.Source -eq 'default') { ' (поля немає)' }) < плагін $plugin — оновлення: /v8storagekit:onboarding (kit-scan покаже кроки)"
}

function Get-SetupProfilePlan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    $path = Join-Path $Root $script:ProfileRel
    $before = Read-SetupText $path
    if ($null -ne $before) {
        return @{ Path = $path; Rel = $script:ProfileRel; Before = $before; After = $before; Note = "уже є, не змінено$(Get-SetupVersionNote -Root $Root)" }
    }
    $sk = Get-SetupProfileSkeleton -Root $Root -Mode $Mode
    @{ Path = $path; Rel = $script:ProfileRel; Before = $null; After = $sk.Text; Note = "створено каркас — заповни $($sk.Todo.Count) TODO-полів: $($sk.Todo -join ', ')" }
}

# ---------- команда ----------

function Invoke-KitKitSetup {
    param([AllowEmptyCollection()][string[]]$Arguments = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        DryRun = 'switch'; NoPermissions = 'switch'; NoGitignore = 'switch'; NoProfile = 'switch'; NoWorktreeInclude = 'switch'
    }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    if ($a.Positional.Count) { throw (New-KitUsageError "неочікуваний аргумент '$($a.Positional[0])'") }
    $root = Get-KitCheckoutRoot -Path $RepoRoot
    $dry = [bool]$a.Named['DryRun']

    $data = Get-SetupProfileData -Root $root
    $mode = Get-SetupMode -Root $root -Data $data
    $plans = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $a.Named['NoPermissions']) { $plans.Add((Get-SetupSettingsPlan -Root $root)) }
    if (-not $a.Named['NoGitignore']) { $plans.Add((Get-SetupGitignorePlan -Root $root -Mode $mode -Data $data)) }
    if (-not $a.Named['NoProfile']) { $plans.Add((Get-SetupProfilePlan -Root $root -Mode $mode)) }
    if (-not $a.Named['NoWorktreeInclude']) { $plans.Add((Get-SetupWorktreeIncludePlan -Root $root -Mode $mode)) }
    # Помилка будь-якого файла — до першого запису: не пишемо нічого.
    $broken = $plans | Where-Object { $_.ContainsKey('Error') } | Select-Object -First 1
    if ($broken) { throw (New-KitNotChecked $broken.Error) }

    $changed = @($plans | Where-Object { $_.After -cne $_.Before })
    foreach ($p in $changed) {
        if ($dry) { Write-KitLine (Get-SetupUnifiedDiff -Rel $p.Rel -Before $p.Before -After $p.After) }
        else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $p.Path) -Force | Out-Null
            [System.IO.File]::WriteAllText($p.Path, $p.After, [System.Text.UTF8Encoding]::new($false))
        }
    }
    Write-KitLine "kit-setup$(if ($dry) { ' -DryRun (нічого не записано)' }): $root; режим $mode"
    foreach ($p in $plans) { Write-KitLine "  $($p.Rel): $($p.Note)" }
    if (-not $changed) { Write-KitLine 'нічого міняти' }
    Write-KitNext 'kit-scan'
    return 0
}

Export-ModuleMember -Function Invoke-KitKitSetup
