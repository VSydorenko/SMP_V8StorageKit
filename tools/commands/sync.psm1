#Requires -Version 7
Set-StrictMode -Version Latest

# Lib-модулі вже імпортував kit.ps1 (module-order.txt); тут — лише оркестрація.
# Платформний шар «версія сховища → дамп» — StoragePlatform.psm1 (спільний із verify). Дамп іде в
# базі агента воркспейсу (Get-KitSourceInfobase); тимчасова ІБ (New-KitStorageInfobase) — лише
# запасний шлях для розширення, якого ще немає в базі агента.

function Sort-KitSyncSources {
    <#
    .SYNOPSIS
        Порядок sync: усередині воркспейсу CONFIGURATION першим — після
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
        Перше злиття дзеркала в цільову гілку (типово головна, інша — -MergeInto). Невдача
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
    # Запобіжник: ПЕРШЕ злиття в гілку без маніфесту — майже напевно не та гілка:
    # злиття пройде чисто, але покладе дерево на гілку, де kit не підключено.
    if (-not (Test-KitBranchMergedInto -RepoRoot $Context.RepoRoot -Branch $Source.Branch -Into $Into)) {
        git -C $Context.RepoRoot cat-file -e "${Into}:v8storagekit.yaml" 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Дужки навколо конкатенації: -f зв'язує міцніше за +.
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

function Invoke-KitMirrorPush {
    <#
    .SYNOPSIS
        Push дзеркала storage/<ключ> в origin — робота kit, а не людини (#149). Лише fast-forward.
    .DESCRIPTION
        Нічого не робить, коли немає origin, локальної гілки чи нових комітів для origin. Дзеркало, що
        розійшлося з origin (коміти є і там, і тут), — зупинка без спроби push: fast-forward неможливий,
        а force kit не робить ніколи. Відмова git push (мережа, права, гонка) — теж зупинка з сирим
        виводом git. Без -Apply лише каже, що запушить -Apply. Повертає Outcome і текст зупинки (Stop).
    #>
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Branch, [bool]$Apply)
    $nothing = [pscustomobject]@{ Outcome = 'none'; Stop = $null }
    $remote = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @('remote', 'get-url', 'origin')
    if ($remote.ExitCode -ne 0) { return $nothing }
    if (-not (Test-KitBranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return $nothing }

    $gap = Get-KitOriginGap -RepoRoot $RepoRoot -Branch $Branch
    if ($gap.HasRemote -and $gap.Ahead -eq 0) { return $nothing }
    if ($gap.HasRemote -and $gap.Behind -gt 0) {
        return [pscustomobject]@{ Outcome = 'stop'; Stop = (
            "push $Branch в origin не виконано: дзеркало й origin розійшлися (лише локально — {0}, лише на origin — {1} комітів), " +
            'fast-forward неможливий. Kit не робить force. Доповісти людині: дзеркало цього сховища оновлювали з двох місць.') -f $gap.Ahead, $gap.Behind }
    }

    $what = if ($gap.HasRemote) { "попереду origin на $($gap.Ahead)" } else { 'ще немає на origin' }
    if (-not $Apply) {
        Write-Host "  Дзеркало $what — kit sync -Apply запушить його (лише fast-forward)." -ForegroundColor Yellow
        return [pscustomobject]@{ Outcome = 'preview'; Stop = $null }
    }
    # Ті самі стелі, що в fetch на старті sync: ключ під passphrase без агента підвісив би git назавжди.
    # Явний refspec без '+': git сам відмовить на не-fast-forward.
    $push = Invoke-KitGitProcess -RepoRoot $RepoRoot -Arguments @(
        '-c', 'core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=5',
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
        'push', '--quiet', 'origin', "refs/heads/${Branch}:refs/heads/$Branch")
    if ($push.ExitCode -ne 0) {
        $raw = (($push.Stderr, $push.Stdout) -join "`n").Trim()
        return [pscustomobject]@{ Outcome = 'stop'; Stop = (
            "git push origin $Branch відхилено (код {0}): {1} — kit не робить force; доповісти людині з цим виводом." -f $push.ExitCode, $raw) }
    }
    $done = if ($gap.HasRemote) { "нових комітів: $($gap.Ahead)" } else { 'нова гілка на origin' }
    Write-Host "  Дзеркало запушено в origin: $Branch ($done)." -ForegroundColor Green
    [pscustomobject]@{ Outcome = 'pushed'; Stop = $null }
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
        Текст зупинки: основна платформа не вивантажує версію. Версія платформи —
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
    # Збій переліку платформ не має ховати відповідь платформи: текст зупинки виходить усе одно.
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
        # Пропуск N активний і коміту ще не було — команди для N+1 відхилила б перевірка -ForVersion/-SkipVersion,
        # тож їх не радимо; рішення — за людиною.
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
        Реплей нових версій кожного джерела truth: storage у гілку storage/<ключ>.
    .DESCRIPTION
        Пише відбиток сховища (build/session-check/<ключ>.json, StorageImprint.psm1) одразу після
        читання звіту — і в прев'ю теж: build/ — гітігнорована робоча тека машини, не git, не
        сховище й не дев-база, тож контракт «прев'ю нічого не змінює» не порушено. Без відбитка
        session-check платив би повним прогоном платформи за кожну відповідь про те саме сховище.

        -FromVersion N / -FromLatest — з якої версії почати ПЕРШИЙ реплей порожньої гілки
        (вісь «звідки», незалежна від -MaxVersions — «скільки»). Без них перший реплей великого
        сховища фізично неможливий. Застосовні лише поки на вершині storage/<ключ> немає трейлера
        Storage-Version — інакше зупинка з поясненням, а не тихе ігнорування. Взаємовиключні.

        Порядок: усередині воркспейсу спершу джерела CONFIGURATION, далі
        решта в порядку маніфесту; воркспейси — у порядку маніфесту. Коли вибірка містить
        EXTENSION воркспейсу з CONFIGURATION під truth: storage, а саму CONFIGURATION до
        вибірки не потрапило, друкується попередження (не зупинка) — один раз на воркспейс.

        -MergeInto <гілка> — куди робити перше злиття й злиття -MergeMain (типово головна гілка
        маніфесту). Запобіжник: якщо дзеркало ще не злите в цільову гілку, а в ній немає
        v8storagekit.yaml, злиття не виконується — результат як у провалу злиття (код 4).

        -DumpPlatform <версія> -ForVersion N — версію N основної конфігурації
        вивантажує інша встановлена платформа (через .cf), коміт несе трейлер
        Storage-Dump-Platform. -SkipVersion N — версію N не переносити зовсім; наступний
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
        [Nullable[int]]$SkipVersion = $null,
        # Шлях до раннера Уніки; порожній — із реєстру плагінів (Get-KitRunnerPath). Явний параметр, не
        # змінна оточення: так тести-підпроцеси підміняють раннер, а production нічого не читає заради тестів.
        [string]$RunnerPath
    )
    Reset-KitNextStep

    # Валідація параметрів — ДО будь-якого звернення до джерел чи платформи: описку в прапорцях
    # має ловити безкоштовна перевірка, а не збій після прогону платформи (20–40 хв/версію).
    if ($null -ne $FromVersion -and $FromLatest) {
        throw 'Параметри -FromVersion і -FromLatest взаємовиключні — вкажіть лише один спосіб визначити початкову версію першого реплею.'
    }
    if ($null -ne $FromVersion -and $FromVersion -le 0) {
        throw "Значення -FromVersion має бути додатним номером версії сховища, отримано: $FromVersion."
    }

    # -DumpPlatform/-ForVersion/-SkipVersion — теж до Select-KitSources.
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


    $into    = if ($MergeInto) { $MergeInto } else { $Context.MainBranch }
    $root    = $Context.RepoRoot
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)
    $sources = @(Sort-KitSyncSources -Sources $sources)
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: storage — синхронізувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Synced = @(); AlignSteps = @() }
    }

    foreach ($src in $sources) {
        if ($src.Type -notin @('CONFIGURATION', 'EXTENSION')) {
            throw "Джерело '$($src.Key)' має тип $($src.Type) — сховища конфігурацій для нього не буває; truth: storage лише для CONFIGURATION і EXTENSION."
        }
        if ($hasDump -and $src.Type -ne 'CONFIGURATION') {
            throw "-DumpPlatform для розширення '$($src.Key)' не підтримується в 1.3.1: вивантаження іншою платформою — лише для основної конфігурації."
        }
    }

    # Платформу для пакетних операцій у базі агента обирає раннер, не Get-V8Path;
    # раннера немає — зупинка до звернення до платформи. Платформа кешується на воркспейс і далі
    # іде явним -V8Path. Шлях раннера — ліниво: у циклі ПІСЛЯ Get-KitSourceInfobase (його дешеві
    # запобіжники — першими), для -DumpPlatform — нижче.
    $runner = $RunnerPath
    $platformByWs = @{}
    $mainPlatformVersion = $null
    if ($hasDump) {
        # «Основна платформа» для -DumpPlatform — платформа раннера воркспейсу єдиного джерела; тому
        # після Select-KitSources, коли воркспейс відомий. Шлях ІНШОЇ платформи — з Get-KitInstalledPlatforms.
        if (-not $runner) { $runner = Get-KitRunnerPath }
        $installed = @(Get-KitInstalledPlatforms)
        $dumpWs = @($Context.Workspaces | Where-Object Path -eq $sources[0].Workspace)[0]
        $mainPath = Get-KitAgentPlatform -Project $dumpWs.Project -RunnerPath $runner
        $platformByWs[$dumpWs.Path] = $mainPath
        if (@($installed | Where-Object { $_.Version -eq $DumpPlatform }).Count -eq 0) {
            throw ("Платформи $DumpPlatform в оточенні немає.`nВстановлені платформи:`n" +
                (@(Format-KitPlatformList -Platforms $installed -MainPath $mainPath) -join "`n"))
        }
        $mainPlatformVersion = Get-KitPlatformVersionFromPath -Path $mainPath
        if ($DumpPlatform -eq $mainPlatformVersion) {
            throw "-DumpPlatform $DumpPlatform — це і є основна платформа: вона цю версію й не вивантажила. Оберіть іншу встановлену платформу."
        }
    }

    # Fetch нічого не змінює, а без нього дзеркало, що відстало від origin, читається як «сховище
    # попереду». Недоступна мережа чи відсутній remote — попередження: репозиторій без origin легальний.
    # Таймаути обов'язкові: Invoke-KitGitProcess чекає процес без ліміту, а ключ під passphrase без
    # агента підвісив би git НАЗАВЖДИ (чекав би вводу). BatchMode=yes робить це швидкою помилкою.
    $fetch = Invoke-KitGitProcess -RepoRoot $root -Arguments @(
        '-c', 'core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=5',
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
        'fetch', '--quiet', '--no-tags', 'origin')
    if ($fetch.ExitCode -ne 0) {
        Write-Host "  УВАГА: git fetch origin не вдався (код $($fetch.ExitCode)) — стан origin може бути застарілим." -ForegroundColor Yellow
    }

    # Попередження: розширення без основної конфігурації воркспейсу, що йде під storage, —
    # вивантажуватимуться на тому стані, що зараз у базі агента. Не зупинка.
    foreach ($wsName in @($sources.Workspace | Select-Object -Unique)) {
        $ws = @($Context.Workspaces | Where-Object Path -eq $wsName)[0]
        $cfg = @($ws.Sources | Where-Object { $_.Type -eq 'CONFIGURATION' -and $_.Truth -eq 'storage' })
        $selectedHere = @($sources | Where-Object Workspace -eq $wsName)
        if ($cfg.Count -gt 0 -and @($selectedHere | Where-Object Type -eq 'EXTENSION').Count -gt 0 -and
            @($selectedHere | Where-Object Type -eq 'CONFIGURATION').Count -eq 0) {
            # Дужки навколо конкатенації обов'язкові: -f зв'язує міцніше за +, і без них формат
            # діяв би лише на другий рядок.
            Write-Host (("  УВАГА: основну конфігурацію '{0}' (truth: storage) у цьому прогоні не синхронізовано — " +
                "контекст вивантаження розширень воркспейсу '{1}' той, що зараз у базі агента. Повний прогін: kit sync -Workspace {1}.") -f
                ($cfg.Key -join ', '), $wsName) -ForegroundColor Yellow
        }
    }

    $authors  = Read-AuthorMap -Path (Join-Path $root 'AUTHORS')
    $results  = [System.Collections.Generic.List[object]]::new()
    $mergeFailed = $false
    # Кроки вирівнювання пам'яті раннера: по одному на набір, базу якого зрушив sync.
    $alignSteps = [System.Collections.Generic.List[object]]::new()
    # Тексти зупинок push дзеркал (Invoke-KitMirrorPush): решта джерел обробляється далі, рядки ЗУПИНКА
    # друкуються наприкінці, код виходу — 1.
    $pushStops = [System.Collections.Generic.List[string]]::new()

    # Друк уже обчислених кроків і ЗУПИНКА — у finally: виняток у пізнішому джерелі не має губити крок,
    # уже потрібний агентові від попередніх наборів. Виняток і код виходу — незмінні.
    $completed = $false
    try {
        foreach ($src in $sources) {
            Write-Host ''
            Write-Host "Джерело:    $($src.Workspace)/$($src.Key) ($($src.Type))"
            Write-Host "Сховище:    $($src.StoragePath) (користувач $($src.StorageUser))"
            Write-Host "Гілка:      $($src.Branch)"
            if (-not (Test-Path -LiteralPath $src.StoragePath)) {
                throw "Каталог сховища не знайдено: $($src.StoragePath). Перевизначте його в v8storagekit.local.yaml під storages: $($src.Key)."
            }
            # Дзеркало лише на origin (#101): реплей з нуля дав би другу історію сховища. Зупинка до бази й платформи.
            if (Test-KitRemoteOnlyMirror -RepoRoot $root -Branch $src.Branch) {
                throw ("Локальної гілки $($src.Branch) немає, але є origin/$($src.Branch) — реплей з нуля дав би другу історію сховища. " +
                       "Відновіть дзеркало: $(Get-KitRestoreMirrorStep -Branch $src.Branch), і повторіть sync.")
            }

            # Дамп — у базі агента, не в тимчасовій ІБ зі стабом: серіалізація розширення залежить від
            # конфігурації-власника (зі стаба — GUID замість імен). Get-KitSourceInfobase несе запобіжник
            # «це не дев-база людини» — критичний, бо UpdateCfg замінює конфігурацію в базі. Він
            # дешевий і стоїть до створення робочої теки.
            $agent = Get-KitSourceInfobase -Context $Context -Source $src

            # Навмисно без try/catch: вершина storage/* без числового Storage-Version — це порушення інваріанту дзеркала,
            # і виняток із текстом «гілку писав не sync. Розбір: kit check» І Є штатною зупинкою sync.
            # Загортати його в інше повідомлення чи вгадувати стан — не можна.
            $last = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $src.Branch
            # Рядок враховує обрану глибину першого реплею (-FromVersion/-FromLatest).
            $mirrorNote = 'гілки ще немає — реплей усіх версій зі звіту'
            if ($null -ne $last) {
                $mirrorNote = "версія $last"
            } elseif ($FromLatest) {
                $mirrorNote = 'гілки ще немає — перший реплей лише з ОСТАННЬОЇ версії звіту (-FromLatest)'
            } elseif ($null -ne $FromVersion) {
                $mirrorNote = "гілки ще немає — перший реплей зі звіту, починаючи з версії $FromVersion (-FromVersion)"
            }
            Write-Host "Дзеркало:   $mirrorNote"

            # На гілці з версіями «звідки почати» вже вирішило дзеркало; мовчазне ігнорування сховало б,
            # що параметр не подіяв. Перевірка — до першого звернення до платформи для джерела.
            if ($null -ne $last -and ($null -ne $FromVersion -or $FromLatest)) {
                throw ("Гілка $($src.Branch) не порожня — вершина вже має трейлер Storage-Version: $last. " +
                       '-FromVersion і -FromLatest визначають, ЗВІДКИ почати ПЕРШИЙ реплей порожньої гілки; ' +
                       'на непорожній гілці дозаливку веде звичайний sync (за потреби — -MaxVersions).')
            }

            # Робоча тека джерела — з нуля на кожен запуск. Worktree від перерваного прогону спершу знімаємо з реєстрації.
            $workDir = Join-Path $root 'build/sync' $src.Key
            Assert-KitBuildPath -Path $workDir -MustBeUnder (Join-Path $root 'build/sync') -RepoRoot $root -Description "робоча тека джерела $($src.Key)"
            $staleWt = Join-Path $workDir 'wt'
            if (Test-Path -LiteralPath $staleWt) {
                # Ґейт на Test-Path: без нього git worktree remove на незареєстрованій теці штатно
                # дає код 128, і попередження лунало б на кожному прогоні. Невдале зняття не зупиняє
                # sync (теку прибере Remove-KitDirectory), але лишає осиротілий запис у worktree list.
                git -C $root worktree remove --force $staleWt 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  УВАГА: не вдалося зняти реєстрацію worktree '$staleWt' від перерваного прогону (код ${LASTEXITCODE}) — теку прибере наступний крок, але запис у git worktree list може лишитись осиротілим." -ForegroundColor Yellow
                }
            }
            git -C $root worktree prune 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  УВАГА: git worktree prune завершився кодом ${LASTEXITCODE} — застарілі реєстрації worktree могли не прибратись." -ForegroundColor Yellow
            }
            Remove-KitDirectory -Path $workDir
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $ibSwitch = $agent.IbSwitch; $ibUser = $agent.User; $ibPassword = $agent.Password; $fallback = $false
            Write-Host "База агента: $ibSwitch (воркспейс $($agent.Workspace))"
            if (-not $runner) { $runner = Get-KitRunnerPath }
            if (-not $platformByWs.ContainsKey($agent.Workspace)) {
                $platformByWs[$agent.Workspace] = Get-KitAgentPlatform -Project $agent.Project -RunnerPath $runner
            }
            $v8Path = $platformByWs[$agent.Workspace]
            Write-Host "Платформа:  $(Get-KitPlatformVersionFromPath -Path $v8Path) (обрав раннер)"
            # agent release — перед кожною пакетною операцією в базі агента: раннер тримає
            # зв'язок із базою, і платформа в неї не ввійде. released:false — норма, без друку.
            $null = Invoke-KitAgentRelease -Project $agent.Project -RunnerPath $runner
            Write-Host 'Читаю історію сховища...'

            try {
                $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath `
                    -ExtensionName $(if ($src.Type -eq 'EXTENSION') { $src.Key } else { '' }) `
                    -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -V8Path $v8Path -User $ibUser -Password $ibPassword
            } catch {
                # Розширення, якого ще немає в базі агента, — не зупинка, а весь прогін джерела
                # у тимчасовій порожній ІБ із заглушкою. Лише EXTENSION: для основної конфігурації база
                # агента — єдиний законний контекст. Будь-яка інша помилка звіту — зупинка.
                if ($src.Type -ne 'EXTENSION' -or -not (Test-KitExtensionNotFound -Output $_.Exception.Message)) { throw }
                $ibSwitch = New-KitStorageInfobase -Source $src -WorkDir $workDir -RepoRoot $root -V8Path $v8Path
                $ibUser = ''; $ibPassword = ''
                $fallback = $true
                Write-Host (("  УВАГА: розширення '{0}' ще немає в базі агента — прогін у тимчасовій ІБ із заглушкою, без власника. " +
                    'Формат історичних комітів може відрізнятися (GUID замість імен у посиланнях); після злиття й push Уніки з "force":true для цього розширення ' +
                    '(його ще немає в пам''яті раннера, звичайний push відповів би no_memory) наступні версії підуть у базі агента. База агента в цьому прогоні не змінюється.') -f $src.Key) -ForegroundColor Yellow
                $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath -ExtensionName $src.Key `
                    -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir -V8Path $v8Path -User $ibUser -Password $ibPassword
            }
            $maxVersion = if ($all.Count -gt 0) { ($all | Measure-Object -Property Version -Maximum).Maximum } else { 'немає' }
            Write-Host "У сховищі версій: $($all.Count), максимальна: $maxVersion"

            # Відбиток — ОДРАЗУ після звіту, ДО гілки «нових версій немає»: саме для неактивного сховища
            # він і потрібен, а після її continue не оновився б ніколи. Без версій писати нема чого
            # ($maxVersion тоді рядок). Збій запису кешу машини — лише попередження.
            if ($all.Count -gt 0) {
                try {
                    Write-KitStorageImprint -RepoRoot $root -Key $src.Key -StoragePath $src.StoragePath -Version ([int]$maxVersion) | Out-Null
                } catch {
                    Write-Host "  УВАГА: не вдалося записати відбиток сховища (build/session-check/$($src.Key).json): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            $skipShow = $null
            if ($hasFor -or $hasSkip) {
                # І -ForVersion, і -SkipVersion — лише для ПЕРШОЇ неперенесеної версії, тож
                # дивимось на перелік без -MaxVersions (він пропущену не рахує). Усі зупинки —
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

                # Дзеркало могло лишитись попереду origin від попереднього прогону — push стосується
                # стану гілки, не цього прогону.
                $pushed = Invoke-KitMirrorPush -RepoRoot $root -Branch $src.Branch -Apply $Apply
                if ($pushed.Stop) { $pushStops.Add($pushed.Stop) }

                $merged = $false
                if ($MergeMain -and $Apply -and $null -ne $last) { $merged = Invoke-KitMainMerge -Context $Context -Source $src -Into $into; if (-not $merged) { $mergeFailed = $true } }
                $results.Add([pscustomobject]@{ Key = $src.Key; Versions = @(); Branch = $src.Branch; MergedIntoMain = $merged; Fallback = $fallback; DumpedVia = $null; Skipped = [int[]]@(); AlignStep = $null })
                continue
            }

            # Автор — на логін АБО на конкретну версію (спільний логін в AUTHORS не вносять).
            # Рядок-заготовка — «<ключ>=Ім'я <пошта>» без хвоста: за цим шаблоном його впізнає
            # Complete-Authors у тестах. Без @(...) навколо виклику: функція повертає масив унарною
            # комою, і @() дав би масив з одного масиву — Group-Object не побачив би .User.
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
                # Для пропущеної версії автор не потрібен — Resolve-Author на ній міг би зупинити.
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
            $alignStep = $null
            $shifted = $false
            try {
                # $bound = $false ПЕРЕД try обов'язковий: під StrictMode неприсвоєна змінна у finally
                # кине й витіснить первинний виняток. Enter-KitStorageBind — ВСЕРЕДИНІ try: якщо
                # прив'язка впаде, worktree однаково прибере finally.
                $bound = $false
                try {
                    $bound = Enter-KitStorageBind -IbSwitch $ibSwitch -Source $src -V8Path $v8Path -User $ibUser
                    foreach ($v in $pending) {
                        $author = Resolve-Author -Map $authors -StorageUser $v.User -SourceKey $src.Key -Version $v.Version
                        Write-Host "→ версія $($v.Version) ($($author.Name), $($v.Date))"

                        # Зупинка: основна платформа не вивантажила версію ПІСЛЯ успішного
                        # UpdateCfg — розпізнаваний виняток стає текстом із виходами; worktree прибере finally,
                        # коміти попередніх версій лишаються, часткового коміту цієї версії немає.
                        # Збій ОБРАНОЇ платформи — звичайний виняток, не розпізнаваний: його не перекладаємо.
                        $msgArgs = @{}
                        # Від цього місця база агента може тримати версію сховища (UpdateCfg усередині виклику).
                        $shifted = $true
                        try {
                            if ($hasFor -and $v.Version -eq $ForVersion) {
                                # WorkDir — build/sync/<ключ> (робоча тека джерела, межа тримається тут).
                                $null = Invoke-KitStorageCheckoutViaPlatform -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                                    -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -WorkDir $workDir -RepoRoot $root `
                                    -V8Path $v8Path -AltV8Path $altV8Path -User $ibUser -Password $ibPassword
                                $msgArgs = @{ DumpPlatform = $DumpPlatform; MainPlatform = $mainPlatformVersion }
                                $dumpedVia = $DumpPlatform
                            } else {
                                $null = Invoke-KitStorageCheckout -IbSwitch $ibSwitch -Source $src -Version $v.Version `
                                    -Target (Join-Path $wt.Path $src.RepoPath) -MustBeUnder $wt.Path -RepoRoot $root -V8Path $v8Path -User $ibUser -Password $ibPassword
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
                            -AuthorName $author.Name -AuthorEmail $author.Email -Timestamp $v.Timestamp -RepoRoot $root
                        if ($commit.Empty) { Write-Host '  (без змін у джерелах — коміт лише фіксує запис версії сховища)' -ForegroundColor DarkGray }
                        $done.Add($v.Version)
                    }
                } finally {
                    Exit-KitStorageBind -IbSwitch $ibSwitch -Source $src -Bound $bound -V8Path $v8Path -User $ibUser
                    Remove-KitStorageWorktree -RepoRoot $root -Path $wt.Path
                }
                Write-Host ("Перенесено версій: {0} → {1}" -f $done.Count, $src.Branch) -ForegroundColor Green

                $pushed = Invoke-KitMirrorPush -RepoRoot $root -Branch $src.Branch -Apply $true
                if ($pushed.Stop) { $pushStops.Add($pushed.Stop) }

                # Контракт sync: перемотування історії ЗАМІНЮЄ конфігурацію в базі агента. Після нього
                # пам'ять раннера розходиться з базою, тож sync закінчується кроком вирівнювання (нижче).
                # Запасний шлях базу агента не чіпав — вирівнювати нічого.
                if ($fallback) {
                    Write-Host ("База агента не змінювалась (запасний шлях). Далі: злиття дзеркала → push Уніки з `"force`":true для цього розширення " +
                        "(його ще немає в пам'яті раннера; звичайний push відповів би no_memory) — розширення з'явиться в базі агента.") -ForegroundColor Yellow
                } else {
                    Write-Host ("База агента воркспейсу '{0}' тепер містить версію {1} зі сховища — це контракт sync, не збій." -f `
                        $agent.Workspace, $done[-1]) -ForegroundColor Yellow
                }

                $merged = $false
                if ($wt.Created -or $MergeMain) {
                    $merged = Invoke-KitMainMerge -Context $Context -Source $src -Into $into
                    if (-not $merged) { $mergeFailed = $true }
                }

        } finally {
            # Крок для КОЖНОГО зсунутого набору: зсунутий, щойно почалось перше оновлення бази агента
            # ($shifted), а не за кількістю перенесених версій — UpdateCfg міг пройти, а дамп впасти. Крок
            # друкується й коли обробка джерела кинула виняток (виняток летить далі незмінним): інакше база
            # тримала б версію сховища, а git — іншу. OnMainBranch лише обирає варіант рецепту поставки.
            if ($shifted -and -not $fallback) {
                try {
                    $onMain = Test-KitOnMainBranch -RepoRoot $root -MainBranch $Context.MainBranch
                    $alignStep = Get-KitAlignStep -Source $src -OnMainBranch $onMain -MainBranch $Context.MainBranch
                    Write-KitAlignStep -Step $alignStep
                    $alignSteps.Add($alignStep)
                } catch {
                    Write-Host "  Крок вирівнювання для '$($src.Key)' не обчислено: $($_.Exception.Message) — база агента зрушена; вирівняйте її вручну (push force:true цього набору)." -ForegroundColor Red
                }
            }
        }
            $results.Add([pscustomobject]@{ Key = $src.Key; Versions = $done.ToArray(); Branch = $src.Branch; MergedIntoMain = $merged; Fallback = $fallback; DumpedVia = $dumpedVia; Skipped = [int[]]@(if ($hasSkip) { [int]$SkipVersion }); AlignStep = $alignStep })
        }
        $completed = $true
    } finally {
        Write-Host ''
        # Рядки ЗУПИНКА — останніми, після підсумку; для набору зі зупинкою підсумок не каже «Готово»,
        # а після винятку (цикл не дійшов до кінця) — не каже його теж.
        $blocked = @($alignSteps | Where-Object Op -eq 'blocked')
        $transferred = @($results | Where-Object { @($_.Versions).Count -gt 0 }).Count -gt 0
        if ($blocked.Count -gt 0) {
            $line = "Дзеркала оновлено, але вирівнювання не завершено для: {0} — див. ЗУПИНКА нижче." -f (($blocked.SourceSet) -join ', ')
            if ($mergeFailed) { $line += ' Злиття в основну гілку теж не вдалось (код виходу 4) — див. повідомлення вище.' }
            Write-Host $line -ForegroundColor Yellow
        } elseif ($mergeFailed) {
            # Злиття впало (код 4): «Готово» було б хибним успіхом; «Дзеркала оновлено» — лише коли справді
            # щось перенесено.
            if ($transferred) {
                Write-Host 'Дзеркала оновлено, але злиття в основну гілку не вдалось — див. повідомлення вище.' -ForegroundColor Yellow
            } else {
                Write-Host 'Нових версій не було, але злиття в основну гілку не вдалось — див. повідомлення вище.' -ForegroundColor Yellow
            }
        } elseif ($pushStops.Count -gt 0) {
            Write-Host 'Push дзеркала в origin не виконано — див. ЗУПИНКА нижче.' -ForegroundColor Yellow
        } elseif ($completed) {
            Write-Host 'Готово.' -ForegroundColor Green
        }
        Write-KitAlignStops -Steps $alignSteps.ToArray()
        Write-KitStopLines -Messages $pushStops.ToArray()
    }
    # Після ЗУПИНКА і після винятку рядка немає (ADR-0014): finally вище його не друкує.
    Write-KitNextStepLine
    $exitCode = if ($pushStops.Count -gt 0) { 1 } elseif ($mergeFailed) { 4 } else { 0 }
    [pscustomobject]@{ ExitCode = $exitCode; Synced = $results.ToArray(); AlignSteps = $alignSteps.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSync
