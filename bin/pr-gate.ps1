# Обгортка команди v8storagekit: ім'я команди = ім'я цього файлу без .ps1; вхід — kit.exe поруч (спека #51 D2).
# Окремий процес, а не виклик у сесії агента: exit команди не закриває його оболонку, а модулі kit не
# лишаються в ній. Аргументи — рядками. Форму -Ім'я:значення PowerShell кладе в $args двома елементами
# (`-Ім'я:` і значення; `$false` — булевим), тож обгортка склеює їх назад у один токен для kit.exe.
$kitArgs = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^-[A-Za-z][A-Za-z0-9]*:$' -and $i + 1 -lt $args.Count) { $a += [string]$args[++$i] }
    $kitArgs.Add($a)
}
& (Join-Path $PSScriptRoot 'kit.exe') ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)) @kitArgs
exit $LASTEXITCODE
