@echo off
setlocal
title SnipeIT Inventory Manual Installer

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_snipeit_manual.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo SnipeIT Inventory installation completed.
) else (
    echo SnipeIT Inventory installation failed with code %EXIT_CODE%.
)
pause
exit /b %EXIT_CODE%
