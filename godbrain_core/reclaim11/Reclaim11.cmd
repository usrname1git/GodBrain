@echo off
setlocal EnableExtensions
REM Double-click door. Do not type pwsh. UAC is inside Reclaim11.ps1.
set "KIT=%~dp0"
set "GUI=%KIT%ps1\Reclaim11.ps1"
if not exist "%GUI%" (
  echo Reclaim11.cmd: missing ps1\Reclaim11.ps1
  exit /b 1
)
set "PWSH="
if exist "C:\pwsh\pwsh.exe" set "PWSH=C:\pwsh\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\pwsh.exe"
REM Do not search PATH for pwsh (Win11 Store stub is WindowsApps). 5.1 is a real host.
if not defined PWSH set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" (
  echo Reclaim11.cmd: no PowerShell found
  exit /b 1
)
start "" "%PWSH%" -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%GUI%"
exit /b 0
