#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/review-pack, modified.
<#
    Пакет рецензії для git-діапазону одним викликом: коміти, stat і дифф із контекстом — в один
    файл. Рецензент отримує шлях, а не будує діапазони руками.

    Логіку тримає функція, а не скрипт команди, бо її кличуть і `review-pack`, і `sdd review`.
    Діф береться як один рядок з \r (див. KitGit): розбір меж файлів, numstat і фенс не
    спотикаються на CRLF, а \r у тілі діфу зберігається.
#>
Set-StrictMode -Version Latest

function Get-KitFenceFor {
    <# Фенс довший за будь-яку серію беквотів у вмісті: дифф markdown-файлів містить ```. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $longest = 0
    foreach ($m in [regex]::Matches($Text, '`+')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
    '`' * [Math]::Max(3, $longest + 1)
}

function Split-KitDiffByFile {
    <# Дифф ділиться на шматки по файлах: кожен починається з `diff --git` на початку рядка. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Diff)
    @([regex]::Split($Diff, '(?m)^(?=diff --git )') | Where-Object { $_.Trim() })
}

function Get-KitDiffChunkFile {
    param([Parameter(Mandatory)][string]$Chunk)
    $m = [regex]::Match($Chunk, '(?m)^diff --git a/(.*?) b/([^\r\n]*)')
    if ($m.Success) { $m.Groups[2].Value.TrimEnd("`r") } else { '?' }
}

function Get-KitLines {
    <# Непорожні рядки виводу git; \r наприкінці (якщо є) відкидається — це імена й числа, не тіло діфу. #>
    param([AllowEmptyString()][string]$Text)
    @(($Text -split "\n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
}

function Write-KitPackFile {
    <# Помилка запису — один рядок, а не стек: агент має знати шлях і причину. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    } catch { throw (New-KitRefusal "не вдалось записати ${Path}: $($_.Exception.Message)") }
}

function New-KitReviewPackage {
    <#
    .SYNOPSIS
        Пише пакет рецензії для base..head і повертає перелік записаних файлів та підсумок.
    .DESCRIPTION
        Лише зміни самої гілки: коли origin/<pr.base> влили в гілку після <Base>, його коміти
        виходять зі списку комітів, а його зміни — з діфу (діф береться від <Base>, злитого з тим
        комітом main). Заголовок про це каже.

        -Branch: base = merge-base голови з origin/<pr.base> (уся гілка, фінальна рецензія перед PR).
        Коди: помилка виклику або невідомий ref — 2; base не предок голови, порожній діапазон — 3
        («не перевірено»: фальшивий пакет рецензент сумлінно «перевірив» би).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Base,
        [string]$Head = 'HEAD',
        [string]$Out,
        [int]$Context = 10,
        [string[]]$Exclude = @(),
        [double]$SplitKb = 0,
        [switch]$Branch
    )
    if ($Context -lt 0) { throw (New-KitUsageError '-Context: невід''ємне ціле') }
    if (-not $Branch -and -not $Base) { throw (New-KitUsageError 'потрібен <base> (або -Branch)') }
    if ($SplitKb -lt 0) { throw (New-KitUsageError '-Split: додатне число КБ') }

    $profile = Get-KitProfile -RepoRoot $Root
    $root = $profile.Root
    $git = { param([string[]]$a) (Invoke-KitGit -Root $root -Arguments $a).Out }
    $try = { param([string[]]$a) Invoke-KitGit -Root $root -Arguments $a -AllowFail }

    # Основна гілка проєкту на origin: її коміти, влиті в гілку, — не зміни гілки.
    $upstream = "origin/$([string](Get-KitProfileValue $profile 'pr.base' -Default 'main'))"
    $upR = & $try @('rev-parse', '--verify', '--quiet', "$upstream^{commit}")
    $upOk = $upR.ExitCode -eq 0
    if ($Branch -and -not $upOk) { throw (New-KitUsageError "-Branch: немає $upstream (git fetch origin?)") }

    $baseRef = $Base
    if ($Branch) {
        $mb = & $try @('merge-base', $upR.Out.Trim(), $Head)
        if ($mb.ExitCode -ne 0) { throw (New-KitNotChecked "-Branch: немає спільного предка $upstream і $Head") }
        $baseRef = $mb.Out.Trim()
    }
    $sha = @{}
    foreach ($pair in @(@('base', $baseRef), @('head', $Head))) {
        $r = & $try @('rev-parse', '--verify', '--quiet', "$($pair[1])^{commit}")
        if ($r.ExitCode -ne 0) { throw (New-KitUsageError "невідомий ref ($($pair[0])): $($pair[1])") }
        $sha[$pair[0]] = $r.Out.Trim()
    }
    $range = "$($sha.base)..$($sha.head)"

    # Діапазон не від BASE (не та гілка) або порожній дає фальшивий пакет — тому «не перевірено».
    $anc = & $try @('merge-base', '--is-ancestor', $sha.base, $sha.head)
    if ($anc.ExitCode -eq 1) { throw (New-KitNotChecked "не перевірено: $baseRef не предок $Head") }
    if ($anc.ExitCode -ne 0) { throw "git merge-base завершився з кодом $($anc.ExitCode): $(($anc.Err -split "\r?\n")[0])" }

    # Гілка влила main після BASE: base..head тягне чужі коміти й зміни. Тоді коміти — без
    # досяжних з main, а дифф — від «BASE + той main» (віртуальний мердж, git merge-tree), тож
    # лишаються зміни гілки й розв'язання конфліктів. Конфлікт у віртуальному мерджі — дифф від
    # того коміту main: показує гілку від розгалуження, і заголовок про це каже.
    $from = $sha.base
    $notMain = @()
    $adjusted = $null
    if ($upOk) {
        $t = & $try @('merge-base', $sha.head, $upR.Out.Trim())
        $T = if ($t.ExitCode -eq 0) { $t.Out.Trim() } else { $null }
        $foreign = if ($T) { [int](& $git @('rev-list', '--count', "$($sha.base)..$T")).Trim() } else { 0 }
        # Голова сама вже в main (рецензія злитої роботи): весь діапазон і є зміни, які рецензують;
        # відсікати «коміти main» тут — порожній пакет.
        if ($foreign -gt 0 -and $T -ne $sha.head) {
            $notMain = @('--not', $T)
            $b7 = $sha.base.Substring(0, 7); $t7 = $T.Substring(0, 7)
            $mt = & $try @('merge-tree', '--write-tree', $sha.base, $T)
            if ($mt.ExitCode -eq 0) {
                $from = ($mt.Out -split "\r?\n")[0].Trim()
                $adjusted = "- Гілка влила ${upstream}: $foreign його комітів виключено; дифф — проти $b7, злитого з $t7"
            } else {
                $from = $T
                $adjusted = "- Гілка влила ${upstream}: $foreign його комітів виключено; $b7 і $t7 конфліктують, тож дифф — проти $t7 і показує також роботу гілки до $baseRef"
            }
        }
    }
    $span = @($from, $sha.head)

    $commits = (& $git (@('log', '--no-color', '--oneline', '--no-decorate', $range) + $notMain)).TrimEnd()
    if (-not $commits) {
        throw (New-KitNotChecked "не перевірено: порожній діапазон $baseRef..$Head$(if ($notMain) { " (лише коміти $upstream)" })")
    }

    $globs = @(@(Get-KitProfileValue $profile 'review.exclude' -Default @()) + @($Exclude) | Where-Object { $_ })
    $pathspec = if ($globs) { @('--', '.') + @($globs | ForEach-Object { ":(exclude,glob)$_" }) } else { @() }
    $allFiles = Get-KitLines (& $git (@('diff', '--name-only') + $span))
    $kept = @(Get-KitLines (& $git (@('diff', '--name-only') + $span + $pathspec)))
    $excluded = @($allFiles | Where-Object { $kept -notcontains $_ })

    $plus = 0; $minus = 0
    foreach ($line in (Get-KitLines (& $git (@('diff', '--numstat') + $span + $pathspec)))) {
        $f = $line -split "`t"
        if ($f[0] -match '^\d+$') { $plus += [int]$f[0] }
        if ($f.Count -gt 1 -and $f[1] -match '^\d+$') { $minus += [int]$f[1] }
    }
    $stat = (& $git (@('diff', '--no-color', '--stat=120') + $span + $pathspec)).TrimEnd()
    $diff = & $git (@('diff', '--no-color', '--no-ext-diff', "-U$Context") + $span + $pathspec)
    $count = @($commits -split "\n").Count
    $base7 = $sha.base.Substring(0, 7); $head7 = $sha.head.Substring(0, 7)

    $header = @(
        "# Пакет рецензії: $base7..$head7",
        '',
        "- Діапазон: ``$baseRef..$Head`` = ``$range``",
        "- Комітів: $count; файлів: $($kept.Count); +$plus / -$minus; контекст: $Context рядків"
    )
    if ($adjusted) { $header += $adjusted }
    $q = [char]96
    $quote = { param($s) "$q$s$q" }
    if ($excluded.Count) { $header += "- Виключено з діфу ($($excluded.Count)): $(($excluded | ForEach-Object { & $quote $_ }) -join ', ')" }
    $commitsBlock = @('', '## Коміти', '', $commits)
    $statFence = Get-KitFenceFor $stat
    $statBlock = @('', '## Змінені файли', '', "${statFence}text", $stat, $statFence)
    $diffBlock = {
        param([string]$Body, [string]$Title)
        $f = Get-KitFenceFor $Body
        @('', $Title, '', "${f}diff", $Body.TrimEnd(), $f, '')
    }

    if ($Out) { $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location).Path $Out } }
    else { $outPath = Join-Path (Get-KitAgentsDir -Name out -RepoRoot $root -Create) "review-$base7-$head7.md" }
    $outPath = [System.IO.Path]::GetFullPath($outPath)
    $whole = (@($header) + $commitsBlock + $statBlock + (& $diffBlock $diff '## Дифф')) -join "`n"

    $written = [System.Collections.Generic.List[object]]::new()
    $addFile = {
        param($Path, $Text)
        $written.Add([pscustomobject]@{
                Path   = $Path
                Kb     = [Math]::Round([System.Text.Encoding]::UTF8.GetByteCount($Text) / 1024, 1)
                Tokens = [int][Math]::Round($Text.Length / 4)
            })
    }
    if ($SplitKb -le 0 -or [System.Text.Encoding]::UTF8.GetByteCount($whole) -le $SplitKb * 1024) {
        Write-KitPackFile -Path $outPath -Text $whole
        & $addFile $outPath $whole
    } else {
        # Межа частини — межа файла: шматок діфу одного файла не розрізаємо, інакше рецензент бачить
        # пів-ханка. Файл, більший за ліміт, іде цілою окремою частиною.
        $limit = $SplitKb * 1024
        $groups = [System.Collections.Generic.List[object]]::new()
        $cur = [System.Collections.Generic.List[string]]::new(); $size = 0
        foreach ($chunk in (Split-KitDiffByFile $diff)) {
            $n = [System.Text.Encoding]::UTF8.GetByteCount($chunk)
            if ($cur.Count -and $size + $n -gt $limit) { $groups.Add($cur); $cur = [System.Collections.Generic.List[string]]::new(); $size = 0 }
            $cur.Add($chunk); $size += $n
        }
        if ($cur.Count) { $groups.Add($cur) }
        $ext = [System.IO.Path]::GetExtension($outPath); if (-not $ext) { $ext = '.md' }
        $stem = $outPath.Substring(0, $outPath.Length - [System.IO.Path]::GetExtension($outPath).Length)
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $path = "$stem-part$($i + 1)$ext"
            $files = @($groups[$i] | ForEach-Object { Get-KitDiffChunkFile $_ })
            $partLine = "- Частина $($i + 1) з $($groups.Count): файлів $($files.Count) — $(($files | ForEach-Object { & $quote $_ }) -join ', ')"
            $lines = @($header) + $partLine + $commitsBlock
            if ($i -eq 0) { $lines += $statBlock }
            $lines += & $diffBlock ($groups[$i] -join '') "## Дифф (частина $($i + 1)/$($groups.Count))"
            $body = $lines -join "`n"
            Write-KitPackFile -Path $path -Text $body
            & $addFile $path $body
        }
    }

    [pscustomobject]@{
        Files      = $written.ToArray()
        Base       = $sha.base
        Head       = $sha.head
        Range      = "$base7..$head7"
        Commits    = $count
        FileCount  = $kept.Count
        Plus       = $plus
        Minus      = $minus
        Excluded   = $excluded
        Parts      = $written.Count
        BaseMerged = [bool]$adjusted
        Upstream   = $upstream
    }
}

Export-ModuleMember -Function New-KitReviewPackage
