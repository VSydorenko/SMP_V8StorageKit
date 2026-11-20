#Requires -Version 7
<#
    Виклик git із командам процесу (review-pack, sdd, …): stdout повертається ОДНИМ рядком як є.

    Чому не `& git`: PowerShell ріже вивід на рядки й губить `\r` у діфах CRLF-файлів 1С, а
    рецензент має бачити діф байт у байт. Тому — System.Diagnostics.Process з UTF-8 потоками;
    stderr читається асинхронно, інакше великий діф, що заповнив буфер одного каналу, поки
    процес пише в другий, дає дедлок.
#>
Set-StrictMode -Version Latest

function Invoke-KitGit {
    <#
    .SYNOPSIS
        git -c core.quotepath=false -C <Root> <Arguments> → [pscustomobject]@{ ExitCode; Out; Err }.
    .DESCRIPTION
        quotepath=false — кириличні імена файлів друкуються як є, а не як \320\272. Без -AllowFail
        ненульовий код — виняток з першим рядком stderr; з -AllowFail код лишається в результаті.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFail
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($a in @('-c', 'core.quotepath=false', '-C', $Root) + $Arguments) { $psi.ArgumentList.Add([string]$a) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        $null = $proc.Start()
        $proc.StandardInput.Close()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $err = $errTask.GetAwaiter().GetResult()
        $code = $proc.ExitCode
    } finally { $proc.Dispose() }

    if ($code -ne 0 -and -not $AllowFail) {
        $first = (@($err -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        throw "git $($Arguments[0]) завершився з кодом ${code}: $(if ($first) { $first } else { 'без повідомлення' })"
    }
    [pscustomobject]@{ ExitCode = $code; Out = $out; Err = $err }
}

Export-ModuleMember -Function Invoke-KitGit
