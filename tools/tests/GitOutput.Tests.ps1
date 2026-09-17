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

Describe 'Get-KitOriginGap' {
    BeforeAll {
        Import-Module (Resolve-Path "$PSScriptRoot/../lib/GitOutput.psm1").Path -Force
        Import-Module (Resolve-Path "$PSScriptRoot/fixtures/KitFixtures.psm1").Path -Force
    }

    It 'без remote — HasRemote=$false і нулі' {
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'no-remote')
        $g = Get-KitOriginGap -RepoRoot $repo -Branch 'main'
        $g.HasRemote | Should -BeFalse
        $g.Behind    | Should -Be 0
    }

    It 'локальна гілка позаду origin — Behind рахується' {
        $up   = Join-Path $TestDrive 'upstream'
        $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'behind')
        git clone -q --bare $repo $up 2>&1 | Out-Null
        git -C $repo remote add origin $up 2>&1 | Out-Null
        # Коміт лише в origin: клонуємо, комітимо там, фетчимо назад.
        $work = Join-Path $TestDrive 'work'
        git clone -q $up $work 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'new.txt') -Value 'x' -Encoding UTF8
        git -C $work add -A 2>&1 | Out-Null
        git -C $work -c user.email=t@e.invalid -c user.name=T commit -q -m 'з іншої машини' 2>&1 | Out-Null
        git -C $work push -q origin main 2>&1 | Out-Null
        git -C $repo fetch -q origin 2>&1 | Out-Null
        $g = Get-KitOriginGap -RepoRoot $repo -Branch 'main'
        $g.HasRemote | Should -BeTrue
        $g.Behind    | Should -Be 1
    }
}
