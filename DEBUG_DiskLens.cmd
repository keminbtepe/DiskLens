@echo off
setlocal
cd /d "%~dp0"
title DiskLens Debug
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -Command "& '%~dp0DiskLensPremiumV3.ps1' *>&1 | Tee-Object -FilePath '%~dp0DiskLens_Debug.log'"
endlocal
