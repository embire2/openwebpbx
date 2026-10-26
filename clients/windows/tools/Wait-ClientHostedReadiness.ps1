# SPDX-License-Identifier: AGPL-3.0-or-later
# Read-only hosted QA readiness; does not replace any later preservation check.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
function NewReadinessState {return [ordered]@{observations=@();changes=0;stable_count=0;stable_since_ms=-1;last_sha256='';ready=$false}}
function AddReadinessObservation($Previous,[long]$StartedMs,[long]$CompletedMs,[long]$Bytes,[string]$Digest){
 $count=$Previous.observations.Count;$scheduled=[long]$count*15000
 if($Previous.ready-or$count-ge12-or$StartedMs-lt$scheduled-or$CompletedMs-lt$StartedMs-or$CompletedMs-ge($scheduled+15000)-or$CompletedMs-ge180000-or$Bytes-le0-or$Bytes-gt8388608-or$Digest-cnotmatch'^[a-f0-9]{64}$'){throw 'Closed bounded readiness observation required.'}
 if($count-and$StartedMs-le$Previous.observations[-1].completed_ms){throw 'Monotonic separate readiness observations required.'}
 $same=$count-and$Digest-ceq$Previous.last_sha256;$changed=$count-and!$same
 $stable=if($same){[long]$Previous.stable_since_ms}else{$CompletedMs};$consecutive=if($same){[int]$Previous.stable_count+1}else{1}
 $row=[ordered]@{index=$count;scheduled_ms=$scheduled;started_ms=$StartedMs;completed_ms=$CompletedMs;bytes=$Bytes;sha256=$Digest}
 return [ordered]@{observations=@($Previous.observations)+@($row);changes=([int]$Previous.changes+[int][bool]$changed);stable_count=$consecutive;stable_since_ms=$stable;last_sha256=$Digest;ready=([bool]($consecutive-ge5-and($CompletedMs-$stable)-ge60000))}
}
$state=NewReadinessState;$stage='source_refused';$reason='source_refused';$preserved=$false;$watch=[Diagnostics.Stopwatch]::StartNew();$selfHash='';$snapshotHash='';$primitivesHash=''
try {
 if(!$IsWindows-or$env:GITHUB_ACTIONS-cne'true'-or$env:RUNNER_ENVIRONMENT-cne'github-hosted'-or$env:GITHUB_REPOSITORY-cne'embire2/openwebpbx'-or(Test-Path 'C:\OpenWebPBX')-or(Test-Path(Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'Only disposable hosted readiness is allowed.'}
 $self=Get-Item -LiteralPath $PSCommandPath -Force;$primitives=Get-Item -LiteralPath (Join-Path $PSScriptRoot 'WavProducerPrimitives.ps1') -Force
 foreach($item in @($self,$primitives)){if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$item.Length-le0-or$item.Length-gt131072){throw 'Exact ordinary readiness source required.'}}
 $selfHash=(Get-FileHash -LiteralPath $self.FullName -Algorithm SHA256).Hash.ToLowerInvariant();$primitivesHash=(Get-FileHash -LiteralPath $primitives.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 if($primitivesHash-cne'dd1c46cce75fa09c306f7a321103f03faf6b7118d289a83dba5d48517ad507ed'){throw 'Original complete snapshot source differs.'}
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($primitives.FullName,[ref]$tokens,[ref]$errors)
 $functions=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'SystemSnapshot'},$true));if($errors.Count-or$functions.Count-ne1){throw 'Unique original snapshot function required.'}
 $functionText=$functions[0].Extent.Text;$snapshotHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($functionText))).ToLowerInvariant()
 . ([scriptblock]::Create($functionText))
 while(!$state.ready-and$state.observations.Count-lt12){
  $due=[long]$state.observations.Count*15000;$now=$watch.ElapsedMilliseconds
  if($now-ge180000){$stage='deadline_not_ready';throw 'Readiness deadline reached.'}
  if($now-lt$due){Start-Sleep -Milliseconds ([int]($due-$now))}
  $stage='snapshot_refused';$started=$watch.ElapsedMilliseconds;if($started-ge180000){$stage='deadline_not_ready';throw 'Readiness deadline reached.'}
  $snapshot=SystemSnapshot
  if($snapshot-isnot[string]){throw 'Complete canonical snapshot string required.'}
  $bytes=[Text.Encoding]::UTF8.GetBytes($snapshot);if(!$bytes.Length-or$bytes.Length-gt8388608){throw 'Complete bounded snapshot required; no truncation.'}
  $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();$completed=$watch.ElapsedMilliseconds
  $stage='timing_refused';$state=AddReadinessObservation $state $started $completed $bytes.Length $digest
 }
 if(!$state.ready-or$watch.ElapsedMilliseconds-ge180000){$stage='deadline_not_ready';throw 'Observed stable readiness was not established.'}
 $stage='source_refused';if((Get-FileHash -LiteralPath $self.FullName -Algorithm SHA256).Hash.ToLowerInvariant()-cne$selfHash-or(Get-FileHash -LiteralPath $primitives.FullName -Algorithm SHA256).Hash.ToLowerInvariant()-cne$primitivesHash){throw 'Readiness source changed.'}
 if($watch.ElapsedMilliseconds-ge180000){$stage='deadline_not_ready';throw 'Readiness deadline reached.'}
 $preserved=$true;$reason='none'
} catch {$reason=$stage}
finally {
 $report=[ordered]@{schema=1;scope='read_only_pretest_stability_only';state= $(if($preserved){'observed_stable_before_preflight'}else{'refused_no_readiness'});reason=$reason;source_commit=$SourceCommit;helper_sha256=$selfHash;primitives_sha256=$primitivesHash;snapshot_function_sha256=$snapshotHash;interval_ms=15000;budget_ms=180000;stable_window_ms=60000;minimum_observations=5;elapsed_ms=$watch.ElapsedMilliseconds;observations=@($state.observations);changes=$state.changes;stable_count=$state.stable_count;stable_since_ms=$state.stable_since_ms;source_preserved=$preserved;cause_or_future_preservation_proved=$false;calling_SDK_WAV_Store_qualified=$false}
 $line=$report|ConvertTo-Json -Depth 8 -Compress;if([Text.Encoding]::UTF8.GetByteCount($line)-gt16384){throw 'Readiness log bound refused.'};Write-Output ('OPENWEB_WAV_READINESS '+$line)
}
if(!$preserved){throw 'Read-only hosted readiness was not established.'}
