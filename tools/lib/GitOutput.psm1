#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — та сама конвенція, що в решті lib-модулів: не перезавантажувати вже наявний
# глобальний TreeCompare. Get-KitOriginGap бере звідти Invoke-KitGitProcess.
Import-Module "$PSScriptRoot/TreeCompare.psm1"

function Split-GitEolNoise {
    <#
    .SYNOPSIS
        Розділяє вивід "git add" на видимі рядки й приховані попередження про конверсію
        кінців рядків.
    .DESCRIPTION
        До версії 0.6.0 шаблон .gitattributes ніс "* text=auto eol=crlf", і кожен
        "git add" щойно вивантаженого Designer XML друкував десятки попереджень
        "LF will be replaced by CRLF" — на реплеї довгого хвоста це сотні рядків, під
        якими губився корисний вивід. Тому storage-sync.ps1 їх фільтрував.

        Під чинною політикою (docs/text-policy.md: -text на деревах, які пише платформа)
        таких попереджень на вихідниках бути не має ВЗАГАЛІ. Тому кількість прихованого
        повертається окремо: викликач друкує її як сигнал, що політику в цьому
        репозиторії або зламано, або ще не мігровано. Фільтр без лічильника глушив би
        рівно той сигнал, заради якого політику й міняли.

        Прибирається лише ця відома форма; будь-що інше в stderr "git add" — реальний
        сигнал і лишається видимим.
    .EXAMPLE
        $r = Split-GitEolNoise -Line (git -C $repo add -A -- $Product 2>&1)
        $r.Kept | ForEach-Object { Write-Host $_ }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Line
    )

    $pattern = "^warning: in the working copy of '.+', " +
               "(LF will be replaced by CRLF|CRLF will be replaced by LF) " +
               "the next time Git touches it$"

    $all  = @($Line | Where-Object { $null -ne $_ })
    $kept = @($all | Where-Object { $_.ToString() -notmatch $pattern })

    [pscustomobject]@{
        Kept       = $kept
        Suppressed = $all.Count - $kept.Count
    }
}

function Test-GitTextPolicy {
    <#
    .SYNOPSIS
        Чи виведено дерево вихідників з-під конверсії кінців рядків (-text).
    .DESCRIPTION
        Правило `-text` у .gitattributes прив'язане до ШЛЯХУ (`**/cfe/src/**`), а
        sourcePath у storage.json — конфігурований. У репозиторії з нетиповим
        sourcePath вихідники лишаються під загальним `* text=auto`, git знову
        конвертує їх на checkout, і дефект, заради якого політику й міняли, тихо
        повертається. `git status` при цьому чистий завжди — побачити це можна лише
        round-trip'ом через платформу (docs/text-policy.md).

        Перевірка питає САМ git, а не розбирає .gitattributes: `git check-attr`
        застосовує ту саму логіку пріоритетів правил, що й checkout, включно з
        порядком рядків і перекриттям. Відповідь `text: unset` означає, що діє `-text`.

        Шлях може ще не існувати — check-attr працює з правилами, не з файлами.
    .EXAMPLE
        if (-not (Test-GitTextPolicy -RepoRoot $repoRoot -Path 'Продукт/cfe/src')) { ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    # Довільне ім'я файлу під теками: правила виду "**/cfe/src/**" збігаються з
    # вмістом теки, а не з нею самою, тож питати треба про файл усередині.
    $probe = ($Path -replace '\\', '/').TrimEnd('/') + '/Configuration.xml'

    $out = git -C $RepoRoot check-attr text -- $probe 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git check-attr завершився з кодом ${LASTEXITCODE}: $out"
    }

    # Формат відповіді: "<шлях>: text: <значення>"
    [bool]($out -match ':\s*text:\s*unset\s*$')
}

function Get-KitOriginGap {
    <#
    .SYNOPSIS
        Розходження локальної гілки з origin/<гілка> — БЕЗ мережі (спека 2026-09-17 §6).
    .DESCRIPTION
        Читає лише те, що вже є локально (refs/remotes). Мережу чіпає викликач, і лише там, де
        це дозволено: session-check працює під стелею часу хука старту сесії й fetch не робить.

        Відсутність remote чи remote-tracking гілки — легальний стан (репозиторій без origin,
        гілка ще не пушена), а не помилка: HasRemote=$false і нулі.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch)

    $none = [pscustomobject]@{ HasRemote = $false; Behind = 0; Ahead = 0 }
    $ref  = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Branch")
    if ($ref.ExitCode -ne 0) { return $none }

    $counts = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('rev-list', '--left-right', '--count', "$Branch...origin/$Branch")
    if ($counts.ExitCode -ne 0) { return $none }
    $parts = @($counts.Stdout.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne 2) { return $none }

    # left = коміти, які є лише локально (ahead); right = лише в origin (behind).
    [pscustomobject]@{ HasRemote = $true; Ahead = [int]$parts[0]; Behind = [int]$parts[1] }
}

Export-ModuleMember -Function Split-GitEolNoise, Test-GitTextPolicy, Get-KitOriginGap
