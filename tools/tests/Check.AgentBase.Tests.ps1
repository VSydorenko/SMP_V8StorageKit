#Requires -Version 7
Describe 'kit check — інваріанти репозиторію-споживача' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It 'джерело truth: storage у воркспейсі без бази агента — warn agent-base-required' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-no-base') -Workspaces $ws -WithHooks
        $r = Invoke-Check -Repo $repo
        # Тег знахідки ('agent-base-required') у Write-Host не друкується — лише Message
        # (той самий факт, що вже задокументовано нижче для 'build-artifacts'): підставою для
        # асерції править фраза з повідомлення. 'kit provision' у виводі 'kit check' зустрічається
        # лише в ЦЬОМУ повідомленні (перевірено grep по tools/lib/ і tools/commands/ у контексті
        # виконання check) — підміна 'agent-base-required', яка інакше НІКОЛИ не з'явиться в
        # Output і зробила б обидва тести (і позитивний, і негативний) хибними без різниці.
        $r.Output | Should -BeLike '*kit provision*'
        $r.Output | Should -BeLike '*Alpha_SMB*'
    }

    It 'база агента з v8project.yaml (без .local) збігається з дев-базою людини — check це каже' {
        $repo = New-GoodRepo -Name 'agent-base-collision'
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        # Дев-база людини в накладці вказує на ту саму теку, що база агента у ЗАКОМІЧЕНОМУ
        # v8project.yaml — жодного v8project.local.yaml у репозиторії немає.
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*дев-базою людини*'
    }

    It 'база агента на місці — знахідки немає' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'check-with-base') -WithHooks
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*kit provision*'
    }

    It 'усе гаразд — код 0, лише інформаційні рядки' {
        $r = Invoke-Check -Repo (New-GoodRepo 'good')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '\[i\]'
        $r.Output | Should -Not -Match '\[-\]'
    }

    # Task 9 — структура репозиторію (kitVersion маніфесту) звіряється з версією плагіна, який
    # зараз виконується (Get-KitPluginVersion, Preflight.psm1). Обидва напрямки — warn. Тег
    # знахідки ('kit-version') у Write-Host не друкується (лише Message, той самий факт, що
    # вже задокументовано вище для 'agent-base-required' і нижче для 'build-artifacts') — тож
    # асерції тут ловлять характерну фразу з кожної гілки, а не тег: 'v8storagekit:onboarding'
    # (з префіксом плагіна) зустрічається лише в гілці «структура відстає», 'claude plugin
    # update' — лише в гілці «плагін старіший». Голе слово 'onboarding' без префікса тут НЕ
    # годиться — воно вже є в іншій, незалежній знахідці кожного New-GoodRepo (info hook-shim,
    # Hooks.psm1: «…onboarding кладе його з templates/hooks/…») і зробило б асерцію хибно
    # позитивною (спіймано живим прогоном фікс-раунду 1).
    It 'структура відстає від плагіна — warn kit-version із порадою onboarding' {
        $repo = New-GoodRepo -Name 'kv-behind'
        (Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw) `
            -replace 'kitVersion: .*', 'kitVersion: 0.9.0' |
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*v8storagekit:onboarding*'
    }

    It 'плагін старіший за структуру — warn із порадою оновити плагін' {
        $repo = New-GoodRepo -Name 'kv-ahead'
        (Get-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Raw) `
            -replace 'kitVersion: .*', 'kitVersion: 99.0.0' |
            Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*claude plugin update*'
    }

    It 'версії збігаються — знахідки немає' {
        $repo = New-GoodRepo -Name 'kv-equal'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*v8storagekit:onboarding*'
        $r.Output | Should -Not -BeLike '*claude plugin update*'
    }

    # Important 2 (рев'ю фікс-раунду 1) — .claude-plugin/plugin.json редагують автори плагіна,
    # і формат його version нічим не гарантований (на відміну від kitVersion маніфесту, який
    # Manifest.psm1 уже перевірив регекспом): передрелізний тег штибу '1.1.0-rc1' — цілком
    # можливе майбутнє значення. [version] на такому рядку кидає, а check виконується в кожній
    # сесії через session-check — виняток тут ламав би старт сесії в кожного споживача. Перевірка
    # мусить мовчки не видавати знахідку, а не падати.
    It 'версія плагіна не X.Y.Z (напр. передрелізний тег) — код 0, без падіння й без знахідки' {
        $repo = New-GoodRepo -Name 'kv-unparseable'
        # У КОПІЇ дерева (Copy-KitTools), не в робочій копії плагіна: саме проти цієї копії
        # $script:Kit запускає підпроцес check нижче. Оригінальний вміст відновлюємо в finally —
        # інакше мутація пережила б цей It і зіпсувала kit-version для решти тестів файлу,
        # які повторно використовують той самий $script:Kit.
        $pluginJsonPath = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Kit)) '.claude-plugin/plugin.json'
        $original = Get-Content -LiteralPath $pluginJsonPath -Raw
        try {
            $json = $original | ConvertFrom-Json
            $json.version = '1.1.0-rc1'
            ($json | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $pluginJsonPath -Encoding UTF8
            $r = Invoke-Check -Repo $repo
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -BeLike '*v8storagekit:onboarding*'
            $r.Output | Should -Not -BeLike '*claude plugin update*'
        } finally {
            Set-Content -LiteralPath $pluginJsonPath -Value $original -Encoding UTF8 -NoNewline
        }
    }
}
