#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$OwnedRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition-cne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or[IntPtr]::Size-ne8-or$env:GITHUB_ACTIONS-cne'true'-or$env:RUNNER_ENVIRONMENT-cne'github-hosted'-or$env:GITHUB_REPOSITORY-cne'embire2/openwebpbx'){throw 'Exact native owned listener component required.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
if($os.Caption-notmatch'Windows Server 2025'-or$os.ProductType-eq1){throw 'Actual Windows Server2025 required.'}
$scope=Get-Item -LiteralPath $OwnedRoot -Force
if(!$scope.PSIsContainer-or@(Get-ChildItem -LiteralPath $scope.FullName -Force).Count){throw 'Fresh owned wrapper scope required.'}
for($node=$scope;$node;$node=$node.Parent){if($node.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Ordinary owned wrapper scope required.'}}
$native=Join-Path $SourceRoot 'tests/windows_public_listeners_native.ps1'
$common=Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1'
$gates=Join-Path $SourceRoot 'packaging/windows/Restore-Gates.ps1'
$pins=@{$native='32fbf9074500f4c9a367904dd0833ffa2a25bdbac94d819360945ec8ff0c3934';$common='18ca8ea882873a6a495793349c34e306c9ced5e49a4b07015577bdf903508c28';$gates='58973e24a201799c10ddb5d96c197da4c1b4fef6e20ec26dea5b528b7475ca27'}
$ownedSources=@{$native='windows_public_listeners_native.ps1';$common='PublicAccess.Common.ps1';$gates='Restore-Gates.ps1';$PSCommandPath='windows_public_listeners_component.ps1'}
function Test-OriginalListenerSources {
 foreach($path in $pins.Keys){$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()-cne$pins[$path]){return $false}}
 return $true
}
$report=[ordered]@{schema=1;scope='unchanged_owned_native_public_listener_component_only';state='failed';phase='input';native_invoked=$false;caught_error=$false;error_type='none';hresult=0;source_name='unavailable';source_line=0;stack_frames=@();stack_frames_truncated=$false;error_observation_complete=$false;original_sources_unchanged=$false;earlier_native_primary_recovered=$false;native_cleanup_qualified_by_wrapper=$false}
function Set-ListenerCaughtError($Record) {
 # Only the actual escaping ErrorRecord. An earlier exception masked by the original finally remains unknown.
 try{
  if($Record.Exception-isnot[Exception]){return}
  $type=$Record.Exception.GetType().Name
  if($type-cnotmatch'^[A-Za-z][A-Za-z0-9_]{0,79}$'){return}
  $report.error_type=$type;$report.hresult=[int]$Record.Exception.HResult
  $origin=$Record.InvocationInfo.ScriptName;$line=$Record.InvocationInfo.ScriptLineNumber
  if($origin-is[string]-and$ownedSources.ContainsKey($origin)-and$line-ge1-and$line-le100000){$report.source_name=$ownedSources[$origin];$report.source_line=[int]$line}
  $trace=$Record.ScriptStackTrace;$frames=@();$truncated=$false
  if($trace-is[string]-and$trace.Length-le16384){
   foreach($frame in $trace-split'\r?\n'){
    foreach($path in $ownedSources.Keys){
     $match=[regex]::Match($frame,',\s*'+[regex]::Escape($path)+': line (?<line>[1-9][0-9]{0,5})\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
     if($match.Success-and[long]$match.Groups['line'].Value-le100000){
      if($frames.Count-lt4){$frames+=,@{source_name=$ownedSources[$path];source_line=[int]$match.Groups['line'].Value}}else{$truncated=$true};break
     }
    }
   }
  }elseif($trace-is[string]){$truncated=$true}
  $report.stack_frames=@($frames);$report.stack_frames_truncated=$truncated
  $report.error_observation_complete=$true
 }catch{} # Observation must not replace the caught error.
}
try{
 if(!(Test-OriginalListenerSources)){throw 'Exact original listener inputs required.'}
 $report.phase='native';$report.native_invoked=$true
 # Direct invocation preserves any stdout emitted before the original finally throws.
 & $native -SourceRoot $SourceRoot
 $report.state='returned';$report.phase='complete'
}catch{
 $report.caught_error=$true;Set-ListenerCaughtError $_
 throw
}finally{
 try{$report.original_sources_unchanged=[bool](Test-OriginalListenerSources)}catch{}
 try{
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 3 -Compress))
  if($bytes.Length-gt4096){throw 'Bounded wrapper observation required.'}
  $file=[IO.File]::Open((Join-Path $scope.FullName 'wrapper.safe.json'),'CreateNew','Write','None')
  try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
 }catch{if(!$report.caught_error){throw}}
}
