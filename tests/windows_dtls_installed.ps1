# Read-only proof of the actual fresh-installed private DTLS identity.
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:OS -cne 'Windows_NT'){throw 'Native Windows is required.'}
. (Join-Path $PackageRoot 'Dtls.Common.ps1')
$certificate='C:\Program Files\FreeSWITCH\cert\dtls-srtp.pem';$state=Join-Path $env:ProgramData 'OpenWebPBX';$checks=0
function Check([bool]$Value){if(!$Value){throw 'The installed native DTLS identity did not validate.'};$script:checks++}
$service=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'";Check ($service.State -ceq 'Running' -and $service.ProcessId -gt 0)
$beforeHash=Get-OpenWebDtlsHash $certificate;$beforeAcl=(Get-Acl -LiteralPath $certificate).Sddl
Assert-OpenWebDtlsOrdinary $certificate;$checks++
$result=& 'C:\OpenWebPBX\php\php.exe' (Join-Path $PackageRoot 'configure-dtls.php') inspect $certificate
Check ($LASTEXITCODE -eq 0);$result=$result|ConvertFrom-Json;Check ($result.schema -eq 1 -and $result.state -ceq 'valid')
$sid=if($service.StartName -in 'LocalSystem','NT AUTHORITY\SYSTEM'){'S-1-5-18'}else{([Security.Principal.NTAccount]$service.StartName).Translate([Security.Principal.SecurityIdentifier]).Value}
Check ($beforeAcl -ceq (New-OpenWebDtlsAcl -ServiceSid $sid).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
$directory=Join-Path $state 'dtls-setup';Assert-OpenWebDtlsPrivate $directory;$checks++
$journals=@(Get-ChildItem -LiteralPath $directory -Directory);Check ($journals.Count -ge 1 -and $journals.Count -le 16)
$owned=@();foreach($transaction in $journals){$journal=Read-OpenWebDtlsJournal $transaction.FullName $certificate;if($journal.state -ceq 'committed' -and $journal.desired_sha256 -ceq $beforeHash){$owned+=@($journal)}}
Check ($owned.Count -eq 1)
foreach($name in 'Install-Dtls.ps1','Dtls.Common.ps1','configure-dtls.php'){Check ((Get-OpenWebDtlsHash (Join-Path $PackageRoot $name)) -ceq (Get-OpenWebDtlsHash (Join-Path 'C:\OpenWebPBX\tools' $name)))}
$after=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'"
Check ($after.State -ceq 'Running' -and $after.ProcessId -eq $service.ProcessId -and (Get-OpenWebDtlsHash $certificate) -ceq $beforeHash -and (Get-Acl -LiteralPath $certificate).Sddl -ceq $beforeAcl)
[ordered]@{schema=1;producer='windows_dtls_installed.ps1';state='passed';actual_native_windows=$true;installed_certificate_valid=$true;installed_private_acl=$true;owned_transaction_verified=$true;installed_engine_untouched=$true;checks=$checks}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ReportPath -Encoding UTF8
