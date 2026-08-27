@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0snipeit_inventory.ps1" -ManualMode -ForceInventory -DryRun
