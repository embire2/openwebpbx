[CmdletBinding()]
param([Parameter(Mandatory)][string]$DesktopDirectory,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
if($env:OS -cne 'Windows_NT' -or $env:GITHUB_ACTIONS -cne 'true'){throw 'Run only on an isolated Windows Actions runner.'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$folder=Join-Path $env:ProgramData 'OpenWebPBX-Status'
$path=Join-Path $folder 'updates.json'
if(Test-Path -LiteralPath $path){throw 'An existing server update status must not be replaced.'}
$created=!(Test-Path -LiteralPath $folder)
New-Item -ItemType Directory -Path $folder -Force|Out-Null
$manager=$null;$written=$null;$checks=0
function Assert($condition,[string]$message){if(!$condition){throw $message};$script:checks++}
function WriteStatus([bool]$required,[bool]$ready){
 $state=@{platform='windows-x64';state=$(if($ready){'ready'}else{'downloading'});message='Isolated native update notice test';installed_version='1.0.20';available_version='1.0.21';update_required=$required;download_ready=$ready;total_bytes=100;progress_bytes=$(if($ready){100}else{25})}
 $text=$state|ConvertTo-Json -Compress
 $bytes=[Text.Encoding]::UTF8.GetBytes($text)
 [IO.File]::WriteAllBytes($path,$bytes)
 $script:written=(Get-FileHash -LiteralPath $path).Hash
}
function FindName([string]$name){
 $root=[Windows.Automation.AutomationElement]::FromHandle($script:manager.MainWindowHandle)
 $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$name)
 return $root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
}
function WaitUntil([scriptblock]$condition,[string]$failure){
 $deadline=[DateTime]::UtcNow.AddSeconds(40)
 do {if(&$condition){$script:checks++;return};$script:manager.Refresh();if($script:manager.HasExited){throw 'The native manager exited.'};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $deadline)
 throw $failure
}
try {
 WriteStatus $true $false
 $manager=Start-Process -FilePath (Join-Path $DesktopDirectory 'OpenWebPbx.Desktop.exe') -WorkingDirectory $env:SystemRoot -PassThru
 WaitUntil {$manager.Refresh();$manager.MainWindowHandle -ne 0 -and $manager.Responding} 'Native manager window did not appear.'
 $message='Your Windows Server PBX system has a new update 1.0.21 - you must update in order to continue using the service.'
 WaitUntil {$null -ne (FindName 'Windows Server update required')} 'The actual WinUI update modal did not appear.'
 $later=FindName 'Later';Assert ($null -ne $later) 'The modal cannot be postponed.'
 $primary=FindName 'Update now';Assert ($null -ne $primary -and !$primary.Current.IsEnabled) 'The modal allows installation before the download is ready.'
 WriteStatus $true $true
 WaitUntil {$button=FindName 'Update now';$null -ne $button -and $button.Current.IsEnabled} 'The modal did not enable the verified download.'
 $invoke=$later.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern);$invoke.Invoke()
 WaitUntil {$null -eq (FindName 'Windows Server update required')} 'Later did not dismiss the modal.'
 Assert ($manager.Responding -and !$manager.HasExited) 'Postponing the modal closed the manager.'
 WaitUntil {$null -ne (FindName $message)} 'The persistent native notice disappeared after Later.'
 Assert ($null -ne (FindName 'Update now')) 'The native banner has no installation action.'
 # A successful installed status removes the notice. It must not remain stale forever.
 WriteStatus $false $false
 WaitUntil {$null -eq (FindName $message)} 'A completed update did not clear the native requirement.'
 [ordered]@{checks=$checks;window_responsive=$manager.Responding;modal_on_actual_window=$true;postpone_keeps_manager=$true;verified_download_required=$true;persistent_banner=$true;completed_notice_cleared=$true;scope='Native notice only; no server upgrade or service restart performed.'}|ConvertTo-Json|Set-Content -LiteralPath $Output -Encoding utf8
} finally {
 if($manager -and !$manager.HasExited){Stop-Process -Id $manager.Id -Force -ErrorAction Stop;$manager.WaitForExit()}
 if(Test-Path -LiteralPath $path){if(!$written -or (Get-FileHash -LiteralPath $path).Hash -cne $written){throw 'Owned status cleanup refused changed bytes.'};Remove-Item -LiteralPath $path -Force}
 if($created -and !(Get-ChildItem -LiteralPath $folder -Force)){Remove-Item -LiteralPath $folder}
}
