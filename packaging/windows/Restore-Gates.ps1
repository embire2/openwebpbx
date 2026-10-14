# Shared by installation, recovery and backup activation. Reading these gates
# never removes them; only the completed backup-restore activation may do that.
function Get-OpenWebRestoreGate {
 [CmdletBinding()]
 param([string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'))
 $directory=Join-Path $StateRoot 'backup-restore'
 $result=[ordered]@{Blocked=$false;Calls=$false;Jobs=$false;Updates=$false;Backups=$false}
 foreach($item in @(@('Calls','calls'),@('Jobs','jobs'),@('Updates','updates'),@('Backups','backups'))){
  $result[$item[0]]=Test-Path -LiteralPath (Join-Path $directory ('hold-'+$item[1]))
 }
 $journal=Join-Path $directory 'journal.json'
 if(Test-Path -LiteralPath $journal){
  try{
   $file=Get-Item -LiteralPath $journal
   if($file.Length -gt 1048576 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid restore journal.'}
   $record=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
   if($record.schema -ne 1 -or $record.state -notin 'prepared','restoring','recovery_required','restored','recovered'){throw 'Invalid restore state.'}
   $result.Blocked=$record.state -in 'prepared','restoring','recovery_required'
  }catch{$result.Blocked=$true}
 }
 [PSCustomObject]$result
}
function Assert-OpenWebUpgradeAllowed {
 [CmdletBinding()]
 param([string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'))
 $gate=Get-OpenWebRestoreGate -StateRoot $StateRoot
 if($gate.Blocked -or $gate.Calls -or $gate.Jobs -or $gate.Updates -or $gate.Backups){
  throw 'Complete backup restore recovery and activate the restored services before installing a server update.'
 }
}
