#Requires -Version 7
# kit.exe session-check: коди виходу, відбиток сховища як точна відповідь, стан «сховище
# прочитано не повністю», серверне сховище, паралельні читання (ADR-0021 п. 2, 6). Підпроцес —
# справжній bin/kit.exe копії (Invoke-KitCommand), синтетичні сховища й репозиторії; платформи, мережі, Уніки немає.
Describe 'kit session-check — коди, відбиток, читання сховищ' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1')
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/Preflight.psm1").Path -Force
        $script:Who = "$env:USERDOMAIN\$env:USERNAME"

        # Заборона читання теки поточному користувачеві (успадковується вниз). Знімається в finally кожного тесту —
        # інакше TestDrive не прибереться.
        function script:Deny-Read([string]$Path) {
            & icacls $Path /deny "$($script:Who):(OI)(CI)R" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls /deny не спрацював для $Path" }
        }
        function script:Allow-Read([string]$Path) { & icacls $Path /remove:d $script:Who | Out-Null }

        # Репозиторій із кількома джерелами truth: storage (розширення в одному воркспейсі), дзеркала злито в main —
        # без втручання сигнал кожного джерела «синхронне» (код 0). $Storages: ім'я джерела → шлях сховища.
        function script:New-MultiRepo {
            param([string]$Name, [System.Collections.Specialized.OrderedDictionary]$Storages)
            $sets = @(foreach ($k in $Storages.Keys) { @{ Name = $k; Type = 'EXTENSION'; Path = "cfe/$k/src" } })
            $ws = [ordered]@{ 'Client' = @{ Infobase = 'File=build/ib'; Sets = $sets } }
            $overlay = 'storages:' + (($Storages.Keys | ForEach-Object { "`n  ${_}: '$($Storages[$_])'" }) -join '')
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces $ws -OverlayText $overlay -WithHooks -WithGitattributes -WithGitignore
            $stamp = $script:Old.ToString('yyyy-MM-ddTHH:mm:ss')
            $env:GIT_AUTHOR_DATE = $stamp; $env:GIT_COMMITTER_DATE = $stamp
            try {
                foreach ($k in $Storages.Keys) {
                    Add-KitFakeStorageCommit -Repo $repo -Branch "storage/$k" -RepoPath "Client/cfe/$k/src" -FileName 'a.xml' -Trailers @("Storage-Source: $k", 'Storage-Version: 1')
                    Merge-KitBranchInto -RepoRoot $repo -Branch "storage/$k" -Into 'main' -Message "перше $k" -AllowUnrelated | Out-Null
                }
            } finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath (Join-Path $repo 'build') -Recurse -Force -ErrorAction SilentlyContinue
            $repo
        }
        function script:Run-Json([string]$Repo, [string[]]$More = @()) {
            $r = Invoke-SessionCheck -Repo $Repo -More (@('-AsJson') + $More)
            [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Signals = @($r.Output | ConvertFrom-Json) }
        }
    }

    Context 'виклик' {
        It 'корінь не git-репозиторій → код 1, перший рядок «session-check: ERROR …»' {
            $dir = Join-Path $TestDrive 'not-git'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $r = Invoke-SessionCheck -Repo $dir
            $r.ExitCode | Should -Be 1 -Because $r.Output
            @($r.Output -split "`r?`n")[0] | Should -BeLike 'session-check: ERROR *'
        }
        It '-Help → usage і код 0; -Apply (команда нічого не мутує) → код 2, «невідомий параметр -Apply»' {
            $dir = Join-Path $TestDrive 'not-git'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $h = Invoke-SessionCheck -Repo $dir -More @('-Help')
            $h.ExitCode | Should -Be 0
            $h.Output | Should -BeLike 'usage: kit session-check*'
            $a = Invoke-SessionCheck -Repo $dir -More @('-Apply')
            $a.ExitCode | Should -Be 2
            $a.Output | Should -BeLike '*session-check: ERROR невідомий параметр -Apply*'
        }
        It 'невідоме ім''я джерела → код 2 із переліком наявних, а не порожній вивід' {
            $s = New-FakeStorage -Name 'usage-src' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'usage-src' -StoragePath $s -MirrorDate $script:Old -Merge
            $r = Invoke-SessionCheck -Repo $repo -More @('-Source', 'Нема')
            $r.ExitCode | Should -Be 2
            $r.Output | Should -BeLike "*session-check: ERROR Джерела 'Нема' немає у маніфесті. Є: Alpha_SMB, base.*"
        }
    }

    Context 'відбиток сховища: паритет із sync і звірка без допуску' {
        # sync пише відбиток зі StoragePath джерела, яке дав PowerShell-префлайт (Write-KitStorageImprint -StoragePath
        # $src.StoragePath). Шлях у накладці навмисно в формі, яку легко записати інакше, ніж прочитати: `/` замість `\`
        # після диска і кінцевий `\` (відносний шлях префлайт відхиляє формою, тож його тут бути не може). Rust-префлайт
        # мусить прочитати той самий рядок і привʼязати до нього відбиток.
        BeforeAll {
            function script:New-ParityCase {
                param([string]$Name, [int]$Packs = 1, [switch]$Unmerged)
                $s = New-FakeStorage -Name $Name -ObjectsWrite $script:Old -DbWrite $script:Old -PackWrite $script:Old
                for ($i = 2; $i -le $Packs; $i++) {
                    $p = Join-Path $s "data/pack/$i.pack"; Set-Content -LiteralPath $p -Value "pack$i"
                    (Get-Item $p).LastWriteTimeUtc = $script:Old.ToUniversalTime().AddSeconds($i)
                }
                $written = $s.Substring(0, 3) + $s.Substring(3).Replace('\', '/') + '\'
                $repo = New-Repo -Name $Name -StoragePath $written -MirrorDate $script:Old -Merge:(-not $Unmerged)
                $ctx = Invoke-KitPreflight -RepoRoot $repo -Mode Lenient
                $src = @(Select-KitSources -Context $ctx -Truth storage)[0]
                $src.StoragePath | Should -BeExactly $written -Because 'відбиток пишеться з того, що віддає префлайт'
                Write-KitStorageImprint -RepoRoot $repo -Key $src.Key -StoragePath $src.StoragePath -Version 1 | Out-Null
                [pscustomobject]@{ Repo = $repo; Storage = $s }
            }
            $script:Exact = '*на версії 1, main містить усе (відбиток прочитано *UTC)*'
        }
        It 'синхронний відбиток: «main містить усе» лише коли незлитих комітів немає' {
            $merged = New-ParityCase -Name 'parity-merged'
            (Invoke-SessionCheck -Repo $merged.Repo).Output | Should -BeLike $script:Exact
            $c = New-ParityCase -Name 'parity-unmerged' -Unmerged
            $r = Invoke-SessionCheck -Repo $c.Repo
            $r.Output | Should -BeLike '*синхронне зі сховищем на версії 1 (відбиток прочитано *UTC)*'
            $r.Output | Should -Not -BeLike '*містить усе*'
            $r.Output | Should -BeLike '*не злиті в main*'
        }
        It 'відбиток із префлайт-шляхом (`/` після диска, кінцевий `\`) дає «синхронне на версії 1», код 0' {
            $c = New-ParityCase -Name 'parity-ok'
            $r = Invoke-SessionCheck -Repo $c.Repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -BeLike $script:Exact
        }
        It 'контроль: час одного pack-файла зсунуто на 1 тик (100 нс) — відбиток не актуальний' {
            $c = New-ParityCase -Name 'parity-tick'
            $pack = Get-Item (Join-Path $c.Storage 'data/pack/1.pack')
            $pack.LastWriteTimeUtc = $pack.LastWriteTimeUtc.AddTicks(1)
            $r = Invoke-SessionCheck -Repo $c.Repo
            $r.Output | Should -Not -BeLike $script:Exact -Because 'допуску немає: байти порівнюються точно'
            $r.Output | Should -BeLike '*- Alpha_SMB:*'
        }
        It 'контроль: новий .pack у сховищі — відбиток не актуальний' {
            $c = New-ParityCase -Name 'parity-newpack'
            Set-Content -LiteralPath (Join-Path $c.Storage 'data/pack/9.pack') -Value 'new'
            (Get-Item (Join-Path $c.Storage 'data/pack/9.pack')).LastWriteTimeUtc = $script:Old.ToUniversalTime()
            $r = Invoke-SessionCheck -Repo $c.Repo
            $r.Output | Should -Not -BeLike $script:Exact
        }
        It 'сховище з трьома .pack: відбиток актуальний, а зсув ОДНОГО з них на 1 тик його скасовує' {
            $c = New-ParityCase -Name 'parity-three' -Packs 3
            (Invoke-SessionCheck -Repo $c.Repo).Output | Should -BeLike $script:Exact
            $second = Get-Item (Join-Path $c.Storage 'data/pack/2.pack')
            $second.LastWriteTimeUtc = $second.LastWriteTimeUtc.AddTicks(1)
            (Invoke-SessionCheck -Repo $c.Repo).Output | Should -Not -BeLike $script:Exact
        }
        It 'відбиток чужого шляху (інше сховище того ж ключа) не актуальний, хоч диск збігається' {
            $c = New-ParityCase -Name 'parity-bound'
            $other = New-FakeStorage -Name 'parity-bound-other' -ObjectsWrite $script:Old -DbWrite $script:Old -PackWrite $script:Old
            Write-KitStorageImprint -RepoRoot $c.Repo -Key 'Alpha_SMB' -StoragePath $other -Version 1 | Out-Null
            (Invoke-SessionCheck -Repo $c.Repo).Output | Should -Not -BeLike $script:Exact
        }
    }

    Context 'серверне сховище (tcp://): відбиток ніколи не актуальний, причина server, код 0' {
        It 'відбиток PowerShell sync для tcp:// не дає «синхронне»; NewInStorageReason = server; код рівно 0; без next:' {
            $repo = New-Repo -Name 'server-imprint' -StoragePath 'tcp://srv.invalid/stor' -MirrorDate $script:Old -Merge
            # sync пише відбиток і для серверної адреси: порожній стан диска «збігається» з порожнім.
            Write-KitStorageImprint -RepoRoot $repo -Key 'Alpha_SMB' -StoragePath 'tcp://srv.invalid/stor' -Version 1 | Out-Null
            $r = Invoke-SessionCheck -Repo $repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -BeLike "*- Alpha_SMB: серверне сховище: нові версії session-check не перевіряє — перевірити вручну: kit sync -Source Alpha_SMB (прев'ю показує нові версії).*"
            $r.Output | Should -Not -BeLike '*(відбиток прочитано*'
            @($r.Output -split "`r?`n" | Where-Object { $_ -like 'next:*' }) | Should -HaveCount 0
            $j = Run-Json -Repo $repo
            $j.ExitCode | Should -Be 0
            $j.Signals[0].NewInStorageReason | Should -Be 'server'
            $j.Signals[0].NewInStorage | Should -BeFalse
            $j.Signals[0].Accessible | Should -BeFalse
        }
    }

    Context 'сховище прочитано не повністю: partial-read → код 3' {
        It 'заборона читання підтеки data/objects посеред обходу → код РІВНО 3, текст із класом помилки без шляху, причина partial-read' {
            $s = New-FakeStorage -Name 'partial' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'partial' -StoragePath $s -MirrorDate $script:Old -Merge
            $denied = Join-Path $s 'data/objects/ab'
            Deny-Read $denied
            try {
                $r = Invoke-SessionCheck -Repo $repo
                $j = Run-Json -Repo $repo
            } finally { Allow-Read $denied }
            $r.ExitCode | Should -Be 3 -Because $r.Output
            $r.Output | Should -BeLike '*- Alpha_SMB: стан сховища прочитано не повністю (немає доступу) — нові версії не виключено.*'
            $r.Output.Contains($s) | Should -BeFalse -Because 'шлях не друкується'
            $j.ExitCode | Should -Be 3
            $j.Signals[0].NewInStorageReason | Should -Be 'partial-read'
            $j.Signals[0].Accessible | Should -BeTrue
        }
        It 'контроль: без заборони те саме сховище — код 0 (3 дає саме помилка читання)' {
            $s = New-FakeStorage -Name 'partial-ctl' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-Repo -Name 'partial-ctl' -StoragePath $s -MirrorDate $script:Old -Merge
            (Invoke-SessionCheck -Repo $repo).ExitCode | Should -Be 0
        }
        It 'partial-read одного джерела разом із GitProblem іншого → код РІВНО 1 (1 > 3), обидва рядки на місці' {
            $a = New-FakeStorage -Name 'mix-a' -ObjectsWrite $script:Old -DbWrite $script:Old
            $b = New-FakeStorage -Name 'mix-b' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-MultiRepo -Name 'mix' -Storages ([ordered]@{ ExtA = $a; ExtB = $b })
            $sha = (git -C $repo rev-parse storage/ExtB).Trim()
            Remove-Item -LiteralPath (Join-Path $repo ".git/objects/$($sha.Substring(0, 2))/$($sha.Substring(2))") -Force
            $denied = Join-Path $a 'data/objects/ab'
            Deny-Read $denied
            try { $r = Invoke-SessionCheck -Repo $repo } finally { Allow-Read $denied }
            $r.ExitCode | Should -Be 1 -Because $r.Output
            $r.Output | Should -BeLike '*- ExtA: стан сховища прочитано не повністю*'
            $r.Output | Should -BeLike '*- ExtB: стан git не прочитано*'
        }
    }

    Context 'кілька недоступних сховищ не гальмують решту' {
        # Справжньої «висячої» теки без мережі не зробити (мережевий шлях без хоста відмовляє одразу): що читання йдуть
        # паралельно й зі стелею, доводить Rust-тест `several_hanging_sources_cost_one_ceiling_not_a_sum` на шві
        # читання; цей тест перевіряє лише порядок рядків і те, що недоступні джерела не роблять решту «невідомими»
        # (часова межа нижче — груба страховка, не доказ паралельності).
        It 'порядок рядків і недоступні джерела не роблять решту невідомими: три недоступні сховища (немає / мережевий шлях / немає в неіснуючій теці) + одне справне: усі рядки на місці в порядку маніфесту, код 0, у межах стелі хука з запасом' {
            $good = New-FakeStorage -Name 'par-good' -ObjectsWrite $script:Old -DbWrite $script:Old
            $repo = New-MultiRepo -Name 'parallel' -Storages ([ordered]@{
                    ExtA = (Join-Path $TestDrive 'par-missing')
                    ExtB = '\\192.0.2.1\kit-test-no-such-share'
                    ExtC = (Join-Path $TestDrive 'par-no-parent\deeper\storage')
                    ExtD = $good
                })
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-SessionCheck -Repo $repo
            $sw.Stop()
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -BeLike '*- ExtA: сховище недоступне на цій машині (каталог недоступний:*'
            $r.Output | Should -BeLike '*- ExtB: сховище недоступне на цій машині*'
            $r.Output | Should -BeLike '*- ExtC: сховище недоступне на цій машині (каталог недоступний:*'
            $r.Output | Should -BeLike '*- ExtD: дзеркало синхронне зі сховищем, main містить усе.*'
            $order = 'ExtA', 'ExtB', 'ExtC', 'ExtD' | ForEach-Object { $r.Output.IndexOf("- ${_}:") }
            $order | Should -Be ($order | Sort-Object) -Because 'рядки йдуть у порядку джерел маніфесту'
            # Стеля хука — 15 с (за умовчанням); читання кожного сховища має власну стелю 5 с і йде паралельно з рештою.
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 12 -Because "недоступні сховища коштують не більше однієї стелі читання, замір: $($sw.Elapsed.TotalSeconds) с"
        }
    }
}
