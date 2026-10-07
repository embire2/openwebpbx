@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ensure-Runtime.ps1" -StartManager
if errorlevel 1 pause
