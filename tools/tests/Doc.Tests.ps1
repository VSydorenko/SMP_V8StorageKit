#Requires -Version 7
# doc (перенесено з agent-kit 0.9.1): три запобіжники, чия поломка мовчки дає хибний результат.
# Перші два — на lib-модулі прямим Import-Module; третій — справжня команда `doc` підпроцесом.
Describe 'doc — запобіжники' {
    BeforeAll {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/KitDoc.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It '§6.4 і 6.4 знаходять розділ «6.4 …», але не «6.40 …» і не «6.4.1 …»' {
        $file = Join-Path $TestDrive 'spec.md'
        [System.IO.File]::WriteAllText($file, "# Спека`n## 6.4 Перший`nтекст`n## 6.40 Другий`nтекст`n### 6.4.1 Третій`nтекст`n")
        foreach ($query in '§6.4', '6.4') {
            $r = Invoke-DocCommand -Positional @('spec.md', $query) -RepoRoot $TestDrive -WorkDir $TestDrive
            $r.Code | Should -Be 0 -Because "запит $query має мати єдиний збіг"
            # Розділ 6.4 — рядки 2–3; 6.40 починається з 4-го і до тіла не входить.
            $r.Lines[0] | Should -BeLike 'spec.md:2-3 *'
            # Без рядка next: — той легально називає 6.40 як наступний розділ.
            (($r.Lines | Select-Object -SkipLast 1) -join "`n") | Should -Not -Match '6\.40'
        }
    }

    It '`# коментар` усередині фенса ``` і ~~~ (з ``` усередині) не є заголовком' {
        $file = Join-Path $TestDrive 'fence.md'
        $text = @'
# Справжній

```bash
# коментар один
```

~~~
```
# коментар два
~~~

````
```
# коментар три
````

```
```bash
# коментар чотири
```

## Після
'@
        [System.IO.File]::WriteAllText($file, $text)
        $r = Invoke-DocCommand -Positional @('fence.md') -RepoRoot $TestDrive -WorkDir $TestDrive
        $r.Code | Should -Be 0
        $toc = $r.Lines -join "`n"
        $toc | Should -Not -Match 'коментар'
        $toc | Should -Match 'Справжній'
        $toc | Should -Match 'Після'
    }

    It 'anchors на справжній команді: кириличний шлях 1С без файла — код 1, коли файл є — код 0' {
        $kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $kitRoot = Split-Path (Split-Path $kit -Parent) -Parent
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs'), (Join-Path $repo '.agents') -Force | Out-Null
        git -C $repo init -q 2>$null
        [System.IO.File]::WriteAllText((Join-Path $repo '.agents/kit.profile.json'), '{ "docs": { "docs": "docs", "anchors": { "roots": ["src"] } } }')
        $inTicks = 'src/cf/Catalogs/Номенклатура/Ext/ObjectModule.bsl'
        $bare = 'src/cf/Catalogs/Номенклатура/Forms/Форма/Ext/Form/Module.bsl'
        # Шлях у зворотних лапках перевіряється як токен, голий — регулярним виразом шляху: саме він
        # мусить приймати кирилицю, інакше такі шляхи мовчки пропускались би.
        [System.IO.File]::WriteAllText((Join-Path $repo 'docs/a.md'), "# A`n`n``$inTicks`` і голий $bare далі.`n")

        function Invoke-DocAnchors {
            Push-Location $repo
            try {
                $out = & pwsh -NoProfile -File (Join-Path $kitRoot 'tools/kit-process.ps1') doc anchors 2>&1 | ForEach-Object { [string]$_ }
                [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
            } finally { Pop-Location }
        }

        $missing = Invoke-DocAnchors
        $missing.Code | Should -Be 1
        $missing.Out | Should -Match ([regex]::Escape($inTicks))
        $missing.Out | Should -Match ([regex]::Escape($bare))

        foreach ($p in $inTicks, $bare) {
            $full = Join-Path $repo $p
            New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, '')
        }
        $present = Invoke-DocAnchors
        $present.Code | Should -Be 0 -Because $present.Out
    }
}
