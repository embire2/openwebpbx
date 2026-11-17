@echo off
if not "%~1"=="" goto command
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ensure-Runtime.ps1" -StartManager
goto done
:command
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-OpenWebPBX.ps1" %*
:done
if errorlevel 1 pause
