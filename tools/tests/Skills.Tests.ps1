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

    # --- Три загальні перевірки понад брифи (рев'ю B5 Task 2-5, мутаційні прогони) ---

    It 'перехресні посилання v8storagekit:ІМ''Я ведуть на теку skills/ІМ''Я, яка існує на диску' {
        # A: раніше звірялось лише зі статичним $script:Allowed — тека могла бути ще не
        # створена (так було з skills/sync до цього циклу), а тест мовчав. Тепер — диск.
        foreach ($s in $script:Skills) {
            foreach ($m in [regex]::Matches($s.Text, 'v8storagekit:([a-z8-]+)')) {
                $refName = $m.Groups[1].Value
                (Join-Path $script:SkillsDir $refName) | Should -Exist -Because "у $($s.Name) посилання на v8storagekit:$refName, а теки skills/$refName немає"
            }
        }
    }

    It 'кожен скіл життєвого циклу має розділ «Межі» з читанням сховища/бази і гейтом на -Apply чи явне прохання' {
        # B: межі стояли лише прозою — вирізати весь розділ і прогін лишався б зеленим.
        # Формулювання гейта різняться за скілом (перевірено дослівно проти текстів брифів):
        # «-Apply — лише на прохання» (sync/dump/onboarding), «лише за явним проханням» (finish),
        # «Без -Apply git не змінюється» (verify), «лише через sync» (reconcile — реплей
        # делегований sync, чий -Apply вже гейтований), «лише з -Apply» (provision, для -Force).
        $lifecycle = @('onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify')
        $gate = '(?:лише на\s+(?:явне\s+)?прохання|лише за\s+(?:явним\s+)?проханням|лише\s+(?:з|через)\s*`?-?(?:Apply|sync)`?|Без\s*`?-Apply`?[^.\r\n]*не змінюється)'
        foreach ($name in $lifecycle) {
            $t = Skill $name
            $t | Should -Not -BeNullOrEmpty -Because "скіл $name ще не написано"
            $section = $null
            if ($t -match '(?ms)^#{1,3}\s*(?:\d+\.\s*)?Межі\s*\r?\n(.*?)(?:\r?\n#{1,3}\s|\z)') {
                $section = $Matches[1].Trim()
            }
            $section | Should -Not -BeNullOrEmpty -Because "у $name немає розділу «Межі», або він порожній"
            if ($name -eq 'provision') {
                # provision — окремий випадок: працює лише з базою АГЕНТА (пише в неї), сховища не читає
                $section | Should -Match 'база агента' -Because "у provision межі мають чесно називати, що йдеться лише про базу агента, не про сховище"
            } else {
                $section | Should -Match 'тільки читання' -Because "у $name розділ «Межі» не каже про читання сховища чи бази людини"
            }
            $section | Should -Match $gate -Because "у $name розділ «Межі» не каже, що зміни — лише на явне прохання"
        }
    }

    It 'у skills/ немає тек поза 1.0-переліком і трьома старими скілами' {
        # C: BeforeAll фільтрує за $Allowed — стороння тека з порушеннями давала нуль фейлів.
        $legacyStillPresent = @('storage-pipeline', 'product-onboarding', 'repo-migration')
        # Три старі поки що мусять проходити — Task 6 їх вилучає, і разом з ними прибирається цей виняток.
        $known = $script:Allowed + $legacyStillPresent
        $actualDirs = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory).Name
        foreach ($d in $actualDirs) {
            $known | Should -Contain $d -Because "тека skills/$d — поза 1.0-переліком ($($script:Allowed -join ', ')) і поза трьома старими скілами, які Task 6 вилучає"
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

    Context 'sync' {
        It 'session-check → прев''ю → -Apply лише на прохання; -MaxVersions; зупинки sync' {
            $t = Skill 'sync'
            $t | Should -Match 'session-check'
            $t | Should -Match 'kit\.ps1" sync -RepoRoot \.'
            $t | Should -Match '-MaxVersions'
            $t | Should -Match 'Невідомі автори'
            $t | Should -Match '-MergeMain'
            $t | Should -Match 'піднімає платформу|запускає платформу'
        }
    }
    Context 'dump' {
        It 'попереджає про Конфігуратор і тривалість; dump лише для dump/vendor' {
            $t = Skill 'dump'
            $t | Should -Match '20.40 хвилин'
            $t | Should -Match 'Конфігуратор'
            $t | Should -Match 'truth: dump|truth: vendor'
            $t | Should -Match 'infobases:'
        }
    }
    Context 'verify' {
        It 'чотири вердикти, лише CR → text-policy, звірочний коміт лише з -Apply' {
            $t = Skill 'verify'
            foreach ($v in 'equal', 'ref-ahead', 'storage-ahead', 'mixed') { $t | Should -Match $v }
            $t | Should -Match 'text-policy'
            $t | Should -Match '-Apply'
            $t | Should -Match 'merge-base'
        }
    }
    Context 'provision' {
        It 'питає тип бази трьома варіантами й записує вибір у накладку; серверна — поза межами' {
            $t = Skill 'provision'
            $t | Should -Match '\*\*порожня\*\*'
            $t | Should -Match '\*\*з `?\.dt`?\*\*|\*\*з \.dt\*\*'
            $t | Should -Match '\*\*серверна\*\*'
            $t | Should -Match '-Remember'
            $t | Should -Match 'operation=build'
            $t | Should -Match 'v8project\.local\.yaml'
        }
    }
    Context 'reconcile' {
        It 'sync → operation=build → canon → merge storage/* у гілку задачі → семантичний diff' {
            $t = Skill 'reconcile'
            $t | Should -Match 'kit\.ps1" sync'
            $t | Should -Match 'operation=build'
            $t | Should -Match 'kit\.ps1" canon'
            $t | Should -Match 'git merge --no-ff storage/'
            $t | Should -Match 'git diff'
            # Позитивно, а не Should -Not -Match 'rebase': сам скіл ЗАБОРОНЯЄ rebase словами
            # «не rebase, не re-derive — merge», тож негативна перевірка на слово падала б на
            # власному тексті скіла (знахідка префлайту B5). Guard має тримати властивість, а не
            # відсутність підрядка.
            $t | Should -Match 'не rebase'
            $t | Should -Not -Match 'git rebase'   # наказу rebase немає — лише заборона словами
        }
    }
    Context 'finish' {
        It 'sync → canon → merge → verify → тести Unica → артефакти → PR; push і PR лише з дозволу' {
            $t = Skill 'finish'
            foreach ($m in 'kit\.ps1" sync', 'kit\.ps1" canon', 'kit\.ps1" verify', 'kit\.ps1" build', 'operation=test', 'operation=syntax', 'operation=make', 'gh pr create', 'build/artifacts') { $t | Should -Match $m }
            $t | Should -Match 'лише за явним проханням|лише на явне прохання'
            # R3: гейт «повідомити користувача» перед PR при суттєвих змінах зі сховища
            $t | Should -Match 'суттєв'
            $t | Should -Match 'ORIG_HEAD'
            $t | Should -Match '--name-only'      # перетин файлів F і нових версій — критерій (а)
        }
    }
}