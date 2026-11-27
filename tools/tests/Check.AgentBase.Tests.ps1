#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It 'джерело truth: storage у воркспейсі без бази агента — warn agent-base-required' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-no-base') -Workspaces $ws -WithHooks
        $r = Invoke-Check -Repo $repo
        # Тег знахідки ('agent-base-required') у Write-Host не друкується — лише Message
        # (той самий факт, що вже задокументовано нижче для 'build-artifacts'): підставою для
        # асерції править фраза з повідомлення. 'v8storagekit:infobase-agent' у виводі 'kit check' зустрічається
        # лише в ЦЬОМУ повідомленні (перевірено grep по tools/lib/ і tools/commands/ у контексті
        # виконання check) — підміна 'agent-base-required', яка інакше НІКОЛИ не з'явиться в
        # Output і зробила б обидва тести (і позитивний, і негативний) хибними без різниці.
        $r.Output | Should -BeLike '*v8storagekit:infobase-agent*'
        $r.Output | Should -BeLike '*Alpha_SMB*'
    }

    It 'truth: storage без infobases.origin — warn з рецептом v8storagekit:infobase-agent, не error' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'p16') -WithHooks -WithGitignore -Workspaces ([ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } })
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*[!]*Alpha_SMB*не налаштована*v8storagekit:infobase-agent*'
    }

    It 'база агента з infobases.origin у v8project.local.yaml збігається з дев-базою людини — check це каже' {
        $repo = New-GoodRepo -Name 'agent-base-collision'
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        # Дев-база людини в накладці вказує на ту саму теку, що infobases.origin бази агента (фікстура
        # пише її у v8project.local.yaml).
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*дев-базою людини*'
    }

    It 'Бази агента двох воркспейсів перетинаються — error з обома воркспейсами, код 1' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-two-ws') -Workspaces $ws -WithHooks -WithGitignore
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Alpha_SMB' -Connection ('File=' + (Join-Path $repo 'Beta_SMB/build/ib/a'))
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*Alpha_SMB*перетинається з базою агента воркспейсу 'Beta_SMB'*"
        # пара симетрична — повідомлено один раз
        ([regex]::Matches($r.Output, 'перетинається з базою агента воркспейсу')).Count | Should -Be 1
    }

    It 'База Beta лежить у .local/infobases воркспейсу Alpha — error з боку Beta (гілка memory-theirs); з боку Alpha збігу немає, код 1' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-memory') -Workspaces $ws -WithHooks -WithGitignore
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection ('File=' + (Join-Path $repo 'Alpha_SMB/.local/infobases/x'))
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        # memory-theirs: з боку Beta його база лежить в .local/infobases Alpha. З боку Alpha збігу немає: захищена лише її origin.
        $r.Output | Should -BeLike "*Beta_SMB/v8project.local.yaml: база агента воркспейсу 'Beta_SMB' лежить у '.local/infobases' воркспейсу 'Alpha_SMB'*"
        $r.Output | Should -Not -BeLike "*Alpha_SMB/v8project.local.yaml: база агента воркспейсу 'Beta_SMB' лежить*"
        # Наслідок — те, що правда зараз: kit нічого не видаляє, шкода в чужій теці й пораді provision.
        $r.Output | Should -BeLike '*kit створив би чи завантажив базу агента в теку (базу) іншого воркспейсу*порада provision видалити теку бази*'
        $r.Output | Should -Not -BeLike '*-Force*'
    }

    It 'База Beta лежить у пам''яті раннера Alpha (.local/infobases/origin) — memory-mine: текст називає пам''ять раннера, а не infobases' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-memory-origin') -Workspaces $ws -WithHooks -WithGitignore
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection ('File=' + (Join-Path $repo 'Alpha_SMB/.local/infobases/origin/x'))
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*Alpha_SMB/v8project.local.yaml: база агента воркспейсу 'Beta_SMB' лежить у пам'яті раннера '.local/infobases/origin' воркспейсу 'Alpha_SMB'*"
    }

    It 'База Beta в workPath/infobases Alpha (шлях 1.5.0) — вже не збіг: раннер 0.18 веде пам''ять не там' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-memory-old-path') -Workspaces $ws -WithHooks -WithGitignore -WithGitattributes
        Set-KitFakeAgentBase -Repo $repo -Workspace 'Beta_SMB' -Connection ('File=' + (Join-Path $repo 'Alpha_SMB/build/infobases/origin/x'))
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike "*пам'яті раннера*"
        $r.Output | Should -Not -BeLike '*лежить у*infobases*'
    }
    It 'agentBase.template воркспейсу з пробілу в накладці — error з ключем, без значення' {
        $repo = New-GoodRepo -Name 'f1-blank-template'
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Encoding UTF8 -Value "workspaces:`n  Alpha_SMB:`n    agentBase:`n      template: ' '"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*workspaces.Alpha_SMB.agentBase.template порожній*'
        $r.Output | Should -BeLike '*рішення прибрати шаблон — за людиною*'
        $r.Output | Should -Not -BeLike '*приберіть ключ*'
    }

    It 'Серверні бази двох воркспейсів з тим самим Ref — error без слів про теку, один раз' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-srv-ref') -Workspaces $ws -WithHooks -WithGitignore
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') { Set-KitFakeAgentBase -Repo $repo -Workspace $n -Connection 'Srvr=VSDEV;Ref=agent_shared;' }
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*та сама серверна база (збігаються сервер і Ref)*"
        $r.Output | Should -BeLike '*(збігаються сервер і Ref) — kit створив би чи завантажив базу агента*'
        ([regex]::Matches($r.Output, 'та сама серверна база')).Count | Should -Be 1
    }

    It 'Та сама серверна база: однаковий власник (dump.from) — порада перенести набір; різні власники — окрема тека' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-srv-owner') -Workspaces $ws -WithHooks -WithGitignore
        foreach ($n in 'Alpha_SMB', 'Beta_SMB') { Set-KitFakeAgentBase -Repo $repo -Workspace $n -Connection 'Srvr=VSDEV;Ref=agent_shared;' }
        $same = Invoke-Check -Repo $repo
        $same.ExitCode | Should -Be 1
        $same.Output | Should -BeLike '*перенесіть набір у воркспейс того самого власника*'
        $same.Output | Should -Not -BeLike '*окрему теку infobases.origin.connection*'

        $manifest = Join-Path $repo 'v8storagekit.yaml'
        $text = Get-Content -LiteralPath $manifest -Raw
        $text = $text -replace '(baseB: \{ truth: \w+, dump: \{ from: )dev', '${1}devB'
        Set-Content -LiteralPath $manifest -Value $text -Encoding UTF8 -NoNewline
        $diff = Invoke-Check -Repo $repo
        $diff.ExitCode | Should -Be 1
        $diff.Output | Should -BeLike '*окрему теку infobases.origin.connection*'
        $diff.Output | Should -Not -BeLike '*перенесіть набір у воркспейс того самого власника*'
    }

    It 'Контроль: build/ibA і build/ibB — check не скаржиться на перетин' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{ Infobase = 'File=build/ibA'; Sets = @(@{ Name = 'baseA'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
            'Beta_SMB'  = @{ Infobase = 'File=build/ibB'; Sets = @(@{ Name = 'baseB'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'Beta_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-two-ws-ok') -Workspaces $ws -WithHooks -WithGitignore
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*перетинається з базою агента воркспейсу*'
    }

    It 'стара форма infobase: лише у v8project.local.yaml — error зі знахідкою "стара форма", код 1' {
        $repo = New-GoodRepo 'old-form-local'
        Set-Content -LiteralPath (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value "infobase:`n  connection: 'File=build/ib'"
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*Alpha_SMB*v8project.local.yaml*стара форма 'infobase:'*"
    }

    It 'база агента на місці — знахідки немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-with-base') -WithHooks
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*v8storagekit:infobase-agent*'
    }

    It 'усе гаразд — код 0, лише інформаційні рядки' {
        $r = Invoke-Check -Repo (New-GoodRepo 'good')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
        $r.Output | Should -Not -Match '\[-\]'
    }
}
