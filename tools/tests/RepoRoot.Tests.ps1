#Requires -Version 7
BeforeAll {
    Import-Module "$PSScriptRoot/../lib/RepoRoot.psm1" -Force
}

Describe 'Resolve-V8RepoRoot' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("v8kit-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'повертає абсолютний шлях для кореня з текою .git' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') | Out-Null
        Resolve-V8RepoRoot -Path $script:tmp | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'приймає .git-файл (git worktree)' {
        Set-Content -LiteralPath (Join-Path $script:tmp '.git') -Value 'gitdir: ../somewhere'
        Resolve-V8RepoRoot -Path $script:tmp | Should -Be (Resolve-Path $script:tmp).Path
    }

    It 'розвʼязує відносний шлях відносно поточної теки' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp '.git') | Out-Null
        Push-Location $script:tmp
        try { Resolve-V8RepoRoot -Path '.' | Should -Be (Resolve-Path $script:tmp).Path }
        finally { Pop-Location }
    }

    It 'кидає виняток на теці без .git' {
        { Resolve-V8RepoRoot -Path $script:tmp } | Should -Throw '*не є коренем git-репозиторію*'
    }

    It 'кидає виняток із зрозумілим повідомленням на неіснуючому шляху' {
        { Resolve-V8RepoRoot -Path (Join-Path $script:tmp 'нема') } | Should -Throw '*не існує*'
    }

    It 'кидає виняток, коли шлях указує на файл, а не на теку' {
        $file = Join-Path $script:tmp 'file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        { Resolve-V8RepoRoot -Path $file } | Should -Throw '*не є коренем git-репозиторію*'
    }
}
