@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-UpgradePathRepair.ps1"
set "OpenWebRepairExit=%ERRORLEVEL%"
if not "%OpenWebRepairExit%"=="0" (
  echo OpenWebPBX update needs attention. The message above explains what happened.
  pause
)
exit /b %OpenWebRepairExit%
