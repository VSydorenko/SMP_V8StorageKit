#Requires -Version 7
# kit-scan: посилання на superpowers із заміною v8storagekit і межа діапазону кроків оновлення
# (оригінал — agent-kit 0.9.1 tests/kit-scan.test.mjs). Справжній kit.ps1 підпроцесом на
# синтетичному git-репо в TestDrive: — за зразком KitSetup.Tests.ps1. Плагін — копія tools/, skills/,
# agents/ зі своїми plugin.json і CHANGELOG.md.
Describe 'kit-scan — скан підключення' -Tag 'Docs' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $kitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Plugin = Split-Path (Copy-KitTools -Root (Join-Path $TestDrive 'plugin')) -Parent | Split-Path -Parent
        foreach ($d in 'skills', 'agents') { Copy-Item -Path (Join-Path $kitRoot $d) -Destination $script:Plugin -Recurse -Force }
        [System.IO.File]::WriteAllText((Join-Path $script:Plugin '.claude-plugin/plugin.json'), '{ "name": "v8storagekit-scan-test", "version": "1.7.0" }')
        [System.IO.File]::WriteAllText((Join-Path $script:Plugin 'CHANGELOG.md'), @'
# Журнал змін

## 1.7.0 — 2026-11-20

### Що змінилось

- нове

### Чекліст оновлення проєкту

- [ ] Крок сім-нуль

## 1.5.0 — 2026-10-01

### Що змінилось

- старе

### Чекліст оновлення проєкту

- [ ] Крок п-один
- [ ] Крок п-два
'@)
        $script:KitProcess = Join-Path $script:Plugin 'tools/kit.ps1'

        function script:New-Repo {
            param([string]$Name)
            $repo = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $repo | Out-Null
            & git -C $repo init -q -b main 2>&1 | Out-Null
            $repo
        }
        function script:Invoke-Scan {
            param([string]$Repo, [string[]]$Arguments = @())
            $saved = $env:CLAUDE_CONFIG_DIR, $env:XDG_CONFIG_HOME
            # Порожній конфіг-каталог: скан не читає справжню пам'ять і машинний профіль розробника.
            $env:CLAUDE_CONFIG_DIR = Join-Path $TestDrive 'claude-config'
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
            Push-Location $Repo
            try { $out = & pwsh -NoProfile -File $script:KitProcess kit-scan @Arguments 2>&1 | Out-String; $code = $LASTEXITCODE }
            finally { Pop-Location; $env:CLAUDE_CONFIG_DIR, $env:XDG_CONFIG_HOME = $saved }
            [pscustomobject]@{ Code = $code; Out = $out }
        }
    }

    It 'знаходить docs/superpowers і посилання на скіл, називає заміну v8storagekit:plan' {
        $repo = New-Repo 'sp'
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs/superpowers/plans') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'docs/superpowers/plans/x.md') -Value '# план' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Encoding utf8NoBOM -Value "# Правила`nвикористовуй superpowers:writing-plans для планів`n"
        $r = Invoke-Scan $repo
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '(?m)^\| S1 \| `CLAUDE\.md:2` \|.*writing-plans → v8storagekit:plan' -Because $r.Out
        $r.Out | Should -Not -Match 'v8storagekit:plan \(planned\)' -Because 'скіл plan є в плагіні'
        $r.Out | Should -Match '(?m)^- `docs/superpowers/plans/`: 1 файлів' -Because $r.Out
        $r.Out | Should -Match '(?m)^next: kit-setup -DryRun\r?$'
    }

    It 'Skills outside the plugin: копія скіла плагіна — same-name, скіл про 1С — domain, решта — other' {
        $repo = New-Repo 'skills'
        $userSkills = Join-Path $TestDrive 'claude-config/skills'
        $mk = { param($name, $body) New-Item -ItemType Directory -Path (Join-Path $userSkills $name) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $userSkills "$name/SKILL.md") -Encoding utf8NoBOM -Value "---`nname: $name`ndescription: x`n---`n$body`n" }
        & $mk 'storage-sync' 'копія, яка лишилась після перенесення'
        & $mk 'bsp-recipe' 'Розширення 1С на БСП: службовий користувач створюється в обробнику оновлення.'
        # Одна ознака предмета — не domain: «1С» мимохідь у скілі про інше.
        & $mk 'notes' 'Нотатки про нараду; згадали 1С один раз.'
        try { $r = Invoke-Scan $repo } finally { Remove-Item -LiteralPath $userSkills -Recurse -Force }
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '(?m)^## Skills outside the plugin \(3\)' -Because $r.Out
        $r.Out | Should -Match '(?m)^\| K\d+ \| `[^`]*/skills/storage-sync/` \| user \| same-name \| remove: у плагіні є v8storagekit:storage-sync' -Because $r.Out
        $r.Out | Should -Match '(?m)^\| K\d+ \| `[^`]*/skills/bsp-recipe/` \| user \| domain \| move-to-plugin' -Because $r.Out
        $r.Out | Should -Match '(?m)^\| K\d+ \| `[^`]*/skills/notes/` \| user \| other \|' -Because $r.Out
    }

    It 'Duplicates: власна bin/session-board споживача — та сама підказка, що й для команди з модулем (bin/sdd)' {
        # session-board виконує kit.exe: модуля в tools/commands немає, у плагіні його ознака — обгортка bin/.
        $pluginBin = Join-Path $script:Plugin 'bin'
        New-Item -ItemType Directory -Path $pluginBin -Force | Out-Null
        foreach ($n in 'sdd', 'session-board') { Set-Content -LiteralPath (Join-Path $pluginBin "$n.ps1") -Value '# обгортка' }
        try {
            $repo = New-Repo 'binparts'
            New-Item -ItemType Directory -Path (Join-Path $repo 'bin') | Out-Null
            foreach ($n in 'sdd', 'session-board') { Set-Content -LiteralPath (Join-Path $repo "bin/$n") -Value "#!/bin/sh`necho власна $n" }
            $r = Invoke-Scan $repo -Arguments @('-Json')
        } finally { Remove-Item -LiteralPath $pluginBin -Recurse -Force }
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'та сама назва, що в bin sdd' -Because $r.Out
        $r.Out | Should -Match 'та сама назва, що в bin session-board' -Because $r.Out
    }

    It 'Kit version: кроки лише версій у (kit.version, плагін] — запис 1.5.0 не береться' {
        $repo = New-Repo 'ver'
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Value '{ "kit": { "version": "1.5.0" } }' -Encoding utf8NoBOM
        $r = Invoke-Scan $repo
        $r.Code | Should -Be 0 -Because $r.Out
        $steps = @([regex]::Matches($r.Out, '(?m)^- \[ \] V\d+ .*$') | ForEach-Object { $_.Value })
        $steps.Count | Should -Be 1 -Because $r.Out
        $steps[0] | Should -Match '^- \[ \] V1 Крок сім-нуль'
        $r.Out | Should -Not -Match 'Крок п-' -Because 'кроки 1.5.0 проєкт уже пройшов'
    }

    It 'Kit version: маніфест з kitVersion без профілю — connected-before; профіль без kit.version і без kitVersion — no-version' {
        $repo = New-Repo 'before'
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Value "kitVersion: `"1.4.0`" # старий`nname: x`n" -Encoding utf8NoBOM
        $r = Invoke-Scan $repo
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'підключено раніше \(1\.4\.0\), профілю немає' -Because $r.Out
        $r.Out | Should -Match 'kit check -RepoRoot \.' -Because $r.Out
        $r.Out | Should -Match 'V1 Крок п-один' -Because 'версії, новіші за 1.4.0, — усі'
        $r.Out | Should -Match 'V3 Крок сім-нуль' -Because $r.Out
        $r.Out | Should -Not -Match 'перше підключення' -Because $r.Out
        $json = (Invoke-Scan $repo -Arguments @('-Json')).Out | ConvertFrom-Json
        $json.kitVersion.status | Should -Be 'connected-before'
        # Профіль з kit.version переважає над маніфестом.
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/kit.profile.json') -Value '{ "kit": { "version": "1.7.0" } }' -Encoding utf8NoBOM
        (Invoke-Scan $repo -Arguments @('-Json')).Out | ConvertFrom-Json | ForEach-Object { $_.kitVersion.status } | Should -Be 'current'
        # D6: профіль без kit.version, маніфесту з kitVersion немає — без переліку кроків від 0.1.0.
        $repo2 = New-Repo 'nover'
        New-Item -ItemType Directory -Path (Join-Path $repo2 '.agents') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo2 '.agents/kit.profile.json') -Value '{ "pr": { "base": "main" } }' -Encoding utf8NoBOM
        $r2 = Invoke-Scan $repo2
        $r2.Out | Should -Match 'v8storagekit\.version немає — запише `kit-setup -SetVersion` останнім комітом PR' -Because $r2.Out
        $r2.Out | Should -Not -Match 'V\d+ Крок' -Because 'перелік кроків від 0.1.0 не друкується'
        # ADR-0018: kit.version agent-kit (0.x) — не версія v8storagekit; v8storagekit.version переважає над ним.
        Set-Content -LiteralPath (Join-Path $repo2 '.agents/kit.profile.json') -Value '{ "kit": { "version": "0.4.2" } }' -Encoding utf8NoBOM
        ((Invoke-Scan $repo2 -Arguments @('-Json')).Out | ConvertFrom-Json).kitVersion.status | Should -Be 'no-version'
        Set-Content -LiteralPath (Join-Path $repo2 '.agents/kit.profile.json') -Value '{ "kit": { "version": "0.4.2" }, "v8storagekit": { "version": "1.7.0" } }' -Encoding utf8NoBOM
        ((Invoke-Scan $repo2 -Arguments @('-Json')).Out | ConvertFrom-Json).kitVersion.status | Should -Be 'current'
    }

    It 'Obsolete names: рядок на кожну стару назву із заміною; kit sync, голе dump і чинне storage-sync рядка не дають' {
        $repo = New-Repo 'obsolete'
        Set-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Encoding utf8NoBOM -Value @'
# Правила
Скіл V8StorageKit:Reconcile для приймання.
Запуск: /v8storagekit:sync і pwsh tools/kit.ps1 check.
Контроль: kit sync, dump бази, v8storagekit:storage-sync, tools/kit.ps1x.
Форми шляху: pwsh -File ./tools/kit.ps1 sync
pwsh -NoProfile -File C:/p/tools/kit.ps1 check
pwsh -File C:\p\tools\kit.ps1 check
'@
        New-Item -ItemType Directory -Path (Join-Path $repo '.agents/out') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.agents/out/x.md') -Value 'v8storagekit:reconcile' -Encoding utf8NoBOM
        $r = Invoke-Scan $repo -Arguments @('-Json')
        $r.Code | Should -Be 0 -Because $r.Out
        $rows = @(($r.Out | ConvertFrom-Json).obsoleteNames)
        $rows.Count | Should -Be 6 -Because $r.Out
        foreach ($n in 5, 6, 7) { @($rows | Where-Object { $_.item -eq "CLAUDE.md:$n" -and $_.old -eq 'tools/kit.ps1' }).Count | Should -Be 1 -Because "рядок $n`: $($r.Out)" }
        ($rows | Where-Object { $_.item -eq 'CLAUDE.md:2' }).replacement | Should -Be 'v8storagekit:storage-adopt'
        ($rows | Where-Object { $_.item -eq 'CLAUDE.md:3' -and $_.old -eq 'v8storagekit:sync' }).replacement | Should -Be 'v8storagekit:storage-sync'
        ($rows | Where-Object { $_.item -eq 'CLAUDE.md:3' -and $_.old -eq 'tools/kit.ps1' }).replacement | Should -Be 'kit'
        $md = (Invoke-Scan $repo).Out
        $md | Should -Match '(?m)^\| O\d+ \| `CLAUDE\.md:2` \| `v8storagekit:reconcile` \| v8storagekit:storage-adopt' -Because $md
    }
}
