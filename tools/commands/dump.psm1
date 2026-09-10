#Requires -Version 7
Set-StrictMode -Version Latest

function Invoke-KitDump {
    <#
    .SYNOPSIS
        Дамп поточного стану живої бази людини в дерево джерела (truth: dump або vendor).
        Kit лише читає базу; куди — каже v8project.yaml; з якої бази — dump.from + накладка kit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply
    )

    $root = $Context.RepoRoot
    if ($Source) {
        $requested = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source)
        foreach ($s in $requested) {
            if ($s.Truth -notin @('dump', 'vendor')) {
                throw "Джерело '$($s.Key)' має truth: $($s.Truth) — dump працює лише з truth: dump або vendor (для storage є sync, для git джерела немає)."
            }
        }
    }
    $sources = @(Select-KitSources -Context $Context -Workspace $Workspace -Source $Source -Truth @('dump', 'vendor'))
    if ($sources.Count -eq 0) {
        Write-Host 'У маніфесті (з урахуванням -Workspace/-Source) немає джерел із truth: dump чи vendor — вивантажувати нічого.'
        return [pscustomobject]@{ ExitCode = 0; Dumped = @() }
    }

    $overlayPath = if ($Context.OverlayPath) { $Context.OverlayPath } else { Join-Path $root 'v8storagekit.local.yaml' }
    $plan = @(foreach ($src in $sources) {
        $ib = Resolve-KitInfobase -Overlay $Context.Overlay -Name $src.DumpFrom -OverlayPath $overlayPath
        [pscustomobject]@{ Source = $src; Infobase = $ib; IbSwitch = (ConvertTo-V8IbSwitch -Connection $ib.Connection) }
    })

    $dumped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $plan) {
        $src = $item.Source
        $wsFull = ($Context.Workspaces | Where-Object Path -eq $src.Workspace).FullPath
        Write-Host ''
        Write-Host "Джерело:  $($src.Workspace)/$($src.Key) ($($src.Type), truth: $($src.Truth))"
        Write-Host "База:     $($item.IbSwitch)  (dump.from: $($item.Infobase.Name), користувач $($item.Infobase.User))"
        Write-Host "Куди:     $($src.RepoPath)"

        if (-not $Apply) {
            Write-Host '  Це попередній перегляд. Для виконання додайте -Apply.' -ForegroundColor Cyan
            Write-Host '  Вивантаження конфігурації триває 20–40 хвилин і займає 1–2 ГБ; база має бути закрита в Конфігураторі.' -ForegroundColor Cyan
            continue
        }

        Assert-SafeWorkPath -Path $src.FullPath -MustBeUnder $wsFull -Description "ціль дампу джерела $($src.Key)"
        if (Test-Path -LiteralPath $src.FullPath) { Remove-Item -LiteralPath $src.FullPath -Recurse -Force }
        New-Item -ItemType Directory -Path $src.FullPath -Force | Out-Null

        $ext = if ($src.Type -eq 'EXTENSION') { " -Extension $($src.Key)" } else { '' }
        $r = Invoke-V8Designer -IbSwitch $item.IbSwitch -User $item.Infobase.User -Arguments @(('/DumpConfigToFiles "{0}"{1}' -f $src.FullPath, $ext))
        if ($r.ExitCode -ne 0) {
            Assert-V8InfobaseNotBusy -Output $r.Output -Infobase $item.Infobase.Name
            throw "Вивантаження $($src.Key) не вдалося: $($r.Output)"
        }
        # @(...) навколо Get-ChildItem обов'язковий (той самий дефект уже ловили в Task 1,
        # Invoke-KitStorageCheckout): гола дужка без @() падає під Set-StrictMode -Version
        # Latest не лише на порожній теці (Get-ChildItem повертає $null), а й на теці РІВНО
        # з одним файлом (Get-ChildItem повертає скалярний FileInfo, а не масив) — в обох
        # випадках .Count кидає "The property 'Count' cannot be found on this object"
        # замість чесних "Файлів: 0"/"Файлів: 1". @(...) перед .Count завжди дає масив.
        $count = @(Get-ChildItem -LiteralPath $src.FullPath -Recurse -File).Count
        Write-Host "  Готово. Файлів: $count" -ForegroundColor Green
        $dumped.Add([pscustomobject]@{ Key = $src.Key; Target = $src.FullPath; Files = $count })
    }
    [pscustomobject]@{ ExitCode = 0; Dumped = $dumped.ToArray() }
}

Export-ModuleMember -Function Invoke-KitDump
