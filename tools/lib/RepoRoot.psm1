#Requires -Version 7
Set-StrictMode -Version Latest

function Resolve-V8RepoRoot {
    <#
    .SYNOPSIS
        Розв'язує -RepoRoot скриптів kit і перевіряє, що це корінь git-репозиторію.
    .DESCRIPTION
        Скрипти kit живуть у плагіні, а не всередині репо-споживача, тому корінь
        передається параметром (типово '.'). Fail-closed: не-git тека зупиняє роботу
        до будь-якого читання чи запису — у дусі guard-перевірок storage-sync.
        .git може бути і текою (звичайний клон), і файлом (git worktree).
        Існування шляху перевіряється ДО Resolve-Path, щоб на неіснуючому -RepoRoot
        сама функція кинула зрозуміле повідомлення замість PropertyNotFoundException від .Path на $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Шлях '$Path' не існує — -RepoRoot має вказувати на корінь git-репозиторію."
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved '.git'))) {
        throw "'$resolved' не є коренем git-репозиторію (немає .git). " +
              'Запустіть із кореня репо-споживача або передайте -RepoRoot явно.'
    }
    return $resolved
}

Export-ModuleMember -Function Resolve-V8RepoRoot
