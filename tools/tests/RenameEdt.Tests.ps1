#Requires -Version 7
<#
Тести Step 3 і Step 3а (B6 Task 3, §9.2) — мали впасти ДО commands/rename-edt.psm1: команди
не існувало, kit.ps1 відповідав "Невідома команда 'rename-edt'". Ризик задачі — `властивість
безпеки` (task-3-brief.md): команда переписує чуже дерево через git mv. Дві властивості, які
рев'ю перевіряє окремо:
  1. Жоден файл не видаляється без показу людині (Unmapped — повний перелік, видалення лише
     під -Apply).
  2. Колізія двох EDT-файлів в один Designer-шлях ЗУПИНЯЄ до першого git mv — дерево лишається
     незміненим (перевіряється через git status/rev-parse HEAD, а не лише текст винятку).
#>
Describe 'kit rename-edt — коміт перейменування EDT -> Designer (§9.2, властивість безпеки)' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        function script:Invoke-TestGit {
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
            $out = & git -C $Repo @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') завершився з кодом ${LASTEXITCODE}: $($out -join "`n")" }
            $out
        }

        function script:Invoke-RenameEdt {
            param([Parameter(Mandatory)][string]$Repo, [string[]]$More = @())
            $out = & pwsh -NoProfile -File $script:Kit rename-edt -RepoRoot $Repo @More 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }

        function script:Add-KitFakeEdtTree {
            <#
            .SYNOPSIS
                Найпростіше EDT-дерево (один CommonModule: дескриптор + Module.bsl) під
                <Repo>/<Rel> — окремим комітом, як штатний наступний коміт gitsync-репозиторію.
            #>
            param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Rel)
            $dir = Join-Path $Repo (Join-Path $Rel 'CommonModules/ОбщегоНазначения')
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'ОбщегоНазначения.mdo') -Value '<MetaDataObject/>' -Encoding UTF8 -NoNewline
            Set-Content -LiteralPath (Join-Path $dir 'Module.bsl') -Value "Процедура Тест()`nКонецПроцедуры" -Encoding UTF8 -NoNewline
            Invoke-TestGit -Repo $Repo -GitArgs @('add', '-A') | Out-Null
            Invoke-TestGit -Repo $Repo -GitArgs @('commit', '-q', '-m', 'gitsync: версія сховища (EDT-дерево)') | Out-Null
        }
    }

    It 'позитивний шлях: git mv (R, не D+A), git log --follow безперервний, вміст лишається EDT-ним' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'positive') -WithGitattributes
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Be 0 -Because $r.Output

        $oldPath = 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl'
        $newPath = 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения/Ext/Module.bsl'
        (Join-Path $repo $newPath) | Should -Exist
        (Join-Path $repo $oldPath) | Should -Not -Exist
        (Join-Path $repo 'Alpha_SMB/cfe/src/CommonModules/ОбщегоНазначения.xml') | Should -Exist

        # Не Remove+Add: diff-tree самого коміту перейменування показує R100, а не окремі A/D
        # для того самого файла (мета задачі — перевіряти саме статус, task-3-brief.md Step 3).
        $sha = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()
        $diffTree = (Invoke-TestGit -Repo $repo -GitArgs @('-c', 'core.quotepath=false', 'diff-tree', '--no-commit-id', '--name-status', '-r', '-M', $sha)) -join "`n"
        $diffTree | Should -Match ([regex]::Escape("R100`t$oldPath`t$newPath"))
        $diffTree | Should -Not -Match '^[AD]\t'

        # git log --follow бачить історію через межу перейменування (спайк 2026-09-09).
        $follow = @(Invoke-TestGit -Repo $repo -GitArgs @('log', '--follow', '--oneline', '--', $newPath))
        $follow.Count | Should -BeGreaterThan 1 -Because 'має включати і коміт перейменування, і попередній gitsync-коміт'

        # Вміст лишається EDT-ним — конверсія це наступний окремий крок (kit sync), не rename-edt.
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo $newPath))
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be "Процедура Тест()`nКонецПроцедуры"

        # Тег межі EDT-епохи створено (docs/migration/2026-09-09-history-spike.md).
        $tags = @(Invoke-TestGit -Repo $repo -GitArgs @('tag', '--list', 'legacy/gitsync-*'))
        $tags.Count | Should -Be 1
    }

    It 'Unmapped не видаляється без -Apply; прев''ю друкує повний перелік із причиною' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'unmapped-preview') -WithGitattributes
        $dir = Join-Path $repo 'Alpha_SMB/src'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'ConfigDumpInfo.xml') -Value 'x' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: службовий файл') | Out-Null

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*ConfigDumpInfo.xml*'
        $r.Output | Should -BeLike '*попередній перегляд*'
        (Join-Path $dir 'ConfigDumpInfo.xml') | Should -Exist
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'колізія (два EDT-шляхи в один Designer-шлях) — зупинка ДО будь-якого git mv; дерево незмінене' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'collision') -WithGitattributes
        $dir = Join-Path $repo 'Alpha_SMB/src/CommonTemplates/Мак1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Мак1.mxlx') -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $dir 'Мак1.dcs') -Value 'b' -Encoding UTF8
        Invoke-TestGit -Repo $repo -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'gitsync: колізія макета') | Out-Null
        $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*олізі*'

        (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before -Because 'жодного коміту не мало створитись'
        (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty -Because 'жодного git mv не мало відбутись'
        (Join-Path $dir 'Мак1.mxlx') | Should -Exist
        (Join-Path $dir 'Мак1.dcs') | Should -Exist
    }

    It 'брудна робоча копія — зупинка до будь-якої зміни (успадковано з repo-migration, §9.2)' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'dirty') -WithGitattributes
        Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
        Add-Content -LiteralPath (Join-Path $repo 'AUTHORS') -Value 'ще один рядок' -Encoding UTF8

        $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*не чиста*'
        (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist
    }

    Context 'Step 3а — запобіжник політики тексту (Test-GitTextPolicy на -TargetRoot)' {
        It 'застаріла gitsync .gitattributes (лише *.bin/*.axdt/*.addin binary) — зупинка ДО git mv, жоден файл не переміщено' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'stale-attrs')
            Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Value @('*.bin binary', '*.axdt binary', '*.addin binary') -Encoding ascii
            Invoke-TestGit -Repo $repo -GitArgs @('add', '.gitattributes') | Out-Null
            Invoke-TestGit -Repo $repo -GitArgs @('commit', '-q', '-m', 'застаріла .gitattributes gitsync') | Out-Null
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'
            $before = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim()

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Output | Should -BeLike '*text*'

            (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse', 'HEAD')).Trim() | Should -Be $before
            (Invoke-TestGit -Repo $repo -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            (Join-Path $repo 'Alpha_SMB/src/CommonModules/ОбщегоНазначения/Module.bsl') | Should -Exist
        }

        It 'сучасна .gitattributes (-text на TargetRoot, templates/gitattributes) — проходить' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'modern-attrs') -WithGitattributes
            Add-KitFakeEdtTree -Repo $repo -Rel 'Alpha_SMB/src'

            $r = Invoke-RenameEdt -Repo $repo -More @('-SourceRelPath', 'Alpha_SMB/src', '-TargetRoot', 'Alpha_SMB/cfe/src', '-Apply')
            $r.ExitCode | Should -Be 0 -Because $r.Output
        }
    }
}
