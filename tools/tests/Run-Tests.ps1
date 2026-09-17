#Requires -Version 7
<#
.SYNOPSIS
    Прогін тестового набору tools/tests через Pester.
.DESCRIPTION
    За замовчуванням запускає все, включно з тестами під тегом Integration
    (New-ExtensionInfobase у V8.Tests.ps1), які реально запускають 1cv8.exe,
    створюють файлову інформаційну базу й завантажують у неї розширення — це вже
    не read-only операція. M8 фінального ревʼю: .claude/settings.json auto-allow
    (без запиту) дозволяє лише виклик із -ExcludeTag Integration, який лишається
    суто читанням; повний прогін (цей файл без параметрів, як у "Типових операціях"
    CLAUDE.md) і надалі питає підтвердження.

    -Only <імена> звужує прогін до названих файлів тестів. Повний набір триває ~6,5 хв
    незалежно від обсягу правки, а TDD вимагає двох прогонів на задачу — у ЧЕРВОНІЙ фазі
    ("тест має впасти") достатньо того файлу, який щойно змінили. Повний набір лишається
    обов'язковим ПЕРЕД комітом і після серії фіксів: звужений прогін не бачить регресій у
    сусідніх файлах, а саме їх тут ловили найчастіше (вимір блоку C1, 2026-09-17: ≈52 хв із
    ≈97 хв стінного часу виконавців пішли на повні прогони, більшість — у червоній фазі).
.EXAMPLE
    pwsh tools/tests/Run-Tests.ps1                                       # усе, разом з Integration
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration                # без запуску платформи
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only Sync     # лише Sync.Tests.ps1
    pwsh tools/tests/Run-Tests.ps1 -ExcludeTag Integration -Only Sync,Verify
#>
[CmdletBinding()]
param(
    [string[]]$ExcludeTag = @(),
    # Ім'я файлу тестів із tools/tests — з розширенням чи без: 'Sync' і 'Sync.Tests.ps1'
    # рівноцінні. Шлях не приймається навмисно: прогін цього набору, не довільного файла.
    [string[]]$Only = @()
)

# Кирилиця в порівняннях доходить із дочірніх процесів лише при UTF-8: під кодовою
# сторінкою 866 (типовий запуск із Git Bash) тести Environment.Tests.ps1 падали на
# Should -Match із кириличним літералом, хоча код був справний.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module Pester -MinimumVersion 5.0

# Розділення по комі власноруч — не примха, а єдиний спосіб, щоб задокументована форма
# запуску працювала. `pwsh -File <скрипт> -Only Sync,Verify` (саме її називає дозволеною
# CLAUDE.md) віддає «Sync,Verify» ОДНИМ рядком: прив'язку масиву робить парсер PowerShell,
# а через -File аргументи приходять уже розібраними оболонкою, і кома лишається всередині
# елемента. Наслідок був тихо-гучний: скрипт шукав файл «Sync,Verify.Tests.ps1» і падав із
# переліком доступних — тобто запобіжник нижче спрацьовував, але на рівному місці, і форма
# з CLAUDE.md не працювала жодного разу (виявлено виконавцем у сесії C2, 2026-09-17).
# Через -Command те саме працювало, бо там рядок розбирає парсер.
$Only       = @($Only       | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ExcludeTag = @($ExcludeTag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$config = New-PesterConfiguration
if ($Only) {
    # Неіснуючий файл — зупинка з переліком, а не мовчазний прогін нуля тестів: описка в
    # -Only інакше дала б "Tests Passed: 0, Failed: 0" і прочиталась би як успіх.
    $paths = foreach ($name in $Only) {
        $leaf = if ($name -like '*.Tests.ps1') { $name } else { "$name.Tests.ps1" }
        $full = Join-Path $PSScriptRoot $leaf
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $available = (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' |
                ForEach-Object { $_.Name -replace '\.Tests\.ps1$', '' }) -join ', '
            throw "Файла тестів '$leaf' немає в $PSScriptRoot. Доступні: $available."
        }
        $full
    }
    $config.Run.Path = @($paths)
} else {
    $config.Run.Path = $PSScriptRoot
}
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
Invoke-Pester -Configuration $config
