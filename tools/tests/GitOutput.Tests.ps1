#Requires -Version 7
Describe 'Split-GitEolNoise' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitOutput.psm1").Path -Force
    }

    It 'ховає справжнє попередження git і рахує його' {
        # Вхід - вивід справжнього "git add" під конвертуючою політикою, а не вигаданий
        # рядок: форма повідомлення git тут і є предметом перевірки.
        $repo = Join-Path $TestDrive 'eol-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q
        git -C $repo config user.email 'test@example.invalid'
        git -C $repo config user.name 'Test Bot'
        Set-Content -LiteralPath (Join-Path $repo '.gitattributes') -Encoding UTF8 `
            -Value '* text=auto eol=crlf'
        [System.IO.File]::WriteAllText((Join-Path $repo 'f.xml'), "<a/>`n<b/>`n",
            [System.Text.UTF8Encoding]::new($false))

        $addOutput = git -C $repo add -A 2>&1
        $LASTEXITCODE | Should -Be 0

        $result = Split-GitEolNoise -Line $addOutput
        $result.Suppressed | Should -BeGreaterThan 0
        $result.Kept | Should -BeNullOrEmpty
    }

    It 'лишає видимим будь-що, крім відомої форми' {
        $known = "warning: in the working copy of 'a.xml', LF will be replaced by CRLF the next time Git touches it"
        $other = 'warning: something totally unrelated happened'

        $result = Split-GitEolNoise -Line @($known, $other)

        $result.Suppressed | Should -Be 1
        @($result.Kept).Count | Should -Be 1
        @($result.Kept)[0].ToString() | Should -Be $other
    }

    It 'на порожньому вводі не падає й нічого не рахує' {
        # "git add" без змін не друкує нічого - викликач отримує $null, не масив.
        $result = Split-GitEolNoise -Line $null
        $result.Suppressed | Should -Be 0
        $result.Kept | Should -BeNullOrEmpty
    }
}

Describe 'Test-GitTextPolicy' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitOutput.psm1").Path -Force
    }

    BeforeEach {
        $script:Repo = Join-Path $TestDrive ("attr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        git -C $script:Repo init -q
    }

    It 'бачить -text на типовому cfe/src' {
        Set-Content -LiteralPath (Join-Path $script:Repo '.gitattributes') -Encoding UTF8 -Value @(
            '* text=auto'
            '**/cfe/src/** -text'
        )
        Test-GitTextPolicy -RepoRoot $script:Repo -Path 'Продукт/cfe/src' | Should -BeTrue
    }

    It 'ловить нетиповий sourcePath, не накритий правилом' {
        # Це і є дефект: правило прив'язане до шляху, а sourcePath конфігурований.
        Set-Content -LiteralPath (Join-Path $script:Repo '.gitattributes') -Encoding UTF8 -Value @(
            '* text=auto'
            '**/cfe/src/** -text'
        )
        Test-GitTextPolicy -RepoRoot $script:Repo -Path 'Продукт/sources/ext' | Should -BeFalse
    }

    It 'бачить правило, дописане під нетиповий sourcePath' {
        Set-Content -LiteralPath (Join-Path $script:Repo '.gitattributes') -Encoding UTF8 -Value @(
            '* text=auto'
            '**/cfe/src/** -text'
            '**/sources/ext/** -text'
        )
        Test-GitTextPolicy -RepoRoot $script:Repo -Path 'Продукт/sources/ext' | Should -BeTrue
    }

    It 'без .gitattributes віддає false, а не падає' {
        Test-GitTextPolicy -RepoRoot $script:Repo -Path 'Продукт/cfe/src' | Should -BeFalse
    }
}
