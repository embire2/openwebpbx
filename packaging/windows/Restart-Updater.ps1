# Runs independently through the installed SYSTEM task after the current worker
# has committed its command/status and the PBX has passed its health checks.
$ErrorActionPreference='Stop'
Start-Sleep -Seconds 5
Restart-Service OpenWebPBXUpdater
