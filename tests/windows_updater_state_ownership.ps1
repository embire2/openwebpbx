#Requires -Version 5.1
# Source-only fictional-file control. Never invoke an installer/upgrade entrypoint.
[CmdletBinding()]
param([string]$OriginalSourceRoot,[switch]$DisposableHostedRunner,[switch]$ExecuteReviewedFictionalControl,[string]$ContractPath,[switch]$SystemChild)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function StateCheck([bool]$Value){if(!$Value){throw 'The isolated updater-state control refused.'}}
function StateHash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function StateJson([string]$Path,$Value){$b=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12));$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($b,0,$b.Length)}finally{$f.Dispose()}}
function StateNoLinks([string]$Path){for($p=[IO.Path]::GetFullPath($Path);$p;$p=Split-Path -Parent $p){if(Test-Path -LiteralPath $p){StateCheck (!((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))};$next=Split-Path -Parent $p;if(!$next -or $next -eq $p){break}}}
function StatePrivateDirectory([string]$Path){StateCheck (!(Test-Path -LiteralPath $Path));[void][IO.Directory]::CreateDirectory($Path);$a=[Security.AccessControl.DirectorySecurity]::new();$a.SetAccessRuleProtection($true,$false);$a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));foreach($sid in 'S-1-5-18','S-1-5-32-544'){$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $Path -AclObject $a;StateNoLinks $Path}
function StateOriginalFunctions([string]$Directory){
 $pins=@{'Install-Updater.ps1'='424cb87eb459ab43f69765565439c8023dac40e8510cc2e5ec1d34d7d27c1309';'Upgrade-OpenWebPBX.ps1'='7b55dc223ea5f55dca117a972fe7c9ed2c5085ac661347382ddf22ce672d8bf3';'Support-Recovery.ps1'='ec701f33807cb67a0865654f621504a8c47662087968fc0a88efdb3e5b7ae49d'}
 $loaded=@{}
 foreach($name in $pins.Keys){$file=Join-Path $Directory $name;StateNoLinks $file;StateCheck ((StateHash $file) -ceq $pins[$name]);$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);StateCheck ($errors.Count -eq 0)
  if($name -eq 'Support-Recovery.ps1'){continue}
  $functionName=if($name -eq 'Install-Updater.ps1'){'SaveState'}else{'WriteState'};$className=if($name -eq 'Install-Updater.ps1'){'OpenWebUpdaterCommit'}else{'OpenWebUpdateState'}
  $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $functionName},$true));StateCheck ($functions.Count -eq 1)
  $types=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class '+$className)},$true));StateCheck ($types.Count -eq 1 -and !($className -as [type]))
  Add-Type -TypeDefinition $types[0].Value -ErrorAction Stop
  $loaded[$functionName]=@{function=([ScriptBlock]::Create($functions[0].Extent.Text));function_sha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($functions[0].Extent.Text)))).Replace('-','').ToLowerInvariant();pinvoke_sha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($types[0].Value)))).Replace('-','').ToLowerInvariant()}
 };return $loaded
}
function StateFunctionEvidence($Value){return @{function_sha256=$Value.function_sha256;pinvoke_sha256=$Value.pinvoke_sha256}}
function StateFileRecord([string]$Path){$b=[IO.File]::ReadAllBytes($Path);$a=Get-Acl -LiteralPath $Path;$d=[Security.AccessControl.RawSecurityDescriptor]::new($a.Sddl);return @{bytes=$b.Length;sha256=(StateHash $Path);base64=[Convert]::ToBase64String($b);owner=$d.Owner.Value;sddl=$a.Sddl;descriptor_base64=[Convert]::ToBase64String($a.GetSecurityDescriptorBinaryForm())}}
function StateTaskMatches($Task,[string]$Name,[string]$Arguments,[string]$Directory){
 if(!$Task){return $false};try{$account=[Security.Principal.NTAccount]::new([string]$Task.Principal.UserId);$principalSid=$account.Translate([Security.Principal.SecurityIdentifier]).Value}catch{if([string]$Task.Principal.UserId -ceq 'S-1-5-18'){$principalSid='S-1-5-18'}else{return $false}}
 return ($Task.TaskName -ceq $Name -and $Task.TaskPath -ceq '\' -and $Task.Description -ceq 'Isolated fictional updater-state ACL control.' -and $principalSid -ceq 'S-1-5-18' -and [string]$Task.Principal.LogonType -ceq 'ServiceAccount' -and [string]$Task.Principal.RunLevel -ceq 'Highest' -and @($Task.Actions).Count -eq 1 -and $Task.Actions.Execute -ceq "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -and $Task.Actions.Arguments -ceq $Arguments -and $Task.Actions.WorkingDirectory -ceq $Directory)
}
StateCheck ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and $ExecuteReviewedFictionalControl)
$env:PSModulePath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$sid=$identity.User.Value
if($SystemChild){
 StateCheck ($sid -ceq 'S-1-5-18' -and $ContractPath);StateNoLinks $ContractPath;StateCheck ((Get-Item -LiteralPath $ContractPath).Length -le 32768)
 $c=Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8|ConvertFrom-Json
 StateCheck ($c.schema -eq 1 -and $c.execute_authorized -is [bool] -and $c.execute_authorized -and $c.parent_hosted_verified -eq $true -and $c.scope -cmatch '^[a-f0-9]{24}$' -and $c.run_id -cmatch '^[0-9]+$' -and $c.expected_computer -ceq $env:COMPUTERNAME -and $c.task_name -ceq ('OW-QA-Updater-State-'+$c.scope))
 $work=[IO.Path]::GetFullPath($c.private_root);StateCheck ([IO.Path]::GetFileName($work) -ceq ('ow-qa-updater-state-'+$c.scope) -and [IO.Path]::GetFullPath($ContractPath) -ceq (Join-Path $work 'contract.json') -and [IO.Path]::GetFullPath($PSCommandPath) -ceq (Join-Path $work 'control.ps1') -and (StateHash $PSCommandPath) -ceq $c.script_sha256);StateNoLinks $work
 $expectedArguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $work 'control.ps1')+'" -ContractPath "'+(Join-Path $work 'contract.json')+'" -ExecuteReviewedFictionalControl -SystemChild';StateCheck ($c.task_arguments -ceq $expectedArguments)
 $task=Get-ScheduledTask -TaskName $c.task_name;StateCheck (StateTaskMatches $task $c.task_name $c.task_arguments $work)
 $functions=StateOriginalFunctions (Join-Path $work 'sources');. $functions.WriteState.function
 $after=@{}
 foreach($name in 'default.json','explicit.json'){$f=Join-Path $work ('fixture\'+$name);StateNoLinks $f;StateCheck (Test-Path -LiteralPath $f -PathType Leaf);$value=Get-Content -LiteralPath $f -Raw -Encoding UTF8|ConvertFrom-Json;WriteState $f $value;$after[$name]=StateFileRecord $f}
 StateJson (Join-Path $work 'system-result.json') @{schema=1;system_sid=$sid;process_id=$PID;native_version=$PSVersionTable.PSVersion.ToString();source=(StateFunctionEvidence $functions.WriteState);after=$after;state='completed'}
 exit 0
}
StateCheck ($DisposableHostedRunner -and $sid -cne 'S-1-5-18' -and $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_REPOSITORY -ceq 'embire2/openwebpbx' -and $env:GITHUB_RUN_ID -cmatch '^[0-9]+$' -and $env:RUNNER_TEMP)
StateCheck ([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
$os=Get-CimInstance Win32_OperatingSystem;StateCheck ($os.ProductType -ne 1 -and $os.Caption -match 'Windows Server 2025' -and [Environment]::OSVersion.Version.Build -ge 26100)
StateCheck (!(Test-Path 'C:\OpenWebPBX') -and !(Test-Path (Join-Path $env:ProgramData 'OpenWebPBX\installation.json')))
$base=[IO.Path]::GetFullPath($env:RUNNER_TEMP);StateNoLinks $base;$scope=[Guid]::NewGuid().ToString('N').Substring(0,24);$work=Join-Path $base ('ow-qa-updater-state-'+$scope);$taskName='OW-QA-Updater-State-'+$scope;$taskOwned=$false;$fixtureGone=$false;$taskGone=$false;$primary=$null;$safe=$null
$beforeTaskNames=@(Get-ScheduledTask|ForEach-Object { $_.TaskPath+$_.TaskName }|Sort-Object);StateCheck (!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue));StatePrivateDirectory $work
try{
 $sources=Join-Path $work 'sources';StatePrivateDirectory $sources
 $sourceBefore=@{};foreach($n in 'Install-Updater.ps1','Upgrade-OpenWebPBX.ps1','Support-Recovery.ps1'){$original=Join-Path $OriginalSourceRoot $n;StateNoLinks $original;$sourceBefore[$n]=StateHash $original;Copy-Item -LiteralPath $original -Destination (Join-Path $sources $n)}
 $scriptFile=Join-Path $work 'control.ps1';Copy-Item -LiteralPath $PSCommandPath -Destination $scriptFile
 $functions=StateOriginalFunctions $sources;. $functions.SaveState.function
 $fixture=Join-Path $work 'fixture';StatePrivateDirectory $fixture;$before=@{}
 foreach($name in 'default.json','explicit.json'){$f=Join-Path $fixture $name;SaveState $f @{Version='1.0.13';Executable='fictional-updater.exe'}
  if($name -ceq 'explicit.json'){$a=Get-Acl -LiteralPath $f;$a.SetAccessRuleProtection($true,$true);$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),'Read','Allow'));Set-Acl -LiteralPath $f -AclObject $a}
  $before[$name]=StateFileRecord $f;StateCheck ($before[$name].owner -cne 'S-1-5-18')
 }
 StateJson (Join-Path $work 'before.private.json') @{schema=1;caller_sid=$sid;source=(StateFunctionEvidence $functions.SaveState);source_files=$sourceBefore;before=$before}
 $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptFile+'" -ContractPath "'+(Join-Path $work 'contract.json')+'" -ExecuteReviewedFictionalControl -SystemChild'
 StateJson (Join-Path $work 'contract.json') @{schema=1;execute_authorized=$true;parent_hosted_verified=$true;scope=$scope;run_id=$env:GITHUB_RUN_ID;expected_computer=$env:COMPUTERNAME;private_root=$work;script_sha256=(StateHash $scriptFile);task_name=$taskName;task_arguments=$arguments}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments -WorkingDirectory $work;$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew) -Description 'Isolated fictional updater-state ACL control.'|Out-Null;$taskOwned=$true
 StateCheck (StateTaskMatches (Get-ScheduledTask -TaskName $taskName) $taskName $arguments $work);Start-ScheduledTask -TaskName $taskName
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 do{$t=Get-ScheduledTask -TaskName $taskName;$info=Get-ScheduledTaskInfo -TaskName $taskName;if((Test-Path (Join-Path $work 'system-result.json')) -and $t.State -ne 'Running'){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $deadline)
 StateCheck ((Test-Path (Join-Path $work 'system-result.json')) -and $t.State -ne 'Running' -and $info.LastTaskResult -eq 0)
 $result=Get-Content -LiteralPath (Join-Path $work 'system-result.json') -Raw -Encoding UTF8|ConvertFrom-Json;StateCheck ($result.state -ceq 'completed' -and $result.system_sid -ceq 'S-1-5-18' -and $result.native_version -match '^5\.1\.' -and $result.process_id -gt 0)
 $observed=@{}
 foreach($name in 'default.json','explicit.json'){$after=StateFileRecord (Join-Path $fixture $name);$r=$result.after.PSObject.Properties[$name].Value;StateCheck ($after.sha256 -ceq $before[$name].sha256 -and $after.base64 -ceq $before[$name].base64 -and $after.sddl -ceq $r.sddl -and $after.owner -ceq $r.owner -and $after.descriptor_base64 -ceq $r.descriptor_base64);$observed[$name]=@{bytes_equal=$true;owner_equal=($after.owner -ceq $before[$name].owner);sddl_equal=($after.sddl -ceq $before[$name].sddl);raw_descriptor_equal=($after.descriptor_base64 -ceq $before[$name].descriptor_base64);system_owner=($after.owner -ceq 'S-1-5-18')}}
 StateJson (Join-Path $work 'after.private.json') $result
 foreach($n in $sourceBefore.Keys){StateCheck ((StateHash (Join-Path $OriginalSourceRoot $n)) -ceq $sourceBefore[$n] -and (StateHash (Join-Path $sources $n)) -ceq $sourceBefore[$n])}
 StateCheck ($result.source.function_sha256 -ceq $functions.WriteState.function_sha256 -and $result.source.pinvoke_sha256 -ceq $functions.WriteState.pinvoke_sha256)
 $safe=@{schema=1;state='observed';fictional_files=2;parent_administrator_not_system=$true;actual_child_system=$true;task_result=0;source_functions_only=$true;source_files_unchanged=$true;observations=$observed;runtime=$PSVersionTable.PSVersion.ToString();product_or_service_operations=$false;remote_owner_access=$false}
}catch{$primary=$_}finally{
 try{
  if($taskOwned){$task=Get-ScheduledTask -TaskName $taskName;StateCheck (StateTaskMatches $task $taskName $arguments $work);if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName;$stopDeadline=[DateTime]::UtcNow.AddSeconds(10);do{$task=Get-ScheduledTask -TaskName $taskName;if($task.State -ne 'Running'){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $stopDeadline);StateCheck ($task.State -ne 'Running')};Unregister-ScheduledTask -TaskName $taskName -Confirm:$false;$taskGone=!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)}
  if($fixture -and (Test-Path -LiteralPath $fixture)){StateNoLinks $fixture;$entries=@(Get-ChildItem -LiteralPath $fixture -Force);StateCheck ($entries.Count -eq 2 -and @($entries|Where-Object {$_.PSIsContainer -or $_.Name -cnotin @('default.json','explicit.json') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count -eq 0);foreach($e in $entries){Remove-Item -LiteralPath $e.FullName};Remove-Item -LiteralPath $fixture;$fixtureGone=!(Test-Path -LiteralPath $fixture)}
  $afterTaskNames=@(Get-ScheduledTask|ForEach-Object {$_.TaskPath+$_.TaskName}|Sort-Object);StateCheck (@(Compare-Object $beforeTaskNames $afterTaskNames).Count -eq 0)
 }catch{if(!$primary){$primary=$_}}
}
if($primary){Write-Output '{"schema":1,"state":"failed","raw_evidence_retained_privately":true}';exit 1}
StateCheck ($taskGone -and $fixtureGone);$safe.own_task_removed=$taskGone;$safe.fixture_files_removed=$fixtureGone;$safe.original_task_name_inventory_equal=$true;StateJson (Join-Path $work 'result.safe.json') $safe;$safe|ConvertTo-Json -Depth 6 -Compress
