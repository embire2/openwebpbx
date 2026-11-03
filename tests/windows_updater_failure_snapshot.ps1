# QA-only bounded failure snapshot. Never changes product state or acceptance.
function Seal-WindowsUpdaterFailureSnapshot([byte[]]$Raw,[string]$SourceCommit,[string]$RunId,[string]$PublicPem){
 if($PSVersionTable.PSEdition -cne 'Core' -or $Raw.Length -lt 2 -or $Raw.Length -gt 1048576 -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $RunId -cnotmatch '^[1-9][0-9]{0,19}$' -or !$PublicPem.StartsWith('-----BEGIN PUBLIC KEY-----') -or $PublicPem.Contains('PRIVATE KEY')){throw 'The exact updater ACL diagnostic binding is required.'}
 $sha=[Security.Cryptography.SHA256]::Create();try{$plainHash=([BitConverter]::ToString($sha.ComputeHash($Raw))).Replace('-','').ToLowerInvariant();$publicHash=([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($PublicPem)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($publicHash -cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){throw 'Only the Root-owned diagnostic public recipient is permitted.'}
 $binding=[ordered]@{schema=1;purpose='windows-updater-failure-snapshot';source_commit=$SourceCommit;run_id=$RunId;stage='failure_before_cleanup';plaintext_bytes=$Raw.Length;plaintext_sha256=$plainHash}
 $aad=[Text.UTF8Encoding]::new($false).GetBytes(($binding|ConvertTo-Json -Depth 4 -Compress));$rsa=[Security.Cryptography.RSA]::Create();$key=$null;$aes=$null
 try{
  $rsa.ImportFromPem($PublicPem);if($rsa.KeySize -ne 3072){throw 'The catalogue diagnostic requires RSA3072.'}
  $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($Raw.Length);$aes=[Security.Cryptography.AesGcm]::new($key,16);$aes.Encrypt($nonce,$Raw,$cipher,$tag,$aad)
  return [ordered]@{schema=1;algorithm='RSA3072-OAEP-SHA256+A256GCM';public_key_sha256=$publicHash;aad=[Convert]::ToBase64String($aad);wrapped_key=[Convert]::ToBase64String($rsa.Encrypt($key,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256));nonce=[Convert]::ToBase64String($nonce);tag=[Convert]::ToBase64String($tag);ciphertext=[Convert]::ToBase64String($cipher)}
 }finally{if($aes){$aes.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)};$rsa.Dispose()}
}
function Test-WindowsUpdaterFailureSnapshotKeys($Value,[string[]]$Expected){
 if($Value-is [Collections.IDictionary]){$keys=@($Value.Keys)}elseif($Value-is [pscustomobject]){$keys=@($Value.PSObject.Properties.Name)}else{return $false}
 return $keys.Count-eq $Expected.Count-and @($keys|Where-Object {$_-isnot [string]-or $_-cnotin $Expected}).Count-eq 0
}
function Read-WindowsUpdaterFailureSnapshot($Record){
 try{
  if((Test-WindowsUpdaterFailureSnapshotKeys $Record @('schema','state','reason'))-and ($Record.schema-is [int]-or $Record.schema-is [long])-and $Record.schema-eq 1-and $Record.state-is [string]-and $Record.state-ceq 'unavailable'-and $Record.reason-is [string]-and $Record.reason-cin 'context_guard','work_root','private_evidence','capture','encryption','closed_output'){return @{schema=1;state='unavailable';reason=$Record.reason}}
  if(!(Test-WindowsUpdaterFailureSnapshotKeys $Record @('schema','state','encrypted'))-or ($Record.schema-isnot [int]-and $Record.schema-isnot [long])-or $Record.schema-ne 1-or $Record.state-isnot [string]-or $Record.state-cne 'captured'){return $null}
  $e=$Record.encrypted
  if(!(Test-WindowsUpdaterFailureSnapshotKeys $e @('schema','algorithm','public_key_sha256','aad','wrapped_key','nonce','tag','ciphertext'))-or ($e.schema-isnot [int]-and $e.schema-isnot [long])-or $e.schema-ne 1-or $e.algorithm-isnot [string]-or $e.algorithm-cne 'RSA3072-OAEP-SHA256+A256GCM'-or $e.public_key_sha256-isnot [string]-or $e.public_key_sha256-cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){return $null}
  $decoded=@{}
  foreach($name in 'aad','wrapped_key','nonce','tag','ciphertext'){
   if($e.$name-isnot [string]-or $e.$name.Length-gt 1398200){return $null}
   $bytes=[Convert]::FromBase64String($e.$name);if([Convert]::ToBase64String($bytes)-cne $e.$name){return $null};$decoded[$name]=$bytes
  }
  if($decoded.aad.Length-gt 2048-or $decoded.wrapped_key.Length-ne 384-or $decoded.nonce.Length-ne 12-or $decoded.tag.Length-ne 16-or $decoded.ciphertext.Length-lt 2-or $decoded.ciphertext.Length-gt 1048576){return $null}
  $a=[Text.UTF8Encoding]::new($false,$true).GetString($decoded.aad)|ConvertFrom-Json -AsHashtable -NoEnumerate
  if(!(Test-WindowsUpdaterFailureSnapshotKeys $a @('schema','purpose','source_commit','run_id','stage','plaintext_bytes','plaintext_sha256'))-or ($a.schema-isnot [int]-and $a.schema-isnot [long])-or $a.schema-ne 1-or $a.purpose-isnot [string]-or $a.purpose-cne 'windows-updater-failure-snapshot'-or $a.stage-isnot [string]-or $a.stage-cne 'failure_before_cleanup'-or $a.source_commit-isnot [string]-or $a.source_commit-cne $env:GITHUB_SHA-or $a.source_commit-cnotmatch '^[a-f0-9]{40}$'-or $a.run_id-isnot [string]-or $a.run_id-cne $env:GITHUB_RUN_ID-or $a.run_id-cnotmatch '^[1-9][0-9]{0,19}$'-or ($a.plaintext_bytes-isnot [int]-and $a.plaintext_bytes-isnot [long])-or $a.plaintext_bytes-ne $decoded.ciphertext.Length-or $a.plaintext_sha256-isnot [string]-or $a.plaintext_sha256-cnotmatch '^[a-f0-9]{64}$'){return $null}
  return @{schema=1;state='captured';encrypted=$e}
 }catch{return $null}
}
function Assert-WindowsUpdaterFailureSnapshotBudget([Diagnostics.Stopwatch]$Clock,[DateTimeOffset]$JobDeadline){
 if($Clock.Elapsed.TotalSeconds-ge 30-or [DateTimeOffset]::UtcNow-ge $JobDeadline){throw 'The original failure observation budget expired.'}
}
function Assert-WindowsUpdaterFailureSnapshotOrdinary([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 for($node=$item;$null-ne $node;$node=if($node.PSIsContainer){$node.Parent}else{$node.Directory}){
  if($node.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Failure observation refuses linked paths.'}
 }
 return $item
}
function Read-WindowsUpdaterFailureSnapshotFile([string]$Path,[string]$Label,[int]$Maximum,[bool]$Tail,[Diagnostics.Stopwatch]$Clock,[DateTimeOffset]$JobDeadline){
 Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
 $record=[ordered]@{label=$Label;state='missing'}
 try{
  $item=Assert-WindowsUpdaterFailureSnapshotOrdinary $Path
  if($item.PSIsContainer){throw 'Only an ordinary file may be observed.'}
  $record.name=$item.Name;$record.last_write_utc=$item.LastWriteTimeUtc.ToString('o')
  $share=[IO.FileShare]::ReadWrite-bor [IO.FileShare]::Delete
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
  try{
   $length=$stream.Length;$record.observed_length=$length
   if(!$Tail-and $length-gt $Maximum){$record.state='oversize';return $record}
   $offset=if($Tail){[Math]::Max(0,$length-$Maximum)}else{0L};$null=$stream.Seek($offset,[IO.SeekOrigin]::Begin)
   $wanted=[int][Math]::Min($Maximum,$length-$offset);$bytes=[byte[]]::new($wanted);$read=0
   while($read-lt $wanted){Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline;$n=$stream.Read($bytes,$read,$wanted-$read);if(!$n){break};$read+=$n}
   Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
   $after=Assert-WindowsUpdaterFailureSnapshotOrdinary $Path
   if($after.PSIsContainer){throw 'The observed file changed type.'}
   if(!$Tail-and $stream.Length-gt $Maximum){$record.state='oversize';return $record}
   if($read-ne $wanted){$short=[byte[]]::new($read);[Array]::Copy($bytes,$short,$read);$bytes=$short}
   $record.state='observed';$record.tail=[bool]$Tail;$record.offset=$offset;$record.bytes=$bytes.Length
   $record.sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();$record.content_base64=[Convert]::ToBase64String($bytes)
  }finally{$stream.Dispose()}
 }catch [Management.Automation.ItemNotFoundException]{$record.state='missing'}
 catch{$record.state='unavailable';$record.exception_type=$_.Exception.GetType().Name;$record.hresult=[int]$_.Exception.HResult}
 Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
 return $record
}
function Limit-WindowsUpdaterFailureSnapshotText($Value,[int]$Maximum=256){
 $text=[string]$Value;return @{value=$text.Substring(0,[Math]::Min($Maximum,$text.Length));truncated=($text.Length-gt $Maximum)}
}
function Get-WindowsUpdaterFailureSnapshotPrimaryFailure($PrimaryFailure){
 if($null-eq $PrimaryFailure){return @{state='unavailable';reason='not_supplied'}}
 if($PrimaryFailure-isnot [Management.Automation.ErrorRecord]){return @{state='unavailable';reason='unsupported_type'}}
 try{
  # Read only known ErrorRecord/Exception properties, never arbitrary ToString().
  $chain=@();$exception=$PrimaryFailure.Exception
  for($index=0;$index-lt 4-and $null-ne $exception;$index++){
   if($exception-isnot [Exception]){throw 'Only a native exception chain is observable.'}
   $chain+=@{type=(Limit-WindowsUpdaterFailureSnapshotText $exception.GetType().FullName 128);message=(Limit-WindowsUpdaterFailureSnapshotText $exception.Message 768);hresult=[int]$exception.HResult}
   $exception=$exception.InnerException
  }
  $invocation=$PrimaryFailure.InvocationInfo
  $record=@{state='observed';exceptions=$chain;inner_chain_truncated=($null-ne $exception);source=@{value='';truncated=$false};line=$null;script_stack_trace=@{value='';truncated=$false}}
  if($invocation-and $invocation.ScriptName-is [string]){$record.source=Limit-WindowsUpdaterFailureSnapshotText $invocation.ScriptName 512;$record.line=[int]$invocation.ScriptLineNumber}
  if($PrimaryFailure.ScriptStackTrace-is [string]){$record.script_stack_trace=Limit-WindowsUpdaterFailureSnapshotText $PrimaryFailure.ScriptStackTrace 1024}
  $length=[Text.UTF8Encoding]::new($false,$true).GetByteCount(($record|ConvertTo-Json -Depth 7 -Compress))
  if($length-gt 32768){throw 'The encrypted primary failure exceeds its fixed bound.'}
  return $record
 }catch{return @{state='unavailable';reason='unsupported_shape'}}
}
function Get-WindowsUpdaterFailureSnapshotTasks([Diagnostics.Stopwatch]$Clock,[DateTimeOffset]$JobDeadline){
 $records=[ordered]@{}
 foreach($name in 'OpenWebPBX-TenantDomains','OpenWebPBX-Backups'){
  Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
  try{
   $task=@(Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop)
   if($task.Count-ne 1-or $task[0].TaskName-cne $name-or $task[0].TaskPath-cne '\'){throw 'One exact named task is required for observation.'};$task=$task[0]
   $info=Get-ScheduledTaskInfo -TaskName $name -TaskPath '\' -ErrorAction Stop
   Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
   $actions=@($task.Actions);$triggers=@($task.Triggers)
   $row=[ordered]@{state='observed';task_state=[string]$task.State;enabled=[bool]$task.Settings.Enabled;action_count=$actions.Count;trigger_count=$triggers.Count;actions=@();triggers=@();last_task_result=$info.LastTaskResult}
   foreach($pair in @(@('last_run',$info.LastRunTime),@('next_run',$info.NextRunTime))){
    $value=$pair[1];$row[$pair[0]]=if($value-is [DateTime]){@{text=$value.ToString('o');kind=[string]$value.Kind;utc=$value.ToUniversalTime().ToString('o')}}else{@{unavailable=$true}}
   }
   $row.principal=@{user=(Limit-WindowsUpdaterFailureSnapshotText $task.Principal.UserId);logon_type=[string]$task.Principal.LogonType;run_level=[string]$task.Principal.RunLevel}
   foreach($action in @($actions|Select-Object -First 4)){$row.actions+=@{execute=(Limit-WindowsUpdaterFailureSnapshotText $action.Execute 2048);arguments=(Limit-WindowsUpdaterFailureSnapshotText $action.Arguments 2048);working_directory=(Limit-WindowsUpdaterFailureSnapshotText $action.WorkingDirectory 2048)}}
   foreach($trigger in @($triggers|Select-Object -First 4)){
    $row.triggers+=@{type=(Limit-WindowsUpdaterFailureSnapshotText $trigger.CimClass.CimClassName);enabled=[bool]$trigger.Enabled;start=(Limit-WindowsUpdaterFailureSnapshotText $trigger.StartBoundary);end=(Limit-WindowsUpdaterFailureSnapshotText $trigger.EndBoundary);interval=(Limit-WindowsUpdaterFailureSnapshotText $trigger.Repetition.Interval);duration=(Limit-WindowsUpdaterFailureSnapshotText $trigger.Repetition.Duration);stop_at_duration_end=[bool]$trigger.Repetition.StopAtDurationEnd}
   }
   $records[$name]=$row
  }catch{$records[$name]=@{state='unavailable';exception_type=$_.Exception.GetType().Name;hresult=[int]$_.Exception.HResult}}
  Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
 }
 return $records
}
function Get-WindowsUpdaterFailureSnapshotServices([Diagnostics.Stopwatch]$Clock,[DateTimeOffset]$JobDeadline){
 $records=[ordered]@{}
 foreach($name in 'OpenWebPBX','FreeSWITCH','OpenWebPBX-Database','OpenWebPBXUpdater'){
  Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
  try{
   $service=@(Get-Service -Name $name -ErrorAction Stop)
   if($service.Count-ne 1-or $service[0].Name-cne $name){throw 'One exact named service is required for observation.'}
   $row=@{state='observed';status=[string]$service[0].Status;start_type=[string]$service[0].StartType}
   try{
    $native=@(Get-CimInstance -ClassName Win32_Service -Filter ("Name='"+$name+"'") -OperationTimeoutSec 2 -ErrorAction Stop)
    Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
    if($native.Count-ne 1-or $native[0].Name-cne $name){throw 'One exact named native service is required.'}
    $row.native=@{state='observed';path_name=(Limit-WindowsUpdaterFailureSnapshotText $native[0].PathName 2048);start_name=(Limit-WindowsUpdaterFailureSnapshotText $native[0].StartName 256);start_mode=(Limit-WindowsUpdaterFailureSnapshotText $native[0].StartMode 64);process_id=[uint32]$native[0].ProcessId}
   }catch{$row.native=@{state='unavailable';exception_type=$_.Exception.GetType().Name;hresult=[int]$_.Exception.HResult}}
   $records[$name]=$row
  }catch{$records[$name]=@{state='unavailable';exception_type=$_.Exception.GetType().Name;hresult=[int]$_.Exception.HResult}}
  Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
 }
 return $records
}
function Get-WindowsUpdaterFailureSnapshotPayload([string]$StateRoot,[string]$WorkRoot,[Diagnostics.Stopwatch]$Clock,[DateTimeOffset]$JobDeadline,$PrimaryFailure=$null){
 $rows=[Collections.Generic.List[object]]::new()
 foreach($pair in @(@('status.json','updater_status'),@('worker-journal.json','worker_journal'),@('install-journal.json','install_journal'))){
  $rows.Add((Read-WindowsUpdaterFailureSnapshotFile (Join-Path $StateRoot ('updates/'+$pair[0])) $pair[1] 65536 $false $Clock $JobDeadline))
 }
 $logs=Join-Path $StateRoot 'updates/logs';$logState='missing'
 try{
  $directory=Assert-WindowsUpdaterFailureSnapshotOrdinary $logs;if(!$directory.PSIsContainer){throw 'The installer log root must be ordinary.'}
  $items=@(Get-ChildItem -LiteralPath $logs -Force -ErrorAction Stop|Select-Object -First 257)
  if($items.Count-gt 256){$logState='oversize'}else{
   $selected=@($items|Where-Object {!$_.PSIsContainer-and $_.Name-cmatch '^install-[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.log$'}|Sort-Object -Property @{Expression='LastWriteTimeUtc';Descending=$true},@{Expression='Name';Descending=$true}|Select-Object -First 3)
   $logState='observed';$index=0
   foreach($item in $selected){$rows.Add((Read-WindowsUpdaterFailureSnapshotFile $item.FullName ('installer_log_'+$index++) 98304 $true $Clock $JobDeadline))}
  }
 }catch [Management.Automation.ItemNotFoundException]{$logState='missing'}catch{$logState='unavailable'}
 foreach($pair in @(@('operator-rollback-native.out','operator_stdout'),@('operator-rollback-native.err','operator_stderr'),@('status-private.err','fixture_status_stderr'))){
  $rows.Add((Read-WindowsUpdaterFailureSnapshotFile (Join-Path $WorkRoot $pair[0]) $pair[1] 65536 $true $Clock $JobDeadline))
 }
 # Reuse the existing last Fixture status output; never issue another DB query.
 $rows.Add((Read-WindowsUpdaterFailureSnapshotFile (Join-Path $WorkRoot 'status-private.out') 'fixture_status_stdout' 32768 $true $Clock $JobDeadline))
 Assert-WindowsUpdaterFailureSnapshotBudget $Clock $JobDeadline
 $tasks=Get-WindowsUpdaterFailureSnapshotTasks $Clock $JobDeadline;$services=Get-WindowsUpdaterFailureSnapshotServices $Clock $JobDeadline
 $payload=[ordered]@{schema=1;purpose='windows-updater-failure-snapshot';source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;stage='failure_before_cleanup';captured_at_utc=[DateTimeOffset]::UtcNow.ToString('o');non_atomic_readonly_observations=$true;context=@{state_root=$StateRoot;work_root=$WorkRoot;original_job_deadline_utc=$JobDeadline.ToUniversalTime().ToString('o');maximum_body_seconds=30};primary_failure=(Get-WindowsUpdaterFailureSnapshotPrimaryFailure $PrimaryFailure);log_directory_state=$logState;files=$rows.ToArray();tasks=$tasks;services=$services}
 $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-Json -InputObject $payload -Depth 8 -Compress))
 if($bytes.Length-gt 1048576){throw 'The failure observation exceeds its plaintext bound.'}
 return ,$bytes
}
function Get-WindowsUpdaterFailureSnapshot([string]$StateRoot,[string]$WorkRoot,[DateTimeOffset]$JobDeadline,$PrimaryFailure=$null){
 $clock=[Diagnostics.Stopwatch]::StartNew();$raw=$null;$failureStage='context_guard'
 try{
  if($PSVersionTable.PSEdition-cne 'Core'-or $env:GITHUB_ACTIONS-cne 'true'-or $env:RUNNER_ENVIRONMENT-cne 'github-hosted'-or $env:RUNNER_OS-cne 'Windows'-or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'-or $env:GITHUB_SHA-cnotmatch '^[a-f0-9]{40}$'-or $env:GITHUB_RUN_ID-cnotmatch '^[1-9][0-9]{0,19}$'-or $StateRoot-cne 'C:\ProgramData\OpenWebPBX'-or [DateTimeOffset]::UtcNow.AddSeconds(30)-ge $JobDeadline){throw 'The exact current disposable failure and original budget are required.'}
  $failureStage='work_root';$work=[IO.Path]::GetFullPath($WorkRoot);$parent=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([char[]]@('\','/'))
  if(![string]::Equals([IO.Path]::GetDirectoryName($work),$parent,[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFileName($work)-cnotmatch '^openwebpbx-updater-[a-f0-9]{32}$'){throw 'Only the current private qualification work root is permitted.'}
  $item=Assert-WindowsUpdaterFailureSnapshotOrdinary $work;if(!$item.PSIsContainer){throw 'An ordinary private work root is required.'}
  $failureStage='private_evidence';$evidence=Join-Path $work ('failure-snapshot-'+[Guid]::NewGuid().ToString('N'))
  $null=New-Item -ItemType Directory -Path $evidence -ErrorAction Stop
  $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
  foreach($sid in 'S-1-5-32-544','S-1-5-18'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
  Set-Acl -LiteralPath $evidence -AclObject $acl -ErrorAction Stop
  $actual=Get-Acl -LiteralPath $evidence -ErrorAction Stop
  if(!$actual.AreAccessRulesProtected-or $actual.Access.Count-ne 2-or $actual.Owner-ne $acl.Owner){throw 'Private evidence permissions did not apply.'}
  foreach($rule in $actual.Access){if($rule.AccessControlType-ne 'Allow'-or $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value-cnotin 'S-1-5-32-544','S-1-5-18'-or $rule.FileSystemRights-ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'Unexpected private evidence access.'}}
  $failureStage='capture';$raw=Get-WindowsUpdaterFailureSnapshotPayload $StateRoot $work $clock $JobDeadline $PrimaryFailure
  $file=[IO.File]::Open((Join-Path $evidence 'failure-snapshot.private.json'),'CreateNew','Write','None');try{$file.Write($raw,0,$raw.Length);$file.Flush($true)}finally{$file.Dispose()}
  Assert-WindowsUpdaterFailureSnapshotBudget $clock $JobDeadline
  $failureStage='encryption';$publicPath=Join-Path $PSScriptRoot 'windows_updater_file_acl_public.pem';$item=Assert-WindowsUpdaterFailureSnapshotOrdinary $publicPath
  if($item.PSIsContainer-or $item.Length-gt 16384){throw 'The exact diagnostic public recipient is required.'}
  $public=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($publicPath))
  $encrypted=Seal-WindowsUpdaterFailureSnapshot $raw $env:GITHUB_SHA $env:GITHUB_RUN_ID $public
  Assert-WindowsUpdaterFailureSnapshotBudget $clock $JobDeadline
  $failureStage='closed_output';$safe=Read-WindowsUpdaterFailureSnapshot @{schema=1;state='captured';encrypted=$encrypted}
  Assert-WindowsUpdaterFailureSnapshotBudget $clock $JobDeadline
  if(!$safe){throw 'The closed encrypted observation is invalid.'};return $safe
 }catch{return @{schema=1;state='unavailable';reason=$failureStage}}finally{if($raw){[Array]::Clear($raw,0,$raw.Length)}}
}
