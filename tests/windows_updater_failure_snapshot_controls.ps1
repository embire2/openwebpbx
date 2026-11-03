# Focused portable real-file/crypto controls; no installed worker or Root private key.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value){if(!$Value){throw ('Failure snapshot control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return $Value|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable}
$source=Join-Path $SourceRoot 'tests/windows_updater_failure_snapshot.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
. $source
$original=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows_updater_file_acl_observation.ps1'));$start=$original.IndexOf('function Seal-WindowsUpdaterAclDifference(');$end=$original.IndexOf('function Get-WindowsUpdaterAclAceBytes(',$start);$old=$original.Substring($start,$end-$start)
$node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'Seal-WindowsUpdaterFailureSnapshot'},$true));Verify ($node.Count-eq 1);$seal=$node[0].Extent.Text
$inverse=$seal.Replace('Seal-WindowsUpdaterFailureSnapshot','Seal-WindowsUpdaterAclDifference').Replace("purpose='windows-updater-failure-snapshot'","purpose='windows-updater-file-acl-difference'").Replace("stage='failure_before_cleanup'","stage='normal_protected_files'");Verify ($inverse-ceq $old.TrimEnd())
$root=Join-Path ([IO.Path]::GetTempPath()) ('failure-snapshot-controls-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $root
$state=Join-Path $root 'state';$work=Join-Path $root 'work';$null=New-Item -ItemType Directory $state,$work
$priorSource=$env:GITHUB_SHA;$priorRun=$env:GITHUB_RUN_ID;$env:GITHUB_SHA='a'*40;$env:GITHUB_RUN_ID='12345';$ephemeral=$null;$aes=$null;$key=$null
# Explicit portable metadata adapters. No Scheduler/service operation executes.
function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
 if($TaskName-cnotin 'OpenWebPBX-TenantDomains','OpenWebPBX-Backups'-or $TaskPath-cne '\'){throw 'Unexpected fixture task read.'}
 return [pscustomobject]@{TaskName=$TaskName;TaskPath='\';State='Ready';Settings=@{Enabled=$true};Principal=@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Actions=@(@{Execute='python.exe';Arguments='PRIVATE_METADATA_SENTINEL';WorkingDirectory='fixture'});Triggers=@(@{CimClass=@{CimClassName='MSFT_TaskTimeTrigger'};Enabled=$true;StartBoundary='2026-11-03T00:00:00';EndBoundary='';Repetition=@{Interval='PT1M';Duration='';StopAtDurationEnd=$false}})}
}
function Get-ScheduledTaskInfo {param($TaskName,$TaskPath,$ErrorAction)return @{LastRunTime=[DateTime]::UtcNow.AddMinutes(-1);NextRunTime=[DateTime]::UtcNow.AddSeconds(10);LastTaskResult=1}}
function Get-Service {param($Name,$ErrorAction)
 if($Name-cnotin 'OpenWebPBX','FreeSWITCH','OpenWebPBX-Database','OpenWebPBXUpdater'){throw 'Unexpected fixture service read.'}
 return [pscustomobject]@{Name=$Name;Status='Running';StartType=if($Name-ceq 'OpenWebPBX'){'Manual'}else{'Automatic'}}
}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction)
 if($ClassName-cne 'Win32_Service'-or $OperationTimeoutSec-ne 2-or $Filter-cnotmatch "^Name='(OpenWebPBX|FreeSWITCH|OpenWebPBX-Database|OpenWebPBXUpdater)'$"){throw 'Unexpected fixture native service read.'}
 return [pscustomobject]@{Name=$Matches[1];PathName='PRIVATE_SERVICE_PATH_SENTINEL';StartName='NT AUTHORITY\LocalService';StartMode='Manual';ProcessId=[uint32]42}
}
try{
 $deadline=[DateTimeOffset]::UtcNow.AddMinutes(2);$clock=[Diagnostics.Stopwatch]::StartNew()
 $unavailable=Get-WindowsUpdaterFailureSnapshot 'forbidden-fixture-root' $work $deadline;Verify ($unavailable.state-ceq 'unavailable'-and $unavailable.reason-ceq 'context_guard'-and $null-ne (Read-WindowsUpdaterFailureSnapshot $unavailable))
 $missing=Get-WindowsUpdaterFailureSnapshotPayload $state $work $clock $deadline
 $view=[Text.UTF8Encoding]::new($false,$true).GetString($missing)|ConvertFrom-Json -AsHashtable
 Verify ($view.log_directory_state-ceq 'missing'-and $view.files.Count-eq 7-and @($view.files|Where-Object {$_.state-cne 'missing'}).Count-eq 0)
 Verify ($view.tasks.Count-eq 2-and $view.tasks['OpenWebPBX-Backups'].state-ceq 'observed'-and $view.tasks['OpenWebPBX-Backups'].last_task_result-eq 1-and $view.tasks['OpenWebPBX-Backups'].triggers[0].interval.value-ceq 'PT1M')
 Verify ($view.services.Count-eq 4-and $view.services.OpenWebPBX.start_type-ceq 'Manual'-and !$view.services.Contains('OpenWebPBXCore'))
 Verify ($view.services.OpenWebPBX.native.state-ceq 'observed'-and $view.services.OpenWebPBX.native.process_id-eq 42-and $view.services.OpenWebPBX.native.path_name.value-ceq 'PRIVATE_SERVICE_PATH_SENTINEL')
 Verify ($view.primary_failure.state-ceq 'unavailable'-and $view.primary_failure.reason-ceq 'not_supplied')
 $primary=$null;try{throw [IO.IOException]::new('PRIVATE_FAILURE_MESSAGE_SENTINEL',[ArgumentException]::new('PRIVATE_INNER_MESSAGE_SENTINEL'))}catch{$primary=$_}
 $primaryIdentity=$primary.Exception;$failure=Get-WindowsUpdaterFailureSnapshotPrimaryFailure $primary
 Verify ($failure.state-ceq 'observed'-and $failure.exceptions.Count-eq 2-and $failure.exceptions[0].type.value-ceq 'System.IO.IOException'-and $failure.exceptions[0].message.value-ceq 'PRIVATE_FAILURE_MESSAGE_SENTINEL'-and $failure.exceptions[1].message.value-ceq 'PRIVATE_INNER_MESSAGE_SENTINEL'-and $failure.line-gt 0-and $failure.source.value.EndsWith('windows_updater_failure_snapshot_controls.ps1')-and $failure.script_stack_trace.value.Length-gt 0-and [object]::ReferenceEquals($primaryIdentity,$primary.Exception))
 $foreign=[pscustomobject]@{};$foreign|Add-Member ScriptMethod ToString {throw 'Arbitrary ToString must never execute.'} -Force
 $unsupported=Get-WindowsUpdaterFailureSnapshotPrimaryFailure $foreign;Verify ($unsupported.state-ceq 'unavailable'-and $unsupported.reason-ceq 'unsupported_type')
 $deep=[Exception]::new(('x'*10000));for($i=0;$i-lt 6;$i++){$deep=[Exception]::new(('y'*10000),$deep)}
 $bounded=Get-WindowsUpdaterFailureSnapshotPrimaryFailure ([Management.Automation.ErrorRecord]::new($deep,'bounded',[Management.Automation.ErrorCategory]::NotSpecified,$null))
 Verify ($bounded.state-ceq 'observed'-and $bounded.exceptions.Count-eq 4-and $bounded.inner_chain_truncated-and $bounded.exceptions[0].message.truncated-and [Text.Encoding]::UTF8.GetByteCount(($bounded|ConvertTo-Json -Depth 7 -Compress))-le 32768)
 $updates=Join-Path $state 'updates';$logs=Join-Path $updates 'logs';$null=New-Item -ItemType Directory $logs -Force
 $sentinel='PRIVATE_DIAGNOSTIC_SENTINEL';[IO.File]::WriteAllText((Join-Path $updates 'status.json'),'{"message":"'+$sentinel+'"}')
 [IO.File]::WriteAllText((Join-Path $updates 'worker-journal.json'),'{}');[IO.File]::WriteAllBytes((Join-Path $updates 'install-journal.json'),[byte[]]::new(65537))
 [IO.File]::WriteAllText((Join-Path $work 'operator-rollback-native.out'),('x'*70000)+$sentinel)
 [IO.File]::WriteAllText((Join-Path $work 'operator-rollback-native.err'),$sentinel);[IO.File]::WriteAllText((Join-Path $work 'status-private.err'),$sentinel)
 [IO.File]::WriteAllText((Join-Path $work 'status-private.out'),'{"commands":[],"channels":0}')
 for($i=0;$i-lt 4;$i++){$path=Join-Path $logs ('install-20261103-12000'+$i+'-'+('b'*31)+$i+'.log');[IO.File]::WriteAllText($path,('y'*110000)+$i);[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddMinutes($i-10))}
 [IO.File]::WriteAllText((Join-Path $logs 'foreign.log'),'FOREIGN_FILE_MUST_NOT_BE_READ')
 $raw=Get-WindowsUpdaterFailureSnapshotPayload $state $work $clock $deadline $primary;$text=[Text.UTF8Encoding]::new($false,$true).GetString($raw);$view=$text|ConvertFrom-Json -AsHashtable
 Verify ($raw.Length-lt 1048576-and $view.files.Count-eq 10-and $view.log_directory_state-ceq 'observed')
 Verify ($view.primary_failure.exceptions[0].message.value-ceq 'PRIVATE_FAILURE_MESSAGE_SENTINEL'-and $view.services.OpenWebPBX.native.path_name.value-ceq 'PRIVATE_SERVICE_PATH_SENTINEL')
 Verify (($view.files|Where-Object label -CEQ 'fixture_status_stdout').state-ceq 'observed'-and $view.non_atomic_readonly_observations)
 Verify (($view.files|Where-Object label -CEQ 'install_journal').state-ceq 'oversize')
 $out=@($view.files|Where-Object label -CEQ 'operator_stdout')[0];Verify ($out.bytes-eq 65536-and $out.offset-gt 0-and [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($out.content_base64)).EndsWith($sentinel))
 $logRows=@($view.files|Where-Object {$_.label-like 'installer_log_*'});Verify ($logRows.Count-eq 3-and @($logRows|Where-Object {$_.bytes-ne 98304}).Count-eq 0)
 Verify ($text-cnotmatch 'foreign.log|FOREIGN_FILE_MUST_NOT_BE_READ'-and @($logRows|Where-Object {$_.name-like '*-120000-*'}).Count-eq 0)
 $target=Join-Path $root 'outside-private.txt';[IO.File]::WriteAllText($target,'REPARSE_CONTENT_MUST_NOT_BE_READ');$link=Join-Path $logs ('install-20261103-130000-'+('c'*32)+'.log');$null=New-Item -ItemType SymbolicLink -Path $link -Target $target
 $refused=Read-WindowsUpdaterFailureSnapshotFile $link 'installer_log_0' 98304 $true $clock $deadline;Verify ($refused.state-ceq 'unavailable'-and !$refused.Contains('content_base64'))
 $caught=$false;try{$null=Get-WindowsUpdaterFailureSnapshotPayload $state $work $clock ([DateTimeOffset]::UtcNow.AddSeconds(-1))}catch{$caught=$true};Verify $caught
 $public=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows_updater_file_acl_public.pem'))
 $encrypted=Seal-WindowsUpdaterFailureSnapshot $raw $env:GITHUB_SHA $env:GITHUB_RUN_ID $public
 $record=@{schema=1;state='captured';encrypted=$encrypted};Verify ($null-ne (Read-WindowsUpdaterFailureSnapshot $record))
 Verify ($null-ne (Read-WindowsUpdaterFailureSnapshot ($record|ConvertTo-Json -Depth 8|ConvertFrom-Json)))
 Verify (($record|ConvertTo-Json -Depth 8 -Compress)-cnotmatch ($sentinel+'|PRIVATE_METADATA_SENTINEL|PRIVATE_FAILURE_MESSAGE_SENTINEL|PRIVATE_INNER_MESSAGE_SENTINEL|PRIVATE_SERVICE_PATH_SENTINEL'))
 foreach($case in 'extra','state_array','recipient','purpose','source','size','nonce','cipher','schema'){
  $bad=Clone $record
  switch($case){extra{$bad.private_value=$sentinel}state_array{$bad.state=@('captured',$sentinel)}recipient{$bad.encrypted.public_key_sha256='b'*64}nonce{$bad.encrypted.nonce=[Convert]::ToBase64String([byte[]]::new(13))}cipher{$bad.encrypted.ciphertext=$sentinel}schema{$bad.schema=$true}default{
   $aad=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bad.encrypted.aad))|ConvertFrom-Json -AsHashtable
   switch($case){purpose{$aad.purpose='other'}source{$aad.source_commit='b'*40}size{$aad.plaintext_bytes=1048577}}
   $bad.encrypted.aad=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($aad|ConvertTo-Json -Compress)))
  }}
  Verify ($null-eq (Read-WindowsUpdaterFailureSnapshot $bad))
 }
 # Ephemeral3072 private key exists in memory only; production recipient gate is
 # changed solely in this extracted test function, never the source/helper.
 $ephemeral=[Security.Cryptography.RSA]::Create(3072);$testPublic=$ephemeral.ExportSubjectPublicKeyInfoPem();$testHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($testPublic))).ToLowerInvariant()
 $testSeal=$seal.Replace('Seal-WindowsUpdaterFailureSnapshot','Seal-TestOnlyFailureSnapshot').Replace('3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819',$testHash);. ([scriptblock]::Create($testSeal))
 $roundtrip=Seal-TestOnlyFailureSnapshot $raw $env:GITHUB_SHA $env:GITHUB_RUN_ID $testPublic
 $key=$ephemeral.Decrypt([Convert]::FromBase64String($roundtrip.wrapped_key),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256);$aes=[Security.Cryptography.AesGcm]::new($key,16);$plain=[byte[]]::new($raw.Length)
 $aes.Decrypt([Convert]::FromBase64String($roundtrip.nonce),[Convert]::FromBase64String($roundtrip.ciphertext),[Convert]::FromBase64String($roundtrip.tag),$plain,[Convert]::FromBase64String($roundtrip.aad))
 Verify ([Convert]::ToBase64String($plain)-ceq [Convert]::ToBase64String($raw))
 Verify ($null-eq (Read-WindowsUpdaterFailureSnapshot @{schema=1;state='captured';encrypted=$roundtrip}))
 @{state='passed';checks=$checks;actual_windows=$false;real_file_reads_and_crypto=$true;readonly_metadata_adapters=$true;ephemeral_private_key_only=$true;no_product_worker_scheduler_or_network_action=$true}|ConvertTo-Json -Compress
}finally{
 if($aes){$aes.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)};if($ephemeral){$ephemeral.Dispose()}
 $env:GITHUB_SHA=$priorSource;$env:GITHUB_RUN_ID=$priorRun;Remove-Item -LiteralPath $root -Recurse -Force
}
