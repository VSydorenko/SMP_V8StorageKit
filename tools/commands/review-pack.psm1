#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/review-pack, modified.
Set-StrictMode -Version Latest

$script:Usage = @'
review-pack <base> [<head>=HEAD] [-Out <файл>] [-Context <n>=10] [-Exclude <glob>]... [-Split <кб>]
review-pack -Branch [<head>=HEAD] …

Пише Markdown-пакет рецензії для base..head: заголовок (діапазон, коміти, файли, +/-),
список комітів, stat і дифф із <n> рядками контексту.

Лише зміни самої гілки: коли origin/<pr.base> (типово main) влили в гілку після <base>,
його коміти виходять зі списку, а його зміни — з діфу. Заголовок про це каже.

  -Branch          base = спільний предок голови й origin/<pr.base>: уся гілка
                   (фінальна рецензія перед PR).
  -Exclude <glob>  не включати шляхи в дифф (повторюваний); додається до поля профілю
                   "review.exclude" (lock-файли, згенероване). Виключені файли
                   лишаються переліченими в заголовку.
  -Split <кб>      коли пакет більший — кілька частин по межах файлів
                   (<ім'я>-part1.md, …).
  -Out <файл>      типово: <головний checkout>/.agents/out/review-<base7>-<head7>.md

Друкує кожен записаний шлях із розміром у КБ і приблизною кількістю токенів (символів/4).
Код: 0 записано; 2 помилка виклику чи невідомий ref; 3 не перевірено: base не предок
голови або порожній діапазон.
'@

function Invoke-KitReviewPack {
    param([string[]]$Arguments = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{ Out = 'string'; Context = 'string'; Exclude = 'list'; Split = 'string'; Branch = 'switch' }
    if ($a.Help) { Write-KitLine $script:Usage; return 0 }
    $branch = [bool]$a.Named['Branch']
    $pos = @($a.Positional)
    if ($branch) { if ($pos.Count -gt 1) { throw (New-KitUsageError 'з -Branch можна вказати лише <head>') } }
    elseif ($pos.Count -lt 1 -or $pos.Count -gt 2) { throw (New-KitUsageError 'потрібен <base>, далі необов''язковий <head>') }

    $context = 10
    if ($a.Named.ContainsKey('Context')) {
        if ($a.Named['Context'] -notmatch '^\d+$') { throw (New-KitUsageError '-Context має бути невід''ємним цілим') }
        $context = [int]$a.Named['Context']
    }
    $split = 0.0
    if ($a.Named.ContainsKey('Split')) {
        $v = 0.0
        if (-not [double]::TryParse($a.Named['Split'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or $v -le 0) {
            throw (New-KitUsageError '-Split має бути додатним числом КБ')
        }
        $split = $v
    }
    $p = @{ Root = $RepoRoot; Context = $context; SplitKb = $split; Branch = $branch }
    if ($branch) { if ($pos.Count -eq 1) { $p.Head = $pos[0] } }
    else { $p.Base = $pos[0]; if ($pos.Count -eq 2) { $p.Head = $pos[1] } }
    if ($a.Named.ContainsKey('Out')) { $p.Out = $a.Named['Out'] }
    if ($a.Named.ContainsKey('Exclude')) { $p.Exclude = [string[]]$a.Named['Exclude'].ToArray() }

    $r = New-KitReviewPackage @p
    $cwd = (Get-Location).Path
    $rel = {
        param($path)
        $x = [System.IO.Path]::GetRelativePath($cwd, $path)
        if ($x.StartsWith('..') -or [System.IO.Path]::IsPathRooted($x)) { $path } else { $x -replace '\\', '/' }
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in $r.Files) {
        Write-KitLine "записано $(& $rel $f.Path): $($f.Kb.ToString('0.0', $inv)) КБ, ~$($f.Tokens.ToString('N0', $inv)) токенів"
    }
    $line = "діапазон $($r.Range): комітів $($r.Commits), файлів $($r.FileCount), +$($r.Plus)/-$($r.Minus)"
    if ($r.Excluded.Count) { $line += ", виключено $($r.Excluded.Count)" }
    if ($r.Parts -gt 1) { $line += ", частин $($r.Parts)" }
    if ($r.BaseMerged) { $line += "; $($r.Upstream) влито: його змін немає в пакеті" }
    Write-KitLine $line
    # Пакет читає рецензент, а не той, хто його зібрав: даємо шлях, не вміст.
    $target = if ($r.Parts -gt 1) { "$($r.Parts) частини" } else { & $rel $r.Files[0].Path }
    # Агент і скіл переносить сесія скілів блоку «процес kit» під тими самими іменами, що в agent-kit.
    Write-KitNext "передай $target рецензенту (агент v8storagekit:task-reviewer або скіл v8storagekit:landed-review)"
    return 0
}

Export-ModuleMember -Function Invoke-KitReviewPack
