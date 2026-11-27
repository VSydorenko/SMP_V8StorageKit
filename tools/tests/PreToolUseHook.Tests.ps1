#Requires -Version 7
# Хук PreToolUse плагіна — прихована підкоманда `kit.exe pretool-1c` (hooks/hooks.json, matcher
# `Grep|Glob|Read|Bash`): у репозиторії 1С на текстове читання `.bsl`/`Ext/` дає підказку Уніки. Лише
# підказка (без permissionDecision), будь-що інше — тиша й код 0. Тест ходить у закомічений bin/kit.exe,
# тож зеленіє після збірки поставки. Логіку розпізнавання тримають Rust-тести модуля pretool_1c.
Describe 'kit.exe pretool-1c — хук PreToolUse плагіна' -Tag 'Docs' {
    BeforeAll {
        $kitRepo = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Exe = Join-Path $kitRepo 'bin/kit.exe'
        function script:New-Repo([string]$Name, [bool]$Is1C) {
            $root = Join-Path $TestDrive "repos/$Name"
            New-Item -ItemType Directory -Path (Join-Path $root '.git') -Force | Out-Null
            if ($Is1C) { Set-Content -LiteralPath (Join-Path $root 'v8storagekit.yaml') -Value 'version: 1' -Encoding UTF8 }
            $root
        }
        function script:Invoke-Hook([string]$Stdin) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Exe)
            $psi.ArgumentList.Add('pretool-1c')
            $psi.WorkingDirectory = $TestDrive
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $p = [System.Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Stdin)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.Close()
            $p.WaitForExit()
            [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.Result; Err = $err.Result }
        }
        function script:New-HookInput([string]$Tool, $ToolInput, [string]$Cwd) {
            [ordered]@{ session_id = 's'; cwd = $Cwd; hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = $ToolInput } | ConvertTo-Json -Compress -Depth 5
        }
    }

    It 'Read *.bsl у репозиторії 1С — підказка Уніки без permissionDecision, код 0' {
        $repo = New-Repo 'one-c' $true
        $r = Invoke-Hook (New-HookInput 'Read' @{ file_path = 'cf/src/CommonModules/A/Ext/Module.bsl' } $repo)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'permissionDecision'
        $j = $r.Output | ConvertFrom-Json
        $j.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $j.hookSpecificOutput.additionalContext | Should -Match 'unica_search'
    }

    It 'контроль: той самий вхід поза репозиторієм 1С, git diff і зламаний JSON — тиша' {
        $plain = New-Repo 'plain' $false
        $one = New-Repo 'one-c-2' $true
        foreach ($stdin in @(
                (New-HookInput 'Read' @{ file_path = 'a/Module.bsl' } $plain),
                (New-HookInput 'Bash' @{ command = 'git diff -- a/Module.bsl' } $one),
                'not json')) {
            $r = Invoke-Hook $stdin
            $r.ExitCode | Should -Be 0
            $r.Output | Should -BeNullOrEmpty
        }
    }

    It 'hooks/hooks.json кличе pretool-1c на PreToolUse з matcher Grep|Glob|Read|Bash' {
        $kitRepo = (Resolve-Path "$PSScriptRoot/../..").Path
        $h = Get-Content -LiteralPath (Join-Path $kitRepo 'hooks/hooks.json') -Raw | ConvertFrom-Json
        $entry = @($h.hooks.PreToolUse)
        $entry.Count | Should -Be 1
        $entry[0].matcher | Should -Be 'Grep|Glob|Read|Bash'
        $entry[0].hooks[0].command | Should -Match 'bin/kit\.exe" pretool-1c'
    }
}
