@echo off
wpeinit
echo Reclaim11 pack A WinPE. Not a host wipe.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Reclaim11\Apply-Reclaim11Offline.ps1
echo.
echo When the guest Windows volume is stubbed: wpeutil reboot
pause
