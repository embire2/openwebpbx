# Test-only definitions. No service, native API, SQL, or configuration is changed.
function Get-NativeRestartPrefix($Stream,[long]$Offset){
 $count=[int][Math]::Min($Offset,128);[void]$Stream.Seek($Offset-$count,[IO.SeekOrigin]::Begin);$bytes=New-Object byte[] $count;$read=0
 while($read -lt $count){$n=$Stream.Read($bytes,$read,$count-$read);if(!$n){throw 'Restart log prefix unavailable.'};$read+=$n}
 $hash=[Security.Cryptography.SHA256]::Create();try{return [Convert]::ToBase64String($hash.ComputeHash($bytes))}finally{$hash.Dispose()}
}
function New-NativeRestartWindow([string]$LogPath){
 $window=@{observed=$false;utc=[DateTime]::UtcNow.ToString('o')}
 try{$item=Get-Item -LiteralPath $LogPath -ErrorAction Stop;if(!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){$stream=[IO.File]::Open($LogPath,'Open','Read',[IO.FileShare]'ReadWrite,Delete');try{$window.offset=[long]$stream.Length;$window.prefix=Get-NativeRestartPrefix $stream $window.offset;$window.observed=$true}finally{$stream.Dispose()}}}catch{}
 return $window
}
function Test-NativeOriginalBytes([string]$Saved,[string]$Current,[bool]$Present){
 # Copy-Item snapshots are private; compare bytes/relative names, never serialize them.
 function Inventory([string]$Path){
  $rows=@{}
  function Visit([string]$Path,[string]$Relative,[int]$Depth){
   if($Depth -gt 4 -or $rows.Count -ge 64){throw 'Bounded original inventory exceeded.'}
   $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Original inventory link refused.'}
   if($item.PSIsContainer){$rows[$Relative]='directory';foreach($child in $item.GetFileSystemInfos()){Visit $child.FullName ($Relative+'/'+$child.Name) ($Depth+1)}}
   else{if($item.Length -gt 4MB){throw 'Bounded original file exceeded.'};$hash=[Security.Cryptography.SHA256]::Create();try{$stream=[IO.File]::Open($item.FullName,'Open','Read',[IO.FileShare]'ReadWrite,Delete');try{$rows[$Relative]=[Convert]::ToBase64String($hash.ComputeHash($stream))}finally{$stream.Dispose()}}finally{$hash.Dispose()}}
  }
  Visit $Path '' 0;return $rows
 }
 if(!$Present){return $null -eq (Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue)}
 $a=Inventory $Saved;$b=Inventory $Current
 if($a.Count -ne $b.Count){return $false};foreach($key in $a.Keys){if(!$b.ContainsKey($key) -or $a[$key] -cne $b[$key]){return $false}};return $true
}
function Get-NativeRestartObservation($Window,[string]$LogPath,[string]$Evidence,$Failure,$OriginalFiles,$OriginalPresent,[string]$Saved){
 $safe=@{native_restart_observer=$true;native_restart_window_observed=$false}
 $types=@();$hresults=@();$codes=@();$exceptionNode=$Failure.Exception
 for($i=0;$exceptionNode -and $i -lt 4;$i++){
  $type=$exceptionNode.GetType().Name;if($type -cin 'ServiceCommandException','InvalidOperationException','Win32Exception','IOException','Exception','RuntimeException','ActionPreferenceStopException'){$types+=,$type}
  $hresults+=,[int]$exceptionNode.HResult
  if($exceptionNode -is [ComponentModel.Win32Exception] -and $exceptionNode.NativeErrorCode -ge 0 -and $exceptionNode.NativeErrorCode -le 65535){$codes+=,[int]$exceptionNode.NativeErrorCode};$exceptionNode=$exceptionNode.InnerException
 }
 $safe.native_restart_exception_types=@($types);$safe.native_restart_hresults=@($hresults);$safe.native_restart_win32_codes=@($codes)
 try{[IO.File]::WriteAllText((Join-Path $Evidence 'native-restart-error.private.txt'),($Failure|Format-List * -Force|Out-String),[Text.UTF8Encoding]::new($false))}catch{}
 $labels=@{'fusion-config.conf'='fusion_config';'phone-tls.json'='phone_tls_metadata';'phone-tls'='phone_tls_directory';'mobile-notifications-config'='notification_config';'mobile-notifications-lock'='notification_lock';'php-cacert'='php_cacert'}
 foreach($label in $labels.Keys){if($OriginalPresent.ContainsKey($label)){try{$safe['native_restart_original_'+$labels[$label]+'_bytes_equal']=Test-NativeOriginalBytes (Join-Path $Saved $label) $OriginalFiles[$label] $OriginalPresent[$label]}catch{}}}
 try{
  if(!$Window.observed){return $safe};$item=Get-Item -LiteralPath $LogPath -ErrorAction Stop
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -lt $Window.offset){return $safe}
  $stream=[IO.File]::Open($LogPath,'Open','Read',[IO.FileShare]'ReadWrite,Delete')
  try{if((Get-NativeRestartPrefix $stream $Window.offset) -cne $Window.prefix){return $safe};[void]$stream.Seek($Window.offset,[IO.SeekOrigin]::Begin);$count=[int][Math]::Min($stream.Length-$Window.offset,1MB);$bytes=New-Object byte[] $count;$read=0;while($read -lt $count){$n=$stream.Read($bytes,$read,$count-$read);if(!$n){break};$read+=$n}}finally{$stream.Dispose()}
  if($read -lt $count){$bytes=if($read){$bytes[0..($read-1)]}else{[byte[]]@()}}
  [IO.File]::WriteAllBytes((Join-Path $Evidence 'native-restart-window.private.log'),$bytes)
  [IO.File]::WriteAllText((Join-Path $Evidence 'native-restart-window.private.json'),($Window|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  $safe.native_restart_window_observed=$true;$safe.native_restart_log_offset=[long]$Window.offset;$safe.native_restart_log_bytes=[int]$read;$safe.native_restart_log_truncated=($item.Length-$Window.offset -gt 1MB)
  $text=[Text.Encoding]::UTF8.GetString($bytes);$patterns=[ordered]@{xml_root_unavailable='Cannot Open log directory or XML Root!';xml_file_parse_error='Error Parsing File \[';xml_parse_error='\[error near line [0-9]+\]';module_load_error='(?im)(error loading|failed to load|module load[^\r\n]*fail)';tls_error='(?im)((TLS|SSL)[^\r\n]*(fail|error)|error loading[^\r\n]*cert)'}
  $safe.native_restart_log_categories=@(foreach($key in $patterns.Keys){if($text -match $patterns[$key]){$key}})
  $sources=@('switch_xml.c','switch_core.c','switch_core_config.c','switch_loadable_module.c','mod_sofia.c','sofia.c','tport.c','tport_tls.c');$locations=@()
  foreach($match in [regex]::Matches($text,'(?m)^[^\r\n]{0,100}\[(?:ERR|CRIT|ALERT|EMERG)\]\s+([A-Za-z0-9_]+\.c):([0-9]{1,7})(?![0-9])')){if($match.Groups[1].Value -cin $sources -and [long]$match.Groups[2].Value -ge 1 -and [long]$match.Groups[2].Value -le 1000000){$locations+=,@{source_basename=$match.Groups[1].Value;source_line=[int]$match.Groups[2].Value};if($locations.Count -ge 8){break}}}
  $safe.native_restart_log_locations=@($locations)
  $match=[regex]::Match($text,'\[error near line ([0-9]{1,7})\]');if($match.Success -and [int]$match.Groups[1].Value -ge 1 -and [int]$match.Groups[1].Value -le 1000000){$safe.native_restart_xml_line=[int]$match.Groups[1].Value}
  $match=[regex]::Match($text,'Error Parsing File \[([^\]\r\n]{1,512})\]');if($match.Success){$name=[IO.Path]::GetFileName($match.Groups[1].Value.Replace('\','/'));$safe.native_restart_xml_basename=if($name -cin 'freeswitch.xml','vars.xml','freeswitch.xml.fsxml','sofia.conf.xml','event_socket.conf.xml','modules.conf.xml','lua.conf.xml','internal.xml','external.xml'){$name}else{'external_component'}}
 }catch{}
 return $safe
}
