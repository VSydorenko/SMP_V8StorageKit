#Requires -Version 7
# Обгортки bin/*.ps1, коли kit.exe не запустився (#51): код ≠ 0 і перший рядок
# stderr `<команда>: ERROR …` (контракт tools/lib/KitCli.psm1; 2 — помилка виклику), а не тихий код 0.
# Тест kit.exe НЕ запускає: копія обгортки лежить у порожній теці, де kit.exe немає або він — текстовий файл.
Describe 'bin/*.ps1 — kit.exe не запустився' {
    BeforeAll {
        $script:BinDir = (Resolve-Path "$PSScriptRoot/../../bin").Path
        function script:Invoke-Wrapper {
            param([string]$Wrapper, [string]$Dir)
            $errFile = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            # Окремий pwsh, як у справжньому виклику: код виходу обгортки — код процесу.
            & pwsh -NoProfile -File (Join-Path $Dir $Wrapper) arg1 2>$errFile | Out-Null
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Err = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue) }
        }
    }

    It '<Wrapper>: kit.exe поруч немає — код 2 і «<Cmd>: ERROR»' -ForEach @(
        Get-ChildItem -LiteralPath "$PSScriptRoot/../../bin" -Filter '*.ps1' | ForEach-Object { @{ Wrapper = $_.Name; Cmd = $_.BaseName } }
    ) {
        $dir = Join-Path $TestDrive "no-exe-$Cmd"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:BinDir $Wrapper) -Destination $dir
        $r = Invoke-Wrapper -Wrapper $Wrapper -Dir $dir
        $r.ExitCode | Should -Be 2
        $r.Err[0] | Should -BeLike "${Cmd}: ERROR *"
    }

    It 'kit.exe — не застосунок (текстовий файл) — код 2 і «sdd: ERROR»' {
        $dir = Join-Path $TestDrive 'fake-exe'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:BinDir 'sdd.ps1') -Destination $dir
        Set-Content -LiteralPath (Join-Path $dir 'kit.exe') -Value 'не виконуваний файл'
        $r = Invoke-Wrapper -Wrapper 'sdd.ps1' -Dir $dir
        $r.ExitCode | Should -Be 2
        $r.Err[0] | Should -BeLike 'sdd: ERROR *'
    }
}
