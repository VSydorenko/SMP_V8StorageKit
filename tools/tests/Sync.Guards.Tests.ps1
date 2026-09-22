#Requires -Version 7
Describe 'kit sync — штатні зупинки до звернення до платформи' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }

    It 'немає джерел truth: storage — код 0 і пояснення, платформа не потрібна' {
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-storage') -Workspaces $ws -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*truth: storage*'
    }

    It 'каталог сховища недоступний — зупинка з його шляхом ДО створення build/sync/<ключ> і без гілки' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-dir') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*no-such-storage-Alpha_SMB*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
        (git -C $repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'AUTHORS відсутній — зупинка до платформи' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-authors') -WithHooks
        Remove-Item -LiteralPath (Join-Path $repo 'AUTHORS')
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*AUTHORS*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It '-Source невідомий — зупинка з переліком' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'bad-source') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Source', 'Nope')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'Nope'*"
    }

    It 'джерело truth: storage на EXTERNAL_DATA_PROCESSORS — зупинка (сховища для обробок не буває)' {
        $text = @('version: 1', 'kitVersion: 1.0.1', 'product: Fake', 'workspaces:', '  - path: epf', '    sources:', "      tools: { truth: storage, storage: { path: '$TestDrive' } }") -join "`n"
        $ws = [ordered]@{ 'epf' = @{ Sets = @(@{ Name = 'tools'; Type = 'EXTERNAL_DATA_PROCESSORS'; Path = 'src' }) } }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'ext-proc') -Workspaces $ws -ManifestText $text -WithHooks
        $r = Invoke-Sync -Repo $repo
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*EXTERNAL_DATA_PROCESSORS*'
    }

    It 'пароль сховища з накладки ніде не потрапляє у вивід зупинки (Task 2a)' {
        # Той самий сценарій, що "каталог сховища недоступний" вище, але з паролем у
        # v8storagekit.local.yaml під storages: Alpha_SMB — sync мусить дійти до тієї самої
        # зупинки ("Каталог сховища не знайдено"), і пароль з накладки ніде в її виводі не
        # з'явиться: ні в Write-Host, ні в тексті винятку, ні деінде.
        $overlay = @('storages:', "  Alpha_SMB: { password: 'secret' }") -join "`n"
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'with-password') -OverlayText $overlay -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*Каталог сховища не знайдено*'
        $r.Output | Should -Not -BeLike '*secret*'
    }

    # Рев'ю Task 2, п. 8 — наскрізна перевірка прив'язки прапорця через СПРАВЖНІЙ kit.ps1 (не
    # напряму Invoke-KitSync): та сама пастка, що вже закріплена для kit verify -Version
    # (Verify.Tests.ps1) — без диспетчерської перевірки типу параметра '-Apply', що йде одразу
    # після '-FromVersion', мовчки прив'язався б як $true, а [Nullable[int]] звів би це до 1 —
    # sync тихо реплеїв би "з версії 1" замість штатної зупинки.
    It '-FromVersion без значення (далі інший прапорець) — зупинка "потребує значення", не мовчазна прив''язка як 1' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'fromversion-novalue') -WithHooks
        $r = Invoke-Sync -Repo $repo -More @('-FromVersion', '-Apply')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-FromVersion*значення*'
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It 'бази агента немає — зупинка з рецептом, дамп не починається' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-agent-base') -WithHooks
        # Каталог сховища має існувати, інакше sync зупиниться раніше — на ньому.
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*kit provision*'
        $r.Output   | Should -BeLike '*operation=build*'
        (git -C $repo branch --list 'storage/*') | Should -BeNullOrEmpty
        Join-Path $repo 'build/sync/Alpha_SMB' | Should -Not -Exist
    }

    It 'база агента збігається з дев-базою людини — зупинка до платформи (принцип 3)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'human-base') -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $ibDir = Join-Path $repo 'Alpha_SMB/build/ib'
        New-Item -ItemType Directory -Force -Path $ibDir | Out-Null
        Set-Content -LiteralPath (Join-Path $ibDir '1Cv8.1CD') -Value 'fake' -Encoding UTF8
        $overlay = @('infobases:', "  dev: { connection: 'File=$ibDir' }") -join "`n"
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.local.yaml') -Value $overlay -Encoding UTF8
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*дев-базою людини*'
    }

    It 'у v8project.yaml немає infobase: — зупинка з іменем воркспейсу' {
        $ws = [ordered]@{
            'Alpha_SMB' = @{
                Sets = @(
                    @{ Name = 'base';      Type = 'CONFIGURATION'; Path = 'cf/src' }
                    @{ Name = 'Alpha_SMB'; Type = 'EXTENSION';     Path = 'cfe/src' }
                )
            }
        }
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-infobase') -Workspaces $ws -WithHooks
        New-Item -ItemType Directory -Force -Path (Join-Path (Split-Path -Parent $repo) 'no-such-storage-Alpha_SMB') | Out-Null
        $r = Invoke-Sync -Repo $repo -More @('-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -BeLike '*Alpha_SMB*'
        $r.Output   | Should -BeLike '*infobase*'
    }
}
