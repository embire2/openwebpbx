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
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Output "PASS: $checks public-access parse, input and atomic-state checks"
