# Source-only normal-private failure propagation using the existing encrypted
# observer. Synthetic descriptors; no installed files/tasks/services are read.
[CmdletBinding()]param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value,[string]$Label){if(!$Value){throw ('Manual encrypted observation control refused: '+$Label)};$script:checks++}
. (Join-Path $SourceRoot 'tests/windows_updater_file_acl_observation.ps1')
. (Join-Path $SourceRoot 'tests/windows-hold-failure-fields.ps1')
function SourceAst([string]$Name){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path "$SourceRoot/tests" $Name),[ref]$t,[ref]$e);Verify (!$e.Count) ('source parse '+$Name);return $a}
function ImportDefinition($Ast,[string]$Name){$f=@($Ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $Name},$true));Verify ($f.Count-eq 1) ('unique '+$Name);return $f[0].Extent.Text}
$updater=SourceAst 'windows-updater-qualification.ps1'
Invoke-Expression (ImportDefinition $updater 'QualificationSnapshotPaths')
$manual=SourceAst 'windows-upgrade-acceptance.ps1';$suite=SourceAst 'windows-suite.ps1'
Invoke-Expression (ImportDefinition $suite 'SafeComparisonFields')
foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields','SafeNativeCleanupFields'){
 Invoke-Expression (ImportDefinition $suite $name)
}
Invoke-Expression (ImportDefinition $suite 'SafeFailureFields')
$calls=@($manual.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.Extent.Text-ceq "Equal `$private21 `$privateComparison 'Original21 private/config/key/recording/custom-media files and ACLs changed across the actual22 upgrade.'"},$true));Verify ($calls.Count-eq 1) 'one exact normal-private comparison'
$wrapper=$calls[0].Parent
while($wrapper -and $wrapper-isnot [Management.Automation.Language.TryStatementAst]){$wrapper=$wrapper.Parent}
Verify ($null-ne $wrapper -and $wrapper.CatchClauses.Count-eq 1 -and $wrapper.Body.Statements.Count-eq 1) 'observation only wraps the normal-private failure'
Verify ($wrapper.CatchClauses[0].Body.Extent.Text.Contains('throw $comparisonPrimary') -and $wrapper.CatchClauses[0].Body.Extent.Text.Contains('Read-WindowsUpdaterAclObservation')) 'primary error and existing sanitizer retained'
$imports=@($manual.FindAll({param($n)$n-is [Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text.Contains("'QualificationSnapshotPaths'")},$true));Verify ($imports.Count-eq 1) 'manual observer classifier imported from original source'
Verify ($suite.Extent.Text.Contains("`$node.Name -ceq 'QualificationSnapshotPaths'") -and $suite.Extent.Text.Contains('Invoke-Expression $aclPathFunctions[0].Extent.Text')) 'outer observer classifier imported from original source'
$private='PRIVATE_SENTINEL_customer_password_SDDL_S-1-5-21'
$private21=@{'C:\ProgramData\OpenWebPBX\runtime.json'=@{directory=$false;bytes=1;sha256='same';acl=($private+'-before')}}
$private22=@{'C:\ProgramData\OpenWebPBX\runtime.json'=@{directory=$false;bytes=1;sha256='same';acl=($private+'-after')}}
$privateComparison=$private22;$equalShouldFail=$true;$equalCalls=0;$expectedError=$null
function Equal($Before,$After,[string]$Message){$script:equalCalls++;if($script:equalShouldFail){$script:expectedError=[InvalidOperationException]::new('original-private-failure');throw $script:expectedError}}
$priorSource=$env:GITHUB_SHA;$priorRun=$env:GITHUB_RUN_ID
$realObserver=(Get-Item Function:Get-WindowsUpdaterAclObservation).ScriptBlock
try{
 $env:GITHUB_SHA='d'*40;$env:GITHUB_RUN_ID='12345678'
 $script:privateSecurityObservation=$null;$caught=$null
 try{& ([scriptblock]::Create($wrapper.Extent.Text))}catch{$caught=$_}
 Verify ($null-ne $caught -and [object]::ReferenceEquals($caught.Exception,$expectedError)) 'exact primary exception survives real encrypted observer'
 $observation=Read-WindowsUpdaterAclObservation $privateSecurityObservation
 Verify ($null-ne $observation -and $observation.state-ceq 'captured' -and $observation.changed_count-eq 1) 'actual existing RSA/AES observer captures bounded metadata'
 Verify ($observation.entries[0].file_label-ceq 'runtime' -and ($observation|ConvertTo-Json -Depth 12 -Compress)-cnotmatch $private) 'only closed labels and ciphertext escape'
 $record=@{source_basename='windows-upgrade-acceptance.ps1';failed_phase='original21 normal private-files comparison';command_basename='windows-compare-json.py';comparison_result='unavailable';comparison_stage='report_validation';file_security=$observation}
 # Exercise the real JSON object transport used by the manual hook and suite.
 $transport=$record|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $safe=SafeFailureFields $transport
 Verify ($safe.file_security.state-ceq 'captured' -and $safe.file_security.encrypted.ciphertext-ceq $observation.encrypted.ciphertext) 'outer hook retains exact sanitized encrypted observation'
 Verify (($safe|ConvertTo-Json -Depth 12 -Compress)-cnotmatch $private) 'no raw descriptor in public failure'
 foreach($case in 'phase','raw_field','label','aad'){
  $invalid=$record|ConvertTo-Json -Depth 12|ConvertFrom-Json
  switch($case){
   phase{$invalid.failed_phase='ordinary exact candidate22 upgrade'}
   raw_field{$invalid.file_security|Add-Member NoteProperty raw_acl $private}
   label{$invalid.file_security.entries[0].file_label=$private}
   aad{$invalid.file_security.encrypted.aad=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes('{}'))}
  }
  $safe=SafeFailureFields $invalid
  Verify (!$safe.ContainsKey('file_security') -and ($safe|ConvertTo-Json -Depth 12 -Compress)-cnotmatch $private) ('outer refusal '+$case)
 }
 $script:observerCalls=0
 function Get-WindowsUpdaterAclObservation($Before,$After){$script:observerCalls++;throw 'observer-unavailable'}
 $script:privateSecurityObservation=$null;$caught=$null
 try{& ([scriptblock]::Create($wrapper.Extent.Text))}catch{$caught=$_}
 Verify ($observerCalls-eq 1 -and $null-ne $caught -and [object]::ReferenceEquals($caught.Exception,$expectedError) -and $null-eq $privateSecurityObservation) 'observer refusal cannot replace original comparison failure'
 $script:equalShouldFail=$false;$script:observerCalls=0
 & ([scriptblock]::Create($wrapper.Extent.Text))
 Verify ($observerCalls-eq 0 -and $null-eq $privateSecurityObservation) 'successful comparison never invokes observer'
 [ordered]@{schema=1;state='passed';checks=$checks;existing_observer_and_public_key=$true;actual_authenticated_encryption=$true;original_exception_preserved=$true;outer_json_transport_tested=$true;unknown_fields_refused=$true;strict_comparison_changed=$false;actual_windows_descriptor_parsing=$false;installed_server_changed=$false}|ConvertTo-Json -Compress
}finally{
 Set-Item Function:Get-WindowsUpdaterAclObservation -Value $realObserver
 if($null-eq $priorSource){Remove-Item Env:\GITHUB_SHA -ErrorAction SilentlyContinue}else{$env:GITHUB_SHA=$priorSource}
 if($null-eq $priorRun){Remove-Item Env:\GITHUB_RUN_ID -ErrorAction SilentlyContinue}else{$env:GITHUB_RUN_ID=$priorRun}
}
