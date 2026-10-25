# SPDX-License-Identifier: AGPL-3.0-or-later
# Existing reviewed media primitives, retained byte-exact except this provenance header.
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

function PrivateDirectory([string]$Path){
 if(Test-Path -LiteralPath $Path){throw 'A new owned scope is required.'};[void][IO.Directory]::CreateDirectory($Path)
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
 foreach($sid in @($user,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path),$acl)
}

function NoLinks([string]$Path){
 $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($Path);$count=0
 while($pending.Count){$next=$pending.Pop();$item=Get-Item -LiteralPath $next -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned cleanup refuses a linked entry.'};if(++$count -gt 30000){throw 'Owned tree exceeds its cleanup bound.'};if($item.PSIsContainer){foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($next)){$pending.Push($entry)}}}
}

function SystemSnapshot{
 $services=@(Get-CimInstance Win32_Service|Sort-Object Name|ForEach-Object {[ordered]@{name=$_.Name;state=$_.State;mode=$_.StartMode;path=$_.PathName;account=$_.StartName}})
 $certs=@(Get-ChildItem Cert:\LocalMachine\Root,Cert:\CurrentUser\Root|ForEach-Object {$_.Thumbprint}|Sort-Object)
 $rules=[ordered]@{}
 foreach($store in @('ActiveStore','PersistentStore')){foreach($command in @('Get-NetFirewallRule','Get-NetFirewallProfile','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter')){
  $rows=@(& $command -PolicyStore $store|Sort-Object InstanceID,Name|ForEach-Object {$values=[ordered]@{};foreach($field in @($_.CimInstanceProperties|Sort-Object Name)){$values[$field.Name]=$field.Value};$values});$rules[$store+'/'+$command]=$rows
 }}
 [ordered]@{services=$services;root_certificates=$certs;firewall=$rules}|ConvertTo-Json -Depth 8 -Compress
}

Add-Type -TypeDefinition @'
using System.IO;using System.Text;using System.Threading.Tasks;
public sealed record MediaCapturedError(string Text,long Characters,bool Truncated);
public static class MediaChildDrain {
 public static async Task<long> Pump(StreamReader reader) { var chars=new char[4096];long total=0;int count;while((count=await reader.ReadAsync(chars))!=0)total=checked(total+count);return total;}
 public static async Task<MediaCapturedError> Capture(StreamReader reader,int limit) { var chars=new char[4096];var text=new StringBuilder(limit);long total=0;int count;while((count=await reader.ReadAsync(chars))!=0){total=checked(total+count);var keep=System.Math.Min(count,limit-text.Length);if(keep>0)text.Append(chars,0,keep);}return new(text.ToString(),total,total>limit);}
}
'@


function MediaGet([string]$Address,[string]$Target,[long]$Limit,[switch]$Api){
  $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseDefaultCredentials=$false;$handler.UseCookies=$false
  $http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[Threading.Timeout]::InfiniteTimeSpan
  $deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15));$response=$null;$out=$null
  try{
    $uri=[Uri]$Address
    for($i=0;$i -le 5;$i++){
      if($uri.Scheme -cne 'https' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsoluteUri.Length -gt 16384 -or $uri.Host -cnotin 'api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','download.linphone.org'){throw 'Component redirect refused.'}
      if($uri.Host -ceq 'api.github.com' -and (!$Api -or !$uri.AbsolutePath.StartsWith('/repos/embire2/openwebpbx/actions/',[StringComparison]::Ordinal))){throw 'API component scope differs.'}
      if($uri.Host -ceq 'github.com' -and $uri.AbsolutePath -cne '/signalwire/freeswitch/releases/download/v1.11.3/FreeSWITCH-1.11.3-Release-x64.msi'){throw 'Public component scope differs.'}
      if($uri.Host -ceq 'download.linphone.org' -and $uri.AbsolutePath -cne '/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip'){throw 'SDK component scope differs.'}
      $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri);$request.Headers.UserAgent.ParseAdd('OpenWebPBX-ClientMedia/1.0')
      if($Api -and $uri.Host -ceq 'api.github.com'){$request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:MEDIA_ACTIONS_TOKEN);$request.Headers.Add('X-GitHub-Api-Version','2022-11-28')}
      try{$response=$http.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()}finally{$request.Dispose()}
      if([int]$response.StatusCode -in 301,302,303,307,308){$next=$response.Headers.Location;if(!$next -or $i -eq 5){throw 'Component redirect bound exceeded.'};$uri=[Uri]::new($uri,$next);$response.Dispose();$response=$null;continue}
      if([int]$response.StatusCode -ne 200){throw 'Pinned component unavailable.'};break
    }
    if(!$response -or [int]$response.StatusCode -ne 200 -or ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $Limit)){throw 'Component response exceeds bound.'}
    $out=[IO.File]::Open($Target,'CreateNew','Write','None');$input=$response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
    try{$bytes=[byte[]]::new(131072);$total=0L;while(($n=$input.ReadAsync($bytes,0,$bytes.Length,$deadline.Token).GetAwaiter().GetResult()) -gt 0){$total+=$n;if($total -gt $Limit){throw 'Component body exceeds bound.'};$out.Write($bytes,0,$n)};$out.Flush($true)}finally{$input.Dispose();$out.Dispose();$out=$null}
  }finally{if($out){$out.Dispose()};if($response){$response.Dispose()};$deadline.Dispose();$http.Dispose()}
}
