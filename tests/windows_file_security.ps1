param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
# Source/compiled-flag controls only: never invokes a native file setter.
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw 'A raw file-security source control failed.'};$script:checks++}
$windows=Join-Path $SourceRoot 'packaging/windows';$helper=Join-Path $windows 'File-Security.ps1'
foreach($name in 'File-Security.ps1','Support-Recovery.ps1','Backup-Control.ps1','Install-Backups.ps1','Install-Updater.ps1','Upgrade-LegacyWindows.ps1'){
 $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $windows $name),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
}
. $helper
Initialize-OpenWebRawFileSecurity
Check ([OpenWebPbx.RawFileSecurityV1]::FileAccessMask($false) -eq 786432)
Check ([OpenWebPbx.RawFileSecurityV1]::FileAccessMask($true) -eq 17563648)
Check (([OpenWebPbx.RawFileSecurityV1]::FileAccessMask($false) -band 16777216) -eq 0)
$payload=[byte[]]@(1,2,3,4);$stream=[OpenWebPbx.RawFileSecurityV1]::SecurityStream($payload)
Check ($stream.Length -eq 24 -and [BitConverter]::ToUInt32($stream,0) -eq 3 -and [BitConverter]::ToUInt32($stream,4) -eq 2)
Check ([BitConverter]::ToInt64($stream,8) -eq 4 -and [BitConverter]::ToUInt32($stream,16) -eq 0)
Check ([Convert]::ToBase64String($stream,20,4) -ceq 'AQIDBA==' -and [Convert]::ToBase64String($payload) -ceq 'AQIDBA==')
$stream=[OpenWebPbx.RawFileSecurityV1]::SecurityStream((New-Object byte[] 262144));Check ($stream.Length -eq 262164 -and [BitConverter]::ToInt64($stream,8) -eq 262144)
foreach($bad in @($null,([byte[]]@()),(New-Object byte[] 262145))){
 $refused=$false;try{$null=[OpenWebPbx.RawFileSecurityV1]::SecurityStream($bad)}catch{$refused=$true};Check $refused
}
$source=Get-Content -LiteralPath $helper -Raw
Check ($source.Contains('WriteSecurity(path,descriptor,length,saclPresent)'))
Check ($source.Contains('LocalFree(descriptor)') -and $source.Contains('token.Dispose()') -and $source.Contains('previous.Count-1'))
Check ($source.Contains('error!=0') -and $source.Contains('SeRestorePrivilege') -and $source.Contains('if(hasSacl) Enable("SeSecurityPrivilege")'))
foreach($forbidden in 'SetKernelObjectSecurity','SetNamedSecurityInfoW(','SetFileSecurityW(','SetSecurityDescriptorSddlForm','CommonAcl','Set-Acl'){Check (!$source.Contains($forbidden))}
Check ($source.Contains('hasSacl?0x01000000u:0u') -and $source.Contains('Get-Acl -LiteralPath $path -Audit'))
Check ($source.Contains('CreateFileW(path,FileAccessMask(hasSacl),7,IntPtr.Zero,3,0x02200000u,IntPtr.Zero)'))
Check ($source.Contains('BackupWrite(file,IntPtr.Zero,0,out ignored,true,true,ref context)') -and $source.Contains('if(pinned.IsAllocated)pinned.Free()') -and $source.Contains('file_security_backup_cleanup'))
Check ($source.IndexOf('$actual=if($lease.HasSacl)') -lt $source.LastIndexOf('if($lease){try{$lease.Dispose()}'))
Check ($source.Contains('ExceptionDispatchInfo.Capture(primary).Throw()') -and $source.Contains('file_security_privilege_cleanup') -and $source.Contains('file_security_buffer_cleanup'))
$primary=New-Object IO.IOException 'private primary marker';$cleanup=New-Object ComponentModel.Win32Exception 5,'private cleanup marker'
[OpenWebPbx.RawFileSecurityV1]::RecordPrivilegeCleanup($primary,(New-Object Reflection.TargetInvocationException $cleanup))
Check ($primary.Message -ceq 'private primary marker' -and $primary.Data.Count -eq 2)
Check ($primary.Data['file_security_privilege_cleanup_type'] -ceq 'Win32Exception' -and $primary.Data['file_security_privilege_cleanup_code'] -eq 5)
Check (!(($primary.Data|ConvertTo-Json -Compress).Contains('private cleanup marker')))
Check ($source.Contains('[string]::Equals($actual,$Sddl,[StringComparison]::Ordinal)'))
foreach($bad in @(@('','O:SY'),@('C:\fixture',''),@('C:\fixture',('x'*131073)),@(('C:\fixture'+[char]0),'O:SY'))){
 $refused=$false
 try{$lease=[OpenWebPbx.RawFileSecurityV1]::Apply($bad[0],$bad[1]);$lease.Dispose()}catch{$refused=$true;Check (!$_.Exception.Message.Contains(('x'*64)))}
 Check $refused
}
$supportPath=Join-Path $windows 'Support-Recovery.ps1';$support=Get-Content -LiteralPath $supportPath -Raw
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($supportPath,[ref]$tokens,[ref]$errors)
$sort=$ast.Find({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Sort-Object'},$true)
Check ($null -ne $sort)
$permissions=@(
 @{Path='C:\owned\deep\file';Directory=$false;Depth=4},@{Path='C:\owned\deep';Directory=$true;Depth=3},
 @{Path='C:\owned\root-file';Directory=$false;Depth=3},@{Path='C:\owned';Directory=$true;Depth=2})
$ordered=@(& ([scriptblock]::Create('$permissions|'+$sort.Extent.Text)))
Check (($ordered.Path -join '|') -ceq 'C:\owned|C:\owned\deep|C:\owned\root-file|C:\owned\deep\file')
Check ($support.Contains('Set-OpenWebFileSddl -LiteralPath $permission.Path -Sddl $permission.Sddl'))
Check ($support.Contains("Collections.Generic.List[object]") -and $support.Contains('$permissions.Add(') -and !$support.Contains('$permissions+='))
Check ($support.Contains('Set-Acl -LiteralPath $taskFile -AclObject $acl'))
$backup=Get-Content -LiteralPath (Join-Path $windows 'Backup-Control.ps1') -Raw
Check ($backup.Contains('Set-OpenWebFileSddl -LiteralPath $path -Sddl $entry.Value'))
Check ($backup.Contains('$path=OrdinaryPath $entry.Name') -and $support.Contains('$target=Check-SupportPath $entry.Name'))
foreach($name in 'Support-Recovery.ps1','Backup-Control.ps1','Install-Backups.ps1','Install-Updater.ps1','Upgrade-LegacyWindows.ps1'){
 Check ((Get-Content -LiteralPath (Join-Path $windows $name) -Raw).Contains('File-Security.ps1'))
}
$installer=Get-Content -LiteralPath (Join-Path $windows 'Install-Backups.ps1') -Raw
Check (@([regex]::Matches($installer,'\$PackageRoot\\File-Security\.ps1')).Count -eq 2)
$upgrade=Get-Content -LiteralPath (Join-Path $windows 'Upgrade-OpenWebPBX.ps1') -Raw
Check ($upgrade.Contains('CopyTree "$root\tools" "$backup\tools"') -and $upgrade.Contains('CopyTree "$Backup\tools" "$root\tools" -Mirror'))
[Console]::Out.WriteLine((@{state='passed';checks=$script:checks;mode='source_compile_flags_only';native_setter_executed=$false}|ConvertTo-Json -Compress))
