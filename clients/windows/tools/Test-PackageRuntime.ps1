# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,[Parameter(Mandatory)][string]$Report)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:RUNNER_OS-cne 'Windows' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows runtime component is allowed.'}
$client=Split-Path $PSScriptRoot -Parent;$repo=Split-Path (Split-Path $client -Parent) -Parent;$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\');$Report=[IO.Path]::GetFullPath($Report)
if([IO.Path]::GetDirectoryName($Report)-ine $temp -or [IO.Path]::GetFileName($Report)-cne 'windows-phone-package-runtime.json' -or (Test-Path -LiteralPath $Report)){throw 'A new fixed runtime report is required.'}
Push-Location $repo;try{if((git rev-parse HEAD).Trim()-cne $SourceCommit -or (git status --porcelain)){throw 'Exact clean committed runtime source is required.'}}finally{Pop-Location}
for($p=[IO.DirectoryInfo]::new($temp);$p;$p=$p.Parent){if(!$p.Exists -or ($p.Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Runtime temporary ancestry is not ordinary.'}}
$nonce=[Guid]::NewGuid().ToString('N');$root=Join-Path $temp ('phone-package-runtime-'+$nonce);if(Test-Path -LiteralPath $root){throw 'Runtime root must be new.'};$created=$false;$failure=$null;$before=$null;$native=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $client 'tests/packaging/RuntimeReceipt.ps1')
. (Join-Path $client 'tests/packaging/NativeReaderSelection.ps1')
$result=[ordered]@{schema=1;producer='Test-PackageRuntime.ps1';source_commit=$SourceCommit;state='incomplete';actual_native_windows=$true;certificate_mutation=$false;package_installation=$false;process_environment_changed=$false;acl_preserved=$false;exact_owned_cleanup=$false;observations=@()}
try{
 [void][IO.Directory]::CreateDirectory($root);$created=$true;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($root),$acl);$before=(Get-Acl -LiteralPath $root).Sddl
 foreach($mode in @('Ambient','Stock')){
  $info=[Diagnostics.ProcessStartInfo]::new($native);$info.WorkingDirectory=[Environment]::SystemDirectory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $client 'tests/packaging/RuntimeProbe.ps1'),'-Mode',$mode,'-Nonce',$nonce,'-Root',$root,'-ParentShellRoot',$PSHOME)){[void]$info.ArgumentList.Add($argument)}
  $p=[Diagnostics.Process]::Start($info);$when=$p.StartTime.ToUniversalTime();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
  try{
   if(!$p.WaitForExit(30000)){throw 'Runtime child exceeded deadline.'};$text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();if($text.Length-gt 65536 -or $errorText.Length-gt 65536 -or $p.ExitCode-notin @(0,1)){throw 'Runtime child output or exit differs.'}
   $path=Join-Path $root ('runtime-'+$mode.ToLowerInvariant()+'.json');$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer -or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint) -or $item.Length-gt 16384){throw 'An ordinary bounded runtime observation is required.'};$view=ReadPackageRuntimeReceipt (Get-Content -LiteralPath $path -Raw) $mode $p.ExitCode
   $result.observations+=,[ordered]@{mode=$mode;child_exit_code=$p.ExitCode;observation=$view}
  }finally{if(!$p.HasExited){if($p.StartTime.ToUniversalTime()-ne $when -or $p.MainModule.FileName-ine $native){throw 'Runtime child identity changed.'};$p.Kill($true);if(!$p.WaitForExit(10000)){throw 'Runtime child did not stop.'}};$p.Dispose()}
 }
 # Observe the exact current package enumeration and numeric selection without
 # building, trusting or executing a native dependency reader.
 $selectionSource=Join-Path $client 'tools/Test-ClientPackage.ps1';$tokens=$null;$errors=$null;$selectionAst=[Management.Automation.Language.Parser]::ParseFile($selectionSource,[ref]$tokens,[ref]$errors);if($errors){throw 'Native reader selection source does not parse.'}
 $enumeration=@($selectionAst.FindAll({param($node)$node-is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath-ceq 'folder' -and $node.Extent.Text.Contains('$readers+=@(Get-ChildItem -Path $pattern -File -ErrorAction Stop)')},$true));$selection=@($selectionAst.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Extent.Text-ceq '$reader=SelectPackageNativeReader $readers'},$true));if($enumeration.Count-ne 1 -or $selection.Count-ne 1){throw 'Native reader selection source is not unique.'}
 $readers=@();. ([scriptblock]::Create($enumeration[0].Extent.Text));$result.native_import_reader_selection=ReadPackageNativeReaderObservation ((GetPackageNativeReaderObservation $readers)|ConvertTo-Json -Depth 5 -Compress)
 $result.native_import_reader_preflight_accepted=$false;try{. ([scriptblock]::Create($selection[0].Extent.Text));$result.native_import_reader_selected_version=(GetPackageNativeReaderVersion $reader.VersionInfo).ToString();$result.native_import_reader_preflight_accepted=$true}catch{if($_.Exception.Message-cnotin @('An ordinary bounded installed native dependency reader is required.','Native reader numeric resource version is missing or invalid.','The native dependency reader version is ambiguous.')){throw}}
 $result.state='observed';$result.acl_preserved=(Get-Acl -LiteralPath $root).Sddl-ceq $before;if(!$result.acl_preserved){throw 'Owned runtime ACL changed.'}
}catch{$failure=$_;$result.state='failed';$result.error_type=$_.Exception.GetType().Name;$result.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
 if($created){try{if($before){$result.acl_preserved=(Get-Acl -LiteralPath $root).Sddl-ceq $before};$item=Get-Item -LiteralPath $root -Force;if(!$item.PSIsContainer -or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Runtime cleanup root differs.'};foreach($item in Get-ChildItem -LiteralPath $root -Recurse -Force){if($item.PSIsContainer -or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint) -or $item.Name-cnotmatch '^runtime-(ambient|stock)\.json$' -or $item.Length-gt 16384){throw 'Runtime cleanup found an unowned entry.'}};Remove-Item -LiteralPath $root -Recurse -Force;$result.exact_owned_cleanup=!(Test-Path -LiteralPath $root)}catch{$result.cleanup_error=$_.Exception.GetType().Name;$result.state='failed'}}
 try{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 12));$f=[IO.File]::Open($Report,'CreateNew','Write','None');try{$f.Write($bytes);$f.Flush($true)}finally{$f.Dispose()}}catch{if($failure){try{$failure.Exception.Data['receipt_write_failed']=$true}catch{}}else{$failure=$_}}
}
if($failure){throw $failure};if($result.state-cne 'observed' -or !$result.acl_preserved -or !$result.exact_owned_cleanup){throw 'Runtime observation incomplete.'}
