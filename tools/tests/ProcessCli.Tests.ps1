#Requires -Version 7
# Контракт команд процесу (оригінал — agent-kit 0.9.1 tests/cli.test.mjs):
# коди 0/1/2/3, перший рядок stderr `<команда>: ERROR …`, останній рядок успіху `next:`.
# Команди процесу звертаються сюди списком $script:ProcessCommands, коли з'являються (sdd, review-pack).
Describe 'Команди процесу — контракт виходу й аргументів' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')
        $script:KitRoot = Split-Path (Split-Path $script:Kit -Parent) -Parent

        # Проба-команда процесу лише в копії: друкує, що отримала, і читає профіль.
        Set-Content -LiteralPath (Join-Path $script:KitRoot 'tools/commands/probe-cli.psm1') -Encoding UTF8 -Value @'
function Invoke-KitProbeCli {
    param([string[]]$Arguments, [string]$RepoRoot)
    $a = ConvertFrom-KitArguments -Arguments $Arguments -Spec @{ Note = 'string'; Out = 'string'; Source = 'string'; Flag = 'switch' }
    if ($a.Help) { Write-KitLine 'usage: probe-cli [need-field] [-Note t] [-Out f] [-Source s] [-Flag]'; return 0 }
    $p = Get-KitProfile -RepoRoot $RepoRoot
    if ($a.Positional -contains 'need-field') { $null = Get-KitProfileValue $p 'probe.required' }
    Write-KitLine "pos=$($a.Positional -join '|') note=$($a.Named['Note']) out=$($a.Named['Out']) source=$($a.Named['Source']) flag=$([bool]$a.Named['Flag'])"
    Write-KitNext 'probe-cli need-field'
    return 0
}
Export-ModuleMember -Function Invoke-KitProbeCli
'@
        Add-Content -LiteralPath (Join-Path $script:KitRoot 'tools/commands/process-commands.txt') -Value 'probe-cli' -Encoding UTF8
        Copy-Item (Join-Path $script:KitRoot 'bin/sdd') (Join-Path $script:KitRoot 'bin/probe-cli')
        Copy-Item (Join-Path $script:KitRoot 'bin/sdd.ps1') (Join-Path $script:KitRoot 'bin/probe-cli.ps1')

        $script:Repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        git -C $script:Repo init -q 2>$null

        # Окремий stderr: контракт стосується саме ПЕРШОГО рядка stderr.
        function script:Invoke-Process {
            param([ValidateSet('bash', 'ps1')][string]$Via, [string]$Command, [string[]]$Arguments = @())
            $errFile = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
            Push-Location $script:Repo
            try {
                $out = if ($Via -eq 'bash') { & bash (Join-Path $script:KitRoot "bin/$Command") @Arguments 2>$errFile }
                       else { & (Join-Path $script:KitRoot "bin/$Command.ps1") @Arguments 2>$errFile }
                $code = $LASTEXITCODE
            } finally { Pop-Location }
            [pscustomobject]@{
                ExitCode = $code
                Out      = @($out | ForEach-Object { [string]$_ })
                Err      = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        }
    }

    It 'обидві обгортки доносять до команди токени, які перехопив би kit.ps1, і успіх закінчується next: (<Via>)' -ForEach @(@{ Via = 'bash' }, @{ Via = 'ps1' }) {
        $r = Invoke-Process -Via $Via -Command 'probe-cli' -Arguments @('x', '-Source', 'controller', '-Out', 'пакет.md', '-Note', 'два слова', '-Flag')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Contain 'pos=x note=два слова out=пакет.md source=controller flag=True'
        $r.Out[-1] | Should -Be 'next: probe-cli need-field'
    }

    It 'невідомий параметр і форма --name — код 2, перший рядок stderr «probe-cli: ERROR» (<Bad>)' -ForEach @(@{ Bad = '-Nope' }, @{ Bad = '--note' }) {
        $r = Invoke-Process -Via 'bash' -Command 'probe-cli' -Arguments @($Bad, 'v')
        $r.ExitCode | Should -Be 2
        $r.Err[0] | Should -BeLike 'probe-cli: ERROR *'
        $r.Out | Should -Not -Contain 'next: probe-cli need-field'
    }

    It 'справжня команда процесу <Command>: невідомий параметр — код 2 і «<Command>: ERROR» першим рядком stderr' -ForEach @(
        @{ Command = 'sdd'; Arguments = @('status', '-Nope', 'v') },
        @{ Command = 'review-pack'; Arguments = @('HEAD', '-Nope', 'v') }
    ) {
        $r = Invoke-Process -Via 'bash' -Command $Command -Arguments $Arguments
        $r.ExitCode | Should -Be 2
        $r.Err[0] | Should -BeLike "${Command}: ERROR *"
    }

    It 'відсутнє поле профілю — код 3 (не перевірено) з назвою поля, не зелений' {
        $r = Invoke-Process -Via 'bash' -Command 'probe-cli' -Arguments @('need-field')
        $r.ExitCode | Should -Be 3
        $r.Err[0] | Should -BeLike 'probe-cli: ERROR *probe.required*'
    }

    It 'той самий профіль із полем — код 0 (контроль, що код 3 дає саме відсутність поля)' {
        $dir = Join-Path $script:Repo '.agents'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'kit.profile.json') -Value '{ "probe": { "required": 1 } }' -Encoding UTF8
        try {
            $r = Invoke-Process -Via 'bash' -Command 'probe-cli' -Arguments @('need-field')
            $r.ExitCode | Should -Be 0
        } finally { Remove-Item -LiteralPath (Join-Path $dir 'kit.profile.json') }
    }

    It 'kit.ps1 probe-cli з -Source — код 2 і вказівка на обгортку, а не тихий перехоплений параметр' {
        Push-Location $script:Repo
        try { $out = & pwsh -NoProfile -File $script:Kit probe-cli -Source controller 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { Pop-Location }
        $code | Should -Be 2
        $out | Should -BeLike '*probe-cli: ERROR*bin/probe-cli*'
    }
}
