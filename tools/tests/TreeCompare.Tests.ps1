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

    It 'великий блоб (≥200 КБ, повторні часткові читання Stream.Read) — байти й хеш збігаються (рев''ю B3, Important 2)' {
        # Копіювання циклом Copy-KitStreamBytes на малих файлах (12 байт, кілька сотень) жоден тест не
        # охороняє від вирізання циклу на єдиний Stream.Read: на такому розмірі Read завжди повертає
        # все за один виклик. Рев'ю виміряв на блобі 1 МБ: один Read(buf, 0, 65536) повернув 16384
        # байти з 65536 запитаних — часткові читання це норма, а не теорія. Файл нижче — 200000+ байт
        # зі змішаними CRLF/LF, щоб цикл виконався десятки разів по 65536-байтному буферу.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'big-blob')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/Ext'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $rnd = [System.Random]::new(42)
        $sb = [System.Text.StringBuilder]::new()
        while ($sb.Length -lt 200000) {
            $eol = if ($rnd.Next(2) -eq 0) { "`r`n" } else { "`n" }
            [void]$sb.Append(('x' * $rnd.Next(10, 80)) + $eol)
        }
        $bigBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'big.bsl'), $bigBytes)
        git -C $repo -c core.autocrlf=false add -A
        git -C $repo commit -q -m 'великий файл зі змішаними кінцями рядків'
        $rawId = (git -C $repo hash-object --no-filters (Join-Path $dir 'big.bsl')).Trim()

        $dest = Join-Path $repo 'build/verify/x/tree-big'
        Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination $dest | Out-Null
        $exported = Join-Path $dest 'Ext/big.bsl'
        $exported | Should -Exist
        (Get-Item -LiteralPath $exported).Length | Should -Be $bigBytes.Length
        [System.IO.File]::ReadAllBytes($exported) | Should -Be $bigBytes
        (git -C $repo hash-object --no-filters $exported).Trim() | Should -Be $rawId
    }

    It 'блоб нульового розміру — файл створюється порожнім (край протоколу cat-file --batch)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'zero-blob')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/Ext'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'empty.txt'), [byte[]]@())
        git -C $repo add -A
        git -C $repo commit -q -m 'порожній файл'

        $dest = Join-Path $repo 'build/verify/x/tree-zero'
        Export-KitTree -RepoRoot $repo -Ref 'main' -RepoPath 'Alpha_SMB/cfe/src' -Destination $dest | Out-Null
        $exported = Join-Path $dest 'Ext/empty.txt'
        $exported | Should -Exist
        (Get-Item -LiteralPath $exported).Length | Should -Be 0
    }

    It 'кириличні шляхи цілі незалежно від амбієнтного [Console]::OutputEncoding дочірнього процесу (рев''ю B3, Important 3)' {
        # Дефект (рев'ю B3): ls-tree йшов голим нативним викликом git, а PowerShell декодує вивід
        # такого виклику за амбієнтним [Console]::OutputEncoding процесу — на cp866 кириличний шлях
        # перетворювався на сміття (рев'ю виміряв: 5 символів на 10 сміттєвих, Test-Path -> False).
        # Run-Tests.ps1 сам виставляє UTF-8 на весь прогін, тож без ОКРЕМОГО дочірнього процесу з
        # іншим кодуванням цей клас дефекту не побачити (той самий прийом, що в
        # RepoRoot.Tests.ps1:65-91). Форсуємо cp866 явно в дочірньому процесі — не покладаємось на
        # амбієнтну кодову сторінку цієї машини.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cyr-encoding')
        $dir = Join-Path $repo 'Alpha_SMB/cfe/src/Forms/Форма'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Форма.xml') -Value 'x' -Encoding UTF8 -NoNewline
        git -C $repo add -A
        git -C $repo commit -q -m 'кириличний шлях'

        $dest = Join-Path $repo 'build/verify/x/tree-cyr'
        $modulePath = (Resolve-Path "$PSScriptRoot/../lib/TreeCompare.psm1").Path
        $script = Join-Path $TestDrive 'cp866-export.ps1'
        Set-Content -LiteralPath $script -Encoding UTF8 -Value @(
            'param($Repo, $ModulePath, $Dest)'
            '[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(866)'
            'Import-Module $ModulePath -Force'
            'Export-KitTree -RepoRoot $Repo -Ref ''main'' -RepoPath ''Alpha_SMB/cfe/src'' -Destination $Dest | Out-Null'
        )
        & pwsh -NoProfile -File $script -Repo $repo -ModulePath $modulePath -Dest $dest 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Join-Path $dest 'Forms/Форма/Форма.xml') | Should -Exist
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
