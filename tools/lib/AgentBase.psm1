#Requires -Version 7
Set-StrictMode -Version Latest

# Без -Force — той самий принцип, що й у решти вкладених імпортів lib-модулів
# (StorageReport.psm1, V8Project.psm1): не перезавантажувати вже наявний глобальний
# V8Project. AgentBase бере звідти Resolve-V8AgentInfobase і Resolve-KitAgentInfobasePath.
Import-Module "$PSScriptRoot/V8Project.psm1"

function Resolve-KitAgentBase {
    <#
    .SYNOPSIS
        База агента воркспейсу — так, як її бачить Unica (§2.5) — плюс аудит: це не база людини.
    .DESCRIPTION
        Принцип 3: kit ніколи не пише в базу людини. Якщо підключення бази агента (з
        v8project.local.yaml або v8project.yaml — Resolve-V8AgentInfobase) нормалізовано
        збігається з будь-якою дев-базою з infobases: накладки kit — зупинка до будь-якої
        дії, а не мовчазне продовження. $null — у воркспейсі бази немає (зовнішні обробки).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Workspace)

    $ib = Resolve-V8AgentInfobase -Project $Workspace.Project
    if ($null -eq $ib) { return $null }

    if ($Context.Overlay) {
        $norm = { param([string]$s) (($s -replace '\s', '') -replace '"', '').TrimEnd(';').ToLowerInvariant() }
        $hit = @($Context.Overlay.Infobases.Values | Where-Object { (& $norm $_.Connection) -eq (& $norm $ib.Connection) }) | Select-Object -First 1
        if ($hit) {
            throw ("База агента воркспейсу '$($Workspace.Path)' ($($ib.Origin)) збігається з дев-базою людини '$($hit.Name)' із накладки kit. " +
                   'Kit ніколи не пише в базу людини (принцип 3): приберіть infobase: з v8project.local.yaml або дайте агентові окрему базу.')
        }
    }

    $resolved = Resolve-KitAgentInfobasePath -Project $Workspace.Project -Connection $ib.Connection
    [pscustomobject]@{
        Workspace = $Workspace.Path; Connection = $ib.Connection; User = $ib.User; Origin = $ib.Origin
        Kind = $resolved.Kind; Path = $resolved.Path; IbSwitch = $resolved.IbSwitch
        Exists = $(if ($resolved.Kind -eq 'file') { Test-Path -LiteralPath (Join-Path $resolved.Path '1Cv8.1CD') -PathType Leaf } else { $true })
    }
}

Export-ModuleMember -Function Resolve-KitAgentBase
