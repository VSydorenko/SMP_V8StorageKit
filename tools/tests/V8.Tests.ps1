BeforeAll {
    Import-Module "$PSScriptRoot/../lib/V8.psm1" -Force
}

Describe 'ConvertTo-V8IbSwitch' {
    It 'перетворює файловий рядок підключення на /F' {
        ConvertTo-V8IbSwitch -Connection 'File=C:\bases\demo;' |
            Should -Be '/F "C:\bases\demo"'
    }

    It 'перетворює серверний рядок підключення на /S' {
        ConvertTo-V8IbSwitch -Connection 'Srvr=SRV01;Ref=DEMO_BASE;' |
            Should -Be '/S "SRV01\DEMO_BASE"'
    }

    It 'не залежить від регістру ключів і зайвих пробілів' {
        ConvertTo-V8IbSwitch -Connection '  srvr = SRV01 ; ref = DEMO_BASE ; ' |
            Should -Be '/S "SRV01\DEMO_BASE"'
    }

    It 'не приймає голий шлях без File= (issue #9 — форма без ключа заборонена)' {
        { ConvertTo-V8IbSwitch -Connection 'C:\bases\demo' } | Should -Throw '*File=*'
    }

    It 'кидає виняток на порожньому значенні' {
        { ConvertTo-V8IbSwitch -Connection '' } | Should -Throw
    }

    It 'кидає виняток на формі в лапках (Уніка на ній не підключається до серверної бази, issue #9)' {
        { ConvertTo-V8IbSwitch -Connection 'Srvr="SRV01";Ref="DEMO_BASE";' } | Should -Throw '*лапк*'
    }
}

Describe 'ConvertFrom-V8Connection — єдиний розбір рядка підключення (issue #9)' {
    It 'серверний рядок без лапок → Kind server, Server і Ref окремо' {
        $r = ConvertFrom-V8Connection -Connection 'Srvr=SRV01;Ref=DEMO_BASE;'
        $r.Kind | Should -Be 'server'
        $r.Server | Should -Be 'SRV01'
        $r.Ref | Should -Be 'DEMO_BASE'
    }

    It 'пробіли довкола ключа й значення обрізаються' {
        $r = ConvertFrom-V8Connection -Connection 'Srvr = SRV01 ; Ref = DEMO_BASE ;'
        $r.Server | Should -Be 'SRV01'
        $r.Ref | Should -Be 'DEMO_BASE'
    }

    It 'кінцева ";" необов''язкова' {
        $r = ConvertFrom-V8Connection -Connection 'Srvr=SRV01;Ref=DEMO_BASE'
        $r.Kind | Should -Be 'server'
    }

    It 'зворотний порядок ключів дає той самий результат (незалежність від порядку)' {
        $forward  = ConvertFrom-V8Connection -Connection 'Srvr=SRV01;Ref=DEMO_BASE;'
        $backward = ConvertFrom-V8Connection -Connection 'Ref=DEMO_BASE;Srvr=SRV01;'
        $forward.Server | Should -Be $backward.Server
        $forward.Ref | Should -Be $backward.Ref
        (ConvertTo-V8IbSwitch -Connection 'Ref=DEMO_BASE;Srvr=SRV01;') | Should -Be (ConvertTo-V8IbSwitch -Connection 'Srvr=SRV01;Ref=DEMO_BASE;')
    }

    It 'регістр ключів не важливий (SRVR, srvr, Srvr — той самий результат)' {
        $r = ConvertFrom-V8Connection -Connection 'SRVR=SRV01;ref=DEMO_BASE;'
        $r.Kind | Should -Be 'server'
        $r.Server | Should -Be 'SRV01'
    }

    It 'File= абсолютний зберігається як є' {
        (ConvertFrom-V8Connection -Connection 'File=C:\bases\demo').File | Should -Be 'C:\bases\demo'
    }

    It 'File= відносний зберігається як є (розв''язання — робота викликача, не цієї функції)' {
        (ConvertFrom-V8Connection -Connection 'File=build/ib').File | Should -Be 'build/ib'
    }

    It 'кидає на порожньому рядку' {
        { ConvertFrom-V8Connection -Connection '' } | Should -Throw
    }

    It 'кидає на значенні в лапках і показує виправлену форму без лапок' {
        $err = $null
        try { ConvertFrom-V8Connection -Connection 'Srvr="SRV01";Ref="DEMO_BASE";' } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*лапк*'
        $err | Should -BeLike '*Srvr=SRV01;Ref=DEMO_BASE;*'
    }

    It 'кидає на лапках і в File= теж' {
        { ConvertFrom-V8Connection -Connection 'File="C:\bases\demo"' } | Should -Throw '*лапк*'
    }

    It 'кидає на Srvr= без Ref=' {
        { ConvertFrom-V8Connection -Connection 'Srvr=SRV01;' } | Should -Throw
    }

    It 'кидає на Ref= без Srvr=' {
        { ConvertFrom-V8Connection -Connection 'Ref=DEMO_BASE;' } | Should -Throw
    }

    It 'кидає, коли Srvr= і File= задано одночасно' {
        { ConvertFrom-V8Connection -Connection 'Srvr=SRV01;Ref=DEMO_BASE;File=C:\x;' } | Should -Throw
    }

    It 'кидає на невідомому ключі' {
        { ConvertFrom-V8Connection -Connection 'Usr=admin;File=C:\x;' } | Should -Throw '*Usr*'
    }

    It 'кидає на голому шляху без File=' {
        { ConvertFrom-V8Connection -Connection 'C:\bases\demo' } | Should -Throw
    }

    It 'кидає на порожньому значенні ключа' {
        { ConvertFrom-V8Connection -Connection 'File=' } | Should -Throw
    }
}

Describe 'Assert-NoLicenseProblem' {
    It 'пропускає чистий рядок без згадки ліцензії' {
        InModuleScope V8 {
            { Assert-NoLicenseProblem -Output 'Конфигурация обновлена успешно' } | Should -Not -Throw
        }
    }

    It 'кидає виняток, якщо у виводі є HASP' {
        InModuleScope V8 {
            { Assert-NoLicenseProblem -Output 'Ошибка: HASP-ключ не найден' } | Should -Throw
        }
    }

    It 'кидає виняток, якщо у виводі є "лиценз"' {
        InModuleScope V8 {
            { Assert-NoLicenseProblem -Output 'Не удалось получить лицензию' } | Should -Throw
        }
    }

    It 'пропускає порожній рядок' {
        InModuleScope V8 {
            { Assert-NoLicenseProblem -Output '' } | Should -Not -Throw
        }
    }
}

Describe 'Hide-V8Secrets' {
    It 'Hide-V8Secrets маскує /P і /ConfigurationRepositoryP, лишаючи решту аргументів' {
        Hide-V8Secrets -ArgLine 'DESIGNER /F "x" /N "u" /P "secret" /ConfigurationRepositoryN "gitbot" /ConfigurationRepositoryP "s2" /Out "l"' |
            Should -Be 'DESIGNER /F "x" /N "u" /P "***" /ConfigurationRepositoryN "gitbot" /ConfigurationRepositoryP "***" /Out "l"'
    }
}

Describe 'New-V8FileInfobase (запобіжник шляху, без звернення до платформи)' {
    It 'кидає виняток на шляху поза -MustBeUnder — до Get-V8Path, незалежно від того, чи встановлена платформа' {
        $outside = Join-Path $TestDrive 'not-the-work-dir'
        $boundary = Join-Path $TestDrive 'work-dir'
        New-Item -ItemType Directory -Path $boundary -Force | Out-Null

        { New-V8FileInfobase -Path $outside -MustBeUnder $boundary } | Should -Throw '*не є підтекою*'
    }

    It 'кидає виняток на порожньому Path' {
        $boundary = Join-Path $TestDrive 'work-dir-2'
        New-Item -ItemType Directory -Path $boundary -Force | Out-Null

        { New-V8FileInfobase -Path '' -MustBeUnder $boundary } | Should -Throw
    }

    It 'кидає виняток на неіснуючому -TemplatePath — до Get-V8Path, незалежно від того, чи встановлена платформа' {
        $boundary = Join-Path $TestDrive 'work-dir-3'
        New-Item -ItemType Directory -Path $boundary -Force | Out-Null
        $missing = Join-Path $TestDrive 'no-such.dt'

        { New-V8FileInfobase -Path (Join-Path $boundary 'ib') -MustBeUnder $boundary -TemplatePath $missing } |
            Should -Throw "*$missing*"
    }
}

Describe 'New-ExtensionInfobase' -Tag 'Integration' {
    It 'створює базу з розширенням, адресованим під заданим іменем' {
        $ib = Join-Path $TestDrive 'ext-ib'
        $stub = Join-Path $PSScriptRoot '../assets/empty-extension'

        $ibSwitch = New-ExtensionInfobase -Path $ib -ExtensionName 'PROBE_EXT' -StubPath $stub -MustBeUnder $TestDrive
        $ibSwitch | Should -Be ('/F "{0}"' -f $ib)

        $dump = Join-Path $TestDrive 'ext-dump'
        New-Item -ItemType Directory -Path $dump -Force | Out-Null
        $res = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
            '/DumpConfigToFiles "{0}" -Extension PROBE_EXT' -f $dump)
        $res.ExitCode | Should -Be 0
        Test-Path (Join-Path $dump 'Configuration.xml') | Should -BeTrue

        $dumpMissing = Join-Path $TestDrive 'ext-dump-missing'
        New-Item -ItemType Directory -Path $dumpMissing -Force | Out-Null
        $resMissing = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
            '/DumpConfigToFiles "{0}" -Extension NEVER_CREATED' -f $dumpMissing)
        $resMissing.ExitCode | Should -Not -Be 0
    }
}

Describe 'New-V8FileInfobase -TemplatePath: розгортання з .dt' -Tag Integration {
    It 'створює базу з реального .dt (CREATEINFOBASE /UseTemplate) — і рахунок доходить до /UseTemplate у аргументах' {
        # .dt робимо самі: порожня ІБ -> /DumpIB. Тест не залежить від чужих файлів (той
        # самий прийом, що в Provision.Tests.ps1 Integration BeforeAll).
        $srcIb = New-V8FileInfobase -Path (Join-Path $TestDrive 'dt-src/ib') -MustBeUnder (Join-Path $TestDrive 'dt-src')
        $dt = Join-Path $TestDrive 'template.dt'
        (Invoke-V8Designer -IbSwitch ('/F "{0}"' -f $srcIb) -Arguments @('/DumpIB "{0}"' -f $dt)).ExitCode | Should -Be 0
        Test-Path -LiteralPath $dt -PathType Leaf | Should -BeTrue

        $target = Join-Path $TestDrive 'from-template/ib'
        $result = New-V8FileInfobase -Path $target -MustBeUnder (Join-Path $TestDrive 'from-template') -TemplatePath $dt
        $result | Should -Be $target
        Join-Path $target '1Cv8.1CD' | Should -Exist
    }
}

Describe 'V8.psm1 — розпізнавання «база зайнята» (спека §5)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }

    It 'російський, український і англійський тексти платформи розпізнаються' -ForEach @(
        @{ Text = 'Ошибка блокировки информационной базы для конфигурирования. Информационная база уже открыта Конфигуратором' }
        @{ Text = 'Не удалось монопольно заблокировать информационную базу' }
        @{ Text = 'Помилка блокування інформаційної бази для конфігурування' }
        @{ Text = 'Не вдалося монопольно заблокувати інформаційну базу' }
        @{ Text = 'Error locking infobase for configuration. The infobase is already opened by Designer' }
        @{ Text = 'Failed to lock the infobase exclusively' }
    ) {
        Test-V8InfobaseBusy -Output $Text | Should -BeTrue
    }

    It 'інший текст і порожній вивід — не «зайнято»' {
        Test-V8InfobaseBusy -Output 'Неверные или отсутствующие параметры соединения' | Should -BeFalse
        Test-V8InfobaseBusy -Output '' | Should -BeFalse
    }

    It 'Assert-V8InfobaseNotBusy: порада «закрийте Конфігуратор» першою, сирий текст — у кінці; на іншому тексті мовчить' {
        $raw = 'Информационная база уже открыта Конфигуратором'
        $err = $null
        try { Assert-V8InfobaseNotBusy -Output $raw -Infobase 'devUNF' } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err.IndexOf('закрийте Конфігуратор', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeLessThan $err.IndexOf($raw)
        $err | Should -BeLike '*devUNF*.cfl*'
        { Assert-V8InfobaseNotBusy -Output 'усе гаразд' -Infobase 'devUNF' } | Should -Not -Throw
    }
}
