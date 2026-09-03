#Requires -Version 7
Set-StrictMode -Version Latest

# Єдине місце в kit, де відомо, ЯКИМ парсером читається YAML. Рішення (спека §2.4):
# модуль powershell-yaml із PSGallery — залежність категорії «Конвеєр». Регекс, яким
# читався v8project.local.yaml до 1.0, не витягне flow-стиль маніфесту
# (`{ truth: vendor, dump: { from: devUNF } }`), а вендорити YamlDotNet.dll у
# git-розповсюджуваний плагін означало б бінарник у репозиторії.
$script:YamlModuleName  = 'powershell-yaml'
$script:YamlInstallHint = "Install-Module $script:YamlModuleName -Scope CurrentUser"

function Test-KitYamlModule {
    <#
    .SYNOPSIS
        Чи встановлено powershell-yaml. Нічого не кидає — це звіт для check-environment.
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{ Available = $false; Version = ''; Reason = '' }
    $modules = @(Get-Module -ListAvailable -Name $script:YamlModuleName -ErrorAction SilentlyContinue)
    if ($modules.Count -eq 0) {
        $result.Reason = "Модуль $script:YamlModuleName не встановлено — $script:YamlInstallHint"
        return $result
    }
    $newest = $modules | Sort-Object Version -Descending | Select-Object -First 1
    $result.Version   = [string]$newest.Version
    $result.Available = $true
    $result
}

function Import-KitYamlModule {
    <#
    .SYNOPSIS
        Завантажує powershell-yaml або зупиняється з командою встановлення.
    #>
    [CmdletBinding()]
    param()

    if (Get-Module -Name $script:YamlModuleName) { return }
    $probe = Test-KitYamlModule
    if (-not $probe.Available) {
        throw "$($probe.Reason). Без нього kit не читає ні v8storagekit.yaml, ні v8project.yaml."
    }
    Import-Module $script:YamlModuleName -ErrorAction Stop
}

function Read-KitYaml {
    <#
    .SYNOPSIS
        Читає YAML-файл у впорядковану мапу. Fail-closed: не файл, порожньо, не мапа, не
        розбирається — зупинка з ім'ям файлу.
    .PARAMETER AllowEmpty
        Порожній або суто коментований файл — законний стан (наприклад, v8project.local.yaml
        без жодного ключа): повернути $null замість зупинки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowEmpty
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл не знайдено: $Path"
    }
    Import-KitYamlModule

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $data = ConvertFrom-Yaml -Yaml $text -Ordered
        } catch {
            throw "Файл $Path не розбирається як YAML: $($_.Exception.Message)"
        }
    }

    if ($null -eq $data) {
        if ($AllowEmpty) { return $null }
        throw "Файл $Path порожній — очікувався YAML-документ із мапою на верхньому рівні."
    }
    if ($data -isnot [System.Collections.IDictionary]) {
        throw "Файл $Path на верхньому рівні має бути мапою (ключ: значення), а не $($data.GetType().Name)."
    }
    $data
}

Export-ModuleMember -Function Test-KitYamlModule, Import-KitYamlModule, Read-KitYaml
