#Requires -Version 7
Set-StrictMode -Version Latest

function Read-AuthorMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Файл мапінгу авторів не знайдено: $Path"
    }

    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^(?<key>.+?)=(?<name>.+?)\s*<(?<mail>[^>]+)>\s*$') {
            $key = $Matches['key'].Trim()
            $name = $Matches['name'].Trim()
            # Пошта — до перевірки форми ключа: -match/-notmatch нижче перезаписують $Matches.
            $mail = $Matches['mail'].Trim()

            # Рядок на версію: <ключ джерела>#<версія>. '#' у ключі без
            # числа після — майже напевно описка (base#v69), а не логін сховища: мовчки прийнятий,
            # такий рядок ніколи б не спрацював, і версія пішла б під логін.
            if ($key.Contains('#') -and $key -notmatch '^.+#[1-9]\d*$') {
                throw "Рядок '$key' у $Path містить '#', але не має форми <ключ джерела>#<версія> (наприклад base#69). " +
                      "Законні форми рядка: <логін сховища>=Ім'я <пошта> і <ключ джерела>#<версія>=Ім'я <пошта>, " +
                      'де ключ джерела — з маніфесту, а версія — число, номер версії сховища.'
            }

            # Ключ лінивий, а якір пошти жадібний: коли два файли AUTHORS зʼєднали докупи
            # без завершального рядка,
            # два записи зливаються в один, і $name поглинає "<", ">" і "=" — у справжньому
            # git-імені їх не буває. Мовчазне прийняття — тиха помилка авторства.
            if ($name -match '[<>=]') {
                throw "Рядок користувача сховища '$key' у $Path розпізнався з підозрілим " +
                      "іменем «$name» — воно містить <, > або =, чого в справжньому " +
                      "git-імені не буває. Найімовірніша причина: два файли AUTHORS " +
                      "зʼєднали докупи, а перший не мав завершального порожнього рядка, " +
                      "тож його останній рядок склеївся з першим рядком другого файлу. " +
                      "Перевірте кінець файлу перед рядком '$key' і розділіть їх порожнім " +
                      "рядком."
            }

            $entry = [pscustomobject]@{
                Name  = $name
                Email = $mail
            }

            # Мовчазне перезаписування сховало б той самий логін з РІЗНИМИ git-особами (реально після
            # злиття AUTHORS): версії комітились би під тим, хто нижче у файлі — тиха помилка авторства.
            if ($map.ContainsKey($key)) {
                $existing = $map[$key]
                if ($existing.Name -ne $entry.Name -or $existing.Email -ne $entry.Email) {
                    throw "Ключ '$key' зустрічається в $Path більше одного разу з " +
                          "різними git-особами: «$($existing.Name) <$($existing.Email)>» і " +
                          "«$($entry.Name) <$($entry.Email)>». Залиште в файлі один правильний " +
                          "рядок для цього ключа."
                }
            }

            $map[$key] = $entry
        }
    }
    $map
}

function Resolve-Author {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StorageUser,
        [string]$SourceKey,
        [Nullable[int]]$Version
    )

    # Рядок на версію важливіший за рядок на логін і рятує версію з
    # порожнім User. Регістр ключа джерела — як у мапи (hashtable регістронечутливий), як і в маніфесті.
    if ($SourceKey -and $null -ne $Version -and $Map.ContainsKey("$SourceKey#$Version")) { return $Map["$SourceKey#$Version"] }

    if ([string]::IsNullOrWhiteSpace($StorageUser)) {
        throw "Версія сховища не має зафіксованого автора (поле User порожнє). " +
              "Звіт сховища, ймовірно, обрізаний або пошкоджений — перевірте цю версію " +
              "в Конфігураторі вручну."
    }

    if ($Map.ContainsKey($StorageUser)) { return $Map[$StorageUser] }

    throw "Користувача сховища '$StorageUser' немає у файлі AUTHORS. " +
          "Додайте рядок «$StorageUser=Ім'я <пошта>» і повторіть запуск."
}

function Get-KitUnattributedVersions {
    <#
    .SYNOPSIS
        Версії без автора: немає ні рядка <ключ>#<версія>, ні рядка на логін.
        Спільний логін навмисно не вноситься в AUTHORS — тоді кожна його версія потрапляє сюди
        й чекає рядка на версію, а не отримує одну особу мовчки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Versions
    )
    , @($Versions | Where-Object {
        -not $Map.ContainsKey("$SourceKey#$($_.Version)") -and
        ([string]::IsNullOrWhiteSpace($_.User) -or -not $Map.ContainsKey($_.User))
    })
}

Export-ModuleMember -Function Read-AuthorMap, Resolve-Author, Get-KitUnattributedVersions
