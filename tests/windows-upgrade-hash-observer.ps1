# SPDX-License-Identifier: AGPL-3.0-or-later
# Failure-only QA metadata. No filesystem/process queries or changed hash access.
function UpgradeHashFailureFields($Record){
 if($null -eq $Record -or $Record -is [Array]){return $null}
 $keys=@('schema','category','file_label','error_type','base_error_type','hresult','base_hresult','win32_code','frames')
 $actual=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1){return $null}
 $categories=@('web','server','desktop','tools','php','backup_runtime','acme','updater','configuration','engine_config','engine_scripts','engine_modules','engine_sounds','engine_logs','storage','notifications','phone_tls','public_access','automatic_backups','backup_restore','backup_control','backup_downloads','codec_cache','codec_build','phone_health_runtime','stun_setup','dtls_setup','state','fault_payload','package','other')
 $labels=@('unknown','upgrade_lock','backup_worker_lock','cdr_import_lock','cdr_hold','config','template_key','runtime','installation','phone_tls_metadata','phone_health_metadata','stun_metadata','native_metadata','codec_metadata','updater_metadata','notification_config','notification_lock','php_ini','php_openssl','php_ca','dtls_material','fault_bootstrap','fault_script','installed_upgrade_helper','candidate_upgrade_helper')
 $types=@('IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','PathTooLongException','NotSupportedException','ArgumentException','InvalidOperationException','SecurityException','RuntimeException','MethodInvocationException','ActionPreferenceStopException','ItemNotFoundException','ProviderInvocationException','Win32Exception','OtherError')
 if($Record.category -isnot [string] -or $Record.category -cnotin $categories -or $Record.file_label -isnot [string] -or $Record.file_label -cnotin $labels){return $null}
 foreach($key in 'error_type','base_error_type'){if($Record.$key -isnot [string] -or $Record.$key -cnotin $types){return $null}}
 foreach($key in 'hresult','base_hresult'){$v=$Record.$key;if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt [int]::MinValue -or $v -gt [int]::MaxValue){return $null}}
 $code=$Record.win32_code
 if($null -ne $code -and (($code -isnot [int] -and $code -isnot [long]) -or $code -lt 0 -or $code -gt 65535)){return $null}
 if(([long]$Record.base_hresult -band 4294901760) -eq 2147942400){if($null -eq $code -or $code -ne ($Record.base_hresult -band 65535)){return $null}}elseif($Record.base_error_type -cne 'Win32Exception' -and $null -ne $code){return $null}
 if($Record.frames -isnot [Array] -or $Record.frames.Count -lt 1 -or $Record.frames.Count -gt 4){return $null}
 $frames=@();$seen=@{}
 foreach($row in $Record.frames){
  if($null -eq $row -or $row -is [Array]){return $null}
  $names=if($row -is [Collections.IDictionary]){@($row.Keys)}else{@($row.PSObject.Properties.Name)}
  if($names.Count -ne 3 -or @($names|Where-Object {$_ -cnotin @('function','source_basename','source_line')}).Count -or $row.function -isnot [string] -or $row.function -cnotin @('Hash','FilesSnapshot','FaultPayload','SignedChecks','<ScriptBlock>') -or $row.source_basename -isnot [string] -or $row.source_basename -cne 'windows-upgrade-acceptance.ps1' -or ($row.source_line -isnot [int] -and $row.source_line -isnot [long]) -or $row.source_line -lt 1 -or $row.source_line -gt 100000){return $null}
  $key=$row.function+':'+$row.source_line;if($seen.ContainsKey($key)){return $null};$seen[$key]=$true
  $frames+=,@{function=$row.function;source_basename='windows-upgrade-acceptance.ps1';source_line=[int]$row.source_line}
 }
 if($frames[0].function -cne 'Hash'){return $null}
 return @{schema=1;category=$Record.category;file_label=$Record.file_label;error_type=$Record.error_type;base_error_type=$Record.base_error_type;hresult=[int]$Record.hresult;base_hresult=[int]$Record.base_hresult;win32_code=$code;frames=$frames}
}
function ObserveUpgradeHashFailure([string]$Path,$Failure,$Frames,$Roots){
 if($Failure -isnot [Management.Automation.ErrorRecord] -or $Frames -isnot [Array] -or $Roots -isnot [Collections.IDictionary]){return $null}
 $normalize={param($Value)if($Value -isnot [string] -or $Value.Length -gt 32767 -or $Value -match '[\x00-\x1f]'){return $null};$s=$Value.Replace('\','/').TrimEnd('/').ToLowerInvariant();if($s -notmatch '^[a-z]:/' -or $s -match '(^|/)\.{1,2}(/|$)' -or $s.Contains('//')){return $null};return $s}
 $pathValue=&$normalize $Path;$paths=@{}
 foreach($key in 'root','state','configuration','engine','work','package'){$value=&$normalize $Roots[$key];if(!$value){return $null};$paths[$key]=$value}
 $category='other';$label='unknown'
 if($pathValue){
  $fixed=@{}
  foreach($row in @(@('state','upgrade.lock','upgrade_lock'),@('state','automatic-backups/worker.lock','backup_worker_lock'),@('state','call-records.hold','cdr_hold'),@('configuration','config.conf','config'),@('configuration','openweb-template.key','template_key'),@('state','runtime.json','runtime'),@('state','installation.json','installation'),@('state','phone-tls.json','phone_tls_metadata'),@('state','phone-health-instance.json','phone_health_metadata'),@('state','stun.json','stun_metadata'),@('state','native-engine.json','native_metadata'),@('state','local-codec.json','codec_metadata'),@('state','updater-install.json','updater_metadata'),@('state','mobile-notifications/config.json','notification_config'),@('state','mobile-notifications/config.json.lock','notification_lock'),@('root','php/php.ini','php_ini'),@('root','php/extras/ssl/openssl.cnf','php_openssl'),@('root','php/extras/ssl/cacert.pem','php_ca'),@('engine','cert/dtls-srtp.pem','dtls_material'),@('engine','log/xml_cdr/.openweb-import.lock','cdr_import_lock'),@('work','forced-payload/bootstrap.php','fault_bootstrap'),@('work','forced-payload/forced-failure.ps1','fault_script'),@('root','tools/Upgrade-OpenWebPBX.ps1','installed_upgrade_helper'),@('package','Upgrade-OpenWebPBX.ps1','candidate_upgrade_helper'))){$fixed[($paths[$row[0]]+'/'+$row[1]).ToLowerInvariant()]=$row[2]}
  if($fixed.ContainsKey($pathValue)){$label=$fixed[$pathValue]}
  $prefixes=,@('work','forced-payload','fault_payload')
  foreach($name in 'web','server','desktop','tools','php','acme','updater'){$prefixes+=,@('root',$name,$name)}
  $prefixes+=,@('root','backup-runtime','backup_runtime')
  foreach($row in @(@('conf','engine_config'),@('scripts','engine_scripts'),@('mod','engine_modules'),@('sounds','engine_sounds'),@('log','engine_logs'))){$prefixes+=,@('engine',$row[0],$row[1])}
  foreach($row in @(@('storage','storage'),@('mobile-notifications','notifications'),@('phone-tls','phone_tls'),@('public-access','public_access'),@('automatic-backups','automatic_backups'),@('backup-restore','backup_restore'),@('backup-control','backup_control'),@('backup-downloads','backup_downloads'),@('codec-compiler-cache','codec_cache'),@('codec-build','codec_build'),@('phone-health-runtime','phone_health_runtime'),@('stun-setup','stun_setup'),@('dtls-setup','dtls_setup'))){$prefixes+=,@('state',$row[0],$row[1])}
  $prefixes+=@(@('configuration','','configuration'),@('state','','state'),@('package','','package'))
  foreach($row in $prefixes){$prefix=($paths[$row[0]]+'/'+$row[1]).TrimEnd('/');if($pathValue -ceq $prefix -or $pathValue.StartsWith($prefix+'/',[StringComparison]::Ordinal)){$category=$row[2];break}}
 }
 $framesOut=@();$seen=@{};$examined=0
 foreach($frame in $Frames){
  if(++$examined -gt 12 -or $framesOut.Count -ge 4){break}
  if($frame.FunctionName -isnot [string] -or $frame.FunctionName -cnotin @('Hash','FilesSnapshot','FaultPayload','SignedChecks','<ScriptBlock>') -or $frame.ScriptName -isnot [string] -or $frame.ScriptName.Length -gt 32767 -or $frame.ScriptLineNumber -isnot [int] -or $frame.ScriptLineNumber -lt 1 -or $frame.ScriptLineNumber -gt 100000){continue}
  $basename=$frame.ScriptName.Replace('\','/').Split('/')[-1];if($basename -cne 'windows-upgrade-acceptance.ps1'){continue}
  $key=$frame.FunctionName+':'+$frame.ScriptLineNumber;if($seen.ContainsKey($key)){continue};$seen[$key]=$true
  $framesOut+=,@{function=$frame.FunctionName;source_basename=$basename;source_line=$frame.ScriptLineNumber}
 }
 $primaryException=$Failure.Exception;$deep=$primaryException
 for($depth=0;$depth -lt 7 -and $deep.InnerException;$depth++){$deep=$deep.InnerException}
 if($deep.InnerException){return $null}
 $types=@('IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','PathTooLongException','NotSupportedException','ArgumentException','InvalidOperationException','SecurityException','RuntimeException','MethodInvocationException','ActionPreferenceStopException','ItemNotFoundException','ProviderInvocationException','Win32Exception')
 $kind=$primaryException.GetType().Name;if($kind -cnotin $types){$kind='OtherError'};$baseKind=$deep.GetType().Name;if($baseKind -cnotin $types){$baseKind='OtherError'}
 $hr=[int]$deep.HResult;$code=$null
 if($deep -is [ComponentModel.Win32Exception] -and $deep.NativeErrorCode -ge 0 -and $deep.NativeErrorCode -le 65535){$code=[int]$deep.NativeErrorCode}elseif(([long]$hr -band 4294901760) -eq 2147942400){$code=[int]($hr -band 65535)}
 return UpgradeHashFailureFields @{schema=1;category=$category;file_label=$label;error_type=$kind;base_error_type=$baseKind;hresult=[int]$primaryException.HResult;base_hresult=$hr;win32_code=$code;frames=$framesOut}
}
