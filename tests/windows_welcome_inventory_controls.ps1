#Requires -Version 7.4
# Actual two-layer failure projections; no installed service or PBX actions.
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Welcome observation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return($Value|ConvertTo-Json -Depth 16|ConvertFrom-Json -AsHashtable)}
function Inventory(){return @{schema=1;public_equal=$false;config_equal=$true;config_check='after_refusal';baseline_state='matched';sample_state='matched';before_tables=2;after_tables=2;changed_tables=1;added_tables=0;removed_tables=0;unlisted_tables=0;tables=@(@{name='v_users';before=1;after=1;kind='changed'})}}
function Primary(){return @{schema=1;error_type='RuntimeError';source_basename='windows_welcome_native.py';source_line=100}}
function Failure(){return @{active_case='native_welcome_inline_qr_config_actual_loopback';welcome_phase='cleanup';welcome_error_type='RuntimeException';welcome_source_basename='windows_welcome_native.php';welcome_source_line=90;welcome_sqlstate='none';welcome_cleanup_failed=$true;welcome_cleanup_inventory=(Inventory);welcome_primary=(Primary);message='PRIVATE_NEVER_COPY'}}
foreach($pair in @(@('windows-native-acceptance.ps1','SmtpFailureFields'),@('windows-suite.ps1','SafeSmtpFailureFields'))){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $pair[0]),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 foreach($name in @('SafeWelcomeInventory','SafeWelcomePrimary',$pair[1])){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text}
 $filter=$pair[1];$good=Inventory
 Check ($null -ne (SafeWelcomeInventory $good));Check ($null -ne (SafeWelcomeInventory ($good|ConvertTo-Json -Depth 12|ConvertFrom-Json)))
 foreach($key in @($good.Keys)){
  foreach($bad in @($null,'PRIVATE_NEVER_COPY',@{},1.5)){$copy=Clone $good;$copy[$key]=$bad;Check ($null -eq (SafeWelcomeInventory $copy))}
  $copy=Clone $good;$copy.Remove($key);Check ($null -eq (SafeWelcomeInventory $copy))
 }
 foreach($key in 'schema','before_tables','after_tables','changed_tables','added_tables','removed_tables','unlisted_tables'){
  foreach($bad in $true,-1,1025){$copy=Clone $good;$copy[$key]=$bad;Check ($null -eq (SafeWelcomeInventory $copy))}
 }
 foreach($key in 'public_equal','config_equal'){foreach($bad in 0,1,'true'){$copy=Clone $good;$copy[$key]=$bad;Check ($null -eq (SafeWelcomeInventory $copy))}}
 $copy=Clone $good;$copy.message='PRIVATE_NEVER_COPY';Check ($null -eq (SafeWelcomeInventory $copy))
 foreach($field in 'name','kind','before','after'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_COPY',1000001){$copy=Clone $good;$copy.tables[0][$field]=$bad;Check ($null -eq (SafeWelcomeInventory $copy))}
 }
 foreach($change in @(@{sample_state='unavailable'},@{baseline_state='unstable'},@{config_check='unavailable'},@{public_equal=$true},@{changed_tables=0},@{unlisted_tables=1},@{after_tables=3},@{added_tables=1},@{removed_tables=1})){
  $copy=Clone $good;foreach($key in $change.Keys){$copy[$key]=$change[$key]};Check ($null -eq (SafeWelcomeInventory $copy))
 }
 $copy=Clone $good;$copy.tables=@($copy.tables[0],$copy.tables[0]);$copy.changed_tables=2;Check ($null -eq (SafeWelcomeInventory $copy))
 $copy=Clone $good;$copy.tables[0].kind='added';$copy.tables[0].before=0;Check ($null -eq (SafeWelcomeInventory $copy))
 $copy=Clone $good;$copy.tables=@();$copy.changed_tables=0;$copy.baseline_state='unavailable';$copy.before_tables=0;Check ($null -ne (SafeWelcomeInventory $copy))
 $copy=Clone $good;$copy.tables=@(@{name='v_users';before=1;after=0;kind='removed'});$copy.changed_tables=2;$copy.added_tables=1;$copy.removed_tables=1;$copy.unlisted_tables=1;Check ($null -ne (SafeWelcomeInventory $copy))
 $primary=Primary;Check ($null -ne (SafeWelcomePrimary $primary))
 foreach($key in @($primary.Keys)){
  foreach($bad in $null,$true,'PRIVATE_NEVER_COPY',1.5){$copy=Clone $primary;$copy[$key]=$bad;Check ($null -eq (SafeWelcomePrimary $copy))}
  $copy=Clone $primary;$copy.Remove($key);Check ($null -eq (SafeWelcomePrimary $copy))
 }
 $copy=Clone $primary;$copy.message='PRIVATE_NEVER_COPY';Check ($null -eq (SafeWelcomePrimary $copy))
 foreach($bad in 0,100001){$copy=Clone $primary;$copy.source_line=$bad;Check ($null -eq (SafeWelcomePrimary $copy))}
 $safe=&$filter (Failure);Check ($safe.Count -eq 8);Check ($safe.welcome_cleanup_inventory.tables.Count -eq 1 -and $safe.welcome_primary.error_type -ceq 'RuntimeError');Check (($safe|ConvertTo-Json -Depth 16) -cnotmatch 'PRIVATE_NEVER_COPY|message|sha256|password')
 foreach($bad in $false,'true',1,$null){$copy=Failure;$copy.welcome_cleanup_failed=$bad;$safe=&$filter $copy;Check (!$safe.ContainsKey('welcome_cleanup_inventory') -and !$safe.ContainsKey('welcome_primary'))}
 $copy=Failure;$copy.active_case='native_other';Check ((&$filter $copy).Count -eq 0)
 $copy=Failure;$copy.welcome_cleanup_inventory.message='PRIVATE_NEVER_COPY';$safe=&$filter $copy;Check ($safe.Count -eq 7 -and $safe.ContainsKey('welcome_primary') -and !$safe.ContainsKey('welcome_cleanup_inventory'))
 $copy=Failure;$copy.welcome_primary.message='PRIVATE_NEVER_COPY';$safe=&$filter $copy;Check ($safe.Count -eq 7 -and $safe.ContainsKey('welcome_cleanup_inventory') -and !$safe.ContainsKey('welcome_primary'))
 foreach($name in 'SafeWelcomeInventory','SafeWelcomePrimary'){
  $original=(Get-Command $name).ScriptBlock;Set-Item -LiteralPath ('Function:'+ $name) -Value {param($Record)throw 'PRIVATE_NEVER_COPY'}
  $safe=&$filter (Failure);Check ($safe.Count -eq 7 -and $safe.welcome_cleanup_failed -eq $true);Check (($safe|ConvertTo-Json -Depth 16) -cnotmatch 'PRIVATE_NEVER_COPY')
  Set-Item -LiteralPath ('Function:'+ $name) -Value $original
 }
}
@{state='passed';checks=$checks;actual_both_parent_functions=$true;no_external_actions=$true}|ConvertTo-Json -Compress
