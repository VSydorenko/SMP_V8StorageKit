#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/sdd, lib/sdd.mjs, modified.
<#
    Механіка виконання плану для скіла `execute`: замість ручних правок журналу і вирізання
    задач із плану — одна команда на крок. sdd сам пам'ятає стан задачі (BASE, переглянута голова,
    раунд): без цього контролер у полі набирав повний шлях плану й BASE вільним текстом, а рядок
    очікування звіту — щоразу заново.
#>
Set-StrictMode -Version Latest

$script:Usage = @'
sdd <підкоманда> [<plan.md>] <задача> …

<plan.md> необов'язковий після `sdd init <plan.md>` у цьому checkout: sdd бере єдиний відкритий
журнал, прив'язаний до нього (кілька — помилка зі списком). Номери задач: 3, 1c, 5b, 3.2.

Цикл задачі (стан живе в журналі):
  sdd dispatch <N> [-Model m] [-Weight w] [-Note "…"]
                     бриф (якщо немає) + рядок "dispatched" з BASE = HEAD; відкриває вікно;
                     друкує шлях брифу, шлях звіту і запасний спостерігач
  sdd resume <N> [-Note "…"]
                     той самий виконавець продовжує поза fix (відповідь на розвилку, пауза):
                     відкриває вікно
  sdd watch <N> [-Round k] [-Timeout с=7200] [-Interval с=5]
                     чекає "Status: …" ("Status round k: …"), дописаний у звіт задачі ПІСЛЯ
                     відкриття поточного вікна; OK → друкує статус і git log вікна (вікно НЕ
                     закриває: контролер комітить задачу між watch і review); TIMEOUT → стан
                     гілки й звіту
  sdd review <N>     пакет рецензії за вікнами задачі (раунд виправлень — вікна після останньої
                     рецензії) → шлях пакета; рядок "review"; перед цим закриває вікно (HEAD)
  sdd fix <N> [-Note "…"] [-Type patch|redesign] [-ApprovedBy <хто>]
             [-Source controller -Note "<знахідка>"]
                     наступний раунд виправлень, відкриває вікно; ліміт 2, ще один раунд —
                     за -ApprovedBy; -Source controller: раунд без пакета рецензії; попередній
                     раунд із нотаткою "security:" → підказка про незалежний аудит
  sdd done <N> [-Review clean|controller] [-Note "…"]
                     закриває вікно; рядок "complete" з комітами задачі

  sdd ruling <N> "<що> — <чому> — <ціна помилки> — вплив на спеку: <немає|…>"
                     рішення класу A; sdd close їх перелічує

Вікна виконання: dispatch, fix і resume записують HEAD, час і довжину звіту в байтах
("Window (task N): open …"); review і done записують HEAD ("… close …"; якщо після вікна вже відкрито
інше вікно будь-якої задачі, воно закінчується там і явно не закривається). Коміти задачі —
об'єднання її вікон; коміти між ними (мердж бази, інша задача) задачі не належать. Журнали без
вікон рахують BASE..HEAD, як раніше.

План і журнал:
  sdd init <plan.md>   робоча тека .agents/sdd/<план>/ у ГОЛОВНОМУ checkout + журнал; план, чий
                       журнал ще в .superpowers/sdd/, лишається там; прив'язує план до цього checkout
  sdd brief <N>        задача N → task-N-brief.md: секція задачі, секції плану з профілю й
                       «Команди» (рівні tests.levels профілю — лише коли вони є)
  sdd log <N> <стан> [-Commits a..b[,c..d]] [-Model m] [-Review r] [-Round k]
                      [-Weight trivial|standard|risky] [-Note "…"]   дописує один рядок;
                       у завершеної задачі додається лише нотатка, стан лишається
  sdd status           задача | стан | вага | модель | коміти | рев'ю | раунди
  sdd handoff          handoff.md для свіжого контролера: зроблено, у роботі, далі, відкрите
  sdd close            позначає закритим; коміти задач за вікнами; Rulings; раунди redesign;
                       рядок report: для архітектора
                       (повторюваний; після close ruling і status ще знаходять журнал)

Стани: dispatched review fix complete parked blocked needs-context fork skipped (code: старий SDD).
Формат журналу — портований SDD 7.0.1 (перший рядок "# SDD ledger — plan: <план>", рядки
"Task N: …"), тож журнали, початі під SDD, працюють далі.
Профіль .agents/kit.profile.json:
  plans.taskHeading    регулярний вираз; група 2 = номер задачі, група 3 = кінець діапазону
                       (типово: Задача|Task N, Tasks N–M)
  plans.briefSections  тексти заголовків, що копіюються в кожен бриф
                       (типово: Global Constraints, Глобальні обмеження, Рішення, Decisions, Інтерфейси, Interfaces)
  tests.levels         рівні тестів із командами в блоці «Команди» брифу (немає — немає й блоку)
Вивід: успіх закінчується "next: <команда>"; будь-яка помилка чи відмова — один перший рядок
stderr "sdd: ERROR …". Код: 0 ок; 1 провал чи відмова; 2 виклик; 3 не перевірено (таймаут, профіль).
'@

# Ліміт раундів — рішення власника; поза ним латки ховають структурну проблему.
$script:FixLimit = 2
$script:WatchTimeout = 7200
$script:LegacyNoted = $false
# Стан проби watch: проба виконується всередині KitWait, тож бачить лише змінні модуля.
$script:WatchProbe = $null
$script:WatchSeen = $null

# Після close блок ще приймають: архітектор повертає правки, і їхні рішення мають лягти в той
# самий журнал, а Rulings — друкуватись знову.
$script:AfterClose = @('close', 'ruling', 'status')
# Скільки позиційних аргументів після (необов'язкового) плану.
$script:Arity = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
# Ordinal: назва підкоманди чутлива до регістру (`sdd Status` — невідома команда), як в оригіналі.
foreach ($pair in @(@('brief', 1), @('log', 2), @('status', 0), @('handoff', 0), @('close', 0), @('dispatch', 1), @('resume', 1), @('watch', 1), @('review', 1), @('fix', 1), @('done', 1), @('ruling', 2))) {
    $script:Arity[$pair[0]] = $pair[1]
}

# ---------- дрібне ----------

function Out-Sdd { param([AllowEmptyString()][string]$Text = '') Write-KitLine $Text }

function Format-SddKb {
    param([double]$Bytes)
    "$(($Bytes / 1024).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)) КБ"
}

function Get-SddShort {
    param([AllowNull()][string]$Sha)
    if ($Sha) { $Sha.Substring(0, [Math]::Min(8, $Sha.Length)) } else { '?' }
}

function Get-SddUtf8 { [System.Text.UTF8Encoding]::new($false) }

function Invoke-SddTryGit {
    <# stdout git без кінцевих пробілів; $null, коли git відмовив. #>
    param([string]$Root, [string[]]$GitArgs)
    $r = Invoke-KitGit -Root $Root -Arguments $GitArgs -AllowFail
    if ($r.ExitCode -ne 0) { return $null }
    $r.Out.Trim()
}

function Get-SddHead {
    param([string]$Root)
    (Invoke-KitGit -Root $Root -Arguments @('rev-parse', 'HEAD')).Out.Trim()
}

function Write-SddLegacyNote {
    # Один раз на запуск: журнал живого блоку лишається у старій теці.
    if ($script:LegacyNoted) { return }
    $script:LegacyNoted = $true
    [Console]::Error.WriteLine('note: стара тека журналів .superpowers/sdd/; нові плани пишуть у .agents/sdd/')
}

function Read-SddSeconds {
    param([string]$Value, [string]$Name)
    $s = 0.0
    if (-not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$s) -or -not [double]::IsFinite($s) -or $s -lt 0) {
        throw (New-KitUsageError "-${Name}: кількість секунд")
    }
    $s
}

function Get-SddOpt {
    param([hashtable]$Opts, [string]$Name)
    if ($Opts.ContainsKey($Name)) { [string]$Opts[$Name] } else { '' }
}

# ---------- план і журнал ----------

function Get-SddCmd {
    <# Команда для підказок `next:`: план у ній пишемо лише коли він не єдиний поточний для checkout. #>
    param($C, [string]$Rest)
    $parts = @($Rest -split ' ')
    $tail = @($parts | Select-Object -Skip 1)
    $prefix = $C.Prefix
    if ($prefix -match '\s') { $prefix = "`"$prefix`"" }
    (@('sdd', $parts[0], $prefix) + $tail | Where-Object { $_ }) -join ' '
}

function Get-SddBoundPlans {
    <# Прив'язані до checkout плани; той самий план в обох теках — перемагає нова (вона перша). #>
    param([string]$Checkout, [switch]$Closed)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($b in (Get-KitSddBoundLedgers -Checkout $Checkout)) {
        if (-not $b.Parsed.Head -or [bool]$b.Parsed.Closed -ne [bool]$Closed) { continue }
        if (@($out | Where-Object { Test-KitSddSamePath $_.Plan $b.Plan }).Count) { continue }
        $out.Add($b)
    }
    $out.ToArray()
}

function Get-SddCurrentPlan {
    param([string]$Command, [string]$RepoRoot)
    $checkout = Get-KitCheckoutRoot -Path $RepoRoot
    $found = @(Get-SddBoundPlans -Checkout $checkout)
    if (-not $found.Count -and $script:AfterClose -contains $Command) { $found = @(Get-SddBoundPlans -Checkout $checkout -Closed) }
    if ($found.Count -eq 1) { return $found[0].Plan }
    if (-not $found.Count) {
        # Закритий журнал — не «план не прив'язано»: повторний init його не відкриває, і підказка «виконай init» вводила б в оману.
        $closed = @(Get-SddBoundPlans -Checkout $checkout -Closed)
        if ($closed.Count) {
            $list = @($closed | ForEach-Object { "$([System.IO.Path]::GetRelativePath($checkout, $_.Plan) -replace '\\', '/') (# closed $($_.Parsed.Closed))" }) -join ', '
            throw (New-KitUsageError "журнал плану закрито: $list; після close працюють лише $($script:AfterClose -join ', '); sdd init журнал не відкриває наново")
        }
        throw (New-KitUsageError "немає відкритого журналу, прив'язаного до ${checkout}: вкажи шлях плану або виконай sdd init <plan.md>")
    }
    $list = @($found | ForEach-Object { [System.IO.Path]::GetRelativePath($checkout, $_.Plan) -replace '\\', '/' }) -join ', '
    throw (New-KitUsageError "відкритих журналів, прив'язаних до ${checkout}: $($found.Count); вкажи шлях плану: $list")
}

function New-SddContext {
    <# Контекст команди: план, його checkout і як писати команду в підказках `next:`. #>
    param([string]$PlanArg, [string]$Command, [string]$RepoRoot)
    $plan = if ($PlanArg) { [System.IO.Path]::GetFullPath($PlanArg, $RepoRoot) } else { Get-SddCurrentPlan -Command $Command -RepoRoot $RepoRoot }
    if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) { throw (New-KitUsageError "немає файлу плану: $(if ($PlanArg) { $PlanArg } else { $plan })") }
    $info = Get-KitSddPlanInfo -Plan $plan
    $cwdCheckout = Get-KitCheckoutRoot -Path $RepoRoot
    $cwdPrefix = (Invoke-KitGit -Root $RepoRoot -Arguments @('rev-parse', '--show-prefix')).Out.Trim()
    $cwdCanon = [System.IO.Path]::GetFullPath((Join-Path $cwdCheckout $cwdPrefix))
    $bound = @(Get-SddBoundPlans -Checkout $cwdCheckout | ForEach-Object { $_.Plan })
    # План не пишемо, якщо він і так поточний для цього checkout.
    $rel = [System.IO.Path]::GetRelativePath($cwdCanon, $info.Path) -replace '\\', '/'
    $prefix = if ($bound.Count -eq 1 -and (Test-KitSddSamePath $bound[0] $info.Path)) { '' }
    elseif ($rel.StartsWith('..') -or [System.IO.Path]::IsPathRooted($rel)) { $info.Path }
    else { $rel }
    [pscustomobject]@{ Plan = $info.Path; Checkout = $info.Checkout; Prefix = $prefix; RepoRoot = $RepoRoot }
}

function Read-SddPlan { param($C) [System.IO.File]::ReadAllText($C.Plan) }

function Get-SddSettings {
    param($C)
    $p = Get-KitProfile -RepoRoot $C.Checkout
    $d = Get-KitSddDefaults
    # Get-KitProfileValue повертає значення обгорнутим: спершу присвоєння, потім приведення.
    $pattern = Get-KitProfileValue $p 'plans.taskHeading' -Default $d.TaskHeading
    $sections = Get-KitProfileValue $p 'plans.briefSections' -Default $d.BriefSections
    [pscustomobject]@{ Profile = $p; Pattern = [string]$pattern; Sections = [string[]]@($sections) }
}

function Get-SddLedger {
    <#
        Наявна тека без журналу або з журналом іншого плану — помилка, а не тихе перезаписування:
        чужий журнал, прочитаний як свій, змушує пропускати задачі.
    #>
    param($C, [switch]$Create)
    $ws = Get-KitSddWorkspace -Plan $C.Plan -Create:$Create
    if (-not $ws.Dir) { throw (New-KitRefusal "немає робочої теки для $($ws.Id): виконай sdd init $($ws.Id)") }
    if ($ws.Legacy) { Write-SddLegacyNote }
    $file = Join-Path $ws.Dir (Get-KitSddLedgerName)
    $expected = "$(Get-KitSddLedgerHead)$($ws.Id)"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        if (-not $Create) { throw (New-KitRefusal "немає журналу в $($ws.Dir): виконай sdd init $($ws.Id)") }
        [System.IO.File]::WriteAllText($file, "$expected`n", (Get-SddUtf8))
        return [pscustomobject]@{ Dir = $ws.Dir; Id = $ws.Id; Base = $ws.Base; Legacy = $ws.Legacy; File = $file; Created = $true }
    }
    $head = ([System.IO.File]::ReadAllText($file) -split "`n")[0].TrimEnd("`r")
    # Шлях плану на Windows нечутливий до регістру: шапка з іншим написанням того самого id — свій журнал.
    if (-not [string]::Equals($head, $expected, [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-KitRefusal "$file належить іншому плану (`"$head`"); залиш його й перевір шлях плану") }
    [pscustomobject]@{ Dir = $ws.Dir; Id = $ws.Id; Base = $ws.Base; Legacy = $ws.Legacy; File = $file; Created = $false }
}

function Read-SddLedgerFile { param($L) ConvertFrom-KitSddLedger -Text ([System.IO.File]::ReadAllText($L.File)) }

function Get-SddState {
    <# L (журнал на диску) і P (розібраний стан). #>
    param($C)
    $l = Get-SddLedger -C $C
    [pscustomobject]@{ L = $l; P = (Read-SddLedgerFile $l) }
}

function Get-SddTaskId {
    param([AllowNull()][string]$N, [string]$Command)
    if (-not $N) { throw (New-KitUsageError "${Command}: вкажи номер задачі (3, 1c, 3.2)") }
    if (-not (Test-KitSddTaskId $N)) { throw (New-KitUsageError "${Command}: `"$N`" не номер задачі (очікується 3, 1c, 5b, 3.2)") }
    $N
}

function Get-SddFiles {
    param($L, [string]$N)
    [pscustomobject]@{ Brief = Join-Path $L.Dir "task-$N-brief.md"; Report = Join-Path $L.Dir "task-$N-report.md" }
}

function Get-SddAllIds {
    param($C, $Rows)
    $s = Get-SddSettings $C
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($i in @(Get-KitSddPlanTaskIds -PlanText (Read-SddPlan $C) -Pattern $s.Pattern) + @($Rows.Keys)) { if (-not $ids.Contains([string]$i)) { $ids.Add([string]$i) } }
    Get-KitSddSortedIds -Ids $ids.ToArray()
}

function Get-SddNextFor {
    param($C, $R)
    switch ($R.State) {
        { $_ -cin 'dispatched', 'fix', 'code' } { return Get-SddCmd $C "watch $($R.N)" }
        { $_ -cin 'review', 'parked' } { return "$(Get-SddCmd $C "done $($R.N) -Review clean")   (blocker чи major: $(Get-SddCmd $C "fix $($R.N)"))" }
        'fork' { return "$(Get-SddCmd $C "dispatch $($R.N)")   (після відповіді архітектора)" }
        default { return Get-SddCmd $C "dispatch $($R.N)" }
    }
}

function Get-SddNextCommand {
    <# Наступна команда за журналом: перша незакінчена задача або перша без рядка. #>
    param($C, $Rows)
    foreach ($n in @(Get-SddAllIds $C $Rows)) {
        $r = $Rows[$n]
        if ($null -eq $r) { return Get-SddCmd $C "dispatch $n -Model <m> -Weight <w>" }
        if (-not (Test-KitSddDone $r)) { return Get-SddNextFor $C $r }
    }
    # Усі задачі завершено: далі фінальна рецензія всієї гілки, а не одразу close.
    "review-pack -Branch, потім скіл v8storagekit:landed-review на цьому пакеті; після його виправлень: $(Get-SddCmd $C 'close')"
}

function Add-SddRow {
    <# Дописує рядок до журналу (UTF-8 без BOM, \n) і друкує його. #>
    param($L, [string]$Row, [switch]$Quiet)
    [System.IO.File]::AppendAllText($L.File, "$Row`n", (Get-SddUtf8))
    if (-not $Quiet) { Out-Sdd $Row }
}

# ---------- бриф ----------

function Get-SddCommandsSection {
    <#
        Команди тестів — у самому брифі, з профілю: implementer слухає бриф, а не загальні
        правила. Розділ є лише коли профіль має tests.levels; без нього розділу немає взагалі.
    #>
    param($Profile)
    $levels = Get-KitProfileValue $Profile 'tests.levels' -Default $null
    if ($levels -isnot [System.Collections.IDictionary] -or $levels.Count -eq 0) { return [pscustomobject]@{ Text = ''; Levels = @() } }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Команди'); $lines.Add('')
    $lines.Add('Тести — лише цими командами; інших способів запуску не вигадуй.'); $lines.Add('')
    $names = @($levels.Keys | ForEach-Object { [string]$_ } | Sort-Object { $_ } -CaseSensitive)
    foreach ($name in $names) {
        $lv = $levels[$name]
        $cmd = if ($lv -is [System.Collections.IDictionary] -and $lv.Contains('command')) {
            $c = $lv['command']
            if ($c -is [System.Collections.IEnumerable] -and $c -isnot [string]) { (@($c) | ForEach-Object { [string]$_ }) -join ' ' } else { [string]$c }
        } else { '' }
        $lines.Add($(if ($cmd) { "- ``$name``: ``$cmd``" } else { "- ``$name``: (команду в профілі не задано)" }))
    }
    [pscustomobject]@{ Text = ($lines -join "`n"); Levels = $names }
}

function Write-SddBrief {
    param($C, [string]$N)
    $s = Get-SddSettings $C
    $ws = Get-KitSddWorkspace -Plan $C.Plan -Create
    if ($ws.Legacy) { Write-SddLegacyNote }
    $cmds = Get-SddCommandsSection $s.Profile
    $b = New-KitSddBrief -PlanText (Read-SddPlan $C) -N $N -Pattern $s.Pattern -Sections $s.Sections -PlanPath $ws.Id -Commands $cmds.Text
    if (-not $b) { throw (New-KitRefusal "задачі $N немає в $($ws.Id) (шаблон заголовка: $($s.Pattern))") }
    $file = Join-Path $ws.Dir "task-$N-brief.md"
    [System.IO.File]::WriteAllText($file, $b.Text, (Get-SddUtf8))
    $size = (Get-SddUtf8).GetByteCount($b.Text)
    Out-Sdd "$file  $(Format-SddKb $size)  `"$($b.Title)`"$(if ($b.Range) { " (спільна для задач $($b.Range))" })"
    # Альтернативні назви (укр./англ.) — не «відсутні» розділи: план має одну з них. Список
    # шуканих — лише коли не знайдено жодної.
    if ($b.Found.Count) { Out-Sdd "розділи: $($b.Found -join ' | ')" }
    else { Out-Sdd "розділи: немає (шукав: $($b.Missing -join ', '); plans.briefSections профілю)" }
    Out-Sdd "команди: $(if ($cmds.Levels.Count) { $cmds.Levels -join ', ' } else { 'немає (у профілі немає tests.levels)' })"
    $file
}

# ---------- підкоманди: план і журнал ----------

function Invoke-SddInit {
    param([string]$PlanArg, [string]$RepoRoot)
    if (-not $PlanArg) { throw (New-KitUsageError 'init: вкажи файл плану') }
    $plan = [System.IO.Path]::GetFullPath($PlanArg, $RepoRoot)
    if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) { throw (New-KitUsageError "немає файлу плану: $PlanArg") }
    $info = Get-KitSddPlanInfo -Plan $plan
    $l = Get-SddLedger -C ([pscustomobject]@{ Plan = $info.Path }) -Create
    [System.IO.File]::WriteAllText((Join-Path $l.Dir (Get-KitSddBindName)), "$($info.Checkout)`n", (Get-SddUtf8))
    $p = Read-SddLedgerFile $l
    if ($l.Created) { Out-Sdd "створено $($l.Dir)" }
    else { Out-Sdd "відновлено $($l.Dir): задач у журналі: $($p.Rows.Count)$(if ($p.Closed) { ", закрито $($p.Closed)" })" }
    if ($p.Closed) { Out-Sdd "журнал закрито $($p.Closed): init його не відкриває наново; працюють лише $($script:AfterClose -join ', ')" }
    Out-Sdd "прив'язано до $($info.Checkout): аргумент плану тут необов'язковий"
    if (-not $p.Closed) { Write-KitNext (Get-SddNextCommand (New-SddContext -PlanArg $PlanArg -Command 'init' -RepoRoot $RepoRoot) $p.Rows) }
}

function Invoke-SddBrief {
    param($C, [string]$N)
    $null = Write-SddBrief $C $N
    Write-KitNext (Get-SddCmd $C "dispatch $N -Model <m> -Weight <w>")
}

function Test-SddOptions {
    param([hashtable]$Opts)
    $commits = Get-SddOpt $Opts 'Commits'
    $sha = '[0-9a-f]{7,40}'
    if ($commits -and -not [regex]::IsMatch($commits, "^$sha\.\.$sha(?:,$sha\.\.$sha)*\z")) { throw (New-KitUsageError '-Commits: очікується <base>..<head> SHA (кілька: a..b,c..d)') }
    $round = Get-SddOpt $Opts 'Round'
    if ($round -and -not [regex]::IsMatch($round, '^[0-9]+\z')) { throw (New-KitUsageError '-Round: число') }
    $weight = Get-SddOpt $Opts 'Weight'
    if ($weight -and @('trivial', 'standard', 'risky') -cnotcontains $weight) { throw (New-KitUsageError '-Weight: trivial, standard або risky') }
    $review = Get-SddOpt $Opts 'Review'
    if ($review -and -not [regex]::IsMatch($review, '^[A-Za-z0-9_-]+\z')) { throw (New-KitUsageError '-Review: одне слово (clean, controller)') }
}

function Invoke-SddLog {
    param($C, [string]$N, [string]$State, [hashtable]$Opts)
    $states = @(Get-KitSddStates)
    if (-not $State -or $states -cnotcontains $State) { throw (New-KitUsageError "log: стан — один із $($states -join ' ')") }
    Test-SddOptions $Opts
    $st = Get-SddState $C
    $prev = $st.P.Rows[$N]
    $row = @{ N = $N; State = $State; Commits = (Get-SddOpt $Opts 'Commits'); Model = (Get-SddOpt $Opts 'Model'); Review = (Get-SddOpt $Opts 'Review'); Round = (Get-SddOpt $Opts 'Round'); Weight = (Get-SddOpt $Opts 'Weight'); Type = (Get-SddOpt $Opts 'Type'); Source = (Get-SddOpt $Opts 'Source'); Note = (Get-SddOpt $Opts 'Note') }
    # Нотатка про вже закриту задачу («minor знято», «parked …») не відкриває її знову: інакше
    # status показував би parked, і done доводилось би запускати вдруге.
    if ($prev -and (Test-KitSddDone $prev) -and $State -cne $prev.State) {
        $note = "$State$(if ($row.Note) { ": $($row.Note)" })"
        Add-SddRow $st.L (Format-KitSddRow -N $N -State $prev.State -Note $note)
        Out-Sdd "задача $N вже $($prev.State): нотатку дописано, стан лишається $($prev.State)"
    } else { Add-SddRow $st.L (Format-KitSddRow @row) }
    $rows = (Read-SddLedgerFile $st.L).Rows
    Write-KitNext $(if (Test-KitSddDone $rows[$N]) { Get-SddNextCommand $C $rows } else { Get-SddNextFor $C $rows[$N] })
}

# ---------- вікна виконання ----------

function Open-SddWindow {
    <# Відкриває вікно: HEAD, час і довжина звіту в байтах — Status до неї watch уже не бачить. #>
    param($C, $L, [string]$N, [string]$By)
    $head = Get-SddHead $C.Checkout
    $report = (Get-SddFiles $L $N).Report
    $size = if (Test-Path -LiteralPath $report -PathType Leaf) { ([System.IO.FileInfo]::new($report)).Length } else { 0 }
    Add-SddRow $L (Format-KitSddWindow -N $N -Kind open -Sha $head -At (Get-KitSddNow) -Report $size -By $By)
    $head
}

function Close-SddWindow {
    <#
        Закриває останнє вікно задачі, якщо воно відкрите; повертає HEAD. Вікно, після якого вже
        відкрито вікно будь-якої задачі, явно не закриваємо: воно й так закінчується там, а закриття
        на нинішньому HEAD захопило б чужі коміти.
    #>
    param($C, $L, [string]$N, [string]$By, [switch]$Quiet)
    $head = Get-SddHead $C.Checkout
    $p = Read-SddLedgerFile $L
    $r = $p.Rows[$N]
    $w = if ($r -and @($r.Windows).Count) { @($r.Windows)[-1] } else { $null }
    $later = if ($w) { @($p.Windows | Where-Object { $_.Line -gt $w.Line }).Count } else { 0 }
    if ($w -and -not $w.Close -and -not $later) {
        Add-SddRow $L (Format-KitSddWindow -N $N -Kind close -Sha $head -At (Get-KitSddNow) -By $By) -Quiet:$Quiet
    }
    $head
}

function Get-SddRanges {
    <# Коміти задачі: об'єднання вікон; журнал без вікон — BASE..HEAD, як до вікон. Масив, викликач обгортає в @(). #>
    param($P, [string]$N, [string]$Head)
    $ranges = Get-KitSddTaskRanges -Parsed $P -N $N -Head $Head
    if ($null -ne $ranges) { return @($ranges) }
    $r = $P.Rows[$N]
    if ($r.Base) { return [pscustomobject]@{ From = $r.Base; To = $Head } }
}

function Format-SddRangeText {
    param($Ranges, [string]$Root)
    (@($Ranges | ForEach-Object {
                $cnt = Invoke-SddTryGit $Root @('rev-list', '--count', "$($_.From)..$($_.To)")
                "$(Get-SddShort $_.From)..$(Get-SddShort $_.To) ($(if ($null -ne $cnt) { $cnt } else { 'немає в git' }))"
            })) -join ', '
}

# ---------- підкоманди: цикл задачі ----------

function Invoke-SddDispatch {
    param($C, [string]$N, [hashtable]$Opts)
    Test-SddOptions $Opts
    $st = Get-SddState $C
    $l = $st.L
    $r = $st.P.Rows[$N]
    if ($r -and (Test-KitSddDone $r)) { throw (New-KitRefusal "задача $N вже $($r.State): завершену задачу ніколи не диспетчеризують повторно (sdd status)") }
    $f = Get-SddFiles $l $N
    $head = Get-SddHead $C.Checkout
    # Повторний dispatch (пауза, свіжий implementer) не зсуває BASE: done має покрити всі коміти
    # задачі, а не лише останнього виконавця.
    $base = if ($r -and $r.Base) { '' } else { $head }
    if (Test-Path -LiteralPath $f.Brief -PathType Leaf) {
        $briefSize = ([System.IO.FileInfo]::new($f.Brief)).Length
        Out-Sdd "$($f.Brief)  $(Format-SddKb $briefSize)  (лишено; sdd brief $N перебудовує)"
    } else { $null = Write-SddBrief $C $N }
    Add-SddRow $l (Format-KitSddRow -N $N -State dispatched -Base $base -Model (Get-SddOpt $Opts 'Model') -Weight (Get-SddOpt $Opts 'Weight') -Note (Get-SddOpt $Opts 'Note'))
    $null = Open-SddWindow $C $l $N 'dispatch'
    $shownBase = if ($r -and $r.Base) { $r.Base } else { $head }
    Out-Sdd "base $(Get-SddShort $shownBase)$(if (-not $base) { ' (лишено з першого dispatch)' })"
    Out-Sdd "звіт: $($f.Report)  (останній рядок `"Status: …`")"
    Out-Sdd "запасний варіант: одразу після виклику Agent запусти ОДИН фоновий Bash: $(Get-SddCmd $C "watch $N")"
    Write-KitNext (Get-SddCmd $C "watch $N")
}

function Invoke-SddResume {
    <# Implementer продовжує поза fix: без нового вікна watch не відрізнив би свіжий Status від старого, а коміти — від чужих. #>
    param($C, [string]$N, [hashtable]$Opts)
    $st = Get-SddState $C
    $r = $st.P.Rows[$N]
    if (-not $r) { throw (New-KitRefusal "у задачі $N немає рядка в журналі: спершу $(Get-SddCmd $C "dispatch $N")") }
    if (Test-KitSddDone $r) { throw (New-KitRefusal "задача $N вже $($r.State): завершену задачу ніколи не відновлюють (sdd status)") }
    $note = Get-SddOpt $Opts 'Note'
    # Відкрита задача (розвилка, блок, parked) знову в роботі; fix лишається fix — watch чекає свій раунд.
    if (Test-KitSddOpen $r) { Add-SddRow $st.L (Format-KitSddRow -N $N -State dispatched -Note $(if ($note) { $note } else { "resume from $($r.State)" })) }
    elseif ($note) { Add-SddRow $st.L (Format-KitSddRow -N $N -State $r.State -Note $note) }
    $null = Open-SddWindow $C $st.L $N 'resume'
    $round = if ($r.State -ceq 'fix') { $r.Rounds } else { 0 }
    Out-Sdd "звіт: $((Get-SddFiles $st.L $N).Report)  (implementer дописує `"$(if ($round) { "Status round ${round}:" } else { 'Status:' }) …`")"
    Write-KitNext (Get-SddCmd $C "watch $N")
}

function Get-SddFreshText {
    <#
        Status приймаємо лише з байтів, дописаних після відкриття вікна. Зсув, а не mtime: будь-яка
        інша правка звіту (нотатка, перезапис того самого рядка) оновлює mtime, і старий Status
        пройшов би. Файл звіту sdd не чіпає: маркер у ньому зламав би Edit/Write implementer'а
        («file changed since read»).
    #>
    param([byte[]]$Bytes, $Window, [string]$Report)
    $utf8 = Get-SddUtf8
    if (-not $Window) { return $utf8.GetString($Bytes) }
    if ($Bytes.Length -ge $Window.Report) { return $utf8.GetString($Bytes, [int]$Window.Report, $Bytes.Length - [int]$Window.Report) }
    # Звіт коротший за зсув — його переписали: свіжий лише тоді, коли переписано після відкриття.
    $at = [datetimeoffset]::MinValue
    if ($Window.At -and [datetimeoffset]::TryParse($Window.At, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at) -and
        ([System.IO.FileInfo]::new($Report)).LastWriteTimeUtc -gt $at.UtcDateTime) { return $utf8.GetString($Bytes) }
    ''
}

function Read-SddReportBytes {
    # Звіт пише implementer: читаємо з FileShare.ReadWrite, інакше відкритий на запис файл не читається.
    param([string]$Report)
    $fs = [System.IO.FileStream]::new($Report, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $ms = [System.IO.MemoryStream]::new()
        $fs.CopyTo($ms)
        , $ms.ToArray()
    } finally { $fs.Dispose() }
}

function Invoke-SddWatchProbe {
    param([double]$RemainingMs)
    $s = $script:WatchProbe
    if (-not (Test-Path -LiteralPath $s.Report -PathType Leaf)) { return @{ Done = $null; State = "$($s.Report): немає" } }
    $text = Get-SddFreshText -Bytes (Read-SddReportBytes $s.Report) -Window $s.Window -Report $s.Report
    $m = $s.Regex.Match($text)
    if (-not $m.Success) { return @{ Done = $null; State = "$($s.Report): рядка `"$($s.Label)`" ще немає" } }
    $s.Found = $m.Value.TrimEnd("`r")
    @{ Done = 'ok'; State = "$($s.Report): знайдено" }
}

function Invoke-SddWatch {
    param($C, [string]$N, [hashtable]$Opts)
    $st = Get-SddState $C
    $l = $st.L
    $r = $st.P.Rows[$N]
    if (-not $r) { throw (New-KitRefusal "у задачі $N немає рядка в журналі: спершу $(Get-SddCmd $C "dispatch $N")") }
    $roundOpt = Get-SddOpt $Opts 'Round'
    if ($Opts.ContainsKey('Round') -and -not [regex]::IsMatch($roundOpt, '^[0-9]+\z')) { throw (New-KitUsageError '-Round: число') }
    # Без -Round чекаємо поточний раунд із журналу: після `sdd fix` — «Status round k:».
    $round = if ($Opts.ContainsKey('Round')) { [int]$roundOpt } elseif ($r.State -ceq 'fix') { $r.Rounds } else { 0 }
    $timeoutSec = if ($Opts.ContainsKey('Timeout')) { Read-SddSeconds (Get-SddOpt $Opts 'Timeout') 'Timeout' } else { [double]$script:WatchTimeout }
    $intervalSec = if ($Opts.ContainsKey('Interval')) { Read-SddSeconds (Get-SddOpt $Opts 'Interval') 'Interval' } else { 5.0 }
    $report = (Get-SddFiles $l $N).Report
    $label = if ($round) { "Status round ${round}:" } else { 'Status:' }
    # `[^\r\n]*`, а не `.*`: у .NET крапка захоплює \r, а звіт може бути CRLF.
    $re = [regex]::new('(?m)^' + [regex]::Escape($label) + ' [^\r\n]*')
    $w = if (@($r.Windows).Count) { @($r.Windows)[-1] } else { $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $script:WatchProbe = @{ Report = $report; Label = $label; Regex = $re; Window = $w; Found = $null }
    # Проміжні стани не друкуємо: watch іде у фоні, і три рядки про одне («знайдено», «OK через»,
    # рядок Status) лише ховали б сам Status.
    $script:WatchSeen = [System.Collections.Generic.List[string]]::new()
    $res = Invoke-KitWaitUntil -Probe { param($RemainingMs) Invoke-SddWatchProbe -RemainingMs $RemainingMs } -TimeoutSec $timeoutSec -IntervalSec $intervalSec -Write { param([string]$Line) $script:WatchSeen.Add($Line) }
    $found = $script:WatchProbe.Found
    $from = if ($w) { $w.Sha } else { $r.Base }
    $log = if ($from) {
        $commits = Invoke-SddTryGit $C.Checkout @('log', '--oneline', "$from..HEAD")
        "git log --oneline $(Get-SddShort $from)..HEAD:`n$(if ($commits) { $commits } else { '(немає комітів)' })"
    } else { 'у журналі немає BASE: коміти не перелічено' }
    if ($res.Code -eq 0) {
        Out-Sdd "$found  ($($res.Line -creplace '^OK ', ''))"
        Out-Sdd $log
        Out-Sdd 'якщо implementer ще не відповів, продовжуй так, ніби відповів; ніколи не диспетчеризуй задачу повторно'
        Write-KitNext (Get-SddCmd $C "review $N")
        return
    }
    Out-Sdd $res.Line
    $porcelain = Invoke-SddTryGit $C.Checkout @('status', '--porcelain')
    $dirty = if ($porcelain) { @($porcelain -split "`n" | Where-Object { $_ }).Count } else { 0 }
    $branch = Invoke-SddTryGit $C.Checkout @('branch', '--show-current')
    Out-Sdd "гілка $(if ($branch) { $branch } else { '?' }), HEAD $(Get-SddShort (Invoke-SddTryGit $C.Checkout @('rev-parse', 'HEAD'))), незакомічено: $dirty файл(ів)"
    Out-Sdd $log
    if (Test-Path -LiteralPath $report -PathType Leaf) {
        $bytes = Read-SddReportBytes $report
        $all = (Get-SddUtf8).GetString($bytes)
        if ($w -and $re.IsMatch($all) -and -not $re.IsMatch((Get-SddFreshText -Bytes $bytes -Window $w -Report $report))) {
            Out-Sdd "рядок `"$label`" старший за вікно, відкрите $(if ($w.At) { $w.At } else { Get-SddShort $w.Sha }), ігнорується"
        }
        $tail = @($all.TrimEnd() -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Select-Object -Last 3) -join "`n"
        Out-Sdd "звіт $(Format-SddKb $bytes.Length), останні рядки:`n$tail"
    } else { Out-Sdd 'звіт: немає' }
    throw (New-KitNotChecked "watch: у $report немає рядка `"$label`" за $($timeoutSec.ToString($inv)) с; доповідь архітектору стан вище одним рядком")
}

function Write-SddPackLines {
    # Те саме, що друкує review-pack: контролер бачить, що саме записано.
    param($Pack)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in $Pack.Files) { Out-Sdd "записано $($f.Path): $($f.Kb.ToString('0.0', $inv)) КБ, ~$($f.Tokens.ToString('N0', $inv)) токенів" }
    Out-Sdd "діапазон $($Pack.Range): комітів $($Pack.Commits), файлів $($Pack.FileCount), +$($Pack.Plus)/-$($Pack.Minus)"
}

function New-SddPack {
    # Збій пакета — відмова з першим рядком причини: код і текст review-pack тут не потрібні.
    param($C, [string]$From, [string]$To, [string]$File)
    try { New-KitReviewPackage -Root $C.Checkout -Base $From -Head $To -Out $File }
    catch { throw (New-KitRefusal "review-pack $(Get-SddShort $From) $(Get-SddShort $To) не вдався: $(@($_.Exception.Message -split "\r?\n")[0])") }
}

function Invoke-SddReview {
    param($C, [string]$N)
    $st = Get-SddState $C
    $l = $st.L
    $p = $st.P
    $r = $p.Rows[$N]
    if (-not $r) { throw (New-KitRefusal "у задачі $N немає рядка в журналі: спершу $(Get-SddCmd $C "dispatch $N")") }
    if (Test-KitSddDone $r) { throw (New-KitRefusal "задача $N вже $($r.State)") }
    if (-not $r.Base -and -not @($r.Windows).Count) { throw (New-KitRefusal "у задачі $N немає BASE у журналі (почато до sdd dispatch): виконай review-pack <BASE> вручну") }
    # Вікно закриває review (watch цього не робить): контролер комітить задачу між watch і review.
    # Але запис закриття — після всіх відмов (немає комітів, збій пакета): відмова не змінює журнал.
    # Діапазони тут рахуються за ще відкритим вікном: кінець незакритого вікна — HEAD, як і після закриття.
    $head = Get-SddHead $C.Checkout
    if (@($r.Windows).Count) {
        # Раунд виправлень рецензується лише своїм диффом — вікнами після попередньої рецензії.
        if ($r.Rounds -gt 0 -and $null -eq $r.ReviewLine) { Out-Sdd "warn: для задачі $N не записано рецензії; пакет охоплює всі її вікна" }
        $after = if ($r.Rounds -gt 0 -and $null -ne $r.ReviewLine) { [int]$r.ReviewLine } else { -1 }
        $tr = Get-KitSddTaskRanges -Parsed $p -N $N -Head $head -AfterLine $after
        # @(…) поза if: порожній масив із гілки if у присвоєнні стає $null, і .Count під StrictMode кидає.
        $ranges = @($tr | Where-Object { $null -ne $_ })
    } else {
        # Журнал до вікон: від BASE, раунд — від голови, яку бачила попередня рецензія.
        $from = if ($r.Rounds -gt 0 -and $r.Reviewed) { $r.Reviewed } else { $r.Base }
        if ($r.Rounds -gt 0 -and -not $r.Reviewed) { Out-Sdd "warn: для задачі $N не записано переглянутої голови; пакет охоплює всю задачу від BASE" }
        $ranges = @(if (-not $head.StartsWith($from, [System.StringComparison]::Ordinal)) { [pscustomobject]@{ From = $from; To = $head } })
    }
    if (-not $ranges.Count) { throw (New-KitRefusal "задача ${N}: у її вікнах немає комітів після останньої рецензії; рецензувати нічого") }
    $pack = Join-Path $l.Dir "task-$N-review$(if ($r.Rounds) { "-round$($r.Rounds)" }).md"
    if ($ranges.Count -eq 1) {
        $res = New-SddPack $C $ranges[0].From $ranges[0].To $pack
        # Свій `next:` review-pack тут зайвий: наступний крок задачі каже sdd.
        Write-SddPackLines $res
    } else {
        # Пакет рецензії бере один діапазон: пакет на вікно, склеєний в один файл. Коміти між
        # вікнами (мердж бази, інша задача) у пакет не потрапляють.
        $parts = @()
        for ($i = 0; $i -lt $ranges.Count; $i++) {
            $x = $ranges[$i]
            $file = $pack -replace '\.md$', "-window$($i + 1).md"
            $null = New-SddPack $C $x.From $x.To $file
            $text = [System.IO.File]::ReadAllText($file)
            [System.IO.File]::Delete($file)
            $parts += "## Вікно $($i + 1): $(Get-SddShort $x.From)..$(Get-SddShort $x.To)`n`n$text"
        }
        $text = "# Пакет рецензії задачі ${N}: вікон $($ranges.Count)`n`nКоміти між вікнами належать іншій роботі й тут їх немає.`n`n$($parts -join "`n")"
        [System.IO.File]::WriteAllText($pack, $text, (Get-SddUtf8))
        $packSize = (Get-SddUtf8).GetByteCount($text)
        Out-Sdd "$pack  $(Format-SddKb $packSize)  ~$([int][Math]::Round($text.Length / 4)) токенів  вікна $(Format-SddRangeText $ranges $C.Checkout)"
    }
    $null = Close-SddWindow $C $l $N 'review'
    Add-SddRow $l (Format-KitSddRow -N $N -State review -Commits (Format-KitSddRanges $ranges) -Round $(if ($r.Rounds) { [string]$r.Rounds } else { '' }))
    Out-Sdd "пакет: $pack"
    Write-KitNext "$(Get-SddCmd $C "done $N -Review clean")   (blocker чи major: $(Get-SddCmd $C "fix $N"))"
}

function Invoke-SddFix {
    param($C, [string]$N, [hashtable]$Opts)
    $st = Get-SddState $C
    $l = $st.L
    $r = $st.P.Rows[$N]
    if (-not $r) { throw (New-KitRefusal "у задачі $N немає рядка в журналі") }
    if (Test-KitSddDone $r) { throw (New-KitRefusal "задача $N вже $($r.State)") }
    $type = if ($Opts.ContainsKey('Type')) { Get-SddOpt $Opts 'Type' } else { 'patch' }
    if (@('patch', 'redesign') -cnotcontains $type) { throw (New-KitUsageError '-Type: patch або redesign') }
    if ($Opts.ContainsKey('Source') -and (Get-SddOpt $Opts 'Source') -cne 'controller') { throw (New-KitUsageError '-Source: лише "controller" (знахідка без пакета рецензії)') }
    $controller = $Opts.ContainsKey('Source')
    $note = Get-SddOpt $Opts 'Note'
    if ($controller -and -not $note.Trim()) { throw (New-KitUsageError '-Source controller: вкажи знахідку в -Note') }
    $approved = (Get-SddOpt $Opts 'ApprovedBy').Trim()
    if ($Opts.ContainsKey('ApprovedBy') -and -not $approved) { throw (New-KitUsageError '-ApprovedBy: хто схвалив додатковий раунд') }
    # Ліміт знімає лише явне рішення архітектора, і лише на один раунд: воно лягає в журнал.
    if ($r.Rounds -ge $script:FixLimit -and -not $approved) {
        throw (New-KitRefusal "задача ${N}: досягнуто ліміт раундів виправлень ($($script:FixLimit)) — ескалюй архітектору як розвилку класу B; більше жодних латок (додатковий раунд за рішенням: -ApprovedBy <хто>)")
    }
    if (-not $controller -and -not $r.Reviewed -and $r.State -cne 'review') {
        throw (New-KitRefusal "задача ${N}: рецензії ще не було; спершу $(Get-SddCmd $C "review $N") (власна знахідка: -Source controller -Note `"…`")")
    }
    $round = $r.Rounds + 1
    Add-SddRow $l (Format-KitSddRow -N $N -State fix -Round ([string]$round) -Type $type -Source $(if ($controller) { 'controller' } else { '' }) -Approved $approved -Note $note)
    $null = Open-SddWindow $C $l $N 'fix'
    Out-Sdd "раунд $round/$($script:FixLimit)$(if ($round -gt $script:FixLimit) { " (понад ліміт, схвалив $approved)" }), ${type}: віднови того самого implementer із знахідками дослівно; він дописує `"Status round ${round}: …`" у $((Get-SddFiles $l $N).Report)"
    # Повторний security-major на тій самій зоні: незалежна модель до наступного раунду (не блокує).
    $lastFix = if ($r.Fixes.Count) { $r.Fixes[$r.Fixes.Count - 1] } else { $null }
    if ($lastFix -and [regex]::IsMatch([string]$lastFix.Note, '^security:', 'IgnoreCase')) {
        Out-Sdd 'підказка: попередній раунд мав нотатку "security:" — до цього раунду зроби незалежний аудит цієї зони скілом codex-companion (якщо він є на машині); перевір кожну знахідку й внеси підтверджені в бриф раунду'
    }
    Write-KitNext (Get-SddCmd $C "watch $N")
}

function Invoke-SddDone {
    param($C, [string]$N, [hashtable]$Opts)
    Test-SddOptions $Opts
    $st = Get-SddState $C
    $l = $st.L
    $r = $st.P.Rows[$N]
    if (-not $r) { throw (New-KitRefusal "у задачі $N немає рядка в журналі") }
    if (Test-KitSddDone $r) { throw (New-KitRefusal "задача $N вже $($r.State)") }
    if (-not $r.Base -and -not @($r.Windows).Count) { throw (New-KitRefusal "у задачі $N немає BASE у журналі (почато до sdd dispatch): $(Get-SddCmd $C "log $N complete -Commits <BASE>..<HEAD>")") }
    # Закриття вікна пишемо після перевірки предка: відмова не змінює журнал (діапазон за відкритим вікном — той самий, що й за закритим).
    $head = Get-SddHead $C.Checkout
    $ranges = @(Get-SddRanges $st.P $N $head)
    foreach ($x in $ranges) {
        $anc = Invoke-KitGit -Root $C.Checkout -Arguments @('merge-base', '--is-ancestor', $x.From, $x.To) -AllowFail
        if ($anc.ExitCode -ne 0) { throw (New-KitRefusal "початок вікна $(Get-SddShort $x.From) задачі $N не предок $(Get-SddShort $x.To) (rebase?); запиши діапазон вручну") }
    }
    $null = Close-SddWindow $C $l $N 'done'
    $count = 0
    foreach ($x in $ranges) { $count += [int](Invoke-KitGit -Root $C.Checkout -Arguments @('rev-list', '--count', "$($x.From)..$($x.To)")).Out.Trim() }
    # Без -Review: була рецензія — clean; не було — дифф читав контролер.
    $reviewOpt = Get-SddOpt $Opts 'Review'
    $reviewed = if ($reviewOpt) { $reviewOpt } elseif ($r.Reviewed) { 'clean' } else { 'controller' }
    Add-SddRow $l (Format-KitSddRow -N $N -State complete -Commits $(if ($count) { Format-KitSddRanges $ranges } else { '' }) -Review $reviewed -Round $(if ($r.Rounds) { [string]$r.Rounds } else { '' }) -Note (Get-SddOpt $Opts 'Note'))
    if (-not $count) { Out-Sdd "warn: у вікнах задачі $N немає комітів" }
    elseif ($ranges.Count -eq 1) { Out-Sdd "комітів: $count, $(Get-SddShort $ranges[0].From)..$(Get-SddShort $ranges[0].To)" }
    else { Out-Sdd "комітів: $count у вікнах: $($ranges.Count): $(Format-SddRangeText $ranges $C.Checkout); коміти між ними не належать цій задачі" }
    Write-KitNext (Get-SddNextCommand $C (Read-SddLedgerFile $l).Rows)
}

function Invoke-SddRuling {
    param($C, [string]$N, [string]$Text)
    if (-not $Text -or -not $Text.Trim()) { throw (New-KitUsageError 'ruling: вкажи текст: "<що> — <чому> — <ціна помилки> — вплив на спеку: <немає|…>"') }
    $st = Get-SddState $C
    $row = $st.P.Rows[$N]
    # Рішення приймання після close позначене: видно, що його ухвалено вже після звіту.
    Add-SddRow $st.L (Format-KitSddRuling -N $N -Text "$(if ($st.P.Closed) { 'after close: ' })$($Text.Trim())")
    if (-not [regex]::IsMatch($Text, 'spec impact|вплив на спеку', 'IgnoreCase')) { Out-Sdd 'warn: у рішенні немає "вплив на спеку"; рішення класу A закінчується "вплив на спеку: немає"' }
    Write-KitNext $(if ($row -and -not (Test-KitSddDone $row)) { Get-SddNextFor $C $row } else { Get-SddNextCommand $C $st.P.Rows })
}

# ---------- звіти ----------

function Format-SddCommitsCell {
    <# Коміти з журналу звіряються з git: після squash-мерджу чи rebase діапазон може зникнути — це видно одразу, а не на прийманні. #>
    param([string]$Ranges, [string]$Root)
    if (-not $Ranges) { return '' }
    (@($Ranges -split ',' | ForEach-Object {
                $ab = $_ -split '\.\.'
                $cnt = Invoke-SddTryGit $Root @('rev-list', '--count', "$($ab[0])..$($ab[1])")
                "$($ab[0].Substring(0, 7))..$($ab[1].Substring(0, 7)) ($(if ($null -ne $cnt) { $cnt } else { 'немає в git' }))"
            })) -join ', '
}

function Format-SddTable {
    param([object[][]]$Rows)
    $w = for ($i = 0; $i -lt $Rows[0].Count; $i++) { ($Rows | ForEach-Object { ([string]$_[$i]).Length } | Measure-Object -Maximum).Maximum }
    ($Rows | ForEach-Object {
        $r = $_
        (@(for ($i = 0; $i -lt $r.Count; $i++) { ([string]$r[$i]).PadRight($w[$i]) }) -join '  ').TrimEnd()
    }) -join "`n"
}

function Invoke-SddStatus {
    param($C)
    $st = Get-SddState $C
    $rows = $st.P.Rows
    $all = @(Get-SddAllIds $C $rows)
    $t = [System.Collections.Generic.List[object[]]]::new()
    $t.Add(@('задача', 'стан', 'вага', 'модель', 'коміти', 'рев''ю', 'раунди'))
    foreach ($n in $all) {
        $r = $rows[$n]
        if ($r) { $t.Add(@($n, $r.State, $r.Weight, $r.Model, (Format-SddCommitsCell $r.Commits $C.Checkout), $r.Review, $(if ($r.Rounds) { $r.Rounds } else { '' }))) }
        else { $t.Add(@($n, '—', '', '', '', '', '')) }
    }
    Out-Sdd (Format-SddTable $t.ToArray())
    $nDone = @($all | Where-Object { $rows[$_] -and (Test-KitSddDone $rows[$_]) }).Count
    $open = @($all | Where-Object { $rows[$_] -and (Test-KitSddOpen $rows[$_]) })
    Out-Sdd "$nDone/$($all.Count) complete$(if ($open.Count) { "; відкриті: $(($open | ForEach-Object { "$_ $($rows[$_].State)" }) -join ', ')" })$(if ($st.P.Closed) { "; закрито $($st.P.Closed)" })"
    # Закритий журнал — нічого робити: `next: sdd close` вів би по колу.
    Out-Sdd $(if ($st.P.Closed) { 'закрито: далі нічого (close-block прибирає журнал разом із блоком)' } else { "next: $(Get-SddNextCommand $C $rows)" })
}

function Invoke-SddHandoff {
    param($C)
    $st = Get-SddState $C
    $l = $st.L
    $rows = $st.P.Rows
    $all = @(Get-SddAllIds $C $rows)
    $g = { param([string[]]$a) $x = Invoke-SddTryGit $C.Checkout $a; if ($x) { $x } else { '?' } }
    $line = {
        param($n)
        $r = $rows[$n]
        $extra = if ($r.Commits) { " ($($r.Commits))" } elseif ($r.Base) { " (base $(Get-SddShort $r.Base))" } else { '' }
        $note = if ($r.Notes.Count) { " — $($r.Notes[$r.Notes.Count - 1])" } else { '' }
        "- Задача $n`: $($r.State)$extra$note"
    }
    $doneIds = @($all | Where-Object { $rows[$_] -and (Test-KitSddDone $rows[$_]) })
    $open = @($all | Where-Object { $rows[$_] -and (Test-KitSddOpen $rows[$_]) })
    $doing = @($all | Where-Object { $rows[$_] -and -not (Test-KitSddDone $rows[$_]) -and -not (Test-KitSddOpen $rows[$_]) })
    $next = @($all | Where-Object { -not $rows[$_] }) | Select-Object -First 1
    $text = [System.Collections.Generic.List[string]]::new()
    $text.Add("# Передача — план $($l.Id)")
    $text.Add('')
    $text.Add("Checkout $($C.Checkout), гілка $(& $g @('branch', '--show-current')), HEAD $(& $g @('rev-parse', '--short', 'HEAD')). Журнал: $($l.File) — прочитай його перед дією; довіряй йому й git log, а не пам'яті.")
    $text.Add("Почни з ``sdd init $($l.Id)`` у цьому checkout (прив'яже план), далі ``sdd status``.")
    $text.Add('')
    $text.Add("## Зроблено ($($doneIds.Count)/$($all.Count))")
    if ($doneIds.Count) { foreach ($n in $doneIds) { $text.Add((& $line $n)) } } else { $text.Add('- немає') }
    $text.Add('')
    $text.Add('## У роботі')
    if ($doing.Count) { foreach ($n in $doing) { $text.Add((& $line $n)) } } else { $text.Add('- немає') }
    $text.Add('')
    $text.Add('## Відкрите (blocked, needs-context, fork, parked)')
    if ($open.Count) { foreach ($n in $open) { $text.Add((& $line $n)) } } else { $text.Add('- немає') }
    $text.Add('')
    $text.Add('## Далі')
    $text.Add($(if ($next) { "- Задача ${next}: ``sdd dispatch $next -Model <m> -Weight <w>``" } else { '- не лишилось задач без рядка в журналі' }))
    $text.Add('')
    $body = $text -join "`n"
    $file = Join-Path $l.Dir 'handoff.md'
    [System.IO.File]::WriteAllText($file, $body, (Get-SddUtf8))
    $bodySize = (Get-SddUtf8).GetByteCount($body)
    Out-Sdd "$file  $(Format-SddKb $bodySize): зроблено $($doneIds.Count), у роботі $($doing.Count), відкритих $($open.Count), далі $(if ($next) { $next } else { '—' })"
    Write-KitNext "надішли $file архітектору"
}

function Get-SddFileList {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)
}

function Invoke-SddClose {
    param($C)
    $st = Get-SddState $C
    $l = $st.L
    $p = $st.P
    if ($p.Closed) { Out-Sdd "вже закрито $($p.Closed)" }
    else { [System.IO.File]::AppendAllText($l.File, "# closed $([DateTime]::UtcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))`n", (Get-SddUtf8)) }
    $open = @($p.Rows.Values | Where-Object { -not (Test-KitSddDone $_) })
    if ($open.Count) { Out-Sdd "warn: задач не завершено: $($open.Count): $(($open | ForEach-Object { "$($_.N) $($_.State)" }) -join ', ')" }
    $all = Get-SddFileList $l.Dir
    $main = Get-KitMainRoot -Path $C.RepoRoot
    $relDir = [System.IO.Path]::GetRelativePath($main, $l.Dir) -replace '\\', '/'
    Out-Sdd "робоча тека лишається в головному checkout ($relDir): файлів $($all.Count), $(Format-SddKb (($all | Measure-Object Length -Sum).Sum))"
    Out-Sdd 'журнал — частина блоку: close-block читає його борг, а тоді прибирає теку; pr-gate cleanup його не чіпає'
    # pr-gate cleanup видаляє лише ignored-каталоги самого worktree, без архіву.
    if (Test-KitSddSamePath $C.Checkout (Get-KitMainRoot -Path $C.Checkout)) { Out-Sdd 'план у головному checkout: worktree для прибирання немає' }
    else {
        $arch = @('.agents/out', '.agents/sdd', '.superpowers') | ForEach-Object {
            $f = Get-SddFileList (Join-Path $C.Checkout $_)
            if ($f.Count) { "$_/ (файлів: $($f.Count))" }
        }
        Out-Sdd "pr-gate cleanup $($C.Checkout) видалить: $(if ($arch) { $arch -join ', ' } else { 'нічого' })"
    }
    # Рішення, що лишилось тільки в робочій теці, ухвалене таємно: секція йде в тіло PR. Коміти
    # задач — за вікнами: діапазон BASE..HEAD задачі міг би покрити чужі коміти.
    $ids = @(Get-KitSddSortedIds -Ids @($p.Rows.Values | Where-Object { $_.Commits -and (Test-KitSddDone $_) } | ForEach-Object { $_.N }))
    if ($ids.Count) {
        Out-Sdd 'коміти задач (об''єднання вікон виконання):'
        foreach ($n in $ids) { Out-Sdd "  Task ${n}: $(Format-SddCommitsCell $p.Rows[$n].Commits $C.Checkout)" }
    }
    Out-Sdd ''
    Out-Sdd '## Rulings'
    Out-Sdd ''
    if ($p.Rulings.Count) { for ($i = 0; $i -lt $p.Rulings.Count; $i++) { Out-Sdd "$($i + 1). Task $($p.Rulings[$i].N): $($p.Rulings[$i].Text)" } }
    else { Out-Sdd 'None.' }
    Out-Sdd ''
    # Редизайн — не латка: архітектор бачить, де план не витримав.
    $redesigns = @($p.Rows.Values | ForEach-Object { $r = $_; $r.Fixes | Where-Object { $_.Type -ceq 'redesign' } | ForEach-Object { [pscustomobject]@{ N = $r.N; Round = $_.Round; Approved = $_.Approved; Source = $_.Source; Note = $_.Note } } })
    Out-Sdd '## Redesign rounds'
    Out-Sdd ''
    if ($redesigns.Count) {
        for ($i = 0; $i -lt $redesigns.Count; $i++) {
            $f = $redesigns[$i]
            Out-Sdd "$($i + 1). Task $($f.N) round $($f.Round)$(if ($f.Approved) { " (approved by $($f.Approved))" })$(if ($f.Source -ceq 'controller') { ' (controller finding)' }): $(if ($f.Note) { $f.Note } else { '—' })"
        }
    } else { Out-Sdd 'None.' }
    Out-Sdd ''
    $forks = @($p.Rows.Values | Where-Object { $_.State -ceq 'fork' -or @($_.Notes | Where-Object { [regex]::IsMatch($_, '(?<![A-Za-z0-9_])fork(?![A-Za-z0-9_])', 'IgnoreCase') }).Count }).Count
    $headNow = Invoke-SddTryGit $C.Checkout @('rev-parse', 'HEAD')
    Out-Sdd "report: готово: <PR>, HEAD $(Get-SddShort $headNow), gates <ok|red: list>, $($p.Rulings.Count + $forks) розвилок, <M> відхилень"
    Out-Sdd "  ($($p.Rulings.Count) рішень + $forks задач із розвилкою; заповни <PR>, gates і <M> відхилень)"
    Write-KitNext 'pr-gate open -Title "…" -BodyFile <тіло PR із розділом Rulings>'
}

# ---------- вхід ----------

function Test-SddLooksLikePlan {
    # Перший аргумент — план, якщо це шлях до .md або наявний файл; інакше план поточний.
    param([AllowNull()][string]$S)
    $null -ne $S -and -not (Test-KitSddTaskId $S) -and ($S.EndsWith('.md') -or $S.Contains('/') -or $S.Contains('\') -or (Test-Path -LiteralPath $S))
}

function Invoke-SddCommand {
    param([string]$Cmd, [System.Collections.Generic.List[string]]$Args2, [hashtable]$Opts, [string]$RepoRoot)
    if ($Cmd -ceq 'init') {
        if ($Args2.Count -gt 1) { throw (New-KitUsageError "init: зайвий аргумент `"$($Args2[1])`"") }
        Invoke-SddInit -PlanArg $(if ($Args2.Count) { $Args2[0] } else { '' }) -RepoRoot $RepoRoot
        return
    }
    if (-not $Cmd -or -not $script:Arity.ContainsKey($Cmd)) { throw (New-KitUsageError "невідома підкоманда `"$Cmd`"") }
    $planArg = ''
    if ($Args2.Count -and (Test-SddLooksLikePlan $Args2[0])) { $planArg = $Args2[0]; $Args2.RemoveAt(0) }
    if ($Args2.Count -gt $script:Arity[$Cmd]) { throw (New-KitUsageError "${Cmd}: зайвий аргумент `"$($Args2[$script:Arity[$Cmd]])`"") }
    $n = if ($script:Arity[$Cmd]) { Get-SddTaskId $(if ($Args2.Count) { $Args2[0] } else { $null }) $Cmd } else { '' }
    $c = New-SddContext -PlanArg $planArg -Command $Cmd -RepoRoot $RepoRoot
    switch -CaseSensitive ($Cmd) {
        'brief' { Invoke-SddBrief $c $n }
        'log' { Invoke-SddLog $c $n $(if ($Args2.Count -gt 1) { $Args2[1] } else { '' }) $Opts }
        'status' { Invoke-SddStatus $c }
        'handoff' { Invoke-SddHandoff $c }
        'close' { Invoke-SddClose $c }
        'dispatch' { Invoke-SddDispatch $c $n $Opts }
        'resume' { Invoke-SddResume $c $n $Opts }
        'watch' { Invoke-SddWatch $c $n $Opts }
        'review' { Invoke-SddReview $c $n }
        'fix' { Invoke-SddFix $c $n $Opts }
        'done' { Invoke-SddDone $c $n $Opts }
        'ruling' { Invoke-SddRuling $c $n $(if ($Args2.Count -gt 1) { $Args2[1] } else { '' }) }
    }
}

function Invoke-KitSdd {
    param([string[]]$Arguments = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $script:LegacyNoted = $false
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{
        Commits = 'string'; Model = 'string'; Review = 'string'; Round = 'string'; Weight = 'string'; Note = 'string'
        Type = 'string'; Source = 'string'; ApprovedBy = 'string'; Timeout = 'string'; Interval = 'string'
    }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    $pos = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $a.Positional) { $pos.Add($p) }
    $cmd = ''
    if ($pos.Count) { $cmd = $pos[0]; $pos.RemoveAt(0) }
    # Усе, що повернули внутрішні функції, не має потрапити в pipeline: контракт команди — один int.
    $null = Invoke-SddCommand -Cmd $cmd -Args2 $pos -Opts $a.Named -RepoRoot $RepoRoot
    return 0
}

Export-ModuleMember -Function Invoke-KitSdd
