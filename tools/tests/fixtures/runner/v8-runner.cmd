@echo off
rem Фальшивий v8-runner для тестів-підпроцесів (спека 2026-11-19 §4.2 п.20). Друкує знімки
rem справжніх відповідей раннера 0.18.1, які лежать поруч. Без міток і goto: файл може
rem лишитись з LF-кінцями рядків, а cmd на LF-мітках збивається.
rem platforms: за наявності v8project.local.yaml у робочій теці - знімок ok:true; без нього -
rem знімок ok:false з кодом виходу 2, як у справжнього раннера на відсутній базі.
set "FIX=%~dp0"
for %%A in (%*) do (
  if /i "%%~A"=="--version" ( type "%FIX%version.txt" & exit /b 0 )
  if /i "%%~A"=="platforms" (
    if exist v8project.local.yaml ( type "%FIX%platforms-ok.json" & exit /b 0 )
    type "%FIX%platforms-no-infobase.json" & exit /b 2
  )
  if /i "%%~A"=="agent" ( type "%FIX%agent-release-ok.json" & exit /b 0 )
)
echo fake v8-runner: unknown command: %* 1>&2
exit /b 64
