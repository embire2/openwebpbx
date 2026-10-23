#Requires -RunAsAdministrator
# Disposable GHA component ONLY. No installed task/service/IIS/DB/firewall writes.
param([Parameter(Mandatory)][string]$SourceBundle,[Parameter(Mandatory)][string]$SourceManifest,[Parameter(Mandatory)][string]$SourceManifestSha256,[Parameter(Mandatory)][string]$PhpDirectory,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_phone_catalogue_proof.ps1')
# Desktop Process.Start children do not use the parent Core module inventory.
# Resolve only the actual Windows stock modules; never alter PSModulePath.
function Assert-CatalogueStockOrdinary([string]$Path){
 if(![IO.File]::Exists($Path) -and ![IO.Directory]::Exists($Path)){throw 'A stock module input is absent.'}
 for($item=[IO.FileInfo]::new($Path);$null -ne $item;){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Stock module ancestry must be ordinary.'}
  if($item -is [IO.DirectoryInfo]){$item=$item.Parent}else{$item=$item.Directory}
 }
}
function Get-CatalogueStockProvenance($Command,[ValidateSet('Utility','Security')][string]$Kind,[string]$NativeHome,[string]$WindowsRoot){
 $moduleName='Microsoft.PowerShell.'+$Kind;$folder=[IO.Path]::Combine($NativeHome,'Modules', $moduleName);$manifest=[IO.Path]::Combine($folder,$moduleName+'.psd1')
 $proof=[ordered]@{command_type=$false;command_name=$false;module_name=$false;module_path=$false;module_base=$false;module_version=$false;module_guid=$false;source_file=$false;implementation=$false}
 if($Kind -ceq 'Utility'){
  $proof.command_type=$Command -is [Management.Automation.FunctionInfo]
  if(!$proof.command_type){return $proof}
  $scriptFile=[IO.Path]::Combine($folder,$moduleName+'.psm1')
  $proof.command_name=$Command.Name -ceq 'Get-FileHash';$proof.module_name=$Command.ModuleName -ceq $moduleName
  # Qualified lookup returns the nested script module; visible lookup returns
  # its stock manifest export. Both must retain the exact same script source.
  $nested=$Command.Module.Path -ieq $scriptFile;$export=$Command.Module.Path -ieq $manifest
  $proof.module_path=$nested -or $export;$proof.module_base=$Command.Module.ModuleBase -ieq $NativeHome
  $proof.module_version=($nested -and $Command.Module.Version -eq [version]'0.0') -or ($export -and $Command.Module.Version -eq [version]'3.1.0.0')
  $proof.module_guid=($nested -and $Command.Module.Guid -eq [Guid]::Empty) -or ($export -and $Command.Module.Guid -eq [Guid]'1da87e53-152b-403e-98dc-74d7b4d63d59')
  $proof.source_file=$Command.ScriptBlock.File -ieq $scriptFile
  $proof.implementation=$Command.ScriptBlock.Ast.Extent.File -ieq $scriptFile
 }else{
  $proof.command_type=$Command -is [Management.Automation.CmdletInfo]
  if(!$proof.command_type){return $proof}
  $assembly=$Command.ImplementingType.Assembly;$name=$assembly.GetName();$location=$assembly.Location
  $proof.command_name=$Command.Name -ceq 'Get-Acl';$proof.module_name=$Command.ModuleName -ceq $moduleName
  $proof.module_path=$Command.Module.Path -ieq $manifest
  $proof.module_base=$Command.Module.ModuleBase -ieq $NativeHome -or $Command.Module.ModuleBase -ieq [IO.Path]::GetDirectoryName($location)
  $proof.module_version=$Command.Module.Version -eq [version]'3.0.0.0';$proof.module_guid=$Command.Module.Guid -eq [Guid]'a94c8c7e-9810-47c0-b8af-65089c13a35a'
  $proof.source_file=$location.StartsWith($WindowsRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
  $token=([BitConverter]::ToString($name.GetPublicKeyToken())).Replace('-','').ToLowerInvariant()
  $proof.implementation=$Command.ImplementingType.FullName -ceq 'Microsoft.PowerShell.Commands.GetAclCommand' -and $name.Name -ceq $moduleName -and $name.Version -eq [version]'3.0.0.0' -and $token -ceq '31bf3856ad364e35'
 }
 return $proof
}
function Assert-CatalogueStockProvenance($Proof){
 $fields=@('command_type','command_name','module_name','module_path','module_base','module_version','module_guid','source_file','implementation')
 if($Proof -isnot [Collections.IDictionary] -or $Proof.Count -ne $fields.Count){throw 'Stock command provenance has an invalid shape.'}
 foreach($field in $fields){if($Proof[$field] -isnot [bool] -or !$Proof[$field]){throw 'The exact stock command provenance differs.'}}
}
function Import-CatalogueDesktopStockModules {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -cne 'Desktop'){throw 'This stock bootstrap requires Windows PowerShell.'}
 $nativeHome=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0');$windows=[Environment]::GetFolderPath('Windows')
 foreach($kind in 'Utility','Security'){
  $moduleName='Microsoft.PowerShell.'+$kind;$folder=[IO.Path]::Combine($nativeHome,'Modules',$moduleName);$manifest=[IO.Path]::Combine($folder,$moduleName+'.psd1')
  Assert-CatalogueStockOrdinary $manifest
  if($kind -ceq 'Utility'){Assert-CatalogueStockOrdinary ([IO.Path]::Combine($folder,$moduleName+'.psm1'))}
  Import-Module -Name $manifest -Global -Force -ErrorAction Stop
  $commandName=if($kind -ceq 'Utility'){'Get-FileHash'}else{'Get-Acl'}
  $commands=@(Get-Command -Name ($moduleName+'\'+$commandName) -All -ErrorAction Stop)
  if($commands.Count -ne 1){throw 'The stock command is absent or ambiguous.'}
  $command=$commands[0];Assert-CatalogueStockProvenance (Get-CatalogueStockProvenance $command $kind $nativeHome $windows)
  Assert-CatalogueStockOrdinary $command.Module.ModuleBase;Assert-CatalogueStockOrdinary $command.Module.Path
  if($kind -ceq 'Security'){Assert-CatalogueStockOrdinary $command.ImplementingType.Assembly.Location}
  # All following unchanged fixture/product calls must resolve to this stock source.
  $visible=Get-Command -Name $commandName -ErrorAction Stop
  Assert-CatalogueStockProvenance (Get-CatalogueStockProvenance $visible $kind $nativeHome $windows)
 }
}
$phase='preflight';$work=$null;$reportOwned=$false;$childrenClosed=$true;$taskRemoved=$true;$vectorsExact=$false;$successRecord=$null
try{
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or ![Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$env:RUNNER_TEMP){throw 'This component is restricted to disposable Windows GitHub Actions.'}
$runner=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($path in $SourceBundle,$PhpDirectory,$ReportPath){if(![IO.Path]::GetFullPath($path).StartsWith($runner,[StringComparison]::OrdinalIgnoreCase)){throw 'Every component path must stay in the disposable runner namespace.'}}
foreach($path in $runner,$SourceBundle,$PhpDirectory,$ReportPath){if($path.Contains("'") -or $path -match '[\x00-\x1f]'){throw 'The fixture literal path requires review.'}}
if(Test-Path -LiteralPath $ReportPath){throw 'Never replace an existing component receipt.'};$reportOwned=$true
if($PSVersionTable.PSEdition -ceq 'Desktop'){Import-CatalogueDesktopStockModules}
if((Get-FileHash -LiteralPath $SourceManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SourceManifestSha256){throw 'The source manifest changed.'}
$sourcePins=Get-Content -LiteralPath $SourceManifest -Raw|ConvertFrom-Json
foreach($entry in $sourcePins.files.PSObject.Properties){$path=Join-Path $SourceBundle $entry.Name;$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $entry.Value.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value.sha256){throw 'An exact component source changed.'}}
. (Join-Path $SourceBundle 'packaging/windows/WindowsPhoneCatalogue.Common.ps1')
. (Join-Path $SourceBundle 'packaging/windows/PhpRuntime.Common.ps1')
$phase='preparation';$nonce=[Guid]::NewGuid().ToString('N');$work=Join-Path $env:RUNNER_TEMP ('OpenWebPBX-Catalogue-QA-'+$nonce);$root=Join-Path $work 'case';$taskName='OpenWebPBX-Catalogue-QA-'+$nonce
if(Test-Path -LiteralPath $work){throw 'Never reuse a fixture.'};$null=New-Item -ItemType Directory -Path $work;Set-OpenWebRecoveryPrivate $work -Directory
foreach($path in $root,(Join-Path $root 'tools'),(Join-Path $root 'state'),(Join-Path $root 'web'),(Join-Path $root 'web/resources'),(Join-Path $root 'web/resources/windows-phone'),(Join-Path $root 'package')){$null=New-Item -ItemType Directory -Path $path;Set-OpenWebRecoveryPrivate $path -Directory}
if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($root)).DriveFormat -cne 'NTFS'){throw 'Actual NTFS is required.'}
$cases=[Collections.Generic.List[string]]::new();$children=[Collections.Generic.List[object]]::new();$phase='initialization';$primary=$null;$lock=$null;$taskOwned=$false;$preservationRecorded=$false
function Check([string]$Name,[bool]$Ok){if(!$Ok){throw ('Catalogue component control refused: '+$Name)};if($cases.Contains($Name)){throw 'A component case repeated.'};$cases.Add($Name)}
function Refused([scriptblock]$Body){$refused=$false;try{& $Body|Out-Null}catch{$refused=$true};return $refused}
function PrivateFile([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false));Set-OpenWebRecoveryPrivate $Path}
function ShaText([string]$Text){$hash=[Security.Cryptography.SHA256]::Create();try{return([BitConverter]::ToString($hash.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}}
function Inventory([string]$Path){
 $rows=[ordered]@{};$items=@(Get-Item -LiteralPath $Path -Force)+@(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
 if($items.Count -gt 10000){throw 'The component inventory exceeds its bound.'}
 foreach($item in $items){$null=Assert-OpenWebRecoveryProtected $item.FullName -Directory:$item.PSIsContainer;$name=$item.FullName.Substring($Path.Length).TrimStart('\').Replace('\','/');$rows[$name]=[ordered]@{directory=[bool]$item.PSIsContainer;attributes=[int]$item.Attributes;sddl=(Get-Acl -LiteralPath $item.FullName).Sddl};if(!$item.PSIsContainer){$rows[$name].bytes=$item.Length;$rows[$name].sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}
 return ($rows|ConvertTo-Json -Depth 8 -Compress -WarningAction Stop)
}
function Originals {
 $record=[ordered]@{services=@();files=@();tasks=@()}
 foreach($name in 'OpenWebPBX-Database','OpenWebPBX','FreeSWITCH','OpenWebPBXUpdater','W3SVC','sshd'){$s=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'") -OperationTimeoutSec 5;$record.services+=,[ordered]@{name=$name;exists=[bool]$s;state=if($s){[string]$s.State}else{''};start=if($s){[string]$s.StartMode}else{''};pid=if($s){[long]$s.ProcessId}else{0L};created=if($s -and $s.ProcessId){(Get-Process -Id $s.ProcessId).StartTime.ToUniversalTime().Ticks}else{0L}}}
 foreach($path in 'C:\OpenWebPBX\web\VERSION','C:\OpenWebPBX\server\OpenWebPbx.Server.dll',(Join-Path $env:ProgramData 'OpenWebPBX/installation.json'),(Join-Path $env:ProgramData 'OpenWebPBX/runtime.json'),(Join-Path $env:ProgramData 'fusionpbx/config.conf')){$exists=Test-Path -LiteralPath $path -PathType Leaf;$record.files+=,[ordered]@{path=$path;exists=[bool]$exists;sha256=if($exists){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''};sddl=if($exists){(Get-Acl -LiteralPath $path).Sddl}else{''};attributes=if($exists){[int](Get-Item -LiteralPath $path -Force).Attributes}else{0}}}
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX-WindowsPhoneCatalogue','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){$t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;$record.tasks+=,[ordered]@{name=$name;exists=[bool]$t;enabled=if($t){[bool]$t.Settings.Enabled}else{$false};xml=if($t){[string](Export-ScheduledTask -TaskName $name)}else{''};security=if($t){$nativeScheduler=New-Object -ComObject Schedule.Service;$nativeScheduler.Connect();[string]$nativeScheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)}else{''}}}
 return ($record|ConvertTo-Json -Depth 8 -Compress -WarningAction Stop)
}
$beforeOriginal=Originals;$beforeSource=Inventory $SourceBundle;Assert-OpenWebPhpTree $PhpDirectory;$beforeRuntime=Inventory $PhpDirectory
PrivateFile (Join-Path $work 'original-before.private.json') $beforeOriginal;PrivateFile (Join-Path $work 'source-before.private.json') $beforeSource;PrivateFile (Join-Path $work 'runtime-before.private.json') $beforeRuntime
$paths=[pscustomobject]@{Root=$root;StateRoot=(Join-Path $root 'state');Directory=(Join-Path $root 'state/windows-phone-catalogue');Php=(Join-Path $PhpDirectory 'php.exe');Ini=(Join-Path $root 'fixture.ini');Runner=(Join-Path $root 'tools/WindowsPhoneCatalogue.ps1');Worker=(Join-Path $root 'tools/windows-phone-catalogue.php');PublicKey=(Join-Path $root 'web/resources/windows-phone/release-public.pem');PowerShell=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')}
$script:FixtureCataloguePaths=$paths
function Get-OpenWebWindowsPhoneCataloguePaths {param([string]$Root,[string]$StateRoot)return $script:FixtureCataloguePaths}
$script:WindowsPhoneCatalogueTask=$taskName
function Get-Date {return [DateTime]::UtcNow.AddYears(5)} # Clock adapter: actual Scheduler trigger stays in the future.
$tools=Join-Path $root 'tools';$package=Join-Path $root 'package';$helperDirectory=Join-Path $SourceBundle 'packaging/windows'
foreach($name in 'UpgradeRecovery.Common.ps1','File-Security.ps1','Restore-Gates.ps1'){Copy-Item -LiteralPath (Join-Path $helperDirectory $name) -Destination (Join-Path $tools $name);Set-OpenWebRecoveryPrivate (Join-Path $tools $name)}
$pathsFile=Join-Path $tools 'paths.json';PrivateFile $pathsFile ($paths|ConvertTo-Json -Depth 4 -Compress)
$quotedPaths=$pathsFile.Replace("'","''")
$commonOriginal=[IO.File]::ReadAllText((Join-Path $helperDirectory 'WindowsPhoneCatalogue.Common.ps1'))
$readerExpression="[Security.Principal.NTAccount]::new('IIS AppPool\OpenWebPBX').Translate([Security.Principal.SecurityIdentifier])"
if(([regex]::Matches($commonOriginal,[regex]::Escape($readerExpression))).Count -ne 1){throw 'The exact fixture-only reader SID expression differs.'}
# The standalone component exercises real ACL APIs with a declared LocalService
# reader SID. It does not start a reader or qualify the installed IIS identity.
$common=$commonOriginal.Replace($readerExpression,"[Security.Principal.SecurityIdentifier]::new('S-1-5-19')")+"`nfunction Get-OpenWebWindowsPhoneCataloguePaths {param([string]`$Root,[string]`$StateRoot);return (Get-Content -LiteralPath '$quotedPaths' -Raw|ConvertFrom-Json)}`n`$script:WindowsPhoneCatalogueTask='$taskName'`n"
PrivateFile (Join-Path $package 'WindowsPhoneCatalogue.Common.ps1') $common
foreach($name in 'WindowsPhoneCatalogue.ps1','Install-WindowsPhoneCatalogue.ps1'){Copy-Item -LiteralPath (Join-Path $helperDirectory $name) -Destination (Join-Path $package $name);Set-OpenWebRecoveryPrivate (Join-Path $package $name)}
Copy-Item -LiteralPath (Join-Path $SourceBundle 'tests/windows_phone_catalogue_native.php') -Destination (Join-Path $package 'windows-phone-catalogue.php');Set-OpenWebRecoveryPrivate (Join-Path $package 'windows-phone-catalogue.php')
foreach($name in 'WindowsPhoneCatalogue.Common.ps1','WindowsPhoneCatalogue.ps1','Install-WindowsPhoneCatalogue.ps1','windows-phone-catalogue.php'){Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $tools $name);Set-OpenWebRecoveryPrivate (Join-Path $tools $name)}
# The parent must use the same exact reviewed reader-SID adapter as its children.
$fixtureCommon=Join-Path $tools 'WindowsPhoneCatalogue.Common.ps1'
if([IO.File]::ReadAllText($fixtureCommon) -cne $common){throw 'The protected fixture Common copy differs.'}
. $fixtureCommon
$library=[IO.File]::ReadAllText((Join-Path $SourceBundle 'packaging/updates/windows-phone-catalogue.php'));$literal="'C:/OpenWebPBX/tools/WindowsPhoneCatalogue.ps1'"
if(([regex]::Matches($library,[regex]::Escape($literal))).Count -ne 1){throw 'The one declared fixture commit-path adapter differs.'}
$adapted=$library.Replace($literal,"'"+$paths.Runner.Replace('\','/').Replace("'","\\'")+"'")
PrivateFile (Join-Path $root 'refresh.fixture.php') $adapted
$openssl=Join-Path $root 'openssl.cnf';Copy-Item -LiteralPath (Join-Path $helperDirectory 'openssl.cnf') -Destination $openssl;Set-OpenWebRecoveryPrivate $openssl;if((Get-FileHash -LiteralPath $openssl -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourcePins.files.'packaging/windows/openssl.cnf'.sha256){throw 'The fixture OpenSSL configuration differs from its original source pin.'}
PrivateFile $paths.Ini ('extension_dir="'+(Join-Path $PhpDirectory 'ext').Replace('\','/')+'"'+"`nextension=openssl`nextension=mbstring`n")
$config=[ordered]@{scope='disposable_github_actions_fixture';runner_temp=$env:RUNNER_TEMP;root=$root.Replace('\','/');catalogue_class=(Join-Path $SourceBundle 'resources/classes/pbx_windows_phone_catalogue.php').Replace('\','/');refresh_library=(Join-Path $root 'refresh.fixture.php').Replace('\','/');clock='2026-10-23T12:00:00Z';openssl_config=$openssl.Replace('\','/');envelope=(Join-Path $root 'envelope-1.json').Replace('\','/')}
function SaveConfig {PrivateFile (Join-Path $tools 'fixture.json') ($config|ConvertTo-Json -Depth 4 -Compress)}
SaveConfig
function StartPhp([string]$Action){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$paths.Php;$start.Arguments='-c "'+$paths.Ini+'" "'+$paths.Worker+'" '+$Action;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($start);$row=[pscustomobject]@{Process=$p;Started=$p.StartTime.ToUniversalTime().Ticks;ErrorTask=$p.StandardError.ReadToEndAsync();Action=$Action;Executable=$paths.Php};$children.Add($row);return $row
}
function FinishPhp($Child,[bool]$Success=$true){
 $p=$Child.Process;$out=$p.StandardOutput.ReadToEndAsync();if(!$p.WaitForExit(60000)){throw 'An exact owned PHP child exceeded its deadline.'}
 if(!$out.Wait(2000) -or !$Child.ErrorTask.Wait(2000) -or $out.Result.Length -gt 32768 -or $Child.ErrorTask.Result.Length -gt 32768){throw 'The component child output exceeded its bound.'}
 $index=$children.IndexOf($Child);PrivateFile (Join-Path $work ('child-'+$index+'.private.out')) $out.Result;PrivateFile (Join-Path $work ('child-'+$index+'.private.err')) $Child.ErrorTask.Result
 if($Success -and ($p.ExitCode -ne 0 -or $Child.ErrorTask.Result.Length)){
  $failure=[InvalidOperationException]::new('The owned PHP operation refused.');$failure.Data['catalogue_php_child_exit']=[int]$p.ExitCode
  try{$failure.Data['catalogue_php_failure']=Read-WindowsPhoneCataloguePhpFailure ($Child.ErrorTask.Result|ConvertFrom-Json -ErrorAction Stop)}catch{$failure.Data['catalogue_php_observation_refused']=$true}
  throw $failure
 }
 return [pscustomobject]@{Exit=$p.ExitCode;Text=$out.Result;Record=if($out.Result.Trim()){$out.Result|ConvertFrom-Json}else{$null}}
}
function Php([string]$Action,[bool]$Success=$true){return (FinishPhp (StartPhp $Action) $Success)}
function ReadyPhp([string]$Action,[string]$Expected){
 $child=StartPhp $Action;$line=$child.Process.StandardOutput.ReadLineAsync();if(!$line.Wait(30000) -or !$line.Result -or $line.Result.Length -gt 4096){if($child.Process.HasExited){$null=FinishPhp $child};throw 'The exact owned child readiness was unavailable.'};$r=$line.Result|ConvertFrom-Json
 if($r.schema -ne 1 -or $r.state -cne 'ready' -or $r.phase -cne $Expected -or $r.pid -ne $child.Process.Id){throw 'The exact owned child readiness differs.'}
 PrivateFile (Join-Path $work ('ready-'+$children.IndexOf($child)+'.private.json')) $line.Result;return $child
}
function KillOwned($Child){$p=$Child.Process;if($p.HasExited -or $p.StartTime.ToUniversalTime().Ticks -ne $Child.Started -or $p.MainModule.FileName -ine $Child.Executable){throw 'Owned child identity changed; no fault injected.'};if(@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$p.Id) -OperationTimeoutSec 5).Count){throw 'An owned child still has descendants; no fault injected.'};$p.Kill();if(!$p.WaitForExit(10000)){throw 'The exact owned child did not terminate.'};$null=FinishPhp $Child $false}
$cache=Join-Path $paths.Directory 'accepted.json';$journal=Join-Path $paths.Directory 'publication.json'
function ReadCache {return (Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json)}
function SetEnvelope([int]$Sequence){$config.envelope=(Join-Path $root ('envelope-'+$Sequence+'.json')).Replace('\','/');SaveConfig}
function PreparedWitness([bool]$Stage){$j=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;if($j.state -cne 'prepared'){throw 'No durable prepared publication; no fault injected.'};$r=Php '--prepared-stage-check';if($Stage -and $r.Record.state -cne 'prepared_stage'){throw 'No complete authenticated stage; no fault injected.'};if(!$Stage -and $r.Record.state -cne 'ready'){throw 'The accepted-rename witness differs; no fault injected.'};return $j}
try{
 $phase='seed';$seed=Php '--seed';Check 'php_crypto_fixture_seeded' ($seed.Record.state -ceq 'seeded' -and $seed.Record.ephemeral_rsa_bits -eq 3072 -and $seed.Record.private_key_persisted -ceq $false)
 $null=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'CreateNew','ReadWrite','None').Dispose();Set-OpenWebRecoveryPrivate (Join-Path $paths.StateRoot 'upgrade.lock')
 $lock=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'Open','ReadWrite','None');Set-OpenWebWindowsPhoneCatalogueDirectory $paths;$lock.Dispose();$lock=$null
 $phase='mutual_exclusion';$held=ReadyPhp '--hold' 'both_leases'
 $blocked=$false;try{$candidate=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'Open','ReadWrite','None');$candidate.Dispose()}catch [IO.IOException]{$blocked=($_.Exception.HResult -band 65535) -in 32,33}
 Check 'php_parent_blocks_dotnet_exclusive' $blocked
 $other=Php '--refresh' $false;Check 'php_parent_blocks_other_php' ($other.Record.state -ceq 'deferred')
 $held.Process.StandardInput.WriteLine('release');$held.Process.StandardInput.Close();$accepted=FinishPhp $held;Check 'parent_commit_uses_real_movefileex' ($accepted.Record.state -ceq 'accepted' -and (ReadCache).sequence -eq 1 -and (Get-Content $journal -Raw|ConvertFrom-Json).state -ceq 'committed')
 $stage=Join-Path $paths.Directory ('.accepted-'+(Get-FileHash $cache -Algorithm SHA256).Hash.ToLowerInvariant()+'.new');Copy-Item $cache $stage
 $probe=Php '--assert-exclusive' $false;$beforeCache=(Get-FileHash $cache -Algorithm SHA256).Hash
 $commitStart=[Diagnostics.ProcessStartInfo]::new();$commitStart.FileName=$paths.PowerShell;$commitStart.Arguments='-NoProfile -NonInteractive -File "'+$paths.Runner+'" -Action Commit -StagePath "'+$stage+'"';$commitStart.UseShellExecute=$false;$commitStart.CreateNoWindow=$true;$commitStart.RedirectStandardOutput=$true;$commitStart.RedirectStandardError=$true
 $commit=[Diagnostics.Process]::Start($commitStart);$co=$commit.StandardOutput.ReadToEndAsync();$ce=$commit.StandardError.ReadToEndAsync();$children.Add([pscustomobject]@{Process=$commit;Started=$commit.StartTime.ToUniversalTime().Ticks;ErrorTask=$ce;Action='commit_without_parent';Executable=$paths.PowerShell});if(!$commit.WaitForExit(30000)){throw 'The exact no-parent commit child timed out.'};PrivateFile (Join-Path $work 'no-parent-commit.private.err') $ce.GetAwaiter().GetResult();Check 'commit_child_refuses_without_parent' ($probe.Exit -ne 0 -and $commit.ExitCode -ne 0 -and (Test-Path $stage) -and (Get-FileHash $cache -Algorithm SHA256).Hash -ceq $beforeCache);Remove-Item -LiteralPath $stage
 $fetchLog=Join-Path $root 'fetches.private.jsonl';$fetchBefore=(Get-FileHash $fetchLog -Algorithm SHA256).Hash
 $lock=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'Open','ReadWrite','None');Assert-OpenWebRecoveryLock $lock $paths.StateRoot;$blockedPhp=Php '--refresh' $false;Check 'dotnet_parent_blocks_php' ($blockedPhp.Exit -ne 0 -and (Get-FileHash $cache -Algorithm SHA256).Hash -ceq $beforeCache -and (Get-FileHash $fetchLog -Algorithm SHA256).Hash -ceq $fetchBefore);$lock.Dispose();$lock=$null
 $again=Php '--refresh';Check 'php_recovers_after_dotnet_release' ($again.Record.state -ceq 'accepted')
 $phase='interruption';SetEnvelope 2;$before=ReadyPhp '--before-rename' 'prepared_complete_stage';$null=PreparedWitness $true;KillOwned $before;Check 'before_rename_child_killed_only_after_prepared_stage' $true;$r=Php '--refresh';Check 'before_rename_recovery_forward' ($r.Record.sequence -eq 2 -and (ReadCache).sequence -eq 2)
 SetEnvelope 3;$after=ReadyPhp '--after-rename' 'accepted_before_committed_journal';$null=PreparedWitness $false;KillOwned $after;Check 'after_rename_child_killed_only_after_prepared_journal' $true;$r=Php '--refresh';Check 'after_rename_recovery_forward' ($r.Record.sequence -eq 3 -and (ReadCache).sequence -eq 3)
 SetEnvelope 4;$expiry=ReadyPhp '--before-rename' 'prepared_complete_stage';$null=PreparedWitness $true;KillOwned $expiry;$config.clock='2028-01-01T00:00:00Z';SaveConfig;$expired=Php '--refresh' $false;$view=Php '--read';Check 'expired_prepared_highwater_unavailable' ($expired.Exit -ne 0 -and (ReadCache).sequence -eq 4 -and $view.Record.version -ceq '')
 SetEnvelope 5;$fresh=Php '--refresh';$view=Php '--read';Check 'fresh_higher_release_after_expired_recovery' ($fresh.Record.sequence -eq 5 -and $view.Record.version -ceq '1.0.4')
 $goodJournal=Get-Content $journal -Raw;$candidate=Get-Content $cache -Raw;$stage=Join-Path $paths.Directory ('.accepted-'+(ShaText $candidate)+'.new');PrivateFile $stage $candidate.Substring(0,$candidate.Length-1);PrivateFile $journal (@{schema=1;component='windows-free-phone';key_id='windows-phone-release-1';state='prepared';previous_sha256=(ShaText $candidate);candidate=$candidate}|ConvertTo-Json -Depth 4 -Compress)
 $partial=(Get-FileHash $stage -Algorithm SHA256).Hash;$reject=Php '--refresh' $false;Check 'partial_stage_preserved' ($reject.Exit -ne 0 -and (Get-FileHash $stage -Algorithm SHA256).Hash -ceq $partial -and (Get-Content $cache -Raw) -ceq $candidate);Remove-Item -LiteralPath $stage;PrivateFile $journal $goodJournal
 # Native task/activation controls follow in the same exact namespace.
 $phase='scheduler';$lock=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'Open','ReadWrite','None')
 $manifestFiles=@{};foreach($name in 'WindowsPhoneCatalogue.Common.ps1','WindowsPhoneCatalogue.ps1','Install-WindowsPhoneCatalogue.ps1','windows-phone-catalogue.php'){$manifestFiles[$name]=(Get-FileHash (Join-Path $package $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
 PrivateFile (Join-Path $package 'release-manifest.json') (@{files=$manifestFiles}|ConvertTo-Json -Depth 4);PrivateFile (Join-Path $package 'VERSION') '1.0.20';PrivateFile (Join-Path $root 'web/VERSION') '1.0.20';PrivateFile (Join-Path $paths.StateRoot 'installation.json') '{"Completed":false,"Version":"1.0.20"}'
 if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'A same-name task already exists; preserve it.'}
 Install-OpenWebWindowsPhoneCatalogue -PackageRoot $package -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock;$taskOwned=$true
 Check 'native_task_staged_disabled' (!(Get-ScheduledTask -TaskName $taskName).Settings.Enabled)
 $baseXml=[string](Export-ScheduledTask -TaskName $taskName);$baseTaskHash=Get-OpenWebWindowsPhoneCatalogueTaskHash $baseXml;$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$baseSecurity=[string]$scheduler.GetFolder('\').GetTask($taskName).GetSecurityDescriptor(7)
 foreach($change in 'action','trigger','principal','settings'){
  [xml]$xml=$baseXml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t',$xml.DocumentElement.NamespaceURI)
  switch($change){'action'{$xml.SelectSingleNode('//t:Exec/t:Arguments',$ns).InnerText+=' -ForeignFixture'}'trigger'{$xml.SelectSingleNode('//t:TimeTrigger/t:StartBoundary',$ns).InnerText='2099-01-01T00:00:00'}'principal'{$xml.SelectSingleNode('//t:Principal/t:RunLevel',$ns).InnerText='LeastPrivilege'}'settings'{$xml.SelectSingleNode('//t:Settings/t:ExecutionTimeLimit',$ns).InnerText='PT9M'}}
  Register-ScheduledTask -TaskName $taskName -Xml $xml.OuterXml -Force|Out-Null;$badXml=[string](Export-ScheduledTask -TaskName $taskName)
  $refused=Refused {Install-OpenWebWindowsPhoneCatalogue -PackageRoot $package -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock}
  Check ('native_task_foreign_'+$change+'_preserved') ($refused -and [string](Export-ScheduledTask -TaskName $taskName) -ceq $badXml)
  if((Get-OpenWebWindowsPhoneCatalogueTaskHash ([string](Export-ScheduledTask -TaskName $taskName))) -cne (Get-OpenWebWindowsPhoneCatalogueTaskHash $badXml)){throw 'The owned tampered fixture changed again; preserve it.'};Register-ScheduledTask -TaskName $taskName -Xml $baseXml -Force|Out-Null;$scheduler.GetFolder('\').GetTask($taskName).SetSecurityDescriptor($baseSecurity,0)
 }
 $badSecurity='D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)';$scheduler.GetFolder('\').GetTask($taskName).SetSecurityDescriptor($badSecurity,0);$observedSecurity=[string]$scheduler.GetFolder('\').GetTask($taskName).GetSecurityDescriptor(7)
 Check 'native_task_foreign_security_preserved' ((Refused {Assert-OpenWebWindowsPhoneCatalogueTask (Get-ScheduledTask -TaskName $taskName) $paths}) -and [string]$scheduler.GetFolder('\').GetTask($taskName).GetSecurityDescriptor(7) -ceq $observedSecurity);$scheduler.GetFolder('\').GetTask($taskName).SetSecurityDescriptor($baseSecurity,0)
 Check 'native_activation_requires_completed_install' ((Refused {Complete-OpenWebWindowsPhoneCatalogueActivation -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock}) -and !(Get-ScheduledTask -TaskName $taskName).Settings.Enabled)
 PrivateFile (Join-Path $paths.StateRoot 'installation.json') '{"Completed":true,"Version":"1.0.20"}';$activation=Join-Path $paths.Directory 'activation.json';$intent=Get-Content $activation -Raw|ConvertFrom-Json;$intent.task_before_exists=$true;$intent.enable_on_commit=$false;Write-OpenWebWindowsPhoneCatalogueState $activation $intent;Complete-OpenWebWindowsPhoneCatalogueActivation -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock
 Check 'native_activation_preserves_disabled_choice' (!(Get-ScheduledTask -TaskName $taskName).Settings.Enabled -and (Get-Content $activation -Raw|ConvertFrom-Json).phase -ceq 'complete')
 $activationScript=Join-Path $tools 'activation-child.ps1'
 $activationBody=@'
param([ValidateSet('before_enable','after_enable','after_complete')][string]$Mode)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. 'COMMON_PATH'
$script:ActualStateWriter=${function:Write-OpenWebWindowsPhoneCatalogueState}
function Checkpoint { [Console]::Out.WriteLine((@{schema=1;state='ready';phase=$Mode;pid=$PID}|ConvertTo-Json -Compress));$line=[Console]::In.ReadLine();if($null -ne $line -and $line -cne 'release'){throw 'The owned checkpoint command differs.'} }
function Enable-ScheduledTask { [CmdletBinding()]param([string]$TaskName)
 if($Mode -ceq 'before_enable'){Checkpoint};ScheduledTasks\Enable-ScheduledTask -TaskName $TaskName|Out-Null;if($Mode -ceq 'after_enable'){Checkpoint}
}
function Write-OpenWebWindowsPhoneCatalogueState {param([string]$Path,$Value)
 & $script:ActualStateWriter -Path $Path -Value $Value
 if($Mode -ceq 'after_complete' -and $Value.phase -ceq 'complete'){Checkpoint}
}
$p=Get-OpenWebWindowsPhoneCataloguePaths
$lease=[IO.File]::Open((Join-Path $p.StateRoot 'upgrade.lock'),'Open','ReadWrite','None')
try{Complete-OpenWebWindowsPhoneCatalogueActivation -Owner install -Root $p.Root -StateRoot $p.StateRoot -MaintenanceLock $lease}finally{$lease.Dispose()}
'@
 PrivateFile $activationScript $activationBody.Replace('COMMON_PATH',(Join-Path $tools 'WindowsPhoneCatalogue.Common.ps1'))
 foreach($position in 'before_enable','after_enable','after_complete'){
  Disable-ScheduledTask -TaskName $taskName|Out-Null;$intent.phase='prepared';$intent.enable_on_commit=$true;Write-OpenWebWindowsPhoneCatalogueState $activation $intent;$lock.Dispose();$lock=$null
  $exe=(Get-Process -Id $PID).Path;$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$activationScript+'" -Mode '+$position;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $childProcess=[Diagnostics.Process]::Start($start);$child=[pscustomobject]@{Process=$childProcess;Started=$childProcess.StartTime.ToUniversalTime().Ticks;ErrorTask=$childProcess.StandardError.ReadToEndAsync();Action=$position;Executable=$exe};$children.Add($child)
  $ready=$childProcess.StandardOutput.ReadLineAsync();if(!$ready.Wait(30000) -or !$ready.Result){throw 'The actual activation checkpoint was unavailable.'};$ack=$ready.Result|ConvertFrom-Json
  $diskIntent=Get-Content $activation -Raw|ConvertFrom-Json;$enabled=[bool](Get-ScheduledTask -TaskName $taskName).Settings.Enabled
  if($ack.schema -ne 1 -or $ack.state -cne 'ready' -or $ack.phase -cne $position -or $ack.pid -ne $childProcess.Id -or ($position -ceq 'before_enable' -and ($enabled -or $diskIntent.phase -cne 'prepared')) -or ($position -ceq 'after_enable' -and (!$enabled -or $diskIntent.phase -cne 'prepared')) -or ($position -ceq 'after_complete' -and (!$enabled -or $diskIntent.phase -cne 'complete'))){throw 'The actual activation witness differs; no fault injected.'}
  PrivateFile (Join-Path $work ('activation-'+$position+'.private.json')) $ready.Result;KillOwned $child
  $lock=[IO.File]::Open((Join-Path $paths.StateRoot 'upgrade.lock'),'Open','ReadWrite','None')
  if($position -ceq 'after_complete'){Disable-ScheduledTask -TaskName $taskName|Out-Null}
  Complete-OpenWebWindowsPhoneCatalogueActivation -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock
  Check ('native_activation_'+$position+'_kill_recovery') ((Get-Content $activation -Raw|ConvertFrom-Json).phase -ceq 'complete' -and [bool](Get-ScheduledTask -TaskName $taskName).Settings.Enabled -ceq ($position -cne 'after_complete'))
 }

 Disable-ScheduledTask -TaskName $taskName|Out-Null;Complete-OpenWebWindowsPhoneCatalogueActivation -Owner install -Root $root -StateRoot $paths.StateRoot -MaintenanceLock $lock;Check 'native_activation_terminal_preserves_admin_choice' (!(Get-ScheduledTask -TaskName $taskName).Settings.Enabled)
 $lock.Dispose();$lock=$null;$config.scheduled_hold=$true;SaveConfig;Enable-ScheduledTask -TaskName $taskName|Out-Null;Start-ScheduledTask -TaskName $taskName
 $scheduledReady=Join-Path $root 'scheduled-ready.private.json';$deadline=[DateTime]::UtcNow.AddSeconds(15)
 while(!(Test-Path -LiteralPath $scheduledReady) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
 if(!(Test-Path -LiteralPath $scheduledReady)){throw 'The exact fixture SYSTEM worker did not become ready.'};$scheduled=Get-Content $scheduledReady -Raw|ConvertFrom-Json
 $nativeProcess=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$scheduled.pid) -OperationTimeoutSec 5
 if(!$nativeProcess -or $nativeProcess.ExecutablePath -ine $paths.Php -or !$nativeProcess.CommandLine.Contains($paths.Worker)){throw 'The scheduled worker identity differs.'}
 $sid=Invoke-CimMethod -InputObject $nativeProcess -MethodName GetOwnerSid -OperationTimeoutSec 5
 Check 'native_scheduled_worker_system_identity' ($sid.ReturnValue -eq 0 -and $sid.Sid -ceq 'S-1-5-18' -and (Get-ScheduledTask -TaskName $taskName).State -ceq 'Running')
 PrivateFile (Join-Path $root 'scheduled-release') 'release';$deadline=[DateTime]::UtcNow.AddSeconds(30)
 while((Get-ScheduledTask -TaskName $taskName).State -ceq 'Running' -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
 if((Get-ScheduledTask -TaskName $taskName).State -ceq 'Running' -or (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -ne 0){throw 'The exact scheduled fixture did not complete.'}
 $config.scheduled_hold=$false;SaveConfig;Disable-ScheduledTask -TaskName $taskName|Out-Null
 Assert-OpenWebWindowsPhoneCatalogueTask (Get-ScheduledTask -TaskName $taskName) $paths;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false;$taskOwned=$false;Check 'native_owned_task_removed_only' (!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))
 $phase='preservation';Assert-OpenWebPhpTree $PhpDirectory;$afterSource=Inventory $SourceBundle;$afterRuntime=Inventory $PhpDirectory;$afterOriginal=Originals
 PrivateFile (Join-Path $work 'source-after.private.json') $afterSource;PrivateFile (Join-Path $work 'runtime-after.private.json') $afterRuntime;PrivateFile (Join-Path $work 'original-after.private.json') $afterOriginal
 Check 'source_runtime_whole_inventory_exact' ($beforeSource -ceq $afterSource -and $beforeRuntime -ceq $afterRuntime);Check 'original_services_files_exact' ($beforeOriginal -ceq $afterOriginal)
 $preservationRecorded=$true;$vectorsExact=$true
 $record=[ordered]@{schema=1;producer='windows_phone_catalogue_native.ps1';state='passed';edition=$PSVersionTable.PSEdition;source_manifest_sha256=$SourceManifestSha256;php_executable_sha256=(Get-FileHash -LiteralPath $paths.Php -Algorithm SHA256).Hash.ToLowerInvariant();checks=$cases.Count;cases=$cases.ToArray();actual_ntfs=$true;actual_php_flock=$true;actual_powershell_exclusive=$true;actual_movefileex=$true;actual_scheduler=$true;actual_system_worker=$true;actual_activation_child_kills=$true;real_primitive_checkpoint_wrappers=$true;path_fetch_clock_taskname_adapters=$true;reader_sid_adapter=$true;ephemeral_rsa_bits=3072;private_key_persisted=$false;whole_source_runtime_exact=$true;original_services_files_tasks_exact=$true;installed_server_changed=$false;iis_or_database_or_firewall_changed=$false;actual_iis_reader_tested=$false;full_upgrade_restore_qualified=$false;production_release_published=$false}
 $successRecord=$record
}catch{
 $primary=$_;throw $primary
}finally{
 if($lock){$lock.Dispose()}
 foreach($child in $children){try{if(!$child.Process.HasExited){if($child.Process.StartTime.ToUniversalTime().Ticks -ne $child.Started -or $child.Process.MainModule.FileName -ine $child.Executable){throw 'Owned child identity changed; preserve evidence.'};$child.Process.Kill();if(!$child.Process.WaitForExit(10000)){throw 'The exact owned child did not stop during cleanup.'}}}catch{$childrenClosed=$false;if(!$primary){throw};$primary.Exception.Data['catalogue_fixture_child_cleanup_failed']=$true};$child.Process.Dispose()}
 if($taskOwned){$taskRemoved=$false;try{
  Assert-OpenWebWindowsPhoneCatalogueTask (Get-ScheduledTask -TaskName $taskName) $paths
  if((Get-ScheduledTask -TaskName $taskName).State -ceq 'Running'){Stop-ScheduledTask -TaskName $taskName}
  $deadline=[DateTime]::UtcNow.AddSeconds(35)
  do{
   $matching=@(Get-CimInstance Win32_Process -Filter "Name='php.exe' OR Name='powershell.exe'" -OperationTimeoutSec 5|Where-Object {$_.CommandLine -and (($_.ExecutablePath -ieq $paths.Php -and $_.CommandLine.Contains($paths.Worker)) -or ($_.ExecutablePath -ieq $paths.PowerShell -and $_.CommandLine.Contains($paths.Runner)))})
   if(!(Get-ScheduledTask -TaskName $taskName).State.Equals('Running') -and !$matching.Count){break};Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow -lt $deadline)
  if($matching.Count -or (Get-ScheduledTask -TaskName $taskName).State -ceq 'Running'){throw 'The exact owned fixture task still has a process; preserve it.'}
  Assert-OpenWebWindowsPhoneCatalogueTask (Get-ScheduledTask -TaskName $taskName) $paths;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false;$taskRemoved=$true;$taskOwned=$false
 }catch{if(!$primary){throw};$primary.Exception.Data['catalogue_fixture_task_cleanup_failed']=$true}}
 if(!$preservationRecorded){try{
  $afterSource=Inventory $SourceBundle;$afterRuntime=Inventory $PhpDirectory;$afterOriginal=Originals
  PrivateFile (Join-Path $work 'source-after.private.json') $afterSource;PrivateFile (Join-Path $work 'runtime-after.private.json') $afterRuntime;PrivateFile (Join-Path $work 'original-after.private.json') $afterOriginal
  if($beforeSource -cne $afterSource -or $beforeRuntime -cne $afterRuntime -or $beforeOriginal -cne $afterOriginal){throw 'The component preservation vectors differ.'};$vectorsExact=$true
 }catch{if(!$primary){throw};$primary.Exception.Data['catalogue_fixture_preservation_failed']=$true}}
 # Retain the complete owned evidence tree for review/artifacts; no recursive removal.
}

 $phase='report';PrivateFile $ReportPath ($successRecord|ConvertTo-Json -Depth 5 -Compress);[Console]::Out.WriteLine(($successRecord|ConvertTo-Json -Depth 5 -Compress))
}catch{
 $failure=$_
 if($reportOwned){try{
  $meta=Get-WindowsPhoneCatalogueFailureMetadata $failure
  $phpExit=$null;$phpFailure=$null
  if($failure.Exception.Data.Contains('catalogue_php_child_exit')){$phpExit=[int]$failure.Exception.Data['catalogue_php_child_exit']}
  if($failure.Exception.Data.Contains('catalogue_php_failure')){$phpFailure=$failure.Exception.Data['catalogue_php_failure']}
  $retained=[bool]($work -and (Test-Path -LiteralPath $work))
  $record=[ordered]@{schema=1;producer='windows_phone_catalogue_native.ps1';state='failed';phase=$phase;source_basename=$meta.source_basename;source_line=$meta.source_line;error_type=$meta.error_type;edition=$PSVersionTable.PSEdition;php_child_exit=$phpExit;php_failure=$phpFailure;child_processes_closed=$childrenClosed;owned_task_removed=$taskRemoved;original_vectors_preserved=$vectorsExact;owned_scope_retained=$retained;cleanup_required=($retained -and !($childrenClosed -and $taskRemoved -and $vectorsExact));actual_native_qualified=$false}
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 8 -Compress));$report=[IO.File]::Open($ReportPath,'CreateNew','Write','None');try{$report.Write($bytes,0,$bytes.Length);$report.Flush($true)}finally{$report.Dispose()}
 }catch{$failure.Exception.Data['catalogue_fixture_failure_report_failed']=$true}}
 throw $failure
}
