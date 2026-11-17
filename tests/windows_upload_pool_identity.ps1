[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$ExistingPool='OpenWebPBX')
# Read actual IIS provider data; never create, modify or restart an IIS object.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -eq 'Core'){throw 'Run these IIS controls in Windows PowerShell 5.1.'}
Import-Module WebAdministration
Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
. (Join-Path $SourceRoot 'packaging/windows/Uploads.Common.ps1')
$checks=0
function Check([bool]$Allowed,[string]$Message){if(!$Allowed){throw $Message};$script:checks++}
$pool=Get-Item -LiteralPath ('IIS:\AppPools\'+$ExistingPool)
$actual=$pool.processModel.identityType
Check (Test-OpenWebUploadPoolIdentity $actual) 'The actual IIS provider ApplicationPoolIdentity must be recognized.'
$manager=New-Object Microsoft.Web.Administration.ServerManager
try{
 $typed=$manager.ApplicationPools[$ExistingPool].ProcessModel.IdentityType
 Check ($typed.GetType().FullName -ceq 'Microsoft.Web.Administration.ProcessModelIdentityType') 'The actual administration API must return the intended enum type.'
 Check (Test-OpenWebUploadPoolIdentity $typed) 'The actual administration API identity must be recognized.'
}finally{$manager.Dispose()}
foreach($value in @('ApplicationPoolIdentity',[int]4,[uint32]4,[Microsoft.Web.Administration.ProcessModelIdentityType]::ApplicationPoolIdentity)){
 Check (Test-OpenWebUploadPoolIdentity $value) 'A canonical intended identity representation must pass.'
}
foreach($value in @($null,'4','applicationpoolidentity',' ApplicationPoolIdentity','ApplicationPoolIdentity ','NetworkService','LocalSystem','SpecificUser','',[int]0,[int]1,[int]2,[int]3,[int]5,[uint32]3,[long]4,[uint64]4,[decimal]4,[double]4,$true,$false,[DayOfWeek]4,[Microsoft.Web.Administration.ProcessModelIdentityType]::NetworkService)){
 Check (-not (Test-OpenWebUploadPoolIdentity $value)) 'An alternate identity/coercion must refuse.'
}
# Run the actual full ownership guard read-only. A present gate exercises the
# former rollback failure; an absent gate is reported separately, never relabelled.
Assert-OpenWebUploadObjects
$gate=Get-Item IIS:\AppPools\OpenWebPBXUploadGate -ErrorAction SilentlyContinue
Check $true 'The actual full IIS ownership guard completed read-only.'
Write-Host "Actual Windows IIS pool identity controls: $checks passed; candidate_gate_present=$([bool]$gate); provider_type=$($actual.GetType().FullName). No IIS or database mutation."
