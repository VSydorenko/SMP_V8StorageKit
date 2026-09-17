#Requires -Version 7
Set-StrictMode -Version Latest

# Lib-модулі вже імпортував kit.ps1 (module-order.txt); тут — лише оркестрація.
# Спільний платформний шар «версія сховища → дамп» (New-KitStorageInfobase, Enter/Exit-KitStorageBind,
# Invoke-KitStorageCheckout, Get-KitRepositoryArguments) — StoragePlatform.psm1 (B3 Task 1); ним же
# користується verify.

function Invoke-KitMainMerge {
    <#
    .SYNOPSIS
        Перше злиття дзеркала в головну гілку (§3.4). Невдача злиття не скасовує реплею:
        дзеркало вже оновлено, і людина може повторити злиття командою з підказки.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Source)
    $main = $Context.MainBranch
    if (-not (Test-KitBranchExists -RepoRoot $Context.RepoRoot -Branch $main)) {
        Write-Host "  Головної гілки '$main' ще немає — злиття пропущено. Створіть перший коміт і повторіть: kit sync -Source $($Source.Key) -Apply -MergeMain" -ForegroundColor Yellow
        return $false
    }
    try {
        $r = Merge-KitBranchInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $main `
            -Message "sync: злиття $($Source.Branch) у $main" -AllowUnrelated
        if ($r.Outcome -eq 'merged') { Write-Host "  Злито в $main ($($r.Via)): $($r.Sha.Substring(0, 7))" -ForegroundColor Green }
        else { Write-Host "  $main уже містить $($Source.Branch)." -ForegroundColor DarkGray }
        return $true
    } catch {
        Write-Host "  Злиття в $main не виконано: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Дзеркало оновлено. Повторити злиття: kit sync -Source $($Source.Key) -Apply -MergeMain" -ForegroundColor Yellow
        return $false
    }
}

function Invoke-KitSync {
    <#
    .SYNOPSIS
        Реплей нових версій кожного джерела truth: storage у гілку storage/<ключ> (спека §3, §5).
    .DESCRIPTION
        Пише відбиток сховища (build/session-check/<ключ>.json, StorageImprint.psm1) одразу після
        читання звіту — і в прев'ю (без -Apply), і з -Apply, обидва: прев'ю нічого не змінює в
        git, у сховищі чи в дев-базі (це і є контракт "-Apply — лише коли попросили"), а
        build/session-check/ — не один із трьох, це робоча тека МАШИНИ, гітігнорована цілком
        (templates/gitignore, рядок build/) — те саме прев'ю вже кладе туди тимчасову ІБ і дампи.
        Відбиток — знання, здобуте читанням звіту, яке щойно відбулося; викидати його, щоб
        дотриматись букви правила "прев'ю нічого не змінює", означало б платити повним прогоном
        платформи за кожну наступну відповідь session-check про це саме запаковане сховище —
        рівно той вічний сигнал "не визначається", заради усунення якого відбиток і існує (спека
        9f6ad5e §5, 0379351 §3.2).

        -FromVersion N / -FromLatest (Task 2, §9.4) — з якої версії почати ПЕРШИЙ реплей порожньої
        гілки; друга, незалежна вісь від -MaxVersions (яка каже "скільки", не "звідки"). Без них
        перший реплей великого сховища (сотні версій, 20–40 хв кожна на повній конфігурації)
        фізично неможливий — довести дзеркало до поточного стану можна лише -FromLatest, без
        зайвого прогону платформи, який знадобився б, щоб спершу побачити номер версії окремим
        прев'ю. Обидва застосовні лише поки трейлер Storage-Version на вершині storage/<ключ> ще
        не існує (гілки немає або вершина без трейлера, п. Get-KitStorageBranchLastVersion) —
        на непорожній гілці sync зупиняється з поясненням, а не тихо ігнорує ці параметри;
        дозаливку далі веде звичайний sync (за потреби — -MaxVersions). Параметри взаємовиключні.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [int]$MaxVersions = 0,
        [switch]$MergeMain,
        [Nullable[int]]$FromVersion = $null,
        [switch]$FromLatest
    )

    # Валідація параметрів — ДО будь-якого звернення до джерел чи платформи (навіть до
    # Select-KitSources): на клієнтській базі повна конфігурація реплеїться 20–40 хв/версію,
    # тож типову описку в номері версії чи в самих прапорцях має ловити перевірка, що не коштує
    # нічого, а не перший-ліпший з можливо кількох джерел truth: storage, ПІСЛЯ підняття
    # тимчасової ІБ для нього.
    if ($null -ne $FromVersion -and $FromLatest) {
        throw 'Параметри -FromVersion і -FromLatest взаємовиключні — вкажіть лише один спосіб визначити початкову версію першого реплею.'
    }
    if ($null -ne $FromVersion -and $FromVersion -le 0) {
        throw "Значення -FromVersion має бути додатним номером версії сховища, отримано: $FromVersion."
    }

    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — синхронізувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Synced = @() }
    }
    foreach ($src in $sources) {
        if ($src.Type -notin @('CONFIGURATION', 'EXTENSION')) {
            throw "Джерело '$($src.Key)' має тип $($src.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION."
        }
    }

    $authors  = Read-AuthorMap -Path (Join-Path $root 'AUTHORS')
    $results  = [System.Collections.Generic.List[object]]::new()
    $mergeFailed = $false

    foreach ($src in $sources) {
        Write-Host ''
        Write-Host "Джерело:    $($src.Workspace)/$($src.Key) ($($src.Type))"
        Write-Host "Сховище:    $($src.StoragePath) (користувач $($src.StorageUser))"
        Write-Host "Гілка:      $($src.Branch)"
        if (-not (Test-Path -LiteralPath $src.StoragePath)) {
            throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)."
        }

        # Дамп — у базі агента воркспейсу, а не в тимчасовій ІБ зі стабом (спека 2026-09-17 §2):
        # серіалізація розширення залежить від присутності конфігурації-власника, і дамп зі
        # стаба давав GUID там, де canon дає імена. Get-KitSourceInfobase несе запобіжник
        # «це не дев-база людини» — критичний саме тут, бо UpdateCfg замінює конфігурацію в базі.
        # Перевірка дешева (читання YAML) і стоїть поруч із перевіркою каталогу сховища вище,
        # ДО створення робочої теки нижче.
        $agent = Get-KitSourceInfobase -Context $Context -Source $src

        # Навмисно без try/catch: вершина storage/* без числового Storage-Version — це порушення інваріанту
        # (§3.2), і виняток із текстом «гілку писав не sync. Розбір: kit check» І Є штатною зупинкою sync.
        # Загортати його в інше повідомлення чи вгадувати стан — не можна.
        $last = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $src.Branch
        # M-4 (фінальне рев'ю B6): рядок мусить враховувати ОБРАНУ глибину першого реплею. Безумовне
        # «реплей усіх версій зі звіту» друкувалось рівно тоді, коли -FromVersion/-FromLatest і
        # застосовні (гілки ще немає): оператор SMP_SMB_ukr_DEV (1 041 версія) запускає -FromLatest
        # саме щоб уникнути повного реплею — і першим рядком читає опис тієї катастрофи, заради
        # уникнення якої прапорець і додали.
        $mirrorNote = 'гілки ще немає — реплей усіх версій зі звіту'
        if ($null -ne $last) {
            $mirrorNote = "версія $last"
        } elseif ($FromLatest) {
            $mirrorNote = 'гілки ще немає — перший реплей лише з ОСТАННЬОЇ версії звіту (-FromLatest)'
        } elseif ($null -ne $FromVersion) {
            $mirrorNote = "гілки ще немає — перший реплей зі звіту, починаючи з версії $FromVersion (-FromVersion)"
        }
        Write-Host "Дзеркало:   $mirrorNote"

        # -FromVersion/-FromLatest визначають ЗВІДКИ починати ПЕРШИЙ реплей — на гілці, що вже
        # має версії, "звідки почати" вже вирішено самим дзеркалом (трейлер Storage-Version
        # вершини), і мовчки їх ігнорувати означало б приховати від людини, що параметр не
        # подіяв. Перевірка тут, ДО створення тимчасової ІБ цього джерела (рядок нижче) — ще один
        # шар "не платити платформою за очевидну помилку виклику", той самий принцип, що
        # валідація на самому вході функції вище.
        if ($null -ne $last -and ($null -ne $FromVersion -or $FromLatest)) {
            throw ("Гілка $($src.Branch) не порожня — вершина вже має трейлер Storage-Version: $last. " +
                   '-FromVersion і -FromLatest визначають, ЗВІДКИ почати ПЕРШИЙ реплей порожньої гілки; ' +
                   'на непорожній гілці дозаливку веде звичайний sync (за потреби — -MaxVersions).')
        }

        # Робоча тека джерела — з нуля на кожен запуск. Worktree від перерваного прогону спершу знімаємо з реєстрації.
        $workDir = Join-Path $root 'build/sync' $src.Key
        Assert-SafeWorkPath -Path $workDir -MustBeUnder (Join-Path $root 'build/sync') -Description "робоча тека джерела $($src.Key)"
        $staleWt = Join-Path $workDir 'wt'
        if (Test-Path -LiteralPath $staleWt) {
            # Ґейт на Test-Path (як у New-KitStorageWorktree): є що знімати лише після
            # перерваного прогону. На звичайному запуску 'wt' під ще не створеним $workDir не
            # існує, і git worktree remove на незареєстрованій теці штатно завершується кодом
            # 128 ("not a working tree") — перевірка коду тут БЕЗ цього ґейту попереджала б на
            # кожному нормальному прогоні, а не на дійсній аномалії. Неуспішне зняття реєстрації
            # не зупиняє sync (Remove-Item нижче однаково прибере теку з диска), але лишає
            # осиротілий запис у git worktree list — про це варто попередити.
            git -C $root worktree remove --force $staleWt 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  УВАГА: не вдалося зняти реєстрацію worktree '$staleWt' від перерваного прогону (код ${LASTEXITCODE}) — теку прибере наступний крок, але запис у git worktree list може лишитись осиротілим." -ForegroundColor Yellow
            }
        }
        git -C $root worktree prune 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  УВАГА: git worktree prune завершився кодом ${LASTEXITCODE} — застарілі реєстрації worktree могли не прибратись." -ForegroundColor Yellow
        }
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $ibSwitch = $agent.IbSwitch
        Write-Host "База агента: $ibSwitch (воркспейс $($agent.Workspace))"
        Write-Host 'Читаю історію сховища...'

        $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath `
            -ExtensionName $(if ($src.Type -eq 'EXTENSION') { $src.Key } else { '' }) `
            -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -User $agent.User
        $maxVersion = if ($all.Count -gt 0) { ($all | Measure-Object -Property Version -Maximum).Maximum } else { 'немає' }
        Write-Host "У сховищі версій: $($all.Count), максимальна: $maxVersion"

        # Відбиток — ОДРАЗУ після звіту, ДО розгалуження "нових версій немає" нижче (Task 8,
        # task-8-brief.md, Важливе №1): саме в гілці "нема нових версій" уся конструкція й потрібна
        # — для неактивного запакованого сховища pending завжди порожній, і якби запис стояв
        # ПІСЛЯ цього continue, відбиток ніколи не оновився б рівно в тому випадку, заради якого
        # його зробили. $all.Count -eq 0 (сховище зовсім без версій) — писати нема чого, $maxVersion
        # тут рядок 'немає', не число. try/catch: збій запису кешу — робочої теки МАШИНИ, не стану
        # git/сховища/бази — не має валити синхронізацію, лише попередження.
        if ($all.Count -gt 0) {
            try {
                Write-KitStorageImprint -RepoRoot $root -Key $src.Key -StoragePath $src.StoragePath -Version ([int]$maxVersion) | Out-Null
            } catch {
                Write-Host "  УВАГА: не вдалося записати відбиток сховища (build/session-check/$($src.Key).json): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $pending = Get-KitPendingVersions -AllVersions $all -LastVersion $last -MaxVersions $MaxVersions `
            -FromVersion $FromVersion -FromLatest:$FromLatest
        $gap = Get-KitVersionGapNote -Pending $pending -LastVersion $last
        if ($gap) { Write-Host "  $gap" -ForegroundColor DarkGray }

        if ($pending.Count -eq 0) {
            Write-Host 'Нових версій немає — дзеркало синхронне зі сховищем.'
            $merged = $false
            if ($MergeMain -and $Apply -and $null -ne $last) { $merged = Invoke-KitMainMerge -Context $Context -Source $src; if (-not $merged) { $mergeFailed = $true } }
            $results.Add([pscustomobject]@{ Key = $src.Key; Versions = @(); Branch = $src.Branch; MergedIntoMain = $merged })
            continue
        }

        $unknown = Get-UnknownAuthors -Map $authors -StorageUsers ($pending.User)
        if ($unknown) {
            Write-Host ''
            Write-Host 'Невідомі автори — додайте їх у AUTHORS перед прогоном:' -ForegroundColor Yellow
            $unknown | ForEach-Object { Write-Host "  $_=Ім'я <пошта>" }
            throw 'Синхронізацію зупинено через невідомих авторів.'
        }

        Write-Host ''
        Write-Host "До перенесення версій: $($pending.Count)"
        foreach ($v in $pending) {
            $author = Resolve-Author -Map $authors -StorageUser $v.User
            $first  = ($v.Comment -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $first) { $first = "Версія сховища $($v.Version)" }
            Write-Host ("  v{0,-4} {1:yyyy-MM-dd HH:mm}  {2,-22} {3}" -f $v.Version, $v.Timestamp, $author.Name, $first)
        }

        if (-not $Apply) {
            Write-Host ''
            Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            continue
        }

        $wt    = New-KitStorageWorktree -RepoRoot $root -Branch $src.Branch -Path (Join-Path $workDir 'wt')
        $done  = [System.Collections.Generic.List[int]]::new()
        # $bound = $false ПЕРЕД try обов'язковий: під Set-StrictMode -Version Latest звернення
        # до неприсвоєної змінної у finally само кине й витіснить первинний виняток (Step 4а
        # цього ж Task'у закривав рівно цю ваду для Remove-KitStorageWorktree). Enter-KitStorageBind
        # — ВСЕРЕДИНІ try (рев'ю Task 1, Important #1): якщо прив'язка впаде, worktree все одно
        # прибереться у finally, а не лишиться сиротою на диску й у git worktree list.
        $bound = $false
        try {
            $bound = Enter-KitStorageBind -IbSwitch $ibSwitch -Source $src -User $agent.User
            foreach ($v in $pending) {
                $author = Resolve-Author -Map $authors -StorageUser $v.User
                Write-Host "→ версія $($v.Version) ($($author.Name), $($v.Date))"

                $null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                    -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -User $agent.User

                $message = New-KitStorageCommitMessage -Version $v -SourceKey $src.Key -SourceType $src.Type
                $commit  = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath $src.RepoPath -Message $message `
                    -AuthorName $author.Name -AuthorEmail $author.Email -Timestamp $v.Timestamp
                if ($commit.Empty) { Write-Host '  (без змін у джерелах — коміт лише фіксує запис версії сховища)' -ForegroundColor DarkGray }
                $done.Add($v.Version)
            }
        } finally {
            Exit-KitStorageBind -IbSwitch $ibSwitch -Source $src -Bound $bound -User $agent.User
            Remove-KitStorageWorktree -RepoRoot $root -Path $wt.Path
        }
        Write-Host ("Перенесено версій: {0} → {1}" -f $done.Count, $src.Branch) -ForegroundColor Green

        # Контракт спеки §4: перемотування історії ЗАМІНЮЄ конфігурацію в базі агента, і база
        # лишається у стані останньої прочитаної версії. Це не побічний ефект, а оголошена
        # поведінка — мовчати про неї означало б, що наступний operation=syntax чи test побіжить
        # не на тому стані, який агент вважає своїм.
        Write-Host ("База агента воркспейсу '{0}' тепер містить версію {1} зі сховища. Перед роботою: operation=build Уніки." -f `
            $agent.Workspace, $done[-1]) -ForegroundColor Yellow

        $merged = $false
        if ($wt.Created -or $MergeMain) {
            $merged = Invoke-KitMainMerge -Context $Context -Source $src
            if (-not $merged) { $mergeFailed = $true }
        }
        $results.Add([pscustomobject]@{ Key = $src.Key; Versions = $done.ToArray(); Branch = $src.Branch; MergedIntoMain = $merged })
    }

    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    [pscustomobject]@{ ExitCode = $(if ($mergeFailed) { 2 } else { 0 }); Synced = $results.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSync
