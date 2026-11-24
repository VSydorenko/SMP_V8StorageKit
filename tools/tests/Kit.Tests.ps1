#Requires -Version 7
Describe 'kit.ps1 — диспетчер команд' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Тестова команда: друкує, що отримала. Живе лише в копії — у справжньому tools/commands її немає.
        # Write-Host, не return: контракт команди суворий — success stream несе лише $null
        # або {ExitCode; …}, людське йде через Write-Host. probe зображає справжню команду
        # (check друкує саме так), тож і тут повернене значення диспетчер не показує.
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

    # Один контракт кодів (ADR-0014, tools/lib/KitCli.psm1): 0 — виконано; 1 — зупинка (throw
    # префлайту чи команди) або check із помилками; 2 — помилка виклику (невідома команда, розбір
    # аргументів, перетворення типу); 3 — не перевірено; 4 — виконано, є наступний крок (sync: злиття
    # не виконано; verify і session-check: є що робити). Помилка — `<команда>: ERROR …` у stderr.
    It 'без команди — помилка виклику з переліком доступних, код 2' {
        $r = Invoke-Kit @('-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -BeLike '*probe*'
    }

    It 'невідома команда — помилка виклику з переліком доступних, код 2' {
        $r = Invoke-Kit @('frobnicate', '-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Be 2
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
        # Регресійний доказ на саму механіку: -Force — останній токен, наступного
        # значення немає, і диспетчер має розпізнати, що параметр — [switch], а не вимагати
        # значення (як він тепер вимагає для будь-якого іншого типу — тест нижче).
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*force=True*'
    }

    It '-Ref без значення — параметр НЕ [switch], диспетчер вимагає значення, код 2' {
        # Ref — [string], не [switch]: -Ref останнім токеном (значення немає) мав би раніше
        # мовчки зв'язатися як $true (перетворений на рядок 'True') — тепер диспетчер сам
        # зупиняє виклик, ще до Invoke-KitProbe. Той самий механізм, що захищає -Version у
        # verify — тут перевірений на нейтральній probe-команді.
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Ref')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -BeLike '*-Ref*'
        $r.Output | Should -Not -BeLikeExactly '*PROBE*'
    }

    It 'sync: -ForVersion і -SkipVersion оголошені як [Nullable[int]], а не [switch] — тому диспетчер вимагає в них значення' {
        # Текст «потребує значення» диспетчер видає й для НЕвідомого параметра, тож сам він
        # нічого не доводить — доводить оголошений тип у справжній команді.
        $kitDir = Split-Path $script:Kit -Parent
        $out = & pwsh -NoProfile -Command ('Import-Module "{0}" -Force; $p = (Get-Command Invoke-KitSync).Parameters; "ForVersion=$($p[''ForVersion''].ParameterType.FullName)"; "SkipVersion=$($p[''SkipVersion''].ParameterType.FullName)"' -f (Join-Path $kitDir 'commands/sync.psm1')) 2>&1 | Out-String
        $out | Should -Match 'ForVersion=System\.Nullable`1\[\[System\.Int32'
        $out | Should -Match 'SkipVersion=System\.Nullable`1\[\[System\.Int32'
        $r = Invoke-Kit @('sync', '-RepoRoot', $script:Repo, '-ForVersion')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -BeLike '*-ForVersion потребує значення*'
    }

    It 'sync -SkipVersion abc — помилка конверсії саме в Int32 (параметр існує), код 2, не тиха конверсія' {
        $r = Invoke-Kit @('sync', '-RepoRoot', $script:Repo, '-SkipVersion', 'abc')
        $r.ExitCode | Should -Be 2
        # Без англійського речення (локаль PowerShell): ім'я параметра й назва типу Int32 є в
        # будь-якій локалізації, а для невідомого параметра назви типу в тексті немає.
        $r.Output | Should -BeLike '*SkipVersion*'
        $r.Output | Should -BeLike '*System.Int32*'
    }


    It 'verify -Version 0 поза git-репозиторієм — помилка ValidateRange до префлайту, код 2' {
        # Без перевірки до префлайту код залежав би від стану репозиторію: тут префлайт зупинив би кодом 1.
        $dir = Join-Path $TestDrive 'validate-nogit'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-Kit @('verify', '-RepoRoot', $dir, '-Version', '0')
        $r.ExitCode | Should -Be 2 -Because $r.Output
        $r.Output | Should -BeLike '*-Version*'
        $r.Output | Should -Not -BeLike '*.git*'
    }

    It 'команда кидає виняток усередині — код 1, повідомлення показано, не сирий стек' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Throw')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*PROBE-THROW*'
    }

    It 'невідомий власний параметр команди — зупинка, команда не виконана' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Bogus', '1')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -BeLikeExactly '*PROBE*'
    }

    It 'провал префлайту зупиняє до виклику команди' {
        $broken = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken')
        Remove-Item -LiteralPath (Join-Path $broken 'Alpha_SMB/v8project.yaml')
        $r = Invoke-Kit @('probe', '-RepoRoot', $broken)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8project.yaml*'
        $r.Output | Should -Not -BeLikeExactly '*PROBE*'
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

    It 'параметр, якого команда не приймає, — помилка виклику з поясненням, код 2' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unsupported-param')
        $r = Invoke-Kit @('install-hooks', '-RepoRoot', $repo, '-Source', 'Alpha_SMB')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -BeLike '*install-hooks*'
        $r.Output | Should -BeLike '*-Source*'
    }
}

Describe 'Copy-KitTools — повнота пісочниці' {
    # Чому цей Describe існує. Тести запускають kit ПІДПРОЦЕСОМ із копії дерева, яку робить
    # Copy-KitTools, а та копіює фіксований перелік тек. Перелік уже двічі відставав від коду,
    # і обидва рази наслідок був той самий і найгірший з можливих: тест зеленів НЕ З ТІЄЇ
    # ПРИЧИНИ. tools/assets (стаб розширення) і templates/settings.json свого часу ловили
    # живим прогоном.
    # Тут ми не перелічуємо теки вдруге (це була б копія формули, яку follow-ups §4 називає
    # дефектом), а перевіряємо ВЛАСТИВІСТЬ: kit у пісочниці робить те саме, що вдома.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:SandboxKit = Copy-KitTools -Root (Join-Path $TestDrive 'completeness')
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo') -WithHooks -WithGitattributes -WithGitignore
    }

    It 'check у пісочниці не падає на відсутньому файлі плагіна' {
        $out = & (Get-KitExe -Kit $script:SandboxKit) check -RepoRoot $script:Repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) -RunnerPath (Join-Path $PSScriptRoot 'fixtures/runner/v8-runner.cmd') 2>&1 | Out-String
        $code = $LASTEXITCODE
        # Клас «щось не скопіювали» має власний почерк: .NET кидає саме такими фразами,
        # і жодна штатна зупинка kit так не звучить.
        $out | Should -Not -Match 'Cannot find path|не вдалося знайти шлях|ItemNotFoundException|FileNotFoundException'
        $code | Should -Be 0 -Because "у справному репозиторії check має завершитись нулем; вивід:`n$out"
    }
}

Describe 'Інваріант -Apply — прямий виклик диспетчера' {
    # `pwsh -File` сам розщеплює -Ім'я:значення на два токени: `-Apply:false` доходить до скрипта як
    # `-Apply` + `False`. Прийми диспетчер позиційний токен — `sync -Apply:false` застосував би
    # замість прев'ю. Заглушка sync лише в копії: друкує, що отримала, — маркер доводить, чи її кликали.
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:ApplyKit = Copy-KitTools -Root (Join-Path $TestDrive 'apply-kit')
        Set-Content -LiteralPath (Join-Path (Split-Path $script:ApplyKit) 'commands/sync.psm1') -Encoding UTF8 -Value @'
function Invoke-KitSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [string]$Workspace, [string]$Source, [bool]$Apply)
    [Console]::Out.WriteLine("SYNC-STUB apply=$Apply ws=$Workspace src=$Source")
}
Export-ModuleMember -Function Invoke-KitSync
'@
        $script:ApplyRepo = New-KitFakeRepo -Root (Join-Path $TestDrive 'apply-repo')

        function script:Invoke-ApplyKit {
            param([string[]]$Arguments)
            $errFile = Join-Path $TestDrive "apply-err-$([guid]::NewGuid()).txt"
            $out = & pwsh -NoProfile -File $script:ApplyKit @Arguments 2>$errFile
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Out      = (@($out | ForEach-Object { [string]$_ }) -join "`n")
                Err      = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        }
    }

    It 'sync -Apply:false — код 2, stderr називає позиційний токен False, команда не запускалась' {
        $r = Invoke-ApplyKit @('sync', '-RepoRoot', $script:ApplyRepo, '-Apply:false')
        $r.ExitCode | Should -Be 2 -Because ($r.Err -join "`n")
        $r.Err[0] | Should -BeLike "sync: ERROR *'False'*"
        $r.Out | Should -Not -BeLike '*SYNC-STUB*'
    }

    It 'позитивний двійник: sync -Apply — заглушка отримала Apply = True, код 0' {
        $r = Invoke-ApplyKit @('sync', '-RepoRoot', $script:ApplyRepo, '-Apply')
        $r.ExitCode | Should -Be 0 -Because ($r.Err -join "`n")
        $r.Out | Should -BeLike '*SYNC-STUB apply=True*'
    }
}

Describe 'Контракт кодів — кожен код справжньою командою підпроцесом' {
    # Код береться з $LASTEXITCODE підпроцесу справжнього tools/kit.ps1, у множину йде СПОСТЕРЕЖЕНИЙ
    # код, не очікуваний: випадок, що свідомо віддає інший код, червонить останнє твердження.
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1')
        $script:Seen = [System.Collections.Generic.HashSet[int]]::new()
        $script:Plain = Join-Path $TestDrive 'codes-plain'
        New-Item -ItemType Directory -Path $script:Plain -Force | Out-Null
        $script:NoProfile = Join-Path $TestDrive 'codes-no-profile'
        New-Item -ItemType Directory -Path $script:NoProfile -Force | Out-Null
        git -C $script:NoProfile init -q 2>$null
        $script:Good = New-KitFakeRepo -Root (Join-Path $TestDrive 'codes-good') -WithHooks -WithGitattributes -WithGitignore
        $s = New-FakeStorage -Name 'codes-unmerged' -ObjectsWrite $script:Old -DbWrite $script:Old
        $script:Unmerged = New-Repo -Name 'codes-unmerged-repo' -StoragePath $s -MirrorDate $script:New
        $script:Machine = @('-InstalledPluginsPath', (New-KitFakeUnicaRegistry), '-RunnerPath', (Join-Path $PSScriptRoot 'fixtures/runner/v8-runner.cmd'))

        function script:Invoke-CodeContract {
            param([string]$Cwd, [string[]]$Arguments)
            $errFile = Join-Path $TestDrive "codes-err-$([guid]::NewGuid()).txt"
            Push-Location $Cwd
            try {
                # check (блок B3) і session-check (блок B4) виконує kit.exe сам, решту — диспетчер.
                if ($Arguments[0] -in 'check', 'session-check') { $out = & (Get-KitExe -Kit $script:Kit) @Arguments 2>$errFile }
                else { $out = & pwsh -NoProfile -File $script:Kit @Arguments 2>$errFile }
                $code = $LASTEXITCODE
            }
            finally { Pop-Location }
            [pscustomobject]@{
                ExitCode = $code
                Out      = (@($out | ForEach-Object { [string]$_ }) -join "`n")
                Err      = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        }
    }

    It 'код <Code>: <Case>' -ForEach @(
        @{ Code = 0; Case = 'check справного репозиторію'; Cwd = 'Good'; Run = { @('check', '-RepoRoot', $script:Good) + $script:Machine } }
        @{ Code = 1; Case = 'verify поза git-репозиторієм — зупинка префлайту'; Cwd = 'Plain'; ErrLike = 'verify: ERROR *'; Run = { @('verify', '-RepoRoot', $script:Plain) } }
        @{ Code = 2; Case = 'check з невідомим параметром — помилка виклику'; Cwd = 'Good'; ErrLike = 'check: ERROR *-Bogus*'; Run = { @('check', '-RepoRoot', $script:Good, '-Bogus', '1') } }
        @{ Code = 3; Case = 'pr-gate start без workspace.mode у профілі — не перевірено'; Cwd = 'NoProfile'; ErrLike = 'pr-gate: ERROR *workspace.mode*'; Run = { @('pr-gate', 'start', 'x') } }
        @{ Code = 4; Case = 'session-check: дзеркало не злите в main — є наступний крок'; Cwd = 'Unmerged'; Run = { @('session-check', '-RepoRoot', $script:Unmerged) + $script:Machine } }
    ) {
        $r = Invoke-CodeContract -Cwd (Get-Variable -Name $Cwd -Scope Script -ValueOnly) -Arguments (& $Run)
        [void]$script:Seen.Add($r.ExitCode)
        $r.ExitCode | Should -Be $Code -Because "$($r.Out)`n$($r.Err -join "`n")"
        if ($ErrLike) { $r.Err[0] | Should -BeLike $ErrLike }
    }

    It 'множина перевірених кодів = {0,1,2,3,4}' {
        (@($script:Seen) | Sort-Object) -join ',' | Should -Be '0,1,2,3,4'
    }
}
