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
    # сама команда) або check із помилками; 2 — лише sync (частковий успіх); 3 —
    # verify і session-check (є що робити; той самий сенс, лише session-check дешевше).
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

    It 'жодна команда не оголошує параметра, якого не вживає' {
        # Клас дефектів, знайдений на живому прогоні (SimplyConnect, 2026-09-15): provision
        # оголошував -Source і мовчки його ігнорував, тож звуження не відбувалось, а помилки
        # не було — створювались бази агента для ВСІХ воркспейсів. Те саме мав install-hooks
        # (-Workspace і -Source). Причина структурна: kit.ps1 клав Source/Workspace у splat
        # для кожної команди, тож команда мусила оголосити параметр, навіть якщо не вживає.
        # Текстовий grep тут не годиться (згадка в коментарі рахувалась би за використання) —
        # тому AST: шукаємо використання змінної в тілі функції ПОЗА param-блоком.
        $commandsDir = Join-Path (Split-Path $script:Kit -Parent) 'commands'
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -LiteralPath $commandsDir -Filter '*.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $funcs = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Invoke-Kit*'
            }, $true)
            foreach ($fn in $funcs) {
                $paramBlock = $fn.Body.ParamBlock
                if (-not $paramBlock) { continue }
                $paramEnd = $paramBlock.Extent.EndOffset
                foreach ($p in $paramBlock.Parameters) {
                    $name = $p.Name.VariablePath.UserPath
                    $uses = $fn.Body.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.VariablePath.UserPath -eq $name -and
                        $n.Extent.StartOffset -gt $paramEnd
                    }, $true)
                    if (@($uses).Count -eq 0) {
                        $bad.Add("$($file.Name): $($fn.Name) оголошує -$name і жодного разу не читає")
                    }
                }
            }
        }
        ($bad -join "`n") | Should -BeNullOrEmpty
    }

    It 'параметр, якого команда не приймає, зупиняє диспетчер із поясненням' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsupported-param')
        $r = Invoke-Kit @('install-hooks', '-RepoRoot', $repo, '-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*install-hooks*'
        $r.Output | Should -BeLike '*-Source*'
    }
}

Describe 'Copy-KitTools — повнота пісочниці' {
    # Чому цей Describe існує. Тести запускають kit ПІДПРОЦЕСОМ із копії дерева, яку робить
    # Copy-KitTools, а та копіює фіксований перелік тек. Перелік уже двічі відставав від коду,
    # і обидва рази наслідок був той самий і найгірший з можливих: тест зеленів НЕ З ТІЄЇ
    # ПРИЧИНИ. tools/assets (стаб розширення) і templates/settings.json свого часу ловили
    # живим прогоном, а .claude-plugin/plugin.json спіймали на префлайті C2 — без нього
    # Get-KitPluginVersion у пісочниці повертає $null, знахідки kit-version немає, і тести,
    # що її чекають, «проходять» бо перевірка просто не спрацювала.
    # Тут ми не перелічуємо теки вдруге (це була б копія формули, яку follow-ups §4 називає
    # дефектом), а перевіряємо ВЛАСТИВІСТЬ: kit у пісочниці робить те саме, що вдома.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:SandboxKit = Copy-KitTools -Root (Join-Path $TestDrive 'completeness')
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo') -WithHooks -WithGitattributes -WithGitignore
    }

    It 'check у пісочниці не падає на відсутньому файлі плагіна' {
        $out = & pwsh -NoProfile -File $script:SandboxKit check -RepoRoot $script:Repo 2>&1 | Out-String
        $code = $LASTEXITCODE
        # Клас «щось не скопіювали» має власний почерк: .NET кидає саме такими фразами,
        # і жодна штатна зупинка kit так не звучить.
        $out | Should -Not -Match 'Cannot find path|не вдалося знайти шлях|ItemNotFoundException|FileNotFoundException'
        $code | Should -Be 0 -Because "у справному репозиторії check має завершитись нулем; вивід:`n$out"
    }

    It 'версія плагіна доступна з пісочниці — інакше перевірка kit-version мовчить, а тести зеленіють дарма' {
        # Пряма перевірка того, що спіймали префлайтом: Get-KitPluginVersion рахує шлях від
        # tools/lib копії, тож .claude-plugin/plugin.json мусить бути ПОРУЧ із tools/ у копії.
        $libPath = Join-Path (Split-Path $script:SandboxKit) 'lib/Preflight.psm1'
        $probe = & pwsh -NoProfile -Command {
            param($Module)
            Import-Module $Module -Force
            Get-KitPluginVersion
        } -args $libPath 2>&1 | Out-String
        $probe.Trim() | Should -Match '^\d+\.\d+\.\d+$' -Because "у пісочниці Get-KitPluginVersion має віддати версію, а не порожнечу; отримано: '$($probe.Trim())'"
    }
}
