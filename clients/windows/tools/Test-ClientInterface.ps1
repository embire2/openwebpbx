[CmdletBinding()]
param([Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$Report)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the disposable native Windows UI fixture may run.'}
$process=Get-Process -Id $ProcessId;if($process.Path -cne $Executable -or $process.MainWindowTitle -cne 'OpenWebPBX Free Phone' -or $process.MainWindowHandle -eq 0){throw 'The owned native window differs.'}
$created=$process.StartTime.ToUniversalTime();Add-Type -AssemblyName UIAutomationClient;Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PhoneUiCapture{[StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}[DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);}'
function Capture([string]$Name){$rect=[PhoneUiCapture+Rect]::new();if(![PhoneUiCapture]::GetWindowRect($process.MainWindowHandle,[ref]$rect)){throw 'Window bounds unavailable.'};$width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top;if($width -lt 320 -or $height -lt 320 -or $width -gt 4000 -or $height -gt 3000){throw 'Window bounds differ.'};$bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path (Split-Path $Report -Parent) $Name),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}

$window=[System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle);$checks=0
function AssertUi([bool]$Value){if(!$Value){throw 'A native UI control did not meet its expected state.'};$script:checks++}
function Element([string]$Name){$end=[DateTime]::UtcNow.AddSeconds(8);do{$found=$window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,$Name));if($found){return $found};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $end);throw 'The required native UI element is absent.'}
function InvokeElement($Element){$pattern=$null;if($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke();return};if($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select();return};throw 'The native element is not actionable.'}
$connect=Element 'Connect an account';AssertUi $connect.Current.IsEnabled
$warning=$window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,'Please wait for the current request to finish.'));AssertUi ($null-eq$warning)
InvokeElement $connect
AssertUi ((Element 'Tenant address').Current.IsEnabled);AssertUi ((Element 'Extension').Current.IsEnabled);AssertUi ((Element 'App password chosen by your administrator').Current.IsEnabled)
AssertUi ((Element 'Open welcome email setup file').Current.IsEnabled);AssertUi ((Element 'Scan QR code with webcam').Current.IsEnabled);Capture 'client-accounts.png'
InvokeElement (Element 'Settings')
foreach($name in @('Microphone','Speaker or headset','Camera','Theme','Open on','Sort contacts by','Incoming call notifications','Hide caller in notifications','Start phone when I sign in to Windows','Check connection','Change my app password','Terms','Privacy','Delete my account')){AssertUi ($null-ne(Element $name))}
Capture 'client-settings.png'
InvokeElement (Element 'Keypad');AssertUi ((Element 'Connect an account').Current.IsEnabled)
$after=Get-Process -Id $ProcessId;AssertUi ($after.Path -ceq $Executable -and $after.StartTime.ToUniversalTime()-eq$created -and $after.Responding)
[ordered]@{schema=1;producer='Test-ClientInterface.ps1';state='passed';checks=$checks;actual_native_uia=$true;logged_out_accounts_settings_keypad=$true;network_sign_in_tested=$false;calls_placed=$false;physical_hardware_tested=$false}|ConvertTo-Json|Set-Content -LiteralPath $Report -Encoding utf8
