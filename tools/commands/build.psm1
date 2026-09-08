#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Get-KitEpfDescriptors {
    <#
    .SYNOPSIS
        Кожна обробка — <Name>.xml поруч із текою <Name> у source-set EXTERNAL_DATA_PROCESSORS.
    .DESCRIPTION
        Дискримінатор — тип source-set (EXTERNAL_DATA_PROCESSORS), не ім'я теки: закриває
        docs/follow-ups.md §7 (обробки шукались за жорстко вшитим іменем теки 'epf' і мовчки
        випадали зі збірки в репозиторії, де тека зветься інакше). $Source сюди приходить уже
        відфільтрованим за типом викликачем (Invoke-KitBuild) — ця функція сама тип не питає.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source)
    # Кома навмисно: викликач робить foreach ($d in (Get-KitEpfDescriptors …)) — (…), НЕ @(…) — див. F7.
    if (-not (Test-Path -LiteralPath $Source.FullPath)) { return , @() }
    , @(Get-ChildItem -LiteralPath $Source.FullPath -Filter '*.xml' -File | Sort-Object Name | ForEach-Object {   # кома навмисно (F7)
        [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName } })
}

function Copy-KitWorkspaceArtifacts {
    <#
    .SYNOPSIS
        Запасний шлях Q6: якщо Unica відмовила в output поза воркспейсом, make поклав .cf/.cfe у
        <воркспейс>/build/artifacts — забираємо їх у кореневу теку артефактів.
    .DESCRIPTION
        Рішення виконавця (задокументовано в task-3-report.md, питання 1 брифа) — приймає
        ГОТОВИЙ перелік воркспейсів, а не весь $Context.Workspaces. У початковому вигляді
        функція обходила ВСІ воркспейси контексту незалежно від того, що саме відібрали
        -Workspace/-Source: "kit build -Workspace Alpha -Apply" збирав би в build/artifacts
        кореня і залишки з build/artifacts сусіднього воркспейсу Beta, з яким цей виклик
        узагалі не мав діла (лишок від попереднього build, чи й від зовсім іншої гілки
        роботи). Це суперечить тому, як -Workspace/-Source звужує кожну іншу команду kit
        (Select-KitSources, і сам build — $epfSources/$extSources у Invoke-KitBuild уже
        відфільтровані), і мовчки підмішує в артефакти те, чого користувач не просив. Викликач
        (Invoke-KitBuild) тепер сам звужує список воркспейсів до тих, чиї джерела реально
        потрапили у $selected, і передає сюди вже звужений перелік.

        Фікс-раунд рев'ю, C1 — фільтр розширень тут ЛИШЕ '.cf'/'.cfe', не '.epf'/'.erf'.
        Цю функцію Invoke-KitBuild кличе ПІСЛЯ циклу, що сам щойно збудував свіжі .epf у тому
        самому $Destination (через платформу), з тим самим Copy-Item -Force. Коли сюди раніше
        потрапляли й .epf/.erf, стара копія з <воркспейс>/build/artifacts (залишок минулого
        build чи чужого operation=make під тією самою назвою) мовчки перезаписувала ЩОЙНО
        зібраний файл — вивід при цьому казав "← зібрано з воркспейсу", що читалось як успіх, а
        $Artifacts діставав той самий шлях удруге. Запасний шлях Q6 (SYNOPSIS вище) існує
        рівно для того, чого build САМ не робить — .cf/.cfe, які кладе operation=make Уніки.
        .epf/.erf build робить сам і зобов'язаний довіряти лише щойно зібраному, не тому, що
        колись лежало у воркспейсі — тому вони прибрані з цього фільтра, не позначені як
        "не перезаписувати той самий шлях": другий підхід тримав би зайву відповідальність
        (пам'ятати, які шляхи вже зайняті цим прогоном), тоді як перший унеможливлює саму
        колізію.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workspaces, [Parameter(Mandatory)][string]$Destination)
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($ws in $Workspaces) {
        $dir = Join-Path $ws.FullPath $ws.Project.WorkPath 'artifacts'
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in @('.cf', '.cfe') }) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Destination $f.Name) -Force
            $copied.Add((Join-Path $Destination $f.Name))
        }
    }
    # Кома навмисно: викликач робить foreach ($c in (Copy-KitWorkspaceArtifacts …)) — (…), НЕ @(…) — див. F7.
    , $copied.ToArray()
}

function Invoke-KitBuild {
    <#
    .SYNOPSIS
        .epf через платформу (/LoadExternalDataProcessorOrReportFromFiles) у build/artifacts, збір .cf/.cfe,
        які operation=make Уніки поклала в артефакти воркспейсів, і вміст теки на екран (спека §5).
    .DESCRIPTION
        .cf/.cfe kit САМ не збирає — це робить operation=make Уніки; build лише друкує, як саме
        її покликати (output=<корінь>/build/artifacts/<Ім'я>.cfe), і забирає звідти, куди make
        могла покласти файл замість цього (запасний шлях Q6 — <воркспейс>/build/artifacts/).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

    $root   = $Context.RepoRoot
    $outDir = Join-Path $root 'build/artifacts'
    $selected = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
    $epfSources = @($selected | Where-Object Type -eq 'EXTERNAL_DATA_PROCESSORS')
    # truth: vendor виключено (фікс-раунд рев'ю, C4) — той самий принцип, що canon.psm1 уже
    # застосовує до своїх targets: чужу конфігурацію не збирають у власні артефакти, і радити
    # для неї operation=make було б порадою зібрати те, що нам не належить.
    $extSources = @($selected | Where-Object { $_.Type -eq 'EXTENSION' -and $_.Truth -ne 'vendor' })

    Write-Host "Артефакти: $outDir"
    $plan = @(foreach ($s in $epfSources) { foreach ($d in (Get-KitEpfDescriptors -Source $s)) { [pscustomobject]@{ Source = $s; Descriptor = $d } } })
    foreach ($p in $plan) { Write-Host "  .epf  $($p.Descriptor.Name).epf  ← $($p.Source.RepoPath)" }
    foreach ($e in $extSources) {
        Write-Host "  .cfe  $($e.Key).cfe — не kit: operation=make Уніки (cwd $($e.Workspace), source-set $($e.Key)) з output=$outDir\$($e.Key).cfe" -ForegroundColor DarkGray
    }
    if ($plan.Count -eq 0 -and $extSources.Count -eq 0) { Write-Host '  Джерел для збірки в цьому виборі немає.' }

    if (-not $Apply) {
        Write-Host 'Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
        return [pscustomobject]@{ ExitCode = 0; Artifacts = @() }
    }

    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $artifacts = [System.Collections.Generic.List[string]]::new()

    if ($plan.Count -gt 0) {
        # Шлях і межа — літерали від $root (спільні для будь-якого вибору -Workspace/-Source, не
        # з v8project.yaml чи накладки): нема поля конфігурації, описка в якому підмінила б цей
        # шлях (питання 2 брифа, task-3-report.md). Тимчасова ІБ спільна на всі .epf цього
        # прогону — платформі байдуже, з якого воркспейсу файл, /LoadExternalDataProcessorOrReportFromFiles
        # не прив'язаний до конфігурації бази.
        $ibSwitch = '/F "{0}"' -f (New-V8FileInfobase -Path (Join-Path $root 'build/build-ib') -MustBeUnder (Join-Path $root 'build'))
        foreach ($p in $plan) {
            $target = Join-Path $outDir "$($p.Descriptor.Name).epf"
            Write-Host "→ $($p.Descriptor.Name).epf"
            $r = Invoke-V8Designer -IbSwitch $ibSwitch -Arguments @(
                '/LoadExternalDataProcessorOrReportFromFiles "{0}" "{1}"' -f $p.Descriptor.Path, $target)
            if ($r.ExitCode -ne 0) { throw "Збірка $($p.Descriptor.Name) не вдалася: $($r.Output)" }
            $artifacts.Add($target)
        }
    }

    # Питання 1 брифа (task-3-report.md): збираємо лише з воркспейсів, чиї джерела реально
    # потрапили у цей вибір ($selected), а не з усіх воркспейсів контексту — інакше
    # "-Workspace Alpha" підмішував би артефакти сусіднього Beta. Без жодного фільтра
    # (-Workspace/-Source не задані) $selected покриває всі воркспейси — той самий ефект, що
    # й раніше, коли обходили $Context.Workspaces напряму.
    $targetWorkspacePaths = @($selected | ForEach-Object { $_.Workspace } | Sort-Object -Unique)
    $targetWorkspaces = @($Context.Workspaces | Where-Object { $targetWorkspacePaths -contains $_.Path })
    foreach ($c in (Copy-KitWorkspaceArtifacts -Workspaces $targetWorkspaces -Destination $outDir)) {
        Write-Host "← зібрано з воркспейсу: $(Split-Path -Leaf $c)"
        $artifacts.Add($c)
    }

    Write-Host ''
    $files = @(Get-ChildItem -LiteralPath $outDir -File)
    if ($files.Count -eq 0) {
        Write-Host "У $outDir порожньо. .cf/.cfe збирає operation=make Уніки з output=$outDir\<Ім'я>.cfe; .epf — з source-set EXTERNAL_DATA_PROCESSORS." -ForegroundColor Yellow
    } else {
        $files | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
    }
    [pscustomobject]@{ ExitCode = 0; Artifacts = $artifacts.ToArray() }
}

Export-ModuleMember -Function Invoke-KitBuild, Get-KitEpfDescriptors, Copy-KitWorkspaceArtifacts
