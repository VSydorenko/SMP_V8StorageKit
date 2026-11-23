#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-setup, modified.
Set-StrictMode -Version Latest

<#
    Разове підключення проєкту до процесу v8storagekit. Плагін не може постачати правила дозволів
    (обмеження Claude Code), тож ця команда зливає .claude/settings.json проєкту з цільовим станом —
    templates/settings.json плагіна, єдиним джерелом правил (ADR-0017). Без питання — локальні
    команди (читання, запис у .agents/, тимчасові дерева) і pr-gate open|ready|land, межі яких тримає
    код pr-gate; голі git push, gh pr create|merge, gh release — з питанням; track spec|milestone і сам
    kit-setup — теж.

    Злиття settings.json (спека §5.2 (а)–(г)): (а) правило шаблону додається до списку, якщо його немає
    в ТОМУ САМОМУ списку проєкту; до allow — лише якщо його не ПОКРИВАЄ правило ask чи deny проєкту чи
    шаблону (строгіше рішення перемагає; D13 за рев'ю безпеки — Test-SetupRuleCovered: форма-близнюк
    Bash ≡ PowerShell, префікс на межі слова, :* ≡ " *", ціле ім'я інструмента); правила Уніки з allow
    шаблону — лише в репозиторії 1С, ask і deny — завжди; (б) з allow і ask прибираються правила, що ТОЧНО
    (з урахуванням регістру) збігаються з застарілими іменами Уніки (tools/assets/obsolete-names.json);
    (в) unica_apply з allow переходить в ask; (г) з hooks.SessionStart[].hooks[] прибирається елемент
    старого шима kit — шлях .claude/hooks/session-start.ps1 окремим токеном, перед ним лише початок,
    пробіл, лапка, ./ чи $CLAUDE_PROJECT_DIR/ (не хук рівня користувача і не складена команда); група,
    SessionStart і hooks — лише коли спорожніли.
    deny проєкту не змінюється ніколи, крім дописування; власні правила й хуки проєкту лишаються. Широкі
    правила першого покоління (pr-gate:*, track:*, git branch:*) не прибираються — команда називає, чим
    їх замінити. Решту файлів (.gitignore, профіль, .worktreeinclude) команда лише доповнює.

    Ідемпотентно: другий запуск нічого не змінює. -DryRun друкує точний diff кожного файла (власним
    кодом, без зовнішнього diff) і нічого не пише. Запис — один помічник Write-SetupFiles: JSON-результат
    розбирається в пам'яті, можливість запису всіх цілей перевіряється до першої заміни, кожен файл
    пишеться в тимчасовий поруч і лише потім атомарно замінює ціль.

    Змін проти оригіналу: параметри PowerShell-стилем; кожне правило дозволу у двох формах — Bash(…) і
    PowerShell(…) (виміряно 2026-11-20 у Claude Code 2.1.329: PowerShell(session-cost:*) пропускає виклик
    інструментом PowerShell, а Bash(session-cost:*) — ні); перелік команд — команди цього плагіна;
    без .cbmignore, без JS-детекції (package.json, ESLint), без лематизатора й без сторожа git
    (ADR-0007); корінь worktree в .gitignore і .worktreeinclude — лише в режимі worktree.
#>

# Цільові правила дозволів — шаблон плагіна (D8); власного переліку команд тут немає.
$script:TemplateRel = 'templates/settings.json'
$script:PermLists = @('allow', 'ask', 'deny')
# Правила Уніки: з allow шаблону — лише в репозиторії 1С (D9).
$script:UnicaRulePrefix = 'mcp__plugin_unica_unica__'
# (в): шаблон тримає unica_apply в ask; з allow проєкту він переходить туди ж.
$script:UnicaApply = 'mcp__plugin_unica_unica__unica_apply'
# (г): шим kit за історію мав одну форму (pwsh -NoProfile -File .claude/hooks/session-start.ps1). Шлях —
# окремим токеном (після заміни \ на /): перед ним лише початок, пробіл чи лапка з необов'язковим ./ або
# $CLAUDE_PROJECT_DIR/ (${…}, у лапках чи без); після — кінець, пробіл чи лапка. Довільний / перед шляхом
# (~/.claude/…, $HOME/…, абсолютні шляхи — хуки рівня користувача чи чужого дерева) — не збіг. Навмисно
# вужче за Test-KitLegacySessionHook (D12).
$script:ShimPattern = '(?<=^|[\s"''])(?:\./|"?\$\{?CLAUDE_PROJECT_DIR\}?"?/)?\.claude/hooks/session-start\.ps1(?=$|[\s"''])'
# Складена команда (&&, ;, |, &, новий рядок) — невідома форма: не прибираємо, навіть зі шимом усередині.
$script:CompoundPattern = '[;&|\r\n]'
# Широкі правила старих налаштувань: дозволяють більше, ніж треба, без питання. Не прибираємо
# (прибирання — лише точні застарілі імена Уніки й шим) — кажемо власнику, чим замінити. Значення —
# порада повністю: вона різна для правила, вузької заміни якого шаблон не має.
$script:BroadOld = [ordered]@{
    'Bash(pr-gate:*)'          = 'дозволяє й майбутні підкоманди pr-gate без рішення; заміни на Bash(pr-gate start:*), Bash(pr-gate cleanup:*), Bash(pr-gate scratch:*), Bash(pr-gate open:*), Bash(pr-gate ready:*), Bash(pr-gate land:*); прибери вручну (вузькі правила покривають безпечні кроки)'
    'PowerShell(pr-gate:*)'    = 'дозволяє й майбутні підкоманди pr-gate без рішення; заміни на PowerShell(pr-gate start:*), PowerShell(pr-gate cleanup:*), PowerShell(pr-gate scratch:*), PowerShell(pr-gate open:*), PowerShell(pr-gate ready:*), PowerShell(pr-gate land:*); прибери вручну (вузькі правила покривають безпечні кроки)'
    'Bash(track:*)'            = 'дозволяє й track spec|milestone (GitHub) без питання; заміни на Bash(track status:*); прибери вручну (вузькі правила покривають безпечні кроки)'
    'PowerShell(track:*)'      = 'дозволяє й track spec|milestone (GitHub) без питання; заміни на PowerShell(track status:*); прибери вручну (вузькі правила покривають безпечні кроки)'
    'Bash(git branch:*)'       = 'пропускає й git branch -D/-f, зокрема на storage/*; заміни на Bash(git branch --list:*), Bash(git branch --show-current); прибери вручну (вузькі правила покривають безпечні кроки)'
    'PowerShell(git branch:*)' = 'пропускає й git branch -D/-f, зокрема на storage/*; прибери вручну. Вузької PowerShell-форми шаблон не має (читальні git-правила — лише Bash): після цього читання гілок інструментом PowerShell піде з питанням, а без питання — через Bash(git branch --list:*), Bash(git branch --show-current)'
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

Разове підключення поточного репозиторію до процесу v8storagekit й оновлення після нової версії
плагіна. Ідемпотентно: другий запуск нічого не змінює.

  permissions  злити $script:SettingsFile з цільовим станом — $script:TemplateRel плагіна:
               (а) дописати правила шаблону, яких немає в тому самому списку (allow, ask, deny);
                   в allow — лише те, чого не покриває ask чи deny проєкту чи шаблону: Bash(X) і
                   PowerShell(X) — одне правило, p:* покриває «p» і «p …» (не «pX»), :* = " *",
                   голе Bash чи PowerShell — увесь інструмент; правила Уніки в allow — лише в
                   репозиторії 1С (v8storagekit.yaml чи v8project.yaml);
               (б) прибрати з allow і ask точні застарілі імена Уніки (tools/assets/obsolete-names.json);
               (в) перенести unica_apply з allow в ask;
               (г) прибрати з hooks.SessionStart елемент старого шима .claude/hooks/session-start.ps1
                   (файл шима не видаляється; хуки рівня користувача й складені команди не чіпаються).
               deny проєкту й власні правила й хуки не прибираються. Без питання — локальні команди
               процесу й pr-gate open|ready|land; git push, gh pr create|merge, gh release,
               track spec|milestone і kit-setup — з питанням. Широкі правила pr-gate:*, track:* і
               git branch:* не прибираються — команда називає, чим їх замінити
  gitignore    дописати .agents/out/, .agents/sdd/, <private.dir>/, .agents/briefs/,
               $script:LocalProfileRel; у режимі worktree ще й <worktrees.root>/
  profile      створити $script:ProfileRel зі знайденими значеннями й TODO-маркерами, лише якщо його
               немає; новий профіль отримує kit.version = версія плагіна. Наявний профіль не
               змінюється: нижчу kit.version команда називає (оновлення — /v8storagekit:onboarding)
  worktreeinclude  лише в режимі worktree: дописати $($script:IncludeLines -join ', ') до
               $script:IncludeFile (гітігноровані файли, що копіюються в кожен новий worktree)
  -DryRun      надрукувати точний diff кожного файла, нічого не писати
  -NoPermissions  не чіпати $script:SettingsFile зовсім (ні дописування, ні прибирання)

Режим workspace.mode: з наявного профілю; інакше shared, якщо в корені є v8storagekit.yaml або будь-де
v8project.yaml, інакше worktree.
Вихід: 0 готово (або нічого міняти); 2 помилка виклику; 3 не git-репозиторій, файл проєкту чи
плагіна (шаблон, застарілі імена) не читається або результат не розбирається — тоді не записано нічого.
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
    # ConvertTo-Json пише Environment.NewLine (на Windows — CRLF): спершу до LF, потім — кінці рядків файла.
    $text = ((ConvertTo-Json -InputObject $Data -Depth 50 -EscapeHandling Default) -replace "`r`n", "`n") + "`n"
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

function Test-SetupJsonArray {
    <# Значення — JSON-масив (не рядок і не об'єкт). #>
    param($Value)
    $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary] -and $Value -is [System.Collections.IEnumerable]
}

function Test-SetupHasRule {
    <# Чи є правило в списку: точний збіг рядка з урахуванням регістру (D13). #>
    param($List, [Parameter(Mandatory)][string]$Rule)
    foreach ($x in $List) { if ($x -is [string] -and $x -ceq $Rule) { return $true } }
    $false
}

function ConvertTo-SetupRuleShape {
    <#
        Розбір правила для покриття (D13): Shell — Bash чи PowerShell (форми-близнюки) або $null; Whole — ціле
        ім'я інструмента без дужок чи (*); Prefix — команда правила з суфіксом :* чи " *" (без суфікса);
        Exact — тіло правила без такого суфікса. Не оболонка — лише рядок (точний збіг).
    #>
    param([Parameter(Mandatory)][string]$Rule)
    $m = [regex]::Match($Rule, '^(?<tool>Bash|PowerShell)(?:\((?<body>.*)\))?$')
    if (-not $m.Success) { return [pscustomobject]@{ Shell = $null; Whole = $false; Prefix = $null; Exact = $null } }
    $shape = [pscustomobject]@{ Shell = 'shell'; Whole = $false; Prefix = $null; Exact = $null }
    if (-not $m.Groups['body'].Success -or $m.Groups['body'].Value -ceq '*') { $shape.Whole = $true; return $shape }
    $body = $m.Groups['body'].Value
    if ($body.EndsWith(':*', [System.StringComparison]::Ordinal) -or $body.EndsWith(' *', [System.StringComparison]::Ordinal)) {
        $shape.Prefix = $body.Substring(0, $body.Length - 2)
    } else { $shape.Exact = $body }
    $shape
}

function Test-SetupRuleCovered {
    <#
        Чи покриває правило з $By (ask чи deny проєкту або шаблону) правило $Rule — тоді воно в allow не йде
        (D13, уточнено за рев'ю безпеки). Форма-близнюк: Bash(X) ≡ PowerShell(X). Ціле ім'я Bash/PowerShell (чи
        (*)) покриває все обох форм. Префікс на межі слова: p:* покриває q (q — префікс чи точне тіло $Rule),
        коли q == p або q починається з «p ». Правило без суфікса покриває лише точне тіло. Не оболонка — точний
        рядок. Регістр — як у Claude Code: враховується.
    #>
    param([Parameter(Mandatory)][string]$Rule, $By)
    $r = ConvertTo-SetupRuleShape $Rule
    foreach ($c in $By) {
        if ($c -isnot [string]) { continue }
        if ($c -ceq $Rule) { return $true }
        if (-not $r.Shell) { continue }
        $s = ConvertTo-SetupRuleShape $c
        if (-not $s.Shell) { continue }
        if ($s.Whole) { return $true }
        if ($r.Whole) { continue }
        $q = if ($null -ne $r.Prefix) { $r.Prefix } else { $r.Exact }
        if ($null -ne $s.Prefix) {
            if ($q -ceq $s.Prefix -or $q.StartsWith($s.Prefix + ' ', [System.StringComparison]::Ordinal)) { return $true }
        } elseif ($null -ne $r.Exact -and $r.Exact -ceq $s.Exact) { return $true }
    }
    $false
}

function Get-SetupTemplateRules {
    <#
        Цільові правила — permissions шаблону templates/settings.json плагіна (D8): allow, ask, deny.
        Без ознак 1С allow — без правил Уніки (D9); ask і deny — повністю. Не читається — «не перевірено».
    #>
    param([Parameter(Mandatory)][bool]$Is1C)
    $path = Join-Path (Get-KitPluginRoot) $script:TemplateRel
    $text = Read-SetupText $path
    if ($null -eq $text) { throw (New-KitNotChecked "немає шаблону дозволів $path") }
    try { $t = ConvertFrom-SetupJson $text } catch { throw (New-KitNotChecked "не читається шаблон ${path}: $($_.Exception.Message)") }
    $perm = Get-SetupField $t 'permissions'
    if (-not ($perm -is [System.Collections.IDictionary])) { throw (New-KitNotChecked "шаблон ${path}: permissions — не об'єкт") }
    $rules = [ordered]@{}
    foreach ($l in $script:PermLists) {
        # Не через вираз if: він розгорнув би одноелементний масив у рядок.
        $v = $null
        if ($perm.Contains($l)) { $v = $perm[$l] }
        if (-not (Test-SetupJsonArray $v)) { throw (New-KitNotChecked "шаблон ${path}: permissions.$l — не масив") }
        $rules[$l] = [string[]]@($v)
    }
    if (-not $Is1C) {
        $rules['allow'] = [string[]]@($rules['allow'] | Where-Object { -not $_.StartsWith($script:UnicaRulePrefix, [System.StringComparison]::Ordinal) })
    }
    $rules
}

function Test-SetupShimHook {
    <# Елемент hooks[] — старий шим kit: команда-рядок із шляхом шима окремим токеном (D12). #>
    param($Hook)
    if (-not ($Hook -is [System.Collections.IDictionary]) -or -not $Hook.Contains('command') -or $Hook['command'] -isnot [string]) { return $false }
    $cmd = $Hook['command']
    if ($cmd -match $script:CompoundPattern) { return $false }
    ($cmd -replace '\\', '/') -cmatch $script:ShimPattern
}

function Remove-SetupShimHook {
    <#
        (г) Прибирає з hooks.SessionStart[].hooks[] елементи старого шима; повертає їх кількість. Група —
        лише коли її hooks[] спорожнів через це прибирання; SessionStart і hooks — так само. Невідомі
        форми (не об'єкт, не масив) не чіпає.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $hooks = if ($Data.Contains('hooks')) { $Data['hooks'] } else { $null }
    if (-not ($hooks -is [System.Collections.IDictionary]) -or -not $hooks.Contains('SessionStart')) { return 0 }
    $groups = $hooks['SessionStart']
    if (-not (Test-SetupJsonArray $groups)) { return 0 }
    $removed = 0
    $keptGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        $inner = $null
        if ($g -is [System.Collections.IDictionary] -and $g.Contains('hooks')) { $inner = $g['hooks'] }
        if (-not (Test-SetupJsonArray $inner)) { $keptGroups.Add($g); continue }
        $keptHooks = [System.Collections.Generic.List[object]]::new()
        $n = 0
        foreach ($h in $inner) { if (Test-SetupShimHook $h) { $n++ } else { $keptHooks.Add($h) } }
        if (-not $n) { $keptGroups.Add($g); continue }
        $removed += $n
        if ($keptHooks.Count) { $g['hooks'] = [object[]]$keptHooks.ToArray(); $keptGroups.Add($g) }
    }
    if (-not $removed) { return 0 }
    if ($keptGroups.Count) { $hooks['SessionStart'] = [object[]]$keptGroups.ToArray() }
    else {
        $hooks.Remove('SessionStart')
        if (-not $hooks.Count) { $Data.Remove('hooks') }
    }
    $removed
}

function Get-SetupSettingsPlan {
    <#
        Злиття settings.json проєкту з шаблоном (§5.2 (а)–(г), D9, D12, D13). Порядок ключів, чужі правила
        й хуки лишаються; deny проєкту лише доповнюється. Нічого міняти — After = Before (файл не
        переписується).
    #>
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root $script:SettingsFile
    $before = Read-SetupText $path
    $data = [ordered]@{}
    if ($null -ne $before) {
        try { $data = ConvertFrom-SetupJson $before } catch { return @{ Error = "не читається $($script:SettingsFile): $($_.Exception.Message)" } }
        if (-not ($data -is [System.Collections.IDictionary])) { return @{ Error = "$($script:SettingsFile) — не JSON-об'єкт" } }
    }
    $perm = if ($data.Contains('permissions')) { $data['permissions'] } else { $null }
    if ($null -ne $perm -and -not ($perm -is [System.Collections.IDictionary])) { return @{ Error = "$($script:SettingsFile): permissions — не об'єкт" } }
    $cur = [ordered]@{}
    foreach ($l in $script:PermLists) {
        # Не через вираз if: він розгорнув би одноелементний масив у рядок.
        $v = $null
        if ($null -ne $perm -and $perm.Contains($l)) { $v = $perm[$l] }
        if ($null -ne $v -and -not (Test-SetupJsonArray $v)) { return @{ Error = "$($script:SettingsFile): permissions.$l — не масив" } }
        $cur[$l] = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $v) { foreach ($x in $v) { $cur[$l].Add($x) } }
    }
    $tpl = Get-SetupTemplateRules -Is1C (Test-SetupIs1C -Root $Root)
    $obsolete = [string[]]@((Get-KitObsoleteNames).UnicaTools)

    # (б) Застарілі імена Уніки — точний збіг, лише allow і ask. deny не чіпаємо ніколи.
    $dropped = 0
    foreach ($l in 'allow', 'ask') {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($x in $cur[$l]) { if ($x -is [string] -and $obsolete -ccontains $x) { $dropped++ } else { $kept.Add($x) } }
        $cur[$l] = $kept
    }
    # (в) unica_apply: з allow — в ask.
    $moved = Test-SetupHasRule $cur['allow'] $script:UnicaApply
    if ($moved) {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($x in $cur['allow']) { if (-not ($x -is [string] -and $x -ceq $script:UnicaApply)) { $kept.Add($x) } }
        $cur['allow'] = $kept
        if (-not (Test-SetupHasRule $cur['ask'] $script:UnicaApply)) { $cur['ask'].Add($script:UnicaApply) }
    }
    # (а) Правила шаблону, яких немає в тому самому списку; в allow — лише те, чого не покриває ask чи
    # deny ні проєкту, ні шаблону (строгіше рішення перемагає; D13 — Test-SetupRuleCovered).
    $added = [ordered]@{ allow = 0; ask = 0; deny = 0 }
    $stricter = @($cur['ask']) + @($cur['deny']) + @($tpl['ask']) + @($tpl['deny'])
    foreach ($l in 'deny', 'ask', 'allow') {
        foreach ($r in $tpl[$l]) {
            if (Test-SetupHasRule $cur[$l] $r) { continue }
            if ($l -eq 'allow' -and (Test-SetupRuleCovered -Rule $r -By $stricter)) { continue }
            $cur[$l].Add($r)
            $added[$l]++
        }
    }
    # (г) Елемент старого шима в hooks.SessionStart.
    $shim = Remove-SetupShimHook -Data $data

    # Попередження — без урахування регістру: тут ширше безпечніше (нічого не прибирається).
    $warn = (@($script:BroadOld.Keys | Where-Object { @($cur['allow']) -contains $_ } | ForEach-Object {
                "`n  власнику: $_ ширше за потрібне — $($script:BroadOld[$_])"
            }) -join '')
    $plan = @{ Path = $path; Rel = $script:SettingsFile; Before = $before; After = $before; Json = $true; Note = "дозволи вже за шаблоном$warn" }
    $addedTotal = $added['allow'] + $added['ask'] + $added['deny']
    if (-not ($addedTotal -or $dropped -or $moved -or $shim)) { return $plan }

    if ($null -eq $perm) { $perm = [ordered]@{}; $data['permissions'] = $perm }
    foreach ($l in $script:PermLists) {
        if ($perm.Contains($l) -or $cur[$l].Count) { $perm[$l] = [object[]]$cur[$l].ToArray() }
    }
    $plan.After = Get-SetupJsonText -Data $data -Before $before
    $parts = @(
        foreach ($l in $script:PermLists) { if ($added[$l]) { "+$($added[$l]) $l" } }
        if ($dropped) { "−$dropped застарілих імен Уніки (allow/ask)" }
        if ($moved) { 'unica_apply: allow → ask' }
        if ($shim) { "−$shim елемент(и) старого шима в hooks.SessionStart (файл .claude/hooks/session-start.ps1 — прибрати з git окремо)" }
    )
    $plan.Note = "$($parts -join '; ') — власнику: перегляньте цей diff (правила allow агенти виконують без питання)$warn"
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
    @{ Path = $path; Rel = $script:ProfileRel; Before = $null; After = $sk.Text; Json = $true; Note = "створено каркас — заповни $($sk.Todo.Count) TODO-полів: $($sk.Todo -join ', ')" }
}

# ---------- запис ----------

function Get-SetupErrorText {
    <# Один рядок причини збою вводу-виводу: без обгортки виклику методу й без стеку. #>
    param([Parameter(Mandatory)]$ErrorRecord)
    $e = $ErrorRecord.Exception
    if ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    $e.Message
}

function Write-SetupFiles {
    <#
        Єдиний запис файлів kit-setup (D13). Етапи — від дешевого до незворотного:
          1) JSON-результат (Json = $true) розбирається з пам'яті;
          2) кожна наявна ціль відкривається на запис (read-only, права, чуже блокування) — до першої заміни;
          3) текст кожного файла пишеться в тимчасовий поруч із ціллю (теки, яких не було, запам'ятовуються);
          4) кожен тимчасовий файл замінює ціль перейменуванням у тій самій теці (File.Move з overwrite:
             MoveFileEx REPLACE_EXISTING — атомарно в межах тому); недописаного файла-цілі не буває.
        Збій на етапах 1–3 — жодну ціль не змінено. Збій на етапі 4 (ціль змінилась після перевірки) — у тексті
        перелік уже записаних і незаписаних файлів; повторний kit-setup допише решту (він ідемпотентний). Будь-який
        збій — «не перевірено» (код 3) одним рядком причини, без сирого винятку .NET; тимчасові файли й порожні
        створені теки прибрано.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plans)
    foreach ($p in $Plans) {
        if ($p.ContainsKey('Json') -and $p.Json) {
            try { $null = ConvertFrom-SetupJson $p.After }
            catch { throw (New-KitNotChecked "$($p.Rel): результат не розбирається як JSON — не записано нічого: $(Get-SetupErrorText $_)") }
        }
    }
    foreach ($p in $Plans) {
        if (-not (Test-Path -LiteralPath $p.Path -PathType Leaf)) { continue }
        try { [System.IO.File]::Open($p.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None).Dispose() }
        catch { throw (New-KitNotChecked "$($p.Rel) недоступний для запису — не записано нічого: $(Get-SetupErrorText $_)") }
    }
    $staged = [System.Collections.Generic.List[object]]::new()
    $madeDirs = [System.Collections.Generic.List[string]]::new()
    $done = [System.Collections.Generic.List[string]]::new()
    $ok = $false
    try {
        foreach ($p in $Plans) {
            $dir = Split-Path -Parent $p.Path
            try {
                $d = $dir
                while ($d -and -not (Test-Path -LiteralPath $d -PathType Container)) { $madeDirs.Add($d); $d = Split-Path -Parent $d }
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $tmp = Join-Path $dir ".$(Split-Path -Leaf $p.Path).kit-setup-$([guid]::NewGuid().ToString('N')).tmp"
                $staged.Add(@($tmp, $p.Path, $p.Rel))
                [System.IO.File]::WriteAllText($tmp, $p.After, [System.Text.UTF8Encoding]::new($false))
            } catch { throw (New-KitNotChecked "$($p.Rel): тимчасовий файл не записано — не записано нічого: $(Get-SetupErrorText $_)") }
        }
        for ($i = 0; $i -lt $staged.Count; $i++) {
            $s = $staged[$i]
            try { [System.IO.File]::Move($s[0], $s[1], $true) }
            catch {
                $rest = @(for ($k = $i; $k -lt $staged.Count; $k++) { $staged[$k][2] })
                $written = if ($done.Count) { $done -join ', ' } else { 'нічого' }
                throw (New-KitNotChecked "запис перервано на $($s[2]): $(Get-SetupErrorText $_). Уже записано: $written; не записано: $($rest -join ', '). Повторний kit-setup допише решту")
            }
            $done.Add($s[2])
        }
        $ok = $true
    } finally {
        # Після успіху тимчасових файлів уже немає; після збою — прибираємо їх і порожні теки, створені тут.
        foreach ($s in $staged) { if (Test-Path -LiteralPath $s[0]) { Remove-Item -LiteralPath $s[0] -Force -ErrorAction SilentlyContinue } }
        if (-not $ok) {
            foreach ($d in $madeDirs) {
                if ((Test-Path -LiteralPath $d -PathType Container) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) {
                    Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
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
    if ($dry) { foreach ($p in $changed) { Write-KitLine (Get-SetupUnifiedDiff -Rel $p.Rel -Before $p.Before -After $p.After) } }
    elseif ($changed) { Write-SetupFiles -Plans $changed }
    Write-KitLine "kit-setup$(if ($dry) { ' -DryRun (нічого не записано)' }): $root; режим $mode"
    foreach ($p in $plans) { Write-KitLine "  $($p.Rel): $($p.Note)" }
    if (-not $changed) { Write-KitLine 'нічого міняти' }
    Write-KitNext 'kit-scan'
    return 0
}

Export-ModuleMember -Function Invoke-KitKitSetup
