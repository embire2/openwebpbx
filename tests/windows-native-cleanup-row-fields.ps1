function Get-NativeCleanupRowFields($Row){
 $safe=@{}
 if(($Row.schema -isnot [int] -and $Row.schema -isnot [long]) -or $Row.schema -ne 1 -or $Row.state -isnot [string]){return $safe}
 if($Row.state -ceq 'unavailable'){
  if($Row.error_kind -is [string] -and $Row.error_kind -cin 'timeout','unavailable'){return @{schema=1;state='unavailable';error_kind=$Row.error_kind}}
  return $safe
 }
 if($Row.state -cne 'observed' -or $Row.read_only -isnot [bool] -or !$Row.read_only -or $Row.all_tables_queried -isnot [bool] -or !$Row.all_tables_queried -or $Row.counts_capped -isnot [bool]){return $safe}
 foreach($bound in @(@('tables_checked',1,512),@('leftover_tables',0,512),@('leftover_rows',0,1000000))){$v=$Row.($bound[0]);if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt $bound[1] -or $v -gt $bound[2]){return $safe}}
 if($Row.leftover_tables -gt $Row.tables_checked -or ($Row.leftover_tables -eq 0) -ne ($Row.leftover_rows -eq 0)){return $safe}
 $categories=@('cdr','history','health','queue','jobs','mail','callback','domain','other');$rowCategories=$Row.categories
 $keys=if($rowCategories -is [Collections.IDictionary]){@($rowCategories.Keys)}elseif($null -ne $rowCategories -and $rowCategories.GetType() -eq [Management.Automation.PSCustomObject]){@($rowCategories.PSObject.Properties.Name)}else{return $safe}
 if($keys.Count -ne $categories.Count -or @($keys|Where-Object {$_ -cnotin $categories}).Count){return $safe}
 $closed=@{};$sum=0L
 foreach($key in $categories){$v=$rowCategories.$key;if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt 0 -or $v -gt 1000000){return $safe};$closed[$key]=$v;$sum+=$v}
 if([Math]::Min(1000000,$sum) -ne $Row.leftover_rows){return $safe}
 return @{schema=1;state='observed';read_only=$true;all_tables_queried=$true;tables_checked=$Row.tables_checked;leftover_tables=$Row.leftover_tables;leftover_rows=$Row.leftover_rows;counts_capped=$Row.counts_capped;categories=$closed}
}
function Get-NativeCleanupDrainFailureFields($Row){
 $safe=@{}
 $properties=if($Row -is [Collections.IDictionary]){@($Row.Keys)}elseif($null -ne $Row -and $Row.GetType() -eq [Management.Automation.PSCustomObject]){@($Row.PSObject.Properties.Name)}else{return $safe}
 foreach($required in 'schema','producer','state','stage','reason','error_type','source_basename','source_line','child_exit_code'){if($required -cnotin $properties){return $safe}}
 if(($Row.schema -isnot [int] -and $Row.schema -isnot [long]) -or $Row.schema -ne 1 -or $Row.producer -isnot [string] -or $Row.producer -cne 'windows-native-cleanup-drain.php' -or $Row.state -isnot [string] -or $Row.state -cne 'failed'){return $safe}
 $enums=@{stage=@('input_scope','bootstrap','spool_configuration','pre_owned_inventory','owned_service_lookup','owned_channels','spool_path','spool_inventory','spool_import','spool_quiet');reason=@('input_scope','runner_scope','input_path','pre_owned_not_idle','pre_owned_spool_present','owned_service_missing','channel_inventory','channel_identity','channel_timeout','spool_path','spool_inventory','foreign_spool_record','import_refused','spool_timeout','other');error_type=@('RuntimeException','InvalidArgumentException','PDOException','JsonException','Error','TypeError','ValueError','ErrorException','Exception','external_error');source_basename=@('windows-native-cleanup-drain.php','windows-native-cleanup-rows.php','pbx_call_records.php','settings.php','require.php','database.php','event_socket.php','config.php','external_component')}
 foreach($key in $enums.Keys){$value=$Row.$key;if($value -isnot [string] -or $value -cnotin $enums[$key]){return @{}};$safe[$key]=$value}
 foreach($bound in @(@('source_line',1,100000),@('child_exit_code',1,255))){$value=$Row.($bound[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $bound[1] -or $value -gt $bound[2]){return @{}};$safe[$bound[0]]=$value}
 foreach($key in 'input_scope_validated','owned_service_validated','spool_directory_exists','spool_directory_link','spool_expected_engine_log','configured_log_setting_present','native_log_authenticated','native_log_observed','configured_matches_native_log','native_log_spool_directory_exists'){
  if($key -cin $properties){if($Row.$key -isnot [bool]){return @{}};$safe[$key]=$Row.$key}
 }
 if('configured_spool_kind' -cin $properties){if($Row.configured_spool_kind -isnot [string] -or $Row.configured_spool_kind -cnotin 'legacy_posix_path','native_engine_log','other'){return @{}};$safe.configured_spool_kind=$Row.configured_spool_kind}
 $safe.schema=1;$safe.producer='windows-native-cleanup-drain.php';$safe.state='failed';return $safe
}
