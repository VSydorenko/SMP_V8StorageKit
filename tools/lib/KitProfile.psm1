#Requires -Version 7
# Ported from agent-kit 0.9.1 lib/profile.mjs, modified.
<#
    Профіль процесу (ADR-0003): усе проєктне живе тут, а не в командах.

    Шари, від нижнього до верхнього:
      машинний   — $env:XDG_CONFIG_HOME\v8storagekit\profile.json (типово %USERPROFILE%\.config\…);
      проєктний  — .agents/kit.profile.json (комітиться);
      локальний  — .agents/kit.profile.local.json (git-ignored).
    Об'єкти зливаються, масиви й скаляри замінюються цілком.

    Поля, якого немає, команда не вгадує: Get-KitProfileValue без -Default кидає «не
    перевірено» (код 3) з назвою поля й файлу.
#>
Set-StrictMode -Version Latest

$script:ProfileFile = '.agents/kit.profile.json'
$script:LocalProfileFile = '.agents/kit.profile.local.json'

function Invoke-KitProfileGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GitArgs)
    $out = & git -C $Path @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    ([string]($out | Select-Object -First 1)).Trim()
}

function Get-KitCheckoutRoot {
    <# Корінь поточного checkout (worktree), у якому працює агент. Не git — «не перевірено». #>
    param([string]$Path = (Get-Location).Path)
    $root = if (Test-Path -LiteralPath $Path) { Invoke-KitProfileGit -Path $Path -GitArgs @('rev-parse', '--show-toplevel') } else { $null }
    if (-not $root) { throw (New-KitNotChecked "не git-репозиторій: $Path") }
    [System.IO.Path]::GetFullPath($root)
}

function Get-KitMainRoot {
    <#
        Корінь ГОЛОВНОГО checkout — батько git-common-dir. Спільний стан процесу (журнали sdd,
        пакети рецензії) живе тут, щоб пережити видалення worktree і бути видимим з будь-якої копії.
    #>
    param([string]$Path = (Get-Location).Path)
    $common = if (Test-Path -LiteralPath $Path) { Invoke-KitProfileGit -Path $Path -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir') } else { $null }
    if (-not $common) { throw (New-KitNotChecked "не git-репозиторій: $Path") }
    [System.IO.Path]::GetFullPath((Split-Path -Parent ([System.IO.Path]::GetFullPath($common))))
}

function Get-KitMachineProfilePath {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path ($env:USERPROFILE ?? $HOME) '.config' }
    Join-Path $base 'v8storagekit/profile.json'
}

function Read-KitProfileJson {
    param([Parameter(Mandatory)][string]$Path)
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw (New-KitNotChecked "не читається ${Path}: $($_.Exception.Message)") }
}

function Merge-KitProfileData {
    <# Верхній шар доповнює нижній: об'єкти зливаються, масиви й скаляри замінюються цілком. #>
    param([hashtable]$Base = @{}, [hashtable]$Over = @{})
    $out = [ordered]@{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) {
        $v = $Over[$k]
        if ($v -is [System.Collections.IDictionary] -and $out.Contains($k) -and $out[$k] -is [System.Collections.IDictionary]) {
            $out[$k] = Merge-KitProfileData -Base $out[$k] -Over $v
        } else { $out[$k] = $v }
    }
    $out
}

function Resolve-KitProfileNamespace {
    <#
        Простір імен v8storagekit (ADR-0020): у профілі, який v8storagekit ділить з agent-kit, наявна секція першого
        рівня `v8storagekit.<секція>` заміняє верхню `<секцію>` ЦІЛКОМ, без злиття (інакше `v8storagekit.tests` без
        `levels` пропустив би рівні тестів іншої зони). `v8storagekit.version` — версія проєкту, не секція. Ключі —
        без урахування регістру, як у хештаблиці. Та сама функція — для злитих шарів (Get-KitProfile) і для одного
        шару (pr.afterMerge з профілю на головній гілці, KitPrGate.psm1).
    #>
    param($Data)
    if (-not ($Data -is [System.Collections.IDictionary])) { return , $Data }
    $nsKey = @($Data.Keys | Where-Object { [string]$_ -ieq 'v8storagekit' }) | Select-Object -First 1
    if ($null -eq $nsKey -or -not ($Data[$nsKey] -is [System.Collections.IDictionary])) { return , $Data }
    $out = [ordered]@{}
    foreach ($k in $Data.Keys) { $out[$k] = $Data[$k] }
    foreach ($k in $Data[$nsKey].Keys) {
        if ([string]$k -ieq 'version') { continue }
        $same = @($out.Keys | Where-Object { [string]$_ -ieq [string]$k })
        foreach ($s in $same) { $out.Remove($s) }
        $out[$k] = $Data[$nsKey][$k]
    }
    , $out
}

function Get-KitProfile {
    <#
    .SYNOPSIS
        Профіль checkout-а -RepoRoot: Root (корінь checkout), MainRoot, Exists (є проєктний або
        локальний файл), Data (злиті шари).
    .DESCRIPTION
        Відсутній файл профілю тут не помилка: команда сама вирішує, чи може без нього, і падає
        через Get-KitProfileValue без -Default.
    #>
    param([string]$RepoRoot = (Get-Location).Path)
    $root = Get-KitCheckoutRoot -Path $RepoRoot
    $machinePath = Get-KitMachineProfilePath
    $sharedPath = Join-Path $root $script:ProfileFile
    $localPath = Join-Path $root $script:LocalProfileFile
    $machine = if (Test-Path -LiteralPath $machinePath) { Read-KitProfileJson $machinePath } else { $null }
    $shared = if (Test-Path -LiteralPath $sharedPath) { Read-KitProfileJson $sharedPath } else { $null }
    $local = if (Test-Path -LiteralPath $localPath) { Read-KitProfileJson $localPath } else { $null }
    $data = Merge-KitProfileData -Base (Merge-KitProfileData -Base ($machine ?? @{}) -Over ($shared ?? @{})) -Over ($local ?? @{})
    # Спершу шари, потім простір імен v8storagekit (ADR-0020).
    $data = Resolve-KitProfileNamespace $data
    [pscustomobject]@{
        Root     = $root
        MainRoot = Get-KitMainRoot -Path $root
        Exists   = ($null -ne $shared -or $null -ne $local)
        Data     = $data
    }
}

function Get-KitProfileValue {
    <#
        Get-KitProfileValue $p 'tests.levels'. Без -Default відсутнє поле — «не перевірено» (код 3)
        з назвою поля й файлу, щоб агент не вгадував значення. -Default $null дозволено.
    #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$Path,
        $Default
    )
    $cur = $Profile.Data
    foreach ($key in $Path.Split('.')) {
        if (-not ($cur -is [System.Collections.IDictionary]) -or -not $cur.Contains($key)) {
            if ($PSBoundParameters.ContainsKey('Default')) { return , $Default }
            throw (New-KitNotChecked "поле профілю `"$Path`" відсутнє (додай його в $script:ProfileFile у $($Profile.Root))")
        }
        $cur = $cur[$key]
    }
    , $cur
}

function Resolve-KitInsidePath {
    <# Відносний шлях усередині головного checkout: без '..', не абсолютний — інакше .gitignore його не покриє. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Field)
    $clean = ($Value.Trim() -replace '\\', '/' -replace '/+$', '' -replace '^\./', '')
    if (-not $clean -or [System.IO.Path]::IsPathRooted($clean) -or ($clean.Split('/') | Where-Object { $_ -in @('..', '.', '') })) {
        throw (New-KitNotChecked "поле профілю `"$Field`" має бути шляхом відносно головного checkout, без '..': отримано `"$Value`"")
    }
    $clean
}

function Get-KitAgentsDir {
    <#
    .SYNOPSIS
        Тека процесу в ГОЛОВНОМУ checkout: out (пакети, повний вивід), sdd (журнали планів),
        private (те, що не комітиться ніколи; profile private.dir), briefs.
    .DESCRIPTION
        -Create створює теку і кладе в неї `.gitignore` з `*`: вміст не потрапить у коміт, навіть
        якщо споживач не оновив свій .gitignore.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('out', 'sdd', 'private', 'briefs')][string]$Name,
        [string]$RepoRoot = (Get-Location).Path,
        [switch]$Create
    )
    $main = Get-KitMainRoot -Path $RepoRoot
    $rel = ".agents/$Name"
    if ($Name -eq 'private') {
        $p = Get-KitProfile -RepoRoot $RepoRoot
        $rel = Resolve-KitInsidePath -Value ([string](Get-KitProfileValue $p 'private.dir' -Default '.agents/private')) -Field 'private.dir'
    }
    $dir = [System.IO.Path]::GetFullPath((Join-Path $main $rel))
    if ($Create) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $ignore = Join-Path $dir '.gitignore'
        if (-not (Test-Path -LiteralPath $ignore)) { [System.IO.File]::WriteAllText($ignore, "*`n") }
    }
    $dir
}

Export-ModuleMember -Function Get-KitCheckoutRoot, Get-KitMainRoot, Get-KitMachineProfilePath, Merge-KitProfileData,
    Get-KitProfile, Get-KitProfileValue, Resolve-KitInsidePath, Get-KitAgentsDir, Resolve-KitProfileNamespace
