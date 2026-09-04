#Requires -Version 7
Describe 'TreeCompare.psm1 — дерево з git як сирі блоби' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'байти дорівнюють блобу навіть під * text eol=crlf і core.autocrlf=true; кириличні шляхи й вкладені теки цілі' {
        # ПОРЯДОК ВАЖЛИВИЙ (рев'ю B3, доведено пробою): явний атрибут `text` нормалізує блоб у LF на вході
        # незалежно від core.autocrlf, тож .gitattributes кладеться ПІСЛЯ коміту змішаного файла. Переставляти
        # кроки можна; послаблювати твердження нижче — ні: вони і є гарантія, заради якої існує Export-KitTree.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'raw')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/Forms/Форма/Ext'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $mixed = [byte[]](0x3C,0x61,0x3E,0x0D,0x0A,0x74,0x0A,0x74,0x3C,0x2F,0x61,0x3E)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'Form.xml'), $mixed)
        git -C $repo -c core.autocrlf=false add -A
        git -C $repo commit -q -m 'змішані кінці рядків як є'
        $rawId = (git -C $repo hash-object --no-filters (Join-Path $dir 'Form.xml')).Trim()
        (git -C $repo rev-parse 'main:Alpha_SMB/cfe/src/Forms/Форма/Ext/Form.xml').Trim() | Should -Be $rawId -Because 'блоб мусить лишитись змішаним — інакше тест перевіряє не те'
        # Тепер — умови, за яких checkout і archive конвертують, а Export-KitTree не має:
        git -C $repo config core.autocrlf true
        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value '* text eol=crlf' -Encoding ascii
        git -C $repo add .gitattributes
        git -C $repo commit -q -m 'політика eol=crlf після факту'

        $dest = Join-Path $repo 'build/verify/x/tree'
        $n = Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination $dest
        $n | Should -Be 2   # Configuration.xml фікстури + Form.xml
        $exported = Join-Path $dest 'Forms/Форма/Ext/Form.xml'
        $exported | Should -Exist
        [System.IO.File]::ReadAllBytes($exported) | Should -Be $mixed
        (git -C $repo hash-object --no-filters $exported).Trim() | Should -Be $rawId
    }

    It 'шлях, якого немає в ref — 0 файлів, порожня тека' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'empty')
        $dest = Join-Path $repo 'build/verify/x/tree'
        Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Nope/cfe/src' -Destination $dest | Should -Be 0
        @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count | Should -Be 0
    }

    It 'призначення поза build/ — відмова' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsafe')
        { Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination (Join-Path $repo 'Alpha_SMB') } | Should -Throw '*build*'
    }
}

Describe 'TreeCompare.psm1 — класифікація розбіжностей (§3.5)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path -Force
        $script:Dump = Join-Path $TestDrive 'dump'
        $script:Tree = Join-Path $TestDrive 'tree'
        foreach ($d in $script:Dump, $script:Tree) { New-Item -ItemType Directory -Path (Join-Path $d 'Ext') -Force | Out-Null }
        function script:W { param($Root, $Rel, [byte[]]$Bytes) [System.IO.File]::WriteAllBytes((Join-Path $Root $Rel), $Bytes) }
        $lf   = [System.Text.Encoding]::UTF8.GetBytes("a`nb`n")
        $crlf = [System.Text.Encoding]::UTF8.GetBytes("a`r`nb`r`n")
        $other = [System.Text.Encoding]::UTF8.GetBytes("a`nc`n")

        W $script:Dump 'equal.xml' $lf;        W $script:Tree 'equal.xml' $lf
        W $script:Dump 'cr-only.xml' $lf;      W $script:Tree 'cr-only.xml' $crlf
        W $script:Dump 'content.bsl' $lf;      W $script:Tree 'content.bsl' $other
        W $script:Dump 'only-dump.xml' $lf
        W $script:Tree 'only-tree.xml' $lf
        W $script:Dump 'Ext/pic.png' $lf;      W $script:Tree 'Ext/pic.png' $crlf      # binary: лише побайтово
        W $script:Dump 'ConfigDumpInfo.xml' $lf                                          # завжди ігнорується
        W $script:Tree 'DumpFilesIndex.txt' $lf                                          # завжди ігнорується

        $script:Binary = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $script:Binary.Add('Ext/pic.png') | Out-Null
    }

    It 'п''ять категорій, бінарник із різницею лише в CR — змістовна, службові файли не рахуються' {
        $r = Compare-KitTrees -DumpDir $script:Dump -TreeDir $script:Tree -BinaryPaths $script:Binary
        $r.Equal | Should -Be 1
        $r.CrOnly | Should -Be @('cr-only.xml')
        $r.Content | Should -Be @('Ext/pic.png', 'content.bsl')   # ordinal: 'E' (0x45) < 'c' (0x63); Sort-Object дав би навпаки
        $r.OnlyInDump | Should -Be @('only-dump.xml')
        $r.OnlyInTree | Should -Be @('only-tree.xml')
        $r.Total | Should -Be 6
    }

    It 'Get-KitRelativeFiles: шляхи з /, без ConfigDumpInfo.xml і DumpFilesIndex.txt' {
        $files = @(Get-KitRelativeFiles -Root $script:Dump)
        $files | Should -Contain 'Ext/pic.png'
        $files | Should -Not -Contain 'ConfigDumpInfo.xml'
    }

    It 'Get-KitBinaryPaths не зависає на обсязі реального дампу (800 кириличних шляхів)' {
        # Проба рев'ю B3: наївний «увесь stdin, потім ReadToEnd()» зависав назавжди від ~800 записів (буфер stdout).
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bulk') -WithGitattributes
        $paths = @(1..800 | ForEach-Object { "Catalogs/ДовгеІмʼяОбʼєкта_$_.xml" }) + @('Ext/pic.png')
        $set = Get-KitBinaryPaths -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -RelativePaths $paths
        $set.Contains('Ext/pic.png') | Should -BeTrue
        $set.Count | Should -Be 1
    }

    It 'Get-KitBinaryPaths питає git check-attr, а не читає .gitattributes' {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'attr') -WithGitattributes
        $set = Get-KitBinaryPaths -RepoRoot $repo -RepoPath 'Alpha_SMB/cfe/src' -RelativePaths @('Ext/pic.png', 'Forms/Форма.xml', 'Ext/driver.bin')
        $set.Contains('Ext/pic.png') | Should -BeTrue
        $set.Contains('Ext/driver.bin') | Should -BeTrue
        $set.Contains('Forms/Форма.xml') | Should -BeFalse
    }
}
