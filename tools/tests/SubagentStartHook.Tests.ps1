#Requires -Version 7
# Хук SubagentStart плагіна — прихована підкоманда `kit.exe subagent-start` (hooks/hooks.json, matcher
# `^v8storagekit:`): у репозиторії 1С вміст hooks/domain-1c/<агент>.md іде в additionalContext субагента.
# Тест ходить у закомічений bin/kit.exe: копія поруч із фальшивою текою hooks/domain-1c (корінь плагіна для
# kit.exe — тека над bin/). Вхід — JSON у stdin, як його дає Claude Code (agent_type, cwd).
Describe 'kit.exe subagent-start — хук SubagentStart плагіна' -Tag 'Docs' {
    BeforeAll {
        $kitRepo = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:Plugin = Join-Path $TestDrive 'plugin'
        New-Item -ItemType Directory -Path (Join-Path $script:Plugin 'bin'), (Join-Path $script:Plugin 'hooks/domain-1c') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $kitRepo 'bin/kit.exe') -Destination (Join-Path $script:Plugin 'bin/kit.exe')
        $script:Exe = Join-Path $script:Plugin 'bin/kit.exe'
        # Кирилиця й лапки — щоб перевірити й кодування, й екранування JSON; BOM на початку хук знімає.
        $script:Text = "## Специфіка 1С для виконавця`nКод 1С читай через Уніку (`"unica.view`")."
        [System.IO.File]::WriteAllText((Join-Path $script:Plugin 'hooks/domain-1c/implementer.md'), $script:Text, [System.Text.UTF8Encoding]::new($true))
        # Файл поза domain-1c: ім'я агента з `..` не мусить до нього дістатись.
        Set-Content -LiteralPath (Join-Path $script:Plugin 'hooks/evil.md') -Value 'ПОЗА ТЕКОЮ' -Encoding UTF8

        function script:New-Repo([string]$Name, [string[]]$Files = @()) {
            $root = Join-Path $TestDrive "repos/$Name"
            New-Item -ItemType Directory -Path (Join-Path $root '.git') -Force | Out-Null
            foreach ($f in $Files) {
                $p = Join-Path $root $f
                New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
                Set-Content -LiteralPath $p -Value 'x: 1' -Encoding UTF8
            }
            $root
        }
        function script:Invoke-Hook([string]$Stdin) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Exe)
            $psi.ArgumentList.Add('subagent-start')
            $psi.WorkingDirectory = $TestDrive
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
            $p = [System.Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Stdin)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.Close()
            $p.WaitForExit()
            [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.Result; Err = $err.Result }
        }
        function script:New-HookInput([string]$Agent, [string]$Cwd) {
            [ordered]@{ session_id = 's'; cwd = $Cwd; agent_id = 'a1'; agent_type = $Agent; hook_event_name = 'SubagentStart' } | ConvertTo-Json -Compress
        }
        function script:Assert-Context($r) {
            $r.ExitCode | Should -Be 0
            $r.Err | Should -BeNullOrEmpty
            $j = $r.Output | ConvertFrom-Json
            $j.hookSpecificOutput.hookEventName | Should -Be 'SubagentStart'
            $j.hookSpecificOutput.additionalContext | Should -Be $script:Text
        }
        function script:Assert-Silent($r) {
            $r.ExitCode | Should -Be 0
            $r.Err | Should -BeNullOrEmpty
            $r.Output | Should -BeNullOrEmpty
        }
    }

    Context 'репозиторій 1С — контекст з файлу агента' {
        It 'маніфест у корені, cwd = корінь' {
            $repo = New-Repo 'manifest' @('v8storagekit.yaml')
            Assert-Context (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
        }
        It 'маніфест у корені, cwd — підтека' {
            $repo = New-Repo 'manifest-sub' @('v8storagekit.yaml', 'src/cf/keep.txt')
            Assert-Context (Invoke-Hook (New-HookInput 'v8storagekit:implementer' (Join-Path $repo 'src/cf')))
        }
        It 'без маніфесту, v8project.yaml у прямій підтеці кореня git' {
            $repo = New-Repo 'workspace' @('Product_SMB/v8project.yaml')
            Assert-Context (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
        }
    }

    Context 'тиша й код 0' {
        It 'лише профіль процесу (як у самого kit) — не репозиторій 1С' {
            $repo = New-Repo 'profile' @('.agents/kit.profile.json')
            Assert-Silent (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
        }
        It 'v8project.yaml глибше прямої підтеки — не ознака' {
            $repo = New-Repo 'deep' @('a/b/v8project.yaml')
            Assert-Silent (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
        }
        It 'агент <Agent> — не агент плагіна чи небезпечне ім''я' -ForEach @(
            @{ Agent = 'Explore' }, @{ Agent = 'other:implementer' }, @{ Agent = 'v8storagekit:Implementer' },
            @{ Agent = 'v8storagekit:../evil' }, @{ Agent = 'v8storagekit:..\evil' }, @{ Agent = 'v8storagekit:' }
        ) {
            $repo = New-Repo "agent-$([guid]::NewGuid())" @('v8storagekit.yaml')
            Assert-Silent (Invoke-Hook (New-HookInput $Agent $repo))
        }
        It 'агент плагіна без файлу в domain-1c' {
            $repo = New-Repo 'nofile' @('v8storagekit.yaml')
            Assert-Silent (Invoke-Hook (New-HookInput 'v8storagekit:researcher' $repo))
        }
        It 'вхід <Name>' -ForEach @(
            @{ Name = 'порожній'; Stdin = '' }, @{ Name = 'не JSON'; Stdin = 'not json' },
            @{ Name = 'без cwd'; Stdin = '{"agent_type":"v8storagekit:implementer"}' },
            @{ Name = 'cwd не існує'; Stdin = '{"agent_type":"v8storagekit:implementer","cwd":"C:\\nonexistent\\kit-test"}' }
        ) {
            Assert-Silent (Invoke-Hook $Stdin)
        }
    }

    It 'контроль: той самий репозиторій і агент без маніфесту дають тишу, з маніфестом — контекст' {
        # Предикат справді дивиться на маніфест: інакше зелені «тиші» вище нічого б не доводили.
        $repo = New-Repo 'toggle'
        Assert-Silent (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
        Set-Content -LiteralPath (Join-Path $repo 'v8storagekit.yaml') -Value 'version: 1' -Encoding UTF8
        Assert-Context (Invoke-Hook (New-HookInput 'v8storagekit:implementer' $repo))
    }

    It 'hooks/hooks.json плагіна кличе subagent-start на SubagentStart з matcher ^v8storagekit:' {
        $kitRepo = (Resolve-Path "$PSScriptRoot/../..").Path
        $h = Get-Content -LiteralPath (Join-Path $kitRepo 'hooks/hooks.json') -Raw | ConvertFrom-Json
        $entry = @($h.hooks.SubagentStart)
        $entry.Count | Should -Be 1
        $entry[0].matcher | Should -Be '^v8storagekit:'
        $entry[0].hooks[0].command | Should -Match 'bin/kit\.exe" subagent-start'
    }
}
