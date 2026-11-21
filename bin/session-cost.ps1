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
# kit.exe не запустився (немає поруч, заблокований антивірусом, не застосунок) — не тихий код 0 від
# `exit $LASTEXITCODE` із застарілого значення, а код 2 (помилка виклику, tools/lib/KitCli.psm1) і рядок
# `<команда>: ERROR …` у stderr. Код запущеного kit.exe проходить як є.
$kitName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$global:LASTEXITCODE = $null
try {
    & (Join-Path $PSScriptRoot 'kit.exe') $kitName @kitArgs
} catch {
    [Console]::Error.WriteLine("${kitName}: ERROR kit.exe не запустився: $($_.Exception.Message)")
    exit 2
}
if ($null -eq $LASTEXITCODE) {
    [Console]::Error.WriteLine("${kitName}: ERROR kit.exe не повернув коду виходу")
    exit 2
}
exit $LASTEXITCODE
