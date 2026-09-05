#Requires -Version 7
Describe 'kit.ps1 — диспетчер команд' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Тестова команда: друкує, що отримала. Живе лише в копії — у справжньому tools/commands її немає.
        # Write-Host, не return: контракт команди суворий — success stream несе лише $null
        # або {ExitCode; …}, людське йде через Write-Host. probe зображає справжню команду
        # (check у задачі 8 друкує саме так), тож і тут повернене значення диспетчер не показує.
        Set-Content -LiteralPath (Join-Path (Split-Path $script:Kit) 'commands/probe.psm1') -Encoding UTF8 -Value @'
function Invoke-KitProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Ref = 'HEAD',
        [switch]$Force,
        [switch]$Throw
    )
    if ($Throw) { throw 'PROBE-THROW: симульований збій команди' }
    Write-Host "PROBE workspaces=$($Context.Workspaces.Count) ws=$Workspace src=$Source apply=$Apply ref=$Ref force=$Force main=$($Context.MainBranch)"
}
Export-ModuleMember -Function Invoke-KitProbe
'@

        function script:Invoke-Kit {
            param([string[]]$Arguments)
            $out = & pwsh -NoProfile -File $script:Kit @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo')
    }

    # Правка 6б (живий прогін задачі 11): раніше — сирий throw і стек PowerShell; тепер —
    # Write-Host червоним і exit 1 (рев'ю B3 раунд 3, Step 5а: був код 2, конфліктував зі
    # штатним частковим успіхом sync — sync теж повертає 2, коли дзеркало оновлено, а
    # злиття не виконано, і один код означав три різні речі). Таблиця кодів тепер: 0 —
    # виконано; 1 — зупинка (throw будь-де: невідома команда, префлайт, розбір аргументів,
    # сама команда) або check із помилками; 2 — лише sync (частковий успіх); 3 — лише
    # verify (є що робити).
    It 'без команди — зупинка з переліком доступних, код 1' {
        $r = Invoke-Kit @('-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*probe*'
    }

    It 'невідома команда — зупинка з переліком доступних, код 1' {
        $r = Invoke-Kit @('frobnicate', '-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike "*'frobnicate'*probe*"
    }

    It 'спільні й власні параметри доходять до команди; контекст після префлайту' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Workspace', 'Alpha_SMB', '-Ref', 'main', '-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*PROBE workspaces=1 ws=Alpha_SMB src= apply=False ref=main force=True main=main*'
    }

    It '-Apply передається як $true' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Apply')
        $r.Output | Should -BeLike '*apply=True*'
    }

    It '-Force без значення (кінець аргументів) — справжній [switch], диспетчер підставляє $true' {
        # Регресійний доказ на саму механіку Step 5а: -Force — останній токен, наступного
        # значення немає, і диспетчер має розпізнати, що параметр — [switch], а не вимагати
        # значення (як він тепер вимагає для будь-якого іншого типу — тест нижче).
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*force=True*'
    }

    It '-Ref без значення — параметр НЕ [switch], диспетчер вимагає значення, код 1' {
        # Ref — [string], не [switch]: -Ref останнім токеном (значення немає) мав би раніше
        # мовчки зв'язатися як $true (перетворений на рядок 'True') — тепер диспетчер сам
        # зупиняє виклик, ще до Invoke-KitProbe. Той самий механізм, що захищає -Version у
        # verify (рев'ю B3 раунд 3, Step 5а) — тут перевірений на нейтральній probe-команді.
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Ref')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*-Ref*'
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'команда кидає виняток усередині — код 1, повідомлення показано, не сирий стек' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Throw')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*PROBE-THROW*'
    }

    It 'невідомий власний параметр команди — зупинка, команда не виконана' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Bogus', '1')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'провал префлайту зупиняє до виклику команди' {
        $broken = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken')
        Remove-Item -LiteralPath (Join-Path $broken 'Alpha_SMB/v8project.yaml')
        $r = Invoke-Kit @('probe', '-RepoRoot', $broken)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8project.yaml*'
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'не git-репозиторій — зупинка' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-Kit @('probe', '-RepoRoot', $dir)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*.git*'
    }
}
