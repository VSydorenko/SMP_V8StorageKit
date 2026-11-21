#Requires -Version 7
# Вхід bin/kit.exe (спека #51 D1, D1а, D2, D7; план Р2, Р3, Р6): передача неперенесених команд
# PowerShell-диспетчеру через KIT_ARGV, інваріанти «-Apply» і «KIT_ARGV» через kit.exe, дефект Н6
# через обгортку bin/ і запобіжник «закомічений бінарник = джерело».
# Тести ходять у закомічений bin/kit.exe (через копію плагіна Copy-KitTools або напряму), не збирають його.

BeforeAll {
    Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    $script:KitRepo = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:KitExe = Join-Path $script:KitRepo 'bin/kit.exe'

    # Процес із точними аргументами (ArgumentList — лапкування за правилами MSVC, які читає kit.exe),
    # stdin байтами й окремими stdout/stderr у UTF-8.
    function script:Invoke-KitExe {
        param(
            [Parameter(Mandatory)][string]$Exe,
            [string[]]$Arguments = @(),
            [byte[]]$Stdin = @(),
            [string]$WorkDir = $TestDrive
        )
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory = $WorkDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if ($Stdin.Count) { $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Count) }
        $p.StandardInput.Close()
        $p.WaitForExit()
        [pscustomobject]@{
            ExitCode = $p.ExitCode
            Out      = @($out.Result -split "`r?`n" | Where-Object { $_ -ne '' })
            Err      = @($err.Result -split "`r?`n" | Where-Object { $_ -ne '' })
        }
    }
}

Describe 'kit.exe — канал KIT_ARGV до диспетчера (D1а, Н6)' {
    # Фальшивий плагін: справжній kit.exe у bin/ і заглушка tools/kit.ps1, що друкує токени з KIT_ARGV,
    # байти stdin і пише в stderr. Заглушка читає САМЕ KIT_ARGV: без змінної — код 9.
    BeforeAll {
        $script:Fake = Join-Path $TestDrive 'fake-plugin'
        New-Item -ItemType Directory -Path (Join-Path $script:Fake 'bin'), (Join-Path $script:Fake 'tools') -Force | Out-Null
        Copy-Item -LiteralPath $script:KitExe -Destination (Join-Path $script:Fake 'bin/kit.exe')
        Set-Content -LiteralPath (Join-Path $script:Fake 'tools/kit.ps1') -Encoding UTF8 -Value @'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$j = [Environment]::GetEnvironmentVariable('KIT_ARGV')
if ($null -eq $j) { [Console]::Out.WriteLine('NO-KIT_ARGV'); exit 9 }
$t = [System.Text.Json.JsonSerializer]::Deserialize[string[]]($j)
if ($t[0] -eq 'code') { exit [int]$t[1] }
foreach ($x in $t) { [Console]::Out.WriteLine("[$x]") }
$ms = [System.IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($ms)
[Console]::Out.WriteLine('STDIN ' + [Convert]::ToHexString($ms.ToArray()))
[Console]::Error.WriteLine('STUB-STDERR')
exit 4
'@
        $script:FakeExe = Join-Path $script:Fake 'bin/kit.exe'
    }

    It 'токени Н6 і -Apply:false доходять дослівно, stdin — байтами, stderr і код 4 — як є' {
        $tokens = @('probe', "-Ім'я:знач ення", '-Apply:false', '', 'з "лапками"', 'хвіст\', '$env:X', '--', 'a&b|c', '%PATH%', 'кирилиця')
        [byte[]]$bytes = 0..255
        $r = Invoke-KitExe -Exe $script:FakeExe -Arguments $tokens -Stdin $bytes
        $r.ExitCode | Should -Be 4 -Because ($r.Out + $r.Err -join "`n")
        $r.Out | Select-Object -SkipLast 1 | Should -Be @($tokens | ForEach-Object { "[$_]" })
        $r.Out[-1] | Should -Be ('STDIN ' + [Convert]::ToHexString($bytes))
        $r.Err | Should -Be @('STUB-STDERR')
    }

    It 'код диспетчера — код kit.exe: спостережені коди = {0,1,2,3,4}' {
        $seen = foreach ($c in 0..4) { (Invoke-KitExe -Exe $script:FakeExe -Arguments @('code', "$c")).ExitCode }
        $seen | Should -Be @(0, 1, 2, 3, 4)
    }
}

Describe 'Інваріанти через kit.exe — «-Apply» і «KIT_ARGV» (D1а)' {
    # Копія плагіна зі справжнім tools/kit.ps1 і bin/kit.exe. Заглушки лише в копії: sync друкує Apply,
    # probe-argv друкує свої токени й запускає дочірній процес, що дивиться на KIT_ARGV.
    BeforeAll {
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitRoot = Split-Path (Split-Path $script:Kit -Parent) -Parent
        $script:CopyExe = Join-Path $script:KitRoot 'bin/kit.exe'
        Set-Content -LiteralPath (Join-Path $script:KitRoot 'tools/commands/sync.psm1') -Encoding UTF8 -Value @'
function Invoke-KitSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [string]$Workspace, [string]$Source, [bool]$Apply)
    [Console]::Out.WriteLine("SYNC-STUB apply=$Apply")
}
Export-ModuleMember -Function Invoke-KitSync
'@
        Set-Content -LiteralPath (Join-Path $script:KitRoot 'tools/commands/probe-argv.psm1') -Encoding UTF8 -Value @'
function Invoke-KitProbeArgv {
    param([string[]]$Arguments, [string]$RepoRoot)
    foreach ($a in $Arguments) { Write-KitLine "TOKEN [$a]" }
    # -EncodedCommand: текст дочірньої команди без лапкування аргументів нативного процесу.
    $childCode = 'if ($null -eq $env:KIT_ARGV) { "CHILD KIT_ARGV absent" } else { "CHILD KIT_ARGV=$env:KIT_ARGV" }'
    $child = & pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode)))
    Write-KitLine "$child"
    return 0
}
Export-ModuleMember -Function Invoke-KitProbeArgv
'@
        Add-Content -LiteralPath (Join-Path $script:KitRoot 'tools/commands/process-commands.txt') -Value 'probe-argv' -Encoding UTF8
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo')
    }

    It 'kit sync -Apply:false — заглушка отримала Apply = False (не позиційний False, не застосування)' {
        $r = Invoke-KitExe -Exe $script:CopyExe -Arguments @('sync', '-RepoRoot', $script:Repo, '-Apply:false')
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        $r.Out | Should -Contain 'SYNC-STUB apply=False'
    }

    It 'позитивний двійник: kit sync -Apply — Apply = True' {
        $r = Invoke-KitExe -Exe $script:CopyExe -Arguments @('sync', '-RepoRoot', $script:Repo, '-Apply')
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        $r.Out | Should -Contain 'SYNC-STUB apply=True'
    }

    It 'токени прийшли з KIT_ARGV, а дочірній процес команди KIT_ARGV не бачить' {
        $r = Invoke-KitExe -Exe $script:CopyExe -Arguments @('probe-argv', '-X:знач ення') -WorkDir $script:Repo
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        # `pwsh -File` розщепив би цей токен на два — цілий доводить канал KIT_ARGV.
        $r.Out | Should -Contain 'TOKEN [-X:знач ення]'
        $r.Out | Should -Contain 'CHILD KIT_ARGV absent'
    }
}

Describe 'Дефект Н6 закрито: обгортка bin/ доносить -Ім''я:false цілим' {
    # -Code розібрано як прапорець, шляхів немає — помилка виклику refs без шляху. Колишній дефект:
    # шлях `False`, код 0 і рядок «next: … doc refs False» (bash) чи «-Code: прапорець без значення» (.ps1).
    BeforeAll {
        $kit = Copy-KitTools -Root (Join-Path $TestDrive 'doc-kit')
        $script:DocRoot = Split-Path (Split-Path $kit -Parent) -Parent
        $script:DocRepo = Join-Path $TestDrive 'doc-repo'
        New-Item -ItemType Directory -Path $script:DocRepo -Force | Out-Null
        git -C $script:DocRepo init -q 2>$null
        function script:Assert-KitCodeFalse($r) {
            $r.ExitCode | Should -Be 2 -Because ($r.Out + $r.Err -join "`n")
            $r.Err[0] | Should -Be 'doc: ERROR doc refs <шлях...> | doc refs -Dead'
            ($r.Out -join "`n") | Should -Not -Match 'False'
        }
    }

    It 'bash bin/doc refs -Code:false — -Code = false, а не пошук шляху False' {
        Assert-KitCodeFalse (Invoke-KitExe -Exe (Get-KitBashPath) -Arguments @((Join-Path $script:DocRoot 'bin/doc'), 'refs', '-Code:false') -WorkDir $script:DocRepo)
    }

    It 'pwsh -c bin/doc.ps1 refs -Code:false — PowerShell дає $args `-Code:` і `false`, обгортка склеює' {
        $cmd = "& '$((Join-Path $script:DocRoot 'bin/doc.ps1').Replace("'", "''"))' refs -Code:false; exit `$LASTEXITCODE"
        Assert-KitCodeFalse (Invoke-KitExe -Exe (Get-Command pwsh).Source -Arguments @('-NoProfile', '-Command', $cmd) -WorkDir $script:DocRepo)
    }
}

Describe 'Закомічений бінарник = джерело (D7, Р6)' {
    BeforeAll {
        # Рядки прихованої підкоманди: `embedded <hex>` і `computed <hex> <файлів>`.
        function script:Get-KitFingerprint([string]$Exe, [string]$Crate) {
            $r = Invoke-KitExe -Exe $Exe -Arguments @('source-fingerprint', $Crate)
            $e = @($r.Out | Where-Object { $_ -like 'embedded *' })
            $c = @($r.Out | Where-Object { $_ -like 'computed *' })
            [pscustomobject]@{
                ExitCode = $r.ExitCode
                Embedded = if ($e.Count) { ($e[0] -split ' ')[1] } else { '' }
                Computed = if ($c.Count) { ($c[0] -split ' ')[1] } else { '' }
                Files    = if ($c.Count) { [int]($c[0] -split ' ')[2] } else { 0 }
                Raw      = ($r.Out + $r.Err) -join "`n"
            }
        }
        function script:Assert-KitFingerprintMatches($f) {
            $f.ExitCode | Should -Be 0 -Because $f.Raw
            $f.Embedded | Should -Match '^[0-9a-f]{16}$' -Because $f.Raw
            $f.Computed | Should -Match '^[0-9a-f]{16}$' -Because $f.Raw
            $f.Files | Should -BeGreaterThan 0 -Because $f.Raw
            $f.Computed | Should -Be $f.Embedded -Because "bin/kit.exe зібрано не з цих джерел rust/ — перезберіть: cargo build --release у rust/ і скопіюйте в bin/kit.exe`n$($f.Raw)"
        }
    }

    It 'робоче дерево: вбудований відбиток = обчислений з rust/' {
        Assert-KitFingerprintMatches (Get-KitFingerprint $script:KitExe (Join-Path $script:KitRepo 'rust'))
    }

    It 'індекс: bin/kit.exe і rust/ з індексу git дають той самий відбиток' {
        $prefix = Join-Path $TestDrive 'index'
        $paths = @(git -C $script:KitRepo ls-files -- rust bin/kit.exe)
        $paths | Should -Contain 'bin/kit.exe'
        # Байти з індексу пише сам git (без конвеєра PowerShell); репозиторій не змінюється.
        git -C $script:KitRepo checkout-index "--prefix=$($prefix.Replace('\', '/'))/" -- @paths
        $LASTEXITCODE | Should -Be 0
        Assert-KitFingerprintMatches (Get-KitFingerprint (Join-Path $prefix 'bin/kit.exe') (Join-Path $prefix 'rust'))
    }

    It 'контроль: мутація класу <Class> дає інший відбиток' -ForEach @(
        @{ Class = 'src/*.rs'; Rel = 'src/main.rs' }
        @{ Class = 'Cargo.lock'; Rel = 'Cargo.lock' }
        @{ Class = 'новий файл'; Rel = 'src/новий.rs' }
        @{ Class = '.cargo/'; Rel = '.cargo/config.toml' }
    ) {
        $crate = Join-Path $TestDrive "crate-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $crate -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:KitRepo 'rust') -Force |
            Where-Object Name -ne 'target' | Copy-Item -Destination $crate -Recurse
        $before = Get-KitFingerprint $script:KitExe $crate
        $before.Computed | Should -Match '^[0-9a-f]{16}$' -Because $before.Raw
        $file = Join-Path $crate $Rel
        New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
        [System.IO.File]::AppendAllText($file, "`n# мутація`n")
        $after = Get-KitFingerprint $script:KitExe $crate
        $after.Computed | Should -Match '^[0-9a-f]{16}$' -Because $after.Raw
        $after.Computed | Should -Not -Be $before.Computed
    }
}
