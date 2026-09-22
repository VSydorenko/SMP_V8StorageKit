# Спільна підготовка для розрізаних файлів SessionCheck.*.Tests.ps1 (Task 7, "Швидкість
# набору тестів") — дослівний перенос тіла BeforeAll з колишнього SessionCheck.Tests.ps1:3-63.
# Підключається DOT-SOURCE із BeforeAll кожного файлу, не Import-Module: перенесені
# хелпери користуються $TestDrive (Pester-змінна поточного тестового прогону) і
# function script:, а New-Repo кличе Merge-KitBranchInto з GitMerge.psm1, імпортований
# у ту саму область — усередині модуля не видно ні того, ні того. Та сама пастка вкладеного
# Import-Module, яку описує великий коментар у KitFixtures.psm1 і docs/follow-ups.md §5.
#
# $PSScriptRoot тут — власна тека ЦЬОГО файлу (tools/tests/fixtures/), А НЕ виклика (як і в
# CheckSetup.ps1, Task 6) — звідси подвійний "..": до tools/tests/SessionCheck.Tests.ps1
# ходило "$PSScriptRoot/../lib", а звідси, з fixtures/, треба на рівень глибше:
# "$PSScriptRoot/../../lib".
Import-Module (Resolve-Path "$PSScriptRoot/KitFixtures.psm1").Path -Force
Import-Module (Resolve-Path "$PSScriptRoot/../../lib/GitMerge.psm1").Path -Force
# Task 8: StorageImprint.psm1 — записуємо відбиток напряму в тестах (без реального kit
# sync), щоб перевірити ГІЛКУ ВІДБИТКА session-check ізольовано від платформи.
Import-Module (Resolve-Path "$PSScriptRoot/../../lib/StorageBranch.psm1").Path -Force
Import-Module (Resolve-Path "$PSScriptRoot/../../lib/StorageImprint.psm1").Path -Force
$script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

# Фейкове сховище: 1cv8ddb.1CD + data/objects/* (типово) і опційно data/pack/* (-PackWrite).
# -NoObjectFile — сховище, де всю історію вже запаковано: data/objects лишається без
# жодного файла (Task 8, спека 9f6ad5e §5, «Запаковане сховище»). Шлях підставляється
# накладкою (storages:).
function script:New-FakeStorage {
    param([string]$Name, [datetime]$ObjectsWrite, [datetime]$DbWrite, [datetime]$PackWrite, [switch]$NoObjectFile)
    $s = Join-Path $TestDrive "storage-$Name"
    if (-not $NoObjectFile) {
        New-Item -ItemType Directory -Path (Join-Path $s 'data/objects/ab') -Force | Out-Null
        $obj = Join-Path $s 'data/objects/ab/cdef.bin'; Set-Content -LiteralPath $obj -Value 'obj'
        (Get-Item $obj).LastWriteTimeUtc = $ObjectsWrite.ToUniversalTime()
    } else {
        New-Item -ItemType Directory -Path $s -Force | Out-Null
    }
    $db  = Join-Path $s '1cv8ddb.1CD'; Set-Content -LiteralPath $db -Value 'db'
    (Get-Item $db).LastWriteTimeUtc = $DbWrite.ToUniversalTime()
    # $PSBoundParameters.ContainsKey, не "$PackWrite -ne $null": [datetime] непорожній за
    # замовчуванням (DateTime.MinValue, не $null), а Nullable[datetime]-параметр, який
    # реально отримав значення, боксується як гола System.DateTime (правило CLR для
    # Nullable<T>), тож .Value на ньому впав би "cannot call a method on a null-valued
    # expression" — той самий зразок, що New-KitFakeRepo (-ManifestText) у KitFixtures.psm1.
    if ($PSBoundParameters.ContainsKey('PackWrite')) {
        New-Item -ItemType Directory -Path (Join-Path $s 'data/pack') -Force | Out-Null
        $pack = Join-Path $s 'data/pack/1.pack'; Set-Content -LiteralPath $pack -Value 'pack'
        (Get-Item $pack).LastWriteTimeUtc = $PackWrite.ToUniversalTime()
    }
    $s
}
function script:New-Repo {
    param([string]$Name, [string]$StoragePath, [datetime]$MirrorDate, [switch]$NoMirror, [switch]$Merge)
    $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -OverlayText "storages:`n  Alpha_SMB: '$StoragePath'" -WithHooks -WithGitattributes -WithGitignore
    if (-not $NoMirror) {
        $stamp = $MirrorDate.ToString('yyyy-MM-ddTHH:mm:ss')
        $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp
        try { Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' -FileName 'a.xml' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1') }
        finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
        if ($Merge) { Merge-KitBranchInto -RepoRoot $repo -Branch 'storage/Alpha_SMB' -Into 'main' -Message 'перше' -AllowUnrelated | Out-Null }
    }
    # Слід фікстури: worktree remove прибирає wt, а порожню build/sync лишає — щоб твердження
    # «session-check не створює тек» перевіряло команду, а не фікстуру (P2 префлайту B3).
    Remove-Item -LiteralPath (Join-Path $repo 'build') -Recurse -Force -ErrorAction SilentlyContinue
    $repo
}
# Task 5/7: тонка обгортка над спільним Invoke-KitCommand (KitFixtures.psm1) — та сама форма
# виклику (session-check -RepoRoot $Repo @More), той самий Output/ExitCode, що й раніше.
function script:Invoke-SessionCheck {
    param([string]$Repo, [string[]]$More = @())
    Invoke-KitCommand -Kit $script:Kit -Command 'session-check' -Repo $Repo -More $More
}
$script:Old = [datetime]'2026-01-10T10:00:00'
$script:New = [datetime]'2026-02-20T10:00:00'
