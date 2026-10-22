# QA-only retained original snapshot/task implementation from 64cc76ece.
# Executed as an old-source negative; never a qualification implementation.
function OldFileSnapshot([switch]$Protected,[ValidateSet('unobserved','before_fault_full','before_fault_protected','after_fault_full','after_normal_protected')][string]$Stage='unobserved'){
 $script:qualificationFailedHash=$null
 $directories=if($Protected){@($configuration,"$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build")}else{@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots",$configuration,"$engine\conf","$engine\scripts","$engine\mod","$engine\sounds","$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build")}
 $entries=@{}
 foreach($parent in $root,"$root\updater",$state,$engine){Check (!(Get-Item $parent).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A linked parent cannot be audited.';$entries[$parent]=@{directory=$true;acl=(Get-Acl $parent).Sddl}}
 foreach($directory in $directories){if(!(Test-Path -LiteralPath $directory)){continue};foreach($item in @(Get-Item -LiteralPath $directory -Force)+@(Get-ChildItem -LiteralPath $directory -Recurse -Force)){Check (!$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A linked fixture cannot be audited.';$record=@{directory=[bool]$item.PSIsContainer;acl=(Get-Acl -LiteralPath $item.FullName).Sddl};if(!$item.PSIsContainer){$record.sha256=SnapshotHash $item.FullName $Stage;$record.bytes=$item.Length};$entries[$item.FullName]=$record}}
 $paths=@("$state\runtime.json","$state\phone-tls.json","$state\native-engine.json","$state\local-codec.json","$root\php\php.ini","$root\php\extras\ssl\openssl.cnf","$root\php\extras\ssl\cacert.pem","$engine\libbcg729.dll")
 if(!$Protected){$paths+=@("$state\installation.json","$state\updater-install.json")}
 foreach($path in $paths){if(Test-Path -LiteralPath $path){$item=Get-Item -LiteralPath $path;Check (!$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A private audited file must be regular.';$entries[$path]=@{directory=$false;acl=(Get-Acl -LiteralPath $path).Sddl;sha256=(SnapshotHash $path $Stage);bytes=$item.Length}}}
 return $entries
}
function OldTaskSnapshot {
 $result=@{};$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 # The owned interactive manager re-registers its task when each new window
 # loads. Its exact user/action/security contract is checked separately; static
 # service tasks must preserve their complete XML/COM/file security inventory.
 $names=@('OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
 foreach($name in $names){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if(!$task){$result[$name]=@{exists=$false};continue};$xml=[xml](Export-ScheduledTask -TaskName $name);$xml.PreserveWhitespace=$false
  $result[$name]=@{exists=$true;enabled=[bool]$task.Settings.Enabled;xml=$xml.OuterXml;acl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$name))).Sddl;security=$scheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)}
 };return $result
}
