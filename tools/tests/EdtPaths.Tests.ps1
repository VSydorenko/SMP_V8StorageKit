#Requires -Version 7
<#
Тести Step 1 (B6 Task 3, §9.2) — мали впасти ДО lib/EdtPaths.psm1: модуля не існувало,
Import-Module падав на "Cannot find path". Таблиця відповідності звірена з
.superpowers/sdd/2026-09-03-B6-migrate/park-edt-shapes.txt (283 форми шляхів) і
park-edt-inventory.md (41 вид метаданих у восьми gitsync-репозиторіях) — деталі звірки
в task-3-report.md.
#>
Describe 'EdtPaths.psm1 — Convert-KitEdtPath: дескриптор об''єкта на кожен вид (§9.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/EdtPaths.psm1").Path -Force
    }

    # Один It на вид метаданих (park-edt-inventory.md, format-index.md §2): власний
    # дескриптор "<Вид>/Ім'я/Ім'я.mdo" -> "<Вид>/Ім'я.xml" — однаково для КОЖНОГО виду
    # (1c-config-objects-spec.md §1.2: "Каталог: X/. Файлы: <Имя>.xml").
    $kinds = @(
        'AccountingRegisters', 'AccumulationRegisters', 'BusinessProcesses', 'Catalogs',
        'CalculationRegisters', 'ChartsOfAccounts', 'ChartsOfCalculationTypes', 'ChartsOfCharacteristicTypes',
        'CommandGroups', 'CommonAttributes', 'CommonCommands', 'CommonForms', 'CommonModules',
        'CommonPictures', 'CommonTemplates', 'Constants', 'DataProcessors', 'DefinedTypes',
        'DocumentJournals', 'DocumentNumerators', 'Documents', 'Enums', 'EventSubscriptions',
        'ExchangePlans', 'FilterCriteria', 'FunctionalOptions', 'FunctionalOptionsParameters',
        'HTTPServices', 'InformationRegisters', 'IntegrationServices', 'Reports', 'Roles',
        'ScheduledJobs', 'Sequences', 'SessionParameters', 'SettingsStorages', 'StyleItems',
        'Styles', 'Subsystems', 'Tasks', 'WebServices', 'WSReferences', 'XDTOPackages'
    ) | ForEach-Object { @{ Kind = $_ } }

    It "<Kind>: власний дескриптор <Kind>/Об1/Об1.mdo -> <Kind>/Об1.xml" -ForEach $kinds {
        $r = Convert-KitEdtPath -RelativePath "$Kind/Об1/Об1.mdo"
        $r.DesignerPath | Should -Be "$Kind/Об1.xml" -Because "усі 41+ видів дають той самий дескрипторний шаблон (Reason: $($r.Reason))"
        $r.Reason | Should -BeNullOrEmpty
    }

    It 'Configuration.mdo -> Configuration.xml (корінь конфігурації, не Configuration/Configuration.xml)' {
        $r = Convert-KitEdtPath -RelativePath 'Configuration/Configuration.mdo'
        $r.DesignerPath | Should -Be 'Configuration.xml'
    }

    It 'корінні модулі Configuration -> Ext з тим самим ім''ям файлу' {
        foreach ($f in 'SessionModule.bsl', 'OrdinaryApplicationModule.bsl', 'ManagedApplicationModule.bsl', 'ExternalConnectionModule.bsl') {
            (Convert-KitEdtPath -RelativePath "Configuration/$f").DesignerPath | Should -Be "Ext/$f"
        }
        (Convert-KitEdtPath -RelativePath 'Configuration/CommandInterface.cmi').DesignerPath | Should -Be 'Ext/CommandInterface.xml'
        (Convert-KitEdtPath -RelativePath 'Configuration/MainSectionCommandInterface.cmi').DesignerPath | Should -Be 'Ext/MainSectionCommandInterface.xml'
    }

    It 'форма власника: Form.form/Module.bsl -> Ext/Form.xml, Ext/Form/Module.bsl' {
        (Convert-KitEdtPath -RelativePath 'Catalogs/Об1/Forms/Форма1/Form.form').DesignerPath | Should -Be 'Catalogs/Об1/Forms/Форма1/Ext/Form.xml'
        (Convert-KitEdtPath -RelativePath 'Catalogs/Об1/Forms/Форма1/Module.bsl').DesignerPath | Should -Be 'Catalogs/Об1/Forms/Форма1/Ext/Form/Module.bsl'
    }

    It 'фіксовані ролі модулів об''єкта -> Ext з тією самою роллю' {
        foreach ($f in 'ObjectModule.bsl', 'ManagerModule.bsl', 'RecordSetModule.bsl', 'ValueManagerModule.bsl', 'CommandModule.bsl') {
            (Convert-KitEdtPath -RelativePath "Catalogs/Об1/$f").DesignerPath | Should -Be "Catalogs/Об1/Ext/$f"
        }
    }

    It 'CommonForms — сама є формою: Form.form/Module.bsl -> Ext/Form.xml, Ext/Form/Module.bsl (не Ext/Module.bsl)' {
        (Convert-KitEdtPath -RelativePath 'CommonForms/Об1/Form.form').DesignerPath | Should -Be 'CommonForms/Об1/Ext/Form.xml'
        (Convert-KitEdtPath -RelativePath 'CommonForms/Об1/Module.bsl').DesignerPath | Should -Be 'CommonForms/Об1/Ext/Form/Module.bsl'
    }

    It 'CommonModules/WebServices/HTTPServices/IntegrationServices — Module.bsl -> Ext/Module.bsl' {
        foreach ($kind in 'CommonModules', 'WebServices', 'HTTPServices', 'IntegrationServices') {
            (Convert-KitEdtPath -RelativePath "$kind/Об1/Module.bsl").DesignerPath | Should -Be "$kind/Об1/Ext/Module.bsl"
        }
    }

    It 'Subsystems — рекурсивна вкладеність (глибина 4 підсистеми) і власний CommandInterface.cmi' {
        (Convert-KitEdtPath -RelativePath 'Subsystems/A/CommandInterface.cmi').DesignerPath | Should -Be 'Subsystems/A/Ext/CommandInterface.xml'
        $deep = 'Subsystems/A/Subsystems/B/Subsystems/C/Subsystems/D/D.mdo'
        (Convert-KitEdtPath -RelativePath $deep).DesignerPath | Should -Be 'Subsystems/A/Subsystems/B/Subsystems/C/Subsystems/D.xml'
    }

    It 'видо-специфічні розширення: XDTOPackages/.xdto, Roles/Rights.rights, Styles/Style.style, BusinessProcesses/Flowchart.scheme' {
        (Convert-KitEdtPath -RelativePath 'XDTOPackages/Об1/Об1.xdto').DesignerPath | Should -Be 'XDTOPackages/Об1/Ext/Package.bin'
        (Convert-KitEdtPath -RelativePath 'Roles/Об1/Rights.rights').DesignerPath | Should -Be 'Roles/Об1/Ext/Rights.xml'
        (Convert-KitEdtPath -RelativePath 'Styles/Об1/Style.style').DesignerPath | Should -Be 'Styles/Об1/Ext/Style.xml'
        (Convert-KitEdtPath -RelativePath 'BusinessProcesses/Об1/Flowchart.scheme').DesignerPath | Should -Be 'BusinessProcesses/Об1/Ext/Flowchart.xml'
    }

    It 'Templates: будь-яке розширення Template.* -> Ext/Template.xml (park-edt-shapes.txt: .mxlx/.dcs/.bin/.txt/.html/.scheme/.addin/…)' {
        foreach ($ext in 'mxlx', 'dcs', 'bin', 'txt', 'html', 'htmldoc', 'scheme', 'addin', 'dcsat') {
            (Convert-KitEdtPath -RelativePath "Reports/Об1/Templates/Мак1/Template.$ext").DesignerPath | Should -Be 'Reports/Об1/Templates/Мак1/Ext/Template.xml'
        }
    }

    It 'вкладений ресурс макета (глибина понад один рівень під теки макета) -> Unmapped' {
        $r = Convert-KitEdtPath -RelativePath 'DataProcessors/Об1/Templates/Мак1/Сторінки/Стор1.png'
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'вкладені атрибути форми (Attributes/…, dcss/chart/pnrs) -> Unmapped, вбудовано у Ext/Form.xml' {
        $r = Convert-KitEdtPath -RelativePath 'Catalogs/Об1/Forms/Форма1/Attributes/Товари/Кількість/УмоваОформлення.dcss'
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -BeLike '*Ext/Form.xml*'
    }

    It 'ScheduledJobs/Schedule.schedule -> Unmapped (вбудовано у властивість дескриптора)' {
        $r = Convert-KitEdtPath -RelativePath 'ScheduledJobs/Об1/Schedule.schedule'
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'коротший за очікуване шлях (<Path>) — Unmapped, а не виняток "Index was outside the bounds"' -ForEach @(
        @{ Path = 'Configuration' }
        @{ Path = 'НевідомийВид' }
        @{ Path = 'Subsystems/ОдинСегмент.txt' }
        @{ Path = 'Subsystems/A/Subsystems' }
        @{ Path = 'Catalogs/ОдинСегмент.txt' }
        @{ Path = 'Catalogs/Об1/Forms/ФайлБезТекиФорми' }
        @{ Path = 'Catalogs/Об1/Templates/ФайлБезТекиМакета' }
        @{ Path = 'Catalogs/Об1/Commands/ФайлБезТекиКоманди' }
    ) {
        { Convert-KitEdtPath -RelativePath $Path } | Should -Not -Throw
        $r = Convert-KitEdtPath -RelativePath $Path
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'файл без відповідника (<Path>) -> DesignerPath = $null, Reason пояснює' -ForEach @(
        @{ Path = 'DT-INF/1CV8.dt' }
        @{ Path = '.project' }
        @{ Path = '.settings' }
        @{ Path = 'AUTHORS' }
        @{ Path = 'VERSION' }
        @{ Path = 'ConfigDumpInfo.xml' }
        @{ Path = 'DumpFilesIndex.txt' }
    ) {
        $r = Convert-KitEdtPath -RelativePath $Path
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'невідомий вид метаданих (немає ні в довідниках, ні в парку) -> Unmapped, а не мовчазне вгадування' {
        $r = Convert-KitEdtPath -RelativePath 'НевідомийВид/Об1/Об1.mdo'
        $r.DesignerPath | Should -BeNullOrEmpty
        $r.Reason | Should -BeLike '*невідомий вид*'
    }

    It 'кириличні імена метаданих проходять без спотворення (SMP_OnlineExchange)' {
        $r = Convert-KitEdtPath -RelativePath 'Catalogs/КлиентыИнтернетМагазина/Forms/ФормаЭлемента/Module.bsl'
        $r.DesignerPath | Should -Be 'Catalogs/КлиентыИнтернетМагазина/Forms/ФормаЭлемента/Ext/Form/Module.bsl'
    }
}

Describe 'EdtPaths.psm1 — Get-KitEdtRenamePlan: обхід дерева, три списки (§9.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/EdtPaths.psm1").Path -Force
    }

    It 'звичайне дерево — усе в Moves з коректними SourceRelPath/TargetRelPath' {
        $root = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'cf/src/Catalogs/Об1') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'cf/src/Catalogs/Об1/Об1.mdo') -Value 'x'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'cf/src' -TargetRoot 'Продукт/cf/src'
        $plan.Collisions.Count | Should -Be 0
        $plan.Unmapped.Count | Should -Be 0
        $plan.Moves.Count | Should -Be 1
        $plan.Moves[0].SourceRelPath | Should -Be 'cf/src/Catalogs/Об1/Об1.mdo'
        $plan.Moves[0].TargetRelPath | Should -Be 'Продукт/cf/src/Catalogs/Об1.xml'
    }

    It 'колізія: два різні EDT-шляхи -> один Designer-шлях — непорожній Collisions, обидва відсутні в Moves' {
        # CommonTemplates/<Ім'я>/<будь-який файл окрім .mdo> завжди мапиться в Ext/Template.xml
        # (park-edt-shapes.txt: рівно один вміст на макет) — два файли в тій самій теці
        # об'єкта навмисно відтворюють колізію, яку має ловити САМЕ Get-KitEdtRenamePlan.
        $root = Join-Path $TestDrive 'collision'
        $dir = Join-Path $root 'cf/src/CommonTemplates/Мак1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Мак1.mxlx') -Value 'a'
        Set-Content -LiteralPath (Join-Path $dir 'Мак1.dcs') -Value 'b'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'cf/src' -TargetRoot 'Продукт/cf/src'
        $plan.Collisions.Count | Should -Be 1
        $plan.Collisions[0].TargetRelPath | Should -Be 'Продукт/cf/src/CommonTemplates/Мак1/Ext/Template.xml'
        @($plan.Collisions[0].SourceRelPaths).Count | Should -Be 2
        $plan.Moves.SourceRelPath | Should -Not -Contain 'cf/src/CommonTemplates/Мак1/Мак1.mxlx'
        $plan.Moves.SourceRelPath | Should -Not -Contain 'cf/src/CommonTemplates/Мак1/Мак1.dcs'
    }

    It 'файли без відповідника — в Unmapped з Reason, не в Moves' {
        $root = Join-Path $TestDrive 'unmapped'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'src/ConfigDumpInfo.xml') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'src/DumpFilesIndex.txt') -Value 'x'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'src' -TargetRoot 'Продукт/cf/src'
        $plan.Moves.Count | Should -Be 0
        $plan.Unmapped.Count | Should -Be 2
        $plan.Unmapped | ForEach-Object { $_.Reason | Should -Not -BeNullOrEmpty }
    }
}
