# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual extracted consumer/filesystem controls; fictional trace and fresh ephemeral AES key.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1'));$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Actual media wrapper must parse.'}
foreach($name in @('ClosedKeys','JsonShape','Ordinary','ReadEngineObservation','ReadSealedEngineDiagnostic','PreserveSealedEngineDiagnostic')){
 $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($found.Count -ne 1){throw 'One actual function required.'};. ([scriptblock]::Create($found[0].Extent.Text))
}
$SourceCommit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$savedRun=$env:GITHUB_RUN_ID;$env:GITHUB_RUN_ID='123456';$checks=0
$temp=Join-Path ([IO.Path]::GetTempPath()) ('engine-diagnostics-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp);$prefix=$temp+[IO.Path]::DirectorySeparatorChar;$scope=Join-Path $temp 'phone-client-media-owned';[void][IO.Directory]::CreateDirectory($scope)
function Check([bool]$Value){if(!$Value){throw 'Engine diagnostic control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){$bad=$false;try{$null=&$Action}catch{$bad=$true};Check $bad}
function Json($Value){$Value|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json}
function Observation {Json ([ordered]@{observed=$true;log_bytes=500;rejection_signals=@('required_crypto_missing');remote_sdp=@([ordered]@{kind='audio';protocol='RTP/SAVP';codecs=@('PCMU');crypto_suites=@('AES_CM_128_HMAC_SHA1_80')});sealed_original=$true})}
function Bytes($Value){,[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))}
try{
 $actual=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'PreserveSealedEngineDiagnostic'},$true))[0].Extent.Text
 function ReservedAssignments([string]$Text){
  $t=$null;$e=$null;$parsed=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$t,[ref]$e);if($e.Count){throw 'Actual function mutation must parse.'}
  @($parsed.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -iin @('input','home','pid','pshome','pwd','error','args','_','foreach','switch','this')},$true)).Count
 }
 Check ((ReservedAssignments $actual) -eq 0 -and (ReservedAssignments $actual.Replace('$sealedInput','$input')) -eq 1)
 $o=Observation;$null=ReadEngineObservation $o;Check $true
 foreach($field in @('observed','sealed_original')){$o=Observation;$o.$field='true';Refuse {ReadEngineObservation $o}}
 foreach($count in @(-1,2097153)){$o=Observation;$o.log_bytes=[long]$count;Refuse {ReadEngineObservation $o}}
 $o=Observation;$o.observed=$false;Refuse {ReadEngineObservation $o}
 $o=Observation;$o.remote_sdp[0].protocol='PRIVATE';Refuse {ReadEngineObservation $o}
 $o=Observation;$o.remote_sdp[0].crypto_suites=@('inline:PRIVATE');Refuse {ReadEngineObservation $o}
 $o=Observation;$o.remote_sdp[0].codecs=@('PRIVATE');Refuse {ReadEngineObservation $o}
 $o=Observation;$o.rejection_signals=@('PRIVATE');Refuse {ReadEngineObservation $o}
 $o=Observation;$o.rejection_signals=@('codec_error','codec_error');Refuse {ReadEngineObservation $o}
 $o=Observation;$o.remote_sdp=@($o.remote_sdp[0])*17;Refuse {ReadEngineObservation $o}
 $o=Observation;$o.remote_sdp[0]|Add-Member NoteProperty key 'PRIVATE';Refuse {ReadEngineObservation $o}
 $o=Observation;$o.observed=$false;$o.rejection_signals=@();$o.remote_sdp=@();$null=ReadEngineObservation $o;Check $true
 $raw=[Text.Encoding]::UTF8.GetBytes('PRIVATE fictional trace');$pemPath=Join-Path $PSScriptRoot '../OpenWebPbx.Phone.MediaChecks/MediaDiagnosticPublic.pem';$pem=[IO.File]::ReadAllText($pemPath)
 $keyHash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pem)));Check ($keyHash -ceq '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307')
 $rsa=[Security.Cryptography.RSA]::Create();$rsa.ImportFromPem($pem);Check ($rsa.KeySize -eq 3072)
 $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($raw.Length)
 $binding=[ordered]@{schema=1;source_commit=$SourceCommit;run_id=$env:GITHUB_RUN_ID;stage='outgoing_audio';plaintext_bytes=$raw.Length;plaintext_sha256=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($raw))};$aad=Bytes $binding
 $wrapped=$rsa.Encrypt($key,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256);$aes=[Security.Cryptography.AesGcm]::new($key,16);try{$aes.Encrypt($nonce,$raw,$cipher,$tag,$aad)}finally{$aes.Dispose();[Security.Cryptography.CryptographicOperations]::ZeroMemory($key)}
 $envelope=[ordered]@{schema=1;algorithm='RSA3072-OAEP-SHA256+A256GCM';public_key_sha256=$keyHash;aad=[Convert]::ToBase64String($aad);wrapped_key=[Convert]::ToBase64String($wrapped);nonce=[Convert]::ToBase64String($nonce);tag=[Convert]::ToBase64String($tag);ciphertext=[Convert]::ToBase64String($cipher)};$rsa.Dispose()
 # This consumer validates shape/binding only; actual decrypt/authentication is tested in PureMediaProgram.
 $bytes=Bytes $envelope;$receipt=ReadSealedEngineDiagnostic $bytes 'outgoing_audio';Check ($receipt.plaintext_bytes -eq $raw.Length -and !([Text.Encoding]::UTF8.GetString($bytes)).Contains('PRIVATE'))
 foreach($field in @('algorithm','public_key_sha256')){$bad=Json $envelope;$bad.$field='PRIVATE';Refuse {ReadSealedEngineDiagnostic (Bytes $bad) 'outgoing_audio'}}
 foreach($field in @('aad','wrapped_key','nonce','tag','ciphertext')){$bad=Json $envelope;$bad.$field='!';Refuse {ReadSealedEngineDiagnostic (Bytes $bad) 'outgoing_audio'}}
 foreach($field in @('source_commit','run_id','stage','plaintext_sha256')){$badBinding=Json $binding;$badBinding.$field='PRIVATE';$bad=Json $envelope;$bad.aad=[Convert]::ToBase64String((Bytes $badBinding));Refuse {ReadSealedEngineDiagnostic (Bytes $bad) 'outgoing_audio'}}
 $badBinding=Json $binding;$badBinding.plaintext_bytes++;$bad=Json $envelope;$bad.aad=[Convert]::ToBase64String((Bytes $badBinding));Refuse {ReadSealedEngineDiagnostic (Bytes $bad) 'outgoing_audio'}
 $bad=Json $envelope;$bad|Add-Member NoteProperty raw 'PRIVATE';Refuse {ReadSealedEngineDiagnostic (Bytes $bad) 'outgoing_audio'}
 Refuse {ReadSealedEngineDiagnostic $bytes 'incoming_audio'}
 Refuse {ReadSealedEngineDiagnostic ([byte[]]::new(2810001)) 'outgoing_audio'}
 $inputPath=Join-Path $scope 'engine-diagnostic.sealed.json';$outputPath=Join-Path $temp 'client-media-private.sealed.json';[IO.File]::WriteAllBytes($inputPath,$bytes)
 $saved=PreserveSealedEngineDiagnostic $inputPath $outputPath 'outgoing_audio';Check ($saved.sha256 -ceq $receipt.sha256 -and [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($outputPath),[byte[]]$bytes))
 Refuse {PreserveSealedEngineDiagnostic $inputPath $outputPath 'outgoing_audio'}
 Refuse {PreserveSealedEngineDiagnostic $inputPath ($outputPath+'.wrong') 'outgoing_audio'}
 Refuse {PreserveSealedEngineDiagnostic ($inputPath+'.wrong') $outputPath 'outgoing_audio'}
 Remove-Item -LiteralPath $outputPath;Remove-Item -LiteralPath $inputPath;$other=Join-Path $scope 'other';[IO.File]::WriteAllBytes($other,$bytes);[IO.File]::CreateSymbolicLink($inputPath,$other)|Out-Null;Refuse {PreserveSealedEngineDiagnostic $inputPath $outputPath 'outgoing_audio'}
 [ordered]@{schema=1;state='passed_actual_closed_engine_consumers';checks=$checks;trace_input='explicit_fictional';native_media_qualified=$false}|ConvertTo-Json -Compress
}finally{if($null -eq $savedRun){Remove-Item Env:GITHUB_RUN_ID -ErrorAction SilentlyContinue}else{$env:GITHUB_RUN_ID=$savedRun};Remove-Item -LiteralPath $temp -Recurse -Force}
