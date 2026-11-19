#Requires -Version 7
# Ported from agent-kit 0.9.1 bin/kit-check, modified.
# Форма плагіна, яку можна перевірити скриптом, а не рецензією: обгортки команд процесу, описи,
# посилання, шапки походження, бамп версії. Помилку, яку знаходить скрипт, має знайти скрипт —
# інакше вона переживає рецензію (в оригіналі так пережив своє видалення агент у п'яти файлах).

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # Знахідки обгорток для репозиторію $Root: перелік рядків «що не так», порожній — усе гаразд.
    # Функція, а не інлайн-перевірка: та сама логіка ганяється і на самому плагіні, і на синтетичному
    # репозиторії-контролі, який мусить її провалити.
    function script:Get-KitWrapperProblems([string]$Root) {
        $problems = [System.Collections.Generic.List[string]]::new()
        $listFile = Join-Path $Root 'tools/commands/process-commands.txt'
        $names = @(Get-Content -LiteralPath $listFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

        # Режим з індексу і з HEAD. Обидва: `git commit --only -- bin/<ім'я>` на Windows
        # (core.filemode=false) бере режим із робочого дерева й комітить 100644, навіть коли в
        # індексі після `update-index --chmod=+x` стояло 100755. Без цієї перевірки біт губиться
        # мовчки, і обгортка в Bash не запускається («Permission denied»).
        $modes = @{}
        foreach ($src in @(
                @{ Where = 'індексі'; Lines = @(git -C $Root ls-files -s -- bin/ 2>$null) },
                @{ Where = 'HEAD'; Lines = @(git -C $Root ls-tree HEAD -- bin/ 2>$null) })) {
            foreach ($l in $src.Lines) {
                if ($l -match '^(\d{6})\s.*?\t(.+)$') { $modes["$($src.Where)|$($Matches[2])"] = $Matches[1] }
            }
        }

        foreach ($n in $names) {
            foreach ($f in "bin/$n", "bin/$n.ps1") {
                if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) { $problems.Add("$f — немає обгортки команди процесу '$n'") }
            }
            if (-not $modes.ContainsKey("індексі|bin/$n")) { $problems.Add("bin/$n — не в індексі git") }
        }
        # Кожна bash-обгортка (файл bin/ без розширення), не лише з переліку: стара команда, яку
        # прибрали з переліку, але лишили обгортку, теж має запускатись або зникнути.
        foreach ($key in @($modes.Keys)) {
            $where, $path = $key -split '\|', 2
            if ([IO.Path]::GetExtension($path) -eq '' -and $modes[$key] -ne '100755') {
                $problems.Add("$path — режим $($modes[$key]) у $where, потрібен 100755 (git add → git update-index --chmod=+x → git commit без шляхів)")
            }
        }
        return , $problems.ToArray()
    }
}

Describe 'Обгортки команд процесу в bin/' {
    # Без кутових дужок у назві: Pester читає <…> у назві It як шаблон підстановки.
    It 'кожна команда з process-commands.txt має bin/ІМ''Я і bin/ІМ''Я.ps1, bash-обгортки — 100755 в індексі й HEAD' {
        $p = Get-KitWrapperProblems $script:PluginRoot
        $p | Should -BeNullOrEmpty -Because ($p -join '; ')
    }

    It 'контроль: синтетичний репозиторій з обгорткою 100644 і без .ps1 — перевірка падає' {
        $root = Join-Path $TestDrive 'shape-wrappers'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin'), (Join-Path $root 'tools/commands') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'tools/commands/process-commands.txt') -Value "# коментар`nprobe" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'bin/probe') -Value '#!/usr/bin/env bash' -Encoding UTF8
        git -C $root init -q 2>$null
        git -C $root -c core.filemode=false add bin/probe
        $p = Get-KitWrapperProblems $root
        ($p -join "`n") | Should -Match 'bin/probe\.ps1 — немає обгортки'
        ($p -join "`n") | Should -Match 'bin/probe — режим 100644 у індексі'

        # Після правильного рецепта знахідка режиму зникає (а відсутня .ps1 лишається).
        git -C $root update-index --chmod=+x bin/probe
        $p2 = Get-KitWrapperProblems $root
        ($p2 -join "`n") | Should -Not -Match 'режим'
        ($p2 -join "`n") | Should -Match 'bin/probe\.ps1 — немає обгортки'
    }
}
