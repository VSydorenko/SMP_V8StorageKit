#Requires -Version 7
Set-StrictMode -Version Latest

# Lib-модулі вже імпортував kit.ps1 (module-order.txt); тут — лише оркестрація.

# Спайк Task 1 (спека §14, «Результат спайку»): чи потребує UpdateCfg для ОСНОВНОЇ конфігурації
# прив'язки ІБ до сховища. $false — шлях (1) працює без прив'язки; $true — kit робить
# ConfigurationRepositoryBindCfg під користувачем сховища на час реплею й знімає її
# ConfigurationRepositoryUnbindCfg -force у finally — єдиний запис у сховище, який kit виконує.
$script:ConfigurationStorageNeedsBind = $false

function Get-KitRepositoryArguments {
    param([Parameter(Mandatory)]$Source)
    # Кома навмисно: викликачі роблять (Get-KitRepositoryArguments …) + @(…), НЕ @(…) — див. F7.
    # Task 2a: третій аргумент бере пароль зі resolved source (маніфест + накладка, Preflight.psm1) —
    # ніколи не порожній рядок-заглушку. Пароль ніде не друкується: Invoke-V8Designer формує з цього
    # рядка командний рядок платформи і сам маскує /ConfigurationRepositoryP у Write-Verbose
    # (Hide-V8Secrets, V8.psm1); текст жодної зупинки тут пароля не читає.
    , @(
        '/ConfigurationRepositoryF "{0}"' -f $Source.StoragePath
        '/ConfigurationRepositoryN "{0}"' -f $Source.StorageUser
        '/ConfigurationRepositoryP "{0}"' -f $Source.StoragePassword
    )
}

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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [int]$MaxVersions = 0,
        [switch]$MergeMain
    )

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
    $stubPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/empty-extension'))
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

        # Навмисно без try/catch: вершина storage/* без числового Storage-Version — це порушення інваріанту
        # (§3.2), і виняток із текстом «гілку писав не sync. Розбір: kit check» І Є штатною зупинкою sync.
        # Загортати його в інше повідомлення чи вгадувати стан — не можна.
        $last = Get-KitStorageBranchLastVersion -RepoRoot $root -Branch $src.Branch
        Write-Host ('Дзеркало:   ' + $(if ($null -eq $last) { 'гілки ще немає — реплей усіх версій зі звіту' } else { "версія $last" }))

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

        Write-Host 'Створюю тимчасову ІБ і читаю історію сховища...'
        $extName = ''
        if ($src.Type -eq 'EXTENSION') {
            $extName  = $src.Key
            $ibSwitch = New-ExtensionInfobase -Path (Join-Path $workDir 'ib') -ExtensionName $extName -StubPath $stubPath -MustBeUnder $workDir
        } else {
            $ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $workDir 'ib') -MustBeUnder $workDir)
        }
        $extArg = if ($extName) { " -Extension $extName" } else { '' }

        $all = Get-StorageVersions -IbSwitch $ibSwitch -StoragePath $src.StoragePath -ExtensionName $extName -StorageUser $src.StorageUser -StoragePassword $src.StoragePassword -WorkDir $workDir
        $maxVersion = if ($all.Count -gt 0) { ($all | Measure-Object -Property Version -Maximum).Maximum } else { 'немає' }
        Write-Host "У сховищі версій: $($all.Count), максимальна: $maxVersion"

        $pending = Get-KitPendingVersions -AllVersions $all -LastVersion $last -MaxVersions $MaxVersions
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

        $wt   = New-KitStorageWorktree -RepoRoot $root -Branch $src.Branch -Path (Join-Path $workDir 'wt')
        $done = [System.Collections.Generic.List[int]]::new()
        $bound = $false
        try {
            if ($src.Type -eq 'CONFIGURATION' -and $script:ConfigurationStorageNeedsBind) {
                # Документований виняток із «сховища — тільки читання» (спека §14): прив'язка під gitbot,
                # знімається у finally нижче незалежно від результату реплею.
                $bind = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @('/ConfigurationRepositoryBindCfg -forceBindAlreadyBindedUser -forceReplaceCfg'))
                if ($bind.ExitCode -ne 0) { throw "Прив'язка тимчасової ІБ до сховища конфігурації не вдалася: $($bind.Output)" }
                $bound = $true
            }

            foreach ($v in $pending) {
                $author = Resolve-Author -Map $authors -StorageUser $v.User
                Write-Host "→ версія $($v.Version) ($($author.Name), $($v.Date))"

                $upd = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @(
                    ('/ConfigurationRepositoryUpdateCfg -v {0}{1} -force' -f $v.Version, $extArg)))
                if ($upd.ExitCode -ne 0) { throw "Оновлення до версії $($v.Version) не вдалося: $($upd.Output)" }

                $target = Clear-KitWorktreeSource -WorktreePath $wt.Path -RepoPath $src.RepoPath
                $dump = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $target, $extArg))
                if ($dump.ExitCode -ne 0) { throw "Вивантаження версії $($v.Version) не вдалося: $($dump.Output)" }

                $message = New-KitStorageCommitMessage -Version $v -SourceKey $src.Key -SourceType $src.Type
                $commit  = Write-KitStorageVersion -WorktreePath $wt.Path -RepoPath $src.RepoPath -Message $message `
                    -AuthorName $author.Name -AuthorEmail $author.Email -Timestamp $v.Timestamp
                if ($commit.Empty) { Write-Host '  (без змін у джерелах — коміт лише фіксує запис версії сховища)' -ForegroundColor DarkGray }
                $done.Add($v.Version)
            }
        } finally {
            if ($bound) {
                $unbind = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments ((Get-KitRepositoryArguments -Source $src) + @('/ConfigurationRepositoryUnbindCfg -force'))
                if ($unbind.ExitCode -ne 0) { Write-Host "УВАГА: не вдалося зняти прив'язку тимчасової ІБ до сховища: $($unbind.Output)" -ForegroundColor Red }
            }
            Remove-KitStorageWorktree -RepoRoot $root -Path $wt.Path
        }
        Write-Host ("Перенесено версій: {0} → {1}" -f $done.Count, $src.Branch) -ForegroundColor Green

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
