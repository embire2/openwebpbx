# Actual read-only observer/filter controls against private ordinary files.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-native-restart-observer.ps1')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Caller source must parse.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'SafeNativeCleanupFields'},$true));if($nodes.Count -ne 1){throw 'Exact filter required.'};Invoke-Expression $nodes[0].Extent.Text
foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeFailureFields'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'Exact caller filter required.'};Invoke-Expression $nodes[0].Extent.Text}
$count=0
function Check([bool]$Value){if(!$Value){throw ('Restart observer control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:count++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('openweb-restart-'+[Guid]::NewGuid().ToString('N'));$saved=Join-Path $root 'saved';$evidence=Join-Path $root 'evidence';[void][IO.Directory]::CreateDirectory($saved);[void][IO.Directory]::CreateDirectory($evidence)
try{
 $names=@('fusion-config.conf','phone-tls.json','phone-tls','mobile-notifications-config','mobile-notifications-lock','php-cacert');$files=@{};$present=@{}
 foreach($name in $names){$files[$name]=Join-Path $root $name;$present[$name]=$true;if($name -ceq 'phone-tls'){[void][IO.Directory]::CreateDirectory($files[$name]);[IO.File]::WriteAllText((Join-Path $files[$name] 'agent.pem'),'PRIVATE_CERTIFICATE')}else{[IO.File]::WriteAllText($files[$name],'PRIVATE_ORIGINAL')};Copy-Item -LiteralPath $files[$name] -Destination (Join-Path $saved $name) -Recurse}
 foreach($name in $names){Check (Test-NativeOriginalBytes (Join-Path $saved $name) $files[$name] $true)}
 Check (Test-NativeOriginalBytes '' (Join-Path $root 'absent') $false);Check (!(Test-NativeOriginalBytes '' $files[$names[0]] $false))
 $log=Join-Path $root 'native.log';[IO.File]::WriteAllText($log,'STALE Cannot Open log directory or XML Root! PRIVATE_OLD'+"`n");$window=New-NativeRestartWindow $log
 Check ($window.observed -and $window.offset -eq (Get-Item $log).Length)
 $exception=[InvalidOperationException]::new('PRIVATE_EXCEPTION',[ComponentModel.Win32Exception]::new(1067));$failure=[Management.Automation.ErrorRecord]::new($exception,'PRIVATE_ID',[Management.Automation.ErrorCategory]::OperationStopped,'PRIVATE_TARGET')
 [IO.File]::AppendAllText($log,"2026-10-15 00:00:00 [NOTICE] ordinary startup PRIVATE_NEW`n")
 $record=Get-NativeRestartObservation $window $log $evidence $failure $files $present $saved
 Check ($record.native_restart_window_observed -and $record.native_restart_log_categories.Count -eq 0 -and $record.native_restart_log_offset -eq $window.offset)
 Check ($record.native_restart_win32_codes.Count -eq 1 -and $record.native_restart_win32_codes[0] -eq 1067 -and [Object]::ReferenceEquals($failure.Exception,$exception))
 Check ([IO.File]::ReadAllText((Join-Path $evidence 'native-restart-window.private.log')).Contains('PRIVATE_NEW') -and ![IO.File]::ReadAllText((Join-Path $evidence 'native-restart-window.private.log')).Contains('PRIVATE_OLD'))
 $window=New-NativeRestartWindow $log
 [IO.File]::AppendAllText($log,"2026-10-15 00:00:01 [ERR] switch_xml.c:1721 Error Parsing File [C:\PRIVATE\vars.xml]`n2026-10-15 00:00:01 [ERR] switch_xml.c:1835 Error[[error near line 73]: PRIVATE_XML]`n2026-10-15 00:00:01 [ERR] PRIVATE_SOURCE.c:19 PRIVATE`n")
 $record=Get-NativeRestartObservation $window $log $evidence $failure $files $present $saved
 Check (($record.native_restart_log_categories -join '|') -ceq 'xml_file_parse_error|xml_parse_error')
 Check ($record.native_restart_xml_basename -ceq 'vars.xml' -and $record.native_restart_xml_line -eq 73 -and $record.native_restart_log_locations.Count -eq 2 -and $record.native_restart_log_locations[0].source_basename -ceq 'switch_xml.c')
 $record.native_cleanup_stage='restart_engine';$record.native_cleanup_reloadxml='success';$record.PRIVATE='PRIVATE_DATA'
 $safe=SafeNativeCleanupFields ([pscustomobject]$record)
 $roundtrip=$record|ConvertTo-Json -Depth 9|ConvertFrom-Json;$caller=SafeFailureFields $roundtrip
 Check ($caller.Count -eq $safe.Count)
 foreach($key in $safe.Keys){if($key -cne 'native_restart_log_locations'){Check (($caller[$key]|ConvertTo-Json -Depth 9) -ceq ($safe[$key]|ConvertTo-Json -Depth 9))}}
 Check ($caller.native_restart_log_locations.Count -eq 2)
 for($i=0;$i -lt 2;$i++){Check ($caller.native_restart_log_locations[$i].source_basename -ceq $safe.native_restart_log_locations[$i].source_basename -and $caller.native_restart_log_locations[$i].source_line -eq $safe.native_restart_log_locations[$i].source_line)}
 Check ([IO.File]::ReadAllText((Join-Path $evidence 'native-restart-error.private.txt')).Contains('PRIVATE_EXCEPTION'))
 Check (($safe|ConvertTo-Json -Depth 9) -notmatch 'PRIVATE|agent.pem|1067.*PRIVATE|utc|creation')
 foreach($key in $record.Keys){if($key -like '*_bytes_equal'){Check ($safe[$key] -eq $true)}}
 Check ($safe.native_cleanup_reloadxml -ceq 'success' -and $safe.native_restart_log_locations.Count -eq 2)
 foreach($label in 'fusion_config','phone_tls_metadata','phone_tls_directory','notification_config','notification_lock','php_cacert'){
  $key='native_restart_original_'+$label+'_bytes_equal';foreach($bad in 'true',1,$null,@{PRIVATE='PRIVATE'}){$copy=@{}+$record;$copy[$key]=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey($key))}
 }
 foreach($pair in @(@('native_restart_log_offset',-1),@('native_restart_log_offset',1099511627777),@('native_restart_log_bytes',1048577),@('native_restart_xml_line',0),@('native_restart_xml_line',1000001))){$copy=@{}+$record;$copy[$pair[0]]=$pair[1];Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey($pair[0]))}
 foreach($field in 'native_restart_log_offset','native_restart_log_bytes','native_restart_xml_line'){foreach($bad in '1',$true,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=@{}+$record;$copy[$field]=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey($field))}}
 foreach($field in 'native_restart_exception_types','native_restart_log_categories'){foreach($bad in @('PRIVATE',@('PRIVATE'),@($true),@('tls_error','PRIVATE'),@(1..9))){$copy=@{}+$record;$copy[$field]=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey($field))}}
 foreach($field in 'native_restart_hresults','native_restart_win32_codes'){foreach($bad in @('1',@('1'),@($true),@(1.5),@(1..5))){$copy=@{}+$record;$copy[$field]=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey($field))}}
 foreach($bad in -1,65536){$copy=@{}+$record;$copy.native_restart_win32_codes=@($bad);Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey('native_restart_win32_codes'))}
 foreach($bad in 'PRIVATE.xml','Vars.xml','../vars.xml','vars.xml ',$true){$copy=@{}+$record;$copy.native_restart_xml_basename=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey('native_restart_xml_basename'))}
 foreach($bad in @(@{source_basename='PRIVATE.c';source_line=1},@{source_basename='switch_xml.c';source_line='1'},@{source_basename='switch_xml.c';source_line=0},@{source_basename='switch_xml.c';source_line=1000001})){$copy=@{}+$record;$copy.native_restart_log_locations=@($bad);Check ((SafeNativeCleanupFields ([pscustomobject]$copy)).native_restart_log_locations.Count -eq 0)}
 foreach($bad in $false,'true',1,$null){$copy=@{}+$record;$copy.native_restart_observer=$bad;Check (@((SafeNativeCleanupFields ([pscustomobject]$copy)).Keys|Where-Object {$_ -like 'native_restart_*'}).Count -eq 0)}
 foreach($stage in 'restore_files','restore_factory','PRIVATE'){$copy=@{}+$record;$copy.native_cleanup_stage=$stage;Check (@((SafeNativeCleanupFields ([pscustomobject]$copy)).Keys|Where-Object {$_ -like 'native_restart_*'}).Count -eq 0)}
 foreach($bad in 'Success','PRIVATE','success ',$true,1,@('success')){$copy=@{}+$record;$copy.native_cleanup_reloadxml=$bad;Check (!(SafeNativeCleanupFields ([pscustomobject]$copy)).ContainsKey('native_cleanup_reloadxml'))}
 [IO.File]::WriteAllText($files['fusion-config.conf'],'DIFFERENT');Check (!(Test-NativeOriginalBytes (Join-Path $saved 'fusion-config.conf') $files['fusion-config.conf'] $true))
 $before=New-NativeRestartWindow $log;[IO.File]::WriteAllText($log,'short');$record=Get-NativeRestartObservation $before $log $evidence $failure $files $present $saved;Check (!$record.native_restart_window_observed)
 Check (!(New-NativeRestartWindow (Join-Path $root 'absent')).observed)
 $window=New-NativeRestartWindow $log;[IO.File]::AppendAllText($log,('z'*1048577));$record=Get-NativeRestartObservation $window $log $evidence $failure $files $present $saved;Check ($record.native_restart_log_truncated -and $record.native_restart_log_bytes -eq 1048576)
 $window=New-NativeRestartWindow $log;[IO.File]::AppendAllText($log,'Error Parsing File [C:\PRIVATE\SECRET.xml]');$record=Get-NativeRestartObservation $window $log $evidence $failure $files $present $saved;Check ($record.native_restart_xml_basename -ceq 'external_component')
 $link=Join-Path $root 'link.log';New-Item -ItemType SymbolicLink -Path $link -Target $log|Out-Null;Check (!(New-NativeRestartWindow $link).observed)
 Check (!(Test-NativeOriginalBytes '' $link $false))
 # A replaced/rotated log with the same length cannot impersonate the old offset.
 $window=New-NativeRestartWindow $log;$oldLength=(Get-Item $log).Length;[IO.File]::WriteAllText($log,('q'*$oldLength));$record=Get-NativeRestartObservation $window $log $evidence $failure $files $present $saved;Check (!$record.native_restart_window_observed)
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
Write-Output "PASS $count actual observer/file/offset/inner-error/closed projection controls; no Windows service or native call"
