# QA-only; no production services, backup files, ACL changes or arbitrary commands.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('register','start-wait','cleanup')][string]$Operation,
      [Parameter(Mandatory)][string]$Request)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
function Refuse-OwnedProbe([string]$Code){$e=[InvalidOperationException]::new('Owned LocalService qualification task refused.');$e.Data['OpenWebProbeReason']=$Code;throw $e}
function Require-OwnedProbe([bool]$Value,[string]$Code){if(!$Value){Refuse-OwnedProbe $Code}}
function Hash-OwnedProbeText([string]$Text){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Assert-OwnedProbeOrdinary([string]$Path){
 $current=[IO.Path]::GetFullPath($Path)
 while($current){$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop;Require-OwnedProbe (-not($item.Attributes-band[IO.FileAttributes]::ReparsePoint)) 'path_refused';$current=Split-Path -Parent $current}
}
function Expected-OwnedProbe($Value){
 Require-OwnedProbe ($Value.schema-is [int]-or$Value.schema-is [long]) 'request_refused'
 Require-OwnedProbe ($Value.schema-eq 1-and$Value.task_name-is [string]-and$Value.task_name-cmatch '^OpenWebPBX-Backup-LocalService-[a-f0-9]{32}$'-and$Value.nonce-is [string]-and$Value.nonce-cmatch '^[a-f0-9]{32}$') 'request_refused'
 Require-OwnedProbe ($Value.root-is [string]-and$Value.script_sha256-is [string]-and$Value.script_sha256-cmatch '^[a-f0-9]{64}$') 'request_refused'
 $root=[IO.Path]::GetFullPath($Value.root);$normal=Join-Path $env:ProgramData 'OpenWebPBX\backup-qualification';$temporary=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
 $preflight=$root.StartsWith($temporary+'\',[StringComparison]::OrdinalIgnoreCase)-and(Split-Path $root -Leaf)-cmatch '^OpenWebPBX-BackupPublication-[a-f0-9]{32}$'-and(Split-Path $root -Parent).Equals($temporary,[StringComparison]::OrdinalIgnoreCase)
 Require-OwnedProbe ($root.Equals([IO.Path]::GetFullPath($normal),[StringComparison]::OrdinalIgnoreCase)-or$preflight) 'path_refused'
 $scriptFile=Join-Path $root 'localservice\read.ps1';Assert-OwnedProbeOrdinary $scriptFile
 Require-OwnedProbe ((Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash.ToLowerInvariant()-ceq $Value.script_sha256) 'script_changed'
 return [pscustomobject]@{Name=$Value.task_name;Path='\';Nonce=$Value.nonce;Script=$scriptFile;Execute=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -NonInteractive -File "'+$scriptFile+'"');Description=('OpenWebPBX-LocalService-Owner:'+ $Value.nonce);ScriptSha256=$Value.script_sha256}
}
function Resolve-OwnedProbeSid([string]$Value){
 if($Value-match '^S-[0-9-]+$'){return ([Security.Principal.SecurityIdentifier]::new($Value)).Value}
 return ([Security.Principal.NTAccount]::new($Value)).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Assert-OwnedProbeModel($Task,$Expected){
 Require-OwnedProbe ($Task.TaskName-ceq $Expected.Name-and$Task.TaskPath-ceq '\'-and$Task.Description-ceq $Expected.Description-and@($Task.Actions).Count-eq 1) 'identity_changed'
 $execute=[IO.Path]::GetFullPath([string]$Task.Actions[0].Execute)
 Require-OwnedProbe ($execute.Equals([IO.Path]::GetFullPath($Expected.Execute),[StringComparison]::OrdinalIgnoreCase)-and$Task.Actions[0].Arguments-ceq $Expected.Arguments) 'identity_changed'
 Require-OwnedProbe ([string]$Task.Principal.LogonType-ceq 'ServiceAccount'-and[string]$Task.Principal.RunLevel-ceq 'Limited'-and(Resolve-OwnedProbeSid ([string]$Task.Principal.UserId))-ceq 'S-1-5-19') 'identity_changed'
}
function Read-OwnedProbeTask($Expected){
 $tasks=@(Get-ScheduledTask -TaskPath '\' -TaskName $Expected.Name -ErrorAction Stop)
 Require-OwnedProbe ($tasks.Count-eq 1) 'identity_changed';$task=$tasks[0];Assert-OwnedProbeModel $task $Expected
 $xml=Export-ScheduledTask -TaskPath '\' -TaskName $Expected.Name -ErrorAction Stop
 Require-OwnedProbe ($xml-is [string]-and$xml.Length-gt 0-and$xml.Length-le 65536) 'identity_changed'
 return [pscustomobject]@{Task=$task;DefinitionSha256=(Hash-OwnedProbeText $xml)}
}
function Assert-OwnedProbeReceipt($Receipt,$Expected){
 Require-OwnedProbe ($Receipt-is [pscustomobject]) 'receipt_refused'
 $keys=@('schema','created','task_name','task_path','nonce','definition_sha256','script_sha256');$actual=@($Receipt.PSObject.Properties.Name)
 Require-OwnedProbe ($actual.Count-eq$keys.Count-and@($actual|Where-Object{$_-cnotin$keys}).Count-eq 0) 'receipt_refused'
 Require-OwnedProbe (($Receipt.schema-is [int]-or$Receipt.schema-is [long])-and$Receipt.schema-eq 1-and$Receipt.created-is [bool]-and$Receipt.created-and$Receipt.task_name-ceq $Expected.Name-and$Receipt.task_path-ceq '\'-and$Receipt.nonce-ceq $Expected.Nonce-and$Receipt.script_sha256-ceq $Expected.ScriptSha256-and$Receipt.definition_sha256-is [string]-and$Receipt.definition_sha256-cmatch '^[a-f0-9]{64}$') 'receipt_refused'
}
function Read-RegisteredOwnedProbe($Receipt,$Expected){
 Assert-OwnedProbeReceipt $Receipt $Expected;$observed=Read-OwnedProbeTask $Expected
 Require-OwnedProbe ($observed.DefinitionSha256-ceq $Receipt.definition_sha256) 'identity_changed'
 return $observed
}
function Wait-OwnedProbeCompletion($Value,$Expected,[long]$Baseline,[Diagnostics.Stopwatch]$Watch){
 Require-OwnedProbe ($Watch.IsRunning) 'request_refused'
   while($watch.Elapsed.TotalSeconds-lt 30){
    # Fresh run info precedes completed-state observation; final info follows it.
    $info=Get-ScheduledTaskInfo -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop
    $observed=Read-RegisteredOwnedProbe $Value.receipt $Expected
    if($info.LastRunTime.ToUniversalTime().Ticks-gt$Baseline-and[string]$observed.Task.State-ceq 'Ready'){
     $final=Get-ScheduledTaskInfo -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop
     Require-OwnedProbe ($final.LastRunTime.ToUniversalTime().Ticks-gt$Baseline) 'completion_refused'
     Require-OwnedProbe ([uint32]$final.LastTaskResult-eq 0) 'task_failed'
     Require-OwnedProbe ($Watch.Elapsed.TotalSeconds-lt 30) 'deadline'
     return [pscustomobject]@{schema=1;state='completed';last_run_advanced=$true;last_task_result=0}
    }
    Require-OwnedProbe ([string]$observed.Task.State-cnotin @('Disabled','Unknown')) 'state_refused'
    Start-Sleep -Milliseconds 200
   }
   Refuse-OwnedProbe 'deadline'
}
function Find-OwnedProbeTasks([string]$Name){
 $all=@(Get-ScheduledTask -ErrorAction Stop)
 Require-OwnedProbe ($all.Count-le 4096) 'identity_changed'
 return @($all|Where-Object{$_.TaskPath-ceq '\'-and$_.TaskName-ceq$Name})
}
function Invoke-OwnedProbeOperation([string]$Action,$Value){
 $expected=Expected-OwnedProbe $Value
 switch($Action){
  'register'{
   Require-OwnedProbe ($null-eq$Value.receipt) 'receipt_refused'
   Require-OwnedProbe (@(Find-OwnedProbeTasks $expected.Name).Count-eq 0) 'collision'
   $a=New-ScheduledTaskAction -Execute $expected.Execute -Argument $expected.Arguments
   $p=New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Limited
   # No Force: a competing existing task must never be replaced.
   $created=Register-ScheduledTask -TaskPath '\' -TaskName $expected.Name -Action $a -Principal $p -Description $expected.Description -ErrorAction Stop
   Assert-OwnedProbeModel $created $expected;$observed=Read-OwnedProbeTask $expected
   Require-OwnedProbe ([string]$observed.Task.State-ceq 'Ready') 'state_refused'
   return [pscustomobject]@{schema=1;created=$true;task_name=$expected.Name;task_path='\';nonce=$expected.Nonce;definition_sha256=$observed.DefinitionSha256;script_sha256=$expected.ScriptSha256}
  }
  'start-wait'{
   $observed=Read-RegisteredOwnedProbe $Value.receipt $expected
   Require-OwnedProbe ([string]$observed.Task.State-ceq 'Ready') 'state_refused'
   $before=Get-ScheduledTaskInfo -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop;$baseline=$before.LastRunTime.ToUniversalTime().Ticks
   Start-ScheduledTask -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop
   return Wait-OwnedProbeCompletion $Value $expected $baseline ([Diagnostics.Stopwatch]::StartNew())
  }
  'cleanup'{
   $observed=Read-RegisteredOwnedProbe $Value.receipt $expected
   Require-OwnedProbe ([string]$observed.Task.State-ceq 'Ready') 'cleanup_refused'
   # Same owned happy-path unregister, now preceded by exact receipt/definition guards.
   Unregister-ScheduledTask -TaskPath '\' -TaskName $expected.Name -Confirm:$false -ErrorAction SilentlyContinue
   Require-OwnedProbe (@(Find-OwnedProbeTasks $expected.Name).Count-eq 0) 'cleanup_refused'
   return [pscustomobject]@{schema=1;state='removed';owned_registration_removed=$true}
  }
  default{Refuse-OwnedProbe 'request_refused'}
 }
}
try{
 Require-OwnedProbe ($PSVersionTable.PSEdition-ceq 'Desktop'-and$PSVersionTable.PSVersion.Major-eq 5-and[IntPtr]::Size-eq 8) 'scope_refused'
 # Exact existing product expression; changes only this native child environment.
 $env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
 Require-OwnedProbe ($env:GITHUB_ACTIONS-ceq 'true'-and$env:RUNNER_ENVIRONMENT-ceq 'github-hosted'-and$env:GITHUB_REPOSITORY-ceq 'embire2/openwebpbx'-and$env:OPENWEB_WINDOWS_BACKUP_TEST-ceq '1') 'scope_refused'
 $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent();Require-OwnedProbe ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'scope_refused'
 Assert-OwnedProbeOrdinary $Request;$inputItem=Get-Item -LiteralPath $Request -Force;Require-OwnedProbe (-not$inputItem.PSIsContainer-and$inputItem.Length-gt 0-and$inputItem.Length-le 16384) 'request_refused'
 $value=Get-Content -LiteralPath $Request -Raw -Encoding UTF8|ConvertFrom-Json
 $keys=@('schema','task_name','nonce','root','script_sha256','receipt');$actual=@($value.PSObject.Properties.Name)
 Require-OwnedProbe ($actual.Count-eq$keys.Count-and@($actual|Where-Object{$_-cnotin$keys}).Count-eq 0) 'request_refused'
 $expectedRequestRoot=[IO.Path]::GetFullPath([string]$value.root)
 Require-OwnedProbe ((Split-Path ([IO.Path]::GetFullPath($Request)) -Parent).Equals($expectedRequestRoot,[StringComparison]::OrdinalIgnoreCase)) 'path_refused'
 Invoke-OwnedProbeOperation $Operation $value|ConvertTo-Json -Depth 6 -Compress
}catch{
 $known=@('scope_refused','request_refused','path_refused','script_changed','identity_changed','receipt_refused','collision','state_refused','completion_refused','task_failed','deadline','cleanup_refused')
 $code=$_.Exception.Data['OpenWebProbeReason'];if($code-isnot[string]-or$code-cnotin$known){$code='unclassified'}
 [Console]::Out.WriteLine((@{schema=1;state='refused';operation=$Operation;reason=$code}|ConvertTo-Json -Compress))
 [Console]::Error.WriteLine('Owned LocalService qualification task control refused.')
 exit 1
}
