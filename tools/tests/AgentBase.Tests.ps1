#Requires -Version 7
Describe 'AgentBase.psm1 — база агента з вказівника Уніки, аудит проти бази людини' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/AgentBase.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'файлова база з v8project.yaml: шлях під воркспейсом, ще не існує' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'file')
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'file'
        $ab.Path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $repo 'Alpha_SMB/build/ib')))
        $ab.Exists | Should -BeFalse
        $ab.Origin | Should -BeLike '*v8project.yaml'
    }

    It 'v8project.local.yaml перекриває на серверну; Origin — накладка Уніки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'server')
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""agent_alpha"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        $ab = Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0]
        $ab.Kind | Should -Be 'server'
        $ab.IbSwitch | Should -Be '/S "VSDEV\agent_alpha"'
        $ab.Origin | Should -BeLike '*v8project.local.yaml'
    }

    It 'підключення бази агента збігається з дев-базою людини з накладки kit — зупинка (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'")
        $ctx = Invoke-KitPreflight -RepoRoot $repo
        # Правка виконавця (обов'язкова, ухвалена заздалегідь): у брифі тест мав патерн
        # '*devUNF*людини*', але саме повідомлення функції несе зворотний порядок —
        # «...збігається з дев-базою людини 'devUNF' із накладки kit» (межа принципу 3
        # читається людиною, і саме повідомлення не змінюється; змінюється тест).
        { Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] } | Should -Throw '*людини*devUNF*'
    }

    It 'воркспейс без infobase: — $null' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $ctx = Invoke-KitPreflight -RepoRoot (New-KitFakeRepo -Root (Join-Path $TestDrive 'none') -Workspaces $ws)
        Resolve-KitAgentBase -Context $ctx -Workspace $ctx.Workspaces[0] | Should -BeNullOrEmpty
    }

    It 'F1-регресія: кінцевий роздільник у File= — раніше текстовий $norm бачив розбіжність у тій самій теці, тепер зупинка' {
        # Той самий сценарій, що я прогнав уручну проти старого $norm: 'File="D:\Bases\SMP_UNF\"'
        # (з кінцевим \) і 'File=D:\Bases\SMP_UNF' (без) — та сама тека, текстово різні рядки.
        # Стара текстова нормалізація ($norm у AgentBase.psm1 до фіксу) мовчала б тут — принцип 3
        # не спрацював би, і provision -Apply -Force стер би базу людини.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'trailing-slash') -OverlayText "infobases:`n  devUNF:`n    connection: 'File=""D:\Bases\SMP_UNF\""'"
        Set-Content (Join-Path $repo 'Alpha_SMB/v8project.local.yaml') -Encoding UTF8 -Value @('infobase:', "  connection: 'File=""D:\Bases\SMP_UNF""'")
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
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'relative-ok') -OverlayText "infobases:`n  devUNF:`n    connection: 'Srvr=""VSDEV"";Ref=""SMP_UNF"";'"
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
        Test-KitSameInfobase -Left 'File="D:\Bases\SMP_UNF\"' -Right 'File="D:\Bases\SMP_UNF"' | Should -BeTrue
    }

    It 'регістр File= — не залежить, збіг' {
        Test-KitSameInfobase -Left 'File="D:\Bases\SMP_UNF"' -Right 'File="d:\bases\smp_unf"' | Should -BeTrue
    }

    It 'різні теки File= — не збіг' {
        Test-KitSameInfobase -Left 'File="D:\Bases\SMP_UNF"' -Right 'File="D:\Bases\Other"' | Should -BeFalse
    }

    It 'порядок ключів Srvr/Ref — незалежний, збіг' {
        Test-KitSameInfobase -Left 'Srvr="VSDEV";Ref="SMP_UNF";' -Right 'Ref="SMP_UNF";Srvr="VSDEV";' | Should -BeTrue
    }

    It 'різний Ref на тому самому сервері — не збіг' {
        Test-KitSameInfobase -Left 'Srvr="VSDEV";Ref="SMP_UNF";' -Right 'Srvr="VSDEV";Ref="Other";' | Should -BeFalse
    }

    It 'різний Kind (file проти server) — безпечно не збіг, без зупинки: ми ЗНАЄМО, що бази різні' {
        { Test-KitSameInfobase -Left 'File="D:\Bases\SMP_UNF"' -Right 'Srvr="VSDEV";Ref="SMP_UNF";' } | Should -Not -Throw
        Test-KitSameInfobase -Left 'File="D:\Bases\SMP_UNF"' -Right 'Srvr="VSDEV";Ref="SMP_UNF";' | Should -BeFalse
    }

    It 'порожній рядок — кидає (fail-closed, не "не збігається")' {
        { Test-KitSameInfobase -Left '' -Right 'File="D:\x"' } | Should -Throw
    }

    It 'Srvr= без Ref= — кидає' {
        { Test-KitSameInfobase -Left 'Srvr="VSDEV";' -Right 'File="D:\x"' } | Should -Throw
    }

    It 'підключення не File= і не Srvr= — кидає' {
        { Test-KitSameInfobase -Left 'щось незрозуміле' -Right 'File="D:\x"' } | Should -Throw
    }

    It 'відносний File= — кидає (ця функція не знає бази відліку; викликач мусить розв''язати сам)' {
        { Test-KitSameInfobase -Left 'File=build/ib' -Right 'File="D:\x"' } | Should -Throw
    }

    It 'кидаючий виняток називає обидва підключення дослівно' {
        $err = $null
        try { Test-KitSameInfobase -Left 'File=build/ib' -Right 'File="D:\x"' } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*build/ib*'
        $err | Should -BeLike '*D:\x*'
    }
}
