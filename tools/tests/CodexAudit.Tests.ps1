#Requires -Version 7
# codex-audit: аудит зелений лише з доказом читання репозиторію в подіях JSONL. Codex виходить кодом 0
# і тоді, коли пісочниця не дала прочитати жодного файла (виміряно на Windows без windows.sandbox:
# «blocked by policy», exit 0, звіт за схемою з вигаданою знахідкою) — тож це головний контракт
# команди. Справжній kit-process.ps1 підпроцесом; Codex — фальшивий codex.ps1 (поле профілю codex.bin),
# що друкує події зі сценарію й пише звіт у шлях після -o.
Describe 'codex-audit — зелений лише з доказом читання' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:KitProcess = Join-Path (Split-Path (Copy-KitTools -Root (Join-Path $TestDrive 'plugin')) -Parent) 'kit-process.ps1'
        $script:Repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.agents') -Force | Out-Null
        & git -C $script:Repo init -q -b main 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Repo 'note.txt') -Value 'MARKER' -Encoding utf8NoBOM
        $fake = Join-Path $TestDrive 'codex.ps1'
        Set-Content -LiteralPath $fake -Encoding utf8NoBOM -Value @'
$out = $args[[array]::IndexOf($args, '-o') + 1]
[void][Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText($out, '{"files_read":["note.txt"],"findings":[]}')
$cmd = $env:FAKE_CODEX_COMMAND
'{"type":"thread.started"}'
('{"type":"item.completed","item":{"type":"command_execution","command":' + (ConvertTo-Json $cmd) + ',"exit_code":0,"status":"completed"}}')
'{"type":"turn.completed"}'
'@
        $profile = @{ codex = @{ model = 'm'; reasoningEffort = 'low'; bin = $fake } } | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath (Join-Path $script:Repo '.agents/kit.profile.local.json') -Value $profile -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $TestDrive 'q.md') -Value 'Read note.txt.' -Encoding utf8NoBOM

        function script:Invoke-Audit {
            param([string]$Command)
            $saved = $env:FAKE_CODEX_COMMAND, $env:XDG_CONFIG_HOME
            $env:FAKE_CODEX_COMMAND = $Command
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
            Push-Location $script:Repo
            try { $out = & pwsh -NoProfile -File $script:KitProcess codex-audit -Prompt (Join-Path $TestDrive 'q.md') 2>&1 | Out-String; $code = $LASTEXITCODE }
            finally { Pop-Location; $env:FAKE_CODEX_COMMAND, $env:XDG_CONFIG_HOME = $saved }
            [pscustomobject]@{ Code = $code; Out = $out }
        }
    }

    It 'turn.completed і звіт за схемою, але жодна команда не читала дерево — код 3, не зелений' {
        $r = Invoke-Audit -Command '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''Write-Output hello'''
        $r.Code | Should -Be 3 -Because $r.Out
        $r.Out | Should -Match 'Codex did not read the repository' -Because $r.Out
    }

    It 'та сама подія з командою читання файла дерева (обгортка pwsh) — код 0' {
        $r = Invoke-Audit -Command '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''Get-Content -LiteralPath note.txt'''
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '0 finding\(s\).*1 file\(s\) read' -Because $r.Out
    }
}
