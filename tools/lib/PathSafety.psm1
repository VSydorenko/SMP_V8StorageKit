#Requires -Version 7
Set-StrictMode -Version Latest

function Assert-SafeWorkPath {
    <#
    .SYNOPSIS
        Зупиняє видалення/створення за шляхом, який не є свідомо звуженою підтекою.
    .DESCRIPTION
        Спільний запобіжник перед кожним рекурсивним видаленням у tools/: storage.json
        пишеться вручну при підключенні продукту, і його поле sourcePath доходить до
        Join-Path і далі до Remove-Item -Recurse -Force без жодної перевірки. Порожній
        sourcePath ("") робить Join-Path $productPath "" рівним самому $productPath —
        і -Apply стирає увесь каталог продукту разом із негітованим v8project.local.yaml,
        який неможливо відновити з git. Та сама форма ризику — у New-V8FileInfobase
        (wipes any $Path без перевірки, що це взагалі інфобаза) і в dump-config.ps1.

        Приймає вже складений (Join-Path чи інакше) шлях, який ось-ось підуть видаляти
        чи створювати заново, і межу, під якою він мусить лежати. Кидає виняток, якщо:
        - $Path порожній або складається лише з пробілів;
        - $Path містить сегмент ".." (перевіряється на сирому рядку, до нормалізації —
          GetFullPath згорнув би ".." непомітно, а сама наявність такого сегмента в
          закомодженому storage.json чи в аргументі скрипта підозріла незалежно від
          того, чи виводить він за межу після згортання);
        - нормалізований $Path не є ВЛАСНЕ підтекою $MustBeUnder (рівність з межею —
          саме той порожній-sourcePath випадок — теж відхиляється, не тільки вихід за неї);
        - будь-який наявний компонент від $MustBeUnder (не включно) до $Path (включно) є посиланням — reparse point
          (П25: kit нічого не видаляє крізь посилання; ціль посилання у виняток не потрапляє). Перевірка йде від -RepoRoot (не включно),
          якщо шлях усередині репо, інакше від -MustBeUnder; посиланням може бути лише -OwnedRoot (див. нижче).
    .EXAMPLE
        Assert-SafeWorkPath -Path $sourceDir -MustBeUnder $productPath -Description "sourceDir продукту $Product"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$OwnedRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description порожній або складається лише з пробілів — відмовляюсь видаляти чи створювати за таким шляхом."
    }

    $segments = $Path -split '[\\/]+'
    if ($segments -contains '..') {
        throw "$Description містить сегмент '..' ('$Path') — відмовляюсь видаляти чи створювати за таким шляхом."
    }

    $boundary = [System.IO.Path]::GetFullPath($MustBeUnder).TrimEnd('\', '/')
    $full     = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $prefix   = $boundary + [System.IO.Path]::DirectorySeparatorChar

    if (($full -eq $boundary) -or (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Description ('$Path') не є підтекою '$MustBeUnder' — відмовляюсь видаляти чи створювати за таким шляхом."
    }

    # П25: kit нічого не видаляє крізь посилання. GetFullPath посилань не розгортає, тож перевірка префікса вище
    # junction на проміжному компоненті не бачить — а Directory.Delete / рекурсивне стирання пішли б у ціль посилання,
    # можливо поза репозиторієм.
    # Звідки йдемо: для шляху всередині репозиторію — від КОРЕНЯ РЕПОЗИТОРІЮ (не включно), незалежно від -MustBeUnder
    # (межа відповідає за «під чим», а не за «звідки перевіряти посилання»: build/adopt лежить усередині репо, і junction
    # на repo\build інакше лишався б непоміченим); для шляху поза репо — від межі (-RepoRoot обов'язковий: без нього перевірка йшла б від межі й повертала діру repo\build-junction).
    # Посиланням може бути рівно один компонент — корінь власності (-OwnedRoot: build/ репо чи воркспейсу, робоча тека
    # Уніки), який викликач називає явно; нижче нього й вище нього (до кореня репо) посилань бути не може.
    # Без -OwnedRoot посилань немає взагалі. Теку набору коренем власності не називають ніколи.
    # Перший ненаявний компонент зупиняє обхід (глибше нічого немає); помилка читання атрибута наявного — виняток
    # (fail-closed), а не кінець перевірки. У виняток іде компонент відносно точки старту, а не ціль посилання.
    $scanFrom = $boundary
    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if ($full.StartsWith($repoFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { $scanFrom = $repoFull }
    $owned = if ($OwnedRoot) { [System.IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\', '/') } else { $null }
    $scanPrefix = $scanFrom + [System.IO.Path]::DirectorySeparatorChar
    $current = $scanFrom
    foreach ($seg in ($full.Substring($scanPrefix.Length) -split '[\\/]+' | Where-Object { $_ })) {
        $current = Join-Path $current $seg
        $attr = Get-KitComponentAttributes -Path $current -Description $Description
        if ($null -eq $attr) { break }
        if ($attr.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            if ($owned -and [string]::Equals($current.TrimEnd('\', '/'), $owned, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $current.Substring($scanPrefix.Length)
            throw "${Description}: компонент шляху '$rel' є посиланням (junction чи symlink) — kit нічого не видаляє крізь посилання; приберіть посилання з шляху."
        }
    }
}

function Get-KitComponentAttributes {
    # Атрибути наявного компонента шляху БЕЗ слідування за посиланням. $null — компонента немає (тоді глибше нічого
    # немає); будь-яка інша помилка читання — виняток: «не вдалося перевірити» не дорівнює «посилання немає».
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    try { return [System.IO.File]::GetAttributes($Path) }
    catch [System.IO.FileNotFoundException] { return $null }
    catch [System.IO.DirectoryNotFoundException] { return $null }
    catch { throw "${Description}: не вдалося перевірити компонент шляху '$Path' на посилання (${_}) — відмовляюсь видаляти чи створювати за таким шляхом." }
}
function Remove-KitDirectory {
    <#
    .SYNOPSIS
        Рекурсивне видалення теки з повторами (#34) — єдине місце рекурсивного видалення в kit.
    .DESCRIPTION
        Remove-Item -Recurse під pwsh 7.6 на Windows Server недетерміновано падає на зайнятому
        файлі (антивірус, індексатор, щойно закритий 1cv8). [System.IO.Directory]::Delete не
        знімає атрибута ReadOnly ні з файлів, ні з тек (на теці з ReadOnly .NET кидає IOException,
        не UnauthorizedAccessException — перевірено аудитом плану), тож перед КОЖНИМ повтором
        атрибут знімається з усього дерева, а на IOException ще й пауза, що росте з номером
        спроби. Межу шляху тут не перевіряють: викликач робить Assert-SafeWorkPath ДО виклику,
        як і раніше перед Remove-Item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 50)][int]$Attempts = 5,
        [ValidateRange(0, 10000)][int]$DelayMs = 200
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Remove-KitDirectory: '$Path' не тека — файли видаляє викликач сам, звичайним видаленням файлу."
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $clearReadOnly = {
        $all = @($full) + @([System.IO.Directory]::EnumerateFileSystemEntries($full, '*', [System.IO.SearchOption]::AllDirectories))
        foreach ($entry in $all) {
            $attr = [System.IO.File]::GetAttributes($entry)
            if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
                [System.IO.File]::SetAttributes($entry, $attr -band (-bnot [System.IO.FileAttributes]::ReadOnly))
            }
        }
    }
    for ($i = 1; ; $i++) {
        try {
            [System.IO.Directory]::Delete($full, $true)
            return
        } catch [System.IO.DirectoryNotFoundException] {
            return
        } catch [System.UnauthorizedAccessException] {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "Remove-KitDirectory: спроба $i — доступ заборонено, знімаю ReadOnly у '$full'"
            & $clearReadOnly
        } catch [System.IO.IOException] {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "Remove-KitDirectory: спроба $i — $($_.Exception.Message); повтор через $($DelayMs * $i) мс"
            try { & $clearReadOnly } catch { Write-Verbose "Remove-KitDirectory: зняти ReadOnly не вдалось — $($_.Exception.Message)" }
            Start-Sleep -Milliseconds ($DelayMs * $i)
        }
    }
}

Export-ModuleMember -Function Assert-SafeWorkPath, Remove-KitDirectory
