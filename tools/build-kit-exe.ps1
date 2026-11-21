#Requires -Version 7
<#
    Збірка поставки bin/kit.exe — один рецепт для машини розробника з MSVC і для CI
    (.github/workflows/kit-exe.yml кличе цей самий файл). Спека #51 D7, план §14 п. 12.

    Збірка поставки = лінкер MSVC link.exe (заголовок Rich) + ресурс версії й маніфест з rust/res.
    Збірку без них (rust-lld, xwin, голий `cargo build`) Windows Defender видаляв як ML-детекцію
    (docs/research/2026-11-21-defender-kit-exe.md), тож у коміт іде лише збірка поставки.

      build-kit-exe.ps1 [-Out <файл>]     cargo test, ресурс, збірка, перевірка; результат — у -Out
                                          (типово bin/kit.exe). Перевірку не пройдено — -Out не змінено.
      build-kit-exe.ps1 -Verify <файл>    лише перевірка форми збірки поставки (її кличе Pester).

    Коди: 0 — так; 1 — збірка чи перевірка не пройшли; 2 — помилка виклику.
    Перший рядок stderr помилки — `build-kit-exe: ERROR <причина>`.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')][string]$Out,
    [Parameter(ParameterSetName = 'Verify', Mandatory)][string]$Verify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Вивід — UTF-8 незалежно від кодової сторінки консолі (як tools/kit.ps1): у cp866 немає «і»/«ї».
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$repo =(Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Fail([string]$Reason, [int]$Code = 1) {
    [Console]::Error.WriteLine("build-kit-exe: ERROR $Reason")
    exit $Code
}

function Get-ShipShapeProblem {
    <# Порожній рядок — файл має форму збірки поставки; інакше — причина. #>
    param([Parameter(Mandatory)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return 'не PE-файл (немає MZ)' }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -le 0x40 -or $pe -ge $b.Length) { return 'не PE-файл (зсув заголовка PE поза файлом)' }
    # Заголовок Rich пише лише MSVC link.exe: між заглушкою DOS і заголовком PE лежить «Rich» + ключ XOR,
    # а на початку блоку — «DanS», зашифроване тим самим ключем. rust-lld і lld-link його не пишуть.
    $rich = -1
    for ($i = 0x40; $i -le $pe - 8; $i += 4) {
        if ($b[$i] -eq 0x52 -and $b[$i + 1] -eq 0x69 -and $b[$i + 2] -eq 0x63 -and $b[$i + 3] -eq 0x68) { $rich = $i; break }
    }
    if ($rich -lt 0) { return 'немає заголовка Rich — зібрано не лінкером MSVC link.exe (rust-lld чи lld-link у ~/.cargo/config.toml?)' }
    $key = [BitConverter]::ToUInt32($b, $rich + 4)
    $dans = $false
    for ($i = 0x40; $i -lt $rich; $i += 4) { if (([BitConverter]::ToUInt32($b, $i) -bxor $key) -eq 0x536E6144) { $dans = $true; break } }
    if (-not $dans) { return 'заголовок Rich пошкоджено (немає DanS під його ключем)' }
    $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($vi.ProductName -ne 'v8storagekit' -or $vi.OriginalFilename -ne 'kit.exe') {
        return "немає ресурсу версії kit (ProductName='$($vi.ProductName)', OriginalFilename='$($vi.OriginalFilename)') — зібрано без rust/res/kit.rc"
    }
    if ($vi.FileVersion -notmatch '^\d+\.\d+\.\d+\.0$') { return "FileVersion '$($vi.FileVersion)' не має форми X.Y.Z.0" }
    ''
}

if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    if (-not (Test-Path -LiteralPath $Verify -PathType Leaf)) { Fail "немає файлу '$Verify'" 2 }
    $problem = Get-ShipShapeProblem -Path $Verify
    if ($problem) { Fail "$Verify — не збірка поставки: $problem" }
    [Console]::Out.WriteLine("build-kit-exe: $Verify — збірка поставки (link.exe, ресурс версії $([Diagnostics.FileVersionInfo]::GetVersionInfo($Verify).FileVersion))")
    exit 0
}

if (-not $Out) { $Out = Join-Path $repo 'bin/kit.exe' }
$Out = [IO.Path]::GetFullPath($Out, (Get-Location).Path)

# Середовище MSVC (rc.exe, INCLUDE для winver.h). На CI його вже дав ilammy/msvc-dev-cmd; локально —
# Launch-VsDevShell зі встановлених Build Tools. Зміни оточення живуть лише в цьому процесі.
if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { Fail 'немає rc.exe у PATH і немає Visual Studio Installer — потрібні VS Build Tools з MSVC x64 і Windows SDK; без них збирає CI' }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { Fail 'Visual Studio з компонентом MSVC x64 не знайдено — без нього збирає CI' }
    & (Join-Path $vs 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) { Fail 'середовище MSVC без rc.exe — встановіть Windows SDK' }
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $cargoBin = Join-Path $HOME '.cargo/bin'
    if (Test-Path -LiteralPath (Join-Path $cargoBin 'cargo.exe')) { $env:PATH = "$cargoBin;$env:PATH" } else { Fail 'немає cargo — встановіть rustup' }
}

$v = (Get-Content -LiteralPath (Join-Path $repo '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json).version
if ($v -notmatch '^\d+\.\d+\.\d+$') { Fail "версія '$v' у plugin.json не має форми X.Y.Z" }
$work = Join-Path ([IO.Path]::GetTempPath()) "kit-exe-build-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $work 'kit-version.h') -Encoding ascii -Value @(
        "#define KIT_VERSION_NUM $(($v -replace '\.', ',') + ',0')",
        "#define KIT_VERSION_STR `"$v.0`""
    )
    $res = Join-Path $work 'kit.res'
    Push-Location (Join-Path $repo 'rust/res')
    try { & rc.exe /nologo /i $work /fo $res kit.rc; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code) { Fail "rc.exe завершився кодом $code" }

    Push-Location (Join-Path $repo 'rust')
    try {
        & cargo test --locked
        if ($LASTEXITCODE) { Fail "cargo test завершився кодом $LASTEXITCODE" }
        & cargo rustc --release --locked --bin kit -- -C "link-arg=$res"
        if ($LASTEXITCODE) { Fail "cargo rustc завершився кодом $LASTEXITCODE" }
    } finally { Pop-Location }

    $built = Join-Path $repo 'rust/target/release/kit.exe'
    $problem = Get-ShipShapeProblem -Path $built
    if ($problem) { Fail "зібраний $built — не збірка поставки: $problem; $Out не змінено" }

    # Запущений kit.exe Windows тримає: замінити можна, лише відсунувши старий файл убік.
    New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
    $old = "$Out.old-$PID"
    if (Test-Path -LiteralPath $Out) { Move-Item -LiteralPath $Out -Destination $old -Force }
    Copy-Item -LiteralPath $built -Destination $Out
    if (Test-Path -LiteralPath $old) {
        try { Remove-Item -LiteralPath $old -Force } catch { [Console]::Error.WriteLine("build-kit-exe: старий файл зайнятий, лишився $old — видаліть, коли kit.exe завершиться") }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$f = Get-Item -LiteralPath $Out
[Console]::Out.WriteLine("build-kit-exe: $Out — $($f.Length) байт, sha256 $((Get-FileHash -LiteralPath $Out).Hash), FileVersion $($f.VersionInfo.FileVersion)")
exit 0
