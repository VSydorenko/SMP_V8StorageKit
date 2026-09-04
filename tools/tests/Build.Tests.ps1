#Requires -Version 7
Describe 'build.ps1 — лише .epf (перехідний стан до kit build, B4)' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("v8kit-build-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') -Force | Out-Null
        $script:build = (Resolve-Path "$PSScriptRoot/../build.ps1").Path
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'без epf/src — зупинка з epf/src у тексті' {
        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'epf/src'
    }

    It 'з epf/src прев''ю показує epf і build/artifacts і завершується 0' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'epf/src') -Force | Out-Null

        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'epf'
        $out | Should -Match 'build[\\/]artifacts'
    }

    It '-Product Other — зупинка з operation=make' {
        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp -Product 'Other' 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'operation=make'
    }
}
