@echo off
setlocal
cd /d "%~dp0"
title DiskLens Premium V3.2.9 - Debug
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0DiskLensPremiumV3.ps1"
