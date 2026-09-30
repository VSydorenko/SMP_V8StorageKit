#Requires -Version 7
Describe 'kit check — поставка вендора основної конфігурації (спека 2026-09-30 §5.2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'fixtures/CheckSetup.ps1')
        function script:New-ClientRepo {
            param([string]$Name)
            New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -Workspaces (New-KitClientWorkspaces) -WithHooks -WithGitattributes -WithGitignore -WithSupply
        }
        $script:Cfg = 'Client_UNF/cf/src'
    }

    It 'усе правильно: поставка під ігнором, .bin у git, позначка актуальна — без знахідок про поставку, код 0' {
        $repo = New-ClientRepo 'supply-good'
        $r = Invoke-Check -Repo $repo
        # Код 0 — ще й доказ, що check приймає здоровий клієнтський воркспейс (спека §1). Якщо тут
        # error — лагодити ФІКСТУРУ (вона мусить зображати здоровий репозиторій), не check, і
        # назвати причину в сумнівах.
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Not -BeLike '*поставк*'
        $r.Output | Should -Not -BeLike '*ознаки підтримки*'
    }

    It '.cf не під ігнором (репозиторій до 1.3.0) — error' {
        $repo = New-ClientRepo 'supply-not-ignored'
        $gi = Join-Path $repo '.gitignore'
        (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*не гітігнорована*'
        $r.Output | Should -BeLike '*`*`*/Ext/ParentConfigurations/*'
    }

    It 'ігнор лише `*.cf` без рядка теки поставки — позначка .kit-bin-sha1 не ігнорується, error' {
        $repo = New-ClientRepo 'supply-cf-only'
        $gi = Join-Path $repo '.gitignore'
        (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
        Add-Content -LiteralPath $gi -Encoding UTF8 -Value '*.cf'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -BeLike '*не гітігнорована*'
    }

    It '.bin під ігнором — error' {
        $repo = New-ClientRepo 'supply-bin-ignored'
        Add-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding UTF8 -Value '**/Ext/ParentConfigurations.bin'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*ознаки підтримки*гітігноровано*'
    }

    It '.cf закомічено силою — error з git rm -r --cached' {
        $repo = New-ClientRepo 'supply-tracked'
        git -C $repo add -f -- "$script:Cfg/Ext/ParentConfigurations/Vendor.cf"
        git -C $repo commit -qm 'поставку закомічено силою'
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -BeLike '*поставка вендора відстежується git*'
        $r.Output | Should -BeLike "*git rm -r --cached*$script:Cfg/Ext/ParentConfigurations*"
    }

    It '.cf на диску немає — warn «відсутня» з рецептом, код 0' {
        $repo = New-ClientRepo 'supply-missing'
        Remove-Item -LiteralPath (Join-Path $repo "$script:Cfg/Ext/ParentConfigurations/Vendor.cf") -Force
        $r = Invoke-Check -Repo $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
        # [!] — рівень warn у виводі check (Invoke-KitCheck: error → [-], warn → [!]).
        $r.Output | Should -Match '\[!\][^\r\n]*поставка вендора відсутня'
        $r.Output | Should -BeLike '*поставка вендора відсутня*kit verify -Source base*kit canon -Source base -Apply*'
    }

    It 'підмінений .bin (новий реліз) — warn «застаріла»' {
        $repo = New-ClientRepo 'supply-stale'
        [System.IO.File]::WriteAllBytes((Join-Path $repo "$script:Cfg/Ext/ParentConfigurations.bin"), [byte[]](1..99))
        git -C $repo commit -qam 'новий реліз вендора'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -BeLike '*поставка вендора застаріла*'
    }

    It 'знята з підтримки (.bin 16 байт), рядка ігнору немає — check мовчить про поставку' {
        $repo = New-ClientRepo 'supply-none'
        $gi = Join-Path $repo '.gitignore'
        (Get-Content -LiteralPath $gi -Encoding UTF8 | Where-Object { $_.Trim() -ne '**/Ext/ParentConfigurations/' }) | Set-Content -LiteralPath $gi -Encoding UTF8
        Remove-Item -LiteralPath (Join-Path $repo "$script:Cfg/Ext/ParentConfigurations") -Recurse -Force
        [System.IO.File]::WriteAllBytes((Join-Path $repo "$script:Cfg/Ext/ParentConfigurations.bin"), [byte[]](1..16))
        git -C $repo commit -qam 'знято з підтримки'
        $r = Invoke-Check -Repo $repo
        $r.Output | Should -Not -BeLike '*поставк*'
    }
}
