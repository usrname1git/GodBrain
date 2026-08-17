@echo off
set "ROOT=%~dp0..\..\"
cd /d "%ROOT%"
echo %DATE% %TIME% watch.cmd start>> "logs\watch.log"
"C:\pwsh\pwsh.exe" -NoProfile -File "%ROOT%Watch-GodBrain.ps1"
echo %DATE% %TIME% watch.cmd exit %ERRORLEVEL%>> "logs\watch.log"
