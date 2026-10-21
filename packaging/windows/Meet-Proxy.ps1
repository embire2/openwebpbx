# SPDX-License-Identifier: AGPL-3.0-or-later
# Administrator-only IIS meeting transport. Importing this file changes nothing.
function Assert-OpenWebMeetOrdinary([string]$Path) {
 $full=[IO.Path]::GetFullPath($Path)
 for($p=$full;$p;$p=[IO.Path]::GetDirectoryName($p)){
  if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Meeting transport paths must not contain links or junctions.'}}
  if([IO.Path]::GetDirectoryName($p) -eq $p){break}
 }
 return $full
}
function Get-OpenWebMeetHostsPlan([byte[]]$Bytes) {
 # Preserve every original byte, including comments and non-ASCII characters.
 $text=[Text.Encoding]::GetEncoding(28591).GetString($Bytes)
 if($text.IndexOf([char]0) -ge 0){throw 'The hosts file encoding needs administrator review.'}
 $found=@()
 foreach($line in ($text -split '\r?\n')){
  $fields=@(($line -split '#',2)[0].Trim() -split '\s+'|Where-Object {$_})
  if($fields.Count -gt 1 -and @($fields[1..($fields.Count-1)]|Where-Object {$_ -ieq 'openweb-meet.internal'}).Count){$found+=,$fields}
 }
 if($found.Count -gt 1 -or ($found.Count -eq 1 -and $found[0][0] -cne '127.0.0.1')){throw 'The private meeting hostname belongs to another hosts configuration.'}
 $line="`r`n127.0.0.1 openweb-meet.internal # OpenWebPBX Meet`r`n"
 return @{Changed=($found.Count -eq 0);Bytes=if($found.Count){$Bytes}else{[byte[]]($Bytes+[Text.Encoding]::ASCII.GetBytes($line))};AddedLine=$line}
}
function Get-OpenWebMeetCertificate([string]$Path) {
 $null=Assert-OpenWebMeetOrdinary $Path
 $text=[IO.File]::ReadAllText($Path)
 $matches=[regex]::Matches($text,'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
 if($matches.Count -ne 1 -or $text -match 'PRIVATE KEY'){throw 'Use the public meeting certificate, without a private key.'}
 $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($matches[0].Groups[1].Value))
 if($certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'openweb-meet.internal' -or $certificate.Subject -cne $certificate.Issuer -or $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays(1) -or $certificate.HasPrivateKey){throw 'The private meeting certificate needs administrator review.'}
 return $certificate
}
function Get-OpenWebMeetProxyState {
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 if(!(Test-Path "$env:ProgramFiles\IIS\Application Request Routing\requestRouter.dll")){return @{Exists=$false;Enabled=$false;PreserveHostHeader=$false}}
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy');return @{Exists=$true;Enabled=[bool]$section['enabled'];PreserveHostHeader=[bool]$section['preserveHostHeader']}
 }finally{$manager.Dispose()}
}
function Save-OpenWebMeetSystem {
 param([string]$Destination,[string]$StateRoot)
 $null=Assert-OpenWebMeetOrdinary $Destination
 $hosts=Join-Path $env:windir 'System32\drivers\etc\hosts';$null=Assert-OpenWebMeetOrdinary $hosts
 $reg='HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters'
 $value=Get-ItemProperty -LiteralPath $reg -Name SecureConnectionIgnoreFlags -ErrorAction SilentlyContinue
 $record=[ordered]@{Schema=1;Hosts=[Convert]::ToBase64String([IO.File]::ReadAllBytes($hosts));HostsSddl=(Get-Acl -LiteralPath $hosts).Sddl;Proxy=(Get-OpenWebMeetProxyState);IgnoreKeyExists=(Test-Path -LiteralPath $reg);IgnoreFlagsExists=($null -ne $value);IgnoreFlags=if($value){[int]$value.SecureConnectionIgnoreFlags}else{0};RootThumbprints=@(Get-ChildItem Cert:\LocalMachine\Root|ForEach-Object Thumbprint);WebSockets=[bool](Get-WindowsFeature Web-WebSockets).Installed;Rewrite=(Test-Path "$env:windir\System32\inetsrv\rewrite.dll");Arr=(Test-Path "$env:ProgramFiles\IIS\Application Request Routing\requestRouter.dll")}
 $record.PreviousMeetCertificate=$null
 $record.PreviousMeetLedger=$null
 $ledgerFile=Join-Path $StateRoot 'meet-proxy.json'
 if(Test-Path -LiteralPath $ledgerFile){
  $previous=Get-Content -LiteralPath $ledgerFile -Raw|ConvertFrom-Json
  if($previous.Schema -ne 1 -or $previous.Thumbprint -cnotmatch '^[A-F0-9]{40}$'){throw 'The installed meeting ownership ledger needs review.'}
  $record.PreviousMeetLedger=[Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerFile))
  if($previous.OwnedTrust -and (Test-Path ('Cert:\LocalMachine\Root\'+$previous.Thumbprint))){
   $cert=Get-Item ('Cert:\LocalMachine\Root\'+$previous.Thumbprint)
   if([Convert]::ToBase64String($cert.RawData) -cne $previous.Certificate){throw 'The installed meeting trust identity needs review.'}
   $record.PreviousMeetCertificate=[string]$previous.Certificate
  }
 }
 if($record.IgnoreFlagsExists -and $record.IgnoreFlags -ne 0){throw 'Existing IIS backend certificate exceptions need administrator review before meetings can be installed.'}
 if($record.Proxy.Exists -and $record.Proxy.PreserveHostHeader){throw 'Existing IIS proxy host preservation needs administrator review before meetings can be installed.'}
 if($record.Rewrite -and (!$record.Proxy.Enabled -or !$record.IgnoreFlagsExists)){
  $manager=[Microsoft.Web.Administration.ServerManager]::new()
  try{
   foreach($site in $manager.Sites){
    foreach($rule in $manager.GetApplicationHostConfiguration().GetSection('system.webServer/rewrite/rules',$site.Name).GetCollection()){
     if([string]$rule.GetChildElement('action')['type'] -eq 'Rewrite' -and [string]$rule.GetChildElement('action')['url'] -match '^https?://' -and [string]$rule['name'] -ne 'OpenWebPBX Meet'){throw 'Existing reverse-proxy rules need administrator review before enabling IIS proxying.'}
    }
   }
   foreach($rule in $manager.GetApplicationHostConfiguration().GetSection('system.webServer/rewrite/globalRules').GetCollection()){
    if([string]$rule.GetChildElement('action')['type'] -eq 'Rewrite' -and [string]$rule.GetChildElement('action')['url'] -match '^https?://'){throw 'Existing global reverse-proxy rules need administrator review before enabling IIS proxying.'}
   }
  }finally{$manager.Dispose()}
 }
 $null=Get-OpenWebMeetHostsPlan ([Convert]::FromBase64String($record.Hosts))
 . (Join-Path $PSScriptRoot 'Write-PrivateState.ps1')
 Write-OpenWebPrivateState -Path $Destination -Value $record
}
function Set-OpenWebMeetWebConfig([string]$Path) {
 $null=Assert-OpenWebMeetOrdinary $Path
 $xml=[xml]::new();$xml.PreserveWhitespace=$true;$xml.Load($Path)
 $server=$xml.SelectSingleNode('/configuration/system.webServer')
 if(!$server){throw 'The PBX IIS configuration is missing.'}
 if(@($server.SelectNodes('rewrite/rules/rule')|Where-Object {$_.name -eq 'OpenWebPBX Meet' -or $_.match.url -match 'meet-sip'}).Count){throw 'An existing meeting rewrite rule needs administrator review.'}
 $rewrite=$server.SelectSingleNode('rewrite');if(!$rewrite){$rewrite=$server.AppendChild($xml.CreateElement('rewrite'))}
 $rules=$rewrite.SelectSingleNode('rules');if(!$rules){$rules=$rewrite.AppendChild($xml.CreateElement('rules'))}
 $fragment=$xml.CreateDocumentFragment()
 $fragment.InnerXml='<rule name="OpenWebPBX Meet" stopProcessing="true"><match url="^meet-sip/$" ignoreCase="false"/><conditions logicalGrouping="MatchAll"><add input="{HTTPS}" pattern="^on$"/><add input="{REQUEST_METHOD}" pattern="^GET$"/><add input="{HTTP_UPGRADE}" pattern="^websocket$" ignoreCase="true"/><add input="{QUERY_STRING}" pattern="^$"/></conditions><action type="Rewrite" url="https://openweb-meet.internal:7444/" appendQueryString="false"/></rule>'
 $null=$rules.PrependChild($fragment)
 $socket=$server.SelectSingleNode('webSocket')
 if(!$socket){$node=$xml.CreateElement('webSocket');$node.SetAttribute('enabled','true');$null=$server.AppendChild($node)}elseif($socket.GetAttribute('enabled') -ne 'true'){throw 'The existing PBX WebSocket policy needs administrator review.'}
 $xml.Save($Path)
}
function Restore-OpenWebMeetSystem {
 param([string]$Snapshot,[string]$StateRoot,[string]$LedgerPath=(Join-Path $StateRoot 'meet-proxy.json'))
 $before=Get-Content -LiteralPath $Snapshot -Raw|ConvertFrom-Json
 if($before.Schema -ne 1){throw 'The meeting recovery snapshot is invalid.'}
 if(!(Test-Path -LiteralPath $LedgerPath)){return}
 $ledger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json
 if($ledger.Schema -ne 1 -or $ledger.Thumbprint -cnotmatch '^[A-F0-9]{40}$'){throw 'The owned meeting transport ledger is invalid.'}
 $hosts=Join-Path $env:windir 'System32\drivers\etc\hosts';$null=Assert-OpenWebMeetOrdinary $hosts
 $bytes=[IO.File]::ReadAllBytes($hosts);$text=[Text.Encoding]::GetEncoding(28591).GetString($bytes)
 $original=[Convert]::FromBase64String($before.Hosts);$oldPlan=Get-OpenWebMeetHostsPlan $original
 if($oldPlan.Changed){
  $needle=[string]$ledger.HostsLine;$position=$text.IndexOf($needle,[StringComparison]::Ordinal)
  if($position -ge 0){
   if($text.IndexOf($needle,$position+$needle.Length,[StringComparison]::Ordinal) -ge 0){throw 'Duplicate owned meeting hosts lines need administrator recovery.'}
   $candidate=$text.Remove($position,$needle.Length);$null=Get-OpenWebMeetHostsPlan ([Text.Encoding]::GetEncoding(28591).GetBytes($candidate))
   [IO.File]::WriteAllBytes($hosts,[Text.Encoding]::GetEncoding(28591).GetBytes($candidate))
  }elseif([Convert]::ToBase64String($bytes) -cne $before.Hosts){throw 'The owned meeting hosts entry changed during recovery.'}
 }
 $reg='HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters'
 $current=Get-ItemProperty -LiteralPath $reg -Name SecureConnectionIgnoreFlags -ErrorAction SilentlyContinue
 if($current -and [int]$current.SecureConnectionIgnoreFlags -ne 0){throw 'IIS backend certificate policy changed during meeting recovery.'}
 if($before.IgnoreFlagsExists){New-ItemProperty -Path $reg -Name SecureConnectionIgnoreFlags -Value ([int]$before.IgnoreFlags) -PropertyType DWord -Force|Out-Null}
 else{Remove-ItemProperty -LiteralPath $reg -Name SecureConnectionIgnoreFlags -ErrorAction SilentlyContinue}
 if((Get-OpenWebMeetProxyState).Exists){
  $manager=[Microsoft.Web.Administration.ServerManager]::new()
  try{
   $section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy')
   $raw=[string]$section.GetRawXml()
   if($ledger.PSObject.Properties['ProxyBeforeXml'] -and $raw -cne [string]$ledger.ProxyBeforeXml -and $raw -cne [string]$ledger.ProxyAfterXml){throw 'IIS proxy configuration changed during recovery.'}
   if([bool]$section['preserveHostHeader'] -ne [bool]$before.Proxy.PreserveHostHeader){throw 'IIS proxy host policy changed during recovery.'}
   if($before.Proxy.Exists){$section['enabled']=[bool]$before.Proxy.Enabled}else{$section.RevertToParent()}
   $manager.CommitChanges()
  }finally{$manager.Dispose()}
 }
 if($ledger.Thumbprint -notin @($before.RootThumbprints)){
  $path='Cert:\LocalMachine\Root\'+$ledger.Thumbprint
  if(Test-Path -LiteralPath $path){$cert=Get-Item -LiteralPath $path;if([Convert]::ToBase64String($cert.RawData) -cne $ledger.Certificate){throw 'The owned meeting trust certificate changed during recovery.'};Remove-Item -LiteralPath $path -Force}
 }
 if($before.PreviousMeetCertificate){
  $previous=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String([string]$before.PreviousMeetCertificate))
  if($previous.Thumbprint -notin @($before.RootThumbprints) -or $previous.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'openweb-meet.internal' -or $previous.Subject -cne $previous.Issuer){throw 'The previous meeting trust identity is invalid.'}
  if(!(Test-Path ('Cert:\LocalMachine\Root\'+$previous.Thumbprint))){$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine');$store.Open('ReadWrite');try{$store.Add($previous)}finally{$store.Close()}}
 }
 # Only packages introduced by this transaction may be uninstalled. Existing
 # IIS extension installations and their other configuration remain untouched.
 foreach($product in @($ledger.Products)|Sort-Object Order -Descending){
  $wasInstalled=if($product.Kind -eq 'Arr'){[bool]$before.Arr}else{[bool]$before.Rewrite}
  if(!$wasInstalled -and $product.Introduced){
   if($product.ProductCode -cnotmatch '^\{[A-F0-9-]{36}\}$'){throw 'The owned IIS prerequisite identity is invalid.'}
   $process=Start-Process msiexec.exe -ArgumentList @('/x',$product.ProductCode,'/qn','/norestart') -Wait -PassThru
   if($process.ExitCode -notin 0,1605){throw 'The newly introduced meeting prerequisite needs administrator recovery.'}
  }
 }
 if(!$before.WebSockets -and (Get-WindowsFeature Web-WebSockets).Installed){$result=Uninstall-WindowsFeature Web-WebSockets;if(!$result.Success -or $result.RestartNeeded -eq 'Yes'){throw 'Windows requires administrator recovery for its newly introduced WebSocket feature.'}}
 if(!$before.IgnoreKeyExists -and (Test-Path -LiteralPath $reg)){$key=Get-Item -LiteralPath $reg;if($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0){Remove-Item -LiteralPath $reg}}
}
