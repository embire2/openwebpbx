# SPDX-License-Identifier: AGPL-3.0-or-later
# Administrator-only IIS meeting transport. Importing this file changes nothing.
function Get-OpenWebMeetFailure {
 param($Failure,[string]$Phase,[Nullable[int]]$CommandExit)
 $phases=@('websockets','rewrite_download','rewrite_signature','rewrite_identity','rewrite_install','arr_download','arr_signature','arr_identity','arr_install','trust','hosts','strict_flags','proxy','web_config','complete_ledger','helper_copy','previous_trust','recovery_web_config','recovery_hosts','recovery_flags','recovery_proxy','recovery_trust','recovery_previous_trust','recovery_packages','recovery_websockets','recovery_registry','recovery_ledger','unknown')
 $sources=@('Install-Meet.ps1','Meet-Proxy.ps1','Write-PrivateState.ps1')
 $types=@('RuntimeException','MethodInvocationException','ActionPreferenceStopException','ParameterBindingException','ParameterBindingValidationException','ItemNotFoundException','ProviderInvocationException','InvalidOperationException','IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ArgumentException','FormatException','Win32Exception','COMException','WebException','Exception')
 $name=if($Failure.InvocationInfo.ScriptName){Split-Path -Leaf $Failure.InvocationInfo.ScriptName}else{'external_component'}
 $record=@{phase=if($Phase -cin $phases){$Phase}else{'unknown'};source_basename=if($name -cin $sources){$name}else{'external_component'};source_line=[Math]::Max(1,[Math]::Min(99999,[int]$Failure.InvocationInfo.ScriptLineNumber));exception_types=@();hresults=@()}
 for($exception=$Failure.Exception;$exception -and $record.exception_types.Count -lt 4;$exception=$exception.InnerException){
  $type=$exception.GetType().Name;$record.exception_types+=if($type -cin $types){$type}else{'external_error'}
  $record.hresults+=[int]$exception.HResult
 }
 if($null -ne $CommandExit){$record.command_exit=[int]$CommandExit}
 return $record
}
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
function ConvertTo-OpenWebMeetProxyXml([Xml.XmlNode]$Node) {
 if(!$Node){return ''}
 $text=[IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
 $settings=[Xml.XmlWriterSettings]::new();$settings.OmitXmlDeclaration=$true;$settings.Indent=$false;$settings.NewLineHandling='None'
 $writer=[Xml.XmlWriter]::Create($text,$settings)
 function WriteNode([Xml.XmlNode]$Current,[int]$Depth){
  if($Depth -gt 32 -or $Current.NamespaceURI){throw 'The local IIS proxy configuration has an unsupported shape.'}
  $writer.WriteStartElement($Current.Name)
  $attributes=[Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
  foreach($attribute in $Current.Attributes){if($attribute.NamespaceURI){throw 'The local IIS proxy configuration has an unsupported attribute.'};$attributes.Add($attribute.Name,$attribute.Value)}
  foreach($attribute in $attributes.GetEnumerator()){$writer.WriteAttributeString($attribute.Key,$attribute.Value)}
  foreach($child in $Current.ChildNodes){
   if($child.NodeType -eq [Xml.XmlNodeType]::Element){WriteNode $child ($Depth+1)}
   elseif($child.NodeType -in [Xml.XmlNodeType]::Text,[Xml.XmlNodeType]::CDATA){$writer.WriteString($child.Value)}
   elseif($child.NodeType -notin [Xml.XmlNodeType]::Whitespace,[Xml.XmlNodeType]::SignificantWhitespace,[Xml.XmlNodeType]::Comment){throw 'The local IIS proxy configuration contains unsupported content.'}
  }
  $writer.WriteEndElement()
 }
 try{WriteNode $Node 0;$writer.Flush();return $text.ToString()}finally{$writer.Dispose();$text.Dispose()}
}
function Get-OpenWebMeetProxyXmlState([string]$Path) {
 $defaultPath=[string]::IsNullOrEmpty($Path)
 if($defaultPath){
  $Path=Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
  $redirect=Join-Path $env:windir 'System32\inetsrv\config\redirection.config'
  $null=Assert-OpenWebMeetOrdinary $redirect
  if(Test-Path -LiteralPath $redirect){
   $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1MB
   $redirectReader=[Xml.XmlReader]::Create($redirect,$settings);$redirectXml=[xml]::new();$redirectXml.XmlResolver=$null
   try{$redirectXml.Load($redirectReader)}finally{$redirectReader.Dispose()}
   $redirection=$redirectXml.SelectSingleNode('/configuration/configurationRedirection')
   if($redirection -and $redirection.HasAttribute('enabled') -and $redirection.GetAttribute('enabled') -cnotin 'false','0'){throw 'Shared IIS configuration requires administrator review before local meeting proxy changes.'}
  }
 }
 $null=Assert-OpenWebMeetOrdinary $Path
 $checksum=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
 $readerSettings=[Xml.XmlReaderSettings]::new();$readerSettings.DtdProcessing='Prohibit';$readerSettings.XmlResolver=$null;$readerSettings.MaxCharactersInDocument=32MB
 $reader=[Xml.XmlReader]::Create($Path,$readerSettings);$xml=[xml]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true
 try{$xml.Load($reader)}finally{$reader.Dispose()}
 if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $checksum){throw 'The local IIS configuration changed during its meeting snapshot.'}
 $nodes=@($xml.SelectNodes('/configuration/system.webServer/proxy'))
 if($nodes.Count -gt 1){throw 'The local IIS proxy configuration is ambiguous.'}
 $node=if($nodes.Count){$nodes[0]}else{$null};$present=$node -and $node.HasAttribute('enabled')
 if($present -and $node.GetAttribute('enabled') -cnotin 'true','false'){throw 'The local IIS proxy enabled value is unsupported.'}
 return @{Xml=(ConvertTo-OpenWebMeetProxyXml $node);EnabledPresent=[bool]$present;Enabled=([bool]$present -and $node.GetAttribute('enabled') -ceq 'true');ConfigurationSha256=$checksum}
}
function Get-OpenWebMeetEnabledProxyXml($State) {
 $xml=[xml]::new();$xml.XmlResolver=$null
 if($State.Xml){$xml.LoadXml([string]$State.Xml)}else{$xml.LoadXml('<proxy/>')}
 $xml.DocumentElement.SetAttribute('enabled','true')
 return ConvertTo-OpenWebMeetProxyXml $xml.DocumentElement
}
function Assert-OpenWebMeetProxyOwnership([string]$Current,[string]$Before,[string]$After) {
 if($Current -cne $Before -and $Current -cne $After){throw 'IIS proxy configuration changed during recovery.'}
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
 $null=Get-OpenWebMeetProxyXmlState
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
 # The installed IIS WebSocket feature defaults to enabled. Its stock section
 # is locked against child overrides, so inherit the existing parent policy.
 if($socket -and $socket.GetAttribute('enabled') -ne 'true'){throw 'The existing PBX WebSocket policy needs administrator review.'}
 $xml.Save($Path)
}
function Assert-OpenWebMeetWebSocket {
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX']
  if(!$site -or [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -ine 'C:\OpenWebPBX\web'){throw 'The owned PBX IIS site is required.'}
  $socket=$manager.GetWebConfiguration('OpenWebPBX').GetSection('system.webServer/webSocket')
  if(![bool]$socket['enabled']){throw 'The effective PBX WebSocket policy is disabled and needs administrator review.'}
 }finally{$manager.Dispose()}
}
function Restore-OpenWebMeetSystem {
 param([string]$Snapshot,[string]$StateRoot,[string]$LedgerPath=(Join-Path $StateRoot 'meet-proxy.json'))
 $before=Get-Content -LiteralPath $Snapshot -Raw|ConvertFrom-Json
 if($before.Schema -ne 1){throw 'The meeting recovery snapshot is invalid.'}
 if(!(Test-Path -LiteralPath $LedgerPath)){return}
 $ledger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json
 if($ledger.Schema -ne 1 -or $ledger.Thumbprint -cnotmatch '^[A-F0-9]{40}$'){throw 'The owned meeting transport ledger is invalid.'}
 $script:OpenWebMeetRecoveryPhase='recovery_hosts'
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
 $script:OpenWebMeetRecoveryPhase='recovery_flags'
 $reg='HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters'
 $current=Get-ItemProperty -LiteralPath $reg -Name SecureConnectionIgnoreFlags -ErrorAction SilentlyContinue
 if($current -and [int]$current.SecureConnectionIgnoreFlags -ne 0){throw 'IIS backend certificate policy changed during meeting recovery.'}
 if($before.IgnoreFlagsExists){New-ItemProperty -Path $reg -Name SecureConnectionIgnoreFlags -Value ([int]$before.IgnoreFlags) -PropertyType DWord -Force|Out-Null}
 else{Remove-ItemProperty -LiteralPath $reg -Name SecureConnectionIgnoreFlags -ErrorAction SilentlyContinue}
 $script:OpenWebMeetRecoveryPhase='recovery_proxy'
 if((Get-OpenWebMeetProxyState).Exists){
  $current=Get-OpenWebMeetProxyXmlState
  $manager=[Microsoft.Web.Administration.ServerManager]::new()
  try{
   $section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy')
   if($ledger.PSObject.Properties['ProxyBeforeXml']){Assert-OpenWebMeetProxyOwnership $current.Xml ([string]$ledger.ProxyBeforeXml) ([string]$ledger.ProxyAfterXml)}
   if([bool]$section['preserveHostHeader'] -ne [bool]$before.Proxy.PreserveHostHeader){throw 'IIS proxy host policy changed during recovery.'}
   if($ledger.PSObject.Properties['ProxyBeforeXml']){
    if($current.Xml -cne [string]$ledger.ProxyBeforeXml){
     if(!$ledger.ProxyBeforeXml){$section.RevertToParent()}
     elseif($ledger.ProxyEnabledBeforePresent){$section['enabled']=[bool]$ledger.ProxyEnabledBefore}
     else{$section.Attributes['enabled'].Delete()}
     if((Get-OpenWebMeetProxyXmlState).ConfigurationSha256 -cne $current.ConfigurationSha256){throw 'The IIS configuration changed before scoped meeting recovery.'}
     $manager.CommitChanges()
     if((Get-OpenWebMeetProxyXmlState).Xml -cne [string]$ledger.ProxyBeforeXml){throw 'IIS proxy recovery did not preserve the original section.'}
    }
   }elseif([bool]$section['enabled'] -ne [bool]$before.Proxy.Enabled){throw 'IIS proxy enabled state changed before this transaction recorded ownership.'}
  }finally{$manager.Dispose()}
 }
 $script:OpenWebMeetRecoveryPhase='recovery_trust'
 if($ledger.Thumbprint -notin @($before.RootThumbprints)){
  $path='Cert:\LocalMachine\Root\'+$ledger.Thumbprint
  if(Test-Path -LiteralPath $path){$cert=Get-Item -LiteralPath $path;if([Convert]::ToBase64String($cert.RawData) -cne $ledger.Certificate){throw 'The owned meeting trust certificate changed during recovery.'};Remove-Item -LiteralPath $path -Force}
 }
 $script:OpenWebMeetRecoveryPhase='recovery_previous_trust'
 if($before.PreviousMeetCertificate){
  $previous=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String([string]$before.PreviousMeetCertificate))
  if($previous.Thumbprint -notin @($before.RootThumbprints) -or $previous.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'openweb-meet.internal' -or $previous.Subject -cne $previous.Issuer){throw 'The previous meeting trust identity is invalid.'}
  if(!(Test-Path ('Cert:\LocalMachine\Root\'+$previous.Thumbprint))){$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine');$store.Open('ReadWrite');try{$store.Add($previous)}finally{$store.Close()}}
 }
 # Only packages introduced by this transaction may be uninstalled. Existing
 # IIS extension installations and their other configuration remain untouched.
 $script:OpenWebMeetRecoveryPhase='recovery_packages'
 foreach($product in @($ledger.Products)|Sort-Object Order -Descending){
  $wasInstalled=if($product.Kind -eq 'Arr'){[bool]$before.Arr}else{[bool]$before.Rewrite}
  if(!$wasInstalled -and $product.Introduced){
   if($product.ProductCode -cnotmatch '^\{[A-F0-9-]{36}\}$'){throw 'The owned IIS prerequisite identity is invalid.'}
   $process=Start-Process msiexec.exe -ArgumentList @('/x',$product.ProductCode,'/qn','/norestart') -Wait -PassThru
   if($process.ExitCode -notin 0,1605){throw 'The newly introduced meeting prerequisite needs administrator recovery.'}
  }
 }
 $script:OpenWebMeetRecoveryPhase='recovery_websockets'
 if(!$before.WebSockets -and (Get-WindowsFeature Web-WebSockets).Installed){$result=Uninstall-WindowsFeature Web-WebSockets;if(!$result.Success -or $result.RestartNeeded -eq 'Yes'){throw 'Windows requires administrator recovery for its newly introduced WebSocket feature.'}}
 $script:OpenWebMeetRecoveryPhase='recovery_registry'
 if(!$before.IgnoreKeyExists -and (Test-Path -LiteralPath $reg)){$key=Get-Item -LiteralPath $reg;if($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0){Remove-Item -LiteralPath $reg}}
}
