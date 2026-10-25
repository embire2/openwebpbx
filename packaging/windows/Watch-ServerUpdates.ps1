[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# This runs in the signed-in user's session, never the Windows service desktop.
# Its only action is opening the unelevated manager. It cannot install an update.
$guard=New-Object Threading.Mutex($false,'Local\OpenWebPBX-ServerUpdateMonitor')
if(!$guard.WaitOne(0)){ $guard.Dispose(); return }
$seen=''
$status=Join-Path $env:ProgramData 'OpenWebPBX-Status\updates.json'
$manager='C:\OpenWebPBX\desktop\OpenWebPbx.Desktop.exe'
try {
 while($true){
  try {
   $file=[IO.File]::Open($status,'Open','Read','ReadWrite,Delete')
   try {
    if($file.Length -gt 65536){throw 'Status exceeds its bound.'}
    $reader=New-Object IO.StreamReader($file)
    try{$notice=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
   }finally{$file.Dispose()}
   $version=$notice.available_version
   $installed=$notice.installed_version
   if($notice.platform -ceq 'windows-x64' -and $notice.update_required -is [bool] -and $notice.update_required -and
      $version -is [string] -and $version -cmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -and
      $installed -is [string] -and $installed -cmatch '^\d+\.\d+\.\d+$' -and [version]$version -gt [version]$installed -and $seen -cne $version){
    $session=(Get-Process -Id $PID).SessionId
    $running=@(Get-Process -Name OpenWebPbx.Desktop -ErrorAction SilentlyContinue|Where-Object {$_.SessionId -eq $session -and $_.Path -eq $manager})
    if(!$running -and (Test-Path -LiteralPath $manager -PathType Leaf)){Start-Process -FilePath $manager -WorkingDirectory (Split-Path $manager)|Out-Null}
    if($running -or (Test-Path -LiteralPath $manager -PathType Leaf)){$seen=$version}
   }
  }catch{ # Atomic status replacement, offline services and sign-in races are retried without affecting the PBX.
  }
  Start-Sleep -Seconds 10
 }
}finally{$guard.ReleaseMutex();$guard.Dispose()}
