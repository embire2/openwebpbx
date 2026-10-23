# Exact scoped restoration body before snapshot-aware recovery. It selected
# the first installation ledger instead of the current upgrade snapshot.
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
