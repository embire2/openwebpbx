#Requires -Version 5.1
<# Actual PowerShell AST projection/type/privacy controls only. No restore,
phone, event socket, process, service, or installed PBX is contacted. #>
[CmdletBinding()]
param([string]$SourceRoot='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceRoot)){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-restore-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual restore wrapper must parse.'}
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'SafeRestoredClockSummary'},$true))
if($nodes.Count -ne 1){throw 'Exactly one actual clock summary projector is required.'}
Invoke-Expression $nodes[0].Extent.Text
$script:count=0
function Assert([bool]$Condition){$script:count++;if(!$Condition){throw ('An actual clock-summary control failed at source line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}}
$good=[ordered]@{
 sourcebindings_verified=$true;GMT_plus_2_full_time_verified=$true;original_phone_media_restored=$true
 owned_clock_call_ended=$true;scoped_observer_stopped=$true;software_phone_only=$true
 no_carrier_calls_or_database_configuration_writes=$true;frozen_Nathaniel_assets=34;complete_announcements=3
 minimum_component_correlation=.9998;maximum_native_signal_lateness_ms=12;maximum_decoded_beep_target_error_ms=17.5
}
function NewRecord{$out=[ordered]@{};foreach($key in $good.Keys){$out[$key]=$good[$key]};return [pscustomobject]$out}
$safe=SafeRestoredClockSummary (NewRecord)
Assert ($safe.Count -eq $good.Count)
Assert (@($safe.Keys|Where-Object {$_ -cnotin $good.Keys}).Count -eq 0)
foreach($key in $good.Keys){Assert ($safe[$key] -ceq $good[$key])}
Assert ((SafeRestoredClockSummary $good).Count -eq $good.Count)
foreach($key in @('sourcebindings_verified','GMT_plus_2_full_time_verified','original_phone_media_restored','owned_clock_call_ended','scoped_observer_stopped','software_phone_only','no_carrier_calls_or_database_configuration_writes')){
 foreach($value in @($null,$false,0,1,'true','PRIVATE password C:/private',@(),@{},@($true))){
  $record=NewRecord;$record.$key=$value;Assert ($null -eq (SafeRestoredClockSummary $record))
 }
 $record=NewRecord;$record.PSObject.Properties.Remove($key);Assert ($null -eq (SafeRestoredClockSummary $record))
}
foreach($definition in @(@{key='frozen_Nathaniel_assets';valid=34},@{key='complete_announcements';valid=3})){
 foreach($value in @([int]$definition.valid,[long]$definition.valid)){$record=NewRecord;$record.($definition.key)=$value;Assert ($null -ne (SafeRestoredClockSummary $record))}
 foreach($value in @($null,$true,$false,[double]$definition.valid,[decimal]$definition.valid,[string]$definition.valid,($definition.valid-1),($definition.valid+1),@{},@())){
  $record=NewRecord;$record.($definition.key)=$value;Assert ($null -eq (SafeRestoredClockSummary $record))
 }
 $record=NewRecord;$record.PSObject.Properties.Remove($definition.key);Assert ($null -eq (SafeRestoredClockSummary $record))
}
foreach($definition in @(
 @{key='minimum_component_correlation';valid=@(.62,.9998,1,[long]1);invalid=@(-.001,.619999,1.000001)},
 @{key='maximum_native_signal_lateness_ms';valid=@(0,[long]0,249,249.999);invalid=@(-.001,250,251)},
 @{key='maximum_decoded_beep_target_error_ms';valid=@(0,[long]0,349,349.999);invalid=@(-.001,350,351)}
)){
 foreach($value in $definition.valid){$record=NewRecord;$record.($definition.key)=$value;Assert ($null -ne (SafeRestoredClockSummary $record))}
 foreach($value in @($definition.invalid)+@($null,$true,$false,'0','PRIVATE',@{},@(),[decimal]1,[single]1,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity)){
  $record=NewRecord;$record.($definition.key)=$value;Assert ($null -eq (SafeRestoredClockSummary $record))
 }
 $record=NewRecord;$record.PSObject.Properties.Remove($definition.key);Assert ($null -eq (SafeRestoredClockSummary $record))
}
foreach($key in 'password','event_socket','realm','domain','events','audio','paths','PRIVATE'){
 $record=NewRecord;$record|Add-Member NoteProperty $key 'PRIVATE password C:/private/file.wav'
 $projected=SafeRestoredClockSummary $record
 # The projector may reject extra fields or discard them. It may never emit one.
 if($null -ne $projected){Assert ($projected.Count -eq $good.Count);Assert (($projected|ConvertTo-Json -Depth 10 -Compress) -notmatch 'PRIVATE|password|event_socket|realm|domain|events|audio|paths|C:/')}
 else{Assert $true}
}
foreach($bad in @($null,'PRIVATE',17,$true,@{},@())){Assert ($null -eq (SafeRestoredClockSummary $bad))}
$one=@((NewRecord));Assert ($null -eq (SafeRestoredClockSummary $one))
$two=@((NewRecord),(NewRecord));Assert ($null -eq (SafeRestoredClockSummary $two))
Write-Output ('PASS '+$count+' actual clock-summary AST/type/boundary/privacy controls; no PBX contacted')
