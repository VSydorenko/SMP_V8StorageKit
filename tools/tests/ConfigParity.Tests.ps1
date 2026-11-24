#Requires -Version 7
# Паритет Rust-префлайту (bin/kit.exe config-preflight) з PowerShell-префлайтом (Invoke-KitPreflight,
# Select-KitSources, функції бази агента) — гейт перенесених команд. Тег Docs не ставити: тест читає код, не документи.
# Кожен випадок — репозиторій з .git (New-KitFakeRepo); порівняння розібраними значеннями, множина ключів кожного
# об'єкта рівна з обох боків. Відомі відмінності (ADR-0021 п. 1) — паритет класом, не текстом.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'fixtures/ConfigParitySetup.ps1')
    . (Join-Path $PSScriptRoot 'fixtures/ConfigParityCases.ps1')
    $corpus = @(Get-ChildItem -LiteralPath $script:ConfigBadDir -Filter '*.yaml' | Sort-Object Name | ForEach-Object { @{ Name = $_.Name; File = $_.FullName } })
    $cases = @(Get-ConfigParityCases | ForEach-Object { $_ })
    $traps = @($script:TrapValues | ForEach-Object { @{ V = $_; Mangled = ($script:TrapMangledByPs -contains $_) } })
    $sizes = @(@{ NCorpus = $corpus.Count; NCases = $cases.Count })
}

Describe 'Rust-префлайт проти PowerShell-префлайту (паритет)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/ConfigParitySetup.ps1')
        . (Join-Path $PSScriptRoot 'fixtures/ConfigParityCases.ps1')
        $script:Modes = 'Strict', 'Lenient', 'Check'
        $script:Runs = @{ Strict = 0; Lenient = 0; Check = 0 }       # порівняння тексту (паритет)
        $script:ClassRuns = @{ Strict = 0; Lenient = 0; Check = 0 }  # відомі відмінності (клас)
        # Базовий добрий репозиторій корпусу: накладка з базою людини робить звірку бази агента активною.
        $script:Baseline = Join-Path $TestDrive 'baseline'
        New-KitFakeRepo -Root $script:Baseline -NoCommit -OverlayText ("infobases:`n  human:`n    connection: '" + 'File=C:\kit-parity-human\ib' + "'") | Out-Null
        $script:Seq = 0
        function script:Get-RunRoot { $script:Seq++; Join-Path $TestDrive "r$($script:Seq)" }
        function script:Invoke-ParityAllModes([string]$Repo, [hashtable]$Select = @{}) {
            $all = [System.Collections.Generic.List[string]]::new()
            foreach ($mode in $script:Modes) {
                foreach ($d in (Compare-ParityRun -Repo $Repo -Mode $mode -Workspace $Select.Workspace -Source $Select.Source -Truth $(if ($Select.Truth) { @($Select.Truth) } else { @() }) -OrderInsensitive:([bool]$Select.OrderInsensitive))) { $all.Add("[$mode] $d") }
                $script:Runs[$mode]++
            }
            $all.ToArray()
        }
    }

    Context 'корпус неправильних файлів config-bad (кожен клас throw)' {
        It '<Name>' -ForEach $corpus {
            $m = Read-ConfigBadFixture $File
            $repo = Copy-ParityBaseline $script:Baseline (Get-RunRoot)
            Install-ConfigBadFixture $m $repo

            # PowerShell-бік: фікстура справді дає заявлені перевірку й початок тексту (інакше «покритий клас» — вигадка).
            $ps = Get-PsParityResult -Repo $repo -Mode Lenient
            $p = Get-FirstProblem $ps
            $p[0] | Should -BeExactly $m.check -Because "PowerShell: перевірка ($($p[1]))"
            if ($m.check -ne 'none') {
                $want = Expand-ParityStarts $m.starts $repo $m.target
                $p[1].StartsWith($want) | Should -BeTrue -Because "PowerShell: «$($p[1])» має починатись з «$want»"
            }
            if ($m.check -in 'manifest', 'overlay', 'workspace', 'source') {
                (Get-PsParityResult -Repo $repo -Mode Strict).stop.message | Should -BeExactly $p[1]
            }

            if ($m.parity -eq 'text') {
                @(Invoke-ParityAllModes $repo) | Should -BeNullOrEmpty
            } else {
                # Відома відмінність: Rust свій клас і свій початок тексту; PowerShell — як заявлено вище.
                # Закритий перелік: без рішення з переліку (чи з невідомим ідентифікатором) клас нічого не доводить.
                $m['decision'] | Should -Not -BeNullOrEmpty -Because 'класова фікстура мусить мати #@ decision: KD-n'
                $m['decision'] | Should -BeIn $script:KnownDifferences -Because "ідентифікатор рішення «$($m['decision'])» поза закритим переліком відомих відмінностей"
                foreach ($mode in $script:Modes) {
                    $rs = Invoke-RustPreflight -Repo $repo -Mode $mode
                    $rs.Code | Should -Be 0
                    $rp = Get-FirstProblem $rs.Tree
                    $wantCheck = if ($m['rust-check'] -in 'manifest', 'overlay', 'workspace', 'source' -and $mode -eq 'Strict') { 'stop' } else { $m['rust-check'] }
                    $rp[0] | Should -BeExactly $wantCheck -Because "Rust [$mode]: $($rp[1])"
                    $wantText = Expand-ParityStarts $m['rust-starts'] $repo $m.target
                    $rp[1].StartsWith($wantText) | Should -BeTrue -Because "Rust [$mode]: «$($rp[1])» має починатись з «$wantText»"
                    if ($mode -eq 'Strict' -and $rs.Tree.stop) { $rs.Tree.stop.check | Should -BeExactly $m['rust-check'] }
                    # Лише перша проблема — не весь клас: друга знахідка error, а також помилка бази агента чи перетинів
                    # з іншим текстом — червоне, якщо фікстура не декларує її початок у rust-also.
                    @($rs.Tree.findings | Where-Object { $_.level -eq 'error' }).Count | Should -BeLessOrEqual 1 -Because "Rust [$mode]: друга знахідка error на класовій фікстурі"
                    $wantAlso = if ($m.Contains('rust-also')) { Expand-ParityStarts $m['rust-also'] $repo $m.target } else { $wantText }
                    foreach ($x in @(Get-ExtraProblems $rs.Tree)) {
                        $x[1].StartsWith($wantAlso) | Should -BeTrue -Because "Rust [$mode]: друга проблема ($($x[0])) «$($x[1])» має починатись з «$wantAlso» (того ж класу) або фікстура декларує rust-also"
                    }
                    $script:ClassRuns[$mode]++
                }
            }
        }
    }

    Context 'зразки, фікстури маніфесту, накладки, junction' {
        It '<Name>' -ForEach $cases {
            $repo = New-ParityRepo -Spec $Spec -Root (Get-RunRoot)
            # Добрий випадок: PowerShell-бік САМ стверджує Ok і відсутність знахідок error — без цього «однакова помилка
            # з обох боків» давала б зелене (паритет не доводить, що вхід добрий).
            $good = if ($Expect.ContainsKey('Good')) { [bool]$Expect.Good } else { -not $Spec.NoManifest }
            if ($good) {
                $psCtx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
                $bad = @($psCtx.Findings | Where-Object { $_.Level -eq 'error' } | ForEach-Object { "$($_.Check): $($_.Message)" })
                $bad | Should -BeNullOrEmpty -Because 'добрий випадок не мусить мати знахідок error (manifest/workspace/overlay/source)'
                $psCtx.Ok | Should -BeTrue
            }
            @(Invoke-ParityAllModes $repo @{ OrderInsensitive = [bool]$Expect.OrderInsensitive }) | Should -BeNullOrEmpty
            foreach ($sel in $Selects) { @(Invoke-ParityAllModes $repo $sel) | Should -BeNullOrEmpty }

            if ($Expect.ModesDiffer) {
                # Три режими — три різні результати (інакше випадок не відрізняє режимів).
                $json = foreach ($mode in $script:Modes) { (Invoke-RustPreflight -Repo $repo -Mode $mode).Stdout }
                @($json | Sort-Object -Unique).Count | Should -Be 3
            }
            if ($Expect.PsAgentBaseError -or $Expect.PsCollisions) {
                $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
                $found = $false
                foreach ($ws in $ctx.Workspaces) {
                    $err = $null; $coll = @()
                    try { Resolve-KitAgentBase -Context $ctx -Workspace $ws | Out-Null } catch { $err = $_.Exception.Message }
                    try { $coll = @(Find-KitAgentBaseCollisions -Context $ctx -Workspace $ws) } catch { $err = $_.Exception.Message }
                    if ($Expect.PsAgentBaseError -and $err -and $err.Contains($Expect.PsAgentBaseError)) { $found = $true }
                    if ($Expect.PsCollisions -and $coll.Count -gt 0) { $found = $true }
                }
                $found | Should -BeTrue -Because 'PowerShell має бачити перетин через junction'
                # Лексичні (GetFullPath) форми шляхів не перетинаються — саме так перетин пропустило б лексичне порівняння.
                $a = [System.IO.Path]::GetFullPath((Join-Path $repo $(if ($Expect.PsCollisions) { 'B/build/ib' } else { 'Alpha_SMB/build/ib' })))
                $b = [System.IO.Path]::GetFullPath((Join-Path $repo $(if ($Expect.PsCollisions) { 'A/.local/infobases/origin' } else { 'human/ib' })))
                $lexical = & (Get-Module AgentBase) { param($x, $y) Test-KitCanonicalPathsOverlap -Left $x -Right $y } $a $b
                $lexical | Should -BeFalse
            }
        }
    }

    Context 'скаляри-пастки у несекретних полях' {
        It 'пастка <V>' -ForEach $traps {
            $specs = Get-TrapSpecs $V
            foreach ($kind in $specs.Keys) {
                $repo = New-ParityRepo -Spec $specs[$kind] -Root (Get-RunRoot)
                if (-not $Mangled) {
                    @(Invoke-ParityAllModes $repo) | Should -BeNullOrEmpty -Because "значення $V (відомих змін PowerShell немає — паритет буквальний)"
                    continue
                }
                # Відома відмінність 3: PowerShell перетворює значення (0123 -> 123), Rust віддає текст з файла.
                @(Compare-ParityRun -Repo $repo -Mode Lenient).Count | Should -BeGreaterThan 0 -Because "PowerShell ще змінює $V (інакше запис відомої відмінності застарів)"
                foreach ($mode in 'Lenient', 'Check') {
                    $t = (Invoke-RustPreflight -Repo $repo -Mode $mode).Tree
                    $t.stop | Should -BeNullOrEmpty
                    if ($kind -eq 'B') {
                        $t.context.manifest.workspaces[0] | Should -BeExactly $V
                        $t.context.workspaces[0].path | Should -BeExactly $V
                    } else {
                        $t.context.label | Should -BeExactly $V
                        $t.context.mainBranch | Should -BeExactly $V
                        $t.context.manifest.mainBranch | Should -BeExactly $V
                        $src = @($t.context.workspaces[0].sources | Where-Object { $_.truth -eq 'storage' })[0]
                        $src.key | Should -BeExactly $V
                        $src.storageUser | Should -BeExactly $V
                        @($t.context.workspaces[0].sources | Where-Object { $_.truth -eq 'vendor' })[0].dumpFrom | Should -BeExactly $V
                        $t.context.overlay.storages[0].user | Should -BeExactly $V
                        $t.context.overlay.infobases[0].user | Should -BeExactly $V
                        $t.context.workspaces[0].agentBase.base.user | Should -BeExactly $V
                    }
                    $script:ClassRuns[$mode]++
                }
            }
        }
    }

    Context 'корінь репозиторію' {
        It 'корінь не існує і не git-репозиторій — той самий текст зупинки в усіх режимах' {
            $missing = Join-Path $TestDrive 'no-such-root'
            $plain = Join-Path $TestDrive 'plain'; New-Item -ItemType Directory -Path $plain | Out-Null
            foreach ($root in $missing, $plain) {
                foreach ($mode in $script:Modes) {
                    $ps = Get-PsParityResult -Repo $root -Mode $mode
                    $rs = Invoke-RustPreflight -Repo $root -Mode $mode
                    $rs.Tree.stop.message | Should -BeExactly $ps.stop.message
                    $rs.Tree.stop.check | Should -BeNullOrEmpty
                    $script:Runs[$mode]++
                }
            }
        }
    }

    # Контроль порожнього розгортання: каталоги порожні чи тест нічого не порівняв — червоне, а не «зелене нічого».
    Context 'межа кількості випадків' {
        It 'корпус і каталог розгорнуто не порожніми' -ForEach $sizes {
            $NCorpus | Should -BeGreaterOrEqual 130
            $NCases | Should -BeGreaterOrEqual 30
        }
        It 'у кожному з трьох режимів порівняно не менше випадків паритету й відомих відмінностей' {
            Write-Host ("ConfigParity: порівнянь тексту Strict/Lenient/Check = $($script:Runs.Strict)/$($script:Runs.Lenient)/$($script:Runs.Check); відомих відмінностей (клас) = $($script:ClassRuns.Strict)/$($script:ClassRuns.Lenient)/$($script:ClassRuns.Check)")
            foreach ($mode in $script:Modes) {
                $script:Runs[$mode] | Should -BeGreaterOrEqual 200 -Because "порівнянь тексту в режимі $mode"
            }
            foreach ($mode in 'Strict', 'Lenient', 'Check') {
                $script:ClassRuns[$mode] | Should -BeGreaterOrEqual 15 -Because "випадків відомих відмінностей у режимі $mode"
            }
        }
    }
}
