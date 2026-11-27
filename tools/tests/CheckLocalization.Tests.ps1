#Requires -Version 7
# Скрипт скіла 1c-localization, вада 5: назва події журналу реєстрації — НСтр без коду мови (мовою сеансу),
# а #std498 п. 2.1 вимагає основну мову конфігурації. Скрипт запускається окремим pwsh, як у CI споживача,
# на підставному корені вихідників у TestDrive: вадні форми мусять дати знахідку й код 1, правильні — мовчати.
Describe 'check-localization.ps1 — назва події журналу реєстрації' {
    BeforeAll {
        $script:Script = (Resolve-Path "$PSScriptRoot/../../skills/1c-localization/scripts/check-localization.ps1").Path
        function script:New-Root {
            param([string]$Name, [string[]]$Langs, [string]$Bsl)
            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path (Join-Path $root 'Languages'), (Join-Path $root 'CommonModules/М/Ext') | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Configuration.xml') -Value '<Configuration/>'
            foreach ($l in $Langs) {
                Set-Content -LiteralPath (Join-Path $root "Languages/$l.xml") `
                    -Value "<Language><Properties><LanguageCode>$l</LanguageCode></Properties></Language>"
            }
            # Вихідники 1С — UTF-8 з BOM і CRLF.
            $text = $Bsl.Replace("`r`n", "`n").Replace("`n", "`r`n")
            [System.IO.File]::WriteAllText((Join-Path $root 'CommonModules/М/Ext/Module.bsl'), $text, [System.Text.UTF8Encoding]::new($true))
            $root
        }
        function script:Invoke-Check([string]$Root) {
            $out = @(& pwsh -NoProfile -File $script:Script $Root)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Events = @($out | Where-Object { $_ -like '*назва події журналу*' }) }
        }
    }

    It 'НСтр без коду мови — знахідка й код 1: <Case>' -ForEach @(
        @{ Case = 'один рядок'; Bsl = "ЗаписьЖурналаРегистрации(НСтр(""ru = 'М.Событие'; uk = 'М.Подія'""), УровеньЖурналаРегистрации.Ошибка);" }
        @{ Case = 'виклик розбито на рядки'; Bsl = "ЗаписьЖурналаРегистрации(`n`tНСтр(""ru = 'М.Событие'; uk = 'М.Подія'""),`n`tУровеньЖурналаРегистрации.Ошибка);" }
        @{ Case = 'багаторядковий літерал'; Bsl = "ЗаписьЖурналаРегистрации(НСтр(""ru = 'М.Событие';`n`t|uk = 'М.Подія'""), УровеньЖурналаРегистрации.Ошибка);" }
    ) {
        $r = Invoke-Check (New-Root -Name "bad-$($Case.GetHashCode())" -Langs 'ru', 'uk' -Bsl $Bsl)
        $r.Events.Count | Should -Be 1
        $r.ExitCode | Should -Be 1
    }

    It 'НСтр з кодом основної мови (і коментар без коду) — без знахідки: <Case>' -ForEach @(
        @{ Case = 'код у тому ж рядку'; Bsl = "ЗаписьЖурналаРегистрации(НСтр(""ru = 'М.Событие'; uk = 'М.Подія'"", КодОсновногоЯзыка), УровеньЖурналаРегистрации.Ошибка);" }
        @{ Case = 'код наступним рядком'; Bsl = "ЗаписьЖурналаРегистрации(`n`tНСтр(""ru = 'М.Событие'; uk = 'М.Подія'"",`n`tОбщегоНазначения.КодОсновногоЯзыка()), УровеньЖурналаРегистрации.Ошибка, , , НСтр(""ru = 'Коммент'; uk = 'Коментар'""));" }
    ) {
        $r = Invoke-Check (New-Root -Name "good-$($Case.GetHashCode())" -Langs 'ru', 'uk' -Bsl $Bsl)
        $r.Events.Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }

    It 'одна мова конфігурації — мова сеансу й основна збігаються, без знахідки' {
        $bsl = "ЗаписьЖурналаРегистрации(НСтр(""ru = 'М.Событие'""), УровеньЖурналаРегистрации.Ошибка);"
        $r = Invoke-Check (New-Root -Name 'one-lang' -Langs 'ru' -Bsl $bsl)
        $r.Events.Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }
}
