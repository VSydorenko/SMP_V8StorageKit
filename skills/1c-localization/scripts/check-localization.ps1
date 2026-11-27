#Requires -Version 7
<#
Перевірка локалізації конфігурацій і розширень 1С (вихідники Designer XML).

Джерело — скіл v8storagekit:1c-localization плагіна v8storagekit (скрипт у його теці scripts/). Копії в
репозиторіях (для CI) не редагувати: правити в скілі плагіна й копіювати заново.

Ловить п'ять вад:
  1. багатомовний рядок метаданих чи форми (синонім, заголовок, підказка) без одної з мов конфігурації;
  2. НСтр без одної з мов конфігурації;
  3. фраза для людини (кирилиця, від двох слів з малої літери) у рядковому літералі BSL поза НСтр;
  4. команда або поле форми без заголовка — платформа показує ім'я ідентифікатора без перекладу;
  5. назва події журналу реєстрації — НСтр без коду мови, тобто мовою сеансу, а не основною мовою
     конфігурації (#std498 п. 2.1, #std784 п. 1). Ловить лише форму ЗаписьЖурналаРегистрации(НСтр("…"))
     з закритою дужкою НСтр у рядку кінця літерала; назву зі змінної чи функції не бачить. Лише для кількох мов.

Мови — ті, що оголошено в Languages/*.xml джерела. Виняток для вади 3 — коментар `// без НСтр: <причина>`
у рядку, де починається літерал (тексти запитів, уривки повідомлень платформи тощо). Назва події журналу
під виняток не підпадає: вона локалізується основною мовою (вада 5).

Запуск: pwsh -NoProfile -File check-localization.ps1 [корінь вихідників ...]
Корінь — тека з Configuration.xml і Languages/ (напр. cf/src, cfe/src). Без аргументів — усі такі теки під
поточною. Код виходу 1, якщо є знахідки.
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Roots = @()
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$CyrPhrase = [regex]::new("[А-Яа-яІіЇїЄєҐґ']{2,} [а-яіїєґ']{2,}")
$Exception = [regex]::new('//\s*без НСтр:')
$NStrLang = [regex]::new("(?:^|;)\s*\|?\s*(\w+)\s*=\s*'")
$NStrPrefix = [regex]::new('(НСтр|NStr)\(\s*$')
$EventNStrPrefix = [regex]::new('(ЗаписьЖурналаРегистрации|WriteLogEvent)\(\s*(НСтр|NStr)\(\s*$')
$NoLangCodeTail = [regex]::new('^\s*\)')
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Read-Text([string]$Path) {
    # Як текстовий режим Python: CRLF і одиночний CR читаються як LF.
    [System.IO.File]::ReadAllText($Path, $Utf8).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Join-Display([string]$Root, [string]$Relative) {
    if ($Root -eq '') { return $Relative }
    if ($Root -match '[\\/]$') { return $Root + $Relative }
    return $Root + '\' + $Relative
}

# Файли під коренем за маскою імені, у порядку за відображуваним шляхом (порядковий порівняльник).
function Get-Files([string]$Root, [string]$Pattern) {
    $rootFull = (Resolve-Path -LiteralPath $(if ($Root -eq '') { '.' } else { $Root })).ProviderPath.TrimEnd('\', '/')
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($i in Get-ChildItem -LiteralPath $rootFull -Recurse -File) {
        if ($i.Name -notlike $Pattern) { continue }
        $rel = $i.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        $rows.Add([pscustomobject]@{ Full = $i.FullName; Display = (Join-Display $Root $rel) })
    }
    $keys = [string[]]@($rows | ForEach-Object { $_.Display })
    $arr = $rows.ToArray()
    [Array]::Sort($keys, $arr, [StringComparer]::Ordinal)
    $arr
}

# Зсуви переведень рядка в тексті (для номера рядка за зсувом).
function Get-LineIndex([string]$Text) {
    $list = [System.Collections.Generic.List[int]]::new()
    $p = -1
    while (($p = $Text.IndexOf("`n", $p + 1, [StringComparison]::Ordinal)) -ge 0) { $list.Add($p) }
    , $list.ToArray()
}

# Номер рядка за зсувом: кількість переведень рядка до зсуву + 1.
function Get-Line([int[]]$Index, [int]$Offset) {
    $pos = [Array]::BinarySearch($Index, $Offset)
    if ($pos -lt 0) { $pos = -$pos - 1 }
    $pos + 1
}

function Get-SortedLangs($Set) {
    $arr = [string[]]@($Set)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    $arr
}

# Подання списку мов у стилі списку Python: ['ru', 'uk'].
function Format-Langs($Set) {
    $arr = Get-SortedLangs $Set
    '[' + (($arr | ForEach-Object { "'$_'" }) -join ', ') + ']'
}

function Get-Missing($Langs, $Found) {
    $res = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Langs))
    $res.ExceptWith([string[]]@($Found))
    , $res
}

function Get-Languages([string]$Root) {
    $codes = [System.Collections.Generic.HashSet[string]]::new()
    $dir = Join-Path $(if ($Root -eq '') { '.' } else { $Root }) 'Languages'
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -File -Filter '*.xml') {
            $m = [regex]::Match((Read-Text $f.FullName), '<LanguageCode>(\w+)</LanguageCode>')
            if ($m.Success) { [void]$codes.Add($m.Groups[1].Value) }
        }
    }
    , $codes
}

function Test-Xml([string]$Root, $Langs, $Out) {
    $block = [regex]::new('<([\w:]+)>\s*((?:<v8:item>.*?</v8:item>\s*)+)</\1>', 'Singleline')
    foreach ($f in @(Get-Files $Root '*.xml')) {
        $text = Read-Text $f.Full
        $idx = $null
        foreach ($m in $block.Matches($text)) {
            $found = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($l in [regex]::Matches($m.Groups[2].Value, '<v8:lang>(\w+)</v8:lang>')) { [void]$found.Add($l.Groups[1].Value) }
            $missing = Get-Missing $Langs $found
            if ($missing.Count -gt 0) {
                if ($null -eq $idx) { $idx = Get-LineIndex $text }
                $line = Get-Line $idx $m.Index
                $Out.Add("$($f.Display):${line}: <$($m.Groups[1].Value)> без мов $(Format-Langs $missing)")
            }
        }
    }
}

# Команда чи поле форми без заголовка: платформа показує ім'я ідентифікатора, тобто без перекладу.
function Test-Forms([string]$Root, $Out) {
    foreach ($f in @(Get-Files $Root 'Form.xml')) {
        $text = Read-Text $f.Full
        $idx = Get-LineIndex $text
        $commands = [regex]::Match($text, '<Commands>(.*?)</Commands>', 'Singleline')
        $base = if ($commands.Success) { $commands.Groups[1].Index } else { 0 }
        $cmdText = if ($commands.Success) { $commands.Groups[1].Value } else { '' }
        foreach ($m in [regex]::Matches($cmdText, '<Command name="([^"]+)"[^>]*>(.*?)</Command>', 'Singleline')) {
            if (-not $m.Groups[2].Value.Contains('<Title>')) {
                $line = Get-Line $idx ($base + $m.Index)
                $Out.Add("$($f.Display):${line}: команда форми $($m.Groups[1].Value) без заголовка")
            }
        }
        $titled = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in [regex]::Matches($text, '<Attribute name="([^"]+)"[^>]*>(?:(?!</Attribute>).)*?<Title>', 'Singleline')) { [void]$titled.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, '<(\w+Field) name="([^"]+)"[^>]*>(.*?)</\1>', 'Singleline')) {
            $body = $m.Groups[3].Value
            $path = [regex]::Match($body, '<DataPath>([^<.]+)')
            if ($path.Success -and -not $body.Contains('<Title>') -and -not $titled.Contains($path.Groups[1].Value) `
                    -and -not $body.Contains('<TitleLocation>None</TitleLocation>')) {
                $line = Get-Line $idx $m.Index
                $Out.Add("$($f.Display):${line}: поле форми $($m.Groups[2].Value) без заголовка (реквізит $($path.Groups[1].Value) теж без нього)")
            }
        }
    }
}

# Рядкові літерали BSL: рядок початку, вміст, текст рядка до літерала, решта рядка після нього.
function Get-Literals([string]$Text) {
    $n = $Text.Length
    $i = 0; $line = 1; $lineStart = 0
    $stops = [char[]]@("`n", '"', '/')
    $res = [System.Collections.Generic.List[object]]::new()
    while ($i -lt $n) {
        $i = $Text.IndexOfAny($stops, $i)
        if ($i -lt 0) { break }
        $c = $Text[$i]
        if ($c -eq "`n") {
            $line++; $lineStart = $i + 1; $i++
        } elseif ($c -eq '/') {
            if ($i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
                $j = $Text.IndexOf("`n", $i, [StringComparison]::Ordinal)
                $i = if ($j -lt 0) { $n } else { $j }
            } else { $i++ }
        } else {
            $startLine = $line
            $prefix = $Text.Substring($lineStart, $i - $lineStart)
            $j = $i + 1
            $buf = [System.Text.StringBuilder]::new()
            while ($j -lt $n) {
                $ch = $Text[$j]
                if ($ch -eq '"') {
                    if ($j + 1 -lt $n -and $Text[$j + 1] -eq '"') { [void]$buf.Append('"'); $j += 2; continue }
                    break
                }
                if ($ch -eq "`n") { $line++; $lineStart = $j + 1 }
                [void]$buf.Append($ch)
                $j++
            }
            $eol = $Text.IndexOf("`n", [Math]::Min($j, $n), [StringComparison]::Ordinal)
            $tailStart = [Math]::Min($j + 1, $n)
            $tailEnd = if ($eol -lt 0) { $n } else { $eol }
            $tail = if ($tailEnd -gt $tailStart) { $Text.Substring($tailStart, $tailEnd - $tailStart) } else { '' }
            $res.Add([pscustomobject]@{ Line = $startLine; Start = $i; Value = $buf.ToString(); Prefix = $prefix; Tail = $tail })
            $i = $j + 1
        }
    }
    $res.ToArray()
}

# Подання рядка в стилі repr Python: лапки й екранування.
function Format-Repr([string]$s) {
    $q = "'"
    if ($s.Contains("'") -and -not $s.Contains('"')) { $q = '"' }
    $e = $s.Replace('\', '\\').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
    if ($q -eq "'") { $e = $e.Replace("'", "\'") }
    # Непечатні символи (nbsp, керівні, формату) — як \xNN чи \uNNNN, як у repr.
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $e.ToCharArray()) {
        $cat = [char]::GetUnicodeCategory($ch)
        $bad = $cat -in 'Control', 'Format', 'Surrogate', 'OtherNotAssigned', 'PrivateUse', 'LineSeparator', 'ParagraphSeparator' -or ($cat -eq 'SpaceSeparator' -and $ch -ne ' ')
        if (-not $bad) { [void]$sb.Append($ch) }
        elseif ([int]$ch -lt 256) { [void]$sb.Append('\x' + ([int]$ch).ToString('x2')) }
        else { [void]$sb.Append('\u' + ([int]$ch).ToString('x4')) }
    }
    $q + $sb.ToString() + $q
}

function Test-Bsl([string]$Root, $Langs, $Out) {
    foreach ($f in @(Get-Files $Root '*.bsl')) {
        $text = Read-Text $f.Full
        foreach ($lit in @(Get-Literals $text)) {
            if ($NStrPrefix.IsMatch($lit.Prefix)) {
                $found = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($m in $NStrLang.Matches($lit.Value)) { [void]$found.Add($m.Groups[1].Value) }
                $missing = Get-Missing $Langs $found
                if ($missing.Count -gt 0) { $Out.Add("$($f.Display):$($lit.Line): НСтр без мов $(Format-Langs $missing)") }
                # Текст перед літералом через переведення рядка: виклик буває розбитий на рядки.
                $from = [Math]::Max(0, $lit.Start - 200)
                $before = $text.Substring($from, $lit.Start - $from)
                if ($Langs.Count -gt 1 -and $EventNStrPrefix.IsMatch($before) -and $NoLangCodeTail.IsMatch($lit.Tail)) {
                    $Out.Add("$($f.Display):$($lit.Line): назва події журналу мовою сеансу: потрібен НСтр(…, КодОсновногоЯзыка)")
                }
            } elseif ($CyrPhrase.IsMatch($lit.Value) -and -not $Exception.IsMatch($lit.Tail)) {
                $v = $lit.Value
                if ($v.Length -gt 70) { $v = $v.Substring(0, 70) }
                $Out.Add("$($f.Display):$($lit.Line): текст поза НСтр: $(Format-Repr $v)")
            }
        }
    }
}

# Без аргументів: усі теки з Configuration.xml і Languages/ під поточною, крім build, temp тощо.
function Find-Roots {
    $skip = @('build', '.build', 'temp', 'node_modules', '.git')
    $cwd = (Get-Location).ProviderPath.TrimEnd('\', '/')
    $found = foreach ($c in Get-ChildItem -LiteralPath $cwd -Recurse -File) {
        if ($c.Name -ne 'Configuration.xml') { continue }
        $rel = $c.FullName.Substring($cwd.Length).TrimStart('\', '/')
        $parts = $rel -split '[\\/]'
        $dir = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '\') } else { '' }
        $langDir = Join-Path $(if ($dir -eq '') { $cwd } else { Join-Path $cwd $dir }) 'Languages'
        if ((Test-Path -LiteralPath $langDir -PathType Container) -and -not ($parts | Where-Object { $skip -contains $_ })) { $dir }
    }
    $arr = [string[]]@($found)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    $arr
}

$roots = @($Roots | Where-Object { $null -ne $_ })
if ($roots.Count -eq 0) { $roots = @(Find-Roots) }
$out = [System.Collections.Generic.List[string]]::new()
$summary = [System.Collections.Generic.List[string]]::new()
foreach ($root in $roots) {
    $langs = Get-Languages $root
    if ($langs.Count -eq 0) { continue }
    $before = $out.Count
    Test-Xml $root $langs $out
    Test-Forms $root $out
    Test-Bsl $root $langs $out
    $summary.Add("$root [$((Get-SortedLangs $langs) -join ', ')]: $($out.Count - $before)")
}
foreach ($o in $out) { Write-Output $o }
foreach ($s in $summary) { Write-Output $s }
Write-Output "Знахідок: $($out.Count)"
if ($out.Count -gt 0) { exit 1 } else { exit 0 }
