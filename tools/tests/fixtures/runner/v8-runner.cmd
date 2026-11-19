@echo off
rem Фальшивий v8-runner для тестів-підпроцесів (спека 2026-11-19 §4.2 п.20). Друкує знімки
rem справжніх відповідей раннера 0.18.1, які лежать поруч.
rem Команду розпізнає підрядком у рядку аргументів, а не циклом for: exit /b усередині for у cmd
rem не завершує скрипт з потрібним кодом (виміряно) - а код виходу тут частина контракту тесту.
rem platforms: за наявності v8project.local.yaml у робочій теці - знімок ok:true; без нього -
rem знімок ok:false. Типові коди виходу: 0 для ok:true, 2 для ok:false (як у справжнього раннера).
rem Код виходу можна задати файлом fake-exit.txt у робочій теці (одне число) - так тест розв'язує
rem поле ok і код виходу: ok:false з кодом 0, ok:true з ненульовим.
set "FIX=%~dp0"
set "ARGS= %* "
set "RC="
if exist fake-exit.txt set /p RC=<fake-exit.txt
set "RCOK=0"
set "RCFAIL=2"
if defined RC set "RCOK=%RC%"
if defined RC set "RCFAIL=%RC%"
if not "%ARGS: --version =%"=="%ARGS%" type "%FIX%version.txt"
if not "%ARGS: --version =%"=="%ARGS%" exit /b 0
if not "%ARGS: agent =%"=="%ARGS%" type "%FIX%agent-release-ok.json"
if not "%ARGS: agent =%"=="%ARGS%" exit /b 0
if "%ARGS: platforms =%"=="%ARGS%" (echo fake v8-runner: unknown command: %* 1>&2 & exit /b 64)
if exist v8project.local.yaml type "%FIX%platforms-ok.json"
if exist v8project.local.yaml exit /b %RCOK%
type "%FIX%platforms-no-infobase.json"
exit /b %RCFAIL%
