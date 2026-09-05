#Requires -Version 7
Set-StrictMode -Version Latest

# Спека §5: «повний check викликається явно і в session-check». Диспетчер імпортує лише запитаний командний
# модуль, тому check підключається тут (без -Force — не перезавантажувати вже наявний).
Import-Module "$PSScriptRoot/check.psm1"

# Допуск порівняння mtime сховища з датою коміту дзеркала (рев'ю раунд 2, I3): sync стемпить
# GIT_AUTHOR_DATE/GIT_COMMITTER_DATE як yyyy-MM-ddTHH:mm:ss — цілими секундами, а
# LatestObjectWrite (mtime файлу) має частку секунди. Без допуску запис, зроблений тим самим
# sync, завжди «новіший» за власний коміт на частку секунди — вічний хибний сигнал, який
# нічим не гаситься (kit sync нових версій не знайде, дата дзеркала не зрушить). Допуск
# навмисно малий (5 с): він має поглинати лише зрізання до цілих секунд і дрібний дрейф
# годинників, не більше. Великий допуск (хвилина й більше) дав би протилежний дефект — версія,
# записана невдовзі після sync, не дала б сигналу НІКОЛИ, бо дата дзеркала вже не зрушить.
$script:StorageMirrorTolerance = [timespan]::FromSeconds(5)

function Invoke-KitSessionCheck {
    <#
    .SYNOPSIS
        Дешевий сигнал для старту сесії (спека §5, §7): без платформи, без ліцензії, один обхід
        каталогу на джерело. Спершу — повний check (-Quiet) тим самим контекстом: error → код 1 і сигнали
        не обчислюються (на storage/* з чужим комітом дата дзеркала нічого не означає — одне правило замість
        таблиці «які помилки ще дозволяють сигнали»); лише warn → [!]-рядки над сигналами, плюс [i] для знахідок
        із білого списку (main-branch — info-половина дворівневої знахідки). Нічого не змінює.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$AsJson
    )

    $root = $Context.RepoRoot
    $main = $Context.MainBranch
    $signals = [System.Collections.Generic.List[object]]::new()

    # --- Повний check першим (спека §5). Виняток із check — теж «репозиторій суперечливий», код 1.
    $checkFindings = @()
    try {
        $checkFindings = @((Invoke-KitCheck -Context $Context -Workspace $Workspace -Source $Source -Quiet).Findings)
    } catch {
        $checkFindings = @(New-KitFinding -Level error -Check 'check' -Message "check не відпрацював: $($_.Exception.Message)")
    }
    $checkErrors = @($checkFindings | Where-Object Level -eq 'error')
    # Недоступне сховище описує сигнал джерела (з порадою про накладку) — check-рядок про той самий шлях опускаємо.
    $checkWarns  = @($checkFindings | Where-Object { $_.Level -eq 'warn' -and $_.Check -ne 'storage-path' })
    # info друкуємо лише з білого списку: check дає info на кожному прогоні (рядок-зведення «Маніфест: …»), і
    # пускати всі означало б шум на кожному старті сесії. main-branch — інша річ: це info-половина дворівневої
    # знахідки Step 2 («свіжий репозиторій: гілку створить перший коміт»), без неї розрізнювач мертвий.
    $checkInfos  = @($checkFindings | Where-Object { $_.Level -eq 'info' -and $_.Check -in @('main-branch') })

    if ($checkErrors.Count -gt 0) {
        if ($AsJson) {
            # Одна форма верхнього рівня для -AsJson в ОБОХ гілках (рев'ю раунд 2, I4): масив
            # сигналів, як і на щасливому шляху нижче. Тут сигнали не обчислювались — масив
            # порожній; категорію «check упав, сигналам не вірити» споживач читає з коду
            # виходу (1), не з форми JSON. Причина вибору саме масиву, а не обгортки
            # {CheckErrors;Signals}: наявний тест на -AsJson (щасливий шлях) уже читає
            # відповідь як масив сигналів напряму (@($json)[0].Key) — обгортка зламала б
            # цей контракт, а не лише розбіжність між гілками.
            Write-Host (ConvertTo-Json -InputObject @() -Depth 4)
        } else {
            Write-Host "session-check — $($Context.Kind) $($Context.Label)"
            foreach ($e in $checkErrors) { Write-Host "[-] $($e.Message)" -ForegroundColor Red }
            Write-Host 'Сигнали не обчислювались: репозиторій суперечливий — спершу kit check.' -ForegroundColor Red
        }
        return [pscustomobject]@{ ExitCode = 1; CheckFindings = $checkFindings; Signals = @() }
    }

    $mainExists = Test-KitBranchExists -RepoRoot $root -Branch $main

    foreach ($src in @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth storage)) {
        $mirror = Test-KitBranchExists -RepoRoot $root -Branch $src.Branch
        # Хук старту сесії: збій git тут — деградація до рядка «стан не прочитано», НЕ виняток (рев'ю B3).
        $lastMirror = $null; $gitProblem = $null
        if ($mirror) {
            $iso = (git -C $root log -1 --format=%aI $src.Branch 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $iso) { $gitProblem = "git log $($src.Branch) не відповів" }
            else { $lastMirror = ([datetimeoffset]$iso).UtcDateTime }
        }
        $activity = Get-KitStorageActivity -StoragePath $src.StoragePath

        # Три причини «є що робити», а не одна (рев'ю раунд 2, I2/I3): 'unclear' — шлях
        # доступний, але не схожий на сховище (немає data/objects або вона порожня) — не
        # можемо підтвердити «синхронне», тиша тут гірша за шум (I2); 'no-mirror' —
        # дзеркала ще немає при доступному сховищі, порівнювати нема з чим, але контракт
        # («дзеркала немає при доступному сховищі → 3») однаковий незалежно від того, чи є
        # вже версії; 'newer' — справжнє порівняння дат, із допуском StorageMirrorTolerance.
        # NewInStorageReason у сигналі — щоб споживач JSON (не лише текст) бачив, ЧОМУ
        # NewInStorage=$true, а не читав це завжди як «є нові версії» (рев'ю раунд 2, дрібна
        # правка про рядок 71): для 'no-mirror'/'unclear' порівнювати справді нема з чим.
        $newInStorage = $false; $newInStorageReason = $null
        if ($activity.Accessible -and -not $gitProblem) {
            if (-not $activity.LatestObjectWrite) {
                $newInStorage = $true; $newInStorageReason = 'unclear'
            } elseif (-not $mirror) {
                $newInStorage = $true; $newInStorageReason = 'no-mirror'
            } elseif ($null -ne $lastMirror -and $activity.LatestObjectWrite -gt $lastMirror.Add($script:StorageMirrorTolerance)) {
                $newInStorage = $true; $newInStorageReason = 'newer'
            }
        }
        # «Дзеркало є, головної гілки немає» — не «не знаю» (1), а 3: незлиті коміти — УСІ коміти дзеркала, і дія
        # відома (спека a7a5d45). sync у B2 сам породжує цей стан на свіжому репозиторії (перше злиття пропущено).
        # Розрізнювач: unborn main (свіжий репо) → «зробіть перший коміт»; HEAD деінде → «перевірте mainBranch:».
        $unmerged = 0; $mainMissing = $false
        if ($mirror -and -not $gitProblem) {
            $range = if ($mainExists) { "$main..$($src.Branch)" } else { $mainMissing = $true; $src.Branch }
            $countRaw = (git -C $root rev-list --count $range 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $countRaw -notmatch '^\d+$') { $gitProblem = "git rev-list $range не відповів" }
            else { $unmerged = [int]$countRaw }
        }

        # Текст будується з незалежних частин, не з ексклюзивних if/elseif-гілок (рев'ю раунд 2,
        # I1/I2): «недоступне»/«не схоже на сховище», «дзеркала немає»/«нові версії» та «незлиті
        # коміти» — три РІЗНІ питання, і кожне з них може бути правдою одночасно з іншими
        # (наприклад, сховище недоступне, А на дзеркалі вже є незлитий коміт — I1). Єдиний
        # виняток — gitProblem: коли стан git не прочитано, довіряти решті обчисленого не можна.
        $text = if ($gitProblem) {
            "- $($src.Key): стан git не прочитано ($gitProblem) — сигнал недоступний; розбір: kit check."
        } else {
            $parts = [System.Collections.Generic.List[string]]::new()

            if (-not $activity.Accessible) {
                $parts.Add("сховище недоступне на цій машині ($($activity.Reason)) — перевизначте шлях у v8storagekit.local.yaml (storages:)")
            } elseif ($newInStorageReason -eq 'unclear') {
                # I2, сценарій A/B: шлях доступний, але не схожий на сховище 1С. Мовчати тут
                # (як робила стара «else»-гілка «синхронне») — хибний all-clear на завідомо
                # неправильному шляху, гірший за будь-який шум: людина припиняє шукати причину.
                $parts.Add("шлях сховища доступний, але не схожий на сховище 1С ($($activity.Reason)) — перевірте storages: $($src.Key) у v8storagekit.local.yaml (чи сам шлях у v8storagekit.yaml)")
            }

            if (-not $mirror) {
                $parts.Add("дзеркала storage/$($src.Key) ще немає — перший реплей: kit sync -Source $($src.Key) -Apply")
            } elseif ($newInStorageReason -eq 'newer') {
                $parts.Add(("у сховищі ймовірно нові версії (запис {0:yyyy-MM-dd HH:mm:ss} UTC після дзеркала {1:yyyy-MM-dd HH:mm:ss} UTC) — оновити? kit sync -Source {2} -Apply" -f $activity.LatestObjectWrite, $lastMirror, $src.Key))
            }

            # I1: незлиті коміти рахуються й відображаються НЕЗАЛЕЖНО від доступності сховища —
            # раніше цей блок жив лише в «else»-гілці, куди недоступне сховище не потрапляло.
            if ($unmerged -gt 0) {
                if ($mainMissing) {
                    if (Test-KitBranchUnborn -RepoRoot $root -Branch $main) {
                        $parts.Add("на $($src.Branch) є $unmerged коміт(и), а головної гілки '$main' ще немає — зробіть перший коміт у '$main', потім kit sync -Source $($src.Key) -Apply -MergeMain")
                    } else {
                        $parts.Add("на $($src.Branch) є $unmerged коміт(и), а гілки '$main' з маніфесту немає — перевірте mainBranch: (описка?)")
                    }
                } else {
                    $parts.Add("на $($src.Branch) є $unmerged коміт(и), не злиті в $main — звірочний коміт: kit verify -Apply")
                }
            }

            if ($parts.Count -eq 0) { $parts.Add("дзеркало синхронне зі сховищем, $main містить усе") }
            "- $($src.Key): " + ($parts -join '; ') + '.'
        }

        $signals.Add([pscustomobject]@{
            Key = $src.Key; Branch = $src.Branch; MirrorExists = $mirror; LastMirrorDate = $lastMirror
            StorageWrite = $activity.LatestObjectWrite; NewInStorage = $newInStorage; NewInStorageReason = $newInStorageReason
            UnmergedCommits = $unmerged; Accessible = $activity.Accessible; GitProblem = $gitProblem; Text = $text
        })
    }

    if ($AsJson) {
        # Через Write-Host, не Write-Output: success stream забирає диспетчер і не друкує (контракт F12).
        Write-Host (ConvertTo-Json -InputObject $signals.ToArray() -Depth 4)
    } else {
        Write-Host "session-check — $($Context.Kind) $($Context.Label)"
        foreach ($i in $checkInfos) { Write-Host "[i] $($i.Message)" -ForegroundColor Gray }
        foreach ($w in $checkWarns) { Write-Host "[!] $($w.Message)" -ForegroundColor Yellow }   # warn/info не міняють коду: його визначають сигнали
        if ($signals.Count -eq 0) { Write-Host '- джерел truth: storage у маніфесті немає.' }
        foreach ($s in $signals) { Write-Host $s.Text }
    }
    # Коди за змістом (спека §5, f4307df), пріоритет: 1 — хоч одне джерело зі станом git, який не прочитано
    # (наявна гілка, а log/rev-list не відповіли) — репозиторій, той самий клас, що зупинка check; інакше
    # 3 — хоч один сигнал дії (нові версії, дзеркала немає при доступному сховищі, шлях не схожий на
    # сховище, незлиті коміти, У ТОМУ ЧИСЛІ коли головної гілки немає) — те саме, що storage-ahead у
    # verify, лише дешево; інакше 0. «Сховище недоступне» — стан машини, 0 з рядком (якщо на ньому немає
    # ще й незлитих комітів — I1). Винятку немає навмисно: хук на код 1 сам ставить позначку «стан
    # НЕВІДОМИЙ» (§7).
    $exit = if (@($signals | Where-Object { $_.GitProblem }).Count) { 1 }
            elseif (@($signals | Where-Object { $_.NewInStorage -or $_.UnmergedCommits -gt 0 }).Count) { 3 }
            else { 0 }
    [pscustomobject]@{ ExitCode = $exit; CheckFindings = $checkFindings; Signals = $signals.ToArray() }
}

Export-ModuleMember -Function Invoke-KitSessionCheck
