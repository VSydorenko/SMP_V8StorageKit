# Обгортка команди процесу v8storagekit (ADR-0002): ім'я команди = ім'я цього файлу без .ps1.
# Окремий процес pwsh, а не виклик у сесії агента: exit команди не закриває його оболонку, а модулі
# kit не лишаються в ній. Аргументи — рядками: форма -Ім'я:значення при сплаті @args губить ім'я.
$kitArgs = [string[]]@(foreach ($a in $args) { [string]$a })
& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../tools/kit.ps1') ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath)) @kitArgs
exit $LASTEXITCODE
