# Ported from agent-kit 0.9.1 lib/markdown.mjs, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Розбір markdown для `doc`: заголовки поза код-блоками, межі розділів, slug GitHub. Окремий
# модуль, бо ті самі заголовки потрібні і змісту, і пошуку, і перевірці якорів — розбіжність між
# ними дала б «розділ є в toc, але якір мертвий».
#
# Рядки в цьому модулі — завжди з нормалізованим кінцем (`\n`): читач файла замінює `\r\n` до
# виклику. Вхід — текст, не шлях: модуль нічого не читає з диска.

# ATX-заголовок: до трьох пробілів відступу, 1–6 `#`, пробіл, текст. Setext-заголовки (`===`/`---`
# під рядком) свідомо не підтримано: у спеках їх немає, а `---` під абзацом легко сплутати з
# роздільником.
$script:RxAtx        = [regex]::new('^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$')
$script:RxFenceOpen  = [regex]::new('^ {0,3}(`{3,}|~{3,})')
$script:RxFenceClose = [regex]::new('^ {0,3}[`~]+[ \t]*$')
$script:RxHeadTail   = [regex]::new('[ \t]+#+[ \t]*$')
$script:RxHeadHashes = [regex]::new('^#+$')

function Get-MdScannedLines {
    <#
    .SYNOPSIS
        Рядки файла з позначкою «у код-блоці»: список @{ Line; Code }.
    .DESCRIPTION
        Закриває блок лише фенс того самого символу й не коротший за відкривальний — як у
        CommonMark; інакше ``` усередині ~~~ закривав би блок, і `# коментар` з bash ставав би
        заголовком.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = $Text.Split([char]10)
    $out = [System.Collections.Generic.List[object]]::new($lines.Length)
    $fence = $null
    foreach ($line in $lines) {
        $m = $script:RxFenceOpen.Match($line)
        if ($null -ne $fence) {
            $out.Add([pscustomobject]@{ Line = $line; Code = $true })
            # Закривальний фенс не має інфо-рядка: лише символи фенса й пробіли.
            if ($m.Success) {
                $f = $m.Groups[1].Value
                if ($f[0] -eq $fence[0] -and $f.Length -ge $fence.Length -and $script:RxFenceClose.IsMatch($line)) { $fence = $null }
            }
            continue
        }
        if ($m.Success) {
            $fence = $m.Groups[1].Value
            $out.Add([pscustomobject]@{ Line = $line; Code = $true })
            continue
        }
        $out.Add([pscustomobject]@{ Line = $line; Code = $false })
    }
    return , $out.ToArray()
}

function Get-MdHeadingText {
    # Текст заголовка без закривальних `#` (`## Foo ##` -> `Foo`).
    param([AllowEmptyString()][string]$Raw = '')
    $t = $script:RxHeadTail.Replace($Raw, '')
    $t = $script:RxHeadHashes.Replace($t, '')
    $t.Trim()
}

function Get-MdHeadings {
    <#
    .SYNOPSIS
        Заголовки файла: { Level; Text; Line (з 1); Start; End; Bytes }.
    .DESCRIPTION
        End — останній рядок розділу разом із підрозділами (до наступного заголовка того ж або
        вищого рівня). Bytes — розмір цих рядків у UTF-8 (з кінцем рядка).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $scanned = Get-MdScannedLines -Text $Text
    $total = $scanned.Count
    # Префіксні суми байтів: розмір розділу — різниця двох значень, без повторного обходу.
    $prefix = [long[]]::new($total + 1)
    for ($i = 0; $i -lt $total; $i++) {
        $prefix[$i + 1] = $prefix[$i] + [System.Text.Encoding]::UTF8.GetByteCount($scanned[$i].Line) + 1
    }
    $heads = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $total; $i++) {
        if ($scanned[$i].Code) { continue }
        $m = $script:RxAtx.Match($scanned[$i].Line)
        if ($m.Success) {
            $heads.Add([pscustomobject]@{
                    Level = $m.Groups[1].Length
                    Text  = Get-MdHeadingText -Raw $m.Groups[2].Value
                    Line  = $i + 1
                    Start = 0
                    End   = 0
                    Bytes = [long]0
                })
        }
    }
    for ($i = 0; $i -lt $heads.Count; $i++) {
        $h = $heads[$i]
        $next = $null
        for ($j = $i + 1; $j -lt $heads.Count; $j++) {
            if ($heads[$j].Level -le $h.Level) { $next = $heads[$j]; break }
        }
        $h.Start = $h.Line
        $h.End = if ($next) { $next.Line - 1 } else { $total }
        # Хвостовий порожній рядок файла (після останнього \n) не рахуємо.
        if (-not $next -and $scanned[$total - 1].Line -ceq '') { $h.End = [Math]::Max($h.Start, $total - 1) }
        $h.Bytes = $prefix[$h.End] - $prefix[$h.Start - 1]
    }
    return , $heads.ToArray()
}

# Кроки «як показує GitHub»: розмітка інлайн-коду, посилань, картинок, HTML-тегів, акцентів.
$script:RenderSteps = @(
    , @([regex]::new('!\[([^\]]*)\]\([^)]*\)'), '$1')
    , @([regex]::new('\[([^\]]*)\]\([^)]*\)'), '$1')
    , @([regex]::new('\[([^\]]*)\]\[[^\]]*\]'), '$1')
    , @([regex]::new('<[^>]+>'), '')
    , @([regex]::new('`+([^`]*)`+'), '$1')
    , @([regex]::new('\\([!-/:-@\[-`{-~])'), '$1')
    # `_акцент_` зникає при рендері, а `snake_case` лишається: прибираємо `_` лише на межі слова.
    , @([regex]::new('(^|[^\p{L}\p{N}])_+(?=\S)'), '$1')
    , @([regex]::new('(\S)_+(?=$|[^\p{L}\p{N}])'), '$1')
    , @([regex]::new('&[a-z]+;|&#[0-9]+;', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase), '')
)
$script:RxSlugDrop = [regex]::new('[^\p{L}\p{M}\p{N}\p{Pc}\- ]')

function Get-MdRenderedText {
    # Текст заголовка так, як його показує GitHub. Slug рахується від показаного тексту, а не від
    # сирого markdown.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    $t = $Raw
    foreach ($step in $script:RenderSteps) { $t = $step[0].Replace($t, $step[1]) }
    $t
}

function ConvertTo-MdSlug {
    <#
    .SYNOPSIS
        Алгоритм `github-slugger`: нижній регістр, викинути все, крім літер, знаків, цифр, `_`,
        `-` і пробілу; пробіли -> `-`. Кирилиця — літери, тож лишається.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = (Get-MdRenderedText -Raw $Text).ToLowerInvariant()
    $t = $script:RxSlugDrop.Replace($t, '')
    $t.Replace(' ', '-')
}

function Get-MdHeadingSlugs {
    # Slug-и всіх заголовків файла з суфіксами дублів `-1`, `-2`, як у GitHub.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Heads)
    # Ординальний словник: ключі-slug вже в нижньому регістрі, але хеш-таблиця PowerShell була б
    # нечутливою до регістру — зайве припущення.
    $seen = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $Heads) {
        $base = ConvertTo-MdSlug -Text $h.Text
        $slug = $base
        while ($seen.ContainsKey($slug)) {
            $n = $seen[$base] + 1
            $seen[$base] = $n
            $slug = "$base-$n"
        }
        $seen[$slug] = 0
        $out.Add($slug)
    }
    return , $out.ToArray()
}

function Test-MdNumberMatch {
    <#
    .SYNOPSIS
        `§6.4` відповідає «6.4 …», «6.4. …», «6.4) …», «§6.4 …», але не «6.40 …» і не «6.4.1 …».
    .DESCRIPTION
        Інакше `§6` був би неоднозначним із кожним підрозділом 6.x. Без урахування регістру:
        `§10A` знаходить «10a. …»; «10» не збігається з «10a», бо після номера має бути крапка,
        пробіл, дужка або кінець.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Number
    )
    $pattern = '^(?:§\s*)?' + [regex]::Escape($Number) + '(?:\.?(?:\s|$)|\))'
    [regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

Export-ModuleMember -Function Get-MdScannedLines, Get-MdHeadings, Get-MdRenderedText, ConvertTo-MdSlug, Get-MdHeadingSlugs, Test-MdNumberMatch
