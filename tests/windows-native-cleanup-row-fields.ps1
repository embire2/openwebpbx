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
