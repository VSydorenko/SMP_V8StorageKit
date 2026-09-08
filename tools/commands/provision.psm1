#Requires -Version 7
Set-StrictMode -Version Latest

# Командний модуль нічого не імпортує сам: lib-модулі вже завантажив kit.ps1 у порядку
# module-order.txt, і вкладений Import-Module тут лише ризикував би перезавантаженням
# (docs/follow-ups.md §5, коментар у StorageReport.psm1).

function Invoke-KitProvision {
    <#
    .SYNOPSIS
        База агента (спека §4): порожня файлова або з .dt (CREATEINFOBASE /UseTemplate). Її можна
        знести й розгорнути знову будь-коли (-Force). Далі — operation=build Уніки.
    .PARAMETER Template
        Файл .dt; без нього береться workspaces.<ws>.agentBase.template з накладки; без обох — порожня база.
    .PARAMETER Remember
        Записати -Template у v8storagekit.local.yaml (те, що робить скіл provision після питання).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [switch]$Force,
        [string]$Template,
        [switch]$Remember
    )

    if ($Remember -and -not $Template) { throw 'Параметр -Remember потребує -Template <файл.dt>: нема що записувати в накладку.' }
    $workspaces = @($Context.Workspaces)
    if ($Workspace) {
        $workspaces = @($workspaces | Where-Object Path -eq $Workspace)
        if ($workspaces.Count -eq 0) { throw "Воркспейсу '$Workspace' немає в маніфесті. Є: $($Context.Workspaces.Path -join ', ')." }
    }
    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $Context.RepoRoot 'v8storagekit.local.yaml' }
    $done = [System.Collections.Generic.List[object]]::new()

    foreach ($ws in $workspaces) {
        $ab = Resolve-KitAgentBase -Context $Context -Workspace $ws
        if ($null -eq $ab) { Write-Host "- $($ws.Path): у v8project.yaml немає infobase: — бази агента тут не буває (зовнішні обробки)."; continue }

        # Правка виконавця (задокументована в брифі задачі): $template — ОКРЕМА локальна
        # змінна від параметра -Template, а не той самий $Template з іншим регістром.
        # PowerShell імена змінних реєстронечутливі: $template = $Template було б однією
        # й тією самою змінною, і шаблон, узятий із накладки для воркспейсу 1, перезаписав
        # би параметр -Template і протік у воркспейс 2 цього самого циклу.
        $wsTemplate = $Template
        if (-not $wsTemplate -and $Context.Overlay -and $Context.Overlay.Workspaces.ContainsKey($ws.Path)) {
            $wsTemplate = $Context.Overlay.Workspaces[$ws.Path].AgentBaseTemplate
        }

        Write-Host ''
        Write-Host "Воркспейс: $($ws.Path)"
        Write-Host "База:      $($ab.Connection)  ($($ab.Origin))"
        if ($ab.Kind -eq 'server') {
            throw ("База агента воркспейсу '$($ws.Path)' серверна (Srvr=). Kit її не створює: серверну базу створює людина в кластері, а розгортання " +
                   'з .dt на сервері — окремий спайк (спека §13). Далі — operation=init/build Уніки.')
        }
        Write-Host ('Шлях:      ' + $ab.Path + $(if ($ab.Exists) { '  (існує)' } else { '  (ще немає)' }))
        Write-Host ('Шаблон:    ' + $(if ($wsTemplate) { $wsTemplate } else { 'порожня база (без .dt)' }))

        if (-not $Apply) {
            # Правка виконавця (задокументована в брифі задачі): у PowerShell '+' після
            # виклику команди — окремий позиційний аргумент, не конкатенація рядків
            # (Write-Host не має параметра з таким позиційним іменем поруч, а '+' і
            # $(if...) надрукувались би літерально). Рядок збирається в змінну ДО виклику.
            $previewNote = '  Це попередній перегляд. Для виконання додайте -Apply' + $(if ($ab.Exists) { ' -Force (база існує й буде перестворена).' } else { '.' })
            Write-Host $previewNote -ForegroundColor Cyan
            continue
        }
        if ($ab.Exists -and -not $Force) {
            throw "База агента вже є: $($ab.Path). Перестворити з нуля — kit provision -Workspace $($ws.Path) -Apply -Force."
        }
        if ($wsTemplate -and -not (Test-Path -LiteralPath $wsTemplate -PathType Leaf)) { throw "Шаблон бази (.dt) не знайдено: $wsTemplate" }

        # Межа для видалення — тека воркспейсу: база агента лежить у workPath Уніки під нею.
        Assert-SafeWorkPath -Path $ab.Path -MustBeUnder $ws.FullPath -Description "база агента воркспейсу $($ws.Path)"
        Write-Host '  Створюю базу...'
        $null = New-V8FileInfobase -Path $ab.Path -MustBeUnder $ws.FullPath -TemplatePath $wsTemplate
        Write-Host "  Готово: $($ab.Path)" -ForegroundColor Green
        Write-Host '  Далі: operation=build Уніки наповнює базу з джерел воркспейсу.' -ForegroundColor DarkGray

        if ($Remember) {
            Save-KitOverlayAgentBase -OverlayPath $overlayPath -WorkspacePath $ws.Path -Template $wsTemplate
            Write-Host "  Шаблон записано в $overlayPath (workspaces.$($ws.Path).agentBase.template)." -ForegroundColor DarkGray
        }
        $done.Add([pscustomobject]@{ Workspace = $ws.Path; Path = $ab.Path; Template = $wsTemplate })
    }
    [pscustomobject]@{ ExitCode = 0; Provisioned = $done.ToArray() }
}

Export-ModuleMember -Function Invoke-KitProvision
