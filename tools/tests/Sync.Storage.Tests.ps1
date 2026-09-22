#Requires -Version 7
Describe 'kit sync — реальне сховище (перший і повторний реплей)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:Storage = 'R:\СховищаРозширень_1С\СМП_BankExchange_SMB'   # живе сховище розширення; лише читання
        $script:Authors = 'R:\github\SMP_BankExchange\AUTHORS'

        function script:Invoke-Sync {
            param([string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        # Невідомих авторів (нові користувачі сховища після останнього оновлення AUTHORS) — у тестову мапу.
        function script:Complete-Authors {
            param([string]$Repo, [string]$Output)
            $added = $false
            foreach ($line in ($Output -split "`r?`n")) {
                if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") {
                    Add-Content -LiteralPath (Join-Path $Repo 'AUTHORS') -Encoding UTF8 -Value "$($Matches.u)=Test Author <test@example.invalid>"
                    $added = $true
                }
            }
            $added
        }

        $ws = [ordered]@{ 'SMP_BankExchange_SMB' = @{ Infobase = 'File=build/ib'; Sets = @(
            @{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }, @{ Name = 'SMP_BankExchange_SMB'; Type = 'EXTENSION'; Path = 'cfe/src' }) } }
        $manifest = @('version: 1', 'kitVersion: 1.0.1', 'product: BankExchange', 'workspaces:', '  - path: SMP_BankExchange_SMB', '    sources:',
            '      base: { truth: vendor, dump: { from: devUNF } }',
            '      SMP_BankExchange_SMB:', '        truth: storage', "        storage: { path: '$script:Storage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'live') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes -WithGitignore
        Copy-Item -LiteralPath $script:Authors -Destination (Join-Path $script:Repo 'AUTHORS') -Force
        # F9: фікстура кладе на main фейковий Configuration.xml за тим самим шляхом, куди дзеркало покладе
        # справжній — перше злиття дало б add/add-конфлікт. У реальному онбордингу дерева на main ще немає.
        git -C $script:Repo rm -rq -- SMP_BankExchange_SMB/cfe/src
        git -C $script:Repo add -A; git -C $script:Repo commit -q -m 'AUTHORS з живого репо; дерево джерела порожнє до першого sync'
    }

    It 'сховище доступне (передумова)' {
        $script:Storage | Should -Exist
    }

    It 'прев''ю без -Apply нічого не міняє в git' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        if (Complete-Authors -Repo $script:Repo -Output $r.Output) {
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = Invoke-Sync -Repo $script:Repo -More @('-MaxVersions', '2')
        }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*попередній перегляд*'
        (git -C $script:Repo branch --list 'storage/*') | Should -BeNullOrEmpty
    }

    It 'перший реплей: дві версії в storage/X, трейлери, перше злиття в main, дерево під шляхом джерела' {
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '2')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $commits = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB')
        $commits.Count | Should -Be 2
        $commits[0].Parents.Count | Should -Be 0
        $commits[1].Trailers['Storage-Source'] | Should -Be 'SMP_BankExchange_SMB'
        [int]$commits[1].Trailers['Storage-Version'] | Should -BeGreaterThan ([int]$commits[0].Trailers['Storage-Version'])
        # -c core.quotepath=false — той самий дефект, що в StorageBranch.psm1: без прапорця
        # git ls-tree квотує кириличні імена (SMP_BankExchange_SMB тримає такі об'єкти), і
        # -notlike вище хибно вважав би їх "поза шляхом".
        @(git -c core.quotepath=false -C $script:Repo ls-tree -r --name-only storage/SMP_BankExchange_SMB | Where-Object { $_ -notlike 'SMP_BankExchange_SMB/cfe/src/*' }).Count | Should -Be 0
        git -C $script:Repo merge-base --is-ancestor storage/SMP_BankExchange_SMB main
        $LASTEXITCODE | Should -Be 0
        Join-Path $script:Repo 'SMP_BankExchange_SMB/cfe/src/Configuration.xml' | Should -Exist
        Join-Path $script:Repo 'build/sync/SMP_BankExchange_SMB/wt' | Should -Not -Exist
        (git -C $script:Repo status --porcelain) | Should -BeNullOrEmpty
    }

    It 'повторний реплей: ще одна версія, main не чіпається (звірочний коміт — verify, B3)' {
        $mainBefore = git -C $script:Repo rev-parse main
        $r = Invoke-Sync -Repo $script:Repo -More @('-Apply', '-MaxVersions', '1')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/SMP_BankExchange_SMB').Count | Should -Be 3
        (git -C $script:Repo rev-parse main) | Should -Be $mainBefore
    }

    It 'kit check після реплею — без помилок' {
        $out = & pwsh -NoProfile -File $script:Kit check -RepoRoot $script:Repo 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

Describe 'kit sync — сховище КОНФІГУРАЦІЇ (без -Extension)' -Tag Integration {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/StorageBranch.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        # Найменше живе сховище конфігурації — знайдене спайком Task 1 (progress.md, «Спайк раунд 1»):
        # КормЦентр_DEV, 1cv8ddb.1CD = 1,27 МБ. Обхід змінною середовища — щоб підставити інше
        # сховище без правки тесту (рішення архітектора).
        $script:CfgStorage = if ($env:V8KIT_CFG_STORAGE) { $env:V8KIT_CFG_STORAGE } else { 'R:\СховищаКонфігурацій_1С\КормЦентр_DEV' }
        $ws = [ordered]@{ 'Client_UNF' = @{ Infobase = 'File=build/ib'; Sets = @(@{ Name = 'base'; Type = 'CONFIGURATION'; Path = 'cf/src' }) } }
        $manifest = @('version: 1', 'kitVersion: 1.0.1', 'client: Client', 'workspaces:', '  - path: Client_UNF', '    sources:',
            '      base:', '        truth: storage', "        storage: { path: '$script:CfgStorage' }") -join "`n"
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'cfg') -Workspaces $ws -ManifestText $manifest -WithHooks -WithGitattributes
        # Шаблонний templates/gitignore тут не годиться: його правило **/cf/** ігнорувало б
        # САМЕ дерево cf/src, яке цей тест перевіряє (тут truth: storage, не vendor). Але без
        # ЖОДНОГО .gitignore build/sync/<key>/ (worktree й робочі файли, які sync створює на
        # час реплею) лишається невідстеженим — робоча копія "брудна", і Merge-KitBranchInto
        # штатно відмовляється зливати в брудний main (саме це спіймав перший живий
        # Integration-прогін тут, а не CRLF-попередження git — core.autocrlf тут false,
        # KitFixtures.psm1:83). Тому свій мінімальний .gitignore, без **/cf/**, і одразу
        # закомічений — незакомічений .gitignore сам був би untracked-файлом і так само
        # забруднив би git status --porcelain.
        Set-Content -LiteralPath (Join-Path $script:Repo '.gitignore') -Encoding UTF8 -Value (
            @('build/', '.build/', 'v8storagekit.local.yaml', 'v8project.local.yaml') -join "`n")
        git -C $script:Repo add -A
        git -C $script:Repo commit -q -m 'мінімальний .gitignore без **/cf/** — cf/src тут truth: storage'
    }

    It 'перша версія конфігурації лягає в storage/base з Config-Version і деревом під Client_UNF/cf/src' {
        $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        if ($r -match "=Ім'я <пошта>") {
            foreach ($line in ($r -split "`r?`n")) { if ($line -match "^\s+(?<u>.+?)=Ім'я <пошта>\s*$") { Add-Content (Join-Path $script:Repo 'AUTHORS') "$($Matches.u)=Test Author <test@example.invalid>" -Encoding UTF8 } }
            git -C $script:Repo commit -qam 'AUTHORS: тестові автори'
            $r = & pwsh -NoProfile -File $script:Kit sync -RepoRoot $script:Repo -Apply -MaxVersions 1 2>&1 | Out-String
        }
        $LASTEXITCODE | Should -Be 0 -Because $r
        $c = @(Get-KitBranchCommits -RepoRoot $script:Repo -Ref 'storage/base')
        $c.Count | Should -Be 1
        $c[0].Trailers.Contains('Extension-Version') | Should -BeFalse
        Join-Path $script:Repo 'Client_UNF/cf/src/Configuration.xml' | Should -Exist
    }
}
