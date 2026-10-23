# QA-only actual closed projection/time-window classification controls.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Meeting runtime projection control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'SafeNativeMeetingRuntimeFields','NativeMeetingLogCategories'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text}
function Fixture {
 return @{schema=1;read_only=$true;observed=$true;certificate_directory_owned=$true;modules=@{sofia=$true;conference=$true;hash=$true;vpx=$false;opus=$false};codecs=@{query_valid=$true;pcmu=$true;pcma=$true;vp8=$true;opus=$false};profile=@{query_valid=$true;loopback_signalling=$true;pcmu=$true;pcma=$true;vp8=$true};dtls_certificate=@{observed=$true;ordinary_file=$true;certificate_parsed=$true;private_key_parsed=$true;key_matches=$true;current_validity=$true;rsa_at_least_4096=$true;sha256_fingerprint=$true}}
}
function Verify($Value){$before=$Value|ConvertTo-Json -Depth 8 -Compress;$safe=SafeNativeMeetingRuntimeFields $Value;Check ($safe.Count -eq 8);Check (($Value|ConvertTo-Json -Depth 8 -Compress) -ceq $before);Check (($safe|ConvertTo-Json -Depth 8 -Compress) -cnotmatch 'PRIVATE');return $safe}
foreach($kind in 'map','object'){
 $good=Fixture;if($kind -ceq 'object'){$good=($good|ConvertTo-Json -Depth 8)|ConvertFrom-Json};$null=Verify $good
 foreach($bad in '1',1.0,$true,$null,@(1)){$row=Fixture;$row.schema=$bad;Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)}
 foreach($section in 'modules','codecs','profile','dtls_certificate'){
  $base=Fixture
  foreach($field in @($base[$section].Keys)){
   foreach($bad in $null,'PRIVATE',0,1,@($true),@{}){$row=Fixture;$row[$section][$field]=$bad;Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)}
   $row=Fixture;$row[$section].Remove($field);Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)
  }
  $row=Fixture;$row[$section].raw='PRIVATE';Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)
 }
 foreach($field in 'read_only','observed','certificate_directory_owned'){
  foreach($bad in $null,'PRIVATE',0,1,@($true),@{}){$row=Fixture;$row[$field]=$bad;Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)}
 }
 $row=Fixture;$row.read_only=$false;Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)
 $row=Fixture;$row.private='PRIVATE';Check ((SafeNativeMeetingRuntimeFields $row).Count -eq 0)
}
$started=[DateTime]::Now.AddSeconds(-3);$stamp=$started.ToString('yyyy-MM-dd HH:mm:ss')
$old=$started.AddMinutes(-2).ToString('yyyy-MM-dd HH:mm:ss');$future=[DateTime]::Now.AddMinutes(2).ToString('yyyy-MM-dd HH:mm:ss')
$examples=@{codec_negotiation='CODEC NEGOTIATION ERROR. SDP PRIVATE';missing_sdp_connection='Cannot find a c= line in the sdp at media or session level! PRIVATE';crypto_required='Crypto not negotiated but required. PRIVATE';fingerprint_file='FP FILE ERR! PRIVATE';dtls_certificate='audio DTLS check key failed PRIVATE';dtls_handshake='audio Fingerprint Verification Failed! PRIVATE';incompatible_destination='Hangup INCOMPATIBLE_DESTINATION PRIVATE';ice_candidate_unusable='PRIVATE no suitable candidates found.';rtp_activation='AUDIO RTP REPORTS ERROR: PRIVATE'}
foreach($name in $examples.Keys){
 $message=$examples[$name]
 $row=NativeMeetingLogCategories "$stamp.123456 10.0% [ERR] $message" $started;Check ($row[$name] -eq $true -and $row.timestamped_lines -eq 1 -and $row.scope -ceq 'isolated_runner_time_window');Check (($row|ConvertTo-Json) -cnotmatch 'PRIVATE|SDP|123456')
 foreach($prefix in $old,$future,'invalid-date',''){$row=NativeMeetingLogCategories "$prefix.123456 10.0% [ERR] $message" $started;Check (!$row[$name] -and $row.timestamped_lines -eq 0)}
}
foreach($reason in 'not an IP address','cannot resolve','no network path'){
 foreach($kind in 'audio','video'){
  $row=NativeMeetingLogCategories "$stamp.1 [DEBUG] Drop $kind Candidate cid: 1 proto: udp type: host addr: PRIVATE ($reason)" $started
  Check ($row.ice_candidate_unusable -is [bool] -and $row.ice_candidate_unusable -eq $true);Check (($row|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|addr:|host|udp|cid:')
 }
}
$row=NativeMeetingLogCategories "$stamp.1 [DEBUG] Choose rtp candidate PRIVATE`n$stamp.1 [DEBUG] Searching for rtp candidate" $started;Check ($row.ice_candidate_unusable -is [bool] -and !$row.ice_candidate_unusable)
$row=NativeMeetingLogCategories "$stamp.0 1.0% [DEBUG] ordinary PRIVATE`nno timestamp CODEC NEGOTIATION ERROR PRIVATE" $started;Check ($row.timestamped_lines -eq 1 -and !$row.codec_negotiation)
Write-Output ('PASS '+$checks+' actual closed runtime/log diagnostic controls; no Windows media qualification implied')
