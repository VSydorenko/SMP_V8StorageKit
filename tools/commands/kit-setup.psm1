#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-setup, modified.
Set-StrictMode -Version Latest

<#
    Разове підключення проєкту до процесу v8storagekit. Плагін не може постачати правила дозволів
    (обмеження Claude Code), але права НЕ автоматизуються (рішення власника 2026-11-23): kit-setup НІКОЛИ не
    пише .claude/settings.json — ні додавання, ні прибирання, ні шим. Замість злиття — звіт лише для читання про
    відхилення проєкту від цільового стану, templates/settings.json плагіна, єдиного еталона правил (ADR-0017):
    правила шаблону, яких немає в проєкті (allow/ask/deny окремо; D9 — allow Уніки лише в репо 1С; правила
    allow, на перший токен яких у проєкті є ask/deny, — окремим підкласом «додавати лише свідомо», D13);
    точні застарілі імена Уніки в allow/ask; unica_apply в allow; старий шим hooks.SessionStart (дослівна
    команда, D12); широкі правила pr-gate:*, track:*, git branch:*; відсутні pr-gate open|ready|land. Додає чи
    прибирає правила людина або агент за її згодою штатними засобами Claude Code.

    Решту файлів (.gitignore, профіль, .worktreeinclude) команда лише доповнює. Новий профіль — без v8storagekit.version:
    поле пише окремий режим -SetVersion останнім комітом PR (D7), читаючи лише сирий проєктний профіль.

    Ідемпотентно: другий запуск нічого не змінює. -DryRun друкує точний diff кожного файла (власним
    кодом, без зовнішнього diff) і нічого не пише. Запис — один помічник Write-SetupFiles: JSON-результат
    розбирається в пам'яті, можливість запису всіх цілей перевіряється до першої заміни, кожен файл
    пишеться в тимчасовий поруч і лише потім атомарно замінює ціль. Невалідний settings.json — код 3 до
    будь-якого запису (звіт не перевірено).

    Змін проти оригіналу: параметри PowerShell-стилем; перелік команд — команди цього плагіна;
    без .cbmignore, без JS-детекції (package.json, ESLint), без лематизатора й без сторожа git
    (ADR-0007); корінь worktree в .gitignore і .worktreeinclude — лише в режимі worktree.
#>
# Цільові правила дозволів — шаблон плагіна (D8); власного переліку команд тут немає.
$script:TemplateRel = 'templates/settings.json'
$script:PermLists = @('allow', 'ask', 'deny')
# Правила Уніки: з allow шаблону — лише в репозиторії 1С (D9).
$script:UnicaRulePrefix = 'mcp__plugin_unica_unica__'
# Шаблон тримає unica_apply в ask; з allow проєкту він переходить туди ж.
$script:UnicaApply = 'mcp__plugin_unica_unica__unica_apply'
# Правила pr-gate open|ready|land (ADR-0017): окремий рядок звіту.
$script:PrGateRule = '^(?:Bash|PowerShell)\(pr-gate (?:open|ready|land):'
# Шим kit за історію мав одну форму — pwsh -NoProfile -File .claude/hooks/session-start.ps1. Збіг — уся
# команда (після обрізання пробілів по краях), заякорена з обох боків: шлях з / чи \, з необов'язковим ./ або
# $CLAUDE_PROJECT_DIR/ (${…}), сам шлях у лапках "…"/'…' чи без, або лапки лише навколо змінної. Будь-яка
# інша команда (інша програма, інші прапорці, складена, хук рівня користувача) — не шим kit, лишається.
# Навмисно вужче за Test-KitLegacySessionHook (D12).
$script:ShimPattern = '\Apwsh -NoProfile -File (?:(?<q>["'']?)(?:\.[/\\]|\$(?:CLAUDE_PROJECT_DIR|\{CLAUDE_PROJECT_DIR\})[/\\])?\.claude[/\\]hooks[/\\]session-start\.ps1\k<q>|"\$(?:CLAUDE_PROJECT_DIR|\{CLAUDE_PROJECT_DIR\})"[/\\]\.claude[/\\]hooks[/\\]session-start\.ps1)\z'
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
# Профіль без v8storagekit.version: той самий текст, що стан no-version kit-scan (D6).
$script:SetVersionNote = 'v8storagekit.version немає — запише `kit-setup -SetVersion` останнім комітом PR'
$script:DefaultWorktreesRoot = '.worktrees'
$script:DefaultPrivateDir = '.agents/private'
# Згенеровані платформою файли вивантаження: без шуму в рев'ю (джерела — у звіті задачі).
$script:ReviewExclude1C = @('**/ConfigDumpInfo.xml', '**/DumpFilesIndex.txt')

$script:Usage = @"
kit-setup [-DryRun] [-Json] [-NoPermissions] [-NoGitignore] [-NoProfile] [-NoWorktreeInclude]
kit-setup -SetVersion [-DryRun]

Разове підключення поточного репозиторію до процесу v8storagekit й оновлення після нової версії
плагіна. Ідемпотентно: другий запуск нічого не змінює.

  permissions  ЗВІТ (лише читання) про $script:SettingsFile відносно $script:TemplateRel плагіна. kit цей файл
               не пише НІКОЛИ (права не автоматизуються): показує, що додати чи прибрати, а правки —
               людина чи агент штатними засобами Claude Code, за згодою людини. Класи звіту:
                 - правила шаблону, яких немає в allow/ask/deny проєкту (allow Уніки — лише в
                   репозиторії 1С: v8storagekit.yaml чи v8project.yaml); підклас: у проєкті є ask/deny
                   на перший токен команди — такі правила allow додавати лише свідомо;
                 - точні застарілі імена Уніки в allow/ask (tools/assets/obsolete-names.json);
                 - unica_apply в allow, коли шаблон тримає його в ask;
                 - старий шим hooks.SessionStart (pwsh -NoProfile -File .claude/hooks/session-start.ps1);
                 - широкі правила pr-gate:*, track:*, git branch:*;
                 - відсутні pr-gate open|ready|land (ADR-0017)
  gitignore    дописати .agents/out/, .agents/sdd/, <private.dir>/, .agents/briefs/,
               $script:LocalProfileRel; у режимі worktree ще й <worktrees.root>/
  profile      створити $script:ProfileRel зі знайденими значеннями й TODO-маркерами обов'язкових
               полів, лише якщо його немає; docs.specs/docs.plans без знайденої теки — без поля. Новий
               профіль — БЕЗ v8storagekit.version: її пише -SetVersion останнім комітом PR. Наявний профіль не
               змінюється: відсутню чи нижчу v8storagekit.version команда називає (оновлення — /v8storagekit:onboarding)
  worktreeinclude  лише в режимі worktree: дописати $($script:IncludeLines -join ', ') до
               $script:IncludeFile (гітігноровані файли, що копіюються в кожен новий worktree)
  -DryRun      надрукувати точний diff кожного файла, нічого не писати
  -Json        вивести результат одним JSON-об'єктом (для агента): файли й звіт permissions
  -NoPermissions  без звіту про $script:SettingsFile (і без розділу permissions у -Json)
  -SetVersion  окремий режим: v8storagekit.version у наявному $script:ProfileRel = версія плагіна, решта
               профілю без змін; читає лише сам цей файл (не $script:LocalProfileRel і не машинний шар).
               З ним — лише -DryRun. Профілю немає — код 1 (спершу kit-setup); профіль не JSON-об'єкт —
               код 3, не записано; v8storagekit.version новіша за плагін — код 1 (онови плагін)

Режим workspace.mode: з наявного профілю; інакше shared, якщо в корені є v8storagekit.yaml або будь-де
v8project.yaml, інакше worktree.
Вихід: 0 готово (або нічого міняти); 1 -SetVersion не виконано (профілю немає, v8storagekit.version новіша за
плагін, репозиторій самого плагіна); 2 помилка виклику; 3 не git-репозиторій, файл проєкту чи
плагіна (шаблон, застарілі імена) не читається або результат не розбирається (зокрема невалідний
$($script:SettingsFile): звіт не перевірено) — тоді не записано нічого.
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


function ConvertFrom-SetupJson {
    <# JSON → впорядкована хеш-таблиця; рядки-дати лишаються рядками. Помилка — виняток. #>
    param([Parameter(Mandatory)][string]$Text)
    $p = @{ AsHashtable = $true; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $p['DateKind'] = 'String' }
    $Text | ConvertFrom-Json @p
}

function Get-SetupJsonText {
    <# Текст JSON-файла kit-setup: LF, кінцевий перевід рядка; кінці рядків наявного файла (CRLF) зберігаються. #>
    param([Parameter(Mandatory)]$Data, [AllowNull()][string]$Before)
    # ConvertTo-Json пише Environment.NewLine (на Windows — CRLF): спершу до LF, потім — кінці рядків файла.
    $text = ((ConvertTo-Json -InputObject $Data -Depth 50 -EscapeHandling Default) -replace "`r`n", "`n") + "`n"
    if ((Get-SetupNewline $Before) -eq "`r`n") { $text = $text -replace "`n", "`r`n" }
    $text
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

function Get-SetupShellToken {
    <#
        Перший токен команди правила оболонки (D13, перебудовано за рев'ю безпеки). $null — не правило оболонки
        (MCP тощо). Bash і PowerShell — одна оболонка; ім'я інструмента — без урахування регістру (у разі сумніву —
        оболонка). Перший токен — тіло до першого пробілу чи «:». Ціле ім'я інструмента, порожнє чи «*» тіло й
        тіло, що не розбирається, дають «*» — маску на будь-яку команду.
    #>
    param([Parameter(Mandatory)][string]$Rule)
    if ($Rule -notmatch '^\s*(?:bash|powershell)(?![A-Za-z0-9_])') { return $null }
    $m = [regex]::Match($Rule, '\A(?i:bash|powershell)\((?<body>.*)\)\z', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return '*' }
    $tok = [regex]::Match($m.Groups['body'].Value.Trim(), '\A[^\s:]*').Value
    if ($tok -eq '') { return '*' }
    $tok
}

function Get-SetupAllowBlock {
    <#
        Чи зачіпає правило шаблону $Rule якесь правило $By — ВХІДНИХ ask і deny проєкту (D13, перебудовано за
        рев'ю безпеки; у разі сумніву — блокувати). Повертає ключ групи рядка «не додано» (перший токен
        команди; для не-оболонки — саме правило) або $null — тоді правило можна додати в allow.
        Правило оболонки блокує будь-яке правило оболонки проєкту (Bash ≡ PowerShell), чий перший токен
        (1) — маска «*» (ціле ім'я, порожнє тіло, не розбирається), (2) містить «*», і частина до «*» —
        посимвольний префікс токена правила шаблону (pr-gate*, pr*), або (3) без «*» дорівнює йому, незалежно
        від решти тіла. Порівняння токенів — без урахування регістру (ширше блокує). Не оболонка — лише
        точний рядок.
    #>
    param([Parameter(Mandatory)][string]$Rule, $By)
    $t = Get-SetupShellToken $Rule
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($c in $By) {
        if ($c -isnot [string]) { continue }
        if ($null -eq $t) { if ($c -ceq $Rule) { return $Rule }; continue }
        $s = Get-SetupShellToken $c
        if ($null -eq $s) { continue }
        if ($t.Contains('*')) { return $t }
        $star = $s.IndexOf('*')
        if ($star -ge 0) { if ($t.StartsWith($s.Substring(0, $star), $ic)) { return $t } }
        elseif ($t.Equals($s, $ic)) { return $t }
    }
    $null
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
    <# Елемент hooks[] — старий шим kit: уся команда (без пробілів по краях) дослівно — форма шима (D12). #>
    param($Hook)
    if (-not ($Hook -is [System.Collections.IDictionary]) -or -not $Hook.Contains('command') -or $Hook['command'] -isnot [string]) { return $false }
    $Hook['command'].Trim() -cmatch $script:ShimPattern
}

function Get-SetupPermissionReport {
    <#
        Звіт про .claude/settings.json проєкту відносно шаблону (спека §5.2; рішення власника 2026-11-23: права
        не автоматизуються). ТІЛЬКИ ЧИТАННЯ: файл не змінюється й не пишеться ніколи — класифікація лише
        називає, що відрізняється; додає людина чи агент за її згодою штатними засобами Claude Code.
        Класи: Missing (правила шаблону, яких немає в тому самому списку проєкту); Held (правила allow шаблону,
        яких не варто додавати, бо вхідні ask/deny проєкту мають правило оболонки на той самий перший токен чи
        маску на нього — D13, Get-SetupAllowBlock); PrGate (відсутні pr-gate open|ready|land, ADR-0017);
        Obsolete (точні застарілі імена Уніки в allow/ask); ApplyInAllow; Shim (дослівні команди старого шима
        hooks.SessionStart); Broad (широкі правила першого покоління). Error — файл не розбирається.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root $script:SettingsFile
    $before = Read-SetupText $path
    $data = [ordered]@{}
    $absent = $null -eq $before
    if (-not $absent) {
        try { $data = ConvertFrom-SetupJson $before } catch { return @{ Error = "звіт дозволів не перевірено: не читається $($script:SettingsFile): $($_.Exception.Message)" } }
        if (-not ($data -is [System.Collections.IDictionary])) { return @{ Error = "звіт дозволів не перевірено: $($script:SettingsFile) — не JSON-об'єкт" } }
    }
    $perm = if ($data.Contains('permissions')) { $data['permissions'] } else { $null }
    if ($null -ne $perm -and -not ($perm -is [System.Collections.IDictionary])) { return @{ Error = "звіт дозволів не перевірено: $($script:SettingsFile): permissions — не об'єкт" } }
    $cur = [ordered]@{}
    foreach ($l in $script:PermLists) {
        # Не через вираз if: він розгорнув би одноелементний масив у рядок.
        $v = $null
        if ($null -ne $perm -and $perm.Contains($l)) { $v = $perm[$l] }
        if ($null -ne $v -and -not (Test-SetupJsonArray $v)) { return @{ Error = "звіт дозволів не перевірено: $($script:SettingsFile): permissions.$l — не масив" } }
        $cur[$l] = @(if ($null -ne $v) { $v })
    }
    $stricter = @($cur['ask']) + @($cur['deny'])
    $tpl = Get-SetupTemplateRules -Is1C (Test-SetupIs1C -Root $Root)
    $obsoleteNames = [string[]]@((Get-KitObsoleteNames).UnicaTools)

    $missing = [ordered]@{ allow = @(); ask = @(); deny = @() }
    $held = [ordered]@{}
    $prGate = @()
    foreach ($l in $script:PermLists) {
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $tpl[$l]) {
            if (Test-SetupHasRule $cur[$l] $r) { continue }
            if ($l -eq 'allow') {
                $key = Get-SetupAllowBlock -Rule $r -By $stricter
                if ($null -ne $key) {
                    if (-not $held.Contains($key)) { $held[$key] = [System.Collections.Generic.List[string]]::new() }
                    $held[$key].Add($r)
                    continue
                }
                if ($r -cmatch $script:PrGateRule) { $prGate += $r; continue }
            }
            $list.Add($r)
        }
        $missing[$l] = [string[]]$list.ToArray()
    }
    $obsolete = [ordered]@{}
    foreach ($l in 'allow', 'ask') {
        $obsolete[$l] = [string[]]@($cur[$l] | Where-Object { $_ -is [string] -and $obsoleteNames -ccontains $_ })
    }
    $apply = (Test-SetupHasRule $cur['allow'] $script:UnicaApply) -and (Test-SetupHasRule $tpl['ask'] $script:UnicaApply)
    $shim = @()
    $hooks = if ($data.Contains('hooks')) { $data['hooks'] } else { $null }
    if ($hooks -is [System.Collections.IDictionary] -and $hooks.Contains('SessionStart') -and (Test-SetupJsonArray $hooks['SessionStart'])) {
        foreach ($g in $hooks['SessionStart']) {
            $inner = $null
            if ($g -is [System.Collections.IDictionary] -and $g.Contains('hooks')) { $inner = $g['hooks'] }
            if (-not (Test-SetupJsonArray $inner)) { continue }
            foreach ($h in $inner) { if (Test-SetupShimHook $h) { $shim += $h['command'].Trim() } }
        }
    }
    # Попередження — без урахування регістру: тут ширше безпечніше.
    $broad = [ordered]@{}
    foreach ($k in $script:BroadOld.Keys) { if (@($cur['allow']) -contains $k) { $broad[$k] = $script:BroadOld[$k] } }
    @{
        Absent = $absent; Missing = $missing; Held = $held; PrGate = [string[]]$prGate
        Obsolete = $obsolete; ApplyInAllow = $apply; Shim = [string[]]$shim; Broad = $broad
    }
}

function Test-SetupReportClean {
    param([Parameter(Mandatory)]$R)
    -not (@($R.Missing.Values | ForEach-Object { $_ }).Count -or $R.Held.Count -or $R.PrGate.Count -or $R.Obsolete['allow'].Count -or
        $R.Obsolete['ask'].Count -or $R.ApplyInAllow -or $R.Shim.Count -or $R.Broad.Count)
}

function Format-SetupPermissionReport {
    <# Текст звіту: один рядок на клас; порожній звіт — один рядок «відхилень немає». #>
    param([Parameter(Mandatory)]$R)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("  $($script:SettingsFile) — звіт про відхилення від $($script:TemplateRel); kit цього файла не змінює (правки — людина чи агент штатними засобами Claude Code, за згодою людини)$(if ($R.Absent) { '; файла немає' })")
    if (Test-SetupReportClean $R) { $out.Add('    відхилень від шаблону немає'); return $out.ToArray() }
    foreach ($l in $script:PermLists) {
        if ($R.Missing[$l].Count) { $out.Add("    немає в $l проєкту, є в шаблоні ($($R.Missing[$l].Count)): $($R.Missing[$l] -join ', ')") }
    }
    foreach ($k in $R.Held.Keys) {
        $out.Add("    у проєкті є ask/deny на ``$k`` — $($R.Held[$k].Count) правил шаблону для allow не пропонуються автоматично (додавати лише свідомо): $($R.Held[$k] -join ', ')")
    }
    if ($R.PrGate.Count) { $out.Add("    правила pr-gate open|ready|land (ADR-0017) відсутні в allow: $($R.PrGate -join ', ')") }
    foreach ($l in 'allow', 'ask') {
        if ($R.Obsolete[$l].Count) { $out.Add("    застарілі імена Уніки в ${l}: $($R.Obsolete[$l] -join ', ') — прибрати (інструмента вже немає)") }
    }
    if ($R.ApplyInAllow) { $out.Add("    $($script:UnicaApply) в allow, а шаблон тримає його в ask — перенести в ask") }
    if ($R.Shim.Count) { $out.Add("    старий шим у hooks.SessionStart ($($R.Shim.Count)): $($R.Shim -join '; ') — прибрати (хук поставляє плагін; файл шима прибрати з git окремо)") }
    foreach ($k in $R.Broad.Keys) { $out.Add("    власнику: $k ширше за потрібне — $($R.Broad[$k])") }
    $out.ToArray()
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
    # Без v8storagekit.version: поле пише окремий виклик kit-setup -SetVersion останнім комітом PR (§5.2, D7).
    $profile = [ordered]@{}
    $base = Get-SetupDefaultBranch -Root $Root
    $profile['pr'] = [ordered]@{ base = $(if ($base) { $base } else { 'TODO: головна гілка' }); mergeMethod = 'TODO: squash або merge' }
    $profile['workspace'] = [ordered]@{ mode = $Mode }
    # docs.specs/docs.plans — необов'язкові: без знайденої теки поля немає (діє типове значення скілу), не TODO.
    $docs = [ordered]@{}
    foreach ($kind in 'specs', 'plans') {
        $found = @("docs/superpowers/$kind", "docs/$kind") | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Container } | Select-Object -First 1
        if ($found) { $docs[$kind] = $found }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'docs') -PathType Container) { $docs['docs'] = 'docs' }
    if ($docs.Count) { $profile['docs'] = $docs }
    # Корпус документів: лише те, що є в репо.
    $corpus = @('AGENTS.md', 'CLAUDE.md', 'README.md') | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf }
    $corpus = @($corpus)
    if (Test-Path -LiteralPath (Join-Path $Root 'docs') -PathType Container) { $corpus += 'docs/**/*.md' }
    foreach ($d in '.agents/skills', '.claude/skills') { if (Test-Path -LiteralPath (Join-Path $Root $d) -PathType Container) { $corpus += "$d/*/SKILL.md" } }
    if ($corpus.Count) { $profile['research'] = [ordered]@{ corpus = [object[]]$corpus } }
    if (Test-SetupIs1C -Root $Root) { $profile['review'] = [ordered]@{ exclude = [object[]]$script:ReviewExclude1C } }
    @{ Text = (Get-SetupJsonText -Data $profile -Before $null); Todo = @(Get-SetupTodoFields $profile) }
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
    <#
        Примітка про версію наявного профілю: команда його не міняє. Без v8storagekit.version — той самий текст, що стан
        no-version kit-scan (D6), без кроків від 0.1.0; нижча v8storagekit.version — оновлення скілом onboarding.
    #>
    param([Parameter(Mandatory)][string]$Root)
    if (Test-KitPluginRepo -Root $Root) { return '' }
    $p = Get-KitProjectVersion -Root $Root
    if ($p.Source -eq 'invalid') { return "; $($p.Error)" }
    if ($p.Source -eq 'default') { return "; $script:SetVersionNote" }
    $plugin = (Get-KitPluginInfo).Version
    if (-not $p.Version -or (Compare-KitVersion -A $p.Version -B $plugin) -ge 0) { return '' }
    "; v8storagekit.version $($p.Version) < плагін $plugin — оновлення: /v8storagekit:onboarding (kit-scan покаже кроки)"
}

function Get-SetupProfilePlan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    $path = Join-Path $Root $script:ProfileRel
    $before = Read-SetupText $path
    if ($null -ne $before) {
        return @{ Path = $path; Rel = $script:ProfileRel; Before = $before; After = $before; Note = "уже є, не змінено$(Get-SetupVersionNote -Root $Root)" }
    }
    $sk = Get-SetupProfileSkeleton -Root $Root -Mode $Mode
    $version = if (Test-KitPluginRepo -Root $Root) { '' } else { "; $script:SetVersionNote" }
    @{ Path = $path; Rel = $script:ProfileRel; Before = $null; After = $sk.Text; Json = $true; Note = "створено каркас — заповни $($sk.Todo.Count) TODO-полів: $($sk.Todo -join ', ')$version" }
}

function Invoke-SetupSetVersion {
    <#
        kit-setup -SetVersion (D7): v8storagekit.version наявного проєктного профілю = версія плагіна; решта властивостей —
        ті самі дані. Читає й розбирає ЛИШЕ сирий .agents/kit.profile.json — не Get-KitProfile і не злиті шари:
        локальний і машинний профілі пише агент, і їхній pr.afterMerge, перенесений у проєктний файл, pr-gate land
        виконав би без запиту (межа — Get-PrGateReviewedAfterMerge, tools/lib/KitPrGate.psm1). Профілю немає —
        код 1; не розбирається як JSON-об'єкт — код 3 без запису (не Get-SetupProfileData, що ковтає помилку).
    #>
    param([Parameter(Mandatory)][string]$Root, [bool]$Dry)
    $rel = $script:ProfileRel
    if (Test-KitPluginRepo -Root $Root) { throw (New-KitRefusal "це сам репозиторій плагіна — версії проєкту немає, $rel не змінено") }
    $path = Join-Path $Root $rel
    $before = Read-SetupText $path
    if ($null -eq $before) { throw (New-KitRefusal "$rel немає — спершу kit-setup (створить профіль), v8storagekit.version — останнім комітом PR") }
    try { $data = ConvertFrom-SetupJson $before }
    catch { throw (New-KitNotChecked "$rel не розбирається як JSON — не записано нічого: $(Get-SetupErrorText $_)") }
    if (-not ($data -is [System.Collections.IDictionary])) { throw (New-KitNotChecked "$rel не JSON-об'єкт — не записано нічого") }
    # ADR-0020: версію v8storagekit пише лише `v8storagekit.version`; `kit.version` (agent-kit) не чіпає.
    $ns = @($data.Keys | Where-Object { [string]$_ -ieq 'v8storagekit' }) | Select-Object -First 1
    if ($null -ne $ns -and -not ($data[$ns] -is [System.Collections.IDictionary])) {
        throw (New-KitNotChecked "$rel`: поле v8storagekit не об'єкт — не записано нічого")
    }
    $plugin = (Get-KitPluginInfo).Version
    # Стара версія — за тим самим правилом, що читання (v8storagekit.version; тимчасово kit.version ≥ 1.0.0).
    $cur = Get-KitProjectVersion -Root $Root
    $old = if ($cur.Source -eq 'profile') { $cur.Version } else { $null }
    $ownSet = $null -ne $ns -and @($data[$ns].Keys | Where-Object { [string]$_ -ieq 'version' }).Count -gt 0
    if ($ownSet -and [string]$old -ceq $plugin) {
        Write-KitLine "kit-setup -SetVersion: $rel`: v8storagekit.version уже $plugin (плагін $plugin) — нічого міняти"
        return 0
    }
    if ((ConvertTo-KitVersion $old) -and (Compare-KitVersion -A ([string]$old) -B $plugin) -gt 0) {
        throw (New-KitRefusal "$rel`: версія проєкту $old новіша за плагін $plugin — не понижую; онови плагін (claude plugin update v8storagekit)")
    }
    if ($null -ne $ns) {
        $vk = @($data[$ns].Keys | Where-Object { [string]$_ -ieq 'version' }) | Select-Object -First 1
        $data[$ns][$(if ($null -ne $vk) { $vk } else { 'version' })] = $plugin
    } else {
        # Секція v8storagekit — після kit (чи першою), решта ключів — у тому самому порядку з тими самими значеннями.
        $new = [ordered]@{}
        $placed = $false
        foreach ($k in $data.Keys) {
            $new[$k] = $data[$k]
            if (-not $placed -and [string]$k -ieq 'kit') { $new['v8storagekit'] = [ordered]@{ version = $plugin }; $placed = $true }
        }
        if (-not $placed) {
            $first = [ordered]@{ v8storagekit = [ordered]@{ version = $plugin } }
            foreach ($k in $new.Keys) { $first[$k] = $new[$k] }
            $new = $first
        }
        $data = $new
    }
    $after = Get-SetupJsonText -Data $data -Before $before
    $plan = @{ Path = $path; Rel = $rel; Before = $before; After = $after; Json = $true }
    if ($Dry) { Write-KitLine (Get-SetupUnifiedDiff -Rel $rel -Before $before -After $after) }
    else { Write-SetupFiles -Plans @($plan) }
    $was = if ($null -eq $old) { 'немає' } else { [string]$old }
    Write-KitLine "kit-setup -SetVersion$(if ($Dry) { ' -DryRun (нічого не записано)' }): $rel`: v8storagekit.version $was → $plugin (плагін $plugin); kit.version не змінено; решта профілю без змін"
    return 0
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
        DryRun = 'switch'; Json = 'switch'; NoPermissions = 'switch'; NoGitignore = 'switch'; NoProfile = 'switch'; NoWorktreeInclude = 'switch'
        SetVersion = 'switch'
    }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    if ($a.Positional.Count) { throw (New-KitUsageError "неочікуваний аргумент '$($a.Positional[0])'") }
    $dry = [bool]$a.Named['DryRun']
    if ($a.Named['SetVersion']) {
        # Окремий режим (D7): з ним — лише -DryRun.
        $other = @($a.Named.Keys | Where-Object { $_ -notin 'SetVersion', 'DryRun' -and $a.Named[$_] } | Sort-Object)
        if ($other) { throw (New-KitUsageError "-SetVersion — окремий режим, з ним лише -DryRun (зайве: $(($other | ForEach-Object { "-$_" }) -join ', '))") }
        return (Invoke-SetupSetVersion -Root (Get-KitCheckoutRoot -Path $RepoRoot) -Dry $dry)
    }
    $root = Get-KitCheckoutRoot -Path $RepoRoot
    $asJson = [bool]$a.Named['Json']
    $plugin = (Get-KitPluginInfo).Version

    $data = Get-SetupProfileData -Root $root
    $mode = Get-SetupMode -Root $root -Data $data
    # Звіт дозволів — лише читання; не розібраний settings.json — «не перевірено» до будь-якого запису.
    $report = $null
    if (-not $a.Named['NoPermissions']) {
        $report = Get-SetupPermissionReport -Root $root
        if ($report.ContainsKey('Error')) { throw (New-KitNotChecked $report.Error) }
    }
    $plans = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $a.Named['NoGitignore']) { $plans.Add((Get-SetupGitignorePlan -Root $root -Mode $mode -Data $data)) }
    if (-not $a.Named['NoProfile']) { $plans.Add((Get-SetupProfilePlan -Root $root -Mode $mode)) }
    if (-not $a.Named['NoWorktreeInclude']) { $plans.Add((Get-SetupWorktreeIncludePlan -Root $root -Mode $mode)) }

    $changed = @($plans | Where-Object { $_.After -cne $_.Before })
    if (-not $dry -and $changed) { Write-SetupFiles -Plans $changed }
    if ($asJson) {
        $o = [ordered]@{
            root = $root; plugin = $plugin; mode = $mode; dryRun = $dry
            files = @(foreach ($p in $plans) { [ordered]@{ path = $p.Rel; changed = ($p.After -cne $p.Before); note = $p.Note } })
        }
        if ($report) {
            $o['permissions'] = [ordered]@{
                file = $script:SettingsFile; absent = $report.Absent; clean = (Test-SetupReportClean $report)
                missing = $report.Missing; heldByAskDeny = $report.Held; prGate = @($report.PrGate)
                obsolete = $report.Obsolete; applyInAllow = $report.ApplyInAllow; shim = @($report.Shim); broad = $report.Broad
            }
        }
        Write-KitLine (ConvertTo-Json -InputObject $o -Depth 10 -EscapeHandling Default)
        return 0
    }
    if ($dry) { foreach ($p in $changed) { Write-KitLine (Get-SetupUnifiedDiff -Rel $p.Rel -Before $p.Before -After $p.After) } }
    Write-KitLine "kit-setup$(if ($dry) { ' -DryRun (нічого не записано)' }): $root; плагін $plugin; режим $mode"
    foreach ($p in $plans) { Write-KitLine "  $($p.Rel): $($p.Note)" }
    if ($report) { foreach ($l in (Format-SetupPermissionReport $report)) { Write-KitLine $l } }
    if (-not $changed) { Write-KitLine 'нічого міняти у файлах' }
    Write-KitNext 'kit-scan'
    return 0
}

Export-ModuleMember -Function Invoke-KitKitSetup
