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

        # Усі .md скіла, не лише SKILL.md: підтеку references/ агент читає тим самим Read, і
        # речення ПРО токен шкодить там не менше — воно так само проситься в копіювання. До
        # 2026-09-18 набір вище бачив рівно вісім SKILL.md, а skills/onboarding/references/
        # лежало поза машинною перевіркою з трьома вживаннями токена (усі виявились
        # легітимними — але це було везіння, не гарантія).
        $script:SkillDocs = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory |
            Where-Object { $_.Name -in $script:Allowed } | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter '*.md' -File -Recurse | ForEach-Object {
                    [pscustomobject]@{
                        Rel  = [IO.Path]::GetRelativePath($script:SkillsDir, $_.FullName)
                        Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8)
                    }
                }
            })
    }

    It 'frontmatter: name = ім''я теки, description з тригерами' {
        foreach ($s in $script:Skills) {
            $s.Text | Should -Match "(?m)^name:\s*$([regex]::Escape($s.Name))\s*$"
            $s.Text | Should -Match '(?m)^description:.*Тригер'
        }
    }
    It '${CLAUDE_PLUGIN_ROOT} — лише всередині шляху (за токеном одразу /), у ВСІХ .md скіла' {
        # Guard на ВЛАСТИВІСТЬ («за токеном одразу /»), не на перелік тек. Ручна перевірка в
        # CLAUDE.md і README.md довго стояла у формі grep -v '/tools/|/templates/|/docs/' — вона
        # перелічувала МІСЦЯ, куди веде шлях, і мала обидві вади: кричала на легітимний
        # ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json (четверта тека, якої в переліку не
        # було) і мовчки пропускала справжню пастку, якщо в тому ж рядку траплялось слово
        # /tools/. Тут перевіряється саме форма вживання, тож нова тека плагіна нічого не ламає.
        $script:SkillDocs.Count | Should -BeGreaterThan 8 -Because 'набір мусить брати й references/, не лише вісім SKILL.md'
        foreach ($d in $script:SkillDocs) {
            [regex]::Matches($d.Text, '\$\{CLAUDE_PLUGIN_ROOT\}(?!/)').Count | Should -Be 0 -Because "у $($d.Rel) токен вжито не як частину шляху"
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
        #
        # Перша редакція цього тесту тримала ФОРМУЛЮВАННЯ, а не властивість: $gate був
        # альтернацією, підігнаною під те, що кожен скіл випадково казав («лише через sync»,
        # «Без -Apply git не змінюється»). Рев'ю довело мутаціями на копії дерева, що так
        # видаляються справжні межі при зеленому прогоні: у verify — заголовок «— лише на явне
        # прохання», у reconcile — весь абзац про згоду, у provision — ВСІ ТРИ твердження «kit не
        # пише в базу людини». Наслідок і причина — не те саме: «Без -Apply git не змінюється» це
        # факт про інструмент, а не зобов'язання агента, і воно лишається правдивим у скілі, який
        # тихо став запускати -Apply самовільно.
        #
        # Тому тепер: зобов'язання шукається дослівно й ПО ВСЬОМУ тексту скіла (сховати його в
        # інший розділ — можна, не сказати взагалі — ні), а розділ «Межі» додатково мусить бути
        # непорожнім і називати, чого саме kit не робить.
        $lifecycle = @('using-v8storagekit', 'onboarding', 'sync', 'dump', 'reconcile', 'finish', 'provision', 'verify')
        $gate = '(?:лише на\s+явне\s+прохання|лише за\s+явним\s+проханням)'
        foreach ($name in $lifecycle) {
            $t = Skill $name
            $t | Should -Not -BeNullOrEmpty -Because "скіл $name ще не написано"
            $section = $null
            if ($t -match '(?ms)^#{1,3}\s*(?:\d+\.\s*)?Межі\s*\r?\n(.*?)(?:\r?\n#{1,3}\s|\z)') {
                $section = $Matches[1].Trim()
            }
            $section | Should -Not -BeNullOrEmpty -Because "у $name немає розділу «Межі», або він порожній"
            if ($name -eq 'provision') {
                # provision — єдиний, хто ПИШЕ в базу (агента) і сховищ не читає, тож «тільки
                # читання» до нього не застосовне. Замість цього — позитивна вимога назвати межу,
                # яку він реально тримає: у базу людини не пише. Без неї розділ «Межі», що казав
                # би «пише і в базу агента, і в базу людини», проходив би тест (мутація M6 рев'ю).
                $section | Should -Match 'база агента' -Because "у provision межі мають чесно називати, що йдеться лише про базу агента, не про сховище"
                $t | Should -Match 'не (?:пише|цілиться) в базу людини' -Because 'provision мусить прямо сказати, що в базу людини kit не пише'
            } else {
                $section | Should -Match 'тільки читання' -Because "у $name розділ «Межі» не каже про читання сховища чи бази людини"
            }
            # По всьому тексту, не лише в «Межах»: зобов'язання може стояти й у кроці, який його
            # застосовує, але зникнути з файлу цілком воно не має права.
            $t | Should -Match $gate -Because "у $name ніде не сказано, що -Apply чи push — лише на явне прохання"
        }
    }

    It 'у skills/ немає тек поза 1.0-переліком (Task 6: три старі скіли вилучено — виняток знято)' {
        # C: BeforeAll фільтрує за $Allowed — стороння тека з порушеннями давала нуль фейлів.
        # До Task 6 тут стояв виняток $legacyStillPresent = storage-pipeline, product-onboarding,
        # repo-migration: три старі скіли ще лежали в дереві, поки цей блок їх не замінив. Task 6
        # видалив ці теки (git rm) — виняток знято разом з ними, і тепер цей It ловить і вилучення
        # (сама перевірка того, що тек більше немає), і випадкове ВОСКРЕСІННЯ будь-якої з них.
        $actualDirs = @(Get-ChildItem -LiteralPath $script:SkillsDir -Directory).Name
        foreach ($old in 'storage-pipeline', 'product-onboarding', 'repo-migration') {
            $actualDirs | Should -Not -Contain $old -Because "скіл $old вилучено в Task 6 (B5) — теку не мало лишитись і не мало з'явитись знову"
        }
        foreach ($d in $actualDirs) {
            $script:Allowed | Should -Contain $d -Because "тека skills/$d — поза 1.0-переліком ($($script:Allowed -join ', '))"
        }
    }

    Context 'onboarding' {
        It 'питає truth з чотирма варіантами й наслідками для git' {
            $t = Skill 'onboarding'
            foreach ($v in 'storage', 'dump', 'vendor', 'git') { $t | Should -Match "\*\*$v\*\*" }
            $t | Should -Match 'гітігноровано'
            $t | Should -Match 'мовчазного дефолту немає|Мовчазних дефолтів'
        }
        It 'шаблон v8project.yaml 0.13: providers designer, без builder/execution_timeout і без бази; база — infobases.origin у блоці local' {
            $t = Skill 'onboarding'
            $blocks = [regex]::Matches($t, '(?ms)^```yaml\s*\r?\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value }
            $committed = @($blocks | Where-Object { $_ -match '(?m)^format:\s*DESIGNER' })
            $committed | Should -HaveCount 1
            $c = $committed[0]
            $c | Should -Match '(?m)^providers:\s*$'
            foreach ($op in 'push', 'pull', 'download') { $c | Should -Match "(?m)^\s+${op}:\s*designer" }
            $c | Should -Not -Match '(?m)^\s*(builder|execution_timeout|infobase|infobases):'
            $c | Should -Match '(?m)^\s*-\s*name:\s*<ІмʼяРозширення>'
            $local = @($blocks | Where-Object { $_ -match '(?m)^infobases:\s*$' -and $_ -match '(?m)^\s+origin:\s*$' })
            $local | Should -Not -BeNullOrEmpty
            $t.IndexOf('v8project.local.yaml') | Should -BeLessThan $t.IndexOf($local[0]) -Because 'блок бази стоїть після назви файлу, у який його пишуть'
        }
        It 'ставить хуки командою install-hooks, дописує -text і .gitignore під фактичні шляхи, перший коміт до -Apply' {
            $t = Skill 'onboarding'
            $t | Should -Match 'install-hooks'
            $t | Should -Match '<ws>/<path>/\*\* -text'
            $t | Should -Match 'перший коміт|Перший коміт'
            $t | Should -Not -Match 'v8storagekit:migrate'   # команди й скіла migrate немає (спека 2f2da62)
        }
        It 'Task 1 (B8): закомічені артефакти збірки — показ переліком, git rm --cached лише з підтвердженням людини' {
            $t = Skill 'onboarding'
            $t | Should -Match 'build-artifacts'
            $t | Should -Match 'git rm --cached'
            $t | Should -Match 'Лише з підтвердженням'
            $t | Should -Match 'без підтвердження не змінюється нічого'
        }

        It 'onboarding посилається на upgrades.md, і той описує перехід на ПОТОЧНУ версію плагіна' {
            $skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/onboarding/SKILL.md') -Raw -Encoding UTF8
            $skill | Should -BeLike '*references/upgrades.md*'
            $up = Join-Path $PSScriptRoot '../../skills/onboarding/references/upgrades.md'
            $up | Should -Exist
            # Версія читається з plugin.json, а не вшита: вшите число старіє на першому ж бампі
            # й тест починає вимагати переходу, якого вже немає (спіймано бампом 1.0.1 → 1.1.0).
            $pluginVersion = [string]((Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.claude-plugin/plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
            $pluginVersion | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $up -Raw -Encoding UTF8) | Should -BeLike "*$pluginVersion*" `
                -Because "upgrades.md мусить описувати перехід на версію, яку плагін щойно оголосив ($pluginVersion)"
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
        It 'три типи бази, -ServerBase New|Existing, CrSQLDB, infobases.origin, -Remember, крок з виводу' {
            $t = Skill 'provision'
            $t | Should -Match '\*\*порожня\*\*'
            $t | Should -Match '\*\*з `?\.dt`?\*\*|\*\*з \.dt\*\*'
            $t | Should -Match '\*\*серверна\*\*'
            $t | Should -Match '-ServerBase New'
            $t | Should -Match '-ServerBase Existing'
            $t | Should -Match 'CrSQLDB'
            $t | Should -Match 'infobases\.origin'
            $t | Should -Match '-Remember'
            $t | Should -Match 'надрукован'
            $t | Should -Match 'v8project\.local\.yaml'
        }
    }
    Context 'provision — цитати зупинок' {
        It 'кожна фраза зупинки, процитована в розділі «Штатні зупинки», існує дослівно в tools/commands чи tools/lib' {
            $t = Skill 'provision'
            $m = [regex]::Match($t, '(?ms)^## 4\. Штатні зупинки\s*$(.*?)(?=^## )')
            $m.Success | Should -BeTrue -Because 'розділ «## 4. Штатні зупинки» має бути у скілі provision'
            # Форма цитати в розділі: пункт списку починається з `…` (перший спан у бектиках), «…» — місце змінної частини.
            $quotes = foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
                $q = [regex]::Match($line, '^- `([^`]+)`')
                if ($q.Success) { $q.Groups[1].Value }
            }
            @($quotes).Count | Should -BeGreaterThan 10 -Because 'розділ має містити цитати зупинок у формі «- `текст`»'
            $toolsDir = (Resolve-Path "$PSScriptRoot/..").Path
            $code = (Get-ChildItem -LiteralPath $toolsDir -Recurse -Filter '*.psm1' |
                Where-Object { $_.DirectoryName -match '[\\/](commands|lib)$' } |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
            # Нормалізація коду до тексту, який побачить людина: склейка літералів через `+` у рядках, '' -> ', `$ -> $.
            $code = [regex]::Replace($code, '["'']\s*\+\s*\r?\n\s*["'']', '')
            $code = $code.Replace("''", "'").Replace('`$', '$')
            $missing = foreach ($q in $quotes) {
                foreach ($frag in ($q -split '…')) {
                    $f = $frag.Trim(' ')
                    if ($f.Length -lt 6) { continue }
                    if (-not $code.Contains($f)) { "«$f» (з цитати: $q)" }
                }
            }
            @($missing) | Should -BeNullOrEmpty -Because ("скіл цитує тексти зупинок, яких немає в коді (виправляти скіл, не код):`n" + (@($missing) -join "`n"))
        }
    }
    Context 'reconcile' {
        It 'sync → крок, надрукований sync (push force) → pull force → adopt; #25' {
            $t = Skill 'reconcile'
            $t | Should -Match 'kit\.ps1" sync'
            $t | Should -Match 'надрукован'
            $t | Should -Match '"force":true'
            $t | Should -Match 'infobase_state_unverified'
            # Запобіжник порядку: push force стоїть РАНІШЕ за pull force, а pull — раніше за adopt. pull на базі, не вирівняній push force,
            # вивантажив би версію сховища замість гілки задачі й замінив би закомічену роботу.
            $posPush = $t.IndexOf('"op":"push"')
            $posPull = $t.IndexOf('"op":"pull"')
            $posAdopt = $t.IndexOf('kit.ps1" adopt')
            $posPush | Should -BeGreaterThan -1
            $posPull | Should -BeGreaterThan $posPush -Because 'pull force — після push force'
            $posAdopt | Should -BeGreaterThan $posPull -Because 'adopt — після pull force'
            $t | Should -Match '"force":true'
            $t | Should -Match 'cancelled'
            $t | Should -Match '"extension":'
            $t | Should -Not -Match 'kit\.ps1" canon'
            $t | Should -Match 'kit\.ps1" adopt'
            $t | Should -Match 'зникне з гілки'
            # Позитивно, а не Should -Not -Match 'rebase': сам скіл ЗАБОРОНЯЄ rebase словами
            # «не rebase, не re-derive», тож негативна перевірка на слово падала б на
            # власному тексті скіла (знахідка префлайту B5). Guard має тримати властивість, а не
            # відсутність підрядка.
            $t | Should -Match 'не rebase'
            $t | Should -Not -Match 'git rebase'   # наказу rebase немає — лише заборона словами
            $t | Should -Not -Match 'git merge --no-ff storage/'   # C2 Task 4: adopt замінює merge
        }
    }
    Context 'finish' {
        It 'sync → push force → pull force → adopt → verify → крок verify → unica.check → артефакти → PR; push і PR лише з дозволу' {
            $t = Skill 'finish'
            foreach ($m in 'kit\.ps1" sync', '"op":"push"', '"op":"pull"', '"force":true', 'cancelled', 'kit\.ps1" adopt', 'kit\.ps1" verify',
                           'unica\.check', '"op":"make"', 'gh pr create', 'build/artifacts') { $t | Should -Match $m }
            $t | Should -Not -Match 'kit\.ps1" build'   # Task 5: збірку робить лише make Уніки
            $t | Should -Not -Match 'kit\.ps1" canon'
            $t | Should -Not -Match 'testRunner'
            $t | Should -Match 'лише за явним проханням|лише на явне прохання'
            # R3: гейт «повідомити користувача» перед PR при суттєвих змінах зі сховища
            $t | Should -Match 'суттєв'
            $t | Should -Match 'ЗНИКНЕ з гілки'   # C2 Task 4: критерій (б) — прев'ю adopt, не конфлікт злиття
            $t | Should -Match '--name-only'      # перетин файлів F і нових версій — критерій (а)
            $t | Should -Not -Match 'ORIG_HEAD'   # ORIG_HEAD був від git merge; adopt його не лишає
        }
    }
    It 'finish: push force стоїть раніше за pull force, а той — раніше за adopt (порядок обох кроків канонізації)' {
        $t = Skill 'finish'
        $posPush = $t.IndexOf('"op":"push"')
        $posPull = $t.IndexOf('"op":"pull"')
        $posAdopt = $t.IndexOf('kit.ps1" adopt')
        $posPush | Should -BeGreaterThan -1
        $posPull | Should -BeGreaterThan $posPush
        $posAdopt | Should -BeGreaterThan $posPull
    }
    It 'команди kit canon більше немає: жодного скіла (крім довідки upgrades.md про минулі версії) і шаблону, що її кличе чи згадує' {
        # Команду замінили pull force Уніки й kit supply-marker (спека 2026-11-19 §3.2). Скіл, що кличе
        # неіснуючу команду, — дефект, який користувач побачить лише на «Unknown command» у живій сесії.
        $templatesDir = (Resolve-Path "$PSScriptRoot/../../templates").Path
        $files = @($script:SkillDocs | Where-Object { $_.Rel -notlike '*upgrades.md' } |
            ForEach-Object { [pscustomobject]@{ Rel = "skills/$($_.Rel)"; Text = $_.Text } }) +
            @(Get-ChildItem -LiteralPath $templatesDir -Recurse -File | ForEach-Object {
                [pscustomobject]@{ Rel = "templates/" + [IO.Path]::GetRelativePath($templatesDir, $_.FullName); Text = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) } })
        $files.Count | Should -BeGreaterThan 8 -Because 'перелік файлів не порожній (контроль, що перевірка дивиться)'
        $hits = @($files | Where-Object { $_.Text -match '(?i)\bcanon\b' } | ForEach-Object Rel)
        $hits | Should -BeNullOrEmpty -Because ("згадка canon у: " + ($hits -join ', '))
    }
    It 'reconcile і finish приймають версію сховища через adopt, а не git merge' {
        foreach ($s in @('reconcile', 'finish')) {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../skills/$s/SKILL.md") -Raw -Encoding UTF8
            $text | Should -BeLike '*kit.ps1" adopt*'
            $text | Should -Not -BeLike '*git merge --no-ff storage/*'
        }
    }

    It 'finish ставить крок, надрукований verify, між verify і unica.check' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../skills/finish/SKILL.md') -Raw -Encoding UTF8
        $posVerify = $text.IndexOf('kit.ps1" verify')
        $posStep   = $text.IndexOf('надрукован', $posVerify)
        $posCheck  = $text.IndexOf('unica.check', $posVerify)
        $posVerify | Should -BeGreaterThan -1
        $posStep   | Should -BeGreaterThan $posVerify
        $posCheck  | Should -BeGreaterThan $posStep
    }

    It 'sync, verify і reconcile попереджають, що база лишається у стані сховища' {
        # verify тут нарівні із sync: verify.psm1 так само робить ConfigurationRepositoryUpdateCfg
        # і так само лишає базу у стані версії сховища, а скіл викликають і напряму, не лише з
        # finish (фінальне рев'ю C1, Important 1). Спека §4 перелічує sync/reconcile/finish —
        # перелік неповний, і це знає код, а не текст.
        foreach ($s in @('sync', 'verify', 'reconcile')) {
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../skills/$s/SKILL.md") -Raw -Encoding UTF8
            # Два твердження, не одне (історія C1, лишається): перше тримає, що скіл відсилає до кроку,
            # який надрукувала команда (раніше це був голий operation=build, і для reconcile підрядок
            # був і до C1 — з іншої причини, колишньої страховки canon, тож його одного відкіт не ловив).
            # Друге тримає саме те, що додав C1: стан бази після sync/verify названо ОГОЛОШЕНИМ
            # КОНТРАКТОМ, а не збоєм; без нього агент читав би зрушену базу як поломку.
            $text | Should -BeLike '*надрукован*'
            $text | Should -BeLike '*контракт*'
        }
    }

    It 'using-v8storagekit: маршрутизація 0.13, крок з виводу, сітка infobase_state_unverified, виняток force (П17), ЗУПИНКА, #13' {
        $t = Skill 'using-v8storagekit'
        foreach ($m in 'unica\.view', 'unica\.check', 'unica\.apply', 'executionToken', 'object\.borrow', 'unica\.task\.result',
                       '"op":"push"', '"full":true', '"op":"make"', 'non_fast_forward', 'no_memory', 'infobase_state_unverified',
                       'надрукован', '"dryRun":true', 'ЗУПИНКА', 'Для будь-якої іншої бази правило Уніки діє без винятків') {
            $t | Should -Match $m
        }
        $t | Should -Not -Match 'одинадцять'   # кількість — не в постійному тексті
    }
    It 'sync, verify, reconcile наказують перевірити ЗУПИНКА й не йти далі' {
        foreach ($s in @('sync', 'verify', 'reconcile')) {
            (Skill $s) | Should -Match 'ЗУПИНКА' -Because "$s мусить зупиняти агента на кроці blocked (умова архітектора)"
        }
    }
}
