# Execute the actual versioned guards from both restore/updater entry points.
# No Windows installation, task, network request or signed package is simulated.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Modern baseline control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){$script:guardCalls++;if(!$Value){throw 'EXACT_CURRENT_BASELINE_REFUSAL'}}
function DtlsProof {return [pscustomobject]@{state='passed';transaction_checks=62;crypto_checks=12;installed_checks=12;transaction_service_adapter_double=$true;actual_native_windows=$true}}
$tokens=$null;$errors=$null;$producer=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
$projection=@($producer.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts.dtls_qualification' -and $node.Right.Extent.Text.StartsWith("@{state='passed';transaction_checks=")},$true));Assert ($projection.Count -eq 1)
# Execute the actual current producer projection, without its native runner.
$report=[pscustomobject]@{transaction_checks=63;crypto_checks=12;installed_checks=12};$facts=@{};Invoke-Expression $projection[0].Extent.Text
$producedDtls=$facts.dtls_qualification
$modern=@('web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back')
foreach($consumer in 'windows-updater-qualification.ps1','windows-restore-qualification.ps1'){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$consumer)),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if([version]$BaseVersion -ge ') -and $node.Extent.Text.Contains("'web_readiness'")},$true));Assert ($nodes.Count -eq 1)
 $guard=[scriptblock]::Create($nodes[0].Extent.Text)
 foreach($version in '1.0.20','1.0.21'){
  $BaseVersion=$version;$values=@{};foreach($gate in $modern){$values[$gate]='passed'};$baseFacts=[pscustomobject]@{gates=[pscustomobject]$values;dtls_qualification=(DtlsProof)}
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 16)
  foreach($gate in $modern){
   $badValues=@($null,$true,$false,0,1,'Passed','passed ','partial','running','unqualified',@('passed'),@('passed','unqualified'),@{},[pscustomobject]@{state='passed'})
   foreach($bad in $badValues){
    $baseFacts.gates.$gate=$bad;$caught=$null;$script:guardCalls=0;try{& $guard}catch{$caught=$_.Exception.Message}
    Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL' -and $script:guardCalls -ge 1 -and $script:guardCalls -le 9)
   }
   $baseFacts.gates.PSObject.Properties.Remove($gate);$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
   $baseFacts.gates|Add-Member -NotePropertyName $gate -NotePropertyValue 'passed'
  }
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 16)
  foreach($currentRecord in @($producedDtls,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $producedDtls -Compress)))){$baseFacts.dtls_qualification=$currentRecord;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 16)}
  foreach($bad in @($null,$true,$false,0,1,'passed','unqualified_historical_candidate',@('passed'),@((DtlsProof)),@{},[pscustomobject]@{state='passed'})){
   $baseFacts.dtls_qualification=$bad;$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  }
  $baseFacts.dtls_qualification=DtlsProof
  foreach($field in 'state','transaction_checks','crypto_checks','installed_checks','transaction_service_adapter_double','actual_native_windows'){
   $minimum=switch($field){'transaction_checks'{62};'crypto_checks'{12};'installed_checks'{12};default{0}}
   $badValues=switch($field){
    'state'{@($null,$true,1,'Passed','passed ','failed','partial',@('passed'),@{})}
    {$_ -in 'actual_native_windows','transaction_service_adapter_double'}{@($null,$false,0,1,'true',@($true),@{})}
    default{@($null,$true,$false,0,($minimum-1),10001,1.5,([decimal]$minimum),([string]$minimum),@($minimum),@{})}
   }
   foreach($bad in $badValues){$baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.$field=$bad;$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')}
   $baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.PSObject.Properties.Remove($field);$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  }
  $baseFacts.dtls_qualification=DtlsProof;$baseFacts.PSObject.Properties.Remove('dtls_qualification');$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  $baseFacts|Add-Member NoteProperty dtls_qualification (DtlsProof)
  foreach($value in 62,([long]62),10000){$baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.transaction_checks=$value;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 16)}
 }
 $BaseVersion='1.0.13';$baseFacts=[pscustomobject]@{gates=[pscustomobject]@{}};$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 0)
}
Write-Output ('PASS '+$checks+' actual modern restore/updater baseline guard controls; current nine gates and complete native DTLS record required, historical13 branch unchanged')
