# QA only: ordinary original21 Core quiet window BEFORE exposure/acceptance baselines.
# Dot-sourcing defines functions only. Never alters a task, startup mode or another service.
function Assert-Original21CoreFixture {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the owned disposable original21 fixture may isolate Core.'}
}
function Assert-Original21CoreOrdinary([string]$O21Path) {
 $O21Item=Get-Item -LiteralPath $O21Path -Force -ErrorAction Stop
 if($O21Item.PSIsContainer){throw 'An ordinary original21 Core file is required.'}
 for($O21Node=$O21Item;$O21Node;$O21Node=if($O21Node.PSIsContainer){$O21Node.Parent}else{$O21Node.Directory}){if($O21Node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Original21 Core paths must not redirect.'}}
}
function Test-Original21CoreImage($O21Actual) {
 return ($O21Actual -is [string] -and ($O21Actual -ieq 'C:\OpenWebPBX\server\OpenWebPbx.Server.exe' -or $O21Actual -ieq '"C:\OpenWebPBX\server\OpenWebPbx.Server.exe"'))
}
function Assert-Original21CoreSample($O21Service,$O21Processes,[bool]$O21Transition) {
 if(@($O21Service).Count -ne 1 -or $O21Service.Name -cne 'OpenWebPBX' -or !(Test-Original21CoreImage $O21Service.PathName) -or $O21Service.StartName -cnotin 'NT AUTHORITY\LocalService','LocalService' -or $O21Service.StartMode -cne 'Manual'){throw 'The original21 Core service identity/configuration changed.'}
 $O21States=if($O21Transition){@('Running','Stopped','Stop Pending','Start Pending')}else{@('Running','Stopped')}
 if($O21Service.State -cnotin $O21States){throw 'The original21 Core service state is not admissible.'}
 if($O21Service.ProcessId -isnot [uint32] -and $O21Service.ProcessId -isnot [int] -and $O21Service.ProcessId -isnot [long]){throw 'The original21 Core PID is invalid.'}
 if($O21Service.ProcessId -lt 0 -or @($O21Processes).Count -gt 1){throw 'The original21 Core process sample is ambiguous.'}
 if(($O21Service.State -ceq 'Running' -and $O21Service.ProcessId -lt 1) -or ($O21Service.State -ceq 'Stopped' -and $O21Service.ProcessId -ne 0) -or (($O21Service.ProcessId -eq 0) -ne (@($O21Processes).Count -eq 0))){throw 'The original21 Core service/process state differs.'}
 if(@($O21Processes).Count -eq 1){
  $O21Process=$O21Processes[0]
  if($O21Process.ProcessId -ne $O21Service.ProcessId -or $O21Process.ExecutablePath -ine 'C:\OpenWebPBX\server\OpenWebPbx.Server.exe' -or $O21Process.OwnerReturn -ne 0 -or $O21Process.OwnerSid -cne 'S-1-5-19' -or $null -eq $O21Process.CreationDate){throw 'The original21 Core PID/image/token identity changed.'}
 }
}
function Get-Original21CoreState([string]$O21PackageRoot,[bool]$O21Transition=$false) {
 $O21ManifestPath=Join-Path $O21PackageRoot 'release-manifest.json';Assert-Original21CoreOrdinary $O21ManifestPath
 $O21Manifest=Get-Content -LiteralPath $O21ManifestPath -Raw -ErrorAction Stop|ConvertFrom-Json
 if($O21Manifest.version -cne '1.0.21'){throw 'Only the verified original public21 package is admissible.'}
 $O21Hashes=@{}
 foreach($O21Name in 'OpenWebPbx.Server.exe','OpenWebPbx.Server.dll'){
  $O21Relative='server/'+$O21Name;$O21Expected=$O21Manifest.files.($O21Relative)
  if($O21Expected -isnot [string] -or $O21Expected -cnotmatch '^[a-f0-9]{64}$'){throw 'The original21 manifest has no exact Core hash.'}
  foreach($O21Path in @((Join-Path $O21PackageRoot $O21Relative),('C:\OpenWebPBX\server\'+$O21Name))){Assert-Original21CoreOrdinary $O21Path;if((Get-FileHash -LiteralPath $O21Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $O21Expected){throw 'Original21 Core bytes differ from the verified package manifest.'}}
  $O21Hashes[$O21Relative]=$O21Expected
 }
 $O21Services=@(Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'" -OperationTimeoutSec 3 -ErrorAction Stop)
 $O21Processes=@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Server.exe'" -OperationTimeoutSec 3 -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq 'C:\OpenWebPBX\server\OpenWebPbx.Server.exe'}|ForEach-Object {
  $O21Owner=Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -OperationTimeoutSec 3 -ErrorAction Stop
  [pscustomobject]@{ProcessId=$_.ProcessId;ExecutablePath=$_.ExecutablePath;CreationDate=$_.CreationDate;OwnerReturn=$O21Owner.ReturnValue;OwnerSid=$O21Owner.Sid}
 })
 Assert-Original21CoreSample $O21Services $O21Processes $O21Transition
 return @{Running=($O21Services[0].State -ceq 'Running');State=$O21Services[0].State;PathName=$O21Services[0].PathName;StartName=$O21Services[0].StartName;StartMode=$O21Services[0].StartMode;ProcessId=[uint32]$O21Services[0].ProcessId;Hashes=$O21Hashes;Processes=$O21Processes}
}
function Assert-Original21CoreUnchanged($O21Original,$O21Current) {
 foreach($O21Field in 'PathName','StartName','StartMode'){if($O21Original[$O21Field] -cne $O21Current[$O21Field]){throw 'The original21 Core captured configuration changed.'}}
 foreach($O21Name in 'server/OpenWebPbx.Server.exe','server/OpenWebPbx.Server.dll'){if($O21Original.Hashes[$O21Name] -cne $O21Current.Hashes[$O21Name]){throw 'The original21 Core captured hashes changed.'}}
}
function Wait-Original21CoreStopped($O21Original,[string]$O21PackageRoot,[Diagnostics.Stopwatch]$O21Clock) {
 do{
  $O21Current=Get-Original21CoreState $O21PackageRoot $true;Assert-Original21CoreUnchanged $O21Original $O21Current
  $O21Prior=@(Get-CimInstance Win32_Process -Filter ('ProcessId='+[uint32]$O21Original.ProcessId) -OperationTimeoutSec 3 -ErrorAction Stop)
  if($O21Clock.Elapsed.TotalSeconds -ge 60){throw 'The exact original21 Core did not stop inside60s; no force or kill.'}
  if($O21Current.State -ceq 'Stopped' -and !$O21Prior.Count){return}
  Start-Sleep -Milliseconds 100
 }while($true)
}
function Restore-Original21CoreRunning($O21Original,[string]$O21PackageRoot) {
 $O21Clock=[Diagnostics.Stopwatch]::StartNew();$O21Current=Get-Original21CoreState $O21PackageRoot $true;Assert-Original21CoreUnchanged $O21Original $O21Current
 # A Stop-Service exception may leave the original process already running.
 if($O21Current.Running -and $O21Current.ProcessId -eq $O21Original.ProcessId -and $O21Current.Processes[0].CreationDate -eq $O21Original.Processes[0].CreationDate){return}
 Wait-Original21CoreStopped $O21Original $O21PackageRoot $O21Clock
 $O21Controller=Get-Service -Name OpenWebPBX -ErrorAction Stop
 try{
  if($O21Controller.ServiceName -cne 'OpenWebPBX' -or $O21Controller.MachineName -cne '.'){throw 'Only the exact local original21 Core start request is admissible.'}
  $O21Controller.Start() # Ordinary request only; no cmdlet/WaitForStatus internal loop.
 }finally{$O21Controller.Dispose()}
 do{
  $O21Current=Get-Original21CoreState $O21PackageRoot $true;Assert-Original21CoreUnchanged $O21Original $O21Current
  if($O21Clock.Elapsed.TotalSeconds -ge 60){throw 'The exact original21 Core running choice did not recover inside60s.'}
  if($O21Current.Running -and $O21Current.ProcessId -ne $O21Original.ProcessId){return}
  Start-Sleep -Milliseconds 100
 }while($true)
}
function Assert-Original21CoreToken($O21Token) {
 if($O21Token -isnot [Collections.IDictionary] -or ($O21Token.Schema -isnot [int] -and $O21Token.Schema -isnot [long]) -or $O21Token.Schema -ne 1 -or $O21Token.Purpose -cne 'original21-prebaseline-core-quiet' -or $O21Token.PackageRoot -isnot [string] -or $O21Token.Original -isnot [Collections.IDictionary] -or $O21Token.Original.Running -isnot [bool]){throw 'Only the private validated original21 Core token is admissible.'}
 if($O21Token.Original.StartMode -cne 'Manual' -or $O21Token.Original.StartName -cnotin 'NT AUTHORITY\LocalService','LocalService' -or !(Test-Original21CoreImage $O21Token.Original.PathName)){throw 'The captured original21 Core token identity changed.'}
 if(($O21Token.Original.Running -and $O21Token.Original.ProcessId -lt 1) -or (!$O21Token.Original.Running -and $O21Token.Original.ProcessId -ne 0)){throw 'The captured original21 Core token PID changed.'}
}
function Suspend-Original21PrebaselineCore {
 [CmdletBinding()]
 param([Parameter(Mandatory)][Alias('PackageRoot')][string]$O21PackageRoot)
 Assert-Original21CoreFixture
 $O21Original=Get-Original21CoreState $O21PackageRoot;$O21StopAttempt=$false;$O21Primary=$null
 try{
  if($O21Original.Running){$O21StopAttempt=$true;$O21Clock=[Diagnostics.Stopwatch]::StartNew();Stop-Service -NoWait -Name OpenWebPBX -ErrorAction Stop;Wait-Original21CoreStopped $O21Original $O21PackageRoot $O21Clock}
  $O21Quiet=Get-Original21CoreState $O21PackageRoot;Assert-Original21CoreUnchanged $O21Original $O21Quiet
  if($O21Quiet.State -cne 'Stopped'){throw 'Original21 Core is not quiet before fixture initialization.'}
  return @{Schema=1;Purpose='original21-prebaseline-core-quiet';PackageRoot=$O21PackageRoot;Original=$O21Original}
 }catch{$O21Primary=$_}
 # No token escaped. Undo only this ordinary stop attempt, including partial Stop failure.
 if($O21Original.Running -and $O21StopAttempt){
  try{Restore-Original21CoreRunning $O21Original $O21PackageRoot}
  catch{try{$O21Primary.Exception.Data['original21_core_restore_failed']=$true;$O21Primary.Exception.Data['original21_core_restore_error_type']=$_.Exception.GetType().FullName}catch{}}
 }
 $PSCmdlet.ThrowTerminatingError($O21Primary)
}
function Resume-Original21PrebaselineCore {
 [CmdletBinding()]
 param([Parameter(Mandatory)][Alias('Token')]$O21Token)
 Assert-Original21CoreFixture;Assert-Original21CoreToken $O21Token
 $O21Current=Get-Original21CoreState $O21Token.PackageRoot;Assert-Original21CoreUnchanged $O21Token.Original $O21Current
 if($O21Current.State -cne 'Stopped'){throw 'The known stopped original21 Core state changed during preparation.'}
 if($O21Token.Original.Running){Restore-Original21CoreRunning $O21Token.Original $O21Token.PackageRoot}
}
