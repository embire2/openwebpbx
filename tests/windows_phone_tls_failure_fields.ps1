# Execute the actual generated phone-TLS failure launcher without PBX changes.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Closed phone TLS diagnostics failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null
$native=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors);Check (!$errors.Count)
$strings=@($native.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains("active_case='phone_tls_helper'") -and $node.Value.Contains('param([Parameter(Mandatory)][string]$InputPath)')},$true));Check ($strings.Count -eq 1)
$caller=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Check (!$errors.Count)
foreach($name in 'SafeFailureFields','SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeNativeCleanupFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields'){
 $nodes=@($caller.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-phone-tls-diagnostics-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
try{
 $launcher=Join-Path $work 'launcher.ps1';[IO.File]::WriteAllText($launcher,$strings[0].Value)
 $pwsh=(Get-Process -Id $PID).Path
 foreach($name in 'Enable-PhoneTLS.ps1','foreign-private.ps1'){
  $helper=Join-Path $work $name;$failure=Join-Path $work 'failure.json';$requestPath=Join-Path $work 'input.json'
  [IO.File]::WriteAllText($helper,"`$inner=[IO.IOException]::new('private-never-copy',-2147024864)`nthrow [InvalidOperationException]::new('private-never-copy',`$inner)`n")
  [IO.File]::WriteAllText($requestPath,(@{helper=$helper;failure=$failure;thumbprint='private-never-copy';chain='private-never-copy'}|ConvertTo-Json))
  & $pwsh -NoProfile -NonInteractive -File $launcher -InputPath $requestPath *> (Join-Path $work 'child.private.log');Check ($LASTEXITCODE -eq 1)
  $record=Get-Content -LiteralPath $failure -Raw|ConvertFrom-Json
  Check ($record.phone_tls_inner_error_type -ceq 'IOException');Check ($record.phone_tls_inner_hresult -eq 2147942432L);Check ($record.phone_tls_inner_depth -ge 1 -and $record.phone_tls_inner_depth -le 8)
  Check (($record|ConvertTo-Json -Depth 8) -notmatch 'private-never-copy|foreign-private|openweb-phone-tls-diagnostics')
  Check ($record.source_basename -ceq $(if($name -ceq 'Enable-PhoneTLS.ps1'){'Enable-PhoneTLS.ps1'}else{'external_component'}))
  $safe=SafeFailureFields $record
  foreach($field in 'phone_tls_inner_error_type','phone_tls_inner_hresult','phone_tls_inner_depth'){Check ($safe[$field] -ceq $record.$field)}
  foreach($field in 'phone_tls_inner_hresult','phone_tls_inner_depth'){
   foreach($bad in '1',$true,$null,-1,4294967296L,@(1),@{private='private-never-copy'}){
    $copy=$record.PSObject.Copy();$copy.$field=$bad;Check (!(SafeFailureFields $copy).ContainsKey($field))
   }
  }
  foreach($bad in 'private-never-copy','IOEXCEPTION',1,$null){$copy=$record.PSObject.Copy();$copy.phone_tls_inner_error_type=$bad;Check (!(SafeFailureFields $copy).ContainsKey('phone_tls_inner_error_type'))}
  foreach($bad in 'basic_decoded_audio','PHONE_TLS_HELPER','phone_tls_','phone_tls_private-value',$null){$copy=$record.PSObject.Copy();$copy.active_case=$bad;$projected=SafeFailureFields $copy;Check (@($projected.Keys|Where-Object {$_ -like 'phone_tls_*'}).Count -eq 0)}
 }
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
"PASS $checks actual generated-launcher/closed caller controls; no Windows PBX result implied"
