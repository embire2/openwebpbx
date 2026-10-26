# SPDX-License-Identifier: AGPL-3.0-or-later
# Cross-platform executable validation; actual IIS/ACME/native tests are separate.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Check([bool]$Result,[string]$Label) { if(-not $Result) { throw $Label };$script:checks++ }
function Refused([scriptblock]$Action,[string]$Label) { $failed=$false;try { & $Action|Out-Null } catch { $failed=$true };Check $failed $Label }
foreach($name in 'PublicAccess.Common.ps1','Enable-PublicAccess.ps1','Renew-PhoneCertificate.ps1','configure-notifications.ps1') {
 $tokens=$null;$errors=$null
 $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('packaging/windows/'+$name)),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ($name+' parses without errors: '+($errors|Out-String))
}
. (Join-Path $root 'packaging/windows/PublicAccess.Common.ps1')
Check ((Assert-OpenWebPublicHostname 'PBX.Sample.ORG') -eq 'pbx.sample.org') 'DNS names are canonicalized'
foreach($name in 'localhost','pbx.local','pbx.invalid','https://pbx.sample.org','pbx.sample.org:443','*.sample.org','a..org','-a.sample.org','a_.sample.org',"pbx.sample.org`r`n--source script",('a'*64+'.org')) { Refused { Assert-OpenWebPublicHostname $name } 'Reject unsafe or non-public host input' }
Check ((Assert-OpenWebPublicAddress '8.8.8.8') -eq '8.8.8.8') 'Public IPv4 input is retained'
foreach($address in '127.0.0.1','10.1.2.3','172.16.0.1','192.168.1.3','169.254.1.2','100.64.0.1','198.18.0.1','192.0.2.1','198.51.100.1','203.0.113.1','224.0.0.1','::1','2001:4860:4860::8888','pbx.sample.org') { Refused { Assert-OpenWebPublicAddress $address } 'Reject unsuitable address input' }
Check ((Resolve-OpenWebPublicAddress '' @('8.8.8.8')) -eq '8.8.8.8') 'Automatic address uses the unique public DNS A record'
Check ((Resolve-OpenWebPublicAddress '' @('8.8.8.8','8.8.8.8')) -eq '8.8.8.8') 'Duplicate identical answers are harmless'
Refused { Resolve-OpenWebPublicAddress '' @('8.8.8.8','1.1.1.1') } 'Automatic address refuses distinct multiple A records'
Refused { Resolve-OpenWebPublicAddress '8.8.8.8' @('1.1.1.1') } 'Explicit wrong address cannot override DNS'
Refused { Resolve-OpenWebPublicAddress '' @('192.168.1.2') } 'Automatic address refuses private DNS results'
Refused { Resolve-OpenWebPublicAddress '' @() } 'Missing DNS addresses cannot trigger issuance'
Check ((Assert-OpenWebPublicEmail 'renewal@sample.org') -eq 'renewal@sample.org') 'Email input is retained'
foreach($email in 'not-an-email','Display <renewal@sample.org>',"renewal@sample.org`n--force",'renewal@local') { Refused { Assert-OpenWebPublicEmail $email } 'Reject unsafe renewal email input' }
# Execute only the real installer parameter binder and early port policy.
$tokens=$null;$errors=$null
$installer=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'packaging/windows/Install-OpenWebPBX.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'Installer port policy parses'
$policy=@($installer.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith("if(`$DomainName.EndsWith(")})
Check ($policy.Count -eq 1) 'Exactly one early managed-host port policy'
$runtime=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq '& "$PSScriptRoot\Ensure-Runtime.ps1"'},$true))
Check ($runtime.Count -eq 1 -and $policy[0].Extent.EndOffset -lt $runtime[0].Extent.StartOffset) 'Incompatible managed port refuses before runtime or installation mutations'
$choosePort=[scriptblock]::Create($installer.ParamBlock.Extent.Text+"`n"+$policy[0].Extent.Text+"`n"+'[pscustomobject]@{port=$HttpsPort;restore=[bool]$RestoreServer}')
foreach($case in @(
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';EnablePublicAccess=$true};port=443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';EnablePublicAccess=$true;HttpsPort=443};port=443},
 @{arguments=@{DomainName='QA-SETUP.OPENWEBPBX.COM';EnablePublicAccess=$true};port=443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';LocalCertificate=$true};port=443},
 @{arguments=@{DomainName='QA-SETUP.OPENWEBPBX.COM';LocalCertificate=$true};port=443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';CertificateThumbprint='fixture-certificate'};port=443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';RestoreServer=$true;LocalCertificate=$true};port=443},
 @{arguments=@{DomainName='pbx.sample.org';CertificateThumbprint='fixture-certificate';HttpsPort=9443};port=9443},
 @{arguments=@{DomainName='pbx.sample.org';EnablePublicAccess=$true};port=8443},
 @{arguments=@{DomainName='pbx.sample.org';EnablePublicAccess=$true;HttpsPort=9443};port=9443},
 @{arguments=@{EnablePublicAccess=$true};port=8443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com.evil.invalid';EnablePublicAccess=$true};port=8443},
 @{arguments=@{DomainName='windowsqa.example.invalid';RestoreServer=$true;LocalCertificate=$true};port=8443},
 @{arguments=@{DomainName='qa-setup.openwebpbx.com';RestoreServer=$true;EnablePublicAccess=$true};port=443}
)){
 $arguments=$case.arguments;$selected=& $choosePort @arguments
 Check ($selected.port -eq $case.port -and $selected.restore -eq [bool]$arguments['RestoreServer']) 'Actual bound/default port and restore option retained'
}
Refused {& $choosePort -DomainName qa-setup.openwebpbx.com -EnablePublicAccess -HttpsPort 8443} 'Explicit incompatible managed port cannot be silently overridden'
Refused {& $choosePort -DomainName qa-setup.openwebpbx.com -LocalCertificate -HttpsPort 8443} 'Local certificate cannot override the managed-host standard port'
Refused {& $choosePort -DomainName qa-setup.openwebpbx.com -CertificateThumbprint fixture-certificate -HttpsPort 8443} 'Installed certificate cannot override the managed-host standard port'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb public checks '+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
try {
 $state=Join-Path $temporary 'state.json'
 Write-OpenWebPublicJson $state @{schema=1;hostname='pbx.sample.org';test='unchanged'}
 Check ((Read-OpenWebPublicJson $state).test -eq 'unchanged') 'New state is readable'
 Write-OpenWebPublicJson $state @{schema=1;hostname='pbx.sample.org';test='replacement'}
 Check ((Read-OpenWebPublicJson $state).test -eq 'replacement') 'Atomic replacement is readable'
 Check (@(Get-ChildItem $temporary -Filter '*.tmp').Count -eq 0) 'No incomplete JSON is left behind'
 [IO.File]::WriteAllText($state,('x'*65537))
 Refused { Read-OpenWebPublicJson $state } 'Oversized state is refused'
 $configuration=Join-Path $temporary 'config.conf'
 $original="database.0.password = private-fixture-only`r`ncustom.unchanged = café`r`nopenweb.public_host = localhost`r`nopenweb.public_url = https://localhost:8443`r`nopenweb.public_ip = `r`n"
 [IO.File]::WriteAllText($configuration,$original,[Text.UTF8Encoding]::new($false))
 $before=[IO.File]::ReadAllBytes($configuration)
 $saved=Set-OpenWebPublicConfiguration $configuration 'pbx.sample.org' '8.8.8.8'
 Check ([Convert]::ToBase64String($saved) -eq [Convert]::ToBase64String($before)) 'Exact original configuration bytes are available for recovery'
 $after=[IO.File]::ReadAllText($configuration)
 Check ($after.Contains("database.0.password = private-fixture-only`r`ncustom.unchanged = café`r`n")) 'Unrelated configuration remains byte-preserved'
 Check ($after.Contains("openweb.public_url = https://pbx.sample.org`r`n") -and -not $after.Contains('localhost')) 'Only the intended public connection metadata changes'
 # The exact original saved-state reload remains authoritative on retries.
 $resumes=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $null -ne $n.ElseClause -and $n.ElseClause.Extent.Text.Contains('$state=Get-Content "$private\installation.json" -Raw | ConvertFrom-Json')},$true))
 Check ($resumes.Count -eq 1) 'Actual saved-state reload remains unique'
 $resume=[scriptblock]::Create($resumes[0].ElseClause.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
 $private=$temporary;$savedPath=Join-Path $private 'installation.json'
 foreach($savedPort in 8443,9443){
  $savedState=@{DomainName='saved.openwebpbx.com';HttpsPort=$savedPort;PublicAddress='192.0.2.10';AdminEmail='saved@example.invalid';RestoreServer=$true;DatabasePassword='fictional-preserved';InstanceUuid='00000000-0000-4000-8000-000000000001'}
  [IO.File]::WriteAllText($savedPath,($savedState|ConvertTo-Json));$beforeState=[IO.File]::ReadAllBytes($savedPath);$HttpsPort=443;$DomainName='new.openwebpbx.com';$RestoreServer=$false
  . $resume
  Check ($HttpsPort -eq $savedPort -and $DomainName -ceq 'saved.openwebpbx.com' -and $RestoreServer -and $state.DatabasePassword -ceq $savedState.DatabasePassword -and $state.InstanceUuid -ceq $savedState.InstanceUuid) 'Saved port/identity/credentials remain authoritative'
  Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($savedPath)) -ceq [Convert]::ToBase64String($beforeState)) 'Existing installation state is read without rewriting'
 }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Output "PASS: $checks public-access parse, input and atomic-state checks"
