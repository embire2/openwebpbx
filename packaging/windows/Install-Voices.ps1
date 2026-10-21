#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$Check)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$engine='C:\Program Files\FreeSWITCH'
foreach($path in $PackageRoot,$engine,"$engine\sounds","$PackageRoot\backup-runtime\python.exe","$PackageRoot\install-voices.py"){
 $current=[IO.Path]::GetFullPath($path)
 while($current){
  if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'System voice paths must not contain links or junctions.'}}
  $parent=[IO.Path]::GetDirectoryName($current);if($parent -eq $current){break};$current=$parent
 }
}
if(!$Check -and (Get-Service FreeSWITCH).Status -ne 'Stopped'){throw 'Stop the call engine inside the installation or upgrade transaction before replacing system voices.'}
$arguments=@('-I','-B',"$PackageRoot\install-voices.py",'--package',$PackageRoot,'--sounds',"$engine\sounds")
if($Check){$arguments+='--check'}
& "$PackageRoot\backup-runtime\python.exe" @arguments
if($LASTEXITCODE){throw 'System voice activation refused. Existing custom prompts are preserved; review the private installation log.'}
