@echo off
title GodBrainDash
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -File "%~dp0Invoke-FrontendGym.ps1" -Command dashboard
