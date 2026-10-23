# SPDX-License-Identifier: AGPL-3.0-or-later
# Only the native Windows PowerShell security command; never change PSModulePath.
function AssertPackageNativeSecurityPath([string]$Path){
 if(![IO.File]::Exists($Path) -and ![IO.Directory]::Exists($Path)){throw 'Native security input is absent.'}
 for($entry=[IO.FileInfo]::new($Path);$entry;){if($entry.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Native security input ancestry is linked.'};if($entry-is [IO.DirectoryInfo]){$entry=$entry.Parent}else{$entry=$entry.Directory}}
}
function GetPackageNativeSecurityProvenance($Command,[string]$ParentShellRoot=''){
 $home=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell\v1.0');$module=[IO.Path]::Combine($home,'Modules\Microsoft.PowerShell.Security');$windows=[Environment]::GetFolderPath('Windows');$parentHome=$ParentShellRoot.TrimEnd('\')
 $base=$Command.Module.ModuleBase;$assembly=$Command.ImplementingType.Assembly;$location=$assembly.Location;$name=$assembly.GetName();$token=([BitConverter]::ToString($name.GetPublicKeyToken())).Replace('-','').ToLowerInvariant()
 [ordered]@{type_is_cmdlet=($Command-is [Management.Automation.CmdletInfo]);module_name_matches=($Command.ModuleName-ceq 'Microsoft.PowerShell.Security');module_under_stock=($base-ieq $module -or $base.StartsWith($module+'\',[StringComparison]::OrdinalIgnoreCase));module_equals_stock_home=($base-ieq $home);module_equals_assembly_directory=($base-ieq [IO.Path]::GetDirectoryName($location));module_under_parent=($parentHome.Length-gt 0 -and $base.StartsWith($parentHome+'\',[StringComparison]::OrdinalIgnoreCase));assembly_under_windows=$location.StartsWith($windows+'\',[StringComparison]::OrdinalIgnoreCase);assembly_under_parent=($parentHome.Length-gt 0 -and $location.StartsWith($parentHome+'\',[StringComparison]::OrdinalIgnoreCase));assembly_name_matches=($name.Name-ceq 'Microsoft.PowerShell.Security');assembly_version_major=[int]$name.Version.Major;assembly_version_matches=($name.Version-eq [version]'3.0.0.0');assembly_token_matches=($token-ceq '31bf3856ad364e35');implementing_type_matches=($Command.ImplementingType.FullName-ceq 'Microsoft.PowerShell.Commands.GetAclCommand')}
}
function AssertPackageNativeSecurityProvenance($Value){
 foreach($name in @('type_is_cmdlet','module_name_matches','module_equals_stock_home','module_equals_assembly_directory','assembly_under_windows','assembly_name_matches','assembly_version_matches','assembly_token_matches','implementing_type_matches')){if($Value[$name]-isnot [bool]){throw 'Native security provenance must be typed.'}}
 if(!$Value.type_is_cmdlet -or !$Value.module_name_matches -or !($Value.module_equals_stock_home -or $Value.module_equals_assembly_directory) -or !$Value.assembly_under_windows -or !$Value.assembly_name_matches -or !$Value.assembly_version_matches -or !$Value.assembly_token_matches -or !$Value.implementing_type_matches){throw 'The stock native security command provenance differs.'}
}
function GetPackageNativeSecurityCommand([string]$ParentShellRoot=''){
 if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition-cne 'Desktop'){throw 'Native security resolution requires Windows PowerShell.'}
 $home=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell\v1.0');$manifest=[IO.Path]::Combine($home,'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1');AssertPackageNativeSecurityPath $manifest
 Import-Module -Name $manifest -Force -ErrorAction Stop
 $commands=@(Get-Command -Name 'Microsoft.PowerShell.Security\Get-Acl' -CommandType Cmdlet -All -ErrorAction Stop)
 if($commands.Count-ne 1 -or $commands[0]-isnot [Management.Automation.CmdletInfo]){throw 'The stock native security command is absent or ambiguous.'}
 $command=$commands[0];$proof=GetPackageNativeSecurityProvenance $command $ParentShellRoot;AssertPackageNativeSecurityProvenance $proof
 AssertPackageNativeSecurityPath $command.Module.ModuleBase;AssertPackageNativeSecurityPath $command.ImplementingType.Assembly.Location
 [pscustomobject]@{Command=$command;Provenance=$proof}
}
