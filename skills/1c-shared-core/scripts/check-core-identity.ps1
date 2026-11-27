#Requires -Version 7
<#
Перевірка ідентичності спільного ядра рішення 1С у кількох редакціях (вихідники Designer XML).

Джерело — скіл v8storagekit:1c-shared-core плагіна v8storagekit (скрипт у його теці scripts/). Копії в
репозиторіях (для CI) не редагувати: правити в скілі плагіна й копіювати заново.

Перелік (-List) — текстовий файл, рядок на перевірку: <перевірка> <шлях відносно кореня редакції> [аргумент].
Порожні рядки й рядки з # пропускаються. Перевірки:
  uuid      — UUID кореневого об'єкта XML однаковий в усіх редакціях;
  bytes     — файл побайтово однаковий в усіх редакціях;
  function  — текст процедури чи функції <аргумент> побайтово однаковий: коментарі й директиви над
              оголошенням і тіло до КонецПроцедуры/КонецФункции;
  child     — UUID дочірнього елемента (реквізит, ресурс) з іменем <аргумент> однаковий в усіх редакціях;
  borrowed  — ExtendedConfigurationObject запозиченого об'єкта кожної редакції дорівнює UUID того самого
              об'єкта в базовій конфігурації цієї редакції (-Bases, у порядку -Editions).

Запуск:
  pwsh -NoProfile -File check-core-identity.ps1 -List <перелік> -Editions <корінь1>,<корінь2>[,...] [-Bases <база1>,<база2>]
Корінь редакції — тека вихідників розширення (cfe/src); база — тека вихідників базової конфігурації (cf/src).
Кожна редакція порівнюється з першою.

Код виходу: 0 — розбіжностей немає; 1 — є розбіжності; 2 — помилка виклику чи переліку.
Контроль, що перевірка вміє впасти: копія дерева редакції з одним зміненим байтом у файлі з переліку дає 1.
#>
param(
    [string]$List = '',
    [string[]]$Editions = @(),
    [string[]]$Bases = @()
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Stop-Call([string]$Message) {
    [Console]::Error.WriteLine("check-core-identity: ERROR $Message")
    exit 2
}

# -Editions a,b з pwsh -File приходить одним рядком: ділимо самі.
function Split-Arg([string[]]$Values) {
    , [string[]]@($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

$editions = Split-Arg $Editions
$bases = Split-Arg $Bases
if ($List -eq '' -or -not (Test-Path -LiteralPath $List -PathType Leaf)) { Stop-Call "перелік не знайдено: '$List'" }
if ($editions.Count -lt 2) { Stop-Call 'потрібно щонайменше дві редакції в -Editions' }
foreach ($e in $editions) { if (-not (Test-Path -LiteralPath $e -PathType Container)) { Stop-Call "корінь редакції не знайдено: '$e'" } }
if ($bases.Count -gt 0 -and $bases.Count -ne $editions.Count) { Stop-Call '-Bases має стільки ж тек, скільки -Editions, у тому самому порядку' }

function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path, $Utf8) }

function Get-RootUuid([string]$Path) {
    $m = [regex]::Match((Read-Text $Path), '<MetaDataObject[^>]*>\s*<\w+ uuid="([0-9a-f-]{36})"')
    if (-not $m.Success) { throw "немає uuid кореневого елемента: $Path" }
    $m.Groups[1].Value
}

function Get-ChildUuid([string]$Path, [string]$Name) {
    $m = [regex]::Match((Read-Text $Path), '<\w+ uuid="([0-9a-f-]{36})">\s*<Properties>\s*<Name>' + [regex]::Escape($Name) + '</Name>')
    if (-not $m.Success) { throw "немає елемента ${Name}: $Path" }
    $m.Groups[1].Value
}

function Get-ExtendedUuid([string]$Path) {
    $m = [regex]::Match((Read-Text $Path), '<ExtendedConfigurationObject>([0-9a-f-]{36})</ExtendedConfigurationObject>')
    if (-not $m.Success) { throw "немає ExtendedConfigurationObject: $Path" }
    $m.Groups[1].Value
}

# Текст методу: рядки разом із CR, тож порівняння рядків тут — порівняння байтів UTF-8.
function Get-MethodText([string]$Path, [string]$Name) {
    $lines = (Read-Text $Path) -split "`n"
    $head = [regex]::new('^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+' + [regex]::Escape($Name) + '\s*\(', 'IgnoreCase')
    $starts = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($head.IsMatch($lines[$i])) { $i } })
    if ($starts.Count -ne 1) { throw "метод $Name знайдено $($starts.Count) раз: $Path" }
    $begin = $starts[0]
    while ($begin -gt 0 -and $lines[$begin - 1] -match '^\s*(//|&)') { $begin-- }
    $end = $starts[0]
    $tail = [regex]::new('^\s*(?:КонецПроцедуры|КонецФункции)\b', 'IgnoreCase')
    while (-not $tail.IsMatch($lines[$end])) {
        $end++
        if ($end -ge $lines.Count) { throw "немає кінця методу ${Name}: $Path" }
    }
    $lines[$begin..$end] -join "`n"
}

function Get-Value([string]$Kind, [string]$Root, [string]$Rel, [string]$Arg) {
    $path = Join-Path $Root $Rel
    switch ($Kind) {
        'uuid' { Get-RootUuid $path }
        'bytes' { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($path))) }
        'function' { Get-MethodText $path $Arg }
        'child' { Get-ChildUuid $path $Arg }
    }
}

$known = @('uuid', 'bytes', 'function', 'child', 'borrowed')
$checked = 0; $diffs = 0
foreach ($raw in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $List).ProviderPath, $Utf8)) {
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $parts = @($line -split '\s+')
    $kind = $parts[0]
    if ($known -notcontains $kind -or $parts.Count -lt 2) { Stop-Call "невідома перевірка чи неповний рядок переліку: $raw" }
    $rel = $parts[1]
    $arg = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    if ($kind -in 'function', 'child' -and $arg -eq '') { Stop-Call "перевірці $kind потрібне ім'я: $raw" }
    if ($kind -eq 'borrowed' -and $bases.Count -eq 0) { Stop-Call "перевірці borrowed потрібні -Bases: $raw" }
    $checked++
    try {
        if ($kind -eq 'borrowed') {
            $pairs = for ($i = 0; $i -lt $editions.Count; $i++) {
                $ext = Get-ExtendedUuid (Join-Path $editions[$i] $rel)
                $own = Get-RootUuid (Join-Path $bases[$i] $rel)
                [pscustomobject]@{ Ok = ($ext -eq $own); Text = "$ext / $own" }
            }
            $ok = -not ($pairs | Where-Object { -not $_.Ok })
            $detail = ($pairs | ForEach-Object { $_.Text }) -join '; '
        } else {
            $values = @($editions | ForEach-Object { Get-Value $kind $_ $rel $arg })
            $ok = -not ($values | Select-Object -Skip 1 | Where-Object { $_ -cne $values[0] })
            $detail = if ($kind -in 'uuid', 'child') { $values -join ' / ' } elseif ($kind -eq 'function') { $arg } else { 'sha256' }
        }
    } catch {
        $ok = $false
        $detail = $_.Exception.Message
    }
    if (-not $ok) { $diffs++ }
    Write-Output ("{0} {1,-9} {2}  [{3}]" -f $(if ($ok) { 'OK  ' } else { 'DIFF' }), $kind, $rel, $detail)
}
Write-Output "перевірок: $checked, розбіжностей: $diffs"
if ($diffs -gt 0) { exit 1 } else { exit 0 }
