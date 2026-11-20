#Requires -Version 7
# kit-scan: посилання на superpowers із заміною v8storagekit і межа діапазону кроків оновлення
# (оригінал — agent-kit 0.9.1 tests/kit-scan.test.mjs). Справжній kit-process.ps1 підпроцесом на
# синтетичному git-репо в TestDrive: — за зразком KitSetup.Tests.ps1. Плагін — копія tools/, skills/,
# agents/ зі своїми plugin.json і CHANGELOG.md.
Describe 'kit-scan — скан підключення' {
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
        $script:KitProcess = Join-Path $script:Plugin 'tools/kit-process.ps1'

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
}
