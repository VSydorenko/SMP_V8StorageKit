#Requires -Version 7
Describe 'Запобіжник словника: поверхня Уніки 0.12.3 і інструменти задач 0.13' -Tag 'Docs' {
    BeforeAll {
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        # Повний перелік інструментів MCP unica 0.12.3 (mcp__plugin_unica_unica__unica_<x>_<y>) — знята
        # поверхня; Уніка 0.13 не має жодного з цих імен і аліасів до них.
        $script:Removed = @(
            'build_dump', 'build_load', 'build_make', 'build_run', 'build_update',
            'cf_edit', 'cf_info', 'cf_init', 'cf_validate',
            'cfe_borrow', 'cfe_diff', 'cfe_init', 'cfe_patch_method', 'cfe_validate',
            'code_definition', 'code_diagnostics', 'code_graph', 'code_outline', 'code_patch', 'code_search',
            'dcs_compile', 'dcs_edit', 'dcs_info', 'dcs_validate',
            'documentation_get', 'documentation_search', 'epf_init', 'erf_init',
            'form_add', 'form_compile', 'form_edit', 'form_info', 'form_remove', 'form_validate',
            'help_add', 'interface_edit', 'interface_validate',
            'meta_add', 'meta_edit', 'meta_info', 'meta_remove',
            'mxl_compile', 'mxl_decompile', 'mxl_info', 'mxl_validate',
            'project_map', 'project_status',
            'role_compile', 'role_edit', 'role_info', 'role_validate',
            'runtime_execute', 'runtime_job_cancel', 'runtime_job_list', 'runtime_job_logs', 'runtime_job_start', 'runtime_job_status', 'runtime_job_wait',
            'source_children', 'source_locate', 'source_read', 'source_resolve', 'source_resources',
            'standards_explain', 'standards_search',
            'subsystem_compile', 'subsystem_edit', 'subsystem_info', 'subsystem_validate',
            'support_edit', 'template_add', 'template_remove', 'xdto_edit', 'xdto_info')

        function script:Get-RemovedPattern {
            # Повне MCP-ім'я (mcp__plugin_unica_unica__unica_x_y) — окремий необов'язковий префікс:
            # без нього lookbehind (?<![\w…]) забороняв би '_' перед 'unica_' і повні імена не
            # ловились би зовсім (аудит плану). '$' у lookbehind — щоб не ловити $meta.Add( у коді.
            $alts = foreach ($name in $script:Removed) {
                $seg = $name -split '_'
                '(?:mcp__plugin_unica_unica__)?(?:unica[._])?' + [regex]::Escape($seg[0]) + '[._]' + (($seg[1..($seg.Count - 1)] | ForEach-Object { [regex]::Escape($_) }) -join '[._-]')
            }
            # Інструменти задач Уніки (unica.task.get/result/cancel) — у протоколі MCP 2026-07-28 Уніки 0.16
            # їх немає в tools/list: будь-яка форма — mcp__…unica_task_x,
            # unica_task_x, unica.task.x. Окремою гілкою, бо в 0.13 ці імена були новою поверхнею.
            '(?<![\w.:$-])(?:' + ($alts -join '|') + ')(?![\w])|operation=|unica:v8-runner|unica[._]task[._]'
        }
        # Прибрані команди kit 1.6.0 у формі виклику: kit.ps1" canon,
        # kit.ps1" build, kit canon, kit build, -MarkerOnly. Форма виклику, а не голе слово: «канонізація»,
        # «build/artifacts», «make» лишаються законними.
        # МЕЖА: ця заборона НЕ діє на upgrades.md. Розділ переходу «1.4.0 → 1.6.0» законно пише, що
        # `kit canon`/`kit build` більше немає і чим їх замінено, — без цього процедура переходу не
        # відповіла б людині, куди поділась команда. Заборона старої поверхні Уніки ($script:Pattern,
        # зокрема unica_task_) на upgrades.md діє, як і на решту: переходу їх називати не потрібно.
        $script:RemovedKitPattern = '\bkit(?:\.ps1"?)?\s+(?:canon|build)(?![\w-])|-MarkerOnly\b'
        function script:Test-VocabularyHit { param($Line)
            ($Line.Text -match $script:Pattern) -or
                ((Split-Path -Leaf $Line.File) -ne 'upgrades.md' -and $Line.Text -match $script:RemovedKitPattern)
        }
        # Заголовок, з якого скануються переходи в upgrades.md. Розділи до нього — історія словником своєї
        # епохи (примітка на початку файлу); розділ «1.4.0 → 1.6.0» і все після нього — мова Уніки 0.16.
        $script:UpgradesHeader = '^##\s+1\.4\.0\s+→\s+1\.6\.0'
        function script:Get-ScannedLines { param([string]$Root, [switch]$AllowNoUpgradesHeader)
            $md = @(Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Filter '*.md' -File -Recurse) +
                  @(Get-ChildItem -LiteralPath (Join-Path $Root 'templates') -File -Recurse)
            foreach ($f in $md) {
                $n = 0
                $scan = $f.Name -ne 'upgrades.md'
                $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
                # Без заголовка скан upgrades.md мовчки дав би нуль рядків — і запобіжник був би зеленим
                # на будь-якому тексті. Тому відсутній заголовок — виняток, а не порожній скан.
                if (-not $scan -and -not $AllowNoUpgradesHeader -and -not ($lines -match $script:UpgradesHeader)) {
                    throw "У $($f.FullName) немає заголовка розділу переходу (регулярний вираз $script:UpgradesHeader): скан цього файлу дав би нуль рядків."
                }
                foreach ($line in $lines) {
                    $n++
                    if (-not $scan -and $line -match $script:UpgradesHeader) { $scan = $true }
                    if ($scan) { [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line } }
                }
            }
            $code = @(Get-ChildItem -LiteralPath (Join-Path $Root 'tools/commands'), (Join-Path $Root 'tools/lib') -Filter '*.psm1' -File) +
                    @(Get-Item -LiteralPath (Join-Path $Root 'tools/kit.ps1'), (Join-Path $Root 'tools/check-environment.ps1'))
            foreach ($f in $code) {
                $text = [regex]::Replace((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8), '(?s)<#.*?#>', { param($m) "`n" * ($m.Value.Split("`n").Count - 1) })
                $n = 0
                foreach ($line in ($text -split "`n")) {
                    $n++
                    if ($line.Trim().StartsWith('#')) { continue }
                    [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line }
                }
            }
        }
        $script:Pattern = Get-RemovedPattern
    }

    It 'на дереві kit — нуль збігів у skills/, templates/ і некоментованому коді tools/' {
        $hits = @(Get-ScannedLines -Root $script:KitRoot | Where-Object { Test-VocabularyHit $_ } |
            ForEach-Object { "$([IO.Path]::GetRelativePath($script:KitRoot, $_.File)):$($_.Line): $($_.Text.Trim())" })
        $hits | Should -BeNullOrEmpty -Because 'kit 1.6.0 говорить лише мовою Уніки 0.16'
    }

    It 'upgrades.md без заголовка «1.4.0 → 1.6.0» — виняток, а не порожній скан' {
        $root = Join-Path $TestDrive 'no-header'
        $ref = Join-Path $root 'skills/onboarding/references'
        New-Item -ItemType Directory -Path $ref, (Join-Path $root 'templates'), (Join-Path $root 'tools/commands'), (Join-Path $root 'tools/lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ref 'upgrades.md') -Encoding UTF8 -Value "## 1.3.1 → 1.4.0`n`nunica_task_get"
        New-Item -ItemType File -Path (Join-Path $root 'tools/kit.ps1'), (Join-Path $root 'tools/check-environment.ps1') -Force | Out-Null
        { @(Get-ScannedLines -Root $root) } | Should -Throw '*немає заголовка розділу переходу*'
    }

    It 'негативний контроль: на дереві до адаптації (коміт плану 5743282) збіги є в усіх трьох зонах' {
        $old = Join-Path $TestDrive 'old-tree'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        $tar = Join-Path $TestDrive 'old.tar'
        git -C $script:KitRoot archive --format=tar -o $tar 5743282 -- skills templates tools
        # Відносні шляхи: GNU tar із Git for Windows читає "C:" в абсолютному шляху як ім'я віддаленого хоста.
        Push-Location -LiteralPath $TestDrive
        try { tar -xf old.tar -C old-tree } finally { Pop-Location }
        # Дерево до адаптації ще не має розділу «1.4.0 → 1.6.0»: upgrades.md там не сканується зовсім,
        # збіги дають інші файли кожної зони.
        $hits = @(Get-ScannedLines -Root $old -AllowNoUpgradesHeader | Where-Object { $_.Text -match $script:Pattern })
        foreach ($zone in 'skills', 'templates', 'tools') {
            @($hits | Where-Object { [IO.Path]::GetRelativePath($old, $_.File) -like "$zone*" }).Count |
                Should -BeGreaterThan 0 -Because "запобіжник мусить бачити старий словник у зоні $zone"
        }
    }
}
