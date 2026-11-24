#Requires -Version 7
# kit.exe check: коди виходу (0/1/3), «нічого не пише», раннер лише з Уніки/-RunnerPath, довідка. Справжній бінарник
# (bin/kit.exe копії Copy-KitTools) підпроцесом на синтетичному репозиторії; рішення 2, 5, 17 плану B3.
Describe 'kit check — коди виходу, межі запису й раннера' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1') }

    It 'здоровий синтетичний репозиторій — рівно 0, без «не перевірено»' {
        $r = Invoke-Check -Repo (New-GoodRepo 'codes-good')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*Помилок немає*'
        $r.Output | Should -Not -BeLike '*не перевірено*'
    }

    It 'глобальний збій git (core.repositoryformatversion=99: кожна команда git дає 128) — рівно 1, страж overlay-ignored fail-closed' {
        $repo = New-GoodRepo 'codes-global'
        # git config сам падає на такому репозиторії — правимо файл конфігурації.
        $cfg = Join-Path $repo '.git/config'
        $text = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
        $text | Should -Match 'repositoryformatversion = 0'
        Set-Content -LiteralPath $cfg -Value ($text -replace 'repositoryformatversion = 0', 'repositoryformatversion = 99') -Encoding UTF8 -NoNewline
        git -C $repo rev-parse HEAD 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 128 -Because 'передумова: git справді дає 128 на цьому конфізі'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match '(?m)^\[-\] не перевірено: гітігнорування v8storagekit\.local\.yaml'
        $r.Output | Should -BeLike '*Expected git repo version*'
    }

    It 'точковий збій git у неохоронній перевірці (ref storage/* на відсутній об''єкт: rev-parse каже «є», log — 128) — рівно 3' {
        $repo = New-GoodRepo 'codes-point'
        $refDir = Join-Path $repo '.git/refs/heads/storage'
        New-Item -ItemType Directory -Force -Path $refDir | Out-Null
        Set-Content -LiteralPath (Join-Path $refDir 'Alpha_SMB') -Value "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`n" -Encoding ascii -NoNewline
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 3 -Because $r.Output
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: Alpha_SMB/Alpha_SMB: інваріанти гілки storage/Alpha_SMB'
        $r.Output | Should -BeLike '*Помилок немає*'
    }

    It 'error разом із точковим збоєм — рівно 1 (пріоритет error над 3)' {
        # Без .gitignore: overlay-ignored — справжній error (не збій); ref на відсутній об'єкт — точковий збій.
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'codes-both') -WithHooks -WithGitattributes
        $refDir = Join-Path $repo '.git/refs/heads/storage'
        New-Item -ItemType Directory -Force -Path $refDir | Out-Null
        Set-Content -LiteralPath (Join-Path $refDir 'Alpha_SMB') -Value "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`n" -Encoding ascii -NoNewline
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match '(?m)^\[-\] v8storagekit\.local\.yaml не гітігноровано'
        $r.Output | Should -Match '(?m)^\[!\] не перевірено: .*інваріанти гілки'
    }

    Context 'нічого не пише' {
        BeforeAll {
            # Знімок усього дерева, включно з .git: шлях, хеш і час запису кожного файла (переписаний тими самими
            # байтами файл — теж запис, напр. `git update-index --refresh`), плюс refs і статус з ігнорованими
            # (--no-optional-locks: сам знімок не переписує індекс).
            function script:Get-TreeSnapshot([string]$Repo) {
                $files = Get-ChildItem -LiteralPath $Repo -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
                    '{0}|{1}|{2}' -f $_.FullName.Substring($Repo.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.LastWriteTimeUtc.Ticks
                }
                $dirs = Get-ChildItem -LiteralPath $Repo -Recurse -Force -Directory | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Repo.Length) }
                @($files) + @($dirs) + @(git -C $Repo for-each-ref) + @(git --no-optional-locks -C $Repo status --porcelain --ignored)
            }
        }
        It 'kit.exe check не змінює ні репозиторій, ні .git (індекс, refs, config, hooks)' {
            $repo = New-GoodRepo 'codes-readonly'
            $before = Get-TreeSnapshot $repo
            $r = Invoke-Check -Repo $repo
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $after = Get-TreeSnapshot $repo
            Compare-Object $before $after | Should -BeNullOrEmpty
        }
        It 'контроль: знімок бачить запис (переписаний тими самими байтами .git/config)' {
            $repo = New-GoodRepo 'codes-readonly-control'
            $before = Get-TreeSnapshot $repo
            Start-Sleep -Milliseconds 50
            $cfg = Join-Path $repo '.git/config'
            Set-Content -LiteralPath $cfg -Value (Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -Encoding UTF8 -NoNewline
            Compare-Object $before (Get-TreeSnapshot $repo) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'раннер — лише з установленої Уніки чи явного -RunnerPath' {
        It 'v8-runner у PATH і змінні оточення з іншим шляхом не підміняють раннер: вердикт — за реєстром (фальшивий реєстр без раннера → error runner-version)' {
            $repo = New-GoodRepo 'codes-runner'
            $bin = Join-Path $TestDrive 'runner-on-path'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot 'fixtures/runner/*') -Destination $bin -Force
            $saved = @{ PATH = $env:PATH; V8_RUNNER = $env:V8_RUNNER; V8_RUNNER_PATH = $env:V8_RUNNER_PATH; RUNNER_PATH = $env:RUNNER_PATH }
            try {
                $env:PATH = "$bin;$env:PATH"
                $env:V8_RUNNER = $env:V8_RUNNER_PATH = $env:RUNNER_PATH = (Join-Path $bin 'v8-runner.cmd')
                $out = & (Get-KitExe -Kit $script:Kit) check -RepoRoot $repo -InstalledPluginsPath (New-KitFakeUnicaRegistry) 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally {
                $env:PATH = $saved.PATH
                foreach ($k in 'V8_RUNNER', 'V8_RUNNER_PATH', 'RUNNER_PATH') { if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $saved[$k] } }
            }
            $code | Should -Be 1 -Because $out
            $out | Should -Match '(?m)^\[-\] .*[Рр]аннер'
        }
    }

    Context 'довідка і розбір аргументів' {
        It '-Help друкує usage, код 0; невідомий параметр — перший рядок stderr «check: ERROR», код 2' {
            $exe = Get-KitExe -Kit $script:Kit
            $u = & $exe check -Help 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $u | Should -BeLike 'usage: kit check*-RepoRoot*'
            $e = & $exe check -Bogus 1 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 2
            $e | Should -BeLike 'check: ERROR*-Bogus*'
        }
        It 'довідка kit.exe називає check рівно один раз (поки check.psm1 існує — без дубля)' {
            $h = & (Get-KitExe -Kit $script:Kit) -Help 2>&1 | Out-String
            $line = @($h -split "`r?`n" | Where-Object { $_ -like 'команди:*' })[0]
            @($line -replace '^команди:\s*', '' -split ',\s*' | Where-Object { $_ -ceq 'check' }).Count | Should -Be 1
        }
    }
}
