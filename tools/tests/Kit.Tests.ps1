#Requires -Version 7
Describe 'kit.ps1 — диспетчер команд' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
        $script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

        # Тестова команда: друкує, що отримала. Живе лише в копії — у справжньому tools/commands її немає.
        Set-Content -LiteralPath (Join-Path (Split-Path $script:Kit) 'commands/probe.psm1') -Encoding UTF8 -Value @'
function Invoke-KitProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Workspace,
        [string]$Source,
        [bool]$Apply,
        [string]$Ref = 'HEAD',
        [switch]$Force
    )
    "PROBE workspaces=$($Context.Workspaces.Count) ws=$Workspace src=$Source apply=$Apply ref=$Ref force=$Force main=$($Context.MainBranch)"
}
Export-ModuleMember -Function Invoke-KitProbe
'@

        function script:Invoke-Kit {
            param([string[]]$Arguments)
            $out = & pwsh -NoProfile -File $script:Kit @Arguments 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        $script:Repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'repo')
    }

    It 'без команди — зупинка з переліком доступних' {
        $r = Invoke-Kit @('-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*probe*'
    }

    It 'невідома команда — зупинка з переліком доступних' {
        $r = Invoke-Kit @('frobnicate', '-RepoRoot', $script:Repo)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike "*'frobnicate'*probe*"
    }

    It 'спільні й власні параметри доходять до команди; контекст після префлайту' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Workspace', 'Alpha_SMB', '-Ref', 'main', '-Force')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*PROBE workspaces=1 ws=Alpha_SMB src= apply=False ref=main force=True main=main*'
    }

    It '-Apply передається як $true' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Apply')
        $r.Output | Should -BeLike '*apply=True*'
    }

    It 'невідомий власний параметр команди — зупинка, команда не виконана' {
        $r = Invoke-Kit @('probe', '-RepoRoot', $script:Repo, '-Bogus', '1')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'провал префлайту зупиняє до виклику команди' {
        $broken = New-KitFakeRepo -Root (Join-Path $TestDrive 'broken')
        Remove-Item -LiteralPath (Join-Path $broken 'Alpha_SMB/v8project.yaml')
        $r = Invoke-Kit @('probe', '-RepoRoot', $broken)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*v8project.yaml*'
        $r.Output | Should -Not -BeLike '*PROBE*'
    }

    It 'не git-репозиторій — зупинка' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $r = Invoke-Kit @('probe', '-RepoRoot', $dir)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -BeLike '*.git*'
    }
}
