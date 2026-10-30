@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DiskLensPremiumV3.ps1" 2>"%~dp0DiskLens_Hata.log"
if errorlevel 1 (
  echo.
  echo DiskLens baslatilirken hata olustu.
  echo Hata kaydi: %~dp0DiskLens_Hata.log
  pause
)
endlocal
