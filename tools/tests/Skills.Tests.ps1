#Requires -Version 7
Describe 'skills/*/SKILL.md — правила, які легко порушити' {
    BeforeAll {
        $script:SkillsDir = (Resolve-Path "$PSScriptRoot/../../skills").Path
        $script:Allowed = @('using-v8storagekit', 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify')   # migrate немає: спека 2f2da62, §9
        # Лише скіли 1.0. Три старі (storage-pipeline, product-onboarding, repo-migration) живуть у
        # дереві до Task 6 і НЕ мусять проходити ці правила: у них є storage-sync.ps1, dump-config.ps1
        # і перехресні посилання на імена поза $Allowed. Без фільтра весь файл був би червоний із
        # Task 2 по Task 5, і «запускати лише цей файл» не рятувало б (знахідка префлайту B5).
        # Те, що старих тек більше немає, перевіряє окремий It у Task 6 — саме там це стає правдою.
        $script:Skills = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory |
            Where-Object { $_.Name -in $script:Allowed } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Text = (Get-Content -LiteralPath (Join-Path $_.FullName 'SKILL.md') -Raw -Encoding UTF8) } })
        function script:Skill([string]$Name) { ($script:Skills | Where-Object Name -eq $Name).Text }
    }

    It 'frontmatter: name = ім''я теки, description з тригерами' {
        foreach ($s in $script:Skills) {
            $s.Text | Should -Match "(?m)^name:\s*$([regex]::Escape($s.Name))\s*$"
            $s.Text | Should -Match '(?m)^description:.*Тригер'
        }
    }
    It '${CLAUDE_PLUGIN_ROOT} — лише всередині шляху (за токеном одразу /)' {
        foreach ($s in $script:Skills) {
            [regex]::Matches($s.Text, '\$\{CLAUDE_PLUGIN_ROOT\}(?!/)').Count | Should -Be 0 -Because "у $($s.Name) токен вжито не як частину шляху"
        }
    }
    It 'перехресні посилання — лише з префіксом v8storagekit: і лише на відомі скіли' {
        foreach ($s in $script:Skills) {
            foreach ($m in [regex]::Matches($s.Text, 'v8storagekit:([a-z8-]+)')) {
                $script:Allowed | Should -Contain $m.Groups[1].Value -Because "у $($s.Name) посилання на невідомий скіл"
            }
            foreach ($old in 'storage-pipeline', 'product-onboarding', 'repo-migration') {
                $s.Text | Should -Not -Match "v8storagekit:$old" -Because "у $($s.Name) посилання на вилучений скіл $old"
            }
        }
    }
    It 'жодних згадок вилучених скриптів і storage.json (крім onboarding, який читає спадок 0.6.0)' {
        # onboarding — єдиний, кому storage.json дозволено згадувати: він бере звідти підказки для
        # двох перехідних репозиторіїв (B6). Після їх переходу розділ і цей виняток вилучаються.
        foreach ($s in ($script:Skills | Where-Object { $_.Name -notin @('onboarding') })) {
            $s.Text | Should -Not -Match 'storage-sync\.ps1|dump-config\.ps1|load-ext\.ps1|build\.ps1' -Because "у $($s.Name)"
        }
    }
    It 'кожен скіл життєвого циклу називає kit.ps1 повним шляхом через ${CLAUDE_PLUGIN_ROOT}' {
        foreach ($s in ($script:Skills | Where-Object { $_.Name -in @('onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify') })) {
            $s.Text | Should -Match '\$\{CLAUDE_PLUGIN_ROOT\}/tools/kit\.ps1' -Because "у $($s.Name)"
        }
    }

    Context 'onboarding' {
        It 'питає truth з чотирма варіантами й наслідками для git' {
            $t = Skill 'onboarding'
            foreach ($v in 'storage', 'dump', 'vendor', 'git') { $t | Should -Match "\*\*$v\*\*" }
            $t | Should -Match 'гітігноровано'
            $t | Should -Match 'мовчазного дефолту немає|Мовчазних дефолтів'
        }
        It 'шаблон v8project.yaml: база агента File=build/ib, name EXTENSION = ім''я розширення' {
            $t = Skill 'onboarding'
            $t | Should -Match "connection:\s*'File=build/ib'"
            $t | Should -Match '(?m)^\s*-\s*name:\s*<ІмʼяРозширення>'
        }
        It 'ставить хуки командою install-hooks, дописує -text і .gitignore під фактичні шляхи, перший коміт до -Apply' {
            $t = Skill 'onboarding'
            $t | Should -Match 'install-hooks'
            $t | Should -Match '<ws>/<path>/\*\* -text'
            $t | Should -Match 'перший коміт|Перший коміт'
            $t | Should -Not -Match 'v8storagekit:migrate'   # команди й скіла migrate немає (спека 2f2da62)
        }
    }
}