# Ported from agent-kit 0.9.1 lib/path-refs.mjs, modified.
#Requires -Version 7
Set-StrictMode -Version Latest

# Шляхи до файлів репо в тексті документа чи плану — одна реалізація для `doc anchors` і всього,
# що перевіряє плани на дрейф. Раніше перевірки розходились: одна бачила лише шляхи в беквотах і
# лінках, інша — і голі, і `file:N` за межею файла; агент, що запустив одну, отримував «ok».

# Розширення шляхів. Оригінальний перелік (веб-стек) доповнено розширеннями 1С і PowerShell: без
# них шлях `src/cf/Catalogs/Номенклатура/Ext/ObjectModule.bsl` не впізнається як шлях.
$script:PathExt = 'ts|tsx|mts|cts|js|jsx|mjs|cjs|sql|md|json|py|sh|yml|yaml|toml|css|bsl|os|xml|mdo|epf|erf|cf|cfe|ps1|psm1'
$script:RootFiles = @('AGENTS.md', 'CLAUDE.md', 'README.md', 'CONTRIBUTING.md', 'package.json', 'tsconfig.json', 'pnpm-workspace.yaml', 'turbo.json')
# План описує й майбутнє: файл під «Create» ще не існує за визначенням — це не дрейф.
$script:RxCreate = [regex]::new('\b(create|new file|add file)\b|створ|новий файл', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$script:RxRelStart = [regex]::new('^\.\.?/')
$script:RegexCache = [System.Collections.Generic.Dictionary[string, regex]]::new([System.StringComparer]::Ordinal)

function Invoke-DocGit {
    <#
    .SYNOPSIS
        git як .NET Process: UTF-8 на виході без перекодування PowerShell (кирилиця в іменах
        файлів), stderr окремо, код виходу — у результаті. Єдиний зовнішній процес `doc`.
    .DESCRIPTION
        `core.quotepath=false` — щоб git не екранував некириличні байти в іменах (без нього
        кириличний шлях прийшов би як "\320\275..." у лапках). Обидва потоки читаються
        асинхронно: на великому виводі `ls-files` читання лише stdout до кінця зависло б на
        заповненому буфері stderr.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in (@('-C', $RepoRoot, '-c', 'core.quotepath=false') + $Arguments)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $errTask.GetAwaiter().GetResult() }
    } finally {
        $proc.Dispose()
    }
}

function Test-DocPathExists {
    # Файл або тека існують. Виняток (недопустимі символи в шляху) — «не існує», не збій.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    try { return ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) } catch { return $false }
}

function Get-PathRefRegex {
    <#
    .SYNOPSIS
        Регулярний вираз шляху: `./x.ts`, `../x.md`, `<корінь>/…/x.ts`, кореневі файли
        (README.md…), з необов'язковим `:N` або `:N-M`.
    .DESCRIPTION
        $Roots — перші сегменти шляхів, які вважаємо шляхами репо. Клас символу шляху — `\w` .NET,
        тобто Юнікодний: кириличні каталоги 1С (`Catalogs/Номенклатура`) входять у шлях. У JS-оригіналі
        `\w` був ASCII, і такі шляхи мовчки пропускались. Межа перед шляхом — lookbehind, а не `\b`:
        `\b` на стику кирилиці й латиниці веде себе інакше, ніж задумано.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots)

    $key = (@($Roots | Sort-Object { $_ } -CaseSensitive) -join "`0")
    $cached = $null
    if ($script:RegexCache.TryGetValue($key, [ref]$cached)) { return $cached }

    $alt = (@($Roots | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $inRepo = ''
    if ($alt) { $inRepo = '|(?:' + $alt + ')/[\w@./-]+\.(?:' + $script:PathExt + ')' }
    $rootFiles = (@($script:RootFiles | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $pattern = '(?<![\w./@:-])((?:\.\.?/)+[\w@./-]+\.(?:' + $script:PathExt + ')' + $inRepo + '|' + $rootFiles + ')(?::([0-9]+)(?:-[0-9]+)?)?(?![\w/-])'
    $re = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $script:RegexCache[$key] = $re
    return $re
}

function Find-PathRef {
    <#
    .SYNOPSIS
        Усі входження шляхів у тексті: список { Ref; File; Line; Create; LineNo }.
    .DESCRIPTION
        `./` і `../` — відносно BaseDir (тека документа), решта — від кореня репо. File — завжди
        з прямими `/`, відносно кореня. Create — рядок каже, що файл буде створено.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Roots,
        [Parameter(Mandatory)][string]$BaseDir
    )
    $re = Get-PathRefRegex -Roots $Roots
    $out = [System.Collections.Generic.List[object]]::new()
    $lines = $Text.Split([char]10)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        foreach ($m in $re.Matches($line)) {
            $g1 = $m.Groups[1].Value
            $file = $g1
            if ($script:RxRelStart.IsMatch($g1)) {
                $abs = [System.IO.Path]::GetFullPath($g1, $BaseDir)
                $file = [System.IO.Path]::GetRelativePath($Root, $abs).Replace('\', '/')
            }
            $out.Add([pscustomobject]@{
                    Ref    = $m.Value
                    File   = $file
                    Line   = if ($m.Groups[2].Success) { [long]$m.Groups[2].Value } else { $null }
                    Create = $script:RxCreate.IsMatch($line)
                    LineNo = $i + 1
                })
        }
    }
    return , $out.ToArray()
}

function Get-TextLineCount {
    # Рядків у файлі: порожній файл — 0, кінцевий `\n` не відкриває нового рядка.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $t = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    if ($t.Length -eq 0) { return 0 }
    $n = $t.Split([char]10).Length
    if ($t.EndsWith("`n", [System.StringComparison]::Ordinal)) { $n-- }
    $n
}

function Get-PathRefState {
    <#
    .SYNOPSIS
        Стан одного посилання: Kind = ok | missing | new (план його створює) | ignored |
        line (номер за межею файла; Total — скільки рядків є).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Ref
    )
    $abs = [System.IO.Path]::Combine($Root, $Ref.File)
    if (-not (Test-DocPathExists -Path $abs)) {
        if ($Ref.Create -and $null -eq $Ref.Line) { return [pscustomobject]@{ Kind = 'new'; Total = 0 } }
        # Ignored-файл (локальний профіль, артефакти) за задумом не лежить у репо.
        $r = Invoke-DocGit -RepoRoot $Root -Arguments @('check-ignore', '-q', '--no-index', $Ref.File)
        if ($r.ExitCode -eq 0) { return [pscustomobject]@{ Kind = 'ignored'; Total = 0 } }
        return [pscustomobject]@{ Kind = 'missing'; Total = 0 }
    }
    if ($null -ne $Ref.Line -and [System.IO.File]::Exists($abs)) {
        $total = Get-TextLineCount -Path $abs
        if ($Ref.Line -gt $total) { return [pscustomobject]@{ Kind = 'line'; Total = $total } }
    }
    [pscustomobject]@{ Kind = 'ok'; Total = 0 }
}

Export-ModuleMember -Function Invoke-DocGit, Test-DocPathExists, Get-PathRefRegex, Find-PathRef, Get-TextLineCount, Get-PathRefState
