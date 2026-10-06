@echo off
setlocal
set "HERE=%~dp0"
title CS2 - manual GodBrain controls
if exist "C:\pwsh\pwsh.exe" (
    set "PWSH=C:\pwsh\pwsh.exe"
) else (
    set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%Start-CS2.ps1" -RepoRoot "%HERE%."
if errorlevel 1 (
    echo CS2 was not launched. Review the error above.
    pause
    exit /b 1
)
exit /b 0
