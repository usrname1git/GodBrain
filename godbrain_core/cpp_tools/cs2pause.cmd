@echo off
set "ROOT=%~dp0..\..\"
cd /d "%ROOT%"
"C:\pwsh\pwsh.exe" -NoProfile -File "%ROOT%Watch-Cs2Pause.ps1"
