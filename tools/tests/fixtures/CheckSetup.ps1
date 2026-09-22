# Спільна підготовка для розрізаних файлів Check.*.Tests.ps1 (Task 6, "Швидкість набору
# тестів") — дослівний перенос тіла BeforeAll з колишнього Check.Tests.ps1:3-18.
# Підключається DOT-SOURCE із BeforeAll кожного файлу, не Import-Module: перенесені
# хелпери користуються $TestDrive (Pester-змінна поточного тестового прогону) і
# function script:, а всередині модуля перше не видно, друге осідає в чужій області —
# та сама пастка вкладеного Import-Module, яку описує великий коментар у KitFixtures.psm1
# і docs/follow-ups.md §5.
#
# $PSScriptRoot тут — власна тека ЦЬОГО файлу (tools/tests/fixtures/), А НЕ виклика:
# у PowerShell dot-source не переносить $PSScriptRoot файлу, що підключає, — файл, який
# підключають, бачить СВІЙ ВЛАСНИЙ $PSScriptRoot (перевірено емпірично: callee.ps1,
# підключений через . з іншої теки, друкує свій каталог, не каталог caller.ps1). Тому
# KitFixtures.psm1 тут — сусід по теці, без префікса 'fixtures/'.
Import-Module (Resolve-Path "$PSScriptRoot/KitFixtures.psm1").Path -Force
$script:Kit = Copy-KitTools -Root (Join-Path $TestDrive 'kit')

function script:Invoke-Check {
    param([string]$Repo, [string[]]$More = @())
    Invoke-KitCommand -Kit $script:Kit -Command 'check' -Repo $Repo -More $More
}
# Репозиторій, у якому все правильно: хуки, політика тексту, gitignore.
function script:New-GoodRepo {
    param([string]$Name, [hashtable]$Extra = @{})
    New-KitFakeRepo -Root (Join-Path $TestDrive $Name) -WithHooks -WithGitattributes -WithGitignore @Extra
}
