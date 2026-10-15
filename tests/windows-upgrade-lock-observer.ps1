# Test-only, read-only failure observation. Never stops/restarts/unlocks a holder.
# https://learn.microsoft.com/windows/win32/api/restartmanager/nf-restartmanager-rmgetlist
function Initialize-OpenWebLockObserverNative {
 if('OpenWebQualificationLockObserver' -as [type]){return}
 Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class OpenWebQualificationLockObserver {
 [StructLayout(LayoutKind.Sequential)] struct UniqueProcess {public int Id; public System.Runtime.InteropServices.ComTypes.FILETIME Started;}
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct ProcessInfo {
  public UniqueProcess Process;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Name;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)] public string Service;
  public uint Kind,Status,Session;
  [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
 }
 public sealed class Holder {public int Id; public long Started;}
 public sealed class Result {public int Code; public bool OverLimit; public Holder[] Holders=new Holder[0];}
 [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)] static extern int RmStartSession(out uint session,uint flags,StringBuilder key);
 [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)] static extern int RmRegisterResources(uint session,uint files,string[] names,uint processes,IntPtr apps,uint services,IntPtr namesServices);
 [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint session,out uint needed,ref uint count,[In,Out] ProcessInfo[] apps,ref uint reasons);
 [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint session);
 [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 public static string[] Arguments(string command) {
  if(String.IsNullOrEmpty(command)||command.Length>32768)return new string[0];
  int count;IntPtr memory=CommandLineToArgvW(command,out count);
  if(memory==IntPtr.Zero)return new string[0];
  try {if(count>128)return new string[0];var args=new string[count];for(int i=0;i<count;i++)args[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));return args;}
  finally {LocalFree(memory);}
 }
 public static Result Holders(string path) {
  var result=new Result();uint session;result.Code=RmStartSession(out session,0,new StringBuilder(33));
  if(result.Code!=0)return result;
  try {
   result.Code=RmRegisterResources(session,1,new[]{path},0,IntPtr.Zero,0,IntPtr.Zero);if(result.Code!=0)return result;
   uint count=32,needed,reasons=0;var apps=new ProcessInfo[32];
   result.Code=RmGetList(session,out needed,ref count,apps,ref reasons);
   result.OverLimit=needed>32||count>32;if(result.Code!=0||result.OverLimit)return result;
   result.Holders=new Holder[count];for(int i=0;i<count;i++)result.Holders[i]=new Holder{Id=apps[i].Process.Id,Started=((long)(uint)apps[i].Process.Started.dwHighDateTime<<32)|(uint)apps[i].Process.Started.dwLowDateTime};
   return result;
  } finally {RmEndSession(session);}
 }
}
'@
}
function Get-OpenWebLockError([Exception]$Failure){
 $errorObject=$Failure.GetBaseException();$code=$errorObject.HResult -band 65535
 $kind=if($code -eq 32){'sharing_violation'}elseif($code -eq 33){'lock_violation'}elseif($code -eq 2 -or $code -eq 3){'missing'}elseif($code -eq 5){'access_denied'}elseif($errorObject -is [IO.IOException]){'other_io'}else{'other_error'}
 return @{lock_probe_result=$kind;lock_probe_hresult=('{0:x8}' -f ($errorObject.HResult -band [long]4294967295))}
}
function Read-OpenWebLockProbe([string]$Path){
 $stream=$null
 try{
  if(!(Test-Path -LiteralPath $Path)){return @{lock_probe_result='missing'}}
  $item=Get-Item -LiteralPath $Path -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return @{lock_probe_result='not_ordinary'}}
  # Open, never OpenOrCreate: observing a missing lock must not create one.
  $stream=[IO.File]::Open($Path,'Open','ReadWrite','None')
  return @{lock_probe_result='available'}
 }catch{return Get-OpenWebLockError $_.Exception}
 finally{if($stream){$stream.Dispose()}}
}
function Get-OpenWebUpdaterGeneration($Previous){
 try{
  $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'"
  if(!$service){return @{observed=$false}}
  if($service.State -ceq 'Stopped' -and $service.ProcessId -eq 0 -and $Previous -and $Previous.stopped){return $Previous}
  $record=@{observed=$true;id=[long]$service.ProcessId;state=[string]$service.State;stopped=$false;started=0L;stopped_at=0L}
  if($record.id -gt 0){$record.started=(Get-Process -Id $record.id).StartTime.ToUniversalTime().ToFileTimeUtc()}
  return $record
 }catch{return @{observed=$false}}
}
function Read-OpenWebUpdaterGeneration([string]$PrivateDirectory){
 try{
  $item=Get-Item -LiteralPath (Join-Path $PrivateDirectory 'updater-generation-private.json') -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384){return $null}
  $row=Get-Content -LiteralPath $item.FullName -Raw|ConvertFrom-Json
  foreach($field in 'id','started','stopped_at'){if(($row.$field -isnot [int] -and $row.$field -isnot [long]) -or $row.$field -lt 0){return $null}}
  if($row.observed -isnot [bool] -or $row.stopped -isnot [bool] -or $row.id -gt [int]::MaxValue){return $null}
  return $row
 }catch{return $null}
}
function Get-OpenWebLockArguments([string]$Command){return [OpenWebQualificationLockObserver]::Arguments($Command)}
function Get-OpenWebLockHolders([string]$Path){Initialize-OpenWebLockObserverNative;return [OpenWebQualificationLockObserver]::Holders($Path)}
function Get-OpenWebLockProcessFacts($Process,[bool]$Verified,$Generation,[long]$Started,[string]$PrivateDirectory){
 $safe=@{kind='other';action='other';identity_verified=$Verified;parent_matches_stopped_updater=$false}
 if(!$Verified){return $safe}
 $exe=[string]$Process.ExecutablePath;$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 if($exe -ieq $powershell){$safe.kind='powershell'}
 elseif($exe -imatch '^C:\\OpenWebPBX\\updater\\slots\\[0-9]+\.[0-9]+\.[0-9]+\\OpenWebPbx\.Updater\.exe$'){$safe.kind='updater'}
 elseif($exe -ieq 'C:\OpenWebPBX\backup-runtime\python.exe'){$safe.kind='python'}
 elseif($exe -ieq 'C:\OpenWebPBX\php\php.exe'){$safe.kind='php'}
 elseif($exe -ieq 'C:\OpenWebPBX\server\OpenWebPbx.Server.exe'){$safe.kind='server'}
 if($safe.kind -ne 'other'){
  $tokens=@(Get-OpenWebLockArguments ([string]$Process.CommandLine))
  if($safe.kind -ceq 'powershell'){
   $fileIndex=-1;for($i=1;$i -lt $tokens.Count-1;$i++){if($tokens[$i] -ieq '-File'){$fileIndex=$i;break}}
   if($fileIndex -ge 0){
    $scriptPath=$tokens[$fileIndex+1];$parameters=@($tokens|Select-Object -Skip ($fileIndex+2))
    if($scriptPath -ieq 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1'){
     $safe.action=if($parameters -icontains '-Recover'){'recover'}elseif($parameters -icontains '-Check'){'check'}elseif($parameters -icontains '-Archive'){'signed_install'}else{'direct_reapply'}
    }elseif($scriptPath -ieq 'C:\OpenWebPBX\tools\Install-MailQueue.ps1' -and $parameters -icontains '-Tick'){$safe.action='mail_tick'}
    elseif($scriptPath -ieq 'C:\OpenWebPBX\tools\Renew-PhoneCertificate.ps1'){$safe.action='certificate_renewal'}
    elseif($scriptPath -ieq 'C:\OpenWebPBX\tools\Restart-Updater.ps1'){$safe.action='updater_restart'}
    elseif($scriptPath -ieq (Join-Path $PrivateDirectory 'direct-preflight-launcher.ps1')){$safe.action='qualification_preflight'}
   }
  }elseif($safe.kind -ceq 'python' -and $tokens -icontains 'C:\OpenWebPBX\tools\backups.py'){$safe.action='backup_control'}
 }
 if($Generation -and $Generation.observed -and $Generation.stopped -and $Generation.id -gt 0 -and $Generation.started -gt 0 -and $Generation.stopped_at -ge $Started -and $Started -ge $Generation.started -and [long]$Process.ParentProcessId -eq $Generation.id){$safe.parent_matches_stopped_updater=$true}
 return $safe
}
function Read-OpenWebLockJournal([string]$Path,[string[]]$States){
 if(!(Test-Path -LiteralPath $Path)){return 'absent'}
 try{$item=Get-Item -LiteralPath $Path -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 262144){return 'unreadable'};$row=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json;if($row.state -is [string] -and $row.state -cin $States){return $row.state};return 'other'}catch{return 'unreadable'}
}
function Get-OpenWebUpgradeLockObservation([string]$StateRoot,[string]$PrivateDirectory,$Generation){
 $safe=@{lock_observer_schema=1;lock_restart_manager='not_attempted';lock_updater_state='unknown';lock_updater_generation_captured=$false;lock_updater_stopped_generation=$false}
 $raw=@{generation=$Generation;holders=@()}
 try{
  if([IO.Path]::GetFullPath($StateRoot) -ine [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'Only the exact owned state root may be observed.'}
  $stateItem=Get-Item -LiteralPath $StateRoot -Force
  if(!$stateItem.PSIsContainer -or ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The exact ordinary owned state root is required.'}
  $directory=Get-Item -LiteralPath $PrivateDirectory -Force
  if(!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The existing private evidence directory is required.'}
  $path=Join-Path $StateRoot 'upgrade.lock';$probe=Read-OpenWebLockProbe $path
  foreach($entry in $probe.GetEnumerator()){$safe[$entry.Key]=$entry.Value}
  $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'"
  if($service.State -is [string] -and $service.State -cin 'Stopped','Running','Start Pending','Stop Pending','Paused','Continue Pending','Pause Pending'){$safe.lock_updater_state=$service.State}
  if($Generation -and $Generation.observed){$safe.lock_updater_generation_captured=$true;$safe.lock_updater_stopped_generation=[bool]$Generation.stopped}
  $safe.lock_install_journal_state=Read-OpenWebLockJournal (Join-Path $StateRoot 'updates\install-journal.json') @('prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required','completed','rolled_back')
  $safe.lock_worker_journal_state=Read-OpenWebLockJournal (Join-Path $StateRoot 'updates\worker-journal.json') @('checking','downloading','ready','waiting_calls','waiting_window','installing','completed','failed')
  $lockItem=Get-Item -LiteralPath $path -Force
  if($lockItem.PSIsContainer -or ($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $safe}
  $result=Get-OpenWebLockHolders $path
  $safe.lock_restart_manager=if($result.OverLimit -or @($result.Holders).Count -gt 32){'more_than_32'}elseif($result.Code -eq 0){'observed'}else{'failed'}
  if($safe.lock_restart_manager -ceq 'observed'){
   $safe.lock_holder_count=@($result.Holders).Count;$kinds=@();$actions=@();$verifiedCount=0;$relatedCount=0
   foreach($holder in $result.Holders){
    $process=$null;$verified=$false
    try{$process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$holder.Id);$verified=$null -ne $process -and (Get-Process -Id $holder.Id).StartTime.ToUniversalTime().ToFileTimeUtc() -eq $holder.Started}catch{}
    $facts=Get-OpenWebLockProcessFacts $process $verified $Generation $holder.Started $PrivateDirectory
    if($facts.identity_verified){$verifiedCount++};if($facts.parent_matches_stopped_updater){$relatedCount++}
    $kinds+=,$facts.kind;$actions+=,$facts.action
    $raw.holders+=,@{restart_manager=$holder;process=@{id=$process.ProcessId;parent=$process.ParentProcessId;executable=$process.ExecutablePath;command=$process.CommandLine;created=$process.CreationDate};facts=$facts}
   }
   $safe.lock_holder_identity_verified_count=$verifiedCount;$safe.lock_holder_updater_child_count=$relatedCount
   $safe.lock_holder_kinds=@('updater','powershell','python','php','server','other'|Where-Object {$_ -cin $kinds})
   $safe.lock_holder_actions=@('recover','check','signed_install','direct_reapply','mail_tick','certificate_renewal','updater_restart','qualification_preflight','backup_control','other'|Where-Object {$_ -cin $actions})
  }
 }catch{$safe.lock_observer_failed=$true;$raw.failure=$_|Out-String}
 finally{
  try{if($directory -and $directory.PSIsContainer -and !($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.File]::WriteAllText((Join-Path $PrivateDirectory ('lock-observer-'+[Guid]::NewGuid().ToString('N')+'-private.json')),($raw|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}}catch{}
 }
 return $safe
}
function SafeOpenWebUpgradeLockFields($Record){
 $safe=@{}
 if(($Record.lock_observer_schema -isnot [int] -and $Record.lock_observer_schema -isnot [long]) -or $Record.lock_observer_schema -ne 1){return $safe}
 $safe.lock_observer_schema=1
 $enums=@{lock_probe_result=@('available','sharing_violation','lock_violation','missing','access_denied','other_io','other_error','not_ordinary');lock_restart_manager=@('not_attempted','observed','more_than_32','failed');lock_updater_state=@('unknown','Stopped','Running','Start Pending','Stop Pending','Paused','Continue Pending','Pause Pending');lock_install_journal_state=@('absent','unreadable','other','prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required','completed','rolled_back');lock_worker_journal_state=@('absent','unreadable','other','checking','downloading','ready','waiting_calls','waiting_window','installing','completed','failed')}
 foreach($field in $enums.Keys){if($Record.$field -is [string] -and $Record.$field -cin $enums[$field]){$safe[$field]=$Record.$field}}
 if($Record.lock_probe_hresult -is [string] -and $Record.lock_probe_hresult -cmatch '^[0-9a-f]{8}$'){$safe.lock_probe_hresult=$Record.lock_probe_hresult}
 foreach($field in 'lock_updater_generation_captured','lock_updater_stopped_generation','lock_observer_failed'){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 foreach($field in 'lock_holder_count','lock_holder_identity_verified_count','lock_holder_updater_child_count'){if(($Record.$field -is [int] -or $Record.$field -is [long]) -and $Record.$field -ge 0 -and $Record.$field -le 32){$safe[$field]=[int]$Record.$field}}
 $arrays=@{lock_holder_kinds=@('updater','powershell','python','php','server','other');lock_holder_actions=@('recover','check','signed_install','direct_reapply','mail_tick','certificate_renewal','updater_restart','qualification_preflight','backup_control','other')}
 foreach($field in $arrays.Keys){$safe[$field]=@(foreach($value in $arrays[$field]){foreach($item in @($Record.$field)){if($item -is [string] -and $item -ceq $value){$value;break}}})}
 return $safe
}
