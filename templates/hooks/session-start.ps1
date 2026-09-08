#Requires -Version 7
<#
.SYNOPSIS
    Шим хука SessionStart для репозиторію під v8storagekit (спека §7). Закомічений у
    репозиторії-споживачі як .claude/hooks/session-start.ps1; його кладе скіл onboarding.
.DESCRIPTION
    Логіки тут немає: знайти плагін у реєстрі Claude Code, викликати kit.ps1 session-check у
    поточній теці й надрукувати контекст для сесії. Плагіна немає — мовчки, код 0. Нічого не
    змінює: рішення — людині, дія — скіл v8storagekit:sync.
    Оновлення: kit check порівнює цей файл із templates/hooks/session-start.ps1 плагіна.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-KitPluginRoot {
    $registry = if ($env:V8KIT_PLUGINS_REGISTRY) { $env:V8KIT_PLUGINS_REGISTRY } else { Join-Path $HOME '.claude/plugins/installed_plugins.json' }
    if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) { return $null }
    try { $json = Get-Content -LiteralPath $registry -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not ($json.PSObject.Properties.Name -contains 'plugins')) { return $null }
    # Ключі реєстру — '<плагін>@<маркетплейс>'; ім'я плагіна — до '@'.
    $entry = $json.plugins.PSObject.Properties | Where-Object { ($_.Name -split '@', 2)[0] -eq 'v8storagekit' } | Select-Object -First 1
    if (-not $entry) { return $null }
    $install = @($entry.Value) | Select-Object -First 1
    if (-not $install -or -not ($install.PSObject.Properties.Name -contains 'installPath')) { return $null }
    $root = [string]$install.installPath
    if (-not (Test-Path -LiteralPath (Join-Path $root 'tools/kit.ps1') -PathType Leaf)) { return $null }
    $root
}

$plugin = Get-KitPluginRoot
if (-not $plugin) { exit 0 }

$context = ''
try {
    $intro = ''
    $skill = Join-Path $plugin 'skills/using-v8storagekit/SKILL.md'
    if (Test-Path -LiteralPath $skill -PathType Leaf) {
        $intro = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $intro = [regex]::Replace($intro, '\A---\r?\n.*?\r?\n---\r?\n', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $intro = $intro.Replace('<корінь плагіна>', $plugin)
    }

    $cwd = (Get-Location).Path
    $status = ''
    if (-not (Test-Path -LiteralPath (Join-Path $cwd 'v8storagekit.yaml') -PathType Leaf)) {
        $status = "У теці $cwd немає v8storagekit.yaml: репозиторій не підключено до kit (скіл v8storagekit:onboarding) або сесія відкрита не в корені репозиторію."
    } else {
        # Стеля часу — обов'язкова: цей код виконується на старті КОЖНОЇ сесії, а session-check обходить
        # data/objects (часто SMB) і викликає повний check. Перевищення показуємо рядком, не мовчанням:
        # мовчання читалось би як «нових версій немає» — та сама логіка, що для коду 1.
        # Стеля — через змінну оточення, а не через накладку: шим за конструкцією не читає YAML
        # (жодних модулів kit, жодного парсера) — інакше він перестав би бути шимом.
        $timeoutSec = 15
        if ($env:V8KIT_SESSION_CHECK_TIMEOUT -match '^\d+$') { $timeoutSec = [int]$env:V8KIT_SESSION_CHECK_TIMEOUT }
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            # Вивід — у ФАЙЛИ, не в пайп: пайп без асинхронного читання дає дедлок на великому виводі
            # (знахідка B2 в Invoke-KitGitProcess). Список аргументів закритий: -Apply шим не передає
            # ніколи — session-check нічого не змінює, і передавати його нема чого.
            $proc = Start-Process -FilePath 'pwsh' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ArgumentList @('-NoProfile', '-File', (Join-Path $plugin 'tools/kit.ps1'), 'session-check', '-RepoRoot', $cwd)
            if ($proc.WaitForExit($timeoutSec * 1000)) {
                $raw = (((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) + (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8)) | Out-String).Trim()
                # Коди за змістом (спека §5): 0 — тиша, 3 — є сигнал — обидва друкуються як є; 1 — перевірка
                # не відпрацювала, і мовчати не можна.
                $status = if ($proc.ExitCode -eq 1) { "УВАГА: kit session-check не відпрацював (код 1) — стан сховищ НЕВІДОМИЙ, не «без змін». Зупинка:`n$raw" } else { $raw }
            } else {
                # Убивати процес дозволено рівно тому, що session-check нічого не мутує (§5).
                try { $proc.Kill($true) } catch { }
                $status = "УВАГА: kit session-check не вклався в $timeoutSec с — стан сховищ НЕВІДОМИЙ, не «без змін». Найчастіша причина — повільний доступ до сховища (SMB); перевірити вручну: kit.ps1 session-check -RepoRoot ."
                # Те, що kit устиг надрукувати, не пропадає: знахідки check виходять раніше за сигнали джерел.
                # Позначка «частково» обов'язкова — без неї обрізаний вивід читався б як повний, тобто як
                # «інших джерел не згадано, отже з ними все гаразд».
                $partial = ''
                try { $partial = ((Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) | Out-String).Trim() } catch { }
                if ($partial) { $status = "$status`n`nЧастково (kit устиг надрукувати до зупинки; повнота НЕ гарантована):`n$partial" }
            }
        } finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    $context = "<v8storagekit>`n$intro`n`n## Стан сховищ (kit session-check)`n`n$status`n</v8storagekit>"
} catch {
    $context = "<v8storagekit>`nХук v8storagekit не зміг зібрати стан: $($_.Exception.Message)`n</v8storagekit>"
}

[ordered]@{
    hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $context }
} | ConvertTo-Json -Depth 4 -Compress
exit 0
