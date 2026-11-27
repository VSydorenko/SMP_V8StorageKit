#Requires -Version 7
# Скрипт скіла 1c-shared-core: ідентичність спільного ядра в кількох редакціях. Скрипт запускається окремим
# pwsh, як у CI споживача, на підставних деревах редакцій у TestDrive. Кожна вада ядра мусить дати код 1, вада
# виклику чи переліку — код 2, а зміна поза тим, що порівнюється, — код 0.
Describe 'check-core-identity.ps1 — ідентичність ядра' {
    BeforeAll {
        $script:Script = (Resolve-Path "$PSScriptRoot/../../skills/1c-shared-core/scripts/check-core-identity.ps1").Path
        $script:ModuleXml = '<?xml version="1.0" encoding="UTF-8"?><MetaDataObject xmlns="x"><CommonModule uuid="{0}"><Properties><Name>М</Name></Properties></CommonModule></MetaDataObject>'
        $script:Bsl = @(
            '// Ядро: однаковий текст.'
            'Функция Ядро() Экспорт'
            '	Возврат 1;'
            'КонецФункции'
            ''
            '&НаСервере'
            'Процедура ЯдроПроцедура() Экспорт'
            '	А = 1;'
            'КонецПроцедуры'
            ''
            'Функция Адаптация() Экспорт'
            '	Возврат "{0}";'
            'КонецФункции'
        ) -join "`r`n"
        $script:BorrowedXml = '<MetaDataObject xmlns="x"><Catalog uuid="{0}"><InternalInfo/><Properties><Name>К</Name><ObjectBelonging>Adopted</ObjectBelonging><ExtendedConfigurationObject>{1}</ExtendedConfigurationObject></Properties></Catalog></MetaDataObject>'
        $script:BaseXml = '<MetaDataObject xmlns="x"><Catalog uuid="{0}"><Properties><Name>К</Name></Properties></Catalog></MetaDataObject>'

        function script:Write-Utf8([string]$Path, [string]$Text) {
            New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
            [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($true))
        }
        # Редакція: модуль ядра (UUID, текст з адаптаційною функцією) і запозичений довідник; база — довідник.
        function script:New-Edition {
            param([string]$Name, [string]$Uuid = '11111111-1111-1111-1111-111111111111', [string]$Adapt = 'RU',
                [string]$Body = $null, [string]$Extended = '22222222-2222-2222-2222-222222222222')
            $root = Join-Path $TestDrive "$Name/cfe"
            $base = Join-Path $TestDrive "$Name/cf"
            Write-Utf8 (Join-Path $root 'CommonModules/М.xml') ($script:ModuleXml -f $Uuid)
            Write-Utf8 (Join-Path $root 'CommonModules/М/Ext/Module.bsl') $(if ($Body) { $Body } else { $script:Bsl -f $Adapt })
            Write-Utf8 (Join-Path $root 'Catalogs/К.xml') ($script:BorrowedXml -f '33333333-3333-3333-3333-333333333333', $Extended)
            Write-Utf8 (Join-Path $base 'Catalogs/К.xml') ($script:BaseXml -f '22222222-2222-2222-2222-222222222222')
            [pscustomobject]@{ Root = $root; Base = $base }
        }
        function script:Invoke-Check {
            param([object[]]$Eds, [string[]]$Lines, [switch]$NoBases)
            $list = Join-Path $TestDrive "list-$([guid]::NewGuid()).txt"
            [System.IO.File]::WriteAllLines($list, $Lines)
            $a = @('-NoProfile', '-File', $script:Script, '-List', $list, '-Editions', (($Eds | ForEach-Object { $_.Root }) -join ','))
            if (-not $NoBases) { $a += @('-Bases', (($Eds | ForEach-Object { $_.Base }) -join ',')) }
            $out = @(& pwsh @a 2>&1)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Diff = @($out | Where-Object { "$_" -like 'DIFF*' }) }
        }
        $script:Core = @(
            '# перелік ядра'
            'uuid      CommonModules/М.xml'
            'bytes     CommonModules/М.xml'
            'function  CommonModules/М/Ext/Module.bsl  Ядро'
            'function  CommonModules/М/Ext/Module.bsl  ЯдроПроцедура'
            'borrowed  Catalogs/К.xml'
        )
    }

    It 'однакове ядро, різна адаптація поза переліком — код 0' {
        $r = Invoke-Check @((New-Edition 'a0'), (New-Edition 'b0' -Adapt 'UA')) $script:Core
        $r.Diff.Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }

    It 'один змінений байт у файлі ядра — код 1 (контроль, що перевірка вміє впасти)' {
        $a = New-Edition 'a1'; $b = New-Edition 'b1'
        $f = Join-Path $b.Root 'CommonModules/М.xml'
        [System.IO.File]::WriteAllBytes($f, [byte[]]([System.IO.File]::ReadAllBytes($f) + [byte]0x20))
        $r = Invoke-Check @($a, $b) @('bytes CommonModules/М.xml')
        $r.Diff.Count | Should -Be 1
        $r.ExitCode | Should -Be 1
    }

    It 'інший UUID модуля — код 1' {
        $r = Invoke-Check @((New-Edition 'a2'), (New-Edition 'b2' -Uuid '99999999-9999-9999-9999-999999999999')) @('uuid CommonModules/М.xml')
        $r.ExitCode | Should -Be 1
    }

    It 'змінено тіло процедури ядра — код 1; директива над нею входить у порівняння' {
        $body = ($script:Bsl -f 'RU').Replace('&НаСервере', '&НаКлиенте')
        $r = Invoke-Check @((New-Edition 'a3'), (New-Edition 'b3' -Body $body)) @('function CommonModules/М/Ext/Module.bsl ЯдроПроцедура')
        $r.ExitCode | Should -Be 1
    }

    It 'третя редакція відрізняється від першої — код 1' {
        $r = Invoke-Check @((New-Edition 'a4'), (New-Edition 'b4'), (New-Edition 'c4' -Body (($script:Bsl -f 'RU').Replace('Возврат 1', 'Возврат 2')))) `
            @('function CommonModules/М/Ext/Module.bsl Ядро')
        $r.ExitCode | Should -Be 1
    }

    It 'запозичення вказує не на об''єкт своєї бази — код 1' {
        $r = Invoke-Check @((New-Edition 'a5'), (New-Edition 'b5' -Extended '44444444-4444-4444-4444-444444444444')) @('borrowed Catalogs/К.xml')
        $r.ExitCode | Should -Be 1
    }

    It 'помилка виклику чи переліку — код 2: <Case>' -ForEach @(
        @{ Case = 'невідома перевірка'; Lines = @('bites CommonModules/М.xml'); One = $false; NoBases = $false }
        @{ Case = 'одна редакція'; Lines = @('bytes CommonModules/М.xml'); One = $true; NoBases = $false }
        @{ Case = 'borrowed без -Bases'; Lines = @('borrowed Catalogs/К.xml'); One = $false; NoBases = $true }
    ) {
        $eds = if ($One) { @(New-Edition "x-$($Case.GetHashCode())") } else { @((New-Edition "x-$($Case.GetHashCode())"), (New-Edition "y-$($Case.GetHashCode())")) }
        $r = Invoke-Check $eds $Lines -NoBases:$NoBases
        $r.ExitCode | Should -Be 2
    }
}
