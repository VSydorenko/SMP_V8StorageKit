#Requires -Version 7
Set-StrictMode -Version Latest

# Lib-модулі вже імпортував kit.ps1 (module-order.txt); тут — лише оркестрація.
# Спільний платформний шар «версія сховища → дамп» (Get-KitSourceInfobase, Enter/Exit-KitStorageBind,
# Invoke-KitStorageCheckout, Get-KitRepositoryArguments) — StoragePlatform.psm1 (B3 Task 1); ним же
# користується verify. Після C1 (2026-09-17) дамп іде в базі агента воркспейсу, яку резолвить
# Get-KitSourceInfobase; New-KitStorageInfobase із того ж модуля sync кличе лише як запасний шлях
# для розширення, якого ще немає в базі агента (спека 2026-09-30 §6.9).

function Sort-KitSyncSources {
    <#
    .SYNOPSIS
        Порядок sync (спека 2026-09-30 §5.4): усередині воркспейсу CONFIGURATION першим — після
        нього в базі агента остання перенесена версія основної конфігурації, і розширення
        вивантажуються на ній, а не на стані гілки задачі. Воркспейси й розширення — у порядку
        маніфесту. Явний цикл, а не Sort-Object: стабільність тут — контракт, а не деталь.
    #>
    param([AllowEmptyCollection()][object[]]$Sources)
    $wsOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Sources) { if (-not $wsOrder.Contains($s.Workspace)) { $wsOrder.Add($s.Workspace) } }
    foreach ($ws in $wsOrder) {
        $Sources | Where-Object { $_.Workspace -eq $ws -and $_.Type -eq 'CONFIGURATION' }
        $Sources | Where-Object { $_.Workspace -eq $ws -and $_.Type -ne 'CONFIGURATION' }
    }
}

function Invoke-KitMainMerge {
    <#
    .SYNOPSIS
        Перше злиття дзеркала в цільову гілку (§3.4; типово головна, інша — -MergeInto). Невдача
        злиття не скасовує реплею: дзеркало вже оновлено, і людина може повторити злиття
        командою з підказки.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$Into)
    $retry = "kit sync -Source $($Source.Key) -Apply -MergeMain"
    if ($Into -ne $Context.MainBranch) { $retry += " -MergeInto $Into" }
    if (-not (Test-KitBranchExists -RepoRoot $Context.RepoRoot -Branch $Into)) {
        Write-Host "  Гілки '$Into' ще немає — злиття пропущено. Створіть її (перший коміт) і повторіть: $retry" -ForegroundColor Yellow
        return $false
    }
    # Запобіжник #15 (спека 2026-09-30 §6.3.4): ПЕРШЕ злиття в гілку, де немає маніфесту, —
    # майже напевно не та гілка (master gitsync-репозиторію до переходу, коли маніфест і
    # перейменування лежать на гілці онбордингу). Там злиття проходить ЧИСТО — шляхи не
    # перетинаються — і кладе Designer-дерево в master ДО коміту конверсії: той самий
    # зворотний порядок, що обнуляє git blame (§9.2 спеки 2026-09-03).
    if (-not (Test-KitBranchMergedInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $Into)) {
        git -C $Context.RepoRoot cat-file -e "${Into}:v8storagekit.yaml" 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Дужки навколо конкатенації — з тієї ж причини, що й у попередженні нижче (-f сильніший за +).
            Write-Host (("  Злиття не виконано: у гілці '{0}' v8storagekit.yaml немає — це перше злиття {1}, і маніфест живе на іншій гілці. " +
                "Злийте в гілку, де лежить маніфест: kit sync -Source {2} -Apply -MergeMain -MergeInto <гілка>.") -f $Into, $Source.Branch, $Source.Key) -ForegroundColor Yellow
            Write-Host '  Дзеркало оновлено.' -ForegroundColor Yellow
            return $false
        }
    }
    try {
        $r = Merge-KitBranchInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $Into `
            -Message "sync: злиття $($Source.Branch) у $Into" -AllowUnrelated
        if ($r.Outcome -eq 'merged') { Write-Host "  Злито в $Into ($($r.Via)): $($r.Sha.Substring(0, 7))" -ForegroundColor Green }
        else { Write-Host "  $Into уже містить $($Source.Branch)." -ForegroundColor DarkGray }
        return $true
    } catch {
        Write-Host "  Злиття в $Into не виконано: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Дзеркало оновлено. Повторити злиття: $retry" -ForegroundColor Yellow
        return $false
    }
}

function Format-KitPlatformList {
    <#
    .SYNOPSIS
        Рядки «  x64: 8.3.27.1644 (основна), 8.3.25.1445» — по рядку на розрядність. «Основна» —
        за збігом шляху з MainPath (не за версією: x86 тієї самої версії основною не є).
    #>
    param([AllowEmptyCollection()][object[]]$Platforms = @(), [string]$MainPath)
    if ($Platforms.Count -eq 0) { return @('  (жодної)') }
    foreach ($arch in @($Platforms.Arch | Select-Object -Unique | Sort-Object)) {
        $items = @($Platforms | Where-Object { $_.Arch -eq $arch } | ForEach-Object {
            if ($MainPath -and $_.Path -ieq $MainPath) { "$($_.Version) (основна)" } else { [string]$_.Version }
        })
        "  ${arch}: $($items -join ', ')"
    }
}

function New-KitDumpStopMessage {
    <#
    .SYNOPSIS
        Текст зупинки спеки 1.3.1 §4.1: основна платформа не вивантажує версію. Версія платформи —
        з Data.PlatformPath (та, що справді впала); перелік платформ і команди виходу — з оточення.
    #>
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()][Nullable[int]]$LastCommitted,
        [AllowNull()][Nullable[int]]$PendingSkip = $null
    )
    $d = $ErrorRecord.Exception.Data
    $n = [int]$d['Version']
    $mainPath = [string]$d['PlatformPath']
    $mainVer = Get-KitPlatformVersionFromPath -Path $mainPath
    # Збій переліку платформ не має ховати відповідь платформи: текст §4.1 виходить усе одно.
    $installed = @()
    $listError = $null
    try { $installed = @(Get-KitInstalledPlatforms) } catch { $listError = $_.Exception.Message }
    $key = $Source.Key
    $mirror = if ($null -ne $LastCommitted) { "лишається на версії $LastCommitted" } else { 'лишається без версій' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Версію $n основної конфігурації '$key' основна платформа $mainVer не вивантажує.")
    $lines.Add("Дзеркало $($Source.Branch) $mirror; часткового коміту немає.")
    $lines.Add("Платформа відповіла: $($d['Output'])")
    if ($null -ne $listError) {
        $lines.Add("(перелік платформ недоступний: $listError)")
    } else {
        $lines.Add('Встановлені платформи:')
        foreach ($l in (Format-KitPlatformList -Platforms $installed -MainPath $mainPath)) { $lines.Add($l) }
    }
    if ($null -ne $PendingSkip) {
        # Спека 1.3.1 §6.2: пропуск N активний і коміту в цьому прогоні ще не було — стандартні
        # команди для N+1 відхилила б §6.1.2/§6.1.5, тож їх не радимо; рішення — за людиною.
        $lines.Add("Пропуск версії $PendingSkip активний, але версія $n у цьому ж прогоні теж не вивантажується: поєднання пропуску $PendingSkip з вивантаженням іншою платформою чи з пропуском $n у 1.3.1 не підтримується.")
        $lines.Add("Пропуск версії $PendingSkip не відбувся (коміту з Storage-Skipped немає); дзеркало лишилось на версії $LastCommitted. Рішення — за людиною.")
        return ($lines -join "`n")
    }
    $others = @($installed | Where-Object { $_.Version -ne $mainVer } | ForEach-Object Version | Select-Object -Unique)
    if ($others.Count -gt 0) {
        $lines.Add('Вивантажити цю версію іншою платформою (зі згоди людини):')
        foreach ($o in $others) { $lines.Add("  kit sync -RepoRoot . -Source $key -Apply -DumpPlatform $o -ForVersion $n") }
    } elseif ($null -eq $listError) {
        $lines.Add('Інших платформ в оточенні немає — встановіть іншу версію або пропустіть версію.')
    }
    $lines.Add('Якщо жодна платформа не вивантажує — пропустити версію явно:')
    $lines.Add("  kit sync -RepoRoot . -Source $key -Apply -SkipVersion $n")
    $lines -join "`n"
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
        (templates/gitignore, рядок build/) — те саме прев'ю вже кладе туди worktree й дампи.
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

        Порядок (спека 2026-09-30 §5.4): усередині воркспейсу спершу джерела CONFIGURATION, далі
        решта в порядку маніфесту; воркспейси — у порядку маніфесту. Коли вибірка містить
        EXTENSION воркспейсу з CONFIGURATION під truth: storage, а саму CONFIGURATION до
        вибірки не потрапило, друкується попередження (не зупинка) — один раз на воркспейс.

        -MergeInto <гілка> — куди робити перше злиття й злиття -MergeMain (типово головна гілка
        маніфесту). Запобіжник (#15): якщо дзеркало ще не злите в цільову гілку, а в ній немає
        v8storagekit.yaml, злиття не виконується — результат як у провалу злиття (код 2).

        -DumpPlatform <версія> -ForVersion N (спека 1.3.1 §4.3) — версію N основної конфігурації
        вивантажує інша встановлена платформа (через .cf), коміт несе трейлер
        Storage-Dump-Platform. -SkipVersion N (§4.4) — версію N не переносити зовсім; наступний
        коміт несе Storage-Skipped. Обидва — лише для першої неперенесеної версії, лише з -Source;
        -DumpPlatform — лише для CONFIGURATION; -DumpPlatform/-ForVersion і -SkipVersion взаємовиключні. Усі
        перевірки — до першого UpdateCfg; у прев'ю обрана платформа не викликається.
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
        [switch]$FromLatest,
        [string]$MergeInto,
        [string]$DumpPlatform,
        [Nullable[int]]$ForVersion = $null,
        [Nullable[int]]$SkipVersion = $null
    )

    # Валідація параметрів — ДО будь-якого звернення до джерел чи платформи (навіть до
    # Select-KitSources): на клієнтській базі повна конфігурація реплеїться 20–40 хв/версію,
    # тож типову описку в номері версії чи в самих прапорцях має ловити перевірка, що не коштує
    # нічого, а не перший-ліпший з можливо кількох джерел truth: storage, ПІСЛЯ прогону платформи
    # в базі агента для нього.
    if ($null -ne $FromVersion -and $FromLatest) {
        throw 'Параметри -FromVersion і -FromLatest взаємовиключні — вкажіть лише один спосіб визначити початкову версію першого реплею.'
    }
    if ($null -ne $FromVersion -and $FromVersion -le 0) {
        throw "Значення -FromVersion має бути додатним номером версії сховища, отримано: $FromVersion."
    }

    # Параметри спеки 1.3.1 (§4.3, §4.4, §6.1) — теж до Select-KitSources; «дешеве першим».
    $hasDump = -not [string]::IsNullOrWhiteSpace($DumpPlatform)
    $hasFor  = $null -ne $ForVersion
    $hasSkip = $null -ne $SkipVersion
    if ($hasDump -xor $hasFor) {
        throw 'Параметри -DumpPlatform і -ForVersion вживаються лише разом: платформа і версія, яку вона вивантажує.'
    }
    if ($hasFor -and $ForVersion -le 0) {
        throw "Значення -ForVersion має бути додатним номером версії сховища, отримано: $ForVersion."
    }
    if ($hasSkip -and $SkipVersion -le 0) {
        throw "Значення -SkipVersion має бути додатним номером версії сховища, отримано: $SkipVersion."
    }
    if ($hasSkip -and $hasDump) {
        throw 'Параметри -SkipVersion і -DumpPlatform/-ForVersion взаємовиключні: версію або вивантажує інша платформа, або її пропущено.'
    }
    if (($hasDump -or $hasSkip) -and -not $Source) {
        throw 'Параметри -DumpPlatform/-ForVersion і -SkipVersion діють на одне джерело — вкажіть -Source <ключ>.'
    }
    $mainPlatformVersion = $null
    if ($hasDump) {
        $installed = @(Get-KitInstalledPlatforms)
        $mainPath = Get-V8Path
        if (@($installed | Where-Object { $_.Version -eq $DumpPlatform }).Count -eq 0) {
            throw ("Платформи $DumpPlatform в оточенні немає.`nВстановлені платформи:`n" +
                (@(Format-KitPlatformList -Platforms $installed -MainPath $mainPath) -join "`n"))
        }
        $mainPlatformVersion = Get-KitPlatformVersionFromPath -Path $mainPath
        if ($DumpPlatform -eq $mainPlatformVersion) {
            throw "-DumpPlatform $DumpPlatform — це і є основна платформа: вона цю версію й не вивантажила. Оберіть іншу встановлену платформу."
        }
    }

    $into    = if ($MergeInto) { $MergeInto } else { $Context.MainBranch }
    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    $sources = @(Sort-KitSyncSources -Sources $sources)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — синхронізувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Synced = @() }
    }

    foreach ($src in $sources) {
        if ($src.Type -notin @('CONFIGURATION', 'EXTENSION')) {
            throw "Джерело '$($src.Key)' має тип $($src.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION."
        }
        if ($hasDump -and $src.Type -ne 'CONFIGURATION') {
            throw "-DumpPlatform для розширення '$($src.Key)' не підтримується в 1.3.1: вивантаження іншою платформою — лише для основної конфігурації."
        }
    }

    # Fetch нічого не змінює в робочому дереві й не чіпає сховища, а знімає цілий клас хибних
    # висновків: локальне дзеркало, що відстало від origin, читається як «сховище попереду»
    # (ішуз #4). Недоступна мережа чи відсутній remote — попередження, не зупинка: репозиторій
    # без origin легальний.
    # Таймаути обов'язкові, і не заради швидкості: Invoke-KitGitProcess чекає на процес БЕЗ
    # обмеження часу (той самий клас, що docs/follow-ups.md §6 про платформу). Недоступний
    # SSH-хост тримав би прев'ю кілька хвилин на TCP-таймауті, а ключ під passphrase без
    # агента підвісив би його НАЗАВЖДИ — git чекав би вводу, якого в неінтерактивному процесі
    # не буде. BatchMode=yes перетворює це на швидку помилку, яку ми й показуємо попередженням.
    $fetch = Invoke-KitGitProcess -RepoRoot $root -Arguments @(
        '-c', 'core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=5',
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
        'fetch', '--quiet', '--no-tags', 'origin')
    if ($fetch.ExitCode -ne 0) {
        Write-Host "  УВАГА: git fetch origin не вдався (код $($fetch.ExitCode)) — стан origin може бути застарілим." -ForegroundColor Yellow
    }

    # Попередження §5.4: розширення без основної конфігурації воркспейсу, що йде під storage, —
    # вивантажуватимуться на тому стані, що зараз у базі агента. Не зупинка.
    foreach ($wsName in @($sources.Workspace | Select-Object -Unique)) {
        $ws = @($Context.Workspaces | Where-Object Path -eq $wsName)[0]
        $cfg = @($ws.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })
        $selectedHere = @($sources | Where-Object Workspace -eq $wsName)
        if ($cfg.Count -gt 0 -and @($selectedHere | Where-Object Type -eq 'EXTENSION').Count -gt 0 -and
            @($selectedHere | Where-Object Type -eq 'CONFIGURATION').Count -eq 0) {
            # Дужки навколо конкатенації обов'язкові: -f зв'язує міцніше за +, і без них формат
            # діяв би лише на другий рядок (ескіз брифа так і робив — {0} лишався в тексті).
            Write-Host (("  УВАГА: основну конфігурацію '{0}' (truth: storage) у цьому прогоні не синхронізовано — " +
                "контекст вивантаження розширень воркспейсу '{1}' той, що зараз у базі агента. Повний прогін: kit sync -Workspace {1}.") -f
                ($cfg.Key -join ', '), $wsName) -ForegroundColor Yellow
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
        # подіяв. Перевірка тут, ДО першого звернення до платформи для цього джерела — ще один
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

        $ibSwitch = $agent.IbSwitch; $ibUser = $agent.User; $fallback = $false
        Write-Host "База агента: $ibSwitch (воркспейс $($agent.Workspace))"
        Write-Host 'Читаю історію сховища...'

        try {
            $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath `
                -ExtensionName $(if ($src.Type -eq 'EXTENSION') { $src.Key } else { '' }) `
                -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -User $ibUser
        } catch {
            # Спека 2026-09-30 §6.9: розширення, якого ще немає в базі агента (нове джерело без
            # дерева), — не зупинка, а весь прогін джерела (звіт і кожна версія) в тимчасовій
            # порожній ІБ із заглушкою. Лише EXTENSION: для основної конфігурації «не знайдено»
            # означає інше, і база агента для неї — єдиний законний контекст. Будь-яка інша
            # помилка звіту (автентифікація, зайнята база) — як раніше, зупинка.
            if ($src.Type -ne 'EXTENSION' -or -not (Test-KitExtensionNotFound -Output $_.Exception.Message)) { throw }
            $ibSwitch = New-KitStorageInfobase -Source $src -WorkDir $workDir
            $ibUser = ''
            $fallback = $true
            Write-Host (("  УВАГА: розширення '{0}' ще немає в базі агента — прогін у тимчасовій ІБ із заглушкою, без власника. " +
                'Формат історичних комітів може відрізнятися (GUID замість імен у посиланнях); після злиття й operation=build ' +
                'наступні версії підуть у базі агента. База агента в цьому прогоні не змінюється.') -f $src.Key) -ForegroundColor Yellow
            $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath -ExtensionName $src.Key `
                -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -User $ibUser
        }
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

        $skipShow = $null
        if ($hasFor -or $hasSkip) {
            # §4.3/§6.1.2: і -ForVersion, і -SkipVersion — лише для ПЕРШОЇ неперенесеної версії, тож
            # дивимось на перелік без -MaxVersions (він пропущену не рахує, §4.4). Усі зупинки —
            # до першого UpdateCfg і до перевірки авторів (для пропущеної автор не потрібен).
            $pendingAll = Get-KitPendingVersions -AllVersions $all -LastVersion $last `
                -FromVersion $FromVersion -FromLatest:$FromLatest
            $optName = if ($hasFor) { "-ForVersion $ForVersion" } else { "-SkipVersion $SkipVersion" }
            $wanted = if ($hasFor) { $ForVersion } else { $SkipVersion }
            if ($pendingAll.Count -eq 0) {
                throw "${optName}: неперенесених версій немає — застосувати нічого."
            }
            if ($pendingAll[0].Version -ne $wanted) {
                throw ("${optName}: це не перша неперенесена версія — вона $($pendingAll[0].Version). " +
                       'Версію можна вивантажити іншою платформою чи пропустити лише тоді, коли вона наступна в черзі дзеркала.')
            }
            if ($hasSkip) {
                if ($pendingAll.Count -lt 2) {
                    throw "-SkipVersion ${SkipVersion}: пропуск можливий, лише коли у звіті є версія після ${SkipVersion} — дочекайтесь її."
                }
                $skipShow = $pendingAll[0]
                $pending = @($pendingAll | Select-Object -Skip 1)
                if ($MaxVersions -gt 0) { $pending = @($pending | Select-Object -First $MaxVersions) }
            } else {
                $pending = $pendingAll
                if ($MaxVersions -gt 0) { $pending = @($pending | Select-Object -First $MaxVersions) }
            }
        } else {
            $pending = Get-KitPendingVersions -AllVersions $all -LastVersion $last -MaxVersions $MaxVersions `
                -FromVersion $FromVersion -FromLatest:$FromLatest
        }
        # Без if-виразу: порожній $pending розгорнувся б у $null (і Pending зв'язався б із null).
        $gapPending = @($pending)
        if ($null -ne $skipShow) { $gapPending = @($skipShow) + $gapPending }
        $gap = Get-KitVersionGapNote -Pending $gapPending -LastVersion $last
        if ($gap) { Write-Host "  $gap" -ForegroundColor DarkGray }

        if ($pending.Count -eq 0) {
            Write-Host 'Нових версій немає — дзеркало синхронне зі сховищем.'

            # M-4-подібна знахідка (фінальне рев'ю, Important §6): дзеркало могло лишитись
            # попереду origin від ПОПЕРЕДНЬОГО прогону sync (наприклад, git push тоді не
            # виконали) — цей прогін нових версій не приносить, але попередження про
            # непушений push усе одно стосується поточного стану гілки й не має мовчати
            # лише тому, що цей рядок стоїть у гілці коду "pending порожній".
            $originGap = Get-KitOriginGap -RepoRoot $root -Branch $src.Branch
            if ($originGap.HasRemote -and $originGap.Ahead -gt 0) {
                Write-Host ("  Дзеркало попереду origin на {0} — git push origin {1}" -f $originGap.Ahead, $src.Branch) -ForegroundColor Yellow
            }

            $merged = $false
            if ($MergeMain -and $Apply -and $null -ne $last) { $merged = Invoke-KitMainMerge -Context $Context -Source $src -Into $into; if (-not $merged) { $mergeFailed = $true } }
            $results.Add([pscustomobject]@{ Key = $src.Key; Versions = @(); Branch = $src.Branch; MergedIntoMain = $merged; Fallback = $fallback; DumpedVia = $null; Skipped = [int[]]@() })
            continue
        }

        # Спека 2026-09-30 §6.8: автор може бути на логін АБО на конкретну версію. Спільний логін
        # в AUTHORS не вноситься — тоді кожна його версія тут і зупиняє прогін готовим рядком.
        # Форма виводу: рядок на логін, під ним ОКРЕМИЙ блок рядків версій підряд (щоб потрібний
        # рядок не губився серед коментарів), а опис версій — окремим блоком після нього. Кожен
        # рядок-заготовка — «<ключ>=Ім'я <пошта>» без хвоста: Complete-Authors (Sync.Storage.Tests.ps1)
        # впізнає його за цим шаблоном, хвіст «# …» його б не пропустив.
        # Без @(...) навколо виклику: функція повертає масив унарною комою (F7), і @() зробив би
        # з нього масив із одного елемента-масиву — Group-Object тоді не бачить .User.
        $unattributed = Get-KitUnattributedVersions -Map $authors -SourceKey $src.Key -Versions $pending
        if ($unattributed.Count -gt 0) {
            Write-Host ''
            Write-Host ('Невідомі автори — додайте в AUTHORS перед прогоном (рядок на логін, АБО рядок на кожну версію, ' +
                'якщо під логіном різні люди):') -ForegroundColor Yellow
            foreach ($g in ($unattributed | Group-Object { if ([string]::IsNullOrWhiteSpace($_.User)) { '' } else { $_.User } })) {
                $login = $g.Name
                Write-Host ("  логін «{0}» — версій {1}:" -f $(if ($login) { $login } else { '<порожній у звіті>' }), $g.Count)
                if ($login) {
                    Write-Host "    $login=Ім'я <пошта>"
                    Write-Host '    якщо за цим логіном різні люди — замість рядка вище, по рядку на кожну версію:'
                } else {
                    Write-Host '    логін у звіті порожній — лише рядок на кожну версію:'
                }
                foreach ($v in $g.Group) { Write-Host "    $($src.Key)#$($v.Version)=Ім'я <пошта>" }
                Write-Host '    що це за версії:'
                foreach ($v in $g.Group) {
                    $first = ($v.Comment -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    Write-Host ("      версія {0}, {1:yyyy-MM-dd HH:mm}{2}" -f $v.Version, $v.Timestamp, $(if ($first) { ", «$first»" } else { '' })) -ForegroundColor DarkGray
                }
            }
            throw 'Синхронізацію зупинено через невідомих авторів.'
        }

        Write-Host ''
        Write-Host "До перенесення версій: $($pending.Count)"
        foreach ($v in @(if ($null -ne $skipShow) { $skipShow }) + @($pending)) {
            $isSkipped = $null -ne $skipShow -and $v.Version -eq $skipShow.Version
            # Для пропущеної версії автор не потрібен (§4.4) — Resolve-Author на ній міг би зупинити.
            $authorName = if ($isSkipped) { '—' } else { (Resolve-Author -Map $authors -StorageUser $v.User -SourceKey $src.Key -Version $v.Version).Name }
            $first  = ($v.Comment -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if (-not $first) { $first = "Версія сховища $($v.Version)" }
            $mark = if ($isSkipped) { '  ← буде пропущено' }
                    elseif ($hasFor -and $v.Version -eq $ForVersion) { "  ← платформою $DumpPlatform" }
                    else { '' }
            Write-Host ("  v{0,-4} {1:yyyy-MM-dd HH:mm}  {2,-22} {3}{4}" -f $v.Version, $v.Timestamp, $authorName, $first, $mark)
        }

        if (-not $Apply) {
            Write-Host ''
            Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            continue
        }

        # Шлях обраної платформи — до worktree й до першого UpdateCfg: відсутня платформа зупиняє дешево.
        $altV8Path = if ($hasDump) { Get-V8Path -Version $DumpPlatform } else { $null }
        $skipNoted = $false
        $dumpedVia = $null

        $wt    = New-KitStorageWorktree -RepoRoot $root -Branch $src.Branch -Path (Join-Path $workDir 'wt')
        $done  = [System.Collections.Generic.List[int]]::new()
        # $bound = $false ПЕРЕД try обов'язковий: під Set-StrictMode -Version Latest звернення
        # до неприсвоєної змінної у finally само кине й витіснить первинний виняток (Step 4а
        # цього ж Task'у закривав рівно цю ваду для Remove-KitStorageWorktree). Enter-KitStorageBind
        # — ВСЕРЕДИНІ try (рев'ю Task 1, Important #1): якщо прив'язка впаде, worktree все одно
        # прибереться у finally, а не лишиться сиротою на диску й у git worktree list.
        $bound = $false
        try {
            $bound = Enter-KitStorageBind -IbSwitch $ibSwitch -Source $src -User $ibUser
            foreach ($v in $pending) {
                $author = Resolve-Author -Map $authors -StorageUser $v.User -SourceKey $src.Key -Version $v.Version
                Write-Host "→ версія $($v.Version) ($($author.Name), $($v.Date))"

                # Зупинка спеки 1.3.1 §4.1: основна платформа не вивантажила версію ПІСЛЯ успішного
                # UpdateCfg — розпізнаваний виняток стає текстом із виходами; worktree прибере finally,
                # коміти попередніх версій лишаються, часткового коміту цієї версії немає.
                # Збій ОБРАНОЇ платформи — звичайний виняток, не розпізнаваний: його не перекладаємо.
                $msgArgs = @{}
                try {
                    if ($hasFor -and $v.Version -eq $ForVersion) {
                        # WorkDir — build/sync/<ключ> (робоча тека джерела, межа тримається тут).
                        $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                            -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -WorkDir $workDir `
                            -AltV8Path $altV8Path -User $ibUser
                        $msgArgs = @{ DumpPlatform = $DumpPlatform; MainPlatform = $mainPlatformVersion }
                        $dumpedVia = $DumpPlatform
                    } else {
                        $null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                            -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -User $ibUser
                    }
                } catch {
                    if (Test-KitDumpFailure -ErrorRecord $_) {
                        $lastCommitted = if ($done.Count -gt 0) { $done[$done.Count - 1] } else { $last }
                        $pendingSkip = if ($hasSkip -and -not $skipNoted) { [int]$SkipVersion } else { $null }
                        throw (New-KitDumpStopMessage -Source $src -ErrorRecord $_ -LastCommitted $lastCommitted -PendingSkip $pendingSkip)
                    }
                    throw
                }
                if ($hasSkip -and -not $skipNoted) { $msgArgs.SkippedVersion = @([int]$SkipVersion); $skipNoted = $true }

                $message = New-KitStorageCommitMessage -Version $v -SourceKey $src.Key -SourceType $src.Type @msgArgs
                $commit = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath $src.RepoPath -Message $message `
                    -AuthorName $author.Name -AuthorEmail $author.Email -Timestamp $v.Timestamp
                if ($commit.Empty) { Write-Host '  (без змін у джерелах — коміт лише фіксує запис версії сховища)' -ForegroundColor DarkGray }
                $done.Add($v.Version)
            }
        } finally {
            Exit-KitStorageBind -IbSwitch $ibSwitch -Source $src -Bound $bound -User $ibUser
            Remove-KitStorageWorktree -RepoRoot $root -Path $wt.Path
        }
        Write-Host ("Перенесено версій: {0} → {1}" -f $done.Count, $src.Branch) -ForegroundColor Green

        $originGap = Get-KitOriginGap -RepoRoot $root -Branch $src.Branch
        if ($originGap.HasRemote -and $originGap.Ahead -gt 0) {
            Write-Host ("  Дзеркало попереду origin на {0} — git push origin {1}" -f $originGap.Ahead, $src.Branch) -ForegroundColor Yellow
        }

        # Контракт спеки §4: перемотування історії ЗАМІНЮЄ конфігурацію в базі агента, і база
        # лишається у стані останньої прочитаної версії. Це не побічний ефект, а оголошена
        # поведінка — мовчати про неї означало б, що наступний operation=syntax чи test побіжить
        # не на тому стані, який агент вважає своїм.
        if ($fallback) {
            Write-Host "База агента не змінювалась (запасний шлях). Далі: злиття дзеркала → operation=build Уніки — розширення з'явиться в базі агента." -ForegroundColor Yellow
        } else {
            Write-Host ("База агента воркспейсу '{0}' тепер містить версію {1} зі сховища. Перед роботою: operation=build Уніки." -f `
                $agent.Workspace, $done[-1]) -ForegroundColor Yellow
        }

        $merged = $false
        if ($wt.Created -or $MergeMain) {
            $merged = Invoke-KitMainMerge -Context $Context -Source $src -Into $into
            if (-not $merged) { $mergeFailed = $true }
        }
        $results.Add([pscustomobject]@{ Key = $src.Key; Versions = $done.ToArray(); Branch = $src.Branch; MergedIntoMain = $merged; Fallback = $fallback; DumpedVia = $dumpedVia; Skipped = [int[]]@(if ($hasSkip) { [int]$SkipVersion }) })
    }

    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    [pscustomobject]@{ ExitCode = $(if ($mergeFailed) { 2 } else { 0 }); Synced = $results.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSync
