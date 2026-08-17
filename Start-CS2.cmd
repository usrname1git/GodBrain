@echo off
setlocal
set "HERE=%~dp0"
title CS2 - GodBrain sleeps
echo Pausing GodBrain and Tailscale, then launching CS2.
echo After you quit, the mouth and Tailscale wake in 5 minutes.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Start-CS2.ps1" -RepoRoot "%HERE%."
echo.
pause
