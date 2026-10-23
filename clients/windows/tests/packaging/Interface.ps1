# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Update','Verify')][string]$Mode,[Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][long]$StartedUtcTicks,[Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Nonce,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:RUNNER_OS-cne 'Windows' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows UI fixture is allowed.'}
if([IO.Path]::GetFullPath($Root) -ine (Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ('phone-package-'+$Nonce))){throw 'The owned UI report root differs.'}
$expected=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('WindowsApps\OpenWebPBX.FreePhone.Dev.'+$Nonce.Substring(0,16)+'_')
if(!$Executable.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($Executable)-cne 'OpenWebPbx.Phone.App.exe'){throw 'Only the nonce development package may be automated.'}
$proc=[Diagnostics.Process]::GetProcessById($ProcessId)
try{
 if($proc.StartTime.ToUniversalTime().Ticks-ne $StartedUtcTicks -or $proc.MainModule.FileName-ine $Executable){throw 'The owned packaged process identity changed.'}
 Add-Type -AssemblyName UIAutomationClient;Add-Type -AssemblyName UIAutomationTypes
 $end=[DateTime]::UtcNow.AddSeconds(60);$window=$null
 do{$proc.Refresh();if($proc.HasExited){throw 'The owned packaged window exited.'};if($proc.MainWindowHandle-ne 0 -and $proc.Responding){$window=[Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)};if(!$window){Start-Sleep -Milliseconds 100}}while(!$window -and [DateTime]::UtcNow-lt $end)
 if(!$window -or $window.Current.Name-cne 'OpenWebPBX Free Phone'){throw 'The actual responsive packaged window is missing.'}
 function Named($Scope,[string]$Name,[bool]$Visible=$true){$items=@($Scope.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Name)));$items=@($items|Where-Object{!$Visible -or !$_.Current.IsOffscreen});if($items.Count-ne 1){throw 'A unique actual visible control is required.'};$items[0]}
 function WaitNamed($Scope,[string]$Name){$end=[DateTime]::UtcNow.AddSeconds(40);do{try{return (Named $Scope $Name)}catch{Start-Sleep -Milliseconds 100}}while([DateTime]::UtcNow-lt $end);throw 'The required actual UI state did not appear.'}
 function Invoke($Control){$pattern=$Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern);$pattern.Invoke()}
 $choice=WaitNamed $window 'Current account';$selection=@($choice.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection())
 if($selection.Count-ne 1 -or $selection[0].Current.Name-cne 'Development preserved profile'){throw 'The actual selected invented account was not preserved.'}
 if($Mode-ceq 'Update'){
  $end=[DateTime]::UtcNow.AddSeconds(40);$banner=$null
  do{$banner=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'WindowsPhoneUpdateBanner'));if(!$banner -or $banner.Current.IsOffscreen -or $banner.Current.Name-cne 'Required Windows phone update'){Start-Sleep -Milliseconds 100;$banner=$null}}while(!$banner -and [DateTime]::UtcNow-lt $end)
  if(!$banner){throw 'The actual required update notice is missing.'};Invoke (WaitNamed $banner 'Get update')
  $end=[DateTime]::UtcNow.AddSeconds(60);$dialog=$null
  do{$dialog=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'WindowsPhoneUpdateConfirmation'));if(!$dialog){Start-Sleep -Milliseconds 100}}while(!$dialog -and [DateTime]::UtcNow-lt $end)
  if(!$dialog){throw 'The explicit native install confirmation is missing.'};Invoke (Named $dialog 'Install and restart')
  if(!$proc.WaitForExit(30000)){throw 'The app did not exit itself after idle update confirmation.'}
 }
 [IO.File]::WriteAllText((Join-Path $Root ('ui-'+$Mode.ToLowerInvariant()+'.json')),(@{schema=1;producer='PackageInterface';state='passed';actual_native_uia=$true;mode=$Mode;invented_profile_visible=$true;calling_tested=$false}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}finally{$proc.Dispose()}
