# Ported from agent-kit 0.9.1 bin/pr-gate (і prHead/конфлікт з lib/gh-run.mjs, mainRoot/worktreesRootOf з lib/profile.mjs), modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Конвеєр PR однією перевіреною командою: push -> PR -> злиття -> видалити гілку -> хто має
# `git merge origin/<base>` -> прибрати worktree. Уроки оригіналу: гілку видаляти лише після
# підтвердженого злиття; `git worktree remove` стирає ignored-журнал разом з деревом.
#
# Відмінності від оригіналу (рішення власника: CI немає, ADR-0005):
#   - немає `wait`, прогонів CI, requiredChecks, waitTimeout, попередження про скасування CI;
#     гейт злиття — стан PR (відкритий, не draft, MERGEABLE), а не прогони;
#   - `workspace.mode`: у `shared` `start` відмовляє, а `land` не зсуває головне дерево — друкує
#     `next:` для людини; у `worktree` усе як в оригіналі. Режиму «гілка в головному
#     checkout» немає: start вирішує лише за workspace.mode;
#   - суворіше за оригінал: захищені гілки (main, base, -Base, ціль origin/HEAD) не пушаться й не
#     видаляються ніде; віддалена гілка PR видаляється, лише коли її верхівка на origin = голова PR;
#     prune без gh не видаляє віддалених; назви гілок порівнюються з урахуванням регістру;
#     legacy-гілки scratch rm (kit-scratch-*/tree) немає.
#
# Уся логіка — тут, без `exit` і без читання профілю: значення приходять у контексті
# (New-PrGateContext). Друкує через -Say; помилки — винятки з кодом виходу (New-KitRefusal та ін.),
# які переводить у stderr і код виходу Invoke-KitProcessEntry. Виклик gh — лише через Invoke-KitGh.
# Тонка обгортка — tools/commands/pr-gate.psm1.

Import-Module "$PSScriptRoot/KitCli.psm1"
Import-Module "$PSScriptRoot/GhRun.psm1"
Import-Module "$PSScriptRoot/WorktreeInclude.psm1"

$script:DefaultSay = { param($Line) Write-KitLine $Line }
$script:MergeFields = @('number', 'state', 'isDraft', 'mergeable', 'headRefName', 'headRefOid', 'isCrossRepository', 'baseRefName', 'url')
# Теки, що зникають разом із worktree: робоче kit і стара тека журналів до переїзду в .agents/.
$script:JournalDirs = @('.agents/out', '.agents/sdd', '.superpowers')
$script:ScratchDir = '.scratch'
$script:ScratchPrefix = 's-'
$script:WorkspaceModes = @('shared', 'worktree')

# ---------------------------------------------------------------------------------------------
# довідка

$script:Usage = @'
pr-gate <крок> …   <pr> типово — PR поточної гілки

  pr-gate land <pr> [-MergeableTimeout <с>]
                           злиття -> оновити головний checkout -> after-merge -> cleanup -> гілка -> prune;
                           рядок на крок; повторний запуск продовжує після збою
  pr-gate open [-Draft] [-Base <b>] [-Title <т>] [-BodyFile <ф>]
                           push (ніколи force, ніколи base), створити PR або взяти наявний (оновлює назву/тіло)
  pr-gate ready [<pr>]     позначити draft-PR готовим до рев'ю
  pr-gate start <issue> [<slug>] [-Resume]
                           fetch; worktree <main>/.worktrees/<issue>-<slug> на гілці issue-<issue>-<slug>
                           (лише workspace.mode = worktree)
  pr-gate scratch add [<ref>]  одноразове відокремлене worktree; друкує лише шлях
  pr-gate scratch rm <шлях>    прибрати його (лише дерева, зроблені scratch add)
  pr-gate cleanup <worktree>   прибрати worktree разом із журналом, видалити його злиту гілку
  pr-gate merge [<pr>] [-Squash|-Merge] [-DryRun]   кроки, з яких складається land
  pr-gate after-merge [<pr>]
  pr-gate prune [-DryRun] [-Remote]
  pr-gate help [profile]   кожен крок докладно; поля профілю

Параметри: -MergeableTimeout (land); -Draft -Base -Title -BodyFile (open); -Resume (start);
-Squash -Merge -DryRun (merge); -DryRun -Remote (prune).
Коди виходу: 0 виконано; 1 збій; 2 помилка виклику; 3 не перевірено (поле профілю, gh відсутній чи
не залогінений, GitHub ще рахує mergeable).
'@

$script:DetailUsage = @'
pr-gate <крок> …

  pr-gate land <pr> [-Squash|-Merge] [-MergeableTimeout <с>=120]
        уся посадка, рядок на крок: draft позначається готовим -> злиття (pr.mergeMethod; повторює,
        поки GitHub каже mergeable UNKNOWN, зупиняється одразу на CONFLICTING) -> fast-forward
        головного checkout до origin/<base> (лише коли він чистий і на <base>; у workspace.mode =
        shared крок пропускається, а точну команду для людини друкує рядок next:) -> after-merge ->
        cleanup worktree гілки PR -> видалення локальної гілки -> prune. При збої: що зроблено, що
        ні, і точна наступна команда. Повторний запуск продовжує: завершені кроки пізнаються й
        пропускаються.
  pr-gate start <issue> [<slug>] [-Resume]
        лише workspace.mode = worktree (у shared відмова: гілку обирає архітектор чи власник, а
        перемикання гілки в спільному дереві зсуває HEAD іншим сесіям). git fetch origin; worktree
        <main>/<worktrees.root>/<issue>-<slug> (типово .worktrees, git-ignored) на новій гілці
        issue-<issue>-<slug> від origin/<base> (slug із назви issue, якщо не задано); друкує шлях і
        назву. Відмовляє, коли корінь не git-ignored, гілка чи шлях уже є, і каже, як продовжити:
        -Resume прикріплює worktree до наявної гілки issue (локальної чи з origin), коли жодне
        worktree її не тримає. Git-ignored нетрековані файли за .worktreeinclude (синтаксис
        gitignore: локальні налаштування, локальний профіль) копіюються в нове worktree; наявні
        лишаються
  pr-gate open [-Draft] [-Base <b>] [-Title <т>] [-BodyFile <ф>]
        push поточної гілки в гілку з тим самим іменем на origin (ніколи force; відмовляє на base з
        профілю, на -Base, на main і на цілі origin/HEAD), створює PR (-Draft: як draft) або бере відкритий; друкує URL і draft/ready
  pr-gate ready [<pr>]
        позначити draft-PR готовим (gh pr ready); нічого робити, коли він уже готовий
  pr-gate merge [<pr>] [-Squash|-Merge] [-DryRun]
        зливає лише відкритий не-draft PR зі станом MERGEABLE; прив'язаний до перевіреної голови
        (--match-head-commit: хтось запушив після перевірки — GitHub відмовить); потім перечитує
        стан і лише після підтвердженого MERGED видаляє віддалену гілку (гілку з форка не чіпає; і
        таку, чия верхівка на origin не дорівнює голові PR; і захищену: main, base).
        UNKNOWN — код 3; конфлікт — відмова з порадою `git merge origin/<base>`. Прогонів CI не
        дивиться: workflow немає
  pr-gate after-merge [<pr>]
        список локальних worktree, чиї гілки торкаються злитих файлів, з порадою злити; команди
        pr.afterMerge, чиї шляхи збігаються зі злитими файлами (код 1, якщо котрась упала)
  pr-gate prune [-DryRun] [-Remote]
        видаляє локальні гілки, злиті в origin/<base> (вміщені або голова злитого PR); -Remote —
        і віддалені (без gh віддалені не видаляються, код 3). Ніколи захищені (main, base, ціль
        origin/HEAD), гілку worktree, гілку з комітами після злиття PR і віддалену гілку з відкритим PR
  pr-gate cleanup <worktree>
        git worktree remove (без --force); git-ignored теки журналів (.agents/out/, .agents/sdd/,
        .superpowers/) зникають разом з ним, копії немає; потім видаляє локальну гілку worktree,
        якщо її PR злито на цій верхівці. Головний checkout — ніколи
  pr-gate scratch add [<ref>=HEAD]
        одноразове відокремлене worktree в новій унікальній теці <main>/<worktrees.root>/.scratch/<id>
        для перевірок мутацією; відмовляє, коли <worktrees.root>/.scratch не git-ignored; друкує лише шлях
  pr-gate scratch rm <шлях>
        force-видаляє його; відмовляє на будь-яке дерево, якого scratch add не робив

<pr> типово — PR поточної гілки. Нічого не примушує force: ні push, ні видалення гілок.
Коди виходу: 0 виконано; 1 збій (не зливається, помилка git чи gh, лишився крок land);
2 помилка виклику; 3 не перевірено (немає поля профілю, gh відсутній, mergeable UNKNOWN).
'@

$script:ProfileUsage = @'
Профіль .agents/kit.profile.json (шари: машинний, проєктний, локальний):
  workspace.mode  "shared"|"worktree"   (start, land; обов'язкове: скрипт його не вгадує)
  pr.base         гілка                 (open, start, prune, land; типово "main"; -Base у open сильніший)
  pr.mergeMethod  "squash"|"merge"      (merge, land, якщо не задано прапорець)
  pr.afterMerge   [{ paths: [glob], run: [argv] }]   (after-merge; argv без shell, у корені репо)
  worktrees.root  шлях                  (start, scratch; типово ".worktrees", відносно головного checkout, git-ignored)
'@

function Get-PrGateUsage { $script:Usage.TrimEnd() }
function Get-PrGateDetailUsage { $script:DetailUsage.TrimEnd() }
function Get-PrGateProfileUsage { $script:ProfileUsage.TrimEnd() }

# ---------------------------------------------------------------------------------------------
# контекст

function New-PrGateContext {
    <#
    .SYNOPSIS
        Значення профілю й шляхи для кроків: Root (checkout, у якому працюємо), MainRoot (головний
        checkout — спільний стан), Base, WorktreesRoot (відносно MainRoot), WorkspaceMode,
        AfterMerge (pr.afterMerge), OutDir (.agents/out головного checkout).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MainRoot,
        [string]$Base = 'main',
        [string]$WorktreesRoot = '.worktrees',
        [string]$WorkspaceMode,
        $AfterMerge = @(),
        [string]$OutDir
    )
    [pscustomobject]@{
        Root = $Root; MainRoot = $MainRoot; Base = $Base; WorktreesRoot = $WorktreesRoot
        WorkspaceMode = $WorkspaceMode; AfterMerge = $AfterMerge
        OutDir = $(if ($OutDir) { $OutDir } else { Join-Path $MainRoot '.agents/out' })
    }
}

function Assert-PrGateWorkspaceMode {
    <# Значення workspace.mode з профілю: інше за shared|worktree — «не перевірено» (код 3) з переліком. #>
    param([AllowNull()][AllowEmptyString()]$Value)
    if ($null -eq $Value) { throw (New-KitNotChecked 'поле профілю "workspace.mode" порожнє (null); допустимі: shared, worktree') }
    $v = [string]$Value
    if ($v -notin $script:WorkspaceModes) {
        throw (New-KitNotChecked "поле профілю `"workspace.mode`" має значення `"$v`"; допустимі: $($script:WorkspaceModes -join ', ')")
    }
    $v
}

# ---------------------------------------------------------------------------------------------
# git, шляхи, gh

function Invoke-PgGit {
    <#
        git як .NET Process: stdout і stderr окремо, UTF-8, код виходу в результаті. Ok — код 0.
        Out — stdout (trim), Raw — без обрізання (для -z), Err — перший рядок stderr.
    #>
    param([Parameter(Mandatory)][string[]]$GitArgs, [string]$Cwd)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $all = if ($Cwd) { @('-C', $Cwd) + $GitArgs } else { $GitArgs }
    foreach ($a in $all) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Ok = $false; Code = -1; Raw = ''; Out = ''; Err = "git не запускається: $($_.Exception.Message)" } }
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $raw = $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        [pscustomobject]@{
            Ok = ($proc.ExitCode -eq 0); Code = $proc.ExitCode; Raw = $raw; Out = $raw.Trim()
            Err = (($err.Trim() -split "\r?\n")[0])
        }
    } finally { $proc.Dispose() }
}

function Get-PgGit {
    <# stdout git (trim) або відмова з першим рядком stderr. #>
    param([Parameter(Mandatory)][string[]]$GitArgs, [string]$Cwd)
    $r = Invoke-PgGit -GitArgs $GitArgs -Cwd $Cwd
    if (-not $r.Ok) { throw (New-KitRefusal "git $($GitArgs -join ' '): $($r.Err)") }
    $r.Out
}

function Format-PgPath {
    <# Повний шлях зі слешами `/` без хвостового, для порівняння (на Windows `\` і `/`, регістр диска). #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full.Length -gt 1 -and $full.EndsWith('/') -and $full -notmatch '^[A-Za-z]:/$') { $full = $full.TrimEnd('/') }
    $full
}

function Test-PgSamePath {
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    [string]::Equals((Format-PgPath $A), (Format-PgPath $B), $cmp)
}

function Test-PgInsidePath {
    <# Чи $Path збігається з $Dir або лежить під ним. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Dir)
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $p = Format-PgPath $Path
    $d = Format-PgPath $Dir
    [string]::Equals($p, $d, $cmp) -or $p.StartsWith($d.TrimEnd('/') + '/', $cmp)
}

function Get-PgWorktrees {
    <# Worktree репозиторію: @{ Path; Branch } (Branch відсутній у відокремлених). #>
    param([Parameter(Mandatory)][string]$Cwd)
    $list = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in ((Get-PgGit -GitArgs @('worktree', 'list', '--porcelain') -Cwd $Cwd) -split "\r?\n")) {
        if ($line.StartsWith('worktree ')) {
            $cur = [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($line.Substring(9)); Branch = $null }
            $list.Add($cur)
        } elseif ($line.StartsWith('branch ') -and $cur) { $cur.Branch = $line.Substring(7) -replace '^refs/heads/', '' }
    }
    $list.ToArray()
}

function Test-PgIgnored {
    <# Чи покриває .gitignore відносний шлях (файла може ще не бути). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    (Invoke-PgGit -GitArgs @('check-ignore', '-q', '--no-index', $Rel) -Cwd $Root).Ok
}

function Invoke-PgGh {
    <# gh: «не перевірено» (3), коли його немає чи не залогінений; збій команди — відмова (1). #>
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    try {
        if ($Json) { return Invoke-KitGh -Arguments $Arguments -Json }
        Invoke-KitGh -Arguments $Arguments
    } catch [KitGhUnavailable] {
        throw (New-KitNotChecked "gh $(@($Arguments | Select-Object -First 2) -join ' '): $($_.Exception.Message)")
    } catch [KitGhError] {
        throw (New-KitRefusal $_.Exception.Message)
    }
}

function Get-PgPr {
    <# Стан PR; без номера — PR поточної гілки (gh приймає ім'я гілки замість номера). #>
    param($Ctx, [string]$Pr, [Parameter(Mandatory)][string[]]$Fields)
    $target = $Pr
    if (-not $target) {
        $target = Get-PgGit -GitArgs @('branch', '--show-current') -Cwd $Ctx.Root
        if (-not $target) { throw (New-KitUsageError 'detached HEAD: перемкнись на гілку або назви номер PR') }
    }
    try { Get-KitPrState -Pr $target -Fields $Fields }
    catch [KitGhUnavailable] { throw (New-KitNotChecked "gh pr view: $($_.Exception.Message)") }
    catch [KitGhError] { throw (New-KitRefusal $_.Exception.Message) }
}

function Get-PgConflictNext {
    <# Наступний крок при конфлікті PR з base: однаковий для merge і land. #>
    param($Ctx, [string]$Branch, [string]$Base, [string]$Then)
    $wt = @(Get-PgWorktrees -Cwd $Ctx.MainRoot) | Where-Object { $_.Branch -ceq $Branch } | Select-Object -First 1
    "git -C $(if ($wt) { $wt.Path } else { '<worktree гілки>' }) merge origin/$Base, розв'яжи, pr-gate open, потім $Then"
}

function Get-PgProtectedBranches {
    <#
        Захищені гілки: main, base профілю, base цього виклику (-Extra: -Base, baseRefName PR) і ціль
        origin/HEAD. Їх pr-gate не пушить і не видаляє ніде (віддалено чи локально). Порівнювати —
        лише -ccontains: на регістрочутливих ФС Main і main — різні гілки.
    #>
    param($Ctx, [string[]]$Extra = @())
    $set = [System.Collections.Generic.List[string]]::new()
    foreach ($b in (@('main', $Ctx.Base) + @($Extra))) { if ($b) { $set.Add([string]$b) } }
    $head = Invoke-PgGit -GitArgs @('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD') -Cwd $Ctx.MainRoot
    if ($head.Ok -and $head.Out -cmatch '^refs/remotes/origin/(.+)$') { $set.Add($Matches[1]) }
    $set.ToArray()
}

function ConvertTo-PgRefPath {
    <# Шлях ref гілки в gh api: кожен сегмент між `/` кодується (`#`, `%`, `?` у назві не ріжуть URL). #>
    param([Parameter(Mandatory)][string]$Branch)
    (($Branch -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Remove-PgRemoteBranch {
    <#
        Видалення гілки на origin через gh api — лише коли гілка не захищена й її верхівка на origin
        (gh api .../git/ref/heads/<гілка>, читання в момент видалення) дорівнює -ExpectedOid (голова
        злитого PR або верхівка, яку перевірено). Інакше гілка лишається з поясненням і точною командою
        для людини. Повертає $true, коли видалено.
    #>
    param($Ctx, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ExpectedOid,
        [string[]]$Protected = @(), [Parameter(Mandatory)][scriptblock]$Say)
    if ($Protected -ccontains $Name) { & $Say "віддалену гілку $Name лишено: захищена (main, base чи ціль origin/HEAD)"; return $false }
    $refPath = "repos/{owner}/{repo}/git/refs/heads/$(ConvertTo-PgRefPath $Name)"
    $tip = $null
    try { $tip = [string](Invoke-KitGh -Arguments @('api', "repos/{owner}/{repo}/git/ref/heads/$(ConvertTo-PgRefPath $Name)", '--jq', '.object.sha')) }
    catch [KitGhUnavailable] { throw (New-KitNotChecked "gh api: $($_.Exception.Message)") }
    catch [KitGhError] {
        if ($_.Exception.Message -match '404|Not Found') { & $Say "віддаленої гілки $Name немає"; return $false }
        throw (New-KitRefusal $_.Exception.Message)
    }
    $tip = $tip.Trim()
    if ($tip -cne $ExpectedOid) {
        $shown = if ($tip) { $tip.Substring(0, [Math]::Min(7, $tip.Length)) } else { 'невідома' }
        & $Say "віддалену гілку $Name лишено: її верхівка на origin ($shown) не дорівнює $($ExpectedOid.Substring(0, [Math]::Min(7, $ExpectedOid.Length))), тож там є зайві коміти; видали сам, якщо вона не потрібна: gh api -X DELETE $refPath"
        return $false
    }
    $null = Invoke-PgGh -Arguments @('api', '-X', 'DELETE', $refPath)
    $true
}

# ---------------------------------------------------------------------------------------------
# open, ready

function Invoke-PrGateOpen {
    <# push поточної гілки (ніколи force, ніколи base і main), PR: створити або взяти наявний. #>
    param($Ctx, [switch]$Draft, [string]$Base, [string]$Title, [string]$BodyFile, [scriptblock]$Say = $script:DefaultSay)
    $branch = Get-PgGit -GitArgs @('branch', '--show-current') -Cwd $Ctx.Root
    if (-not $branch) { throw (New-KitUsageError 'detached HEAD: спершу перемкнись на гілку') }
    $target = if ($Base) { $Base } else { $Ctx.Base }
    # Агенти пушать гілки блоків без питання (рішення власника): тому base і main pr-gate не пушить
    # ніколи, навіть із -Base іншої гілки.
    if ((Get-PgProtectedBranches -Ctx $Ctx -Extra @($Base)) -ccontains $branch) {
        throw (New-KitUsageError "на $branch`: pr-gate ніколи не пушить захищену гілку (main, base, ціль origin/HEAD); відкривай PR із гілки задачі")
    }
    # Лише звичайний push і явний refspec у гілку з тим самим іменем: worktree від origin/main має
    # upstream origin/main, і push.default=upstream інакше пішов би в main. Force не існує.
    $null = Get-PgGit -GitArgs @('push', '-u', 'origin', "refs/heads/${branch}:refs/heads/${branch}") -Cwd $Ctx.Root
    & $Say "запушено $branch"
    $existing = @(Invoke-PgGh -Arguments @('pr', 'list', '--head', $branch, '--state', 'open', '--json', 'url,number,isDraft') -Json | Where-Object { $_ })
    if ($existing.Count) {
        $p = $existing[0]
        $n = $p.number
        # Повторний open лише пушить: draft не стає ready і навпаки (для цього — pr-gate ready).
        & $Say "PR уже є ($(if ($p.isDraft) { 'draft' } else { 'готовий до рев''ю' })): $($p.url)"
        if ($Draft -and -not $p.isDraft) { & $Say 'примітка: PR уже готовий до рев''ю; -Draft його назад у draft не повертає' }
        # Тіло й назву, передані явно, переносимо в наявний PR: інакше виконавець вважає звіт у тілі
        # оновленим, а архітектор читає старий.
        $edit = @()
        if ($Title) { $edit += @('--title', $Title) }
        if ($BodyFile) { $edit += @('--body-file', $BodyFile) }
        if ($edit.Count) {
            $null = Invoke-PgGh -Arguments (@('pr', 'edit', [string]$n) + $edit)
            & $Say "оновлено $(@(if ($Title) { 'назву' }; if ($BodyFile) { 'тіло' }) -join ' і '): #$n"
        }
        Write-KitNext "pr-gate land $n"
        return 0
    }
    $ghArgs = @('pr', 'create', '--base', $target, '--head', $branch)
    if ($Draft) { $ghArgs += '--draft' }
    if ($Title) { $ghArgs += @('--title', $Title) }
    if ($BodyFile) { $ghArgs += @('--body-file', $BodyFile) }
    if (-not $Title -or -not $BodyFile) { $ghArgs += '--fill' }
    $url = @((Invoke-PgGh -Arguments $ghArgs) -split "\r?\n")[-1]
    & $Say "PR створено$(if ($Draft) { ' (draft)' }): $url"
    Write-KitNext "pr-gate land $(($url -split '/')[-1])"
    0
}

function Invoke-PrGateReady {
    param($Ctx, [string]$Pr, [scriptblock]$Say = $script:DefaultSay)
    $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields @('number', 'state', 'isDraft')
    if ($p.state -ne 'OPEN') { throw (New-KitRefusal "#$($p.number) має стан $($p.state): готовим позначати нічого") }
    if (-not $p.isDraft) { & $Say "#$($p.number) уже готовий до рев'ю" }
    else {
        $null = Invoke-PgGh -Arguments @('pr', 'ready', [string]$p.number)
        & $Say "готово: #$($p.number) позначено готовим до рев'ю"
    }
    Write-KitNext "pr-gate merge $($p.number)"
    0
}

# ---------------------------------------------------------------------------------------------
# merge

function Invoke-PgMergeChecked {
    <#
        Перевірки й злиття одного PR; рядки — через -Say. Гейт: PR OPEN, не draft, не конфліктний,
        mergeable == MERGEABLE (UNKNOWN — код 3). Злиття прив'язане до перевіреної голови; після
        нього стан перечитується, і гілка видаляється лише при підтвердженому MERGED.
    #>
    param($Ctx, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Method, [switch]$DryRun, [Parameter(Mandatory)][scriptblock]$Say)
    $p = $State
    $fail = { param($why, $hint) throw (New-KitRefusal ("НЕ ЗЛИТО #$($p.number): $why" + $(if ($hint) { "`n$hint" } else { '' }))) }
    if ($p.state -ne 'OPEN') { & $fail "стан $($p.state)" }
    if ($p.isDraft) { & $fail 'draft' "pr-gate ready $($p.number) (або pr-gate land $($p.number) сам позначить готовим)" }
    if ($p.Conflict) { & $fail "PR у конфлікті з $($p.baseRefName)" (Get-PgConflictNext -Ctx $Ctx -Branch $p.headRefName -Base $p.baseRefName -Then "pr-gate merge $($p.number)") }
    # UNKNOWN — GitHub ще рахує; це «не перевірено», а не провал.
    if ($p.mergeable -eq 'UNKNOWN') { throw (New-KitNotChecked "НЕ ЗЛИТО #$($p.number): mergeable UNKNOWN (GitHub ще рахує); повтори пізніше") }
    if ($p.mergeable -ne 'MERGEABLE') { & $fail "mergeable $($p.mergeable)" }
    $sha7 = $p.headRefOid.Substring(0, [Math]::Min(7, $p.headRefOid.Length))
    if ($DryRun) {
        & $Say "ПРОБНИЙ ПРОГІН: злив би #$($p.number) методом $Method на $sha7 і видалив би $($p.headRefName)"
        return 0
    }
    # --match-head-commit: якщо після перевірки хтось запушив, GitHub відмовить, і неперевірений
    # коміт не потрапить у base.
    $null = Invoke-PgGh -Arguments @('pr', 'merge', [string]$p.number, "--$Method", '--match-head-commit', $p.headRefOid)
    $after = Get-PgPr -Ctx $Ctx -Pr ([string]$p.number) -Fields @('state', 'mergeCommit')
    if ($after.state -ne 'MERGED') { & $fail "gh pr merge повернув керування, але стан $($after.state); гілку лишено" }
    $oid = if ($after.mergeCommit -and $after.mergeCommit.oid) { ([string]$after.mergeCommit.oid).Substring(0, 7) } else { '?' }
    & $Say "ЗЛИТО #$($p.number) як $oid"
    # Гілку — лише після підтвердженого злиття; гілка з форка не наша.
    if ($p.isCrossRepository) { & $Say "гілка $($p.headRefName) у форку: не видалено" }
    elseif (Remove-PgRemoteBranch -Ctx $Ctx -Name $p.headRefName -ExpectedOid $p.headRefOid -Protected (Get-PgProtectedBranches -Ctx $Ctx -Extra @($p.baseRefName)) -Say $Say) {
        & $Say "видалено віддалену гілку $($p.headRefName)"
    }
    0
}

function Invoke-PrGateMerge {
    param($Ctx, [string]$Pr, [Parameter(Mandatory)][string]$Method, [switch]$DryRun, [scriptblock]$Say = $script:DefaultSay)
    $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields $script:MergeFields
    $null = Invoke-PgMergeChecked -Ctx $Ctx -State $p -Method $Method -DryRun:$DryRun -Say $Say
    if (-not $DryRun) { Write-KitNext "pr-gate after-merge $($p.number)" } else { Write-KitNext "pr-gate merge $($p.number)" }
    0
}

# ---------------------------------------------------------------------------------------------
# start

function Get-PrGateSlug {
    <# Slug з назви issue: частина до «:», лише a-z0-9, до 30 символів по межі слова; кирилиця дає «task». #>
    param([AllowEmptyString()][string]$Title)
    $head = ($Title -split ':')[0].ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $slug = ''
    foreach ($m in [regex]::Matches($head, '[a-z0-9]+')) {
        $next = if ($slug) { "$slug-$($m.Value)" } else { $m.Value }
        if ($next.Length -gt 30) { break }
        $slug = $next
    }
    if ($slug) { $slug } else { 'task' }
}

function Invoke-PrGateStart {
    param($Ctx, [Parameter(Mandatory)][AllowEmptyString()][string]$Issue, [string]$Slug, [switch]$Resume, [scriptblock]$Say = $script:DefaultSay)
    if ($Issue -notmatch '^\d+$') { throw (New-KitUsageError 'start: назви номер issue') }
    if ($Slug -and $Slug -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw (New-KitUsageError 'start: slug — слова a-z0-9, з''єднані «-»') }
    # shared: одне дерево, одна база агента. Гілку обирає архітектор чи власник; перемкнути гілку в
    # спільному дереві — зсунути HEAD іншим сесіям (ADR-0005).
    if ($Ctx.WorkspaceMode -ceq 'shared') {
        throw (New-KitRefusal "start: workspace.mode = shared: гілку задачі обирає архітектор чи власник, а перемикання гілки в спільному дереві зсуває HEAD іншим сесіям`nпрацюй у наявній гілці; worktree для задач — лише в профілі з workspace.mode = worktree")
    }
    if ($Ctx.WorkspaceMode -cne 'worktree') { throw (New-KitNotChecked 'поле профілю "workspace.mode" має бути "shared" або "worktree"') }
    $root = $Ctx.MainRoot
    $base = $Ctx.Base
    $ghIssue = Invoke-PgGh -Arguments @('issue', 'view', $Issue, '--json', 'number,title,state') -Json
    if ($ghIssue.state -ne 'OPEN') { & $Say "увага: issue #$Issue має стан $($ghIssue.state)" }
    $null = Get-PgGit -GitArgs @('fetch', '-q', 'origin') -Cwd $root

    # Будь-яка гілка цієї задачі — навіть з іншим slug — означає, що робота вже почата.
    $prefix = "issue-$Issue-"
    $localBranches = @((Get-PgGit -GitArgs @('for-each-ref', '--format=%(refname:short)', "refs/heads/$prefix*") -Cwd $root) -split "\r?\n" | Where-Object { $_ })
    $remoteBranches = @((Get-PgGit -GitArgs @('for-each-ref', '--format=%(refname:short)', "refs/remotes/origin/$prefix*") -Cwd $root) -split "\r?\n" | Where-Object { $_ } | ForEach-Object { $_ -replace '^origin/', '' })
    $wts = @(Get-PgWorktrees -Cwd $root)
    $existing = if ($localBranches.Count) { $localBranches[0] } elseif ($remoteBranches.Count) { $remoteBranches[0] } else { $null }
    if ($existing) {
        $held = $wts | Where-Object { $_.Branch -ceq $existing } | Select-Object -First 1
        if ($held) { throw (New-KitRefusal "ВІДМОВА: issue #$Issue уже має гілку $existing у worktree $($held.Path); продовжуй: cd $($held.Path)") }
        if (-not $Resume) {
            throw (New-KitRefusal "ВІДМОВА: issue #$Issue уже має гілку $existing$(if ($localBranches -cnotcontains $existing) { ' на origin' }); продовжити: pr-gate start $Issue -Resume")
        }
    } elseif ($Resume) {
        throw (New-KitRefusal "ВІДМОВА: у issue #$Issue немає гілки $prefix* для продовження; почати: pr-gate start $Issue")
    }
    $branch = if ($existing) { $existing } else { "$prefix$(if ($Slug) { $Slug } else { Get-PrGateSlug $ghIssue.title })" }

    # Тека worktree — номер і slug гілки: `issue-56-fix` -> `<root>/56-fix`.
    $path = Join-Path (Join-Path $root $Ctx.WorktreesRoot) $branch.Substring('issue-'.Length)
    # Worktree у репо: без рядка в .gitignore головний checkout бачить його як нетрекнуту теку, і
    # `git add -A` забрав би чужий checkout у коміт.
    if (-not (Test-PgIgnored -Root $root -Rel "$($Ctx.WorktreesRoot)/$($branch.Substring('issue-'.Length))")) {
        throw (New-KitRefusal "ВІДМОВА: $($Ctx.WorktreesRoot)/ не git-ignored у $root; додай `"$($Ctx.WorktreesRoot)/`" у .gitignore, потім pr-gate start $Issue$(if ($Resume) { ' -Resume' })")
    }
    if (Test-Path -LiteralPath $path) {
        $held = $wts | Where-Object { Test-PgSamePath $_.Path $path } | Select-Object -First 1
        throw (New-KitRefusal "ВІДМОВА: $path уже існує$(if ($held) { " (worktree гілки $(if ($held.Branch) { $held.Branch } else { 'відокремленого HEAD' })); продовжуй: cd $path" } else { '; прибери його або дай інший slug' })")
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    if ($existing -and $localBranches -ccontains $existing) {
        $null = Get-PgGit -GitArgs @('worktree', 'add', '-q', $path, $existing) -Cwd $root
        & $Say "продовжено #$Issue `"$($ghIssue.title)`"`n$path`nгілка $existing (локальна, $(Get-PgGit -GitArgs @('rev-parse', '--short', $existing) -Cwd $root))"
    } elseif ($existing) {
        # Гілка лише на origin (інша машина, прибраний клон): локальна з її верхівки, upstream — та
        # сама гілка на origin, не base.
        $null = Get-PgGit -GitArgs @('worktree', 'add', '-q', '--track', '-b', $existing, $path, "origin/$existing") -Cwd $root
        & $Say "продовжено #$Issue `"$($ghIssue.title)`"`n$path`nгілка $existing з origin/$existing ($(Get-PgGit -GitArgs @('rev-parse', '--short', "origin/$existing") -Cwd $root))"
    } else {
        $null = Get-PgGit -GitArgs @('worktree', 'add', '-q', '-b', $branch, $path, "origin/$base") -Cwd $root
        # Без upstream на origin/<base>: інакше `git push` без аргументів пішов би в base.
        $null = Invoke-PgGit -GitArgs @('branch', '--unset-upstream', $branch) -Cwd $root
        & $Say "розпочато #$Issue `"$($ghIssue.title)`"`n$path`nгілка $branch від origin/$base ($(Get-PgGit -GitArgs @('rev-parse', '--short', "origin/$base") -Cwd $root))"
    }
    # Локальні налаштування (дозволи, профіль) не в git: без копії сесія у worktree їх не мала б.
    $copied = Format-KitCopiedLine (Copy-KitWorktreeInclude -Root $root -Dest $path -Skip @($Ctx.WorktreesRoot))
    if ($copied) { & $Say $copied }
    Write-KitNext "cd $path; працюй і коміть там, потім pr-gate open"
    0
}

# ---------------------------------------------------------------------------------------------
# after-merge

function ConvertTo-PgGlobRegex {
    <# Glob (`**`, `*`, `?`) -> регулярний вираз по відносному шляху зі слешами `/`. #>
    param([Parameter(Mandatory)][string]$Glob)
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*' -and $i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3 } else { [void]$sb.Append('.*'); $i += 2 }
        } elseif ($c -eq '*') { [void]$sb.Append('[^/]*'); $i++ }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]'); $i++ }
        else { [void]$sb.Append([regex]::Escape([string]$c)); $i++ }
    }
    [void]$sb.Append('$')
    $sb.ToString()
}

function Invoke-PgArgv {
    <# Команда з argv без shell, у корені репо: @{ Ok; Why; Tail }. #>
    param([Parameter(Mandatory)][string[]]$Argv, [Parameter(Mandatory)][string]$Cwd)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Argv[0]
    foreach ($a in ($Argv | Select-Object -Skip 1)) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Ok = $false; Why = $_.Exception.Message; Tail = @() } }
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $text = ($outTask.GetAwaiter().GetResult() + $errTask.GetAwaiter().GetResult()).Trim()
        [pscustomobject]@{
            Ok = ($proc.ExitCode -eq 0); Why = "код $($proc.ExitCode)"
            Tail = @(($text -split "\r?\n") | Where-Object { $_ } | Select-Object -Last 10)
        }
    } finally { $proc.Dispose() }
}

function Invoke-PgAfterMergeCommands {
    <# Проєктний крок після злиття: команда — argv без shell, щоб профіль не став місцем для ін'єкцій. Повертає число збоїв. #>
    param($Ctx, [string[]]$Files, [scriptblock]$Say)
    $entries = $Ctx.AfterMerge
    if ($null -eq $entries) { $entries = @() }
    if ($entries -isnot [System.Collections.IList]) { throw (New-KitNotChecked 'поле профілю "pr.afterMerge" має бути списком { paths, run }') }
    $failed = 0
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $run = if ($e -is [System.Collections.IDictionary] -and $e.Contains('run')) { , $e['run'] } else { $null }
        $paths = if ($e -is [System.Collections.IDictionary] -and $e.Contains('paths')) { , $e['paths'] } else { $null }
        $okRun = $run -is [System.Collections.IList] -and $run.Count -gt 0 -and -not @($run | Where-Object { $_ -isnot [string] })
        $okPaths = $paths -is [System.Collections.IList] -and -not @($paths | Where-Object { $_ -isnot [string] })
        if (-not $okRun -or -not $okPaths) { throw (New-KitNotChecked "поле профілю `"pr.afterMerge[$i]`" потребує paths: [glob] і run: [argv]") }
        $regexes = @($paths | ForEach-Object { [regex]::new((ConvertTo-PgGlobRegex $_), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant) })
        $hit = $Files | Where-Object { $f = $_; $regexes | Where-Object { $_.IsMatch($f) } } | Select-Object -First 1
        if (-not $hit) { continue }
        $shown = $run -join ' '
        $r = Invoke-PgArgv -Argv ([string[]]$run) -Cwd $Ctx.Root
        if ($r.Ok) { & $Say "after-merge: $shown -> ok (збіглося $hit)"; continue }
        $failed++
        & $Say "after-merge: $shown -> ЗБІЙ $($r.Why) (збіглося $hit)"
        if ($r.Tail.Count) { & $Say (($r.Tail | ForEach-Object { "  $_" }) -join "`n") }
    }
    $failed
}

function Invoke-PgAfterMergeReport {
    <# Поради сусіднім worktree і команди pr.afterMerge. `land` прибирає гілку PR сам (-InLand). Повертає код. #>
    param($Ctx, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][scriptblock]$Say, [switch]$InLand)
    $p = $State
    $merged = [System.Collections.Generic.HashSet[string]]::new([string[]]@($p.files | ForEach-Object { $_.path }), [System.StringComparer]::Ordinal)
    $root = $Ctx.MainRoot
    $null = Get-PgGit -GitArgs @('fetch', '-q', 'origin') -Cwd $root
    $base = "origin/$($p.baseRefName)"
    $advised = 0
    foreach ($wt in (Get-PgWorktrees -Cwd $root)) {
        if (-not $wt.Branch -or $wt.Branch -ceq $p.baseRefName) { continue }
        if ($wt.Branch -ceq $p.headRefName) {
            if (-not $InLand) { & $Say "$($wt.Path) ($($wt.Branch)): злита гілка -> pr-gate cleanup $($wt.Path)" }
            continue
        }
        # Свої зміни гілки (від точки розходження) плюс незакомічене в дереві.
        $mb = Get-PgGit -GitArgs @('merge-base', $base, $wt.Branch) -Cwd $wt.Path
        $own = (Get-PgGit -GitArgs @('-c', 'core.quotepath=false', 'diff', '--name-only', $mb, $wt.Branch) -Cwd $wt.Path) -split "\r?\n"
        $dirty = @((Get-PgGit -GitArgs @('-c', 'core.quotepath=false', 'diff', '--name-only', 'HEAD') -Cwd $wt.Path) -split "\r?\n") +
            @((Get-PgGit -GitArgs @('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard') -Cwd $wt.Path) -split "\r?\n")
        $overlap = @(($own + $dirty) | Where-Object { $_ -and $merged.Contains($_) } | Select-Object -Unique)
        if (-not $overlap.Count) { continue }
        $advised++
        & $Say "$($wt.Path) ($($wt.Branch)): торкається $($overlap -join ', ') -> git -C $($wt.Path) merge $base"
    }
    & $Say $(if ($advised) { "$advised worktree мають злити $base" } else { "жодне worktree не торкається $($merged.Count) злитих файлів" })
    if (Invoke-PgAfterMergeCommands -Ctx $Ctx -Files @($merged) -Say $Say) { return 1 }
    0
}

function Invoke-PrGateAfterMerge {
    param($Ctx, [string]$Pr, [scriptblock]$Say = $script:DefaultSay)
    $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields @('number', 'state', 'baseRefName', 'headRefName', 'files')
    if ($p.state -ne 'MERGED') { throw (New-KitRefusal "#$($p.number) має стан $($p.state), а не злитий") }
    $code = Invoke-PgAfterMergeReport -Ctx $Ctx -State $p -Say $Say
    if ($code -ne 0) { throw (New-KitRefusal 'команда pr.afterMerge впала (вище)') }
    Write-KitNext 'none'
    0
}

# ---------------------------------------------------------------------------------------------
# prune, cleanup

function Get-PgGhWhy {
    <# Чому gh не відповів — словами, а не першим рядком його stderr. #>
    param($ErrorRecord)
    $m = [string]$ErrorRecord.Exception.Message
    if ($ErrorRecord.Exception -is [KitGhUnavailable] -and $m -notmatch 'залогінений') { return 'gh не встановлено' }
    if ($m -match 'none of the git remotes|no git remotes|not a git repository') { return 'у цього репозиторію немає GitHub-remote' }
    if ($m -match 'залогінений|auth login|not logged in|authentication') { return 'gh не залогінений (gh auth login)' }
    "gh збій ($($m.Substring(0, [Math]::Min(80, $m.Length))))"
}

function Invoke-PgPrune {
    <#
        Злиті гілки: вміст гілки вже в origin/<base> (звичайне злиття), або її верхівка — голова
        злитого PR (squash: предка немає, тож дивимось на стан PR). Верхівка != голова PR — у гілці є
        коміти після злиття, вона не зайва. Друкує підсумок, повертає @{ Deleted; Skipped; NotChecked }.
    #>
    param($Ctx, [switch]$DryRun, [switch]$Remote, [Parameter(Mandatory)][scriptblock]$Say)
    $base = $Ctx.Base
    $cwd = $Ctx.MainRoot   # не Root: у land worktree цього checkout уже видалено
    $null = Get-PgGit -GitArgs @('fetch', '-q', '--prune', 'origin') -Cwd $cwd
    $baseRef = "origin/$base"
    $protected = Get-PgProtectedBranches -Ctx $Ctx
    # Словник чутливий до регістру: гілки Feat і feat різні.
    $held = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($w in (Get-PgWorktrees -Cwd $cwd)) { if ($w.Branch) { $held[$w.Branch] = $w.Path } }
    $refs = {
        param($pattern)
        @((Get-PgGit -GitArgs @('for-each-ref', '--format=%(refname:short) %(objectname)', $pattern) -Cwd $cwd) -split "\r?\n" |
            Where-Object { $_ } | ForEach-Object { $x = $_ -split ' '; [pscustomobject]@{ Name = $x[0]; Sha = $x[1] } })
    }
    $branches = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (& $refs 'refs/heads')) { $branches.Add([pscustomobject]@{ Name = $r.Name; Sha = $r.Sha; Where = 'local' }) }
    if ($Remote) {
        foreach ($r in (& $refs 'refs/remotes/origin')) {
            if ($r.Name -in @('origin/HEAD', 'origin')) { continue }
            $branches.Add([pscustomobject]@{ Name = $r.Name.Substring('origin/'.Length); Sha = $r.Sha; Where = 'remote' })
        }
    }

    # Один запит на всі PR: стан і голова кожної гілки. Без gh squash-злиття не розпізнати — такі
    # гілки «не перевірено», а не «злиті».
    $prs = $null
    try {
        $prs = @(Invoke-KitGh -Arguments @('pr', 'list', '--state', 'all', '--limit', '500', '--json', 'number,state,headRefName,headRefOid') -Json)
    } catch [KitGhUnavailable], [KitGhError] {
        & $Say "gh недоступний ($(Get-PgGhWhy $_)): squash-злиті гілки не перевірено"
    }
    $prsOf = { param($b) @($prs | Where-Object { $_ -and $_.headRefName -ceq $b }) }
    # Віддалені гілки видаляємо лише з повним переліком PR: без нього (gh недоступний, pr list
    # впав) чи з обрізаним (--limit) відкритий PR міг лишитись невидимим.
    $prsComplete = ($null -ne $prs) -and $prs.Count -lt 500

    $deleted = 0; $skipped = 0; $notChecked = 0
    foreach ($br in $branches) {
        $label = "$($br.Where) $($br.Name)"
        if ($protected -ccontains $br.Name) { continue }
        if ($held.ContainsKey($br.Name)) { $skipped++; & $Say "пропущено ${label}: тримає worktree $($held[$br.Name])"; continue }
        if ($br.Where -eq 'remote' -and -not $prsComplete) { $notChecked++; continue }
        $open = (& $prsOf $br.Name) | Where-Object { $_.state -eq 'OPEN' } | Select-Object -First 1
        if ($br.Where -eq 'remote' -and $open) { $skipped++; & $Say "пропущено ${label}: відкритий PR #$($open.number)"; continue }
        $reason = $null
        if ((Invoke-PgGit -GitArgs @('merge-base', '--is-ancestor', $br.Sha, $baseRef) -Cwd $cwd).Ok) { $reason = "вміщена в $baseRef" }
        else {
            $m = (& $prsOf $br.Name) | Where-Object { $_.state -eq 'MERGED' } | Select-Object -First 1
            if ($m -and $m.headRefOid -eq $br.Sha) { $reason = "PR #$($m.number) злито на цій верхівці" }
            elseif ($m) { $skipped++; & $Say "пропущено ${label}: коміти після злиття PR #$($m.number)"; continue }
            elseif ($null -eq $prs) { $notChecked++; continue }
        }
        if (-not $reason) { continue }
        if ($DryRun) { & $Say "видалив би $label ($reason)" }
        else {
            if ($br.Where -eq 'local') { $null = Get-PgGit -GitArgs @('branch', '-D', $br.Name) -Cwd $cwd }
            elseif (-not (Remove-PgRemoteBranch -Ctx $Ctx -Name $br.Name -ExpectedOid $br.Sha -Protected $protected -Say $Say)) { $skipped++; continue }
            & $Say "видалено $label ($reason)"
        }
        $deleted++
    }
    & $Say "$(if ($DryRun) { 'видалив би' } else { 'видалено' }) $deleted, пропущено $skipped$(if ($notChecked) { ", не перевірено $notChecked" })"
    [pscustomobject]@{ Deleted = $deleted; Skipped = $skipped; NotChecked = $notChecked }
}

function Invoke-PrGatePrune {
    param($Ctx, [switch]$DryRun, [switch]$Remote, [scriptblock]$Say = $script:DefaultSay)
    $r = Invoke-PgPrune -Ctx $Ctx -DryRun:$DryRun -Remote:$Remote -Say $Say
    if ($r.NotChecked) {
        Write-KitNext 'gh auth status (squash-злиті гілки потребують gh), потім pr-gate prune'
        throw (New-KitNotChecked "prune: не перевірено $($r.NotChecked) гілок: без gh squash-злиття не розпізнати")
    }
    Write-KitNext $(if ($DryRun -and $r.Deleted) { "pr-gate prune$(if ($Remote) { ' -Remote' })" } else { 'none' })
    0
}

function Move-PgOutOf {
    <# Процес не може лишатись у теці, яку видаляємо: переходимо в головний checkout. Повертає $true, якщо були всередині. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$To)
    if (-not (Test-PgInsidePath -Path (Get-Location).Path -Dir $Path)) { return $false }
    Set-Location -LiteralPath $To
    [System.Environment]::CurrentDirectory = $To
    $true
}

function Remove-PgWorktree {
    <#
        `git worktree remove` (без --force). Журнали worktree — git-ignored теки; git видаляє їх разом
        з деревом, тож архіву немає: живий борг із журналу збирає close-block до видалення. Рядок
        «журнал» лише показує, що саме зникне. Повертає $true, якщо процес стояв усередині.
    #>
    param($Ctx, [Parameter(Mandatory)]$Wt, [Parameter(Mandatory)][scriptblock]$Say)
    $path = $Wt.Path
    $journals = @($script:JournalDirs | Where-Object { Test-Path -LiteralPath (Join-Path $path $_) } |
        ForEach-Object { "$_/ ($(@(Get-ChildItem -LiteralPath (Join-Path $path $_) -Recurse -Force).Count) записів)" })
    # Каталог процесу всередині дерева, що зникає: наступні кроки (гілка, prune) запускають git
    # звідси, тож переходимо в головний checkout заздалегідь.
    $cwd = (Get-Location).Path
    $inside = Move-PgOutOf -Path $path -To $Ctx.MainRoot
    # Без --force: брудне дерево git відмовиться видаляти, і це правильно.
    try { $null = Get-PgGit -GitArgs @('worktree', 'remove', $path) -Cwd $Ctx.MainRoot }
    catch {
        if ($inside) { Set-Location -LiteralPath $cwd; [System.Environment]::CurrentDirectory = $cwd }
        throw
    }
    & $Say $(if ($journals.Count) { "видалено журнал $($journals -join ', ')" } else { 'у worktree немає журналу' })
    & $Say "видалено worktree $path"
    $inside
}

function Remove-PgMergedBranch {
    <#
        Локальна гілка злитого PR більше не потрібна. Видаляємо лише коли її верхівка — у
        origin/<base> або це голова злитого PR; коміти після злиття — гілка лишається. -KnownHead —
        голова PR, якщо її вже знаємо (land), тоді без запиту до gh.
    #>
    param($Ctx, [Parameter(Mandatory)][string]$Branch, [Parameter(Mandatory)][scriptblock]$Say, [string]$KnownHead)
    $root = $Ctx.MainRoot
    if ((Get-PgProtectedBranches -Ctx $Ctx) -ccontains $Branch) { & $Say "гілку $Branch лишено: захищена (main, base чи ціль origin/HEAD)"; return }
    $tip = Invoke-PgGit -GitArgs @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch") -Cwd $root
    if (-not $tip.Ok) { & $Say "гілка ${Branch}: локальної немає"; return }
    $holder = @(Get-PgWorktrees -Cwd $root) | Where-Object { $_.Branch -ceq $Branch } | Select-Object -First 1
    if ($holder) { & $Say "гілку $Branch лишено: її тримає worktree $($holder.Path)"; return }
    $baseRef = "origin/$($Ctx.Base)"
    $null = Invoke-PgGit -GitArgs @('fetch', '-q', 'origin') -Cwd $root
    $reason = $null
    if ((Invoke-PgGit -GitArgs @('merge-base', '--is-ancestor', $tip.Out, $baseRef) -Cwd $root).Ok) { $reason = "вміщена в $baseRef" }
    elseif ($KnownHead) { if ($KnownHead -eq $tip.Out) { $reason = 'її PR злито на цій верхівці' } }
    else {
        try { $prs = @(Invoke-KitGh -Arguments @('pr', 'list', '--head', $Branch, '--state', 'merged', '--json', 'number,headRefOid') -Json) }
        catch [KitGhUnavailable], [KitGhError] {
            & $Say "гілку $Branch лишено: $(Get-PgGhWhy $_), тож стан її PR невідомий (її немає в $baseRef); видали після злиття: git branch -D $Branch"
            return
        }
        $m = $prs | Where-Object { $_ -and $_.headRefOid -eq $tip.Out } | Select-Object -First 1
        if ($m) { $reason = "PR #$($m.number) злито на цій верхівці" }
    }
    if (-not $reason) { & $Say "гілку $Branch лишено: на верхівці $($tip.Out.Substring(0, 7)) не злита"; return }
    $null = Get-PgGit -GitArgs @('branch', '-D', $Branch) -Cwd $root
    & $Say "видалено локальну гілку $Branch ($reason)"
}

function Invoke-PrGateCleanup {
    param($Ctx, [AllowEmptyString()][string]$Path, [scriptblock]$Say = $script:DefaultSay)
    if (-not $Path) { throw (New-KitUsageError 'cleanup: назви шлях worktree') }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = $Ctx.MainRoot
    if (Test-PgSamePath $full $root) { throw (New-KitUsageError "${full}: головний checkout не видаляється ніколи") }
    $wt = @(Get-PgWorktrees -Cwd $root) | Where-Object { Test-PgSamePath $_.Path $full } | Select-Object -First 1
    if (-not $wt) { throw (New-KitUsageError "${full}: це не worktree цього репозиторію") }
    $inside = Remove-PgWorktree -Ctx $Ctx -Wt $wt -Say $Say
    $lines = [System.Collections.Generic.List[string]]::new()
    $collect = { param($l) $lines.Add($l); & $Say $l }.GetNewClosure()
    if ($wt.Branch) { Remove-PgMergedBranch -Ctx $Ctx -Branch $wt.Branch -Say $collect }
    $kept = $lines | Where-Object { $_.Contains('лишено') -and $_.Contains('git branch -D') } | Select-Object -First 1
    $next = if ($kept) { $kept.Substring($kept.IndexOf('git branch -D')) + ' після злиття його PR' } else { 'none' }
    Write-KitNext "$next$(if ($inside) { "; cd $root (цього worktree вже немає)" })"
    0
}

# ---------------------------------------------------------------------------------------------
# scratch

function Get-PgScratchPlace {
    param($Ctx)
    $dir = Join-Path (Join-Path $Ctx.MainRoot $Ctx.WorktreesRoot) $script:ScratchDir
    $rel = "$($Ctx.WorktreesRoot)/$script:ScratchDir/${script:ScratchPrefix}x"
    [pscustomobject]@{ Dir = $dir; InRepo = (Test-PgIgnored -Root $Ctx.MainRoot -Rel $rel) }
}

function Invoke-PrGateScratchAdd {
    <# Тимчасове відокремлене worktree для перевірок мутацією. stdout — лише шлях; підказка — в stderr. #>
    param($Ctx, [string]$Ref = 'HEAD', [scriptblock]$Say = $script:DefaultSay)
    $sha = Invoke-PgGit -GitArgs @('rev-parse', '--verify', '--quiet', "$Ref^{commit}") -Cwd $Ctx.Root
    if (-not $sha.Ok) { throw (New-KitUsageError "scratch add: невідомий ref $Ref") }
    $place = Get-PgScratchPlace -Ctx $Ctx
    # Дерево — лише в git-ignored <worktrees.root>/.scratch: інакше scratch rm не мав би надійної ознаки,
    # що тека зроблена scratch add (запасного місця в тимчасовій теці немає: його прибирання
    # видаляло б батьківську теку з чужими файлами).
    if (-not $place.InRepo) {
        throw (New-KitRefusal "scratch add: $($Ctx.WorktreesRoot)/$script:ScratchDir не git-ignored у $($Ctx.MainRoot); додай рядок `"$($Ctx.WorktreesRoot)/`" у .gitignore, потім повтори")
    }
    $id = -join (1..6 | ForEach-Object { 'abcdefghijklmnopqrstuvwxyz0123456789'[(Get-Random -Maximum 36)] })
    $cleanupDir = Join-Path $place.Dir "$script:ScratchPrefix$id"
    $path = $cleanupDir
    # Порожня тека: git worktree add приймає порожню теку, а ім'я унікальне для паралельних агентів.
    New-Item -ItemType Directory -Path $cleanupDir -Force | Out-Null
    $r = Invoke-PgGit -GitArgs @('worktree', 'add', '-q', '--detach', $path, $sha.Out) -Cwd $Ctx.Root
    if (-not $r.Ok) {
        # Рекурсивне видалення — лише Remove-KitDirectory (#34, PathSafety): повтори й зняття ReadOnly
        # (об'єкти git на Windows — ReadOnly). Прибирання тут — найкраще можливе, провал не важливіший
        # за причину, яку повідомляємо далі.
        try {
            Assert-SafeWorkPath -Path $cleanupDir -MustBeUnder $place.Dir -RepoRoot $Ctx.MainRoot -OwnedRoot (Join-Path $Ctx.MainRoot $Ctx.WorktreesRoot) -Description 'тека scratch-дерева'
            Remove-KitDirectory -Path $cleanupDir
        } catch { }
        throw (New-KitRefusal "scratch add: git worktree add не вдався: $($r.Err); на спільне дерево не відкочуємось")
    }
    $copied = Format-KitCopiedLine (Copy-KitWorktreeInclude -Root $Ctx.MainRoot -Dest $path -Skip @($Ctx.WorktreesRoot))
    # stdout — лише шлях, щоб `t=$(pr-gate scratch add …)` працював; підказка — в stderr.
    & $Say $path
    [Console]::Error.Write("scratch-дерево на $($sha.Out.Substring(0, 7)) (відокремлене)`n$(if ($copied) { "$copied`n" })next: змінюй і ганяй там, потім pr-gate scratch rm $path`n")
    0
}

function Invoke-PrGateScratchRm {
    param($Ctx, [AllowEmptyString()][string]$Path, [scriptblock]$Say = $script:DefaultSay)
    if (-not $Path) { throw (New-KitUsageError 'scratch rm: назви шлях, який надрукував scratch add') }
    $expanded = if ($Path -eq '~' -or $Path.StartsWith('~/') -or $Path.StartsWith('~\')) { Join-Path ($env:USERPROFILE ?? $HOME) $Path.Substring(1).TrimStart('/', '\') } else { $Path }
    $full = [System.IO.Path]::GetFullPath($expanded)
    $parent = Split-Path -Parent $full
    $place = Get-PgScratchPlace -Ctx $Ctx
    $inRepo = (Test-PgSamePath $parent $place.Dir) -and (Split-Path -Leaf $full).StartsWith($script:ScratchPrefix, [System.StringComparison]::Ordinal)
    if (-not $inRepo) {
        throw (New-KitUsageError "scratch rm: $full зроблено не pr-gate scratch add (очікувалось $(Join-Path $place.Dir "$script:ScratchPrefix*")); worktree задачі прибирає pr-gate cleanup")
    }
    $wt = @(Get-PgWorktrees -Cwd $Ctx.MainRoot) | Where-Object { Test-PgSamePath $_.Path $full } | Select-Object -First 1
    if ($wt -and $wt.Branch) { throw (New-KitUsageError "scratch rm: $full на гілці $($wt.Branch), не відокремлене: відмова") }
    $null = Move-PgOutOf -Path $full -To $Ctx.MainRoot
    if ($wt) { $null = Get-PgGit -GitArgs @('worktree', 'remove', '--force', $full) -Cwd $Ctx.MainRoot }
    # Рекурсивне видалення — лише Remove-KitDirectory (#34): провал кидає виняток, а не мовчить —
    # інакше наступний рядок сказав би «видалено» про теку, що лишилась.
    # П25: не видаляти крізь посилання і лише власне під <worktrees.root>/.scratch.
    Assert-SafeWorkPath -Path $full -MustBeUnder $place.Dir -RepoRoot $Ctx.MainRoot -OwnedRoot (Join-Path $Ctx.MainRoot $Ctx.WorktreesRoot) -Description 'тека scratch-дерева'
    Remove-KitDirectory -Path $full
    if (-not $wt) { $null = Invoke-PgGit -GitArgs @('worktree', 'prune') -Cwd $Ctx.MainRoot }
    & $Say $(if ($wt) { "видалено scratch-дерево $full" } else { "${full}: це вже не worktree; теку видалено" })
    Write-KitNext 'none'
    0
}

# ---------------------------------------------------------------------------------------------
# land

function Invoke-PrGateLand {
    <#
        Уся посадка PR однією командою. Кожен крок перевіряє, чи він уже зроблений, тож повторний
        запуск після збою продовжує з місця збою. Збій: що зроблено, що ні, точна наступна команда.
    #>
    param($Ctx, [Parameter(Mandatory)][AllowEmptyString()][string]$Pr, [Parameter(Mandatory)][string]$Method, [double]$MergeableTimeout = 120, [scriptblock]$Say = $script:DefaultSay)
    if (-not $Pr) { throw (New-KitUsageError 'land: назви номер PR') }
    $root = $Ctx.MainRoot
    $base = $Ctx.Base
    $shared = ($Ctx.WorkspaceMode -ceq 'shared')
    $rerun = "pr-gate land $Pr"
    $done = [System.Collections.Generic.List[string]]::new()
    $left = [System.Collections.Generic.List[string]]::new()
    $steps = @('ready', 'merge', 'update', 'after-merge', 'cleanup', 'branch', 'prune')
    $step = 'merge'
    $stepSay = { param($line) & $Say "${step}: $line" }
    $stop = {
        param($why, $next, [int]$code = 1)
        & $stepSay "ЗБІЙ $why"
        $rest = @($steps[([array]::IndexOf($steps, $step))..($steps.Count - 1)])
        & $Say "зроблено: $(if ($done.Count) { $done -join ', ' } else { 'нічого' }); не зроблено: $($rest -join ', ')"
        Write-KitNext $next
        $e = New-KitCliError -Message "land: крок ${step}: $why" -ExitCode $code
        $e.Data['PgStopped'] = $true
        throw $e
    }
    $newCollector = {
        $lines = [System.Collections.Generic.List[string]]::new()
        [pscustomobject]@{ Lines = $lines; Add = { param($l) $lines.Add($l) }.GetNewClosure() }
    }

    $fields = $script:MergeFields + @('mergeCommit')
    $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields $fields
    try {
        # 1. Draft: land робить його ready і мерджить (CI немає, окремого очікування нема).
        if ($p.state -eq 'OPEN' -and $p.isDraft) {
            $step = 'ready'
            $null = Invoke-PgGh -Arguments @('pr', 'ready', [string]$p.number)
            & $stepSay 'позначено готовим до рев''ю'
            $done.Add($step)
        }

        # 2. Злиття: UNKNOWN — GitHub ще рахує, чекаємо; конфлікт — одразу стоп.
        $step = 'merge'
        if ($p.state -eq 'MERGED') {
            & $stepSay "уже злито як $(if ($p.mergeCommit -and $p.mergeCommit.oid) { ([string]$p.mergeCommit.oid).Substring(0, 7) } else { '?' })"
            # Збій міг статися між злиттям і видаленням гілки на origin.
            if (-not $p.isCrossRepository) {
                $c0 = & $newCollector
                if (Remove-PgRemoteBranch -Ctx $Ctx -Name $p.headRefName -ExpectedOid $p.headRefOid -Protected (Get-PgProtectedBranches -Ctx $Ctx -Extra @($p.baseRefName)) -Say $c0.Add) {
                    $c0.Add.Invoke("видалено віддалену гілку $($p.headRefName)")
                }
                foreach ($l in $c0.Lines) { & $stepSay $l }
            }
        } elseif ($p.state -ne 'OPEN') {
            & $stop "PR #$($p.number) має стан $($p.state)" "gh pr view $($p.number)"
        } else {
            $until = [DateTime]::UtcNow.AddSeconds($MergeableTimeout)
            $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields $fields
            while ($p.mergeable -eq 'UNKNOWN' -and -not $p.Conflict -and [DateTime]::UtcNow -lt $until) {
                Start-Sleep -Milliseconds ([int][Math]::Min(5000, [Math]::Max(($until - [DateTime]::UtcNow).TotalMilliseconds, 0)))
                $p = Get-PgPr -Ctx $Ctx -Pr $Pr -Fields $fields
            }
            if ($p.Conflict) { & $stop "PR #$($p.number) у конфлікті з $($p.baseRefName)" (Get-PgConflictNext -Ctx $Ctx -Branch $p.headRefName -Base $p.baseRefName -Then $rerun) }
            if ($p.mergeable -eq 'UNKNOWN') { & $stop "GitHub досі рахує mergeable після $MergeableTimeout с" $rerun 3 }
            $c = & $newCollector
            try { $null = Invoke-PgMergeChecked -Ctx $Ctx -State $p -Method $Method -Say $c.Add }
            catch {
                $code = if ($_.Exception.Data.Contains('KitExitCode')) { [int]$_.Exception.Data['KitExitCode'] } else { 1 }
                $why = (($_.Exception.Message -split "\r?\n")[0]) + $(if ($c.Lines.Count) { "; $($c.Lines -join '; ')" })
                & $stop $why $(if ($code -eq 3) { $rerun } else { "gh pr view $($p.number), виправ, потім $rerun" }) $code
            }
            & $stepSay ($c.Lines -join '; ')
        }
        $done.Add($step)

        # 3. Головний checkout: fetch + ff-only, лише чистий і на base. У shared HEAD спільного дерева
        # не зсуваємо: людина виконує команду з next: сама.
        $step = 'update'
        $ff = "git -C $root merge --ff-only origin/$base"
        $null = Get-PgGit -GitArgs @('fetch', '-q', 'origin') -Cwd $root
        if ($shared) {
            & $stepSay "пропущено: workspace.mode = shared, головне дерево $root спільне, HEAD не зсуваємо"
            $left.Add($ff)
        } else {
            $cur = Get-PgGit -GitArgs @('branch', '--show-current') -Cwd $root
            $dirty = Get-PgGit -GitArgs @('status', '--porcelain', '--untracked-files=no') -Cwd $root
            # Гілка PR могла лишитись у головному checkout (поза pr-gate start); після злиття — назад на base.
            if ($cur -ceq $p.headRefName -and -not $dirty) {
                $null = Get-PgGit -GitArgs @('switch', '-q', $base) -Cwd $root
                & $stepSay "головний checkout перемкнено з $cur на $base"
                $cur = $base
            }
            if ($cur -cne $base) {
                & $stepSay "пропущено: головний checkout $root на $(if ($cur) { $cur } else { 'відокремленому HEAD' }), не на $base"
                $left.Add("git -C $root switch $base && $ff")
            } elseif ($dirty) {
                & $stepSay "пропущено: у головному checkout $root є незакомічені зміни"
                $left.Add("закоміть або прибери їх, потім $ff")
            } elseif ((Invoke-PgGit -GitArgs @('merge-base', '--is-ancestor', "origin/$base", 'HEAD') -Cwd $root).Ok) {
                & $stepSay "головний checkout уже на origin/$base ($(Get-PgGit -GitArgs @('rev-parse', '--short', 'HEAD') -Cwd $root))"
                $done.Add($step)
            } else {
                $r = Invoke-PgGit -GitArgs @('merge', '-q', '--ff-only', "origin/$base") -Cwd $root
                if ($r.Ok) {
                    & $stepSay "головний checkout переведено на origin/$base ($(Get-PgGit -GitArgs @('rev-parse', '--short', 'HEAD') -Cwd $root))"
                    $done.Add($step)
                } else {
                    & $stepSay "пропущено: $($r.Err)"
                    $left.Add("$ff ($($r.Err))")
                }
            }
        }

        # 4. after-merge: виконується раз; позначка — у головному checkout.
        $step = 'after-merge'
        $mark = Join-Path (Join-Path $Ctx.OutDir 'pr-gate') "land-$($p.number).json"
        $marked = $false
        if (Test-Path -LiteralPath $mark) { try { $marked = ((Get-Content -LiteralPath $mark -Raw | ConvertFrom-Json).afterMerge -eq 'ok') } catch { $marked = $false } }
        if ($marked) { & $stepSay 'виконано раніше' }
        else {
            $full = Get-PgPr -Ctx $Ctx -Pr ([string]$p.number) -Fields @('number', 'state', 'baseRefName', 'headRefName', 'files')
            $c = & $newCollector
            $code = Invoke-PgAfterMergeReport -Ctx $Ctx -State $full -Say $c.Add -InLand
            if ($code -ne 0) {
                & $Say (($c.Lines | ForEach-Object { "  $_" }) -join "`n")
                & $stop 'команда pr.afterMerge впала (вище)' "виправ її, потім $rerun"
            }
            # Підсумок — рядком кроку; поради сусідам і команди профілю — під ним.
            $summary = $c.Lines | Where-Object { $_ -match 'мають злити|не торкається' } | Select-Object -First 1
            & $stepSay $summary
            foreach ($l in $c.Lines) { if ($l -ne $summary) { & $Say "  $l" } }
            New-Item -ItemType Directory -Path (Split-Path -Parent $mark) -Force | Out-Null
            [System.IO.File]::WriteAllText($mark, '{"afterMerge":"ok"}')
        }
        $done.Add($step)

        # 5. Worktree гілки PR: видалення разом із журналом.
        $step = 'cleanup'
        $cdHint = $null
        $wt = @(Get-PgWorktrees -Cwd $root) | Where-Object { $_.Branch -ceq $p.headRefName -and -not (Test-PgSamePath $_.Path $root) } | Select-Object -First 1
        if (-not $wt) { & $stepSay "worktree гілки $($p.headRefName) немає" }
        else {
            $c = & $newCollector
            try { $inside = Remove-PgWorktree -Ctx $Ctx -Wt $wt -Say $c.Add }
            catch {
                if ($_.Exception.Data.Contains('PgStopped')) { throw }
                & $stop "$($wt.Path): $(($_.Exception.Message -split "\r?\n")[0])" "закоміть або прибери зміни в $($wt.Path) (git -C $($wt.Path) status), потім $rerun"
            }
            & $stepSay ($c.Lines -join '; ')
            if ($inside) { $cdHint = "cd $root" }
        }
        $done.Add($step)

        # 6. Локальна гілка.
        $step = 'branch'
        $c = & $newCollector
        Remove-PgMergedBranch -Ctx $Ctx -Branch $p.headRefName -Say $c.Add -KnownHead $p.headRefOid
        & $stepSay ($c.Lines -join '; ')
        $done.Add($step)

        # 7. Інші вже злиті локальні гілки.
        $step = 'prune'
        $c = & $newCollector
        $pruneOk = (Invoke-PgPrune -Ctx $Ctx -Say $c.Add).NotChecked -eq 0
        $deleted = @($c.Lines | Where-Object { $_.StartsWith('видалено local ') } | ForEach-Object { ($_ -split ' ')[2] })
        & $stepSay "$(if ($deleted.Count) { "видалено $($deleted -join ', ')" } else { 'видаляти нічого' })$(if (-not $pruneOk) { ' (частину гілок не перевірено)' })"
        $done.Add($step)

        if ($left.Count) {
            & $Say "посаджено #$($p.number); лишилось: $($left.Count) крок(ів)"
            Write-KitNext "$($left -join '; ')$(if ($cdHint) { "; $cdHint" })"
            if ($shared) { return 0 }
            $e = New-KitRefusal "land: PR #$($p.number) злито, але лишилось $($left.Count) крок(ів) (вище)"
            $e.Data['PgStopped'] = $true
            throw $e
        }
        & $Say "посаджено #$($p.number)"
        Write-KitNext $(if ($cdHint) { "$cdHint (цього worktree вже немає)" } else { 'none' })
        return 0
    } catch {
        if ($_.Exception.Data.Contains('PgStopped') -or -not $_.Exception.Data.Contains('KitExitCode')) { throw }
        # Звичайна відмова кроку (git, gh): той самий формат збою з точною наступною командою.
        & $stop (($_.Exception.Message -split "\r?\n")[0]) $rerun ([int]$_.Exception.Data['KitExitCode'])
    }
}

Export-ModuleMember -Function Get-PrGateUsage, Get-PrGateDetailUsage, Get-PrGateProfileUsage, New-PrGateContext,
    Assert-PrGateWorkspaceMode, Get-PrGateSlug, Invoke-PrGateOpen, Invoke-PrGateReady, Invoke-PrGateMerge,
    Invoke-PrGateStart, Invoke-PrGateAfterMerge, Invoke-PrGatePrune, Invoke-PrGateCleanup,
    Invoke-PrGateScratchAdd, Invoke-PrGateScratchRm, Invoke-PrGateLand
