#Requires -Version 7
Set-StrictMode -Version Latest

# Повний check викликається явно і в session-check. Диспетчер імпортує лише запитаний командний
# модуль, тому check підключається тут (без -Force — не перезавантажувати вже наявний).
Import-Module "$PSScriptRoot/check.psm1"

# Допуск порівняння mtime сховища з датою коміту дзеркала: sync стемпить дати комітів цілими
# секундами, а mtime має частку секунди — без допуску вічний хибний сигнал. Навмисно малий (5 с):
# великий дав би протилежний дефект — версія, записана невдовзі після sync, не дала б сигналу ніколи.
$script:StorageMirrorTolerance = [timespan]::FromSeconds(5)

# Знахідки check про СТАН МАШИНИ (Уніка, її раннер), а не про репозиторій. Сигнали (git, теки сховищ, відбитки) раннера
# не потребують, тож такі errors не блокують їх обчислення: session-check друкує і сигнали, і ці знахідки. Блокують лише
# errors репозиторію й конфігу. ЄДИНЕ місце переліку: новий check про стан машини додається сюди, за ідентифікатором
# знахідки (Check), а не за текстом повідомлення.
$script:MachineStateChecks = @('runner-version', 'unica-version')

function Invoke-KitSessionCheck {
    <#
    .SYNOPSIS
        Дешевий сигнал для старту сесії: без платформи, без ліцензії, один обхід
        каталогу на джерело. Спершу — повний check (-Quiet) тим самим контекстом: error → код 1 і сигнали
        не обчислюються (на storage/* з чужим комітом дата дзеркала нічого не означає — одне правило замість
        таблиці «які помилки ще дозволяють сигнали»); лише warn → [!]-рядки над сигналами, плюс [i] для знахідок
        із білого списку (main-branch — info-половина дворівневої знахідки). Нічого не змінює: на кожне
        джерело спершу відбиток сховища — якщо він актуальний, точна відповідь замість евристик mtime;
        інакше евристики. Відбиток тут лише ЧИТАЄТЬСЯ: пише його виключно sync.psm1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        # Реєстр плагінів машини — прокидається в check (там версія Уніки); умовчання те саме.
        [string]$InstalledPluginsPath = (Join-Path $HOME '.claude/plugins/installed_plugins.json'),
        # Шлях до раннера Уніки — прокидається в check (там версія раннера); порожній — із реєстру вище.
        [string]$RunnerPath,
        # -Apply не оголошено свідомо: команда нічого не мутує. Диспетчер на переданий -Apply
        # зупиняється з поясненням.
        [switch]$AsJson
    )

    Reset-KitNextStep
    $root = $Context.RepoRoot
    $main = $Context.MainBranch
    $signals = [System.Collections.Generic.List[object]]::new()
    # Перший крок-команда кожного джерела — для рядка `next:` (ADR-0014); у -AsJson не друкується.
    $stepOf = @{}

    # --- Повний check першим. Виняток із check — теж «репозиторій суперечливий», код 1.
    $checkFindings = @()
    try {
        $checkFindings = @((Invoke-KitCheck -Context $Context -Workspace $Workspace -Source $Source -InstalledPluginsPath $InstalledPluginsPath -RunnerPath $RunnerPath -Quiet).Findings)
    } catch {
        $checkFindings = @(New-KitFinding -Level error -Check 'check' -Message "check не відпрацював: $($_.Exception.Message)")
    }
    $allErrors = @($checkFindings | Where-Object Level -eq 'error')
    $checkErrors = @($allErrors | Where-Object { $_.Check -notin $script:MachineStateChecks })   # блокують сигнали
    $machineErrors = @($allErrors | Where-Object { $_.Check -in $script:MachineStateChecks })    # друкуються поряд із сигналами
    # Недоступне сховище описує сигнал джерела (з порадою про накладку) — check-рядок про той самий шлях опускаємо.
    $checkWarns  = @($checkFindings | Where-Object { $_.Level -eq 'warn' -and $_.Check -ne 'storage-path' })
    # info друкуємо лише з білого списку: check дає info на кожному прогоні (рядок-зведення «Маніфест: …»), і
    # пускати всі означало б шум на кожному старті сесії. main-branch — інша річ: це info-половина дворівневої
    # знахідки («свіжий репозиторій: гілку створить перший коміт»), без неї розрізнювач мертвий.
    $checkInfos  = @($checkFindings | Where-Object { $_.Level -eq 'info' -and $_.Check -in @('main-branch') })

    if ($checkErrors.Count -gt 0) {
        if ($AsJson) {
            # Контракт -AsJson — одна форма в обох гілках: масив сигналів (тут порожній). Що check
            # упав, споживач читає з коду виходу (1), не з форми JSON.
            Write-Host (ConvertTo-Json -InputObject @() -Depth 4)
        } else {
            Write-Host "session-check — $($Context.Kind) $($Context.Label)"
            foreach ($e in $allErrors) { Write-Host "[-] $($e.Message)" -ForegroundColor Red }   # і знахідки стану машини: вони теж інформація
            Write-Host 'Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.' -ForegroundColor Red
            Register-KitNextStep -Step 'kit check'
            Write-KitNextStepLine
        }
        return [pscustomobject]@{ ExitCode = 1; CheckFindings = $checkFindings; Signals = @() }
    }

    $mainExists = Test-KitBranchExists -RepoRoot $root -Branch $main

    foreach ($src in @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)) {
        $mirror = Test-KitBranchExists -RepoRoot $root -Branch $src.Branch
        # Хук старту сесії: збій git тут — деградація до рядка «стан не прочитано», НЕ виняток.
        $lastMirror = $null; $gitProblem = $null
        if ($mirror) {
            $iso = (git -C $root log -1 --format=%aI $src.Branch 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $iso) { $gitProblem = "git log $($src.Branch) не відповів" }
            else { $lastMirror = ([datetimeoffset]$iso).UtcDateTime }
        }

        # Стан origin — з наявних refs, БЕЗ мережі: два джерела правди (сховище й
        # origin) розходяться мовчки, і сліпота до другого дає впевнено хибну картину першого.
        $originGap = $null
        if ($mirror -and -not $gitProblem) {
            $originGap = Get-KitOriginGap -RepoRoot $root -Branch $src.Branch
        }
        $activity = Get-KitStorageActivity -StoragePath $src.StoragePath

        # Відбиток — ЛИШЕ читання; пише його виключно sync. На цьому інваріанті стоїть законність
        # примусового вбивання процесу session-check за стелею часу. Читаємо лише коли є з чим
        # звірити версію (дзеркало є, стан git прочитано).
        $imprint = $null; $imprintCurrent = $false; $lastVersion = $null
        if ($mirror -and -not $gitProblem) {
            $imprint = Read-KitStorageImprint -RepoRoot $root -Key $src.Key
            if ($null -ne $imprint) { $imprintCurrent = Test-KitStorageImprintCurrent -Imprint $imprint -Activity $activity }
            if ($imprintCurrent) {
                try { $lastVersion = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $src.Branch }
                catch {
                    # Гілку вже пройшов повний check (checkErrors.Count -eq 0 вище) — трейлер
                    # Storage-Version має бути валідним; лишається деградація до git-проблеми, як і
                    # решта збоїв git у цій функції, а не throw (session-check нічого не кидає).
                    $gitProblem = "Storage-Version на вершині $($src.Branch) не прочитано: $($_.Exception.Message)"
                    $imprintCurrent = $false
                }
            }
        }

        # Причини «є що робити» (NewInStorageReason — щоб споживач JSON бачив, ЧОМУ NewInStorage=$true):
        #  'imprint-ahead' — диск не змінювався після читання sync, і версія того звіту більша за
        #                    дзеркало: факт, не здогад, тому текст НЕ каже «ймовірно»;
        #  'unclear'       — шлях доступний, але не схожий на сховище 1С: підтвердити «синхронне»
        #                    не можемо, а тиша тут гірша за шум;
        #  'no-mirror'     — дзеркала ще немає при доступному сховищі;
        #  'newer'         — mtime data/objects новіший за дзеркало (з допуском);
        #  'packed-newer'  — усе запаковано, а data/pack новіший: дешева перевірка сказати не може
        #                    — теж код 4, не тиша й не 1.
        $newInStorage = $false; $newInStorageReason = $null
        if ($imprintCurrent) {
            if ($imprint.Version -gt $lastVersion) { $newInStorage = $true; $newInStorageReason = 'imprint-ahead' }
        } elseif ($activity.Accessible -and -not $gitProblem) {
            if (-not $activity.IsStorage) {
                $newInStorage = $true; $newInStorageReason = 'unclear'
            } elseif (-not $mirror) {
                $newInStorage = $true; $newInStorageReason = 'no-mirror'
            } elseif ($null -ne $activity.LatestObjectWrite -and $null -ne $lastMirror -and $activity.LatestObjectWrite -gt $lastMirror.Add($script:StorageMirrorTolerance)) {
                $newInStorage = $true; $newInStorageReason = 'newer'
            } elseif ($null -ne $activity.LatestPackWrite -and $null -ne $lastMirror -and $activity.LatestPackWrite -gt $lastMirror.Add($script:StorageMirrorTolerance)) {
                $newInStorage = $true; $newInStorageReason = 'packed-newer'
            }
        }
        # «Дзеркало є, головної гілки немає» — не «не знаю» (1), а 3: незлиті коміти — УСІ коміти дзеркала, і дія
        # відома. sync сам породжує цей стан на свіжому репозиторії (перше злиття пропущено).
        # Розрізнювач: unborn main (свіжий репо) → «зробіть перший коміт»; HEAD деінде → «перевірте mainBranch:».
        $unmerged = 0; $mainMissing = $false
        if ($mirror -and -not $gitProblem) {
            $range = if ($mainExists) { "$main..$($src.Branch)" } else { $mainMissing = $true; $src.Branch }
            $countRaw = (git -C $root rev-list --count $range 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $countRaw -notmatch '^\d+$') { $gitProblem = "git rev-list $range не відповів" }
            else { $unmerged = [int]$countRaw }
        }

        # Текст — з незалежних частин, не з ексклюзивних if/elseif: стан сховища, стан дзеркала й
        # незлиті коміти — три РІЗНІ питання, що можуть бути правдою одночасно. Єдиний виняток —
        # gitProblem: коли стан git не прочитано, решті обчисленого довіряти не можна.
        $srcStep = $null
        $text = if ($gitProblem) {
            $srcStep = 'kit check'
            "- $($src.Key): стан git не прочитано ($gitProblem) — сигнал недоступний; розбір: kit check."
        } else {
            $parts = [System.Collections.Generic.List[string]]::new()

            if ($imprintCurrent) {
                # Точна відповідь замість здогадки: диск не змінювався з моменту, коли sync
                # його читав, тож версія з того читання — факт, не оцінка mtime. Текст завжди називає
                # версію й момент читання — і коли дзеркало вже на ній (код 0), і коли позаду (код 4) —
                # і НІКОЛИ не каже «ймовірно»: це не той самий сигнал, що евристики нижче.
                if ($newInStorageReason -eq 'imprint-ahead') {
                    $parts.Add(("за відбитком сховище було на версії {0} станом на {1:yyyy-MM-dd HH:mm:ss} UTC, дзеркало на версії {2} — оновити: kit sync -Source {3} -Apply" -f $imprint.Version, $imprint.ReadAtUtc, $lastVersion, $src.Key))
                    $srcStep = "kit sync -Source $($src.Key) -Apply"
                } else {
                    $parts.Add(("дзеркало синхронне зі сховищем на версії {0} (відбиток прочитано {1:yyyy-MM-dd HH:mm:ss} UTC)" -f $imprint.Version, $imprint.ReadAtUtc))
                }
            } else {
                if (-not $activity.Accessible) {
                    $parts.Add("сховище недоступне на цій машині ($($activity.Reason)) — перевизначте шлях у v8storagekit.local.yaml (storages:)")
                } elseif ($newInStorageReason -eq 'unclear') {
                    # Мовчати тут — хибний all-clear на завідомо неправильному шляху, гірший за будь-який
                    # шум: людина припиняє шукати причину.
                    $parts.Add("шлях сховища доступний, але не схожий на сховище 1С ($($activity.Reason)) — перевірте storages: $($src.Key) у v8storagekit.local.yaml (чи сам шлях у v8storagekit.yaml)")
                }

                if (-not $mirror) {
                    $parts.Add("дзеркала storage/$($src.Key) ще немає — перший реплей: kit sync -Source $($src.Key) -Apply")
                    $srcStep = "kit sync -Source $($src.Key) -Apply"
                } elseif ($newInStorageReason -eq 'newer') {
                    $parts.Add(("у сховищі ймовірно нові версії (запис {0:yyyy-MM-dd HH:mm:ss} UTC після дзеркала {1:yyyy-MM-dd HH:mm:ss} UTC) — оновити? kit sync -Source {2} -Apply" -f $activity.LatestObjectWrite, $lastMirror, $src.Key))
                    $srcStep = "kit sync -Source $($src.Key) -Apply"
                } elseif ($newInStorageReason -eq 'packed-newer') {
                    # Дешева перевірка чесно каже «не знаю»; дія — kit sync БЕЗ
                    # -Apply: прочитає звіт і залишить точний відбиток на майбутнє.
                    $parts.Add(("усі об'єкти запаковані після останнього дзеркала ({0:yyyy-MM-dd HH:mm:ss} UTC) — чи є нові версії, дешева перевірка сказати не може; точну відповідь дає kit sync -Source {1} без -Apply" -f $lastMirror, $src.Key))
                    $srcStep = "kit sync -Source $($src.Key)"
                }
            }

            # Незлиті коміти — НЕЗАЛЕЖНО від доступності сховища.
            if ($unmerged -gt 0) {
                if ($mainMissing) {
                    if (Test-KitBranchUnborn -RepoRoot $root -Branch $main) {
                        $parts.Add("на $($src.Branch) є $unmerged коміт(и), а головної гілки '$main' ще немає — зробіть перший коміт у '$main', потім kit sync -Source $($src.Key) -Apply -MergeMain")
                        if ($null -eq $srcStep) { $srcStep = "kit sync -Source $($src.Key) -Apply -MergeMain" }
                    } else {
                        $parts.Add("на $($src.Branch) є $unmerged коміт(и), а гілки '$main' з маніфесту немає — перевірте mainBranch: (описка?)")
                    }
                } else {
                    $parts.Add("на $($src.Branch) є $unmerged коміт(и), не злиті в $main — звірочний коміт: kit verify -Apply")
                    if ($null -eq $srcStep) { $srcStep = 'kit verify -Apply' }
                }
            }

            if ($parts.Count -eq 0) { $parts.Add("дзеркало синхронне зі сховищем, $main містить усе") }
            "- $($src.Key): " + ($parts -join '; ') + '.'
        }

        $stepOf[$src.Key] = $srcStep
        $signals.Add([pscustomobject]@{
            Key = $src.Key; Branch = $src.Branch; MirrorExists = $mirror; LastMirrorDate = $lastMirror
            StorageWrite = $activity.LatestObjectWrite; NewInStorage = $newInStorage; NewInStorageReason = $newInStorageReason
            UnmergedCommits = $unmerged; Accessible = $activity.Accessible; GitProblem = $gitProblem; Text = $text
            OriginGap = $originGap
        })
    }

    if ($AsJson) {
        # Через Write-Host, не Write-Output: success stream забирає диспетчер і не друкує.
        Write-Host (ConvertTo-Json -InputObject $signals.ToArray() -Depth 4)
    } else {
        Write-Host "session-check — $($Context.Kind) $($Context.Label)"
        foreach ($m in $machineErrors) { Write-Host "[-] $($m.Message)" -ForegroundColor Red }
        foreach ($i in $checkInfos) { Write-Host "[i] $($i.Message)" -ForegroundColor Gray }
        foreach ($w in $checkWarns) { Write-Host "[!] $($w.Message)" -ForegroundColor Yellow }   # warn/info не міняють коду: його визначають сигнали
        if ($signals.Count -eq 0) { Write-Host '- джерел truth: storage у маніфесті немає.' }
        foreach ($s in $signals) {
            Write-Host $s.Text
            if ($stepOf[$s.Key]) { Register-KitNextStep -Step $stepOf[$s.Key] }
            # Відставання від origin — окремим рядком лише в людському виводі; у -AsJson це
            # поле OriginGap сигналу, не текст.
            if ($null -ne $s.OriginGap -and $s.OriginGap.HasRemote -and $s.OriginGap.Behind -gt 0) {
                Write-Host ("- {0}: локальна гілка {1} позаду origin на {2} комітів — git fetch" -f `
                    $s.Key, $s.Branch, $s.OriginGap.Behind) -ForegroundColor Yellow
            }
        }
        Write-KitNextStepLine
    }
    # Коди за змістом, пріоритет: 1 — хоч одне джерело зі станом git, який не прочитано (той самий
    # клас, що зупинка check); інакше 4 — хоч один сигнал дії (нові версії, дзеркала немає, шлях не схожий
    # на сховище, незлиті коміти — і коли головної гілки немає); інакше 0. «Сховище недоступне» — стан
    # машини, 0 з рядком. Винятку немає навмисно: хук на код 1 сам ставить позначку «стан НЕВІДОМИЙ».
    $exit = if (@($signals | Where-Object { $_.GitProblem }).Count) { 1 }
            elseif (@($signals | Where-Object { $_.NewInStorage -or $_.UnmergedCommits -gt 0 }).Count) { 4 }
            else { 0 }
    [pscustomobject]@{ ExitCode = $exit; CheckFindings = $checkFindings; Signals = $signals.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSessionCheck
