@echo off
wpeinit
echo Reclaim11 pack A WinPE. Not a host wipe.
echo Press H on the next screen if Windows won't boot.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Reclaim11\Start-Reclaim11Pe.ps1
echo.
echo When finished: wpeutil reboot
pause
