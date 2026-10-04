#Requires -Version 7
Describe 'CaseGuard.psm1 — шляхи, що різняться лише регістром (спека 2026-10-04 §4.4)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/CaseGuard.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'Get-KitCaseCollisions: кирилична пара — одна група в порядку Ordinal; ASCII-пара теж; різні шляхи — ні' {
        $g = @(Get-KitCaseCollisions -Paths @('a/Образецанализ.xml', 'b/x.xml', 'a/ОбразецАнализ.xml', 'c/Readme.md', 'c/README.md'))
        $g | Should -HaveCount 2
        $g[0] | Should -Be @('a/ОбразецАнализ.xml', 'a/Образецанализ.xml')
        $g[1] | Should -Be @('c/README.md', 'c/Readme.md')
    }

    It 'Get-KitCaseCollisions: порожній вхід і один шлях — порожній результат під StrictMode' {
        @(Get-KitCaseCollisions -Paths @()) | Should -HaveCount 0
        @(Get-KitCaseCollisions -Paths @('a/Форма.xml')) | Should -HaveCount 0
    }

    It 'Get-KitCaseCollisions: однакові шляхи двічі — не група' {
        @(Get-KitCaseCollisions -Paths @('a/Форма.xml', 'a/Форма.xml')) | Should -HaveCount 0
    }

    It 'Get-KitTreePaths: кириличні шляхи цілі, -Path звужує, порожня тека — порожньо' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'paths')
        # Літерал @{} регістронезалежний і відхиляє пару як дубль ключа — потрібен Ordinal-словник.
        $files = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        $files['Alpha_SMB/cfe/src/T/Образецанализ.xml'] = '1'
        $files['Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'] = '2'
        $files['other/x.txt'] = '3'
        Set-KitFakeBranchTree -Repo $repo -Branch 'storage/Alpha_SMB' -Message 'v1' -Files $files | Out-Null
        $all = @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB')
        $all | Should -HaveCount 3
        $src = @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB' -Path 'Alpha_SMB/cfe/src')
        $src | Should -HaveCount 2
        ($src -ccontains 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml') | Should -BeTrue -Because "у переліку: $($src -join ', ')"
        @(Get-KitTreePaths -RepoRoot $repo -Ref 'storage/Alpha_SMB' -Path 'nope') | Should -HaveCount 0
        @(Get-KitCaseCollisions -Paths $src) | Should -HaveCount 1
    }

    It 'Get-KitTreePaths: невідомий ref — виняток з кодом git' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'paths-bad')
        { Get-KitTreePaths -RepoRoot $repo -Ref 'no-such-ref' } | Should -Throw '*git ls-tree*no-such-ref*'
    }

    It 'Assert-KitIndexMatchesDisk: збіг — без винятку; службові файли й поставка на диску не рахуються' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'match')
        $src = Join-Path $repo 'Alpha_SMB/cfe/src'
        Set-Content -LiteralPath (Join-Path $src 'ConfigDumpInfo.xml') -Value 'junk'
        New-Item -ItemType Directory -Path (Join-Path $src 'Ext/ParentConfigurations') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Ext/ParentConfigurations/Vendor.cf') -Value 'cf'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Not -Throw
    }

    It 'Assert-KitIndexMatchesDisk: фантом в індексі (кириличний старий регістр) — виняток з обома переліками' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ghost')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/T'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'ОбразецАнализ.xml') -Value 'x' -NoNewline
        git -C $repo add -- 'Alpha_SMB/cfe/src/T/ОбразецАнализ.xml'
        $sha = (git -C $repo hash-object -w -- (Join-Path $dir 'ОбразецАнализ.xml')).Trim()
        git -C $repo -c core.ignorecase=false update-index --add --cacheinfo "100644,$sha,Alpha_SMB/cfe/src/T/Образецанализ.xml"
        $err = { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "Індекс 'Alpha_SMB/cfe/src' не збігається з деревом на диску*"
        $err.Exception.Message | Should -BeLike '*T/Образецанализ.xml*'
    }

    It 'Assert-KitIndexMatchesDisk: файл, який git ігнорує, на диску не рахується' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ignored')
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value '*.bak' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/local.bak') -Value 'b'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Not -Throw
    }

    It 'Assert-KitIndexMatchesDisk: файл на диску, якого немає в індексі — виняток' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'untracked')
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/cfe/src/New.xml') -Value 'n'
        { Assert-KitIndexMatchesDisk -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' } | Should -Throw '*New.xml*'
    }
}
