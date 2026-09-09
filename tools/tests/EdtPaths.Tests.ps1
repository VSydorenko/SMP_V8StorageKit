#Requires -Version 7
<#
Тести Step 1 (B6 Task 3, §9.2) — мали впасти ДО lib/EdtPaths.psm1: модуля не існувало,
Import-Module падав на "Cannot find path". Таблиця відповідності звірена з
.superpowers/sdd/2026-09-03-B6-migrate/park-edt-shapes.txt (283 форми шляхів) і
park-edt-inventory.md (41 вид метаданих у восьми gitsync-репозиторіях) — деталі звірки
в task-3-report.md.

Раунд 1 рев'ю (task-3-findings-round1.md) і подальше стендове звірення координатора (48 990
шляхів парку + живі Designer-дерева) додали до цього файлу:
- C-C/I-D (Templates — остаточна таблиця розширень, нижче);
- третій стан результату Status ('Mapped'/'Unmapped'/'Unresolved') — Unmapped = ЗНАЄМО, що
  не потрібне (видаляється під -Apply); Unresolved = НЕ ЗНАЄМО, що це (ніколи не видаляється);
- M-8 (текст причини для .bin/.png/.svg під Configuration/ звіряється зі спекою, а не
  узагальнюється — і це тепер Unresolved, не Unmapped: реальний вміст, не сміття);
- M-10 (Languages у переліку видів);
- I-F (перейменування -RelativePath -> -EdtPath, поле Kind у результаті, поля From/To/Kind
  у плані).

Таблиця макетів — ОСТАТОЧНА (координатор, з доказом на кожен рядок):
  mxlx/dcs/htmldoc -> Ext/Template.xml (виміряно + format-index.md §3 + 1c-erf-spec.md +
  1c-config-objects-spec.md §6.4); bin/txt -> Ext/Template.<те саме> (виміряно,
  SMP_SimplyConnect); scheme/addin -> Unresolved (доказу немає в жоден бік — навіть
  правдоподібний здогад для addin свідомо НЕ застосований). Сторінки-сателіти
  "<Сторінка>.html" за формою шляху (не за видом метаданих) -> Ext/Template/<файл> — це й
  закриває колишню хибну колізію C-C одним правилом.
#>
Describe 'EdtPaths.psm1 — Convert-KitEdtPath: дескриптор об''єкта на кожен вид (§9.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/EdtPaths.psm1").Path -Force
    }

    # Один It на вид метаданих (park-edt-inventory.md, format-index.md §2): власний
    # дескриптор "<Вид>/Ім'я/Ім'я.mdo" -> "<Вид>/Ім'я.xml" — однаково для КОЖНОГО виду
    # (1c-config-objects-spec.md §1.2: "Каталог: X/. Файлы: <Имя>.xml"). Kind у результаті
    # мусить називати сам вид (I-F: контракт плану, поле Kind).
    $kinds = @(
        'AccountingRegisters', 'AccumulationRegisters', 'BusinessProcesses', 'Catalogs',
        'CalculationRegisters', 'ChartsOfAccounts', 'ChartsOfCalculationTypes', 'ChartsOfCharacteristicTypes',
        'CommandGroups', 'CommonAttributes', 'CommonCommands', 'CommonForms', 'CommonModules',
        'CommonPictures', 'CommonTemplates', 'Constants', 'DataProcessors', 'DefinedTypes',
        'DocumentJournals', 'DocumentNumerators', 'Documents', 'Enums', 'EventSubscriptions',
        'ExchangePlans', 'FilterCriteria', 'FunctionalOptions', 'FunctionalOptionsParameters',
        'HTTPServices', 'InformationRegisters', 'IntegrationServices', 'Languages', 'Reports', 'Roles',
        'ScheduledJobs', 'Sequences', 'SessionParameters', 'SettingsStorages', 'StyleItems',
        'Styles', 'Subsystems', 'Tasks', 'WebServices', 'WSReferences', 'XDTOPackages'
    ) | ForEach-Object { @{ Kind = $_ } }

    It "<Kind>: власний дескриптор <Kind>/Об1/Об1.mdo -> <Kind>/Об1.xml, Kind='<Kind>'" -ForEach $kinds {
        $r = Convert-KitEdtPath -EdtPath "$Kind/Об1/Об1.mdo"
        $r.DesignerRelPath | Should -Be "$Kind/Об1.xml" -Because "усі 41+ видів дають той самий дескрипторний шаблон (Reason: $($r.Reason))"
        $r.Reason | Should -BeNullOrEmpty
        $r.Kind | Should -Be $Kind
    }

    It 'Configuration.mdo -> Configuration.xml (корінь конфігурації, не Configuration/Configuration.xml)' {
        $r = Convert-KitEdtPath -EdtPath 'Configuration/Configuration.mdo'
        $r.DesignerRelPath | Should -Be 'Configuration.xml'
        $r.Kind | Should -Be 'Configuration'
    }

    It 'корінні модулі Configuration -> Ext з тим самим ім''ям файлу' {
        foreach ($f in 'SessionModule.bsl', 'OrdinaryApplicationModule.bsl', 'ManagedApplicationModule.bsl', 'ExternalConnectionModule.bsl') {
            (Convert-KitEdtPath -EdtPath "Configuration/$f").DesignerRelPath | Should -Be "Ext/$f"
        }
        (Convert-KitEdtPath -EdtPath 'Configuration/CommandInterface.cmi').DesignerRelPath | Should -Be 'Ext/CommandInterface.xml'
        (Convert-KitEdtPath -EdtPath 'Configuration/MainSectionCommandInterface.cmi').DesignerRelPath | Should -Be 'Ext/MainSectionCommandInterface.xml'
    }

    It 'M-8: .bin/.png/.svg під Configuration/ — Reason посилається на конкретні розділи спеки (Unresolved, реальний вміст — не Unmapped)' {
        $bin = Convert-KitEdtPath -EdtPath 'Configuration/Logo.bin'
        $bin.DesignerRelPath | Should -BeNullOrEmpty
        $bin.Status | Should -Be 'Unresolved'
        $bin.Reason | Should -BeLike '*§4.5*'
        $bin.Reason | Should -BeLike '*ParentConfigurations.bin*'

        $png = Convert-KitEdtPath -EdtPath 'Configuration/Logo.png'
        $png.DesignerRelPath | Should -BeNullOrEmpty
        $png.Status | Should -Be 'Unresolved'
        $png.Reason | Should -BeLike '*§4.4*'
        $png.Reason | Should -BeLike '*Splash*'

        # Розширення, якого справді немає в жодній таблиці спеки, — старий, узагальнений текст лишається правильним.
        $other = Convert-KitEdtPath -EdtPath 'Configuration/Logo.ico'
        $other.Status | Should -Be 'Unresolved'
        $other.Reason | Should -BeLike '*не підтверджена жодним джерелом*'
    }

    It 'форма власника: Form.form/Module.bsl -> Ext/Form.xml, Ext/Form/Module.bsl' {
        (Convert-KitEdtPath -EdtPath 'Catalogs/Об1/Forms/Форма1/Form.form').DesignerRelPath | Should -Be 'Catalogs/Об1/Forms/Форма1/Ext/Form.xml'
        (Convert-KitEdtPath -EdtPath 'Catalogs/Об1/Forms/Форма1/Module.bsl').DesignerRelPath | Should -Be 'Catalogs/Об1/Forms/Форма1/Ext/Form/Module.bsl'
    }

    It 'фіксовані ролі модулів об''єкта -> Ext з тією самою роллю' {
        foreach ($f in 'ObjectModule.bsl', 'ManagerModule.bsl', 'RecordSetModule.bsl', 'ValueManagerModule.bsl', 'CommandModule.bsl') {
            (Convert-KitEdtPath -EdtPath "Catalogs/Об1/$f").DesignerRelPath | Should -Be "Catalogs/Об1/Ext/$f"
        }
    }

    It 'CommonForms — сама є формою: Form.form/Module.bsl -> Ext/Form.xml, Ext/Form/Module.bsl (не Ext/Module.bsl)' {
        (Convert-KitEdtPath -EdtPath 'CommonForms/Об1/Form.form').DesignerRelPath | Should -Be 'CommonForms/Об1/Ext/Form.xml'
        (Convert-KitEdtPath -EdtPath 'CommonForms/Об1/Module.bsl').DesignerRelPath | Should -Be 'CommonForms/Об1/Ext/Form/Module.bsl'
    }

    It 'CommonModules/WebServices/HTTPServices/IntegrationServices — Module.bsl -> Ext/Module.bsl' {
        foreach ($kind in 'CommonModules', 'WebServices', 'HTTPServices', 'IntegrationServices') {
            (Convert-KitEdtPath -EdtPath "$kind/Об1/Module.bsl").DesignerRelPath | Should -Be "$kind/Об1/Ext/Module.bsl"
        }
    }

    It 'Subsystems — рекурсивна вкладеність (глибина 4 підсистеми) і власний CommandInterface.cmi' {
        (Convert-KitEdtPath -EdtPath 'Subsystems/A/CommandInterface.cmi').DesignerRelPath | Should -Be 'Subsystems/A/Ext/CommandInterface.xml'
        $deep = 'Subsystems/A/Subsystems/B/Subsystems/C/Subsystems/D/D.mdo'
        (Convert-KitEdtPath -EdtPath $deep).DesignerRelPath | Should -Be 'Subsystems/A/Subsystems/B/Subsystems/C/Subsystems/D.xml'
    }

    It 'видо-специфічні розширення: XDTOPackages/.xdto, Roles/Rights.rights, Styles/Style.style, BusinessProcesses/Flowchart.scheme' {
        (Convert-KitEdtPath -EdtPath 'XDTOPackages/Об1/Об1.xdto').DesignerRelPath | Should -Be 'XDTOPackages/Об1/Ext/Package.bin'
        (Convert-KitEdtPath -EdtPath 'Roles/Об1/Rights.rights').DesignerRelPath | Should -Be 'Roles/Об1/Ext/Rights.xml'
        (Convert-KitEdtPath -EdtPath 'Styles/Об1/Style.style').DesignerRelPath | Should -Be 'Styles/Об1/Ext/Style.xml'
        (Convert-KitEdtPath -EdtPath 'BusinessProcesses/Об1/Flowchart.scheme').DesignerRelPath | Should -Be 'BusinessProcesses/Об1/Ext/Flowchart.xml'
    }

    # Таблиця макетів — ОСТАТОЧНА (координатор, з доказом на кожен рядок; замінює round-1
    # припущення "лише mxlx/dcs -> xml, решта як є" — htmldoc теж загортається в XML,
    # scheme/addin взагалі не вгадуються). Три групи, кожна власним It — не одне правило на
    # всі розширення (це і була сама помилка, яку рев'ю знайшло в попередній версії тесту).
    It 'Templates: <Ext> -> Ext/Template.xml (XML-контейнер)' -ForEach @(
        @{ Ext = 'mxlx' }    # виміряно 18/18, SMP_BankExchange
        @{ Ext = 'dcs' }     # format-index.md §3 + 1c-erf-spec.md
        @{ Ext = 'htmldoc' } # 1c-config-objects-spec.md §6.4: XML-дескриптор з <Page>
    ) {
        $r = Convert-KitEdtPath -EdtPath "Reports/Об1/Templates/Мак1/Template.$Ext"
        $r.DesignerRelPath | Should -Be 'Reports/Об1/Templates/Мак1/Ext/Template.xml'
        $r.Status | Should -Be 'Mapped'
    }

    It 'Templates: <Ext> зберігає своє розширення (виміряно, SMP_SimplyConnect)' -ForEach @(
        @{ Ext = 'bin' }
        @{ Ext = 'txt' }
    ) {
        $r = Convert-KitEdtPath -EdtPath "Reports/Об1/Templates/Мак1/Template.$Ext"
        $r.DesignerRelPath | Should -Be "Reports/Об1/Templates/Мак1/Ext/Template.$Ext"
        $r.Status | Should -Be 'Mapped'
    }

    It 'Templates: <Ext> -> Unresolved, НЕ Mapped і НЕ Unmapped (доказу немає в жоден бік — не вгадується)' -ForEach @(
        @{ Ext = 'scheme' }
        @{ Ext = 'addin' }
    ) {
        $r = Convert-KitEdtPath -EdtPath "Reports/Об1/Templates/Мак1/Template.$Ext"
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unresolved'
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'Templates: сторінка-сателіт (lang.html) за ФОРМОЮ ШЛЯХУ (не видом метаданих) -> Ext/Template/файл, не колізія' {
        # Координатор: правило працює однаково для DataProcessors/ExchangePlans/Catalogs/
        # CommonTemplates/Reports — перевірено на двох різних видах-власниках.
        (Convert-KitEdtPath -EdtPath 'DataProcessors/Об1/Templates/Мак1/ru.html').DesignerRelPath | Should -Be 'DataProcessors/Об1/Templates/Мак1/Ext/Template/ru.html'
        (Convert-KitEdtPath -EdtPath 'DataProcessors/Об1/Templates/Мак1/uk.html').DesignerRelPath | Should -Be 'DataProcessors/Об1/Templates/Мак1/Ext/Template/uk.html'
        (Convert-KitEdtPath -EdtPath 'ExchangePlans/Об1/Templates/Мак1/ru.html').DesignerRelPath | Should -Be 'ExchangePlans/Об1/Templates/Мак1/Ext/Template/ru.html'
    }

    It 'вкладений ресурс макета поза підтвердженою розкладкою (глибше одного рівня, не .html) -> Unresolved' {
        $r = Convert-KitEdtPath -EdtPath 'DataProcessors/Об1/Templates/Мак1/Сторінки/Стор1.png'
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unresolved'
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'CommonTemplates: та сама таблиця макетів, що для об''єктних Templates/' {
        (Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/Мак1.mdo').DesignerRelPath | Should -Be 'CommonTemplates/Мак1.xml'
        (Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/Template.mxlx').DesignerRelPath | Should -Be 'CommonTemplates/Мак1/Ext/Template.xml'
        (Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/Template.htmldoc').DesignerRelPath | Should -Be 'CommonTemplates/Мак1/Ext/Template.xml'
        (Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/Template.bin').DesignerRelPath | Should -Be 'CommonTemplates/Мак1/Ext/Template.bin'
        (Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/ru.html').DesignerRelPath | Should -Be 'CommonTemplates/Мак1/Ext/Template/ru.html'
        $scheme = Convert-KitEdtPath -EdtPath 'CommonTemplates/Мак1/Template.scheme'
        $scheme.DesignerRelPath | Should -BeNullOrEmpty
        $scheme.Status | Should -Be 'Unresolved'
    }

    It 'C-C закрита одним правилом: Template.htmldoc + два файли lang.html в одній теці — три РІЗНІ шляхи, нуль колізій' {
        # Пряма перевірка властивості, яку вимагав координатор: три файли, які раніше (до
        # правила сторінок-сателітів) мапились в ОДИН Ext/Template.xml.
        $htmldoc = Convert-KitEdtPath -EdtPath 'CommonTemplates/Печать/Template.htmldoc'
        $ru = Convert-KitEdtPath -EdtPath 'CommonTemplates/Печать/ru.html'
        $uk = Convert-KitEdtPath -EdtPath 'CommonTemplates/Печать/uk.html'
        $paths = @($htmldoc.DesignerRelPath, $ru.DesignerRelPath, $uk.DesignerRelPath)
        ($paths | Sort-Object -Unique).Count | Should -Be 3 -Because 'усі три шляхи мають бути РІЗНІ — нуль колізій'
        $htmldoc.DesignerRelPath | Should -Be 'CommonTemplates/Печать/Ext/Template.xml'
        $ru.DesignerRelPath | Should -Be 'CommonTemplates/Печать/Ext/Template/ru.html'
        $uk.DesignerRelPath | Should -Be 'CommonTemplates/Печать/Ext/Template/uk.html'
    }

    It 'вкладені атрибути форми (Attributes/…, dcss/chart/pnrs) -> Unmapped (ЗНАЄМО: вбудовано у Ext/Form.xml, підтверджено координатором окремо)' {
        $r = Convert-KitEdtPath -EdtPath 'Catalogs/Об1/Forms/Форма1/Attributes/Товари/Кількість/УмоваОформлення.dcss'
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unmapped'
        $r.Reason | Should -BeLike '*Ext/Form.xml*'
    }

    It 'ScheduledJobs/Schedule.schedule -> Unmapped (ЗНАЄМО: вбудовано у властивість дескриптора)' {
        $r = Convert-KitEdtPath -EdtPath 'ScheduledJobs/Об1/Schedule.schedule'
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unmapped'
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'коротший за очікуване шлях (<Path>) — Unresolved (невідома структура), а не виняток "Index was outside the bounds"' -ForEach @(
        @{ Path = 'Configuration' }
        @{ Path = 'НевідомийВид' }
        @{ Path = 'Subsystems/ОдинСегмент.txt' }
        @{ Path = 'Subsystems/A/Subsystems' }
        @{ Path = 'Catalogs/ОдинСегмент.txt' }
        @{ Path = 'Catalogs/Об1/Forms/ФайлБезТекиФорми' }
        @{ Path = 'Catalogs/Об1/Templates/ФайлБезТекиМакета' }
        @{ Path = 'Catalogs/Об1/Commands/ФайлБезТекиКоманди' }
    ) {
        { Convert-KitEdtPath -EdtPath $Path } | Should -Not -Throw
        $r = Convert-KitEdtPath -EdtPath $Path
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unresolved'
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It 'файл без відповідника (<Path>) -> DesignerRelPath = $null, Status = Unmapped (ЗНАЄМО, що не потрібне), Reason пояснює, Kind = $null' -ForEach @(
        @{ Path = 'DT-INF/1CV8.dt' }
        @{ Path = '.project' }
        @{ Path = '.settings' }
        @{ Path = 'AUTHORS' }
        @{ Path = 'VERSION' }
        @{ Path = 'ConfigDumpInfo.xml' }
        @{ Path = 'DumpFilesIndex.txt' }
    ) {
        $r = Convert-KitEdtPath -EdtPath $Path
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unmapped'
        $r.Reason | Should -Not -BeNullOrEmpty
        $r.Kind | Should -BeNullOrEmpty
    }

    It 'невідомий вид метаданих (немає ні в довідниках, ні в парку) -> Unresolved (НЕ ЗНАЄМО, що це — не мовчазне вгадування і не сміття), Kind = $null' {
        $r = Convert-KitEdtPath -EdtPath 'НевідомийВид/Об1/Об1.mdo'
        $r.DesignerRelPath | Should -BeNullOrEmpty
        $r.Status | Should -Be 'Unresolved'
        $r.Reason | Should -BeLike '*невідомий вид*'
        $r.Kind | Should -BeNullOrEmpty
    }

    It 'кириличні імена метаданих проходять без спотворення (SMP_OnlineExchange)' {
        $r = Convert-KitEdtPath -EdtPath 'Catalogs/КлиентыИнтернетМагазина/Forms/ФормаЭлемента/Module.bsl'
        $r.DesignerRelPath | Should -Be 'Catalogs/КлиентыИнтернетМагазина/Forms/ФормаЭлемента/Ext/Form/Module.bsl'
    }
}

Describe 'EdtPaths.psm1 — Get-KitEdtRenamePlan: обхід дерева, чотири списки (§9.2)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/EdtPaths.psm1").Path -Force
    }

    It 'звичайне дерево — усе в Moves з коректними From/To/Kind' {
        $root = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'cf/src/Catalogs/Об1') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'cf/src/Catalogs/Об1/Об1.mdo') -Value 'x'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'cf/src' -TargetRoot 'Продукт/cf/src'
        $plan.Collisions.Count | Should -Be 0
        $plan.Unmapped.Count | Should -Be 0
        $plan.Unresolved.Count | Should -Be 0
        $plan.Moves.Count | Should -Be 1
        $plan.Moves[0].From | Should -Be 'cf/src/Catalogs/Об1/Об1.mdo'
        $plan.Moves[0].To | Should -Be 'Продукт/cf/src/Catalogs/Об1.xml'
        $plan.Moves[0].Kind | Should -Be 'Catalogs'
    }

    It 'Unresolved: розширення макета без доказу (scheme/addin) — окремий перелік, не Unmapped, не Moves' {
        $root = Join-Path $TestDrive 'unresolved'
        $dir = Join-Path $root 'src/Reports/Об1/Templates/Мак1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Template.scheme') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'Template.addin') -Value 'y'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'src' -TargetRoot 'Продукт/cfe/src'
        $plan.Moves.Count | Should -Be 0
        $plan.Unmapped.Count | Should -Be 0
        $plan.Unresolved.Count | Should -Be 2
        $plan.Unresolved.From | Should -Contain 'src/Reports/Об1/Templates/Мак1/Template.scheme'
        $plan.Unresolved.From | Should -Contain 'src/Reports/Об1/Templates/Мак1/Template.addin'
    }

    It 'колізія: два різні EDT-шляхи -> один Designer-шлях — непорожній Collisions, обидва відсутні в Moves' {
        # CommonTemplates/<Ім'я>/<mxlx і dcs> обидва загортаються в Ext/Template.xml
        # (XML-контейнер, $script:TemplateXmlWrappedExtensions) — два файли в тій самій теці
        # об'єкта навмисно відтворюють колізію, яку має ловити САМЕ Get-KitEdtRenamePlan.
        $root = Join-Path $TestDrive 'collision'
        $dir = Join-Path $root 'cf/src/CommonTemplates/Мак1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Template.mxlx') -Value 'a'
        Set-Content -LiteralPath (Join-Path $dir 'Template.dcs') -Value 'b'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'cf/src' -TargetRoot 'Продукт/cf/src'
        $plan.Unresolved.Count | Should -Be 0
        $plan.Collisions.Count | Should -Be 1
        $plan.Collisions[0].To | Should -Be 'Продукт/cf/src/CommonTemplates/Мак1/Ext/Template.xml'
        @($plan.Collisions[0].From).Count | Should -Be 2
        $plan.Moves.From | Should -Not -Contain 'cf/src/CommonTemplates/Мак1/Template.mxlx'
        $plan.Moves.From | Should -Not -Contain 'cf/src/CommonTemplates/Мак1/Template.dcs'
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

    It 'C-C, живий сценарій: CommonTemplates HTMLDocument (Template.htmldoc + ru.html + uk.html) — три Moves, жодної колізії' {
        $root = Join-Path $TestDrive 'htmldoc'
        $dir = Join-Path $root 'src/CommonTemplates/Печать'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Печать.mdo') -Value 'd'
        Set-Content -LiteralPath (Join-Path $dir 'Template.htmldoc') -Value 'a'
        Set-Content -LiteralPath (Join-Path $dir 'ru.html') -Value 'b'
        Set-Content -LiteralPath (Join-Path $dir 'uk.html') -Value 'c'

        $plan = Get-KitEdtRenamePlan -RepoRoot $root -SourceRelPath 'src' -TargetRoot 'Продукт/cfe/src'
        $plan.Collisions.Count | Should -Be 0 -Because 'раніше всі чотири файли мапились у ОДИН Ext/Template.xml (C-C)'
        $plan.Unmapped.Count | Should -Be 0
        $plan.Unresolved.Count | Should -Be 0
        $plan.Moves.Count | Should -Be 4
        ($plan.Moves | Where-Object From -Like '*Печать.mdo').To | Should -Be 'Продукт/cfe/src/CommonTemplates/Печать.xml'
        ($plan.Moves | Where-Object From -Like '*Template.htmldoc').To | Should -Be 'Продукт/cfe/src/CommonTemplates/Печать/Ext/Template.xml' -Because 'htmldoc теж загортається в XML-дескриптор (1c-config-objects-spec.md §6.4) — остаточна таблиця, не round-1 версія'
        ($plan.Moves | Where-Object From -Like '*ru.html').To | Should -Be 'Продукт/cfe/src/CommonTemplates/Печать/Ext/Template/ru.html'
        ($plan.Moves | Where-Object From -Like '*uk.html').To | Should -Be 'Продукт/cfe/src/CommonTemplates/Печать/Ext/Template/uk.html'
    }
}
