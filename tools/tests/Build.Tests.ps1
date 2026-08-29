#Requires -Version 7
Describe 'build.ps1 — виявлення продуктів' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("v8kit-build-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') -Force | Out-Null
        $script:build = (Resolve-Path "$PSScriptRoot/../build.ps1").Path
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'знаходить теки зі storage.json і epf/src' {
        foreach ($p in 'Alpha_SMB', 'Beta_ACC') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmp $p) | Out-Null
            Set-Content -LiteralPath (Join-Path $script:tmp $p 'storage.json') -Value '{}'
        }
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'epf/src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'NoStorage') | Out-Null

        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Alpha_SMB'
        $out | Should -Match 'Beta_ACC'
        $out | Should -Match 'epf'
        $out | Should -Not -Match 'NoStorage'
    }

    It 'зупиняється, коли продуктів немає' {
        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'жодного продукту'
    }

    It 'явний -Product передається як є' {
        $out = & pwsh -NoProfile -File $script:build -RepoRoot $script:tmp -Product 'Gamma_SMB' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Gamma_SMB'
    }
}
