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

    It 'парні лапки знімаються: перемикач той самий, що без лапок' {
        ConvertTo-V8IbSwitch -Connection 'Srvr="SRV01";Ref="DEMO_BASE";' | Should -Be '/S "SRV01\DEMO_BASE"'
    }

    It 'кидає виняток на непарній лапці' {
        { ConvertTo-V8IbSwitch -Connection 'Srvr="SRV01;Ref=DEMO_BASE;' } | Should -Throw '*непарні лапки*'
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

    It 'парні лапки навколо значень знімаються: <C>' -ForEach @(
        @{ C = 'Srvr="VSDEV";Ref="SMP_UNF";'; Kind = 'server'; S = 'VSDEV'; R = 'SMP_UNF'; F = $null }
        @{ C = 'File="D:\Bases\X"';          Kind = 'file';   S = $null;   R = $null;     F = 'D:\Bases\X' }
        @{ C = 'Srvr=VSDEV;Ref="SMP_UNF"';    Kind = 'server'; S = 'VSDEV'; R = 'SMP_UNF'; F = $null }
    ) {
        $p = ConvertFrom-V8Connection -Connection $C
        $p.Kind | Should -Be $Kind; $p.Server | Should -Be $S; $p.Ref | Should -Be $R; $p.File | Should -Be $F
    }

    It 'непарна лапка — виняток з ключем: <C>' -ForEach @(
        @{ C = 'Srvr="VSDEV;Ref=SMP_UNF' }
        @{ C = 'Srvr=VS"DEV;Ref=SMP_UNF' }
        @{ C = 'File="D:\a;b"' }
    ) {
        { ConvertFrom-V8Connection -Connection $C } | Should -Throw '*непарні лапки*'
    }

    It 'лапки в імені ключа — виняток' {
        { ConvertFrom-V8Connection -Connection '"Srvr"=VSDEV;Ref=X' } | Should -Throw '*імені ключа*'
    }

    It 'порожнє значення в лапках (Ref="") — порожнє значення, не база з порожнім Ref' {
        { ConvertFrom-V8Connection -Connection 'Srvr=VSDEV;Ref="";' } | Should -Throw '*порожнє значення*'
    }

    It 'кидає на Srvr= без Ref=' {
        { ConvertFrom-V8Connection -Connection 'Srvr=SRV01;' } | Should -Throw '*бракує Ref=*'
    }

    It 'кидає на Ref= без Srvr=' {
        { ConvertFrom-V8Connection -Connection 'Ref=DEMO_BASE;' } | Should -Throw '*бракує Srvr=*'
    }

    It 'кидає, коли Srvr= і File= задано одночасно' {
        { ConvertFrom-V8Connection -Connection 'Srvr=SRV01;Ref=DEMO_BASE;File=C:\x;' } | Should -Throw '*одночасно Srvr= і File=*'
    }

    It 'кидає на повтореному ключі — неоднозначний рядок, а не «останній виграє»' {
        { ConvertFrom-V8Connection -Connection 'Srvr=A;Srvr=B;Ref=DEMO_BASE;' } | Should -Throw '*двічі*'
    }

    It 'кидає на невідомому ключі' {
        { ConvertFrom-V8Connection -Connection 'Usr=admin;File=C:\x;' } | Should -Throw '*Usr*'
    }

    It 'кидає на голому шляху без File=' {
        { ConvertFrom-V8Connection -Connection 'C:\bases\demo' } | Should -Throw '*голий шлях без ключа*'
    }

    It 'кидає на порожньому значенні ключа' {
        { ConvertFrom-V8Connection -Connection 'File=' } | Should -Throw '*порожнє значення для ключа*'
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

        { New-V8FileInfobase -Path $outside -MustBeUnder $boundary -RepoRoot $boundary } | Should -Throw '*не є підтекою*'
    }

    It 'кидає виняток на порожньому Path' {
        $boundary = Join-Path $TestDrive 'work-dir-2'
        New-Item -ItemType Directory -Path $boundary -Force | Out-Null

        { New-V8FileInfobase -Path '' -MustBeUnder $boundary -RepoRoot $boundary } | Should -Throw
    }

    It 'кидає виняток на неіснуючому -TemplatePath — до Get-V8Path, незалежно від того, чи встановлена платформа' {
        $boundary = Join-Path $TestDrive 'work-dir-3'
        New-Item -ItemType Directory -Path $boundary -Force | Out-Null
        $missing = Join-Path $TestDrive 'no-such.dt'

        { New-V8FileInfobase -Path (Join-Path $boundary 'ib') -MustBeUnder $boundary -RepoRoot $boundary -TemplatePath $missing } |
            Should -Throw "*$missing*"
    }
}

Describe 'New-ExtensionInfobase' -Tag 'Integration' {
    It 'створює базу з розширенням, адресованим під заданим іменем' {
        $ib = Join-Path $TestDrive 'ext-ib'
        $stub = Join-Path $PSScriptRoot '../assets/empty-extension'

        $ibSwitch = New-ExtensionInfobase -Path $ib -ExtensionName 'PROBE_EXT' -StubPath $stub -MustBeUnder $TestDrive -RepoRoot $TestDrive -V8Path (Get-V8Path)
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
        $srcIb = New-V8FileInfobase -Path (Join-Path $TestDrive 'dt-src/ib') -MustBeUnder (Join-Path $TestDrive 'dt-src') -RepoRoot (Join-Path $TestDrive 'dt-src')
        $dt = Join-Path $TestDrive 'template.dt'
        (Invoke-V8Designer -IbSwitch ('/F "{0}"' -f $srcIb) -Arguments @('/DumpIB "{0}"' -f $dt)).ExitCode | Should -Be 0
        Test-Path -LiteralPath $dt -PathType Leaf | Should -BeTrue

        $target = Join-Path $TestDrive 'from-template/ib'
        $result = New-V8FileInfobase -Path $target -MustBeUnder (Join-Path $TestDrive 'from-template') -RepoRoot (Join-Path $TestDrive 'from-template') -TemplatePath $dt
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

Describe 'Get-KitPlatformVersionFromPath' {
    It 'версія — тека над bin\1cv8.exe' {
        Get-KitPlatformVersionFromPath -Path 'C:\Program Files\1cv8\8.3.27.1644\bin\1cv8.exe' | Should -Be '8.3.27.1644'
        Get-KitPlatformVersionFromPath -Path 'C:\pf86\8.3.25.1445\bin\1cv8.exe' | Should -Be '8.3.25.1445'
    }
}

Describe 'Get-KitInstalledPlatforms — платформи оточення (спека 1.3.1 §4.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        function script:New-FakePlatform {
            param([string]$Root, [string]$Version, [switch]$NoExe)
            $bin = Join-Path $Root "$Version\bin"
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            if (-not $NoExe) { Set-Content -LiteralPath (Join-Path $bin '1cv8.exe') -Value 'stub' -Encoding ascii }
        }
        $script:X64 = Join-Path $TestDrive 'pf'; $script:X86 = Join-Path $TestDrive 'pf86'
        New-FakePlatform -Root $script:X64 -Version '8.3.27.1644'
        New-FakePlatform -Root $script:X64 -Version '8.3.25.1445'
        New-FakePlatform -Root $script:X86 -Version '8.3.25.1445'
        New-FakePlatform -Root $script:X86 -Version '8.3.24.1000'
        New-FakePlatform -Root $script:X64 -Version '8.3.23.9999' -NoExe          # тека без 1cv8.exe — не платформа
        # не версія за іменем, хоча exe є: відсікається саме фільтром імені, не перевіркою exe
        New-FakePlatform -Root $script:X64 -Version 'common'
        # [version] ≠ рядковий порядок: 8.3.10.1 новіша за 8.3.9.1
        New-FakePlatform -Root $script:X64 -Version '8.3.9.1'
        New-FakePlatform -Root $script:X64 -Version '8.3.10.1'
        # x86 першим ключем: вторинний ключ «x64 перед x86» не може випливти з порядку обходу
        $script:Roots = [ordered]@{ x86 = $script:X86; x64 = $script:X64 }
    }

    It 'лише теки-версії з фактичним bin\1cv8.exe; обидві розрядності; за спаданням версії як [version], x64 першим' {
        $p = @(Get-KitInstalledPlatforms -Roots $script:Roots)
        @($p | ForEach-Object { "$($_.Version)/$($_.Arch)" }) | Should -Be @('8.3.27.1644/x64', '8.3.25.1445/x64', '8.3.25.1445/x86', '8.3.24.1000/x86', '8.3.10.1/x64', '8.3.9.1/x64')
        $p[0].Path | Should -Be (Join-Path $script:X64 '8.3.27.1644\bin\1cv8.exe')
    }

    It 'коренів немає — нічого не повертає й не кидає' {
        $none = [ordered]@{ x64 = (Join-Path $TestDrive 'none'); x86 = (Join-Path $TestDrive 'none86') }
        { Get-KitInstalledPlatforms -Roots $none } | Should -Not -Throw
        @(Get-KitInstalledPlatforms -Roots $none).Count | Should -Be 0
    }

    It 'Get-V8Path з явною версією знаходить її в x86, коли в x64 її немає' {
        Get-V8Path -Version '8.3.24.1000' -Roots $script:Roots | Should -Be (Join-Path $script:X86 '8.3.24.1000\bin\1cv8.exe')
    }

    It 'Get-V8Path з явною версією, яка є в обох — x64' {
        Get-V8Path -Version '8.3.25.1445' -Roots $script:Roots | Should -Be (Join-Path $script:X64 '8.3.25.1445\bin\1cv8.exe')
    }

    It 'Get-V8Path з явною відсутньою версією — зупинка з переліком наявних' {
        { Get-V8Path -Version '8.3.22.1' -Roots $script:Roots } | Should -Throw '*8.3.25.1445*'
    }
}

Describe 'Invoke-V8Designer — пароль (#26, Review Focus 2)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }
    It 'пароль із подвійною лапкою — відмова до запуску платформи, пароль у тексті не з''являється' {
        $err = $null
        try { Invoke-V8Designer -IbSwitch '/F "C:\x"' -Arguments @('/DumpCfg "C:\y.cf"') -Password 'ab"c-секрет' -V8Path 'C:\no-such\1cv8.exe' }
        catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*подвійну лапку*'
        $err | Should -Not -BeLike '*секрет*'
    }
    It 'пароль у Write-Verbose замасковано, але платформа його отримує' {
        Mock -ModuleName V8 Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $old = $global:VerbosePreference; $global:VerbosePreference = 'Continue'
        try { $out = & { Invoke-V8Designer -IbSwitch '/F "C:\x"' -Arguments @('/DumpCfg "C:\y.cf"') -User 'agent' -Password 'S3cr3t-Пароль' -V8Path 'C:\fake\1cv8.exe' } 4>&1 | Out-String }
        finally { $global:VerbosePreference = $old }
        $out | Should -Not -BeLike '*S3cr3t*'
        $out | Should -BeLike '*/P "[*][*][*]"*'
        Should -Invoke -ModuleName V8 Start-Process -Times 1 -ParameterFilter { $ArgumentList -like '*/P "S3cr3t-Пароль"*' }
    }
}

Describe 'ConvertFrom-V8Connection — текст винятку без вхідного рядка (§10.2 П23)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        function script:Get-ConnError { param([string]$C)
            try { ConvertFrom-V8Connection -Connection $C | Out-Null } catch { return $_.Exception.Message }
            return $null
        }
    }

    # Маркер СЕКРЕТ-Ж7SECRETZ7 стоїть у значенні й у тілі рядка кожної гілки. Гілка «не описує базу»
    # недосяжна через вхід (будь-який елемент з '=' або дає дозволений ключ, або кидає раніше) —
    # її текст перевіряє читання коду, а не цей перелік.
    It 'гілка «<Name>»: виняток є, вхідного рядка й маркера в тексті немає' -TestCases @(
        @{ Name = 'голий шлях';             C = 'D:\СЕКРЕТ-Ж7SECRETZ7\base' }
        @{ Name = 'елемент без =';          C = 'File=C:\x;СЕКРЕТ-Ж7SECRETZ7' }
        @{ Name = 'лапки в імені ключа';    C = '"СЕКРЕТ-Ж7SECRETZ7"=VSDEV;Ref=X' }
        @{ Name = 'непарні лапки';          C = 'Srvr="СЕКРЕТ-Ж7SECRETZ7;Ref=BASE' }
        @{ Name = 'порожнє значення';       C = 'Srvr=СЕКРЕТ-Ж7SECRETZ7;Ref="";' }
        @{ Name = 'невідомий ключ';         C = 'File=СЕКРЕТ-Ж7SECRETZ7;Foo=СЕКРЕТ-Ж7SECRETZ7' }
        @{ Name = 'дубль ключа';            C = 'Srvr=СЕКРЕТ-Ж7SECRETZ7;Srvr=B;Ref=C' }
        @{ Name = 'Srvr разом з File';      C = 'Srvr=СЕКРЕТ-Ж7SECRETZ7;Ref=B;File=C:\СЕКРЕТ-Ж7SECRETZ7' }
        @{ Name = 'серверна без Ref';       C = 'Srvr=СЕКРЕТ-Ж7SECRETZ7' }
        @{ Name = 'серверна без Srvr';      C = 'Ref=СЕКРЕТ-Ж7SECRETZ7' }
        @{ Name = '= у значенні';           C = 'File=C:СЕКРЕТ-Ж7SECRETZ7,Pwd=СЕКРЕТ-Ж7SECRETZ7' }
    ) {
        $err = Get-ConnError $C
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -BeLike '*СЕКРЕТ-Ж7*'
        $err | Should -Not -BeLike '*SECRETZ7*'
        $err | Should -Not -BeLike "*$C*"
    }

    It 'порожній рядок — окреме повідомлення без значення' {
        Get-ConnError '   ' | Should -BeLike '*порожній*'
    }

    It 'голий шлях: рецепт File= без шляху' {
        $err = Get-ConnError 'D:\СЕКРЕТ-Ж7SECRETZ7\base'
        $err | Should -BeLike '*File=<шлях>*'
    }

    It 'Usr/Pwd у будь-якому регістрі — окреме повідомлення без значень; рецепт дописує викликач за походженням' -TestCases @(
        @{ C = 'File=build/ib;Usr=логін-Ж7;Pwd=СЕКРЕТ-Ж7SECRETZ7' }
        @{ C = 'File=build/ib;usr=логін-Ж7' }
        @{ C = 'File=build/ib;pwd=СЕКРЕТ-Ж7SECRETZ7' }
        @{ C = 'Srvr=S;Ref=R;PWD=СЕКРЕТ-Ж7SECRETZ7;' }
        @{ C = 'Usr=логін-Ж7;File=build/ib' }
    ) {
        $err = Get-ConnError $C
        $err | Should -BeLike '*не задаються в рядку підключення*'
        $err | Should -Not -BeLike '*infobases*'   # рецепт залежить від походження — його тут немає
        $err | Should -Not -BeLike '*Ж7*'
        $err | Should -Not -BeLike '*Z7*'
        $err | Should -Not -BeLike '*невідомий ключ*'
    }
}

Describe 'Get-V8CredentialsRecipe — рецепт за походженням рядка' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force
        function script:Get-CredEx { try { ConvertFrom-V8Connection -Connection 'File=x;Pwd=СЕКРЕТ-Ж7SECRETZ7' } catch { $_.Exception } }
    }
    It 'база агента: user і password в infobases.origin' {
        $r = Get-V8CredentialsRecipe -Exception (Get-CredEx) -Kind agent
        $r | Should -BeLike '*user і password в infobases.origin у v8project.local.yaml*'
    }
    It 'дев-база накладки: user в infobases: накладки, пароль не підтримується — і жодного infobases.origin' {
        $r = Get-V8CredentialsRecipe -Exception (Get-CredEx) -Kind overlay
        $r | Should -BeLike '*v8storagekit.local.yaml*пароль дев-бази kit не підтримує*'
        $r | Should -Not -BeLike '*infobases.origin*'
    }
    It 'виняток з іншої причини — порожній рецепт' {
        $ex = try { ConvertFrom-V8Connection -Connection 'Srvr=A' } catch { $_.Exception }
        Get-V8CredentialsRecipe -Exception $ex -Kind agent | Should -BeNullOrEmpty
    }
}

Describe 'Assert-V8SecretQuoteFree — одна перевірка " для обох паролів (§10.2 П23)' {
    BeforeAll { Import-Module (Resolve-Path "$PSScriptRoot/../lib/V8.psm1").Path -Force }

    It 'пароль із " — виняток із Origin, значення в тексті немає' {
        $err = $null
        try { Assert-V8SecretQuoteFree -Value 'ab"ХВІСТ-Ж7' -Origin 'накладка v8storagekit.local.yaml, storages.Alpha.password' }
        catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*накладка v8storagekit.local.yaml, storages.Alpha.password*'
        $err | Should -BeLike '*подвійну лапку*'
        $err | Should -Not -BeLike '*ХВІСТ*'
        $err | Should -Not -BeLike '*ab"*'
    }

    It 'пароль без " і порожній пароль — тиша' {
        { Assert-V8SecretQuoteFree -Value 'abc-Ж7' -Origin 'x' } | Should -Not -Throw
        { Assert-V8SecretQuoteFree -Value '' -Origin 'x' } | Should -Not -Throw
    }

    It 'Invoke-V8Designer відмовляє через ту саму перевірку — з Origin «пароль бази агента»' {
        $err = $null
        try { Invoke-V8Designer -IbSwitch '/F "C:\x"' -Arguments @('/X') -Password 'ab"c-Ж7' -V8Path 'C:\no-such\1cv8.exe' }
        catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*пароль бази агента*'
        $err | Should -Not -BeLike '*c-Ж7*'
    }
}
