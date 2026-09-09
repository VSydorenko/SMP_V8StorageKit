#Requires -Version 7
Set-StrictMode -Version Latest

# Показується замість порожнього User: коли Task 2 (Read-StorageReport) не зміг
# розібрати мітку "Пользователь:" у звіті сховища — версія лишається без автора.
$script:BlankUserPlaceholder = '<версія без автора: звіт пошкоджено, перевірте в Конфігураторі>'

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

            # Ключ лінивий, а якір пошти жадібний до кінця рядка — коли два файли
            # AUTHORS зʼєднали докупи (одна ситуація, яку сама ця довідка і радить: розділ 7
            # docs/migration/legacy-gitsync-repo.md, «обʼєднайте вручну» — колишній repo-migration,
            # Task 6 B5), а перший не мав завершального
            # порожнього рядка, останній рядок першого файлу зливається з першим рядком
            # другого. Результат парситься як ОДИН запис, а $name поглинає хвіст першого
            # рядка разом з "<", ">" і "=" другого — символи, яких у справжньому git-імені
            # не буває. Мовчазне прийняття такого запису — та сама категорія тихої помилки
            # авторства, від якої вже захищає дублікат-перевірка нижче, тільки непомітніша:
            # тут навіть немає видимого дубліката ключа, який впав би в очі.
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
                Email = $Matches['mail'].Trim()
            }

            # Мовчазне перезаписування ($map[$key] = ...) ховало б випадок, коли той самий
            # логін сховища трапляється двічі з РІЗНИМИ git-особами — цілком реальний сценарій
            # після злиття AUTHORS при міграції репозиторію (docs/migration/legacy-gitsync-repo.md
            # тут же й радить користувачу таке злиття). Тоді кожна версія цього користувача комітилась би під
            # тим, хто випадково опинився нижче у файлі — та сама категорія тихої помилки
            # авторства, якій уже не дає статись Get-UnknownAuthors.
            if ($map.ContainsKey($key)) {
                $existing = $map[$key]
                if ($existing.Name -ne $entry.Name -or $existing.Email -ne $entry.Email) {
                    throw "Користувач сховища '$key' зустрічається в $Path більше одного разу з " +
                          "різними git-особами: «$($existing.Name) <$($existing.Email)>» і " +
                          "«$($entry.Name) <$($entry.Email)>». Залиште в файлі один правильний " +
                          "рядок для цього логіна."
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$StorageUser
    )

    if ([string]::IsNullOrWhiteSpace($StorageUser)) {
        throw "Версія сховища не має зафіксованого автора (поле User порожнє). " +
              "Звіт сховища, ймовірно, обрізаний або пошкоджений — перевірте цю версію " +
              "в Конфігураторі вручну."
    }

    if ($Map.ContainsKey($StorageUser)) { return $Map[$StorageUser] }

    throw "Користувача сховища '$StorageUser' немає у файлі AUTHORS. " +
          "Додайте рядок «$StorageUser=Ім'я <пошта>» і повторіть запуск."
}

function Get-UnknownAuthors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$StorageUsers
    )

    $normalized = $StorageUsers | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { $script:BlankUserPlaceholder } else { $_ }
    }

    , @($normalized | Sort-Object -Unique | Where-Object { -not $Map.ContainsKey($_) })
}

Export-ModuleMember -Function Read-AuthorMap, Resolve-Author, Get-UnknownAuthors
