# Ported from agent-kit 0.9.1 bin/doc, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Читання великих спек і планів за розділами та перевірка якорів документації. Спеки бувають
# 68–466 КБ; агент, що читає файл цілком або `sed -n` навмання, витрачає контекст і пропускає
# потрібне. `doc` дає зміст із розмірами, один розділ, пошук із шляхом заголовків і гард мертвих
# посилань.
#
# Уся логіка підкоманд — тут, без `exit` і без читання профілю: функції отримують корінь репо та
# значення профілю (хеш-таблицю) і повертають результат @{ Lines; ErrLines; Code }. Друкує,
# читає профіль і розбирає аргументи тонка обгортка tools/commands/doc.psm1; так логіку можна
# тестувати прямим Import-Module без kit.ps1.
#
# Ключі хеш-таблиці профілю (значення $null — поле відсутнє в профілі):
#   Specs Plans Docs Skills                 — docs.specs, docs.plans, docs.docs, docs.skills
#   AnchorsInclude AnchorsExclude AnchorsRoots AnchorsExternal   — docs.anchors.*
#   HistoryIgnore                           — docs.history.ignore
#   LintInclude LintExclude LintDuplicateBlock LintSkillMaxLines
#   LintReferenceMaxLines LintContentsHeadLines                  — docs.lint.*

Import-Module "$PSScriptRoot/Markdown.psm1"
Import-Module "$PSScriptRoot/PathRefs.psm1"

$script:DocExit = @{ Ok = 0; Failed = 1; Usage = 2; NotChecked = 3 }

$script:ProfilePaths = @{
    Specs = 'docs.specs'; Plans = 'docs.plans'; Docs = 'docs.docs'; Skills = 'docs.skills'
    AnchorsInclude = 'docs.anchors.include'; AnchorsExclude = 'docs.anchors.exclude'
    AnchorsRoots = 'docs.anchors.roots'; AnchorsExternal = 'docs.anchors.external'
    HistoryIgnore = 'docs.history.ignore'
    LintInclude = 'docs.lint.include'; LintExclude = 'docs.lint.exclude'
    LintDuplicateBlock = 'docs.lint.duplicateBlock'; LintSkillMaxLines = 'docs.lint.skillMaxLines'
    LintReferenceMaxLines = 'docs.lint.referenceMaxLines'; LintContentsHeadLines = 'docs.lint.contentsHeadLines'
}

$script:Ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:Ci = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:Sl = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

# --- довідка ----------------------------------------------------------------------------------

$script:Usage = @'
doc <файл>                       зміст: заголовки, діапазони рядків, КБ (великий файл: 2 рівні)
doc <файл> <§N | слова заголовка>  один розділ разом з підрозділами
doc <файл> <A-B>                 рядки A..B (замість sed -n)
doc find <regex> [-In specs|plans|docs] [-CaseSensitive] [-Max <n>=20]
doc anchors [<файли...>]         посилання, шляхи репо, file:N, вказівники §, #якорі
doc lint [<файли...>] [-List]    форма корпусу: дублі, ліміт SKILL.md, «Зміст»
doc refs <шлях...> [-Max <n>] | doc refs -Dead
doc debt <файл...>
doc history [-Code | -Docs] [-Only <regex>] [-Ignore <regex>] [-Path <тека>...] [-Max <n>]

Кожне читання завершується рядком "next:". Деталі: doc -Help <команда>; поля профілю: doc -Help profile.
Коди виходу: 0 ок, 1 збій/биті посилання/немає збігів, 2 помилка виклику, 3 не перевірено (немає поля профілю, порожній корпус).
'@

# Подробиці — за підкомандою: повний usage був 3.6 КБ, і агент читав його цілком.
$script:HelpTopics = @{
    read    = @'
doc <файл>                       зміст: заголовки з діапазонами рядків і КБ на розділ.
                                 До 3 рівнів заголовків; якщо виходить довше за ~1.5 КБ — 2 рівні
                                 і підказка "-Level 3" (doc <файл> -Level <n> — обрати рівень).
doc <файл> <§N | слова заголовка>  один розділ разом з підрозділами. Запит збігається із заголовком
                                 точно, потім як унікальна підстрока, потім за всіма його словами
                                 (будь-який порядок, без регістру); §6.4 або 6.4 збігається із
                                 заголовком з номером 6.4; кілька збігів — список точних команд.
doc <файл> <A-B>                 рядки A..B.
Кожне читання завершується "next:" — сусідні розділи як готові команди.
'@
    find    = @'
doc find <regex> [-In specs|plans|docs] [-CaseSensitive] [-Max <n>=20]
  Пошук у теках документації профілю (docs.specs, docs.plans, docs.docs). Без регістру, якщо немає
  -CaseSensitive. Вивід: групи за файлом, потім за найближчим заголовком; кожен збіг — "рядок: текст"
  із вікном навколо збігу. next: перший збіг як діапазон рядків.
'@
    anchors = @'
doc anchors [<файли...>]
  Перевіряє посилання, шляхи репо (у зворотних лапках, у посиланнях і голим текстом), file:N за
  кінцем файла, вказівники § ("doc.md §6.4", скіл `x` § "Розділ") і #якорі (slug GitHub). Корпус за
  замовчуванням: docs.anchors.include. Код 1 зі списком.
'@
    refs    = @'
doc refs <шлях...> [-Max <n>]    кожне посилання на ці файли/теки в усьому репо (документи, код,
                                 конфіги): повний шлях, відносне markdown-посилання, довге голе ім'я
doc refs -Dead                   посилання будь-де в репо на неіснуючі файли в теках документації; код 1
'@
    debt    = @'
doc debt <файл...>
  Кандидати в живий борг перед видаленням: невідмічені пункти [ ] і розділи про борг, відкладене,
  пастки, відкриті питання.
'@
    history = @'
doc history [-Code | -Docs] [-Only <regex>] [-Ignore <regex>] [-Path <тека>...] [-Max <n>]
  Мітки етапів у коді (§N, Phase/Фаза N, Task N, PR #N) і фазова нарація в документах (корпус +
  AGENTS/CLAUDE/README); код 1 зі списком. -Only лишає рядки з мітками самого блоку (назва, код,
  PR #); -Ignore відкидає збіги; -Path обмежує сканування коду.
'@
    lint    = @'
doc lint [<файли...>] [-List]
  Форма корпусу: дубльовані блоки тверджень, ліміт SKILL.md, «Зміст» у довгих reference,
  вказівники reference -> reference. -List друкує корпус.
'@
    profile = @'
Профіль (.agents/kit.profile.json), розділ "docs":
  specs, plans, docs        тека або список тек (find -In, пошук документа за ім'ям)
  skills                    теки скілів (дозволено glob) для вказівників скіл `x` § "Розділ"
  anchors.include/exclude   glob-и корпусу anchors (за замовчуванням: <docs>/**/*.md)
  anchors.roots             перші сегменти шляхів, що вважаються шляхами репо (за замовчуванням:
                            каталоги верхнього рівня відстежуваних файлів)
  anchors.external          голі імена файлів, які не резолвляться (за замовчуванням: MEMORY.md
                            SKILL.md CLAUDE.local.md)
  history.ignore            слова предметної області, що не є фазовою нарацією (напр. ["phase"])
  lint.include/exclude      glob-и корпусу lint (за замовчуванням: корпус anchors)
  lint.duplicateBlock       скільки рядків тверджень дають дубль (за замовчуванням 3)
  lint.skillMaxLines        ліміт рядків SKILL.md (за замовчуванням 500)
  lint.referenceMaxLines    довжина reference, якій потрібен розділ «Зміст» (за замовчуванням 100)
  lint.contentsHeadLines    де шукати "Contents"/"Зміст" (за замовчуванням: перші 20 рядків)
'@
}

function Get-DocUsage {
    [CmdletBinding()]
    param()
    $script:Usage.TrimEnd()
}

function Get-DocHelp {
    # Довідка за підкомандою або $null, якщо такої теми немає.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Topic)
    if ($script:HelpTopics.ContainsKey($Topic)) { return $script:HelpTopics[$Topic].TrimEnd() }
    return $null
}

# --- спільні дрібниці -------------------------------------------------------------------------

function New-DocException {
    # Kind: usage (код 2) | profile (код 3). Тип виняткового об'єкта в PowerShell не розрізняє
    # причин, тож причина — у Data: так диспетчер відрізняє «помилка виклику» від «не перевірено».
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Message)
    $e = [System.InvalidOperationException]::new($Message)
    $e.Data['DocKind'] = $Kind
    $e
}

function New-DocResult {
    param([string[]]$Lines = @(), [string[]]$ErrLines = @(), [int]$Code = 0)
    [pscustomobject]@{ Lines = @($Lines); ErrLines = @($ErrLines); Code = $Code }
}

function Format-DocError {
    param([Parameter(Mandatory)][string]$Message)
    "doc: ERROR $Message"
}

function ConvertTo-DocList {
    # Поле профілю — скаляр, список або нічого. Елементи йдуть у конвеєр; викликач завжди обгортає в @().
    param($Value)
    if ($null -eq $Value) { return }
    $Value
}

function New-DocContext {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [hashtable]$Profile = @{},
        [string]$WorkDir
    )
    if (-not $WorkDir) { $WorkDir = (Get-Location).ProviderPath }
    @{
        Root     = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
        Profile  = $Profile
        WorkDir  = $WorkDir
        GitFiles = $null
    }
}

function Get-DocField {
    # Значення поля профілю; з -Required відсутнє поле — «не перевірено» (код 3) з назвою поля.
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Key, [switch]$Required)
    $v = $null
    if ($Ctx.Profile.ContainsKey($Key)) { $v = $Ctx.Profile[$Key] }
    if ($null -eq $v -and $Required) {
        throw (New-DocException 'profile' ('поле профілю "{0}" відсутнє (додайте його в .agents/kit.profile.json у {1})' -f $script:ProfilePaths[$Key], $Ctx.Root))
    }
    return $v
}

function Get-DocFieldList {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Key)
    $v = Get-DocField -Ctx $Ctx -Key $Key
    ConvertTo-DocList -Value $v
}

function Format-DocKb {
    param([Parameter(Mandatory)][double]$Bytes)
    ($Bytes / 1024).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + ' КБ'
}

function ConvertTo-DocNumber {
    # Як JS Number(): нечисло -> NaN, а `-not (NaN -gt 0)` — істина.
    param($Value)
    [double]$r = 0
    if ([double]::TryParse(([string]$Value).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$r)) { return $r }
    return [double]::NaN
}

function Read-DocText {
    # UTF-8, CRLF нормалізується в LF (CRLF у файлах 1С — норма).
    param([Parameter(Mandatory)][string]$Path)
    try {
        $t = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    } catch {
        throw (New-DocException 'usage' ("не вдалося прочитати ${Path}: " + $_.Exception.Message))
    }
    $t.Replace("`r`n", "`n")
}

function Resolve-DocPath {
    # Відносні шляхи розв'язуються від робочої теки викликача, а не від кореня репо.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$WorkDir)
    [System.IO.Path]::GetFullPath($Path, $WorkDir)
}

function Get-DocRel {
    # Шлях відносно кореня репо, завжди з прямими `/`.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Join-DocPath {
    # Корінь + відносний шлях. Не Path.Combine: той, побачивши «/x», відкидає корінь.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    $Root.TrimEnd('\', '/') + '/' + $Rel.TrimStart('/', '\')
}

$script:RxSafeArg = [regex]::new('^[\p{L}\p{N}_.§/+-]+$')
function Format-DocQuote {
    # Аргумент для shell: одинарні лапки, якщо є щось крім безпечних символів.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($script:RxSafeArg.IsMatch($Text)) { return $Text }
    # Апостроф усередині: одинарні лапки з `'\''` розбирає лише bash, тож за відсутності `"`, `$` і
    # зворотної лапки беремо подвійні — вони однаково діють у bash і PowerShell.
    if ($Text.Contains("'") -and $Text -notmatch '["$`]') { return '"' + $Text + '"' }
    "'" + $Text.Replace("'", "'\''") + "'"
}

function Format-DocFiles {
    param([string[]]$Files)
    if (-not $Files -or $Files.Count -eq 0) { return '' }
    ' ' + (($Files | ForEach-Object { Format-DocQuote -Text $_ }) -join ' ')
}

$script:Sep = '   ·   '

function Sort-DocOrdinal {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items)
    $arr = [string[]]@($Items)
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return , $arr
}

function Get-DocGitFiles {
    # Відстежувані й не ігноровані нові файли репо: відсортовано ординально, без дублів. Кеш — у
    # контексті одного виклику, а не в модулі: між викликами файли з'являються й зникають.
    param([Parameter(Mandatory)]$Ctx)
    if ($null -eq $Ctx.GitFiles) {
        $r = Invoke-DocGit -RepoRoot $Ctx.Root -Arguments @('ls-files', '-z', '--cached', '--others', '--exclude-standard')
        if ($r.ExitCode -ne 0) {
            throw (New-DocException 'profile' ("не вдалося перелічити файли репозиторію через git у $($Ctx.Root): " + $r.Stderr.Trim()))
        }
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($f in $r.Stdout.Split([char]0)) { if ($f) { [void]$set.Add($f) } }
        $Ctx.GitFiles = Sort-DocOrdinal -Items @($set)
    }
    return , $Ctx.GitFiles
}

# --- toc / section ----------------------------------------------------------------------------

# Великий документ (спека на 100+ заголовків) давав 2 КБ змісту: за замовчуванням показуємо 3
# рівні, а коли це довше за ~1.5 КБ — 2 рівні й підказку.
$script:TocBudget = 1500

$script:RxRefNum = [regex]::new('^§?\s*([0-9]+[a-z]?(?:\.[0-9]+[a-z]?)*)(?:[.)]|\s|$)', $script:Ic)
$script:RxSecNum = [regex]::new('^§?\s*([0-9]+[a-z]?(?:\.[0-9]+[a-z]?)*)\.?$', $script:Ic)
$script:RxRange = [regex]::new('^L?([0-9]+)\s*-\s*L?([0-9]+)$', $script:Ic)
$script:RxNotWord = [regex]::new('[^\p{L}\p{N}.]+')

function ConvertTo-DocWords {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $script:RxNotWord.Replace($Text.ToLowerInvariant(), ' ').Trim()
}

function Find-DocSection {
    <#
    .SYNOPSIS
        Знаходить заголовок за `§N`/`N` або текстом. Результат: { Head; Message; Hits }; Head = $null,
        якщо збіг не єдиний (Message каже чому, Hits — кандидати).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Heads, [Parameter(Mandatory)][string]$Query)
    $q = $Query.Trim()
    $hits = [System.Collections.Generic.List[object]]::new()
    # Номер може мати літеру в сегменті: `§10a`, `§3.2b` (розділ, вставлений між сусідами).
    $num = $script:RxSecNum.Match($q)
    if ($num.Success) {
        foreach ($h in $Heads) { if (Test-MdNumberMatch -Text $h.Text -Number $num.Groups[1].Value) { $hits.Add($h) } }
    } else {
        $needle = $q.ToLowerInvariant()
        foreach ($h in $Heads) { if ($h.Text.ToLowerInvariant() -ceq $needle) { $hits.Add($h) } }
        if ($hits.Count -eq 0) {
            foreach ($h in $Heads) { if ($h.Text.ToLowerInvariant().Contains($needle)) { $hits.Add($h) } }
        }
        # Нечіткий збіг: усі слова запиту є в заголовку, у будь-якому порядку, без розмітки й
        # розділових знаків («приймання 6.4» -> «6.4. Приймання блоку»).
        if ($hits.Count -eq 0) {
            $qw = @((ConvertTo-DocWords -Text $q).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
            if ($qw.Count -gt 0) {
                foreach ($h in $Heads) {
                    $hw = ConvertTo-DocWords -Text $h.Text
                    $all = $true
                    foreach ($w in $qw) { if (-not $hw.Contains($w)) { $all = $false; break } }
                    if ($all) { $hits.Add($h) }
                }
            }
        }
    }
    if ($hits.Count -eq 1) { return [pscustomobject]@{ Head = $hits[0]; Message = ''; Hits = @() } }
    if ($hits.Count -eq 0) { return [pscustomobject]@{ Head = $null; Message = "немає розділу, що збігається з ""$q"""; Hits = @() } }
    [pscustomobject]@{ Head = $null; Message = """$q"" збігається з $($hits.Count) розділами; уточніть запит"; Hits = $hits.ToArray() }
}

function Get-DocRef {
    # Найкоротший аргумент, що однозначно веде до розділу: §N, текст, або рядки.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Heads, [Parameter(Mandatory)]$Head)
    $num = $script:RxRefNum.Match($Head.Text)
    if ($num.Success) {
        $r = Find-DocSection -Heads $Heads -Query ('§' + $num.Groups[1].Value)
        if ($null -ne $r.Head -and $r.Head.Line -eq $Head.Line) { return '§' + $num.Groups[1].Value }
    }
    $r = Find-DocSection -Heads $Heads -Query $Head.Text
    if ($null -ne $r.Head -and $r.Head.Line -eq $Head.Line) { return Format-DocQuote -Text $Head.Text }
    "$($Head.Start)-$($Head.End)"
}

function Get-DocNextAfterSection {
    # Сусіди розділу: попередній (брат або батько) і наступний після його кінця. Агент, що прочитав
    # розділ, найчастіше йде саме туди — без toc і sed.
    param([string]$File, [object[]]$Heads, $Head)
    $prev = $null
    foreach ($x in $Heads) { if ($x.Line -lt $Head.Line -and $x.Level -le $Head.Level) { $prev = $x } }
    $after = $null
    foreach ($x in $Heads) { if ($x.Line -gt $Head.End) { $after = $x; break } }
    # Кожна частина — готова команда; що це за сусід — у дужках після неї.
    $parts = [System.Collections.Generic.List[string]]::new()
    $f = Format-DocQuote -Text $File
    if ($after) { $parts.Add("doc $f $(Get-DocRef -Heads $Heads -Head $after)  (наступний розділ)") }
    if ($prev) { $parts.Add("doc $f $(Get-DocRef -Heads $Heads -Head $prev)  (попередній)") }
    if ($parts.Count -eq 0) { $parts.Add("doc $f  (зміст)") }
    'next: ' + ($parts -join $script:Sep)
}

function Format-DocTocLines {
    param([string]$Display, [string]$Text, [object[]]$Heads, [int]$Lv, [int]$Width, [int]$Lines)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add(('{0}  {1}, рядків: {2}, заголовків: {3}' -f $Display, (Format-DocKb -Bytes ([System.Text.Encoding]::UTF8.GetByteCount($Text))), $Lines, $Heads.Count))
    $hidden = 0
    foreach ($h in $Heads) {
        if ($h.Level -gt $Lv) { $hidden++; continue }
        $range = 'L' + "$($h.Start)".PadLeft($Width) + '-' + "$($h.End)".PadRight($Width)
        $out.Add("$range $((Format-DocKb -Bytes $h.Bytes).PadLeft(9))  $('  ' * ($h.Level - 1))$('#' * $h.Level) $($h.Text)")
    }
    if ($hidden -gt 0) { $out.Add("(глибших заголовків приховано: $hidden; -Level $($Lv + 1), щоб показати)") }
    return , $out.ToArray()
}

function Get-DocToc {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$File, $Level)
    $display = $File.Replace('\', '/')
    $text = Read-DocText -Path (Resolve-DocPath -Path $File -WorkDir $Ctx.WorkDir)
    $heads = Get-MdHeadings -Text $text
    $lines = $text.Split([char]10).Length
    if ($text.EndsWith("`n", [System.StringComparison]::Ordinal)) { $lines-- }
    $width = "$lines".Length
    $lv = if ($null -eq $Level) { 3 } else { [int]$Level }
    $out = Format-DocTocLines -Display $display -Text $text -Heads $heads -Lv $lv -Width $width -Lines $lines
    if ($null -eq $Level -and ([string]::Join("`n", $out)).Length -gt $script:TocBudget) {
        $out = Format-DocTocLines -Display $display -Text $text -Heads $heads -Lv 2 -Width $width -Lines $lines
    }
    $first = $null
    foreach ($h in $heads) { if ($h.Level -gt 1) { $first = $h; break } }
    if ($null -eq $first -and $heads.Count -gt 0) { $first = $heads[0] }
    $arg = if ($first) { Get-DocRef -Heads $heads -Head $first } else { '1-40' }
    $all = [System.Collections.Generic.List[string]]::new($out)
    $all.Add("next: doc $(Format-DocQuote -Text $display) $arg  (розділ: §N, слова заголовка або діапазон рядків A-B)")
    New-DocResult -Lines $all.ToArray() -Code $script:DocExit.Ok
}

function Get-DocLinesRange {
    # Рядки A..B — щоб агент, який уже знає рядки, не йшов у `sed -n`.
    param([string]$Display, [string]$Text, [object[]]$Heads, [long]$A, [long]$B)
    $all = $Text.Split([char]10)
    $total = $all.Length
    if ($Text.EndsWith("`n", [System.StringComparison]::Ordinal)) { $total-- }
    if ($A -lt 1 -or $B -lt $A) { throw (New-DocException 'usage' "некоректний діапазон рядків $A-$B") }
    if ($A -gt $total) { throw (New-DocException 'usage' "у $Display рядків: $total") }
    $end = [Math]::Min($B, $total)
    $body = $all[($A - 1)..($end - 1)]
    $inside = $null
    foreach ($h in $Heads) { if ($h.Start -le $A -and $A -le $h.End) { $inside = $h } }
    $f = Format-DocQuote -Text $Display
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($end -lt $total) { $parts.Add("doc $f $($end + 1)-$([Math]::Min($total, $end + 1 + ($end - $A)))  (ще рядки)") }
    if ($inside) { $parts.Add("doc $f $(Get-DocRef -Heads $Heads -Head $inside)  (розділ повністю)") }
    else { $parts.Add("doc $f  (зміст)") }
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount([string]::Join("`n", $body)) + 1
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("${Display}:${A}-${end} ($(Format-DocKb -Bytes $bytes))")
    $out.AddRange([string[]]$body)
    $out.Add('next: ' + ($parts -join $script:Sep))
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

function Get-DocSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Query)
    $display = $File.Replace('\', '/')
    $text = Read-DocText -Path (Resolve-DocPath -Path $File -WorkDir $Ctx.WorkDir)
    $heads = Get-MdHeadings -Text $text
    $range = $script:RxRange.Match($Query.Trim())
    if ($range.Success) {
        $a = 0L; $b = 0L
        if (-not ([long]::TryParse($range.Groups[1].Value, [ref]$a) -and [long]::TryParse($range.Groups[2].Value, [ref]$b))) {
            throw (New-DocException 'usage' "некоректний діапазон рядків $($Query.Trim())")
        }
        return Get-DocLinesRange -Display $display -Text $text -Heads $heads -A $a -B $b
    }
    $r = Find-DocSection -Heads $heads -Query $Query
    if ($null -eq $r.Head) {
        $err = [System.Collections.Generic.List[string]]::new()
        $err.Add((Format-DocError -Message $r.Message))
        if (@($r.Hits).Count -gt 0) {
            foreach ($x in $r.Hits) {
                $err.Add("  L$($x.Line) $('#' * $x.Level) $($x.Text) -> doc $(Format-DocQuote -Text $display) $(Get-DocRef -Heads $heads -Head $x)")
            }
        } else {
            $err.Add("next: doc $(Format-DocQuote -Text $display)")
        }
        return New-DocResult -ErrLines $err.ToArray() -Code $script:DocExit.Failed
    }
    $h = $r.Head
    $all = $text.Split([char]10)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("${display}:$($h.Start)-$($h.End) ($(Format-DocKb -Bytes $h.Bytes))")
    $out.AddRange([string[]]$all[($h.Start - 1)..($h.End - 1)])
    $out.Add((Get-DocNextAfterSection -File $display -Heads $heads -Head $h))
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

# --- допоміжне для профілю: glob-и, теки, файли -----------------------------------------------

function ConvertTo-DocGlobRegex {
    # `*` — у межах сегмента, `**` — будь-яка глибина (зокрема нульова).
    param([Parameter(Mandatory)][string]$Pattern)
    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $Pattern.Length) {
        if ($Pattern.Substring($i).StartsWith('**/', [System.StringComparison]::Ordinal)) { [void]$sb.Append('(?:.*/)?'); $i += 3 }
        elseif ($Pattern.Substring($i).StartsWith('**', [System.StringComparison]::Ordinal)) { [void]$sb.Append('.*'); $i += 2 }
        elseif ($Pattern[$i] -eq '*') { [void]$sb.Append('[^/]*'); $i++ }
        else { [void]$sb.Append([regex]::Escape([string]$Pattern[$i])); $i++ }
    }
    [regex]::new('^' + $sb.ToString() + '$', $script:Ci)
}

function Expand-DocDirs {
    # Теки профілю з розкриттям `*` у сегментах (`packages/*/skills`).
    param([Parameter(Mandatory)][string]$Root, [AllowEmptyCollection()][string[]]$Patterns = @())
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Patterns) {
        $cur = [System.Collections.Generic.List[string]]::new()
        $cur.Add($Root)
        foreach ($seg in @($p.Split('/') | Where-Object { $_ })) {
            $next = [System.Collections.Generic.List[string]]::new()
            if (-not $seg.Contains('*')) {
                foreach ($c in $cur) { $next.Add((Join-DocPath -Root $c -Rel $seg)) }
            } else {
                $re = ConvertTo-DocGlobRegex -Pattern $seg
                foreach ($c in $cur) {
                    try {
                        $names = [System.Collections.Generic.List[string]]::new()
                        foreach ($d in [System.IO.Directory]::GetDirectories($c)) {
                            $n = [System.IO.Path]::GetFileName($d)
                            if ($re.IsMatch($n)) { $names.Add($n) }
                        }
                        foreach ($n in (Sort-DocOrdinal -Items $names.ToArray())) { $next.Add((Join-DocPath -Root $c -Rel $n)) }
                    } catch { }
                }
            }
            $cur = $next
        }
        foreach ($c in $cur) { if ([System.IO.Directory]::Exists($c)) { $out.Add($c) } }
    }
    return , $out.ToArray()
}

function Test-DocSymlink {
    param([Parameter(Mandatory)][string]$Path)
    try { return (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { return $false }
}

function Get-DocFilesByGlobs {
    # Відстежувані файли репо за include/exclude-glob-ами: лише наявні звичайні файли, не симлінки.
    param([Parameter(Mandatory)]$Ctx, [string[]]$Include, [string[]]$Exclude)
    $inc = @($Include | ForEach-Object { ConvertTo-DocGlobRegex -Pattern $_ })
    $exc = @($Exclude | ForEach-Object { ConvertTo-DocGlobRegex -Pattern $_ })
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-DocGitFiles -Ctx $Ctx)) {
        $take = $false
        foreach ($r in $inc) { if ($r.IsMatch($f)) { $take = $true; break } }
        if (-not $take) { continue }
        $skip = $false
        foreach ($r in $exc) { if ($r.IsMatch($f)) { $skip = $true; break } }
        if ($skip) { continue }
        $p = Join-DocPath -Root $Ctx.Root -Rel $f
        # Симлінк або видалений, але ще відстежуваний файл — не джерело.
        if ([System.IO.File]::Exists($p) -and -not (Test-DocSymlink -Path $p)) { $out.Add($p) }
    }
    return , $out.ToArray()
}

function Get-DocCorpus {
    # Корпус anchors: docs.anchors.include, а без нього — усі .md першої теки docs.docs.
    param([Parameter(Mandatory)]$Ctx)
    $include = @(Get-DocFieldList -Ctx $Ctx -Key 'AnchorsInclude')
    if ($include.Count -eq 0) {
        $docs = @(Get-DocFieldList -Ctx $Ctx -Key 'Docs')
        if ($null -eq (Get-DocField -Ctx $Ctx -Key 'Docs') -or $docs.Count -eq 0) {
            throw (New-DocException 'profile' ('поле профілю "docs.docs" відсутнє (додайте його в .agents/kit.profile.json у {0})' -f $Ctx.Root))
        }
        $include = @("$(([string]$docs[0]).TrimEnd('/'))/**/*.md")
    }
    $exclude = @(Get-DocFieldList -Ctx $Ctx -Key 'AnchorsExclude')
    return , (Get-DocFilesByGlobs -Ctx $Ctx -Include $include -Exclude $exclude)
}

# --- find -------------------------------------------------------------------------------------

$script:RxFindHead = [regex]::new('^ {0,3}(#{1,6})[ \t]+(.*?)[ \t#]*$')
$script:SnippetWidth = 56

function Get-DocSnippet {
    # Вікно рядка навколо першого збігу: довгі рядки таблиць інакше займали по 160 символів.
    param([string]$Text, [regex]$Re, [int]$Width)
    if ($Text.Length -le $Width) { return $Text }
    $m = $Re.Match($Text)
    $at = if ($m.Success) { $m.Index } else { 0 }
    $start = [Math]::Max(0, [Math]::Min($at - [Math]::Floor($Width / 3), $Text.Length - $Width))
    $lead = if ($start -gt 0) { '…' } else { '' }
    $tail = if ($start + $Width -lt $Text.Length) { '…' } else { '' }
    $lead + $Text.Substring($start, [Math]::Min($Width, $Text.Length - $start)).Trim() + $tail
}

function Find-DocText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Pattern,
        [string]$In,
        [bool]$CaseSensitive = $false,
        $Max
    )
    $kinds = if ($In) { @($In) } else { @('specs', 'plans', 'docs') }
    foreach ($k in $kinds) {
        if ($k -notin @('specs', 'plans', 'docs')) { throw (New-DocException 'usage' "-In має бути specs, plans або docs, отримано ""$k""") }
    }
    $keyOf = @{ specs = 'Specs'; plans = 'Plans'; docs = 'Docs' }
    $dirs = [System.Collections.Generic.List[string]]::new()
    if ($In) {
        # `-In X` без поля X — «не перевірено»; без `-In` достатньо будь-якого поля.
        $null = Get-DocField -Ctx $Ctx -Key $keyOf[$In] -Required
        foreach ($d in (Get-DocFieldList -Ctx $Ctx -Key $keyOf[$In])) { $dirs.Add([string]$d) }
    } else {
        foreach ($k in $kinds) { foreach ($d in (Get-DocFieldList -Ctx $Ctx -Key $keyOf[$k])) { $dirs.Add([string]$d) } }
    }
    if ($dirs.Count -eq 0) { $null = Get-DocField -Ctx $Ctx -Key 'Docs' -Required }
    $opts = if ($CaseSensitive) { $script:Ci } else { $script:Ic }
    try {
        $re = [regex]::new($Pattern, $opts)
    } catch {
        throw (New-DocException 'usage' ('некоректний regex: ' + $_.Exception.Message))
    }
    $prefixes = @($dirs | ForEach-Object { $_.TrimEnd('/') + '/' })
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-DocGitFiles -Ctx $Ctx)) {
        if (-not $f.EndsWith('.md', [System.StringComparison]::Ordinal)) { continue }
        foreach ($p in $prefixes) { if ($f.StartsWith($p, [System.StringComparison]::Ordinal)) { $files.Add($f); break } }
    }
    $max = if ($null -ne $Max) { ConvertTo-DocNumber -Value $Max } else { 20.0 }
    # Компактно (у полі 15 збігів давали 4 КБ): група за файлом, під нею — за найближчим
    # заголовком, рядок збігу — вікно навколо збігу.
    $groups = [System.Collections.Generic.List[object]]::new()
    $groupByRel = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $shown = 0
    $total = 0
    $first = $null
    foreach ($rel in $files) {
        $path = Join-DocPath -Root $Ctx.Root -Rel $rel
        if (-not (Test-DocPathExists -Path $path)) { continue }
        $scanned = Get-MdScannedLines -Text (Read-DocText -Path $path)
        $heading = $null
        for ($i = 0; $i -lt $scanned.Count; $i++) {
            $line = $scanned[$i].Line
            if (-not $scanned[$i].Code) {
                $hm = $script:RxFindHead.Match($line)
                if ($hm.Success) { $heading = $hm.Groups[2].Value }
            }
            if (-not $re.IsMatch($line)) { continue }
            $total++
            if ($shown -ge $max) { continue }
            $shown++
            if ($null -eq $first) { $first = @{ Rel = $rel; Line = $i + 1 } }
            if (-not $groupByRel.ContainsKey($rel)) {
                $g = [pscustomobject]@{
                    Rel   = $rel
                    Order = [System.Collections.Generic.List[string]]::new()
                    Map   = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                    Count = 0
                }
                $groupByRel[$rel] = $g
                $groups.Add($g)
            }
            $g = $groupByRel[$rel]
            $key = if ($null -ne $heading) { $heading } else { '' }
            if (-not $g.Map.ContainsKey($key)) {
                $g.Map[$key] = [System.Collections.Generic.List[string]]::new()
                $g.Order.Add($key)
            }
            $g.Map[$key].Add("    $($i + 1): $(Get-DocSnippet -Text $line.Trim() -Re $re -Width $script:SnippetWidth)")
            $g.Count++
        }
    }
    if ($files.Count -eq 0) {
        return New-DocResult -ErrLines @(Format-DocError -Message "немає markdown-файлів у $($dirs -join ', ')") -Code $script:DocExit.NotChecked
    }
    if ($total -eq 0) {
        $flag = if ($CaseSensitive) { '' } else { 'i' }
        $other = if ($In -eq 'docs') { 'specs' } else { 'docs' }
        return New-DocResult -Lines @(
            "немає збігів для /$Pattern/$flag у файлів: $($files.Count)",
            ('next: doc find {0} -In {1}' -f (Format-DocQuote -Text $Pattern), $other)
        ) -Code $script:DocExit.Failed
    }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $groups) {
        $out.Add("$($g.Rel) ($($g.Count))")
        foreach ($h in $g.Order) {
            if ($h) { $out.Add("  § $(if ($h.Length -gt 48) { $h.Substring(0, 47) + '…' } else { $h })") }
            $out.AddRange([string[]]$g.Map[$h].ToArray())
        }
    }
    if ($total -gt $shown) { $out.Add("(ще збігів: $($total - $shown); -Max $total, щоб показати всі)") }
    $more = if ($total -gt $shown) { "$($script:Sep)doc find $(Format-DocQuote -Text $Pattern) -Max $total" } else { '' }
    $out.Add("next: doc $(Format-DocQuote -Text $first.Rel) $($first.Line)-$($first.Line + 20)$more")
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

# --- anchors ----------------------------------------------------------------------------------
# Перевірки якорів (шляхи, посилання, вказівники § на розділи) плюс `#якорі` за slug GitHub.
# Перевірки форми корпусу (дублі блоків, ліміти скілів, глибина reference) — у lint нижче.

$script:DefaultExternal = @('MEMORY.md', 'SKILL.md', 'CLAUDE.local.md')
# Плейсхолдер або glob — не якір: перевіряти нічого.
$script:RxPlaceholder = [regex]::new('[<>{}*|]|\.\.\.|\$\{|\$[A-Za-z_]', $script:Ci)
$script:RxBackticked = [regex]::new('`([^`\n]+)`', $script:Ci)
# Текст лінка може переноситись на один наступний рядок (обгортка абзацу).
$script:RxMdLink = [regex]::new('\[[^\]\n]*(?:\n[^\]\n]*)?\]\(([^)\s]+)(?:\s+"[^"]*")?\)', $script:Ci)
$script:RxUrl = [regex]::new('^[a-z][a-z0-9+.-]*:', $script:Ic)
$script:Quoted = '(?:«[^»\n]+»|“[^”\n]+”|"[^"\n]+")'
$script:RxSectionName = [regex]::new('«([^»\n]+)»|“([^”\n]+)”|"([^"\n]+)"', $script:Ci)
$script:RxSectionAt = [regex]::new('§{1,2}\s*(?<sections>' + $script:Quoted + '(?:\s*(?:,|і|and)\s*' + $script:Quoted + ')*)', $script:Ci)
# Найближче ПЕРЕД § посилання на док чи скіл: у рядку їх буває кілька.
$script:RxAnchorBefore = [regex]::new('(?<![A-Za-z0-9_./-])(?:(?<doc>[A-Za-z0-9_./-]+\.md)|(?:скіл|skill)\s+`(?<skill>[a-z0-9-]+)`)(?!.*(?:\.md|(?:скіл|skill)\s+`))', $script:Sl)
$script:RxOwnTail = [regex]::new('^\s*(нижче|вище|тут|below|above|here)(?![\p{L}\p{N}_])', $script:Ic)
$script:RxNumbered = [regex]::new('(?<![A-Za-z0-9_./-])`?(?<doc>[A-Za-z0-9_./-]+\.md)`?\s*,?\s*§\s*(?<num>[0-9]+[a-z]?(?:\.[0-9]+[a-z]?)*)(?![A-Za-z])', $script:Ci)
$script:RxLineSuffix = [regex]::new('[:]\s*[0-9]+(?:\s*[-–]\s*[0-9]+)?(?:\s*,\s*[0-9]+(?:\s*[-–]\s*[0-9]+)?)*$', $script:Ci)
$script:RxHtmlId = [regex]::new('<a\s[^>]*(?:name|id)\s*=\s*["'']([^"'']+)["'']', $script:Ic)
$script:RxNormTail = [regex]::new('[.,:;)»]+$', $script:Ci)
$script:RxNormAt = [regex]::new('^@+', $script:Ci)
$script:RxLeadSlashes = [regex]::new('^/+', $script:Ci)
$script:RxWsRun = [regex]::new('\s+', $script:Ci)
$script:RxHttp = [regex]::new('https?://', $script:Ci)

function Format-DocNorm {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)
    $t = $Token.Trim()
    $t = $script:RxNormTail.Replace($t, '')
    $t = $script:RxNormAt.Replace($t, '')
    if ($t.StartsWith('./', [System.StringComparison]::Ordinal)) { $t = $t.Substring(2) }
    $t
}

function ConvertFrom-DocUri {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try { return [System.Uri]::UnescapeDataString($Text) } catch { return $Text }
}

function Get-DocFileNameOf {
    # Ім'я файла з шляху: розділювачі й `/`, і `\`.
    param([Parameter(Mandatory)][string]$Path)
    [System.IO.Path]::GetFileName($Path.TrimEnd('/', '\'))
}

function Get-DocWalkMd {
    param([Parameter(Mandatory)][string]$Dir)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($f.EndsWith('.md', [System.StringComparison]::Ordinal)) { $names.Add($f) }
    }
    return , (Sort-DocOrdinal -Items $names.ToArray())
}

function New-DocAnchorChecker {
    param([Parameter(Mandatory)]$Ctx)
    $external = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $ext = Get-DocField -Ctx $Ctx -Key 'AnchorsExternal'
    foreach ($e in $(if ($null -eq $ext) { $script:DefaultExternal } else { @($ext) })) { [void]$external.Add([string]$e) }
    $skills = @(Get-DocFieldList -Ctx $Ctx -Key 'Skills')
    @{
        Ctx       = $Ctx
        Root      = $Ctx.Root
        DocDirs   = @(Get-DocFieldList -Ctx $Ctx -Key 'Docs' | ForEach-Object { [string]$_ })
        NameDirs  = @(@(Get-DocFieldList -Ctx $Ctx -Key 'Specs') + @(Get-DocFieldList -Ctx $Ctx -Key 'Plans') | ForEach-Object { [string]$_ })
        SkillDirs = Expand-DocDirs -Root $Ctx.Root -Patterns ([string[]]@($skills | ForEach-Object { [string]$_ }))
        External  = $external
        RootsSet  = $null
        Cache     = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        Stats     = @{ files = 0; paths = 0; links = 0; sections = 0; fragments = 0; skipped = 0 }
    }
}

function Get-DocAnchorRoots {
    param([Parameter(Mandatory)]$A)
    if ($null -eq $A.RootsSet) {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $field = Get-DocField -Ctx $A.Ctx -Key 'AnchorsRoots'
        if ($null -ne $field) {
            foreach ($r in @($field)) { [void]$set.Add([string]$r) }
        } else {
            foreach ($f in (Get-DocGitFiles -Ctx $A.Ctx)) {
                $i = $f.IndexOf('/')
                if ($i -ge 0) { [void]$set.Add($f.Substring(0, $i)) }
            }
        }
        $A.RootsSet = $set
    }
    return , $A.RootsSet
}

function Test-DocRepoPath {
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)][string]$Token)
    $i = $Token.IndexOf('/')
    if ($i -lt 0) { return $false }
    (Get-DocAnchorRoots -A $A).Contains($Token.Substring(0, $i))
}

function Get-DocDocInfo {
    # Заголовки й ідентифікатори якорів файла (з кешем). Неіснуючий файл — порожній документ.
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)][string]$Path)
    if (-not $A.Cache.ContainsKey($Path)) {
        $text = if ([System.IO.File]::Exists($Path)) { Read-DocText -Path $Path } else { '' }
        $heads = Get-MdHeadings -Text $text
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($s in (Get-MdHeadingSlugs -Heads $heads)) { [void]$ids.Add($s) }
        foreach ($m in $script:RxHtmlId.Matches($text)) { [void]$ids.Add($m.Groups[1].Value) }
        $A.Cache[$Path] = [pscustomobject]@{ Heads = $heads; Ids = $ids }
    }
    return $A.Cache[$Path]
}

function Resolve-DocDocName {
    # Голе ім'я `.md`: сусідній файл, свій скіл, docs/, корінь, каталоги спек і планів.
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Src)
    $root = $A.Root
    if ([System.IO.Path]::IsPathRooted($Name) -and $Name.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-DocPathExists -Path $Name) { return $Name } else { return $null }
    }
    $s = $script:RxLeadSlashes.Replace($Name, '')
    $here = [System.IO.Path]::GetDirectoryName($Src)
    $cands = [System.Collections.Generic.List[string]]::new()
    $cands.Add([System.IO.Path]::GetFullPath($s, $here))
    $cands.Add([System.IO.Path]::GetFullPath('../' + $s, $here))
    $cands.Add([System.IO.Path]::GetFullPath('references/' + $s, $here))
    $cands.Add((Join-DocPath -Root $root -Rel $s))
    foreach ($d in $A.DocDirs) { $cands.Add((Join-DocPath -Root (Join-DocPath -Root $root -Rel $d) -Rel $s)) }
    foreach ($d in $A.NameDirs) { $cands.Add((Join-DocPath -Root (Join-DocPath -Root $root -Rel $d) -Rel (Get-DocFileNameOf -Path $s))) }
    foreach ($c in $cands) {
        if (Test-DocPathExists -Path $c) { return [System.IO.Path]::GetFullPath($c) }
    }
    # Крос-скілове `references/foo.md` — лише якщо ім'я унікальне серед скілів.
    if ($s.StartsWith('references/', [System.StringComparison]::Ordinal)) {
        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $A.SkillDirs) {
            foreach ($sk in [System.IO.Directory]::GetFileSystemEntries($d)) {
                $p = Join-DocPath -Root $sk -Rel $s
                if (Test-DocPathExists -Path $p) { $hits.Add($p) }
            }
        }
        if ($hits.Count -eq 1) { return $hits[0] }
    }
    return $null
}

function Add-DocBroken {
    param($Broken, [string]$Rel, [string]$Text, [int]$Index, [string]$Message)
    $line = 1
    $upto = [Math]::Min($Index, $Text.Length)
    for ($k = 0; $k -lt $upto; $k++) { if ($Text[$k] -eq "`n") { $line++ } }
    $Broken.Add("${Rel}:${line}: $Message")
}

function Test-DocFragment {
    param($A, [string]$Path, [string]$Frag, $Broken, [string]$Rel, [string]$Text, [int]$At, [string]$Where)
    $A.Stats.fragments++
    $ids = (Get-DocDocInfo -A $A -Path $Path).Ids
    # GitHub знаходить якір і без урахування регістру — `#Foo` веде на `foo`.
    if (-not $ids.Contains($Frag) -and -not $ids.Contains($Frag.ToLowerInvariant())) {
        Add-DocBroken -Broken $Broken -Rel $Rel -Text $Text -Index $At -Message "немає якоря #$Frag у $Where"
    }
}

function Test-DocSectionNames {
    param($A, [object[]]$Heads, [string]$Where, [string]$Sections, [bool]$Own, $Broken, [string]$Rel, [string]$Text, [int]$At)
    foreach ($m in $script:RxSectionName.Matches($Sections)) {
        $shown = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $name = $shown.Trim().ToLowerInvariant()
        $A.Stats.sections++
        # Заголовок може нести номер («## 3. Хуки…»), тож звіряємо за входженням.
        $found = $false
        foreach ($h in $Heads) { if ($h.Text.ToLowerInvariant().Contains($name)) { $found = $true; break } }
        if (-not $found) {
            $what = if ($Own) { 'немає власного розділу' } else { 'немає розділу' }
            Add-DocBroken -Broken $Broken -Rel $Rel -Text $Text -Index $At -Message "$Where — $what ""$shown"""
        }
    }
}

function Test-DocAnchorSource {
    # Усі перевірки якорів одного файла; повертає список рядків-знахідок (порожній — усе гаразд).
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)][string]$Src)
    $root = $A.Root
    $rel = Get-DocRel -Root $root -Path $Src
    $raw = Read-DocText -Path $Src
    # Код-блоки — приклади, не якорі: замінюємо порожніми рядками, щоб номери рядків у звіті лишились
    # справжніми.
    $scanned = Get-MdScannedLines -Text $raw
    $plain = [string[]]::new($scanned.Count)
    for ($i = 0; $i -lt $scanned.Count; $i++) { $plain[$i] = if ($scanned[$i].Code) { '' } else { $scanned[$i].Line } }
    $text = [string]::Join("`n", $plain)
    $broken = [System.Collections.Generic.List[string]]::new()
    $A.Stats.files++

    $tokens = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $script:RxBackticked.Matches($text)) { $tokens.Add([pscustomobject]@{ Raw = $m.Groups[1].Value; At = $m.Index; Link = $false }) }
    foreach ($m in $script:RxMdLink.Matches($text)) {
        $v = $m.Groups[1].Value
        if ($v.StartsWith('<')) { $v = $v.Substring(1) }
        if ($v.EndsWith('>')) { $v = $v.Substring(0, $v.Length - 1) }
        $tokens.Add([pscustomobject]@{ Raw = $v; At = $m.Index; Link = $true })
    }
    foreach ($tk in $tokens) {
        $token = Format-DocNorm -Token $tk.Raw
        if (-not $token -or $script:RxUrl.IsMatch($token) -or $script:RxPlaceholder.IsMatch($token)) { continue }
        $hash = $token.IndexOf('#')
        $pathPart = ConvertFrom-DocUri -Text $(if ($hash -ge 0) { $token.Substring(0, $hash) } else { $token })
        $frag = if ($hash -ge 0) { ConvertFrom-DocUri -Text $token.Substring($hash + 1) } else { $null }
        $at = $tk.At
        # Фрагмент без шляху — лише в лінку: у беквотах `#foo` — це не посилання.
        if (-not $pathPart) {
            if ($tk.Link -and $frag) { Test-DocFragment -A $A -Path $Src -Frag $frag -Broken $broken -Rel $rel -Text $text -At $at -Where 'власному файлі' }
            continue
        }
        # `шлях:НОМЕР` на справжній шлях: номери рядків зсуваються від першої правки.
        $base = $script:RxLineSuffix.Replace($pathPart, '')
        if ($base -cne $pathPart -and (Test-DocRepoPath -A $A -Token $base) -and (Test-DocPathExists -Path (Join-DocPath -Root $root -Rel $base))) {
            $A.Stats.paths++
            Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $at -Message "номер рядка в якорі ``$token`` — вказуйте на файл (і розділ), а не на рядок"
            continue
        }
        $target = $null
        if (Test-DocRepoPath -A $A -Token $pathPart) {
            $A.Stats.paths++
            $target = Join-DocPath -Root $root -Rel $pathPart
            if (-not (Test-DocPathExists -Path $target)) {
                Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $at -Message "немає шляху ``$pathPart``"
                continue
            }
        } elseif ($pathPart.EndsWith('.md', [System.StringComparison]::Ordinal)) {
            if ($A.External.Contains((Get-DocFileNameOf -Path $pathPart))) { $A.Stats.skipped++; continue }
            $A.Stats.links++
            $target = Resolve-DocDocName -A $A -Name $pathPart -Src $Src
            if (-not $target) {
                Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $at -Message "немає документа ``$pathPart``"
                continue
            }
        } elseif ($tk.Link) {
            # Відносний лінк не на .md (картинка, скрипт) — від каталогу файла.
            $A.Stats.links++
            $target = if ($pathPart.StartsWith('/', [System.StringComparison]::Ordinal)) { Join-DocPath -Root $root -Rel $pathPart } else { [System.IO.Path]::GetFullPath($pathPart, [System.IO.Path]::GetDirectoryName($Src)) }
            if (-not (Test-DocPathExists -Path $target)) {
                Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $at -Message "немає цілі посилання ``$pathPart``"
                continue
            }
        } else { continue }
        if ($frag -and $target.EndsWith('.md', [System.StringComparison]::Ordinal)) {
            Test-DocFragment -A $A -Path $target -Frag $frag -Broken $broken -Rel $rel -Text $text -At $at -Where "``$pathPart``"
        }
    }

    # 2b. Голі шляхи (поза беквотами й лінками) і `file:N` за межею файла.
    $evalBlank = [System.Text.RegularExpressions.MatchEvaluator] { param($m) ' ' * $m.Length }
    $evalBlankKeepNl = [System.Text.RegularExpressions.MatchEvaluator] { param($m) [regex]::Replace($m.Value, '[^\n]', ' ') }
    $masked = $script:RxBackticked.Replace($text, $evalBlank)
    $masked = $script:RxMdLink.Replace($masked, $evalBlankKeepNl)
    $null = Get-DocAnchorRoots -A $A
    $rootsSet = [string[]]@($A.RootsSet)
    $refs = Find-PathRef -Text $masked -Root $root -Roots $rootsSet -BaseDir ([System.IO.Path]::GetDirectoryName($Src))
    foreach ($r in $refs) {
        if ($script:RxPlaceholder.IsMatch($r.Ref)) { continue }
        $c = Get-PathRefState -Root $root -Ref $r
        if ($c.Kind -eq 'new' -or $c.Kind -eq 'ignored') { $A.Stats.skipped++; continue }
        $A.Stats.paths++
        if ($c.Kind -eq 'missing') { $broken.Add("${rel}:$($r.LineNo): немає шляху $($r.Ref)") }
        elseif ($c.Kind -eq 'line') { $broken.Add("${rel}:$($r.LineNo): $($r.Ref) — рядок $($r.Line) за межею файла (у файлі рядків: $($c.Total))") }
    }

    # 3. § «Назва»: розділ шукаємо серед заголовків цільового файла.
    foreach ($m in $script:RxSectionAt.Matches($text)) {
        $start = [Math]::Max(0, $m.Index - 400)
        $head = $text.Substring($start, $m.Index - $start)
        $tail60 = if ($head.Length -gt 60) { $head.Substring($head.Length - 60) } else { $head }
        if ($script:RxHttp.IsMatch($tail60)) { continue }
        $sections = $m.Groups['sections'].Value
        $afterAt = $m.Index + $m.Length
        $tail = $text.Substring($afterAt, [Math]::Min(20, $text.Length - $afterAt))
        $ownHeads = (Get-DocDocInfo -A $A -Path $Src).Heads
        $ownWhere = "``$(Get-DocFileNameOf -Path $Src)``"
        if ($script:RxOwnTail.IsMatch($tail)) {
            Test-DocSectionNames -A $A -Heads $ownHeads -Where $ownWhere -Sections $sections -Own $true -Broken $broken -Rel $rel -Text $text -At $m.Index
            continue
        }
        $ab = $script:RxAnchorBefore.Match($head)
        # Збіг на позиції 0 — вікно, найімовірніше, розрізало токен.
        if ($ab.Success -and $ab.Index -eq 0 -and $start -gt 0) { $ab = $null }
        if ($null -eq $ab -or -not $ab.Success -or ($head.Length - ($ab.Index + $ab.Length)) -gt 120) {
            Test-DocSectionNames -A $A -Heads $ownHeads -Where $ownWhere -Sections $sections -Own $true -Broken $broken -Rel $rel -Text $text -At $m.Index
            continue
        }
        if ($ab.Groups['doc'].Success) {
            $target = Format-DocNorm -Token $ab.Groups['doc'].Value
            $tn = Get-DocFileNameOf -Path $target
            if ($A.External.Contains($tn) -and $tn -cne 'SKILL.md') { $A.Stats.skipped++; continue }
            $path = Resolve-DocDocName -A $A -Name $target -Src $Src
            if (-not $path) {
                Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $m.Index -Message "немає документа ``$target`` для вказівника §"
                continue
            }
            Test-DocSectionNames -A $A -Heads (Get-DocDocInfo -A $A -Path $path).Heads -Where "``$target``" -Sections $sections -Own $false -Broken $broken -Rel $rel -Text $text -At $m.Index
        } else {
            $skill = $ab.Groups['skill'].Value
            $sdir = $null
            foreach ($d in $A.SkillDirs) {
                $cand = Join-DocPath -Root $d -Rel $skill
                if (Test-DocPathExists -Path $cand) { $sdir = $cand; break }
            }
            if (-not $sdir) {
                Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $m.Index -Message "немає скіла ``$skill``"
                continue
            }
            $heads = [System.Collections.Generic.List[object]]::new()
            foreach ($f in (Get-DocWalkMd -Dir $sdir)) { $heads.AddRange([object[]](Get-DocDocInfo -A $A -Path $f).Heads) }
            Test-DocSectionNames -A $A -Heads $heads.ToArray() -Where "скіл ``$skill``" -Sections $sections -Own $false -Broken $broken -Rel $rel -Text $text -At $m.Index
        }
    }

    # 3b. `док.md §N` — лише з явним доком упритул; голий `спека §14` не резолвиться.
    foreach ($m in $script:RxNumbered.Matches($text)) {
        $target = Format-DocNorm -Token $m.Groups['doc'].Value
        $before = $text.Substring([Math]::Max(0, $m.Index - 60), $m.Index - [Math]::Max(0, $m.Index - 60))
        if ($script:RxHttp.IsMatch($before) -or $script:RxPlaceholder.IsMatch($target)) { continue }
        if ($A.External.Contains((Get-DocFileNameOf -Path $target))) { $A.Stats.skipped++; continue }
        $A.Stats.sections++
        $path = Resolve-DocDocName -A $A -Name $target -Src $Src
        if (-not $path) {
            Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $m.Index -Message "немає документа ``$target`` для вказівника §"
            continue
        }
        $num = $m.Groups['num'].Value
        $has = $false
        foreach ($h in (Get-DocDocInfo -A $A -Path $path).Heads) { if (Test-MdNumberMatch -Text $h.Text -Number $num) { $has = $true; break } }
        if (-not $has) { Add-DocBroken -Broken $broken -Rel $rel -Text $text -Index $m.Index -Message "``$target`` — немає розділу §$num" }
    }
    return , $broken.ToArray()
}

function Test-DocAnchors {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string[]]$Files = @())
    $A = New-DocAnchorChecker -Ctx $Ctx
    $sources = [System.Collections.Generic.List[string]]::new()
    if ($Files.Count -gt 0) { foreach ($f in $Files) { $sources.Add((Resolve-DocPath -Path $f -WorkDir $Ctx.WorkDir)) } }
    else { foreach ($f in (Get-DocCorpus -Ctx $Ctx)) { $sources.Add($f) } }
    foreach ($f in $sources) {
        if (-not (Test-DocPathExists -Path $f)) { throw (New-DocException 'usage' "немає такого файла: $f") }
    }
    if ($sources.Count -eq 0) {
        return New-DocResult -ErrLines @(Format-DocError -Message 'anchors: корпус порожній (перевірте docs.anchors.include)') -Code $script:DocExit.NotChecked
    }
    $broken = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $sources) { $broken.AddRange([string[]](Test-DocAnchorSource -A $A -Src $s)) }
    $s = $A.Stats
    $summary = "файлів $($s.files), шляхів $($s.paths), посилань $($s.links), розділів $($s.sections), #якорів $($s.fragments), пропущено $($s.skipped)"
    $fileArgs = Format-DocFiles -Files $Files
    if ($broken.Count -gt 0) {
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($b in $broken) { $out.Add("- $b") }
        $out.Add("doc anchors: биті: $($broken.Count) ($summary)")
        $out.Add("next: виправте рядки вище, потім doc anchors$fileArgs")
        return New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Failed
    }
    New-DocResult -Lines @("doc anchors: ok ($summary)", "next: doc lint$fileArgs") -Code $script:DocExit.Ok
}

# --- refs / history ---------------------------------------------------------------------------
# Механіка закриття блоку. Простий пошук за іменем файла не бачить відносних посилань у markdown і
# коментарів коду; а мітки етапів (`§6.4`, «Фаза 3», `PR #N`) у коді не є шляхами взагалі — після
# видалення документа це навігація в нікуди.

$script:MaxText = 1024 * 1024
$script:RxLockfile = [regex]::new('(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb?|Cargo\.lock|poetry\.lock)$', $script:Ci)
$script:RxConfigExt = [regex]::new('\.(json|ya?ml|toml)$', $script:Ci)

function Get-DocTextFiles {
    # Усі текстові файли репо (до 1 МБ, без двійкових і lock-файлів): список { Rel; Text }.
    param([Parameter(Mandatory)]$Ctx)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in (Get-DocGitFiles -Ctx $Ctx)) {
        if ($rel.Contains('node_modules/') -or $script:RxLockfile.IsMatch($rel)) { continue }
        $path = Join-DocPath -Root $Ctx.Root -Rel $rel
        try {
            $fi = [System.IO.FileInfo]::new($path)
            if (-not $fi.Exists -or $fi.Length -gt $script:MaxText) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($path)
            if ([System.Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }
            $out.Add([pscustomobject]@{ Rel = $rel; Text = [System.Text.UTF8Encoding]::new($false).GetString($bytes).Replace("`r`n", "`n") })
        } catch { continue }
    }
    return , $out.ToArray()
}

function Get-DocKind {
    param([Parameter(Mandatory)][string]$Rel)
    if ($Rel.EndsWith('.md', [System.StringComparison]::Ordinal) -or $Rel.EndsWith('.mdx', [System.StringComparison]::Ordinal)) { return 'doc' }
    if ($script:RxConfigExt.IsMatch($Rel)) { return 'config' }
    'code'
}

function Format-DocClip {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $t = $Line.Trim()
    if ($t.Length -gt 160) { return $t.Substring(0, 157) + '...' }
    $t
}

function Join-DocRelative {
    # Відносний шлях (від кореня репо) теки + відносного посилання, нормалізований: `.` і `..`
    # згорнуто, розділювач `/`.
    param([string]$DirRel, [string]$Link)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in (($DirRel + '/' + $Link).Replace('\', '/').Split('/'))) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') {
            if ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -ne '..') { $parts.RemoveAt($parts.Count - 1) } else { $parts.Add('..') }
            continue
        }
        $parts.Add($seg)
    }
    $parts -join '/'
}

function Get-DocLineRefKind {
    # Чи посилається рядок файла `rel` на ціль `target` (файл або тека/): path | link | name | $null.
    param([string]$Line, [string]$Rel, [string]$Target, [bool]$IsDir)
    if ($Line.Contains($Target)) { return 'path' }
    $targetNoSlash = $Target.TrimEnd('/')
    if ($Line.Contains('](')) {
        $dirRel = ''
        $slash = $Rel.LastIndexOf('/')
        if ($slash -ge 0) { $dirRel = $Rel.Substring(0, $slash) }
        foreach ($m in $script:RxMdLink.Matches($Line)) {
            $link = $m.Groups[1].Value
            if ($script:RxUrl.IsMatch($link) -or $link.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
            $h = $link.IndexOf('#')
            $linkPath = ConvertFrom-DocUri -Text $(if ($h -ge 0) { $link.Substring(0, $h) } else { $link })
            $resolved = Join-DocRelative -DirRel $dirRel -Link $linkPath
            if ($resolved -ceq $targetNoSlash -or ($IsDir -and $resolved.StartsWith($Target, [System.StringComparison]::Ordinal))) { return 'link' }
        }
    }
    $name = Get-DocFileNameOf -Path $targetNoSlash
    # Голе ім'я — лише довге й з розширенням, інакше шум (README.md, index.ts).
    if (-not $IsDir -and $name.Length -ge 12 -and $name.Contains('.')) {
        if ([regex]::IsMatch($Line, '(?<![\w./-])' + [regex]::Escape($name) + '(?![\w-])')) { return 'name' }
    }
    return $null
}

function Get-DocRefs {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string[]]$Targets = @(), [bool]$Dead = $false, $Max)
    $files = Get-DocTextFiles -Ctx $Ctx
    $max = if ($null -ne $Max) { ConvertTo-DocNumber -Value $Max } else { 200.0 }
    if ($Dead) { return Get-DocDeadRefs -Ctx $Ctx -Files $files -Max $max }
    if ($Targets.Count -eq 0) { throw (New-DocException 'usage' 'doc refs <шлях...> | doc refs -Dead') }
    $norm = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Targets) {
        $abs = Resolve-DocPath -Path $t -WorkDir $Ctx.WorkDir
        $rel = Get-DocRel -Root $Ctx.Root -Path $abs
        $isDir = [System.IO.Directory]::Exists($abs)
        $norm.Add([pscustomobject]@{ Rel = $(if ($isDir) { $rel.TrimEnd('/') + '/' } else { $rel }); IsDir = $isDir })
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $total = 0
    foreach ($t in $norm) {
        $hits = [System.Collections.Generic.List[string]]::new()
        # Дешеве відсіювання файла до рядкового циклу: ціль, `](` або довге голе ім'я мусять бути в тексті.
        $tName = Get-DocFileNameOf -Path $t.Rel.TrimEnd('/')
        $nameCheck = (-not $t.IsDir) -and $tName.Length -ge 12 -and $tName.Contains('.')
        foreach ($f in $files) {
            if (-not ($f.Text.Contains($t.Rel) -or $f.Text.Contains('](') -or ($nameCheck -and $f.Text.Contains($tName)))) { continue }
            # Посилання всередині видалюваного зникнуть разом із ним.
            $inside = $false
            foreach ($x in $norm) {
                if (($x.IsDir -and $f.Rel.StartsWith($x.Rel, [System.StringComparison]::Ordinal)) -or (-not $x.IsDir -and $f.Rel -ceq $x.Rel)) { $inside = $true; break }
            }
            if ($inside) { continue }
            $lines = $f.Text.Split([char]10)
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $how = Get-DocLineRefKind -Line $lines[$i] -Rel $f.Rel -Target $t.Rel -IsDir $t.IsDir
                if ($how) { $hits.Add("  $($f.Rel):$($i + 1) [$(Get-DocKind -Rel $f.Rel), $how] $(Format-DocClip -Line $lines[$i])") }
            }
        }
        $total += $hits.Count
        $out.Add("$($t.Rel): посилань: $($hits.Count)")
        for ($k = 0; $k -lt [Math]::Min($hits.Count, $max); $k++) { $out.Add($hits[$k]) }
        if ($hits.Count -gt $max) { $out.Add("  (ще $($hits.Count - $max); -Max $($hits.Count))") }
    }
    $out.Add("doc refs: посилань: $total на шляхів: $($norm.Count) поза ними — виправте кожне перед видаленням (види: doc, code, config)")
    # Перед видаленням: спершу посилання, потім живий борг самих файлів.
    if ($total -gt 0) {
        $out.Add('next: виправте кожне посилання вище, потім doc refs' + (Format-DocFiles -Files $Targets))
    } else {
        $md = @($Targets | Where-Object { $_.EndsWith('.md', [System.StringComparison]::Ordinal) })
        $arg = if ($md.Count -gt 0) { (Format-DocFiles -Files $md).TrimStart() } else { '<файл.md>' }
        $out.Add("next: doc debt $arg")
    }
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

function Get-DocDeadRefs {
    # Згадки шляхів у теках документації, яких немає на диску, — по всьому репо.
    param($Ctx, [object[]]$Files, [double]$Max)
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'Docs', 'Specs', 'Plans') {
        foreach ($d in (Get-DocFieldList -Ctx $Ctx -Key $k)) {
            $r = ([string]$d).TrimEnd('/')
            if (-not $roots.Contains($r)) { $roots.Add($r) }
        }
    }
    if ($roots.Count -eq 0) { $null = Get-DocField -Ctx $Ctx -Key 'Docs' -Required }
    $alt = ($roots | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $re = [regex]::new('(?<![\w./-])((?:' + $alt + ')/[\w.@/-]*[\w-]\.[a-z0-9]{1,5})(?![\w/])', $script:Ci)
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Files) {
        $lines = $f.Text.Split([char]10)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i].Length -eq 0) { continue }
            foreach ($m in $re.Matches($lines[$i])) {
                $p = $m.Groups[1].Value
                if ($script:RxPlaceholder.IsMatch($p) -or (Test-DocPathExists -Path (Join-DocPath -Root $Ctx.Root -Rel $p))) { continue }
                $hits.Add("$($f.Rel):$($i + 1) [$(Get-DocKind -Rel $f.Rel)] $p")
            }
        }
    }
    if ($hits.Count -eq 0) {
        return New-DocResult -Lines @("doc refs -Dead: ok (файлів $($Files.Count), корені $($roots -join ', '))", 'next: doc anchors') -Code $script:DocExit.Ok
    }
    $out = [System.Collections.Generic.List[string]]::new()
    for ($k = 0; $k -lt [Math]::Min($hits.Count, $Max); $k++) { $out.Add($hits[$k]) }
    if ($hits.Count -gt $Max) { $out.Add("(ще $($hits.Count - $Max); -Max $($hits.Count))") }
    $out.Add("doc refs -Dead: посилань на неіснуючі файли: $($hits.Count) — биті (виправити) або майбутні (їх створить жива задача: лишити, сказати про це)")
    $out.Add('next: виправте або позначте кожен рядок вище, потім doc refs -Dead')
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Failed
}

# Межа слова для кирилиці: `\b` у JS бачить межу лише між ASCII-символами, а `\b` .NET бачить
# її між будь-якими буквами, тож ліва межа — lookbehind. Оригінал міняв `\b` на lookbehind і
# праворуч, тому гілки з правою межею там не спрацьовували ніколи; в оригіналі ці гілки мертві
# через межу слова, а оживлені дають хибні мітки на звичайній англійській прозі (рев'ю T1, I1),
# тож їх тут немає.
$script:NbL = '(?<![\p{L}\p{N}_])'

$script:CodeLabels = @(
    , @('§', [regex]::new('§\s?[0-9]', $script:Ci))
    , @('phase', [regex]::new($script:NbL + '[Pp]hase [0-9]|' + $script:NbL + '[Фф]аз[аиуіоє]\p{L}* [0-9]', $script:Ci))
    , @('stage', [regex]::new($script:NbL + '[Ее]тап\p{L}* [0-9]|' + $script:NbL + '[Ss]tage [0-9]', $script:Ci))
    , @('task', [regex]::new($script:NbL + '[Tt]ask [0-9]|' + $script:NbL + '[Зз]адач\p{L}* [0-9]', $script:Ci))
    , @('PR', [regex]::new('\bPR #[0-9]', $script:Ci))
)
# Фазова нарація в доках: доки тримають стан, історія — у git.
$script:DocNarration = @(
    , @('phase', [regex]::new($script:NbL + '(у|в|на|після|до|з) (фаз|етап|блок|блоц|хвил)\p{L}* [\p{Lu}0-9]', $script:Ic))
    , @('phase', [regex]::new('\b(in|after|before|during) (phase|stage|block|wave) [A-Z0-9]', $script:Ic))
    , @('PR', [regex]::new('\bPR #[0-9]|\(#[0-9]+\)', $script:Ci))
    , @('was→is', [regex]::new($script:NbL + 'було\s*→\s*стало', $script:Ic))
    , @('reversal', [regex]::new($script:NbL + '(скасован|відмінен|розвернут)\p{L}*', $script:Ic))
    , @('removed-in', [regex]::new($script:NbL + '(removed|deleted|видален)\p{L}* (in|у|в) v?[0-9]', $script:Ic))
    , @('header', [regex]::new('^(\*\*)?(Версія|Version|Дата|Date|Оновлено|Updated)(\*\*)?\s*:', $script:Ci))
    , @('as-of', [regex]::new($script:NbL + 'станом на [0-9]|' + $script:NbL + 'as of [0-9]{4}', $script:Ic))
    , @('changelog', [regex]::new('^#+\s*(changelog|журнал змін|історія змін|history)(?![\p{L}])', $script:Ic))
)

function New-DocUserRegex {
    param([string]$Pattern, [string]$Flag)
    if ([string]::IsNullOrEmpty($Pattern)) { return $null }
    try { return [regex]::new($Pattern, $script:Ci) } catch {
        throw (New-DocException 'usage' "некоректний regex для ${Flag}: $($_.Exception.Message)")
    }
}

function Format-DocCountBy {
    # Топ-8 значень ключа за кількістю (стабільно: за порядком першої появи).
    param([string[]]$Hits, [scriptblock]$Key)
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $Hits) {
        $k = & $Key $h
        if (-not $counts.ContainsKey($k)) { $counts[$k] = 0; $order.Add($k) }
        $counts[$k]++
    }
    $idx = 0
    $rows = foreach ($k in $order) { [pscustomobject]@{ K = $k; N = $counts[$k]; I = $idx++ } }
    (@($rows | Sort-Object -Property @{ Expression = 'N'; Descending = $true }, @{ Expression = 'I'; Descending = $false } | Select-Object -First 8 | ForEach-Object { "$($_.K) $($_.N)" }) -join ', ')
}

function Get-DocHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ctx,
        [bool]$Code = $false, [bool]$Docs = $false,
        [string]$Only, [string]$Ignore, [string[]]$Path = @(), $Max
    )
    $max = if ($null -ne $Max) { ConvertTo-DocNumber -Value $Max } else { 200.0 }
    $rxIgnore = New-DocUserRegex -Pattern $Ignore -Flag '-Ignore'
    # Мітки блоку (назва, код блоку, номер PR): весь репо дає тисячі `§` на живу спеку, а закриття
    # блоку цікавлять лише мітки самого блоку.
    $rxOnly = New-DocUserRegex -Pattern $Only -Flag '-Only'
    # Слова проєкту, що не є наративом фаз: мітка, чий збіг містить таке слово, — шум, а не історія.
    $domain = @(Get-DocFieldList -Ctx $Ctx -Key 'HistoryIgnore' | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $prefixes = @($Path | ForEach-Object { $_.Replace('\', '/').TrimEnd('/') + '/' })
    $wantCode = (-not $Docs) -or $Code
    $wantDocs = (-not $Code) -or $Docs
    $out = [System.Collections.Generic.List[string]]::new()
    $script:HistTotal = 0
    $scan = {
        param($title, $list, $rules)
        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $list) {
            if ($f.Rel.EndsWith('.md', [System.StringComparison]::Ordinal)) {
                $scanned = Get-MdScannedLines -Text $f.Text
                $lines = [string[]]::new($scanned.Count)
                for ($i = 0; $i -lt $scanned.Count; $i++) { $lines[$i] = if ($scanned[$i].Code) { '' } else { $scanned[$i].Line } }
            } else { $lines = $f.Text.Split([char]10) }
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $line = $lines[$i]
                if (-not $line -or ($rxIgnore -and $rxIgnore.IsMatch($line)) -or ($rxOnly -and -not $rxOnly.IsMatch($line))) { continue }
                $tags = [System.Collections.Generic.List[string]]::new()
                foreach ($rule in $rules) {
                    $m = $rule[1].Match($line)
                    if (-not $m.Success) { continue }
                    $low = $m.Value.ToLowerInvariant()
                    $isDomain = $false
                    foreach ($w in $domain) { if ($low.Contains($w)) { $isDomain = $true; break } }
                    if (-not $isDomain -and -not $tags.Contains($rule[0])) { $tags.Add($rule[0]) }
                }
                if ($tags.Count -gt 0) { $hits.Add("$($f.Rel):$($i + 1) [$($tags -join ', ')] $(Format-DocClip -Line $line)") }
            }
        }
        $script:HistTotal += $hits.Count
        $out.Add("## ${title}: $($hits.Count)")
        for ($k = 0; $k -lt [Math]::Min($hits.Count, $max); $k++) { $out.Add($hits[$k]) }
        if ($hits.Count -gt $max) {
            # Підсумок замість тисяч рядків: за мітками й теками — щоб звузити -Only/-Path або
            # поділити роботу між агентами за теками, що не перетинаються.
            $out.Add("(ще $($hits.Count - $max); -Max $($hits.Count))")
            $out.Add('за мітками: ' + (Format-DocCountBy -Hits $hits.ToArray() -Key { param($h) [regex]::Match($h, '\[([^\]]+)\]').Groups[1].Value }))
            $out.Add('за теками: ' + (Format-DocCountBy -Hits $hits.ToArray() -Key { param($h) ((($h -split '/' | Select-Object -First 2) -join '/') -replace ':.*', '') }))
        }
    }
    $all = Get-DocTextFiles -Ctx $Ctx
    $files = @($all | Where-Object {
            $rel = $_.Rel
            $prefixes.Count -eq 0 -or ($prefixes | Where-Object { $rel.StartsWith($_, [System.StringComparison]::Ordinal) })
        })
    if ($wantCode) {
        & $scan 'мітки в коді (коментарі, рядки, назви тестів)' @($files | Where-Object { (Get-DocKind -Rel $_.Rel) -eq 'code' }) $script:CodeLabels
    }
    if ($wantDocs) {
        $docSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($p in (Get-DocCorpus -Ctx $Ctx)) { [void]$docSet.Add((Get-DocRel -Root $Ctx.Root -Path $p)) }
        foreach ($f in 'AGENTS.md', 'CLAUDE.md', 'README.md') { if ([System.IO.File]::Exists((Join-DocPath -Root $Ctx.Root -Rel $f))) { [void]$docSet.Add($f) } }
        & $scan 'нарація в документах' @($files | Where-Object { $docSet.Contains($_.Rel) }) $script:DocNarration
    }
    $total = $script:HistTotal
    $out.Add("doc history: кандидатів: $total — лишіть причину, приберіть мітку; шум (термін предметної області «phase», § живої спеки) лишається")
    if ($total -gt 0) {
        if ($Only) { $out.Add('next: виправте кожен рядок вище, потім той самий doc history') }
        else { $out.Add("next: doc history -Only '<власні мітки блоку, напр. B1c|PR #12>'   (лише мітки цього блоку)") }
    } else { $out.Add('next: doc refs -Dead') }
    $exitCode = if ($total -gt 0) { $script:DocExit.Failed } else { $script:DocExit.Ok }
    New-DocResult -Lines $out.ToArray() -Code $exitCode
}

# --- debt -------------------------------------------------------------------------------------
# Живий борг блоку, який не можна втратити з видаленням: невідмічені пункти й розділи про
# борг/відкладене/пастки. Список — щоб не пропустити; читати файл однаково треба повністю.

$script:RxDebtHeading = [regex]::new('борг|debt|відклад|deferred|парков|parked|known issues|відомі|пастк|pitfall|ризик|risk|не покри|not covered|open questions|відкриті питання|нерозв|unresolved|залишк|residual|todo|follow-?up|наступн|next', $script:Ic)
$script:RxUnchecked = [regex]::new('^\s*[-*+]\s+\[ \]', $script:Ci)

function Get-DocDebt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string[]]$Files = @())
    if ($Files.Count -eq 0) { throw (New-DocException 'usage' 'doc debt <файл...>') }
    $out = [System.Collections.Generic.List[string]]::new()
    $total = 0
    foreach ($f in $Files) {
        $text = Read-DocText -Path (Resolve-DocPath -Path $f -WorkDir $Ctx.WorkDir)
        $heads = Get-MdHeadings -Text $text
        $lineCount = $text.Split([char]10).Length
        $items = [System.Collections.Generic.List[string]]::new()
        $scanned = Get-MdScannedLines -Text $text
        for ($i = 0; $i -lt $scanned.Count; $i++) {
            if (-not $scanned[$i].Code -and $script:RxUnchecked.IsMatch($scanned[$i].Line)) { $items.Add("  $($i + 1): $(Format-DocClip -Line $scanned[$i].Line)") }
        }
        $sections = [System.Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $heads.Count; $k++) {
            $h = $heads[$k]
            $endLine = $lineCount + 1
            for ($j = $k + 1; $j -lt $heads.Count; $j++) { if ($heads[$j].Level -le $h.Level) { $endLine = $heads[$j].Line; break } }
            if ($script:RxDebtHeading.IsMatch($h.Text)) { $sections.Add("  $($h.Line)-$($endLine - 1): $('#' * $h.Level) $($h.Text)") }
        }
        $total += $items.Count + $sections.Count
        $out.Add("${f}: невідмічених пунктів: $($items.Count), розділів про борг: $($sections.Count)")
        if ($sections.Count -gt 0) { $out.Add('  розділи:'); foreach ($s in $sections) { $out.Add("  $s") } }
        if ($items.Count -gt 0) { $out.Add('  невідмічені:'); foreach ($s in $items) { $out.Add("  $s") } }
    }
    $out.Add("doc debt: кандидатів: $total — прочитайте кожен файл повністю; живі пункти перенесіть у задачі (issues) до видалення")
    if ($total -gt 0) { $out.Add('next: gh issue create --title "…" --body "…"   (по одному на живий пункт, потім видаляйте)') }
    else { $out.Add("next: doc refs$(Format-DocFiles -Files $Files)   (посилання перед видаленням)") }
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

# --- lint -------------------------------------------------------------------------------------
# Форма самого корпусу: дублі блоків, ліміти скілів, глибина reference. Прибирання дублів і лімітів
# без гарда живе рівно до наступного скіла, який хтось напише. Межі кожної перевірки записано
# поруч із нею.

$script:LintDefaults = [ordered]@{ LintDuplicateBlock = 3; LintSkillMaxLines = 500; LintReferenceMaxLines = 100; LintContentsHeadLines = 20 }
# Рядки, що НЕ є твердженням: збіг структури — не копія моделі. Відсіюються вони, а не
# піднімається поріг: поріг каже, наскільки довгий збіг вважаємо дублем, нормалізація — збіг ЧОГО
# ми взагалі рахуємо.
$script:RxLFence = [regex]::new('^\s*(?:```|~~~)', $script:Ci)
$script:RxLSeparator = [regex]::new('^(?:[-*_]{3,}|:?-{2,}:?)$', $script:Ci)
$script:RxLPointerOnly = [regex]::new('^[-*>\s]*(?:\*\*)?(?:Еталон|Exemplar|Reference|Example)(?:\*\*)?\s*:\s*`?[^\s`]+`?\.?$', $script:Ci)
$script:RxLLoneLink = [regex]::new('^[-*>\s]*\[[^\]]+\]\([^)\s]+\)[.,;:]?$', $script:Ci)
$script:RxContentsMark = [regex]::new('зміст|contents', $script:Ic)
# Вказівник із reference углиб: шлях у теку references (свою чи чужу).
$script:RxReferencePath = [regex]::new('(?:^|/)references/[^/]+\.md$', $script:Ci)
$script:RxSplitLines = [regex]::new('\r\n|[\n\r\v\f\x1c\x1d\x1e\x85  ]', $script:Ci)

function Split-DocLines {
    # Рядки як у Python `str.splitlines()`: без хвостового порожнього елемента.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parts = [System.Collections.Generic.List[string]]::new($script:RxSplitLines.Split($Text))
    if ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') { $parts.RemoveAt($parts.Count - 1) }
    return , $parts.ToArray()
}

function Get-DocStatementLines {
    # Рядки-ТВЕРДЖЕННЯ файла: те, чим модель описують. Код у фенсах, заголовки, таблиці,
    # роздільники, рядок-вказівник, порожні — викидаються, бо їх збіг у двох файлах копією моделі
    # не є за визначенням. Фенс — просте перемикання (паритет важливіший за точність CommonMark).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = [System.Collections.Generic.List[object]]::new()
    $inFence = $false
    $raws = Split-DocLines -Text $Text
    for ($i = 0; $i -lt $raws.Count; $i++) {
        $raw = $raws[$i]
        if ($script:RxLFence.IsMatch($raw)) { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#', [System.StringComparison]::Ordinal) -or $line.StartsWith('|', [System.StringComparison]::Ordinal)) { continue }
        if ($script:RxLSeparator.IsMatch($line) -or $script:RxLPointerOnly.IsMatch($line) -or $script:RxLLoneLink.IsMatch($line)) { continue }
        $out.Add([pscustomobject]@{ N = $i + 1; Line = $script:RxWsRun.Replace($line, ' ') })
    }
    return , $out.ToArray()
}

function New-DocLintChecker {
    param([Parameter(Mandatory)]$Ctx)
    $anchors = New-DocAnchorChecker -Ctx $Ctx   # той самий resolveDoc і ті самі теки скілів
    $t = @{}
    foreach ($k in $script:LintDefaults.Keys) {
        $v = Get-DocField -Ctx $Ctx -Key $k
        if ($null -eq $v) { $v = $script:LintDefaults[$k] }
        $isNum = $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]
        if (-not $isNum -or [Math]::Floor([double]$v) -ne [double]$v -or $v -lt 1) {
            throw (New-DocException 'profile' ('поле профілю "{0}" має бути додатним цілим' -f $script:ProfilePaths[$k]))
        }
        $t[$k] = [int]$v
    }
    @{
        Ctx       = $Ctx
        Root      = $Ctx.Root
        Anchors   = $anchors
        SkillDirs = @($anchors.SkillDirs | ForEach-Object { [System.IO.Path]::GetFullPath($_).Replace('\', '/') })
        T         = $t
        Stats     = @{ files = 0; statements = 0; skills = 0; references = 0; pointers = 0 }
    }
}

function Get-DocSkillsRootOf {
    # Тека скілів, якій належить файл, або $null — файл не скіл.
    param($L, [string]$Path)
    $r = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    foreach ($d in $L.SkillDirs) {
        if ($r -ieq $d -or $r.StartsWith($d + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $d }
    }
    return $null
}

function Find-DocDuplicates {
    # 4. Той самий блок тверджень у двох файлах корпусу — копія моделі.
    param($L, [object[]]$Texts)
    $seen = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $seenOrder = [System.Collections.Generic.List[string]]::new()
    $size = $L.T.LintDuplicateBlock
    foreach ($pair in $Texts) {
        $lines = Get-DocStatementLines -Text $pair.Text
        $L.Stats.statements += $lines.Count
        for ($i = 0; $i + $size -le $lines.Count; $i++) {
            $win = $lines[$i..($i + $size - 1)]
            $key = ($win | ForEach-Object { $_.Line }) -join "`0"
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = [pscustomobject]@{ First = $win[0].Line; Hits = [System.Collections.Generic.List[object]]::new() }
                $seenOrder.Add($key)
            }
            $seen[$key].Hits.Add([pscustomobject]@{ Src = $pair.Src; N = $win[0].N })
        }
    }
    $broken = [System.Collections.Generic.List[string]]::new()
    # На пару файлів друкуємо ПЕРШИЙ збіг: довгий дубль дає стільки вікон, скільки в ньому рядків, і
    # звіт перетворився б на стіну. Отже «одне влучання» не означає «один рядок» — після правки
    # перевірку ганяють ще раз.
    $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $seenOrder) {
        $e = $seen[$key]
        $byFile = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::Ordinal)
        foreach ($h in $e.Hits) { if (-not $byFile.ContainsKey($h.Src)) { $byFile[$h.Src] = $h.N } }
        if ($byFile.Count -lt 2) { continue }
        $places = @($byFile.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Rel = (Get-DocRel -Root $L.Root -Path $_.Key); N = $_.Value } })
        $places = @($places | Sort-Object -Property @{ Expression = { $_.Rel }; Descending = $false }, @{ Expression = { $_.N }; Descending = $false })
        # Ординальний порядок імен: Sort-Object чутливий до культури, а порядок у звіті має бути стабільним.
        $arr = [object[]]$places
        [System.Array]::Sort($arr, [System.Comparison[object]] { param($a, $b) $c = [string]::CompareOrdinal($a.Rel, $b.Rel); if ($c -ne 0) { $c } else { $a.N.CompareTo($b.N) } })
        $pair = $arr[0].Rel + "`0" + $arr[1].Rel
        if (-not $reported.Add($pair)) { continue }
        $where = ($arr | ForEach-Object { "$($_.Rel):$($_.N)" }) -join ', '
        $first = if ($e.First.Length -gt 60) { $e.First.Substring(0, 60) } else { $e.First }
        $broken.Add("$($arr[0].Rel): дубльований блок — ті самі твердження в ${where}: ""${first}…""")
    }
    return , $broken.ToArray()
}

function Find-DocSkillCanon {
    # 5–7. Ліміт SKILL.md, «Зміст» у довгому reference, глибина вказівників.
    param($L, [object[]]$Texts)
    $broken = [System.Collections.Generic.List[string]]::new()
    $sorted = [object[]]@($Texts)
    [System.Array]::Sort($sorted, [System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Src, $b.Src) })
    foreach ($pair in $sorted) {
        $src = $pair.Src
        $sroot = Get-DocSkillsRootOf -L $L -Path $src
        if (-not $sroot) { continue }
        $parts = [System.IO.Path]::GetRelativePath($sroot, [System.IO.Path]::GetFullPath($src)).Replace('\', '/').Split('/')
        $lines = Split-DocLines -Text $pair.Text
        $here = Get-DocRel -Root $L.Root -Path $src
        if ((Get-DocFileNameOf -Path $src) -ceq 'SKILL.md' -and $parts.Count -eq 2) {
            $L.Stats.skills++
            # Ліміт — це кількість РЯДКІВ, а не насиченість: скіл із 490 рядків води зелений.
            if ($lines.Count -gt $L.T.LintSkillMaxLines) { $broken.Add("${here}: рядків $($lines.Count) — ліміт SKILL.md $($L.T.LintSkillMaxLines)") }
            continue
        }
        if ($parts.Count -ne 3 -or $parts[1] -cne 'references') { continue }
        $skill = $parts[0]
        $L.Stats.references++
        $headText = [string]::Join("`n", @($lines | Select-Object -First $L.T.LintContentsHeadLines))
        if ($lines.Count -gt $L.T.LintReferenceMaxLines -and -not $script:RxContentsMark.IsMatch($headText)) {
            $broken.Add("${here}: рядків $($lines.Count) без розділу «Зміст» (ліміт $($L.T.LintReferenceMaxLines); шукали в перших $($L.T.LintContentsHeadLines) рядках)")
        }
        # 7. Один рівень від SKILL.md. Сюди доходять ЛИШЕ файли `<скіл>/references/*.md` — SKILL.md
        #    відсіяно вище, і це межа перевірки, а не оптимізація: маршрутизатор МУСИТЬ називати свій
        #    другий рівень. Усередині reference перехід у сусідній reference веде повз
        #    маршрутизатор незалежно від форми запису. Легальні виходи — док і SKILL.md (свій чи
        #    чужий). Сканується весь текст, разом із код-блоками.
        $tokens = [System.Collections.Generic.List[string]]::new()
        foreach ($m in $script:RxBackticked.Matches($pair.Text)) { $tokens.Add($m.Groups[1].Value) }
        foreach ($m in $script:RxMdLink.Matches($pair.Text)) { $tokens.Add($m.Groups[1].Value) }
        foreach ($raw in $tokens) {
            $token = Format-DocNorm -Token $raw
            if (-not $token.EndsWith('.md', [System.StringComparison]::Ordinal) -or $script:RxHttp.IsMatch($token) -or $script:RxPlaceholder.IsMatch($token)) { continue }
            $target = Resolve-DocDocName -A $L.Anchors -Name $token -Src $src
            if (-not $target -or [System.IO.Path]::GetFullPath($target) -ieq [System.IO.Path]::GetFullPath($src)) { continue }
            $troot = Get-DocSkillsRootOf -L $L -Path $target
            if (-not $troot) { continue }   # док або кореневий канон — легальний вихід із reference
            $tparts = [System.IO.Path]::GetRelativePath($troot, [System.IO.Path]::GetFullPath($target)).Replace('\', '/').Split('/')
            if ($tparts.Count -ne 3 -or $tparts[1] -cne 'references') { continue }   # SKILL.md — легально
            $L.Stats.pointers++
            if ($tparts[0] -cne $skill) { $broken.Add("${here}: ``$token`` — reference іншого скіла ``$($tparts[0])``; заходьте в нього через його SKILL.md") }
            elseif ($script:RxReferencePath.IsMatch($token)) { $broken.Add("${here}: шлях ``$token`` веде на другий рівень нижче SKILL.md") }
            else { $broken.Add("${here}: ``$token`` — сусідній reference; навігація між reference належить ``$skill/SKILL.md``") }
        }
    }
    return , $broken.ToArray()
}

function Test-DocLint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string[]]$Files = @(), [bool]$List = $false)
    $L = New-DocLintChecker -Ctx $Ctx
    $sources = [System.Collections.Generic.List[string]]::new()
    if ($Files.Count -gt 0) {
        foreach ($f in $Files) { $sources.Add((Resolve-DocPath -Path $f -WorkDir $Ctx.WorkDir)) }
    } elseif ($null -ne (Get-DocField -Ctx $Ctx -Key 'LintInclude')) {
        foreach ($p in (Get-DocFilesByGlobs -Ctx $Ctx -Include @(Get-DocFieldList -Ctx $Ctx -Key 'LintInclude') -Exclude @(Get-DocFieldList -Ctx $Ctx -Key 'LintExclude'))) { $sources.Add($p) }
    } else {
        foreach ($p in (Get-DocCorpus -Ctx $Ctx)) { $sources.Add($p) }
    }
    foreach ($f in $sources) {
        if (-not (Test-DocPathExists -Path $f)) { throw (New-DocException 'usage' "немає такого файла: $f") }
    }
    if ($sources.Count -eq 0) {
        return New-DocResult -ErrLines @(Format-DocError -Message 'lint: корпус порожній (перевірте docs.lint.include або docs.anchors.include)') -Code $script:DocExit.NotChecked
    }
    $texts = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $sources) {
        $texts.Add([pscustomobject]@{ Src = $s; Text = [System.IO.File]::ReadAllText($s, [System.Text.UTF8Encoding]::new($false)) })
    }
    $L.Stats.files = $texts.Count
    $broken = [System.Collections.Generic.List[string]]::new()
    $broken.AddRange([string[]](Find-DocDuplicates -L $L -Texts $texts.ToArray()))
    $broken.AddRange([string[]](Find-DocSkillCanon -L $L -Texts $texts.ToArray()))
    $s = $L.Stats
    $out = [System.Collections.Generic.List[string]]::new()
    if ($List) {
        # Мовчазна гілка гірша за порожню: поки «нічого не знайдено» і «сюди навіть не дивились»
        # виглядають однаково, читач добудовує поведінку сам.
        $out.Add("джерел: $($s.files) | рядків-тверджень: $($s.statements) | скілів: $($s.skills) | references: $($s.references) | вказівників reference→reference: $($s.pointers)")
        $dirs = @($L.Anchors.SkillDirs | ForEach-Object { $r = Get-DocRel -Root $L.Root -Path $_; if ($r -eq '.') { '.' } else { $r } })
        $out.Add('теки скілів: ' + $(if ($dirs.Count -gt 0) { $dirs -join ', ' } else { '(немає: задайте docs.skills)' }))
        foreach ($t in $texts) { $out.Add("  · $(Get-DocRel -Root $L.Root -Path $t.Src)") }
    }
    $summary = "файлів $($s.files), рядків-тверджень $($s.statements), скілів $($s.skills), references $($s.references), вказівників ref→ref $($s.pointers)"
    $fileArgs = Format-DocFiles -Files $Files
    if ($broken.Count -gt 0) {
        foreach ($b in $broken) { $out.Add("- $b") }
        $out.Add("doc lint: проблем: $($broken.Count) ($summary)")
        $out.Add("next: виправте рядки вище, потім doc lint$fileArgs")
        return New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Failed
    }
    $out.Add("doc lint: ok ($summary)")
    $out.Add("next: doc anchors$fileArgs")
    New-DocResult -Lines $out.ToArray() -Code $script:DocExit.Ok
}

# --- диспетчер --------------------------------------------------------------------------------

function Get-DocOpt {
    param($Options, [string]$Name)
    if ($null -ne $Options -and $Options.ContainsKey($Name)) { return $Options[$Name] }
    return $null
}

function Invoke-DocCommand {
    <#
    .SYNOPSIS
        Диспетчер підкоманд `doc`: розібрані аргументи -> результат @{ Lines; ErrLines; Code }.
    .DESCRIPTION
        Positional — слова після імені команди (підкоманда або файл і запит). Options — хеш-таблиця
        з ключами Level, In, CaseSensitive, Max, Dead, Code, Docs, Ignore, Only, Path, List (відсутній
        ключ = не задано). Помилка виклику -> код 2, поле профілю відсутнє / порожній корпус -> код 3.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Positional = @(),
        [hashtable]$Options = @{},
        [Parameter(Mandatory)][string]$RepoRoot,
        [hashtable]$Profile = @{},
        [string]$WorkDir
    )
    $ctx = New-DocContext -RepoRoot $RepoRoot -Profile $Profile -WorkDir $WorkDir
    $cmd = if ($Positional.Count -gt 0) { $Positional[0] } else { $null }
    $rest = [string[]]@(if ($Positional.Count -gt 1) { $Positional[1..($Positional.Count - 1)] })
    $maxOpt = Get-DocOpt $Options 'Max'
    $checkMax = {
        if ($null -ne $maxOpt -and -not ((ConvertTo-DocNumber -Value $maxOpt) -gt 0)) { throw (New-DocException 'usage' '-Max має бути додатним числом') }
    }
    $level = {
        $v = Get-DocOpt $Options 'Level'
        if ($null -eq $v) { return $null }
        $n = ConvertTo-DocNumber -Value $v
        if ([double]::IsNaN($n) -or [Math]::Floor($n) -ne $n -or $n -lt 1 -or $n -gt 6) { throw (New-DocException 'usage' '-Level має бути 1..6') }
        return [int]$n
    }
    try {
        switch ($cmd) {
            'find' {
                if ($rest.Count -ne 1) { throw (New-DocException 'usage' 'doc find <regex>') }
                & $checkMax
                return Find-DocText -Ctx $ctx -Pattern $rest[0] -In ([string](Get-DocOpt $Options 'In')) -CaseSensitive ([bool](Get-DocOpt $Options 'CaseSensitive')) -Max $maxOpt
            }
            'anchors' { return Test-DocAnchors -Ctx $ctx -Files $rest }
            'refs' {
                & $checkMax
                return Get-DocRefs -Ctx $ctx -Targets $rest -Dead ([bool](Get-DocOpt $Options 'Dead')) -Max $maxOpt
            }
            'debt' { return Get-DocDebt -Ctx $ctx -Files $rest }
            'history' {
                if ($rest.Count -gt 0) { throw (New-DocException 'usage' 'doc history не приймає файлів') }
                return Get-DocHistory -Ctx $ctx -Code ([bool](Get-DocOpt $Options 'Code')) -Docs ([bool](Get-DocOpt $Options 'Docs')) `
                    -Only ([string](Get-DocOpt $Options 'Only')) -Ignore ([string](Get-DocOpt $Options 'Ignore')) `
                    -Path ([string[]]@(Get-DocOpt $Options 'Path' | Where-Object { $_ })) -Max $maxOpt
            }
            'lint' { return Test-DocLint -Ctx $ctx -Files $rest -List ([bool](Get-DocOpt $Options 'List')) }
            default {
                # `doc <файл> [запит]`: зміст, розділ, рядки замість sed -n.
                if ($cmd -and [System.IO.File]::Exists((Resolve-DocPath -Path $cmd -WorkDir $ctx.WorkDir))) {
                    if ($rest.Count -eq 0) { return Get-DocToc -Ctx $ctx -File $cmd -Level (& $level) }
                    return Get-DocSection -Ctx $ctx -File $cmd -Query ($rest -join ' ')
                }
                throw (New-DocException 'usage' $(if ($cmd) { "невідома команда або немає файла ""$cmd""" } else { 'потрібна команда або файл' }))
            }
        }
    } catch {
        $kind = $null
        if ($_.Exception -is [System.InvalidOperationException]) { $kind = $_.Exception.Data['DocKind'] }
        if ($kind -eq 'usage') {
            return New-DocResult -ErrLines @((Format-DocError -Message $_.Exception.Message), 'usage: doc -Help') -Code $script:DocExit.Usage
        }
        if ($kind -eq 'profile') {
            return New-DocResult -ErrLines @(Format-DocError -Message $_.Exception.Message) -Code $script:DocExit.NotChecked
        }
        throw
    }
}

Export-ModuleMember -Function Invoke-DocCommand, Get-DocUsage, Get-DocHelp, `
    Get-DocToc, Get-DocSection, Find-DocText, Test-DocAnchors, Get-DocRefs, Get-DocDebt, Get-DocHistory, Test-DocLint, `
    New-DocContext, Format-DocError, New-DocResult
