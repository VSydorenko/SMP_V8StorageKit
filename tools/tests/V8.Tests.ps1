BeforeAll {
    Import-Module "$PSScriptRoot/../lib/V8.psm1" -Force
}

Describe 'ConvertTo-V8IbSwitch' {
    It 'перетворює файловий рядок підключення на /F' {
        ConvertTo-V8IbSwitch -Connection 'File="C:\bases\demo";' |
            Should -Be '/F "C:\bases\demo"'
    }

    It 'перетворює серверний рядок підключення на /S' {
        ConvertTo-V8IbSwitch -Connection 'Srvr="SRV01";Ref="DEMO_BASE";' |
            Should -Be '/S "SRV01\DEMO_BASE"'
    }

    It 'не залежить від регістру ключів і зайвих пробілів' {
        ConvertTo-V8IbSwitch -Connection '  srvr = "SRV01" ; ref = "DEMO_BASE" ; ' |
            Should -Be '/S "SRV01\DEMO_BASE"'
    }

    It 'приймає голий шлях як файлову базу' {
        ConvertTo-V8IbSwitch -Connection 'C:\bases\demo' |
            Should -Be '/F "C:\bases\demo"'
    }

    It 'кидає виняток на порожньому значенні' {
        { ConvertTo-V8IbSwitch -Connection '' } | Should -Throw
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
