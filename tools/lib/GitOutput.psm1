#Requires -Version 7
Set-StrictMode -Version Latest

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

Export-ModuleMember -Function Split-GitEolNoise
