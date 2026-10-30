@echo off
setlocal
cd /d "%~dp0"
title DiskLens Premium V3.2.9

echo DiskLens baslatiliyor...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DiskLensPremiumV3.ps1" 1>>"%~dp0DiskLens_Baslatma.log" 2>>&1

if errorlevel 1 (
    echo.
    echo =========================================================
    echo DiskLens kritik hata verdi.
    echo Ayrinti: DiskLens_Baslatma.log ve DiskLens_Hata.log
    echo =========================================================
    echo.
    if exist "%~dp0DiskLens_Hata.log" type "%~dp0DiskLens_Hata.log"
    echo.
    pause
)
