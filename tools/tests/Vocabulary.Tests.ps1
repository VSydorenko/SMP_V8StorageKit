#Requires -Version 7
Describe 'Запобіжник словника Уніки 0.12.3 (спека 2026-10-11 §8, §10 П14)' {
    BeforeAll {
        $script:KitRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        # Повний перелік інструментів MCP unica 0.12.3 (mcp__plugin_unica_unica__unica_<x>_<y>) — знята
        # поверхня; Уніка 0.13 не має жодного з цих імен і аліасів до них (спека §2.1).
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
            '(?<![\w.:$-])(?:' + ($alts -join '|') + ')(?![\w])|operation=|unica:v8-runner'
        }
        function script:Get-ScannedLines { param([string]$Root)
            $md = @(Get-ChildItem -LiteralPath (Join-Path $Root 'skills') -Filter '*.md' -File -Recurse) +
                  @(Get-ChildItem -LiteralPath (Join-Path $Root 'templates') -File -Recurse)
            foreach ($f in $md) {
                $n = 0
                # upgrades.md: розділи переходів до 1.4.0 — історія словником своєї епохи (з приміткою
                # на початку файлу, Task 16); скануються лише розділ «1.4.0 → 1.5.0» і все після нього.
                $scan = $f.Name -ne 'upgrades.md'
                foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
                    $n++
                    if (-not $scan -and $line -match '^##\s+1\.4\.0\s+→\s+1\.5\.0') { $scan = $true }
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
        $hits = @(Get-ScannedLines -Root $script:KitRoot | Where-Object { $_.Text -match $script:Pattern } |
            ForEach-Object { "$([IO.Path]::GetRelativePath($script:KitRoot, $_.File)):$($_.Line): $($_.Text.Trim())" })
        $hits | Should -BeNullOrEmpty -Because 'kit 1.5.0 говорить лише мовою Уніки 0.13 (рішення 9 спеки)'
    }

    It 'шаблон ловить кожну форму: <Probe>' -ForEach @(
        @{ Probe = 'валідувати — `cfe.validate`' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_project_status' }
        @{ Probe = 'unica.code.search' }
        @{ Probe = 'operation=build' }
        @{ Probe = 'скіл unica:v8-runner' }
        @{ Probe = 'unica_cfe_patch_method' }
    ) {
        $Probe | Should -Match $script:Pattern
    }

    It 'шаблон НЕ чіпає нову поверхню 0.13: <Probe>' -ForEach @(
        @{ Probe = 'unica.view {}' }
        @{ Probe = 'unica.check {at: x}' }
        @{ Probe = 'unica.diff' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_search' }
        @{ Probe = 'unica.run {"op":"make"}' }
        @{ Probe = 'unica.apply object.borrow' }
        @{ Probe = 'unica.task.result' }
        @{ Probe = 'скіл unica:cfe-borrow' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_task_result' }
        @{ Probe = '$template.Add(1); $meta.Add(2)' }
    ) {
        $Probe | Should -Not -Match $script:Pattern
    }

    It 'шаблон ловить повне MCP-ім''я: <Probe>' -ForEach @(
        @{ Probe = '"mcp__plugin_unica_unica__unica_cfe_borrow",' }
        @{ Probe = 'mcp__plugin_unica_unica__unica_build_dump' }
    ) {
        $Probe | Should -Match $script:Pattern
    }

    It 'негативний контроль: на дереві до адаптації (коміт плану 5743282) збіги є в усіх трьох зонах' {
        $old = Join-Path $TestDrive 'old-tree'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        $tar = Join-Path $TestDrive 'old.tar'
        git -C $script:KitRoot archive --format=tar -o $tar 5743282 -- skills templates tools
        # Відносні шляхи: GNU tar із Git for Windows читає "C:" в абсолютному шляху як ім'я віддаленого хоста.
        Push-Location -LiteralPath $TestDrive
        try { tar -xf old.tar -C old-tree } finally { Pop-Location }
        $hits = @(Get-ScannedLines -Root $old | Where-Object { $_.Text -match $script:Pattern })
        foreach ($zone in 'skills', 'templates', 'tools') {
            @($hits | Where-Object { [IO.Path]::GetRelativePath($old, $_.File) -like "$zone*" }).Count |
                Should -BeGreaterThan 0 -Because "запобіжник мусить бачити старий словник у зоні $zone"
        }
    }
}
