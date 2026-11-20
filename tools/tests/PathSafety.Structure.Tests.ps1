#Requires -Version 7
Describe 'Запобіжник: кожному Remove-KitDirectory у коді kit передує Assert-SafeWorkPath у тій самій функції' {
    It 'структурно (AST): жодного виклику Remove-KitDirectory без попереднього Assert-SafeWorkPath' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..') -Recurse -Include *.psm1, *.ps1 -File |
            Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' -and $_.Name -ne 'PathSafety.psm1' })
        $files.Count | Should -BeGreaterThan 10 -Because 'пошук має справді знаходити файли kit'
        $calls = 0
        $bad = foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in @($cmds | Where-Object { $_.GetCommandName() -eq 'Remove-KitDirectory' })) {
                $calls++
                $fn = $c.Parent
                while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
                $guarded = $false
                if ($fn) {
                    $guarded = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Assert-SafeWorkPath', 'Assert-KitBuildPath') -and $n.Extent.StartOffset -lt $c.Extent.StartOffset }, $true)).Count -gt 0
                }
                if (-not $guarded) { "$($f.Name):$($c.Extent.StartLineNumber)" }
            }
        }
        $calls | Should -BeGreaterThan 10 -Because 'у kit десятки викликів Remove-KitDirectory; нуль означає, що пошук сліпий'
        @($bad) | Should -HaveCount 0 -Because ("виклики без Assert-SafeWorkPath перед ними: " + ($bad -join ', '))
    }

    It 'структурно (AST): кожен виклик Assert-SafeWorkPath передає -RepoRoot' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..') -Recurse -Include *.psm1, *.ps1 -File |
            Where-Object { ($_.FullName -notmatch '[\\/]tests[\\/]' -or $_.Name -eq 'Run-Tests.ps1') -and $_.Name -ne 'PathSafety.psm1' })
        $calls = 0
        $bad = foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-SafeWorkPath' }, $true)
            foreach ($c in @($cmds)) {
                $calls++
                $has = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'RepoRoot' }).Count -gt 0
                if (-not $has) { "$($f.Name):$($c.Extent.StartLineNumber)" }
            }
        }
        $calls | Should -BeGreaterThan 10 -Because 'у kit десятки викликів Assert-SafeWorkPath; нуль означає, що пошук сліпий'
        @($bad) | Should -HaveCount 0 -Because ("виклики Assert-SafeWorkPath без -RepoRoot: " + ($bad -join ', '))
    }
}
