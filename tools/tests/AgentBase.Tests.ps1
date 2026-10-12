#Requires -Version 7
Describe 'AgentBase.psm1 — база агента з вказівника Уніки, аудит проти бази людини' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/AgentBase.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'файлова база з infobases.origin: шлях під воркспейсом, ще не існує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'file'
        $ab.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib')))
        $ab.Exists | Should -BeFalse
        $ab.Origin | Should -BeLike '*v8project.local.yaml'
    }

    It 'v8project.local.yaml перекриває на серверну; Origin — накладка Уніки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'server')
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=agent_alpha;'
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'server'
        $ab.IbSwitch | Should -Be '/S "VSDEV\agent_alpha"'
        $ab.Origin | Should -BeLike '*v8project.local.yaml'
    }

    It 'підключення бази агента збігається з дев-базою людини з накладки kit — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=SMP_UNF;'
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Правка виконавця (обов'язкова, ухвалена заздалегідь): у брифі тест мав патерн
        # '*devUNF*людини*', але саме повідомлення функції несе зворотний порядок —
        # «...збігається з дев-базою людини 'devUNF' із накладки kit» (межа принципу 3
        # читається людиною, і саме повідомлення не змінюється; змінюється тест).
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*людини*devUNF*'
    }

    It 'воркспейс без infobases.origin — $null' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws)
        Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] | Should -BeNullOrEmpty
    }

    It 'пароль і dbms з infobases.origin доходять до результату' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'with-pwd')
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=build/ib' -User 'agent' -Password 'S3cr3t'
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.User | Should -Be 'agent'
        $ab.Password | Should -Be 'S3cr3t'
        $ab.PSObject.Properties.Name | Should -Contain 'Dbms'
    }

    It 'П16: воркспейс з EXTENSION без infobases.origin — потребує бази, Resolve-KitAgentBase дає $null' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-origin') -Workspaces ([ordered]@{
            'Alpha_SMB' = @{ Sets = @(@{ Name = 'Alpha_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } })
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ws = $ctx.Workspaces[0]
        Test-KitWorkspaceNeedsAgentBase -Workspace $ws | Should -BeTrue
        Resolve-KitAgentBase -Context $ctx -Workspace $ws | Should -BeNullOrEmpty
        New-KitAgentBaseMissingMessage -WorkspacePath 'Alpha_SMB' | Should -BeLike '*infobases.origin*v8storagekit:provision*'
    }

    It 'П16: воркспейс лише з EXTERNAL_DATA_PROCESSORS — бази не потребує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'epf') -Workspaces ([ordered]@{
            'Epf' = @{ Sets = @(@{ Name = 'external-processors'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } })
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        Test-KitWorkspaceNeedsAgentBase -Workspace $ctx.Workspaces[0] | Should -BeFalse
    }

    It 'збіг з дев-базою людини: повідомлення називає infobases.origin, не стару форму' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-msg') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
        Set-KitFakeAgentBase -Repo $repo -Connection 'Srvr=VSDEV;Ref=SMP_UNF;'
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*приберіть infobases.origin*'
    }

    It 'F1-регресія: кінцевий роздільник у File= — раніше текстовий $norm бачив розбіжність у тій самій теці, тепер зупинка' {
        # Той самий сценарій, що я прогнав уручну проти старого $norm: 'File=D:\Bases\SMP_UNF\'
        # (з кінцевим \) і 'File=D:\Bases\SMP_UNF' (без) — та сама тека, текстово різні рядки.
        # Стара текстова нормалізація ($norm у AgentBase.psm1 до фіксу) мовчала б тут — принцип 3
        # не спрацював би, і provision -Apply -Force стер би базу людини.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'trailing-slash') -OverlayText "infobases:`n  devUNF:`n    connection: 'File=D:\Bases\SMP_UNF\'"
        Set-KitFakeAgentBase -Repo $repo -Connection 'File=D:\Bases\SMP_UNF'
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*людини*devUNF*'
    }

    It 'F1-регресія: типовий відносний File=build/ib бази агента НЕ кидає, коли в накладці є (інша) дев-база — регрес, знайдений архітектором' {
        # Дефект, знайдений під час планування F1: правило "відносний File= кидає"
        # застосоване до ОБОХ боків ламало б штатну конфігурацію — фікстура за
        # замовчуванням дає саме відносний File=build/ib, і аудит кидав би на КОЖНОМУ
        # прогоні provision, щойно в накладці є хоч одна infobases:. Без цього тесту
        # регресія лишилась би непоміченою: Resolve-KitAgentBase МАЄ спершу розв'язати
        # File=build/ib до абсолютного шляху (Resolve-KitAgentInfobasePath) і звіряти вже
        # абсолютне підключення — не сирий відносний рядок.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'relative-ok') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=VSDEV;Ref=SMP_UNF;'"
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Виклик НАПРЯМУ, не всередині { } | Should -Not -Throw: скрипт-блок Pester
        # виконується у власній дочірній області видимості, і присвоєння $ab усередині
        # нього НЕ поверталось би зовнішній $ab (класична пастка scope у PowerShell) —
        # якби функція таки кинула виняток, цей рядок сам провалив би тест з тим самим
        # повідомленням, тож окремий Should -Not -Throw тут не потрібен.
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'file'
        $ab.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib')))
    }
}

Describe 'AgentBase.psm1 — Test-KitSameInfobase (F1: ідентичність бази, не текст підключення)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/AgentBase.psm1").Path -Force
    }

    It 'кінцевий роздільник File= — та сама тека, збіг' {
        Test-KitSameInfobase -Left 'File=D:\Bases\SMP_UNF\' -Right 'File=D:\Bases\SMP_UNF' | Should -BeTrue
    }

    It 'регістр File= — не залежить, збіг' {
        Test-KitSameInfobase -Left 'File=D:\Bases\SMP_UNF' -Right 'File=d:\bases\smp_unf' | Should -BeTrue
    }

    It 'різні теки File= — не збіг' {
        Test-KitSameInfobase -Left 'File=D:\Bases\SMP_UNF' -Right 'File=D:\Bases\Other' | Should -BeFalse
    }

    It 'порядок ключів Srvr/Ref — незалежний, збіг' {
        Test-KitSameInfobase -Left 'Srvr=VSDEV;Ref=SMP_UNF;' -Right 'Ref=SMP_UNF;Srvr=VSDEV;' | Should -BeTrue
    }

    It 'різний Ref на тому самому сервері — не збіг' {
        Test-KitSameInfobase -Left 'Srvr=VSDEV;Ref=SMP_UNF;' -Right 'Srvr=VSDEV;Ref=Other;' | Should -BeFalse
    }

    It 'різний Kind (file проти server) — безпечно не збіг, без зупинки: ми ЗНАЄМО, що бази різні' {
        { Test-KitSameInfobase -Left 'File=D:\Bases\SMP_UNF' -Right 'Srvr=VSDEV;Ref=SMP_UNF;' } | Should -Not -Throw
        Test-KitSameInfobase -Left 'File=D:\Bases\SMP_UNF' -Right 'Srvr=VSDEV;Ref=SMP_UNF;' | Should -BeFalse
    }

    It 'порожній рядок — кидає (fail-closed, не "не збігається")' {
        { Test-KitSameInfobase -Left '' -Right 'File=D:\x' } | Should -Throw
    }

    It 'Srvr= без Ref= — кидає' {
        { Test-KitSameInfobase -Left 'Srvr=VSDEV;' -Right 'File=D:\x' } | Should -Throw
    }

    It 'підключення не File= і не Srvr= — кидає' {
        { Test-KitSameInfobase -Left 'щось незрозуміле' -Right 'File=D:\x' } | Should -Throw
    }

    It 'відносний File= — кидає (ця функція не знає бази відліку; викликач мусить розв''язати сам)' {
        { Test-KitSameInfobase -Left 'File=build/ib' -Right 'File=D:\x' } | Should -Throw
    }

    It 'кидаючий виняток називає нерозбірну сторону за походженням, а не рядком (П23)' {
        $err = $null
        try { Test-KitSameInfobase -Left 'File=build/ib' -Right 'File=D:\x;Pwd=СЕКРЕТ-Ж7' -LeftOrigin 'ЛІВА-ПОХОДЖЕННЯ' -RightOrigin 'ПРАВА-ПОХОДЖЕННЯ' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*ЛІВА-ПОХОДЖЕННЯ*'
        $err | Should -Not -BeLike '*ПРАВА-ПОХОДЖЕННЯ*'
        $err | Should -Not -BeLike '*build/ib*'
        $err | Should -Not -BeLike '*D:\x*'
        # права сторона нерозбірна (Pwd) при розібраній лівій — називається права, значення немає
        $err = $null
        try { Test-KitSameInfobase -Left 'File=D:\ok' -Right 'File=D:\x;Pwd=СЕКРЕТ-Ж7' -LeftOrigin 'ЛІВА-ПОХОДЖЕННЯ' -RightOrigin 'ПРАВА-ПОХОДЖЕННЯ' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*ПРАВА-ПОХОДЖЕННЯ*'
        $err | Should -Not -BeLike '*ЛІВА-ПОХОДЖЕННЯ*'
        $err | Should -Not -BeLike '*Ж7*'
        $err | Should -Not -BeLike '*D:\*'
    }
    It 'Srvr у лапках і без лапок — та сама база (§4.3 п. 4)' {
        # Властивість безпеки: якби лапки робили запис «іншою базою», аудит «база агента ≠ база
        # людини» пропустив би колізію (мовчазний дозвіл до provision -Apply -Force).
        Test-KitSameInfobase -Left 'Srvr="VSDEV";Ref="SMP_UNF";' -Right 'Ref=smp_unf;Srvr=vsdev' | Should -BeTrue
    }

    It 'парні лапки не роблять різні бази однаковими' {
        Test-KitSameInfobase -Left 'Srvr="VSDEV";Ref="SMP_UNF";' -Right 'Srvr=VSDEV;Ref=Other;' | Should -BeFalse
    }

    It 'непарна лапка — fail-closed: кидає, навіть коли на іншому боці коректний запис' {
        { Test-KitSameInfobase -Left 'Srvr="VSDEV;Ref=SMP_UNF;' -Right 'Srvr=VSDEV;Ref=SMP_UNF;' } | Should -Throw '*непарні лапки*'
    }
}
