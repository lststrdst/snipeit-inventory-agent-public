@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%snipeit_inventory.ps1" -ManualMode -ForceInventory -ForceEmailReport
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
