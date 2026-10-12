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
          саме той порожній-sourcePath випадок — теж відхиляється, не тільки вихід за неї).
    .EXAMPLE
        Assert-SafeWorkPath -Path $sourceDir -MustBeUnder $productPath -Description "sourceDir продукту $Product"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$MustBeUnder,
        [Parameter(Mandatory)][string]$Description
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
