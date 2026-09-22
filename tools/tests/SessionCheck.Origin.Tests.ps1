#Requires -Version 7
Describe 'kit session-check — сигнал без платформи (§5)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'fixtures/SessionCheckSetup.ps1') }

    # Task 6 (batch-5-6-brief.md) — відставання локальної гілки від origin: session-check лише
    # ЧИТАЄ вже наявні remote-tracking refs (Get-KitOriginGap, Task 5), мережі не чіпає взагалі.
    Context 'origin: відставання без мережі (Task 6)' {
        It 'дзеркало позаду origin — рядок із порадою git fetch' {
            # Дзеркало, яке в origin пішло вперед, а локально лишилось позаду — рівно стан із ішузу #4.
            # Перший коміт — через Add-KitFakeStorageCommit (той самий механізм, що New-Repo вище): орфанна
            # гілка з коректними трейлерами, інакше kit check спіткнеться на власних інваріантах
            # storage/* (Storage-Source/Storage-Version, дерево лише під шляхом джерела) РАНІШЕ, ніж
            # дійде до сигналу origin, і "Сигнали не обчислювались" замаскує саме те, що тест перевіряє.
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-behind') -WithHooks -WithGitattributes -WithGitignore
            Add-KitFakeStorageCommit -Repo $repo -Branch 'storage/Alpha_SMB' -RepoPath 'Alpha_SMB/cfe/src' `
                -FileName 'A.xml' -Content 'v1' -Trailers @('Storage-Source: Alpha_SMB', 'Storage-Version: 1')

            $up = Join-Path $TestDrive 'sc-upstream'
            git clone -q --bare $repo $up 2>&1 | Out-Null
            git -C $repo remote add origin $up 2>&1 | Out-Null

            # Коміт, який зробила «інша машина»: у bare-репозиторій через окрему робочу копію,
            # ПРОДОВЖЕННЯМ уже існуючої (орфанної) гілки — не новий orphan, звичайний лінійний
            # коміт, з тим самим набором трейлерів, який дав би реальний kit sync.
            $work = Join-Path $TestDrive 'sc-work'
            git clone -q $up $work 2>&1 | Out-Null
            git -C $work checkout -q 'storage/Alpha_SMB' 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $work 'Alpha_SMB/cfe/src/A.xml') -Value 'v2' -Encoding UTF8
            git -C $work add -A 2>&1 | Out-Null
            $msg2 = @('sync: версія 2', '', 'Storage-Source: Alpha_SMB', 'Storage-Version: 2') -join "`n"
            git -C $work -c user.email=t@e.invalid -c user.name=T commit -q -m $msg2 2>&1 | Out-Null
            git -C $work push -q origin 'storage/Alpha_SMB' 2>&1 | Out-Null

            # Локальний репозиторій дізнається про це лише фетчем — саме те, чого агент не робив.
            git -C $repo fetch -q origin 2>&1 | Out-Null

            $r = Invoke-SessionCheck -Repo $repo
            $r.Output | Should -BeLike '*позаду origin*'
            $r.Output | Should -BeLike '*git fetch*'
        }

        It 'session-check не викликає git fetch' {
            $repo = New-KitFakeRepo -Root (Join-Path $TestDrive 'sc-nofetch') -WithHooks -WithGitignore
            # GIT_TRACE пише кожен запуск git у файл рядком виду
            #   trace: built-in: git fetch origin
            # — БЕЗ лапок навколо підкоманди (перевірено на git 2.53). Асерція на "*'fetch'*"
            # (у лапках) була б зелена завжди й не стверджувала б нічого — рівно той клас
            # тавтологічного guard'а, що docs/follow-ups.md §4 називає дефектом культури тестів.
            $trace = Join-Path $TestDrive 'git-trace.log'
            $env:GIT_TRACE = $trace
            Invoke-SessionCheck -Repo $repo | Out-Null
            Remove-Item Env:\GIT_TRACE
            $trace | Should -Exist -Because 'без трасування тест не стверджує нічого'
            (Get-Content -LiteralPath $trace -Raw) | Should -Not -BeLike '*built-in: git fetch*'
        }
    }
}
